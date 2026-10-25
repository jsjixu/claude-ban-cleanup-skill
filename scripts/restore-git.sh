#!/usr/bin/env bash
# restore-git.sh — 修复被"隔离/清理"弄坏的仓库：备份 .git → 找回远端历史 →
# index 对齐 origin/<默认分支>，然后停下来把"丢弃或保留工作区改动"的决定留给用户。
# 绝不 checkout / clean / reset --hard：工作区文件一个字节不动。
set -euo pipefail

REPO=""
REMOTE_URL=""
TRASH_ROOT="$HOME/ClaudeBackups"

usage() {
  cat <<'USAGE' >&2
用法: restore-git.sh <repo-dir> [remote-url] [--trash-root <dir>]
症状: git rev-parse HEAD 失败 / 对象库为空 / remote -v 为空
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --trash-root) TRASH_ROOT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "未知参数: $1" >&2; usage; exit 2;;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$REMOTE_URL" ]; then REMOTE_URL="$1"; else echo "多余参数: $1" >&2; exit 2; fi; shift;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { usage; exit 2; }
cd "$REPO"

echo "== 仓库: $REPO"

# ---- 症状诊断 ----
objects=$(git count-objects -v 2>/dev/null | awk '/^count:/{print $2}' || echo "?")
head_ok=0; git rev-parse --verify HEAD >/dev/null 2>&1 && head_ok=1
remotes=$(git remote -v 2>/dev/null | head -4)
echo "HEAD 可解析: $([ $head_ok = 1 ] && echo 是 || echo 否)   本地对象数: $objects"
echo "remote -v: ${remotes:-（空）}"

# ---- 备份 .git ----
ts=$(date '+%Y%m%d-%H%M%S')
BAK="$TRASH_ROOT/git-restore-$ts"
mkdir -p "$BAK"
if [ -d .git ]; then
  tar -czf "$BAK/dotgit-before.tgz" .git && echo "已备份 .git -> $BAK/dotgit-before.tgz"
fi

# ---- 无 .git 则初始化 ----
if [ ! -d .git ]; then
  git init >/dev/null
  echo "git init 完成（工作区未动）"
fi

# ---- remote ----
if [ -n "$REMOTE_URL" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
  else
    git remote add origin "$REMOTE_URL"
  fi
  echo "origin = $REMOTE_URL"
fi
git remote get-url origin >/dev/null 2>&1 || { echo "错误: 无 origin 且未提供 remote-url" >&2; exit 1; }

# ---- 拉历史 ----
export GIT_TERMINAL_PROMPT=0
git fetch origin --prune || { echo "错误: fetch 失败（凭据/网络/仓库名）" >&2; exit 1; }
echo "--- 远端分支 ---"; git branch -r

# ---- 默认分支 ----
DEF=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
if [ -z "$DEF" ]; then
  DEF=$(git remote show origin 2>/dev/null | awk '/HEAD branch/{print $NF}' || true)
fi
DEF=${DEF:-main}
echo "默认分支: $DEF"

# ---- index 对齐（只动 index 和 HEAD，不动工作区）----
git reset --mixed "origin/$DEF" >/dev/null
echo "git reset --mixed origin/$DEF 完成（工作区未动）"
git branch --set-upstream-to="origin/$DEF" 2>/dev/null || true

echo "--- 与远端的差异 ---"
echo "status 条数: $(git status --short | wc -l | tr -d ' ')"
git status --short | head -20
echo "diff --stat 末行: $(git diff --stat "origin/$DEF" | tail -1)"

echo
echo "== 已停在动手之前 =="
echo "- 要把工作区恢复成远端状态:  git checkout -- .   （会覆盖所有已跟踪文件）"
echo "- 要保留当前工作区:          逐文件核对后 commit"
echo "- .git 备份在: $BAK"
