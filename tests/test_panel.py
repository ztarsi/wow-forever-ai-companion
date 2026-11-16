"""The in-game companion panel (issue #2): plan content, self-ticking steps, minimap button."""

import json
import math
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import ROOT, Game, to_py  # noqa: E402
from test_addon import GameTest  # noqa: E402
import world as W  # noqa: E402

PLAN = {
    "roster": ["Testchar Test"],
    "sources": {
        "fsrc": {"label": "Forever site: page", "url": "https://example.com/forever"},
        "old": {"label": "Old wiki: page", "url": "https://example.com/classic", "scope": "classic"},
    },
    "characters": {"Testchar": {
        "headline": "Level 20 hunter. Finish Boar Trouble, then train.",
        "next": [
            {"id": "t-bow", "title": "Equip the Hunting Bow", "detail": "5.7 DPS.", "tag": "game", "done": {"equipped": "Hunting Bow"}},
            {"id": "t-boar", "title": "Finish Boar Trouble", "tag": "lookup", "source": "fsrc", "done": {"questDone": "Boar Trouble"}},
            {"id": "t-first", "title": "First Steps", "tag": "game", "done": {"questDone": "First Steps"}},
            {"id": "t-eat", "title": "Eat before the fight", "tag": "judgment"},
            {"id": "t-lw", "title": "Leatherworking 50", "tag": "game", "done": {"skill": ["Leatherworking", 50]}},
            {"id": "t-lw60", "title": "Leatherworking 60", "tag": "classic", "source": "old", "done": {"skill": ["Leatherworking", 60]}},
            {"id": "t-junk", "title": "Sell the fangs", "tag": "game", "done": {"notInBags": ["Broken Fang"]}},
            {"id": "t-all", "title": "Old bow and space", "tag": "game", "done": {"all": [{"equipped": "Worn Shortbow"}, {"freeSlots": 10}]}},
            {"id": "t-rec", "title": "Open Leatherworking", "tag": "game", "done": {"captured": "recipes:Leatherworking"}},
            {"id": "t-odd", "title": "A rule from a newer plan", "tag": "unverified", "done": {"somethingNew": 1}},
        ],
        "questing": [{"title": "Testvale", "note": "In this order.", "steps": [
            {"id": "q1", "title": "Boar Trouble", "tag": "lookup", "source": "fsrc", "done": {"questDone": "Boar Trouble"}}]}],
        "professions": {"Leatherworking": {"status": "50 of 75.", "next": "Train Journeyman in Testtown.", "tag": "classic", "source": "old"}},
        "gear": [{"id": "g1", "title": "Ranged: Hunting Bow", "tag": "game", "done": {"equipped": "Hunting Bow"}}],
        "talents": {"note": "5 points in Marksmanship.", "suggestion": "Next: Improved Concussive Shot.", "tag": "judgment"},
        "bags": "Two free slots in the pouch.",
        "blindspots": [{"text": "Open your Leatherworking window once.", "done": {"captured": "recipes:Leatherworking"}}],
        "items": {"Light Leather": {"action": "bank", "tip": "For Leatherworking 55+."}},
    }},
}


def data_file(plan=PLAN):
    d = tempfile.mkdtemp()
    src, out = os.path.join(d, "plans.json"), os.path.join(d, "AICompanion_Data.lua")
    with open(src, "w", encoding="utf-8") as f:
        json.dump(plan, f)
    subprocess.run([sys.executable, os.path.join(ROOT, "companion/gen_data.py"), src, out], check=True, capture_output=True)
    with open(out, encoding="utf-8") as f:
        return f.read()


OLD_DATA_FILE = '''AICompanionShopping = {}
AICompanionAdvice = { asOf = "Nov 1", characters = {} }
'''


class PanelTest(GameTest):
    def panel(self, g):
        return g.ns["AICompanion"].panel

    def model(self, g):
        return to_py(self.panel(g).currentModel()[0])

    def steps(self, g, section="next"):
        return {l["id"]: l for l in self.model(g)["sections"][section] if l.get("id")}

    def step_lines(self, g, section="next"):
        return [l for l in self.model(g)["sections"][section] if l.get("kind") == "step"]

    def open(self, g):
        g.slash("/aic panel")
        return g.lua.globals().AICompanionPanel


