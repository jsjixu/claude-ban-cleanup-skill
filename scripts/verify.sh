#!/usr/bin/env bash
# verify.sh — 一致性核查（SKILL.md §6）。只读，每项打印 PASS/WARN/INFO/FAIL。
set -euo pipefail

PORT=62919
BROWSER_APP=""
CLAUDE_DIR="$HOME/.local/share/claude/versions"
LAUNCHER="$HOME/.local/bin/claude-browser"
CHECK_EXIT=0
declare -a OLD_KC=()

usage() {
  cat <<'USAGE' >&2
用法: verify.sh [--port 62919] [--browser-app <path>] [--launcher <path>]
               [--claude-dir <dir>] [--old-keychain-service <name>]... [--check-exit]
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --browser-app) BROWSER_APP="$2"; shift 2;;
    --launcher) LAUNCHER="$2"; shift 2;;
    --claude-dir) CLAUDE_DIR="$2"; shift 2;;
    --check-exit) CHECK_EXIT=1; shift;;
    --old-keychain-service) OLD_KC+=("$2"); shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 2;;
  esac
done

say() { printf '%-4s %s\n' "$1" "$2"; }

echo "== 一致性核查 $(date '+%Y-%m-%d %H:%M:%S') =="

# ---- 时区 ----
tz_link=$(readlink /etc/localtime 2>/dev/null || echo "?")
say INFO "系统时区: $tz_link ($(date +%Z) $(date '+%Y-%m-%d %H:%M %z'))  —— 应与固定出口 IP 所在时区一致"

# ---- 自动时区 ----
at_line=$(log show --last 1d --predicate 'process == "timed"' --style compact 2>/dev/null \
          | grep -o 'TMAutomaticTimeZoneEnabled",v,"[01]"' | tail -1 || true)
case "$at_line" in
  *'"0"') say PASS "自动时区已关闭（timed: ${at_line}）";;
  *'"1"') say WARN "自动时区仍开启（timed: ${at_line}）——时区会随真实位置漂移";;
  *)      say INFO "近 24h 无 timed 日志，无法判定自动时区（INFO，不等于开启）";;
esac
say INFO "注: /Library/Preferences/com.apple.timezone.auto.plist 是旧版遗留键，不作数"

# ---- settings.json env ----
SJ="$HOME/.claude/settings.json"
if [ -f "$SJ" ]; then
  eval "$(python3 - "$SJ" "$PORT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); port = sys.argv[2]
e = d.get("env") or {}
def ok(v): return "1" if v == f"http://127.0.0.1:{port}" else "0"
def q(v): return "'" + str(v).replace("'", "'\\''") + "'"
print("HP=" + ok(e.get("HTTPS_PROXY")))
print("HPV=" + q(e.get("HTTPS_PROXY", "-")))
print("H_P=" + ok(e.get("HTTP_PROXY")))
print("B=" + q(e.get("BROWSER", "-")))
PY
)"
  [ "${HP:-0}" = 1 ] && say PASS "settings.json HTTPS_PROXY -> 127.0.0.1:$PORT" || say FAIL "settings.json HTTPS_PROXY=${HPV:--}（期望 http://127.0.0.1:$PORT）"
  [ "${H_P:-0}" = 1 ] && say PASS "settings.json HTTP_PROXY -> 127.0.0.1:$PORT" || say FAIL "settings.json HTTP_PROXY 缺失或不是 127.0.0.1:$PORT"
  if [ "${B:--}" != "-" ] && [ -x "$B" ]; then
    say PASS "settings.json BROWSER 指向可执行文件 ($B)"
  elif [ "${B:--}" != "-" ]; then
    say WARN "settings.json BROWSER=$B 存在但不可执行"
  else
    say WARN "settings.json 未设 BROWSER（OAuth/artifact 链接不会进专用浏览器）"
  fi
else
  say WARN "$SJ 不存在"
fi

# ---- claude 入口 ----
BIN="$HOME/.local/bin/claude"
if [ -L "$BIN" ]; then
  resolved=$(readlink -f "$BIN")
  case "$resolved" in
    "$CLAUDE_DIR/"*) say PASS "claude 入口是原生软链 -> $resolved";;
    *) say WARN "claude 入口软链指向非标准目标: $resolved";;
  esac
