#!/usr/bin/env bash
# Notarize and staple a Developer ID signed Kaiming.app.
#
# Credentials (either form):
#   APPLE_ID + APPLE_TEAM_ID + APP_NOTARY_PASSWORD   (app-specific password)
# or a stored notarytool keychain profile:
#   NOTARY_PROFILE=KaimingNotary
#
# Usage: ./Scripts/notarize.sh [path/to/Kaiming.app]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/export/Kaiming.app}"

if [ ! -d "$APP" ]; then
  echo "!! app not found: $APP" >&2
  exit 1
fi

echo "==> Checking signature"
codesign --verify --deep --strict --verbose=2 "$APP"

if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "!! $APP is not signed with a Developer ID Application certificate." >&2
  echo "   Re-run: DEVELOPMENT_TEAM=<team> ./Scripts/archive.sh --sign" >&2
  exit 1
fi

ZIP="$ROOT/build/Kaiming-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SUBMIT_ARGS=(--wait)
if [ -n "${NOTARY_PROFILE:-}" ]; then
  SUBMIT_ARGS+=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${APPLE_ID:?Set APPLE_ID or NOTARY_PROFILE}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID or NOTARY_PROFILE}"
  : "${APP_NOTARY_PASSWORD:?Set APP_NOTARY_PASSWORD or NOTARY_PROFILE}"
  SUBMIT_ARGS+=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APP_NOTARY_PASSWORD")
fi

echo "==> Submitting to Apple notary service"
xcrun notarytool submit "$ZIP" "${SUBMIT_ARGS[@]}"

echo "==> Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Notarized: $APP"
