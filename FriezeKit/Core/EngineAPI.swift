import SpriteKit
import Foundation

/// EngineAPI — the engine's machine-drivable surface.
///
/// Everything a human can do through the editors, a program can do by sending
/// commands: build a level, place friezes, retime lighting, spawn actors, play
/// animations, tune physics. Commands are plain JSON, which makes the natural
/// producer an LLM (see `Tools/ai_director.py`) — but nothing here depends on
/// AI: it is equally a scripting layer, a test harness, and a replay format.
///
/// Design rules that keep this safe:
///  • **Declarative, not executable.** Commands name intents with typed
///    parameters. There is no eval, no code path from JSON to arbitrary
///    behaviour, so a malformed or hostile document can at worst produce a
///    silly level — never run code.
///  • **Validated and clamped.** Every numeric parameter is range-checked
///    before it reaches the engine, and non-finite numbers are rejected at the
///    door: JSON is allowed to carry `1e400`, and `Int(CGFloat.infinity)`
///    traps in Swift.
///  • **Reversible.** Nothing is written to the compiled tables and nothing
///    persists; every effect lands in `EngineOverrides`, so op `"reset"`
///    restores the shipped game exactly and `snapshot()` / `restore(_:)`
///    bracket an experiment.
///  • **Answerable.** `apply` returns a receipt: what landed, what was
///    rejected and why, which level-design rules the result breaks, and
///    whether the scene must be rebuilt. Paired with `EngineQuery` (the read
///    half of this surface) a program can close its own loop — generate,
///    apply, read back, correct — with no human in it.
enum EngineCommand {

    // Level authoring
    case setLevel(rows: [String])
    case setTile(col: Int, row: Int, symbol: Character)
    case fillRegion(col: Int, row: Int, width: Int, height: Int, symbol: Character)
    case setSpawn(col: Int, row: Int)

    // Presentation
    case loadFrieze(name: String)
    case setLighting(warm: [CGFloat], cool: [CGFloat], ambient: CGFloat)
    case setTimeOfDay(t: CGFloat)          // 0 dawn … 1 dusk

    // Actors
    case spawnActor(kind: String, col: Int, row: Int)
    case playAnimation(actor: String, clip: String, track: Int, loop: Bool)
    case setAnimationMix(from: String, to: String, duration: TimeInterval)
    /// Which collision representation animated actors use — the box, one hull
    /// around the whole deformed rig, or a hull per deforming limb.
    case setColliderMode(mode: ColliderMode, slots: [String])
    /// Swap a rig's attachment set — costumes, damage states, seasonal skins.
    case setSkin(actor: String, skin: String)

    // Tuning (safe, clamped subset)
    case setGravity(CGFloat)
    case setRunSpeed(CGFloat)
    case setJumpVelocity(CGFloat)

    // Camera / debug / session
    case setCameraLead(CGFloat)
    case showColliders(Bool)
    /// Switch the post chain on or off — the escape hatch when a device can't
    /// afford it, and the A/B when judging a grade.
    case setPostProcess(Bool)
    /// Pick a named colour grade. The single strongest lever on how a level looks.
    case setGrade(name: String)
    /// Open or close in-engine editing. DEBUG builds only — a release binary has no
    /// editor, and the receipt says so rather than failing silently.
    case editLevel(Bool)
    case reset                             // drop every override
    case reload                            // rebuild the scene as-is
}

/// Result of applying a command batch. This is the whole answer a caller gets,
/// so it carries enough for a program to correct itself: what applied, what was
/// refused *and why*, design-rule warnings on the result, and whether the scene
/// has to be rebuilt for the change to show.
struct EngineReceipt {
    var applied: [String] = []
    var rejected: [String] = []
    /// Level-design rules the resulting map breaks (`LevelRules`). Warnings
    /// never block a command — an unreachable coin is a note, not an error.
    var warnings: [String] = []
    var needsReload = false

    var summary: String {
        "applied \(applied.count), rejected \(rejected.count)"
            + (warnings.isEmpty ? "" : ", \(warnings.count) warning(s)")
            + (needsReload ? " (scene reload required)" : "")
    }

    var jsonObject: [String: Any] {
        ["applied": applied, "rejected": rejected, "warnings": warnings,
         "needsReload": needsReload, "summary": summary]
    }

