#!/usr/bin/env python3
"""Generate compact passive-tree data for the QML viewer."""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from urllib.request import Request, urlopen

TREE_URLS = {
    "3_25": "https://raw.githubusercontent.com/grindinggear/skilltree-export/d355f6a16aadfa5d73e3b9a31ca9d7346fa84673/data.json",
    "3_26": "https://raw.githubusercontent.com/grindinggear/skilltree-export/9785205dca9cb617ea5a7d77faefd3608693ce77/data.json",
    "3_27": "https://raw.githubusercontent.com/grindinggear/skilltree-export/765dda38b9dd21ec28429fd81dd2d17ad6390623/data.json",
    "3_28": "https://raw.githubusercontent.com/grindinggear/skilltree-export/648e492b17d49d7213c63f4c1e0aa561617d5ad1/data.json",
    "3_29": "https://raw.githubusercontent.com/grindinggear/skilltree-export/b13a09fe8b8f3bec06c4440bdf90ab20988d327f/data.json",
}
TREE_TAGS_URL = (
    "https://api.github.com/repos/grindinggear/skilltree-export/tags?per_page=100"
)
TREE_VERSION_PATTERN = re.compile(r"(?P<major>\d+)_(?P<minor>\d+)")


def tree_url_from_tags(version: str, tags: list[dict]) -> str:
    match = TREE_VERSION_PATTERN.fullmatch(version)
    if not match:
        raise ValueError(f"Invalid passive tree version: {version}")

    release_prefix = f"{match.group('major')}.{match.group('minor')}."
    candidates = []
    for tag in tags:
        tag_name = tag.get("name", "")
        patch = re.fullmatch(rf"{re.escape(release_prefix)}(\d+)", tag_name)
        commit = tag.get("commit", {})
        sha = commit.get("sha", "") if isinstance(commit, dict) else ""
        if patch and re.fullmatch(r"[0-9a-f]{40}", sha):
            candidates.append((int(patch.group(1)), sha))

    if not candidates:
        raise ValueError(f"No stable GitHub tree tag found for version {version}")

    _, commit_sha = max(candidates)
    return f"https://raw.githubusercontent.com/grindinggear/skilltree-export/{commit_sha}/data.json"


def tree_source_url(version: str) -> str:
    if not TREE_VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"Invalid passive tree version: {version}")
    if version in TREE_URLS:
        return TREE_URLS[version]

    request = Request(
        TREE_TAGS_URL,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "poe-campaign-overlay",
        },
    )
    with urlopen(request, timeout=20) as response:
        tags = json.load(response)
    if not isinstance(tags, list):
        raise ValueError("GitHub returned an invalid tree tag list")
    return tree_url_from_tags(version, tags)


ANGLES_16 = [0, 30, 45, 60, 90, 120, 135, 150, 180, 210, 225, 240, 270, 300, 315, 330]
ANGLES_40 = [
    0,
    10,
    20,
    30,
    40,
    45,
    50,
    60,
    70,
    80,
    90,
    100,
    110,
    120,
    130,
    135,
    140,
    150,
    160,
    170,
    180,
    190,
    200,
    210,
    220,
    225,
    230,
    240,
    250,
    260,
    270,
    280,
    290,
    300,
    310,
    315,
    320,
    330,
    340,
    350,
]
ASCENDANCY_OFFSETS = {
    "Juggernaut": (-10400, 5200),
    "Berserker": (-10400, 3700),
    "Chieftain": (-10400, 2200),
    "Raider": (10200, 5200),
    "Deadeye": (10200, 2200),
    "Pathfinder": (10200, 3700),
    "Occultist": (-1500, -9850),
    "Elementalist": (0, -9850),
    "Necromancer": (1500, -9850),
    "Slayer": (1500, 9800),
    "Gladiator": (-1500, 9800),
    "Champion": (0, 9800),
    "Inquisitor": (-10400, -2200),
    "Hierophant": (-10400, -3700),
    "Guardian": (-10400, -5200),
    "Assassin": (10200, -5200),
    "Trickster": (10200, -3700),
    "Saboteur": (10200, -2200),
    "Ascendant": (-7800, 7200),
    "Reliquarian": (-7800, 8900),
    "Luminary": (-7800, 10600),
    "Warden": (8250, 8350),
    "Primalist": (7200, 9400),
    "Warlock": (9300, 7300),
    "Aul": (-6750, 12000),
    "Breachlord": (-5250, 12000),
    "Catarina": (-3750, 12000),
    "Trialmaster": (-2250, 12000),
    "Delirious": (-750, 12000),
    "Farrul": (750, 12000),
    "Lycia": (2250, 12000),
    "KingInTheMists": (3750, 12000),
    "Olroth": (5250, 12000),
    "Oshabi": (6750, 12000),
    "Necromantic": (8250, 12000),
    "Abyssal": (-750, 13600),
    "Brinerot": (750, 13600),
}


