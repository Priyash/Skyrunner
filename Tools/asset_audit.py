#!/usr/bin/env python3
"""
asset_audit.py — verifies that what the data references actually exists.

The engine loads art by *name*: a rig names `hero_body`, a frieze scene names
`forest_hill_far`, and both resolve through the bundle at runtime. That is what
makes art swappable without a rebuild — and it is also why a typo or a missing
@3x variant shows up as an invisible limb on a device rather than as an error at
build time. This closes that gap offline.

Checks, in the order they bite in practice:
  • every rig attachment resolves to a file, at every required scale
  • @2x and @3x agree on aspect ratio (a mismatched pair scales wrong on one
    class of device only, which is the worst kind of bug to find late)
  • attachment width/height match the art's real aspect, so meshes aren't
    stretched by the lattice
  • every frieze layer image exists, and is wide enough for the parallax travel
    it is asked to do
  • orphans: art in the folder that nothing references

Usage:
    python3 asset_audit.py [--rigs ../Assets/Rigs] [--friezes ../Assets/Friezes]
                           [--level-width 50] [--strict]
"""
import argparse, glob, json, os, re, sys

try:
    from PIL import Image
    HAVE_PIL = True
except ImportError:
    HAVE_PIL = False

SCALES = (2, 3)
TILE = 40.0
SCREEN_W = 844.0
SCREEN_H = 390.0

# What a device actually needs, in pixels per *scene* point. `.aspectFill` scales
# the 844×390 scene up to the view before the screen scale applies, so these are
# larger than the @3x suffix suggests:
#   iPhone 15 Pro Max  1.10 × 3 = 3.3
#   iPad Pro 12.9"     2.63 × 2 = 5.3   ← the binding case
MIN_DENSITY = 3.3          # below this, art is magnified on every modern device
GOOD_DENSITY = 5.3         # covers the densest device without magnification

# Backdrops are capped below GOOD_DENSITY on purpose: a layer wide enough to
# cover a long level's parallax travel would cost tens of MB of texture at 5.3
# px/pt, and every backdrop layer is hazed and depth-of-field blurred anyway.
# Mirrors `art_director.BACKDROP_DENSITY`.
BACKDROP_CAP = 4.0


def image_variants(directory, name):
    """Every @Nx file for a logical image name."""
    found = {}
    for scale in SCALES:
        path = os.path.join(directory, f"{name}@{scale}x.png")
        if os.path.isfile(path):
            found[scale] = path
    # A bare name (no @Nx) is legal for a 1x asset.
    plain = os.path.join(directory, f"{name}.png")
    if os.path.isfile(plain):
        found[1] = plain
    return found


def size_of(path):
    if not HAVE_PIL:
        return None
    try:
        with Image.open(path) as im:
            return im.size
    except OSError:
        return None


