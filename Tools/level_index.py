#!/usr/bin/env python3
"""
level_index.py — writes `Assets/Levels/levels.json`, the launch-time level index.

Why it exists: without an index the game finds its levels by decoding every JSON in
the bundle. That is free at six levels and about a second of launch at a thousand,
with every level's rows held resident for the session. The index lists what exists —
name, order, title, grid size — and a level's contents are decoded only when played.

    python3 Tools/level_index.py            # write the index
    python3 Tools/level_index.py --check    # is it current? (CI)
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ai_director import level_files                                  # noqa: E402


def build(directory):
    docs, problems = level_files(directory)
    return {
        "format": "levels/1",
        "levels": [
            {"name": d["name"], "order": d["order"],
             "title": d.get("title") or d["name"],
             "cols": max(len(r) for r in d["rows"]), "rows": len(d["rows"])}
            for d in docs
        ],
    }, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--levels", default=os.path.join(HERE, "..", "Assets", "Levels"))
    ap.add_argument("--check", action="store_true",
                    help="fail if the index on disk is missing or stale")
    args = ap.parse_args()

    index, problems = build(args.levels)
    for problem in problems:
        print(f"  ✗ {problem}", file=sys.stderr)
    path = os.path.join(args.levels, "levels.json")

    if args.check:
        try:
            with open(path) as f:
                current = json.load(f)
        except (OSError, json.JSONDecodeError):
            print("levels.json is missing or unreadable — run "
                  "`python3 Tools/level_index.py`", file=sys.stderr)
            return 1
        if current != index:
            print("levels.json is stale — run `python3 Tools/level_index.py`",
                  file=sys.stderr)
            return 1
        print(f"levels.json is current ({len(index['levels'])} level(s))")
        return 1 if problems else 0

    with open(path, "w") as f:
        json.dump(index, f, indent=1)
        f.write("\n")
    print(f"wrote {os.path.relpath(path, os.path.dirname(HERE))} "
          f"({len(index['levels'])} level(s))")
    for entry in index["levels"]:
        print(f"  {entry['order']:>4}  {entry['name']:<12} "
              f"{entry['cols']}×{entry['rows']}  {entry['title']}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
