#!/usr/bin/env python3
"""Read and atomically persist the campaign route checkpoint."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

LOG_STAMP = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) (\d+)")
ROUTE_EVENT = re.compile(
    r'Generating level\s+\d+\s+area\s+"[^"]+"|You have entered |\*{5} LOG FILE OPENING \*{5}'
)


def line_stamp(line: str) -> str:
    match = LOG_STAMP.match(line)
    return f"{match.group(1)} {int(match.group(2)):012d}" if match else ""


def replay_route_events(path: Path, after_stamp: str) -> dict:
    events = []
    checkpoint_line_found = False
    with path.open(encoding="utf-8", errors="replace") as log_file:
        for line in log_file:
            stamp = line_stamp(line)
            is_route_event = bool(ROUTE_EVENT.search(line))
            if not checkpoint_line_found and stamp == after_stamp:
                checkpoint_line_found = True
                continue
            if checkpoint_line_found and is_route_event:
                events.append(line.rstrip("\r\n"))

    return {"ok": True, "checkpointFound": checkpoint_line_found, "events": events}


def validate_checkpoint(value: Any) -> dict:
    required_strings = (
        "buildKey",
        "routeFingerprint",
        "routeMode",
        "bandit",
        "areaId",
        "previousAreaId",
        "zone",
        "logStamp",
    )
    if not isinstance(value, dict) or value.get("version") not in {1, 2}:
        raise ValueError("Invalid route checkpoint version")
    if any(not isinstance(value.get(key), str) for key in required_strings):
        raise ValueError("Invalid route checkpoint fields")
    for key in ("act", "step"):
        if not isinstance(value.get(key), int) or value[key] < -1:
            raise ValueError("Invalid route checkpoint cursor")
    if value["version"] == 1:
        value = dict(value)
        value.update({
            "version": 2,
            "recoveryTargetAreaId": "",
        })
    else:
        value = dict(value)
    if value.get("manualMode") is True:
        manual_act = value.get("manualAct")
        manual_step = value.get("manualStep")
        if isinstance(manual_act, int) and manual_act >= 0 and isinstance(manual_step, int) and manual_step >= 0:
            value["act"] = manual_act
            value["step"] = manual_step
    if not isinstance(value.get("recoveryTargetAreaId"), str):
        raise ValueError("Invalid route recovery target")
    for key in ("manualAct", "manualStep", "manualMode"):
        value.pop(key, None)
    return value


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(value, temporary, ensure_ascii=False, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        sync_directory(path.parent)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def write_checkpoint(path: Path, value: Any) -> dict:
    checkpoint = validate_checkpoint(value)
    atomic_write_json(path, checkpoint)
    return {"ok": True, "saved": True}


def read_checkpoint(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"ok": True, "checkpoint": None}
    return {"ok": True, "checkpoint": validate_checkpoint(value)}


def clear_checkpoint(path: Path) -> dict:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    else:
        sync_directory(path.parent)
    return {"ok": True, "cleared": True}


def main() -> int:
    if sys.argv[1:2] == ["--replay"] and len(sys.argv) == 4:
        try:
            print(json.dumps(replay_route_events(Path(sys.argv[2]), sys.argv[3]), ensure_ascii=False))
            return 0
        except OSError as error:
            print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
            return 1

    if len(sys.argv) != 3 or sys.argv[1] not in {"--read", "--write", "--clear"}:
        print("Usage: route_state.py {--read|--write|--clear} CHECKPOINT_FILE | --replay LOG_FILE LOG_STAMP", file=sys.stderr)
        return 2

    operation = sys.argv[1]
    path = Path(sys.argv[2]).expanduser()
    try:
        if operation == "--read":
            result = read_checkpoint(path)
        elif operation == "--clear":
            result = clear_checkpoint(path)
        else:
            result = write_checkpoint(path, json.loads(sys.stdin.readline()))
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())