def audit_rigs(directory, problems, notes, referenced):
    rigs = sorted(glob.glob(os.path.join(directory, "*_rig.json")))
    if not rigs:
        notes.append(f"{directory}: no *_rig.json found")
    for rig_path in rigs:
        try:
            with open(rig_path) as f:
                rig = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{os.path.basename(rig_path)}: unreadable ({e})")
            continue

        slots = {s["name"]: s for s in rig.get("slots", [])}
        bones = {b["name"] for b in rig.get("bones", [])}
        for slot in rig.get("slots", []):
            if slot.get("bone") not in bones:
                problems.append(f"{os.path.basename(rig_path)}: slot "
                                f"'{slot['name']}' binds to missing bone "
                                f"'{slot.get('bone')}'")

        for skin in rig.get("skins", []):
            for slot_name, attachments in (skin.get("attachments") or {}).items():
                if slot_name not in slots:
                    problems.append(f"{os.path.basename(rig_path)}: skin references "
                                    f"unknown slot '{slot_name}'")
                for att_name, att in attachments.items():
                    image = att.get("path") or att.get("image") or att_name
                    referenced.add(image)
                    variants = image_variants(directory, image)
                    missing = [s for s in SCALES if s not in variants]
                    if not variants:
                        problems.append(f"{os.path.basename(rig_path)}: "
                                        f"'{image}' has no art at all")
                        continue
                    if missing and 1 not in variants:
                        problems.append(f"{os.path.basename(rig_path)}: '{image}' "
                                        f"missing @{'x, @'.join(str(m) for m in missing)}x")

                    if not HAVE_PIL:
                        continue
                    # @2x and @3x must describe the same picture.
                    aspects = {}
                    for scale, path in variants.items():
                        size = size_of(path)
                        if not size:
                            problems.append(f"{os.path.basename(path)}: unreadable image")
                            continue
                        aspects[scale] = size[0] / max(size[1], 1)

                    # Resolution: the check that decides whether the game looks
                    # sharp or soft. Measured against the *scene* point size the
                    # attachment declares, not against the file's suffix.
                    declared_w = att.get("width", 0)
                    if declared_w and 3 in variants:
                        px = size_of(variants[3])
                        if px:
                            density = px[0] / declared_w
                            if density < MIN_DENSITY:
                                problems.append(
                                    f"'{image}' is {density:.1f} px per scene point "
                                    f"({px[0]}px for {declared_w:.1f}pt) — magnified on "
                                    f"every current device; {GOOD_DENSITY:.1f} needed "
                                    f"for iPad Pro")
                            elif density < GOOD_DENSITY:
                                notes.append(
                                    f"'{image}' is {density:.1f} px/pt — sharp on "
                                    f"iPhone, slightly soft on iPad Pro "
                                    f"({GOOD_DENSITY:.1f} clears it)")
                    if len(aspects) > 1:
                        lo, hi = min(aspects.values()), max(aspects.values())
                        if hi - lo > 0.02:
                            problems.append(
                                f"'{image}': @2x and @3x disagree on aspect "
                                f"({lo:.3f} vs {hi:.3f}) — one device class will "
                                f"render it stretched")
                    if att.get("width") and aspects:
                        art = list(aspects.values())[0]
                        declared = att["width"] / max(att.get("height", 1), 1)
                        if abs(art - declared) > 0.06:
                            problems.append(
                                f"'{image}': art aspect {art:.3f} vs attachment "
                                f"{declared:.3f} — the mesh will stretch the art")


def audit_friezes(directory, level_width, problems, notes, referenced):
    import ai_director
    scenes = [p for p in sorted(glob.glob(os.path.join(directory, "*.json")))
              if not p.endswith("spec.json")]
    if not scenes:
        notes.append(f"{directory}: no frieze scene JSON found")
    for scene_path in scenes:
        try:
            with open(scene_path) as f:
                scene = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{os.path.basename(scene_path)}: unreadable ({e})")
            continue
        if "layers" not in scene:
            continue                          # not a frieze scene
        focus = float(scene.get("focus", 0.55)) or 0.55
        dof = float(scene.get("dofPointsPerDepth", 5))
        travel = level_width * TILE - SCREEN_W     # how far the camera can move

        for layer in scene.get("layers", []):
            image = layer.get("image", "")
            referenced.add(image)
            # Props and spline geometry are backdrop content too, so their art has
            # to resolve and must not read as an orphan.
            for prop in layer.get("props") or []:
                name = prop.get("image", "")
                referenced.add(name)
                if name and not image_variants(directory, name):
                    problems.append(f"{os.path.basename(scene_path)}: prop "
                                    f"'{name}' on layer '{image}' has no art")
                if int(prop.get("count", 0)) <= 0:
                    notes.append(f"{os.path.basename(scene_path)}: prop '{name}' "
                                 f"has count 0, so it draws nothing")
                if float(prop.get("span", 0)) <= 0:
                    problems.append(f"{os.path.basename(scene_path)}: prop "
                                    f"'{name}' needs a positive span")
            for index, spec in enumerate(layer.get("frises") or []):
                for problem in ai_director.frise_problems(spec, index):
                    problems.append(f"{os.path.basename(scene_path)}: "
                                    f"layer '{image}' {problem}")
                for key in ("texture", "cap"):
                    art = spec.get(key)
                    if art:
                        referenced.add(art)
            variants = image_variants(directory, image)
            if not variants:
                problems.append(f"{os.path.basename(scene_path)}: layer '{image}' "
                                f"has no art")
                continue
            if not HAVE_PIL:
                continue
            scale = max(variants)
            size = size_of(variants[scale])
            if not size:
                continue
            # A dense layer reports more pixels for the same points; the scene
            # JSON says how dense, and the runtime divides it back out.
            density = float(layer.get("density", 3))
            points = size[0] / scale / (max(density, 0.1) / 3)
            # A backdrop layer does not need the character density. `FriezeBaker`
            # Gaussian-blurs each layer by its distance from the focus plane, so
            # a far ridge's fine detail is destroyed at load no matter how dense
            # the file was. What matters is that a layer be at least as sharp as
            # what survives that blur — flagging a layer *near the focus plane*
            # for being soft, and staying quiet about one that gets blurred to
            # mush anyway. This mirrors `art_director.layer_density`.
            blur = abs(float(layer.get("depth", 0)) - focus) * dof
            deserved = max(2.25, min(BACKDROP_CAP, BACKDROP_CAP / (1 + blur / 2)))
            if density < deserved * 0.9:
                notes.append(f"{os.path.basename(scene_path)}: layer '{image}' is "
                             f"{density:.2f} px/pt but sits {blur:.1f}pt from the "
                             f"focus plane's blur, which passes {deserved:.2f} "
                             f"px/pt of detail — it will look soft")
            # A layer that isn't tiled must cover the screen plus the parallax
            # travel it does, or its edge walks into frame — the single most
            # common backdrop bug, and invisible until a level gets long.
            rate = float(layer.get("depth", 0)) / focus
            needed = SCREEN_W + 2 * max(0.0, travel) * rate
            if not layer.get("tile") and points + 1 < needed:
                problems.append(
                    f"{os.path.basename(scene_path)}: layer '{image}' is "
                    f"{points:.0f}pt wide but needs {needed:.0f}pt at depth "
                    f"{layer.get('depth')} for a {level_width}-tile level "
                    f"(or set \"tile\": true)")


