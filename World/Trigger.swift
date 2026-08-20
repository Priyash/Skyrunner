import Foundation
import CoreGraphics

/// Triggers: the thing that turns a level from a room into a designed moment.
///
/// Why this exists. Every Rayman set piece — the chase, the ambush, the gate that
/// slams, the camera reveal — is "when the player reaches *here*, do *this*". Before
/// this there was no way to say that except by editing `GameScene`, which meant
/// every set piece cost programmer time and no designer could author one. Levels
/// were data; *moments* were code.
///
/// The design constraints that shaped it:
///
/// * **A closed action vocabulary, not a script language.** A `TriggerAction` is an
///   enum, so it is `Codable`, validatable offline, showable in an editor, and
///   writable by a model against a published schema. An embedded interpreter would
///   be more expressive and none of those things.
/// * **Regions in tile coordinates.** The author is looking at a glyph grid; a
///   trigger at "column 12, two wide" is something they can see. Points would be
///   a second coordinate system to hold in your head.
/// * **Firing is explicit.** `once` is the default because the overwhelmingly
///   common bug is a trigger that re-fires every frame the player stands in it.
///
/// ```json
/// "triggers": [
///   { "name": "start_chase",
///     "region": {"col": 12, "row": 0, "width": 2, "height": 9},
///     "when": "enter",
///     "actions": [
///       {"do": "camera", "mode": "chase", "speed": 190},
///       {"do": "music", "name": "theme_arena"},
///       {"do": "hazardWall", "fromCol": 0, "speed": 190},
///       {"do": "text", "message": "RUN!"},
///       {"do": "shake", "strength": 0.8}
///     ]}
/// ]
/// ```
struct TriggerSpec: Codable, Equatable {

    /// When the trigger evaluates.
    enum When: String, Codable {
        /// The frame the player's box first overlaps the region.
        case enter
        /// The frame it stops overlapping.
        case exit
        /// Every frame it overlaps. Pair with `once: false` deliberately.
        case inside
        /// Immediately at level load — for setup that isn't positional.
        case start
    }

    /// A rectangle in tile coordinates. Row 0 is the top, matching the glyph grid.
    struct Region: Codable, Equatable {
        var col: Int
        var row: Int = 0
        var width: Int = 1
        var height: Int = 64      // full height by default: a vertical tripwire

        /// In scene points, given the level's height. The grid's row 0 is the top
        /// and the scene's origin is the bottom, which is the conversion every
        /// coordinate bug in this engine has come from.
        func rect(rows: Int, tile: CGFloat) -> CGRect {
            let clampedHeight = min(height, max(rows - row, 1))
            let top = CGFloat(rows) * tile - CGFloat(row) * tile
            return CGRect(x: CGFloat(col) * tile,
                          y: top - CGFloat(clampedHeight) * tile,
                          width: CGFloat(max(width, 1)) * tile,
                          height: CGFloat(clampedHeight) * tile)
        }
    }

    var name: String
    var region: Region?
    var when: When = .enter
    /// Fire at most once per level attempt. The default, because a repeating
    /// trigger is almost always a mistake.
    var once: Bool = true
    /// Extra gates, all of which must hold. `nil` means position alone.
    var requires: Requirement?
    var actions: [TriggerAction]

    /// Non-positional conditions. Kept small on purpose: this is a trigger system,
    /// not a rules engine.
    struct Requirement: Codable, Equatable {
        /// Seconds since the level started.
        var afterSeconds: Double?
        /// Coins collected this attempt.
        var coinsAtLeast: Int?
        /// Enemies defeated this attempt.
        var enemiesDefeated: Int?
        /// Another trigger must have fired first — the only sequencing primitive,
        /// and enough to chain a set piece into stages.
        var afterTrigger: String?
    }

    var structuralProblems: [String] {
        var out: [String] = []
        if name.isEmpty { out.append("trigger needs a name") }
        if actions.isEmpty { out.append("'\(name)' has no actions, so it does nothing") }
        if when != .start, region == nil {
            out.append("'\(name)' is positional (when: \(when.rawValue)) but has no "
                       + "region")
        }
        if let region {
            if region.col < 0 || region.row < 0 {
                out.append("'\(name)' region starts off the grid")
            }
            if region.width < 1 || region.height < 1 {
                out.append("'\(name)' region must be at least 1×1")
            }
        }
        if when == .inside, once {
            out.append("'\(name)' fires `inside` but is `once` — it would fire on one "
                       + "frame only; use `enter`, or set once: false")
        }
        for (index, action) in actions.enumerated() {
            for problem in action.problems {
                out.append("'\(name)' action \(index): \(problem)")
            }
        }
        return out
    }
}

