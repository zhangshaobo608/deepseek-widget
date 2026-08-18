#!/bin/bash
# 构建 DeepSeek 浮窗 .app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DeepSeek浮窗"
BIN="DeepSeekWidget"
BUILD="build"

mkdir -p "$BUILD"

echo "==> 编译 main.swift"
mkdir -p "$BUILD/tmp" "$BUILD/ModuleCache"
TMPDIR="$PWD/$BUILD/tmp" swiftc -swift-version 5 -O \
    -module-cache-path "$BUILD/ModuleCache" \
    -framework AppKit \
    Sources/main.swift \
    -o "$BUILD/$BIN"

echo "==> 打包 $APP_NAME.app"
rm -rf "$BUILD/$APP_NAME.app"
mkdir -p "$BUILD/$APP_NAME.app/Contents/MacOS"
cp "$BUILD/$BIN" "$BUILD/$APP_NAME.app/Contents/MacOS/$BIN"
cp Info.plist "$BUILD/$APP_NAME.app/Contents/Info.plist"
codesign --force -s - "$BUILD/$APP_NAME.app" 2>/dev/null || true

echo "==> 完成: $PWD/$BUILD/$APP_NAME.app"
echo "    运行: open \"$PWD/$BUILD/$APP_NAME.app\""