BEHAVIOUR_VERBS = {"wait", "telegraph", "patrol", "chase", "retreat", "leap", "shoot"}


def audit_behaviours(directory, problems, notes):
    """Behaviour graphs: structure, reachability, and no dead ends.

    Mirrors `BehaviourGraph.problems`. The two checks worth having are the ones a
    reader misses: a state nothing transitions *into* is behaviour the enemy can
    never show, and a state with no way *out* is a permanent freeze — both silent.
    """
    names = set()
    for path in sorted(glob.glob(os.path.join(directory, "behaviour_*.json"))):
        label = os.path.basename(path)
        try:
            with open(path) as f:
                graph = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{label}: unreadable ({e})")
            continue
        if graph.get("format") != "behaviour/1":
            problems.append(f"{label}: format is {graph.get('format')!r}, "
                            f"expected 'behaviour/1'")
            continue
        names.add(os.path.splitext(label)[0])
        states = graph.get("states") or []
        if not states:
            problems.append(f"{label}: no states")
            continue
        state_names = [s.get("name", "") for s in states]
        if len(state_names) != len(set(state_names)):
            problems.append(f"{label}: duplicate state names")
        initial = graph.get("initial") or state_names[0]
        if initial not in state_names:
            problems.append(f"{label}: initial state '{initial}' does not exist")
        for state in states:
            verb = (state.get("action") or {}).get("do")
            if verb not in BEHAVIOUR_VERBS:
                problems.append(f"{label}: state '{state.get('name')}' has unknown "
                                f"action {verb!r}")
        transitions = graph.get("transitions") or []
        for transition in transitions:
            if transition.get("from") != "*" \
                    and transition.get("from") not in state_names:
                problems.append(f"{label}: transition from unknown state "
                                f"{transition.get('from')!r}")
            if transition.get("to") not in state_names:
                problems.append(f"{label}: transition to unknown state "
                                f"{transition.get('to')!r}")
        reachable = {t.get("to") for t in transitions} | {initial}
        for name in state_names:
            if name not in reachable:
                problems.append(f"{label}: state '{name}' has no transition into it, "
                                f"so the enemy can never show it")
        sources = {t.get("from") for t in transitions}
        if "*" not in sources:
            for name in state_names:
                if name not in sources:
                    problems.append(f"{label}: state '{name}' has no transition out "
                                    f"of it — the enemy would freeze there")
    if not names:
        notes.append(f"{directory}: no behaviour/1 graphs — enemies use the built-in "
                     f"machine")
    return names