/// What a trigger does. One case per authored effect.
///
/// Encoded with a `do` discriminator so the JSON reads as a verb — `{"do": "shake"}`
/// — which is how an author and a model both think about it. Swift's synthesised
/// `Codable` for enums with associated values produces a shape nobody would write by
/// hand, so this is coded explicitly.
enum TriggerAction: Equatable {

    /// Spawn a wave of actors. The ambush.
    case spawn(kind: String, col: Int, row: Int, count: Int, spacing: Int)
    /// A lethal wall advancing from a column at points per second. The chase.
    case hazardWall(fromCol: Int, speed: CGFloat)
    /// Camera behaviour for the rest of the level, or until another trigger.
    case camera(mode: CameraSpec.Mode, zoom: CGFloat?, speed: CGFloat?)
    /// Move a named node — a gate rising, a bridge falling.
    case move(target: String, dx: CGFloat, dy: CGFloat, seconds: Double)
    /// Screen shake / barrel distortion through the post chain.
    case shake(strength: CGFloat)
    case sound(name: String)
    case music(name: String?)
    case grade(name: String)
    /// Floating message. Set-piece signposting.
    case text(message: String, seconds: Double)
    /// Retune movement for a section — a chase is faster, an ice cave is slippier.
    case tuning(runSpeed: CGFloat?, jumpVelocity: CGFloat?, gravity: CGFloat?)
    /// Move the respawn point here.
    case checkpoint
    /// End the level as a win.
    case finish

    var problems: [String] {
        switch self {
        case .spawn(let kind, let col, let row, let count, let spacing):
            var out: [String] = []
            if TileSymbol.actorKinds[kind] == nil {
                out.append("unknown actor kind '\(kind)' (have "
                           + TileSymbol.actorKindList.joined(separator: ", ") + ")")
            }
            if col < 0 || row < 0 { out.append("spawn is off the grid") }
            if count < 1 || count > 24 {
                out.append("spawn count \(count) is outside 1…24")
            }
            if spacing < 1 { out.append("spawn spacing must be at least 1") }
            return out
        case .hazardWall(let col, let speed):
            var out: [String] = []
            if col < 0 { out.append("hazardWall starts off the grid") }
            if speed <= 0 || speed > 1200 {
                out.append("hazardWall speed \(speed) is outside 1…1200 pt/s")
            }
            return out
        case .camera(_, let zoom, let speed):
            var out: [String] = []
            if let zoom, zoom < 0.5 || zoom > 2.5 {
                out.append("camera zoom \(zoom) is outside 0.5…2.5")
            }
            if let speed, speed <= 0 || speed > 1200 {
                out.append("camera speed \(speed) is outside 1…1200 pt/s")
            }
            return out
        case .move(let target, _, _, let seconds):
            var out: [String] = []
            if target.isEmpty { out.append("move needs a target name") }
            if seconds <= 0 || seconds > 30 {
                out.append("move duration \(seconds)s is outside 0…30")
            }
            return out
        case .shake(let strength):
            return strength <= 0 || strength > 2
                ? ["shake strength \(strength) is outside 0…2"] : []
        case .sound(let name):
            return Audio.soundNames.contains(name) ? []
                : ["unknown sound '\(name)'"]
        case .music(let name):
            guard let name else { return [] }
            return Audio.musicNames.contains(name) ? []
                : ["unknown music '\(name)'"]
        case .grade(let name):
            return PostProcess.Grade.named[name] == nil
                ? ["unknown grade '\(name)'"] : []
        case .text(let message, let seconds):
            var out: [String] = []
            if message.isEmpty { out.append("text needs a message") }
            if seconds <= 0 || seconds > 12 {
                out.append("text duration \(seconds)s is outside 0…12")
            }
            return out
        case .tuning(let run, let jump, let gravity):
            var out: [String] = []
            if let run, run < 60 || run > 700 {
                out.append("runSpeed \(run) is outside 60…700")
            }
            if let jump, jump < 300 || jump > 1600 {
                out.append("jumpVelocity \(jump) is outside 300…1600")
            }
            if let gravity, gravity > -4 || gravity < -60 {
                out.append("gravity \(gravity) is outside −60…−4")
            }
            return out
        case .checkpoint, .finish:
            return []
        }
    }
}

// MARK: - Codable

extension TriggerAction: Codable {

