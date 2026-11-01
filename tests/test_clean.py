#!/usr/bin/env python3
import json, os, shutil, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import clean


class T(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp()
        self.home = Path(self.td) / "home"
        self.home.mkdir()
        (self.home / ".claude" / "cache").mkdir(parents=True)
        (self.home / ".claude" / "cache" / "a.bin").write_bytes(b"x" * 10)
        (self.home / ".claude.json").write_text(json.dumps({
            "oauthAccount": {"accountUuid": "aaaa-1", "emailAddress": "e@x.co"},
            "userID": "u", "machineID": "m", "firstStartTime": "2026-01-01",
            "keep": 1}))
        (self.home / ".claude" / "backups").mkdir(parents=True)
        (self.home / ".claude" / "backups" / ".claude.json.backup.1").write_text(
            json.dumps({"oauthAccount": {"accountUuid": "aaaa-1"}, "keep2": 2}))
        (self.home / ".claude" / ".credentials.json").write_text("{}")

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def test_plan_picks_existing_only(self):
        p = clean.plan(self.home, ["cache"])
        paths = [m["path"] for m in p["moves"]]
        self.assertIn(".claude/cache", paths)
        self.assertNotIn(".claude/telemetry", paths)
        self.assertTrue(p["always"]["main_config"]["userID"])

    def test_symlink_rejected(self):
        target = Path(self.td) / "outside"
        target.mkdir()
        (target / "f").write_text("x")
        os.symlink(target, self.home / ".claude" / "telemetry")
        p = clean.plan(self.home, ["cache"])
        self.assertTrue(any(r.endswith("/.claude/telemetry") for r in p["rejected_paths"]))

    def test_edit_whitelist_only(self):
        edits = dict((e["file"], e["keys"]) for e in
                     clean.plan(self.home, ["account"], reset_ids=False)["json_edits"])
        self.assertIn(".claude.json", edits)
        self.assertNotIn("userID", edits[".claude.json"])
        edits2 = dict((e["file"], e["keys"]) for e in
                      clean.plan(self.home, ["device-records"], reset_ids=True)["json_edits"])
        self.assertIn("userID", edits2[".claude.json"])

    def test_apply_complete(self):
        plan = clean.plan(self.home, ["cache", "account"])
        # monkeypatch guard
        clean.guard_processes = lambda: None
        r = clean.apply(self.home, plan)
        self.assertEqual(r["report"]["status"], "complete")
        self.assertFalse((self.home / ".claude" / "cache").exists())
        self.assertTrue((self.home / ".Trash" / r["trash"].split("/")[-1]).exists() or
                        Path(r["trash"]).exists())
        self.assertTrue((Path(r["backup"]) / "hashes.json").is_file())
        rep = json.loads((Path(r["backup"]) / "report.json").read_text())
        self.assertEqual(rep["status"], "complete")
        self.assertIn(".claude/cache", rep["moved"])
        # credential file moved
        self.assertFalse((self.home / ".claude" / ".credentials.json").exists())
        # json edit: oauthAccount gone, keep intact
        d = json.loads((self.home / ".claude.json").read_text())
        self.assertNotIn("oauthAccount", d)
        self.assertEqual(d["keep"], 1)
        b = json.loads((self.home / ".claude" / "backups" / ".claude.json.backup.1").read_text())
        self.assertNotIn("oauthAccount", b)
        self.assertEqual(b["keep2"], 2)

    def test_edit_lists_present_keys_only(self):
        # .claude.json has oauthAccount but not lastKnownAccountUuid etc.
        p = clean.plan(self.home, ["account"])
        e = dict((x["file"], x["keys"]) for x in p["json_edits"])
        self.assertEqual(e[".claude.json"], ["oauthAccount"])
        # 无白名单键的文件不进列表；坏 JSON 进 json_parse_errors
        (self.home / "Library/Application Support/Claude").mkdir(parents=True)
        (self.home / "Library/Application Support/Claude/config.json").write_text("{bad")
        p2 = clean.plan(self.home, ["account"])
        self.assertTrue(any("config.json" in e_["file"] for e_ in p2["json_parse_errors"]))
        self.assertFalse(any("config.json" in x["file"] for x in p2["json_edits"]))

    def test_case_colliding_basenames(self):
        a = self.home / ".claude" / "cache2" / "Cache"
        b = self.home / "Library/Application Support/Claude" / "Cache"
        a.mkdir(parents=True); b.mkdir(parents=True)
        (a / "f.txt").write_text("lower"); (b / "f.txt").write_text("upper")
        clean.guard_processes = lambda: None
        plan = {"moves": [{"path": ".claude/cache2/Cache", "kind": "dir", "size": 0},
                          {"path": "Library/Application Support/Claude/Cache", "kind": "dir", "size": 0}],
                "json_edits": []}
        r = clean.apply(self.home, plan)
        files = Path(r["backup"]) / "files"
        self.assertTrue((files / ".claude/cache2/Cache/f.txt").is_file())
        self.assertTrue((files / "Library/Application Support/Claude/Cache/f.txt").is_file())

    def test_marker_scan_excludes(self):
        (self.home / "x" / "deep" / "node_modules").mkdir(parents=True, exist_ok=True)
        (self.home / "x" / "deep" / "node_modules" / "hit.txt").write_text("MARK1")
        (self.home / "hit2.txt").write_text("MARK1")
        (self.home / ".claude" / "skills" / "synced" / "ORG_MARK1").mkdir(parents=True, exist_ok=True)
        mk = Path(self.td) / "markers.txt"; mk.write_text("MARK1\n")
        res = clean.marker_scan(self.home, str(mk), [self.home])
        paths = [h["path"] for h in res["content"]]
        self.assertTrue(any(p.endswith("hit2.txt") for p in paths))
        self.assertFalse(any("node_modules" in p for p in paths))   # 任意深度的 node_modules 都被剪掉
        self.assertTrue(any(p.endswith("ORG_MARK1") for p in res["names"]))  # 目录名含标记也要报
        # 缺省根：只扫重点位置，不扫 HOME 下的其它目录
        res2 = clean.marker_scan(self.home, str(mk))
        self.assertFalse(any(p.endswith("hit2.txt") for p in [h["path"] for h in res2["content"]]))
        self.assertTrue(any(p.endswith("ORG_MARK1") for p in res2["names"]))

    def test_apply_guard_abort(self):
        plan = clean.plan(self.home, ["cache"])
        clean.guard_processes = lambda: "检测到运行中"
        with self.assertRaises(RuntimeError):
            clean.apply(self.home, plan)
        # find the partial report
        reps = list((self.home / "ClaudeBackups").glob("claude-clean-*/report.json"))
        self.assertTrue(reps)
        self.assertEqual(json.loads(reps[-1].read_text())["status"], "partial-or-stopped")
        # source untouched
        self.assertTrue((self.home / ".claude" / "cache" / "a.bin").exists())


if __name__ == "__main__":
    unittest.main()
