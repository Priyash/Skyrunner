# Sky Runner — 2D Platformer (SpriteKit)

A complete, monetization-ready iOS platformer. Native Swift + SpriteKit — no
Unity, no third-party dependencies required to build and run.

**What's included**
- 4 levels as data (`Assets/Levels/*.json`, written by the visual editor;
  `Levels.builtIn` is the compiled fallback)
- Run / jump with coyote time + jump buffering (feels fair, not floaty)
- Coins, patrolling stompable enemies, spikes, fall deaths, finish flag
- Lives system, respawn, game-over flow with **rewarded-ad revive**
- Camera follow with level-bounds clamping, on-screen multi-touch controls
- Coin + level-unlock persistence (`UserDefaults`)
- **StoreKit 2 IAP**: Remove Ads (non-consumable) + 500 Coins (consumable), with restore
- **Ad abstraction**: interstitial-between-levels + rewarded revive, shipped as a
  working stub so the game runs with zero SDKs; AdMob swap-in steps documented
  in `AdsManager.swift`

---

## 1. Run it

```bash
make doctor      # is the toolchain usable? run this first
make run         # generate project → build → boot simulator → launch
```

There is no `.xcodeproj` in the repository: `project.yml` is the source of truth
and the project is generated from it, so adding a Swift file needs no project
edit and no merge conflict. `make project` uses XcodeGen when installed and the
bundled `Tools/genproject.py` otherwise, so a missing brew install is never the
reason you can't build.

Controls: ◀ ▶ move, ▲ jump (hold = higher; hold while falling = helicopter
hover; press against a wall while falling = wall slide, then ▲ again = wall
jump), ● = punch on the ground / ground pound in the air, ⇢ = dash.

Full walkthrough — including authoring a level and a character animation end to
end — is in **[GETTING_STARTED.md](GETTING_STARTED.md)**.

## 2. Test IAP locally (no App Store Connect needed yet)

1. **File ▸ New ▸ File ▸ StoreKit Configuration File** → name it `Store.storekit`.
2. Add two products (IDs must match `Constants.swift`, or edit the constants):
   - Non-consumable: `com.yourcompany.platformer.removeads` — e.g. $2.99
   - Consumable: `com.yourcompany.platformer.coins500` — e.g. $0.99
3. Edit Scheme ▸ Run ▸ Options ▸ **StoreKit Configuration** → select `Store.storekit`.
4. Run → Menu → "Remove Ads" / "Buy 500 Coins" now use the local test store.

## 3. Go live with real ads

Follow the numbered steps at the top of `AdsManager.swift` (add the AdMob SDK
via SPM, set `GADApplicationIdentifier` + SKAdNetwork entries in Info.plist,
replace the two stub methods). The rest of the game never changes — the ad
network is fully isolated behind that one class.

## 4. Ship to the App Store

1. Enroll in the **Apple Developer Program** ($99/yr) if you haven't.
2. In **App Store Connect**: create the app, then create the two IAPs with the
   exact product IDs above (they must be submitted *with* your first build).
3. Replace `com.yourcompany` everywhere with your real bundle-ID prefix.
4. Add an app icon (Assets.xcassets → AppIcon; 1024×1024 source).
5. **App Privacy** section: if you ship AdMob, declare ad-related data
   collection; for personalized ads you also need the AppTrackingTransparency
   prompt. With the stub (no ads/tracking), you can declare "no data collected."
6. Screenshots: 6.9" and 6.5" iPhone sizes minimum. Capture from Simulator
   (⌘S) while playing.
7. Product ▸ Archive → Distribute → App Store Connect → submit for review.
   Typical review time: 1–2 days.

## 5. Extend it

- **New level**: append a `[String]` block in `Levels.swift`. The menu and
  unlock chain adapt automatically. Design rules are documented at the top of
  that file (the engine assumes them).
- **Art**: the entire cartoon look is PAINTED procedurally at device
  resolution in `Painter.swift` — shaded spheres with glossy highlights for
  every character part, speckled dirt with grass blades, wood-grain crates,
  beveled coins, faceted crystals, rim-lit parallax ridges, and dithered sky
  gradients. `UIGraphicsImageRenderer` inherits the screen scale, so all of
  it renders @2x/@3x automatically with zero image assets. To swap in drawn
  art later, each visual still lives behind one builder function in
  `Decor.swift`.
- **Tuning**: all game-feel numbers live in `Constants.swift` with the physics
  math explained in comments.
- **Analytics** (do this before launch): add Firebase via SPM and log
  `level_start`, `level_complete`, `player_death`, `ad_reward_granted`,
  `iap_purchase`. D1/D7 retention is the number that tells you if the game
  is worth marketing.


## FriezeKit — hi-res painted backdrop engine (UbiArt-style)

`FriezeKit/` is a small layer-presentation runtime: hi-res painted PNG
layers + a JSON scene file → deep parallax with baked atmosphere. The
authoring/preview tool is the Python composer (offline); the runtime is
three Swift files. All expensive work (haze tinting toward the sky color,
depth-of-field blur by distance from the focal plane) is baked ONCE at load
via Core Graphics/Core Image — at runtime every layer is a plain sprite and
the per-frame cost is one multiply-add per layer, so it holds 60–120fps.

