#!/usr/bin/env python3
# clean.py — 分档清理 Claude Code / Claude Desktop 的本机残余。
# 默认只读审计输出 JSON；--apply 才动手：进程守卫 + SHA-256 校验备份 + 系统废纸篓 + TTY CONFIRM。
# 只限 macOS；绝不打印密钥值（键名、存在性、时间、数量 only）。
import argparse, datetime, hashlib, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

CACHE_PATHS = [
    ".claude/cache", ".claude/stats-cache.json", ".claude/telemetry", ".claude/statsig",
    "Library/Caches/claude-cli-nodejs", "Library/Caches/com.anthropic.claudefordesktop",
    "Library/Caches/com.anthropic.claudefordesktop.ShipIt", "Library/Logs/Claude",
    "Library/HTTPStorages/com.anthropic.claudefordesktop",
]
APP_SUP_CLAUDE_CACHE = [
    "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "GPUPersistentCache", "GraphiteDawnCache", "Crashpad", "sentry",
    "window-state.json", "vm-support-probe.json",
]
CACHE_GLOBS = ["Library/Logs/DiagnosticReports/Claude_*", "Library/Application Support/CrashReporter/Claude_*"]
ACCOUNT_MOVES = [
    ".claude/.credentials.json",
    "Library/Application Support/Claude/config.json.journal",
    "Library/Application Support/Claude/plan-usage-history.json",
]
ACCOUNT_KEYS = ["oauthAccount", "accountUuid", "oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
ACCOUNT_EDIT_FILES = [".claude.json", "Library/Application Support/Claude/config.json"]
ACCOUNT_EDIT_GLOB = ".claude/backups/.claude.json.backup.*"
DEVICE_MOVES = [
    "Library/Application Support/Claude/ant-did",
    "Library/Application Support/Claude/ant-device-registry.json",
]
DEVICE_KEYS = ["userID", "machineID"]
# 排除项：不含 "/" 的按目录名在任意深度剪枝（node_modules、.git…）；含 "/" 的按相对扫描根的路径剪枝。
MARKER_EXCLUDES = ["Library/Caches", "node_modules", ".git", "ClaudeBackups", ".Trash",
                   "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
                   ".npm", ".cache", ".local/share/claude/versions", "Library/Developer",
                   ".local/share/devin",
                   # 浏览器/Electron 纯缓存目录：没有账号标识，但动辄数 GB（Cookies/IndexedDB/Local Storage/Cache_Data 仍然扫）
                   "Service Worker", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                   "GrShaderCache", "ShaderCache", "blob_storage", "File System", "Extensions", "optimization_guide_model_store"]
# 不扫全盘，只扫关键位置：Claude 自身状态、shell rc、wrapper / Electron agent 工具的 Claude 数据与内嵌浏览器分区、
# 浏览器资料里的站点数据（Cookies / Local Storage / IndexedDB / Session Storage）。
# Codex/Cursor 的会话库、Library/Logs 等只会以"路径字符串"形式提到老账号，默认不扫，需要时用 --scan-root 指定。
MARKER_DEFAULT_ROOTS = [
    ".claude", ".claude.json", ".zshrc", ".zprofile", ".bashrc", ".bash_profile",
    "Library/Application Support/Claude", "Library/Preferences", "Library/HTTPStorages",
]
MARKER_APP_SUPPORT_GLOBS = [
    "*/workspaces/*/data/Claude", "*/data/Claude",                 # wrapper 的 .claude 副本
    "orca/Partitions", "Codex/Partitions", "Codex/*/Partitions", "Cursor/Partitions",   # agent 工具的内嵌浏览器分区（不扫 Notion/币安等无关 App 的分区）
]
BROWSER_SITE_DATA_GLOBS = [
    "Library/Application Support/Google/Chrome/*/{Cookies,Local Storage,IndexedDB,Session Storage}",
    "Library/Application Support/Microsoft Edge/*/{Cookies,Local Storage,IndexedDB,Session Storage}",
    "Library/Application Support/BraveSoftware/Brave-Browser/*/{Cookies,Local Storage,IndexedDB,Session Storage}",
]

def _brace_glob(home, pat):
    if "{" in pat:
        pre, rest = pat.split("{", 1); alts, post = rest.split("}", 1)
        return [p for a in alts.split(",") for p in _brace_glob(home, pre + a + post)]
    return sorted(home.glob(pat))

def default_marker_roots(home):
    roots = [home / r for r in MARKER_DEFAULT_ROOTS]
    asd = home / "Library/Application Support"
    for g in MARKER_APP_SUPPORT_GLOBS:
        roots += sorted(asd.glob(g))
    if asd.is_dir():
        roots += [d for d in asd.iterdir() if d.is_dir() and "claude" in d.name.lower()]
    for g in BROWSER_SITE_DATA_GLOBS:
        roots += _brace_glob(home, g)
    seen, out = set(), []
    for r in roots:
        if str(r) not in seen:
            seen.add(str(r)); out.append(r)
    return out
KC_SERVICES = ["Claude Code-credentials", "claude-code-oauth-token"]

def mask(v):
    return (v[:4] + "…") if isinstance(v, str) and v else None

def under_home(home, p):
    """True 仅当 p 在 home 内，且 p 自身及到 home 的祖先都不是软链。"""
    p = Path(p)
    try:
        p.relative_to(home)
    except ValueError:
        return False
    cur = p
    while True:
        if cur.is_symlink():
            return False
        if cur == home:
            return True
        cur = cur.parent

def inventory(path):
    """{relpath: {sha256,size}} — 目录递归；软链/非常规文件跳过并标记。"""
    inv, skipped = {}, []
    path = Path(path)
    def add(f):
        try:
            h = hashlib.sha256()
            with open(f, "rb") as fh:
                for c in iter(lambda: fh.read(1 << 20), b""):
                    h.update(c)
            inv[str(f)] = {"sha256": h.hexdigest(), "size": f.stat().st_size}
        except OSError:
            skipped.append(str(f))
    if path.is_symlink():
        skipped.append(str(path))
    elif path.is_file():
        add(path)
    elif path.is_dir():
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]
            for n in files:
                f = Path(root) / n
                if f.is_symlink() or not f.is_file():
                    skipped.append(str(f))
                else:
                    add(f)
    return inv, skipped