    /// Receipts are written back to disk for the producer to read, so the loop
    /// closes over the filesystem without any networking (see `EngineBridge`).
    var jsonText: String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"summary":"receipt could not be encoded"}"#
        }
        return text
    }
}

/// Parses and validates a command document. Nothing here touches the engine:
/// parsing is a pure function from bytes to typed, in-range commands, which is
/// what makes the surface testable offline (`Tools/ai_director.py` runs the
/// same rules in Python before it ever writes a file).
enum EngineScript {

    /// The only document version this build accepts.
    static let version = 1

    /// Document shape:
    /// ```json
    /// { "version": 1, "commands": [ {"op": "setTile", "col": 3, "row": 7,
    ///                                "symbol": "X"}, ... ] }
    /// ```
    static func parse(data: Data) -> (commands: [EngineCommand], errors: [String]) {
        var commands: [EngineCommand] = []
        var errors: [String] = []
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["commands"] as? [[String: Any]] else {
            return ([], ["document is not {version, commands:[…]}"])
        }
        // An unknown version is refused rather than best-guessed: a document
        // written for a later vocabulary would apply half of itself.
        if let v = num(root["version"]), Int(v) != version {
            return ([], ["document version \(Int(v)) — this build speaks version \(version)"])
        }
        guard list.count <= 2048 else {
            return ([], ["document exceeds 2048 commands"])
        }
        for (i, raw) in list.enumerated() {
            guard let op = raw["op"] as? String else {
                errors.append("command \(i): missing op"); continue
            }
            switch make(op: op, raw: raw) {
            case .success(let cmd): commands.append(cmd)
            case .failure(let why): errors.append("command \(i) (\(op)): \(why)")
            }
        }
        return (commands, errors)
    }

    static func parse(text: String) -> (commands: [EngineCommand], errors: [String]) {
        guard let data = text.data(using: .utf8) else {
            return ([], ["document is not UTF-8"])
        }
        return parse(data: data)
    }

    // MARK: Typed readers

    /// JSON numbers arrive as `NSNumber`. Rejecting non-finite values *here* is
    /// what lets every `Int(...)` conversion below be safe: `Int(nan)` and
    /// `Int(1e400)` both trap, and a document is allowed to contain either.
    private static func num(_ any: Any?) -> CGFloat? {
        guard let n = any as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        return CGFloat(d)
    }

    /// A map coordinate: finite, non-negative, and inside the documented map
    /// limits. Out-of-range is refused at parse time so the interpreter only
    /// ever bounds-checks against the *actual* level.
    private static func gridIndex(_ any: Any?, limit: Int) -> Int? {
        guard let v = num(any), v >= 0, v <= CGFloat(limit) else { return nil }
        return Int(v)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }

