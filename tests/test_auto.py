"""Automatic companion updates (companion/auto): change detection, the daily budget, the AI run
and the schedulers. A made-up game folder and a stand-in "claude" are used; no AI is called.
Runs on Windows, macOS and Linux (GitHub runs it on all three)."""
import datetime, io, json, os, shutil, subprocess, sys, tempfile, unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUTO = os.path.join(ROOT, "companion", "auto")
sys.path.insert(0, AUTO)
import core  # noqa: E402

FAKE_CLAUDE = r'''
import json, os, sys
home = os.environ["AIC_AUTO_HOME"]
with open(os.path.join(home, "claude_args.json"), "w") as f:
    json.dump({"args": sys.argv[1:], "cwd": os.getcwd(),
               "marker": os.path.exists(os.path.join(os.getcwd(), ".automation-running"))}, f)
if "--version" in sys.argv:
    print("9.9.9 (stand-in)"); sys.exit(0)
if os.path.exists(os.path.join(home, "claude_fails")):
    print(json.dumps({"is_error": True, "result": "failed", "subtype": "error_during_execution"})); sys.exit(1)
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "num_turns": 4,
                  "result": "Advice updated. Type /reload.", "total_cost_usd": 0.12,
                  "usage": {"input_tokens": 10, "output_tokens": 500, "cache_read_input_tokens": 90000,
                            "cache_creation_input_tokens": 8000}}))
'''


def snapshot_lua(level=21, zone="Testvale", quests=(("101", "Boar Trouble", False),), talent=0,
                 bank="2026-11-01 10:00:00", free=10, questions=()):
    q = ", ".join('{ questID = %s, title = "%s", complete = %s }' % (i, t, "true" if r else "false")
                  for i, t, r in quests)
    asks = ", ".join('{ character = "Testchar@Testrealm", text = "%s" }' % t for t in questions)
    return """AICompanionDB = {
  questions = { %s },
  characters = { ["Testchar@Testrealm"] = {
    bank = { seenAtText = "%s" },
    snapshot = {
      takenAtText = "now",
      character = { name = "Testchar", level = %d, unspentTalentPoints = %d },
      location = { zone = "%s" },
      quests = { %s },
      bags = { { bag = 0, free = %d, slots = 16 } },
      equipment = { { slotName = "Chest", name = "Worn Vest", durability = 50, durabilityMax = 50 } },
      skills = { professions = { { name = "Skinning", rank = 40, max = 75 } } },
    },
  } },
}
""" % (asks, bank, level, talent, zone, q, free)


class AutoTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        self.game = os.path.join(self.tmp, "World of Warcraft", "_forever_")
        self.sv_dir = os.path.join(self.game, "WTF", "Account", "TESTACCOUNT", "SavedVariables")
        os.makedirs(self.sv_dir)
        os.makedirs(os.path.join(self.game, "Interface", "AddOns", "AICompanion_Data"))
        self.companion = os.path.join(self.tmp, "My Companion")
        os.makedirs(self.companion)
        with open(os.path.join(self.companion, "plans.json"), "w") as f:
            json.dump({"characters": {}}, f)
        self.fake = os.path.join(self.tmp, "fake_claude.py")
        with open(self.fake, "w") as f:
            f.write(FAKE_CLAUDE)
        os.makedirs(self.home)
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump({"game_dir": self.game, "companion_dir": self.companion, "debounce_seconds": 0,
                       "max_runs_per_day": 3, "min_gap_hours": 2,           # fixed here, whatever the defaults
                       "claude_cmd": [sys.executable, self.fake], "python": sys.executable}, f)
        self.env = os.environ.get("AIC_AUTO_HOME")
        os.environ["AIC_AUTO_HOME"] = self.home
        self.t = 1_700_000_000
        self.write()

    def tearDown(self):
        if self.env is None:
            os.environ.pop("AIC_AUTO_HOME", None)
        else:
            os.environ["AIC_AUTO_HOME"] = self.env
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, **kw):
        """Write the snapshot file as the game would, with a newer timestamp each time."""
        p = os.path.join(self.sv_dir, "AICompanion.lua")
        with open(p, "w", encoding="utf-8") as f:
            f.write(snapshot_lua(**kw))
        self.t += 600
        os.utime(p, (self.t, self.t))

    def cfg(self):
        return core.Config()

    def decide(self, mode="now"):
        buf = io.StringIO()
        with redirect_stdout(buf):
            core.decide(self.cfg(), mode, out=print)
        return buf.getvalue()

    def store(self):
        return core.Store(self.cfg())

    def claude_args(self):
        p = os.path.join(self.home, "claude_args.json")
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return json.load(f)


