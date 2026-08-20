#!/usr/bin/env python3
"""
ai_director.py — the AI end of the engine's machine-drivable surface.

The engine already exposes everything as data (`FriezeKit/Core/EngineAPI.swift`):
commands in, receipts and world snapshots out. This tool sits on the other side
of that boundary and turns a sentence into those documents:

    "a windy cliff level, three jumps, one boss"
        → {version:1, commands:[…]}   → validated → dropped in Documents/
    "a grumpy orange forest sprite"
        → art-spec/1                  → art_director.py → PNGs + Spine rig

Three things make it trustworthy rather than a slot machine:

  • **The engine describes itself.** Ops, parameter ranges and the tile alphabet
    come from `EngineOut/schema.json` (written by the running game) — so the
    model is constrained by *this build's* vocabulary, never a stale prompt.
  • **Structured output.** Responses are schema-constrained by the API, then
    re-validated here before anything reaches the engine.
  • **A closed loop.** Generated levels are checked against the design rules
    offline; violations go back to the model once as a repair brief. What lands
    on disk has already survived the same rules the engine applies.

Runs with no API key: every subcommand except `plan`/`art` is local, and both of
those fall back to a deterministic composer so the pipeline is demonstrable
offline — the same choice `AdsManager` makes with a stub ad network.

Usage:
    python3 ai_director.py plan "a cliff level with a boss" [--level 2] [--install]
    python3 ai_director.py art  "a grumpy orange forest sprite" --out ../Assets/Rigs
    python3 ai_director.py validate engine.json
    python3 ai_director.py install engine.json
    python3 ai_director.py state
    python3 ai_director.py serve            # localhost bridge for the HTML editors
"""
import argparse, glob, json, math, os, re, shutil, sys, textwrap

MODEL = "claude-opus-5"
MAX_TOKENS = 16000
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


# ─── engine vocabulary ───────────────────────────────────────────────────────

def documents_dir():
    """The app's Documents directory: the engine's inbox.

    Checked in order: $SKYRUNNER_DOCS, then the newest booted-simulator
    container that has an EngineOut in it, then the current directory.
    """
    override = os.environ.get("SKYRUNNER_DOCS")
    if override:
        return override
    pattern = os.path.expanduser(
        "~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/"
        "Application/*/Documents")
    candidates = [p for p in glob.glob(pattern) if os.path.isdir(p)]
    engine = [p for p in candidates if os.path.isdir(os.path.join(p, "EngineOut"))]
    pool = engine or candidates
    if pool:
        return max(pool, key=os.path.getmtime)
    return os.getcwd()


def engine_schema():
    """This build's op vocabulary, straight from the running engine when it has
    published one. Falls back to the bundled copy so the tool works before the
    game has ever been launched."""
    path = os.path.join(documents_dir(), "EngineOut", "schema.json")
    if os.path.isfile(path):
        try:
            with open(path) as f:
                return json.load(f), path
        except (OSError, json.JSONDecodeError):
            pass
    return FALLBACK_SCHEMA, "(bundled fallback)"


def engine_state():
    path = os.path.join(documents_dir(), "EngineOut", "state.json")
    if os.path.isfile(path):
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            return None
    return None


# Mirrors World/LevelRules.swift. Kept in step by hand, like the editor's copy —
# `EngineOut/schema.json` carries the authoritative table whenever the game has
# run, and `--schema-check` diffs this against it.
TILES = "XCSE^FNBMPDK./\\><!L#~@"
SOLID = set("XDMP/\\><!")
NEEDS_GROUND = set("SFE^NBDK!@")
NEEDS_AIR = set("MP#")
UNIQUE = set("SFK")
LIFTS = set("L~!")
# A space is an accepted spelling of empty; `normalize` folds it to ".". Mirrors
# `TileSymbol.accepted` — everything that writes rows writes them with spaces,
# because a grid of dots is unreadable.
ACCEPTED = set(TILES) | {" "}
MAX_ROWS, MAX_COLS = 64, 512
MAX_UP, MAX_ACROSS, MAX_DROP = 3, 4, 5
MAX_DASH_ACROSS, MAX_SPRING_UP = 7, 8

FALLBACK_SCHEMA = {
    "version": 1,
    "tiles": [{"symbol": c} for c in TILES],
    "ops": [{"op": o} for o in [
        "setLevel", "setTile", "fillRegion", "setSpawn", "spawnActor", "loadFrieze",
        "setLighting", "setTimeOfDay", "playAnimation", "setAnimationMix",
        "setColliderMode", "setGravity", "setRunSpeed", "setJumpVelocity",
        "setCameraLead", "showColliders", "setPostProcess", "setGrade",
        "editLevel", "reset", "reload"]],
}


# ─── offline validation (mirror of EngineScript + LevelRules) ────────────────

# ─── frises: spline-extruded terrain (mirror of FriezeKit/Frieze/Frise.swift) ──
#
# The tile grid stays the authority for design rules, so a level whose ground is a
# curve has to declare which cells that curve fills. This is that computation,
# ported so `make verify` and the editor answer exactly what the game will.

def _catmull(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    def axis(a, b, c, d):
        return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2
                      + (-a + 3 * b - 3 * c + d) * t3)
    return (axis(p0[0], p1[0], p2[0], p3[0]), axis(p0[1], p1[1], p2[1], p3[1]))


def frise_sample(control, closed=False, resolution=12):
    """Catmull-Rom through the control points — the curve passes through them."""
    if len(control) < 2:
        return list(control)
    steps = max(2, min(64, resolution))
    count = len(control)
    out = []
    last = count - 1 if closed else count - 2
    for index in range(max(0, last) + 1):
        if closed:
            p0 = control[(index - 1) % count]
            p1 = control[index % count]
            p2 = control[(index + 1) % count]
            p3 = control[(index + 2) % count]
        else:
            p0 = control[max(0, index - 1)]
            p1 = control[index]
            p2 = control[min(count - 1, index + 1)]
            p3 = control[min(count - 1, index + 2)]
        for step in range(steps):
            out.append(_catmull(p0, p1, p2, p3, step / steps))
    if not closed:
        out.append(tuple(control[-1]))
    return out


def frise_normals(curve, closed=False):
    out = []
    n = len(curve)
    for i in range(n):
        prev = curve[(i - 1) % n] if closed else curve[max(0, i - 1)]
        nxt = curve[(i + 1) % n] if closed else curve[min(n - 1, i + 1)]
        dx, dy = nxt[0] - prev[0], nxt[1] - prev[1]
        length = max(math.hypot(dx, dy), 1e-4)
        out.append((-dy / length, dx / length))
    return out


def frise_outline(spec):
    control = [(p[0], p[1]) for p in spec.get("points", []) if len(p) >= 2]
    closed = bool(spec.get("closed"))
    curve = frise_sample(control, closed, int(spec.get("resolution", 12)))
    if len(curve) < 2:
        return []
    thickness = float(spec.get("thickness", 80))
    ns = frise_normals(curve, closed)
    inner = [(c[0] - n[0] * thickness, c[1] - n[1] * thickness)
             for c, n in zip(curve, ns)]
    return curve if closed else curve + inner[::-1]


def _contains(polygon, point):
    """Even-odd ray cast, matching `Geometry2D.contains`."""
    x, y = point
    inside = False
    n = len(polygon)
    for i in range(n):
        ax, ay = polygon[i]
        bx, by = polygon[(i + 1) % n]
        if (ay > y) != (by > y):
            tx = ax + (y - ay) / (by - ay) * (bx - ax)
            if x < tx:
                inside = not inside
    return inside


def frise_footprint(spec, tile, rows, columns, origin_y):
    if spec.get("kind", "ground") == "decor":
        return set()
    polygon = frise_outline(spec)
    if len(polygon) < 3:
        return set()
    xs = [p[0] for p in polygon]
    ys = [p[1] for p in polygon]
    first_col = max(0, int(min(xs) / tile))
    last_col = min(columns - 1, int(max(xs) / tile))
    cells = set()
    for column in range(first_col, last_col + 1):
        for row in range(rows):
            cy = origin_y - (row + 0.5) * tile
            if cy < min(ys) or cy > max(ys):
                continue
            if _contains(polygon, ((column + 0.5) * tile, cy)):
                cells.add((column, row))
    return cells