    /// Names cross into bundle-resource lookups and dictionary keys, so they are
    /// held to a plain identifier alphabet. A hostile string then has nothing to
    /// do but fail to resolve — no traversal, no injection.
    private static func identifier(_ any: Any?, dots: Bool = false,
                                  maxLength: Int = 64) -> String? {
        guard let s = any as? String, !s.isEmpty, s.count <= maxLength,
              !s.contains(".."),
              s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
                             || (dots && $0 == ".") })
        else { return nil }
        return s
    }

    /// One tile glyph. A space is accepted and folded to `.`, so "clear this
    /// cell" works however the caller spells it and the stored row stays
    /// canonical.
    private static func symbol(_ any: Any?) -> Character? {
        guard let s = any as? String, s.count == 1, let c = s.first,
              TileSymbol.accepted.contains(c) else { return nil }
        return c == " " ? "." : c
    }

    /// Every op validates its own arguments; unknown ops are rejected, not
    /// ignored, so a typo surfaces instead of silently doing nothing.
    private static func make(op: String, raw: [String: Any]) -> Result<EngineCommand, String> {
        switch op {
        case "setLevel":
            guard let rows = raw["rows"] as? [String], !rows.isEmpty else {
                return .failure("rows must be a non-empty string array")
            }
            guard rows.count <= LevelRules.maxRows,
                  rows.allSatisfy({ $0.count <= LevelRules.maxColumns }) else {
                return .failure("level exceeds \(LevelRules.maxRows) rows / "
                                + "\(LevelRules.maxColumns) columns")
            }
            guard rows.contains(where: { !$0.isEmpty }) else {
                return .failure("level has no columns")
            }
            guard rows.allSatisfy({ $0.allSatisfy { TileSymbol.accepted.contains($0) } }) else {
                return .failure("unknown tile symbol (legal: \(TileSymbol.allowedText))")
            }
            return .success(.setLevel(rows: rows))

        case "setTile":
            guard let c = gridIndex(raw["col"], limit: LevelRules.maxColumns),
                  let r = gridIndex(raw["row"], limit: LevelRules.maxRows),
                  let s = symbol(raw["symbol"]) else {
                return .failure("needs col, row (row 0 = TOP) and a symbol from "
                                + TileSymbol.allowedText)
            }
            return .success(.setTile(col: c, row: r, symbol: s))

        case "fillRegion":
            guard let c = gridIndex(raw["col"], limit: LevelRules.maxColumns),
                  let r = gridIndex(raw["row"], limit: LevelRules.maxRows),
                  let w = gridIndex(raw["width"], limit: LevelRules.maxColumns),
                  let h = gridIndex(raw["height"], limit: LevelRules.maxRows),
                  let s = symbol(raw["symbol"]) else {
                return .failure("needs col, row, width, height, symbol")
            }
            guard w > 0, h > 0 else { return .failure("width and height must be ≥ 1") }
            return .success(.fillRegion(col: c, row: r, width: w, height: h, symbol: s))

        case "setSpawn":
            guard let c = gridIndex(raw["col"], limit: LevelRules.maxColumns),
                  let r = gridIndex(raw["row"], limit: LevelRules.maxRows) else {
                return .failure("needs col, row")
            }
            return .success(.setSpawn(col: c, row: r))

        case "loadFrieze":
            guard let n = identifier(raw["name"]) else {
                return .failure("name must be a simple identifier")
            }
            return .success(.loadFrieze(name: n))

        case "setLighting":
            let warm = (raw["warm"] as? [Any])?.compactMap(num) ?? [1, 0.94, 0.78]
            let cool = (raw["cool"] as? [Any])?.compactMap(num) ?? [0.45, 0.62, 0.95]
            guard warm.count >= 3, cool.count >= 3 else {
                return .failure("colors need 3 components (0…1)")
            }
            let amb = clamp(num(raw["ambient"]) ?? 0.62, 0, 1)
            return .success(.setLighting(warm: warm.map { clamp($0, 0, 1) },
                                         cool: cool.map { clamp($0, 0, 1) }, ambient: amb))

        case "setTimeOfDay":
            guard let t = num(raw["t"]) else { return .failure("needs t (0 dawn … 1 dusk)") }
            return .success(.setTimeOfDay(t: clamp(t, 0, 1)))

        case "spawnActor":
            guard let kind = raw["kind"] as? String,
                  TileSymbol.actorKinds[kind] != nil,
                  let c = gridIndex(raw["col"], limit: LevelRules.maxColumns),
                  let r = gridIndex(raw["row"], limit: LevelRules.maxRows) else {
                return .failure("kind must be one of \(TileSymbol.actorKindList) with col,row")
            }
            return .success(.spawnActor(kind: kind, col: c, row: r))

        case "playAnimation":
            guard let actor = identifier(raw["actor"], dots: true),
                  let clip = identifier(raw["clip"]) else {
                return .failure("needs actor, clip (identifiers)")
            }
            let track = Int(clamp(num(raw["track"]) ?? 0, 0, 4))
            return .success(.playAnimation(actor: actor, clip: clip, track: track,
                                           loop: (raw["loop"] as? Bool) ?? true))

        case "setAnimationMix":
            guard let f = identifier(raw["from"]), let t = identifier(raw["to"]),
                  let d = num(raw["duration"]) else {
                return .failure("needs from, to, duration")
            }
            return .success(.setAnimationMix(from: f, to: t,
                                             duration: TimeInterval(clamp(d, 0, 2))))

        case "setSkin":
            guard let actor = identifier(raw["actor"], dots: true),
                  let skin = identifier(raw["skin"]) else {
                return .failure("needs actor, skin (identifiers)")
            }
            return .success(.setSkin(actor: actor, skin: skin))

        case "setColliderMode":
            guard let name = raw["mode"] as? String,
                  let mode = ColliderMode(rawValue: name) else {
                return .failure("mode must be one of \(ColliderMode.allNames)")
            }
            let slots = ((raw["slots"] as? [Any])?.compactMap { identifier($0, dots: true) }
                         ?? []).prefix(32)
            return .success(.setColliderMode(mode: mode, slots: Array(slots)))

        // Physics is clamped hard: an out-of-range value makes the game
        // unplayable rather than merely odd.
        case "setGravity":
            guard let v = num(raw["value"]) else { return .failure("needs value") }
            return .success(.setGravity(clamp(v, -60, -4)))
        case "setRunSpeed":
            guard let v = num(raw["value"]) else { return .failure("needs value") }
            return .success(.setRunSpeed(clamp(v, 60, 700)))
        case "setJumpVelocity":
            guard let v = num(raw["value"]) else { return .failure("needs value") }
            return .success(.setJumpVelocity(clamp(v, 300, 1600)))
        case "setCameraLead":
            guard let v = num(raw["value"]) else { return .failure("needs value") }
            return .success(.setCameraLead(clamp(v, 0, 0.6)))
        case "showColliders":
            return .success(.showColliders((raw["value"] as? Bool) ?? true))
        case "editLevel":
            return .success(.editLevel((raw["value"] as? Bool) ?? true))
        case "setPostProcess":
            return .success(.setPostProcess((raw["value"] as? Bool) ?? true))
        case "setGrade":
            guard let name = raw["name"] as? String, !name.isEmpty else {
                return .failure("needs name")
            }
            guard PostProcess.Grade.named[name] != nil else {
                return .failure("unknown grade '\(name)' (have "
                                + PostProcess.Grade.named.keys.sorted()
                                    .joined(separator: ", ") + ")")
            }
            return .success(.setGrade(name: name))
        case "reset":
            return .success(.reset)
        case "reload":
            return .success(.reload)

        default:
            return .failure("unknown op")
        }
    }
}

