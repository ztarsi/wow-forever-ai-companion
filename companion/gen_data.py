"""Writes the AICompanion_Data add-on file (shopping lists, per-item advice and the plan shown in
the in-game panel) from the plan file.
Usage: python3 gen_data.py plans.json <path to AICompanion_Data.lua> [--automatic]
--automatic marks the data as written by an automatic update (companion/auto). The mark stays on
later runs without the flag, and turns on the add-on's "load new advice" reminder by default.
The AICompanion_Data folder is not part of installing the add-on. If the folder or its .toc is
missing, this creates them and says so: a new folder needs a full game restart, once.
The data add-on's "## Interface:" always follows the installed AICompanion release's .toc, never
the game's own version: supporting a new game version is a tested add-on release."""
import json, sys, datetime, os, re
args = [a for a in sys.argv[1:] if a != "--automatic"]
plans, target = args[0], args[1]
# Automatic once means the player uses automatic updates; keep that when the companion writes by hand.
automatic = "--automatic" in sys.argv[1:]
if not automatic and os.path.exists(target):
    automatic = re.search(r"^AICompanionMeta = \{[^}]*\bautomatic = true", open(target, encoding="utf-8").read(), re.M) is not None
# The template's text, with the interface number filled in (a test checks it matches the repository's).
TOC = """## Interface: {interface}
## Title: AI Companion Data
## Notes: Your own shopping lists and item advice for AI Companion, written by your AI companion. Updating AI Companion never touches this folder.
## Version: 1

AICompanion_Data.lua
"""
INTERFACE_LINE = re.compile(r"^## Interface:[ \t]*(.*?)[ \t]*$", re.M)
def addon_interface(data_folder):
    """The "## Interface:" of the installed AICompanion next to the data folder; else the one
    released with this tool. Returns (value, path read)."""
    here = os.path.dirname(os.path.abspath(__file__))
    for toc in (os.path.join(os.path.dirname(data_folder), "AICompanion", "AICompanion.toc"),
                os.path.join(here, "..", "AddOns", "AICompanion", "AICompanion.toc")):
        if os.path.exists(toc):
            m = INTERFACE_LINE.search(open(toc, encoding="utf-8-sig").read())
            if m and m.group(1): return m.group(1), os.path.normpath(toc)
    sys.exit("cannot find AICompanion.toc to read its ## Interface: line")
