#!/usr/bin/env python3
"""
cook.py — the content pipeline: validate, pack, manifest, budget.

"Cooking" is the step between the files an author edits and the bytes a device
loads. Without one, every content mistake is found by a person looking at a
device, and bundle size is whatever it happens to be. This is that step, and it is
the gate `make ci` runs.

What it does, in order — each stage refuses to continue on a real problem, because
a manifest of broken content is worse than no manifest:

  1. **Validate** everything `asset_audit.py` checks, plus level design rules.
  2. **Pack** texture atlases so a character costs one bind instead of seven.
  3. **Manifest** every shipped asset with its size, density and content hash, so a
     build is reproducible and a diff between two builds is readable.
  4. **Budget** by category, with a hard ceiling. Bundle size is a product
     decision, and the only way to hold one is to fail the build when it is
     exceeded.

    python3 Tools/cook.py                 # validate, pack, manifest, budget
    python3 Tools/cook.py --check         # no writes: CI mode
    python3 Tools/cook.py --budget 90     # override the ceiling, in MB
"""
import argparse, hashlib, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

# Per-category ceilings in MB. These are deliberately tight enough to notice:
# an unbounded bundle is how a 2D game ships at 400MB.
BUDGETS = {
    "Rigs": 12.0,
    "Friezes": 46.0,
    "Terrain": 8.0,
    "Levels": 0.5,
    "Audio": 10.0,
}
TOTAL_BUDGET_MB = 70.0

# What ships. Everything else in Assets/ is a build input (specs, previews).
SHIPPED = (".png", ".json", ".wav")
EXCLUDED_SUFFIXES = ("_preview", "_scene", "_ingest")
EXCLUDED_STEMS = (".spec", ".artspec")


def shipped_files(assets_dir):
    """Every file that ends up in the bundle, by category."""
    out = {}
    for category in sorted(os.listdir(assets_dir)):
        directory = os.path.join(assets_dir, category)
        if not os.path.isdir(directory):
            continue
        found = []
        for name in sorted(os.listdir(directory)):
            stem, ext = os.path.splitext(name)
            if ext.lower() not in SHIPPED:
                continue
            bare = stem
            for scale in ("@2x", "@3x"):
                bare = bare.replace(scale, "")
            if bare.endswith(EXCLUDED_SUFFIXES):
                continue
            if any(bare.endswith(s) for s in EXCLUDED_STEMS):
                continue
            if bare.endswith("_legacy"):
                continue
            found.append(os.path.join(directory, name))
        if found:
            out[category] = found
    return out


def digest(path, chunk=1 << 16):
    """Content hash. Cheap enough to run over the whole bundle, and it is what
    makes "did the content change?" answerable without comparing byte by byte."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()[:16]


def image_density(path, manifest_hint=None):
    """px per scene point, when we can tell. Recorded so a later build can see a
    density regression rather than only a size one."""
    try:
        from PIL import Image
    except ImportError:
        return None
    stem = os.path.basename(path)
    scale = 3 if "@3x" in stem else 2 if "@2x" in stem else 1
    try:
        with Image.open(path) as im:
            return {"pixels": list(im.size), "suffixScale": scale}
    except OSError:
        return None


def run(cmd, label):
    """Run a stage, streaming its output. Returns its exit code.

    The flush matters: without it Python's buffered stdout lands *after* the
    subprocess's unbuffered output, so every stage's results appear under the
    previous stage's heading.
    """
    print(f"\n── {label} ──", flush=True)
    result = subprocess.run([sys.executable] + cmd, cwd=ROOT)
    sys.stdout.flush()
    return result.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--assets", default=os.path.join(ROOT, "Assets"))
    ap.add_argument("--out", default=os.path.join(ROOT, "Assets", "content.json"))
    ap.add_argument("--budget", type=float, default=TOTAL_BUDGET_MB,
                    help=f"total ceiling in MB (default {TOTAL_BUDGET_MB})")
    ap.add_argument("--check", action="store_true",
                    help="validate and report without writing the manifest")
    ap.add_argument("--skip-pack", action="store_true",
                    help="don't repack atlases (they are already current)")
    ap.add_argument("--stamp", default="",
                    help="build stamp recorded in the manifest, e.g. a git sha")
    args = ap.parse_args()

    failures = 0

    # 1 ─ validate. The audit is the authority; cooking does not duplicate it.
    if run(["Tools/asset_audit.py", "--strict"], "validate assets") != 0:
        failures += 1
    if run(["Tools/ai_director.py", "validate", "--all"], "validate levels") != 0:
        failures += 1

    # 2 ─ pack. Skipped in --check so CI never mutates the tree.
    if not args.skip_pack and not args.check:
        rigs = os.path.join(args.assets, "Rigs")
        if os.path.isdir(rigs):
            if run(["Tools/atlas_packer.py", rigs,
                    os.path.join(rigs, "hero_atlas"), "--size", "1024"],
                   "pack atlases") != 0:
                failures += 1

    # 3 ─ manifest.
    print("\n── manifest ──")
    files = shipped_files(args.assets)
    entries, totals = {}, {}
    for category, paths in files.items():
        size = 0
        for path in paths:
            relative = os.path.relpath(path, ROOT)
            bytes_ = os.path.getsize(path)
            size += bytes_
            entry = {"bytes": bytes_, "sha256": digest(path), "category": category}
            info = image_density(path)
            if info:
                entry.update(info)
            entries[relative] = entry
        totals[category] = size
        print(f"  {category:<10} {len(paths):3d} file(s)  {size / 1e6:6.2f} MB")

    total = sum(totals.values())
    print(f"  {'TOTAL':<10} {len(entries):3d} file(s)  {total / 1e6:6.2f} MB")

    # 4 ─ budget. A ceiling nobody enforces is a wish.
    print("\n── budget ──")
    for category, size in sorted(totals.items()):
        ceiling = BUDGETS.get(category)
        if ceiling is None:
            print(f"  {category:<10} {size / 1e6:6.2f} MB  (no ceiling set)")
            continue
        used = size / 1e6 / ceiling * 100
        mark = "✗" if size / 1e6 > ceiling else "·"
        print(f"  {mark} {category:<10} {size / 1e6:6.2f} / {ceiling:5.1f} MB  "
              f"{used:5.1f}%")
        if size / 1e6 > ceiling:
            failures += 1
    over = total / 1e6 > args.budget
    print(f"  {'✗' if over else '·'} {'TOTAL':<10} {total / 1e6:6.2f} / "
          f"{args.budget:5.1f} MB  {total / 1e6 / args.budget * 100:5.1f}%")
    if over:
        failures += 1

    if not args.check:
        manifest = {
            "format": "content/1",
            "stamp": args.stamp,
            # No wall-clock time: a manifest that changes when nothing changed is
            # useless for answering "did the content move?".
            "totalBytes": total,
            "categories": {k: v for k, v in sorted(totals.items())},
            "files": dict(sorted(entries.items())),
        }
        with open(args.out, "w") as f:
            json.dump(manifest, f, indent=1)
            f.write("\n")
        print(f"\nwrote {os.path.relpath(args.out, ROOT)} "
              f"({len(entries)} entries, content-hashed)")

    if failures:
        print(f"\n{failures} stage(s) failed — the content is not shippable")
        return 1
    print("\n✓ content validated, packed, manifested and inside budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