/// Runtime-tunable values the API is allowed to touch. Kept separate from
/// `Tuning` (which stays a compile-time constant table) so scripted changes are
/// always reversible by discarding this object — and so the shipped game's feel
/// can never be edited by accident, only shadowed.
final class EngineOverrides {
    static let shared = EngineOverrides()
    private init() {}

    // Tuning
    var gravity: CGFloat?
    var runSpeed: CGFloat?
    var jumpVelocity: CGFloat?
    var cameraLead: CGFloat?

    // Presentation. `timeOfDay` is the coarse dial; explicit colours win.
    var warm: [CGFloat]?
    var cool: [CGFloat]?
    var ambient: CGFloat?
    var timeOfDay: CGFloat?
    var friezeOverride: String?
    /// What the current level *file* asked for. A `setTimeOfDay` command still
    /// wins — an explicit instruction should not be overruled by content — but
    /// without one a level authored as an evening loads as an evening.
    var levelTimeOfDay: CGFloat?
    /// Post chain on/off and the grade in force. Kept here so a reload rebuilds
    /// the scene with the look the caller asked for rather than the level default.
    var postProcess = true
    var grade: String?

    // Debug / collision
    var showColliders = false
    var colliderMode: ColliderMode = .box
    /// Slots the collider tracks; empty = every mesh slot in the rig.
    var colliderSlots: [String] = []

    /// Which level the scene is currently building. Level edits address *this*
    /// level, and the override is keyed to it, so walking to the next level
    /// doesn't inherit the previous level's edits.
    var currentLevelIndex = 0
    /// Edits, keyed by level.
    ///
    /// Was a single level's rows plus the index it belonged to, which meant
    /// editing level 2 silently discarded your edit to level 1 — so an agent
    /// building a four-level game could only ever hold one level in flight. A
    /// dictionary costs nothing and removes the whole failure mode.
    private(set) var levelOverrides: [Int: [String]] = [:]

    /// Levels with an edit pending, in order — for the state document.
    var editedLevels: [Int] { levelOverrides.keys.sorted() }

    var effectiveGravity: CGFloat { gravity ?? Tuning.gravity }
    var effectiveRunSpeed: CGFloat { runSpeed ?? Tuning.runSpeed }
    var effectiveJumpVelocity: CGFloat { jumpVelocity ?? Tuning.jumpVelocity }
    var effectiveCameraLead: CGFloat { cameraLead ?? Tuning.cameraLead }

