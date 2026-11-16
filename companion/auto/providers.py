"""Provider adapters. Scheduling, change detection and publishing belong to core.py.

Adapters own discovery, provider-specific permissions/flags and output decoding. Adding a
provider must be explicit: an unknown provider never falls back to another user's account.
"""
import json
import os
import shutil
import subprocess


def find_command(name):
    found = shutil.which(name)
    if found:
        return [found]
    paths = [os.path.expanduser("~/.local/bin/" + name + (".exe" if os.name == "nt" else ""))]
    if os.name == "nt":
        paths.append(os.path.join(os.environ.get("APPDATA", ""), "npm", name + ".cmd"))
    else:
        paths += ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
    if name == "codex" and os.sys.platform == "darwin":
        paths += ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                  "/Applications/Codex.app/Contents/Resources/codex"]
    return next(([p] for p in paths if os.path.isfile(p)), None)


def rule_path(path):
    """Claude permission-rule path; //absolute or //c/... on Windows."""
    p = os.path.abspath(path).replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        p = "/" + p[0].lower() + p[2:]
    return "/" + p


def shell_path(path):
    return os.path.abspath(path).replace("\\", "/")


def probe(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def version_checks(provider, cfg):
    cmd = cfg.get(provider.name + "_cmd")
    ok, version = False, ""
    if cmd:
        try:
            result = probe(list(cmd) + ["--version"])
            ok, version = result.returncode == 0, (result.stdout or "").strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
    return [(ok, "%s: %s" % (provider.label, " ".join(cmd or []) + (" (%s)" % version if ok else "")), provider.setup)]


class Claude:
    name, label = "claude", "Claude Code"
    default_model, model_setting, supports_dollar_cap = "sonnet", "model", True
    check_note = None
    setup = "install Claude Code and sign in once (it needs a paid Claude plan)"

    def checks(self, cfg):
        return version_checks(self, cfg)

    def command(self, cfg, prompt, web):
        allowed = ["Read", "Glob", "Grep",
                   "Edit(%s/**)" % rule_path(cfg["companion_dir"]),
                   "Write(%s/**)" % rule_path(cfg["companion_dir"]),
                   "Bash(%s:*)" % shell_path(cfg["python"]), 'Bash("%s":*)' % shell_path(cfg["python"])]
        if web:
            allowed += ["WebSearch", "WebFetch"]
        cmd = list(cfg["claude_cmd"]) + ["-p", prompt, "--output-format", "json", "--model", cfg["model"],
                                        "--no-session-persistence", "--add-dir", cfg["game_dir"],
                                        "--add-dir", cfg.tools, "--allowedTools", *allowed]
        if cfg.get("max_budget_usd_per_run"):
            cmd += ["--max-budget-usd", str(cfg["max_budget_usd_per_run"])]
        return cmd, None

    def decode(self, out):
        res = json.loads(out)
        if not isinstance(res, dict):
            raise ValueError("expected a Claude result object")
        usage = res.get("usage") or {}
        return {"ok": res.get("type") == "result" and res.get("subtype") == "success" and not res.get("is_error"), "result": res.get("result") or "",
                "cost_usd": res.get("total_cost_usd"), "turns": res.get("num_turns"),
                "input_tokens": usage.get("input_tokens"), "output_tokens": usage.get("output_tokens"),
                "cache_read_tokens": usage.get("cache_read_input_tokens"),
                "cache_write_tokens": usage.get("cache_creation_input_tokens"), "subtype": res.get("subtype")}


class Codex:
    name, label = "codex", "Codex CLI"
    # Do not force a paid-only model or pass Claude's legacy 'sonnet' setting to Codex.
    default_model, model_setting, supports_dollar_cap = None, "codex_model", False
    check_note = "Codex has no dollar cap flag; daily/gap limits apply. API-key auth is separately billed."
    setup = "install the Codex CLI and sign in with codex login; CLI/model access depends on your plan"

    def checks(self, cfg):
        checks = version_checks(self, cfg)
        if not checks[0][0]:
            return checks
        cmd = list(cfg["codex_cmd"])
        try:
            help_result = probe(cmd + ["exec", "--help"])
            required = ("--json", "--ephemeral", "--sandbox", "--skip-git-repo-check", "--cd")
            checks.append((help_result.returncode == 0 and all(flag in help_result.stdout for flag in required),
                           "Codex CLI supports unattended sandboxed runs", "update the Codex CLI"))
        except (OSError, subprocess.TimeoutExpired):
            checks.append((False, "Codex CLI capabilities could not be checked", "update the Codex CLI"))
        try:
            auth = probe(cmd + ["login", "status"])
            checks.append((auth.returncode == 0, "Codex CLI signed in", "sign in with codex login"))
        except (OSError, subprocess.TimeoutExpired):
            checks.append((False, "Codex CLI sign-in could not be checked", "run codex login"))
        return checks

    def command(self, cfg, prompt, web):
        cmd = list(cfg["codex_cmd"]) + ["exec", "--json", "--ephemeral", "--skip-git-repo-check",
                                       "--sandbox", "workspace-write", "--cd", cfg["companion_dir"],
                                       "-c", 'approval_policy="never"',
                                       "-c", 'web_search="%s"' % ("live" if web else "disabled"),
                                       "-c", "sandbox_workspace_write.network_access=false",
                                       "-c", "sandbox_workspace_write.writable_roots=[]"]
        if cfg.get("model"):
            cmd += ["--model", cfg["model"]]
        # Keep long prompts (and paths/questions containing shell metacharacters) out of argv.
        return cmd + ["-"], prompt

    def decode(self, out):
        completed, failed, messages = False, False, []
        totals = {"input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0}
        usage_seen = False
        for line in out.splitlines():
            if not line.strip():
                continue
            event = json.loads(line)
            if not isinstance(event, dict):
                raise ValueError("expected a Codex event object")
            kind = event.get("type")
            if kind == "turn.completed":
                completed = True
                usage = event.get("usage")
                if isinstance(usage, dict):
                    usage_seen = True
                    cached = usage.get("cached_input_tokens") or 0
                    # Codex input_tokens already includes cache hits. Normalize to the same
                    # noncached + cache accounting used by the shared report and Claude.
                    totals["input_tokens"] += max(0, (usage.get("input_tokens") or 0) - cached)
                    totals["cache_read_tokens"] += cached
                    totals["output_tokens"] += usage.get("output_tokens") or 0
            elif kind in ("turn.failed", "error"):
                failed = True
                messages.append(str(event.get("error") or event.get("message") or "Codex run failed"))
            elif kind == "item.completed":
                item = event.get("item") or {}
                if item.get("type") == "agent_message":
                    messages.append(item.get("text") or "")
        return {"ok": completed and not failed, "result": "\n".join(messages),
                "cost_usd": None, "turns": None, "cache_write_tokens": None,
                "subtype": "completed" if completed and not failed else "incomplete_or_failed",
                **{k: v if usage_seen else None for k, v in totals.items()}}


PROVIDERS = {p.name: p for p in (Claude(), Codex())}


def get(name):
    try:
        return PROVIDERS[name]
    except KeyError:
        raise ValueError("unsupported provider %r; choose %s (Gemini is not implemented yet)" %
                         (name, ", ".join(PROVIDERS))) from None