    private enum Key: String, CodingKey {
        case `do`, kind, col, row, count, spacing, fromCol, speed, mode, zoom
        case target, dx, dy, seconds, strength, name, message
        case runSpeed, jumpVelocity, gravity
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Key.self)
        let verb = try box.decode(String.self, forKey: .do)
        func number(_ key: Key, _ fallback: CGFloat) -> CGFloat {
            (try? box.decode(CGFloat.self, forKey: key)) ?? fallback
        }
        func integer(_ key: Key, _ fallback: Int) -> Int {
            (try? box.decode(Int.self, forKey: key)) ?? fallback
        }
        switch verb {
        case "spawn":
            self = .spawn(kind: (try? box.decode(String.self, forKey: .kind)) ?? "enemy",
                          col: integer(.col, 0), row: integer(.row, 0),
                          count: integer(.count, 1), spacing: integer(.spacing, 2))
        case "hazardWall":
            self = .hazardWall(fromCol: integer(.fromCol, 0), speed: number(.speed, 180))
        case "camera":
            let raw = (try? box.decode(String.self, forKey: .mode)) ?? "follow"
            self = .camera(mode: CameraSpec.Mode(rawValue: raw) ?? .follow,
                           zoom: try? box.decode(CGFloat.self, forKey: .zoom),
                           speed: try? box.decode(CGFloat.self, forKey: .speed))
        case "move":
            self = .move(target: (try? box.decode(String.self, forKey: .target)) ?? "",
                         dx: number(.dx, 0), dy: number(.dy, 0),
                         seconds: Double(number(.seconds, 1)))
        case "shake":
            self = .shake(strength: number(.strength, 0.7))
        case "sound":
            self = .sound(name: (try? box.decode(String.self, forKey: .name)) ?? "")
        case "music":
            self = .music(name: try? box.decode(String.self, forKey: .name))
        case "grade":
            self = .grade(name: (try? box.decode(String.self, forKey: .name)) ?? "")
        case "text":
            self = .text(message: (try? box.decode(String.self, forKey: .message)) ?? "",
                         seconds: Double(number(.seconds, 1.6)))
        case "tuning":
            self = .tuning(runSpeed: try? box.decode(CGFloat.self, forKey: .runSpeed),
                           jumpVelocity: try? box.decode(CGFloat.self,
                                                         forKey: .jumpVelocity),
                           gravity: try? box.decode(CGFloat.self, forKey: .gravity))
        case "checkpoint": self = .checkpoint
        case "finish": self = .finish
        default:
            // An unknown verb is a level authored against a newer engine. Refusing
            // loudly beats silently dropping a set piece.
            throw DecodingError.dataCorruptedError(
                forKey: .do, in: box,
                debugDescription: "unknown trigger action '\(verb)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Key.self)
        switch self {
        case .spawn(let kind, let col, let row, let count, let spacing):
            try box.encode("spawn", forKey: .do)
            try box.encode(kind, forKey: .kind)
            try box.encode(col, forKey: .col)
            try box.encode(row, forKey: .row)
            try box.encode(count, forKey: .count)
            try box.encode(spacing, forKey: .spacing)
        case .hazardWall(let col, let speed):
            try box.encode("hazardWall", forKey: .do)
            try box.encode(col, forKey: .fromCol)
            try box.encode(speed, forKey: .speed)
        case .camera(let mode, let zoom, let speed):
            try box.encode("camera", forKey: .do)
            try box.encode(mode.rawValue, forKey: .mode)
            try box.encodeIfPresent(zoom, forKey: .zoom)
            try box.encodeIfPresent(speed, forKey: .speed)
        case .move(let target, let dx, let dy, let seconds):
            try box.encode("move", forKey: .do)
            try box.encode(target, forKey: .target)
            try box.encode(dx, forKey: .dx)
            try box.encode(dy, forKey: .dy)
            try box.encode(seconds, forKey: .seconds)
        case .shake(let strength):
            try box.encode("shake", forKey: .do)
            try box.encode(strength, forKey: .strength)
        case .sound(let name):
            try box.encode("sound", forKey: .do)
            try box.encode(name, forKey: .name)
        case .music(let name):
            try box.encode("music", forKey: .do)
            try box.encodeIfPresent(name, forKey: .name)
        case .grade(let name):
            try box.encode("grade", forKey: .do)
            try box.encode(name, forKey: .name)
        case .text(let message, let seconds):
            try box.encode("text", forKey: .do)
            try box.encode(message, forKey: .message)
            try box.encode(seconds, forKey: .seconds)
        case .tuning(let run, let jump, let gravity):
            try box.encode("tuning", forKey: .do)
            try box.encodeIfPresent(run, forKey: .runSpeed)
            try box.encodeIfPresent(jump, forKey: .jumpVelocity)
            try box.encodeIfPresent(gravity, forKey: .gravity)
        case .checkpoint: try box.encode("checkpoint", forKey: .do)
        case .finish: try box.encode("finish", forKey: .do)
        }
    }

    /// Every verb, for the published schema and the editor's palette.
    static let verbs = ["spawn", "hazardWall", "camera", "move", "shake", "sound",
                        "music", "grade", "text", "tuning", "checkpoint", "finish"]
}
