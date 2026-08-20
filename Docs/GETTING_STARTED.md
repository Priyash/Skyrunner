# Getting started

A working game on screen, then a level, then a character animation — each with
the shortest path first and the machine-drivable path after it.

Everything here assumes you are a software engineer and not an artist. There is
no step that requires drawing.

---

## 1. First run

```bash
make doctor      # is the toolchain usable? starts here, tells you exactly what's missing
make run         # generate project → build → boot simulator → launch
```

`make doctor` is worth running first because the usual failure is not a code
problem: a Mac set up for command-line work often has `xcode-select` pointing at
CommandLineTools, which has no iOS SDK. It prints the two `sudo` lines that fix
it.

There is no `.xcodeproj` in the repository on purpose. A pbxproj is a generated
2000-line file that conflicts on every branch and reviews to nothing, so
[`project.yml`](../project.yml) is the source of truth and the project is
generated from it:

```bash
make project     # XcodeGen if installed, Tools/genproject.py otherwise
```

Both read the same `project.yml`, so a missing brew install is never the reason
you can't build. **Adding a Swift file needs no project edit** — directories are
globbed, so `make project` picks it up.

```bash
make build                     # compile
make test                      # the unit suites
make verify                    # content checks, needs no Xcode at all (~1s)
CONFIG=Release make build      # optimised
SIMULATOR='iPad Pro 13-inch (M4)' make run
```

---

## 2. The mental model

The engine is **data-driven by name**. No content is compiled in; every kind of
content is a file the bundle resolves at runtime, with a compiled fallback so a
build missing a file is still playable.

| Content | Lives as | Resolved by |
|---|---|---|
| Level | rows of glyphs + presentation | `Assets/Levels/*.json` → `LevelLibrary`, falling back to `Levels.builtIn` |
| Character | Spine-subset JSON + `@2x/@3x` PNGs | `RigLoader.load(named:)` → `Assets/Rigs/` |
| Backdrop | a frieze scene JSON + layer PNGs | `FriezeScene.load(named:)` → `Assets/Friezes/` |
| Tuning | compile-time constants, shadowed at runtime | `Core/Constants.swift` ← `EngineOverrides` |

Two consequences worth internalising:

- **Art is swappable without a rebuild.** Every lookup is by name through the
  bundle, which is why `Tools/asset_audit.py` exists: a typo or a missing `@3x`
  is otherwise invisible until you look at a device.
- **The engine has a machine surface.** Anything the editors can do, a program
  can do, through the same validated command API — see §9.

---

## 3. Build a level, end to end

A level is a file. `Assets/Levels/<name>.json`, format `level/1`:

```json
{
  "format": "level/1",
  "name": "grove",
  "order": 10,
  "title": "Sunlit Grove",
  "frieze": "forest_backdrop",
  "timeOfDay": 0.4,
  "rows": ["...........F..",
           "..S........X..",
           "XXXXXXXXXXXXXX"]
}
```

`order` is the sort key and it is sparse (10, 20, 30…) so you can drop a level
*between* two others without renumbering anything. `frieze` and `timeOfDay` are
per level, so every level no longer has to look like the same place. Only
`format`, `name`, `order` and `rows` are required.

Row 0 is the top. One character is one 40pt tile:

```
terrain: `.` empty                 `X` ground                `/` slope up-right
         `\` slope up-left         `P` one-way platform      `M` moving platform
         `>` conveyor right        `<` conveyor left         `!` spring
         `D` crate                 `L` climbable vine        `~` updraft
hazard:  `#` crusher               `^` crystal
pickup:  `C` coin
marker:  `@` checkpoint            `S` spawn                 `F` goal portal
actor:   `E` enemy                 `N` villager              `B` bird
         `K` boss
