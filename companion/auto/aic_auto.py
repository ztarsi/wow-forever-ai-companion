"""Automatic AI companion updates. Same commands on macOS and Windows.

  python aic_auto.py provider claude|codex  choose the provider without resetting plans or limits
  python aic_auto.py check       is everything in place? (no AI tokens)
  python aic_auto.py install     start watching the game's saves (survives restarts)
  python aic_auto.py uninstall   stop watching; keeps settings and logs
  python aic_auto.py status      watcher on or off, pending changes, today's runs
  python aic_auto.py report      AI runs, tokens and estimated cost per day; 7-day average
  python aic_auto.py dry         what would happen now; changes nothing, runs nothing
  python aic_auto.py now         decide now, within the daily limits
  python aic_auto.py force       run the AI now if changes are pending, ignoring the limits
  python aic_auto.py log         the last lines of the log

The scheduler runs "watch" (macOS, on each save) or "poll" (Windows, every few minutes).
Settings: config.json in the folder "check" prints.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402

if core.IS_WIN:
    import scheduler_windows as scheduler  # noqa: E402
elif core.IS_MAC:
    import scheduler_macos as scheduler  # noqa: E402
else:
    scheduler = None


def notify(title, text):
    if scheduler:
        try:
            scheduler.notify(title, text)
        except Exception:  # a notification is a nicety; never fail a run over it
            pass


def installed():
    return bool(scheduler and scheduler.installed())


def main(argv):
    cmd = (argv or ["status"])[0]
    if cmd == "provider" or (cmd == "install" and os.environ.get("AIC_AUTO_PROVIDER")):
        selected = (argv[1] if len(argv) == 2 else None) if cmd == "provider" else os.environ["AIC_AUTO_PROVIDER"]
        if selected not in core.providers.PROVIDERS:
            print("Choose a supported provider: claude or codex. Gemini support is coming later.")
            return 1
        # Hold the same lock as the watcher while changing configuration. Keep state, queued
        # changes, plans and both providers' model settings; the next run reloads the config.
        cfg = core.Config()
        store = core.Store(cfg)
        lock = core.Lock(os.path.join(cfg.state_dir, "gatekeeper.lock"))
        if not lock.acquire():
            print("An update is running. Wait for it to finish before switching providers.")
            return 1
        cfg["provider"] = selected
        cfg.save(["provider"])
        lock.f.close()
        if cmd == "provider":
            print("Provider: %s. Plans, pending changes and limits kept." % selected)
            return 0
    cfg = core.Config()
    if cmd in ("watch", "poll", "now", "force", "dry"):
        store = core.Store(cfg)
        lock = core.Lock(os.path.join(cfg.state_dir, "gatekeeper.lock"))
        if not lock.acquire():
            store.log("%s: another check is already running; skipped" % cmd)
            return 0
        try:
            core.decide(cfg, cmd, notify=notify)
        except Exception as e:  # keep the scheduler from retrying a crash over and over
            store.log("%s failed: %r" % (cmd, e))
            if cmd in ("now", "force", "dry"):
                raise
        return 0
    if cmd == "check":
        return 0 if core.check(cfg, installed()) else 1
    if cmd == "install":
        if not scheduler:
            print("Automatic updates support macOS and Windows.")
            return 1
        core.Store(cfg)
        cfg.save(["companion_dir", "python"])          # remember the choices the watcher must reuse
        print(scheduler.install(cfg, os.path.abspath(__file__)))
        print("Provider: %s" % cfg.provider.label)
        print("Limits: %d AI runs a day, at least %s apart, model %s. Settings: %s" % (
            cfg["max_runs_per_day"], core.gap_text(cfg["min_gap_hours"]), cfg["model"] or "CLI default", cfg.path))
        core.check(cfg, installed())
        return 0
    if cmd == "uninstall":
        print(scheduler.uninstall() if scheduler else "nothing to remove")
        return 0
    if cmd == "status":
        store = core.Store(cfg)
        today = core.now().strftime("%Y-%m-%d")
        runs = [r for r in store.runs() if r.get("started", "").startswith(today)]
        pending = store.load("pending.json", [])
        print("Provider: %s; model: %s" % (cfg.provider.label, cfg["model"] or "CLI default"))
        print("Watcher: %s" % ("on" if installed() else "off"))
        print("Enabled: %s   dry_run: %s" % (cfg["enabled"], cfg["dry_run"]))
        print("AI runs today: %d of %d" % (len(runs), cfg["max_runs_per_day"]))
        print("Pending changes: %d" % len(pending))
        for c in pending[-5:]:
            print("   [%s] %s" % (c["kind"], c["text"]))
        if os.path.exists(cfg.running_marker):
            print("An AI run is in progress now.")
        return 0
    if cmd == "report":
        core.report(cfg)
        return 0
    if cmd == "log":
        p = os.path.join(cfg.log_dir, "gatekeeper.log")
        if not os.path.exists(p):
            print("no log yet")
            return 0
        with open(p, encoding="utf-8") as f:
            print("".join(f.readlines()[-int((argv[1:] or ["20"])[0]):]), end="")
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