def audit_atlas(directory, rig_referenced, problems, notes, infos):
    """A packed atlas has to cover every image the rig names.

    A page that is missing a frame is worse than no page at all: the runtime falls
    back per-image, so the limb still draws and the only symptom is that the
    batching win quietly didn't happen. Returns the names the atlas accounts for,
    so they don't read as orphans.
    """
    accounted = set()
    for path in sorted(glob.glob(os.path.join(directory, "*_atlas.json"))):
        stem = os.path.basename(path)[: -len(".json")]
        try:
            with open(path) as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{os.path.basename(path)}: unreadable ({e})")
            continue
        if doc.get("format") != "atlas/1":
            continue
        accounted.add(stem)
        frames = set(doc.get("frames", {}))
        for page in doc.get("pages", []):
            page_stem = os.path.splitext(page)[0]
            accounted.add(page_stem)
            if not os.path.isfile(os.path.join(directory, page)):
                problems.append(f"{stem}: page '{page}' is missing")
        if doc.get("trimmed"):
            problems.append(f"{stem}: packed with trimming, which `PackedAtlas` "
                            f"refuses — repack without --trim")
        if len(doc.get("pages", [])) > 1:
            problems.append(f"{stem}: {len(doc['pages'])} pages; `PackedAtlas` "
                            f"handles one — raise --size")
        missing = rig_referenced - frames
        if missing:
            problems.append(f"{stem}: does not contain {sorted(missing)} — the rig "
                            f"would silently fall back to loose textures for them, "
                            f"so the batching win is lost")
        else:
            # An *info*, not a note: `--strict` fails on notes, and "the atlas is
            # complete" is a fact worth printing, never a reason to fail a build.
            infos.append(f"{stem}: {len(frames)} frame(s) cover every rig image "
                         f"({len(rig_referenced)} binds/frame become 1)")
    return accounted


def audit_audio(directory, swift_dir, problems, notes):
    """Every sound and track `Audio` declares has to be in the bundle.

    `Audio.play` is a deliberate no-op for a missing file, so a typo in a name is
    indistinguishable from a sound that has not been made yet — the exact failure
    this walks. Names are read out of the Swift so the list cannot drift.
    """
    source_path = os.path.join(swift_dir, "AudioManager.swift")
    try:
        with open(source_path) as f:
            source = f.read()
    except OSError:
        notes.append(f"{source_path}: not readable, so audio was not checked")
        return set()
    declared = set()
    for field in ("soundNames", "musicNames"):
        match = re.search(field + r"\s*=\s*\[(.*?)\]", source, re.S)
        if not match:
            problems.append(f"AudioManager.swift: no {field} to check against")
            continue
        for name in re.findall(r'"([^"]+)"', match.group(1)):
            declared.add(name)
            if not os.path.isfile(os.path.join(directory, f"{name}.wav")):
                problems.append(f"'{name}' is in {field} but {name}.wav is not in "
                                f"{os.path.basename(directory)} — it would play as "
                                f"silence, indistinguishable from a bug")
    for path in sorted(glob.glob(os.path.join(directory, "*.wav"))):
        name = os.path.basename(path)[:-4]
        if name not in declared:
            notes.append(f"{name}.wav is in the folder but nothing declares it")
    return declared


def audit_levels(directory, friezes_dir, problems, notes, tracks=frozenset(),
                 behaviours=frozenset()):
    """Level files: structure, design, and that the backdrop they name exists.

    The frieze reference is the one that bites — a level naming a backdrop that
    isn't bundled falls back to the procedural parallax, which looks like the
    hi-res art silently stopped working rather than like a typo.
    """
    import ai_director
    files, structural = ai_director.level_files(directory)
    problems.extend(structural)
    if not files:
        notes.append(f"{directory}: no level/1 files — the game will fall back to "
                     f"the compiled table in World/Levels.swift")
        return
    for doc in files:
        label = f"{doc['name']}.json"
        for problem in ai_director.validate_level(
                doc["rows"], ai_director.level_footprint(doc)):
            problems.append(f"{label}: {problem}")
        frieze = doc.get("frieze")
        if frieze and not os.path.isfile(os.path.join(friezes_dir, f"{frieze}.json")):
            problems.append(f"{label}: names backdrop '{frieze}', which is not in "
                            f"{os.path.basename(friezes_dir)} — the level would "
                            f"silently fall back to procedural parallax")
        # `level_files` already reported structural + frise problems; this pass
        # only adds what needs the surrounding directories to answer.
        for index, spec in enumerate(doc.get("frises", []) or []):
            for key in ("texture", "cap"):
                image = spec.get(key)
                terrain_dir = os.path.join(os.path.dirname(friezes_dir), "Terrain")
                if image and not image_variants(friezes_dir, image) \
                        and not image_variants(terrain_dir, image):
                    problems.append(f"{label}: frise {index} names {key} "
                                    f"'{image}', which is not bundled — the band "
                                    f"would fall back to a flat colour")
        wanted = doc.get("enemyBehaviour")
        if wanted and behaviours and wanted not in behaviours:
            problems.append(f"{label}: names enemy behaviour '{wanted}', which is not "
                            f"in Behaviours — the level would silently fall back to "
                            f"the built-in machine")
        track = doc.get("music")
        if track and tracks and track not in tracks:
            problems.append(f"{label}: names music '{track}', which `Audio` does "
                            f"not declare — the level would play in silence")


