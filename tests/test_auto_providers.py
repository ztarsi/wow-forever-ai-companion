"""Provider boundaries and real publishing with fake CLIs; no AI or scheduler is started."""
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch
from test_auto import AutoTest, AUTO
import core
import providers

FAKE_CODEX = r'''
import json, os, sys
home = os.environ["AIC_AUTO_HOME"]
if "--version" in sys.argv:
    print("codex-cli 9.9.9 (stand-in)"); sys.exit(0)
if "--help" in sys.argv:
    print("--json --ephemeral --sandbox --skip-git-repo-check --cd"); sys.exit(0)
if "login" in sys.argv:
    sys.exit(1 if os.path.exists(os.path.join(home, "signed_out")) else 0)
prompt = sys.stdin.read()
with open(os.path.join(home, "codex_args.json"), "w") as f:
    json.dump({"args": sys.argv[1:], "prompt": prompt, "cwd": os.getcwd(),
               "marker": os.path.exists(".automation-running")}, f)
mode_path = os.path.join(home, "codex_mode")
mode = open(mode_path).read() if os.path.exists(mode_path) else "success"
if mode == "bad_json":
    print("not json"); sys.exit(0)
if mode == "invalid_plan":
    open("plans.json", "w").write("not json")
elif mode == "dropped_character":
    json.dump({"characters": {}}, open("plans.json", "w"))
else:
    plan = json.load(open("plans.json"))
    plan["characters"]["Testchar"] = {"headline": "Your next step is in town."}
    if mode == "bad_tip":
        plan["characters"]["Testchar"]["items"] = {"Test Item": {"action": "carry", "tip": "x" * 49}}
    json.dump(plan, open("plans.json", "w"))
print(json.dumps({"type": "thread.started", "thread_id": "test"}))
print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "Updated your plan."}}))
if mode == "failed":
    print(json.dumps({"type": "turn.failed", "error": {"message": "limit reached"}})); sys.exit(0)
if mode == "incomplete": sys.exit(0)
print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 80,
                                                      "output_tokens": 15}}))
if mode == "nonzero": sys.exit(1)
'''