def frise_problems(spec, index=0):
    """Mirror of `FriseSpec.problems`."""
    out = []
    label = f"frise {index} ({spec.get('kind', 'ground')})"
    control = [p for p in spec.get("points", []) if isinstance(p, list) and len(p) >= 2]
    if len(control) < 2:
        out.append(f"{label}: needs at least 2 control points, has {len(control)}")
    thickness = float(spec.get("thickness", 80))
    if thickness <= 0:
        out.append(f"{label}: thickness must be positive")
    cap = float(spec.get("capHeight", 14))
    if cap < 0:
        out.append(f"{label}: capHeight cannot be negative")
    if cap > thickness:
        out.append(f"{label}: capHeight {cap} exceeds thickness {thickness}")
    if spec.get("kind", "ground") not in ("ground", "platform", "decor"):
        out.append(f"{label}: kind must be ground, platform or decor")
    curve = frise_sample([(p[0], p[1]) for p in control], bool(spec.get("closed")),
                         int(spec.get("resolution", 12)))
    radius = _tightest_radius(curve)
    if radius is not None and radius < thickness:
        out.append(f"{label}: thickness {int(thickness)} exceeds the tightest curve "
                   f"radius ({int(radius)}) — the band self-intersects")
    return out


def _tightest_radius(curve):
    if len(curve) < 3:
        return None
    tightest = None
    for i in range(1, len(curve) - 1):
        a, b, c = curve[i - 1], curve[i], curve[i + 1]
        ab = math.hypot(b[0] - a[0], b[1] - a[1])
        bc = math.hypot(c[0] - b[0], c[1] - b[1])
        ca = math.hypot(a[0] - c[0], a[1] - c[1])
        area = abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2
        if area <= 0.01:
            continue
        r = ab * bc * ca / (4 * area)
        tightest = r if tightest is None else min(tightest, r)
    return tightest


def level_footprint(doc, tile=40.0):
    """Every cell the document's frises make solid."""
    rows = normalize(doc.get("rows", []))
    if not rows:
        return set()
    columns = max(len(r) for r in rows)
    origin_y = len(rows) * tile
    cells = set()
    for spec in doc.get("frises", []) or []:
        cells |= frise_footprint(spec, tile, len(rows), columns, origin_y)
    return cells


def normalize(rows):
    """Pad to the widest row and canonicalise empty to ".".

    Mirrors `LevelRules.normalize`. Both halves matter: ragged rows index out of
    bounds during the build, and mixed spelling of empty makes the same level
    compare unequal to itself depending on which tool touched it last.
    """
    width = max((len(r) for r in rows), default=0)
    return [r.replace(" ", ".") + "." * (width - len(r)) for r in rows]


def validate_level(rows, solid_cells=frozenset()):
    """Design-rule violations, in the same words the engine uses.

    `solid_cells` is `(column, row)` cells a frise makes solid even though the
    glyph grid says air — see `LevelRules.validate(_:solidCells:)`.
    """
    out = []
    rows = normalize(rows)
    if not rows or not rows[0]:
        return ["level is empty"]
    height, width = len(rows), len(rows[0])

    # An unknown glyph builds as empty air, so a typo silently removes a
    # platform. The command API refuses one at its boundary; a hand-written level
    # file never passed through that check.
    seen_bad = {}
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            if ch not in ACCEPTED and ch not in seen_bad:
                seen_bad[ch] = (c, r)
    for ch, (c, r) in sorted(seen_bad.items()):
        out.append(f"unknown tile {ch!r} at column {c}, row {r} — legal symbols "
                   f"are {TILES}")

    def at(c, r):
        if not (0 <= r < height and 0 <= c < width):
            return "."
        glyph = rows[r][c]
        # A frise's footprint is solid ground even where the grid says air. Only
        # empty cells are filled in, so an author's explicit glyph always wins.
        if glyph == "." and (c, r) in solid_cells:
            return "X"
        return glyph

    pos = {}
    for r in range(height):
        for c in range(width):
            ch = at(c, r)
            if ch != ".":
                pos.setdefault(ch, []).append((c, r))

    spawns = len(pos.get("S", []))
    if spawns == 0:
        out.append("no spawn: add exactly one S")
    if spawns > 1:
        out.append(f"{spawns} spawns: exactly one S is allowed")
    goals, bosses = len(pos.get("F", [])), len(pos.get("K", []))
    if goals == 0 and bosses == 0:
        out.append("no exit: add one F, or one K for a boss level")
    if goals > 1:
        out.append(f"{goals} goals: exactly one F is allowed")
    if bosses > 1:
        out.append(f"{bosses} bosses: exactly one K is allowed")
    if goals and bosses:
        out.append("boss levels have no static F — the portal appears when K goes down")

    for sym in NEEDS_GROUND:
        for (c, r) in pos.get(sym, []):
            if r + 1 >= height:
                out.append(f"'{sym}' at ({c},{r}) is on the bottom row — nothing under it")
            elif at(c, r + 1) not in SOLID:
                out.append(f"'{sym}' at ({c},{r}) has no ground below")
    for sym in NEEDS_AIR:
        for (c, r) in pos.get(sym, []):
            if r + 1 < height and at(c, r + 1) in SOLID:
                out.append(f"'{sym}' at ({c},{r}) sits on ground — platforms must hang")
    for (c, r) in pos.get("^", []):
        for dr in (1, 2):
            if r - dr >= 0 and at(c, r - dr) in SOLID:
                out.append(f"crystal at ({c},{r}) has a ceiling {dr} tile(s) above "
                           f"— unjumpable")
                break

    floor, run, saw = height - 1, 0, False
    for c in range(width):
        if at(c, floor) in SOLID:
            if saw and run > MAX_DASH_ACROSS - 1:
                out.append(f"floor gap of {run} tiles at column {c - run} — "
                           f"{MAX_DASH_ACROSS - 1} is the most a dash can clear")
            saw, run = True, 0
        elif saw:
            run += 1

    out += reachability(rows, pos, width, height, solid_cells)
    return out


def reachability(rows, pos, width, height, solid_cells=frozenset()):
    """Optimistic flood fill from the spawn — it can call an impossible level
    possible, never the reverse."""
    if "S" not in pos or not ("F" in pos or "K" in pos):
        return []
    start = pos["S"][0]
    exit_ = (pos.get("F") or pos.get("K"))[0]

    def at(c, r):
        if not (0 <= r < height and 0 <= c < width):
            return "."
        glyph = rows[r][c]
        # A frise's footprint is solid ground even where the grid says air. Only
        # empty cells are filled in, so an author's explicit glyph always wins.
        if glyph == "." and (c, r) in solid_cells:
            return "X"
        return glyph

    def standable(c, r):
        if not (0 <= c < width and 0 <= r < height):
            return False
        if at(c, r) in ("X", "D"):
            return False
        if at(c, r) in LIFTS:
            return True
        return at(c, r + 1) in SOLID

    origin = next(((start[0], start[1] + dr) for dr in range(4)
                   if standable(start[0], start[1] + dr)), None)
    if origin is None:
        return [f"spawn at {start} has no floor to stand on"]

    seen, stack = {origin}, [origin]
    while stack:
        c, r = stack.pop()
        if abs(c - exit_[0]) <= 1 and abs(r - exit_[1]) <= 1:
            return []
        nxt = []
        for dc in (-1, 1):
            if standable(c + dc, r):
                nxt.append((c + dc, r))
        for dr in range(0, MAX_UP + 1):
            for dc in range(-MAX_ACROSS, MAX_ACROSS + 1):
                if standable(c + dc, r - dr):
                    nxt.append((c + dc, r - dr))
        # dash: further across, no height gain of its own
        for dr in (0, 1):
            for dc in range(-MAX_DASH_ACROSS, MAX_DASH_ACROSS + 1):
                if standable(c + dc, r - dr):
                    nxt.append((c + dc, r - dr))
        # springs throw you far higher than a jump
        if at(c, r + 1) == "!" or at(c, r) == "!":
            for dr in range(1, MAX_SPRING_UP + 1):
                for dc in range(-MAX_ACROSS, MAX_ACROSS + 1):
                    if standable(c + dc, r - dr):
                        nxt.append((c + dc, r - dr))
        # vines and updrafts: ride the column, step off either side
        if at(c, r) in LIFTS:
            rr = r
            while rr > 0 and at(c, rr - 1) in LIFTS:
                rr -= 1
                nxt.append((c, rr))
                for dc in (-1, 1):
                    if standable(c + dc, rr):
                        nxt.append((c + dc, rr))
        for dc in (-1, 1):
            if at(c + dc, r) in LIFTS:
                nxt.append((c + dc, r))
        for dc in range(-MAX_DROP, MAX_DROP + 1):
            cc = c + dc
            if not 0 <= cc < width:
                continue
            rr = r + 1
            while rr < height:
                if standable(cc, rr):
                    nxt.append((cc, rr)); break
                if at(cc, rr) in SOLID:
                    break
                rr += 1
        for p in nxt:
            if p not in seen:
                seen.add(p); stack.append(p)
    what = "goal" if pos.get("F") else "boss"
    return [f"{what} at {exit_} is not reachable from the spawn "
            f"(≤{MAX_UP} tiles up, ≤{MAX_ACROSS} across per jump)"]


