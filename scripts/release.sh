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
#   ZONOGY_ALLOW_DIRTY=1  - allow releasing from a dirty working tree

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

step() { printf '\n==> %s\n' "$1"; }

# Submit an artifact for notarization. On failure, automatically fetches and prints
# the detailed log for the rejected submission so the user does not have to dig
# through `notarytool history` manually.
notarize() {
  local artifact="$1"
  local submit_log="$WORK_DIR/notary-submit.log"
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
    return "$rc"
  fi
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
# Released builds must be reproducible from history: build.sh stamps the git
# hash into the bundle and marks a dirty tree with a trailing "+", so refuse
# to sign a build with uncommitted changes or unverifiable git state.
if [[ "${ZONOGY_ALLOW_DIRTY:-}" != "1" ]]; then
  GIT_STATUS="$(git -C "$PROJECT_DIR" status --porcelain)" || {
    echo "Cannot determine git status; refusing to release."
    echo "Set ZONOGY_ALLOW_DIRTY=1 to bypass intentionally."
    exit 1
  }
  if [[ -n "$GIT_STATUS" ]]; then
    echo "Refusing to release from a dirty working tree."
    echo "Commit (or stash) changes so the stamped git hash matches the released code."
    echo "Set ZONOGY_ALLOW_DIRTY=1 to bypass intentionally."
    exit 1
  fi
fi
# Captured for the publish command printed at the end: tagging --target this
# commit pins the release tag to the exact code packaged into the DMG (and
# fails if the commit was never pushed).
GIT_HEAD_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
  || { echo "Signing identity not found: $SIGN_IDENTITY"; exit 1; }
NOTARY_CHECK_OUTPUT=""
if ! NOTARY_CHECK_OUTPUT="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
  echo "Notarization credential check failed for keychain profile '$NOTARY_PROFILE':" >&2
  printf '%s\n' "$NOTARY_CHECK_OUTPUT" >&2
  echo >&2
  echo "If the profile is missing, configure it with:" >&2
  echo "  xcrun notarytool store-credentials '$NOTARY_PROFILE'" >&2
  exit 1
fi
[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements file: $ENTITLEMENTS"; exit 1; }

mkdir -p "$DIST_DIR"

# Scratch space for the notarization zip, submit log, and DMG staging;
# cleaned up on any exit.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
APP_ZIP_PATH="$WORK_DIR/$APP_NAME-$VERSION.zip"

step "Building app bundle (release)"
"$SCRIPT_DIR/build.sh"

step "Signing $APP_NAME.app with Developer ID + hardened runtime"
# The bundle signature covers and seals the main executable. If nested code
# (helpers, frameworks) is ever added to the bundle, sign it first, inside-out.
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

step "Submitting app for notarization (waits for result)"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP_PATH"
notarize "$APP_ZIP_PATH"

step "Stapling notarization ticket onto app"
xcrun stapler staple "$APP_BUNDLE"
spctl -a -vv -t execute "$APP_BUNDLE"

step "Building DMG"
rm -f "$DMG_PATH"
DMG_STAGE="$WORK_DIR/dmg"
mkdir "$DMG_STAGE"
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

cat <<EOF

Done.

Artifact:
  $DMG_PATH

Next step — publish the GitHub release for this exact commit (must be pushed):
  gh release create v$VERSION "$DMG_PATH" --target ${GIT_HEAD_SHA:-<commit>} --title "Zonogy $VERSION" --notes "What changed..."
EOF