    /// Explicit `setLighting` colours win; otherwise `setTimeOfDay` drives the
    /// ramp; otherwise the rig's shipped defaults.
    var effectiveLighting: (warm: [CGFloat], cool: [CGFloat], ambient: CGFloat) {
        let base = DayCycle.lighting(at: timeOfDay ?? levelTimeOfDay
                                     ?? DayCycle.defaultTime)
        return (warm ?? base.warm, cool ?? base.cool, ambient ?? base.ambient)
    }

    func setLevelOverride(_ rows: [String], for index: Int) {
        levelOverrides[index] = LevelRules.normalize(rows)
    }

    /// Drop one level's edit and leave the others alone — what "undo this level"
    /// needs, and what `reset` used to be the only way to get.
    func clearLevelOverride(for index: Int) {
        levelOverrides[index] = nil
    }

    /// Rows for a level: the override when it belongs to that level, otherwise
    /// the compiled table. Returns nil for an index the game doesn't have.
    func rows(forLevel index: Int) -> [String]? {
        if let rows = levelOverrides[index] { return rows }
        guard Levels.all.indices.contains(index) else { return nil }
        return Levels.all[index]
    }

    func reset() {
        gravity = nil; runSpeed = nil; jumpVelocity = nil; cameraLead = nil
        warm = nil; cool = nil; ambient = nil; timeOfDay = nil
        friezeOverride = nil
        showColliders = false
        colliderMode = .box
        colliderSlots = []
        levelOverrides = [:]
        levelTimeOfDay = nil
        postProcess = true
        grade = nil
    }

    // MARK: Reversibility

    /// Everything the API can change, in one value — so a test or an AI
    /// experiment can be bracketed and rolled back exactly.
    struct Snapshot {
        var gravity: CGFloat?, runSpeed: CGFloat?, jumpVelocity: CGFloat?
        var cameraLead: CGFloat?
        var warm: [CGFloat]?, cool: [CGFloat]?, ambient: CGFloat?, timeOfDay: CGFloat?
        var friezeOverride: String?
        var showColliders: Bool
        var colliderMode: ColliderMode
        var colliderSlots: [String]
        var levelOverrides: [Int: [String]]
        var levelTimeOfDay: CGFloat?
        var postProcess: Bool
        var grade: String?
    }

    func snapshot() -> Snapshot {
        Snapshot(gravity: gravity, runSpeed: runSpeed, jumpVelocity: jumpVelocity,
                 cameraLead: cameraLead, warm: warm, cool: cool, ambient: ambient,
                 timeOfDay: timeOfDay, friezeOverride: friezeOverride,
                 showColliders: showColliders, colliderMode: colliderMode,
                 colliderSlots: colliderSlots, levelOverrides: levelOverrides,
                 levelTimeOfDay: levelTimeOfDay, postProcess: postProcess,
                 grade: grade)
    }

    func restore(_ s: Snapshot) {
        gravity = s.gravity; runSpeed = s.runSpeed; jumpVelocity = s.jumpVelocity
        cameraLead = s.cameraLead
        warm = s.warm; cool = s.cool; ambient = s.ambient; timeOfDay = s.timeOfDay
        friezeOverride = s.friezeOverride
        showColliders = s.showColliders
        colliderMode = s.colliderMode
        colliderSlots = s.colliderSlots
        levelOverrides = s.levelOverrides
        levelTimeOfDay = s.levelTimeOfDay
        postProcess = s.postProcess
        grade = s.grade
    }
}

/// Applies commands to a live scene.
///
/// Two kinds of effect: things that can change *now* (lighting, animation,
/// gravity, debug draw) are pushed straight into the running scene; things that
/// change the world's shape (tiles, actors, backdrop) are recorded in
/// `EngineOverrides` and flagged `needsReload`, because the level graph is built
/// once at load — the same trade UbiArt made, and the reason its editor
/// re-cooked a scene rather than patching one.
final class EngineInterpreter {

    private weak var scene: SKScene?
    private let overrides = EngineOverrides.shared

    init(scene: SKScene) { self.scene = scene }

