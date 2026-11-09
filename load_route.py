#!/usr/bin/env python3
"""Load the leveling project's act route files without converting them."""

from __future__ import annotations

import json
import hashlib
import re
import sys
from pathlib import Path


FRAGMENT = re.compile(r"\{([a-z_]+)(?:\|([^}]*))?\}")
DIRECTIONS = {
    "0": "North",
    "45": "Northeast",
    "90": "East",
    "135": "Southeast",
    "180": "South",
    "225": "Southwest",
    "270": "West",
    "315": "Northwest",
}


def load_json(path: Path, default: object) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def render_fragment(match: re.Match[str], areas: dict, quests: dict) -> str:
    kind = match.group(1)
    args = match.group(2).split("|") if match.group(2) is not None else []
    value = args[0].strip() if args else ""
    area = areas.get(value, {})
    area_name = area.get("name", value)

    if kind == "enter":
        return f"enter areaid{value} ;; {area_name}"
    if kind == "area":
        return area_name
    if kind == "waypoint":
        if value:
            return f"(img:waypoint) to areaid{value} ;; {area_name}"
        return "(img:waypoint)"
    if kind == "waypoint_get":
        return "(img:waypoint)"
    if kind == "kill":
        return value
    if kind == "arena":
        return f"arena:{value}"
    if kind == "quest":
        quest = quests.get(value, {})
        name = quest.get("name", value)
        offer_ids = args[1:]
        offer_part = "|" + ",".join(offer_ids) if offer_ids else ""
        return f"(quest-id:{value}{offer_part})(quest:{name})"
    if kind == "quest_text":
        return f"(quest:{value})"
    if kind == "generic":
        return value
    if kind == "dir":
        return DIRECTIONS.get(value, value + " degrees")
    if kind == "portal":
        return "(action-portal)"
    if kind == "logout":
        return "(action-logout)"
    if kind == "trial":
        return "(img:lab) trial"
    if kind == "crafting":
        return "(img:craft)"
    if kind == "ascend":
        return f"Complete {value} Labyrinth"
    if kind == "reward_quest":
        return f"Take {value}"
    if kind == "reward_vendor":
        return f"Buy {value}"
    if kind == "copy":
        return value
    return match.group(0)


def render_line(line: str, areas: dict, quests: dict) -> str:
    line = line.split("#", 1)[0].strip()

    def replace(match: re.Match[str]) -> str:
        return render_fragment(match, areas, quests)

    rendered = FRAGMENT.sub(replace, line).replace("➞", "→")
    if line == "{portal|use}":
        rendered = "Use " + rendered
    return rendered


def route_transition(line: str, current_area: str, last_town: str, portal_area: str | None, areas: dict) -> tuple[str, str, str | None]:
    destination = ""
    for match in FRAGMENT.finditer(line):
        kind = match.group(1)
        args = match.group(2).split("|") if match.group(2) is not None else []
        value = args[0].strip() if args else ""
        if kind in {"enter", "waypoint"} and value:
            destination = value
        elif kind == "logout":
            destination = last_town
        elif kind == "portal":
            if value == "set":
                portal_area = current_area
            elif value == "use" and portal_area:
                if current_area == portal_area:
                    destination = areas.get(current_area, {}).get("parent_town_area_id") or last_town
                elif current_area == areas.get(portal_area, {}).get("parent_town_area_id"):
                    destination = portal_area
                else:
                    destination = areas.get(current_area, {}).get("parent_town_area_id") or last_town

    if destination:
        current_area = destination
        if areas.get(destination, {}).get("is_town_area"):
            last_town = destination
    return current_area, last_town, portal_area


