import json
import tempfile
import unittest
from pathlib import Path

from load_route import load_route


class LoadRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.route_dir = Path(self.temp_dir.name)
        areas = {
            "1_1_1": {"id": "1_1_1", "name": "Strand", "act": 1},
            "1_1_town": {
                "id": "1_1_town",
                "name": "Lioneye's Watch",
                "act": 1,
                "is_town_area": True,
            },
            "1_1_2": {"id": "1_1_2", "name": "Coast", "act": 1},
            "1_1_3": {"id": "1_1_3", "name": "Mud Flats", "act": 1},
        }
        (self.route_dir / "areas.json").write_text(json.dumps(areas), encoding="utf-8")
        for act in range(1, 11):
            route = f"#section Act {act}\n"
            if act == 1:
                route += (
                    "Find Hillock\n"
                    "➞ {enter|1_1_town}\n"
                    "Hand in {quest_text|Enemy at the Gate}\n"
                    "➞ {enter|1_1_2}\n"
                    "#ifdef LEAGUE_START\n"
                    "    Get {waypoint_get}\n"
                    "#endif\n"
                    "➞ {enter|1_1_3}\n"
                    "    #sub Follow the river\n"
                )
            (self.route_dir / f"act-{act}.txt").write_text(route, encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_actions_are_grouped_with_the_next_zone_transition(self):
        route = load_route(self.route_dir, "leaguestart", "None", True)
        rows = route["sections"][0]["rows"]

        self.assertEqual(len(route["sections"]), 10)
        self.assertEqual(rows[1]["destinationAreaId"], "1_1_2")
        self.assertEqual(
            [line["text"] for line in rows[2]["lines"]],
            [
                "Get (img:waypoint)",
                "→ enter areaid1_1_3 ;; Mud Flats",
                "Follow the river",
            ],
        )

    def test_twinkrun_skips_league_start_only_actions(self):
        route = load_route(self.route_dir, "twinkrun", "None", True)
        rows = route["sections"][0]["rows"]

        self.assertEqual(rows[2]["destinationAreaId"], "1_1_3")
        self.assertFalse(any("waypoint" in line["text"] for line in rows[2]["lines"]))

    def test_route_fingerprint_changes_when_author_updates_route(self):
        first = load_route(self.route_dir, "leaguestart", "None", True)["fingerprint"]
        act_one = self.route_dir / "act-1.txt"
        act_one.write_text(
            act_one.read_text(encoding="utf-8") + "Updated hint\n", encoding="utf-8"
        )
        second = load_route(self.route_dir, "leaguestart", "None", True)["fingerprint"]

        self.assertNotEqual(first, second)

    def test_upstream_route_files_load_in_all_modes_and_bandit_choices(self):
        upstream_routes = Path(__file__).resolve().parents[1] / "routes"
        areas = json.loads((upstream_routes / "areas.json").read_text(encoding="utf-8"))
        modes = ("leaguestart", "twinkrun")
        bandits = ("None", "Oak", "Kraityn", "Alira")

        for mode in modes:
            for bandit in bandits:
                with self.subTest(mode=mode, bandit=bandit):
                    route = load_route(upstream_routes, mode, bandit, True)
                    self.assertEqual(len(route["sections"]), 10)
                    self.assertEqual(len(route["fingerprint"]), 64)
                    destinations = [
                        row["destinationAreaId"]
                        for section in route["sections"]
                        for row in section["rows"]
                        if row["destinationAreaId"]
                    ]
                    self.assertTrue(all(area_id in areas for area_id in destinations))
                    self.assertFalse(
                        any(
                            "{" in line["text"]
                            for section in route["sections"]
                            for row in section["rows"]
                            for line in row["lines"]
                        )
                    )

    def test_bandit_choice_selects_the_matching_act_two_route(self):
        routes = Path(__file__).resolve().parents[1] / "routes"

        def act_two_text(bandit):
            route = load_route(routes, "leaguestart", bandit, True)
            return "\n".join(
                line["text"]
                for row in route["sections"][1]["rows"]
                for line in row["lines"]
            )

        self.assertIn("Kill Alira Darktongue", act_two_text("none"))
        self.assertIn("Help Alira Darktongue", act_two_text("alira"))
        self.assertIn("Help Kraityn, Scarbearer", act_two_text("kraityn"))
        self.assertIn("Find and help Oak, Skullbreaker", act_two_text("oak"))


if __name__ == "__main__":
    unittest.main()
