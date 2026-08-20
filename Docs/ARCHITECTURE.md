# SkyRunner — architecture

Two halves, deliberately separated the way UbiArt separated them: an offline
**art pipeline** (tools that produce data) and a thin, fast **runtime**
(Swift/SpriteKit, iOS + iPadOS).

```
Tools/composer.py    →  Assets/Friezes/*.png + *.json   →  FriezeKit/Frieze/*
Tools/RigEditor.html →  Assets/Rigs/*.json + part PNGs   →  FriezeKit/Anim/*
   (or Spine editor) ↗        ↑
Tools/LevelEditor.html →  World/Levels.swift  or  engine.json
Tools/art_director.py  →  part PNGs + Spine rig  (art spec in, assets out)
Tools/ai_director.py   →  brief in, validated engine.json / art spec out
```

## Folder map

| Path | Contents |
|---|---|
| `App/` | SwiftUI entry point hosting the SpriteKit view |
| `Core/` | Tuning constants, physics categories, persistence, audio, procedural Painter |
| `FriezeKit/Core/` | The machine-drivable surface: command API + world queries |
| `FriezeKit/Frieze/` | Backdrop engine: scene model, load-time baker, parallax stage |
| `FriezeKit/Anim/` | Skeletal animation: Skeleton/IK, timelines+state, rig loader, SpriteKit renderer, deformed-mesh collision |
| `World/` | Level maps, design rules, world-piece builders, procedural parallax fallback |
| `Actors/` | Player (procedural + skeletal), enemy AI, boss, NPCs |
| `Scenes/` | Gameplay scene, world-map menu |
| `FX/` | Particles, dust, floating combo text |
| `Monetization/` | StoreKit 2 IAP, ad abstraction |
| `Assets/Friezes/` | Hi-res backdrop layers + scene JSON |
| `Assets/Rigs/` | Skeleton rig JSON + body-part art |
| `Assets/Audio/` | Synthesized SFX |
| `Tools/` | `composer.py` (backdrops), `LevelEditor.html` (levels), `RigEditor.html` (rigs + curves), `art_director.py` (art + rigs), `ai_director.py` (AI bridge), `atlas_packer.py` |
| `Docs/` | This file, README, ENGINE_API.md |

## FriezeKit/Anim — animation system

Data model matches the industry standard (Spine/DragonBones), so rigs from
either the bundled editor or the Spine app load through the same path.

* `Skeleton.swift` — `SkeletonData` (immutable, shared) vs `Skeleton`
  (per-instance pose). Bone hierarchy composed with 2×3 affine matrices in a
  single parent-before-child pass; `inheritRotation:false` supports Rayman-style
  detached limbs. Two-bone analytic IK (law of cosines) plus single-bone aim.
* `Animation.swift` — timelines for rotate/translate/scale/attachment/color/
  **mesh deform**/events; Bézier curve easing solved by Newton iteration;
  `AnimationState` with numbered tracks, automatic crossfade (per-pair mix
  times) and **additive layers** — e.g. an airborne lean weighted by velocity
  layered over a keyframed run cycle.
* `RigLoader.swift` — parses Spine JSON (3.8+ and legacy skin dialects) and the
  native `animkit-rig/1` format. Bones are topologically sorted on load, so
  hand-edited files can't break the transform pass.
* `SkeletonNode.swift` — SpriteKit renderer. Persistent node per slot (no churn
  per frame), region attachments as sprites, mesh attachments as
  texture-filled deformable paths, slot order = draw order. Adds **procedural
  secondary motion**: damped springs on tagged bones (hair, cloth) computed on
  top of the keyframed pose. `boxPoints(slot:)` exposes animation-following hit
  regions for gameplay.

`Actors/SkeletalPlayer.swift` adapts this to the `PlayerRig` protocol, which
`PlayerCharacter` (procedural) also implements — `PlayerRigFactory.make()`
picks whichever has assets bundled, so gameplay code never changes and the
game still runs with no rig assets at all.

## FriezeKit/Frieze — backdrop system