def load_route(route_dir: Path, mode: str, bandit: str, library: bool) -> dict:
    areas = load_json(route_dir / "areas.json", {})
    quests = load_json(route_dir / "quests.json", {})
    route_hash = hashlib.sha256()
    route_hash.update(b"poe-overlay-route-parser-v1\0")
    route_hash.update((route_dir / "areas.json").read_bytes())
    definitions = {
        "LEAGUE_START": mode.lower() == "leaguestart",
        "LIBRARY": library,
        "BANDIT_KILL": bandit.lower() == "none",
        "BANDIT_OAK": bandit.lower() == "oak",
        "BANDIT_KRAITYN": bandit.lower() == "kraityn",
        "BANDIT_ALIRA": bandit.lower() == "alira",
    }
    sections = []
    current_area = "1_1_1"
    last_town = "1_1_town"
    portal_area = None

    for act in range(1, 11):
        path = route_dir / f"act-{act}.txt"
        source = path.read_bytes()
        route_hash.update(path.name.encode("utf-8"))
        route_hash.update(source)
        lines = source.decode("utf-8").splitlines()
        section = {"index": act - 1, "title": f"Act {act}", "rows": []}
        conditions: list[tuple[bool, bool]] = []
        previous_row = None
        pending_group = None
        pending_destination = False

        def finish_group() -> None:
            nonlocal pending_group
            if pending_group is not None:
                pending_group["step"] = len(section["rows"])
                section["rows"].append(pending_group)
                pending_group = None

        def active() -> bool:
            return all(parent and branch for parent, branch in conditions)

        for source_line in lines:
            stripped = source_line.strip()
            directive = re.match(r"#(section|ifdef|ifndef|else|endif|sub)\b\s*(.*)", stripped)
            if directive:
                command, argument = directive.groups()
                if command == "section":
                    section["title"] = argument.strip() or f"Act {act}"
                elif command in {"ifdef", "ifndef"}:
                    parent_active = active()
                    defined = bool(definitions.get(argument.strip(), False))
                    conditions.append((parent_active, defined if command == "ifdef" else not defined))
                elif command == "else" and conditions:
                    parent, branch = conditions[-1]
                    conditions[-1] = (parent, not branch)
                elif command == "endif" and conditions:
                    conditions.pop()
                elif command == "sub" and active() and previous_row is not None:
                    text = render_line(argument, areas, quests)
                    if text:
                        previous_row["lines"].append({"text": text, "sub": True})
                        if pending_group is not None:
                            pending_group["lines"].append({"text": text, "sub": True})
                continue

            if not active() or not stripped or stripped.startswith("#"):
                continue

            if pending_destination:
                finish_group()
                pending_destination = False

            text = render_line(source_line, areas, quests)
            if not text:
                continue
            previous_row = {
                "act": act - 1,
                "lines": [{"text": text, "sub": False}],
            }
            if pending_group is None:
                pending_group = {
                    "act": act - 1,
                    "step": 0,
                    "lines": [],
                    "sourceAreaId": current_area,
                    "destinationAreaId": "",
                }
            pending_group["lines"].extend(previous_row["lines"])
            previous_area = current_area
            current_area, last_town, portal_area = route_transition(
                source_line, current_area, last_town, portal_area, areas
            )
            if current_area != previous_area:
                pending_group["destinationAreaId"] = current_area
                pending_destination = True

        finish_group()
        sections.append(section)

    return {
        "sections": sections,
        "fingerprint": route_hash.hexdigest(),
        "mode": mode.lower(),
        "bandit": bandit.lower(),
        "library": library,
    }


def main() -> int:
    if len(sys.argv) not in {2, 4, 5}:
        print("Usage: load_route.py ROUTES_DIR [MODE BANDIT [LIBRARY]]", file=sys.stderr)
        return 2
    route_dir = Path(sys.argv[1]).expanduser()
    mode = sys.argv[2] if len(sys.argv) >= 4 else "leaguestart"
    bandit = sys.argv[3] if len(sys.argv) >= 4 else "None"
    library = sys.argv[4].lower() != "false" if len(sys.argv) == 5 else True
    try:
        print(json.dumps(load_route(route_dir, mode, bandit, library), ensure_ascii=False))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())