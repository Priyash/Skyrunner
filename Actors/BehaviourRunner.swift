import SpriteKit

/// Runs a `BehaviourGraph`: senses in, intent out.
///
/// Never touches the scene, for the same reason `PlayerMotion` and `TriggerRuntime`
/// don't: enemy logic is where "why did it do that?" bugs live, and it is only cheap
/// to answer if the whole thing can be stepped frame by frame in a test with no
/// physics world.
struct BehaviourRunner {

    /// What the scene tells the behaviour about the frame.
    struct Sense {
        /// Signed x distance to the player: positive means the player is to the right.
        var playerDx: CGFloat = 0
        var playerDy: CGFloat = 0
        var playerDistance: CGFloat = .greatestFiniteMagnitude
        /// Which way the enemy is currently facing: +1 right, −1 left.
        var facing: CGFloat = 1
        var grounded: Bool = true
        /// At the end of its patrol run, so a patroller turns instead of walking off.
        var atEdge: Bool = false
        var hurt: Bool = false

        /// Is the enemy looking at the player? Derived rather than passed, so the
        /// scene can't get it inconsistent with `facing`.
        var facingPlayer: Bool {
            playerDx == 0 ? true : (playerDx > 0) == (facing > 0)
        }
    }

    /// What the behaviour wants to happen. The scene decides how to apply it.
    struct Intent: Equatable {
        /// Horizontal velocity in points per second.
        var vx: CGFloat = 0
        /// One-shot vertical impulse. Non-zero only on the frame a leap starts.
        var jumpVelocity: CGFloat = 0
        /// Facing the enemy should adopt.
        var facing: CGFloat = 1
        var clip: String?
        var flash: Bool = false
        var dangerous: Bool = true
        var vulnerable: Bool = true
        /// Fire a projectile this frame, at this speed.
        var shoot: CGFloat?
        /// State name, for debugging and for the state document.
        var state: String = ""
    }

    let graph: BehaviourGraph
    private(set) var current: String
    private(set) var stateTime: Double = 0
    /// Shot cooldown, so a `shoot` state fires on a rhythm rather than every frame.
    private var nextShotAt: Double = 0
    private var clock: Double = 0
    /// A leap is an impulse, not a velocity: it must fire once per state entry.
    private var leapSpent = false

    init(graph: BehaviourGraph) {
        self.graph = graph
        current = graph.initialState
    }

    /// One frame.
    mutating func step(dt: Double, sense: Sense,
                       patrolDirection: CGFloat) -> Intent {
        clock += dt
        stateTime += dt

        // Highest-priority eligible transition wins, so array order is irrelevant
        // and "hurt interrupts everything" is expressible as a number.
        let eligible = graph.transitions.filter { transition in
            guard transition.from == "*" || transition.from == current else { return false }
            guard transition.to != current else { return false }
            guard stateTime >= transition.minimumTime else { return false }
            return transition.when.holds(sense, stateTime: stateTime)
        }
        if let taken = eligible.max(by: { $0.priority < $1.priority }) {
            current = taken.to
            stateTime = 0
            leapSpent = false
        }

        guard let state = graph.state(named: current) else {
            return Intent(facing: sense.facing, state: current)
        }
        var intent = Intent(facing: sense.facing, clip: state.clip,
                            flash: state.flash, dangerous: state.dangerous,
                            vulnerable: state.vulnerable, state: current)

        switch state.action {
        case .wait, .telegraph:
            intent.vx = 0

        case .patrol(let speed):
            // Turning is the scene's business (it owns the bounds); the behaviour
            // just walks the direction it is given.
            intent.vx = patrolDirection * speed
            intent.facing = patrolDirection >= 0 ? 1 : -1

        case .chase(let speed):
            let towards: CGFloat = sense.playerDx >= 0 ? 1 : -1
            intent.vx = towards * speed
            intent.facing = towards

        case .retreat(let speed):
            let away: CGFloat = sense.playerDx >= 0 ? -1 : 1
            intent.vx = away * speed
            // Still looking at the player while backing off, which reads as fear
            // rather than as fleeing blindly.
            intent.facing = sense.playerDx >= 0 ? 1 : -1

        case .leap(let vx, let vy):
            let towards: CGFloat = sense.playerDx >= 0 ? 1 : -1
            intent.facing = towards
            if !leapSpent, sense.grounded {
                intent.vx = towards * vx
                intent.jumpVelocity = vy
                leapSpent = true
            } else {
                // Mid-air: keep the horizontal drift, add no more impulse.
                intent.vx = towards * vx
            }

        case .shoot(let speed, let cooldown):
            intent.vx = 0
            intent.facing = sense.playerDx >= 0 ? 1 : -1
            if clock >= nextShotAt {
                intent.shoot = speed
                nextShotAt = clock + cooldown
            }
        }
        return intent
    }

    mutating func reset() {
        current = graph.initialState
        stateTime = 0
        leapSpent = false
        nextShotAt = 0
    }
}

