import SpriteKit
import Foundation

/// EngineQuery — the read half of the machine surface.
///
/// `EngineAPI` lets a program *change* the engine; this file lets it *see* the
/// engine, which is what turns a script into an agent. Three pieces:
///
///  • `EngineSchema` — the vocabulary, self-described: every op, its
///    parameters, their types and legal ranges, plus the tile alphabet. A
///    producer never has to hard-code what this build accepts; it asks. (It is
///    also exactly the shape a tool-calling model wants.)
///  • `EngineSnapshot` — the live world as JSON: level rows, actors and their
///    rigs, effective tuning, lighting, collider state, and the design-rule
///    report for the current map.
///  • `EngineBridge` — the transport. A document dropped in Documents is
///    applied; the receipt, the snapshot and the schema are written back to
///    `Documents/EngineOut/`. Generate → apply → read back → correct, over the
///    filesystem, with no networking and no server in the app.
enum EngineSchema {

    static let version = EngineScript.version

    /// One parameter's contract. `range` is inclusive; values outside it are
    /// clamped (tuning) or refused (indices) — `clamped` says which.
    private struct Param {
        let name: String
        let type: String
        let note: String
        var range: [Double]? = nil
        var values: [String]? = nil
        var clamped = false
        var optional = false

        var json: [String: Any] {
            var out: [String: Any] = ["name": name, "type": type, "note": note]
            if let range { out["range"] = range }
            if let values { out["values"] = values }
            if clamped { out["clamped"] = true }
            if optional { out["optional"] = true }
            return out
        }
    }

    private struct Op {
        let op: String
        let doc: String
        let params: [Param]
        var reload = false

        var json: [String: Any] {
            ["op": op, "doc": doc, "params": params.map(\.json), "needsReload": reload]
        }
    }

    private static let col = Param(name: "col", type: "int",
                                   note: "column, 0 = left",
                                   range: [0, Double(LevelRules.maxColumns)])
    private static let row = Param(name: "row", type: "int",
                                   note: "row, 0 = TOP of the level",
                                   range: [0, Double(LevelRules.maxRows)])
    private static let symbol = Param(name: "symbol", type: "char",
                                      note: "tile symbol",
                                      values: TileSymbol.allowed.sorted().map(String.init))

