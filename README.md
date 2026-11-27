# MotionDots

A lightweight, single-file macOS menu bar utility that renders subtle parallax motion-cue dots across the screen, driven by your Mac's camera to help reduce motion sickness while working in a moving vehicle.

## How it works

- **Camera-driven motion estimation**: Uses `AVFoundation` (640×480 video frames) and Apple's `Vision` framework (`VNTranslationalImageRegistrationRequest`) to measure frame-to-frame translation locally on-device.
- **Click-through overlay**: Borderless, transparent, screen-saver-level overlay visible across all Spaces and full-screen apps without intercepting clicks.
- **Parallax depth & center falloff**: Three depth layers of dots move at scaled gains (`0.6×`, `1.0×`, `1.3×`) with full visibility near the screen edges and low opacity across the center so text remains easy to read.
- **Menu bar controls**: Click the grid icon in the menu bar to Pause/Resume (`⌘P`) or Quit (`⌘Q`).

## Privacy

- All camera frame analysis runs 100% locally in memory using Apple's on-device Vision framework.
- Frames are never saved to disk or transmitted over the network.
- Zero external dependencies, telemetry, or analytics.

## Requirements

- macOS 13 (Ventura) or later
- Xcode or Swift Command Line Tools (`swiftc`)

## Build & Run

```sh
git clone https://github.com/chrisjgf/motion-dots.git
cd motion-dots
./build.sh
open MotionDots.app
```

Grant Camera permission when macOS prompts on first launch.

## Tuning

Adjust the responsiveness, gains, deadband, and sway damping at the top of `Sources/main.swift` (`enum Tuning`), then re-run `./build.sh`.

## Notes

- Because camera-based optical flow measures movement relative to the visible scene (the rider and vehicle interior), it responds well to bumps, turns, and vibration, and less strongly to smooth constant acceleration.
- macOS 15.2+ on supported Macs also offers a built-in alternative under **System Settings → Accessibility → Motion → Show Vehicle Motion Cues**.