class FindsThings(AutoTest):
    def test_account_found_from_the_newest_snapshot(self):
        other = os.path.join(self.game, "WTF", "Account", "OLDACCOUNT", "SavedVariables")
        os.makedirs(other)
        with open(os.path.join(other, "AICompanion.lua"), "w") as f:
            f.write("AICompanionDB = {}")
        os.utime(os.path.join(other, "AICompanion.lua"), (1000, 1000))
        cfg = self.cfg()
        self.assertEqual(cfg["account"], "TESTACCOUNT")
        self.assertTrue(cfg.saved_variables.endswith(os.path.join("TESTACCOUNT", "SavedVariables", "AICompanion.lua")))

    def test_check_reports_everything_in_place(self):
        lines = []
        ok = core.check(self.cfg(), True, out=lines.append)
        self.assertTrue(ok, "\n".join(lines))
        self.assertTrue(any("9.9.9" in l for l in lines))

    def test_check_names_what_to_fix(self):
        os.remove(os.path.join(self.companion, "plans.json"))
        lines = []
        self.assertFalse(core.check(self.cfg(), False, out=lines.append))
        self.assertTrue(any(l.startswith("FIX") and "plan file" in l for l in lines))
        self.assertTrue(any(l.startswith("FIX") and "watcher" in l for l in lines))

    def test_paths_for_permission_rules_and_the_shell(self):
        self.assertEqual(core.rule_path("C:\\Users\\Pat\\Documents\\AI Companion") if os.name == "nt" else
                         core.rule_path("/Users/pat/AI Companion"),
                         "//c/Users/Pat/Documents/AI Companion" if os.name == "nt" else "//Users/pat/AI Companion")
        self.assertNotIn("\\", core.shell_path(self.companion))


