#!/usr/bin/env bash
# install.sh — 装出专用浏览器三件套：
#   1) Chrome.app 的独立副本（$CLAUDE_BROWSER_APP）
#   2) ~/.local/bin/claude-browser 启动器
#   3) ~/Applications/Claude Browser.app 的 Dock 入口（50 字节壳，exec 启动器）
# 幂等；--dry-run 只打印计划。绝不改 /Applications/Google Chrome.app 本体。
set -euo pipefail

CHROME_SRC="${CHROME_SRC:-/Applications/Google Chrome.app}"
APP_DIR="${CLAUDE_BROWSER_APP:-$HOME/Applications/Claude Browser Runtime/Claude Chrome.app}"
LAUNCHER_DST="${LAUNCHER_DST:-$HOME/.local/bin/claude-browser}"
DOCK_APP="${DOCK_APP:-$HOME/Applications/Claude Browser.app}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

act() { if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] $*"; else eval "$@"; fi; }

[ -d "$CHROME_SRC" ] || { echo "源 Chrome 不存在: $CHROME_SRC" >&2; exit 1; }

# ---- 1) Chrome 副本 ----
if [ -d "$APP_DIR" ]; then
  echo "[跳过] 浏览器副本已存在: $APP_DIR"
else
  echo "[动作] 复制 $CHROME_SRC -> $APP_DIR"
  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$(dirname "$APP_DIR")"
    ditto "$CHROME_SRC" "$APP_DIR"   # ditto 保留签名与扩展属性；cp -R 亦可
  else
    echo "[dry-run] mkdir -p $(dirname "$APP_DIR") && ditto <src> <dst>"
  fi
fi

# 防止 Spotlight 索引副本本体（误点会拉起无代理裸 Chrome）
act "touch \"$(dirname "$APP_DIR")/.metadata_never_index\""

# ---- 2) 启动器 ----
if [ -f "$LAUNCHER_DST" ] && cmp -s "$SCRIPT_DIR/claude-browser.sh" "$LAUNCHER_DST"; then
  echo "[跳过] 启动器已是最新: $LAUNCHER_DST"
else
  echo "[动作] 安装启动器 -> $LAUNCHER_DST"
  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$(dirname "$LAUNCHER_DST")"
    cp "$SCRIPT_DIR/claude-browser.sh" "$LAUNCHER_DST"
    chmod 755 "$LAUNCHER_DST"
  else
    echo "[dry-run] cp claude-browser.sh $LAUNCHER_DST && chmod 755"
  fi
fi

# ---- 3) Dock 入口 .app ----
MACOS_DIR="$DOCK_APP/Contents/MacOS"
RES_DIR="$DOCK_APP/Contents/Resources"
if [ -d "$DOCK_APP" ]; then
  echo "[跳过] Dock 入口已存在: $DOCK_APP"
else
  echo "[动作] 创建 Dock 入口: $DOCK_APP"
  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$MACOS_DIR" "$RES_DIR"
    cat > "$DOCK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>local.claude.browser-launcher</string>
	<key>CFBundleName</key>
	<string>Claude Browser</string>
	<key>CFBundleExecutable</key>
	<string>ClaudeBrowserLauncher</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<false/>
</dict>
</plist>
PLIST
    cat > "$MACOS_DIR/ClaudeBrowserLauncher" <<'SH'
#!/bin/sh
exec "$HOME/.local/bin/claude-browser" "$@"
SH
    chmod 755 "$MACOS_DIR/ClaudeBrowserLauncher"
    # 图标直接借 Chrome 副本的
    if [ -f "$APP_DIR/Contents/Resources/app.icns" ]; then
      cp "$APP_DIR/Contents/Resources/app.icns" "$RES_DIR/AppIcon.icns"
    fi
    codesign --force --deep --sign - "$DOCK_APP" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DOCK_APP" 2>/dev/null || true
  else
    echo "[dry-run] 生成 Info.plist + MacOS/ClaudeBrowserLauncher + 图标 + codesign"
  fi
fi

echo
echo "完成检查:"
echo "  $LAUNCHER_DST https://claude.ai/   # 应拉起专用浏览器（隔离资料 + 固定代理）"
echo "  ps 里确认: --user-data-dir 与 --proxy-server 参数都在"
