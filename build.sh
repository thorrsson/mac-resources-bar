#!/bin/sh
# Builds ResourcesBar.app into ./build. Usage: ./build.sh [install]
#
# Optional environment:
#   VERSION           CFBundleShortVersionString (default: the value in Info.plist)
#   BUILD_NUMBER      CFBundleVersion (default: the value in Info.plist)
#   SIGNING_IDENTITY  codesigning identity; "-" (default) signs ad-hoc. Any other
#                     identity signs with the Hardened Runtime and a secure
#                     timestamp, which notarization requires.
#   SPARKLE_PUBLIC_ED_KEY  Ed25519 public key; omitted local builds disable updates.
set -eu
cd "$(dirname "$0")"

APP=build/ResourcesBar.app
IDENTITY="${SIGNING_IDENTITY:--}"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  swift Scripts/validate-sparkle-keys.swift
fi
sh Scripts/fetch-sparkle.sh
SPARKLE=build/Sparkle-2.10.0
ICONSET=build/ResourcesBar.iconset
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift Scripts/generate-app-icon.swift "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/ResourcesBar.icns" "$ICONSET"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
else
  echo "warning: SPARKLE_PUBLIC_ED_KEY is unset; updates are disabled in this build." >&2
fi
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

for arch in arm64 x86_64; do
  swiftc -O -wmo -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -F "$SPARKLE" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -dead_strip \
    -o "build/ResourcesBar-$arch" Sources/main.swift
done
lipo -create build/ResourcesBar-arm64 build/ResourcesBar-x86_64 -output "$APP/Contents/MacOS/ResourcesBar"
rm build/ResourcesBar-arm64 build/ResourcesBar-x86_64
strip -x "$APP/Contents/MacOS/ResourcesBar"

# Sign inside-out, including Sparkle's nested helpers, before sealing the app.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for component in \
  "$FRAMEWORK/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Autoupdate" \
  "$FRAMEWORK/Updater.app" \
  "$APP/Contents/Frameworks/Sparkle.framework"; do
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$component"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$component"
  fi
done

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/ResourcesBar.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/ResourcesBar.app"
fi
