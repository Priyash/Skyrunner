#!/usr/bin/env python3
"""
level_export.py — the compiled level table → `level/1` files.

A one-shot migration, kept because it is also the answer to "I have levels in
Swift and I want them in the editor": read `World/Levels.swift`, write one JSON
per level into `Assets/Levels/`. After that the files are the source of truth and
`Levels.builtIn` is only the fallback for a build with no level files at all.

    python3 Tools/level_export.py [--out ../Assets/Levels] [--force]

Names and titles are taken from the `── Level N: …` comments in the Swift source
where they exist, because those comments are the only place the intent of each
level was recorded.
"""
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ai_director import shipped_levels, validate_level          # noqa: E402

# Slug + display title per level index, where the source comment gives one.
# Anything beyond this list gets a generated name, so adding a fifth level to the
# Swift table and re-running still works.
KNOWN = [
    ("grove",  "Sunlit Grove", "forest_backdrop", 0.40, "theme_grove",  "grove"),
    ("hollow", "Thorn Hollow", "forest_backdrop", 0.55, "theme_hollow", "hollow"),
    ("ridge",  "Canopy Ridge", "forest_backdrop", 0.30, "theme_ridge",  "grove"),
    ("arena",  "King Blob",    "forest_backdrop", 0.72, "theme_arena",  "arena"),
]


def comment_titles(source):
    """`// ── Level 2: spikes, a pit, and a moving platform ──` → the text."""
    found = []
    for match in re.finditer(r"//\s*─*\s*Level\s+\d+\s*:\s*(.+?)\s*─*\s*$",
                             source, re.MULTILINE):
        found.append(match.group(1).strip())
    return found


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default=os.path.join(here, "..", "World", "Levels.swift"))
    ap.add_argument("--out", default=os.path.join(here, "..", "Assets", "Levels"))
    ap.add_argument("--force", action="store_true",
                    help="overwrite level files that already exist")
    args = ap.parse_args()

    levels = shipped_levels(args.source)
    if not levels:
        print("no levels found in the Swift source", file=sys.stderr)
        return 1
    with open(args.source) as f:
        notes = comment_titles(f.read())
    os.makedirs(args.out, exist_ok=True)

    written, skipped, failed = 0, 0, 0
    for index, rows in enumerate(levels):
        if index < len(KNOWN):
            name, title, frieze, time_of_day, track, look = KNOWN[index]
        else:
            name = f"level{index + 1}"
            title = notes[index] if index < len(notes) else f"Level {index + 1}"
            frieze, time_of_day, track, look = ("forest_backdrop", 0.5,
                                               "theme_grove", "grove")
        path = os.path.join(args.out, f"{name}.json")
        if os.path.exists(path) and not args.force:
            print(f"  = {name}.json exists (--force to overwrite)")
            skipped += 1
            continue

        width = max(len(r) for r in rows)
        document = {
            "format": "level/1",
            "name": name,
            # Sparse, so a level can be inserted between two others without
            # renumbering everything after it.
            "order": (index + 1) * 10,
            "title": title,
            "frieze": frieze,
            "timeOfDay": time_of_day,
            "music": track,
            "grade": look,
            "rows": [r.ljust(width) for r in rows],
        }
        problems = validate_level(rows)
        if problems:
            failed += 1
            print(f"  ✗ {name}.json would not validate:")
            for problem in problems:
                print(f"      {problem}")
            continue
        with open(path, "w") as f:
            json.dump(document, f, indent=1)
            f.write("\n")
        print(f"  ✓ {name}.json  ({width}×{len(rows)})  order {document['order']}")
        written += 1

    print(f"{written} written, {skipped} skipped, {failed} rejected")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