    private static let ops: [Op] = [
        Op(op: "setLevel",
           doc: "Replace the current level's map. Row 0 is the top; rows are "
              + "padded to a rectangle with '.'.",
           params: [Param(name: "rows", type: "[string]",
                          note: "≤ \(LevelRules.maxRows) rows of ≤ "
                              + "\(LevelRules.maxColumns) tile symbols")],
           reload: true),
        Op(op: "setTile", doc: "Write one tile.", params: [col, row, symbol], reload: true),
        Op(op: "fillRegion", doc: "Write a rectangle of tiles ('.' erases).",
           params: [col, row,
                    Param(name: "width", type: "int", note: "tiles, ≥ 1",
                          range: [1, Double(LevelRules.maxColumns)]),
                    Param(name: "height", type: "int", note: "tiles, ≥ 1",
                          range: [1, Double(LevelRules.maxRows)]),
                    symbol],
           reload: true),
        Op(op: "setSpawn", doc: "Move the player spawn (clears the previous 'S').",
           params: [col, row], reload: true),
        Op(op: "spawnActor", doc: "Place an actor by kind — sugar for setTile.",
           params: [Param(name: "kind", type: "string", note: "actor kind",
                          values: TileSymbol.actorKindList), col, row],
           reload: true),
        Op(op: "loadFrieze",
           doc: "Swap the backdrop scene (a bundled <name>.json + layer images).",
           params: [Param(name: "name", type: "identifier",
                          note: "letters, digits, _ and - only")],
           reload: true),
        Op(op: "setLighting", doc: "Retint the key and rim lights live.",
           params: [Param(name: "warm", type: "[number]", note: "key light RGB 0…1",
                          range: [0, 1], clamped: true),
                    Param(name: "cool", type: "[number]", note: "rim light RGB 0…1",
                          range: [0, 1], clamped: true),
                    Param(name: "ambient", type: "number", note: "ambient level",
                          range: [0, 1], clamped: true, optional: true)]),
        Op(op: "setTimeOfDay",
           doc: "One dial for the whole lighting ramp; overrides setLighting.",
           params: [Param(name: "t", type: "number", note: "0 dawn, 0.5 noon, 1 dusk",
                          range: [0, 1], clamped: true)]),
        Op(op: "playAnimation", doc: "Play a clip on a rig track.",
           params: [Param(name: "actor", type: "identifier",
                          note: "actor node name, e.g. 'player' or 'enemy.0'"),
                    Param(name: "clip", type: "identifier", note: "clip name in the rig"),
                    Param(name: "track", type: "int",
                          note: "0 = base pose, higher layers on top",
                          range: [0, 4], clamped: true, optional: true),
                    Param(name: "loop", type: "bool", note: "default true",
                          optional: true)]),
        Op(op: "setAnimationMix", doc: "Crossfade time between two clips, every rig.",
           params: [Param(name: "from", type: "identifier", note: "clip name"),
                    Param(name: "to", type: "identifier", note: "clip name"),
                    Param(name: "duration", type: "number", note: "seconds",
                          range: [0, 2], clamped: true)]),
        Op(op: "setSkin", doc: "Swap a rig's attachment set (costume, damage state).",
           params: [Param(name: "actor", type: "identifier", note: "actor node name"),
                    Param(name: "skin", type: "identifier",
                          note: "skin name; state.json lists each rig's skins")]),
        Op(op: "setColliderMode",
           doc: "Collision representation for animated rigs: 'box' is the static "
              + "capsule, 'hull' one convex hull around the deformed rig, "
              + "'perSlot' one hull per deforming limb (compound body).",
           params: [Param(name: "mode", type: "string", note: "collider mode",
                          values: ColliderMode.allNames),
                    Param(name: "slots", type: "[identifier]",
                          note: "slots to track; empty = every mesh slot",
                          optional: true)]),
        Op(op: "setGravity", doc: "World gravity (SpriteKit m/s², 150pt = 1m).",
           params: [Param(name: "value", type: "number", note: "negative = down",
                          range: [-60, -4], clamped: true)]),
        Op(op: "setRunSpeed", doc: "Player horizontal speed, pt/s.",
           params: [Param(name: "value", type: "number", note: "", range: [60, 700],
                          clamped: true)]),
        Op(op: "setJumpVelocity", doc: "Player jump impulse, pt/s.",
           params: [Param(name: "value", type: "number", note: "", range: [300, 1600],
                          clamped: true)]),
        Op(op: "setCameraLead", doc: "Seconds of velocity the camera looks ahead.",
           params: [Param(name: "value", type: "number", note: "", range: [0, 0.6],
                          clamped: true)]),
        Op(op: "showColliders", doc: "Debug draw: physics bodies + deformed hulls.",
           params: [Param(name: "value", type: "bool", note: "default true",
                          optional: true)]),
        Op(op: "editLevel",
           doc: "Open in-engine editing: paint tiles by touch, play from a point. "
                + "DEBUG builds only.",
           params: [Param(name: "value", type: "bool", note: "default true",
                          optional: true)]),
        Op(op: "setPostProcess",
           doc: "Post chain on/off: bloom, grade, vignette, aberration.",
           params: [Param(name: "value", type: "bool", note: "default true",
                          optional: true)]),
        Op(op: "setGrade",
           doc: "Named colour grade — the strongest single lever on a level's look.",
           params: [Param(name: "name", type: "string",
                          note: "grove | hollow | evening | arena | neutral")]),
        Op(op: "reset", doc: "Drop every override — back to the shipped game.",
           params: [], reload: true),
        Op(op: "reload", doc: "Rebuild the scene with the current overrides.",
           params: [], reload: true),
    ]

    static var jsonObject: [String: Any] {
        ["version": version,
         "document": ["version": version, "commands": "[{op: …}, …]"],
         "notes": [
            "Row 0 is the TOP of a level; column 0 is the left edge.",
            "Out-of-range indices are refused; out-of-range tuning is clamped.",
            "Ops marked needsReload take effect when the scene rebuilds.",
            "Every batch returns a receipt: applied, rejected, warnings.",
         ],
         "tiles": TileSymbol.legendJSON,
         "rules": LevelRules.documentedRules,
         "ops": ops.map(\.json)]
    }

    static var jsonText: String { EngineJSON.text(jsonObject) }
}

/// The live world, as JSON. Everything a producer needs to decide what to do
/// next: the map it is editing, the actors that exist, the clips they can play,
/// the numbers currently in force, and what is wrong with the map right now.
enum EngineSnapshot {

