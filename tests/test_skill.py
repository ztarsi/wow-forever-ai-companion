"""Checks companion/SKILL.md, the one document every assistant follows.

The gameplay rules, the working loop and the file formats live only there. The per-assistant
guides point to it. These tests fail when the skill loses its front matter or a required part,
names a tool that is not in its folder, carries personal data, or when its rules are copied into
another file, where the two copies would drift apart.
"""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import ROOT  # noqa: E402

COMPANION = os.path.join(ROOT, "companion")
SKILL = os.path.join(COMPANION, "SKILL.md")
GUIDES = ("CLAUDE_GUIDE.md", "CODEX_GUIDE.md")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def front_matter(text):
    m = re.match(r"---\n(.*?)\n---\n", text, flags=re.S)
    if not m:
        return None
    fields = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        fields[k.strip()] = v.strip()
    return fields


def sections(text):
    """Level-two headings in order, and the text under each."""
    parts = re.split(r"^## (.+)$", text, flags=re.M)
    return [(parts[i].strip(), parts[i + 1]) for i in range(1, len(parts), 2)]


def other_markdown():
    """Every Markdown file in the repository except the skill itself."""
    out = {}
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "__pycache__")]
        for name in files:
            path = os.path.join(base, name)
            if name.endswith(".md") and os.path.abspath(path) != os.path.abspath(SKILL):
                out[os.path.relpath(path, ROOT)] = read(path)
    return out


def rule_sentences(rules_text):
    """The sentences of every rule, without the bold titles: what a copy would repeat."""
    body = re.sub(r"\*\*[^*]+\*\*", "", rules_text)
    out = []
    for line in body.splitlines():
        line = re.sub(r"^\s*(\d+\.|-)\s*", "", line).strip()
        for sentence in re.split(r"(?<=[.!?])\s+", line):
            if len(sentence) >= 40:
                out.append(sentence)
    return out


class SkillFile(unittest.TestCase):
    def setUp(self):
        self.text = read(SKILL)
        self.sections = sections(self.text)

    def test_front_matter_names_the_skill_and_says_when_to_use_it(self):
        fields = front_matter(self.text)
        self.assertIsNotNone(fields, "SKILL.md must start with front matter between --- lines")
        self.assertRegex(fields.get("name", ""), r"^[a-z0-9]+(-[a-z0-9]+)*$")
        self.assertLessEqual(len(fields["name"]), 64)
        description = fields.get("description", "")
        self.assertTrue(0 < len(description) <= 1024, "description must be 1 to 1024 characters")
        self.assertNotRegex(description, r"[<>]")
        for trigger in ("Forever", "AI Companion", "snapshot", "plans.json", "refresh", "/aic save"):
            self.assertIn(trigger, description)

    def test_parts_come_in_order_with_the_changelog_last(self):
        self.assertEqual([title for title, _ in self.sections], ["Rules", "Working loop", "Reference", "Changelog"])

    def test_every_required_rule_is_there(self):
        rules = dict(self.sections)["Rules"]
        titles = re.findall(r"^\d+\. \*\*(.+?)\*\*", rules, flags=re.M)
        for needed in ("Forever only", "The game wins", "Label every source", "concrete and immediate",
                       "coordinates", '"you"', "where the player is standing", "Verify absence two ways",
                       "does not run commands"):
            self.assertTrue(any(needed in t for t in titles), "no rule about %r" % needed)
        numbers = [int(n) for n in re.findall(r"^(\d+)\. \*\*", rules, flags=re.M)]
        self.assertEqual(numbers, list(range(1, len(numbers) + 1)), "rules must be numbered 1, 2, 3 ...")

    def test_working_loop_has_every_step(self):
        loop = dict(self.sections)["Working loop"]
        steps = re.findall(r"^\d+\. \*\*(.+?)\*\*", loop, flags=re.M)
        self.assertEqual([s.rstrip(".") for s in steps],
                         ["Read the save", "Research", "Write `plans.json`", "Generate", "Verify the write", "Reply"])
        self.assertIn("The first line says", loop)
        self.assertIn("/reload", loop)
        self.assertIn("full restart", loop)

    def test_every_active_quest_is_placed_before_ordering(self):
        """Issue #37: no active quest is left out because the plan grouped it elsewhere."""
        rules = dict(self.sections)["Rules"]
        rule10 = rules[rules.index("10. **Order steps"):rules.index("11. **")]
        for needed in ("Place every active quest on the map before ordering", "`snapshot.quests`",
                       "not from quest level", "`questing` groups are by place", "Before replying, check the count"):
            self.assertIn(needed, rule10)
        loop = dict(self.sections)["Working loop"]
        self.assertIn("List every active quest with the place of its next objective before ordering (rule 10).", loop)

    def test_example_plan_groups_quests_by_area(self):
        import json
        with open(os.path.join(COMPANION, "plans.example.json"), encoding="utf-8") as f:
            plan = json.load(f)
        for name, c in plan["characters"].items():
            for g in c.get("questing", []):
                self.assertRegex(g["title"], r"^(In|Around|At|Near) ", "%s: questing groups are titled by area" % name)

    def test_tools_it_names_travel_with_it(self):
        for name in ("gen_data.py", "build.py", "template.html", "plans.example.json"):
            self.assertIn("`%s`" % name, self.text)
            self.assertTrue(os.path.isfile(os.path.join(COMPANION, name)), "%s is not beside SKILL.md" % name)
        for name in set(re.findall(r"\b([\w.-]+\.(?:py|html))\b", self.text)):
            if name != "index.html":
                self.assertTrue(os.path.isfile(os.path.join(COMPANION, name)), "SKILL.md names %s, not beside it" % name)
        self.assertNotIn("companion/", self.text, "paths are relative to the skill's own folder")

    def test_no_personal_data(self):
        self.assertNotRegex(self.text, r"[\w.+-]+@[\w-]+\.[\w.]+", "an email address")
        self.assertNotRegex(self.text, r"(?i)[a-z]:\\users\\|/users/|/home/", "a path with a user name")
        self.assertEqual(set(re.findall(r"[\w<>]+@[\w<>]+", self.text)), {"<Name>@<Realm>"},
                         "character keys appear only as the <Name>@<Realm> placeholder")
        account = re.findall(r"WTF/Account/([^/`\s]+)", self.text)
        self.assertTrue(all(a == "<account>" for a in account), "an account name: %r" % account)
        for made_up_in_tests in ("Testchar", "Testrealm"):
            self.assertNotIn(made_up_in_tests, self.text)


