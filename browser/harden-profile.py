#!/usr/bin/env python3
# harden-profile.py — 专用浏览器资料目录的"地区信号"加固。
# Chrome 退出后运行（运行中会检测 SingletonLock / lsof 并拒绝）。
#
# 写死的键：
#   intl.accept_languages / intl.selected_languages = "en-US,en"
#   spellcheck.dictionaries = ["en-US"]          translate.enabled = false
#   profile.default_content_setting_values.geolocation = 2  （默认拒绝定位）
#   dns_over_https.mode = "off"
#   webrtc.ip_handling_policy = "disable_non_proxied_udp"
#   webrtc.multiple_routes_enabled / nonproxied_udp_enabled = false
#   signin.allowed = false    sync.requested = false
#
# 注意：对已登录 Google 账号的资料，signin.allowed=false 可能被忽略甚至触发登出。
#       若资料已登录且想保住登录态，加 --keep-signin 跳过这两个键。
#
# --clear-site-storage：把该资料的 Local Storage / Session Storage / IndexedDB /
#   Service Worker 整体移到 <profile>/../_site-storage-backup-<ts>/。
#   只对「刚建好、还没登录」的资料有意义——claude.ai 会把首次语言判定写进
#   localStorage spa:locale，登录过再想清语言就得整站清。
import argparse, datetime, json, os, shutil, subprocess, sys

KEYS = {
    ("intl", "accept_languages"): "en-US,en",
    ("intl", "selected_languages"): "en-US,en",
    ("spellcheck", "dictionaries"): ["en-US"],
    ("translate", "enabled"): False,
    ("profile", "default_content_setting_values", "geolocation"): 2,
    ("dns_over_https", "mode"): "off",
    ("webrtc", "ip_handling_policy"): "disable_non_proxied_udp",
    ("webrtc", "multiple_routes_enabled"): False,
    ("webrtc", "nonproxied_udp_enabled"): False,
    ("signin", "allowed"): False,
    ("sync", "requested"): False,
}
SIGNIN_KEYS = [("signin", "allowed"), ("sync", "requested")]

def in_use(profile):
    if os.path.exists(os.path.join(os.path.dirname(profile.rstrip("/")), "SingletonLock")) or \
       os.path.exists(os.path.join(profile, "SingletonLock")):
        return True
    r = subprocess.run(["lsof", "-t", "--", profile], capture_output=True, text=True)
    return bool(r.stdout.strip())

def main():
    ap = argparse.ArgumentParser(description="加固专用浏览器资料目录的地区信号")
    ap.add_argument("profile_dir")
    ap.add_argument("--keep-signin", action="store_true", help="跳过 signin.allowed / sync.requested")
    ap.add_argument("--clear-site-storage", action="store_true",
                    help="把 Local/Session Storage、IndexedDB、Service Worker 整体移走备份")
    args = ap.parse_args()
    profile = os.path.abspath(os.path.expanduser(args.profile_dir))

    if not os.path.isdir(profile):
        sys.exit(f"资料目录不存在: {profile}")
    if in_use(profile):
        sys.exit("检测到 Chrome 正在使用该资料（SingletonLock/lsof），请先退出浏览器。")

    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    prefs_path = os.path.join(profile, "Preferences")
    if not os.path.isfile(prefs_path):
        sys.exit(f"Preferences 不存在: {prefs_path}（先让浏览器在该资料下启动一次）")

    bak = prefs_path + f".bak-{ts}"
    shutil.copy2(prefs_path, bak)
    print(f"已备份 Preferences -> {bak}")

    prefs = json.load(open(prefs_path))
    keys = {k: v for k, v in KEYS.items() if not (args.keep_signin and k in SIGNIN_KEYS)}
    changes = []
    for path, new in keys.items():
        node = prefs
        for k in path[:-1]:
            node = node.setdefault(k, {})
            if not isinstance(node, dict):
                sys.exit(f"Preferences 中 {path[:-1]} 不是对象，中止")
        old = node.get(path[-1], "<unset>")
        if old != new:
            changes.append((".".join(path), old, new))
            node[path[-1]] = new

    json.dump(prefs, open(prefs_path, "w"), ensure_ascii=False, indent=2)
    print(f"改动 {len(changes)} 个键" + ("（--keep-signin：跳过登录/同步两键）" if args.keep_signin else "") + ":")
    for k, old, new in changes:
        o = json.dumps(old, ensure_ascii=False)
        n = json.dumps(new, ensure_ascii=False)
        print(f"  {k}: {o[:60]} -> {n}")

    if args.clear_site_storage:
        dest = os.path.join(os.path.dirname(profile), f"_site-storage-backup-{ts}")
        os.makedirs(dest, exist_ok=True)
        for d in ("Local Storage", "Session Storage", "IndexedDB", "Service Worker"):
            src = os.path.join(profile, d)
            if os.path.exists(src):
                shutil.move(src, os.path.join(dest, d))
                print(f"移走 {d} -> {dest}")
        print(f"站点存储已清空备份于: {dest}（仅适合未登录的新资料）")

if __name__ == "__main__":
    main()
