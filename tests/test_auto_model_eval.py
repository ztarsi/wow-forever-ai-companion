"""The opt-in quality grader rejects unsafe/invalid plans; it never calls a model in CI."""
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "companion", "auto"))
from evaluate_models import grade, OTHER, SOURCE


def response():
    cases = []
    for name, action in (("later", "bank"), ("now", "craft"), ("unknown", "check")):
        cases.append({"id": name, "plan": {"sources": {"oldgame": copy.deepcopy(SOURCE)}, "characters": {
            "OtherTestchar": copy.deepcopy(OTHER), "Testchar": {
                "next": [{"id": "keep-step", "title": "Check Test Gloves", "tag": "unverified" if name == "unknown" else "game"}],
                "items": {"Test Leather": {"action": action, "tip": "Check Test Gloves.",
                    "note": "Missing ingredients; original-game reference unconfirmed for Forever."}}}}}})
    return {"cases": cases}


class ModelGrader(unittest.TestCase):
    def test_valid_plan_passes(self):
        self.assertEqual(grade(json.dumps(response()))["passed"], 22)

    def test_invalid_json_and_duplicate_cases_fail(self):
        self.assertEqual(grade("not json")["passed"], 0)
        value = response()
        value["cases"].append(value["cases"][0])
        self.assertEqual(grade(json.dumps(value))["passed"], 0)

    def test_immediate_craft_at_low_skill_fails(self):
        value = response()
        value["cases"][0]["plan"]["characters"]["Testchar"]["items"]["Test Leather"]["action"] = "craft"
        self.assertIn("later: correct action", grade(json.dumps(value))["failures"])

    def test_character_deletion_and_long_tooltip_fail(self):
        value = response()
        c = value["cases"][2]["plan"]["characters"]
        del c["OtherTestchar"]
        c["Testchar"]["items"]["Test Leather"]["tip"] = "x" * 49
        failures = grade(json.dumps(value))["failures"]
        self.assertIn("unknown: other character unchanged", failures)
        self.assertIn("unknown: short ASCII tooltip", failures)

    def test_original_game_source_cannot_be_promoted_to_verified(self):
        value = response()
        value["cases"][0]["plan"]["sources"]["oldgame"]["scope"] = "game"
        self.assertIn("later: source retained", grade(json.dumps(value))["failures"])

    def test_missing_uncertainty_tag_fails(self):
        value = response()
        value["cases"][2]["plan"]["characters"]["Testchar"]["next"][0]["tag"] = "game"
        self.assertIn("unknown: missing facts acknowledged", grade(json.dumps(value))["failures"])
