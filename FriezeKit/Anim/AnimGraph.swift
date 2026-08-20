import SpriteKit

/// A declarative animation state machine with blend trees.
///
/// What it replaces: a chain of `if` statements in `SkeletalPlayer.update` that
/// picked a clip name. That works, and it is what shipped — but it has three
/// problems a state machine doesn't. Transitions can't have *conditions* beyond
/// the current frame's booleans, so "don't leave `land` until it has played" needs
/// an ad-hoc timer per case. Blends can't be *parameterised*, so a run cycle
/// can't speed up smoothly with velocity. And the graph is code, so a rig author
/// can't retarget it or an editor visualise it.
///
/// This is data:
///
/// ```swift
/// AnimGraph(states: [
///     .init(name: "idle", clip: .single("idle")),
///     .init(name: "run",  clip: .speed("run", parameter: "speed",
///                                     range: .init(120, 420), rate: .init(0.7, 1.5))),
///     .init(name: "air",  clip: .blend1D(["jump", "fall"], parameter: "vy",
///                                        range: .init(300, -600))),
/// ], transitions: [
///     .init(from: "*", to: "air", when: .isFalse("grounded"), mix: 0.10),
///     .init(from: "air", to: "land", when: .isTrue("grounded"), mix: 0.04),
///     .init(from: "land", to: "idle", when: .clipFinished, mix: 0.10),
/// ])
/// ```
///
/// The engine drives it with named parameters each frame; the graph decides what
/// plays and how it is mixed. `SkeletalPlayer` keeps its old path as the fallback
/// for a rig whose clips the graph doesn't cover, so this is additive.
struct AnimGraph {

    // MARK: Clip selection

    /// An ordered pair, which `ClosedRange` cannot be.
    ///
    /// A falling `vy` blend runs from +300 to −600, and `300 ... -600` *traps* in
    /// Swift — `ClosedRange` requires lower ≤ upper. Forcing the author to invert
    /// the mapping by hand is exactly how blend trees end up subtly backwards, so
    /// the type allows a descending span instead.
    struct Span {
        var from: CGFloat
        var to: CGFloat

        init(_ from: CGFloat, _ to: CGFloat) { self.from = from; self.to = to }

        var isDegenerate: Bool { from == to }

        /// 0 at `from`, 1 at `to`, clamped.
        func fraction(_ value: CGFloat) -> CGFloat {
            guard from != to else { return 0 }
            return max(0, min(1, (value - from) / (to - from)))
        }
    }

    /// How a state turns parameters into playing clips.
    enum ClipSource {
        /// One clip, played at its authored rate.
        case single(String)
        /// One clip whose *playback rate* follows a parameter — a run cycle that
        /// speeds up with the player instead of sliding.
        case speed(String, parameter: String, range: Span, rate: Span)
        /// A 1D blend tree: N clips laid out along a parameter, cross-faded
        /// between the two nearest. This is what makes rise→fall continuous
        /// rather than a switch at vy = 0.
        ///
        /// `range.from → clips.first`, `range.to → clips.last`; descending is fine.
        case blend1D([String], parameter: String, range: Span)

        var clipNames: [String] {
            switch self {
            case .single(let name): return [name]
            case .speed(let name, _, _, _): return [name]
            case .blend1D(let names, _, _): return names
            }
        }
    }

    /// One clip to play this frame, with a weight and a rate.
    struct Playing: Equatable {
        var clip: String
        var weight: CGFloat
        var rate: CGFloat
    }

    // MARK: Conditions

    /// A transition guard. Deliberately a small closed set rather than a closure:
    /// a closure can't be serialised, compared, or shown in an editor.
    enum Condition {
        case always
        case isTrue(String)
        case isFalse(String)
        case greater(String, CGFloat)
        case less(String, CGFloat)
        /// The current state's longest clip has played through once. This is the
        /// condition that removes every hand-rolled timer.
        case clipFinished
        case all([Condition])
        case any([Condition])

