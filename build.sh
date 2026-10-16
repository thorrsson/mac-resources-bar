#!/bin/sh
# Builds ResourcesBar.app into ./build. Usage: ./build.sh [install]
set -eu
cd "$(dirname "$0")"

APP=build/ResourcesBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"

for arch in arm64 x86_64; do
  swiftc -O -wmo -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -Xlinker -dead_strip \
    -o "build/ResourcesBar-$arch" Sources/main.swift
done
lipo -create build/ResourcesBar-arm64 build/ResourcesBar-x86_64 -output "$APP/Contents/MacOS/ResourcesBar"
rm build/ResourcesBar-arm64 build/ResourcesBar-x86_64
strip -x "$APP/Contents/MacOS/ResourcesBar"
codesign --force --sign - "$APP"

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/ResourcesBar.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/ResourcesBar.app"
fi
