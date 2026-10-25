#!/usr/bin/env bash
# build.sh — 编译并打包 Claude Link Router.app。
#   ./build.sh            只构建到 ./out/Claude Link Router.app 并做基本校验
#   ./build.sh --install  构建 + 装到 ~/Applications/ 并 lsregister
#   ./build.sh --set-default  （配合 --install 或已安装时）触发系统默认浏览器确认框——须用户亲点
#   ./build.sh --icon <file.icns|png>  给 .app 配图标（png 用 sips+iconutil 转 icns）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Link Router"
OUT_DIR="$DIR/out"
ICON=""
DO_INSTALL=0
DO_DEFAULT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install) DO_INSTALL=1; shift;;
    --set-default) DO_DEFAULT=1; shift;;
    --icon) ICON="$2"; shift 2;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

APP="$OUT_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/4] 编译 main.swift"
swiftc -O "$DIR/main.swift" -o "$APP/Contents/MacOS/ClaudeLinkRouter" -framework AppKit
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null && echo "     Info.plist OK"

echo "[2/4] 图标"
if [ -n "$ICON" ]; then
  case "$ICON" in
    *.icns) cp "$ICON" "$APP/Contents/Resources/AppIcon.icns";;
    *.png)
      iset=$(mktemp -d)/a.iconset; mkdir -p "$iset"
      for pair in "16x16:16" "16x16@2x:32" "32x32:32" "32x32@2x:64" "128x128:128" "128x128@2x:256" "256x256:256" "256x256@2x:512" "512x512:512" "512x512@2x:1024"; do
        name="${pair%%:*}"; px="${pair##*:}"
        sips -z "$px" "$px" "$ICON" --out "$iset/icon_${name}.png" >/dev/null
      done
      iconutil -c icns "$iset" -o "$APP/Contents/Resources/AppIcon.icns"
      rm -rf "$(dirname "$iset")";;  # 自己 mktemp 出来的 iconset，删
    *) echo "图标需 .icns 或 .png: $ICON" >&2; exit 1;;
  esac
  echo "     AppIcon.icns 已写入"
else
  [ -f "$APP/Contents/Resources/AppIcon.icns" ] && mv "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns.bak"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "     未提供 --icon，无图标"
fi

echo "[3/4] 签名"
codesign --force --deep --sign - "$APP"
codesign -v "$APP" && echo "     ad-hoc 签名 OK"

TARGET="$HOME/Applications/$APP_NAME.app"
if [ "$DO_INSTALL" = 1 ]; then
  echo "[4/4] 安装到 $TARGET"
  mkdir -p "$HOME/Applications"
  # 覆盖安装：旧副本不删，挪成 .bak-<ts>（本脚本不 rm 任何东西）
  [ -d "$TARGET" ] && mv "$TARGET" "$TARGET.bak-$(date '+%Y%m%d-%H%M%S')"
  mv "$APP" "$TARGET"
  APP="$TARGET"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
  echo "     已注册到 LaunchServices"
else
  echo "[4/4] 未加 --install：产物在 $APP"
fi

if [ "$DO_DEFAULT" = 1 ]; then
  [ -d "$APP" ] || { echo "--set-default 需要先 --install" >&2; exit 1; }
  echo "触发系统默认浏览器确认框——请在弹出的 macOS 对话框里点确认"
  open -a "$APP" --args --set-default
fi

echo "完成。"
