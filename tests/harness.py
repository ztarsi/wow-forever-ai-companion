"""Drives the add-on inside the stand-in game client (mock_wow.lua) under Lua 5.1.

A Game holds one running client. Its world (character, bags, items, auction listings) is a
plain Python dict, so a test can build any situation. The SavedVariables text survives
reload, logout and login exactly as the game would write and read it.
"""

import copy
import os
import re
import xml.etree.ElementTree as ET

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = os.path.join(ROOT, "AddOns")
MOCK = os.path.join(ROOT, "tests", "mock_wow.lua")

# Globals the add-ons are allowed to create.
DECLARED_GLOBALS = {
    "AICompanionDB", "AICompanionRules", "AICompanionShopping", "AICompanionAdvice",
    "SLASH_AICOMPANION1", "SLASH_AICOMPANION2", "AICompanionCopyFrame", "AICompanionCopyScroll",
    "AICompanionAuctionButton", "AICompanionPlans", "AICompanionPanel", "AICompanionPanelScroll",
    "AICompanionMinimapButton", "AICompanionMeta", "BINDING_HEADER_AICOMPANION", "BINDING_NAME_AICOMPANION_TOGGLE_PANEL",
    "AICompanion_TogglePanel",
}


def toc_files(addon):
    """The files an add-on loads, in order, and its SavedVariables names, read from its .toc."""
    path = os.path.join(ADDONS, addon, addon + ".toc")
    files, saved = [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            m = re.match(r"^##\s*SavedVariables:\s*(.+)$", line)
            if m:
                saved += [s.strip() for s in m.group(1).split(",") if s.strip()]
            elif line and not line.startswith("#"):
                files.append(line)
    return files, saved


def to_py(value):
    """Convert a Lua value to plain Python: tables become dicts, or lists when keyed 1..n."""
    if lua51.lua_type(value) != "table":
        return value
    d = {k: to_py(v) for k, v in value.items()}
    if d and all(isinstance(k, int) for k in d) and sorted(d) == list(range(1, len(d) + 1)):
        return [d[i] for i in range(1, len(d) + 1)]
    return d


class Game:
    def __init__(self, world, saved=None, data_source=None, with_data=True):
        self.world = copy.deepcopy(world)
        self.saved = saved or {}            # SavedVariables name -> file text
        self.data_source = data_source       # replacement AICompanion_Data.lua text, if any
        self.with_data = with_data           # False: the AICompanion_Data folder is not installed
        self.lua = None
        self.reloads = 0
        self.lua_prelude = None              # Lua run after the stand-in client loads, before the add-ons

    # ------------------------------------------------------------------ startup

    def addons(self):
        """The add-ons installed, in load order."""
        return ("AICompanion_Data", "AICompanion") if self.with_data else ("AICompanion",)

    def start(self):
        """Start the client: load add-ons and their SavedVariables, log in, settle for 6 seconds."""
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().WORLD = self.lua.table_from(self.world, recursive=True)
        with open(MOCK, encoding="utf-8") as f:
            self.lua.execute(f.read())
        self.M = self.lua.globals().Mock
        if self.lua_prelude:
            self.lua.execute("local M = Mock\n" + self.lua_prelude)
        allowed = self.lua.table_from({k: True for k in DECLARED_GLOBALS})
        self.M.trackGlobals(allowed)
        self.ns = {}
        for addon in self.addons():
            files, saved_names = toc_files(addon)
            ns = self.lua.table()
            self.ns[addon] = ns
            for fname in files:
                path = os.path.join(ADDONS, addon, fname)
                with open(path, encoding="utf-8") as f:
                    src = f.read()
                if addon == "AICompanion_Data" and fname == "AICompanion_Data.lua" and self.data_source is not None:
                    src = self.data_source
                self.M.loadFile(addon, "AddOns/%s/%s" % (addon, fname), src, ns)
            # The client reads Bindings.xml from the add-on's folder by itself (it is not in the .toc).
            bindings = os.path.join(ADDONS, addon, "Bindings.xml")
            if os.path.exists(bindings):
                for b in ET.parse(bindings).getroot().iter("Binding"):
                    self.M.addBinding(b.get("name"), b.get("header") or "", b.get("category") or "", (b.text or "").strip())
            for name in saved_names:
                if name in self.saved:
                    self.lua.execute(self.saved[name])
            self.M.fire("ADDON_LOADED", addon)
        self.M.fire("PLAYER_LOGIN")
        self.M.fire("PLAYER_ENTERING_WORLD", self.reloads == 0, self.reloads > 0)
        for event in ("BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE", "SPELLS_CHANGED"):
            self.M.fire(event)
        self.advance(6)
        return self

    # ------------------------------------------------------------------ actions

    def advance(self, seconds):
        self.M.advance(seconds)

    def fire(self, event, *args):
        self.M.fire(event, *args)

    def slash(self, text):
        """Type a slash command. If it asked for a reload, perform the reload."""
        self.M.slash(text)
        if self.M.reloadRequested:
            self.reload()

    def set(self, key, value):
        """Change the world while the client runs (the change is visible to the next game call)."""
        self.world[key] = value
        w = self.lua.globals().WORLD
        w[key] = self.lua.table_from(value, recursive=True) if isinstance(value, (dict, list)) else value

    def press_binding(self, name):
        """Press the key bound to a Key Bindings entry (a key press is a hardware event)."""
        self.M.pressBinding(name)

    def hover(self, item_id):
        """Show an item tooltip; return the lines the add-on added, as (left, right) pairs."""
        added = self.M.hover(item_id)
        return [(l.get("left"), l.get("right")) for l in to_py(added) or []]

    def _shutdown(self, data_present):
        """What the client does on reload or logout: tell add-ons, then write SavedVariables."""
        if not data_present:
            self.set("characterDataUnloaded", True)
        self.fire("PLAYER_LEAVING_WORLD")
        self.fire("PLAYER_LOGOUT")
        self.check_clean()
        for addon in self.addons():
            for name in toc_files(addon)[1]:
                value = self.lua.globals()[name]
                if value is not None:
                    self.saved[name] = self.M.serialize(name, value)
        self.check_clean()

    def reload(self):
        self._shutdown(data_present=True)
        self.reloads += 1
        self.start()

    def logout(self, countdown=20):
        """A real logout: the countdown starts, then character data unloads before add-ons hear."""
        self.fire("PLAYER_CAMPING")
        self.advance(countdown)
        self._shutdown(data_present=False)
        self.world.pop("characterDataUnloaded", None)
        self.lua = None

    def login(self):
        self.reloads = 0
        return self.start()

    # ------------------------------------------------------------------ inspection

    def db(self):
        """AICompanionDB as it is in memory right now."""
        return to_py(self.lua.globals().AICompanionDB)

    def disk(self):
        """AICompanionDB as the companion reads it from the SavedVariables file."""
        text = self.saved.get("AICompanionDB")
        if text is None:
            return None
        lua = lua51.LuaRuntime()
        lua.execute(text)
        return to_py(lua.globals().AICompanionDB)

    def char(self, source=None):
        db = source if source is not None else self.db()
        return db["characters"][self.world["character"]["name"] + "@" + self.world["character"]["realm"]]

    def chat(self):
        return list(to_py(self.M.chat) or [])

    def auction_queries(self):
        return to_py(self.M.auction.sent) or []

    def problems(self):
        return {
            "lua errors": to_py(self.M.errors) or [],
            "game would refuse": to_py(self.M.violations) or [],
            "stray globals": to_py(self.M.newGlobals) or [],
            "add-on event errors": [e for e in [(self.db() or {}).get("lastEventError")] if e],
            "item left on the cursor": ["yes"] if self.M.cursor is not None else [],
        }

    def check_clean(self):
        bad = {k: v for k, v in self.problems().items() if v}
        if bad:
            raise AssertionError("game reported problems: %r" % bad)