Layers ("friezes") at depth 0…1 with the gameplay plane at `focus`. Haze
tinting toward the sky and depth-of-field blur are **baked once at load**
(Core Graphics / Core Image); per frame each layer costs one multiply-add.
Layers deeper than `focus` render behind gameplay, nearer ones in front.

## Performance strategy

* Expensive imaging happens at load, never per frame.
* Shared immutable rig data; per-instance pose only.
* Texture cache + persistent slot nodes → no allocation in the render loop.
* Springs and IK run only on bones that opt in.

## Differences from classic UbiArt (deliberate)

* UbiArt shipped a full custom engine; this rides SpriteKit/Metal, so one
  person can maintain it.
* UbiArt's art was hand-painted; here art is swappable — procedural today,
  painted or AI-generated PNGs tomorrow, same loaders.
* Editors are web/Python tools rather than an integrated app: they run
  anywhere, need no build step, and export plain JSON.

## Review pass — hardening log

A full audit was run over the runtime; every finding below was fixed.

**Would not have compiled**
1. `RigLoader.parseIK` cast a `CGFloat` to `NSNumber` with `as` — replaced with
   explicit `bendPositive` (Bool) / `bendDirection` (±1) handling.
2. `Skeleton.applyIK` used a `cond ? Int : nil` ternary inside `guard let`
   (ambiguous type) — rewritten as a plain bounds check.

**Correctness**
3. `AnimationState` set `loops` on the *shared* `AnimationClip`, so one actor's
   loop setting leaked to every actor using that clip — looping moved onto
   `TrackEntry` (per-instance).
4. `SkeletonNode` mutated its `springs` dictionary while iterating it
   (undefined behaviour) — now iterates a key snapshot.
5. The `SKTextureAtlas` passed to `SkeletonNode.init` was dropped, so atlas
   textures never resolved — now retained and used.
6. A slot switching between region and mesh attachments left a stale node —
   slot kind is tracked and the node rebuilt.
7. IK descendant re-solve could form an invalid `Range` when a chain ended on
   the last bone.
8. Modulo-by-zero when a clip had no keyframes.

**Crash-proofing**
9. `buildLevel` now guards a bad level index and empty/zero-width maps.
10. A map missing its `S` marker no longer drops the player through the world.
11. Boss portal column clamped (was negative on narrow levels).
12. Butterfly spawn no longer forms an invalid `Range` on short levels.
13. `goToNextLevel` bounds-checked (returns to menu instead of trapping).
14. `hazeColor` and `skyTexture` handle empty/short gradient stop arrays.
15. Removed the last `as!` force-cast in the rig loader.

**Hygiene**: missing `import UIKit`, dead bindings, and an unused stored
property removed; `pose` now actually drives rig animation selection (hover
stays level, pound/wall-slide read correctly).

Verified after patching: delimiters balanced across all files, no
force-unwraps / force-casts / stray `fatalError`, `PlayerRig` satisfied by both
hero implementations, every `Tuning` constant resolves, and the animation math
(interpolation, key clamping, seamless loop, crossfade weights summing to 1,
loop wrapping) checked against a Python port of the runtime.

## Round 2 — the three big subsystems

### 1. Weighted mesh skinning (`FriezeKit/Anim/MeshSkinning.swift`)
Vertices can be driven by several bones at once — the difference between a
cut-out puppet hinging at seams and a painted limb deforming as one surface.
Rendering uses `SKWarpGeometryGrid`, Apple's native GPU mesh warp on
`SKSpriteNode`: real per-vertex deformation inside SpriteKit's own pipeline,
without hand-writing a Metal renderer or leaving the batching everything else
uses. `RigLoader` now decodes Spine's weighted-mesh vertex encoding
(`boneCount, [boneIndex, x, y, weight]…`), and lattice points inherit the
artist's painted weights by inverse-distance blending from the nearest authored
vertices. Influences are normalized to sum to 1, or the mesh would inflate as
bones move. Animated free-form `deform` timelines ride on top of skinning.