    @discardableResult
    func apply(_ commands: [EngineCommand]) -> EngineReceipt {
        var receipt = EngineReceipt()
        var levelTouched = false

        for cmd in commands {
            switch cmd {

            // MARK: Level authoring

            case .setLevel(let rows):
                overrides.setLevelOverride(rows, for: overrides.currentLevelIndex)
                levelTouched = true
                receipt.needsReload = true
                receipt.applied.append("setLevel(\(rows.count) rows)")

            case .setTile(let col, let row, let symbol):
                switch editRows({ rows in
                    guard rows.indices.contains(row) else { return "row out of range" }
                    var chars = Array(rows[row])
                    guard chars.indices.contains(col) else { return "col out of range" }
                    chars[col] = symbol
                    rows[row] = String(chars)
                    return nil
                }) {
                case .some(let why): receipt.rejected.append("setTile: \(why)")
                case .none:
                    levelTouched = true
                    receipt.needsReload = true
                    receipt.applied.append("setTile(\(col),\(row),\(symbol))")
                }

            case .fillRegion(let col, let row, let width, let height, let symbol):
                switch editRows({ rows in
                    guard rows.indices.contains(row), rows.indices.contains(row + height - 1)
                    else { return "rows out of range" }
                    for r in row..<(row + height) {
                        var chars = Array(rows[r])
                        guard chars.indices.contains(col),
                              chars.indices.contains(col + width - 1) else {
                            return "cols out of range"
                        }
                        for c in col..<(col + width) { chars[c] = symbol }
                        rows[r] = String(chars)
                    }
                    return nil
                }) {
                case .some(let why): receipt.rejected.append("fillRegion: \(why)")
                case .none:
                    levelTouched = true
                    receipt.needsReload = true
                    receipt.applied.append("fillRegion(\(width)×\(height) of \(symbol))")
                }

            case .setSpawn(let col, let row):
                switch editRows({ rows in
                    guard rows.indices.contains(row) else { return "row out of range" }
                    guard Array(rows[row]).indices.contains(col) else {
                        return "col out of range"
                    }
                    // Exactly one S is a hard rule, so clear the old one first.
                    rows = rows.map { String($0.map { $0 == "S" ? "." : $0 }) }
                    var chars = Array(rows[row])
                    chars[col] = "S"
                    rows[row] = String(chars)
                    return nil
                }) {
                case .some(let why): receipt.rejected.append("setSpawn: \(why)")
                case .none:
                    levelTouched = true
                    receipt.needsReload = true
                    receipt.applied.append("setSpawn(\(col),\(row))")
                }

            case .spawnActor(let kind, let col, let row):
                guard let symbol = TileSymbol.actorKinds[kind] else {
                    receipt.rejected.append("spawnActor: unknown kind '\(kind)'"); continue
                }
                switch editRows({ rows in
                    guard rows.indices.contains(row) else { return "row out of range" }
                    var chars = Array(rows[row])
                    guard chars.indices.contains(col) else { return "col out of range" }
                    chars[col] = symbol
                    rows[row] = String(chars)
                    return nil
                }) {
                case .some(let why): receipt.rejected.append("spawnActor: \(why)")
                case .none:
                    levelTouched = true
                    receipt.needsReload = true
                    receipt.applied.append("spawnActor(\(kind)@\(col),\(row))")
                }

            // MARK: Presentation

            case .loadFrieze(let name):
                overrides.friezeOverride = name
                receipt.needsReload = true
                receipt.applied.append("loadFrieze(\(name))")

            case .setLighting(let warm, let cool, let ambient):
                overrides.warm = warm
                overrides.cool = cool
                overrides.ambient = ambient
                let n = retintLights(warm: warm, cool: cool, ambient: ambient)
                receipt.applied.append("setLighting(\(n) light(s))")

            case .setTimeOfDay(let t):
                overrides.timeOfDay = t
                // Explicit colours would otherwise pin the sky; the dial owns
                // lighting once it is used.
                overrides.warm = nil; overrides.cool = nil; overrides.ambient = nil
                let light = DayCycle.lighting(at: t)
                let n = retintLights(warm: light.warm, cool: light.cool,
                                     ambient: light.ambient)
                receipt.applied.append("setTimeOfDay(\(String(format: "%.2f", t)), "
                                       + "\(n) light(s))")

            // MARK: Actors

            case .playAnimation(let actor, let clip, let track, let loop):
                guard let node = skeleton(for: actor) else {
                    receipt.rejected.append("playAnimation: actor '\(actor)' not found")
                    continue
                }
                guard node.skeleton.data.animations[clip] != nil else {
                    receipt.rejected.append("playAnimation: '\(actor)' has no clip '\(clip)'"
                        + " (has \(node.skeleton.data.animations.keys.sorted()))")
                    continue
                }
                node.play(clip, track: track, loop: loop)
                receipt.applied.append("playAnimation(\(actor):\(clip)@\(track))")

            case .setAnimationMix(let from, let to, let duration):
                var count = 0
                forEachSkeleton { node in
                    node.setMix(from: from, to: to, duration: duration)
                    count += 1
                }
                receipt.applied.append("setAnimationMix(\(from)→\(to) on \(count) rig(s))")

            case .setSkin(let actor, let skin):
                guard let node = skeleton(for: actor) else {
                    receipt.rejected.append("setSkin: actor '\(actor)' not found")
                    continue
                }
                guard node.availableSkins.contains(skin) else {
                    receipt.rejected.append("setSkin: '\(actor)' has no skin "
                        + "'\(skin)' (has \(node.availableSkins))")
                    continue
                }
                node.setSkin(skin)
                receipt.applied.append("setSkin(\(actor):\(skin))")

            case .setColliderMode(let mode, let slots):
                overrides.colliderMode = mode
                overrides.colliderSlots = slots
                var count = 0
                forEachSkeleton { node in
                    node.setColliderMode(mode, slots: slots)
                    count += 1
                }
                receipt.applied.append("setColliderMode(\(mode.rawValue) on \(count) rig(s))")

            // MARK: Tuning

            case .setGravity(let v):
                overrides.gravity = v
                scene?.physicsWorld.gravity = CGVector(dx: 0, dy: v)
                receipt.applied.append("setGravity(\(v))")

            case .setRunSpeed(let v):
                overrides.runSpeed = v; receipt.applied.append("setRunSpeed(\(v))")
            case .setJumpVelocity(let v):
                overrides.jumpVelocity = v; receipt.applied.append("setJumpVelocity(\(v))")
            case .setCameraLead(let v):
                overrides.cameraLead = v; receipt.applied.append("setCameraLead(\(v))")

            // MARK: Session

            case .showColliders(let on):
                overrides.showColliders = on
                scene?.view?.showsPhysics = on
                forEachSkeleton { $0.setColliderDebugDraw(on) }
                receipt.applied.append("showColliders(\(on))")

            case .editLevel(let on):
#if DEBUG
                if let scene = scene as? GameScene {
                    // The overlay is a toggle, so only act when the request differs
                    // from the current state — sending `true` twice should not close it.
                    if scene.isEditing != on { scene.toggleEditor() }
                    receipt.applied.append("editLevel(\(on))")
                } else {
                    receipt.rejected.append("editLevel: not a GameScene")
                }
#else
                receipt.rejected.append("editLevel: in-engine editing is DEBUG only")
#endif

            case .setPostProcess(let on):
                overrides.postProcess = on
                // Live: the chain is a node in the running scene, so this takes
                // effect on the next frame with no reload.
                if let chain = firstPostProcess() {
                    chain.shouldEnableEffects = on
                    receipt.applied.append("setPostProcess(\(on))")
                } else {
                    receipt.rejected.append("setPostProcess: no post chain in the "
                                            + "scene")
                }

            case .setGrade(let name):
                overrides.grade = name
                if let chain = firstPostProcess(), chain.apply(named: name) {
                    receipt.applied.append("setGrade(\(name))")
                } else {
                    receipt.rejected.append("setGrade: no post chain in the scene")
                }

            case .reset:
                overrides.reset()
                scene?.physicsWorld.gravity = CGVector(dx: 0, dy: Tuning.gravity)
                scene?.view?.showsPhysics = false
                receipt.needsReload = true
                receipt.applied.append("reset")

            case .reload:
                receipt.needsReload = true
                receipt.applied.append("reload")
            }
        }

        // One rule pass over the final map, not one per edit: an AI writing a
        // level tile-by-tile would otherwise drown in transient warnings.
        if levelTouched, let rows = overrides.rows(forLevel: overrides.currentLevelIndex) {
            receipt.warnings = LevelRules.validate(rows)
        }
        return receipt
    }

