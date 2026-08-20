import SpriteKit

/// Enemy behaviour as data: `behaviour/1`.
///
/// Why this exists. `Enemy.swift` was one hardcoded four-state machine, so fifteen
/// enemy types meant fifteen Swift classes and fifteen rounds of a programmer. That
/// is the constraint that caps a platformer's cast size, and it is the same
/// constraint `AnimGraph` removed for animation — so this is deliberately the same
/// shape: states, transitions, conditions, priorities, all declarative and all
/// validatable offline.
///
/// The split that makes it work: a behaviour decides **intent** (a velocity, a clip,
/// a request to fire) and never touches the scene. The scene applies intent. That is
/// what lets the whole thing be stepped in a test without a physics world, which is
/// the only way this kind of logic gets pinned down.
///
/// ```json
/// { "format": "behaviour/1", "name": "hopper",
///   "states": [
///     {"name": "crouch", "action": {"do": "wait"}, "clip": "idle"},
///     {"name": "leap",   "action": {"do": "leap", "vx": 130, "vy": 520}, "clip": "jump"}
///   ],
///   "transitions": [
///     {"from": "crouch", "to": "leap", "when": {"stateTime": 0.9}},
///     {"from": "leap", "to": "crouch", "when": {"grounded": true}, "minimumTime": 0.2}
///   ]}
/// ```
struct BehaviourGraph: Codable, Equatable {

    static let currentFormat = "behaviour/1"

    // MARK: What an enemy can do

    /// One state's action. A closed set, for the same reasons `TriggerAction` is:
    /// serialisable, validatable, and showable in an editor.
    enum Action: Equatable {
        /// Hold position. The telegraph, the recovery, the idle.
        case wait
        /// Walk between the patrol bounds, turning at each end.
        case patrol(speed: CGFloat)
        /// Move toward the player.
        case chase(speed: CGFloat)
        /// Move away from the player — a skittish enemy, or a recoil.
        case retreat(speed: CGFloat)
        /// One impulse. `vx` is signed toward the player.
        case leap(vx: CGFloat, vy: CGFloat)
        /// Ask the scene to fire a projectile toward the player.
        case shoot(speed: CGFloat, cooldown: Double)
        /// Freeze and flash — the wind-up that makes an attack fair.
        case telegraph

        var problems: [String] {
            switch self {
            case .wait, .telegraph: return []
            case .patrol(let s), .chase(let s), .retreat(let s):
                return s <= 0 || s > 600 ? ["speed \(s) is outside 1…600"] : []
            case .leap(let vx, let vy):
                var out: [String] = []
                if abs(vx) > 600 { out.append("leap vx \(vx) exceeds 600") }
                if vy <= 0 || vy > 1400 {
                    out.append("leap vy \(vy) is outside 1…1400")
                }
                return out
            case .shoot(let speed, let cooldown):
                var out: [String] = []
                if speed <= 0 || speed > 900 {
                    out.append("shoot speed \(speed) is outside 1…900")
                }
                if cooldown <= 0 || cooldown > 10 {
                    out.append("shoot cooldown \(cooldown)s is outside 0…10")
                }
                return out
            }
        }
    }

    /// A transition guard. Every case is something the scene can actually measure.
    indirect enum Condition: Equatable {
        case always
        /// Player within N points.
        case playerWithin(CGFloat)
        case playerBeyond(CGFloat)
        /// The enemy is facing the player — so an ambusher can't see behind itself.
        case facingPlayer
        /// Seconds in the current state.
        case stateTime(Double)
        case grounded(Bool)
        /// Standing at the edge of its ground run.
        case atEdge
        /// Took damage this frame.
        case hurt
        case all([Condition])
        case any([Condition])
        case not(Condition)

        func holds(_ sense: BehaviourRunner.Sense, stateTime: Double) -> Bool {
            switch self {
            case .always: return true
            case .playerWithin(let d): return sense.playerDistance <= d
            case .playerBeyond(let d): return sense.playerDistance > d
            case .facingPlayer: return sense.facingPlayer
            case .stateTime(let s): return stateTime >= s
            case .grounded(let want): return sense.grounded == want
            case .atEdge: return sense.atEdge
            case .hurt: return sense.hurt
            case .all(let list): return list.allSatisfy { $0.holds(sense, stateTime: stateTime) }
            case .any(let list): return list.contains { $0.holds(sense, stateTime: stateTime) }
            case .not(let inner): return !inner.holds(sense, stateTime: stateTime)
            }
        }
    }

