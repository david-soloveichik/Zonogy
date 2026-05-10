#!/bin/bash

# Release pipeline for Zonogy.app
# Builds, signs with Developer ID, notarizes, staples, and packages a DMG.
#
# Prerequisites:
#   - Developer ID Application certificate installed in login keychain.
#   - Notarization credentials stored under a keychain profile (default: zonogy-notary)
#     via `xcrun notarytool store-credentials`.
#
# Environment overrides:
#   ZONOGY_SIGN_IDENTITY  - codesign identity string (default reads from security find-identity)
#   ZONOGY_NOTARY_PROFILE - notarytool keychain profile name (default: zonogy-notary)
#   ZONOGY_VERSION        - version string used in artifact filenames (default: CFBundleShortVersionString)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Zonogy"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/Resources/Zonogy.entitlements"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"

SIGN_IDENTITY="${ZONOGY_SIGN_IDENTITY:-Developer ID Application: David Soloveichik (KPESSM9SZU)}"
NOTARY_PROFILE="${ZONOGY_NOTARY_PROFILE:-zonogy-notary}"
VERSION="${ZONOGY_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")}"

DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
APP_ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

step() { printf '\n==> %s\n' "$1"; }

# Submit an artifact for notarization. On failure, automatically fetches and prints
# the detailed log for the rejected submission so the user does not have to dig
# through `notarytool history` manually.
notarize() {
  local artifact="$1"
  local submit_log
  submit_log="$(mktemp)"
  set +e
  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1 | tee "$submit_log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    local sid
    sid="$(awk '/^[[:space:]]*id:/ {print $2; exit}' "$submit_log")"
    if [[ -n "$sid" ]]; then
      printf '\nNotarization failed. Detailed log for submission %s:\n' "$sid"
      xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    rm -f "$submit_log"
    return "$rc"
  fi
  rm -f "$submit_log"
}

step "Sanity checks"
# Defense in depth: refuse to release from an untrusted CI context (e.g., a
# pull_request event running fork-controlled code). The signing identity and
# notary credentials live in the local keychain; if a future CI workflow ever
# exposes them on PR events, an attacker's PR could get its modified app
# signed and notarized under this project's Developer ID without ever needing
# to exfiltrate the secrets themselves. Releases must come from a protected
# tag/branch after review. Set ZONOGY_RELEASE_OVERRIDE=1 to bypass intentionally.
if [[ "${CI:-}" == "true" \
   && ( "${GITHUB_EVENT_NAME:-}" == "pull_request" \
     || "${GITHUB_EVENT_NAME:-}" == "pull_request_target" ) \
   && "${ZONOGY_RELEASE_OVERRIDE:-}" != "1" ]]; then
  echo "Refusing to release from a CI pull_request event."
  echo "Releases must run on a protected tag/branch after review."
  echo "Set ZONOGY_RELEASE_OVERRIDE=1 to bypass intentionally."
  exit 1
fi
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || { echo "Signing identity not found: $SIGN_IDENTITY"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "Notary profile '$NOTARY_PROFILE' not configured. Run xcrun notarytool store-credentials."; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements file: $ENTITLEMENTS"; exit 1; }

mkdir -p "$DIST_DIR"

step "Building app bundle (release)"
"$SCRIPT_DIR/build.sh"

step "Signing $APP_NAME.app with Developer ID + hardened runtime"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

step "Submitting app for notarization (waits for result)"
rm -f "$APP_ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP_PATH"
notarize "$APP_ZIP_PATH"

step "Stapling notarization ticket onto app"
xcrun stapler staple "$APP_BUNDLE"
spctl -a -vv -t execute "$APP_BUNDLE"

step "Building DMG"
rm -f "$DMG_PATH"
DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG_PATH"

step "Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

step "Submitting DMG for notarization (waits for result)"
notarize "$DMG_PATH"

step "Stapling notarization ticket onto DMG"
xcrun stapler staple "$DMG_PATH"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

step "Computing SHA-256 (for Homebrew cask)"
shasum -a 256 "$DMG_PATH"

cat <<EOF

Done.

Artifacts:
  $DMG_PATH
  $APP_ZIP_PATH  (intermediate; can be deleted)

Next steps:
  1. Upload $DMG_PATH to a GitHub Release tagged v$VERSION.
  2. Update the Homebrew cask file with the new version, URL, and SHA-256.
EOF
