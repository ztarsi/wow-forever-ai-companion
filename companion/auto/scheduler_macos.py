"""macOS: a launch agent runs the gatekeeper when the SavedVariables folder changes, and every
30 minutes to pick up changes held back by the daily limits. Nothing keeps running in between."""
import os, subprocess, time
from xml.sax.saxutils import escape

LABEL = os.environ.get("AIC_AUTO_LABEL", "local.aicompanion.auto")
RETRY_SECONDS = 1800
REMOVE_WAIT_SECONDS = 5         # launchctl bootout returns before the agent is gone; wait this long at most


def plist_path():
    return os.path.expanduser("~/Library/LaunchAgents/%s.plist" % LABEL)


def plist(python, script, watch_dir, log_dir, home=None):
    env = {"PATH": os.path.expanduser("~/.local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"}
    if home:
        env["AIC_AUTO_HOME"] = home
    env_xml = "".join("<key>%s</key><string>%s</string>" % (escape(k), escape(v)) for k, v in env.items())
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array><string>{python}</string><string>-I</string><string>{script}</string><string>watch</string></array>
  <key>WatchPaths</key><array><string>{watch}</string></array>
  <key>StartInterval</key><integer>{retry}</integer>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>EnvironmentVariables</key><dict>{env}</dict>
  <key>StandardOutPath</key><string>{out}</string>
  <key>StandardErrorPath</key><string>{err}</string>
</dict>
</plist>
""".format(label=escape(LABEL), python=escape(python), script=escape(script), watch=escape(watch_dir),
           retry=RETRY_SECONDS, env=env_xml, out=escape(os.path.join(log_dir, "launchd.out.log")),
           err=escape(os.path.join(log_dir, "launchd.err.log")))


def _domain():
    return "gui/%d" % os.getuid()


def _bootout():
    """Remove the agent and wait until launchctl no longer lists it (bounded), so a check or a new
    bootstrap right after never meets the old agent."""
    subprocess.run(["launchctl", "bootout", "%s/%s" % (_domain(), LABEL)], capture_output=True)
    for _ in range(int(REMOVE_WAIT_SECONDS / 0.1)):
        if not installed():
            return True
        time.sleep(0.1)
    return not installed()


def install(cfg, script):
    if not cfg.saved_variables:
        return "Could not find the game's SavedVariables folder. Run check for what to fix."
    watch = os.path.dirname(cfg.saved_variables)
    os.makedirs(os.path.dirname(plist_path()), exist_ok=True)
    home = os.environ.get("AIC_AUTO_HOME")
    with open(plist_path(), "w", encoding="utf-8") as f:
        f.write(plist(cfg["python"], script, watch, cfg.log_dir, home))
    _bootout()
    r = subprocess.run(["launchctl", "bootstrap", _domain(), plist_path()], capture_output=True, text=True)
    if r.returncode != 0:
        return "Could not start the watcher: %s" % (r.stderr.strip() or r.returncode)
    return "Watching %s (on each save, and every %d minutes)." % (watch, RETRY_SECONDS // 60)


def uninstall():
    gone = _bootout()
    if os.path.exists(plist_path()):
        os.remove(plist_path())
    if not gone:
        return "Stopped watching; macOS is still finishing. Settings and logs are kept."
    return "Stopped watching. Settings and logs are kept."


def installed():
    return subprocess.run(["launchctl", "print", "%s/%s" % (_domain(), LABEL)], capture_output=True).returncode == 0


def notify(title, text):
    script = 'display notification "%s" with title "%s"' % (text.replace('"', "'"), title.replace('"', "'"))
    subprocess.run(["osascript", "-e", script], capture_output=True, timeout=15)
