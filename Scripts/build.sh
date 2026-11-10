#!/usr/bin/env bash
# Kaiming — local Debug/Release build helper.
# Usage: ./Scripts/build.sh [Debug|Release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Debug}"
DERIVED="$ROOT/build/dd"
mkdir -p "$ROOT/build/tmp" "$ROOT/build/mcache"

# 本地 ad-hoc 构建关闭 Hardened Runtime：ad-hoc 签名下 app 与内嵌 framework 的
# Team ID 不一致会触发 dyld 库验证失败。正式分发请用 Scripts/archive.sh --sign，
# 由 Developer ID 统一重签（Hardened Runtime 保持开启）。
LOCAL_SIGN_ARGS=()
if [ "$CONFIG" = "Release" ]; then
  LOCAL_SIGN_ARGS=(ENABLE_HARDENED_RUNTIME=NO)
fi

echo "==> Building Kaiming ($CONFIG)"
TMPDIR="$ROOT/build/tmp" \
CLANG_MODULE_CACHE_PATH="$ROOT/build/mcache" \
xcodebuild \
  -project "$ROOT/Kaiming.xcodeproj" \
  -scheme Kaiming \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  ${LOCAL_SIGN_ARGS[@]+"${LOCAL_SIGN_ARGS[@]}"} \
  build

APP="$DERIVED/Build/Products/$CONFIG/Kaiming.app"
echo
echo "==> Built: $APP"
/usr/bin/codesign -dv "$APP" 2>&1 | sed -n '1,4p' || true

if [ "$CONFIG" = "Debug" ]; then
  echo "==> Run with: ./Scripts/run.sh"
fi
