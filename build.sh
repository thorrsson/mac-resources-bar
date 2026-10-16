#!/bin/sh
# Builds ResourcesBar.app into ./build. Usage: ./build.sh [install]
#
# Optional environment:
#   VERSION           CFBundleShortVersionString (default: the value in Info.plist)
#   BUILD_NUMBER      CFBundleVersion (default: the value in Info.plist)
#   SIGNING_IDENTITY  codesigning identity; "-" (default) signs ad-hoc. Any other
#                     identity signs with the Hardened Runtime and a secure
#                     timestamp, which notarization requires.
set -eu
cd "$(dirname "$0")"

APP=build/ResourcesBar.app
IDENTITY="${SIGNING_IDENTITY:--}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

for arch in arm64 x86_64; do
  swiftc -O -wmo -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -Xlinker -dead_strip \
    -o "build/ResourcesBar-$arch" Sources/main.swift
done
lipo -create build/ResourcesBar-arm64 build/ResourcesBar-x86_64 -output "$APP/Contents/MacOS/ResourcesBar"
rm build/ResourcesBar-arm64 build/ResourcesBar-x86_64
strip -x "$APP/Contents/MacOS/ResourcesBar"

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/ResourcesBar.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/ResourcesBar.app"
fi