    static func of(scene: SKScene?) -> [String: Any] {
        let overrides = EngineOverrides.shared
        let index = overrides.currentLevelIndex
        let rows = overrides.rows(forLevel: index) ?? []
        let light = overrides.effectiveLighting

        let levelFile = LevelLibrary.file(at: index)
        let levelName: String = levelFile?.name ?? "builtIn\(index)"
        let levelTitle: String = levelFile?.displayTitle ?? "Level \(index + 1)"
        let levelFrieze: String = overrides.friezeOverride ?? LevelLibrary.frieze(at: index) ?? "forest_backdrop"
        let levelMusic: Any = Audio.shared.currentMusic ?? LevelLibrary.music(at: index) ?? NSNull()
        let levelGrade: String = overrides.grade ?? LevelLibrary.grade(at: index) ?? "grove"
        let levelSource: String = LevelLibrary.files.isEmpty ? "compiled" : "file"

        var out: [String: Any] = [
            "version": EngineScript.version,
            "level": [
                "index": index,
                "count": Levels.all.count,
                "edited": overrides.levelOverrides[index] != nil,
                "editedLevels": overrides.editedLevels,
                "rows": rows,
                "size": ["cols": rows.map(\.count).max() ?? 0, "rows": rows.count],
                "tileSize": Double(Tuning.tileSize),
                "histogram": histogram(rows),
                "name": levelName,
                "title": levelTitle,
                "frieze": levelFrieze,
                "music": levelMusic,
                "source": levelSource,
                "grade": levelGrade,
                "postProcess": overrides.postProcess,
            ],
            "tuning": [
                "gravity": entry(overrides.effectiveGravity, Tuning.gravity,
                                 overrides.gravity != nil),
                "runSpeed": entry(overrides.effectiveRunSpeed, Tuning.runSpeed,
                                  overrides.runSpeed != nil),
                "jumpVelocity": entry(overrides.effectiveJumpVelocity,
                                      Tuning.jumpVelocity, overrides.jumpVelocity != nil),
                "cameraLead": entry(overrides.effectiveCameraLead, Tuning.cameraLead,
                                    overrides.cameraLead != nil),
            ],
            "lighting": [
                "warm": light.warm.map(Double.init),
                "cool": light.cool.map(Double.init),
                "ambient": Double(light.ambient),
                "timeOfDay": Double(overrides.timeOfDay ?? DayCycle.defaultTime),
                "explicitColors": overrides.warm != nil || overrides.cool != nil,
            ],
            "collision": [
                "mode": overrides.colliderMode.rawValue,
                "slots": overrides.colliderSlots,
                "debugDraw": overrides.showColliders,
            ],
            "validation": LevelRules.validate(rows),
        ]
        out["actors"] = actors(in: scene)
        return out
    }

    static func jsonText(of scene: SKScene?) -> String { EngineJSON.text(of(scene: scene)) }

    private static func entry(_ value: CGFloat, _ shipped: CGFloat,
                              _ overridden: Bool) -> [String: Any] {
        ["value": Double(value), "shipped": Double(shipped), "overridden": overridden]
    }

    private static func histogram(_ rows: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows {
            for ch in row where ch != "." {
                counts[String(ch), default: 0] += 1
            }
        }
        return counts
    }

    /// Named nodes in the scene, with rig detail where a skeleton is attached.
    /// HUD and control nodes are skipped — they are not part of the world — and
    /// the list is capped so a pathological scene can't produce a giant document.
    private static func actors(in scene: SKScene?) -> [[String: Any]] {
        guard let scene else { return [] }
        var out: [[String: Any]] = []
        scene.enumerateChildNodes(withName: "//*") { node, stop in
            guard out.count < 128 else { stop.pointee = true; return }
            guard let name = node.name, !name.hasPrefix("ui."), !name.hasPrefix("btn")
            else { return }
            let inScene = node.parent.map { $0.convert(node.position, to: scene) }
                ?? node.position
            var entry: [String: Any] = [
                "name": name,
                "type": String(describing: type(of: node)),
                "position": ["x": rounded(inScene.x), "y": rounded(inScene.y)],
            ]
            if let body = node.physicsBody {
                entry["physics"] = ["category": Int(body.categoryBitMask),
                                    "dynamic": body.isDynamic]
            }
            if let rig = node as? SkeletonNode ?? firstSkeleton(under: node) {
                entry["rig"] = rigInfo(rig)
            }
            out.append(entry)
        }
        return out
    }