def kc_status(service):
    r = subprocess.run(["security", "find-generic-password", "-s", service],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return {"exists": False}
    m = re.search(r'"mdat"[^\n]*"(\d{14}Z)', r.stdout)
    return {"exists": True, "mdat": m.group(1) if m else None}

def main_json_info(home):
    f = home / ".claude.json"
    if not f.is_file():
        return {"exists": False}
    try:
        d = json.loads(f.read_text())
    except Exception:
        return {"exists": True, "parse": "error"}
    o = d.get("oauthAccount") or {}
    return {"exists": True,
            "firstStartTime": d.get("firstStartTime"),
            "userID": bool(d.get("userID")), "machineID": bool(d.get("machineID")),
            "accountUuid": mask(o.get("accountUuid")),
            "email": mask(o.get("emailAddress") or o.get("email"))}

def collect_moves(home, scopes):
    cands = []
    if "cache" in scopes:
        cands += [home / p for p in CACHE_PATHS]
        cands += [home / "Library/Application Support/Claude" / p for p in APP_SUP_CLAUDE_CACHE]
        for g in CACHE_GLOBS:
            cands += sorted(home.glob(g))
    if "account" in scopes:
        cands += [home / p for p in ACCOUNT_MOVES]
    if "device-records" in scopes:
        cands += [home / p for p in DEVICE_MOVES]
    ok, rej = [], []
    for p in cands:
        if not p.exists() and not p.is_symlink():
            continue
        if not under_home(home, p):
            rej.append(str(p))
        else:
            ok.append(p)
    return ok, rej

def collect_edits(home, scopes, reset_ids):
    """([(file, keys_present)], [parse_errors]) — 只列文件里真实存在的白名单键。"""
    out, errs = [], []
    wanted = []
    if "account" in scopes:
        wanted += [home / f for f in ACCOUNT_EDIT_FILES]
        wanted += sorted(home.glob(ACCOUNT_EDIT_GLOB))
        kw = ACCOUNT_KEYS
    else:
        kw = []
    for p in wanted:
        if not (p.is_file() and under_home(home, p)):
            continue
        try:
            d = json.loads(p.read_text())
            if not isinstance(d, dict):
                raise ValueError("top-level not object")
        except Exception as e:
            errs.append({"file": str(p.relative_to(home)), "error": str(e)})
            continue
        keys = [k for k in kw if k in d]
        if keys:
            out.append((p, keys))
    if "device-records" in scopes and reset_ids:
        f = home / ".claude.json"
        if f.is_file() and under_home(home, f):
            try:
                d = json.loads(f.read_text())
                keys = [k for k in DEVICE_KEYS if k in d]
                if keys:
                    out.append((f, keys))
            except Exception as e:
                errs.append({"file": ".claude.json", "error": str(e)})
    return out, errs

def wrapper_copies(home):
    res = []
    for pat in ("Library/Application Support/*/workspaces/*/data/Claude/.claude.json",
                "Library/Application Support/*/data/Claude/.claude.json"):
        for f in sorted(home.glob(pat)):
            if not f.is_file():
                continue
            try:
                o = json.loads(f.read_text()).get("oauthAccount") or {}
                res.append({"path": str(f.relative_to(home)),
                            "oauthAccount": mask(o.get("accountUuid"))})
            except Exception:
                res.append({"path": str(f.relative_to(home)), "oauthAccount": "parse-error"})
    return res

def marker_scan(home, markers_file, scan_roots=None):
    """返回 {"content": [{path,hits}], "names": [path]}：
    content = 文件内容含标记；names = 文件/目录名本身含标记（如 skills/synced/<org>_<acct>/）。"""
    home = Path(home)
    roots = [Path(r) for r in scan_roots] if scan_roots else default_marker_roots(home)
    roots = [r for r in roots if r.exists()]
    markers = [m.strip() for m in Path(markers_file).read_text().splitlines() if m.strip()]
    content, names = [], []
    for root in roots:
        root = str(root)
        fargs = []
        for e in MARKER_EXCLUDES:
            if "/" in e:
                fargs += ["-path", os.path.join(root, e), "-prune", "-o"]
            else:
                fargs += ["-name", e, "-prune", "-o"]
        find = subprocess.run(["find", root] + fargs + ["-type", "f", "-size", "-50M", "-print0"],
                              capture_output=True)
        hits = subprocess.run(["xargs", "-0", "grep", "-lF", "-f", markers_file],
                              input=find.stdout, capture_output=True)
        for line in hits.stdout.decode("utf-8", "surrogateescape").splitlines():
            c = subprocess.run(["grep", "-cF", "-f", markers_file, line], capture_output=True, text=True)
            content.append({"path": line, "hits": int(c.stdout.strip() or 0)})
        nargs = []
        for m in markers:
            nargs += ["-name", f"*{m}*", "-o"]
        if nargs:
            f2 = subprocess.run(["find", root] + fargs + ["("] + nargs[:-1] + [")", "-print0"],
                                capture_output=True)
            names += [p for p in f2.stdout.decode("utf-8", "surrogateescape").split("\0") if p]
    return {"content": content, "names": sorted(set(names)), "roots": [str(r) for r in roots]}

def plan(home, scopes=None, markers_file=None, scan_roots=None, reset_ids=False):
    home = Path(home).resolve()
    scopes = set(scopes or ["cache", "account", "device-records"])
    moves, rejected = collect_moves(home, scopes)
    edits, parse_errs = collect_edits(home, scopes, reset_ids)
    rep = {"generated": datetime.datetime.now().isoformat(timespec="seconds"),
           "scopes": sorted(scopes), "home": str(home),
           "always": {"keychain": {s: kc_status(s) for s in KC_SERVICES},
                      "main_config": main_json_info(home)},
           "moves": [{"path": str(p.relative_to(home)), "kind": "dir" if p.is_dir() else "file",
                      "size": sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) if p.is_dir() else p.stat().st_size}
                     for p in moves],
           "rejected_paths": rejected,
           "json_edits": [{"file": str(f.relative_to(home)), "keys": k} for f, k in edits],
           "json_parse_errors": parse_errs,
           "reset_machine_ids": bool(reset_ids)}
    if "account" in scopes:
        rep["wrapper_copies_detected"] = wrapper_copies(home)
    if markers_file:
        rep["marker_scan"] = marker_scan(home, markers_file, scan_roots)
        rep["marker_scan_total_files"] = len(rep["marker_scan"]["content"]) + len(rep["marker_scan"]["names"])
    return rep

