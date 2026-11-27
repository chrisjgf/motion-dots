import AppKit
import AVFoundation
import Vision

// Tuning — flip a gain's sign or raise it if the dots feel wrong in a moving car.
enum Tuning {
    static let verticalGain: CGFloat = 2.2   // pitch/bumps -> vertical dot scroll
    static let lateralGain: CGFloat = 1.4    // turns -> sideways sway
    static let smoothing: CGFloat = 0.18     // 0..1, higher = snappier response
    static let deadband: CGFloat = 0.35      // px/frame of camera motion treated as noise
    static let maxSway: CGFloat = 70         // clamp for lateral dot displacement
    static let swayDecay: CGFloat = 0.92     // spring-back toward center per tick
}

// MARK: - Camera motion estimation

final class MotionEstimator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "motiondots.camera")
    private var previousBuffer: CVPixelBuffer?

    // Called on the camera queue with the estimated translation (px/frame).
    var onMotion: ((CGFloat, CGFloat) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async {
                if self.session.inputs.isEmpty { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async {
            self.session.stopRunning()
            self.previousBuffer = nil
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        defer { previousBuffer = buffer }
        guard let previous = previousBuffer else { return }

        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return }
        let t = observation.alignmentTransform
        onMotion?(t.tx, t.ty)
    }
}

// MARK: - Overlay dots

final class DotsView: NSView {
    var scrollY: CGFloat = 0
    var sway: CGFloat = 0

    // Parallax depth layers: bigger dots move more (near field), smaller move
    // less (far field). Size must correlate with motion gain or it's just noise.
    private struct Layer {
        let radius: CGFloat
        let gain: CGFloat
        let alpha: CGFloat
        let columnShift: CGFloat
    }

    private let layers: [Layer] = [
        Layer(radius: 3, gain: 0.6, alpha: 0.22, columnShift: 0),
        Layer(radius: 5, gain: 1.0, alpha: 0.30, columnShift: 40),
        Layer(radius: 7, gain: 1.3, alpha: 0.38, columnShift: 80),
    ]

    private let spacing: CGFloat = 64
    private let columnSpacing: CGFloat = 120

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Full strength at the screen edges, fading to faint in the middle so the
    // center stays readable (Apple clears it entirely; we keep a whisper).
    private func edgeWeight(_ x: CGFloat) -> CGFloat {
        let half = bounds.width / 2
        let d = min(1, abs(x - half) / half) // 0 at center, 1 at edge
        return 0.12 + 0.88 * d * d
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        for layer in layers {
            let layerScroll = scrollY * layer.gain
            let layerSway = sway * layer.gain
            let wrapped = ((layerScroll.truncatingRemainder(dividingBy: spacing)) + spacing)
                .truncatingRemainder(dividingBy: spacing)

            var column = 0
            var baseX: CGFloat = columnSpacing / 2 + layer.columnShift
            while baseX < bounds.width {
                let phase: CGFloat = column % 2 == 0 ? 0 : spacing / 2
                let x = baseX + layerSway
                let weight = edgeWeight(x)
                let r = layer.radius
                var y = wrapped + phase - spacing
                while y < bounds.height + spacing {
                    let dot = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    // Dark halo behind a light dot so it reads on any background.
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.1 * weight).cgColor)
                    ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                    ctx.setFillColor(NSColor.white.withAlphaComponent(layer.alpha * weight).cgColor)
                    ctx.fillEllipse(in: dot)
                    y += spacing
                }
                column += 1
                baseX += columnSpacing
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var dotsView: DotsView!
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private let estimator = MotionEstimator()
    private var timer: Timer?

    private var rawX: CGFloat = 0
    private var rawY: CGFloat = 0
    private var smoothX: CGFloat = 0
    private var smoothY: CGFloat = 0
    private var paused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupOverlay()
        setupStatusItem()

        estimator.onMotion = { [weak self] dx, dy in
            DispatchQueue.main.async {
                self?.rawX = dx
                self?.rawY = dy
            }
        }
        estimator.start()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func setupOverlay() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        dotsView = DotsView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = dotsView
        window.orderFrontRegardless()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.grid.3x3.fill",
                                           accessibilityDescription: "MotionDots")
        let menu = NSMenu()
        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit MotionDots", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func tick() {
        guard !paused else { return }
        smoothX += (rawX - smoothX) * Tuning.smoothing
        smoothY += (rawY - smoothY) * Tuning.smoothing
        // Decay raw input so a stalled camera doesn't leave the dots drifting.
        rawX *= 0.85
        rawY *= 0.85

        let vx = abs(smoothX) < Tuning.deadband ? 0 : smoothX
        let vy = abs(smoothY) < Tuning.deadband ? 0 : smoothY

        dotsView.scrollY += vy * Tuning.verticalGain
        let sway = dotsView.sway * Tuning.swayDecay + vx * Tuning.lateralGain
        dotsView.sway = max(-Tuning.maxSway, min(Tuning.maxSway, sway))
        dotsView.needsDisplay = true
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseItem.title = paused ? "Resume" : "Pause"
        if paused {
            estimator.stop()
            window.orderOut(nil)
        } else {
            estimator.start()
            window.orderFrontRegardless()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
