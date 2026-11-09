#!/usr/bin/env bash
# Build Debug and launch Kaiming, replacing any previous instance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/build.sh" Debug

APP="$ROOT/build/dd/Build/Products/Debug/Kaiming.app"

pkill -f "$APP/Contents/MacOS/Kaiming" 2>/dev/null || true
sleep 0.3

echo "==> Launching $APP"
open "$APP"

sleep 1
if pgrep -f "$APP/Contents/MacOS/Kaiming" >/dev/null; then
  echo "==> Kaiming is running. Menu bar icon should be visible."
else
  echo "!! Kaiming did not start; check Console.app / 'log show --process Kaiming'" >&2
  exit 1
fi