def validate_document(doc):
    """Structure + design rules. Errors block; warnings are advisory, exactly as
    the engine treats them."""
    errors, warnings = [], []
    if not isinstance(doc, dict):
        return ["document is not an object"], []
    if doc.get("version") != 1:
        errors.append(f"version must be 1, got {doc.get('version')!r}")
    commands = doc.get("commands")
    if not isinstance(commands, list) or not commands:
        return errors + ["commands must be a non-empty array"], []

    schema, _ = engine_schema()
    known = {o["op"] for o in schema.get("ops", [])}
    for i, cmd in enumerate(commands):
        if not isinstance(cmd, dict) or "op" not in cmd:
            errors.append(f"command {i}: missing op"); continue
        op = cmd["op"]
        if known and op not in known:
            errors.append(f"command {i}: unknown op '{op}' "
                          f"(this build knows {sorted(known)})")
            continue
        if op == "setLevel":
            rows = cmd.get("rows")
            if not isinstance(rows, list) or not rows or \
                    not all(isinstance(r, str) for r in rows):
                errors.append(f"command {i}: rows must be a non-empty string array")
                continue
            if len(rows) > MAX_ROWS or any(len(r) > MAX_COLS for r in rows):
                errors.append(f"command {i}: level exceeds {MAX_ROWS}×{MAX_COLS}")
            illegal = {ch for r in rows for ch in r} - set(TILES)
            if illegal:
                errors.append(f"command {i}: unknown tile symbol(s) {sorted(illegal)}")
            else:
                warnings += validate_level(rows)
        elif op in ("setTile", "setSpawn", "spawnActor", "fillRegion"):
            for field in ("col", "row"):
                v = cmd.get(field)
                if not isinstance(v, (int, float)) or v < 0:
                    errors.append(f"command {i}: {field} must be a non-negative number")
            if op in ("setTile", "fillRegion") and cmd.get("symbol") not in list(TILES):
                errors.append(f"command {i}: symbol must be one of {TILES}")
    return errors, warnings


# ─── the model ───────────────────────────────────────────────────────────────