def find_orphans(directory, referenced, notes):
    for path in sorted(glob.glob(os.path.join(directory, "*.png"))):
        base = os.path.basename(path)
        name = base.rsplit(".", 1)[0]
        for scale in SCALES:
            name = name.replace(f"@{scale}x", "")
        if name in referenced:
            continue
        if name.endswith("_preview") or name.endswith("_scene") \
                or name.endswith("_ingest") or name.endswith("_n"):
            continue                          # tool output and normal maps
        notes.append(f"{base}: in the folder but nothing references it")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rigs", default=os.path.join(here, "..", "Assets", "Rigs"))
    ap.add_argument("--friezes", default=os.path.join(here, "..", "Assets", "Friezes"))
    ap.add_argument("--levels", default=os.path.join(here, "..", "Assets", "Levels"))
    ap.add_argument("--audio", default=os.path.join(here, "..", "Assets", "Audio"))
    ap.add_argument("--behaviours",
                    default=os.path.join(here, "..", "Assets", "Behaviours"))
    ap.add_argument("--swift", default=os.path.join(here, "..", "Core"),
                    help="where AudioManager.swift lives, for the declared names")
    ap.add_argument("--level-width", type=int, default=50,
                    help="widest level in tiles, for backdrop coverage")
    ap.add_argument("--strict", action="store_true",
                    help="treat advisory notes as failures too")
    args = ap.parse_args()

    # Backdrop coverage depends on the longest level, and now that levels are
    # files we can measure it instead of taking it on faith from a flag.
    if os.path.isdir(args.levels):
        sys.path.insert(0, here)
        try:
            import ai_director
            widest = max((max(len(r) for r in d["rows"])
                          for d in ai_director.level_files(args.levels)[0]),
                         default=0)
            if widest:
                args.level_width = max(args.level_width, widest)
        except Exception:
            pass                      # the flag default still applies

    problems, notes, infos, referenced = [], [], [], set()
    if os.path.isdir(args.rigs):
        audit_rigs(args.rigs, problems, notes, referenced)
        referenced |= audit_atlas(args.rigs, set(referenced), problems, notes, infos)
        find_orphans(args.rigs, referenced, notes)
    else:
        notes.append(f"{args.rigs}: not a directory")
    frieze_referenced = set()
    if os.path.isdir(args.friezes):
        audit_friezes(args.friezes, args.level_width, problems, notes,
                      frieze_referenced)
        find_orphans(args.friezes, frieze_referenced, notes)
    else:
        notes.append(f"{args.friezes}: not a directory")

    tracks = set()
    if os.path.isdir(args.audio):
        tracks = audit_audio(args.audio, args.swift, problems, notes)
    else:
        notes.append(f"{args.audio}: not a directory")

    behaviours = set()
    if os.path.isdir(args.behaviours):
        behaviours = audit_behaviours(args.behaviours, problems, notes)

    if os.path.isdir(args.levels):
        audit_levels(args.levels, args.friezes, problems, notes, tracks, behaviours)
    else:
        notes.append(f"{args.levels}: not a directory")

    if not HAVE_PIL:
        notes.append("Pillow is not installed, so image dimensions were not "
                     "checked (python3 -m pip install pillow)")

    for p in problems:
        print(f"  ✗ {p}")
    for n in notes:
        print(f"  • {n}")
    for i in infos:
        print(f"  · {i}")
    if not problems and not notes:
        print("✓ every referenced asset exists, at every scale, with matching aspects")
    elif not problems:
        print(f"\n✓ no failures ({len(notes)} advisory note(s))")
    else:
        print(f"\n{len(problems)} problem(s), {len(notes)} note(s)")
    return 1 if problems or (args.strict and notes) else 0


if __name__ == "__main__":
    sys.exit(main())
