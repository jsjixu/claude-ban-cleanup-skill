#!/usr/bin/env bash
# audit.sh — 只读审计：找出老账号在 Claude Code / wrapper / Codex / Electron agent / 浏览器里的全部残余。
# 输出 Markdown 报告到 stdout（或 --out <file>）。绝不打印密钥值：只有 存在/路径/时间/数量。
set -euo pipefail

OUT=""
MANIFEST_OUT=""
MARKERS=""
SCAN_ROOT="$HOME"
EXTRA_KC=()
EXTRA_PROFILES=()

usage() {
  cat <<'USAGE' >&2
用法: audit.sh [--out <report.md>] [--manifest-out <manifest.json>] [--markers <file>]
              [--scan-root <dir>] [--keychain-service <name>]... [--browser-profile <dir>]...
只读；不修改任何东西。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --manifest-out) MANIFEST_OUT="$2"; shift 2;;
    --markers) MARKERS="$2"; shift 2;;
    --scan-root) SCAN_ROOT="$2"; shift 2;;
    --keychain-service) EXTRA_KC+=("$2"); shift 2;;
    --browser-profile) EXTRA_PROFILES+=("$2"); shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 2;;
  esac
done

AS="$HOME/Library/Application Support"

# 从 .claude.json 取 oauthAccount（值脱敏：前4字符+…），末段是原始 accountUuid（仅供内部比较，不进报告）
oauth_fields() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERROR||||")
    raise SystemExit
o = d.get("oauthAccount") or {}
def m(v):
    return (v[:4] + "…") if isinstance(v, str) and v else "-"
mcps = len(d.get("mcpServers") or {})
mail = o.get("emailAddress") or o.get("email") or ""
pres = lambda k: "存在" if isinstance(d.get(k), str) and d.get(k) else "缺失"
fst = d.get("firstStartTime") or "-"
fsv = d.get("firstStartVersion") or "-"
print("|".join([m(o.get("accountUuid")), m(o.get("organizationUuid")), m(mail), str(mcps),
                pres("userID"), pres("machineID"), str(fst), str(fsv),
                o.get("accountUuid") or ""]))
PY
}

kc_status() { # $1=service → "存在, 修改时间 <mdat>" 或 "不存在"
  local out mdat
  if out=$(security find-generic-password -s "$1" 2>/dev/null); then
    # mdat 行形如 "mdat"<timedate>=0x..  "YYYYMMDDHHMMSSZ\000" —— 只取日期串
    mdat=$(printf '%s\n' "$out" | grep ' "mdat"' | grep -oE '[0-9]{14}Z' | head -1 || true)
    printf '存在, 修改时间 %s' "${mdat:-未知}"
  else
    printf '不存在'
  fi
}

size_of() { { du -sk "$1" 2>/dev/null || echo "0 -"; } | awk '{printf "%.1fMB", $1/1024}'; }