LEVEL_SCHEMA = {
    "type": "object",
    "properties": {
        "version": {"const": 1},
        "notes": {"type": "string", "description": "one line on the design intent"},
        "commands": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "op": {"type": "string"},
                    "rows": {"type": "array", "items": {"type": "string"}},
                    "col": {"type": "integer"}, "row": {"type": "integer"},
                    "width": {"type": "integer"}, "height": {"type": "integer"},
                    "symbol": {"type": "string"},
                    "kind": {"type": "string"}, "name": {"type": "string"},
                    "value": {"type": "number"}, "t": {"type": "number"},
                    "mode": {"type": "string"},
                },
                "required": ["op"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["version", "commands"],
    "additionalProperties": False,
}


def system_prompt(schema):
    """The engine's own vocabulary as the stable prefix — cached, so a repair
    round costs a fraction of the first call."""
    return textwrap.dedent(f"""\
        You author content for a 2D platformer engine in the UbiArt tradition
        (Rayman-style): ASCII tile levels applied through a command API.

        Answer only with a command document for this build. Its published
        vocabulary follows — treat it as the only legal ops, symbols and ranges.

        {json.dumps(schema, indent=1)}

        Level authoring rules, all enforced before your output is accepted:
          • row 0 is the TOP of the level; the last row is the floor
          • exactly one S; exactly one F, or exactly one K and no F
          • S F E ^ N B D K need solid ground directly below; M and P must hang
          • a jump clears at most {MAX_ACROSS - 1} empty floor tiles and rises
            at most {MAX_UP} tiles, so keep every gap and climb inside that
          • never put a crystal (^) under a ceiling within 2 tiles — unjumpable
          • the goal must be reachable from the spawn
          • all rows the same length; '.' is empty

        Design like a level designer, not a random generator: teach one idea at
        a time, place coins on the line the player will already travel, and put
        hazards where a mistake costs a retry rather than a life. Nine rows and
        40–50 columns reads well on the 844×390 camera.
        """)


def call_claude(brief, schema_obj, output_schema, extra_context=""):
    """One structured request. Returns (parsed_json, note) or raises RuntimeError."""
    try:
        import anthropic
    except ImportError:
        raise RuntimeError("the anthropic SDK is not installed "
                           "(python3 -m pip install anthropic)")

    client = anthropic.Anthropic()
    system = [{
        "type": "text",
        "text": system_prompt(schema_obj),
        # The vocabulary is large and identical between the first call and the
        # repair round; cache it so the retry is nearly free.
        "cache_control": {"type": "ephemeral"},
    }]
    user = brief if not extra_context else f"{brief}\n\n{extra_context}"

    try:
        response = client.beta.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=system,
            messages=[{"role": "user", "content": user}],
            output_config={"format": {"type": "json_schema", "schema": output_schema}},
            # Safety classifiers can decline a request; a fallback model answers
            # it in the same call instead of handing back an empty response.
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
    except anthropic.NotFoundError as e:
        raise RuntimeError(f"model '{MODEL}' not available to this key: {e}")
    except anthropic.RateLimitError as e:
        raise RuntimeError(f"rate limited — retry shortly: {e}")
    except anthropic.APIStatusError as e:
        raise RuntimeError(f"API error {e.status_code}: {e.message}")
    except anthropic.APIConnectionError as e:
        raise RuntimeError(f"could not reach the API: {e}")

    if response.stop_reason == "refusal":
        detail = getattr(response, "stop_details", None)
        raise RuntimeError("the request was declined by safety classifiers"
                           + (f" ({detail.category})" if detail else ""))

    text = next((b.text for b in response.content if b.type == "text"), "")
    if not text:
        raise RuntimeError("empty response")
    try:
        return json.loads(text), f"{response.model}, {response.usage.output_tokens} tokens out"
    except json.JSONDecodeError as e:
        raise RuntimeError(f"response was not JSON despite the schema: {e}")


# ─── offline composer (no key, no network) ───────────────────────────────────

def compose_offline(brief):
    """A deterministic level built from the brief's keywords.

    Not an imitation of the model — a legible fallback so the whole pipeline
    (validate → install → hot reload) can be exercised and demonstrated without
    credentials, and so tests have something stable to assert on.
    """
    words = brief.lower()
    cols = 46
    rows = ["." * cols for _ in range(8)]
    floor = list("X" * cols)

    # pits: one per "jump"/"gap" mention, three tiles wide (the documented max)
    pits = 1 + words.count("jump") + words.count("gap")
    for i in range(min(pits, 3)):
        start = 12 + i * 12
        for c in range(start, min(start + 3, cols - 6)):
            floor[c] = "."
    rows.append("".join(floor))

    grid = [list(r) for r in rows]
    boss = "boss" in words or "king" in words
    grid[7][2] = "S"
    if boss:
        grid[7][cols // 2] = "K"
    else:
        grid[7][cols - 4] = "F"

    # a ledge with a coin over each pit shoulder, always inside the jump envelope
    for i in range(min(pits, 3)):
        c = 12 + i * 12
        if c + 4 < cols - 6:
            for k in range(3):
                grid[5][c + 3 + k] = "X"
            grid[4][c + 4] = "C"
    if "enemy" in words or "enemies" in words or "danger" in words:
        for c in (20, 32):
            if grid[8][c] == "X" and grid[7][c] == ".":
                grid[7][c] = "E"
    if "spike" in words or "crystal" in words or "hazard" in words:
        # A crystal under a ledge can't be jumped, so check headroom first —
        # the composer obeys the same rules it validates against.
        placed = 0
        for c in range(5, cols - 6):
            if placed >= 2:
                break
            if grid[8][c] != "X" or grid[7][c] != ".":
                continue
            if any(grid[7 - dr][c] in SOLID for dr in (1, 2)):
                continue
            if any(grid[7][c + dc] not in "." for dc in (-1, 1)
                   if 0 <= c + dc < cols):
                continue
            grid[7][c] = "^"
            placed += 1
    if "villager" in words or "friend" in words:
        if grid[8][6] == "X" and grid[7][6] == ".":
            grid[7][6] = "N"

    rows = ["".join(r) for r in grid]
    doc = {"version": 1,
           "notes": f"offline composer: {'boss arena' if boss else 'traversal'} "
                    f"with {min(pits, 3)} pit(s)",
           "commands": [{"op": "setLevel", "rows": rows}]}
    if "dusk" in words or "sunset" in words or "evening" in words:
        doc["commands"].append({"op": "setTimeOfDay", "t": 0.92})
    elif "dawn" in words or "morning" in words:
        doc["commands"].append({"op": "setTimeOfDay", "t": 0.08})
    return doc


def compose_art_offline(brief):
    """The stock Rayman-style spec, tinted by the brief's colour words."""
    import art_director
    spec = json.loads(json.dumps(art_director.DEFAULT_SPEC))
    words = brief.lower()
    tints = {
        "blue": [64, 132, 236], "green": [86, 186, 92], "purple": [150, 96, 226],
        "red": [226, 74, 62], "pink": [246, 128, 178], "yellow": [246, 200, 62],
        "teal": [58, 190, 178], "orange": [255, 148, 26],
    }
    for word, rgb in tints.items():
        if word in words:
            spec["style"]["palette"]["skin"] = rgb
            spec["style"]["palette"]["hair"] = [min(255, int(c * 1.12)) for c in rgb]
            break
    # Name the asset after the descriptive words, not the article — "a grumpy
    # purple sprite" should not produce files called a_body@3x.png.
    stop = {"a", "an", "the", "some", "with", "and", "very", "really", "kind",
            "of", "in", "on", "for", "that", "this"}
    words_list = [w for w in "".join(
        c if c.isalnum() or c.isspace() else " " for c in words).split()
        if w not in stop]
    spec["name"] = "_".join(words_list[:2]) or "actor"
    if "grumpy" in words or "angry" in words:
        spec["personality"] = {"bounce": 0.6, "swagger": 1.4, "squash": 0.8}
    elif "bouncy" in words or "happy" in words or "cheerful" in words:
        spec["personality"] = {"bounce": 1.5, "swagger": 1.2, "squash": 1.4}
    return spec


def part_data_urls(spec, out_dir, scale=3):
    """The generated part PNGs as data URLs, keyed by attachment name.

    The rig editor is a static file with no filesystem access, so this is how
    freshly generated art reaches its canvas.
    """
    import base64
    images = {}
    for part in spec.get("parts", []):
        path = os.path.join(out_dir, f"{spec['name']}_{part['name']}@{scale}x.png")
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            blob = base64.b64encode(f.read()).decode()
        images[f"{spec['name']}_{part['name']}"] = "data:image/png;base64," + blob
    return images


# ─── reference images ────────────────────────────────────────────────────────

def read_reference(path, samples=24000):
    """Measure a reference screenshot: palette by depth band, sky gradient, haze,
    and which way the light comes from.

    This is the non-designer's entry point. Picking four foliage greens that sit
    right against each other is a skill; measuring them off a frame you already
    like is arithmetic. Runs with no API key — vision only *adds* naming and
    layout on top of these numbers.
    """
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        raise RuntimeError("reading a reference needs Pillow and numpy "
                           "(python3 -m pip install pillow numpy)")

    img = Image.open(path).convert("RGB")
    w, h = img.size
    small = img.resize((min(w, 320), max(1, int(min(w, 320) * h / w))), Image.LANCZOS)
    a = np.asarray(small, dtype=np.float32)
    sh, sw = a.shape[:2]

    def cluster(block, k=3, rounds=8):
        """Tiny k-means — no scikit dependency for what is a few hundred pixels."""
        flat = block.reshape(-1, 3)
        if len(flat) > samples:
            idx = np.linspace(0, len(flat) - 1, samples).astype(int)
            flat = flat[idx]
        # seed on luminance quantiles so clusters come out dark→light, stably
        lum = flat @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
        centres = np.stack([flat[np.argsort(lum)[int(q * (len(flat) - 1))]]
                            for q in np.linspace(0.15, 0.85, k)])
        for _ in range(rounds):
            d = ((flat[:, None, :] - centres[None]) ** 2).sum(-1)
            who = d.argmin(1)
            for i in range(k):
                if (who == i).any():
                    centres[i] = flat[who == i].mean(0)
        order = np.argsort(centres @ np.array([0.299, 0.587, 0.114], dtype=np.float32))
        return [[int(v) for v in centres[i]] for i in order]

    # Depth bands: in a side-scroller the far plane sits high in frame, the
    # gameplay plane across the middle, the foreground low and at the edges.
    far = cluster(a[: int(sh * 0.45)], k=2)
    mid = cluster(a[int(sh * 0.35): int(sh * 0.75)], k=3)
    edge = max(1, int(sw * 0.08))
    near = cluster(np.concatenate([a[int(sh * 0.7):].reshape(-1, 3),
                                   a[:, :edge].reshape(-1, 3),
                                   a[:, -edge:].reshape(-1, 3)]), k=2)

    # Sky gradient: median colour of the top rows, bottom → top for FriezeScene.
    rows = [a[int(sh * f): int(sh * f) + max(1, sh // 24)].reshape(-1, 3).mean(0)
            for f in (0.30, 0.18, 0.06)]
    sky = [[int(v) for v in r] for r in rows]

    # Haze: how much contrast the far band has lost relative to the near band.
    def spread(block):
        return float(block.reshape(-1, 3).std())
    far_spread, near_spread = spread(a[: int(sh * 0.4)]), spread(a[int(sh * 0.6):])
    haze = float(max(0.15, min(0.85, 1 - far_spread / max(near_spread, 1e-3))))

    # Light direction: compare mean luminance of the left and right thirds.
    lum = a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    left, right = lum[:, : sw // 3].mean(), lum[:, -sw // 3:].mean()
    top, bottom = lum[: sh // 3].mean(), lum[-sh // 3:].mean()
    angle = math.degrees(math.atan2(max(top - bottom, 1.0), (right - left) or 1.0))
    angle = float((angle + 360) % 360)

    accent = max(mid + near, key=lambda c: sum(c))          # brightest sampled tone
    return {
        "palette": {
            "far": far[0], "mid": mid[1], "near": near[0],
            "trunk": mid[0], "accent": accent,
            # a warm dark ink, keyed off the darkest sampled tone
            "outline": [max(18, int(mid[0][0] * 0.45)), max(12, int(mid[0][1] * 0.35)),
                        max(8, int(mid[0][2] * 0.30))],
        },
        "sky": sky,
        "haze": round(haze, 3),
        "lightAngle": round(angle, 1),
        "size": [w, h],
    }


def frieze_spec_from_reference(name, measured, vision=None):
    """Measured numbers (+ optional vision notes) → a frieze-spec/1.

    The layer stack is the Rayman-ish default — far ridge, canopy overhead,
    trunks at the gameplay plane, vines in front — because that reads as depth
    for almost any jungle-ish reference. Vision can override it.
    """
    palette = dict(measured["palette"])
    spec = {
        "format": "frieze-spec/1",
        "name": name,
        "sky": measured["sky"],
        "palette": palette,
        # A haze floor: a reference may be shot in clear air, but a *layered*
        # backdrop needs some atmosphere or the far planes read as stickers.
        "haze": max(measured["haze"], 0.45),
        "focus": 0.55,
        "dofPointsPerDepth": 5.0,
        "vignette": 0.46,
        "lightAngle": measured["lightAngle"],
        "layers": [
            {"kind": "glow",   "depth": 0.04, "color": "accent", "y": 40, "height": 390},
            # tall and hung low: a silhouette layer whose *own* bottom edge lands
            # inside the frame shows up as a horizontal cut across the picture
            {"kind": "ridge",  "depth": 0.12, "color": "far",   "y": -150, "height": 560},
            {"kind": "canopy", "depth": 0.22, "color": "far",   "y": 150, "height": 240},
            {"kind": "fog",    "depth": 0.34, "color": "accent", "y": 30, "height": 200},
            {"kind": "trunks", "depth": 0.46, "color": "trunk", "y": 0,   "height": 420},
            {"kind": "canopy", "depth": 0.62, "color": "mid",   "y": 170, "height": 220},
            {"kind": "vines",  "depth": 0.88, "color": "near",  "y": 120, "height": 300},
        ],
        "rays": True,
        "fireflies": True,
    }
    if vision:
        for key in ("focus", "haze", "vignette", "rays", "fireflies"):
            if key in vision:
                spec[key] = vision[key]
        if isinstance(vision.get("layers"), list) and vision["layers"]:
            spec["layers"] = [l for l in vision["layers"] if l.get("color") in palette]
        if isinstance(vision.get("palette"), dict):
            # vision may *name* extra tones; measured values still win for the
            # ones it measured, because a screenshot is ground truth
            for k, v in vision["palette"].items():
                palette.setdefault(k, v)
    return spec


VISION_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "description": "identifier for this scene"},
        "mood": {"type": "string", "description": "one line on the atmosphere"},
        "focus": {"type": "number"}, "haze": {"type": "number"},
        "vignette": {"type": "number"},
        "rays": {"type": "boolean"}, "fireflies": {"type": "boolean"},
        "layers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string",
                             "enum": ["canopy", "ridge", "trunks", "vines", "fog"]},
                    "depth": {"type": "number"},
                    "color": {"type": "string",
                              "enum": ["far", "mid", "near", "trunk", "accent"]},
                    "y": {"type": "number"}, "height": {"type": "number"},
                },
                "required": ["kind", "depth", "color"],
            },
        },
        "level": {
            "type": "object",
            "description": "a playable layout in the spirit of the reference",
            "properties": {"rows": {"type": "array", "items": {"type": "string"}}},
        },
    },
    "required": ["name"],
}


