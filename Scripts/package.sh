#!/usr/bin/env bash
# 把已归档的 Kaiming.app 打包为可分发的 ZIP + DMG + SHA256SUMS。
# Usage: ./Scripts/package.sh [app-path] [output-dir]
# Defaults: build/export/Kaiming.app, build/dist
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/export/Kaiming.app}"
OUT="${2:-$ROOT/build/dist}"

if [ ! -d "$APP" ]; then
  echo "!! app not found: $APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VERSION="${VERSION:-1.1.0}"
mkdir -p "$OUT"

ZIP="$OUT/Kaiming-$VERSION.zip"
DMG="$OUT/Kaiming-$VERSION.dmg"
rm -f "$ZIP" "$DMG" "$OUT/SHA256SUMS.txt"

echo "==> Creating $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ "${SKIP_DMG:-0}" = "1" ]; then
  echo "==> Skipping DMG (SKIP_DMG=1)"
else
  echo "==> Creating $DMG"
  STAGE="$ROOT/build/dmg-stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Kaiming.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create \
    -volname "Kaiming $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
fi

echo "==> Checksums"
(
  cd "$OUT"
  FILES=("$(basename "$ZIP")")
  if [ -f "$DMG" ]; then FILES+=("$(basename "$DMG")"); fi
  shasum -a 256 "${FILES[@]}" > SHA256SUMS.txt
  cat SHA256SUMS.txt
)

echo "==> Package: $OUT"
ls -lh "$OUT"
