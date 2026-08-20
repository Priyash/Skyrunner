# Engine API — driving SkyRunner from a program

The engine has no hidden control path. Everything the editors can do, a program
can do by sending a JSON document; everything the engine knows, it will hand
back as JSON. That is the whole surface, and it is deliberately small.

```
   ai_director.py ─┐                            ┌─▶ EngineOut/receipt.json
   LevelEditor.html├─▶ Documents/engine.json ─▶ engine ─▶ EngineOut/state.json
   RigEditor.html  ┘        (commands)          │      └─▶ EngineOut/schema.json
   your script ────┘                            └─▶ live scene
```

| File | Role |
|---|---|
| `FriezeKit/Core/EngineAPI.swift` | the write half — vocabulary, validation, interpreter |
| `FriezeKit/Core/EngineQuery.swift` | the read half — schema, world snapshot, file transport |
| `World/LevelRules.swift` | the tile alphabet and design rules, as data |
| `Tools/ai_director.py` | brief → validated document; the localhost bridge |
| `Tools/art_director.py` | art spec → Rayman-style PNGs + Spine rig |

## The document

```json
{
  "version": 1,
  "commands": [
    {"op": "setLevel", "rows": ["..S.....F...", "XXXXXXXXXXXX"]},
    {"op": "setTimeOfDay", "t": 0.85},
    {"op": "setColliderMode", "mode": "perSlot"}
  ]
}
```

Drop it at `Documents/engine.json`. In DEBUG the game watches that folder, applies
the document, and writes a receipt. Commands apply in order; one bad command is
rejected with a reason and the rest still run.

### Ops

| Op | Parameters | Effect |
|---|---|---|
| `setLevel` | `rows[]` | replace the current level's map (row 0 = top) |
| `setTile` | `col`, `row`, `symbol` | write one tile |
| `fillRegion` | `col`, `row`, `width`, `height`, `symbol` | write a rectangle (`.` erases) |
| `setSpawn` | `col`, `row` | move the spawn, clearing the old `S` |
| `spawnActor` | `kind`, `col`, `row` | place `enemy`/`villager`/`bird`/`crate`/`coin`/`boss` |
| `loadFrieze` | `name` | swap the backdrop scene |
| `setLighting` | `warm[]`, `cool[]`, `ambient` | retint the key and rim lights, live |
| `setTimeOfDay` | `t` 0…1 | dawn → noon → dusk in one dial |
| `playAnimation` | `actor`, `clip`, `track`, `loop` | play a clip on a rig |
| `setAnimationMix` | `from`, `to`, `duration` | crossfade time between two clips |
| `setColliderMode` | `mode`, `slots[]` | `box` / `hull` / `perSlot` collision |
| `setSkin` | `actor`, `skin` | swap a rig's attachment set (costume, damage state) |
| `setGravity` | `value` −60…−4 | world gravity |
| `setRunSpeed` | `value` 60…700 | player speed |
| `setJumpVelocity` | `value` 300…1600 | jump impulse |
| `setCameraLead` | `value` 0…0.6 | seconds of velocity the camera looks ahead |
| `showColliders` | `value` | debug draw: physics bodies + deformed hulls |
| `reset` | — | drop every override; back to the shipped game |
| `reload` | — | rebuild the scene with the current overrides |

The engine publishes this same table, with live ranges, to
`EngineOut/schema.json` — read that rather than trusting this page, and a
producer written against it can never use an op this build doesn't have.

### Receipts

```json
{ "applied": ["setLevel(9 rows)", "setTimeOfDay(0.85, 2 light(s))"],
  "rejected": ["command 3 (setTile): col out of range"],
  "warnings": ["goal at (44,7) is not reachable from the spawn"],
  "needsReload": true,
  "summary": "applied 2, rejected 1, 1 warning(s) (scene reload required)" }
```

`rejected` means refused, and says why. `warnings` are design-rule violations on
the *result* — the engine builds what it was told and reports what it thinks of
it. That split is what lets a program correct itself: apply, read the warnings,
send a fix.

### Snapshot