    // MARK: Level editing plumbing

    /// Runs `edit` against the current level's rows, writing the result back as
    /// the override. The closure returns nil on success or a reason string —
    /// which becomes the receipt's rejection, so every refusal says why.
    private func editRows(_ edit: (inout [String]) -> String?) -> String? {
        guard var rows = overrides.rows(forLevel: overrides.currentLevelIndex) else {
            return "no level loaded"
        }
        rows = LevelRules.normalize(rows)
        if let why = edit(&rows) { return why }
        overrides.setLevelOverride(rows, for: overrides.currentLevelIndex)
        return nil
    }

    // MARK: Scene lookups

    /// Rigs are addressed by the name of the actor node that owns them
    /// ("player", "enemy.0", …) or by the skeleton's own name. Searching for
    /// both means gameplay code is free to name things however it likes and the
    /// API still finds them.
    private func skeleton(for actor: String) -> SkeletonNode? {
        guard let scene else { return nil }
        if let direct = scene.childNode(withName: "//\(actor)") {
            if let node = direct as? SkeletonNode { return node }
            if let node = EngineInterpreter.firstSkeleton(under: direct) { return node }
        }
        var found: SkeletonNode?
        scene.enumerateChildNodes(withName: "//*") { node, stop in
            if let rig = node as? SkeletonNode, rig.name == actor {
                found = rig
                stop.pointee = true
            }
        }
        return found
    }