report() {

echo "# Claude 账号残余审计报告"
echo
echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "- 主机家目录: \$HOME"
echo

# ---------- 1. ~/.claude.json ----------
echo "## ~/.claude.json"
echo
if [ -f "$HOME/.claude.json" ]; then
  echo "- 存在, $(size_of "$HOME/.claude.json"), mtime $(stat -f '%Sm' "$HOME/.claude.json")"
  res=$(oauth_fields "$HOME/.claude.json")
  IFS='|' read -r mu mo me mc uid mid fst fsv rawuuid <<< "$res"
  MAIN_UUID="$rawuuid"
  echo "- oauthAccount.accountUuid: $mu   organizationUuid: $mo   email: $me"
  echo "- mcpServers 数量: $mc"
  echo "- 设备标识: userID $uid  machineID $mid  firstStartTime $fst  firstStartVersion $fsv"
  [ "$fst" != "-" ] && echo "- 判断: firstStartTime 早于新账号登录时间 ⇒ userID/machineID 诞生于新账号之前，需确认老账号是否曾在此配置下使用；如不确定，建议重置（manifest 类型 json-unset）"
else
  echo "- 不存在"
  MAIN_UUID=""
fi
echo

# ---------- 2. ~/.claude/ ----------
echo "## ~/.claude/ 子目录"
echo
if [ -d "$HOME/.claude" ]; then
  for d in "$HOME/.claude"/*/; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    flag=""
    case "$b" in
      statsig)
        flag="  ⚠️ 建议清理候选"
        printf '%s\t%s\n' "$d" "Claude Code 遥测/实验状态（含老账号 stableID）" >> "$CAND_FILE";;
      telemetry)
        tn=$(find "$d" -maxdepth 1 -name '1p_failed_events.*.json' 2>/dev/null | wc -l | tr -d ' ')
        flag="  ⚠️ 建议清理候选（失败重发队列 $tn 个文件）"
        printf '%s\t%s\n' "$d" "Claude Code 遥测/实验状态（含老账号 stableID）" >> "$CAND_FILE";;
    esac
    echo "- \`$b\`  $(size_of "$d")$flag"
  done
else
  echo "- ~/.claude 不存在"
fi
echo

# ---------- 2b. ~/.claude/backups/ ----------
echo "## ~/.claude/backups/（配置滚动备份）"
echo
BKP="$HOME/.claude/backups"
if [ -d "$BKP" ]; then
  any=0
  for bp in "$BKP"/.claude.json.backup.*; do
    [ -f "$bp" ] || continue
    any=1
    res=$(oauth_fields "$bp")
    IFS='|' read -r mu mo me mc uid mid fst fsv rawuuid <<< "$res"
    if [ -z "$rawuuid" ]; then
      verdict="- 无 oauthAccount"
    elif [ -z "$MAIN_UUID" ]; then
      verdict="（主文件无 accountUuid，不比较）"
    elif [ "$rawuuid" = "$MAIN_UUID" ]; then
      verdict="✅ 同当前账号"
    else
      verdict="⚠️ 与当前账号不同（老账号残余）"
      printf '%s\t%s\n' "$bp" "备份中含非当前账号的 oauthAccount" >> "$CAND_FILE"
    fi
    echo "- $(basename "$bp")  $(stat -f '%Sm' "$bp")  $(size_of "$bp")  acct=$mu uid=$uid mid=$mid  $verdict"
  done
  [ "$any" = 0 ] && echo "- 目录存在但无 .claude.json.backup.*"
else
  echo "- 不存在"
fi
echo

# ---------- 3. ~/.local/bin/claude ----------
echo "## ~/.local/bin/claude 入口"
echo
BIN="$HOME/.local/bin/claude"
if [ -e "$BIN" ] || [ -L "$BIN" ]; then
  echo "- file: $(file -b "$BIN" | head -c 120)"
  resolved=$(readlink -f "$BIN" 2>/dev/null || echo "$BIN")
  echo "- readlink -f: \`$resolved\`"
  case "$resolved" in
    "$HOME/.local/share/claude/versions/"*) echo "- 判定: ✅ 原生软链（官方布局）";;
    *) if file -b "$BIN" | grep -qi 'script'; then
         echo "- 判定: ⚠️ 脚本/包装器（疑似第三方启动器，建议恢复为指向 versions/<ver> 的软链）"
       else
         echo "- 判定: ⚠️ 非标准目标（请人工核对）"
       fi;;
  esac
else
  echo "- 不存在"
fi
echo

# ---------- 4. 钥匙串 ----------
echo "## 钥匙串"
echo
echo "| 服务名 | 状态 |"
echo "|---|---|"
echo "| Claude Code-credentials | $(kc_status "Claude Code-credentials") |"
echo "| claude-code-oauth-token | $(kc_status "claude-code-oauth-token") |"
for s in ${EXTRA_KC[@]+"${EXTRA_KC[@]}"}; do
  echo "| $s | $(kc_status "$s") |"
done
echo
# 非钥匙串环境的明文凭证文件
CRED="$HOME/.claude/.credentials.json"
if [ -f "$CRED" ]; then
  echo "- ~/.claude/.credentials.json: 存在（明文凭证文件，mtime $(stat -f '%Sm' "$CRED")）⚠️ 建议清理候选"
  printf '%s\t%s\n' "$CRED" "明文 OAuth 凭证文件（非钥匙串路径）" >> "$CAND_FILE"
else
  echo "- ~/.claude/.credentials.json: 不存在"
fi
echo

# ---------- 5. shell rc ----------
echo "## shell rc 中的令牌 / alias 注入"
echo
rc_hit=0
for rc in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  [ -f "$rc" ] || continue
  hits=$(grep -nE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|alias claude|claude\(\)' "$rc" 2>/dev/null || true)
  [ -n "$hits" ] || continue
  rc_hit=1
  echo "**$(basename "$rc")**:"
  printf '%s\n' "$hits" | while IFS=: read -r ln rest; do
    var=$(printf '%s\n' "$rest" | grep -oE '(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|alias claude|claude\(\))' | head -1 || true)
    # 被注释的行也标出来
    commented=""; case "$rest" in \#*) commented="（已注释）";; esac
    echo "- 第 $ln 行: \`${var}=***\` $commented"
  done
done
[ "$rc_hit" = 0 ] && echo "- 未发现"
echo

# ---------- 6. wrapper / Application Support 下的 .claude.json ----------
echo "## Application Support 下的 .claude.json（wrapper 工作区）"
echo
declare -a CJ_FILES=()
while IFS= read -r f; do CJ_FILES+=("$f"); done < <(find "$AS" -maxdepth 6 -name ".claude.json" -type f 2>/dev/null | sort)
if [ ${#CJ_FILES[@]} -eq 0 ]; then
  echo "- 未发现"
else
  for f in "${CJ_FILES[@]}"; do
    res=$(oauth_fields "$f")
    IFS='|' read -r mu mo me mc uid mid fst fsv rawuuid <<< "$res"
    rel="${f#$HOME/}"
    echo "- \`$rel\`"
    echo "    accountUuid=$mu org=$mo email=$me mcp=$mc uid=$uid mid=$mid firstStartTime=$fst"
    # 与主 .claude.json 的 accountUuid 不同 → 记录为"账号不同"候选（内部判断）
    if [ -n "$rawuuid" ] && [ "$rawuuid" != "$MAIN_UUID" ]; then
      echo "    ⚠️ 与 ~/.claude.json 的 accountUuid 不同（疑似老账号残余）"
      printf '%s\t%s\n' "$f" "wrapper 工作区账号不同" >> "$CAND_FILE"
    fi
  done
fi
echo

# ---------- 7. Claude Desktop ----------
echo "## Claude Desktop"
echo
DESKTOP_PATHS=(
  "$AS/Claude"
  "$HOME/Library/Caches/com.anthropic.claudefordesktop"
  "$HOME/Library/Preferences/com.anthropic.claudefordesktop.plist"
  "$HOME/Library/HTTPStorages/com.anthropic.claudefordesktop"
)
for p in "${DESKTOP_PATHS[@]}"; do
  if [ -e "$p" ]; then
    echo "- 存在: \`${p#$HOME/}\`  $(size_of "$p")"
    printf '%s\t%s\n' "$p" "Claude Desktop 残余" >> "$CAND_FILE"
  else
    echo "- 不存在: \`${p#$HOME/}\`"
  fi
done
echo

# ---------- 8. Codex ----------
echo "## Codex (~/.codex)"
echo
if [ -d "$HOME/.codex" ]; then
  if [ -d "$HOME/.codex/sessions" ]; then
    n=$(find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    echo "- sessions: $n 个 jsonl, $(size_of "$HOME/.codex/sessions")"
    printf '%s\t%s\n' "$HOME/.codex/sessions" "Codex 会话日志（可能含老账号标记）" >> "$CAND_FILE"
  fi
  shopt -s nullglob
  for s in "$HOME/.codex"/*.sqlite*; do
    [ -e "$s" ] || continue
    pids=$(lsof -t -- "$s" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || true)
    echo "- \`$(basename "$s")\` $(size_of "$s") mtime $(stat -f '%Sm' "$s") 占用进程: ${pids:-无}"
    printf '%s\t%s\n' "$s" "Codex sqlite（含会话索引，可能含老账号标记）" >> "$CAND_FILE"
  done
  shopt -u nullglob
else
  echo "- ~/.codex 不存在"
fi
echo

# ---------- 9. Electron partitions ----------
echo "## Electron 应用内嵌浏览器 partitions"
echo
while IFS= read -r d; do
  cflag=""
  [ -f "$d/Cookies" ] && { cflag="  ⚠️ 含 Cookies"; printf '%s\t%s\n' "$d" "内嵌浏览器 partition（含 Cookies）" >> "$CAND_FILE"; }
  echo "- \`${d#$HOME/Library/Application Support/}\`  $(size_of "$d")$cflag"
done < <(find "$AS" -maxdepth 4 -type d -path '*/Partitions/*' -prune 2>/dev/null | sort)
echo

# ---------- 10. 浏览器 Cookies ----------
echo "## 浏览器 Cookies 中的 claude.ai / anthropic.com 命中数"
echo
declare -a PROF_DIRS=()
for base in "$AS/Google/Chrome" "$AS/Microsoft Edge" "$AS/BraveSoftware/Brave-Browser"; do
  for prof in "$base/Default" "$base"/Profile\ *; do
    [ -d "$prof" ] && PROF_DIRS+=("$prof")
  done
done
for prof in ${EXTRA_PROFILES[@]+"${EXTRA_PROFILES[@]}"}; do PROF_DIRS+=("$prof"); done
if [ ${#PROF_DIRS[@]} -eq 0 ]; then
  echo "- 未发现浏览器资料目录"
else
  tmpd=$(mktemp -d)
  for prof in "${PROF_DIRS[@]}"; do
    ck="$prof/Cookies"
    if [ -f "$ck" ]; then
      # 锁库不可读 → 复制到 $TMPDIR 再查（含 wal/shm，计数更准）；脚本退出时 trap 删除
      sub="$tmpd/$(echo "$prof" | tr '/ ' '__')"
      mkdir -p "$sub"
      cp -p "$ck" "$sub/Cookies" 2>/dev/null
      cp -p "$ck-wal" "$sub/Cookies-wal" 2>/dev/null || true
      cp -p "$ck-shm" "$sub/Cookies-shm" 2>/dev/null || true
      cnt=$(sqlite3 "$sub/Cookies" "SELECT count(*) FROM cookies WHERE host_key LIKE '%claude.ai%' OR host_key LIKE '%anthropic.com%';" 2>/dev/null || echo "查询失败")
      echo "- \`${prof#$HOME/Library/Application Support/}\`: $cnt 条"
    else
      echo "- \`${prof#$HOME/Library/Application Support/}\`: 无 Cookies 文件"
    fi
  done
fi
echo

# ---------- 11. 老账号标记扫描 ----------
if [ -n "$MARKERS" ]; then
  echo "## 老账号标记全盘文本扫描"
  echo
  echo "- 扫描根: \`$SCAN_ROOT\`"
  EXCL=(Library/Caches node_modules .git .Trash Library/Developer .cache .npm .cargo go .rustup ClaudeBackups)
  gargs=()
  for e in "${EXCL[@]}"; do gargs+=(--exclude-dir="$e"); done
  mlist=()
  while IFS= read -r line; do
    case "$line" in *[![:space:]]*) ;; *) continue;; esac   # 跳过空行
    case "$line" in \#*) continue;; esac                    # 跳过注释
    mlist+=("$line")
  done < "$MARKERS"
  echo "- 标记数: ${#mlist[@]}（值不显示，以下用 #序号 指代）"
  echo
  if [ ${#mlist[@]} -gt 0 ]; then
    tmpf=$(mktemp)
    i=0
    for m in "${mlist[@]}"; do
      i=$((i+1))
      printf '  扫描标记 %d/%d …\r' "$i" "${#mlist[@]}" >&2
      { grep -rIlF "${gargs[@]}" -e "$m" "$SCAN_ROOT" 2>/dev/null || true; } | while IFS= read -r hit; do
        c=$(grep -c -F -e "$m" "$hit" 2>/dev/null || echo 0)
        printf '%s\t%s\t%s\n' "$hit" "$c" "#$i" >> "$tmpf"
      done
    done
    printf '\n' >&2
    if [ -s "$tmpf" ]; then
      echo "| 文件 | 命中行数 | 标记 |"
      echo "|---|---|---|"
      sort -u "$tmpf" | awk -F'\t' '{c[$1]+=$2; a[$1]=a[$1]" "$3} END{for(k in a) printf "%s\t%d\t%s\n", k, c[k], a[k]}' | sort | \
      while IFS=$'\t' read -r f c mk; do
        echo "| \`$f\` | $c |$mk |"
      done
    else
      echo "✅ 0 命中"
    fi
  fi
  echo
fi

# ---------- 12. manifest 草稿 ----------
echo "## 建议的清理 manifest 草稿"
echo
echo "（全部为 confirmed:false —— 逐项确认后再交给 cleanup.sh）"
echo
[ -s "$CAND_FILE" ] || echo "（无路径候选，仅 json-unset 草稿）"
MJSON=$(python3 - "$CAND_FILE" <<'PY'
import json, sys
items = []
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line: continue
    p, _, note = line.partition("\t")
    items.append({"type": "path", "path": p, "confirmed": False, "note": note})
items.append({"type": "json-unset", "file": "~/.claude.json",
              "keys": ["userID", "machineID"], "confirmed": False,
              "note": "重置设备标识（仅当老账号可能用过这份配置时确认；下次启动自动生成新值）"})
print(json.dumps({"items": items}, ensure_ascii=False, indent=2))
PY
)
echo '```json'; echo "$MJSON"; echo '```'
if [ -n "$MANIFEST_OUT" ]; then
  printf '%s\n' "$MJSON" > "$MANIFEST_OUT"
  echo
  echo "已写入: \`$MANIFEST_OUT\`"
fi
}

CAND_FILE=$(mktemp); tmpd=""; tmpf=""
# 只允许删自己造的临时文件（cookie DB 副本、中间文件）——用户数据永远走 mv 不走 rm
trap 'rm -rf "$tmpd" "$tmpf" "$CAND_FILE" 2>/dev/null || true' EXIT

if [ -n "$OUT" ]; then
  report > "$OUT"
  echo "报告已写入 $OUT" >&2
else
  report
fi
