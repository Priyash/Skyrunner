#!/usr/bin/env python3
"""
art_director.py — generates Rayman-style cartoon art *and* the Spine 2D rig
that animates it, from one small JSON spec.

Why a spec instead of a prompt: an image model returns pixels, and pixels alone
can't be animated — a rig needs parts on transparent backgrounds, consistent
pivots, bone lengths that match the art, and mesh weights. So the AI writes the
*art direction* (palette, silhouette, part list, personality) and this file
paints it and builds the rig. Same split UbiArt used, and the same split
composer.py already uses for backdrops: art is data, the engine is code.

    brief ──▶ ai_director.py ──▶ art spec ──▶ art_director.py ──▶ PNGs @2x/@3x
                                                              └─▶ <name>_rig.json

Output loads through the shipped path with no code changes: `RigLoader` reads
the rig (Spine JSON subset — bones, slots, skins, weighted meshes, animations
with Bézier curves and mesh deform), `SkeletonNode` renders and skins it,
`DeformedCollider` builds hulls from the same lattice, and `Tools/RigEditor.html`
imports it for hand-tuning. Nothing here is a one-way export.

Usage:
    python3 art_director.py hero.artspec.json [--out ../Assets/Rigs] [--preview]
    python3 art_director.py --default hero          # write a stock spec and build it
    python3 art_director.py --schema                # print the spec schema (for the AI)

The look: bold dark outline, radial interior shading with a warm bounce, cool
rim on the shadow side, one glossy highlight, faint paper grain — rendered 4×
and downsampled, which is where the clean edges come from.
"""
import colorsys
import argparse, json, math, os, sys

# Pillow and numpy paint the raster parts. The rig half — bones, slots,
# weighted meshes, clips — is pure arithmetic, so it stays available without
# them: a machine with no imaging stack can still generate and validate a rig,
# and `ai_director serve` keeps running instead of dying on an import.
try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    HAVE_RASTER = True
except ImportError:
    HAVE_RASTER = False
    RASTER_HINT = ("Pillow and numpy are not installed, so no PNGs were painted "
                   "(python3 -m pip install pillow numpy)")

# ── asset resolution policy ──────────────────────────────────────────────────
#
# The scene is authored at 844×390 points and presented with `.aspectFill`, so a
# scene point is *not* a view point: on an iPad Pro 12.9" the scene scales by
# 1024/390 = 2.63 before the ×2 screen scale, which needs **5.3 pixels per scene
# point**. An iPhone 15 Pro Max needs 3.3. A plain `@3x` asset supplies 3.0 — so
# nominal art is upscaled on every current device, worst on iPad.
#
# iOS only understands the @1x/@2x/@3x suffixes, so the fix is not a new suffix:
# it is to put *more pixels behind the same point size*. `SkeletonNode` sets
# `sprite.size` from the attachment's declared width/height, so extra pixels cost
# memory and buy sharpness — the texture is minified rather than magnified, which
# is the direction that looks good.
HERE = os.path.dirname(os.path.abspath(__file__))

ASSET_DENSITY = 6.0        # pixels per scene point in the @3x file
NOMINAL_DENSITY = 3.0      # what a plain @3x would give
DENSITY_MULTIPLE = ASSET_DENSITY / NOMINAL_DENSITY      # 2× denser than nominal

SS = 3                      # supersampling on top of the output resolution
SCALES = (2, 3)             # @2x / @3x, matching the bundle's asset naming


# ─── spec ────────────────────────────────────────────────────────────────────

SPEC_SCHEMA = {
    "type": "object",
    "properties": {
        "format": {"const": "art-spec/1"},
        "name": {"type": "string", "description": "asset prefix, e.g. 'hero'"},
        "style": {
            "type": "object",
            "properties": {
                "palette": {
                    "type": "object",
                    "description": "named RGB triples 0-255; keys referenced by parts",
                    "additionalProperties": {
                        "type": "array", "items": {"type": "integer"},
                        "minItems": 3, "maxItems": 3,
                    },
                },
                "outline": {"type": "number", "description": "outline weight in points, 1.5–4"},
                "gloss": {"type": "number", "description": "highlight strength 0–1"},
                "rim": {"type": "number", "description": "cool rim-light strength 0–1"},
                "grain": {"type": "number", "description": "paper grain 0–0.25"},
                "lightAngle": {"type": "number", "description": "degrees, 0 = from the right"},
            },
            "required": ["palette"],
        },
        "parts": {
            "type": "array",
            "description": "one entry per body part; names drive bone and slot names",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string",
                             "enum": ["body", "head", "tuft", "hand_l", "hand_r",
                                      "foot_l", "foot_r"]},
                    "shape": {"type": "string",
                              "enum": ["ball", "pill", "tuft", "glove", "shoe"]},
                    "size": {"type": "array", "items": {"type": "number"},
                             "minItems": 2, "maxItems": 2,
                             "description": "width, height in points"},
                    "color": {"type": "string", "description": "palette key"},
                    "face": {"type": "boolean",
                             "description": "draw eyes/brow/mouth on this part"},
                    "mesh": {"type": "boolean",
                             "description": "deformable weighted mesh instead of a flat quad"},
                },
                "required": ["name", "shape", "size", "color"],
            },
        },
        "personality": {
            "type": "object",
            "description": "how the generated clips should feel",
            "properties": {
                "bounce": {"type": "number", "description": "idle/run vertical travel 0–2"},
                "swagger": {"type": "number", "description": "run lean and arm swing 0–2"},
                "squash": {"type": "number", "description": "squash-and-stretch 0–2"},
            },
        },
    },
    "required": ["format", "name", "style", "parts"],
}

DEFAULT_SPEC = {
    "format": "art-spec/1",
    "name": "hero",
    "style": {
        "palette": {
            "skin":    [255, 148, 26],
            "cream":   [255, 237, 204],
            "shoe":    [230, 56, 46],
            "hair":    [255, 122, 20],
            "outline": [74, 38, 12],
        },
        "outline": 2.6,
        "gloss": 0.55,
        "rim": 0.34,
        "grain": 0.09,
        "lightAngle": 125,
    },
    "parts": [
        {"name": "body",   "shape": "pill",  "size": [26, 30], "color": "skin",  "mesh": True},
        {"name": "head",   "shape": "ball",  "size": [24, 24], "color": "skin",
         "face": True, "mesh": True},
        {"name": "tuft",   "shape": "tuft",  "size": [14, 18], "color": "hair"},
        {"name": "hand_l", "shape": "glove", "size": [11, 11], "color": "cream"},
        {"name": "hand_r", "shape": "glove", "size": [11, 11], "color": "cream"},
        {"name": "foot_l", "shape": "shoe",  "size": [15, 9],  "color": "shoe"},
        {"name": "foot_r", "shape": "shoe",  "size": [15, 9],  "color": "shoe"},
    ],
    "personality": {"bounce": 1.0, "swagger": 1.0, "squash": 1.0},
}


def validate_spec(spec):
    """Offline check, mirroring SPEC_SCHEMA. Returns a list of problems."""
    bad = []
    if spec.get("format") != "art-spec/1":
        bad.append("format must be 'art-spec/1'")
    name = spec.get("name", "")
    if not name or not all(c.isalnum() or c in "_-" for c in name):
        bad.append("name must be a simple identifier")
    style = spec.get("style") or {}
    palette = style.get("palette") or {}
    if not palette:
        bad.append("style.palette is required")
    for key, rgb in palette.items():
        if not (isinstance(rgb, list) and len(rgb) >= 3
                and all(isinstance(c, (int, float)) and 0 <= c <= 255 for c in rgb[:3])):
            bad.append(f"palette.{key} must be three numbers 0-255")
    parts = spec.get("parts") or []
    seen = set()
    legal_parts = set(SPEC_SCHEMA["properties"]["parts"]["items"]
                      ["properties"]["name"]["enum"])
    legal_shapes = set(SPEC_SCHEMA["properties"]["parts"]["items"]
                       ["properties"]["shape"]["enum"])
    for p in parts:
        pname = p.get("name")
        if pname not in legal_parts:
            bad.append(f"unknown part '{pname}' (legal: {sorted(legal_parts)})")
        if pname in seen:
            bad.append(f"duplicate part '{pname}'")
        seen.add(pname)
        if p.get("shape") not in legal_shapes:
            bad.append(f"part {pname}: shape must be one of {sorted(legal_shapes)}")
        size = p.get("size")
        if not (isinstance(size, list) and len(size) == 2
                and all(isinstance(v, (int, float)) and 2 <= v <= 256 for v in size)):
            bad.append(f"part {pname}: size must be [w, h] in 2…256 points")
        if p.get("color") not in palette:
            bad.append(f"part {pname}: color '{p.get('color')}' is not in the palette")
    for required in ("body", "head"):
        if required not in seen:
            bad.append(f"missing required part '{required}'")
    return bad


# ─── painting ────────────────────────────────────────────────────────────────

def _rgb(palette, key, fallback=(255, 255, 255)):
    c = palette.get(key, fallback)
    return tuple(int(max(0, min(255, v))) for v in c[:3])


def _quad(p0, p1, p2, steps=14):
    """Quadratic Bézier as a point list — ImageDraw has no curve primitive, and
    a hand-listed polygon is what makes a 'flame' read as a diamond."""
    pts = []
    for i in range(steps + 1):
        t = i / steps
        m = 1 - t
        pts.append((m * m * p0[0] + 2 * m * t * p1[0] + t * t * p2[0],
                    m * m * p0[1] + 2 * m * t * p1[1] + t * t * p2[1]))
    return pts


def _silhouette(shape, w, h):
    """A filled white mask of the part's shape at (w, h)."""
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    if shape == "ball":
        d.ellipse([0, 0, w - 1, h - 1], fill=255)
    elif shape == "pill":
        r = w / 2
        d.ellipse([0, 0, w - 1, w - 1], fill=255)
        d.ellipse([0, h - w, w - 1, h - 1], fill=255)
        d.rectangle([0, r, w - 1, h - r], fill=255)
    elif shape == "glove":
        # ball with a flattened cuff — reads as a mitten, not a bead
        d.ellipse([0, 0, w - 1, h * 0.86], fill=255)
        d.rounded_rectangle([w * 0.22, h * 0.62, w * 0.78, h - 1],
                            radius=w * 0.18, fill=255)
    elif shape == "shoe":
        # chunky cartoon shoe: tall rounded toe box at the front, lower heel
        d.ellipse([0, h * 0.02, w * 0.58, h - 1], fill=255)          # toe
        d.rounded_rectangle([w * 0.30, h * 0.34, w - 1, h - 1],
                            radius=h * 0.30, fill=255)               # heel + sole
        d.rectangle([w * 0.10, h * 0.62, w - 1, h - 1], fill=255)    # sole plate
    elif shape == "tuft":
        # a flame/leaf: one long sweep up the left, a fuller curve back down
        pts = _quad((w * 0.46, h - 1), (w * 0.02, h * 0.52), (w * 0.52, 0))
        pts += _quad((w * 0.52, 0), (w * 0.99, h * 0.44), (w * 0.60, h - 1))
        d.polygon(pts, fill=255)
    else:
        d.ellipse([0, 0, w - 1, h - 1], fill=255)
    return mask


