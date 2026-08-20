#!/usr/bin/env python3
"""
atlas_packer.py — packs loose PNGs into texture atlas pages.

Why it matters: every loose image is its own draw call and its own memory
allocation rounded up to a power of two. Packed pages let SpriteKit batch
draws and cut memory sharply — the difference between a smooth 120fps scene
and a stuttering one once you have hundreds of painted assets.

Algorithm: MaxRects (best-short-side-fit) with rotation disabled — the same
family Spine's own packer and TexturePacker use.

Usage:
    python3 atlas_packer.py <input_dir> <out_name> [--size 2048] [--pad 2]

Outputs:
    <out_name>.png      atlas page(s); multiple pages get -1, -2 suffixes
    <out_name>.atlas    Spine-format descriptor (also read by our RigLoader)
    <out_name>.json     simple name -> frame map for other tools
"""
import argparse, json, os, sys
from PIL import Image


class MaxRects:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.free = [(0, 0, w, h)]
        self.used = []

    def _score(self, fr, w, h):
        fx, fy, fw, fh = fr
        if w > fw or h > fh:
            return None
        leftover_h = abs(fw - w)
        leftover_v = abs(fh - h)
        return (min(leftover_h, leftover_v), max(leftover_h, leftover_v))

    def insert(self, w, h):
        best, best_score = None, None
        for fr in self.free:
            s = self._score(fr, w, h)
            if s is not None and (best_score is None or s < best_score):
                best, best_score = fr, s
        if best is None:
            return None
        node = (best[0], best[1], w, h)
        self._split(node)
        self.used.append(node)
        return node

    def _split(self, node):
        nx, ny, nw, nh = node
        new_free = []
        for fr in self.free:
            fx, fy, fw, fh = fr
            # no overlap → keep as-is
            if nx >= fx + fw or nx + nw <= fx or ny >= fy + fh or ny + nh <= fy:
                new_free.append(fr)
                continue
            if nx > fx:
                new_free.append((fx, fy, nx - fx, fh))
            if nx + nw < fx + fw:
                new_free.append((nx + nw, fy, fx + fw - (nx + nw), fh))
            if ny > fy:
                new_free.append((fx, fy, fw, ny - fy))
            if ny + nh < fy + fh:
                new_free.append((fx, ny + nh, fw, fy + fh - (ny + nh)))
        # prune rects fully contained in another
        pruned = []
        for i, a in enumerate(new_free):
            if not any(i != j and self._contains(b, a) for j, b in enumerate(new_free)):
                pruned.append(a)
        self.free = pruned

    @staticmethod
    def _contains(outer, inner):
        ox, oy, ow, oh = outer
        ix, iy, iw, ih = inner
        return ix >= ox and iy >= oy and ix + iw <= ox + ow and iy + ih <= oy + oh


SKIP_SUFFIXES = ("_preview", "_scene", "_ingest", "_n")