### 2. Atlas packer + hot reload (`Tools/atlas_packer.py`, `Render/Lighting.swift`)
MaxRects (best-short-side-fit) packing with alpha trimming, power-of-two pages,
and multi-page overflow. Emits a Spine-format `.atlas` descriptor plus a JSON
frame map. Packed pages batch draw calls and cut memory — on the shipped hero
art it produced a single 64×256 page at 56% of the loose file size.
`HotReloader` (DEBUG only, compiled out of Release) watches a directory with a
`DispatchSource` file-system observer, debounces bursts of editor writes, and
re-presents the scene — tweak a rig or frieze in the tools and see it live.

### 3. Normal-mapped 2D lighting (`FriezeKit/Render/Lighting.swift`)
`LightingRig` installs a warm key light and a cool rim light on the camera,
with optional local point lights for coins and portals. `NormalMapper`
generates normal maps from each sprite's own texture via
`SKTexture.generatingNormalMap` — no hand-authored maps needed — and caches
them per texture, since generation is expensive and must never happen per
frame. Gameplay sprites are lit and cast shadows; backdrop friezes are lit only
(distant layers casting shadows reads wrong) at reduced contrast.

## Round 3 — the editor becomes machine-drivable

### 1. Deformed-mesh collision (`FriezeKit/Anim/DeformedCollider.swift`)
A cut-out puppet can get away with one capsule; a skinned, deforming rig cannot.
A thrown punch reaches half a body-length past the box, a wind-up pulls the fist
back inside it, and a stretched jump pose is nothing like the rectangle that
supposedly contains it. The collider reads **exactly the lattice the renderer
draws with** (`MeshSkinning.solveWorld` — one solver, so hulls can never drift
from pixels), reduces it to convex hulls (Andrew's monotone chain,
counter-clockwise because `SKPhysicsBody(polygonFrom:)` builds an inside-out body
from a clockwise path, and winding is re-normalised whenever the rig flips), and
offers three modes: `box` (the shipped body, computes nothing), `hull` (one hull
around the whole rig), `perSlot` (a hull per limb; a compound body).

Cost is split deliberately: hulls re-solve every frame — a few hundred multiplies,
and gameplay queries must not lag the pose — while physics *bodies* are rebuilt
every few frames, because `SKPhysicsBody(polygonFrom:)` re-triangulates on each
call and a swapped body loses SpriteKit's contact bookkeeping. Where a body is
swapped it inherits the old one's role (category, masks, velocity), so a collider
can't quietly redefine what an actor is or stop it mid-air.

Gameplay uses it in two places. The punch resolves against the **drawn fist**
over the length of the swing rather than at the button press, and enemy/hazard
contacts are confirmed against the drawn body: a graze the box reported but the
art missed is remembered and re-tested each frame, because `didBegin` fires once
and a hazard you are standing inside would otherwise never hurt you. In `box`
mode there are no hulls and the box remains the truth — the shipped game plays
identically until a collider mode is asked for.

Procedural rigs are not left out: `PlayerRig`'s default implementation derives
hit volumes from sprite quads, so collision quality degrades gracefully instead
of switching off.

### 2. Visual level editor (`Tools/LevelEditor.html`)
Brush / rect / flood-fill / eyedropper over the ASCII maps, with undo, pan and
zoom, and the camera's 844×390 viewport drawn as an overlay so you can see what
fits on screen. Two things make it a design tool rather than a paint program:

* **Live rule checking.** The design rules that were a comment at the top of
  `Levels.swift` are now data (`World/LevelRules.swift`) — support requirements,
  uniqueness, crystal headroom, floor gaps, and an optimistic reachability
  flood-fill from the spawn using the player's real movement envelope (3 tiles
  up, 4 across, derived from `jumpVelocity` and `gravity`). Violations list in the
  panel and clicking one centres the offending tile.
* **A reachability overlay** that tints every standable cell by whether the
  player can actually get there.

Exports a Swift block for `Levels.swift` *or* an `engine.json` the running game
applies — the same document the AI writes.

