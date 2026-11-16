"""Opt-in synthetic model smoke check. Never reads the game, plan or watcher configuration.

Uses signed-in CLIs and consumes their usage allowance. The assistant runs it only when asked.
Example: python evaluate_models.py --provider codex --model gpt-6-luna --output /private/path/result.json
"""
import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
import providers

OTHER = {"headline": "Your existing plan.", "next": [{"id": "other-step", "title": "Keep this step", "tag": "game"}]}
SOURCE = {"label": "Original-game crafting reference", "url": "https://example.com/classic/recipe", "scope": "classic"}
ACTIONS = {"later": "bank", "now": "craft", "unknown": "check"}


def grade(text):
    """Objective checks, not a model grading its own prose. Invalid JSON scores zero."""
    checks = {}
    try:
        result = json.loads(text)
        cases = {c["id"]: c["plan"] for c in result["cases"]}
        if set(cases) != set(ACTIONS) or len(result["cases"]) != len(ACTIONS):
            raise ValueError("expected exactly the three named cases")
    except (ValueError, KeyError, TypeError):
        return {"passed": 0, "total": 22, "failures": ["valid JSON containing exactly three cases"]}
    checks["valid JSON containing exactly three cases"] = True
    for name, action in ACTIONS.items():
        try:
            plan = cases[name]
            c = plan["characters"]["Testchar"]
            item = c["items"]["Test Leather"]
            checks[name + ": correct action"] = item["action"] == action
            checks[name + ": other character unchanged"] = plan["characters"].get("OtherTestchar") == OTHER
            checks[name + ": existing step preserved"] = any(step.get("id") == "keep-step" for step in c["next"])
            tip = item.get("tip", "")
            checks[name + ": short ASCII tooltip"] = bool(tip) and len(tip) <= 48 and tip.isascii()
            source = plan["sources"].get("oldgame") or {}
            checks[name + ": source retained"] = (source.get("url") == SOURCE["url"]
                                                     and source.get("scope") == "classic" and bool(source.get("label")))
            checks[name + ": no invented sources"] = set(plan["sources"]) == {"oldgame"}
            text = json.dumps(c).lower()
            if name == "later":
                checks[name + ": source uncertainty stated"] = "unconfirmed" in text or "not confirmed" in text
            elif name == "now":
                checks[name + ": game evidence used"] = "gloves" in text
            else:
                checks[name + ": missing facts acknowledged"] = (
                    any(word in text for word in ("missing", "unknown", "not captured", "absent", "not provided", "not supplied", "not available", "unconfirmed", "confirm"))
                    and any(step.get("tag") == "unverified" for step in c["next"]))
        except (KeyError, TypeError, AttributeError):
            # Make malformed plans fail every check for that case, without crashing the run.
            for label in ("correct action", "other character unchanged", "existing step preserved",
                          "short ASCII tooltip", "source retained", "no invented sources",
                          {"later": "source uncertainty stated", "now": "game evidence used", "unknown": "missing facts acknowledged"}[name]):
                checks[name + ": " + label] = False
    return {"passed": sum(checks.values()), "total": len(checks),
            "failures": [name for name, ok in checks.items() if not ok]}


def command(provider, executable, model, cwd):
    if provider == "codex":
        return executable + ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                             "--sandbox", "read-only", "--cd", cwd, "-c", 'approval_policy="never"',
                             "-c", 'web_search="disabled"', "--model", model, "-"]
    return executable + ["-p", "--output-format", "json", "--model", model, "--max-budget-usd", "0.25",
                         "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                         "--setting-sources", "", "--disable-slash-commands"]


def evaluate(provider, executable, model, prompt, repeats):
    results = []
    for _ in range(repeats):
        with tempfile.TemporaryDirectory(prefix="aic-model-eval-") as cwd:
            started = time.monotonic()
            try:
                p = subprocess.run(command(provider, executable, model, cwd), input=prompt,
                                   capture_output=True, text=True, encoding="utf-8", errors="replace",
                                   cwd=cwd, timeout=120, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                res = providers.get(provider).decode(p.stdout)
                record = {"provider": provider, "requested_model": model, "exit": p.returncode,
                          "seconds": round(time.monotonic() - started, 2), **res}
                if p.returncode or not res["ok"]:
                    record["status"] = "unavailable_or_failed"
                    record["diagnostic"] = (res.get("result") or p.stderr)[-2000:]
                else:
                    record["status"] = "completed"
                    record["quality"] = grade(res["result"])
                    if provider == "claude":
                        record["reported_models"] = list((json.loads(p.stdout).get("modelUsage") or {}).keys())
            except (OSError, subprocess.SubprocessError, ValueError, TypeError, AttributeError) as e:
                record = {"provider": provider, "requested_model": model,
                          "status": "unavailable_or_failed", "diagnostic": str(e),
                          "seconds": round(time.monotonic() - started, 2)}
            results.append(record)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=sorted(providers.PROVIDERS), required=True)
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    executable = providers.find_command(args.provider)
    if not executable:
        parser.error("%s CLI not found" % args.provider)
    prompt = Path(__file__).with_name("eval_prompt.txt").read_text()
    records = []
    for model in args.model:
        records += evaluate(args.provider, executable, model, prompt, args.repeats)
        r = records[-1]
        print("%s %s: %s; %s" % (args.provider, model, r["status"], r.get("quality", {})), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"scope": "synthetic smoke check, not a reliability benchmark",
                                      "prompt": prompt, "results": records}, indent=2) + "\n")
    return 0 if all(r.get("quality", {}).get("passed") == 22 for r in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
