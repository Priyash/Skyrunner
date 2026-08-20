#!/usr/bin/env python3
"""
composer.py — a miniature UbiArt-style presentation engine.

Architecture (mirroring UbiArt's structure):
  • FRIEZES  → depth planes: any RGBA image placed at a depth 0..1
  • ACTORS   → props placed on planes (same mechanism, named assets)
  • PIPELINE → per-plane atmospheric haze + depth-of-field blur,
               volumetric light shafts, particle pass, bloom pass,
               full-frame color grade + vignette

A scene is a JSON dict. Assets come from a registry — procedural
stand-ins today; drop painted/AI PNGs into assets/ with the same names
tomorrow and the engine uses them instead. That split (art vs engine)
is exactly UbiArt's split.
"""
import json, math, os, random, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 3
OUTLINE = (46, 30, 22)


# ── shared paint helpers ────────────────────────────────────────────────

def value_noise(w, h, cells, seed=0):
    rng = np.random.default_rng(seed)
    grid = rng.random((cells + 1, cells + 1)).astype(np.float32)
    img = Image.fromarray((grid * 255).astype(np.uint8), "L").resize((w, h), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32) / 255.0

def fbm(w, h, octaves=(6, 12, 24, 48), seed=0):
    total, amp, norm = np.zeros((h, w), np.float32), 1.0, 0.0
    for i, c in enumerate(octaves):
        total += value_noise(w, h, c, seed + i) * amp
        norm += amp
        amp *= 0.55
    return total / norm

def brushify(img, strength=0.12, seed=0, scalemix=(8, 20, 44)):
    w, h = img.size
    n = fbm(w, h, scalemix, seed)
    arr = np.asarray(img).astype(np.float32)
    arr[..., :3] *= 1.0 + (n[..., None] - 0.5) * 2 * strength
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), img.mode)

def vgrad(w, h, stops):
    arr = np.zeros((h, w, 4), np.float32)
    n = len(stops) - 1
    for row, t in enumerate(np.linspace(0, 1, h)):
        seg = min(int(t * n), n - 1)
        f = t * n - seg
        c0, c1 = np.array(stops[seg], np.float32), np.array(stops[seg + 1], np.float32)
        arr[row, :, :3] = c0 + (c1 - c0) * f
    arr[..., 3] = 255
    return Image.fromarray(arr.astype(np.uint8), "RGBA")

def outline_silhouette(img, width_px, color=OUTLINE):
    alpha = img.split()[3]
    edge = alpha.filter(ImageFilter.MaxFilter(2 * width_px + 1))
    ring = ImageChops.subtract(edge, alpha)
    base = Image.new("RGBA", img.size, color + (255,))
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(base, (0, 0), ring)
    return Image.alpha_composite(out, img)

def bezier(p0, p1, p2, p3, n=40):
    ts = np.linspace(0, 1, n)
    pts = []
    for t in ts:
        mt = 1 - t
        x = mt**3*p0[0] + 3*mt*mt*t*p1[0] + 3*mt*t*t*p2[0] + t**3*p3[0]
        y = mt**3*p0[1] + 3*mt*mt*t*p1[1] + 3*mt*t*t*p2[1] + t**3*p3[1]
        pts.append((x, y))
    return pts

def tapered_stroke(d, pts, w0, w1, color):
    n = len(pts)
    for i in range(n - 1):
        w = w0 + (w1 - w0) * i / max(1, n - 1)
        d.line([pts[i], pts[i + 1]], fill=color, width=max(1, int(w)))
        d.ellipse([pts[i][0] - w/2, pts[i][1] - w/2, pts[i][0] + w/2, pts[i][1] + w/2], fill=color)


# ── procedural stand-in assets (swap with painted PNGs anytime) ─────────

