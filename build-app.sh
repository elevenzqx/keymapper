#!/bin/bash
# 打包脚本：将编译产物打包成可运行的 KeyMapper.app
set -e

cd "$(dirname "$0")"

APP_NAME="KeyMapper"
BUILD_DIR=".build/release"
BIN="$BUILD_DIR/$APP_NAME"
OUT_APP="dist/$APP_NAME.app"

echo "==> 编译 release 版本..."
swift build -c release

echo "==> 创建 app bundle..."
rm -rf "$OUT_APP"
mkdir -p "$OUT_APP/Contents/MacOS"
mkdir -p "$OUT_APP/Contents/Resources"

cp "$BIN" "$OUT_APP/Contents/MacOS/$APP_NAME"
cp "KeyMapper/Info.plist" "$OUT_APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$OUT_APP/Contents/Resources/AppIcon.icns"

# 生成 PkgInfo
echo -n "APPL????" > "$OUT_APP/Contents/PkgInfo"

# 本地签名（ad-hoc，无需开发者证书）
echo "==> 签名 (ad-hoc)..."
codesign --force --deep --sign - "$OUT_APP"

echo "==> 完成：$OUT_APP"
echo "    双击即可运行，或复制到 /Applications"