def paint_part(shape, size, base, outline_col, style, seed=0):
    """One part, painted at `size` points × SS then downsampled.

    Shading model, in the order it reads on screen: a lambert-ish radial ramp
    with a warm bounce from below, a cool rim on the shadow edge, one soft gloss
    blob, faint grain, and a bold ink outline last so nothing bleeds over it.

    The shape is **inset** by the outline weight rather than filling the canvas:
    the outline is grown outward from the silhouette, so a silhouette that
    already touches the edge has nowhere to grow into and the ink is clipped away
    entirely. Insetting keeps the declared part size honest — the rig's
    width/height stay exactly what the spec asked for — and gives the ink its
    margin inside that box.
    """
    # Paint at the largest output size × SS, so every emitted tier is a
    # *reduction* of the master. Downsampling is what produces clean edges;
    # painting at the output size and hoping is what produces stair-steps.
    master = ASSET_DENSITY * SS
    w = max(4, int(round(size[0] * master)))
    h = max(4, int(round(size[1] * master)))
    lw = max(1, int(round(float(style.get("outline", 2.5)) * master * 0.5)))
    inset = lw + 1

    inner = _silhouette(shape, max(2, w - inset * 2), max(2, h - inset * 2))
    mask = Image.new("L", (w, h), 0)
    mask.paste(inner, (inset, inset))
    m = np.asarray(mask, dtype=np.float32) / 255.0

    # normalized coordinates over the *shape*, not the canvas, so the shading
    # ramp still runs edge to edge after the inset
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    half_w = max((w - inset * 2 - 1) / 2, 1)
    half_h = max((h - inset * 2 - 1) / 2, 1)
    nx = (xs - (w - 1) / 2) / half_w
    ny = (ys - (h - 1) / 2) / half_h
    r = np.clip(np.sqrt(nx * nx + ny * ny), 0, 1)
    nz = np.sqrt(np.clip(1 - r * r, 0, 1))

    angle = math.radians(style.get("lightAngle", 125))
    lx, ly = math.cos(angle), -math.sin(angle)
    lambert = np.clip(nx * lx + ny * ly + nz * 0.85, 0, 1.6)

    base_arr = np.array(base, dtype=np.float32) / 255.0
    shade = 0.66 + 0.46 * lambert
    rgb = base_arr[None, None, :] * shade[..., None]

    # warm bounce light from the ground plane keeps shadows from going muddy
    bounce = np.clip(-ny * 0.55 - 0.05, 0, 1)[..., None]
    rgb += bounce * np.array([0.20, 0.10, 0.02], dtype=np.float32) * 0.9

    # cool rim on the dark edge
    rim = float(style.get("rim", 0.3))
    if rim > 0:
        edge = np.clip((r - 0.62) / 0.38, 0, 1) ** 1.6
        away = np.clip(-(nx * lx + ny * ly), 0, 1)
        rgb += (edge * away * rim)[..., None] * np.array([0.42, 0.56, 0.95],
                                                         dtype=np.float32)

    # one glossy highlight, blurred for softness
    gloss = float(style.get("gloss", 0.5))
    if gloss > 0:
        hi = Image.new("L", (w, h), 0)
        hd = ImageDraw.Draw(hi)
        cx = (w - 1) / 2 + lx * w * 0.20
        cy = (h - 1) / 2 + ly * h * 0.20
        rx, ry = w * 0.20, h * 0.16
        hd.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=255)
        hi = hi.filter(ImageFilter.GaussianBlur(max(1.0, w * 0.055)))
        rgb += (np.asarray(hi, dtype=np.float32) / 255.0 * gloss * 0.85)[..., None]

    # paper grain — keeps large flats from looking like vector fills
    grain = float(style.get("grain", 0.08))
    if grain > 0:
        rng = np.random.default_rng(seed + 17)
        # grain cells sized in *output* pixels, not master pixels, or a denser
        # master would silently make the grain finer and finer
        cell = max(1, int(SS))
        noise = rng.random((max(1, h // cell), max(1, w // cell))).astype(np.float32)
        noise = np.asarray(Image.fromarray((noise * 255).astype(np.uint8), "L")
                           .resize((w, h), Image.BICUBIC), dtype=np.float32) / 255.0
        rgb *= (1.0 - grain * 0.5) + grain * noise[..., None]

    rgb = np.clip(rgb, 0, 1)
    art = Image.fromarray((rgb * 255).astype(np.uint8), "RGB")
    art.putalpha(mask)

    # outline drawn from the silhouette's own edge, so it hugs every shape
    lw = max(1, int(round(float(style.get("outline", 2.5)) * SS * 0.5)))
    grown = mask.filter(ImageFilter.MaxFilter(lw * 2 + 1))
    ring = Image.fromarray(
        np.clip(np.asarray(grown, np.int16) - np.asarray(mask, np.int16), 0, 255)
        .astype(np.uint8), "L")
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (w, h), outline_col + (255,)), (0, 0), grown)
    out.alpha_composite(art)
    # soften the inner edge so the outline reads as ink, not as a stroke
    inner = ring.filter(ImageFilter.GaussianBlur(master * 0.13))
    shadow = Image.new("RGBA", (w, h), outline_col + (110,))
    out.alpha_composite(Image.composite(shadow, Image.new("RGBA", (w, h), (0, 0, 0, 0)),
                                        Image.fromarray(
                                            (np.asarray(inner, np.float32)
                                             * np.asarray(mask, np.float32) / 255.0)
                                            .astype(np.uint8), "L")))
    return out


def draw_face(img, size, palette, style):
    """Eyes, brow and mouth on the head part — the whole character read."""
    w, h = img.size
    d = ImageDraw.Draw(img)
    ink = _rgb(palette, "outline", (60, 30, 10))
    stroke = max(1, int(w * 0.012))
    eye_w, eye_h = w * 0.19, h * 0.24
    for sign in (-1, 1):
        cx = w * 0.5 + sign * w * 0.17
        cy = h * 0.43
        d.ellipse([cx - eye_w / 2, cy - eye_h / 2, cx + eye_w / 2, cy + eye_h / 2],
                  fill=(255, 255, 255, 255), outline=ink + (255,), width=stroke)
        # pupil, offset toward the light so both eyes look the same direction
        px = cx + w * 0.022
        pr = eye_w * 0.34
        d.ellipse([px - pr, cy - pr, px + pr, cy + pr], fill=(24, 18, 30, 255))
        gr = pr * 0.42
        d.ellipse([px - gr - pr * 0.35, cy - gr - pr * 0.35,
                   px + gr - pr * 0.35, cy + gr - pr * 0.35],
                  fill=(255, 255, 255, 220))
    # Brows sit above the eyes with their *inner* ends slightly lower: inner-high
    # brows read as worried, outer-low as angry, this as relaxed.
    brow = max(2, int(w * 0.035))
    d.line([(w * 0.26, h * 0.25), (w * 0.43, h * 0.28)], fill=ink + (255,), width=brow)
    d.line([(w * 0.57, h * 0.28), (w * 0.74, h * 0.25)], fill=ink + (255,), width=brow)
    # Mouth: PIL measures arc angles clockwise from 3 o'clock, so 20°→160° is the
    # *bottom* of the ellipse — a smile. 200°→340° draws the top, i.e. a frown.
    d.arc([w * 0.36, h * 0.56, w * 0.64, h * 0.80], start=20, end=160,
          fill=ink + (255,), width=max(2, int(w * 0.034)))
    return img


# ─── rig ─────────────────────────────────────────────────────────────────────

# Rayman-style body plan: floating hands and feet, hair that swings on its own.
# `inheritRotation: false` on the detached limbs is what keeps them from
# cartwheeling with the body — the runtime honours it (Skeleton.swift).
BODY_PLAN = {
    "root":   {"parent": None,   "x": 0,   "y": 0,  "length": 0},
    "body":   {"parent": "root", "x": 0,   "y": 18, "length": 20},
    "head":   {"parent": "body", "x": 0,   "y": 20, "length": 16},
    "tuft":   {"parent": "head", "x": 0,   "y": 11, "length": 14, "spring": 240},
    "hand_l": {"parent": "body", "x": -16, "y": 2,  "length": 8, "detached": True},
    "hand_r": {"parent": "body", "x": 16,  "y": 2,  "length": 8, "detached": True},
    "foot_l": {"parent": "root", "x": -7,  "y": 5,  "length": 8, "detached": True},
    "foot_r": {"parent": "root", "x": 7,   "y": 5,  "length": 8, "detached": True},
}
BONE_ORDER = ["root", "body", "head", "tuft", "hand_l", "hand_r", "foot_l", "foot_r"]

# Bézier control points, matching Tools/RigEditor.html's presets and the
# runtime's Newton solver (Animation.swift). Linear keys carry no curve at all.
EASE_IN_OUT = [0.42, 0.0, 0.58, 1.0]
EASE_OUT = [0.0, 0.0, 0.58, 1.0]
ANTICIPATE = [0.30, -0.35, 0.70, 1.0]
OVERSHOOT = [0.30, 0.0, 0.60, 1.35]


def bone_world(name):
    """Setup-pose world position. Every setup rotation is 0, so the chain is a
    plain sum — which is also what makes the mesh weight offsets below exact."""
    x = y = 0.0
    while name:
        b = BODY_PLAN[name]
        x += b["x"]; y += b["y"]
        name = b["parent"]
    return x, y


def build_rig(spec):
    """Spec → Spine-format rig JSON (the subset RigLoader reads)."""
    parts = {p["name"]: p for p in spec["parts"]}
    name = spec["name"]
    personality = spec.get("personality") or {}
    bounce = float(personality.get("bounce", 1.0))
    swagger = float(personality.get("swagger", 1.0))
    squash = float(personality.get("squash", 1.0))

    bones, slots, attachments = [], [], {}
    for bone_name in BONE_ORDER:
        plan = BODY_PLAN[bone_name]
        if bone_name != "root" and bone_name not in parts:
            continue
        bone = {"name": bone_name, "x": plan["x"], "y": plan["y"],
                "rotation": 0, "length": plan["length"]}
        if plan["parent"]:
            bone["parent"] = plan["parent"]
        if plan.get("detached"):
            bone["inheritRotation"] = False
        if plan.get("spring"):
            bone["spring"] = plan["spring"]
        bones.append(bone)

    bone_index = {b["name"]: i for i, b in enumerate(bones)}

    for bone_name in BONE_ORDER:
        part = parts.get(bone_name)
        if not part:
            continue
        image = f"{name}_{bone_name}"
        slot_name = f"slot_{bone_name}"
        slots.append({"name": slot_name, "bone": bone_name, "attachment": image})
        w, h = float(part["size"][0]), float(part["size"][1])
        if part.get("mesh"):
            attachments[slot_name] = {
                image: weighted_mesh(bone_name, image, w, h, bone_index)}
        else:
            attachments[slot_name] = {image: {
                "type": "region", "path": image,
                "x": 0, "y": 0, "rotation": 0, "width": w, "height": h,
            }}

    rig = {
        "format": "animkit-rig/1",
        "skeleton": {"spine": "3.8.99", "images": "./"},
        "bones": bones,
        "slots": slots,
        "skins": [{"name": "default", "attachments": attachments}],
        "animations": {
            "idle":  clip_idle(parts, bounce, squash, name),
            "run":   clip_run(parts, bounce, swagger),
            "jump":  clip_jump(parts, squash),
            "punch": clip_punch(parts),
            "hurt":  clip_hurt(parts),
            # A jump with no fall and no landing is the gap you feel first: the
            # character rises with intent and then floats down in the same pose.
            "fall":  clip_fall(parts, squash),
            "land":  clip_land(parts, squash),
            "dash":  clip_dash(parts),
            "climb": clip_climb(parts, bounce),
            "victory": clip_victory(parts, bounce, squash),
        },
    }
    return rig


def weighted_mesh(bone_name, image, w, h, bone_index, cols=2, rows=2):
    """A weighted mesh over one part.

    Spine's vertex encoding, per vertex: `boneCount, [boneIndex, x, y, weight]…`
    where each (x, y) is the vertex in *that bone's* space. Weights fall off with
    distance to the influencing bones and are normalised, so the surface deforms
    as one piece instead of tearing at a seam — and `DeformedCollider` gets a
    hull that follows the drawn shape rather than a box.
    """
    # Which bones may pull on this part: itself, its parent, and its children.
    influences = [bone_name]
    parent = BODY_PLAN[bone_name]["parent"]
    if parent in bone_index:
        influences.append(parent)
    for child, plan in BODY_PLAN.items():
        if plan["parent"] == bone_name and child in bone_index:
            influences.append(child)
    influences = [b for b in influences if b in bone_index]

    origin_x, origin_y = bone_world(bone_name)
    verts, uvs, tris = [], [], []
    grid = []
    for r in range(rows + 1):
        for c in range(cols + 1):
            u, v = c / cols, r / rows
            # local space of this part: centred on its own bone
            lx = (u - 0.5) * w
            ly = (0.5 - v) * h
            uvs.extend([u, v])
            grid.append((lx, ly))

            wx, wy = origin_x + lx, origin_y + ly
            weights = []
            for b in influences:
                bx, by = bone_world(b)
                d = math.hypot(wx - bx, wy - by)
                weights.append((b, 1.0 / max(d, 4.0) ** 1.7))
            total = sum(x for _, x in weights) or 1.0
            entry = [len(weights)]
            for b, raw in weights:
                bx, by = bone_world(b)
                entry.extend([bone_index[b], round(wx - bx, 3), round(wy - by, 3),
                              round(raw / total, 4)])
            verts.extend(entry)

    for r in range(rows):
        for c in range(cols):
            i0 = r * (cols + 1) + c
            i1 = i0 + 1
            i2 = i0 + (cols + 1)
            i3 = i2 + 1
            tris.extend([i0, i2, i1, i1, i2, i3])

    return {
        "type": "mesh", "path": image,
        "uvs": [round(v, 4) for v in uvs],
        "triangles": tris,
        "vertices": verts,
        "hull": (cols + 1) * (rows + 1),
        "width": w, "height": h,
        "vertexCount": (cols + 1) * (rows + 1),
    }


def key(time, value=None, x=None, y=None, curve=None):
    k = {"time": round(time, 3)}
    if value is not None:
        k["value"] = round(value, 3)
    if x is not None:
        k["x"] = round(x, 3)
    if y is not None:
        k["y"] = round(y, 3)
    if curve:
        k["curve"] = curve
    return k


def _has(parts, *names):
    return [n for n in names if n in parts]


def clip_idle(parts, bounce, squash, asset_name):
    """Breathing, a hair sway that lags the body, and a mesh deform so the
    torso actually inflates rather than scaling. Deform keys are per authored
    vertex; `MeshSkinning` resamples them onto its lattice."""
    b = 2.4 * bounce
    anim = {"bones": {
        "body": {"translate": [key(0, x=0, y=0, curve=EASE_IN_OUT),
                               key(0.9, x=0, y=b, curve=EASE_IN_OUT),
                               key(1.8, x=0, y=0)]},
        "head": {"rotate": [key(0, value=0, curve=EASE_IN_OUT),
                            key(0.9, value=2.2, curve=EASE_IN_OUT),
                            key(1.8, value=0)],
                 "translate": [key(0, x=0, y=0, curve=EASE_IN_OUT),
                               key(0.9, x=0, y=b * 0.5, curve=EASE_IN_OUT),
                               key(1.8, x=0, y=0)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=-4, curve=EASE_IN_OUT),
                                            key(1.0, value=5, curve=EASE_IN_OUT),
                                            key(1.8, value=-4)]}
    for hand, sign in (("hand_l", -1), ("hand_r", 1)):
        if hand in parts:
            anim["bones"][hand] = {"translate": [
                key(0, x=0, y=0, curve=EASE_IN_OUT),
                key(0.9, x=sign * 0.8, y=-1.4 * bounce, curve=EASE_IN_OUT),
                key(1.8, x=0, y=0)]}
    if parts.get("body", {}).get("mesh"):
        puff = 1.1 * squash
        # One (x, y) pair per authored vertex — the 3×3 grid `weighted_mesh`
        # emits, so 9 vertices → 18 numbers. The attachment key must be the
        # real attachment name, not a guess.
        flat = [0.0] * 18
        wide = []
        for i in range(9):
            col, row = i % 3, i // 3
            wide.extend([(col - 1) * puff, (1 - row) * puff * 0.6])
        anim["deform"] = {"default": {"slot_body": {f"{asset_name}_body": [
            {"time": 0, "vertices": flat, "curve": EASE_IN_OUT},
            {"time": 0.9, "vertices": [round(v, 3) for v in wide], "curve": EASE_IN_OUT},
            {"time": 1.8, "vertices": flat},
        ]}}}
    return anim


def clip_run(parts, bounce, swagger):
    """A two-beat cycle: contact, passing, contact. Feet lead, hands
    counter-swing, body bobs at double frequency, and the whole rig leans.

    Every track is *sampled from a periodic function* rather than hand-keyed and
    phase-shifted, so the first and last key are identical by construction. A
    looping clip whose ends don't match pops once per stride — the kind of thing
    that is obvious in motion and invisible in a diff.
    """
    cycle = 0.52
    steps = 6
    reach = 7.5 * swagger
    lift = 5.0 * bounce

    def sampled(fn, ease=EASE_IN_OUT):
        keys = []
        for i in range(steps + 1):
            u = i / steps
            x, y = fn(u)
            keys.append(key(cycle * u, x=x, y=y, curve=None if i == steps else ease))
        return keys

    anim = {"bones": {
        "body": {
            # constant lean into the run; one key is a constant track
            "rotate": [key(0, value=-4 * swagger)],
            # bob at twice stride frequency: one rise per footfall
            "translate": sampled(lambda u: (0.0, lift * 0.55 * abs(math.sin(2 * math.pi * u))),
                                 ease=EASE_OUT),
        },
        "head": {"rotate": [key(0, value=3 * swagger, curve=EASE_IN_OUT),
                            key(cycle / 2, value=-2 * swagger, curve=EASE_IN_OUT),
                            key(cycle, value=3 * swagger)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=-14 * swagger, curve=EASE_OUT),
                                            key(cycle / 2, value=6 * swagger, curve=EASE_OUT),
                                            key(cycle, value=-14 * swagger)]}

    # Feet: forward at phase 0, back at 0.5, lifted through the swing half.
    for foot, phase in (("foot_l", 0.0), ("foot_r", 0.5)):
        if foot not in parts:
            continue
        anim["bones"][foot] = sampled_track(foot, phase, reach, lift, cycle, steps)

    # Hands counter-swing the legs — opposite foot, half the travel.
    for hand, phase in (("hand_l", 0.5), ("hand_r", 0.0)):
        if hand not in parts:
            continue
        anim["bones"][hand] = {"translate": sampled(
            lambda u, p=phase: (reach * 0.5 * math.cos(2 * math.pi * ((u + p) % 1.0)),
                                1.5 * abs(math.sin(2 * math.pi * ((u + p) % 1.0)))))}
    return anim


def sampled_track(_name, phase, reach, lift, cycle, steps):
    """One foot's stride, sampled over a full cycle."""
    keys = []
    for i in range(steps + 1):
        u = i / steps
        p = (u + phase) % 1.0
        x = reach * math.cos(2 * math.pi * p)
        y = lift * max(0.0, math.sin(2 * math.pi * p))
        keys.append(key(cycle * u, x=x, y=y,
                        curve=None if i == steps else EASE_IN_OUT))
    return {"translate": keys}


def clip_jump(parts, squash):
    """Anticipation, tuck, reach — the anticipate curve is what sells the launch."""
    anim = {"bones": {
        "body": {"translate": [key(0, x=0, y=-2.5 * squash, curve=ANTICIPATE),
                               key(0.18, x=0, y=3.0 * squash, curve=EASE_OUT),
                               key(0.5, x=0, y=1.2 * squash)],
                 "rotate": [key(0, value=0, curve=EASE_OUT),
                            key(0.5, value=-7)]},
        "head": {"rotate": [key(0, value=0, curve=EASE_OUT), key(0.5, value=6)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=0, curve=OVERSHOOT),
                                            key(0.3, value=26), key(0.5, value=20)]}
    for hand, sign in (("hand_l", -1), ("hand_r", 1)):
        if hand in parts:
            anim["bones"][hand] = {"translate": [
                key(0, x=0, y=0, curve=EASE_OUT),
                key(0.5, x=sign * 2.0, y=6.0)]}
    for foot, sign in (("foot_l", -1), ("foot_r", 1)):
        if foot in parts:
            anim["bones"][foot] = {"translate": [
                key(0, x=0, y=0, curve=EASE_OUT),
                key(0.22, x=sign * 1.5, y=5.0, curve=EASE_IN_OUT),
                key(0.5, x=sign * 0.5, y=3.0)]}
    return anim


def clip_fall(parts, squash):
    """The descent. Loops, because a fall has no natural length.

    Arms trail *up*, which is the cartoon convention for falling and reads
    instantly — the same pose with arms down looks like floating.
    """
    anim = {"bones": {
        "body": {"translate": [key(0, x=0, y=0, curve=EASE_IN_OUT),
                               key(0.3, x=0, y=-1.2 * squash, curve=EASE_IN_OUT),
                               key(0.6, x=0, y=0)],
                 "rotate": [key(0, value=6, curve=EASE_IN_OUT),
                            key(0.3, value=10, curve=EASE_IN_OUT),
                            key(0.6, value=6)]},
        "head": {"rotate": [key(0, value=-4, curve=EASE_IN_OUT),
                            key(0.3, value=-8, curve=EASE_IN_OUT),
                            key(0.6, value=-4)]},
    }}
    if "tuft" in parts:
        # Hair streams upward against the fall.
        anim["bones"]["tuft"] = {"rotate": [key(0, value=-30, curve=EASE_IN_OUT),
                                            key(0.3, value=-40, curve=EASE_IN_OUT),
                                            key(0.6, value=-30)]}
    for hand, sign in (("hand_l", -1), ("hand_r", 1)):
        if hand in parts:
            anim["bones"][hand] = {"translate": [
                key(0, x=sign * 3.0, y=7.0, curve=EASE_IN_OUT),
                key(0.3, x=sign * 3.8, y=8.5, curve=EASE_IN_OUT),
                key(0.6, x=sign * 3.0, y=7.0)]}
    for foot, sign in (("foot_l", -1), ("foot_r", 1)):
        if foot in parts:
            anim["bones"][foot] = {"translate": [
                key(0, x=sign * 1.0, y=-1.0, curve=EASE_IN_OUT),
                key(0.3, x=sign * 1.6, y=-2.0, curve=EASE_IN_OUT),
                key(0.6, x=sign * 1.0, y=-1.0)]}
    return anim


def clip_land(parts, squash):
    """Impact and recover. Short and hard — the squash *is* the weight.

    One-shot: the scene crossfades out of it into idle or run, so it ends at the
    neutral pose rather than looping back to the squash.
    """
    anim = {"bones": {
        "body": {"scale": [key(0, x=1.26, y=0.74, curve=EASE_OUT),
                           key(0.10, x=0.94, y=1.06, curve=EASE_IN_OUT),
                           key(0.24, x=1.0, y=1.0)],
                 "translate": [key(0, x=0, y=-3.2 * squash, curve=EASE_OUT),
                               key(0.24, x=0, y=0)]},
        "head": {"translate": [key(0, x=0, y=-2.0, curve=OVERSHOOT),
                               key(0.24, x=0, y=0)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=34, curve=OVERSHOOT),
                                            key(0.16, value=-8), key(0.24, value=0)]}
    for foot, sign in (("foot_l", -1), ("foot_r", 1)):
        if foot in parts:
            anim["bones"][foot] = {"translate": [
                key(0, x=sign * 2.6, y=0, curve=EASE_OUT),
                key(0.24, x=0, y=0)]}
    for hand, sign in (("hand_l", -1), ("hand_r", 1)):
        if hand in parts:
            anim["bones"][hand] = {"translate": [
                key(0, x=sign * 2.4, y=-1.5, curve=EASE_OUT),
                key(0.24, x=0, y=0)]}
    return anim


def clip_dash(parts):
    """Streaked forward, held. Loops over the dash's short window.

    The pose is the read: body pitched into the direction of travel, limbs swept
    back. Nothing about it needs to move much, because the dash is 0.16s.
    """
    anim = {"bones": {
        "body": {"rotate": [key(0, value=0, curve=EASE_OUT), key(0.08, value=16),
                            key(0.16, value=16)],
                 "scale": [key(0, x=1.0, y=1.0, curve=EASE_OUT),
                           key(0.08, x=1.18, y=0.86), key(0.16, x=1.18, y=0.86)]},
        "head": {"rotate": [key(0, value=0, curve=EASE_OUT), key(0.16, value=-10)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=0, curve=EASE_OUT),
                                            key(0.16, value=-52)]}
    for hand, sign in (("hand_l", -1), ("hand_r", 1)):
        if hand in parts:
            anim["bones"][hand] = {"translate": [
                key(0, x=0, y=0, curve=EASE_OUT),
                key(0.16, x=-4.5, y=sign * 1.2)]}
    for foot, sign in (("foot_l", -1), ("foot_r", 1)):
        if foot in parts:
            anim["bones"][foot] = {"translate": [
                key(0, x=0, y=0, curve=EASE_OUT),
                key(0.16, x=-3.0, y=sign * 0.8)]}
    return anim


def clip_climb(parts, bounce):
    """Hand over hand up a vine. Loops, and the two sides are in antiphase —
    which is the only thing that makes a climb read as a climb."""
    period = 0.72
    anim = {"bones": {
        "body": {"translate": [key(0, x=0, y=0, curve=EASE_IN_OUT),
                               key(period / 2, x=0, y=1.6 * bounce, curve=EASE_IN_OUT),
                               key(period, x=0, y=0)],
                 "rotate": [key(0, value=-3, curve=EASE_IN_OUT),
                            key(period / 2, value=3, curve=EASE_IN_OUT),
                            key(period, value=-3)]},
        "head": {"rotate": [key(0, value=2, curve=EASE_IN_OUT),
                            key(period / 2, value=-2, curve=EASE_IN_OUT),
                            key(period, value=2)]},
    }}
    for index, (hand, sign) in enumerate((("hand_l", -1), ("hand_r", 1))):
        if hand not in parts:
            continue
        # Half a period out of phase: one hand reaches while the other pulls.
        high, low = (9.0, 1.0) if index == 0 else (1.0, 9.0)
        anim["bones"][hand] = {"translate": [
            key(0, x=sign * 1.6, y=high, curve=EASE_IN_OUT),
            key(period / 2, x=sign * 1.6, y=low, curve=EASE_IN_OUT),
            key(period, x=sign * 1.6, y=high)]}
    for index, (foot, sign) in enumerate((("foot_l", -1), ("foot_r", 1))):
        if foot not in parts:
            continue
        high, low = (2.4, -1.0) if index == 1 else (-1.0, 2.4)
        anim["bones"][foot] = {"translate": [
            key(0, x=sign * 1.2, y=high, curve=EASE_IN_OUT),
            key(period / 2, x=sign * 1.2, y=low, curve=EASE_IN_OUT),
            key(period, x=sign * 1.2, y=high)]}
    return anim


def clip_victory(parts, bounce, squash):
    """A hop with both arms up, then a held pose. One-shot: it is the last thing
    the player sees on a level, so it should settle rather than loop."""
    anim = {"bones": {
        "body": {"translate": [key(0, x=0, y=0, curve=ANTICIPATE),
                               key(0.22, x=0, y=7.0 * bounce, curve=EASE_IN_OUT),
                               key(0.44, x=0, y=0, curve=EASE_OUT),
                               key(0.9, x=0, y=0)],
                 "scale": [key(0, x=1.0, y=1.0, curve=EASE_OUT),
                           key(0.44, x=1.16, y=0.86, curve=EASE_IN_OUT),
                           key(0.6, x=1.0, y=1.0),
                           key(0.9, x=1.0, y=1.0)]},
        "head": {"rotate": [key(0, value=0, curve=EASE_IN_OUT),
                            key(0.22, value=-8, curve=EASE_IN_OUT),
                            key(0.9, value=0)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=0, curve=OVERSHOOT),
                                            key(0.3, value=30),
                                            key(0.6, value=-10),
                                            key(0.9, value=6)]}
    for hand, sign in (("hand_l", -1), ("hand_r", 1)):
        if hand in parts:
            anim["bones"][hand] = {"translate": [
                key(0, x=0, y=0, curve=EASE_OUT),
                key(0.22, x=sign * 4.0, y=11.0, curve=EASE_IN_OUT),
                key(0.9, x=sign * 3.4, y=10.0)]}
    for foot, sign in (("foot_l", -1), ("foot_r", 1)):
        if foot in parts:
            anim["bones"][foot] = {"translate": [
                key(0, x=0, y=0, curve=EASE_OUT),
                key(0.22, x=sign * 1.4, y=4.0, curve=EASE_IN_OUT),
                key(0.44, x=0, y=0),
                key(0.9, x=0, y=0)]}
    return anim


def clip_punch(parts):
    """Wind up, fire, snap back. The fist's own hull is what connects in
    gameplay (`SkeletalPlayer.attackRegion`), so the extension matters."""
    anim = {"bones": {
        "body": {"rotate": [key(0, value=0, curve=ANTICIPATE),
                            key(0.08, value=8), key(0.21, value=0)]},
    }}
    if "hand_r" in parts:
        anim["bones"]["hand_r"] = {"translate": [
            key(0, x=0, y=0, curve=ANTICIPATE),
            key(0.06, x=-3, y=1),
            key(0.11, x=17, y=0, curve=EASE_OUT),
            key(0.21, x=0, y=0)]}
    if "hand_l" in parts:
        anim["bones"]["hand_l"] = {"translate": [
            key(0, x=0, y=0, curve=EASE_IN_OUT),
            key(0.11, x=-4, y=2, curve=EASE_IN_OUT),
            key(0.21, x=0, y=0)]}
    anim["events"] = [{"time": 0.09, "name": "punch"}]
    return anim


def clip_hurt(parts):
    anim = {"bones": {
        "body": {"rotate": [key(0, value=0, curve=EASE_OUT),
                            key(0.09, value=-16), key(0.34, value=0)],
                 "translate": [key(0, x=0, y=0, curve=EASE_OUT),
                               key(0.09, x=-4, y=1), key(0.34, x=0, y=0)]},
        "head": {"rotate": [key(0, value=0, curve=EASE_OUT),
                            key(0.09, value=14), key(0.34, value=0)]},
    }}
    if "tuft" in parts:
        anim["bones"]["tuft"] = {"rotate": [key(0, value=0, curve=OVERSHOOT),
                                            key(0.12, value=-30), key(0.34, value=0)]}
    anim["events"] = [{"time": 0.02, "name": "hurt"}]
    return anim


# ─── build ───────────────────────────────────────────────────────────────────

def build(spec, out_dir, preview=False):
    """Spec → files on disk.

    Returns `(written, problems, notes)`: problems are fatal (a bad spec),
    notes are advisory (no imaging stack, so the rig shipped without art).
    """
    problems = validate_spec(spec)
    if problems:
        return [], problems, []

    palette = spec["style"]["palette"]
    style = spec["style"]
    name = spec["name"]
    os.makedirs(out_dir, exist_ok=True)
    written, notes = [], []

    if HAVE_RASTER:
        for i, part in enumerate(spec["parts"]):
            base = _rgb(palette, part["color"])
            ink = _rgb(palette, "outline", (60, 30, 12))
            art = paint_part(part["shape"], part["size"], base, ink, style, seed=i * 13)
            if part.get("face"):
                draw_face(art, part["size"], palette, style)
            for scale in SCALES:
                # 2× nominal: the @3x file carries 6 px per scene point, which
                # covers the densest device (iPad Pro, 5.3) with headroom.
                w = max(1, int(round(part["size"][0] * scale * DENSITY_MULTIPLE)))
                h = max(1, int(round(part["size"][1] * scale * DENSITY_MULTIPLE)))
                path = os.path.join(out_dir, f"{name}_{part['name']}@{scale}x.png")
                art.resize((w, h), Image.LANCZOS).save(path)
                written.append(path)
    else:
        notes.append(RASTER_HINT)

    rig = build_rig(spec)
    rig_path = os.path.join(out_dir, f"{name}_rig.json")
    with open(rig_path, "w") as f:
        json.dump(rig, f, indent=1)
    written.append(rig_path)

    if preview and HAVE_RASTER:
        written.append(write_preview(spec, out_dir))
    return written, [], notes


def write_preview(spec, out_dir):
    """A contact sheet of the parts plus the assembled setup pose, shown on both
    a dark and a light ground — an ink outline is invisible against a dark sheet,
    which is exactly how a clipped outline hid the first time."""
    palette = spec["style"]["palette"]
    style = spec["style"]
    name = spec["name"]
    scale = 6
    sheet = Image.new("RGBA", (940, 470), (28, 30, 38, 255))
    d = ImageDraw.Draw(sheet)
    d.text((16, 12), f"{name} - art-spec/1 preview", fill=(230, 235, 245, 255))
    # the game's sky, so the silhouette and outline are judged in context
    d.rectangle([0, 250, 620, 470], fill=(115, 184, 250, 255))
    d.text((16, 258), "on the game's sky", fill=(20, 40, 70, 255))

    painted = []
    for i, part in enumerate(spec["parts"]):
        base = _rgb(palette, part["color"])
        ink = _rgb(palette, "outline", (60, 30, 12))
        art = paint_part(part["shape"], part["size"], base, ink, style, seed=i * 13)
        if part.get("face"):
            draw_face(art, part["size"], palette, style)
        painted.append((part, art))

    for row_y, label_col in ((60, (150, 158, 172, 255)), (290, (20, 40, 70, 255))):
        x = 16
        for part, art in painted:
            w = int(part["size"][0] * scale * 0.5)
            h = int(part["size"][1] * scale * 0.5)
            sheet.alpha_composite(art.resize((w, h), Image.LANCZOS), (x, row_y))
            d.text((x, row_y + h + 6), part["name"], fill=label_col)
            x += w + 18

    # assembled setup pose, using the rig's own bone positions
    parts = {p["name"]: (p, a) for p, a in painted}
    ox, oy = 760, 360
    order = ["foot_l", "foot_r", "hand_l", "hand_r", "body", "head", "tuft"]
    for pname in order:
        entry = parts.get(pname)
        if not entry:
            continue
        part, art = entry
        bx, by = bone_world(pname)
        w = int(part["size"][0] * scale * 0.5)
        h = int(part["size"][1] * scale * 0.5)
        sheet.alpha_composite(art.resize((w, h), Image.LANCZOS),
                              (int(ox + bx * scale * 0.5 - w / 2),
                               int(oy - by * scale * 0.5 - h / 2)))
    d.text((680, 20), "assembled setup pose", fill=(150, 158, 172, 255))
    path = os.path.join(out_dir, f"{name}_preview.png")
    sheet.convert("RGB").save(path)
    return path


# ─── ingesting art from an image model ───────────────────────────────────────
#
# The procedural painter above is a stand-in, and honest about it: reference-grade
# painted art comes from an artist or an image-generation model, not from
# ellipses and noise. What the engine needs from that art is not beauty but
# *structure* — parts on transparent backgrounds, one per bone, with sizes and
# pivots that match the rig. This turns a generated character sheet into exactly
# that, so "AI made me a Rayman-ish sprite" becomes an animated, colliding actor.

PART_SLOTS = ["body", "head", "tuft", "hand_l", "hand_r", "foot_l", "foot_r"]


def _cutout(img, tolerance=26):
    """Give an image an alpha channel by flooding the background in from the edges.

    Image models return a flat or near-flat backdrop rather than transparency.
    Flooding from the border (instead of keying a colour globally) keeps holes
    *inside* the character opaque — a white eye stays white.
    """
    img = img.convert("RGBA")
    a = np.asarray(img).astype(np.int16)
    h, w = a.shape[:2]
    if a[..., 3].min() < 250:                 # already has usable alpha
        return img

    corners = np.array([a[0, 0, :3], a[0, w - 1, :3],
                        a[h - 1, 0, :3], a[h - 1, w - 1, :3]], dtype=np.int16)
    bg = np.median(corners, axis=0)
    close = (np.abs(a[..., :3] - bg[None, None, :]).sum(-1) <= tolerance * 3)

    keep = np.zeros((h, w), dtype=bool)       # flood the border-connected region
    stack = [(0, x) for x in range(w)] + [(h - 1, x) for x in range(w)] \
        + [(y, 0) for y in range(h)] + [(y, w - 1) for y in range(h)]
    seen = np.zeros((h, w), dtype=bool)
    while stack:
        y, x = stack.pop()
        if y < 0 or x < 0 or y >= h or x >= w or seen[y, x] or not close[y, x]:
            continue
        seen[y, x] = True
        keep[y, x] = True
        stack.extend([(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)])

    out = a.copy()
    out[..., 3] = np.where(keep, 0, 255)
    # Deliberately crisp: softening here would bridge parts that merely touch,
    # and connected-component analysis would then read two limbs as one mass.
    # Each written crop gets its edge softened instead.
    result = Image.fromarray(out[..., :3].astype(np.uint8), "RGB").convert("RGBA")
    result.putalpha(Image.fromarray(out[..., 3].astype(np.uint8), "L"))
    return result


def _soften(img, radius=0.7):
    """Feather a crop's alpha so it doesn't alias against the game's sky."""
    alpha = img.split()[3].filter(ImageFilter.GaussianBlur(radius))
    out = img.copy()
    out.putalpha(alpha)
    return out


def _detect_grid(img, max_cells=12):
    """Work out the parts grid from the sheet, so `--grid` is optional.

    A spaced grid has empty gutters, and a gutter is a run of rows or columns
    whose alpha is entirely zero. Counting the *blocks between* the gutters gives
    the layout — no computer vision, just projection profiles, and it fails
    loudly (returns None) rather than guessing when the sheet has no clean
    gutters.

    Returns `(cols, rows)` or None.
    """
    alpha = np.asarray(img.split()[3]).astype(np.uint8) > 40
    if not alpha.any():
        return None

    def blocks(profile, min_gap):
        """Count runs of occupied cells separated by gaps of at least min_gap."""
        occupied = profile > 0
        runs, start = [], None
        for i, on in enumerate(occupied):
            if on and start is None:
                start = i
            elif not on and start is not None:
                runs.append((start, i))
                start = None
        if start is not None:
            runs.append((start, len(occupied)))
        if not runs:
            return []
        # Merge runs separated by a gap too small to be a gutter — a gap inside a
        # single drawn part (between two fingers, say) is not a cell boundary.
        merged = [list(runs[0])]
        for a, b in runs[1:]:
            if a - merged[-1][1] < min_gap:
                merged[-1][1] = b
            else:
                merged.append([a, b])
        return merged

    height, width = alpha.shape
    # A gutter has to be a meaningful fraction of the sheet, or noise splits cells.
    columns = blocks(alpha.sum(axis=0), max(4, width // 40))
    rows = blocks(alpha.sum(axis=1), max(4, height // 40))
    if not columns or not rows:
        return None
    cols_n, rows_n = len(columns), len(rows)
    # Plausibility, not just arithmetic. A *drawn figure* also separates into a
    # couple of vertical masses (head above body), and treating that as a 1×2
    # grid would slice the character in half. A real parts sheet is at least two
    # columns and at least four cells.
    if cols_n < 2 or cols_n * rows_n < 4 or cols_n * rows_n > max_cells:
        return None
    # Finally: is it actually a *grid*? A drawn figure can also split into three
    # column masses (arm, body, arm) over two row masses, and slicing that as a
    # 3×2 grid would cut the character up. The distinguishing property is
    # occupancy — a real parts sheet fills nearly every cell, a composition
    # leaves the corners empty.
    #
    # Cell *sizes* deliberately are not checked: a genuine sheet has a large body
    # cell next to a small foot cell, so uniformity would reject the real thing.
    # Occupancy is measured on the *detected* block boundaries, not on a uniform
    # slice of the sheet. A uniform slice is defeated by exactly the case this is
    # meant to catch: a figure with spread arms has its arms straddling the
    # uniform row boundary, so every uniform cell looks occupied while the real
    # block grid is visibly two-thirds empty.
    filled = 0
    for y0, y1 in rows:
        for x0, x1 in columns:
            if alpha[y0:y1, x0:x1].any():
                filled += 1
    if filled < 0.75 * cols_n * rows_n:
        return None
    return cols_n, rows_n


def _grid_boxes(img, cols, rows):
    """Tight boxes for a regular parts grid, in reading order.

    Connectivity can't separate limbs that touch, and a single drawn figure has
    every part touching. Asking an image model for a *spaced grid* of pieces and
    slicing on that grid is deterministic, and it is a prompt instruction rather
    than a computer-vision problem.
    """
    alpha = np.asarray(img.split()[3]).astype(np.uint8) > 40
    H, W = alpha.shape
    boxes = []
    for r in range(rows):
        for c in range(cols):
            y0, y1 = int(r * H / rows), int((r + 1) * H / rows)
            x0, x1 = int(c * W / cols), int((c + 1) * W / cols)
            cell = alpha[y0:y1, x0:x1]
            if not cell.any():
                continue
            ys, xs = np.nonzero(cell)
            boxes.append((x0 + int(xs.min()), y0 + int(ys.min()),
                          x0 + int(xs.max()) + 1, y0 + int(ys.max()) + 1))
    return boxes


def _components(img, min_area_frac=0.0015):
    """Opaque connected components, biggest first, as (bbox, area)."""
    alpha = np.asarray(img.split()[3]).astype(np.uint8) > 40
    h, w = alpha.shape
    seen = np.zeros_like(alpha)
    out = []
    for sy in range(0, h, 2):
        for sx in range(0, w, 2):
            if not alpha[sy, sx] or seen[sy, sx]:
                continue
            stack = [(sy, sx)]
            minx = maxx = sx
            miny = maxy = sy
            area = 0
            while stack:
                y, x = stack.pop()
                if y < 0 or x < 0 or y >= h or x >= w or seen[y, x] or not alpha[y, x]:
                    continue
                seen[y, x] = True
                area += 1
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
                stack.extend([(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)])
            if area >= min_area_frac * w * h:
                out.append(((minx, miny, maxx + 1, maxy + 1), area))
    return sorted(out, key=lambda c: -c[1])


def assign_parts(components, canvas):
    """Guess which blob is which bone from position and size.

    A sheet from an image model has no labels, so the mapping has to come from
    layout: the largest central mass is the body, the mass above it the head, a
    small pair low down the feet, a small pair at mid height the hands, and a
    narrow shape on top the hair. Wrong guesses are cheap to fix by hand — the
    rig is plain JSON — but this gets the common case right unattended.
    """
    W, H = canvas
    boxes = [c[0] for c in components]
    if not boxes:
        return {}
    assigned = {}
    remaining = list(boxes)

    def centre(b):
        return ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)

    def area(b):
        return (b[2] - b[0]) * (b[3] - b[1])

    body = max(remaining, key=area)
    assigned["body"] = body
    remaining.remove(body)
    bx, by = centre(body)

    above = [b for b in remaining if centre(b)[1] < by]
    if above:
        head = max(above, key=area)
        assigned["head"] = head
        remaining.remove(head)
        hx, hy = centre(head)
        spikes = [b for b in remaining if centre(b)[1] < hy]
        if spikes:
            tuft = max(spikes, key=area)
            assigned["tuft"] = tuft
            remaining.remove(tuft)

    lower = sorted([b for b in remaining if centre(b)[1] > by], key=lambda b: centre(b)[0])
    if len(lower) >= 2:
        assigned["foot_l"], assigned["foot_r"] = lower[0], lower[-1]
        remaining = [b for b in remaining if b not in (lower[0], lower[-1])]
    mids = sorted(remaining, key=lambda b: centre(b)[0])
    if len(mids) >= 2:
        assigned["hand_l"], assigned["hand_r"] = mids[0], mids[-1]
    return assigned


def ingest_sheet(path, name, out_dir, tile=40.0, height_tiles=0.85,
                 preview=True, grid=None):
    """A generated character sheet → per-part PNGs + a Spine rig sized to the art.

    Returns `(written, problems, notes)` like the other builders.
    """
    if not HAVE_RASTER:
        return [], [], [RASTER_HINT]
    sheet = _cutout(Image.open(path))
    notes_pre = []
    if grid is None:
        # Auto-detect, so `--grid` is a correction rather than a requirement. It
        # only fires on something that actually looks like a spaced parts sheet;
        # a drawn figure falls through to connectivity as before.
        detected = _detect_grid(sheet)
        if detected:
            grid = detected
            notes_pre.append(f"detected a {detected[0]}x{detected[1]} parts grid "
                             f"from the sheet's gutters (pass --grid to override)")
    if grid:
        cols, rows = grid
        boxes = _grid_boxes(sheet, cols, rows)
        parts = {slot: box for slot, box in zip(PART_SLOTS, boxes)}
        if len(boxes) < len(PART_SLOTS):
            notes_pre.append(f"grid {cols}x{rows} yielded {len(boxes)} filled cells; "
                             f"expected {len(PART_SLOTS)} in the order "
                             f"{', '.join(PART_SLOTS)}")
    else:
        comps = _components(sheet)
        if not comps:
            return [], [f"{path}: found no opaque shapes — is the background flat?"], []
        parts = assign_parts(comps, sheet.size)
        if len(comps) < 4:
            notes_pre.append(
                f"only {len(comps)} separate shape(s) found — parts that touch read "
                f"as one mass. Ask for a spaced grid and pass --grid COLSxROWS, or "
                f"cut the sheet by hand.")
    if "body" not in parts:
        return [], [f"{path}: could not identify a body mass"], notes_pre

    # Scale the art so it plays at the size the rig and physics body expect.
    #
    # The rule differs by layout, and getting it wrong is silent: a grid sheet's
    # union bounding box is the *sheet*, not the character, so scaling by it
    # shrinks every part to a tenth of its size. For a grid, match the shipped
    # rig's art-to-gameplay ratio (body + head heights against a character that
    # occupies `height_tiles` of a tile); for a figure, the union box really is
    # the character.
    notes = list(notes_pre)
    stock = {p["name"]: p["size"] for p in DEFAULT_SPEC["parts"]}
    target = tile * height_tiles
    if grid:
        stack_px = (parts["body"][3] - parts["body"][1])
        if "head" in parts:
            stack_px += parts["head"][3] - parts["head"][1]
        stack_points = stock["body"][1] + stock["head"][1]        # 30 + 24
        scale = stack_points / max(1, stack_px)
    else:
        union = [min(b[0] for b in parts.values()), min(b[1] for b in parts.values()),
                 max(b[2] for b in parts.values()), max(b[3] for b in parts.values())]
        scale = (stock["body"][1] + stock["head"][1]) / max(1, union[3] - union[1])
    if not 0.001 < scale < 100:
        return [], [f"{path}: implausible scale {scale:.4f} — check the sheet layout"], \
            notes_pre
    notes.append(f"scaled art by {scale:.3f} so body+head span "
                 f"{stock['body'][1] + stock['head'][1]:.0f}pt "
                 f"({target:.0f}pt character)")

    os.makedirs(out_dir, exist_ok=True)
    written, spec_parts = [], []
    for slot in PART_SLOTS:
        box = parts.get(slot)
        if not box:
            notes.append(f"no shape matched '{slot}' — the rig will omit it")
            continue
        crop = _soften(sheet.crop(box))
        pw = max(2.0, round((box[2] - box[0]) * scale, 1))
        ph = max(2.0, round((box[3] - box[1]) * scale, 1))
        # Keep the source pixels. Resizing a generated part down to `points × 3`
        # threw away most of what the image model produced — a 300px arm became
        # 78px, which is exactly the pixelation this pipeline exists to avoid.
        # The declared point size sets how big it plays; the pixels behind it
        # only ever get capped, never invented.
        native_w = box[2] - box[0]
        want_w = pw * 3 * DENSITY_MULTIPLE
        if native_w < want_w * 0.95:
            notes.append(f"{slot}: source art is {native_w}px for a {pw:.1f}pt part "
                         f"({native_w / max(pw, 1):.1f} px/pt); "
                         f"{ASSET_DENSITY:.0f} px/pt wanted — ask the image model "
                         f"for a larger sheet")
        for s in SCALES:
            target = max(1, int(round(pw * s * DENSITY_MULTIPLE)))
            # min(): downscale a generous source, but never upscale a thin one —
            # magnifying it would only add blur and file size.
            out_w = min(target, int(native_w))
            out_h = max(1, int(round(out_w * (box[3] - box[1]) / max(native_w, 1))))
            p = os.path.join(out_dir, f"{name}_{slot}@{s}x.png")
            crop.resize((out_w, out_h), Image.LANCZOS).save(p)
            written.append(p)
        spec_parts.append({"name": slot, "shape": "ball", "size": [pw, ph],
                           "color": "skin",
                           "mesh": slot in ("body", "head")})

    # The rig is built from the *measured* art, so bone lengths and mesh sizes
    # match the pixels instead of a guess.
    spec = {"format": "art-spec/1", "name": name,
            "style": {"palette": {"skin": [255, 255, 255], "outline": [40, 24, 12]}},
            "parts": spec_parts,
            "personality": {"bounce": 1.0, "swagger": 1.0, "squash": 1.0}}
    problems = validate_spec(spec)
    if problems:
        return written, problems, notes

    rig = build_rig(spec)
    rig_path = os.path.join(out_dir, f"{name}_rig.json")
    with open(rig_path, "w") as f:
        json.dump(rig, f, indent=1)
    written.append(rig_path)

    if preview:
        sheet_preview = Image.new("RGBA", sheet.size, (115, 184, 250, 255))
        sheet_preview.alpha_composite(sheet)
        pd = ImageDraw.Draw(sheet_preview)
        for slot, box in parts.items():
            pd.rectangle(box, outline=(255, 80, 40, 255), width=3)
            pd.text((box[0] + 4, box[1] + 4), slot, fill=(20, 20, 20, 255))
        p = os.path.join(out_dir, f"{name}_ingest.png")
        sheet_preview.convert("RGB").save(p)
        written.append(p)
    return written, [], notes



#
# The other half of "build a level as a non-designer": layered painted backdrops.
# A frieze-spec says what the layers *are* — canopy, ridge, trunks, vines, fog —
# at what depth; this paints them wide enough for the parallax travel and writes
# the `FriezeScene` JSON that `FriezeStage` already loads. Nothing new is needed
# on the runtime side.

FRIEZE_SCHEMA = {
    "type": "object",
    "properties": {
        "format": {"const": "frieze-spec/1"},
        "name": {"type": "string"},
        "sky": {"type": "array", "description": "gradient stops, index 0 = bottom",
                "items": {"type": "array", "items": {"type": "integer"},
                          "minItems": 3, "maxItems": 3}},
        "palette": {
            "type": "object",
            "description": "far/mid/near/accent RGB — depth-sorted foliage colours",
            "additionalProperties": {"type": "array", "items": {"type": "integer"},
                                     "minItems": 3, "maxItems": 3},
        },
        "haze": {"type": "number", "description": "atmospheric wash at depth 0, 0–1"},
        "focus": {"type": "number", "description": "gameplay plane depth, 0.4–0.7"},
        "vignette": {"type": "number"},
        "lightAngle": {"type": "number"},
        "layers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string",
                             "enum": ["canopy", "ridge", "trunks", "vines",
                                      "fog", "glow"]},
                    "depth": {"type": "number", "description": "0 far … 1 near"},
                    "color": {"type": "string", "description": "palette key"},
                    "y": {"type": "number", "description": "points from screen centre"},
                    "height": {"type": "number", "description": "points"},
                    "props": {"type": "array", "description":
                              "scattered instances on this plane: "
                              "{image, count, span, y, yJitter, scale, "
                              "scaleJitter, flipChance, seed, density}"},
                    "frises": {"type": "array", "description":
                               "painted spline geometry on this plane: "
                               "{points, thickness, capHeight, color, closed}"},
                },
                "required": ["kind", "depth", "color"],
            },
        },
        "rays": {"type": "boolean", "description": "volumetric light shafts"},
        "fireflies": {"type": "boolean"},
    },
    "required": ["format", "name", "sky", "palette", "layers"],
}

# Backdrop resolution, and why it differs from characters.
#
# A backdrop layer wide enough to cover a 50-tile level's parallax travel is
# ~1600pt. At the character density (6 px/pt) that is a 9600px texture — ~70MB
# for one layer, and there are six. So backdrops trade a little density for a
# budget that fits on a phone: 4 px/pt still clears every current device's
# `.aspectFill` scale except the iPad Pro's 5.3, and haze plus depth-of-field
# blur cover the rest. What they must NOT do is what this used to do — paint at
# 2 px/pt and upsample into a 6 px/pt file. That is a 3× enlargement, and on the
# gameplay-plane layers (which sit at the focus distance, so no DoF blur hides
# them) it reads as exactly the softness dense output was supposed to fix.
BACKDROP_DENSITY = 4.0
BACKDROP_MULTIPLE = BACKDROP_DENSITY / NOMINAL_DENSITY
# Supersampling *above* the output density, in px/pt. PIL draws polygons with no
# antialiasing, so the shapes need to be painted larger and averaged down — but
# only down to `BACKDROP_DENSITY`, never below it and then back up. Must be an
# int: the painters use it as a `range()` step and a PIL line width.
FRIEZE_SS = 6

# Layers repeat rather than being painted level-wide — the same reason a real
# backdrop is a tileable strip. Each kind gets a width long enough that the
# repeat isn't legible while it scrolls, and `_seamless` makes the wrap
# invisible. Fog and glow are near-uniform, so they can repeat sooner.
TILE_WIDTH = {"ridge": 760, "canopy": 520, "trunks": 680,
              "vines": 440, "fog": 700, "glow": 1040}
FRIEZE_WIDTH = 760           # default tile width in points

# `glow` is one light source, not a pattern — repeating it puts three suns in
# the sky. It is painted wide enough to cover its own parallax travel instead.
TILES = {"ridge", "canopy", "trunks", "vines", "fog"}

# The longest level the generated backdrops must cover, in tiles. Non-tiled layers
# are sized from this; `asset_audit --level-width` checks against the real longest.
LEVEL_TILES = 50


def layer_density(depth, focus, dof):
    """Pixels per point this layer deserves, given the blur it will receive.

    `FriezeBaker` blurs every layer by its distance from the focus plane, so a
    far ridge is Gaussian-blurred by ~2pt before the player ever sees it.
    Shipping that at the full density pays for detail the loader then destroys —
    on the layer that is *already* the biggest texture in the scene. Layers near
    the gameplay plane, which are the ones the eye actually reads, keep it all.
    """
    blur = abs(float(depth) - float(focus)) * float(dof)
    want = BACKDROP_DENSITY / (1.0 + blur / 2.0)
    return round(max(2.25, min(BACKDROP_DENSITY, want)) * 4) / 4


def _value_noise(w, h, cells, seed):
    rng = np.random.default_rng(seed)
    grid = rng.random((max(2, cells + 1), max(2, cells + 1))).astype(np.float32)
    return np.asarray(
        Image.fromarray((grid * 255).astype(np.uint8), "L")
        .resize((w, h), Image.BICUBIC), dtype=np.float32) / 255.0


def _fbm(w, h, seed, octaves=(3, 7, 17, 41)):
    """Fractal noise — the basis of every painterly texture here."""
    total = np.zeros((h, w), np.float32)
    amp, norm = 1.0, 0.0
    for i, cells in enumerate(octaves):
        total += _value_noise(w, h, cells, seed + i * 31) * amp
        norm += amp
        amp *= 0.55
    return total / norm


def _brush(img, strength, seed):
    """Break up flat fills with directional painterly value variation.

    This is the single biggest difference between "vector shapes with a gradient"
    and "looks painted": real brushwork leaves value blotches at several scales,
    and the eye reads their absence instantly even when the palette is right.
    """
    if strength <= 0:
        return img
    w, h = img.size
    a = np.asarray(img, dtype=np.float32)
    noise = _fbm(w, h, seed)
    # stretch the noise horizontally: strokes follow the form, they aren't fog
    stretched = np.asarray(
        Image.fromarray((noise * 255).astype(np.uint8), "L")
        .resize((max(2, w // 3), h), Image.BILINEAR)
        .resize((w, h), Image.BICUBIC), dtype=np.float32) / 255.0
    mix = (0.65 * noise + 0.35 * stretched - 0.5) * 2.0
    a[..., :3] *= (1.0 + mix[..., None] * strength)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def _glow(img, colour, strength, seed=0):
    """Backlit bloom: the reference's signature is light *behind* the foliage,
    so every silhouette carries a warm halo rather than a hard edge."""
    if strength <= 0:
        return img
    w, h = img.size
    alpha = img.split()[3]
    halo = alpha.filter(ImageFilter.GaussianBlur(max(3, w // 90)))
    glow = Image.new("RGBA", (w, h), tuple(int(c) for c in colour) + (0,))
    glow.putalpha(halo.point(lambda v: int(v * strength)))
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.alpha_composite(glow)
    out.alpha_composite(img)
    return out


def _feather_edges(img, bottom=0.0, top=0.0, sides=0.0):
    """Fade a layer's alpha near chosen edges.

    Painted content that runs off a layer's own boundary composites as a
    straight line across the picture — a canopy of round blobs suddenly ends in
    a ruler-edge. Layers that are *meant* to reach an edge (a ridge, a trunk
    rooted below frame) pass 0 for it; the rest fade out and read as depth.
    """
    if not any((bottom, top, sides)):
        return img
    w, h = img.size
    a = np.asarray(img).astype(np.float32)
    mask = np.ones((h, w), np.float32)
    if bottom > 0:
        n = max(1, int(h * bottom))
        mask[h - n:, :] *= np.linspace(1, 0, n, dtype=np.float32)[:, None]
    if top > 0:
        n = max(1, int(h * top))
        mask[:n, :] *= np.linspace(0, 1, n, dtype=np.float32)[:, None]
    if sides > 0:
        n = max(1, int(w * sides))
        ramp = np.linspace(0, 1, n, dtype=np.float32)[None, :]
        mask[:, :n] *= ramp
        mask[:, w - n:] *= ramp[:, ::-1]
    a[..., 3] *= mask
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def _wobble(n, amp, seed, smooth=3):
    """A smooth pseudo-random offset series — organic edges instead of arcs."""
    rng = np.random.default_rng(seed)
    raw = rng.random(n + smooth * 2) - 0.5
    kernel = np.ones(smooth * 2 + 1) / (smooth * 2 + 1)
    return np.convolve(raw, kernel, mode="same")[smooth:smooth + n] * amp * 2


def _spiral(d, cx, cy, r, turns, colour, width, seed=0):
    """The curl that says 'Rayman' more than any other single shape — every
    trunk, vine and leaf tip in the reference ends in one."""
    pts = []
    steps = int(28 * turns)
    for i in range(steps + 1):
        t = i / steps
        ang = t * turns * 2 * math.pi
        rad = r * (1 - t * 0.82)
        pts.append((cx + math.cos(ang) * rad, cy + math.sin(ang) * rad * 0.85))
    for i in range(len(pts) - 1):
        taper = max(1, int(width * (1 - i / len(pts)) ** 0.6))
        d.line([pts[i], pts[i + 1]], fill=colour, width=taper)


def _blade(d, x, y, length, width, angle, colour, seed=0):
    """A long leaf blade with a curved spine — the reference is full of them."""
    rad = math.radians(angle)
    tipx, tipy = x + math.cos(rad) * length, y - math.sin(rad) * length
    ctrl = (x + math.cos(rad + 0.5) * length * 0.55,
            y - math.sin(rad + 0.5) * length * 0.55)
    left = _quad((x, y), ctrl, (tipx, tipy), 12)
    ctrl2 = (x + math.cos(rad - 0.45) * length * 0.6,
             y - math.sin(rad - 0.45) * length * 0.6)
    right = _quad((tipx, tipy), ctrl2, (x + width * 0.6, y + width * 0.3), 12)
    d.polygon(left + right, fill=colour)


def _resolve(img, width, height, density=None):
    """Supersampled canvas → the density the file actually ships at.

    Always a downsample (FRIEZE_SS > BACKDROP_DENSITY), which is where the edge
    antialiasing comes from. The old code resolved to *points* here and let the
    caller enlarge, which threw away the supersample and then guessed the
    detail back.
    """
    density = BACKDROP_DENSITY if density is None else density
    return img.resize((max(4, round(width * density)),
                       max(4, round(height * density))), Image.LANCZOS)


def _seamless(img, fade_points, density=None):
    """Make a layer tile with no visible seam, by folding its tail into its head.

    Standard offset-blend: cross-fade the last `fade` columns over the first
    `fade`, then crop the tail away. Column 0 of the result is the original
    column `fade`, and the last column is `fade - 1` — consecutive pixels in the
    source, so the wrap joins as smoothly as the middle of the image.
    Premultiplied, because blending straight RGBA against transparent black
    darkens every edge into a halo.
    """
    w, h = img.size
    density = BACKDROP_DENSITY if density is None else density
    fade = int(min(fade_points * density, w // 3))
    if fade < 2:
        return img
    a = np.asarray(img).astype(np.float32)
    rgb, alpha = a[..., :3], a[..., 3:4] / 255.0
    pm = rgb * alpha                                   # premultiply
    ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)[None, :, None]
    pm[:, :fade] = pm[:, :fade] * ramp + pm[:, w - fade:] * (1 - ramp)
    alpha[:, :fade] = alpha[:, :fade] * ramp + alpha[:, w - fade:] * (1 - ramp)
    pm, alpha = pm[:, :w - fade], alpha[:, :w - fade]
    out = np.concatenate([pm / np.maximum(alpha, 1e-4), alpha * 255.0], axis=2)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA")


def paint_frieze_layer(kind, color, width, height, style, seed=0, depth=0.5,
                       density=None):
    """One backdrop layer, painted RGBA at (width, height) points × FRIEZE_SS.

    Shape language and finish both come from the reference frames: organic
    silhouettes ending in curls, painterly value texture at several scales, and
    a backlit halo. `depth` drives how much of that is dialled back — far layers
    are flatter and hazier because that is what distance does.
    """
    w, h = int(width * FRIEZE_SS), max(8, int(height * FRIEZE_SS))
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = np.array(color, dtype=np.float32)
    rng = np.random.default_rng(seed)
    accent = _rgb(style.get("palette", {}), "accent", (255, 246, 190))

    def shade(f):
        return tuple(int(max(0, min(255, c * f))) for c in base)

    if kind == "ridge":
        top = h * 0.40 + _wobble(w, h * 0.18, seed, smooth=45)
        poly = [(x, top[x]) for x in range(0, w, 4)] + [(w, h), (0, h)]
        d.polygon(poly, fill=shade(0.80) + (255,))
        # lit cap along the crest, and vertical cliff striations below it
        cap = [(x, top[x]) for x in range(0, w, 4)] + \
              [(x, top[x] + h * 0.06) for x in range(w - 1, 0, -4)]
        d.polygon(cap, fill=shade(1.22) + (255,))
        for _ in range(int(w / (26 * FRIEZE_SS))):
            x = int(rng.integers(0, w))
            depth_px = int(rng.integers(int(h * 0.12), int(h * 0.5)))
            d.line([(x, top[min(x, w - 1)] + h * 0.05),
                    (x + rng.integers(-6, 6), top[min(x, w - 1)] + depth_px)],
                   fill=shade(0.66) + (120,), width=int(rng.integers(2, 6)) * FRIEZE_SS)

    elif kind == "canopy":
        # leaf masses hanging from the top, each a cluster of blades + a curl
        for _ in range(int(w / (46 * FRIEZE_SS)) + 3):
            cx = int(rng.integers(-40, w + 40))
            r = int(rng.integers(int(h * 0.26), int(h * 0.68)))
            cy = int(rng.integers(-int(h * 0.3), int(h * 0.3)))
            tint = shade(0.72 + 0.34 * rng.random())
            d.ellipse([cx - r, cy - r, cx + r, cy + int(r * 0.9)], fill=tint + (255,))
            for _ in range(3):
                _blade(d, cx + rng.integers(-r // 2, r // 2), cy + r * 0.6,
                       r * rng.uniform(0.5, 1.1), r * 0.18,
                       rng.uniform(200, 340), shade(0.8) + (255,))
        for _ in range(int(w / (170 * FRIEZE_SS)) + 1):
            cx = int(rng.integers(0, w))
            _spiral(d, cx, h * 0.55, h * 0.22, 1.6, shade(1.1) + (230,),
                    max(2, 3 * FRIEZE_SS))

    elif kind == "trunks":
        count = max(2, int(w / (250 * FRIEZE_SS)))
        for i in range(count):
            cx = int((i + 0.5) * w / count) + int(rng.integers(-40, 40) * FRIEZE_SS)
            tw = int(rng.integers(30, 62) * FRIEZE_SS)
            lean = _wobble(h, tw * 0.55, seed + i, smooth=30)
            # segment bulges: width swells between rings, as bamboo does
            swell = 1.0 + 0.12 * np.sin(np.arange(h) / (36.0 * FRIEZE_SS))
            left = [(cx - tw * 0.5 * swell[y] + lean[y], y) for y in range(0, h, 6)]
            right = [(cx + tw * 0.5 * swell[y] + lean[y], y)
                     for y in range(h - 1, 0, -6)]
            d.polygon(left + right, fill=shade(0.84) + (255,))
            # bamboo-ish segment rings and a lit side stripe
            for y in range(int(h * 0.1), h, int(rng.integers(50, 110)) * FRIEZE_SS):
                off = lean[min(y, h - 1)]
                d.arc([cx - tw // 2 + off, y - tw * 0.22,
                       cx + tw // 2 + off, y + tw * 0.22],
                      start=15, end=165, fill=shade(0.66) + (200,),
                      width=max(2, FRIEZE_SS * 2))
            d.line([(cx - tw * 0.2 + lean[y], y) for y in range(0, h, 6)],
                   fill=shade(1.20) + (210,), width=max(2, int(tw * 0.16)))
            _spiral(d, cx + tw * 0.1, tw * 0.9, tw * 0.85, 1.5,
                    shade(0.9) + (255,), int(tw * 0.35))

    elif kind == "vines":
        for i in range(int(w / (64 * FRIEZE_SS)) + 2):
            cx = int(rng.integers(0, w))
            length = int(rng.integers(int(h * 0.35), h))
            sway = _wobble(length, 26 * FRIEZE_SS, seed + i * 7, smooth=18)
            d.line([(cx + sway[y], y) for y in range(0, length, 4)],
                   fill=shade(0.86) + (255,), width=max(2, 3 * FRIEZE_SS))
            for t in range(0, length, max(24, length // 7)):
                _blade(d, cx + sway[t], t, rng.uniform(12, 30) * FRIEZE_SS,
                       6 * FRIEZE_SS, rng.uniform(30, 150), shade(1.0) + (255,))
            _spiral(d, cx + sway[length - 1], length, 9 * FRIEZE_SS, 1.7,
                    shade(0.9) + (255,), max(2, 3 * FRIEZE_SS))

    elif kind == "glow":
        # The backlight everything else is silhouetted against. In the reference
        # frames this single element carries the whole read of depth: foliage is
        # dark *because* something bright sits behind it.
        core = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        cd = ImageDraw.Draw(core)
        cx, cy = w * 0.42, h * 0.44
        for i, (rf, alpha) in enumerate([(0.62, 90), (0.42, 110), (0.24, 140),
                                         (0.12, 170)]):
            rx, ry = w * rf * 0.5, h * rf * 0.85
            tint = tuple(int(c + (255 - c) * (0.25 + i * 0.18)) for c in accent)
            cd.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=tint + (alpha,))
        core = core.filter(ImageFilter.GaussianBlur(max(8, w // 26)))
        return _resolve(core, width, height, density)

    elif kind == "fog":
        band = np.linspace(0, 1, h, dtype=np.float32)[:, None]
        veil = _fbm(w, h, seed, octaves=(2, 5, 11))
        # clip before the power: in float32, sin(pi) lands a hair below zero,
        # and a negative base with a fractional exponent is NaN
        alpha = (np.clip(np.sin(band * math.pi), 0, None) ** 1.3
                 * (0.55 + 0.45 * veil) * 210)
        # feather the ends too, or the band composites as a visible rectangle
        across = np.clip(np.sin(np.linspace(0, math.pi, w, dtype=np.float32)) * 1.6,
                         0, 1)[None, :]
        alpha = alpha * across
        layer = np.zeros((h, w, 4), dtype=np.uint8)
        lit = shade(1.3)
        layer[..., 0], layer[..., 1], layer[..., 2] = [int(c) for c in lit]
        layer[..., 3] = np.clip(alpha, 0, 255).astype(np.uint8)
        img = Image.fromarray(layer, "RGBA").filter(
            ImageFilter.GaussianBlur(5 * FRIEZE_SS))
        return _resolve(img, width, height, density)

    # finish: painterly texture, then a backlit halo, then a touch of softening.
    # Far layers get more texture damping and more glow — that *is* aerial
    # perspective, and it is most of why the reference reads as deep.
    # Hanging foliage fades out before its own boundary; a ridge or a trunk is
    # rooted off-frame and must not.
    if kind in ("canopy", "vines"):
        img = _feather_edges(img, bottom=0.22, sides=0.02)
    img = _brush(img, strength=float(style.get("texture", 0.22)) * (1.15 - depth * 0.5),
                 seed=seed + 55)
    img = _glow(img, accent, strength=0.30 + 0.32 * (1 - depth), seed=seed)
    img = img.filter(ImageFilter.GaussianBlur(0.5 * FRIEZE_SS))
    return _resolve(img, width, height, density)


# ─── terrain textures for frises ─────────────────────────────────────────────
#
# A frise fills its band with a *tiled* texture, so these have to tile in both
# directions — a seam in a cliff face runs the whole length of a hill and is the
# first thing anyone notices. Same offset-blend the backdrop layers use, applied
# on both axes.

def _seamless_both(img, fade_points, density):
    """Make a texture tile in x and y."""
    out = _seamless(img, fade_points, density)
    out = out.transpose(Image.ROTATE_90)
    out = _seamless(out, fade_points, density)
    return out.transpose(Image.ROTATE_270)


def paint_terrain(kind, colour, size_points=(96, 96), seed=0,
                  density=ASSET_DENSITY):
    """One tiling terrain texture: `rock`, `soil`, `grass` or `bark`."""
    if not HAVE_RASTER:
        return None
    # Painted oversized, because `_seamless_both` folds a fade-width strip off
    # each axis to make the tile wrap. Without this a caller who asks for a 96pt
    # tile silently gets an 83pt one — harmless for a tiling texture, but it makes
    # the declared size a lie and any layout that trusts it wrong.
    fade_fraction = 0.14
    grow = 1.0 / (1.0 - fade_fraction)
    w = max(8, int(size_points[0] * grow * FRIEZE_SS))
    h = max(8, int(size_points[1] * grow * FRIEZE_SS))
    img = Image.new("RGBA", (w, h), tuple(int(c) for c in colour) + (255,))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(seed)
    # Grass is already a saturated green before the pass, so the same multiplier
    # that lifts rock out of grey pushes grass into neon.
    colour = _vivid(colour, saturation=1.18 if kind == "grass" else 1.45,
                    value=1.06 if kind == "grass" else 1.10)
    base = np.array(colour, np.float32)
    alt = np.array(_hue_rotate(colour, 16), np.float32)

    def shade(f):
        return _hue_shade(base, f)

    def shade_alt(f):
        return _hue_shade(alt, f)

    if kind == "rock":
        # Angular facets: a few large polygons with hard value steps, which is
        # what makes rock read as rock rather than as noise.
        for _ in range(int(w * h / (90 * FRIEZE_SS) ** 2) + 6):
            cx, cy = rng.integers(0, w), rng.integers(0, h)
            r = int(rng.integers(18, 52) * FRIEZE_SS)
            sides = int(rng.integers(4, 7))
            pts = []
            for i in range(sides):
                a = 2 * math.pi * i / sides + rng.uniform(-0.3, 0.3)
                pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r * 0.7))
            # Wider value range and alternating hues: the old 0.82…1.14 band is
            # why cave and ridge rock read as one flat colour.
            tone = shade_alt if rng.random() < 0.45 else shade
            d.polygon(pts, fill=tone(rng.uniform(0.68, 1.34)) + (255,))
        # Cracks
        for _ in range(int(w / (40 * FRIEZE_SS)) + 3):
            x, y = rng.integers(0, w), rng.integers(0, h)
            pts = [(x, y)]
            for _ in range(6):
                x += rng.integers(-22, 22) * FRIEZE_SS
                y += rng.integers(6, 26) * FRIEZE_SS
                pts.append((x, y))
            d.line(pts, fill=shade(0.62) + (190,), width=max(2, FRIEZE_SS))
    elif kind == "soil":
        for _ in range(int(w * h / (26 * FRIEZE_SS) ** 2) + 24):
            cx, cy = rng.integers(0, w), rng.integers(0, h)
            r = int(rng.integers(4, 16) * FRIEZE_SS)
            tone = shade_alt if rng.random() < 0.4 else shade
            d.ellipse([cx - r, cy - r * 0.6, cx + r, cy + r * 0.6],
                      fill=tone(rng.uniform(0.74, 1.24)) + (255,))
    elif kind == "grass":
        # Blades from the top edge — the cap texture, so the top is what matters.
        for _ in range(int(w / (5 * FRIEZE_SS)) + 20):
            x = int(rng.integers(0, w))
            length = int(rng.integers(int(h * 0.4), int(h * 0.95)))
            lean = int(rng.integers(-8, 8) * FRIEZE_SS)
            tone = shade_alt if rng.random() < 0.5 else shade
            d.line([(x, h), (x + lean, h - length)],
                   fill=tone(rng.uniform(0.78, 1.42)) + (255,),
                   width=max(2, int(2 * FRIEZE_SS)))
    elif kind == "bark":
        for _ in range(int(w / (10 * FRIEZE_SS)) + 8):
            x = int(rng.integers(0, w))
            d.line([(x + int(math.sin(y / (30.0 * FRIEZE_SS)) * 6 * FRIEZE_SS), y)
                    for y in range(0, h, 4)],
                   fill=shade(rng.uniform(0.7, 1.15)) + (220,),
                   width=int(rng.integers(2, 6)) * FRIEZE_SS)

    elif kind == "sand":
        # Ripples: long low arcs, which is what distinguishes sand from soil.
        for i in range(int(h / (7 * FRIEZE_SS))):
            y = i * 7 * FRIEZE_SS + int(rng.integers(0, 4 * FRIEZE_SS))
            d.arc([-w * 0.2, y - 6 * FRIEZE_SS, w * 1.2, y + 6 * FRIEZE_SS],
                  start=190, end=350,
                  fill=shade(rng.uniform(0.9, 1.12)) + (200,),
                  width=max(2, FRIEZE_SS))
    elif kind == "ice":
        for _ in range(int(w / (30 * FRIEZE_SS)) + 5):
            x, y = rng.integers(0, w), rng.integers(0, h)
            pts = [(x, y)]
            for _ in range(4):
                x += rng.integers(-30, 30) * FRIEZE_SS
                y += rng.integers(-30, 30) * FRIEZE_SS
                pts.append((x, y))
            d.line(pts, fill=shade(1.3) + (170,), width=max(2, FRIEZE_SS))
    elif kind == "moss":
        for _ in range(int(w * h / (16 * FRIEZE_SS) ** 2) + 40):
            cx, cy = rng.integers(0, w), rng.integers(0, h)
            r = int(rng.integers(3, 11) * FRIEZE_SS)
            d.ellipse([cx - r, cy - r, cx + r, cy + r],
                      fill=(shade_alt if rng.random() < 0.45 else shade)(
                          rng.uniform(0.7, 1.3)) + (255,))

    # No ink and no volume ramp: a tiling surface has no silhouette to outline, and
    # a vertical ramp would show up as banding every time the tile repeats.
    img = _saturate(img, 1.24)
    img = _hue_noise(img, strength=0.07, seed=seed + 21)
    img = _brush(img, strength=0.16, seed=seed + 11)
    img = _seamless_both(img, fade_points=size_points[0] * grow * fade_fraction,
                         density=FRIEZE_SS)
    # Resolve to the size that was *asked for*, which the growth above makes the
    # size that survived the fold.
    return _resolve(img, size_points[0], size_points[1], density)


# ─── richness ────────────────────────────────────────────────────────────────
#
# Why these exist. The first version of the prop and terrain painters shaded every
# shape by multiplying one base colour by a brightness factor. That is the classic
# mistake: the measured hue spread across a whole asset was 0.004, i.e. every pixel
# was the same colour at a different lightness, which the eye reads as muddy no
# matter how good the shapes are.
#
# Painted art does four things these functions add:
#   • shifts *hue* with light — shadows cool and blue, lights warm and yellow
#   • gives each shape internal volume, not a flat fill
#   • catches a bright rim on the lit edge
#   • carries an ink outline, which is the Rayman/UbiArt signature and is what lets
#     a shape read against a busy backdrop at all

WARM = np.array([1.14, 1.04, 0.84], np.float32)     # sunlight
COOL = np.array([0.82, 0.92, 1.20], np.float32)     # sky bounce in shadow


def _vivid(rgb, saturation=1.6, value=1.14):
    """Push a base colour toward the saturation cartoon art actually uses.

    The shading pass fixed *how* colour varies; this fixes *what* colour it varies
    around. Hand-picked palettes drift muted — `(70, 92, 58)` is an olive, and no
    amount of good shading makes an olive look like Rayman foliage. Working in HSV
    and multiplying S is the direct fix, and doing it here rather than by editing
    six themes by hand keeps one knob for the whole look.
    """
    r, g, b = (max(0.0, min(1.0, c / 255)) for c in rgb[:3])
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    s = max(0.0, min(1.0, s * saturation))
    v = max(0.0, min(1.0, v * value))
    return tuple(int(round(c * 255)) for c in colorsys.hsv_to_rgb(h, s, v))


def _hue_rotate(rgb, degrees):
    """Shift a colour's hue, for the *second* tone every rich asset carries.

    One hue plus light and shade is still one colour. A leaf whose tips run lime
    while its base stays deep green reads as painted; the same leaf in one hue
    reads as printed.
    """
    r, g, b = (max(0.0, min(1.0, c / 255)) for c in rgb[:3])
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    h = (h + degrees / 360.0) % 1.0
    return tuple(int(round(c * 255)) for c in colorsys.hsv_to_rgb(h, s, v))


def _hue_shade(base, f):
    """Brightness *and* hue. `f` > 1 warms toward light, < 1 cools into shadow.

    This one function is most of the difference between "muddy" and "painted".
    """
    c = np.asarray(base, np.float32)
    if f >= 1:
        tint = 1 + (WARM - 1) * min(1.0, (f - 1) * 2.2)
    else:
        tint = 1 + (COOL - 1) * min(1.0, (1 - f) * 2.2)
    return tuple(int(max(0, min(255, v))) for v in c * f * tint)


def _volume(img, strength=0.34, top=1.16):
    """A vertical light ramp across the opaque region: sky above, occlusion below.

    Flat fills are why a leaf looks like a sticker. This is the cheapest thing that
    turns a silhouette into a form.
    """
    a = np.asarray(img).astype(np.float32)
    h = a.shape[0]
    ramp = np.linspace(top, top - strength - (top - 1), h, dtype=np.float32)
    a[..., :3] *= ramp[:, None, None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def _rim(img, colour, dx=-2, dy=-2, strength=0.85):
    """A bright edge where the light hits.

    Computed as the alpha mask minus itself shifted away from the light, so it
    follows the silhouette exactly rather than being painted by hand per shape.
    """
    alpha = np.asarray(img.split()[3]).astype(np.float32)
    shifted = np.roll(np.roll(alpha, dy, axis=0), dx, axis=1)
    edge = np.clip(alpha - shifted, 0, 255) / 255.0
    if edge.max() <= 0:
        return img
    a = np.asarray(img).astype(np.float32)
    tint = np.asarray(colour, np.float32)
    weight = (edge * strength)[..., None]
    a[..., :3] = a[..., :3] * (1 - weight) + tint * weight
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def _ink(img, width, base, darkness=0.30):
    """An outline behind the art, in a dark *tinted* version of the base colour.

    Tinted rather than black: pure black outlines flatten a palette, which is why
    hand-painted 2D uses a deep version of the local colour instead.
    """
    width = max(1, int(width))
    alpha = img.split()[3]
    grown = alpha.filter(ImageFilter.MaxFilter(width * 2 + 1))
    ink_rgb = tuple(int(max(0, min(255, c * darkness))) for c in base)
    outline = Image.new("RGBA", img.size, ink_rgb + (0,))
    outline.putalpha(grown)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.alpha_composite(outline)
    out.alpha_composite(img)
    return out


def _saturate(img, k=1.28):
    """Push saturation about the Rec.709 luma, so greens don't go grey."""
    a = np.asarray(img).astype(np.float32)
    rgb = a[..., :3]
    luma = (rgb * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(-1, keepdims=True)
    a[..., :3] = np.clip(luma + (rgb - luma) * k, 0, 255)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def _hue_noise(img, strength=0.05, seed=0):
    """Per-pixel *hue* jitter at a coarse scale.

    `_brush` already varies value; varying the channels independently is what makes
    a large flat area look mixed rather than printed.
    """
    a = np.asarray(img).astype(np.float32)
    h, w = a.shape[:2]
    rng = np.random.default_rng(seed)
    cells = max(4, min(24, w // 24))
    small = rng.normal(0, 1, (cells, cells, 3)).astype(np.float32)
    field = np.asarray(Image.fromarray(
        np.clip(small * 40 + 128, 0, 255).astype(np.uint8), "RGB")
        .resize((w, h), Image.BICUBIC), np.float32)
    a[..., :3] *= 1 + (field - 128) / 128 * strength
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def _enrich(img, base, ink_width=0, rim_colour=None, saturation=1.26,
            volume=0.34, noise=0.05, seed=0):
    """The full pass, in the order that matters.

    Volume before rim (the rim must sit on top of the shading), saturation before
    the ink (or the outline gets pushed too), noise last on the colour but still
    inside the outline.
    """
    out = _volume(img, strength=volume)
    if rim_colour is not None:
        out = _rim(out, rim_colour)
    out = _saturate(out, saturation)
    out = _hue_noise(out, strength=noise, seed=seed)
    if ink_width > 0:
        out = _ink(out, ink_width, base)
    return out


def paint_prop(kind, colour, size_points, seed=0, density=ASSET_DENSITY):
    """One backdrop prop on transparent background — a trunk, rock, bush or fern.

    Props exist because one full-width image per plane is what makes a procedural
    backdrop look like wallpaper: everything at a given distance is the same picture
    repeating. A scatter of a small asset at jittered positions and scales reads as
    a forest instead.
    """
    if not HAVE_RASTER:
        return None
    w = max(8, int(size_points[0] * FRIEZE_SS))
    h = max(8, int(size_points[1] * FRIEZE_SS))
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(seed)
    # Vivid first, then shade. Shading a muted colour well still gives a muted
    # asset; this is the knob that decides whether the set reads as colourful.
    colour = _vivid(colour)
    base = np.array(colour, np.float32)
    # The second tone. Rotating *toward* yellow-green for foliage and toward
    # magenta for rock is what stops a scatter reading as one flat hue.
    alt = np.array(_hue_rotate(colour, -26 if kind in ("bush", "fern", "palm")
                               else 14), np.float32)

    def shade(f):
        return _hue_shade(base, f)

    def shade_alt(f):
        """The second hue at the same light level — for tips, facets and caps."""
        return _hue_shade(alt, f)

    if kind == "trunk":
        # Slight lean and a swell, so a scatter of them doesn't read as fence posts.
        lean = _wobble(h, w * 0.16, seed, smooth=40)
        half = w * 0.30
        left = [(w / 2 - half * (1 + 0.12 * math.sin(y / (h * 0.3))) + lean[y], y)
                for y in range(0, h, 4)]
        right = [(w / 2 + half * (1 + 0.12 * math.sin(y / (h * 0.3))) + lean[y], y)
                 for y in range(h - 1, 0, -4)]
        d.polygon(left + right, fill=shade(0.85) + (255,))
        # Lit side stripe in the second hue: the cheapest thing that makes a
        # silhouette read as round *and* as more than one colour.
        d.line([(w / 2 - half * 0.45 + lean[y], y) for y in range(0, h, 4)],
               fill=shade_alt(1.30) + (215,), width=max(2, int(w * 0.10)))
        for y in range(int(h * 0.12), h, max(8, int(h * 0.22))):
            d.arc([w / 2 - half + lean[min(y, h - 1)], y - half * 0.3,
                   w / 2 + half + lean[min(y, h - 1)], y + half * 0.3],
                  start=15, end=165, fill=shade(0.62) + (170,),
                  width=max(2, FRIEZE_SS))
    elif kind == "rock":
        # A boulder is faceted, not a filled hexagon. One silhouette plus a lit top
        # plane, a shadowed base and three or four interior facets — which is the
        # difference between reading as stone and reading as a shape.
        pts = []
        sides = int(rng.integers(6, 9))
        for i in range(sides):
            a = 2 * math.pi * i / sides
            r = 0.5 * min(w, h) * rng.uniform(0.72, 1.0)
            pts.append((w / 2 + math.cos(a) * r, h * 0.62 + math.sin(a) * r * 0.8))
        d.polygon(pts, fill=shade(0.72) + (255,))
        centre = (w / 2, h * 0.62)
        # Interior facets: wedges from the centre to pairs of silhouette points,
        # each at its own light level so the form turns.
        for i in range(len(pts)):
            wedge = [centre, pts[i], pts[(i + 1) % len(pts)]]
            lit = 1.0 - (pts[i][1] / max(h, 1))          # higher = more light
            tone = shade_alt if i % 2 else shade
            d.polygon(wedge, fill=tone(0.62 + lit * 0.86) + (255,))
        # The top plane, brightest and in the second hue.
        top = [q for q in pts if q[1] < h * 0.52]
        if len(top) >= 2:
            d.polygon(top + [centre], fill=shade_alt(1.42) + (255,))
        # Contact shadow where it meets the ground.
        d.polygon([q for q in pts if q[1] > h * 0.72] + [centre],
                  fill=shade(0.52) + (190,))
    elif kind in ("bush", "fern"):
        blades = 14 if kind == "fern" else 9
        for i in range(blades):
            a = math.pi * (0.15 + 0.7 * i / max(1, blades - 1))
            length = h * rng.uniform(0.55, 0.98)
            # Alternate the two hues across the fan, brighter toward the outside:
            # a fern is not one green.
            tone = shade_alt if i % 2 else shade
            _blade(d, w / 2, h - 1, length, w * 0.10,
                   math.degrees(a), tone(rng.uniform(0.86, 1.34)) + (255,))
        if kind == "bush":
            # Lobes lit by height rather than at random: a bush is a mass with a
            # top, and randomising the value flattens it into confetti.
            for _ in range(7):
                cx = w / 2 + rng.uniform(-0.32, 0.32) * w
                cy = h * rng.uniform(0.32, 0.82)
                r = min(w, h) * rng.uniform(0.16, 0.32)
                lit = 1.0 - cy / max(h, 1)
                tone = shade_alt if rng.random() < 0.45 else shade
                d.ellipse([cx - r, cy - r * 0.8, cx + r, cy + r * 0.8],
                          fill=tone(0.64 + lit * 0.82) + (255,))

    elif kind == "cloud":
        # Stacked lobes with a flat base — the shape that reads as cloud rather
        # than as a blob is the flat bottom.
        for _ in range(9):
            cx = w * rng.uniform(0.15, 0.85)
            cy = h * rng.uniform(0.35, 0.75)
            r = min(w, h) * rng.uniform(0.20, 0.38)
            d.ellipse([cx - r, cy - r * 0.72, cx + r, cy + r * 0.72],
                      fill=shade(rng.uniform(0.94, 1.06)) + (255,))
        d.rectangle([w * 0.12, h * 0.66, w * 0.88, h * 0.80],
                    fill=shade(0.92) + (255,))
        img = img.filter(ImageFilter.GaussianBlur(max(2, w // 60)))
    elif kind == "crystal":
        # Cave crystals: narrow prisms with a bright inner core.
        for _ in range(int(rng.integers(3, 6))):
            base_x = w * rng.uniform(0.2, 0.8)
            tip_y = h * rng.uniform(0.05, 0.35)
            half = w * rng.uniform(0.06, 0.14)
            d.polygon([(base_x - half, h - 1), (base_x, tip_y),
                       (base_x + half, h - 1)],
                      fill=shade(rng.uniform(0.8, 1.0)) + (255,))
            d.line([(base_x, h - 1), (base_x, tip_y)],
                   fill=shade_alt(1.65) + (230,), width=max(2, int(half * 0.5)))
    elif kind == "palm":
        # A leaning stem with fronds fanning from the top.
        top = (w * 0.5, h * 0.18)
        d.line([(w * 0.5 + math.sin(y / h * 1.2) * w * 0.12, y)
                for y in range(h - 1, int(top[1]), -4)],
               fill=shade(0.8) + (255,), width=max(3, int(w * 0.10)))
        for i in range(7):
            a = math.pi * (0.08 + 0.84 * i / 6)
            tone = shade_alt if i % 2 else shade
            _blade(d, top[0], top[1], h * rng.uniform(0.30, 0.46), w * 0.09,
                   math.degrees(a), tone(rng.uniform(0.9, 1.36)) + (255,))
    elif kind == "mushroom":
        cap_r = w * 0.42
        d.rectangle([w * 0.44, h * 0.45, w * 0.56, h - 1],
                    fill=shade(1.15) + (255,))
        d.ellipse([w * 0.5 - cap_r, h * 0.18, w * 0.5 + cap_r, h * 0.62],
                  fill=shade_alt(0.98) + (255,))
        for _ in range(5):
            sx = w * rng.uniform(0.22, 0.78)
            sy = h * rng.uniform(0.26, 0.48)
            sr = w * rng.uniform(0.04, 0.09)
            d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr],
                      fill=shade(1.35) + (255,))

    # Richness pass. The ink width scales with the asset so a small rock and a
    # tall palm carry outlines of the same *visual* weight.
    ink = max(2, int(min(w, h) * 0.022))
    img = _enrich(img, colour, ink_width=ink,
                  rim_colour=_hue_shade(base, 1.55),
                  saturation=1.30, volume=0.38, noise=0.06, seed=seed + 3)
    img = _brush(img, strength=0.14, seed=seed + 3)
    img = _feather_edges(img, bottom=0.06, sides=0.02)
    return _resolve(img, size_points[0], size_points[1], density)


PROP_KINDS = {
    "prop_trunk": ("trunk", (70, 92, 58), (34, 190)),
    "prop_rock":  ("rock",  (96, 104, 96), (46, 34)),
    "prop_bush":  ("bush",  (84, 128, 66), (52, 38)),
    "prop_fern":  ("fern",  (96, 142, 74), (44, 46)),
}


def build_props(out_dir, density=ASSET_DENSITY, kinds=None, prefix=""):
    """Every backdrop prop, at every scale tier."""
    if not HAVE_RASTER:
        return [], [RASTER_HINT]
    os.makedirs(out_dir, exist_ok=True)
    written = []
    table = kinds if kinds is not None else PROP_KINDS
    for index, (name, (kind, colour, size)) in enumerate(sorted(table.items())):
        name = prefix + name
        img = paint_prop(kind, colour, size, seed=index * 53 + 9, density=density)
        if img is None:
            continue
        points = (img.width / density, img.height / density)
        for scale in (2, 3):
            multiple = density / NOMINAL_DENSITY
            out = (max(1, int(round(points[0] * scale * multiple))),
                   max(1, int(round(points[1] * scale * multiple))))
            path = os.path.join(out_dir, f"{name}@{scale}x.png")
            (img if out == img.size else img.resize(out, Image.LANCZOS)).save(path)
            written.append(path)
    return written, []


TERRAIN_KINDS = {
    "cliff":  ("rock",  (86, 104, 74)),
    "soil":   ("soil",  (92, 70, 52)),
    "grass":  ("grass", (108, 158, 74)),
    "trunk":  ("bark",  (78, 62, 46)),
    "stone":  ("rock",  (108, 112, 118)),
}


def build_terrain(out_dir, density=ASSET_DENSITY, kinds=None, prefix=""):
    """Every terrain texture, at every scale tier."""
    if not HAVE_RASTER:
        return [], [RASTER_HINT]
    os.makedirs(out_dir, exist_ok=True)
    written = []
    table = kinds if kinds is not None else TERRAIN_KINDS
    for index, (name, (kind, colour)) in enumerate(sorted(table.items())):
        name = prefix + name
        img = paint_terrain(kind, colour, seed=index * 37 + 5, density=density)
        if img is None:
            continue
        points = (img.width / density, img.height / density)
        for scale in (2, 3):
            multiple = density / NOMINAL_DENSITY
            out = (max(1, int(round(points[0] * scale * multiple))),
                   max(1, int(round(points[1] * scale * multiple))))
            path = os.path.join(out_dir, f"{name}@{scale}x.png")
            (img if out == img.size else img.resize(out, Image.LANCZOS)).save(path)
            written.append(path)
    return written, []


MASK64 = (1 << 64) - 1
LCG_MUL = 6_364_136_223_846_793_005
LCG_ADD = 1_442_695_040_888_963_407


def scatter_positions(prop):
    """Where a prop's instances go — the same arithmetic `FriezeStage.scatter` runs.

    This has to be identical, not merely similar: the preview is what an author
    approves, and a scatter that lands differently in the game means the composite
    they signed off is not the picture that ships. Hence an explicit LCG with
    64-bit masking on both sides rather than each language's own RNG.
    """
    count = int(prop.get("count", 0))
    if count <= 0:
        return []
    span = float(prop.get("span", 600))
    state = (int(prop.get("seed", 1)) * LCG_MUL + 1) & MASK64

    def nxt():
        nonlocal state
        state = (state * LCG_MUL + LCG_ADD) & MASK64
        return (state >> 33) / float(1 << 31)

    out = []
    for index in range(count):
        slot = (index + 0.5) / count
        jitter_x = (nxt() - 0.5) * span / count
        scale = 1 + (nxt() - 0.5) * 2 * float(prop.get("scaleJitter", 0))
        y = float(prop.get("y", 0)) + (nxt() - 0.5) * 2 * float(prop.get("yJitter", 0))
        flip = nxt() < float(prop.get("flipChance", 0.5))
        out.append({"x": slot * span + jitter_x - span / 2, "y": y,
                    "scale": scale, "flip": flip})
    return out


# ─── themes ──────────────────────────────────────────────────────────────────
#
# A theme is everything that makes a place look like itself: a palette, a sky, a
# layer stack, the surfaces its terrain is made of and the props scattered through
# it. One entry here generates a complete, coherent set of hi-res raster assets —
# which is the difference between "the engine can paint a jungle" and "the engine
# can paint jungles".
#
# Everything is emitted at `ASSET_DENSITY` (6 px per scene point) except the
# backdrop layers, which are density-per-depth because the loader blurs them. See
# the density policy at the top of this file.

THEMES = {
    "forest": {
        "sky": [[120, 150, 96], [250, 226, 152], [186, 200, 120],
                [92, 132, 84], [34, 60, 50]],
        "palette": {"far": [132, 164, 100], "mid": [88, 130, 76],
                    "trunk": [70, 96, 58], "near": [30, 46, 32],
                    "accent": [255, 234, 162]},
        "focus": 0.62, "haze": 0.38, "grade": "grove",
        "rays": True, "fireflies": True,
        "terrain": {"cliff": ("rock", (86, 104, 74)),
                    "soil": ("soil", (92, 70, 52)),
                    "grass": ("grass", (108, 158, 74))},
        "props": {"trunk": ("trunk", (70, 92, 58), (34, 190)),
                  "rock": ("rock", (96, 104, 96), (46, 34)),
                  "bush": ("bush", (84, 128, 66), (52, 38)),
                  "fern": ("fern", (96, 142, 74), (44, 46))},
    },
    "jungle": {
        # Denser, wetter, darker than forest: less sky, more canopy, teal shadows.
        "sky": [[86, 128, 92], [188, 214, 150], [120, 168, 118],
                [46, 92, 78], [18, 44, 40]],
        "palette": {"far": [110, 158, 116], "mid": [64, 122, 84],
                    "trunk": [52, 84, 56], "near": [18, 38, 28],
                    "accent": [226, 248, 176]},
        "focus": 0.58, "haze": 0.46, "grade": "hollow",
        "rays": True, "fireflies": True,
        "terrain": {"cliff": ("rock", (66, 92, 72)),
                    "soil": ("soil", (74, 58, 44)),
                    "moss": ("moss", (72, 122, 68))},
        "props": {"trunk": ("trunk", (54, 82, 54), (40, 210)),
                  "palm": ("palm", (74, 124, 70), (78, 150)),
                  "fern": ("fern", (84, 138, 78), (52, 54)),
                  "mushroom": ("mushroom", (176, 96, 84), (38, 40))},
    },
    "ridge": {
        # High altitude: cold rock, thin air, a lot of sky.
        "sky": [[186, 206, 220], [232, 240, 248], [156, 188, 218],
                [86, 132, 182], [40, 74, 128]],
        "palette": {"far": [166, 182, 198], "mid": [122, 138, 156],
                    "trunk": [96, 104, 116], "near": [48, 56, 68],
                    "accent": [255, 246, 226]},
        "focus": 0.6, "haze": 0.55, "grade": "neutral",
        "rays": False, "fireflies": False,
        "terrain": {"cliff": ("rock", (128, 136, 148)),
                    "ice": ("ice", (196, 216, 230)),
                    "soil": ("soil", (84, 78, 72))},
        "props": {"rock": ("rock", (118, 126, 138), (58, 42)),
                  "crystal": ("crystal", (168, 206, 226), (44, 66)),
                  "trunk": ("trunk", (96, 92, 84), (30, 150)),
                  "bush": ("bush", (104, 122, 96), (46, 32))},
    },
    "sky": {
        # Above the clouds: no terrain to speak of, everything is air and light.
        "sky": [[248, 226, 186], [255, 244, 216], [196, 224, 246],
                [128, 182, 232], [62, 122, 196]],
        "palette": {"far": [236, 244, 252], "mid": [198, 220, 240],
                    "trunk": [166, 190, 214], "near": [120, 152, 186],
                    "accent": [255, 250, 226]},
        "focus": 0.5, "haze": 0.6, "grade": "grove",
        "rays": True, "fireflies": False,
        "terrain": {"cliff": ("rock", (176, 190, 206)),
                    "grass": ("grass", (150, 196, 150))},
        "props": {"cloud": ("cloud", (250, 250, 252), (140, 70)),
                  "rock": ("rock", (176, 188, 202), (54, 38)),
                  "bush": ("bush", (150, 190, 150), (48, 34))},
    },
    "cave": {
        # Underground: the only light is what you bring, so the accent is the sky.
        "sky": [[34, 30, 44], [58, 48, 70], [40, 34, 52],
                [22, 20, 32], [12, 12, 20]],
        "palette": {"far": [72, 64, 90], "mid": [56, 50, 72],
                    "trunk": [44, 40, 58], "near": [20, 18, 28],
                    "accent": [148, 208, 232]},
        "focus": 0.56, "haze": 0.3, "grade": "arena",
        "rays": False, "fireflies": True,
        "terrain": {"cliff": ("rock", (68, 62, 84)),
                    "basalt": ("rock", (44, 40, 54)),
                    "moss": ("moss", (56, 88, 74))},
        "props": {"crystal": ("crystal", (128, 196, 224), (46, 78)),
                  "rock": ("rock", (66, 60, 80), (56, 40)),
                  "mushroom": ("mushroom", (128, 176, 196), (40, 42))},
    },
    "shore": {
        # Warm, open, low contrast: sand, palms, a bright horizon.
        "sky": [[252, 232, 196], [255, 246, 222], [214, 234, 246],
                [148, 200, 232], [86, 156, 204]],
        "palette": {"far": [216, 216, 186], "mid": [186, 190, 150],
                    "trunk": [138, 122, 92], "near": [86, 84, 62],
                    "accent": [255, 244, 200]},
        "focus": 0.6, "haze": 0.42, "grade": "grove",
        "rays": True, "fireflies": False,
        "terrain": {"sand": ("sand", (224, 206, 164)),
                    "cliff": ("rock", (170, 156, 130)),
                    "grass": ("grass", (156, 178, 116))},
        "props": {"palm": ("palm", (110, 148, 90), (86, 168)),
                  "rock": ("rock", (166, 154, 132), (54, 38)),
                  "bush": ("bush", (150, 176, 112), (50, 36))},
    },
}

# The layer stack every theme uses. Depths and heights are shared because they
# encode *composition* — how a 2D scene reads as deep — which does not change
# between a forest and a cave. Only the palette and the props do.
THEME_LAYERS = [
    {"kind": "glow",   "depth": 0.05, "color": "accent", "y": -10,  "height": 390},
    {"kind": "ridge",  "depth": 0.18, "color": "far",    "y": -168, "height": 400},
    {"kind": "canopy", "depth": 0.30, "color": "far",    "y": 152,  "height": 250},
    {"kind": "fog",    "depth": 0.40, "color": "accent", "y": -120, "height": 150},
    {"kind": "trunks", "depth": 0.52, "color": "trunk",  "y": 0,    "height": 430},
    {"kind": "canopy", "depth": 0.62, "color": "mid",    "y": 170,  "height": 220},
    {"kind": "vines",  "depth": 0.88, "color": "near",   "y": 115,  "height": 300},
]


def theme_spec(name):
    """A theme → a `frieze-spec/1`, with props and spline geometry wired in."""
    theme = THEMES[name]
    layers = []
    for layer in THEME_LAYERS:
        entry = dict(layer)
        if layer["kind"] == "trunks":
            # Every tall kind the theme declares, not just the first — an unused
            # prop is a generated asset nothing draws, which the audit reports as an
            # orphan and which is simply wasted work.
            tall = [k for k in ("trunk", "palm", "cloud", "crystal")
                    if k in theme["props"]]
            entry["props"] = [
                {"image": f"prop_{name}_{k}",
                 "count": max(3, 7 - index * 3), "span": 680,
                 "y": -60 - index * 18, "yJitter": 26,
                 "scale": 1.0 - index * 0.12, "scaleJitter": 0.28,
                 "flipChance": 0.5, "seed": 4177 + index * 1531,
                 "density": ASSET_DENSITY}
                for index, k in enumerate(tall)]
            if "rock" in theme["props"]:
                entry["props"].append(
                    {"image": f"prop_{name}_rock", "count": 6, "span": 680,
                     "y": -132, "yJitter": 10, "scale": 0.9, "scaleJitter": 0.34,
                     "flipChance": 0.5, "seed": 8021, "density": ASSET_DENSITY})
            # A second, softer skyline behind the trunks: painted spline geometry,
            # which is what a UbiArt backdrop is made of.
            entry["frises"] = [{"points": [[-80, 60], [200, 118], [430, 76],
                                           [660, 126], [860, 70]],
                                "thickness": 110, "capHeight": 0,
                                "color": theme["palette"]["far"]}]
        if layer["kind"] == "canopy" and layer["depth"] > 0.5:
            near = [k for k in ("fern", "bush", "mushroom", "crystal", "cloud")
                    if k in theme["props"]]
            entry["props"] = [
                {"image": f"prop_{name}_{k}", "count": 9 - i * 2, "span": 460,
                 "y": -80 - i * 40, "yJitter": 18, "scale": 1.1 - i * 0.1,
                 "scaleJitter": 0.3, "flipChance": 0.5, "seed": 991 + i * 2316,
                 "density": ASSET_DENSITY}
                for i, k in enumerate(near[:2])]
        layers.append(entry)
    return {
        "format": "frieze-spec/1", "name": f"{name}_backdrop",
        "sky": theme["sky"], "palette": theme["palette"],
        "focus": theme["focus"], "haze": theme["haze"],
        "dofPointsPerDepth": 5, "vignette": 0.3, "texture": 0.26,
        "rays": theme["rays"], "fireflies": theme["fireflies"],
        "layers": layers,
    }


def build_theme(name, friezes_dir, terrain_dir, preview=True):
    """One theme's complete asset set: props, terrain surfaces and a backdrop.

    Returns `(written, problems, notes)` like the other builders.
    """
    if name not in THEMES:
        return [], [f"unknown theme '{name}' (have {', '.join(sorted(THEMES))})"], []
    theme = THEMES[name]
    written, problems, notes = [], [], []

    props = {f"prop_{name}_{k}": v for k, v in theme["props"].items()}
    made, bad = build_props(friezes_dir, kinds=props)
    written += made
    problems += bad

    surfaces = {f"tex_{name}_{k}": v for k, v in theme["terrain"].items()}
    made, bad = build_terrain(terrain_dir, kinds=surfaces)
    written += made
    problems += bad

    spec = theme_spec(name)
    made, bad, extra = build_frieze(spec, friezes_dir, preview=preview)
    written += made
    problems += bad
    notes += extra
    # The spec is the reproducible input, kept next to what it produced.
    spec_path = os.path.join(friezes_dir, f"{name}_backdrop.spec.json")
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=1)
        f.write("\n")
    written.append(spec_path)
    return written, problems, notes


def build_frieze(spec, out_dir, preview=True):
    """Frieze spec → layer PNGs + the FriezeScene JSON `FriezeStage` loads."""
    problems = validate_frieze_spec(spec)
    if problems:
        return [], problems, []
    if not HAVE_RASTER:
        return [], [], [RASTER_HINT]

    name = spec["name"]
    palette = spec["palette"]
    os.makedirs(out_dir, exist_ok=True)
    written, layers, painted = [], [], []

    sky_mid = np.array(spec["sky"][len(spec["sky"]) // 2][:3], np.float32)
    accent = np.array(_rgb(palette, "accent", (255, 246, 190)), np.float32)

    def tone(rgb, depth):
        """Push a sampled colour onto a value ramp by depth.

        Sampling a reference gives you *hues* that agree; it does not give you a
        value hierarchy, and without one every layer sits at the same lightness
        and the picture reads flat no matter how good the shapes are. Far layers
        lift toward the sky (aerial perspective), near layers crush toward
        silhouette — which is exactly what the reference frames do.
        """
        c = np.array(rgb, np.float32)
        if depth < 0.5:                      # distance washes out and lightens
            f = (0.5 - depth) / 0.5
            c = c + (sky_mid * 0.75 + accent * 0.25 - c) * (0.55 * f)
        else:                                # foreground goes toward silhouette
            f = (depth - 0.5) / 0.5
            c = c * (1.0 - 0.62 * f)
        return [int(max(0, min(255, v))) for v in c]

    for i, layer in enumerate(spec["layers"]):
        depth = float(layer["depth"])
        colour = tone(_rgb(palette, layer["color"], (90, 150, 70)), depth)
        height = float(layer.get("height", 260))
        tiles = layer["kind"] in TILES
        if layer.get("width"):
            width = float(layer["width"])
        elif tiles:
            width = float(TILE_WIDTH.get(layer["kind"], FRIEZE_WIDTH))
        else:
            # A non-tiled layer must cover the screen plus its own parallax travel,
            # or its edge walks into frame. Computing that from `focus` and `depth`
            # rather than hardcoding a width is what stops a theme with a nearer
            # focus plane silently shipping a too-narrow layer — which is exactly
            # what the `sky` theme did with the glow.
            focus_value = max(float(spec.get("focus", 0.55)), 0.001)
            travel = max(0.0, LEVEL_TILES * 40.0 - 844.0)
            rate = depth / focus_value
            width = max(float(TILE_WIDTH.get(layer["kind"], FRIEZE_WIDTH)),
                        844.0 + 2 * travel * rate + 24.0)
        density = layer_density(depth, spec.get("focus", 0.55),
                                spec.get("dofPointsPerDepth", 5))
        img = paint_frieze_layer(layer["kind"], colour, width, height,
                                 spec, seed=i * 101 + 7, depth=depth,
                                 density=density)
        if tiles:
            img = _seamless(img, fade_points=width * 0.12, density=density)
        points = (img.width / density, img.height / density)
        image_name = f"{name}_{layer['kind']}{i}"
        for scale in (2, 3):
            path = os.path.join(out_dir, f"{image_name}@{scale}x.png")
            multiple = density / NOMINAL_DENSITY
            out = (max(1, int(round(points[0] * scale * multiple))),
                   max(1, int(round(points[1] * scale * multiple))))
            # @3x lands on the painted resolution exactly, so it is a copy, not
            # a resample; @2x is a clean downsample.
            (img if out == img.size else img.resize(out, Image.LANCZOS)).save(path)
            written.append(path)
        # Props and spline geometry ride along on the same plane, so they inherit
        # its depth, parallax rate, haze and depth-of-field automatically.
        extras = {}
        if layer.get("props"):
            extras["props"] = layer["props"]
        if layer.get("frises"):
            extras["frises"] = layer["frises"]
        for key in ("wind", "windPinTop"):
            if key in layer:
                extras[key] = layer[key]
        entry = {"image": image_name, "x": 0.0,
                 "y": float(layer.get("y", 0)), "depth": depth,
                 # repeat across the level instead of shipping one level-wide
                 # texture; `_seamless` made the wrap invisible
                 "tile": tiles,
                 # tell the loader the art is denser than its suffix implies, or
                 # it would read the extra pixels as extra points and lay the
                 # backdrop out too big
                 "density": density}
        entry.update(extras)
        layers.append(entry)
        painted.append((entry, img))

    scene = {
        "focus": float(spec.get("focus", 0.55)),
        "haze": float(spec.get("haze", 0.45)),
        "dofPointsPerDepth": float(spec.get("dofPointsPerDepth", 5)),
        "sky": [[int(c) for c in stop[:3]] for stop in spec["sky"]],
        "layers": sorted(layers, key=lambda l: l["depth"]),
        "vignette": float(spec.get("vignette", 0.3)),
    }
    if spec.get("rays"):
        accent = _rgb(palette, "accent", (255, 240, 190))
        scene["rays"] = {"x": -120, "y": 210, "angles": [-16, -8, 4, 12],
                         "color": list(accent), "alpha": 0.16, "width": 46}
    if spec.get("fireflies"):
        accent = _rgb(palette, "accent", (255, 240, 190))
        scene["fireflies"] = {"count": 26, "color": list(accent)}

    scene_path = os.path.join(out_dir, f"{name}.json")
    with open(scene_path, "w") as f:
        json.dump(scene, f, indent=1)
    written.append(scene_path)

    if preview:
        written.append(write_frieze_preview(name, scene, painted, spec, out_dir))
    return written, [], []


def _plane_extras_canvas(entry, out_dir, frame_size):
    """A frame-sized RGBA canvas holding this plane's props and spline geometry.

    Frame-sized rather than layer-sized because that is what the runtime does: a
    prop scatter and a frise are their own nodes on the plane, so they are not
    bounded by whatever the plane's image happens to measure. Getting this wrong
    silently clips every prop that falls outside the image — which is most of them
    when a scatter spans wider than the picture.
    """
    props = entry.get("props") or []
    frises = entry.get("frises") or []
    if not props and not frises:
        return None
    W, H = frame_size
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)

    for spec_f in frises:
        outline = _frise_outline_points(spec_f)
        if len(outline) < 3:
            continue
        colour = tuple((spec_f.get("color") or [90, 130, 76])[:3])
        # Frise points are in scene space (y up, origin left); the canvas is y down
        # and centred on the camera, matching how `FriseNode` sits on its plane.
        d.polygon([(x - W / 2 + W / 2, H - y) for x, y in outline],
                  fill=colour + (255,))

    for prop in props:
        # Prop art usually already lives in the bundle folder, not in whatever
        # directory this build is writing to — so search both. Silently skipping a
        # prop whose art is one directory over is the kind of miss that makes a
        # preview quietly disagree with the game.
        art_path, art_scale = None, 3
        search = [out_dir, os.path.join(HERE, "..", "Assets", "Friezes"),
                  os.path.join(HERE, "..", "Assets", "Terrain")]
        for directory in search:
            for scale in (3, 2):
                candidate = os.path.join(directory, f"{prop['image']}@{scale}x.png")
                if os.path.isfile(candidate):
                    art_path, art_scale = candidate, scale
                    break
            if art_path:
                break
        if not art_path:
            print(f"note: prop art '{prop['image']}' not found in "
                  f"{[os.path.normpath(s) for s in search]}", file=sys.stderr)
        if not art_path:
            continue
        with Image.open(art_path) as src:
            src = src.convert("RGBA")
            prop_density = float(prop.get("density", BACKDROP_DENSITY))
            base_w = src.width / art_scale / (prop_density / NOMINAL_DENSITY)
            base_h = src.height / art_scale / (prop_density / NOMINAL_DENSITY)
            base_scale = float(prop.get("scale", 1))
            for place in scatter_positions(prop):
                w = max(1, int(base_w * place["scale"] * base_scale))
                h = max(1, int(base_h * place["scale"] * base_scale))
                sprite = src.resize((w, h), Image.LANCZOS)
                if place["flip"]:
                    sprite = sprite.transpose(Image.FLIP_LEFT_RIGHT)
                x = int(W / 2 + place["x"] - w / 2)
                y = int(H / 2 - place["y"] - h / 2)
                canvas.alpha_composite(sprite, (x, y))
    return canvas


def _frise_outline_points(spec):
    """Catmull-Rom sample + normal offset — the mirror of `Frise.outline`."""
    control = [(p[0], p[1]) for p in spec.get("points", []) if len(p) >= 2]
    if len(control) < 2:
        return []
    closed = bool(spec.get("closed"))
    steps = max(2, min(64, int(spec.get("resolution", 12))))
    curve = []
    count = len(control)
    last = count - 1 if closed else count - 2
    for index in range(max(0, last) + 1):
        if closed:
            p0, p1 = control[(index - 1) % count], control[index % count]
            p2, p3 = control[(index + 1) % count], control[(index + 2) % count]
        else:
            p0, p1 = control[max(0, index - 1)], control[index]
            p2 = control[min(count - 1, index + 1)]
            p3 = control[min(count - 1, index + 2)]
        for step in range(steps):
            tt = step / steps
            t2, t3 = tt * tt, tt * tt * tt

            def axis(a, b, c, e):
                return 0.5 * ((2 * b) + (-a + c) * tt
                              + (2 * a - 5 * b + 4 * c - e) * t2
                              + (-a + 3 * b - 3 * c + e) * t3)
            curve.append((axis(p0[0], p1[0], p2[0], p3[0]),
                          axis(p0[1], p1[1], p2[1], p3[1])))
    if not closed:
        curve.append(control[-1])
    thickness = float(spec.get("thickness", 80))
    inner = []
    n = len(curve)
    for i in range(n):
        prev = curve[(i - 1) % n] if closed else curve[max(0, i - 1)]
        nxt = curve[(i + 1) % n] if closed else curve[min(n - 1, i + 1)]
        dx, dy = nxt[0] - prev[0], nxt[1] - prev[1]
        length = max(math.hypot(dx, dy), 1e-4)
        nx, ny = -dy / length, dx / length
        inner.append((curve[i][0] - nx * thickness, curve[i][1] - ny * thickness))
    return curve if closed else curve + inner[::-1]


def write_frieze_preview(name, scene, painted, spec, out_dir):
    """Composite the scene exactly as `FriezeStage` + `FriezeBaker` would.

    Same sky gradient, the same per-layer haze wash toward the sky colour and
    depth-of-field blur by distance from `focus`, the same z-order, rays and
    vignette. Without this you are judging loose layers rather than the picture
    the player sees — and the picture is the thing being asked for.
    """
    W, H = 844, 390
    sky_stops = scene["sky"]
    grad = np.zeros((H, W, 3), dtype=np.float32)
    for y in range(H):
        f = 1 - y / max(H - 1, 1)                      # 0 at top … 1 at bottom
        pos = f * (len(sky_stops) - 1)
        i = int(min(pos, len(sky_stops) - 2))
        t = pos - i
        a = np.array(sky_stops[i], np.float32)
        b = np.array(sky_stops[i + 1], np.float32)
        grad[y, :] = a + (b - a) * t
    frame = Image.fromarray(grad.astype(np.uint8), "RGB").convert("RGBA")

    haze_rgb = np.array(sky_stops[len(sky_stops) // 2], np.float32)
    focus = scene["focus"]
    for entry, img in sorted(painted, key=lambda p: p[0]["depth"]):
        depth = entry["depth"]
        # Painted pixels → scene points. Without this the preview is a zoomed
        # crop of the middle of each layer, which flatters the art: it shows
        # detail at 4× the size the player will ever see it.
        d_layer = float(entry.get("density", BACKDROP_DENSITY))
        layer = img.resize((max(1, round(img.width / d_layer)),
                            max(1, round(img.height / d_layer))), Image.LANCZOS)
        # haze: wash toward the sky colour, strongest at depth 0 (FriezeBaker)
        strength = scene["haze"] * max(0.0, 1.0 - depth / max(focus, 0.001)) * 0.9
        if strength > 0.01:
            a = np.asarray(layer, np.float32)
            a[..., :3] += (haze_rgb - a[..., :3]) * strength
            layer = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")
        # depth of field by distance from the gameplane
        blur = abs(depth - focus) * scene["dofPointsPerDepth"]
        if blur > 0.4:
            layer = layer.filter(ImageFilter.GaussianBlur(blur))
        # Repeat exactly as `FriezeStage` wraps a tiled plane, so a seam in the
        # wrap shows up here rather than on a device.
        if entry.get("tile") and layer.width < W * 2:
            repeats = W * 2 // layer.width + 1
            strip = Image.new("RGBA", (layer.width * repeats, layer.height), (0, 0, 0, 0))
            for k in range(repeats):
                strip.alpha_composite(layer, (k * layer.width, 0))
            layer = strip
        y = int(H / 2 - entry["y"] - layer.size[1] / 2)
        frame.alpha_composite(layer, (int(-(layer.size[0] - W) / 2), y))

        # Props and spline geometry are their *own* plane at this depth — the
        # runtime builds them as separate nodes, not baked into the layer image, and
        # compositing them into it here would clip them to the image's bounds.
        # Same haze and blur, applied to a frame-sized canvas.
        extras = _plane_extras_canvas(entry, out_dir, (W, H))
        if extras is not None:
            if strength > 0.01:
                a = np.asarray(extras, np.float32)
                a[..., :3] += (haze_rgb - a[..., :3]) * strength
                extras = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")
            if blur > 0.4:
                extras = extras.filter(ImageFilter.GaussianBlur(blur))
            frame.alpha_composite(extras, (0, 0))

    if scene.get("rays"):
        rays = scene["rays"]
        shafts = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        rd = ImageDraw.Draw(shafts)
        for ang in rays["angles"]:
            x = W / 2 + rays["x"]
            dx = math.tan(math.radians(ang)) * H
            rd.polygon([(x - rays["width"] / 2, 0), (x + rays["width"] / 2, 0),
                        (x + dx + rays["width"] * 1.4, H),
                        (x + dx - rays["width"] * 1.4, H)],
                       fill=tuple(rays["color"]) + (int(255 * rays["alpha"]),))
        shafts = shafts.filter(ImageFilter.GaussianBlur(18))
        frame = Image.alpha_composite(frame, shafts)

    if scene.get("vignette", 0) > 0.01:
        ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
        nx = (xs / W - 0.5) * 2
        ny = (ys / H - 0.5) * 2
        r = np.sqrt(nx * nx + ny * ny * 1.15)
        mask = np.clip((r - 0.55) / 0.75, 0, 1) ** 1.5 * scene["vignette"]
        a = np.asarray(frame, np.float32)
        a[..., :3] *= (1 - mask)[..., None]
        frame = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")

    d = ImageDraw.Draw(frame)
    d.text((10, 8), f"{name} - as FriezeStage composites it "
                    f"(haze {scene['haze']:.2f}, focus {scene['focus']:.2f})",
           fill=(255, 255, 255, 190))
    path = os.path.join(out_dir, f"{name}_scene.png")
    frame.convert("RGB").save(path)
    return path


def validate_frieze_spec(spec):
    bad = []
    if spec.get("format") != "frieze-spec/1":
        bad.append("format must be 'frieze-spec/1'")
    name = spec.get("name", "")
    if not name or not all(c.isalnum() or c in "_-" for c in name):
        bad.append("name must be a simple identifier")
    sky = spec.get("sky") or []
    if len(sky) < 2:
        bad.append("sky needs at least two gradient stops")
    palette = spec.get("palette") or {}
    if not palette:
        bad.append("palette is required")
    layers = spec.get("layers") or []
    if not layers:
        bad.append("at least one layer is required")
    legal = set(FRIEZE_SCHEMA["properties"]["layers"]["items"]
                ["properties"]["kind"]["enum"])
    for i, layer in enumerate(layers):
        if layer.get("kind") not in legal:
            bad.append(f"layer {i}: kind must be one of {sorted(legal)}")
        depth = layer.get("depth")
        if not isinstance(depth, (int, float)) or not 0 <= depth <= 1:
            bad.append(f"layer {i}: depth must be 0…1")
        if layer.get("color") not in palette:
            bad.append(f"layer {i}: color '{layer.get('color')}' is not in the palette")
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", nargs="?", help="art-spec or frieze-spec JSON (see --schema)")
    ap.add_argument("--out", default=".", help="output directory")
    ap.add_argument("--preview", action="store_true", help="also write a contact sheet")
    ap.add_argument("--default", metavar="NAME",
                    help="write a stock Rayman-style spec under NAME and build it")
    ap.add_argument("--schema", action="store_true",
                    help="print the art-spec JSON schema and exit")
    ap.add_argument("--frieze-schema", action="store_true",
                    help="print the frieze-spec JSON schema and exit")
    ap.add_argument("--ingest", metavar="SHEET",
                    help="a painted/AI-generated character sheet → parts + rig")
    ap.add_argument("--name", help="asset prefix when ingesting")
    ap.add_argument("--grid", metavar="COLSxROWS",
                    help="slice the sheet as a grid instead of by connectivity; "
                         "cells are read left-to-right, top-to-bottom as "
                         "body, head, tuft, hand_l, hand_r, foot_l, foot_r")
    args = ap.parse_args()

    if args.schema:
        print(json.dumps(SPEC_SCHEMA, indent=2))
        return 0
    if args.frieze_schema:
        print(json.dumps(FRIEZE_SCHEMA, indent=2))
        return 0

    if args.ingest:
        name = args.name or os.path.splitext(os.path.basename(args.ingest))[0]
        name = "".join(c if c.isalnum() or c == "_" else "_" for c in name).lower()
        grid = None
        if args.grid:
            try:
                cols, rows = (int(v) for v in args.grid.lower().split("x"))
                grid = (cols, rows)
            except ValueError:
                print("--grid wants COLSxROWS, e.g. 4x2", file=sys.stderr)
                return 2
        written, problems, notes = ingest_sheet(args.ingest, name, args.out, grid=grid)
        for path in written:
            print(f"wrote {path}")
        for n in notes:
            print(f"note: {n}", file=sys.stderr)
        for p in problems:
            print("  ✗", p, file=sys.stderr)
        return 1 if problems else 0

    if args.default:
        spec = json.loads(json.dumps(DEFAULT_SPEC))
        spec["name"] = args.default
        spec_path = os.path.join(args.out, f"{args.default}.artspec.json")
        os.makedirs(args.out, exist_ok=True)
        with open(spec_path, "w") as f:
            json.dump(spec, f, indent=2)
        print(f"wrote {spec_path}")
    elif args.spec:
        with open(args.spec) as f:
            spec = json.load(f)
    else:
        ap.error("give a spec file, or --default NAME")
        return 2

    # One entry point, two spec kinds — the caller shouldn't have to know which
    # builder to invoke, only what it wants made.
    if spec.get("format") == "frieze-spec/1":
        written, problems, notes = build_frieze(spec, args.out)
    else:
        written, problems, notes = build(spec, args.out, preview=args.preview)
    if problems:
        print("spec rejected:", file=sys.stderr)
        for p in problems:
            print("  •", p, file=sys.stderr)
        return 1
    for path in written:
        print(f"wrote {path}")
    for note in notes:
        print(f"note: {note}", file=sys.stderr)
    print(f"\n{len(written)} file(s). Drop the PNGs and *_rig.json into Assets/Rigs/ "
          f"and the runtime picks them up; import the rig into Tools/RigEditor.html "
          f"to hand-tune curves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
