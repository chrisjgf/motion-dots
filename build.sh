#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="MotionDots.app"
BUNDLE_ID="com.motiondots.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/MotionDots"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Built $APP — run with: open $APP"
