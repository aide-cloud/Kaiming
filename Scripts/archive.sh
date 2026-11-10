#!/usr/bin/env bash
# Archive Kaiming.
#
# Ad-hoc (no Developer ID, for local testing):
#   ./Scripts/archive.sh
#
# Developer ID signed release (requires a Developer ID Application certificate):
#   DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/archive.sh --sign
#
# Optional env:
#   DEVELOPMENT_TEAM   Apple team id
#   CODE_SIGN_IDENTITY defaults to "Developer ID Application"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN=0
[ "${1:-}" = "--sign" ] && SIGN=1

VERSION="${KAIMING_VERSION:-1.0.0}"
ARCHIVE="$ROOT/build/Kaiming.xcarchive"
EXPORT_DIR="$ROOT/build/export"
DERIVED="$ROOT/build/dd-release"
mkdir -p "$ROOT/build/tmp" "$ROOT/build/mcache"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

SIGN_ARGS=()
if [ "$SIGN" = "1" ]; then
  : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team id}"
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
  echo "==> Archiving with Developer ID (team $DEVELOPMENT_TEAM)"
else
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="-"
    DEVELOPMENT_TEAM=""
    ENABLE_HARDENED_RUNTIME=NO
  )
  echo "==> Archiving ad-hoc signed (local testing only)"
fi

ARCH_ARGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_ARGS=('ARCHS=arm64 x86_64' 'ONLY_ACTIVE_ARCH=NO')
  echo "==> Building universal binary (arm64 + x86_64)"
fi

TMPDIR="$ROOT/build/tmp" CLANG_MODULE_CACHE_PATH="$ROOT/build/mcache" \
xcodebuild archive \
  -project "$ROOT/Kaiming.xcodeproj" \
  -scheme Kaiming \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}

APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/Kaiming.app"
if [ ! -d "$APP_IN_ARCHIVE" ]; then
  echo "!! archive does not contain Kaiming.app" >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR"
if [ "$SIGN" = "1" ]; then
  PLIST="$ROOT/build/ExportOptions.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$PLIST"
else
  ditto "$APP_IN_ARCHIVE" "$EXPORT_DIR/Kaiming.app"
fi

APP="$EXPORT_DIR/Kaiming.app"
echo "==> Verifying signature"
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1; then
  echo "!! signature verification failed" >&2
  if [ "$SIGN" = "1" ]; then exit 1; fi
fi

DMG="$ROOT/build/Kaiming-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE" "$DMG"
if [ -d "$APP" ]; then
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Kaiming.app"
  ln -s /Applications "$STAGE/Applications"
  echo "==> Creating $DMG"
  if hdiutil create -volname "Kaiming $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; then
    echo "==> Done: $DMG"
  else
    echo "!! DMG creation failed (sandbox/permissions?). App is at $APP" >&2
  fi
fi

echo "==> App: $APP"
if [ "$SIGN" = "1" ]; then
  echo "==> Next: ./Scripts/notarize.sh \"$APP\""
fi