class CodexAutomation(AutoTest):
    def setUp(self):
        super().setUp()
        self.fake_codex = os.path.join(self.tmp, "fake_codex.py")
        with open(self.fake_codex, "w") as f:
            f.write(FAKE_CODEX)
        self.config_update(provider="codex", codex_cmd=[sys.executable, self.fake_codex])

    def config_update(self, **values):
        p = os.path.join(self.home, "config.json")
        with open(p) as f:
            config = json.load(f)
        config.update(values)
        with open(p, "w") as f:
            json.dump(config, f)

    def mode(self, name):
        with open(os.path.join(self.home, "codex_mode"), "w") as f:
            f.write(name)

    def args(self):
        with open(os.path.join(self.home, "codex_args.json")) as f:
            return json.load(f)

    def trigger(self, notify=None):
        self.decide()
        self.write(level=22)
        core.decide(self.cfg(), "now", notify=notify)

    def test_default_claude_model_never_leaks_to_codex(self):
        self.config_update(model="sonnet")
        cfg = self.cfg()
        self.assertIsNone(cfg["model"])
        cmd, stdin = cfg.provider.command(cfg, "task", False)
        self.assertNotIn("--model", cmd)
        self.assertEqual(stdin, "task")
        self.config_update(codex_model="chosen-model")
        cfg = self.cfg()
        cmd, _ = cfg.provider.command(cfg, "task", False)
        self.assertEqual(cmd[cmd.index("--model") + 1], "chosen-model")

    def test_codex_plan_is_published_and_tokens_not_double_counted(self):
        notifications = []
        self.trigger(lambda *args: notifications.append(args))
        rec = self.store().runs()[0]
        self.assertTrue(rec["ok"])
        self.assertEqual(rec["provider"], "codex")
        self.assertEqual(rec["input_tokens"], 20)
        self.assertEqual(rec["cache_read_tokens"], 80)
        self.assertIsNone(rec["cost_usd"])
        self.assertEqual(self.store().load("pending.json", None), [])
        with open(self.cfg().data_lua) as f:
            data = f.read()
        self.assertIn("Your next step is in town.", data)
        self.assertIn("automatic = true", data, "watcher-published data turns on the in-game reminder")
        self.assertIn("Fully restart", notifications[0][1])
        self.assertFalse(os.path.exists(self.cfg().running_marker))
        self.assertTrue(self.args()["marker"])
        self.assertIsNone(self.claude_args(), "Codex never calls Claude")

    def test_codex_permissions_and_prompt_are_scoped(self):
        self.trigger()
        args = self.args()
        cmd = args["args"]
        self.assertIn("--ephemeral", cmd)
        self.assertEqual(cmd[cmd.index("--sandbox") + 1], "workspace-write")
        self.assertNotIn("--add-dir", cmd)
        self.assertNotIn("danger-full-access", cmd)
        self.assertIn('approval_policy="never"', cmd)
        self.assertIn('web_search="disabled"', cmd)
        self.assertIn("sandbox_workspace_write.network_access=false", cmd)
        self.assertIn("sandbox_workspace_write.writable_roots=[]", cmd)
        self.assertIn("SKILL.md", args["prompt"])
        self.assertNotIn("CLAUDE_GUIDE.md", args["prompt"])
        self.assertIn("do not wait for it", args["prompt"])
        self.assertIn("Do not edit the game folder", args["prompt"])
        self.assertEqual(cmd[-1], "-")

    def test_new_zone_enables_search_and_quotes_stay_in_stdin(self):
        self.decide()
        self.write(zone="Newlands", questions=("Use $(bad) & quote?",))
        self.decide()
        self.assertIn('web_search="live"', self.args()["args"])
        self.assertIn("$(bad)", self.args()["prompt"])
        self.assertNotIn("$(bad)", " ".join(self.args()["args"]))

    def test_provider_failure_keeps_plan_game_and_pending(self):
        for mode in ("bad_json", "incomplete", "failed", "nonzero", "invalid_plan", "bad_tip"):
            with self.subTest(mode=mode):
                # Reset per-case state while retaining the fake game and CLI.
                for name in ("state.json", "pending.json"):
                    try:
                        os.remove(os.path.join(self.cfg().state_dir, name))
                    except FileNotFoundError:
                        pass
                self.write()
                self.mode(mode)
                with open(self.cfg().plans, "w") as f:
                    f.write('{"characters": {}}')
                with open(self.cfg().plans, "rb") as f:
                    before = f.read()
                self.decide()
                self.write(level=22)
                notifications = []
                core.decide(self.cfg(), "force", notify=lambda *args: notifications.append(args))
                self.assertTrue(self.store().load("pending.json", []))
                self.assertFalse(self.store().runs()[-1]["ok"])
                with open(self.cfg().plans, "rb") as f:
                    self.assertEqual(f.read(), before)
                self.assertFalse(os.path.exists(self.cfg().data_lua))
                self.assertEqual(notifications, [])
                self.assertFalse(os.path.exists(self.cfg().running_marker))

    def test_invalid_existing_plan_does_not_spend_ai_usage(self):
        with open(self.cfg().plans, "w") as f:
            f.write("not json")
        self.trigger()
        self.assertEqual(self.store().runs(), [])
        self.assertTrue(self.store().load("pending.json", []))
        self.assertFalse(os.path.exists(os.path.join(self.home, "codex_args.json")))

    def test_removed_character_is_rejected(self):
        with open(self.cfg().plans, "w") as f:
            json.dump({"characters": {"OtherTestchar": {"headline": "Your existing plan."}}}, f)
        self.mode("dropped_character")
        self.trigger()
        with open(self.cfg().plans) as f:
            self.assertIn("OtherTestchar", json.load(f)["characters"])
        self.assertTrue(self.store().load("pending.json", []))
        self.assertFalse(os.path.exists(self.cfg().data_lua))

    def test_generator_preserves_installed_interface_and_existing_toc(self):
        addon = os.path.join(self.game, "Interface", "AddOns", "AICompanion")
        os.makedirs(addon)
        with open(os.path.join(addon, "AICompanion.toc"), "w") as f:
            f.write("## Interface: 16002\n")
        toc = os.path.join(os.path.dirname(self.cfg().data_lua), "AICompanion_Data.toc")
        with open(toc, "w") as f:
            f.write("## Interface: 16001\n## Notes: Keep this text\nAICompanion_Data.lua\n")
        self.trigger()
        with open(toc) as f:
            self.assertEqual(f.read(), "## Interface: 16002\n## Notes: Keep this text\nAICompanion_Data.lua\n")

    def test_existing_toc_means_reload_notification(self):
        self.trigger()
        self.write(level=23)
        notices = []
        core.decide(self.cfg(), "force", notify=lambda *args: notices.append(args))
        self.assertIn("/reload", notices[0][1])
        self.assertNotIn("restart", notices[0][1])

    def test_codex_honors_shared_limits(self):
        self.trigger()
        self.write(level=23)
        self.decide()
        self.assertEqual(len(self.store().runs()), 1)
        self.assertTrue(self.store().load("pending.json", []))

    def test_unavailable_codex_never_falls_back_to_claude(self):
        self.decide()
        self.write(level=22)
        cfg = self.cfg()
        cfg["codex_cmd"] = None
        core.decide(cfg, "now")
        self.assertEqual(self.store().runs(), [])
        self.assertTrue(self.store().load("pending.json", []))
        self.assertIsNone(self.claude_args())

    def test_auth_check_and_unknown_cost_report(self):
        lines = []
        self.assertTrue(core.check(self.cfg(), True, out=lines.append))
        open(os.path.join(self.home, "signed_out"), "w").close()
        lines = []
        self.assertFalse(core.check(self.cfg(), True, out=lines.append))
        self.assertTrue(any("FIX" in line and "signed in" in line for line in lines))
        self.trigger()
        lines = []
        core.report(self.cfg(), out=lines.append)
        report = "\n".join(lines)
        self.assertIn("cost unavailable", report)
        self.assertNotIn("$0.000", report)
        self.assertIn("100 input + 15 output", report)
        self.assertIn("providers: codex: 1 runs", report)
        self.assertIn("no dollar cap supported", report)

    def test_timeout_retains_changes_and_removes_marker(self):
        self.decide()
        self.write(level=22)
        real_run = subprocess.run
        def timeout_codex(cmd, **kwargs):
            if self.fake_codex in cmd:
                raise subprocess.TimeoutExpired(cmd, 1200)
            return real_run(cmd, **kwargs)
        with patch.object(core.subprocess, "run", side_effect=timeout_codex):
            self.decide()
        self.assertFalse(self.store().runs()[0]["ok"])
        self.assertTrue(self.store().load("pending.json", []))
        self.assertFalse(os.path.exists(self.cfg().running_marker))

    def cli(self, *args):
        return subprocess.run([sys.executable, os.path.join(AUTO, "aic_auto.py"), *args],
                              capture_output=True, text=True, timeout=30)

    def test_switch_preserves_settings_plans_and_pending(self):
        self.config_update(model="sonnet", codex_model="my-codex-model")
        self.store().save("pending.json", [{"kind": "level_up", "text": "keep me"}])
        self.assertEqual(self.cli("provider", "claude").returncode, 0)
        self.assertEqual(self.cfg()["model"], "sonnet")
        self.assertEqual(self.cli("provider", "codex").returncode, 0)
        self.assertEqual(self.cfg()["model"], "my-codex-model")
        self.assertEqual(self.cfg()["max_runs_per_day"], 3)
        self.assertEqual(len(self.store().load("pending.json", [])), 1)
        self.assertTrue(os.path.exists(self.cfg().plans))

    def test_unknown_provider_does_not_change_configuration(self):
        self.assertNotEqual(self.cli("provider", "gemini").returncode, 0)
        self.assertEqual(self.cfg()["provider"], "codex")
        with self.assertRaisesRegex(ValueError, "unsupported provider"):
            providers.get("gemini")

    def test_switch_waits_for_running_watcher(self):
        lock = core.Lock(os.path.join(self.store().cfg.state_dir, "gatekeeper.lock"))
        try:
            self.assertTrue(lock.acquire())
            self.assertNotEqual(self.cli("provider", "claude").returncode, 0)
            self.assertEqual(self.cfg()["provider"], "codex")
        finally:
            lock.f.close()

    def test_shared_skill_is_used_when_present(self):
        cfg = self.cfg()
        original = core.TOOLS
        try:
            core.TOOLS = self.tmp
            with open(os.path.join(self.tmp, "SKILL.md"), "w") as f:
                f.write("# Future shared gameplay rules")
            prompt, _ = core.prompt_for(cfg, [{"kind": "level_up", "text": "test"}])
            self.assertIn("SKILL.md", prompt)
            self.assertNotIn("CODEX_GUIDE.md", prompt)
        finally:
            core.TOOLS = original


class ProviderDecoding(unittest.TestCase):
    def test_codex_requires_completion_and_rejects_errors_after_completion(self):
        p = providers.get("codex")
        self.assertFalse(p.decode("")["ok"])
        self.assertFalse(p.decode('{"type":"thread.started"}')["ok"])
        self.assertFalse(p.decode('{"type":"turn.completed"}\n{"type":"error","message":"failure"}')["ok"])
        self.assertTrue(p.decode('{"type":"turn.completed"}')["ok"])
        self.assertIsNone(p.decode('{"type":"turn.completed"}')["input_tokens"])
        with self.assertRaises(ValueError):
            p.decode("not json")

    def test_claude_result_preserves_legacy_accounting(self):
        r = providers.get("claude").decode(json.dumps({"type": "result", "subtype": "success", "result": "done", "total_cost_usd": 0.12,
            "usage": {"input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 5}}))
        self.assertTrue(r["ok"])
        self.assertEqual(r["input_tokens"], 10)
        self.assertEqual(r["cache_read_tokens"], 20)
        self.assertEqual(r["cache_write_tokens"], 5)


if __name__ == "__main__":
    unittest.main()