        func holds(_ p: Parameters, stateTime: TimeInterval,
                   stateDuration: TimeInterval) -> Bool {
            switch self {
            case .always: return true
            case .isTrue(let key): return p.flag(key)
            case .isFalse(let key): return !p.flag(key)
            case .greater(let key, let value): return p.number(key) > value
            case .less(let key, let value): return p.number(key) < value
            case .clipFinished: return stateDuration > 0 && stateTime >= stateDuration
            case .all(let list):
                return list.allSatisfy { $0.holds(p, stateTime: stateTime,
                                                  stateDuration: stateDuration) }
            case .any(let list):
                return list.contains { $0.holds(p, stateTime: stateTime,
                                                stateDuration: stateDuration) }
            }
        }

        /// Parameter names this condition reads — so a graph can be checked against
        /// what the engine actually supplies.
        var parameters: [String] {
            switch self {
            case .always, .clipFinished: return []
            case .isTrue(let k), .isFalse(let k): return [k]
            case .greater(let k, _), .less(let k, _): return [k]
            case .all(let l), .any(let l): return l.flatMap(\.parameters)
            }
        }
    }

    /// What the engine tells the graph each frame.
    struct Parameters {
        var flags: [String: Bool] = [:]
        var numbers: [String: CGFloat] = [:]

        func flag(_ key: String) -> Bool { flags[key] ?? false }
        func number(_ key: String) -> CGFloat { numbers[key] ?? 0 }

        mutating func set(_ key: String, _ value: Bool) { flags[key] = value }
        mutating func set(_ key: String, _ value: CGFloat) { numbers[key] = value }
    }

    // MARK: Graph

    struct State {
        var name: String
        var clip: ClipSource
        var loops: Bool = true
        /// Interrupt priority. A higher-priority transition wins when several are
        /// eligible on the same frame, which is how "hurt beats everything" is
        /// expressed without ordering the array by hand.
        var priority: Int = 0
    }

    struct Transition {
        /// Source state, or `*` for any.
        var from: String
        var to: String
        var when: Condition
        /// Crossfade seconds.
        var mix: TimeInterval = 0.12
        var priority: Int = 0
        /// Refuse to leave before the source clip has played this fraction. Stops
        /// a one-frame flicker from cutting an impact pose off at 2 frames.
        var minimumTime: TimeInterval = 0
    }

    var states: [State]
    var transitions: [Transition]
    var initialState: String

    init(states: [State], transitions: [Transition], initial: String? = nil) {
        self.states = states
        self.transitions = transitions
        self.initialState = initial ?? states.first?.name ?? "idle"
    }

    func state(named name: String) -> State? { states.first { $0.name == name } }

    /// Every clip the graph can ask for. Used to check a rig can drive it.
    var clipNames: Set<String> {
        Set(states.flatMap { $0.clip.clipNames })
    }

    /// Structural problems — a graph that names a state no transition can reach is
    /// a character that can never play that animation.
    func problems(availableClips: Set<String>) -> [String] {
        var out: [String] = []
        let names = Set(states.map(\.name))
        if names.count != states.count { out.append("duplicate state names") }
        if state(named: initialState) == nil {
            out.append("initial state '\(initialState)' does not exist")
        }
        for clip in clipNames where !availableClips.contains(clip) {
            out.append("state clip '\(clip)' is not in the rig")
        }
        for transition in transitions {
            if transition.from != "*", !names.contains(transition.from) {
                out.append("transition from unknown state '\(transition.from)'")
            }
            if !names.contains(transition.to) {
                out.append("transition to unknown state '\(transition.to)'")
            }
        }
        let reachable = Set(transitions.map(\.to)).union([initialState])
        for state in states where !reachable.contains(state.name) {
            out.append("state '\(state.name)' has no transition into it")
        }
        for state in states {
            if case .blend1D(let clips, _, let range) = state.clip {
                if clips.count < 2 {
                    out.append("state '\(state.name)' blends \(clips.count) clip(s)")
                }
                if range.isDegenerate {
                    out.append("state '\(state.name)' has a zero-width blend range")
                }
            }
            if case .speed(_, _, let range, let rate) = state.clip {
                if rate.from <= 0 || rate.to <= 0 {
                    out.append("state '\(state.name)' has a non-positive rate")
                }
                if range.isDegenerate {
                    out.append("state '\(state.name)' has a zero-width speed range")
                }
            }
        }
        return out
    }
}