    private static func rigInfo(_ rig: SkeletonNode) -> [String: Any] {
        var playing: [String: Any] = [:]
        for (track, entry) in rig.state.tracks {
            playing[String(track)] = ["clip": entry.clip.name,
                                      "time": rounded(CGFloat(entry.time)),
                                      "loops": entry.loops,
                                      "additive": entry.additive]
        }
        return ["clips": rig.skeleton.data.animations.keys.sorted(),
                "skins": rig.availableSkins,
                "bones": rig.skeleton.data.bones.map(\.name),
                "slots": rig.skeleton.data.slots.map(\.name),
                "meshSlots": rig.meshSlotNames,
                "playing": playing,
                "colliderMode": rig.colliderMode.rawValue,
                "hulls": rig.colliderHullCount]
    }

    private static func firstSkeleton(under node: SKNode, depth: Int = 3) -> SkeletonNode? {
        guard depth > 0 else { return nil }
        for child in node.children {
            if let rig = child as? SkeletonNode { return rig }
            if let rig = firstSkeleton(under: child, depth: depth - 1) { return rig }
        }
        return nil
    }

    private static func rounded(_ v: CGFloat) -> Double {
        (Double(v) * 10).rounded() / 10
    }
}

/// Shared JSON writer. Pretty-printed and key-sorted so two snapshots of the
/// same state diff cleanly — which is how a caller (or a test) tells whether
/// anything actually changed.
enum EngineJSON {
    static func text(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"snapshot could not be encoded"}"#
        }
        return text
    }
}

/// File-drop transport for the command surface.
///
/// Inbox: `Documents/engine.json` — a command document. Outbox:
/// `Documents/EngineOut/` — `receipt.json`, `state.json`, `schema.json`.
///
/// Two details that matter:
///  • **Outputs live in a subdirectory.** `HotReloader` watches Documents
///    itself; writing our own answers next to the inbox would retrigger the
///    watcher and the scene would rebuild forever. Writes *inside* a
///    subdirectory don't touch the watched directory's vnode.
///  • **Documents are fingerprinted statically.** The bridge is rebuilt with
///    each scene, but the fingerprint of the last applied document is not, so an
///    unrelated asset edit (which also fires the watcher) can't re-apply a
///    document whose `needsReload` would then rebuild the scene again, forever.
final class EngineBridge {

    static let inboxName = "engine.json"
    static let outboxName = "EngineOut"

    private let interpreter: EngineInterpreter
    private weak var scene: SKScene?
    private static var appliedFingerprint: UInt64?

    init(scene: SKScene) {
        self.scene = scene
        self.interpreter = EngineInterpreter(scene: scene)
    }

    // MARK: Locations

    static var inboxURL: URL? {
        HotReloader.documentsURL?.appendingPathComponent(inboxName)
    }

    static var outboxURL: URL? {
        HotReloader.documentsURL?.appendingPathComponent(outboxName, isDirectory: true)
    }

    // MARK: Read

    /// Apply the inbox if it changed since the last time any scene applied it.
    /// Returns nil when there is nothing new — the common case, since the same
    /// watcher fires for rig and frieze edits.
    @discardableResult
    func poll() -> EngineReceipt? {
        guard let url = EngineBridge.inboxURL else { return nil }
        // Check the size before reading: `Data(contentsOf:)` pulls the whole file
        // into memory, and the inbox is a folder a user (or a runaway script) can
        // write anything into. 4 MB is far more than the 2048-command ceiling
        // needs and small enough to read without thinking about it.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? Int, size > 4 * 1024 * 1024 {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let print = EngineBridge.fingerprint(data)
        guard print != EngineBridge.appliedFingerprint else { return nil }
        EngineBridge.appliedFingerprint = print

        let (commands, errors) = EngineScript.parse(data: data)
        var receipt = interpreter.apply(commands)
        receipt.rejected.append(contentsOf: errors)
        write(receipt.jsonText, to: "receipt.json")
        return receipt
    }

    /// Apply a document by hand — the path tests and in-process scripts use.
    @discardableResult
    func apply(text: String) -> EngineReceipt {
        let receipt = interpreter.applyText(text)
        write(receipt.jsonText, to: "receipt.json")
        return receipt
    }

    // MARK: Write

    /// Publish what a producer needs to decide its next move. Called once per
    /// scene build, never per frame: encoding a snapshot is cheap but not free.
    func publish() {
        write(EngineSnapshot.jsonText(of: scene), to: "state.json")
        write(EngineSchema.jsonText, to: "schema.json")
    }

    private func write(_ text: String, to name: String) {
        #if DEBUG
        guard let dir = EngineBridge.outboxURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent(name),
                                            options: .atomic)
        #endif
    }

    /// FNV-1a over the raw bytes: enough to tell "same document" from "edited
    /// document" without pulling in a hashing framework, and stable across
    /// launches (unlike `Hasher`, which is seeded per process).
    private static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