    private static func firstSkeleton(under node: SKNode, depth: Int = 4) -> SkeletonNode? {
        guard depth > 0 else { return nil }
        for child in node.children {
            if let rig = child as? SkeletonNode { return rig }
            if let rig = firstSkeleton(under: child, depth: depth - 1) { return rig }
        }
        return nil
    }

    /// The scene's post chain, if it has one. Searched rather than injected so the
    /// interpreter stays constructible from any `SKScene`.
    private func firstPostProcess() -> PostProcess? {
        scene?.children.compactMap { $0 as? PostProcess }.first
    }

    private func forEachSkeleton(_ body: (SkeletonNode) -> Void) {
        scene?.enumerateChildNodes(withName: "//*") { node, _ in
            if let rig = node as? SkeletonNode { body(rig) }
        }
    }

    /// Retint the live lights instead of rebuilding the scene: `SKLightNode`s
    /// are identified by the category bits `LightingRig` assigned them, so no
    /// extra wiring between the API and the rig is needed. Returns how many
    /// lights were touched — zero is a useful signal that lighting is off.
    private func retintLights(warm: [CGFloat], cool: [CGFloat],
                              ambient: CGFloat) -> Int {
        var touched = 0
        scene?.enumerateChildNodes(withName: "//*") { node, _ in
            guard let light = node as? SKLightNode else { return }
            if light.categoryBitMask & LightCategory.key != 0 {
                light.lightColor = DayCycle.color(warm)
                light.ambientColor = SKColor(white: ambient, alpha: 1)
                touched += 1
            } else if light.categoryBitMask & LightCategory.rim != 0 {
                light.lightColor = DayCycle.color(cool)
                touched += 1
            }
        }
        return touched
    }

    // MARK: Documents

    /// Convenience: load a command document from the Documents directory —
    /// pairs with `HotReloader` so a generated script applies the moment it
    /// lands on disk.
    @discardableResult
    func applyDocument(named name: String) -> EngineReceipt {
        guard let docs = HotReloader.documentsURL else {
            var r = EngineReceipt()
            r.rejected.append("no Documents directory")
            return r
        }
        guard let data = try? Data(contentsOf: docs.appendingPathComponent(name)) else {
            var r = EngineReceipt()
            r.rejected.append("document \(name) not found")
            return r
        }
        let (commands, errors) = EngineScript.parse(data: data)
        var receipt = apply(commands)
        receipt.rejected.append(contentsOf: errors)
        return receipt
    }

    /// Apply a document held in memory — the path a test harness or an
    /// in-process script uses.
    @discardableResult
    func applyText(_ text: String) -> EngineReceipt {
        let (commands, errors) = EngineScript.parse(text: text)
        var receipt = apply(commands)
        receipt.rejected.append(contentsOf: errors)
        return receipt
    }
}
