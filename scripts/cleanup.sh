#!/usr/bin/env bash
# cleanup.sh — 按用户确认过的 manifest 逐项清理。
# 原则：confirmed != true 一律跳过；写操作只有 mv 到带时间戳的废纸篓 + 钥匙串删除 + rc 注释；
#       绝不 rm；路径命中保护白名单直接拒绝；被进程占用则跳过并报告 PID。
set -euo pipefail

MANIFEST=""
TASK="claude-cleanup"
TRASH_ROOT="$HOME/ClaudeBackups"
DRY_RUN=0
declare -a PROTECTS=()

usage() {
  cat <<'USAGE' >&2
用法: cleanup.sh <manifest.json> [--task <name>] [--trash-root <dir>] [--protect <dir>]... [--dry-run]
manifest 项类型: path / keychain / rc-comment / json-unset（见 SKILL.md §2）
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="$2"; shift 2;;
    --trash-root) TRASH_ROOT="$2"; shift 2;;
    --protect) PROTECTS+=("$2"); shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "未知参数: $1" >&2; usage; exit 2;;
    *) [ -z "$MANIFEST" ] && MANIFEST="$1" || { echo "多余参数: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$MANIFEST" ] || { usage; exit 2; }
[ -f "$MANIFEST" ] || { echo "manifest 不存在: $MANIFEST" >&2; exit 2; }

export CBC_MANIFEST="$MANIFEST" CBC_TASK="$TASK" CBC_TRASH_ROOT="$TRASH_ROOT" CBC_DRY_RUN="$DRY_RUN"
export CBC_PROTECTS="$(printf '%s\n' "${PROTECTS[@]+"${PROTECTS[@]}"}")"

python3 <<'PY'
import datetime, json, os, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
MANIFEST = os.environ["CBC_MANIFEST"]
TASK = os.environ["CBC_TASK"]
TRASH_ROOT = os.path.expanduser(os.environ["CBC_TRASH_ROOT"])
DRY_RUN = os.environ["CBC_DRY_RUN"] == "1"
PROTECTS = [os.path.realpath(os.path.expanduser(p)) for p in os.environ.get("CBC_PROTECTS", "").splitlines() if p.strip()]

# 路径子串命中即视为受保护（settings 前缀同时覆盖 settings.json / settings.local.json）
PROTECT_SUBSTR = ("/.claude/projects", "/.claude/skills", "/.claude/plugins",
                  "/.claude/hooks", "/.claude/commands", "/.claude/agents",
                  "/.claude/settings", "/.git/")

def is_protected(path):
    rp = os.path.realpath(path)
    for s in PROTECT_SUBSTR:
        if s in rp or rp.rstrip("/").endswith(s):
            return f"白名单 {s}"
    for p in PROTECTS:
        if rp == p or rp.startswith(p + os.sep):
            return f"--protect {p}"
    return None

def lsof_pids(path, timeout=20):
    """返回占用该路径的 PID 列表。目录用 lsof +D（加超时）。"""
    if os.path.isdir(path):
        cmd = ["lsof", "-Fp", "+D", path]
    else:
        cmd = ["lsof", "-t", "--", path]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ["<lsof 超时>"]
    pids = set()
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("p") and line[1:].isdigit():   # -Fp 输出
            pids.add(line[1:])
        elif line.isdigit():                            # -t 输出
            pids.add(line)
    return sorted(pids)

def rel_dest(trash, path):
    rp = os.path.abspath(path)
    if rp.startswith(HOME + os.sep):
        rel = rp[len(HOME) + 1:]
    else:
        rel = "outside-home" + rp
    return os.path.join(trash, rel)

ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
trash = os.path.join(TRASH_ROOT, f"{TASK}-{ts}")
moved, busy, unconfirmed, refused, kc_deleted, absent, errors = [], [], [], [], [], [], []

items = json.load(open(MANIFEST)).get("items", [])
print(f"task={TASK} trash={trash} dry_run={DRY_RUN} items={len(items)}")

if not DRY_RUN:
    os.makedirs(trash, exist_ok=True)