```

`.` and a space both mean empty — write whichever reads better, `normalize` folds
them to `.`. That legend is generated from `TileSymbol.legend`, which is the
single authority: the editor palette, the AI planner's constraints and this table
all come from it, and `LevelRulesTests` pins it.

### Draw it — and the editor writes the file

```bash
make editor          # LevelEditor.html + the bridge on :8787
```

Give the level a **name**, **title** and **order** in the toolbar, then **💾 Save**.
The editor POSTs to the local bridge, which validates the document exactly as the
game will and writes `Assets/Levels/<name>.json`. A browser can't write to your
repository, so that loopback process is the mechanism — but the effect is what you
want: the editor *is* the pipeline, not a thing you copy out of.

- The picker lists the level files on disk, so you open and re-save real content.
- Design warnings never block a save. A level in progress is normal.
- An `order` clash is refused with a free slot suggested, because two levels in
  one slot would order unpredictably between runs.
- **⚡ Live** applies the level to the running game immediately, without a rebuild
  — a level *file* needs a build to enter the bundle, and waiting for one breaks
  the rhythm while you are iterating on shape.

### Or type it

Write the JSON by hand; `make run` picks it up. Migrating levels that are still
Swift literals:

```bash
.venv/bin/python Tools/level_export.py      # World/Levels.swift → Assets/Levels/*.json
```

`Levels.builtIn` stays as the fallback, so a build with no level files is still a
playable game — the same rule the rig and backdrop loaders follow.

### Curved terrain — frises

A tile grid quantises ground to 40pt steps, so every slope is a staircase. A
**frise** is spline-extruded, textured, collidable geometry — the tool UbiArt was
built around:

```json
"frises": [
  { "kind": "ground", "texture": "cliff", "cap": "grass", "thickness": 120,
    "points": [[-40, 90], [180, 118], [380, 96], [560, 130], [900, 86]] },
  { "kind": "decor", "depth": 0.24, "thickness": 200, "points": [[-60, 250], ...] }
]
```

- **Catmull-Rom**, so the curve passes *through* your points — you place ground
  where you want ground, not where a tangent handle goes.
- **`kind`** is `ground` (collides), `platform` (one-way, jump up through) or
  `decor` (no collision — painted spline geometry for the backdrop, which is what
  a UbiArt backdrop actually is).
- **Collision comes from the same outline as the fill**, via
  `SKPhysicsBody(edgeChainFrom:)`. What you see is exactly what you stand on, and
  the existing slope code projects along the contact normal, so a curved hill runs
  correctly with no new gameplay logic.
- Extruding further than the tightest turn would fold the band through itself;
  that is **refused with the numbers**, not drawn as a knot.

Terrain textures tile in both directions and are generated: `make terrain` paints
`cliff`, `soil`, `grass`, `trunk`, `stone`.

`Assets/Levels/bluffs.json` is a level whose floor is *entirely* spline — no `X`
glyph anywhere — and it satisfies the same design rules as a tiled one. That works
because a frise declares its **footprint**: the grid cells the curve fills. The
tile grid stays the authority for reachability, so the geometry tells it where the
floor is rather than the validator guessing.

### The rules are checked, not assumed

```bash
make verify                                        # every level file + the fallback
.venv/bin/python Tools/ai_director.py levels       # what the game will load, in order
.venv/bin/python Tools/ai_director.py validate --all
```

`LevelRules.validate` runs a reachability flood-fill using the player's *actual*
movement envelope — walk, jump (3 up / 4 across), dash (7 across), spring (8 up),
lift columns, drops. So "the goal is unreachable" is a one-second offline answer
rather than a playtest discovery, and the editor shades every reachable tile so an
orphaned ledge is visible before you run anything. It also names any unknown
glyph and where it is, because a typo otherwise builds as empty air and silently
deletes a platform.

### Or describe it

```json
{"commands": [
  {"op": "setLevel", "rows": ["S    C   F", "XXX  XX  XX"]},
  {"op": "fillRegion", "col": 3, "row": 8, "width": 4, "height": 1, "symbol": "X"},
  {"op": "setTile", "col": 7, "row": 7, "symbol": "!"}
]}
```

```bash
.venv/bin/python Tools/ai_director.py plan --brief "a vertical spring level"
.venv/bin/python Tools/ai_director.py validate mylevel.json
.venv/bin/python Tools/ai_director.py install  mylevel.json
```

A DEBUG build watches its `Documents/` folder and applies the file on write, and
the **receipt** in `Documents/EngineOut/receipt.json` says what applied, what was
refused *and why*, plus design warnings on the result. Edits to several levels
coexist, so an agent can hold a whole game in flight.

## 4. Build a character animation, end to end

This is the part that usually needs an artist and an animator. It doesn't here.

### Generate art and a rig

```bash
.venv/bin/python Tools/art_director.py --preview
```

Out comes a full skeletal character: `hero_body@2x/@3x.png` and friends, plus
`hero_rig.json` containing bones, slots, weighted meshes and **ten clips** — idle,
run, jump, **fall, land, dash, climb**, punch, hurt, **victory** — with Bézier
easing and mesh deform, driven by a **state machine with blend trees**
(`AnimGraph`): `run` is speed-parameterised so the cycle matches the ground instead
of sliding, `air` blends rise→fall across the apex by vertical velocity, and
one-shots leave on `clipFinished` rather than on hand-rolled timers. `hero_preview.png` shows it composited the way the game
will.

Rise and fall are separate clips on purpose: one held "jump" pose through the
whole arc is what makes airborne motion look weightless, and a landing with no
impact frame is the next thing you notice. `SkeletalPlayer` degrades to a clip the
rig actually has, so an older hand-authored rig with only the original five still
animates rather than freezing.

Art is emitted at **6 pixels per scene point**, not the 3 that an `@3x` suffix
implies. The reason: the scene is authored at 844×390 and scaled `.aspectFill`,
so an iPad Pro needs 5.3 px per scene point before the screen scale even applies.
A plain `@3x` asset is magnified on every current device — which is what "the art
looks soft" actually is. `Tests/AssetTests` fails the build if any character asset
drops below 3.3.

### Or ingest art from an image model

```bash
.venv/bin/python Tools/ai_director.py art  --brief "grumpy jungle frog, Rayman style"
.venv/bin/python Tools/art_director.py ingest sheet.png --grid 3x2
```

`ingest` cuts a character sheet into parts, matches them to the rig's body plan by
position and size, and writes the tiers — so a real image model's output drives the
same rig the generator produces. It refuses to upscale: if the source is thinner
than 6 px/pt it says so rather than inventing detail.

`--grid` is now a *correction*, not a requirement: the gutters in a spaced parts
sheet are detected automatically. The detector is deliberately conservative — it
requires at least two columns, four cells, and near-full occupancy of the detected
blocks, because a drawn figure with spread arms also splits into three columns and
slicing that as a grid would cut the character up. When it isn't confident it
falls through to connectivity and says so.

### Author the motion

```bash
make editor      # Tools/RigEditor.html
```

Setup mode places bones; Animate mode gives per-channel lanes, a **Bézier curve
editor** per key, and a motion trail. It writes the same `hero_rig.json` the
loader reads, so there is no import step.

### Wire it into gameplay

Nothing to wire. `PlayerRigFactory.make()` returns the skeletal rig when its JSON
and art are bundled and the procedural one otherwise, and `GameScene` never
learns which it got. Clips are played by name:

```swift
node.play("run", loop: true)
node.play("jump", track: 1, additive: true, alpha: lean)   // procedural layering
node.setMix(from: "idle", to: "run", duration: 0.12)       // crossfade
```

### Collision that follows the deformation

```json
{"op": "setColliderMode", "mode": "perSlot"}
{"op": "showColliders", "value": true}
```

`box` is the shipped default. `hull` wraps the whole deformed rig in one convex
hull; `perSlot` gives each deforming limb its own, so a punch at full extension
reaches further than the character box and a wind-up doesn't connect.
`attackRegion` is what gameplay asks for the fist.

---

## 5. Backdrops from a reference image

```bash
.venv/bin/python Tools/ai_director.py reference myframe.png --name jungle
```

It measures the frame — k-means palette, sky gradient, haze, light angle — turns
that into a frieze spec, paints the layers, and writes both the scene JSON and a
composite preview that goes through the same haze, depth-of-field and z-order the
runtime does. So you judge the picture, not a pile of loose layers.

Each layer declares its own `density`, derived from the depth-of-field blur it
will receive: layers at the gameplay plane are sharp, far layers that get blurred
at load are not paid for twice. Drop the output in `Assets/Friezes/` and
`{"op": "loadFrieze", "name": "jungle"}` switches to it live.

---

## 6. Sound

```bash
make audio       # every effect and every music track, synthesized from scratch
.venv/bin/python Tools/audio_director.py --list
.venv/bin/python Tools/audio_director.py --only jump,coin
```

No samples and no licensing — 16 effects and 6 music themes are generated from
parameters, so a new sound is a few lines rather than a purchase. Effects are
written as *pitch gestures* (a jump is a rising sweep, a hurt is a falling one, a
coin is two steps up a fifth) because the gesture is what reads; the waveform
barely matters at 0.2 seconds.

Music loops are made seamless the same way the backdrop layers are — fold the
decaying tail back over the head so the wrap lands mid-phrase. Levels name their
own track:

```json
{ "music": "theme_grove" }
```

On the engine side `Audio` gives you a pooled effect player (so two coins can
overlap), persisted **music and effect volumes**, crossfaded track changes, and
`duck(to:for:)` for a boss hit that has to cut through. A missing file is silence,
never a crash — which is exactly why `AssetTests` and the audit walk
`Audio.soundNames` and `Audio.musicNames` against the bundle: a typo is otherwise
indistinguishable from a sound nobody has made yet.

## 7. Look: post-processing and the atlas

```bash
make atlas       # pack rig art into one page: 7 binds/frame become 1
make terrain     # tiling terrain textures for frises
```

Painted 2D reads as cheap without a post chain, because nothing blooms and nothing
ties the palette together. `PostProcess` is one fragment pass over the composited
frame: bright-pass bloom, exposure/tint/contrast/saturation grading, vignette,
chromatic aberration, and a barrel distortion for impacts. Levels pick a grade the
same way they pick a backdrop:

```json
{ "grade": "evening" }
```

`grove`, `hollow`, `evening`, `arena`, `neutral` — and `neutral` disables the chain
entirely, so a grade with nothing switched on costs nothing. `setGrade` and
`setPostProcess` are live commands, so A/B-ing a look needs no rebuild.

The cost worth knowing: `SKEffectNode` renders its subtree to an intermediate
texture sized to that subtree, which for a 50-tile level is about four screens.
That is the price of a single-pass chain in SpriteKit and it is why
`setPostProcess` exists.

The **packed atlas** is the other half. `Tools/atlas_packer.py` (MaxRects) packs one
density tier into a page and writes a frame map; `PackedAtlas` hands out
`SKTexture(rect:in:)` sub-textures, so a character costs one texture bind instead
of seven. Packed **untrimmed** on purpose — a trimmed frame is smaller than the
image it came from, so using it would need a per-attachment correction that nothing
applies; `PackedAtlas` refuses a trimmed page rather than mis-drawing it.

## 8. Themes — every place the engine can paint

```bash
make themes                 # all six: props, terrain surfaces, backdrop
make themes THEME=jungle    # just one
```

Six themes ship — **forest, jungle, ridge, sky, cave, shore** — and each one is a
complete, coherent asset set: a palette, a sky gradient, tiling terrain surfaces, a
prop family, a layer stack with prop scatters and painted spline geometry, and a
colour grade. Adding a seventh is one entry in `THEMES`.

Everything is **hi-res raster at 6 px per scene point** — props and terrain at the
gameplay-plane density, backdrop layers at density-per-depth because the loader
blurs them. `make cook` fails the build if any of it regresses.

What makes the art read as painted rather than printed, because the first version
did not:

- **Hue shifts with light.** Shadows go cool and blue, lights go warm and yellow.
  Measured hue spread went from 0.004 (every pixel the same colour at different
  brightness — the definition of muddy) to 0.060.
- **Vivid palettes.** Good shading of an olive still gives an olive; base colours
  are pushed in HSV first. Saturation went from 0.36 to 0.57.
- **A second tone per asset.** Fern tips run lime while the base stays emerald;
  rock facets alternate hue. One hue plus light and shade is still one colour.
- **Ink outlines**, in a dark tinted version of the local colour rather than black —
  the Rayman signature, and what lets a prop read against a busy backdrop.
- **Volume and rim light**, so a leaf is a form rather than a sticker.

## 9. The machine surface

Read the schema, read the state, send commands, read the receipt:

```bash
.venv/bin/python Tools/ai_director.py state       # what the engine currently is
.venv/bin/python Tools/ai_director.py plan --brief "a vertical spring level"
```

- `EngineSchema` is **self-describing** — every op, its parameters and their legal
  ranges — so an agent discovers the API instead of being told it.
- `EngineSnapshot` reports the level, a tile histogram, tuning (shipped *vs.*
  overridden), lighting, collision mode and every actor's clips, bones and skins.
- Every numeric parameter is validated and **clamped, not refused**: gravity −900
  becomes −60, because a caller that asked for "much heavier" should get the
  strongest legal answer rather than a dead end.
- `EngineOverrides.snapshot()` / `.restore()` brackets an experiment exactly, which
  is what makes automated tuning safe to run.

Full reference: [`ENGINE_API.md`](ENGINE_API.md).

---

## 10. What to run before you push

```bash
make verify      # ~1s, no Xcode: assets, level rules, rig data
make test        # the Swift suites
```

The suites are deliberately about the things that fail *quietly*:

| Suite | Guards |
|---|---|
| `LevelRulesTests` | the legend, and that every shipped level satisfies its own rules |
| `GeometryTests` | hull winding (an inside-out physics body), SAT symmetry, MTV axis choice, convex decomposition |
| `PlayerMotionTests` | movement precedence — dash beats spring, ledge grab needs falling, slopes project |
| `EngineAPITests` | that bad input clamps or is rejected with a reason, never traps (`1e400` → `Int` is a real crash) |
| `LevelFileTests` | that every level file loads, orders uniquely, and names a backdrop and track that exist |
| `AnimGraphTests` | transition priority, `clipFinished` timing, blend weights summing to 1, monotonic apex blend |
| `FriseTests` | that a curve passes through its points, that the extrusion doesn't self-intersect, and that a spline-floored level validates |
| `AssetTests` | that art resolves, at every scale, dense enough not to be magnified; that every sound is bundled |

---

## 11. Where things live

```
App/            SwiftUI entry point
Core/           tuning constants, physics categories, audio
Actors/         player rigs (procedural + skeletal), movement state machine
Scenes/         GameScene, MenuScene
World/          level format + library, tile legend + design rules, interactables
FX/             particles
FriezeKit/
  Core/         EngineAPI (write) + EngineQuery (read) — the machine surface
  Anim/         skeleton, animation, state machine + blend trees, mesh skinning,
                deformed collision, rig loader
  Frieze/       parallax backdrop model, baker, stage, spline frises
  Render/       normal-mapped lighting, day cycle, post chain, packed atlas
