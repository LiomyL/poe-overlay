import json
import tempfile
import unittest
from pathlib import Path

from route_state import clear_checkpoint, read_checkpoint, replay_route_events, write_checkpoint


def checkpoint(**overrides):
    value = {
        "version": 2,
        "buildKey": "witch|league|None",
        "routeFingerprint": "route-sha256",
        "routeMode": "leaguestart",
        "bandit": "none",
        "act": 0,
        "step": 4,
        "areaId": "1_1_2",
        "previousAreaId": "1_1_town",
        "zone": "The Coast",
        "logStamp": "2026/10/28 20:50:00 000000012345",
        "recoveryTargetAreaId": "",
    }
    value.update(overrides)
    return value


class RouteStateTests(unittest.TestCase):
    def test_round_trip_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            write_checkpoint(path, checkpoint())
            self.assertEqual(read_checkpoint(path)["checkpoint"], checkpoint())

    def test_legacy_manual_cursor_migrates_to_primary_checkpoint_cursor(self):
        legacy_state = checkpoint(
            act=2,
            step=7,
            manualAct=0,
            manualStep=15,
            manualMode=True,
            recoveryTargetAreaId="1_1_2",
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            write_checkpoint(path, legacy_state)

            restored = read_checkpoint(path)["checkpoint"]

            self.assertEqual((restored["act"], restored["step"]), (0, 15))
            self.assertNotIn("manualAct", restored)
            self.assertNotIn("manualStep", restored)
            self.assertNotIn("manualMode", restored)
            self.assertEqual(restored["recoveryTargetAreaId"], "1_1_2")

    def test_checkpoint_v2_log_position_is_preserved(self):
        value = checkpoint(version=2, logStamp="2026/10/28 21:00:00 000000000123")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            write_checkpoint(path, value)

            restored = read_checkpoint(path)["checkpoint"]

            self.assertEqual(restored["version"], 2)
            self.assertEqual(restored["logStamp"], value["logStamp"])

    def test_selected_checkpoint_can_precede_first_log_timestamp(self):
        value = checkpoint(act=1, step=3, logStamp="")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            write_checkpoint(path, value)

            restored = read_checkpoint(path)["checkpoint"]

            self.assertEqual((restored["act"], restored["step"]), (1, 3))
            self.assertEqual(restored["logStamp"], "")

    def test_invalid_write_keeps_previous_durable_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            write_checkpoint(path, checkpoint())
            with self.assertRaises(ValueError):
                write_checkpoint(path, checkpoint(step=-2))
            self.assertEqual(read_checkpoint(path)["checkpoint"], checkpoint())

    def test_missing_checkpoint_is_a_clean_first_run(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                read_checkpoint(Path(directory) / "missing.json"),
                {"ok": True, "checkpoint": None},
            )

    def test_clear_checkpoint_removes_saved_route_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            write_checkpoint(path, checkpoint())

            self.assertEqual(clear_checkpoint(path), {"ok": True, "cleared": True})
            self.assertEqual(read_checkpoint(path), {"ok": True, "checkpoint": None})

    def test_version_one_checkpoint_migrates_without_manual_cursor_fields(self):
        legacy = checkpoint(version=1)
        for key in ("recoveryTargetAreaId", "manualAct", "manualStep", "manualMode"):
            legacy.pop(key, None)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.json"
            path.write_text(json.dumps(legacy), encoding="utf-8")

            migrated = read_checkpoint(path)["checkpoint"]

            self.assertEqual(migrated["version"], 2)
            self.assertEqual(migrated["recoveryTargetAreaId"], "")
            self.assertNotIn("manualMode", migrated)

    def test_log_replay_returns_only_new_area_events(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Client.txt"
            path.write_text(
                "2026/10/28 20:00:00 10 [DEBUG Client] Generating level 2 area \"old\"\n"
                "2026/10/28 20:00:01 20 [INFO Client] You have entered Old.\n"
                "2026/10/28 20:00:02 30 [INFO Client] chat line\n"
                "2026/10/28 20:00:03 40 [DEBUG Client] Generating level 4 area \"new\"\n"
                "2026/10/28 20:00:04 50 [INFO Client] You have entered New.\n",
                encoding="utf-8",
            )

            result = replay_route_events(path, "2026/10/28 20:00:01 000000000020")

            self.assertEqual(len(result["events"]), 2)
            self.assertTrue(result["checkpointFound"])
            self.assertIn('area "new"', result["events"][0])
            self.assertIn("You have entered New", result["events"][1])

    def test_log_replay_uses_file_order_after_checkpoint_across_clock_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Client.txt"
            path.write_text(
                "2026/10/28 23:59:58 900 [INFO Client] You have entered Coast.\n"
                "2026/10/28 00:01:00 10 ***** LOG FILE OPENING *****\n"
                "2026/10/28 00:01:02 30 [DEBUG Client] Generating level 13 area \"1_1_town\"\n"
                "2026/10/28 00:01:03 40 [INFO Client] You have entered Lioneye's Watch.\n",
                encoding="utf-8",
            )

            result = replay_route_events(path, "2026/10/28 23:59:58 000000000900")

            self.assertEqual(len(result["events"]), 3)
            self.assertIn("LOG FILE OPENING", result["events"][0])
            self.assertIn('area "1_1_town"', result["events"][1])
            self.assertIn("You have entered Lioneye's Watch", result["events"][2])

    def test_missing_checkpoint_anchor_does_not_replay_untrusted_history(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Client.txt"
            path.write_text(
                "2026/10/28 20:00:00 20 ***** LOG FILE OPENING *****\n"
                "2026/10/28 20:00:01 30 [DEBUG Client] Generating level 4 area \"new\"\n",
                encoding="utf-8",
            )

            result = replay_route_events(path, "2026/10/27 23:00:00 000000000010")

            self.assertFalse(result["checkpointFound"])
            self.assertEqual(result["events"], [])


if __name__ == "__main__":
    unittest.main()