class DecidesWhenToRun(AutoTest):
    def test_first_look_records_a_baseline_without_an_ai_run(self):
        self.decide()
        self.assertEqual(self.store().load("pending.json", None), [])
        self.assertIsNone(self.claude_args())

    def test_level_up_starts_one_ai_run(self):
        self.decide()
        self.write(level=22)
        self.decide()
        runs = self.store().runs()
        self.assertEqual(len(runs), 1)
        self.assertTrue(runs[0]["ok"])
        self.assertEqual(runs[0]["kinds"], ["level_up"])
        self.assertEqual(runs[0]["cost_usd"], 0.12)
        self.assertEqual(self.store().load("pending.json", None), [])
        a = self.claude_args()
        self.assertTrue(a["marker"], "the in-progress marker exists during the run")
        self.assertFalse(os.path.exists(self.cfg().running_marker), "and is gone afterwards")
        self.assertEqual(os.path.normcase(os.path.realpath(a["cwd"])), os.path.normcase(os.path.realpath(self.companion)))
        prompt = a["args"][a["args"].index("-p") + 1]
        self.assertIn("Testchar reached level 22 (was 21)", prompt)
        self.assertIn("Do not use web search", prompt)
        self.assertNotIn("WebSearch", a["args"])

    def test_unchanged_file_or_quiet_changes_start_nothing(self):
        self.decide()
        self.decide()                                  # same file again
        self.write(zone="Testvale")                    # rewritten, nothing new
        self.decide()
        self.assertEqual(self.store().runs(), [])

    def test_meaningful_changes_are_all_noticed(self):
        self.decide()
        self.write(level=26, zone="Newlands", quests=(("101", "Boar Trouble", True), ("102", "Wolves", False)),
                   talent=1, bank="2026-11-02 10:00:00", free=2, questions=("What should I craft?",))
        out = self.decide("dry")
        for kind in ("level_up", "new_zone", "quest_added", "quest_ready", "talents", "bank", "bags_full", "question"):
            self.assertIn("[%s]" % kind, out)
        self.assertIn("You may use web search", out)    # a new zone allows research
        self.assertEqual(self.store().runs(), [])       # dry runs nothing

    def test_known_zone_is_quiet_but_a_new_one_is_not(self):
        self.decide()
        self.write(zone="Newlands")
        self.assertIn("[new_zone]", self.decide("dry"))
        self.decide()
        self.write(zone="Testvale")                     # back to a zone seen before
        self.assertIn("new changes: 0", self.decide("dry"))

    def test_minimum_gap_defers_and_keeps_the_change(self):
        self.decide()
        self.write(level=22)
        self.decide()
        self.write(level=23)
        self.decide()
        self.assertEqual(len(self.store().runs()), 1)
        self.assertEqual(len(self.store().load("pending.json", [])), 1)
        self.assertIn("minimum gap", "".join(open(os.path.join(self.cfg().log_dir, "gatekeeper.log")).readlines()[-1:]))

    def test_daily_limit(self):
        store = self.store()
        today = core.now().strftime("%Y-%m-%d")
        for h in ("00:00:00", "03:00:00", "06:00:00"):
            store.add_run({"started": "%s %s" % (today, h), "ok": True})
        self.assertIn("daily limit", core.budget_block(self.cfg(), store))
        yesterday = (core.now() - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
        self.assertIsNone(core.budget_block(self.cfg(), store, at=datetime.datetime.strptime(
            yesterday + " 12:00:00", "%Y-%m-%d %H:%M:%S") + datetime.timedelta(days=2)))

    def test_force_ignores_the_budget(self):
        self.decide()
        self.write(level=22)
        self.decide()
        self.write(level=23)
        self.decide()
        self.decide("force")
        self.assertEqual(len(self.store().runs()), 2)
        self.assertEqual(self.store().load("pending.json", None), [])

    def test_failed_run_keeps_the_changes_for_later(self):
        open(os.path.join(self.home, "claude_fails"), "w").close()
        self.decide()
        self.write(level=22)
        self.decide()
        self.assertFalse(self.store().runs()[0]["ok"])
        self.assertEqual(len(self.store().load("pending.json", [])), 1)

    def test_no_plan_yet_means_no_ai_run(self):
        os.remove(os.path.join(self.companion, "plans.json"))
        self.decide()
        self.write(level=22)
        self.decide()
        self.assertEqual(self.store().runs(), [])
        self.assertEqual(len(self.store().load("pending.json", [])), 1)

    def test_run_in_progress_defers(self):
        self.decide()
        self.write(level=22)
        open(self.cfg().running_marker, "w").close()
        self.decide()
        self.assertEqual(self.store().runs(), [])

    def test_disabled_does_nothing(self):
        with open(os.path.join(self.home, "config.json")) as f:
            c = json.load(f)
        c["enabled"] = False
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(c, f)
        self.decide()
        self.write(level=22)
        self.decide()
        self.assertEqual(self.store().runs(), [])

    def test_report_totals(self):
        self.decide()
        self.write(level=22)
        self.decide()
        lines = []
        core.report(self.cfg(), out=lines.append)
        text = "\n".join(lines)
        self.assertIn("$0.120", text)
        self.assertIn("1.0 runs/day", text)


class CommandLine(AutoTest):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, os.path.join(AUTO, "aic_auto.py"), *args], capture_output=True,
                              text=True, env=dict(os.environ, AIC_AUTO_HOME=self.home), timeout=120)

    def test_now_status_and_report(self):
        self.assertEqual(self.run_cli("now").returncode, 0)
        self.write(level=22)
        self.assertEqual(self.run_cli("now").returncode, 0)
        st = self.run_cli("status").stdout
        self.assertIn("AI runs today: 1 of 3", st)
        self.assertIn("1 runs/day", self.run_cli("report").stdout.replace(".0 runs", " runs"))
        self.assertIn("AI run ok", self.run_cli("log").stdout)

    def test_second_gatekeeper_is_turned_away(self):
        lock = core.Lock(os.path.join(self.store().cfg.state_dir, "gatekeeper.lock"))
        self.assertTrue(lock.acquire())
        self.assertEqual(self.run_cli("now").returncode, 0)
        self.assertIn("another check is already running", self.run_cli("log").stdout)