Setup: drag `FriezeKit/` (code) and `FriezeAssets/` (images + JSON) into the
project with your target checked. GameScene auto-detects the bundled
`forest_backdrop` scene and uses it; without the assets it falls back to the
procedural parallax, so nothing breaks either way.

Authoring your own scene: place layer PNGs (@3x) in FriezeAssets, list them
in a JSON with `x`,`y` (points, from screen center), and `depth` 0–1
(0 far, `focus` = gameplay plane, >focus renders in front of gameplay).
Layers that must never show their edges (hills, skies) need width ≥ screen
width + 2 × (max camera travel × depth/focus).

## Editors, and driving the engine from a program

Three authoring tools, all single files with no build step:

| Tool | What it does |
|---|---|
| `Tools/LevelEditor.html` | Visual tile editor: brush/rect/fill, undo, live design-rule checking, a reachability overlay, and the camera viewport drawn over the map. Exports a `Levels.swift` block or an `engine.json` the running game applies. |
| `Tools/RigEditor.html` | Rig and animation editor, now with a **Bézier curve editor** on the right — draggable handles, presets including anticipate and overshoot, and a motion trail that shows what the curve did. Setup/Animate modes; exports Spine-compatible JSON. |
| `Tools/composer.py` | Backdrop (frieze) authoring and preview. |

The engine also exposes a **command API** (`FriezeKit/Core/`): drop a JSON
document in the app's Documents folder and it applies — level edits, lighting,
animation, physics, collision modes — then writes back a receipt, a full world
snapshot, and its own op schema. Everything the editors can do, a script can do.
See `Docs/ENGINE_API.md`.

Both editors can **generate through AI**. `python3 Tools/ai_director.py serve`
runs a loopback bridge that holds the API key (the editors are static files and
never do), constrains the model to the engine's published vocabulary, and
validates the reply before it lands:

```sh
python3 Tools/ai_director.py plan "a windy cliff level, three jumps, a boss at dusk" --install
python3 Tools/ai_director.py art  "a grumpy purple forest sprite" --out Assets/Rigs
```

`art` produces Rayman-style cartoon parts (bold ink outline, radial shading, gloss,
paper grain — rendered 4× and downsampled) **and the Spine 2D rig that animates
them**: bones with detached limbs, weighted mesh attachments, and five clips
carrying Bézier curves and mesh deform. It loads through the shipped
`RigLoader`, collides through the deformed-hull collider, and opens in the rig
editor for hand-tuning. Needs `pip install pillow numpy` for the PNGs.

With no `ANTHROPIC_API_KEY`, a deterministic composer answers instead, so the
whole pipeline still runs offline.

## Project structure

| Folder | Contents |
|---|---|
| `App/` | SwiftUI entry point hosting the SpriteKit view |
| `Core/` | Tuning constants, physics categories, persistence, texture painter |
| `World/` | Level maps + rules, world-piece builders, 9-layer parallax |
| `Actors/` | Player rig, enemy AI state machine, NPCs (villager/bird/butterfly) |
| `Scenes/` | Gameplay scene, world-map menu |
| `FX/` | Particle bursts, dust, floating combo text |
| `Monetization/` | StoreKit 2 IAP, ad abstraction |

`project.yml` globs these directories, so the Xcode groups mirror the
layout automatically and a new file is picked up by `make project`.

## Spec coverage (what's in, what's deferred)

Implemented from the design spec:
- **Controls**: variable jump height (release early = shorter), coyote time,
  jump buffering, helicopter-hair hover (hold jump while falling)
- **Animation**: procedural squash-and-stretch rig, run cycle, lean, landing
  squash + dust, idle breathing, random blinking, rotor-spin hover, cartoon
  stars-circling-head hurt reaction
- **Parallax**: 9 layers — sky, sun, far mountains, clouds, two hill depths,
  gliding bird flocks, light rays, dust motes
- **Enemy AI**: state machine (patrol → alert "!" telegraph → chase → return),
  forward-facing vision, platform-bounded chasing
- **Living world**: waving villagers with speech bubbles, perched birds that
  startle and fly off, wandering butterflies
- **Coins**: magnetic attraction, combo multiplier (up to ×5) with floating
  "+N ×combo" text, sparkle bursts
- **Camera**: predictive velocity lead + smoothing + impact shake
- **Platforming**: moving platforms that correctly carry the player
- **Menu**: world-map style dotted path between level nodes
- **Combat**: Rayman-style punch (● on the ground) and ground pound (● in the
  air) with an area-of-effect landing; breakable crates that drop coins
- **Wall movement**: wall slide with grip animation + wall jump with brief
  steering lock so you launch away cleanly
- **One-way platforms**: jump up through, land on top
- **Boss**: King Blob (level 4) — telegraphed hop-chase pattern, 3 HP, speeds
  up each phase, crown pops off on defeat, victory portal spawns
- **Audio**: 7 synthesized cartoon SFX ship in `Audio/` (jump, coin, stomp,
  hurt, pound, pop, win), bundled automatically. Missing files are silent
  no-ops, never crashes — which is why `AssetTests` walks `Audio.soundNames`
  against the bundle, since a typo would otherwise be undetectable.

Still deferred: frame-by-frame drawn animation & IK blend trees (the
procedural rig stands in), climb/swim, slopes, background music (the SFX are
synthesized; music genuinely wants composed audio), weather/day-night
variants, shops/quests, flocking group AI, additional bosses.