def asset_vine_curl(h_pt=120, flip=False, seed=1):
    """Log-spiral curl with leaves — the signature Rayman decorative swirl."""
    random.seed(seed)
    H = h_pt * S
    W = int(H * 0.62)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    green = (74, 158, 66)
    # stem rises then curls into a spiral
    stem = bezier((W * 0.5, H), (W * 0.30, H * 0.62), (W * 0.62, H * 0.42), (W * 0.52, H * 0.30), 30)
    cx, cy = W * 0.5, H * 0.22
    spiral = []
    for i in range(70):
        t = i / 70 * 3.4 * math.pi
        r = H * 0.16 * math.exp(-0.22 * t)
        spiral.append((cx + math.cos(t + math.pi/2) * r, cy + math.sin(t + math.pi/2) * r))
    pts = stem + spiral
    tapered_stroke(d, pts, 7 * S, 1.5 * S, green + (255,))
    # leaves along the stem
    for i in range(3, len(stem) - 4, 6):
        x, y = stem[i]
        ang = random.uniform(-0.7, 0.7)
        lw, lh = 12 * S, 6 * S
        leaf = Image.new("RGBA", (lw * 2, lh * 2), (0, 0, 0, 0))
        ImageDraw.Draw(leaf).ellipse([0, lh//2, lw, lh + lh//2], fill=(96, 190, 84, 255))
        leaf = leaf.rotate(math.degrees(ang), expand=True)
        img.alpha_composite(leaf, (int(x), int(y - lh)))
    img = outline_silhouette(img, int(1.6 * S))
    return img.transpose(Image.FLIP_LEFT_RIGHT) if flip else img

def asset_tree_gnarled(h_pt=210, seed=3):
    """Curvy-trunk tree with root flares, a branch curl, layered canopy."""
    random.seed(seed)
    H = h_pt * S
    W = int(H * 1.0)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    bark, bark_hi = (92, 64, 44), (136, 98, 66)
    trunk = bezier((W*0.48, H), (W*0.36, H*0.72), (W*0.60, H*0.55), (W*0.50, H*0.34), 44)
    tapered_stroke(d, trunk, 26 * S * h_pt/210, 8 * S, bark + (255,))
    # root flares
    for dx, bend in [(-0.16, -0.10), (0.18, 0.12)]:
        root = bezier((W*0.48, H*0.97), (W*(0.48+dx*0.4), H*0.96), (W*(0.48+dx), H*0.98), (W*(0.48+dx*1.3), H), 18)
        tapered_stroke(d, root, 14 * S, 3 * S, bark + (255,))
    # one curling branch
    br = bezier((W*0.52, H*0.45), (W*0.72, H*0.40), (W*0.80, H*0.30), (W*0.76, H*0.22), 24)
    tapered_stroke(d, br, 8 * S, 2 * S, bark + (255,))
    # bark highlight
    hl = [(x - 3*S, y) for x, y in trunk[6:-6]]
    tapered_stroke(d, hl, 6 * S, 2 * S, bark_hi + (255,))
    # canopy: dark under-blobs then lit blobs then glow crown
    blobs = [(0.50, 0.24, 0.30), (0.28, 0.32, 0.22), (0.72, 0.30, 0.24),
             (0.40, 0.14, 0.20), (0.62, 0.15, 0.20)]
    for cx, cy, r in blobs:
        R = r * H
        d.ellipse([cx*W - R, cy*H - R, cx*W + R, cy*H + R], fill=(38, 112, 52, 255))
    for cx, cy, r in blobs:
        R = r * H * 0.72
        d.ellipse([cx*W - R, cy*H - R*1.3, cx*W + R, cy*H + R*0.5], fill=(78, 168, 70, 255))
    d.ellipse([W*0.36, H*0.02, W*0.66, H*0.20], fill=(150, 216, 96, 220))
    img = brushify(img, 0.13, seed, scalemix=(5, 12, 28))
    return outline_silhouette(img, int(2 * S))

def asset_platform_moss(w_pt=300, h_pt=56, seed=5):
    """Mossy ledge: noisy earth, grass mane with drips, hanging moss strands."""
    random.seed(seed)
    W, H = w_pt * S, h_pt * S
    pad = 22 * S
    img = Image.new("RGBA", (W + pad*2, H + pad*2), (0, 0, 0, 0))
    body = brushify(vgrad(W, H, [(126, 86, 52), (58, 36, 26)]), 0.2, seed, (5, 12, 26))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W-1, H-1], radius=18*S, fill=255)
    img.paste(body, (pad, pad), mask)
    d = ImageDraw.Draw(img)
    def mane(color, y_off, lobe):
        x = pad - 4*S
        while x < pad + W + 4*S:
            r = random.uniform(9, 17) * S * lobe
            d.ellipse([x - r, pad + y_off - r, x + r, pad + y_off + r], fill=color + (255,))
            x += r * random.uniform(0.85, 1.25)
    mane((52, 140, 58), 7*S, 1.15)
    mane((88, 190, 68), 3*S, 0.95)
    mane((156, 226, 88), 0, 0.68)
    # hanging moss strands: drape from the grass lip down over the dirt face
    for _ in range(w_pt // 14):
        x = random.uniform(pad + 8*S, pad + W - 8*S)
        ln = random.uniform(16, 40) * S
        sway = random.uniform(-6, 6) * S
        pts = bezier((x, pad + 13*S), (x + sway*0.3, pad + 13*S + ln*0.4),
                     (x + sway, pad + 13*S + ln*0.8), (x + sway, pad + 13*S + ln), 10)
        tapered_stroke(d, pts, 5*S, 1.5*S, (96, 182, 80, 245))
        d.ellipse([pts[-1][0]-2*S, pts[-1][1]-2*S, pts[-1][0]+2*S, pts[-1][1]+2*S],
                  fill=(150, 216, 96, 255))
    img = brushify(img, 0.05, seed + 9)
    return outline_silhouette(img, int(2.2 * S))

def asset_glow_flower(h_pt=52, color=(255, 120, 220), seed=8):
    color = tuple(color)
    random.seed(seed)
    H = h_pt * S
    W = int(H * 0.8)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    tapered_stroke(d, bezier((W*0.5, H), (W*0.4, H*0.7), (W*0.6, H*0.5), (W*0.5, H*0.34), 20),
                   4*S, 2*S, (52, 128, 60, 255))
    r = H * 0.16
    for i in range(5):
        a = i / 5 * 2 * math.pi
        d.ellipse([W*0.5 + math.cos(a)*r - r*0.8, H*0.28 + math.sin(a)*r - r*0.8,
                   W*0.5 + math.cos(a)*r + r*0.8, H*0.28 + math.sin(a)*r + r*0.8],
                  fill=color + (255,))
    d.ellipse([W*0.5 - r*0.7, H*0.28 - r*0.7, W*0.5 + r*0.7, H*0.28 + r*0.7],
              fill=(255, 246, 200, 255))
    return outline_silhouette(img, int(1.5 * S))

def asset_hill(w_pt=900, amp_pt=70, color=(58, 142, 92), seed=13, bushes=True):
    color = tuple(color)
    W, Hh = w_pt * S, (amp_pt + 420) * S   # deep body so hills anchor to frame bottom
    n = value_noise(W, 8, 6, seed)[4]
    curve = amp_pt * S - (n - n.mean()) * 2 * amp_pt * S * 0.8 + 10 * S
    img = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
    grad = vgrad(W, Hh, [color, tuple(int(c*0.55) for c in color)])
    mask_arr = np.zeros((Hh, W), np.uint8)
    mask_arr[np.arange(Hh)[:, None] >= curve[None, :]] = 255
    img.paste(grad, (0, 0), Image.fromarray(mask_arr, "L"))
    d = ImageDraw.Draw(img)
    d.line([(x, curve[x]) for x in range(0, W, 4)],
           fill=tuple(min(255, c + 52) for c in color) + (210,), width=4*S)
    if bushes:
        random.seed(seed)
        x = 0
        while x < W:
            r = random.uniform(16, 34) * S
            cy = curve[min(W-1, int(x))]
            d.ellipse([x-r, cy-r*0.9, x+r, cy+r*0.6], fill=tuple(int(c*0.9) for c in color)+(255,))
            d.ellipse([x-r*0.5, cy-r*0.95, x+r*0.45, cy-r*0.1],
                      fill=tuple(min(255, c+38) for c in color)+(255,))
            x += random.uniform(34, 90) * S
    return brushify(img, 0.10, seed + 2)

ASSETS = {
    "vine_curl": asset_vine_curl,
    "tree_gnarled": asset_tree_gnarled,
    "platform_moss": asset_platform_moss,
    "glow_flower": asset_glow_flower,
    "hill": asset_hill,
}

def load_asset(spec):
    """Painted file wins over procedural stand-in — the UbiArt swap point."""
    name = spec["asset"]
    path = f"assets/{name}.png"
    if os.path.exists(path):
        img = Image.open(path).convert("RGBA")
    else:
        img = ASSETS[name](**spec.get("params", {}))
    if "scale" in spec:
        w, h = img.size
        img = img.resize((int(w * spec["scale"]), int(h * spec["scale"])), Image.LANCZOS)
    if spec.get("flip"):
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    return img


# ── the presentation pipeline ───────────────────────────────────────────

def radial_glow(dd, color, alpha=255):
    yy, xx = np.mgrid[0:dd, 0:dd].astype(np.float32)
    r = np.sqrt((xx - dd/2)**2 + (yy - dd/2)**2) / (dd/2)
    fall = np.clip(1 - r, 0, 1) ** 2.2
    arr = np.zeros((dd, dd, 4), np.float32)
    arr[..., :3] = color
    arr[..., 3] = fall * alpha
    return Image.fromarray(arr.astype(np.uint8), "RGBA")

def add_light(scene, img, pos):
    layer = Image.new("RGBA", scene.size, (0, 0, 0, 0))
    layer.alpha_composite(img, pos)
    base = np.asarray(scene).astype(np.float32)
    lay = np.asarray(layer).astype(np.float32)
    base[..., :3] += lay[..., :3] * (lay[..., 3:4] / 255.0)
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGBA")

def render(scene_spec, out_path):
    W, H = scene_spec["size"][0] * S, scene_spec["size"][1] * S
    sky = vgrad(W, H, scene_spec["sky"])
    frame = brushify(sky, 0.05, 1, (3, 6))
    sky_rgb = scene_spec["sky"][len(scene_spec["sky"]) // 2]
    focus = scene_spec.get("focus", 0.62)

    # sun glows
    for g in scene_spec.get("glows", []):
        frame = add_light(frame, radial_glow(g["d"] * S, g["color"], g["alpha"]),
                          (g["x"] * S, g["y"] * S))

    # planes far→near: haze by depth, DOF blur by |depth − focus|
    for plane in sorted(scene_spec["planes"], key=lambda p: p["depth"]):
        img = load_asset(plane)
        depth = plane["depth"]
        hz = max(0.0, (focus - depth)) * scene_spec.get("haze", 0.75)
        if hz > 0.01:
            arr = np.asarray(img).astype(np.float32)
            arr[..., :3] = arr[..., :3] * (1 - hz) + np.array(sky_rgb, np.float32) * hz
            img = Image.fromarray(arr.astype(np.uint8), "RGBA")
        blur = abs(depth - focus) * scene_spec.get("dof", 14) * S
        if blur > 0.8:
            img = img.filter(ImageFilter.GaussianBlur(blur))
        frame.alpha_composite(img, (plane["x"] * S, plane["y"] * S))

    # volumetric shafts
    rays = scene_spec.get("rays")
    if rays:
        lay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        rd = ImageDraw.Draw(lay)
        sx, sy = rays["x"] * S, rays["y"] * S
        for ang in rays["angles"]:
            a = math.radians(ang + 90)
            rd.line([(sx, sy), (sx + math.cos(a)*H*1.8, sy + math.sin(a)*H*1.8)],
                    fill=tuple(rays["color"]) + (rays["alpha"],), width=rays["width"] * S)
        lay = lay.filter(ImageFilter.GaussianBlur(9 * S))
        frame = Image.alpha_composite(frame, lay)

    # particles
    random.seed(99)
    for _ in range(scene_spec.get("particles", 30)):
        px, py = random.uniform(0, W-40), random.uniform(H*0.2, H-30)
        sz = int(random.uniform(5, 20)) * S
        frame = add_light(frame, radial_glow(sz, scene_spec.get("particle_color", (255, 226, 140)),
                                             random.randint(24, 78)), (int(px), int(py)))

    # bloom: blur the bright pixels back over the frame
    arr = np.asarray(frame).astype(np.float32)
    lum = arr[..., :3].mean(axis=2)
    thresh = np.clip((lum - 200) / 55, 0, 1)
    bright = arr.copy()
    bright[..., 3] = thresh * 255
    bloom = Image.fromarray(bright.astype(np.uint8), "RGBA").filter(ImageFilter.GaussianBlur(10 * S))
    frame = add_light(frame, bloom, (0, 0))

    # grade: vignette + shadow/highlight split-tone + contrast
    arr = np.asarray(frame).astype(np.float32)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    r = np.sqrt(((xx - W/2)/(W/2))**2 + ((yy - H/2)/(H/2))**2)
    arr[..., :3] *= (1 - np.clip(r - 0.6, 0, 1) * 0.32)[..., None]
    lum = arr[..., :3].mean(axis=2, keepdims=True) / 255.0
    g = scene_spec.get("grade", {"shadow": [-6, 5, 10], "light": [10, 3, -8]})
    arr[..., :3] += (1 - lum) * np.array(g["shadow"]) + lum * np.array(g["light"])
    arr[..., :3] = np.clip((arr[..., :3] - 128) * 1.07 + 128 + 2, 0, 255)
    Image.fromarray(arr.astype(np.uint8), "RGBA").convert("RGB").save(out_path, quality=93)
    print("rendered", out_path)


if __name__ == "__main__":
    with open(sys.argv[1] if len(sys.argv) > 1 else "scene.json") as f:
        render(json.load(f), "scene_render.png")