class Schedulers(AutoTest):
    def test_macos_launch_agent_file(self):
        import scheduler_macos as m
        text = m.plist("/py & co/python", "/x/aic_auto.py", "/game/SavedVariables", "/logs", home="/h")
        self.assertIn("<string>watch</string>", text)
        self.assertIn("<key>WatchPaths</key><array><string>/game/SavedVariables</string>", text)
        self.assertIn("<integer>1800</integer>", text)
        self.assertIn("/py &amp; co/python", text)             # escaped
        if sys.platform == "darwin" and shutil.which("plutil"):
            p = os.path.join(self.tmp, "a.plist")
            with open(p, "w") as f:
                f.write(text)
            self.assertEqual(subprocess.run(["plutil", "-lint", p], capture_output=True).returncode, 0)

    def test_windows_task_script(self):
        import scheduler_windows as w
        s = w.task_script("C:\\Py thon\\python.exe", "C:\\it's\\aic_auto.py", "C:\\it's")
        self.assertIn("-RepetitionInterval (New-TimeSpan -Minutes 5)", s)
        self.assertIn("'C:\\it''s'", s)                            # PowerShell quoting
        self.assertIn("poll", s)

    @unittest.skipUnless(os.name == "nt", "needs Windows Task Scheduler")
    def test_windows_task_is_created_found_and_removed(self):
        import scheduler_windows as w
        w.TASK = "AICompanionAutoTest"
        try:
            msg = w.install(self.cfg(), os.path.join(AUTO, "aic_auto.py"))
            self.assertIn("every 5 minutes", msg)
            self.assertTrue(w.installed())
        finally:
            w.uninstall()
        self.assertFalse(w.installed())

    @unittest.skipUnless(sys.platform == "darwin" and os.environ.get("AIC_TEST_LAUNCHD"), "set AIC_TEST_LAUNCHD=1")
    def test_macos_launch_agent_is_loaded_and_removed(self):
        import scheduler_macos as m
        m.LABEL = "local.aicompanion.auto.test"
        try:
            self.assertIn("Watching", m.install(self.cfg(), os.path.join(AUTO, "aic_auto.py")))
            self.assertTrue(m.installed())
        finally:
            m.uninstall()
        self.assertFalse(m.installed())


class MacRemovalWaits(unittest.TestCase):
    """launchctl bootout returns before the agent is gone; removal waits until launchctl confirms it.
    Runs everywhere: launchctl is imitated, so the race can be reproduced on purpose."""

    def fake_launchctl(self, m, gone_after):
        """A launchctl whose agent is still listed for gone_after checks after each bootout."""
        state = {"loaded": False, "left": 0, "calls": []}

        class R:
            def __init__(self, code): self.returncode, self.stdout, self.stderr = code, "", ""

        def run(args, **kw):
            state["calls"].append(args[1])
            if args[1] == "bootout":
                if state["loaded"]:
                    state["left"] = gone_after
                return R(0)
            if args[1] == "bootstrap":
                if state["loaded"]:
                    return R(5)                       # macOS refuses: the old agent is not gone yet
                state["loaded"] = True
                return R(0)
            if args[1] == "print":
                if state["left"] > 0:
                    state["left"] -= 1
                    if state["left"] == 0:
                        state["loaded"] = False
                    return R(0)
                return R(0 if state["loaded"] else 113)
            return R(0)
        return state, run

    def setUp(self):
        import scheduler_macos as m
        self.m = m
        self.saved = (m.subprocess.run, m.time.sleep, m.LABEL, m.plist_path)
        self.tmp = tempfile.mkdtemp()
        m.LABEL = "local.aicompanion.auto.test"
        m.plist_path = lambda: os.path.join(self.tmp, "agent.plist")
        m.time.sleep = lambda s: None
        self.cfg = type("C", (), {"saved_variables": os.path.join(self.tmp, "SV", "AICompanion.lua"),
                                  "log_dir": self.tmp, "__getitem__": lambda s, k: sys.executable})()

    def tearDown(self):
        m = self.m
        m.subprocess.run, m.time.sleep, m.LABEL, m.plist_path = self.saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_uninstall_returns_only_once_the_agent_is_gone(self):
        state, self.m.subprocess.run = self.fake_launchctl(self.m, gone_after=3)
        state["loaded"] = True
        self.m.uninstall()
        self.assertFalse(self.m.installed())

    def test_reinstall_waits_for_the_old_agent_before_starting_the_new_one(self):
        state, self.m.subprocess.run = self.fake_launchctl(self.m, gone_after=3)
        state["loaded"] = True                         # an older watcher is still installed
        self.assertIn("Watching", self.m.install(self.cfg, "aic_auto.py"))
        self.assertTrue(self.m.installed())

    def test_gives_up_after_a_bounded_wait(self):
        state, self.m.subprocess.run = self.fake_launchctl(self.m, gone_after=10 ** 6)
        state["loaded"] = True
        self.m.uninstall()                             # returns instead of hanging
        self.assertLessEqual(state["calls"].count("print"), 60)


class Defaults(unittest.TestCase):
    def test_defaults_are_valid_limits(self):
        self.assertGreaterEqual(core.DEFAULTS["max_runs_per_day"], 1)
        self.assertGreater(core.DEFAULTS["min_gap_hours"], 0)
        self.assertEqual(core.DEFAULTS["model"], "sonnet")

    def test_gap_in_plain_words(self):
        self.assertEqual(core.gap_text(5 / 60), "5 min")
        self.assertEqual(core.gap_text(2), "2h")


if __name__ == "__main__":
    unittest.main()