def call_vision(image_path, measured, schema_obj):
    """Ask the model to read the reference and name what it sees.

    Only the *interpretation* is delegated — palette and haze are measured from
    the pixels, because a model asked to guess hex values will drift, while a
    model asked "what is the layer structure and mood here" is on solid ground.
    """
    try:
        import anthropic
    except ImportError:
        raise RuntimeError("the anthropic SDK is not installed")
    import base64
    import mimetypes

    media = mimetypes.guess_type(image_path)[0] or "image/png"
    if media not in ("image/png", "image/jpeg", "image/gif", "image/webp"):
        raise RuntimeError(f"unsupported image type {media}")
    with open(image_path, "rb") as f:
        data = base64.standard_b64encode(f.read()).decode()

    client = anthropic.Anthropic()
    prompt = textwrap.dedent(f"""\
        This is a reference frame from a 2D platformer. I have already *measured*
        its palette, sky gradient, haze and light direction from the pixels:

        {json.dumps(measured, indent=1)}

        Describe the scene as a layer stack my engine can build. Use only the
        palette keys above for `color`. Depth is 0 (far) to 1 (near), with the
        gameplay plane at `focus`; put overhead foliage high and in front, the
        silhouetted ridge far back, trunks near the play plane. Also propose a
        playable level in the spirit of the frame as `level.rows` — ASCII tiles,
        symbols {TILES}, row 0 at the top, one S, one F, gaps of at most
        {MAX_ACROSS - 1} tiles, climbs of at most {MAX_UP}.
        """)
    try:
        response = client.beta.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64",
                                             "media_type": media, "data": data}},
                {"type": "text", "text": prompt},
            ]}],
            output_config={"format": {"type": "json_schema", "schema": schema_obj}},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
    except anthropic.APIStatusError as e:
        raise RuntimeError(f"API error {e.status_code}: {e.message}")
    except anthropic.APIConnectionError as e:
        raise RuntimeError(f"could not reach the API: {e}")
    if response.stop_reason == "refusal":
        raise RuntimeError("the request was declined by safety classifiers")
    text = next((b.text for b in response.content if b.type == "text"), "")
    if not text:
        raise RuntimeError("empty response")
    return json.loads(text), f"{response.model}, {response.usage.output_tokens} tokens out"


def cmd_reference(args):
    """A reference frame → a matching backdrop, character palette, and level.

    The whole point: you pick a screenshot you like, and the engine's own
    generators produce assets that sit in that world. Palette and atmosphere are
    *measured* from the image; the model (when available) names the layer
    structure and proposes a layout.
    """
    import art_director
    measured = read_reference(args.image)
    name = args.name or os.path.splitext(os.path.basename(args.image))[0]
    name = "".join(c if c.isalnum() or c == "_" else "_" for c in name).strip("_").lower()
    print(f"measured {args.image}:")
    print(f"  palette      {json.dumps(measured['palette'])}")
    print(f"  sky (b→t)    {measured['sky']}")
    print(f"  haze         {measured['haze']}   light {measured['lightAngle']}°")

    vision = None
    if not args.no_vision:
        try:
            vision, note = call_vision(args.image, measured, VISION_SCHEMA)
            print(f"  vision       {note}")
            if vision.get("mood"):
                print(f"  mood         {vision['mood']}")
        except RuntimeError as e:
            print(f"  vision       unavailable ({e}) — using the measured "
                  f"numbers and the default layer stack", file=sys.stderr)

    os.makedirs(args.out, exist_ok=True)
    spec = frieze_spec_from_reference(name, measured, vision)
    spec_path = os.path.join(args.out, f"{name}.friezespec.json")
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=2)
    print(f"\nwrote {spec_path}")

    written, problems, notes = art_director.build_frieze(spec, args.out)
    if problems:
        for p in problems:
            print("  ✗", p, file=sys.stderr)
        return 1
    for path in written:
        print(f"wrote {path}")
    for n in notes:
        print(f"note: {n}", file=sys.stderr)

    # A character palette drawn from the same measurements, so the hero belongs
    # in the scene instead of being dropped into it.
    art = json.loads(json.dumps(art_director.DEFAULT_SPEC))
    art["name"] = f"{name}_hero"
    art["style"]["palette"].update({
        "skin": measured["palette"]["accent"],
        "hair": measured["palette"]["near"],
        "cream": [min(255, c + 46) for c in measured["palette"]["accent"]],
        "shoe": measured["palette"]["trunk"],
        "outline": measured["palette"]["outline"],
    })
    art["style"]["lightAngle"] = measured["lightAngle"]
    if args.hero:
        art_path = os.path.join(args.out, f"{art['name']}.artspec.json")
        with open(art_path, "w") as f:
            json.dump(art, f, indent=2)
        hero_written, hero_bad, hero_notes = art_director.build(
            art, args.out, preview=True)
        if hero_bad:
            for p in hero_bad:
                print("  ✗", p, file=sys.stderr)
        for path in [art_path] + hero_written:
            print(f"wrote {path}")
        for n in hero_notes:
            print(f"note: {n}", file=sys.stderr)

    # The layout, if the model proposed one — validated like any other document.
    rows = (vision or {}).get("level", {}).get("rows")
    if rows:
        doc = {"version": 1,
               "notes": (vision.get("mood") or "from reference"),
               "commands": [{"op": "setLevel", "rows": rows},
                            {"op": "loadFrieze", "name": name}]}
        errors, warnings = validate_document(doc)
        if errors:
            print("\nproposed level rejected:", file=sys.stderr)
            for m in errors:
                print("  ✗", m, file=sys.stderr)
        else:
            doc_path = os.path.join(args.out, f"{name}.engine.json")
            with open(doc_path, "w") as f:
                json.dump(doc, f, indent=1)
            print(f"wrote {doc_path}")
            for row in rows:
                print("  " + row)
            for m in warnings:
                print("  •", m)

    print(f"\nDrop the @2x/@3x PNGs and {name}.json into Assets/Friezes/, then "
          f"`loadFrieze` (or the generated engine.json) switches the game to it.")
    return 0


# ─── subcommands ─────────────────────────────────────────────────────────────

def cmd_plan(args):
    schema, source = engine_schema()
    state = engine_state()
    context = ""
    if state:
        level = state.get("level", {})
        context = ("Current world state (edit this level unless told otherwise):\n"
                   + json.dumps({"index": level.get("index"),
                                 "size": level.get("size"),
                                 "rows": level.get("rows")}, indent=1))
    print(f"vocabulary: {source}")

    try:
        doc, note = call_claude(args.brief, schema, LEVEL_SCHEMA, context)
        print(f"model: {note}")
    except RuntimeError as e:
        print(f"model unavailable ({e})\nfalling back to the offline composer.",
              file=sys.stderr)
        doc = compose_offline(args.brief)

    errors, warnings = validate_document(doc)
    if (errors or warnings) and args.repair and os.environ.get("ANTHROPIC_API_KEY"):
        print(f"first pass: {len(errors)} error(s), {len(warnings)} warning(s) "
              f"— asking for one repair round")
        violations = "\n".join(f"  • {m}" for m in errors + warnings)
        try:
            doc, note = call_claude(
                args.brief, schema, LEVEL_SCHEMA,
                "Your previous document broke these rules:\n" + violations
                + "\n\nHere it is:\n" + json.dumps(doc)
                + "\n\nReturn a corrected document. Fix every point above and "
                  "change nothing else.")
            print(f"repair: {note}")
            errors, warnings = validate_document(doc)
        except RuntimeError as e:
            print(f"repair round failed ({e}); keeping the first document",
                  file=sys.stderr)

    report(errors, warnings)
    if errors:
        return 1

    with open(args.out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"\nwrote {args.out}")
    if doc.get("notes"):
        print(f"intent: {doc['notes']}")
    for cmd in doc["commands"]:
        if cmd["op"] == "setLevel":
            print()
            for row in cmd["rows"]:
                print("  " + row)
    if args.install:
        cmd_install(argparse.Namespace(file=args.out))
    return 0