def node_position(raw: dict, node: dict) -> tuple[float, int, int]:
    group = raw["groups"][str(node["group"])]
    orbit = node["orbit"]
    orbit_index = node.get("orbitIndex", 0)
    count = raw["constants"]["skillsPerOrbit"][orbit]
    radius = raw["constants"]["orbitRadii"][orbit]
    if count == 16:
        angle = math.radians(ANGLES_16[orbit_index])
    elif count == 40:
        angle = math.radians(ANGLES_40[orbit_index])
    else:
        angle = math.tau / count * orbit_index
    x = round(group["x"] + radius * math.sin(angle))
    y = round(group["y"] - radius * math.cos(angle))
    return angle % math.tau, x, y


def build_tree(raw: dict) -> dict:
    classes = [
        {
            "name": item["name"],
            "ascendancies": [asc["id"] for asc in item["ascendancies"]],
        }
        for item in raw["classes"]
    ]
    graphs = [{"nodes": {}, "connections": []}]
    ascendancies = {}
    for item in raw["classes"]:
        for asc in item["ascendancies"]:
            ascendancies[asc["id"]] = {"graphIndex": len(graphs)}
            graphs.append({"nodes": {}, "connections": []})
    for asc in raw.get("alternate_ascendancies", []) or []:
        ascendancies[asc["id"]] = {"graphIndex": len(graphs)}
        graphs.append({"nodes": {}, "connections": []})

    bounds = [math.inf, math.inf, -math.inf, -math.inf]
    mastery_effects = {}
    for group in raw["groups"].values():
        for node_id in group["nodes"]:
            node = raw["nodes"][str(node_id)]
            if group.get("isProxy") and not node.get("isJewelSocket"):
                continue
            if node.get("classStartIndex") is not None or not node.get("name"):
                continue
            if node.get("group") is None or node.get("orbit") is None:
                continue
            angle, x, y = node_position(raw, node)
            asc_name = node.get("ascendancyName")
            if node.get("isMastery"):
                for effect in node.get("masteryEffects", []):
                    mastery_effects[str(effect["effect"])] = {"stats": effect["stats"]}
            graph_index = ascendancies[asc_name]["graphIndex"] if asc_name else 0
            kind = (
                "Ascendancy_Start"
                if node.get("isAscendancyStart")
                else "Mastery"
                if node.get("isMastery")
                else "Keystone"
                if node.get("isKeystone")
                else "Notable"
                if node.get("isNotable")
                else "Jewel"
                if node.get("isJewelSocket")
                else "Normal"
            )
            graphs[graph_index]["nodes"][str(node_id)] = {
                "x": x,
                "y": y,
                "k": kind,
                "text": node["name"],
                "stats": node.get("stats", []),
            }
            if not asc_name:
                bounds[0] = min(bounds[0], x)
                bounds[1] = min(bounds[1], y)
                bounds[2] = max(bounds[2], x)
                bounds[3] = max(bounds[3], y)

            if node.get("isAscendancyStart") and asc_name:
                ascendancies[asc_name]["startNodeId"] = str(node_id)
                ascendancies[asc_name]["id"] = asc_name

    for group in raw["groups"].values():
        for node_id in group["nodes"]:
            node = raw["nodes"][str(node_id)]
            if group.get("isProxy") and not node.get("isJewelSocket"):
                continue
            if node.get("classStartIndex") is not None or not node.get("name"):
                continue
            asc_name = node.get("ascendancyName")
            graph_index = ascendancies[asc_name]["graphIndex"] if asc_name else 0
            graph = graphs[graph_index]
            if str(node_id) not in graph["nodes"] or node.get("isMastery"):
                continue
            angle, _, _ = node_position(raw, node)
            for out_id in node.get("out", []):
                other = raw["nodes"].get(str(out_id), {})
                if (
                    other.get("classStartIndex") is not None
                    or node.get("isMastery")
                    or other.get("isMastery")
                    or node.get("ascendancyName") != other.get("ascendancyName")
                    or str(out_id) not in graph["nodes"]
                ):
                    continue
                other_angle, _, _ = node_position(raw, other)
                connection = {"a": str(node_id), "b": str(out_id)}
                if node.get("group") == other.get("group") and node.get(
                    "orbit"
                ) == other.get("orbit"):
                    rotation = (angle - other_angle) % math.tau
                    connection["s"] = {
                        "w": "CW" if rotation > math.pi else "CCW",
                        "r": raw["constants"]["orbitRadii"][node["orbit"]],
                    }
                graph["connections"].append(connection)

    for ascendancy_id, ascendancy in ascendancies.items():
        graph = graphs[ascendancy["graphIndex"]]
        if not graph["nodes"]:
            continue
        offset_x, offset_y = ASCENDANCY_OFFSETS[ascendancy_id]
        start_node = graph["nodes"][ascendancy["startNodeId"]]
        delta_x, delta_y = offset_x - start_node["x"], offset_y - start_node["y"]
        for node in graph["nodes"].values():
            node["x"] += delta_x
            node["y"] += delta_y
            bounds[0] = min(bounds[0], node["x"])
            bounds[1] = min(bounds[1], node["y"])
            bounds[2] = max(bounds[2], node["x"])
            bounds[3] = max(bounds[3], node["y"])

    return {
        "bounds": {
            "minX": bounds[0],
            "minY": bounds[1],
            "maxX": bounds[2],
            "maxY": bounds[3],
        },
        "classes": classes,
        "graphs": graphs,
        "graphIndex": 0,
        "ascendancies": ascendancies,
        "masteryEffects": mastery_effects,
    }