for it in items:
    t = it.get("type")
    if it.get("confirmed") is not True:
        unconfirmed.append(it)
        print(f"[未确认，跳过] {t}: {it.get('path') or it.get('service') or it.get('file')}")
        continue

    if t == "path":
        p = os.path.expanduser(it["path"])
        why = is_protected(p)
        if why:
            refused.append(p); print(f"[拒绝: 受保护({why})] {p}"); continue
        if not os.path.lexists(p):
            absent.append(p); print(f"[不存在] {p}"); continue
        pids = lsof_pids(p)
        if pids:
            busy.append((p, pids)); print(f"[跳过: 被占用 pid {','.join(pids)}] {p}"); continue
        dest = rel_dest(trash, p)
        if DRY_RUN:
            print(f"[计划 mv] {p} -> {dest}")
        else:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.move(p, dest)
            print(f"[已移动] {p} -> {dest}")
        moved.append(p)

    elif t == "keychain":
        svc, acct, req = it.get("service"), it.get("account"), it.get("require_service")
        if req:
            r = subprocess.run(["security", "find-generic-password", "-s", req],
                               capture_output=True)
            if r.returncode != 0:
                refused.append(f"keychain:{svc}")
                print(f"[中止该项: 新凭据服务 {req} 不存在] {svc}")
                continue
        if DRY_RUN:
            print(f"[计划删除钥匙串] service={svc} account={acct or '-'}")
        else:
            cmd = ["security", "delete-generic-password", "-s", svc]
            if acct:
                cmd += ["-a", acct]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode == 0:
                kc_deleted.append(svc)
                print(f"[钥匙串已删] service={svc} account={acct or '-'}")
            else:
                errors.append(svc)
                print(f"[钥匙串删除失败 rc={r.returncode}] service={svc}")

    elif t == "rc-comment":
        f = os.path.expanduser(it["file"])
        pat = it.get("pattern", "")
        if not os.path.isfile(f):
            absent.append(f); print(f"[不存在] {f}"); continue
        tag = f"# [claude-ban-cleanup {datetime.date.today().isoformat()}] "
        bak = rel_dest(trash, f)
        if DRY_RUN:
            print(f"[计划注释] {f} 含 {pat!r} 的行（先备份到 {bak}）")
        else:
            os.makedirs(os.path.dirname(bak), exist_ok=True)
            shutil.copy2(f, bak)
            lines = open(f, encoding="utf-8", errors="surrogateescape").read().splitlines(True)
            out = []
            for ln in lines:
                if pat in ln and not ln.lstrip().startswith(tag.rstrip()):
                    out.append(tag + ln)
                else:
                    out.append(ln)
            open(f, "w", encoding="utf-8", errors="surrogateescape").writelines(out)
            # 语法校验：zsh 系用 zsh -n，其它用 bash -n
            shell = "zsh" if os.path.basename(f).startswith(".z") or "zsh" in f else "bash"
            r = subprocess.run([shell, "-n", f], capture_output=True, text=True)
            if r.returncode != 0:
                errors.append(f); print(f"[警告: 语法校验失败，请人工核对] {f}: {r.stderr.strip()[:200]}")
            else:
                print(f"[已注释并校验] {f}（备份 {bak}）")
        moved.append(f)

    elif t == "json-unset":
        f = os.path.expanduser(it["file"])
        keys = it.get("keys") or []
        why = is_protected(f)
        if why:
            refused.append(f); print(f"[拒绝: 受保护({why})] {f}"); continue
        if not os.path.isfile(f):
            refused.append(f); print(f"[拒绝: 不是常规文件] {f}"); continue
        # Claude Code 不常驻持有该文件，lsof 查不到——必须用进程名兜底
        run_pids = set()
        for pat, flag in (("claude", "-x"), ("/.local/share/claude/versions/", "-f")):
            r = subprocess.run(["pgrep", flag, pat], capture_output=True, text=True)
            run_pids.update(p for p in r.stdout.split() if p.isdigit())
        run_pids.discard(str(os.getpid()))
        if run_pids:
            pl = sorted(run_pids)
            busy.append((f, pl))
            print(f"[跳过: Claude Code 正在运行 pid {','.join(pl)}（请先退出）] {f}"); continue
        pids = lsof_pids(f)
        if pids:
            busy.append((f, pids)); print(f"[跳过: 被占用 pid {','.join(pids)}（请先退出 Claude Code）] {f}"); continue
        bak = rel_dest(trash, f)
        if DRY_RUN:
            print(f"[计划 json-unset] {f} keys={keys}（先备份到 {bak}）")
        else:
            os.makedirs(os.path.dirname(bak), exist_ok=True)
            shutil.copy2(f, bak)
            d = json.load(open(f, encoding="utf-8"))
            present = [k for k in keys if k in d]
            for k in present:
                del d[k]
            tmp = f + ".cbc-tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(d, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            shutil.copymode(f, tmp)
            os.replace(tmp, f)
            print(f"[json-unset] {f} 已删键 {present or '（无命中）'} 缺失键 {[k for k in keys if k not in present]}（备份 {bak}）")
        moved.append(f)

    else:
        errors.append(str(t)); print(f"[未知类型] {t}")

print()
print("===== 汇总 =====")
print(f"已移动/处理: {len(moved)}")
print(f"跳过(被占用): {len(busy)}" + (" -> " + "; ".join(f"{p} pids={q}" for p, q in busy) if busy else ""))
print(f"跳过(未确认): {len(unconfirmed)}")
print(f"拒绝(受保护): {len(refused)}")
print(f"钥匙串删除: {len(kc_deleted)}")
print(f"不存在: {len(absent)}")
print(f"错误/未知: {len(errors)}")
print(f"废纸篓: {trash}")
PY