def cmd_art(args):
    import art_director
    schema, _ = engine_schema()
    try:
        spec, note = call_claude(
            "Design a character for a Rayman-style 2D platformer: " + args.brief
            + "\n\nReturn an art-spec/1 document. Choose a palette that reads as "
              "hand-painted cartoon art — saturated but not neon, with a dark warm "
              "outline colour. Part sizes are in points on a 40pt tile grid, so a "
              "hero stands about 34pt tall in total.",
            schema, art_director.SPEC_SCHEMA)
        print(f"model: {note}")
    except RuntimeError as e:
        print(f"model unavailable ({e})\nfalling back to the offline composer.",
              file=sys.stderr)
        spec = compose_art_offline(args.brief)

    problems = art_director.validate_spec(spec)
    if problems:
        print("spec rejected:", file=sys.stderr)
        for p in problems:
            print("  •", p, file=sys.stderr)
        return 1

    spec_path = os.path.join(args.out, f"{spec['name']}.artspec.json")
    os.makedirs(args.out, exist_ok=True)
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=2)
    print(f"wrote {spec_path}")

    written, problems, notes = art_director.build(spec, args.out, preview=args.preview)
    if problems:
        for p in problems:
            print("  •", p, file=sys.stderr)
        return 1
    for path in written:
        print(f"wrote {path}")
    for note in notes:
        print(f"note: {note}", file=sys.stderr)
    return 0


def report(errors, warnings):
    if errors:
        print("\nrejected:")
        for m in errors:
            print("  ✗", m)
    if warnings:
        print("\nrule warnings (the engine would apply this anyway):")
        for m in warnings:
            print("  •", m)
    if not errors and not warnings:
        print("\n✓ valid, and every design rule satisfied")


LEVEL_DIR = os.path.join(HERE, "..", "Assets", "Levels")
LEVEL_FORMAT = "level/1"
NAME_OK = re.compile(r"^[a-z0-9][a-z0-9_-]{0,39}$")


def level_files(directory=None):
    """Every `level/1` file on disk, in play order.

    Mirrors `LevelLibrary.load()` in Swift, including the duplicate-order check —
    two levels claiming the same slot would order unpredictably between runs,
    which reads to a player as the levels shuffling themselves.
    """
    directory = directory or LEVEL_DIR
    found, problems = [], []
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        try:
            with open(path) as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{os.path.basename(path)}: unreadable ({e})")
            continue
        if doc.get("format") != LEVEL_FORMAT:
            continue
        problems += [f"{os.path.basename(path)}: {p}"
                     for p in level_structure_problems(doc)]
        for index, spec in enumerate(doc.get("frises", []) or []):
            problems += [f"{os.path.basename(path)}: {p}"
                         for p in frise_problems(spec, index)]
        found.append((doc, path))
    seen = {}
    for doc, path in found:
        order = doc.get("order")
        if order in seen:
            problems.append(f"{os.path.basename(path)}: order {order} is already "
                            f"used by '{seen[order]}'")
        seen[order] = doc.get("name")
    found.sort(key=lambda pair: (pair[0].get("order", 0), pair[0].get("name", "")))
    return [doc for doc, _ in found], problems


# ─── triggers + camera (mirror of World/Trigger.swift, CameraDirector.swift) ───

TRIGGER_VERBS = {"spawn", "hazardWall", "camera", "move", "shake", "sound",
                 "music", "grade", "text", "tuning", "checkpoint", "finish"}
TRIGGER_WHEN = {"enter", "exit", "inside", "start"}
CAMERA_MODES = {"follow", "lock", "lockY", "chase"}
GRADES = {"neutral", "grove", "hollow", "evening", "arena"}
SOUNDS = {"jump", "land", "coin", "stomp", "pop", "hurt", "pound", "dash",
          "spring", "checkpoint", "crusher", "hover", "win", "boss_hit",
          "boss_die", "menu"}
MUSIC = {"theme_menu", "theme_grove", "theme_hollow", "theme_ridge",
         "theme_arena", "theme_evening"}
ACTOR_KINDS = {"enemy", "coin", "villager", "bird"}


def trigger_action_problems(action, label):
    """Mirror of `TriggerAction.problems`."""
    out = []
    verb = action.get("do")
    if verb not in TRIGGER_VERBS:
        return [f"{label}: unknown action '{verb}' (have "
                f"{', '.join(sorted(TRIGGER_VERBS))})"]
    def num(key, default=0):
        v = action.get(key, default)
        return v if isinstance(v, (int, float)) else default
    if verb == "spawn":
        if action.get("kind", "enemy") not in ACTOR_KINDS:
            out.append(f"{label}: unknown actor kind {action.get('kind')!r}")
        if not 1 <= num("count", 1) <= 24:
            out.append(f"{label}: spawn count {num('count', 1)} outside 1…24")
        if num("spacing", 2) < 1:
            out.append(f"{label}: spawn spacing must be ≥ 1")
    elif verb == "hazardWall":
        if not 0 < num("speed", 180) <= 1200:
            out.append(f"{label}: hazardWall speed {num('speed', 180)} outside 1…1200")
    elif verb == "camera":
        if action.get("mode", "follow") not in CAMERA_MODES:
            out.append(f"{label}: unknown camera mode {action.get('mode')!r}")
        if "zoom" in action and not 0.5 <= num("zoom", 1) <= 2.5:
            out.append(f"{label}: camera zoom {num('zoom')} outside 0.5…2.5")
        if "speed" in action and not 0 < num("speed", 1) <= 1200:
            out.append(f"{label}: camera speed {num('speed')} outside 1…1200")
    elif verb == "move":
        if not action.get("target"):
            out.append(f"{label}: move needs a target")
        if not 0 < num("seconds", 1) <= 30:
            out.append(f"{label}: move duration outside 0…30s")
    elif verb == "shake":
        if not 0 < num("strength", 0.7) <= 2:
            out.append(f"{label}: shake strength outside 0…2")
    elif verb == "sound":
        if action.get("name") not in SOUNDS:
            out.append(f"{label}: unknown sound {action.get('name')!r}")
    elif verb == "music":
        if action.get("name") is not None and action["name"] not in MUSIC:
            out.append(f"{label}: unknown music {action.get('name')!r}")
    elif verb == "grade":
        if action.get("name") not in GRADES:
            out.append(f"{label}: unknown grade {action.get('name')!r}")
    elif verb == "text":
        if not action.get("message"):
            out.append(f"{label}: text needs a message")
        if not 0 < num("seconds", 1.6) <= 12:
            out.append(f"{label}: text duration outside 0…12s")
    elif verb == "tuning":
        if "runSpeed" in action and not 60 <= num("runSpeed") <= 700:
            out.append(f"{label}: runSpeed outside 60…700")
        if "jumpVelocity" in action and not 300 <= num("jumpVelocity") <= 1600:
            out.append(f"{label}: jumpVelocity outside 300…1600")
        if "gravity" in action and not -60 <= num("gravity", -18) <= -4:
            out.append(f"{label}: gravity outside −60…−4")
    return out


def trigger_problems(doc):
    """Mirror of the trigger half of `LevelFile.structuralProblems`."""
    out = []
    triggers = doc.get("triggers") or []
    names = [t.get("name", "") for t in triggers]
    for index, spec in enumerate(triggers):
        name = spec.get("name") or f"#{index}"
        label = f"trigger '{name}'"
        if not spec.get("name"):
            out.append(f"{label}: needs a name")
        if names.count(spec.get("name")) > 1:
            out.append(f"{label}: duplicate name, so `afterTrigger` cannot address it")
        when = spec.get("when", "enter")
        if when not in TRIGGER_WHEN:
            out.append(f"{label}: unknown `when` {when!r}")
        if not spec.get("actions"):
            out.append(f"{label}: has no actions, so it does nothing")
        if when != "start" and not spec.get("region"):
            out.append(f"{label}: positional (when: {when}) but has no region")
        if when == "inside" and spec.get("once", True):
            out.append(f"{label}: fires `inside` but is `once` — it would fire on one "
                       f"frame only; use `enter`, or set once: false")
        region = spec.get("region") or {}
        if region:
            if region.get("col", 0) < 0 or region.get("row", 0) < 0:
                out.append(f"{label}: region starts off the grid")
            if region.get("width", 1) < 1 or region.get("height", 64) < 1:
                out.append(f"{label}: region must be at least 1×1")
        previous = (spec.get("requires") or {}).get("afterTrigger")
        if previous and previous not in names:
            out.append(f"{label}: waits for trigger '{previous}', which this level "
                       f"does not define")
        for i, action in enumerate(spec.get("actions") or []):
            out += trigger_action_problems(action, f"{label} action {i}")
    # A move target has to name a frise, or the set piece silently does nothing.
    addressable = {f.get("name") for f in (doc.get("frises") or []) if f.get("name")}
    for spec in triggers:
        for action in spec.get("actions") or []:
            if action.get("do") == "move" and action.get("target") not in addressable:
                out.append(f"trigger '{spec.get('name')}': moves "
                           f"{action.get('target')!r}, which no frise in this level "
                           f"is named")
    return out


