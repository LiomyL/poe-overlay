#!/usr/bin/env python3
"""Decode a Path of Building export code and extract its skill sets."""

from __future__ import annotations

import base64
import json
import re
import struct
import sys
import zlib
from pathlib import Path
from xml.etree import ElementTree

from route_state import atomic_write_json

OVERLAY_BANDITS = {"auto", "none", "oak", "kraityn", "alira"}


def validate_overlay_state(value: object) -> dict:
    if not isinstance(value, dict) or not isinstance(value.get("enabled"), bool):
        raise ValueError("Invalid overlay state.")
    bandit = value.get("bandit", "auto")
    if not isinstance(bandit, str) or bandit not in OVERLAY_BANDITS:
        raise ValueError("Invalid overlay bandit choice.")
    log_path = value.get("logPath", "")
    if not isinstance(log_path, str):
        raise ValueError("Invalid game log path.")
    return {**value, "bandit": bandit, "logPath": log_path}


def decode_export(value: str) -> bytes:
    value = re.sub(r"\s+", "", value.strip()).replace("-", "+").replace("_", "/")
    if not value:
        raise ValueError("Paste a Path of Building export code.")

    value += "=" * (-len(value) % 4)
    try:
        compressed = base64.b64decode(value, validate=True)
        return zlib.decompress(compressed)
    except (ValueError, zlib.error) as error:
        raise ValueError(
            "Could not decode the code. Use a Path of Building Export Code."
        ) from error


def parse_tree_spec(spec: ElementTree.Element) -> dict | None:
    url = (spec.findtext("URL") or "").strip()
    encoded = url.rsplit("/", 1)[-1].split("?", 1)[0].split("#", 1)[0]
    if not encoded:
        return None

    encoded += "=" * (-len(encoded) % 4)
    try:
        data = base64.urlsafe_b64decode(encoded)
    except (ValueError, base64.binascii.Error) as error:
        raise ValueError("Invalid PoB passive tree URL.") from error
    if len(data) < 7:
        raise ValueError("Incomplete PoB passive tree URL.")

    url_version = struct.unpack_from(">I", data)[0]
    if url_version < 6:
        raise ValueError("Unsupported PoB passive tree URL version.")

    node_count = data[6]
    nodes_offset = 7
    clusters_offset = nodes_offset + node_count * 2
    if len(data) <= clusters_offset:
        raise ValueError("Incomplete PoB passive tree node list.")
    nodes = [
        str(node_id)
        for (node_id,) in struct.iter_unpack(">H", data[nodes_offset:clusters_offset])
    ]

    cluster_count = data[clusters_offset]
    mastery_count_offset = clusters_offset + 1 + cluster_count * 2
    if len(data) <= mastery_count_offset:
        mastery_data = {}
    else:
        mastery_count = data[mastery_count_offset]
        mastery_offset = mastery_count_offset + 1
        mastery_end = mastery_offset + mastery_count * 4
        if len(data) < mastery_end:
            raise ValueError("Incomplete PoB passive tree mastery list.")
        mastery_data = {
            str(node_id): str(effect_id)
            for effect_id, node_id in struct.iter_unpack(
                ">HH", data[mastery_offset:mastery_end]
            )
        }

    return {
        "title": spec.get("title", "") or "Default",
        "version": spec.get("treeVersion", ""),
        "urlVersion": url_version,
        "classId": data[4],
        "ascendancyId": data[5],
        "nodes": nodes,
        "masteries": mastery_data,
    }


def parse_build(export_code: str) -> dict:
    xml_data = decode_export(export_code)
    try:
        root = ElementTree.fromstring(xml_data)
    except ElementTree.ParseError as error:
        raise ValueError("The PoB code does not contain valid build XML.") from error

    if root.tag != "PathOfBuilding":
        raise ValueError("Use a Path of Building Export Code for PoE 1.")

    build = root.find("Build")
    skills = root.find("Skills")
    if build is None or skills is None:
        raise ValueError("The export is missing Build or Skills data.")

    skill_sets = []
    for index, skill_set in enumerate(skills.findall("SkillSet")):
        groups = []
        for skill in skill_set.findall("Skill"):
            if skill.get("enabled", "true").lower() == "false":
                continue
            gems = []
            for gem in skill.findall("Gem"):
                if gem.get("enabled", "true").lower() == "false":
                    continue
                name = gem.get("nameSpec", "").strip()
                if not name:
                    continue
                gems.append(
                    {
                        "name": name,
                        "id": gem.get("gemId", ""),
                        "support": "supportgem" in gem.get("gemId", "").lower(),
                    }
                )
            if gems:
                groups.append({"label": skill.get("label", ""), "gems": gems})

        if groups:
            skill_sets.append(
                {
                    "id": skill_set.get("id", str(index + 1)),
                    "title": skill_set.get("title", "") or f"Skill set {index + 1}",
                    "note": skill_set.get("title", "") or "Default",
                    "enabled": True,
                    "groups": groups,
                    "gems": [gem for group in groups for gem in group["gems"]],
                }
            )

    if not skill_sets:
        raise ValueError("No gems found. Check the enabled Skill Sets in PoB.")

    tree_specs = [
        parsed
        for spec in root.iter("Spec")
        if (parsed := parse_tree_spec(spec)) is not None
    ]

    return {
        "parserVersion": 4,
        "format": root.tag,
        "name": build.get("name", ""),
        "class": build.get("className", "").strip().lower(),
        "ascendancy": build.get("ascendClassName", ""),
        "bandit": build.get("bandit", "None"),
        "level": int(build.get("level", "1")),
        "skillSets": skill_sets,
        "activeSkillSet": skills.get("activeSkillSet", "1"),
        "treeSpecs": tree_specs,
        "activeTreeSpec": root.find("Tree").get("activeSpec", "1")
        if root.find("Tree") is not None
        else "1",
    }


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--save":
        state_path = Path(sys.argv[2]).expanduser()
        try:
            state = json.loads(sys.stdin.readline())
            if not isinstance(state, dict) or not isinstance(
                state.get("skillSets"), list
            ):
                raise ValueError("Invalid saved build data.")
            atomic_write_json(state_path, state)
            print(json.dumps({"ok": True, "saved": True}, ensure_ascii=False))
            return 0
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
            return 1

    if len(sys.argv) == 3 and sys.argv[1] == "--overlay-state":
        state_path = Path(sys.argv[2]).expanduser()
        try:
            state = validate_overlay_state(json.loads(sys.stdin.readline()))
            atomic_write_json(state_path, state)
            print(json.dumps({"ok": True, "saved": True}, ensure_ascii=False))
            return 0
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
            return 1

    if len(sys.argv) == 3 and sys.argv[1] == "--delete":
        state_path = Path(sys.argv[2]).expanduser()
        try:
            state_path.unlink(missing_ok=True)
            print(json.dumps({"ok": True, "deleted": True}, ensure_ascii=False))
            return 0
        except OSError as error:
            print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
            return 1

    if len(sys.argv) != 2:
        print(
            "Usage: import_pob.py STATE_FILE | --save STATE_FILE | --delete STATE_FILE | --overlay-state STATE_FILE",
            file=sys.stderr,
        )
        return 2

    try:
        export_code = sys.stdin.readline().strip()
        build_data = parse_build(export_code)
        state_path = Path(sys.argv[1]).expanduser()
        atomic_write_json(state_path, build_data)
        print(json.dumps({"ok": True, "build": build_data}, ensure_ascii=False))
        return 0
    except (OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