    struct State: Codable, Equatable {
        var name: String
        var action: Action
        /// Animation clip while in this state. Optional: a procedural enemy has none.
        var clip: String?
        /// Flash while in this state — the telegraph tell.
        var flash: Bool = false
        /// Can the player be hurt by touching the enemy in this state? A stunned
        /// enemy that still damages on contact is the classic unfair hitbox.
        var dangerous: Bool = true
        /// Can the enemy be stomped in this state?
        var vulnerable: Bool = true
    }

    struct Transition: Codable, Equatable {
        var from: String            // or "*"
        var to: String
        var when: Condition
        var priority: Int = 0
        /// Refuse to leave before this many seconds — stops a one-frame sense blip
        /// from cutting a telegraph short, which is what makes an attack unreadable.
        var minimumTime: Double = 0
    }

    var format: String = BehaviourGraph.currentFormat
    var name: String
    var states: [State]
    var transitions: [Transition]
    var initial: String?

    var initialState: String { initial ?? states.first?.name ?? "idle" }

    func state(named name: String) -> State? { states.first { $0.name == name } }

    var problems: [String] {
        var out: [String] = []
        if format != BehaviourGraph.currentFormat {
            out.append("format is '\(format)', expected '\(BehaviourGraph.currentFormat)'")
        }
        if name.isEmpty { out.append("behaviour needs a name") }
        if states.isEmpty { out.append("behaviour has no states") }
        let names = Set(states.map(\.name))
        if names.count != states.count { out.append("duplicate state names") }
        if state(named: initialState) == nil {
            out.append("initial state '\(initialState)' does not exist")
        }
        for state in states {
            out += state.action.problems.map { "state '\(state.name)': \($0)" }
        }
        for transition in transitions {
            if transition.from != "*", !names.contains(transition.from) {
                out.append("transition from unknown state '\(transition.from)'")
            }
            if !names.contains(transition.to) {
                out.append("transition to unknown state '\(transition.to)'")
            }
            if transition.minimumTime < 0 || transition.minimumTime > 20 {
                out.append("transition \(transition.from)→\(transition.to): "
                           + "minimumTime \(transition.minimumTime)s is outside 0…20")
            }
        }
        // A state nothing can reach is behaviour the enemy will never show.
        let reachable = Set(transitions.map(\.to)).union([initialState])
        for state in states where !reachable.contains(state.name) {
            out.append("state '\(state.name)' has no transition into it")
        }
        // A state with no way out is a permanent freeze, which is almost never meant.
        let sources = Set(transitions.map(\.from))
        for state in states where !sources.contains(state.name)
            && !sources.contains("*") {
            out.append("state '\(state.name)' has no transition out of it")
        }
        return out
    }

    /// Load `<name>.json` from the bundle.
    static func load(named name: String, bundle: Bundle = .main) -> BehaviourGraph? {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let graph = try? JSONDecoder().decode(BehaviourGraph.self, from: data),
              graph.format == currentFormat, graph.problems.isEmpty
        else { return nil }
        return graph
    }
}

// MARK: - Codable for the two enums