class OneSourceOfTruth(unittest.TestCase):
    def setUp(self):
        self.text = read(SKILL)
        self.parts = dict(sections(self.text))
        self.others = other_markdown()

    def test_rules_are_not_copied_into_another_file(self):
        copies = {}
        for sentence in rule_sentences(self.parts["Rules"]):
            for path, text in self.others.items():
                if sentence in text:
                    copies.setdefault(path, []).append(sentence[:60])
        self.assertEqual(copies, {}, "SKILL.md rules repeated elsewhere; point to SKILL.md instead")

    def test_formats_are_not_copied_into_another_file(self):
        markers = ["characters[\"<Name>@<Realm>\"]", "| `equip` | Equip now |", "`tag` is one of:",
                   "Recipe entries carry `name`, `learned`, `difficulty`"]
        for marker in markers:
            self.assertIn(marker, self.text)
            where = [p for p, t in self.others.items() if marker in t]
            self.assertEqual(where, [], "%r is copied into %s" % (marker, where))

    def test_guides_point_to_the_skill(self):
        for name in GUIDES:
            guide = read(os.path.join(COMPANION, name))
            self.assertIn("](SKILL.md)", guide, "%s must link to SKILL.md" % name)
            self.assertNotRegex(guide, r"(?m)^## \d+\. ", "%s still has numbered rule sections" % name)
            self.assertEqual(sections(guide)[-1][0], "Changelog", "%s: changelog last" % name)

    def test_automatic_updates_follow_the_skill(self):
        """companion/auto hands the unattended run one guide: it must be SKILL.md, not a pointer."""
        core = read(os.path.join(COMPANION, "auto", "core.py"))
        named = set(re.findall(r'"([\w.-]+\.md)"', core))
        self.assertEqual(named, {"SKILL.md"}, "the automatic run must be given SKILL.md")

    def test_entry_points_name_the_skill(self):
        self.assertIn("companion/SKILL.md", read(os.path.join(ROOT, "AGENTS.md")))
        readme = read(os.path.join(ROOT, "README.md"))
        self.assertIn("### Give your assistant the skill", readme)
        self.assertIn("companion/SKILL.md", readme)


if __name__ == "__main__":
    unittest.main()