def camera_problems(doc):
    """Mirror of `CameraSpec.structuralProblems`."""
    out = []
    camera = doc.get("camera")
    if not camera:
        return out
    zoom = camera.get("zoom", 1)
    if not 0.5 <= zoom <= 2.5:
        out.append(f"camera zoom {zoom} outside 0.5…2.5")
    if "lead" in camera and not 0 <= camera["lead"] <= 0.6:
        out.append(f"camera lead {camera['lead']} outside 0…0.6")
    zones = camera.get("zones") or []
    for index, zone in enumerate(zones):
        if zone.get("width", 0) < 1:
            out.append(f"camera zone {index}: needs width ≥ 1")
        if zone.get("col", 0) < 0:
            out.append(f"camera zone {index}: starts off the grid")
        if "zoom" in zone and not 0.5 <= zone["zoom"] <= 2.5:
            out.append(f"camera zone {index}: zoom {zone['zoom']} outside 0.5…2.5")
        mode = zone.get("mode", "follow")
        if mode not in CAMERA_MODES:
            out.append(f"camera zone {index}: unknown mode {mode!r}")
        if mode == "lock" and zone.get("atCol") is None:
            out.append(f"camera zone {index}: locks but has no atCol")
        if mode == "chase" and not zone.get("speed"):
            out.append(f"camera zone {index}: chases but has no speed")
        if not 0 <= zone.get("blend", 0.5) <= 4:
            out.append(f"camera zone {index}: blend outside 0…4s")
    ordered = sorted(zones, key=lambda z: z.get("col", 0))
    for a, b in zip(ordered, ordered[1:]):
        if a.get("col", 0) + a.get("width", 1) > b.get("col", 0):
            out.append(f"camera zones at col {a.get('col')} and {b.get('col')} overlap")
    return out


def level_structure_problems(doc):
    """What makes a level file unusable, as opposed to badly designed."""
    out = []
    if doc.get("format") != LEVEL_FORMAT:
        out.append(f"format is {doc.get('format')!r}, expected {LEVEL_FORMAT!r}")
    name = doc.get("name") or ""
    if not NAME_OK.match(name):
        out.append(f"name {name!r} must be lowercase letters, digits, - or _ "
                   f"(it becomes a file name and a bundle resource key)")
    if not isinstance(doc.get("order"), int):
        out.append("order must be an integer")
    rows = doc.get("rows")
    if not isinstance(rows, list) or not rows:
        out.append("rows must be a non-empty list of strings")
    elif not all(isinstance(r, str) for r in rows):
        out.append("every row must be a string")
    elif len(rows) > MAX_ROWS:
        out.append(f"{len(rows)} rows exceeds the {MAX_ROWS} limit")
    elif max(len(r) for r in rows) > MAX_COLS:
        out.append(f"{max(len(r) for r in rows)} columns exceeds the "
                   f"{MAX_COLS} limit")
    time_of_day = doc.get("timeOfDay")
    if time_of_day is not None and not (isinstance(time_of_day, (int, float))
                                        and 0 <= time_of_day <= 1):
        out.append("timeOfDay must be a number in 0…1")
    out += trigger_problems(doc)
    out += camera_problems(doc)
    return out