class Content(PanelTest):
    def test_steps_tick_themselves_from_the_snapshot(self):
        g = self.game(data_source=data_file())
        st = self.steps(g)
        done = {k: (v["auto"], v["done"]) for k, v in st.items()}
        self.assertEqual(done, {
            "t-bow": (True, False), "t-boar": (True, False), "t-first": (True, True), "t-eat": (False, False),
            "t-lw": (True, True), "t-lw60": (True, False), "t-junk": (True, False), "t-all": (True, True),
            "t-rec": (True, False), "t-odd": (False, False),
        })
        # open steps first in doing order, then the finished ones; numbers kept
        self.assertEqual([l["number"] for l in self.step_lines(g)], [1, 2, 4, 6, 7, 9, 10, 3, 5, 8])

    def test_cautions_in_plain_words(self):
        g = self.game(data_source=data_file())
        st = self.steps(g)
        self.assertEqual(st["t-lw60"]["caution"], "From the original game. Not confirmed for Forever.")
        self.assertEqual(st["t-odd"]["caution"], "Not verified yet.")
        for key in ("t-boar", "t-first", "t-eat"):          # Forever source, game data, judgment: nothing to say
            self.assertNotIn("caution", st[key])
        self.assertEqual(st["t-boar"]["source"], "Source: Forever site: page")
        self.assertEqual(st["t-lw60"]["source"], "Source: Old wiki: page")

    def test_an_original_game_source_gets_the_caution_whatever_the_tag(self):
        plan = json.loads(json.dumps(PLAN))
        plan["characters"]["Testchar"]["next"].append(
            {"id": "t-mixed", "title": "Train Journeyman", "tag": "lookup", "source": "old"})
        g = self.game(data_source=data_file(plan))
        self.assertEqual(self.steps(g)["t-mixed"]["caution"], "From the original game. Not confirmed for Forever.")

    def test_steps_update_as_you_play(self):
        g = self.game(data_source=data_file())
        self.assertFalse(self.steps(g)["t-bow"]["done"])
        w = g.world
        w["equipment"][18] = W.NEW_BOW
        g.set("equipment", w["equipment"])
        g.fire("PLAYER_EQUIPMENT_CHANGED")
        g.advance(6)
        self.assertTrue(self.steps(g)["t-bow"]["done"])
        self.assertFalse(self.steps(g)["t-all"]["done"])   # no longer wearing the old bow

    def test_captured_window_ticks_the_step_and_clears_the_blindspot(self):
        g = self.game(data_source=data_file())
        self.assertEqual(self.model(g)["blindspots"], ["Open your Leatherworking window once."])
        g.set("tradeSkill", {"profession": "Leatherworking", "recipes": [{"id": 1, "name": "Light Armor Kit"}]})
        g.fire("TRADE_SKILL_LIST_UPDATE")
        self.assertTrue(self.steps(g)["t-rec"]["done"])
        self.assertEqual(self.model(g).get("blindspots") or [], [])

    def test_other_sections(self):
        g = self.game(data_source=data_file())
        m = self.model(g)
        q = m["sections"]["questing"]
        self.assertEqual((q[0]["kind"], q[0]["title"], q[0]["detail"]), ("heading", "Testvale", "In this order."))
        self.assertEqual(q[1]["title"], "Boar Trouble")
        prof = m["sections"]["professions"]
        self.assertEqual(prof[0]["title"], "Leatherworking 50/75")
        self.assertEqual(prof[1]["title"], "Next: Train Journeyman in Testtown.")
        self.assertEqual((prof[1]["source"], prof[1]["caution"]), ("Source: Old wiki: page", "From the original game. Not confirmed for Forever."))
        self.assertFalse(m["sections"]["gear"][0]["done"])
        self.assertEqual(m["sections"]["talents"][0]["title"], "5 points in Marksmanship.")
        self.assertEqual(m["bagsNote"], "Two free slots in the pouch.")

    def test_items_grouped_by_action(self):
        g = self.game(data_source=data_file())
        groups = [(grp["action"], [i["name"] for i in grp["items"]]) for grp in self.model(g)["sections"]["items"]]
        self.assertEqual(groups, [
            ("sell", ["Broken Fang", "Linen Cloth"]),
            ("auction", ["Battleworn Plate Helm"]),
            ("bank", ["Light Leather", "Pattern: Fine Leather Belt"]),
            ("equip", ["Hunting Bow"]),
            ("carry", ["Hearthstone", "Roasted Boar Meat", "Rough Arrow"]),
        ])
        leather = next(i for grp in self.model(g)["sections"]["items"] for i in grp["items"] if i["name"] == "Light Leather")
        self.assertEqual((leather["note"], leather["rule"]), ("For Leatherworking 55+.", False))

    def test_no_plan_shows_rule_advice_only(self):
        g = self.game(data_source=OLD_DATA_FILE)       # a data file from before plans existed
        m = self.model(g)
        self.assertFalse(m["hasPlan"])
        self.assertIn("No plan for Testchar yet", m["headline"])
        self.assertEqual(m["sections"]["items"][0]["action"], "sell")
        self.assertTrue(m["sections"]["items"][0]["items"][0]["rule"])
        self.open(g)
        rows = to_py(g.lua.globals().AICompanionPanel.lastRows)
        self.assertEqual(rows[0]["text"], "No plan for this character yet.")

    def test_plan_for_another_character_is_not_shown(self):
        plan = json.loads(json.dumps(PLAN))
        plan["characters"] = {"Someoneelse": plan["characters"]["Testchar"]}
        g = self.game(data_source=data_file(plan))
        self.assertFalse(self.model(g)["hasPlan"])