### 3. Curve editing (`Tools/RigEditor.html`)
The runtime has read cubic Bézier easing since day one (`Curve.bezier`, solved by
Newton iteration); nothing could author it, so every key was linear — which is
exactly what makes hand-keyed motion read as mechanical. The right-hand panel now
edits the curve leaving the selected key: draggable control handles, presets
(including anticipate and overshoot, which need control points outside the unit
square — safe, because the solver only ever inverts *x*), and a live playhead dot
that tracks playback through the curve. The editor's sampler mirrors the Swift
solver exactly, so what you dial in is what the game plays.

Supporting changes it needed: lanes split per bone *per channel* (a curve belongs
to a key on a channel), a Setup/Animate mode split so dragging a bone writes
animation deltas instead of editing the rest pose, a measured playhead instead of
a magic pixel offset, and a motion trail that samples the whole clip — the only
honest way to see what a curve did, since easing changes spacing, not shape.

### 4. The machine-drivable surface (`FriezeKit/Core/`)
`EngineAPI.swift` is the write half, `EngineQuery.swift` the read half. Commands
in as JSON, receipts and a full world snapshot back out, plus the engine's own
op schema so a producer is constrained by *this build's* vocabulary. Full
reference: `Docs/ENGINE_API.md`.

Its safety story is structural: declarative ops only (no eval, no path from JSON
to arbitrary behaviour), every number range-checked with non-finite values
rejected at the door, names held to an identifier alphabet, and every effect
landing in `EngineOverrides` so `reset` restores the shipped game exactly.

### 5. AI-generated art with Spine rigs (`Tools/art_director.py`, `ai_director.py`)
An image model returns pixels, and pixels alone can't be animated. So the model
writes the *art direction* — palette, silhouette, part list, personality — and
`art_director.py` paints it (bold ink outline, radial shading with a warm bounce,
cool rim, one gloss blob, paper grain, rendered 4× and downsampled) and builds
the rig: bones with detached limbs and spring tags, slots, **weighted mesh
attachments**, and five clips carrying Bézier curves and mesh deform. Output is
the dialect `RigLoader` already reads, so generated characters animate, collide
through the deformed hulls, and open in the rig editor for hand-tuning.

`ai_director.py` is the loop: brief → schema-constrained document → offline
validation → one repair round → `Documents/engine.json` → receipt. It also serves
a `127.0.0.1` bridge so both editors can generate through AI without an API key
in the page. With no key at all, a deterministic composer answers instead — the
whole pipeline stays demonstrable offline, the same call `AdsManager` makes with
its stub ad network.

## Round 3 — hardening log

Found and fixed while wiring the above:

1. **`Int(CGFloat)` could trap.** JSON may carry `1e400`; `Int(.infinity)` and
   `Int(.nan)` both trap in Swift. Non-finite numbers are now rejected during
   parsing, before any conversion.
2. **Mesh deform was applied to the wrong vertices.** Spine keys `deform` per
   *authored vertex*, but the solver indexed its own lattice points — silently
   warping the wrong corners. Lattice bindings now remember the authored
   vertices they were blended from, and deform is resampled through that
   mapping.
3. **Mirrored hulls built inside-out bodies.** A rig facing left is
   `xScale = -1`, which flips winding; `signedArea > 0` then rejected every hull.
   Winding is normalised on every space change.