/// Runs an `AnimGraph`: holds the current state, evaluates transitions, and turns
/// the active state into weighted clips.
struct AnimGraphRunner {

    let graph: AnimGraph
    private(set) var current: String
    private(set) var previous: String?
    private(set) var stateTime: TimeInterval = 0
    /// Remaining crossfade, so the runner reports both clips while blending.
    private(set) var fadeRemaining: TimeInterval = 0
    private var fadeTotal: TimeInterval = 0
    /// How long the current state's clip runs, supplied by the rig.
    private var durations: [String: TimeInterval]

    init(graph: AnimGraph, clipDurations: [String: TimeInterval]) {
        self.graph = graph
        self.current = graph.initialState
        self.durations = clipDurations
    }

    private func duration(of stateName: String) -> TimeInterval {
        guard let state = graph.state(named: stateName) else { return 0 }
        return state.clip.clipNames.compactMap { durations[$0] }.max() ?? 0
    }

    /// Advance. Returns the clips to play, with weights summing to 1.
    mutating func step(dt: TimeInterval, parameters: AnimGraph.Parameters)
        -> [AnimGraph.Playing] {
        stateTime += dt
        if fadeRemaining > 0 { fadeRemaining = max(0, fadeRemaining - dt) }

        // Pick the highest-priority eligible transition. Evaluating all of them
        // and sorting — rather than taking the first match — is what makes
        // priority mean something and keeps the array order irrelevant.
        let stateDuration = duration(of: current)
        let eligible = graph.transitions.filter { transition in
            guard transition.from == "*" || transition.from == current else { return false }
            guard transition.to != current else { return false }
            guard stateTime >= transition.minimumTime else { return false }
            return transition.when.holds(parameters, stateTime: stateTime,
                                         stateDuration: stateDuration)
        }
        if let taken = eligible.max(by: { $0.priority < $1.priority }) {
            previous = current
            current = taken.to
            stateTime = 0
            fadeTotal = taken.mix
            fadeRemaining = taken.mix
        }

        var playing = clips(for: current, parameters: parameters)
        // During a crossfade the outgoing state still contributes, so the caller
        // gets a complete picture and can drive additive tracks with it.
        if fadeRemaining > 0, fadeTotal > 0, let previous {
            let outgoing = CGFloat(fadeRemaining / fadeTotal)
            for index in playing.indices { playing[index].weight *= (1 - outgoing) }
            playing += clips(for: previous, parameters: parameters).map {
                AnimGraph.Playing(clip: $0.clip, weight: $0.weight * outgoing,
                                  rate: $0.rate)
            }
        }
        return playing
    }

    private func clips(for stateName: String,
                       parameters: AnimGraph.Parameters) -> [AnimGraph.Playing] {
        guard let state = graph.state(named: stateName) else { return [] }
        switch state.clip {
        case .single(let name):
            return [.init(clip: name, weight: 1, rate: 1)]

        case .speed(let name, let parameter, let range, let rate):
            let t = range.fraction(parameters.number(parameter))
            return [.init(clip: name, weight: 1,
                          rate: rate.from + (rate.to - rate.from) * t)]

        case .blend1D(let names, let parameter, let range):
            guard names.count >= 2 else {
                return names.first.map { [.init(clip: $0, weight: 1, rate: 1)] } ?? []
            }
            let t = range.fraction(parameters.number(parameter))
            // Position along the clip list, then cross-fade the two neighbours.
            let position = t * CGFloat(names.count - 1)
            let low = min(names.count - 1, max(0, Int(position)))
            let high = min(names.count - 1, low + 1)
            let f = position - CGFloat(low)
            if low == high { return [.init(clip: names[low], weight: 1, rate: 1)] }
            return [.init(clip: names[low], weight: 1 - f, rate: 1),
                    .init(clip: names[high], weight: f, rate: 1)]
        }
    }

}