def guard_processes():
    r = subprocess.run(["ps", "-axo", "comm=,args="], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        parts = line.split(None, 1)
        if not parts:
            continue
        comm = os.path.basename(parts[0])
        if comm in ("Claude", "claude", "claude-code") or "/Claude.app/" in line:
            return f"检测到 Claude 相关进程在运行: {parts[0]}"
    pid = os.getppid()
    while pid > 1:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "ppid=,comm="],
                           capture_output=True, text=True)
        line = r.stdout.strip()
        if not line:
            break
        ppid_s, _, comm = line.partition(" ")
        if os.path.basename(comm.strip()).lower() in ("claude", "claude-code"):
            return "不能从 Claude Code 会话内运行本工具"
        try:
            pid = int(ppid_s)
        except ValueError:
            break
    return None

def backup_tree(sources, dest, home):
    """按 HOME 相对路径存放，避免 APFS 大小写不敏感/同名冲突。"""
    n, total = 0, 0
    for src in sources:
        src = Path(src)
        if not src.exists():
            continue
        base = dest / src.relative_to(home)
        inv, _ = inventory(src)
        for f in inv:
            rel = os.path.relpath(f, src if src.is_dir() else src.parent)
            tgt = base / rel if src.is_dir() else Path(str(base))
            tgt.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, tgt)
            n += 1
            total += inv[f]["size"]
    return n, total