def pack(input_dir, out_name, max_size=2048, pad=2, trim=False, scale=3,
         only=None):
    """Pack one density tier into a page, plus a frame map the runtime reads.

    Two decisions worth stating, because both are load-bearing:

    **One density per page.** A directory holds `@2x` and `@3x` of everything;
    packing both would put each image in twice and the runtime would have no way
    to choose. `scale` picks the tier and the suffix is stripped from the frame
    name, so a rig asking for `hero_body` finds it whatever tier was packed.
    The page itself carries no `@Nx` suffix — it doesn't need one, because every
    attachment declares its size in points and the texture only supplies pixels.
    That is also what preserves the density policy: a denser page is simply
    crisper.

    **Trim is off by default.** A trimmed frame is smaller than the image it came
    from, so drawing it needs a per-attachment position and size correction. The
    packer records `offset`/`orig` for a consumer that wants to do that work; ours
    doesn't, and an untrimmed page is a drop-in substitution for the loose files.
    Pages come out a little larger; correctness is worth more.
    """
    suffix = f"@{scale}x.png"
    files = sorted(f for f in os.listdir(input_dir) if f.lower().endswith(suffix))
    if not files:                      # a 1x-only folder is legal
        files = sorted(f for f in os.listdir(input_dir)
                       if f.lower().endswith(".png") and "@" not in f)
    files = [f for f in files
             if not any(os.path.splitext(f)[0].removesuffix(f"@{scale}x").endswith(s)
                        for s in SKIP_SUFFIXES)]
    if only:
        files = [f for f in files
                 if os.path.splitext(f)[0].removesuffix(f"@{scale}x") in only]
    if not files:
        print("no PNGs found in", input_dir)
        return 1

    images = []
    for f in files:
        img = Image.open(os.path.join(input_dir, f)).convert("RGBA")
        name = os.path.splitext(f)[0].removesuffix(f"@{scale}x")
        offset = (0, 0)
        orig = img.size
        if trim:
            bbox = img.getbbox()          # crop fully transparent margins
            if bbox:
                offset = (bbox[0], bbox[1])
                img = img.crop(bbox)
        images.append({"name": name, "img": img, "offset": offset, "orig": orig})

    # tallest-first packs denser
    images.sort(key=lambda d: -d["img"].size[1])

    pages, remaining = [], images[:]
    while remaining:
        packer = MaxRects(max_size, max_size)
        placed, leftover = [], []
        for entry in remaining:
            w, h = entry["img"].size
            node = packer.insert(w + pad * 2, h + pad * 2)
            if node is None:
                leftover.append(entry)
            else:
                entry["rect"] = (node[0] + pad, node[1] + pad, w, h)
                placed.append(entry)
        if not placed:
            print("ERROR: image larger than page size", max_size)
            return 1
        pages.append(placed)
        remaining = leftover

    atlas_lines, frame_map = [], {}
    for pi, placed in enumerate(pages):
        # shrink the page to the used extent, rounded up to a power of two
        used_w = max(e["rect"][0] + e["rect"][2] for e in placed) + pad
        used_h = max(e["rect"][1] + e["rect"][3] for e in placed) + pad
        # Round to a multiple of 4, not a power of two. Metal has not needed POT
        # textures for a decade, and rounding 640 rows up to 1024 wastes 38% of
        # the page — which is the opposite of why you pack.
        pw = (used_w + 3) & ~3
        ph = (used_h + 3) & ~3
        page = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        for e in placed:
            page.paste(e["img"], (e["rect"][0], e["rect"][1]))

        suffix = "" if len(pages) == 1 else f"-{pi + 1}"
        png_name = f"{out_name}{suffix}.png"
        page.save(png_name)
        print(f"page {png_name}: {pw}x{ph}, {len(placed)} images")

        atlas_lines += [png_name, f"size: {pw},{ph}", "format: RGBA8888",
                        "filter: Linear,Linear", "repeat: none"]
        for e in placed:
            x, y, w, h = e["rect"]
            ox, oy = e["offset"]
            orig_w, orig_h = e["orig"]
            atlas_lines += [
                e["name"], "  rotate: false", f"  xy: {x}, {y}", f"  size: {w}, {h}",
                f"  orig: {orig_w}, {orig_h}", f"  offset: {ox}, {orig_h - oy - h}",
                "  index: -1",
            ]
            frame_map[e["name"]] = {"page": png_name, "x": x, "y": y, "w": w, "h": h,
                                    "origW": orig_w, "origH": orig_h,
                                    "offsetX": ox, "offsetY": orig_h - oy - h}

    with open(f"{out_name}.atlas", "w") as fh:
        fh.write("\n".join(atlas_lines) + "\n")
    with open(f"{out_name}.json", "w") as fh:
        json.dump({"format": "atlas/1", "scale": scale, "trimmed": bool(trim),
                   "pages": [f"{out_name.rsplit(os.sep, 1)[-1]}"
                             f"{'' if len(pages) == 1 else f'-{i + 1}'}.png"
                             for i in range(len(pages))],
                   "frames": frame_map}, fh, indent=1)

    # The win is texture *count*, not file size: a packed page is often a larger
    # PNG than the sum of its parts (PNG compresses small images well, and the
    # page carries padding), while costing one bind instead of N and one
    # allocation instead of N.
    loose_pixels = sum(e["orig"][0] * e["orig"][1] for e in images)
    page_pixels = 0
    for i in range(len(pages)):
        name = f"{out_name}{'' if len(pages) == 1 else f'-{i + 1}'}.png"
        with Image.open(name) as page_img:
            page_pixels += page_img.size[0] * page_img.size[1]
    print(f"{len(images)} textures → {len(pages)} page(s): "
          f"{len(images)} binds/frame become {len(pages)}")
    print(f"pixels: {loose_pixels:,} in parts → {page_pixels:,} on pages "
          f"({100 * page_pixels / max(loose_pixels, 1):.0f}%, the rest is padding)")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input_dir")
    ap.add_argument("out_name")
    ap.add_argument("--size", type=int, default=2048)
    ap.add_argument("--pad", type=int, default=2)
    ap.add_argument("--trim", action="store_true",
                    help="crop transparent margins (needs a trim-aware consumer)")
    ap.add_argument("--scale", type=int, default=3,
                    help="which @Nx tier to pack (default 3)")
    a = ap.parse_args()
    sys.exit(pack(a.input_dir, a.out_name, a.size, a.pad, a.trim, a.scale))