// MARK: - The shipped player graph

extension AnimGraph {

    /// The hero's graph.
    ///
    /// Written out rather than generated so it is readable as *design*: the shape
    /// of this graph is the character's feel. Three things it expresses that the
    /// previous `if` chain could not:
    ///
    /// * `run` is a **speed-parameterised** clip, so the cycle matches the ground
    ///   speed instead of sliding — the single most noticeable animation flaw in a
    ///   platformer.
    /// * `air` is a **blend** between rise and fall driven by vertical velocity,
    ///   so the apex is a continuous pose change rather than a switch at vy = 0.
    /// * `land`, `punch` and `hurt` leave on `.clipFinished`, which removes the
    ///   hand-rolled timers that used to guard them.
    static func player() -> AnimGraph {
        AnimGraph(states: [
            .init(name: "idle", clip: .single("idle")),
            .init(name: "run", clip: .speed("run", parameter: "speed",
                                            range: Span(90, 420),
                                            rate: Span(0.72, 1.55))),
            .init(name: "air", clip: .blend1D(["jump", "fall"], parameter: "vy",
                                              range: Span(320, -520))),
            .init(name: "land", clip: .single("land"), loops: false),
            .init(name: "dash", clip: .single("dash"), loops: false),
            .init(name: "climb", clip: .speed("climb", parameter: "climbSpeed",
                                              range: Span(0, 180),
                                              rate: Span(0.3, 1.4))),
            .init(name: "punch", clip: .single("punch"), loops: false, priority: 5),
            .init(name: "hurt", clip: .single("hurt"), loops: false, priority: 9),
            .init(name: "victory", clip: .single("victory"), loops: false, priority: 10),
        ], transitions: [
            // Interrupts, highest priority first. `from: "*"` because being hit
            // has to override whatever was playing.
            .init(from: "*", to: "hurt", when: .isTrue("hurt"), mix: 0.05, priority: 90),
            .init(from: "*", to: "victory", when: .isTrue("victory"),
                  mix: 0.12, priority: 95),
            .init(from: "*", to: "punch", when: .isTrue("punch"),
                  mix: 0.05, priority: 70),
            .init(from: "*", to: "dash", when: .isTrue("dashing"),
                  mix: 0.05, priority: 60),
            .init(from: "*", to: "climb", when: .isTrue("climbing"),
                  mix: 0.12, priority: 50),

            // Leaving the one-shots. `minimumTime` keeps a one-frame input blip
            // from cutting an impact pose off after two frames.
            .init(from: "punch", to: "idle", when: .clipFinished, mix: 0.10),
            .init(from: "hurt", to: "idle", when: .clipFinished, mix: 0.12),
            .init(from: "dash", to: "idle", when: .isFalse("dashing"), mix: 0.10),
            .init(from: "climb", to: "idle", when: .isFalse("climbing"), mix: 0.14),
            .init(from: "land", to: "run",
                  when: .all([.isTrue("grounded"), .greater("speed", 40)]),
                  mix: 0.08, minimumTime: 0.10),
            .init(from: "land", to: "idle", when: .clipFinished, mix: 0.10,
                  minimumTime: 0.10),

            // Airborne / grounded, the ordinary locomotion cycle.
            .init(from: "*", to: "air", when: .isFalse("grounded"), mix: 0.10,
                  priority: 20),
            .init(from: "air", to: "land", when: .isTrue("grounded"), mix: 0.04,
                  priority: 30),
            .init(from: "idle", to: "run", when: .greater("speed", 40), mix: 0.12),
            .init(from: "run", to: "idle", when: .less("speed", 25), mix: 0.18),
        ], initial: "idle")
    }
}
