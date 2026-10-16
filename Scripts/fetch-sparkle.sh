#!/bin/sh
# Pinned binary dependency shared by the compiler and release tooling.
set -eu
cd "$(dirname "$0")/.."

VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DEST="build/Sparkle-$VERSION"
if [ -f "$DEST/.verified-$SHA256" ]; then
  exit 0
fi

mkdir -p build
TEMP_DIR="$(mktemp -d build/sparkle-download.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
  -o "$TEMP_DIR/Sparkle.tar.xz"
echo "$SHA256  $TEMP_DIR/Sparkle.tar.xz" | shasum -a 256 --check --status
mkdir "$TEMP_DIR/extracted"
tar -xf "$TEMP_DIR/Sparkle.tar.xz" -C "$TEMP_DIR/extracted"
rm -rf "$DEST"
mv "$TEMP_DIR/extracted" "$DEST"
touch "$DEST/.verified-$SHA256"
