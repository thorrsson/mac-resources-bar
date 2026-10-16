#!/bin/bash
# Builds a signed, notarized ResourcesBar disk image.
#
#   ./Scripts/release.sh <version>
#
# Produces dist/ResourcesBar-<version>.dmg and a .sha256 beside it.
#
# Environment:
#   SIGNING_IDENTITY       Developer ID Application identity. Defaults to the
#                          first one in the keychain; "-" forces ad-hoc.
#   BUILD_NUMBER           CFBundleVersion (default: git commit count)
#   NOTARY_PROFILE         a notarytool keychain profile, or
#   NOTARY_API_KEY_ID +
#   NOTARY_API_ISSUER_ID +
#   NOTARY_API_KEY_P8      an App Store Connect API key (path, PEM, or base64)
#   REQUIRE_NOTARIZATION=1 fail instead of skipping notarization (CI sets this)
#   SPARKLE_PUBLIC_ED_KEY + SPARKLE_PRIVATE_ED_KEY  matching update signing keys
#   REQUIRE_SPARKLE=1     require update signing (release CI sets this)
set -euo pipefail
cd "$(dirname "$0")/.."

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: $0 <version>"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
  || die "'$VERSION' is not a valid CFBundleShortVersionString (e.g. 1.2.3)"

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must be a positive integer"
export BUILD_NUMBER
APP=build/ResourcesBar.app
DIST=dist
DMG="$DIST/ResourcesBar-$VERSION.dmg"

if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" || "${REQUIRE_SPARKLE:-0}" == "1" ]]; then
  [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" && -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] \
    || die "SPARKLE_PUBLIC_ED_KEY and SPARKLE_PRIVATE_ED_KEY are required for update signing"
  swift Scripts/validate-sparkle-keys.swift
fi

IDENTITY="${SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  IDENTITY="${IDENTITY:--}"
fi

TEMP_DIR="$(mktemp -d -t resourcesbar-release)"
trap 'rm -rf "$TEMP_DIR"' EXIT

notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" && -n "${NOTARY_API_KEY_P8:-}" ]]; then
  key_path="$NOTARY_API_KEY_P8"
  if [[ ! -f "$key_path" ]]; then
    key_path="$TEMP_DIR/AuthKey.p8"
    if printf '%s' "$NOTARY_API_KEY_P8" | grep -q -- '-----BEGIN PRIVATE KEY-----'; then
      printf '%s\n' "$NOTARY_API_KEY_P8" > "$key_path"
    elif ! printf '%s' "$NOTARY_API_KEY_P8" | base64 --decode > "$key_path" 2>/dev/null; then
      die "NOTARY_API_KEY_P8 is neither a file path, PEM content, nor valid base64"
    fi
    chmod 600 "$key_path"
  fi
  openssl pkey -in "$key_path" -noout >/dev/null 2>&1 \
    || die "NOTARY_API_KEY_P8 is not a valid App Store Connect .p8 key"
  notary_args=(--key "$key_path" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
fi

can_notarize=1
[[ "$IDENTITY" == "-" ]] && can_notarize=0
[[ ${#notary_args[@]} -eq 0 ]] && can_notarize=0
if [[ $can_notarize -eq 0 && "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    die "notarization required but no Developer ID identity is available"
  fi
  die "notarization required but no notary credentials are configured"
fi

log "Building ResourcesBar $VERSION ($BUILD_NUMBER), signing as: $IDENTITY"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGNING_IDENTITY="$IDENTITY" ./build.sh

log "Creating $DMG"
mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"
staging="$TEMP_DIR/dmg"
mkdir -p "$staging"
# ditto preserves the extended attributes the code signature is sealed over.
ditto "$APP" "$staging/ResourcesBar.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "ResourcesBar $VERSION" -srcfolder "$staging" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" > /dev/null

if [[ "$IDENTITY" != "-" ]]; then
  # Signing the image lets the notarization ticket be stapled to it.
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

if [[ $can_notarize -eq 1 ]]; then
  log "Notarizing $DMG (usually a few minutes)"
  submit_log="$TEMP_DIR/notary.log"
  xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait --timeout 30m | tee "$submit_log" || true
  # notarytool exits 0 for a submission Apple then rejected, so check the status.
  if ! grep -q 'status: Accepted' "$submit_log"; then
    submission_id="$(awk '/id:/ { print $2; exit }' "$submit_log")"
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
    die "notarization was not accepted"
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  warn "skipping notarization; $DMG will be blocked by Gatekeeper on other Macs."
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
rm -f "$DIST/appcast.xml"
if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
  log "Generating the signed Sparkle appcast"
  # Isolate this release so stale local archives cannot enter the feed.
  mkdir "$TEMP_DIR/updates"
  cp "$DMG" "$TEMP_DIR/updates/"
  printf '%s' "$SPARKLE_PRIVATE_ED_KEY" |
    build/Sparkle-2.10.0/bin/generate_appcast \
      --ed-key-file - --maximum-deltas 0 \
      --download-url-prefix "https://github.com/thorrsson/mac-resources-bar/releases/download/v$VERSION/" \
      --link "https://github.com/thorrsson/mac-resources-bar/releases/tag/v$VERSION" \
      -o "$DIST/appcast.xml" "$TEMP_DIR/updates"
  [[ -s "$DIST/appcast.xml" ]] || die "Sparkle did not generate an appcast"
else
  warn "skipping appcast generation; SPARKLE_PRIVATE_ED_KEY is unset."
fi
log "Done: $DMG"