elif [ -e "$BIN" ]; then
  say WARN "claude 入口不是软链（$(file -b "$BIN" | head -c 60)）——疑似 wrapper"
else
  say FAIL "claude 入口不存在: $BIN"
fi

# ---- 钥匙串 ----
if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  say PASS "钥匙串 Claude Code-credentials 存在（新 OAuth 凭据已就位）"
else
  say WARN "钥匙串 Claude Code-credentials 不存在（尚未 /login？）"
fi
kc_old=0
for s in "claude-code-oauth-token" ${OLD_KC[@]+"${OLD_KC[@]}"}; do
  if security find-generic-password -s "$s" >/dev/null 2>&1; then
    say WARN "老长效令牌仍存在: service=$s"; kc_old=1
  fi
done
[ "$kc_old" = 0 ] && say PASS "老长效令牌服务名均不存在"

# ---- surge-cli ----
SCLI="$(command -v surge-cli 2>/dev/null || true)"
[ -z "$SCLI" ] && [ -x "/Applications/Surge.app/Contents/Applications/surge-cli" ] && SCLI="/Applications/Surge.app/Contents/Applications/surge-cli"
if [ -n "$SCLI" ]; then
  for u in https://claude.ai/ https://anthropic.auth0.com/ https://api.anthropic.com/; do
    say INFO "rule match $u -> $("$SCLI" rule match "$u" 2>&1 | tail -1)"
  done
  say INFO "surge profile: $("$SCLI" profile current 2>&1 | tail -1 || echo '查询失败')"
else
  say INFO "surge-cli 不在 PATH，跳过规则核查"
fi

# ---- 出口 IP 对比 ----
if [ "$CHECK_EXIT" = 1 ]; then
  pip=$(curl -s -m 10 -x "http://127.0.0.1:$PORT" https://api.ipify.org || true)
  dip=$(curl -s -m 10 https://api.ipify.org || true)
  if [ -n "$pip" ] && [ -n "$dip" ] && [ "$pip" != "$dip" ]; then
    say PASS "出口对比: 代理=${pip} 直连=${dip}（不同 ✓）"
  elif [ -z "$pip" ]; then
    say FAIL "经 127.0.0.1:${PORT} 的代理出口无响应（直连=${dip}）"
  else
    say WARN "出口对比: 代理=${pip} 直连=${dip}"
  fi
fi

# ---- 专用浏览器 ----
if [ -n "$BROWSER_APP" ]; then
  if [ -d "$BROWSER_APP" ]; then
    say PASS "专用浏览器存在: $BROWSER_APP"
    team=$(codesign -dv "$BROWSER_APP" 2>&1 | grep TeamIdentifier | head -1)
    say INFO "签名 ${team:-（无 TeamIdentifier——可能是 ad-hoc）}"
  else
    say FAIL "专用浏览器不存在: $BROWSER_APP"
  fi
  if [ -f "$LAUNCHER" ]; then
    missing=""
    # 值可能被引号包住（--proxy-server="http://..."），按正则匹配允许可选引号
    # 同时接受字面端口与启动器脚本里的 $CLAUDE_PROXY_PORT 变量形式
    grep -qE -- "--proxy-server=\"?http://127\.0\.0\.1:(\\\$\{?CLAUDE_PROXY_PORT\}?|$PORT)" "$LAUNCHER" || missing="$missing --proxy-server=127.0.0.1:$PORT"
    grep -qE -- "--accept-lang=\"?en-US" "$LAUNCHER" || missing="$missing --accept-lang=en-US"
    grep -qF -- "--force-webrtc-ip-handling-policy=disable_non_proxied_udp" "$LAUNCHER" || missing="$missing --force-webrtc-ip-handling-policy=disable_non_proxied_udp"
    grep -qF -- "--disable-quic" "$LAUNCHER" || missing="$missing --disable-quic"
    if [ -z "$missing" ]; then
      say PASS "launcher $LAUNCHER 四个关键参数齐全"
    else
      say WARN "launcher $LAUNCHER 缺少:$missing"
    fi
  else
    say WARN "launcher 不存在: $LAUNCHER"
  fi
fi

echo "== 核查结束（INFO 为参考信息；WARN/FAIL 需处理）=="
