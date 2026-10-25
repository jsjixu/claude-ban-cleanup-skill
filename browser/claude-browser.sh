#!/bin/sh
# claude-browser — 专用浏览器启动器：一份独立复制的 Chrome + 独立资料目录，
# 全部流量经 Surge 专用口（默认 127.0.0.1:62919，对应固定节点）。
# 三处可改：下面的默认值 / 同名环境变量 / install.sh 生成的本文件副本。
#
# 注意：专用 Chrome 副本与个人 Chrome 的 bundle id 相同，永远按绝对路径 open，绝不按 bundle id。

CLAUDE_BROWSER_APP="${CLAUDE_BROWSER_APP:-$HOME/Applications/Claude Browser Runtime/Claude Chrome.app}"
CLAUDE_BROWSER_PROFILE="${CLAUDE_BROWSER_PROFILE:-$HOME/Library/Application Support/Claude Browser}"
CLAUDE_PROXY_PORT="${CLAUDE_PROXY_PORT:-62919}"

mkdir -p "$CLAUDE_BROWSER_PROFILE"

exec /usr/bin/open -na "$CLAUDE_BROWSER_APP" --args \
  --user-data-dir="$CLAUDE_BROWSER_PROFILE" \
  --proxy-server="http://127.0.0.1:$CLAUDE_PROXY_PORT" \
  --lang=en-US --accept-lang=en-US,en --disable-quic \
  --force-webrtc-ip-handling-policy=disable_non_proxied_udp \
  --no-first-run --no-default-browser-check "$@"