`EngineOut/state.json` carries the level rows, the tile histogram, effective
tuning (with the shipped value alongside, so you can see what's overridden),
lighting, collider state, every named actor with its rig's clips and bones, and
the current rule report. It is the input a director reads before deciding
anything.

## Safety

The surface is declarative on purpose. Commands name intents with typed
parameters — there is no eval and no path from JSON to arbitrary behaviour, so a
malformed or hostile document can at worst produce a silly level.

* Numbers are range-checked; non-finite values are rejected at the door (JSON
  may carry `1e400`, and `Int(CGFloat.infinity)` traps in Swift).
* Names are held to an identifier alphabet — they cross into bundle-resource
  lookups.
* Physics is clamped hard: out-of-range values make the game unplayable rather
  than merely odd.
* Nothing mutates the compiled tables. Every effect lands in `EngineOverrides`,
  so `reset` restores the shipped game exactly, and `snapshot()`/`restore(_:)`
  bracket an experiment.
* The document watcher is DEBUG-only, like `HotReloader`.

## Driving it with AI

```sh
export ANTHROPIC_API_KEY=…            # optional; without it an offline composer answers

# a level, validated before it lands
python3 Tools/ai_director.py plan "a windy cliff level, three jumps, a boss at dusk" --install

# a character: Rayman-style art *and* the Spine rig that animates it
python3 Tools/ai_director.py art "a grumpy purple forest sprite" --out Assets/Rigs

# read back what the engine made of it
python3 Tools/ai_director.py state

# and the bridge the HTML editors talk to
python3 Tools/ai_director.py serve
```

Three things keep this honest rather than a slot machine:

1. **The engine describes itself.** The op list, ranges and tile alphabet come
   from `EngineOut/schema.json`, so the model is constrained by *this build's*
   vocabulary and never a stale prompt.
2. **Structured output.** Responses are schema-constrained by the API, then
   re-validated locally before anything reaches the engine.
3. **A closed loop.** Generated levels are checked against the design rules
   offline — including an optimistic reachability flood-fill from the spawn — and
   violations go back to the model once as a repair brief.

With no API key every path still runs: `plan` and `art` fall back to a
deterministic composer, so the pipeline is demonstrable offline and tests have
something stable to assert on. Same choice `AdsManager` makes with its stub ad
network.

### Art generation

An image model returns pixels, and pixels alone can't be animated — a rig needs
parts on transparent backgrounds, consistent pivots, bone lengths that match the
art, and mesh weights. So the model writes the *art direction* and
`art_director.py` paints it and builds the rig:

```
brief ─▶ art-spec/1 ─▶ art_director.py ─┬─▶ <name>_<part>@2x/@3x.png
                                        ├─▶ <name>_rig.json   (Spine subset)
                                        └─▶ <name>_preview.png
```

The rig is the same dialect `RigLoader` already reads: bones (with detached
limbs and spring tags), slots, skins, **weighted mesh attachments**, and clips
carrying Bézier curves and mesh deform. So generated art is animated by
`SkeletonNode`, collides through `DeformedCollider`, and opens in
`Tools/RigEditor.html` for hand-tuning — no one-way export anywhere.

`Tools/composer.py` remains the backdrop generator; `loadFrieze` swaps between
the scenes it writes.

## Editors

Both editors are static files that never hold an API key. Their **Generate**
panels call the loopback bridge, which owns the key, constrains the model, and
validates the reply.

| Editor | Generates | Then |
|---|---|---|
| `Tools/LevelEditor.html` | a level from a brief | paint over it, watch the rule panel, ▶ To game |
| `Tools/RigEditor.html` | art + Spine rig from a brief | tune curves on the keys, export JSON |

`serve` binds to `127.0.0.1` only — the key lives in that process and nothing is
exposed off the machine.

## Working from a reference frame (no design skill required)

```sh
# 1. Point it at a frame you like. Palette, sky gradient, haze and light
#    direction are MEASURED from the pixels; vision (when a key is present)
#    names the layer structure and proposes a level.
python3 Tools/ai_director.py reference rayman_shot.png --out Assets/Friezes

#    → <name>.friezespec.json      the art direction, editable
#    → <name>_*@2x/@3x.png         7 backdrop layers (glow, ridge, fog, trunks,
#                                  canopy, vines)
#    → <name>.json                 the FriezeScene FriezeStage loads
#    → <name>_scene.png            the composite, exactly as the game shows it
#    → <name>_hero_*               a character in the same palette, rigged
#    → <name>.engine.json          a level in the spirit of the frame

# 2. Iterate visually in the editor, then send it to the running game
open Tools/LevelEditor.html                 # brief → level → ▶ To game
python3 Tools/ai_director.py serve           # the bridge the editor talks to
```

### Getting art that matches a reference, not just its palette

The procedural painter is a stand-in and says so. Reference-grade painted art
comes from an artist or an image-generation model — so the pipeline is built to
*ingest* that rather than pretend to replace it:

```sh
# Ask an image model for a spaced parts grid on a flat background:
#   "seven separate pieces — body, head, hair tuft, two hands, two feet —
#    arranged in a 4x2 grid, spaced apart, flat magenta background,
#    hand-painted Rayman Legends style, <your palette>"
python3 Tools/art_director.py --ingest sheet.png --grid 4x2 --name jungle_hero \
    --out Assets/Rigs
```

That cuts the background out by flooding from the border (so a white eye stays
white), slices the grid, scales the art so body + head match the shipped rig's
proportions, and writes per-part PNGs plus a weighted-mesh Spine rig with five
clips. The result animates, collides through its deformed hulls, and opens in the
rig editor — the art is the only thing that changed.

Without `--grid` it will try to split by connectivity, which works for pieces
that don't touch and tells you when they do.

## Tile alphabet

22 symbols. `EngineOut/schema.json` publishes the same table with each tile's
support rules, so a producer never has to hard-code it.

| | | | |
|---|---|---|---|
| `X` ground | `/` `\` 45° slopes | `P` one-way | `M` moving platform |
| `>` `<` conveyors | `!` spring (~8 tiles up) | `L` climbable vine | `~` updraft column |
| `#` crusher | `D` crate | `^` crystal | `@` checkpoint |
| `S` spawn | `F` goal | `K` boss | `C` coin |
| `E` enemy | `N` villager | `B` bird | `.` empty |

The movement envelope the validator checks against: 3 tiles up and 4 across per
jump, 7 across with a dash, 8 up off a spring, and free vertical travel inside a
vine or updraft column. All of it derived from `Tuning`, so changing the jump
height changes what the validator accepts.