def shipped_levels(path=None):
    """The rows compiled into `World/Levels.swift`.

    Read out of the Swift source rather than duplicated here, so `make verify`
    checks the levels the game will actually build — the point of a mirror is to
    disagree with the authority when one of them is wrong, not to drift quietly.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    path = path or os.path.join(here, "..", "World", "Levels.swift")
    with open(path) as f:
        source = f.read()
    levels, current, depth = [], None, 0
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and current is None and "\"" not in stripped:
            current, depth = [], 1
            continue
        if current is None:
            continue
        if stripped.startswith("]"):
            if current:
                levels.append(current)
            current = None
            continue
        match = re.match(r'^"((?:[^"\\]|\\.)*)"\s*,?\s*$', stripped)
        if match:
            current.append(match.group(1).replace('\\\\', '\\'))
    if current:
        levels.append(current)
    return levels


def cmd_validate(args):
    if getattr(args, "all", False):
        # Files first, because they are what the game loads. The compiled table
        # is only the fallback, so it is checked too but reported as such.
        files, structural = level_files()
        failed = len(structural)
        for problem in structural:
            print(f"  ✗ {problem}")
        for doc in files:
            rows = doc["rows"]
            label = f"{doc['name']} ({max(len(r) for r in rows)}×{len(rows)}, " \
                    f"order {doc['order']})"
            problems = validate_level(rows, level_footprint(doc))
            if problems:
                failed += 1
                print(f"  ✗ {label}")
                for problem in problems:
                    print(f"      {problem}")
            else:
                print(f"  ✓ {label}")
        if files:
            print(f"{len(files)} level file(s), {failed} failing")

        compiled = shipped_levels()
        if not files and not compiled:
            print("no level files and no compiled levels — the game has nothing "
                  "to play", file=sys.stderr)
            return 1
        for index, rows in enumerate(compiled):
            problems = validate_level(rows)
            if problems:
                failed += 1
                print(f"  ✗ fallback level {index}")
                for problem in problems:
                    print(f"      {problem}")
        if compiled and not files:
            print(f"{len(compiled)} compiled fallback level(s), {failed} failing")
        elif compiled:
            print(f"  (+{len(compiled)} compiled fallback level(s), all clean)"
                  if failed == 0 else "")
        return 1 if failed else 0
    if not args.file:
        print("give a document to validate, or --all for the shipped levels",
              file=sys.stderr)
        return 1
    with open(args.file) as f:
        doc = json.load(f)
    if doc.get("format") == "art-spec/1":
        import art_director
        problems = art_director.validate_spec(doc)
        report(problems, [])
        return 1 if problems else 0
    errors, warnings = validate_document(doc)
    report(errors, warnings)
    return 1 if errors else 0


def cmd_levels(args):
    files, problems = level_files()
    for problem in problems:
        print(f"  ✗ {problem}")
    if not files:
        print(f"no level/1 files in {os.path.normpath(LEVEL_DIR)} — the game will "
              f"fall back to the compiled table in World/Levels.swift")
        return 1 if problems else 0
    print(f"{len(files)} level(s) in {os.path.normpath(LEVEL_DIR)}:")
    for index, doc in enumerate(files):
        rows = doc["rows"]
        warnings = validate_level(rows, level_footprint(doc))
        print(f"  {index}  {doc['name']:<10} order {doc['order']:<4} "
              f"{max(len(r) for r in rows)}×{len(rows)}  "
              f"{doc.get('frieze') or '-':<18} "
              f"{doc.get('title') or doc['name']}"
              + (f"  {len(doc.get('frises') or [])} frise(s)"
                 if doc.get("frises") else "")
              + (f"   ⚠ {len(warnings)} design warning(s)" if warnings else ""))
    return 1 if problems else 0


def cmd_install(args):
    docs = documents_dir()
    if not os.path.isdir(docs):
        print(f"no Documents directory found (tried {docs})", file=sys.stderr)
        return 1
    target = os.path.join(docs, "engine.json")
    shutil.copyfile(args.file, target)
    print(f"installed → {target}")
    print("the running game applies it on the next file-system event "
          "(DEBUG builds watch this folder)")
    return 0


def cmd_state(args):
    out = os.path.join(documents_dir(), "EngineOut")
    if not os.path.isdir(out):
        print(f"no EngineOut in {documents_dir()} — launch the game once "
              f"(DEBUG) so it can publish its state", file=sys.stderr)
        return 1
    for name in ("receipt.json", "state.json"):
        path = os.path.join(out, name)
        if not os.path.isfile(path):
            continue
        print(f"── {name} ───────────────────────────────")
        with open(path) as f:
            print(f.read().rstrip())
    return 0


# ─── localhost bridge for the HTML editors ───────────────────────────────────

def cmd_serve(args):
    """A tiny loopback bridge so `LevelEditor.html` and `RigEditor.html` can
    generate through AI without an API key in the page.

    Bound to 127.0.0.1 on purpose: the key lives in this process, the editors
    are static files, and nothing is exposed off the machine.
    """
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Bridge(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            # The editors are opened from file://, so their Origin is "null".
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):
            self._send(204, {})

        def do_GET(self):
            if self.path.startswith("/health"):
                schema, source = engine_schema()
                self._send(200, {"ok": True, "model": MODEL, "vocabulary": source,
                                 "hasKey": bool(os.environ.get("ANTHROPIC_API_KEY")),
                                 "documents": documents_dir()})
            elif self.path.startswith("/state"):
                self._send(200, {"state": engine_state()})
            elif self.path.startswith("/levels"):
                levels, problems = level_files()
                self._send(200, {"levels": levels, "problems": problems,
                                 "dir": os.path.normpath(LEVEL_DIR)})
            else:
                self._send(404, {"error": "try /health, /state, /levels, "
                                          "/plan, /art, /save"})

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError) as e:
                return self._send(400, {"error": f"bad request body: {e}"})
            brief = (body.get("brief") or "").strip()

            if self.path.startswith("/install"):
                # Write the command document into the app's Documents folder. A
                # DEBUG build watches that folder, so this is the two-second loop
                # for iterating on level *shape* — a level file needs a rebuild to
                # enter the bundle, and waiting for one breaks the rhythm.
                doc = body.get("document") or body
                errors, warnings = validate_document(doc)
                if errors:
                    return self._send(400, {"errors": errors})
                docs = documents_dir()
                if not os.path.isdir(docs):
                    return self._send(409, {"errors": [
                        f"no Documents directory found (looked in {docs}) — launch "
                        f"the game once in DEBUG so it creates one"]})
                path = os.path.join(docs, "engine.json")
                with open(path, "w") as f:
                    json.dump(doc, f, indent=1)
                return self._send(200, {"path": path, "warnings": warnings})

            if self.path.startswith("/save"):
                # This is the endpoint that turns the editor from a drawing tool
                # into the pipeline: a browser cannot write to the repository, so
                # it hands the document to this loopback process, which validates
                # it exactly as the game will and then writes the file.
                doc = body.get("level") or body
                rows = doc.get("rows") or []
                if rows:
                    width = max(len(r) for r in rows)
                    doc["rows"] = [r.ljust(width) for r in rows]
                doc.setdefault("format", LEVEL_FORMAT)
                structural = level_structure_problems(doc)
                if structural:
                    return self._send(400, {"errors": structural})
                existing, _ = level_files()
                clash = [l for l in existing
                         if l.get("order") == doc.get("order")
                         and l.get("name") != doc.get("name")]
                if clash and not body.get("force"):
                    return self._send(409, {
                        "errors": [f"order {doc['order']} is already used by "
                                   f"'{clash[0]['name']}' — change the order, or "
                                   f"resend with force"],
                        "suggestOrder": max(l.get("order", 0)
                                            for l in existing) + 10})
                for index, spec in enumerate(doc.get("frises", []) or []):
                    structural += frise_problems(spec, index)
                if structural:
                    return self._send(400, {"errors": structural})
                warnings = validate_level(doc["rows"], level_footprint(doc))
                # Design warnings do NOT block the write. A level in progress is
                # normal; refusing to save it would make the editor unusable.
                os.makedirs(LEVEL_DIR, exist_ok=True)
                path = os.path.join(LEVEL_DIR, f"{doc['name']}.json")
                existed = os.path.exists(path)
                with open(path, "w") as f:
                    json.dump(doc, f, indent=1)
                    f.write("\n")
                return self._send(200, {
                    "path": os.path.normpath(path), "replaced": existed,
                    "warnings": warnings,
                    "note": "rebuild to pick it up (make run), or install it as a "
                            "runtime override for an instant reload"})

            if self.path.startswith("/plan"):
                if not brief:
                    return self._send(400, {"error": "brief is required"})
                schema, _ = engine_schema()
                try:
                    doc, note = call_claude(brief, schema, LEVEL_SCHEMA,
                                            body.get("context", ""))
                except RuntimeError as e:
                    doc, note = compose_offline(brief), f"offline composer ({e})"
                errors, warnings = validate_document(doc)
                rows = next((c.get("rows") for c in doc.get("commands", [])
                             if c.get("op") == "setLevel"), None)
                return self._send(200, {"document": doc, "rows": rows, "note": note,
                                        "errors": errors, "warnings": warnings})

            if self.path.startswith("/art"):
                if not brief:
                    return self._send(400, {"error": "brief is required"})
                import art_director
                schema, _ = engine_schema()
                try:
                    spec, note = call_claude(
                        "Design a character for a Rayman-style 2D platformer: " + brief,
                        schema, art_director.SPEC_SCHEMA)
                except RuntimeError as e:
                    spec, note = compose_art_offline(brief), f"offline composer ({e})"
                problems = art_director.validate_spec(spec)
                payload = {"spec": spec, "note": note, "errors": problems}
                if not problems and body.get("build"):
                    out = body.get("out") or os.path.join(HERE, "..", "Assets", "Rigs")
                    try:
                        written, bad, notes = art_director.build(spec, out, preview=True)
                        payload["written"] = written
                        payload["errors"] = bad
                        payload["notes"] = notes
                        rig = os.path.join(out, f"{spec['name']}_rig.json")
                        if os.path.isfile(rig):
                            with open(rig) as f:
                                payload["rig"] = json.load(f)
                        # Hand the art back as data URLs keyed by attachment
                        # name, so the editor draws the real thing instead of
                        # asking the user to re-pick files it just wrote.
                        payload["images"] = part_data_urls(spec, out)
                    except Exception as e:                    # noqa: BLE001
                        payload["errors"] = [f"build failed: {e}"]
                return self._send(200, payload)

            if self.path.startswith("/validate"):
                doc = body.get("document")
                if isinstance(doc, dict) and doc.get("format") == "art-spec/1":
                    import art_director
                    return self._send(200, {"errors": art_director.validate_spec(doc),
                                            "warnings": []})
                errors, warnings = validate_document(doc or {})
                return self._send(200, {"errors": errors, "warnings": warnings})

            if self.path.startswith("/install"):
                doc = body.get("document")
                if not isinstance(doc, dict):
                    return self._send(400, {"error": "document is required"})
                errors, _ = validate_document(doc)
                if errors:
                    return self._send(400, {"errors": errors})
                target = os.path.join(documents_dir(), "engine.json")
                try:
                    with open(target, "w") as f:
                        json.dump(doc, f, indent=1)
                except OSError as e:
                    return self._send(500, {"error": str(e)})
                return self._send(200, {"installed": target})

            self._send(404, {"error": "unknown endpoint"})

        def log_message(self, fmt, *a):        # quieter than the default
            sys.stderr.write("  %s\n" % (fmt % a))

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Bridge)
    schema, source = engine_schema()
    keyed = "key found" if os.environ.get("ANTHROPIC_API_KEY") else \
        "NO ANTHROPIC_API_KEY — offline composer will answer"
    print(f"bridge on http://127.0.0.1:{args.port}  ({keyed})")
    print(f"vocabulary: {source}")
    print(f"documents:  {documents_dir()}")
    print("open Tools/LevelEditor.html or Tools/RigEditor.html and use the AI panel")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbridge stopped")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("plan", help="brief → validated command document")
    p.add_argument("brief")
    p.add_argument("--out", default="engine.json")
    p.add_argument("--install", action="store_true", help="also copy into Documents/")
    p.add_argument("--no-repair", dest="repair", action="store_false",
                   help="skip the rule-violation repair round")
    p.set_defaults(func=cmd_plan, repair=True)

    p = sub.add_parser("art", help="brief → art spec → Rayman-style PNGs + Spine rig")
    p.add_argument("brief")
    p.add_argument("--out", default=os.path.join(HERE, "..", "Assets", "Rigs"))
    p.add_argument("--preview", action="store_true", default=True)
    p.set_defaults(func=cmd_art)

    p = sub.add_parser("reference",
                       help="a screenshot you like → matching backdrop, hero palette "
                            "and level")
    p.add_argument("image", help="reference frame (png/jpeg/gif/webp)")
    p.add_argument("--name", help="scene name; defaults to the file name")
    p.add_argument("--out", default=os.path.join(HERE, "..", "Assets", "Friezes"))
    p.add_argument("--hero", action="store_true", default=True,
                   help="also generate a character in the reference's palette")
    p.add_argument("--no-vision", action="store_true",
                   help="measure only; don't send the image to the model")
    p.set_defaults(func=cmd_reference)

    p = sub.add_parser("validate", help="check a command document or art spec offline")
    p.add_argument("file", nargs="?")
    p.add_argument("--all", action="store_true",
                   help="validate every level compiled into World/Levels.swift")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("levels", help="list the level files the game will load")
    p.set_defaults(func=cmd_levels)

    p = sub.add_parser("install", help="copy a document into the app's Documents dir")
    p.add_argument("file")
    p.set_defaults(func=cmd_install)

    p = sub.add_parser("state", help="read back the engine's snapshot and last receipt")
    p.set_defaults(func=cmd_state)

    p = sub.add_parser("serve", help="localhost bridge for the HTML editors")
    p.add_argument("--port", type=int, default=8787)
    p.set_defaults(func=cmd_serve)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