def seed(version: str, output_dir: Path) -> Path:
    source_url = tree_source_url(version)
    with urlopen(source_url, timeout=60) as response:
        raw = json.load(response)
    tree = build_tree(raw)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{version}.json"
    output_path.write_text(json.dumps(tree, separators=(",", ":")), encoding="utf-8")
    return output_path


def ensure_seed(version: str, output_dir: Path) -> Path:
    if not TREE_VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"Invalid passive tree version: {version}")

    output_path = output_dir / f"{version}.json"
    try:
        cached = json.loads(output_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cached = None
    if isinstance(cached, dict) and cached.get("graphs"):
        return output_path
    return seed(version, output_dir)


def main() -> int:
    if sys.argv[1:2] == ["--ensure"] and len(sys.argv) == 4:
        try:
            print(ensure_seed(sys.argv[2], Path(sys.argv[3])))
            return 0
        except Exception as error:
            print(
                f"Could not load passive tree {sys.argv[2]}: {error}", file=sys.stderr
            )
            return 1

    version = sys.argv[1] if len(sys.argv) > 1 else "all"
    output_dir = Path(__file__).resolve().parent / "routes" / "passive-tree"
    versions = TREE_URLS if version == "all" else {version: None}
    for tree_version in versions:
        try:
            output_path = seed(tree_version, output_dir)
            print(output_path)
        except Exception as error:
            print(f"Could not seed {tree_version}: {error}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