d = json.load(open(plans, encoding="utf-8"))
ACTIONS = {"equip", "use", "craft", "sell", "auction", "mail", "bank", "quest", "carry", "check"}
REPL = {"\u2014": ", ", "\u2013": "-", "\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"', "\u00d7": "x", "\u2026": "...", "\u00a0": " "}
def q(s):
    for a, b in REPL.items(): s = s.replace(a, b)
    s = s.encode("ascii", "ignore").decode().replace("|", "/")  # the game treats | as a formatting escape
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'
PLAN_KEYS = ["headline", "headlineShort", "next", "questing", "professions", "gear", "talents", "bags", "blindspots",
             "suggestedTalents", "basedOn"]
def lua(v, indent="    "):
    """A JSON value as a Lua literal. Strings go through q(), so they are plain ASCII."""
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    if isinstance(v, str): return q(v)
    if isinstance(v, list): return "{ " + ", ".join(lua(x, indent) for x in v if x is not None) + " }"
    if isinstance(v, dict):
        inner = indent + "    "
        parts = ["%s[%s] = %s," % (inner, q(str(k)), lua(x, inner)) for k, x in v.items() if x is not None]
        return "{\n" + "\n".join(parts) + "\n" + indent + "}" if parts else "{}"
    raise ValueError("cannot write %r to the data file" % (v,))
out = ["-- AI Companion data: shopping lists, per-item advice and plans for your characters.",
       "-- Generated from the plan file by gen_data.py. Do not edit by hand; regenerate instead.",
       "-- Keys are character first names, exactly as the game shows them.", "",
       "AICompanionShopping = {"]
for cname, c in d.get("characters", {}).items():
    names = c.get("shopping") or []
    if names: out.append("    [%s] = { %s }," % (q(cname), ", ".join(q(n) for n in names)))
out += ["}", "", "AICompanionAdvice = {",
        "    asOf = %s," % q(datetime.date.today().strftime("%b %d").replace(" 0", " ")),
        "    characters = {"]
n = 0
for cname, c in d.get("characters", {}).items():
    items = c.get("items") or {}
    if not items: continue
    out.append("        [%s] = {" % q(cname))
    for item, p in items.items():
        assert p["action"] in ACTIONS, (cname, item, p["action"])
        tip = p.get("tip") or p.get("note", "")
        assert len(tip) <= 48, "tooltip text over 48 characters for %s: add a short \"tip\"" % item
        out.append("            [%s] = { %s, %s }," % (q(item), q(p["action"]), q(tip)))
        n += 1
    out.append("        },")
out += ["    },", "}", ""]
def check_places(cname, v):
    """A step's optional place: {"zone", "x", "y", "label"}, coordinates on the game's 0-100 map scale."""
    if isinstance(v, list):
        for x in v: check_places(cname, x)
    elif isinstance(v, dict):
        if "where" in v:
            w, step = v["where"], v.get("id") or v.get("title") or "?"
            ok = (isinstance(w, dict) and isinstance(w.get("zone"), str) and w["zone"].strip() != ""
                  and all(isinstance(w.get(k), (int, float)) and not isinstance(w.get(k), bool)
                          and 0 <= w[k] <= 100 for k in ("x", "y"))
                  and (w.get("label") is None or (isinstance(w["label"], str) and len(w["label"]) <= 48)))
            if not ok:
                sys.exit("bad \"where\" on step %s of %s: use {\"zone\": \"Zone\", \"x\": 42.1, \"y\": 65.9, "
                         "\"label\": \"who or what is there, at most 48 characters\"}, x and y from 0 to 100" % (step, cname))
        for k, x in v.items():
            if k != "where": check_places(cname, x)
plans = {}
for cname, c in d.get("characters", {}).items():
    p = {k: c[k] for k in PLAN_KEYS if c.get(k) not in (None, "", [], {})}
    check_places(cname, p)
    if "basedOn" in p:   # where the player was in the snapshot this plan was made from
        b = p["basedOn"]
        ok = (isinstance(b, dict) and set(b) <= {"zone", "snapshot"} and isinstance(b.get("zone"), str)
              and 0 < len(b["zone"].strip()) <= 60 and (b.get("snapshot") is None or isinstance(b["snapshot"], str)))
        if not ok:
            sys.exit("bad \"basedOn\" for %s: use {\"zone\": \"<snapshot.location.zone>\", \"snapshot\": "
                     "\"<snapshot.takenAtText>\"}" % cname)
    if "suggestedTalents" in p:   # the companion's main and second talent tree, while the player has not chosen
        st = p["suggestedTalents"]
        ok = (isinstance(st, dict) and set(st) <= {"main", "second"}
              and all(isinstance(st.get(k), str) and 0 < len(st[k].strip()) <= 40 for k in st)
              and "main" in st and st.get("second") != st["main"])
        if not ok:
            sys.exit("bad \"suggestedTalents\" for %s: use {\"main\": \"Tree\", \"second\": \"Other tree\"}, the talent "
                     "trees as the snapshot names them; \"second\" is optional and differs from \"main\"" % cname)
    assert len(p.get("headlineShort", "")) <= 100, "headlineShort over 100 characters for %s" % cname
    if p: plans[cname] = p
# Feedback the player left with /aic feedback that the companion has filed: entry id -> issue ("#34").
reported = d.get("reported") or {}
assert isinstance(reported, dict) and all(isinstance(v, str) for v in reported.values()), \
    "\"reported\" maps a feedback id to its issue, for example {\"20261116-101500-3\": \"#34\"}"
out += ["AICompanionPlans = {",
        "    asOf = %s," % q(datetime.date.today().strftime("%b %d").replace(" 0", " ")),
        "    sources = %s," % lua(d.get("sources") or {}, "    "),
        "    characters = %s," % lua(plans, "    "),
        "    reported = %s," % lua(reported, "    "),
        "}", "",
        "-- How this file was written. automatic = true: the player uses automatic updates.",
        "AICompanionMeta = { automatic = %s, writtenAt = %d }" % ("true" if automatic else "false", int(datetime.datetime.now().timestamp())),
        ""]
folder = os.path.dirname(os.path.abspath(target))
interface, interface_from = addon_interface(folder)
restart = None
os.makedirs(folder, exist_ok=True)
toc = os.path.join(folder, "AICompanion_Data.toc")
if not os.path.exists(toc):
    open(toc, "w", encoding="utf-8", newline="\n").write(TOC.format(interface=interface))
    restart = "created the AICompanion_Data add-on in %s" % folder
else:
    text = open(toc, encoding="utf-8-sig").read()
    m = INTERFACE_LINE.search(text)
    if not m or m.group(1) != interface:       # only the interface line changes; the rest is kept
        line = "## Interface: " + interface
        text = INTERFACE_LINE.sub(line, text, count=1) if m else line + "\n" + text
        open(toc + ".new", "w", encoding="utf-8", newline="\n").write(text)
        os.replace(toc + ".new", toc)
        restart = "updated AICompanion_Data.toc to interface %s (from %s)" % (interface, interface_from)
tmp = target + ".new"
open(tmp, "w", encoding="utf-8", newline="\n").write("\n".join(out))
os.replace(tmp, target)
print("wrote", target, "advice entries:", n, "plans:", len(plans))
if restart:
    print(restart, "- the player must fully restart the game and tick AI Companion Data under AddOns")
