#!/usr/bin/env bash
# Install the `kaiming` CLI shim.
# Usage: ./Scripts/install-cli.sh [destination]
# Default destination: /usr/local/bin/kaiming (may require sudo).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-/usr/local/bin/kaiming}"
DIR="$(dirname "$DEST")"

if [ ! -d "$DIR" ]; then
  echo "==> Creating $DIR"
  mkdir -p "$DIR"
fi

if [ ! -w "$DIR" ]; then
  echo "!! $DIR 不可写；请改用： sudo $0 \"$DEST\"" >&2
  exit 1
fi

ln -sf "$ROOT/Scripts/kaiming" "$DEST"
echo "==> Installed: $DEST -> $ROOT/Scripts/kaiming"
echo "==> Try: kaiming ./docs"
