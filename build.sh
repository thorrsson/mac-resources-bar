#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "ResourcesBar requires macOS 13+ and the Xcode Command Line Tools." >&2
    exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="$ROOT/build"
APP="$BUILD/ResourcesBar.app"
mkdir -p "$APP/Contents/MacOS"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -whole-module-optimization -swift-version 5 \
        -sdk "$SDK" -target "$ARCH-apple-macos13.0" \
        -framework AppKit -framework IOKit -framework ServiceManagement \
        "$ROOT/Sources/Metrics.swift" "$ROOT/Sources/App.swift" \
        -o "$BUILD/ResourcesBar-$ARCH"
done
xcrun lipo -create "$BUILD/ResourcesBar-arm64" "$BUILD/ResourcesBar-x86_64" \
    -output "$APP/Contents/MacOS/ResourcesBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP (arm64 + x86_64)"
