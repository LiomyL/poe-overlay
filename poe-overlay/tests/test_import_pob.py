import base64
import struct
import unittest
import zlib

from import_pob import parse_build, validate_overlay_state


def export_code(xml: str) -> str:
    return base64.b64encode(zlib.compress(xml.encode("utf-8"))).decode("ascii")


class ParseBuildTests(unittest.TestCase):
    def test_excludes_disabled_gems_and_disabled_skill_groups(self):
        code = export_code(
            """<PathOfBuilding>
<Build className="Witch" level="1" />
<Skills activeSkillSet="1">
  <SkillSet id="1" title="Main">
    <Skill enabled="true" label="Active">
      <Gem nameSpec="Fireball" gemId="fireball" enabled="true" />
      <Gem nameSpec="Frostblink" gemId="frostblink" enabled="false" />
    </Skill>
    <Skill enabled="false" label="Disabled group">
      <Gem nameSpec="Arc" gemId="arc" enabled="true" />
    </Skill>
  </SkillSet>
</Skills>
</PathOfBuilding>"""
        )

        build = parse_build(code)

        self.assertEqual(build["parserVersion"], 4)
        self.assertEqual(
            [gem["name"] for gem in build["skillSets"][0]["gems"]], ["Fireball"]
        )

    def test_missing_gem_enabled_attribute_defaults_to_enabled(self):
        code = export_code(
            """<PathOfBuilding>
<Build className="Witch" />
<Skills><SkillSet id="1"><Skill><Gem nameSpec="Raise Zombie" gemId="zombie" /></Skill></SkillSet></Skills>
</PathOfBuilding>"""
        )

        build = parse_build(code)

        self.assertEqual(build["skillSets"][0]["gems"][0]["name"], "Raise Zombie")

    def test_extracts_ordered_tree_specs_and_allocated_masteries(self):
        tree_url = (
            struct.pack(">I", 6)
            + bytes((1, 2, 2))
            + struct.pack(">HH", 100, 200)
            + bytes((0, 1))
            + struct.pack(">HH", 12, 100)
        )
        encoded_tree_url = base64.urlsafe_b64encode(tree_url).decode().rstrip("=")
        code = export_code(
            f"""<PathOfBuilding>
<Build className="Witch" level="1" />
<Tree activeSpec="2">
  <Spec title="Act 1" treeVersion="3_29"><URL>https://www.pathofexile.com/passive-skill-tree/{encoded_tree_url}</URL></Spec>
  <Spec title="Act 2" treeVersion="3_29"><URL>https://www.pathofexile.com/passive-skill-tree/{encoded_tree_url}</URL></Spec>
</Tree>
<Skills><SkillSet id="1"><Skill><Gem nameSpec="Fireball" gemId="fireball" /></Skill></SkillSet></Skills>
</PathOfBuilding>"""
        )

        build = parse_build(code)

        self.assertEqual(build["activeTreeSpec"], "2")
        self.assertEqual(
            [tree["title"] for tree in build["treeSpecs"]], ["Act 1", "Act 2"]
        )
        self.assertEqual(build["treeSpecs"][0]["version"], "3_29")
        self.assertEqual(build["treeSpecs"][0]["nodes"], ["100", "200"])
        self.assertEqual(build["treeSpecs"][0]["masteries"], {"100": "12"})

    def test_overlay_state_accepts_known_manual_bandit_choices(self):
        for bandit in ("auto", "none", "oak", "kraityn", "alira"):
            with self.subTest(bandit=bandit):
                self.assertEqual(
                    validate_overlay_state({"enabled": True, "bandit": bandit})[
                        "bandit"
                    ],
                    bandit,
                )

    def test_overlay_state_defaults_missing_bandit_to_auto(self):
        self.assertEqual(validate_overlay_state({"enabled": True})["bandit"], "auto")

    def test_overlay_state_preserves_game_log_path(self):
        state = validate_overlay_state(
            {"enabled": True, "logPath": "/games/poe/Client.txt"}
        )

        self.assertEqual(state["logPath"], "/games/poe/Client.txt")

    def test_overlay_state_rejects_non_string_game_log_path(self):
        with self.assertRaisesRegex(ValueError, "game log path"):
            validate_overlay_state({"enabled": True, "logPath": 123})

    def test_overlay_state_rejects_unknown_bandit(self):
        with self.assertRaises(ValueError):
            validate_overlay_state({"enabled": True, "bandit": "unknown"})


if __name__ == "__main__":
    unittest.main()