extension BehaviourGraph.Action: Codable {
    private enum Key: String, CodingKey { case `do`, speed, vx, vy, cooldown }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Key.self)
        let verb = try box.decode(String.self, forKey: .do)
        func number(_ key: Key, _ fallback: CGFloat) -> CGFloat {
            (try? box.decode(CGFloat.self, forKey: key)) ?? fallback
        }
        switch verb {
        case "wait": self = .wait
        case "telegraph": self = .telegraph
        case "patrol": self = .patrol(speed: number(.speed, 60))
        case "chase": self = .chase(speed: number(.speed, 120))
        case "retreat": self = .retreat(speed: number(.speed, 90))
        case "leap": self = .leap(vx: number(.vx, 120), vy: number(.vy, 480))
        case "shoot": self = .shoot(speed: number(.speed, 300),
                                    cooldown: Double(number(.cooldown, 1.2)))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .do, in: box,
                debugDescription: "unknown behaviour action '\(verb)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Key.self)
        switch self {
        case .wait: try box.encode("wait", forKey: .do)
        case .telegraph: try box.encode("telegraph", forKey: .do)
        case .patrol(let s):
            try box.encode("patrol", forKey: .do); try box.encode(s, forKey: .speed)
        case .chase(let s):
            try box.encode("chase", forKey: .do); try box.encode(s, forKey: .speed)
        case .retreat(let s):
            try box.encode("retreat", forKey: .do); try box.encode(s, forKey: .speed)
        case .leap(let vx, let vy):
            try box.encode("leap", forKey: .do)
            try box.encode(vx, forKey: .vx); try box.encode(vy, forKey: .vy)
        case .shoot(let speed, let cooldown):
            try box.encode("shoot", forKey: .do)
            try box.encode(speed, forKey: .speed)
            try box.encode(cooldown, forKey: .cooldown)
        }
    }
}

extension BehaviourGraph.Condition: Codable {
    private enum Key: String, CodingKey {
        case always, playerWithin, playerBeyond, facingPlayer, stateTime, grounded
        case atEdge, hurt, all, any, not
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Key.self)
        // A condition is written as a small object with exactly the key that names
        // it — `{"playerWithin": 220}` — which reads far better in a hand-written
        // file than a tagged union would.
        if let d = try? box.decode(CGFloat.self, forKey: .playerWithin) {
            self = .playerWithin(d)
        } else if let d = try? box.decode(CGFloat.self, forKey: .playerBeyond) {
            self = .playerBeyond(d)
        } else if let s = try? box.decode(Double.self, forKey: .stateTime) {
            self = .stateTime(s)
        } else if let g = try? box.decode(Bool.self, forKey: .grounded) {
            self = .grounded(g)
        } else if (try? box.decode(Bool.self, forKey: .facingPlayer)) == true {
            self = .facingPlayer
        } else if (try? box.decode(Bool.self, forKey: .atEdge)) == true {
            self = .atEdge
        } else if (try? box.decode(Bool.self, forKey: .hurt)) == true {
            self = .hurt
        } else if let list = try? box.decode([BehaviourGraph.Condition].self,
                                             forKey: .all) {
            self = .all(list)
        } else if let list = try? box.decode([BehaviourGraph.Condition].self,
                                             forKey: .any) {
            self = .any(list)
        } else if let inner = try? box.decode(BehaviourGraph.Condition.self,
                                              forKey: .not) {
            self = .not(inner)
        } else {
            self = .always
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Key.self)
        switch self {
        case .always: try box.encode(true, forKey: .always)
        case .playerWithin(let d): try box.encode(d, forKey: .playerWithin)
        case .playerBeyond(let d): try box.encode(d, forKey: .playerBeyond)
        case .facingPlayer: try box.encode(true, forKey: .facingPlayer)
        case .stateTime(let s): try box.encode(s, forKey: .stateTime)
        case .grounded(let g): try box.encode(g, forKey: .grounded)
        case .atEdge: try box.encode(true, forKey: .atEdge)
        case .hurt: try box.encode(true, forKey: .hurt)
        case .all(let list): try box.encode(list, forKey: .all)
        case .any(let list): try box.encode(list, forKey: .any)
        case .not(let inner): try box.encode(inner, forKey: .not)
        }
    }
}