4. **The document watcher could loop forever.** The engine's own answers were
   written next to the inbox it watches, and a re-applied document's
   `needsReload` rebuilt the scene, which re-applied it. Answers now go to a
   subdirectory (writes inside it don't touch the watched vnode) and applied
   documents are fingerprinted in static storage that survives a scene rebuild.
5. **Level overrides leaked across levels.** An edit to level 2 was applied to
   level 3 on "Next Level"; overrides are now keyed to the level they edit.
6. **The reachability validator cried wolf.** Its first version couldn't model a
   flat hop over a gap and declared shipped level 2 unplayable. All four levels
   validate clean now, checked against a Python port of the Swift.
7. **The run cycle popped once per stride.** Phase-shifted keys for the second
   foot didn't return to their start value; tracks are now sampled from a
   periodic function, so the ends match by construction.
8. **`art_director` killed the bridge when Pillow was missing.** A module-level
   `sys.exit` on import took the server down; the raster dependency is now
   optional and the rig half still generates without it.
9. Two generator bugs a reader would have missed: mesh attachments pointed at
   the bone name instead of the image (blank meshes), and the deform timeline
   hard-coded a `hero_` prefix (dead timeline for any other character).

Verified: 100+ assertions over the generated rig against a port of `RigLoader`'s
parsing rules (weighted-vertex decode, weight normalisation, bone indices, curve
ranges, seamless loops, deform arity); the editors' rule engines checked against
all four shipped levels and agreeing with the Swift; the curve solver's
endpoints, monotonicity and symmetry; the AI pipeline end to end offline
(generate → validate → install → serve). Delimiters balanced and every new
symbol cross-referenced across all Swift files.

**Not verified here:** the Swift does not compile in this environment (no iOS SDK
is selected — `xcode-select` points at the Command Line Tools), and the raster
painter never executed (no Pillow/numpy, and the package index is unreachable).
Both need a run on a machine with Xcode and `pip install pillow numpy`.
`make doctor` reports whether either is missing; `make verify` runs the
content checks with no Xcode at all.

## Round 4 — raising the six subsystem ceilings

Each of these existed and worked; each was missing the capability that separates
"demonstrates the idea" from "could ship a game".

**Backdrops.** Vertical parallax (a level taller than the screen no longer slides
its backdrop as a flat sheet), infinite horizontal tiling — which removes the
cap on level length that the old "author your layers wide enough" rule really
was — per-layer drift and sway, and live retinting so the time-of-day dial
reaches the baked layers.

**Art pipeline.** `Tools/asset_audit.py` verifies that what the data references
exists, at every scale, with aspect ratios that agree. Run once on the shipped
assets it found nine real defects: the hero rig declared its art at ~2.4× the
size of the actual PNGs (so every mesh stretched), the two foot sprites had
mismatched @2x/@3x aspects, and five backdrop layers were far too narrow for a
50-tile level. All fixed. Plus authored normal-map support (`<image>_n`) and the
image-model ingest path.

**Skeletal animation.** Shear (bones skew, so cut-out limbs lean instead of
staying boards), draw-order timelines (a fist passes in front on the way out and
behind on the way back), animated IK mix, IK stretch and softness, mix-blend
modes (replace / add / first), and runtime skin swapping — exposed as the
`setSkin` command.

**Lighting.** Authored normal maps win over generated ones, per-slot, because the
rig is the only thing that knows each slot's image name. Light culling with a
budget, since SpriteKit costs a pass per light per lit sprite. Time of day drives
the key light's *direction* and shadow colour, not just its tint. Flicker lights.

**Deformed collision.** Contacts now carry a normal and a penetration depth, so
gameplay can ask *which way* and *how deep* rather than only *whether* —
knockback and impact effects come off the contact. Concave decomposition keeps
the notch between two shapes instead of hulling it away. A broadphase bounds test
rejects candidates before any SAT work, and a swept test catches fast movers: the
crusher descends 20pt per frame and is tested along its path.

**Gameplay.** Nine new tiles and the mechanics behind them: 45° slopes with
surface-projected movement (a ramp climbed by repeated collision reads as
stuttering), dash on the ground and in the air, ledge grab, vine climbing,
springs, conveyors, updraft columns, cycling crushers, and checkpoints.
`Actors/PlayerMotion.swift` holds it as a plain value type with an explicit
precedence order — dash > ledge > climb > spring > updraft > run — because a
dash that a conveyor can cancel feels broken in a way tuning never fixes.

The validator moved with the abilities: reachability now models dash range,
spring launches and free travel inside lift columns, and all three
implementations of the rules (Swift, the editor's JS, the director's Python)
agree on levels built from the new tiles.