// MARK: - The shipped behaviours

extension BehaviourGraph {

    /// Every bundled behaviour, by name. Walked by the audit and the tests.
    static let shippedNames = ["behaviour_patroller", "behaviour_hopper",
                              "behaviour_charger", "behaviour_sentry"]

    /// The original hardcoded enemy, now expressed as data — which is the proof that
    /// the format can say what the Swift version said.
    static func patroller() -> BehaviourGraph {
        BehaviourGraph(
            name: "patroller",
            states: [
                .init(name: "patrol", action: .patrol(speed: 62), clip: "run"),
                .init(name: "alert", action: .telegraph, clip: "idle", flash: true),
                .init(name: "chase", action: .chase(speed: 128), clip: "run"),
                .init(name: "recover", action: .wait, clip: "idle",
                      dangerous: false, vulnerable: true),
            ],
            transitions: [
                .init(from: "*", to: "recover", when: .hurt, priority: 90),
                .init(from: "recover", to: "patrol", when: .stateTime(0.7)),
                .init(from: "patrol", to: "alert",
                      when: .all([.playerWithin(200), .facingPlayer])),
                // The telegraph is what makes the chase fair: 0.35s of warning, and
                // `minimumTime` stops a sense blip cutting it short.
                .init(from: "alert", to: "chase", when: .stateTime(0.35),
                      minimumTime: 0.35),
                .init(from: "chase", to: "patrol", when: .playerBeyond(320)),
            ],
            initial: "patrol")
    }

    /// Crouch, leap at the player, land, repeat. Reads as an animal.
    static func hopper() -> BehaviourGraph {
        BehaviourGraph(
            name: "hopper",
            states: [
                .init(name: "crouch", action: .wait, clip: "idle"),
                .init(name: "wind", action: .telegraph, clip: "idle", flash: true),
                .init(name: "leap", action: .leap(vx: 150, vy: 520), clip: "jump"),
                .init(name: "land", action: .wait, clip: "idle"),
            ],
            transitions: [
                .init(from: "crouch", to: "wind", when: .playerWithin(260)),
                .init(from: "wind", to: "leap", when: .stateTime(0.3),
                      minimumTime: 0.3),
                // Leaving the leap needs `minimumTime`: on the frame it starts the
                // enemy is still grounded, so `grounded: true` would end it instantly.
                .init(from: "leap", to: "land", when: .grounded(true),
                      minimumTime: 0.25),
                .init(from: "land", to: "crouch", when: .stateTime(0.4)),
                .init(from: "crouch", to: "crouch", when: .playerBeyond(400)),
            ],
            initial: "crouch")
    }

    /// Winds up, then charges fast and overshoots — punishes standing still.
    static func charger() -> BehaviourGraph {
        BehaviourGraph(
            name: "charger",
            states: [
                .init(name: "watch", action: .patrol(speed: 40), clip: "run"),
                .init(name: "wind", action: .telegraph, clip: "idle", flash: true,
                      vulnerable: true),
                .init(name: "charge", action: .chase(speed: 290), clip: "run"),
                .init(name: "stagger", action: .wait, clip: "hurt",
                      dangerous: false),
            ],
            transitions: [
                .init(from: "*", to: "stagger", when: .hurt, priority: 90),
                .init(from: "stagger", to: "watch", when: .stateTime(0.9)),
                .init(from: "watch", to: "wind",
                      when: .all([.playerWithin(300), .facingPlayer])),
                .init(from: "wind", to: "charge", when: .stateTime(0.5),
                      minimumTime: 0.5),
                // A charge that ends when the player is close would be unavoidable;
                // ending on distance *or* time makes it dodgeable.
                .init(from: "charge", to: "stagger",
                      when: .any([.stateTime(1.4), .atEdge])),
            ],
            initial: "watch")
    }

    /// Holds position and fires on a rhythm. The ranged threat.
    static func sentry() -> BehaviourGraph {
        BehaviourGraph(
            name: "sentry",
            states: [
                .init(name: "scan", action: .wait, clip: "idle"),
                .init(name: "aim", action: .telegraph, clip: "idle", flash: true),
                .init(name: "fire", action: .shoot(speed: 300, cooldown: 1.1),
                      clip: "punch"),
                .init(name: "back", action: .retreat(speed: 110), clip: "run"),
            ],
            transitions: [
                .init(from: "scan", to: "aim",
                      when: .all([.playerWithin(360), .facingPlayer])),
                .init(from: "aim", to: "fire", when: .stateTime(0.4),
                      minimumTime: 0.4),
                // Too close and it backs off rather than being a free stomp.
                .init(from: "fire", to: "back", when: .playerWithin(90), priority: 20),
                .init(from: "back", to: "scan", when: .playerBeyond(180)),
                .init(from: "fire", to: "scan", when: .playerBeyond(400)),
            ],
            initial: "scan")
    }

    static func shipped() -> [BehaviourGraph] {
        [patroller(), hopper(), charger(), sentry()]
    }
}