def apply(home, plan_obj, backup_root=None, confirm_fn=None):
    home = Path(home).resolve()
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bdir = Path(backup_root or home / "ClaudeBackups") / f"claude-clean-{stamp}"
    report = {"status": "backing-up", "moved": [], "edited": []}
    def write_report():
        bdir.mkdir(parents=True, exist_ok=True)
        (bdir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    try:
        moves = [home / m["path"] for m in plan_obj["moves"]]
        edits = [(home / e["file"], e["keys"]) for e in plan_obj["json_edits"]]
        sources = moves + [f for f, _ in edits]
        snap = {}
        skipped_all = []
        for s in sources:
            inv, sk = inventory(s)
            skipped_all += sk
            snap.update(inv)
        if skipped_all:
            raise RuntimeError("存在不可读/非常规文件，中止（未做任何改动）: " + "; ".join(skipped_all[:5]))
        total = sum(v["size"] for v in snap.values())
        free = shutil.disk_usage(str(home)).free
        if free < total + 100 * 1024 * 1024:
            raise RuntimeError(f"磁盘空间不足: 需要 {total + 100*1024*1024} 可用 {free}")
        bdir.mkdir(parents=True, exist_ok=True)
        os.chmod(bdir, 0o700)
        backup_tree(sources, bdir / "files", home)
        (bdir / "hashes.json").write_text(json.dumps(snap, indent=1))
        back_inv = {}
        for s in sources:
            sub = bdir / "files" / s.relative_to(home)
            if sub.exists():
                bi, _ = inventory(sub)
                if s.is_dir():
                    for f, v in bi.items():
                        back_inv[os.path.join(str(s), os.path.relpath(f, sub))] = v
                else:
                    back_inv[str(s)] = list(bi.values())[0] if bi else {}
        mismatch = [k for k, v in snap.items() if back_inv.get(k) != v]
        if mismatch:
            raise RuntimeError(f"备份校验失败 {len(mismatch)} 项，中止（未做任何改动）")
        g = guard_processes()
        if g:
            raise RuntimeError(g)
        for s in sources:
            inv2, _ = inventory(s)
            for f in inv2:
                if f in snap and inv2[f] != snap[f]:
                    raise RuntimeError(f"备份期间源文件发生变化: {f}，中止")
        report["status"] = "applying"; write_report()
        trash = home / ".Trash" / f"claude-clean-{stamp}"
        for s in moves:
            if not s.exists() and not s.is_symlink():
                continue
            rel = s.relative_to(home)
            tgt = trash / rel
            tgt.parent.mkdir(parents=True, exist_ok=True)
            exp, _ = inventory(s)
            os.rename(str(s), str(tgt))
            got, _ = inventory(tgt)
            if {os.path.relpath(f, tgt): v for f, v in got.items()} != {os.path.relpath(f, s): v for f, v in exp.items()}:
                raise RuntimeError(f"移动后校验失败: {s}")
            report["moved"].append(str(rel))
        for f, keys in edits:
            if not f.is_file():
                continue
            d = json.loads(f.read_text())
            removed = [k for k in keys if d.pop(k, None) is not None]
            fd, tmp = tempfile.mkstemp(dir=str(f.parent), prefix=f.name + ".")
            try:
                with os.fdopen(fd, "w") as fh:
                    json.dump(d, fh, indent=2, ensure_ascii=False)
                    fh.write("\n")
                    fh.flush(); os.fsync(fh.fileno())
                shutil.copymode(f, tmp)
                os.replace(tmp, str(f))
            except BaseException:
                if os.path.exists(tmp):
                    os.unlink(tmp)
                raise
            json.loads(f.read_text())
            report["edited"].append({"file": str(f.relative_to(home)), "keys": removed})
            write_report()
        report["status"] = "complete"; write_report()
        return {"backup": str(bdir), "trash": str(trash), "report": report}
    except BaseException as e:
        report["status"] = "partial-or-stopped"
        try:
            write_report()
        except Exception:
            pass
        raise

def main():
    if sys.platform != "darwin":
        print("clean.py 仅支持 macOS"); sys.exit(2)
    ap = argparse.ArgumentParser(description="Claude 本机残余分档清理（默认只读审计）")
    ap.add_argument("--scope", action="append", choices=["cache", "account", "device-records"])
    ap.add_argument("--reset-machine-ids", action="store_true")
    ap.add_argument("--markers", help="老账号标记文件（每行一个 UUID/邮箱）")
    ap.add_argument("--scan-root", action="append", help="可重复；缺省只扫重点位置，不扫全盘")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    home = Path.home().resolve()
    rep = plan(home, a.scope, a.markers, a.scan_root, a.reset_machine_ids)
    if not a.apply:
        print(json.dumps(rep, ensure_ascii=False, indent=2)); return
    err = guard_processes()
    if err:
        print(err, file=sys.stderr); sys.exit(1)
    if not sys.stdin.isatty():
        print("--apply 需要真实终端 TTY 输入 CONFIRM", file=sys.stderr); sys.exit(1)
    print(json.dumps({k: rep[k] for k in ("moves", "json_edits")}, ensure_ascii=False, indent=2))
    if input("输入 CONFIRM 继续: ") != "CONFIRM":
        print("已取消"); sys.exit(0)
    r = apply(home, rep)
    print(f"完成。备份: {r['backup']}  废纸篓: {r['trash']}")

if __name__ == "__main__":
    main()
