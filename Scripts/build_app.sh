#!/usr/bin/env bash
#
# Builds RecordTimeLapse and assembles a signed .app bundle.
#
#   ./Scripts/build_app.sh            # release build, auto-detected signing identity
#   ./Scripts/build_app.sh --install  # …and update the copy in /Applications (Spotlight)
#   SIGN_ID="Apple Development: you (TEAMID)" ./Scripts/build_app.sh
#   CONFIG=debug ./Scripts/build_app.sh
#
# Why signing matters: the macOS Screen Recording (TCC) permission is keyed on the bundle id
# PLUS the code-signing designated requirement. Ad-hoc signing ("-") uses a cdhash that changes
# on every rebuild, so the permission is revoked each time. Signing with a STABLE certificate
# (Apple Development / Developer ID) keeps the grant across rebuilds.

set -euo pipefail

cd "$(dirname "$0")/.."          # package root (so -sectcreate Info.plist resolves)

APP_NAME="RecordTimeLapse"
BUNDLE_ID="com.recvient.RecordTimeLapse"
CONFIG="${CONFIG:-release}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▶︎ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[[ -f "$BIN" ]] || { echo "✗ built binary not found at $BIN"; exit 1; }

echo "▶︎ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Pick a stable signing identity unless one was provided.
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
fi

if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="-"
  echo "⚠︎  No Developer ID / Apple Development identity found — signing AD-HOC."
  echo "    The Screen Recording permission will reset on every rebuild."
else
  echo "▶︎ codesign identity: $SIGN_ID"
fi

codesign --force --options runtime --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP"
codesign --verify --verbose "$APP" || true

echo ""
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Quit a running copy first so the bundle isn't replaced under a live process.
  pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null && sleep 1
  ditto "$APP" "/Applications/$APP_NAME.app"
  echo "✓ Installed /Applications/$APP_NAME.app — launch it from Spotlight (⌘Space → \"Record TimeLapse\")"
else
  echo "  Run it:    open \"$APP\""
  echo "  Install:   ./Scripts/build_app.sh --install"
fi
echo ""
echo "  First launch: grant Screen Recording in"
echo "  System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording,"
echo "  then re-open the app. The menu-bar icon (record.circle) appears at the top-right."
