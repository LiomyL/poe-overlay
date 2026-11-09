import json
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

from seed_passive_tree import (
    TREE_TAGS_URL,
    TREE_URLS,
    build_tree,
    tree_source_url,
    tree_url_from_tags,
)


class SeedPassiveTreeTests(unittest.TestCase):
    def test_selects_latest_stable_tag_for_requested_tree_version(self):
        tags = [
            {"name": "3.30.0-preview", "commit": {"sha": "a" * 40}},
            {"name": "3.30.0", "commit": {"sha": "b" * 40}},
            {"name": "3.30.2", "commit": {"sha": "c" * 40}},
            {"name": "3.31.0", "commit": {"sha": "d" * 40}},
        ]

        url = tree_url_from_tags("3_30", tags)

        self.assertEqual(
            url,
            f"https://raw.githubusercontent.com/grindinggear/skilltree-export/{'c' * 40}/data.json",
        )

    def test_missing_stable_tag_reports_unsupported_tree_version(self):
        with self.assertRaisesRegex(ValueError, "No stable GitHub tree tag"):
            tree_url_from_tags("3_30", [{"name": "3.30.0-preview"}])

    def test_unbundled_version_resolves_through_github_tags_api(self):
        tags = [{"name": "3.30.0", "commit": {"sha": "e" * 40}}]
        response = BytesIO(json.dumps(tags).encode("utf-8"))

        with patch("seed_passive_tree.urlopen", return_value=response) as open_url:
            url = tree_source_url("3_30")

        self.assertEqual(
            url,
            f"https://raw.githubusercontent.com/grindinggear/skilltree-export/{'e' * 40}/data.json",
        )
        self.assertEqual(open_url.call_args.args[0].full_url, TREE_TAGS_URL)

    def test_bundled_tree_data_covers_latest_five_supported_versions(self):
        tree_dir = Path(__file__).resolve().parents[1] / "routes" / "passive-tree"

        self.assertEqual(set(TREE_URLS), {"3_25", "3_26", "3_27", "3_28", "3_29"})
        for version in TREE_URLS:
            with self.subTest(version=version):
                tree = json.loads(
                    (tree_dir / f"{version}.json").read_text(encoding="utf-8")
                )
                self.assertTrue(tree["graphs"])
                self.assertTrue(tree["graphs"][0]["nodes"])

    def test_connections_are_built_after_all_nodes(self):
        raw_tree = {
            "classes": [{"name": "Duelist", "ascendancies": []}],
            "alternate_ascendancies": [],
            "groups": {
                "1": {"x": 0, "y": 0, "nodes": ["1", "2"]},
            },
            "nodes": {
                "1": {
                    "name": "Start",
                    "group": 1,
                    "orbit": 0,
                    "orbitIndex": 0,
                    "out": ["2"],
                },
                "2": {"name": "Life", "group": 1, "orbit": 0, "orbitIndex": 1},
            },
            "constants": {"skillsPerOrbit": [4], "orbitRadii": [10]},
        }

        tree = build_tree(raw_tree)

        self.assertEqual(len(tree["graphs"][0]["nodes"]), 2)
        self.assertEqual(
            tree["graphs"][0]["connections"],
            [{"a": "1", "b": "2", "s": {"w": "CW", "r": 10}}],
        )

    def test_proxy_groups_keep_jewel_sockets_but_skip_position_proxies(self):
        raw_tree = {
            "classes": [{"name": "Duelist", "ascendancies": []}],
            "alternate_ascendancies": [],
            "groups": {
                "1": {"x": 0, "y": 0, "nodes": ["1"]},
                "2": {"x": 100, "y": 0, "isProxy": True, "nodes": ["2", "3", "4"]},
            },
            "nodes": {
                "1": {
                    "name": "Large Jewel Socket",
                    "isJewelSocket": True,
                    "group": 1,
                    "orbit": 0,
                    "orbitIndex": 0,
                },
                "2": {
                    "name": "Medium Jewel Socket",
                    "isJewelSocket": True,
                    "expansionJewel": {"parent": "1"},
                    "group": 2,
                    "orbit": 0,
                    "orbitIndex": 0,
                    "out": ["3"],
                },
                "3": {
                    "name": "Medium Jewel Socket",
                    "isJewelSocket": True,
                    "expansionJewel": {"parent": "1"},
                    "group": 2,
                    "orbit": 0,
                    "orbitIndex": 1,
                },
                "4": {
                    "name": "Position Proxy",
                    "isProxy": True,
                    "group": 2,
                    "orbit": 0,
                    "orbitIndex": 2,
                },
            },
            "constants": {"skillsPerOrbit": [4], "orbitRadii": [10]},
        }

        tree = build_tree(raw_tree)
        nodes = tree["graphs"][0]["nodes"]

        self.assertIn("2", nodes)
        self.assertIn("3", nodes)
        self.assertNotIn("4", nodes)
        self.assertEqual(
            tree["graphs"][0]["connections"],
            [{"a": "2", "b": "3", "s": {"w": "CW", "r": 10}}],
        )


if __name__ == "__main__":
    unittest.main()