Assets/         Levels/, Rigs/, Friezes/, Audio/ — all resolved by name at runtime
Tools/          art_director, audio_director, ai_director, atlas_packer,
                level_export, asset_audit, genproject, the two editors
Tests/          the suites above
```

---

## 12. Known gaps

Stated plainly so you don't discover them at a bad moment:

- **No spatial audio.** Volume and ducking exist; panning by screen position does
  not. `Audio.play(_:on:)` still takes the node for exactly that reason.
- **No in-game editing.** You author outside the game and reload. The ⚡ Live
  button makes that loop about two seconds, but there is no in-place camera or
  drag-a-platform-while-playing.
- **Backdrop art is procedural.** The painter produces a credible backlit jungle,
  not an artist's frame. The path to genuinely reference-quality art is the
  image-model ingest in §4, not the procedural painter.
- **iPhone and iPad only, deliberately.** `SUPPORTS_MACCATALYST`,
  `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` and the visionOS equivalent are all
  explicitly `NO`, and `SUPPORTED_PLATFORMS` is `iphoneos iphonesimulator`. The
  whole presentation is built on a 844×390 scene scaled `.aspectFill`, touch
  controls, and asset densities derived from iOS screen scales — Mac or tvOS would
  need a different input model *and* a different density policy, and a
  half-supported platform is worse than an unsupported one.
- **Device builds need a team.** Signing is off by default so a clean machine can
  build for the simulator; `SKYRUNNER_TEAM=ABCDE12345 make archive` switches it on
  without editing `project.yml`.