class Window(PanelTest):
    def test_opens_and_closes(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        self.assertTrue(f.shown)
        rows = to_py(f.lastRows)
        self.assertEqual((rows[0]["style"], rows[0]["text"]), ("progress", "3 of 10 done"))
        self.assertEqual(rows[1]["text"], "1. Equip the Hunting Bow")
        self.assertTrue(rows[1]["isNext"])
        self.assertNotIn("sub", rows[1])                     # one line per step until clicked
        self.assertEqual(f.headline.text, "Level 20 hunter.")   # first sentence of the full headline
        self.assertTrue(f.footer.text.startswith("Snapshot "))
        self.assertNotIn("Bags", f.footer.text)
        g.slash("/aic panel")
        self.assertFalse(f.shown)

    def test_tabs(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        for key, first in (("questing", "Testvale"), ("professions", "Leatherworking 50/75"), ("gear", "Ranged: Hunting Bow"),
                           ("talents", "5 points in Marksmanship."), ("items", "Sell to vendor")):
            self.panel(g).select(key)
            self.assertEqual(to_py(f.lastRows)[0]["text"], first, key)

    def test_escape_closes_it(self):
        g = self.game(data_source=data_file())
        self.open(g)
        self.assertIn("AICompanionPanel", to_py(g.lua.globals().UISpecialFrames))

    def test_does_not_open_in_combat(self):
        g = self.game(data_source=data_file())
        g.set("inCombat", True)
        g.slash("/aic panel")
        self.assertTrue(any("opens after combat" in l for l in g.chat()))
        self.assertFalse(self.panel(g).isShown())

    def test_manual_tick_is_remembered_per_character(self):
        g = self.game(data_source=data_file())
        self.open(g)
        g.lua.execute("Mock.lastTicks = nil")
        model, ticks = self.panel(g).currentModel()
        ticks["t-eat"] = True
        self.assertTrue(self.steps(g)["t-eat"]["done"])
        g.slash("/aic save")
        self.assertTrue(self.steps(g)["t-eat"]["done"])
        self.assertTrue(g.disk()["panel"]["ticks"]["Testchar@Testrealm"]["t-eat"])

    def test_tick_box_click(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        g.lua.execute('''
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "CheckButton" and fr.shown and fr.enabled ~= false then
                    fr:SetChecked(true); fr.scripts.OnClick(fr); break
                end
            end''')
        self.assertTrue(self.steps(g)["t-eat"]["done"])

    def test_self_ticking_steps_cannot_be_ticked_by_hand(self):
        g = self.game(data_source=data_file())
        self.open(g)
        enabled = g.lua.eval('''(function()
            local n = 0
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "CheckButton" and fr.shown and fr.enabled ~= false then n = n + 1 end
            end
            return n end)()''')
        self.assertEqual(enabled, 2)   # "Eat before the fight" and the step with an unknown rule

    def test_position_and_size_are_remembered(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        g.lua.execute('''
            local f = AICompanionPanel
            f:SetSize(1000, 760); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -60)
            f.scripts.OnDragStop(f)''')
        g.slash("/aic save")
        f = self.open(g)
        self.assertEqual((f.width, f.height), (1000, 760))
        self.assertEqual(to_py(f.point)[2:], ["TOPLEFT", 40, -60])

    def test_refreshes_while_open(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        g.set("tradeSkill", {"profession": "Leatherworking", "recipes": [{"id": 1, "name": "Light Armor Kit"}]})
        g.fire("TRADE_SKILL_LIST_UPDATE")
        g.advance(6)
        row = next(r for r in to_py(f.lastRows) if r["text"].startswith("9."))
        self.assertTrue(row["done"])
        g.slash("/aic panel")
        g.advance(30)   # the refresh timer stops with the window


class MinimapButton(PanelTest):
    def button(self, g):
        return g.lua.globals().AICompanionMinimapButton

    def test_click_opens_the_panel(self):
        g = self.game(data_source=data_file())
        b = self.button(g)
        b.scripts.OnClick(b)
        self.assertTrue(self.panel(g).isShown())

    def test_drag_moves_it_around_the_minimap_and_is_remembered(self):
        g = self.game(data_source=data_file())
        b = self.button(g)
        g.lua.execute('''
            local b = AICompanionMinimapButton
            b.scripts.OnDragStart(b)
            Mock.cursorX, Mock.cursorY = 700, 600   -- straight above the minimap centre (700, 500)
            b.scripts.OnUpdate(b)
            b.scripts.OnDragStop(b)''')
        self.assertAlmostEqual(g.db()["panel"]["minimapAngle"], 90)
        self.assertIsNone(b.scripts.OnUpdate)
        g.slash("/aic save")
        p = to_py(self.button(g).point)
        self.assertEqual(p[0], "CENTER")
        self.assertAlmostEqual(p[3], 0, places=6)
        self.assertAlmostEqual(p[4], 75)    # on the edge: minimap radius 70, plus 5

    def test_default_position(self):
        g = self.game(data_source=data_file())
        p = to_py(self.button(g).point)
        self.assertLess(p[3], 0)
        self.assertLess(p[4], 0)   # lower left of the minimap until moved


class AddonMenu(PanelTest):
    def test_registers_when_the_client_has_the_menu(self):
        g = Game(W.world(), data_source=data_file())
        self.games.append(g)
        g.lua_prelude = '''AddonCompartmentFrame = M.widget("Frame", "AddonCompartmentFrame")
            function AddonCompartmentFrame:RegisterAddon(info) Mock.compartment = info end'''
        g.start()
        self.assertEqual(g.db()["panelCompartment"], "registered")
        info = g.M.compartment
        self.assertEqual(info["text"], "AI Companion")
        info["func"]()
        self.assertTrue(self.panel(g).isShown())

    def test_quiet_without_it(self):
        g = self.game(data_source=data_file())
        self.assertEqual(g.db()["panelCompartment"], "not available")

    def test_quiet_if_registration_fails(self):
        g = Game(W.world(), data_source=data_file())
        self.games.append(g)
        g.lua_prelude = '''AddonCompartmentFrame = M.widget("Frame", "AddonCompartmentFrame")
            function AddonCompartmentFrame:RegisterAddon() error("not supported") end'''
        g.start()
        self.assertEqual(g.db()["panelCompartment"], "not available")


class DataFile(PanelTest):
    def test_generator_writes_plans_in_plain_ascii(self):
        plan = json.loads(json.dumps(PLAN))
        plan["characters"]["Testchar"]["headline"] = "Go to Testtown — then “train” | now"
        text = data_file(plan)
        self.assertTrue(all(ord(c) < 128 for c in text))
        g = self.game(data_source=text)
        self.assertEqual(self.model(g)["headline"], 'Go to Testtown ,  then "train" / now')

    def test_example_plan_still_generates(self):
        with open(os.path.join(ROOT, "companion/plans.example.json"), encoding="utf-8") as f:
            text = data_file(json.load(f))
        self.assertIn("AICompanionPlans", text)


class Readability(PanelTest):
    """Issue #6: bigger, larger text, one line per step, nothing clipped or overlapping."""

    def test_default_size_fits_the_do_next_tab(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        self.assertEqual(f.width, 780)
        self.assertEqual(f.height, 200 + 16 * 28)            # 16 rows in Do next
        g.lua.execute('local f = AICompanionPanel f:SetSize(300, 200) f.scripts.OnDragStop(f)')
        self.assertEqual((g.db()["panel"]["width"], g.db()["panel"]["height"]), (560, 360))

    def test_default_size_limits(self):
        g = self.game(data_source=OLD_DATA_FILE)
        self.assertEqual(self.open(g).height, 360)          # no plan: the minimum
        plan = json.loads(json.dumps(PLAN))
        plan["characters"]["Testchar"]["next"] = [{"id": "s%d" % i, "title": "Step %d" % i} for i in range(60)]
        g = self.game(data_source=data_file(plan))
        self.assertEqual(self.open(g).height, 700)          # long plan: at most 700, then it scrolls

    def test_text_sizes(self):
        g = self.game(data_source=data_file())
        self.open(g)
        fonts = to_py(g.lua.eval('''(function()
            local out = {}
            for _, r in ipairs(Mock.regions) do
                if r.kind == "FontString" and not rawget(r, "fromTemplate") then out[#out + 1] = tostring(r.font) end
            end
            return out end)()'''))
        self.assertTrue(fonts)
        small = [f for f in fonts if "Small" in f or "Tiny" in f]
        self.assertEqual(small, [], "fonts below 12")
        self.assertIn("GameFontHighlightLarge", fonts)    # step titles

    def test_one_line_per_step_and_click_to_expand(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        rows = to_py(f.lastRows)
        self.assertTrue(all("sub" not in r for r in rows if r.get("check")))
        self.panel(g).expand("t-boar")
        rows = {r["key"]: r for r in to_py(f.lastRows)}
        self.assertEqual(rows["t-boar"]["sub"], "Source: Forever site: page")
        self.assertNotIn("sub", rows["t-bow"])
        self.panel(g).expand("t-bow")                    # only one open at a time
        rows = {r["key"]: r for r in to_py(f.lastRows)}
        self.assertEqual(rows["t-bow"]["sub"], "5.7 DPS.")
        self.assertNotIn("sub", rows["t-boar"])

    def test_clicking_a_row_toggles_it(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        click_first_step = '''
            local list
            for _, fr in ipairs(Mock.frames) do if fr.kind == "ScrollFrame" then list = fr.scrollChild end end
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and fr.parent == list and fr.shown and rawget(fr.title, "text") == "1. Equip the Hunting Bow" then
                    fr.scripts.OnClick(fr) break end
            end'''
        g.lua.execute(click_first_step)
        self.assertEqual(to_py(f.lastRows)[1]["sub"], "5.7 DPS.")
        g.lua.execute(click_first_step)
        self.assertNotIn("sub", to_py(f.lastRows)[1])

    def test_no_tags_in_any_list(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        for key in ("next", "questing", "professions", "gear", "talents", "items"):
            self.panel(g).select(key)
            self.assertEqual([r for r in to_py(f.lastRows) if "tag" in r], [], key)
        texts = " ".join(t for t in to_py(g.lua.eval('''(function() local o = {}
            for _, r in ipairs(Mock.regions) do if r.kind == "FontString" and rawget(r, "text") then o[#o + 1] = r.text end end
            return o end)()''')) if t)
        for word in ("Original", "Forever", "Judgment", "Unverified"):
            self.assertNotIn(">" + word, texts)
            self.assertNotIn(word + "|r", texts)

    def test_short_headline_wins(self):
        plan = json.loads(json.dumps(PLAN))
        plan["characters"]["Testchar"]["headlineShort"] = "Finish Boar Trouble, then train in Testtown."
        g = self.game(data_source=data_file(plan))
        f = self.open(g)
        self.assertEqual(f.headline.text, "Finish Boar Trouble, then train in Testtown.")

    def test_headline_never_more_than_two_lines(self):
        g = self.game(data_source=data_file())
        self.open(g)
        self.assertEqual(g.lua.eval("AICompanionPanel.headline.maxLines"), 2)

    def test_bags_and_blindspots_close_the_do_next_tab(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        texts = [r["text"] for r in to_py(f.lastRows)]
        self.assertEqual(texts[-4:], ["Bags", "Two free slots in the pouch.", "I can't see yet", "Open your Leatherworking window once."])

    def test_long_list_scrolls_with_bar_and_wheel(self):
        plan = json.loads(json.dumps(PLAN))
        plan["characters"]["Testchar"]["next"] = [{"id": "s%d" % i, "title": "Step %d" % i, "tag": "judgment"} for i in range(60)]
        g = self.game(data_source=data_file(plan))
        self.open(g)
        bar = g.lua.eval('''(function() for _, fr in ipairs(Mock.frames) do if fr.kind == "Slider" then return fr end end end)()''')
        sf = g.lua.eval('''(function() for _, fr in ipairs(Mock.frames) do if fr.kind == "ScrollFrame" then return fr end end end)()''')
        self.assertTrue(bar.shown)
        self.assertGreater(bar.max, 0)
        sf.scripts.OnMouseWheel(sf, -1)
        self.assertEqual((bar.value, sf.scrollY), (48, 48))
        sf.scripts.OnMouseWheel(sf, 5)
        self.assertEqual(sf.scrollY, 0)               # never scrolls above the top
        for _ in range(200):
            sf.scripts.OnMouseWheel(sf, -1)
        self.assertEqual(sf.scrollY, bar.max)         # nor past the end

    def test_short_list_has_no_scroll_bar(self):
        g = self.game(data_source=OLD_DATA_FILE)
        self.open(g)
        bar = g.lua.eval('''(function() for _, fr in ipairs(Mock.frames) do if fr.kind == "Slider" then return fr end end end)()''')
        self.assertFalse(bar.shown)

    def test_generator_refuses_a_long_short_headline(self):
        plan = json.loads(json.dumps(PLAN))
        plan["characters"]["Testchar"]["headlineShort"] = "x" * 101
        with self.assertRaises(subprocess.CalledProcessError):
            data_file(plan)


class RoundButton(PanelTest):
    """Issue #7: a round, ringed minimap button with a real icon."""

    def art(self, g):
        return to_py(g.lua.eval("AICompanionMinimapButton.art"))

    def test_ring_mask_icon_and_highlight(self):
        g = self.game(data_source=data_file())
        art = self.art(g)
        self.assertEqual(art["ring"], "Interface\\Minimap\\MiniMap-TrackingBorder")
        self.assertEqual(art["mask"], "Interface\\CharacterFrame\\TempPortraitAlphaMask")
        self.assertEqual(art["icon"], "Interface\\Icons\\INV_Misc_Book_09")
        b = g.lua.globals().AICompanionMinimapButton
        self.assertEqual(b.highlightTexture, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        self.assertEqual((b.width, b.height), (31, 31))

    def test_missing_icon_falls_back_to_a_real_one(self):
        w = W.world()
        w["missingFiles"] = {"Interface\\Icons\\INV_Misc_Book_09": True}
        g = self.game(w, data_source=data_file())
        self.assertEqual(self.art(g)["icon"], "Interface\\Icons\\INV_Misc_Book_11")

    def test_missing_ring_file_uses_the_modern_atlas(self):
        w = W.world()
        w["missingFiles"] = {"Interface\\Minimap\\MiniMap-TrackingBorder": True}
        g = self.game(w, data_source=data_file())
        self.assertEqual(self.art(g)["ring"], "ui-hud-minimap-button")

    def test_tooltip(self):
        g = self.game(data_source=data_file())
        b = g.lua.globals().AICompanionMinimapButton
        b.scripts.OnEnter(b)
        self.assertEqual(to_py(g.lua.globals().GameTooltip.lines), ["AI Companion", "Click: open the plan", "Drag: move this button"])

    def test_pressed_icon_shifts(self):
        g = self.game(data_source=data_file())
        b = g.lua.globals().AICompanionMinimapButton
        b.scripts.OnMouseDown(b)
        self.assertEqual(to_py(b.icon.point), ["CENTER", 1, -1])
        b.scripts.OnMouseUp(b)
        self.assertEqual(to_py(b.icon.point), ["CENTER"])

    def test_sits_above_the_minimap(self):
        g = self.game(data_source=data_file())
        self.assertTrue(g.lua.eval("AICompanionMinimapButton.parent == Minimap"))
        self.assertEqual(g.lua.eval("AICompanionMinimapButton.strata"), "MEDIUM")


class NativeWindow(PanelTest):
    """Issue #12: looks like part of the game."""

    def test_uses_the_clients_window_and_tabs(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        self.assertEqual(g.db()["panelFrame"], "ButtonFrameTemplate, native tabs")
        self.assertEqual(f.template, "ButtonFrameTemplate")
        self.assertEqual(f.title, "AI Companion \u00b7 Testchar")
        self.assertFalse(f.portraitShown)
        tabs = to_py(g.lua.eval("(function() local o = {} for i, t in ipairs(AICompanionPanel.Tabs) do o[i] = { t.template, t.text } end return o end)()"))
        self.assertEqual([t[0] for t in tabs], ["PanelTabButtonTemplate"] * 6)
        self.assertEqual([t[1] for t in tabs], ["Do next", "Questing", "Professions", "Gear", "Talents", "Items"])
        first = g.lua.eval("AICompanionPanel.Tabs[1].point")
        self.assertEqual((first[1], first[3]), ("TOPLEFT", "BOTTOMLEFT"))   # along the bottom edge
        self.assertTrue(g.lua.eval("AICompanionPanel.Tabs[1].selected"))
        self.panel(g).select("gear")
        self.assertTrue(g.lua.eval("AICompanionPanel.Tabs[4].selected"))
        self.assertFalse(g.lua.eval("AICompanionPanel.Tabs[1].selected"))

    def test_close_button_of_the_window(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        f.CloseButton.scripts.OnClick(f.CloseButton)
        self.assertFalse(f.shown)

    def test_falls_back_when_the_templates_are_missing(self):
        w = W.world()
        w["noFrameTemplates"] = True
        g = self.game(w, data_source=data_file())
        f = self.open(g)
        self.assertEqual(g.db()["panelFrame"], "plain, plain tabs")
        self.assertTrue(f.shown)
        self.assertEqual(to_py(f.lastRows)[1]["text"], "1. Equip the Hunting Bow")
        self.panel(g).select("items")
        self.assertEqual(to_py(f.lastRows)[0]["text"], "Sell to vendor")

    def test_next_step_stands_out_and_done_steps_recede(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        rows = to_py(f.lastRows)
        self.assertEqual([r["text"] for r in rows if r.get("isNext")], ["1. Equip the Hunting Bow"])
        styles = [r["style"] for r in rows]
        divider = styles.index("divider")
        self.assertEqual(rows[divider]["text"], "Done")
        self.assertTrue(all(r.get("done") for r in rows[divider + 1:divider + 4]))
        self.assertFalse(any(r.get("done") for r in rows[:divider]))
        shown = to_py(g.lua.eval('''(function() local o = {}
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and fr.bg and fr.shown and fr.bg.shown then o[#o + 1] = fr.title.text end
            end return o end)()'''))
        self.assertEqual(shown, ["1. Equip the Hunting Bow"])   # only the next step is highlighted

    def test_headings_are_never_larger_than_step_titles(self):
        g = self.game(data_source=data_file())
        self.open(g)
        fonts = to_py(g.lua.eval('''(function() local o = {}
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and fr.title and fr.shown then o[#o + 1] = { fr.title.text, fr.title.font, fr.title.wordWrap } end
            end return o end)()'''))
        by_text = {t: (font, wrap) for t, font, wrap in fonts}
        self.assertEqual(by_text["Bags"][0], "GameFontNormal")
        self.assertEqual(by_text["1. Equip the Hunting Bow"][0], "GameFontHighlightLarge")
        self.assertTrue(by_text["Two free slots in the pouch."][1])     # notes wrap, never cut off
        self.assertNotIn("GameFontNormalHuge", [f for _, f, _ in fonts])

    def row(self, g, text):
        """The row frame showing this title, as a Lua table."""
        return g.lua.eval('''(function(t)
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and rawget(fr, "title") and rawget(fr.title, "text") == t and fr.shown then return fr end
            end end)''')(text)

    def test_arrow_on_the_right_turns_down_when_open(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        r = self.row(g, "6. Leatherworking 60")
        self.assertEqual(r.arrow.texture, "Interface\\ChatFrame\\ChatFrameExpandArrow")
        self.assertEqual(r.arrow.point[1], "TOPRIGHT")
        self.assertEqual(r.arrow.rotation, 0)                       # pointing right: closed
        self.panel(g).expand("t-lw60")
        r = self.row(g, "6. Leatherworking 60")
        self.assertAlmostEqual(r.arrow.rotation, -math.pi / 2)      # pointing down: open
        row = next(x for x in to_py(f.lastRows) if x["key"] == "t-lw60")
        self.assertEqual(row["sub"], "From the original game. Not confirmed for Forever.\nSource: Old wiki: page")

    def test_arrow_falls_back_to_other_real_art(self):
        w = W.world()
        w["missingFiles"] = {"Interface\\ChatFrame\\ChatFrameExpandArrow": True}
        g = self.game(w, data_source=data_file())
        self.open(g)
        self.assertEqual(self.row(g, "6. Leatherworking 60").arrow.texture, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")

    def test_next_label_on_the_first_unfinished_step_only(self):
        g = self.game(data_source=data_file())
        self.open(g)
        shown = to_py(g.lua.eval('''(function() local o = {}
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and rawget(fr, "nextTag") and fr.shown and fr.nextTag.shown then o[#o + 1] = { fr.title.text, fr.nextTag.text } end
            end return o end)()'''))
        self.assertEqual(shown, [["1. Equip the Hunting Bow", "Next"]])

    def test_do_next_tab_matches_the_mockup_order(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        rows = to_py(f.lastRows)
        styles = [r["style"] for r in rows]
        texts = [r["text"] for r in rows]
        self.assertEqual(styles[0], "progress")
        divider = styles.index("divider")
        self.assertTrue(all(st == "step" and not r.get("done") for st, r in zip(styles[1:divider], rows[1:divider])))
        self.assertEqual(texts[divider], "Done")
        done = [r for r in rows[divider + 1:] if r["style"] == "step"]
        self.assertTrue(done and all(r.get("done") for r in done))
        self.assertEqual(texts[-4:], ["Bags", "Two free slots in the pouch.", "I can't see yet", "Open your Leatherworking window once."])

    def test_footer(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        self.assertRegex(f.footer.text, r"^Snapshot today \d\d:\d\d \u00b7 Plan \w+ \d+$")
        footer = self.panel(g).footer
        self.assertEqual(footer("2026-11-14 17:44:10", "Nov 14", "2026-11-15"), "Snapshot 2026-11-14 17:44 \u00b7 Plan Nov 14")
        self.assertEqual(footer(None, None, "2026-11-15"), "No snapshot yet")


class FitsAtEveryWidth(PanelTest):
    """Owner feedback on #23: tabs never pass the window's edge, and nothing is cut off, at any allowed width."""

    def tabs_right_edge(self, g):
        r = to_py(g.lua.eval('''(function()
            local f = AICompanionPanel
            local first = f.Tabs[1].point
            local x = first[4] or 0
            for i, t in ipairs(f.Tabs) do x = x + (t.width or 0) if i > 1 then x = x + 3 end end
            return { x, f.width } end)()'''))
        return r[0], r[1]

    def at_minimum(self, g):
        g.lua.execute('local f = AICompanionPanel f:SetSize(300, 200) f.scripts.OnSizeChanged(f) f.scripts.OnDragStop(f)')
        self.panel(g).render()

    def test_tabs_fit_at_minimum_width(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        self.at_minimum(g)
        self.assertEqual(g.db()["panel"]["width"], 560)
        right, width = self.tabs_right_edge(g)
        self.assertLessEqual(right, width - 11)

    def test_tabs_shrink_to_fit_when_their_text_is_large(self):
        w = W.world()
        w["tabCharWidth"] = 14            # a large UI scale or font: natural tabs would be ~730 wide
        g = self.game(w, data_source=data_file())
        self.open(g)
        self.at_minimum(g)
        right, width = self.tabs_right_edge(g)
        self.assertLessEqual(right, width - 11)
        widths = to_py(g.lua.eval("(function() local o = {} for i, t in ipairs(AICompanionPanel.Tabs) do o[i] = t.width end return o end)()"))
        self.assertEqual(len(set(widths)), 1)   # shared evenly

    def test_tabs_get_their_natural_width_when_there_is_room(self):
        g = self.game(data_source=data_file())
        self.open(g)
        widths = to_py(g.lua.eval("(function() local o = {} for i, t in ipairs(AICompanionPanel.Tabs) do o[i] = t.width end return o end)()"))
        self.assertEqual(widths, [len(t) * 7 + 20 for t in ("Do next", "Questing", "Professions", "Gear", "Talents", "Items")])

    def test_fallback_buttons_fit_at_minimum_width(self):
        w = W.world()
        w["noFrameTemplates"] = True
        g = self.game(w, data_source=data_file())
        self.open(g)
        self.at_minimum(g)
        right, width = self.tabs_right_edge(g)
        self.assertLessEqual(right, width - 11)

    def test_size_saved_by_an_older_version_is_brought_within_limits(self):
        g = self.game(data_source=data_file())
        g.lua.execute("AICompanionDB.panel = { width = 300, height = 2400, ticks = {} }")
        f = self.open(g)
        self.assertEqual((f.width, f.height), (560, 1200))
        self.assertEqual((g.db()["panel"]["width"], g.db()["panel"]["height"]), (560, 1200))

    def test_nothing_is_cut_off_at_minimum_width(self):
        g = self.game(data_source=data_file())
        self.open(g)
        self.at_minimum(g)
        rows = to_py(g.lua.eval('''(function() local o = {}
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and rawget(fr, "title") and fr.shown then
                    o[#o + 1] = { fr.title.text, fr.title.wordWrap == true, fr.title.width or 0, rawget(fr.title, "maxLines") or 0 }
                end
            end return o end)()'''))
        by_text = {r[0]: r for r in rows}
        note = by_text["Two free slots in the pouch."]
        self.assertTrue(note[1])                        # wraps instead of "..."
        self.assertGreater(note[2], 100)
        self.assertLessEqual(note[2], 560 - 2 * 14)     # inside the window's margins
        self.assertTrue(by_text["Open your Leatherworking window once."][1])
        self.assertEqual([r[0] for r in rows if r[3] == 1], [])   # nothing limited to one line


class KeyBinding(PanelTest):
    """Issue #25: a Key Bindings entry that opens and closes the panel."""

    BINDING = "AICOMPANION_TOGGLE_PANEL"

    def test_key_bindings_screen_entry(self):
        g = self.game(data_source=data_file())
        b = g.M.bindings[self.BINDING]
        self.assertEqual((b.header, b.category), ("AICOMPANION", "ADDONS"))
        self.assertEqual(g.lua.globals().BINDING_HEADER_AICOMPANION, "AI Companion")
        # The game may show no heading above an add-on's binding, so the line itself names the add-on.
        self.assertEqual(g.lua.globals()["BINDING_NAME_" + self.BINDING], "AI Companion: open or close the panel")

    def test_key_opens_and_closes_the_panel(self):
        g = self.game(data_source=data_file())
        g.press_binding(self.BINDING)
        self.assertTrue(self.panel(g).isShown())
        g.press_binding(self.BINDING)
        self.assertFalse(self.panel(g).isShown())

    def test_key_does_not_open_the_panel_in_combat(self):
        g = self.game(data_source=data_file())
        g.set("inCombat", True)
        g.press_binding(self.BINDING)
        self.assertFalse(self.panel(g).isShown())
        self.assertTrue(any("opens after combat" in l for l in g.chat()))

    def test_escape_still_closes_it(self):
        g = self.game(data_source=data_file())
        g.press_binding(self.BINDING)
        self.assertIn("AICompanionPanel", to_py(g.lua.globals().UISpecialFrames))

    def test_loads_cleanly_with_no_key_set(self):
        g = self.game(data_source=data_file())               # tearDown checks for errors and stray globals
        b = g.lua.globals().AICompanionMinimapButton
        b.scripts.OnEnter(b)
        self.assertEqual(to_py(g.lua.globals().GameTooltip.lines)[1], "Click: open the plan")

    def test_tooltip_shows_the_chosen_key(self):
        w = W.world()
        w["bindings"] = {self.BINDING: "SHIFT-P"}
        g = self.game(w, data_source=data_file())
        b = g.lua.globals().AICompanionMinimapButton
        b.scripts.OnEnter(b)
        self.assertEqual(to_py(g.lua.globals().GameTooltip.lines)[1], "Click or press Shift-P: open the plan")


class FeedbackButton(PanelTest):
    """The panel has a way to report a problem or give feedback."""

    def test_feedback_button_opens_the_feedback_window(self):
        g = self.game(data_source=data_file())
        f = self.open(g)
        b = f.feedbackButton
        self.assertEqual(b.text, "Feedback")
        self.assertTrue(g.lua.eval("AICompanionPanel.feedbackButton.parent ~= nil"))
        b.scripts.OnClick(b)
        self.assertTrue(g.lua.globals().AICompanionFeedbackFrame.shown)
        self.assertEqual(g.lua.eval("AICompanionFeedbackFrame.strata"), "FULLSCREEN_DIALOG")   # above the panel
        self.assertEqual(f.strata, "DIALOG")

LONG_NEXT = ("You carry 13 Wool Cloth. The First Aid trainer listed Wool Bandage at 80; "
             "make Heavy Linen Bandage until then, at Testtown 52.1, 47.3, and buy the Expert book at 125.")


class LongLines(PanelTest):
    """A line too long for one row can always be read in full: click opens it, hover shows it."""

    def plan(self):
        import copy
        plan = copy.deepcopy(PLAN)
        c = plan["characters"]["Testchar"]
        c["professions"] = {"First Aid": {"status": "66 of 150.", "next": LONG_NEXT, "tag": "game"}}
        c["next"].append({"id": "t-short", "title": "Hearth home", "tag": "game"})
        return plan

    def row(self, g, starts):
        return g.lua.eval('''(function(prefix)
            for _, fr in ipairs(Mock.frames) do
                if fr.kind == "Button" and fr.title and fr.shown and type(rawget(fr.title, "text")) == "string"
                   and rawget(fr.title, "text"):sub(1, #prefix) == prefix then return fr end
            end end)''')(starts)

    def test_long_line_opens_on_click(self):
        g = self.game(data_source=data_file(self.plan()))
        f = self.open(g)
        self.panel(g).select("professions")
        r = self.row(g, "Next: You carry 13 Wool Cloth")
        self.assertTrue(r.arrow.shown, "a cut-off line gets the arrow, so it can be opened")
        self.assertFalse(r.sub.shown)
        r.scripts.OnClick(r)
        r = self.row(g, "Next: You carry 13 Wool Cloth")
        self.assertTrue(r.sub.shown)
        self.assertEqual(r.sub.text, "Next: " + LONG_NEXT)
        r.scripts.OnClick(r)
        self.assertFalse(self.row(g, "Next: You carry 13 Wool Cloth").sub.shown)

    def test_long_line_shows_in_full_on_hover(self):
        g = self.game(data_source=data_file(self.plan()))
        self.open(g)
        self.panel(g).select("professions")
        r = self.row(g, "Next: You carry 13 Wool Cloth")
        r.scripts.OnEnter(r)
        self.assertEqual(to_py(g.lua.globals().GameTooltip.lines)[0], "Next: " + LONG_NEXT)
        r.scripts.OnLeave(r)

    def test_full_text_comes_before_the_details(self):
        plan = self.plan()
        plan["characters"]["Testchar"]["professions"]["First Aid"]["source"] = "fsrc"
        g = self.game(data_source=data_file(plan))
        self.open(g)
        self.panel(g).select("professions")
        r = self.row(g, "Next: You carry 13 Wool Cloth")
        r.scripts.OnClick(r)
        r = self.row(g, "Next: You carry 13 Wool Cloth")
        self.assertEqual(r.sub.text, "Next: " + LONG_NEXT + "\nSource: Forever site: page")

    def test_short_line_without_details_does_not_open(self):
        g = self.game(data_source=data_file(self.plan()))
        self.open(g)
        r = self.row(g, "11. Hearth home")
        self.assertFalse(r.arrow.shown)
        r.scripts.OnClick(r)
        self.assertFalse(self.row(g, "11. Hearth home").sub.shown)

