import SpriteKit

/// An enemy.
///
/// Two brains, and which one runs depends on content rather than on code. When a
/// `behaviour/1` graph is supplied the graph decides everything — that is the path
/// that lets a new enemy type be a JSON file instead of a Swift class. The original
/// hardcoded patrol → alert → chase → return machine stays as the fallback, so an
/// enemy placed by a level with no behaviour named still behaves exactly as before.
///
/// Stays on its own platform, faces its movement, telegraphs the chase with a "!".
final class Enemy {

    enum State { case patrol, alert(since: TimeInterval), chase, returning }

    /// The data-driven brain, when one was supplied.
    private var brain: BehaviourRunner?
    /// Set by the scene on the frame the enemy is hit, so `hurt` conditions fire.
    private var hurtThisFrame = false
    /// What the graph last asked for — the scene reads these instead of assuming.
    private(set) var isDangerous = true
    private(set) var isVulnerable = true
    /// A projectile request the scene should honour this frame, and its speed.
    private(set) var wantsShot: CGFloat?
    /// The behaviour state name, for the state document and the debug overlay.
    var brainState: String? { brain?.current }

    let node: SKNode
    private let rig: SKNode
    private let alertMark: SKLabelNode
    private let minX: CGFloat
    private let maxX: CGFloat
    private var dir: CGFloat = 1
    private(set) var state: State = .patrol

    /// - Parameter behaviour: a `behaviour/1` graph. `nil` keeps the built-in machine.
    init(position: CGPoint, minX: CGFloat, maxX: CGFloat,
         behaviour: BehaviourGraph? = nil) {
        if let behaviour { brain = BehaviourRunner(graph: behaviour) }
        let (container, rig) = Decor.enemy()
        container.position = position
        container.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 30, height: 26))
        container.physicsBody?.isDynamic = false // kinematic: moved manually
        container.physicsBody?.categoryBitMask = PhysicsCategory.enemy
        container.physicsBody?.collisionBitMask = PhysicsCategory.none
        self.node = container
        self.rig = rig
        self.minX = minX
        self.maxX = maxX

        alertMark = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        alertMark.text = "!"
        alertMark.fontSize = 22
        alertMark.fontColor = SKColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1)
        alertMark.position = CGPoint(x: 0, y: 20)
        alertMark.alpha = 0
        container.addChild(alertMark)
    }

    /// Tell the behaviour it was hit. Consumed on the next `update`, so a one-frame
    /// flag can't be missed by a graph that only samples it later.
    func registerHit() { hurtThisFrame = true }

    func update(dt: CGFloat, now: TimeInterval, playerPos: CGPoint) {
        if brain != nil {
            updateFromGraph(dt: dt, playerPos: playerPos)
            return
        }
        let dx = playerPos.x - node.position.x
        let dy = playerPos.y - node.position.y
        let playerNearMyPlatform = playerPos.x > minX - 40 && playerPos.x < maxX + 40

        switch state {
        case .patrol:
            move(speed: Tuning.enemyPatrolSpeed, dt: dt)
            // Vision: sees ahead only, roughly same height
            let sees = abs(dx) < Tuning.enemyAlertRange
                && abs(dy) < 70
                && (dx >= 0) == (dir > 0)
            if sees {
                state = .alert(since: now)
                alertMark.removeAllActions()
                alertMark.setScale(0.4)
                alertMark.alpha = 1
                alertMark.run(.scale(to: 1.0, duration: 0.15).eased())
            }

        case .alert(let since):
            // Freeze briefly — the telegraph gives the player a beat to react
            if now - since >= Tuning.enemyAlertDelay {
                alertMark.run(.fadeOut(withDuration: 0.2))
                state = .chase
            }

        case .chase:
            dir = dx >= 0 ? 1 : -1
            move(speed: Tuning.enemyChaseSpeed, dt: dt, clampToBounds: true)
            if abs(dx) > Tuning.enemyGiveUpRange || abs(dy) > 110 || !playerNearMyPlatform {
                state = .returning
            }

        case .returning:
            let home = (minX + maxX) / 2
            dir = home >= node.position.x ? 1 : -1
            move(speed: Tuning.enemyPatrolSpeed, dt: dt)
            if abs(node.position.x - home) < 8 { state = .patrol }
        }

        rig.xScale = dir > 0 ? 1 : -1
    }

    private func move(speed: CGFloat, dt: CGFloat, clampToBounds: Bool = false) {
        node.position.x += dir * speed * dt
        if node.position.x <= minX { node.position.x = minX; if !clampToBounds { dir = 1 } }
        if node.position.x >= maxX { node.position.x = maxX; if !clampToBounds { dir = -1 } }
    }

    /// One frame of the data-driven brain.
    ///
    /// The split is the point: the graph produces an *intent* — a velocity, a facing,
    /// a clip, a request to fire — and this method is the only thing that knows about
    /// nodes, bounds and sprites. That is what lets the behaviour be stepped in a test
    /// with no scene at all.
    private func updateFromGraph(dt: CGFloat, playerPos: CGPoint) {
        guard var brain else { return }
        let dx = playerPos.x - node.position.x
        var sense = BehaviourRunner.Sense()
        sense.playerDx = dx
        sense.playerDy = playerPos.y - node.position.y
        sense.playerDistance = hypot(dx, sense.playerDy)
        sense.facing = dir
        // Kinematic: it is always "grounded" unless a leap put it in the air.
        sense.grounded = airborneUntil <= 0
        sense.atEdge = node.position.x <= minX + 2 || node.position.x >= maxX - 2
        sense.hurt = hurtThisFrame
        hurtThisFrame = false

        // Patrol direction is the scene's business because it owns the bounds; the
        // graph only asks to "patrol" and this turns it around at each end.
        if node.position.x <= minX { dir = 1 }
        if node.position.x >= maxX { dir = -1 }

        let intent = brain.step(dt: Double(dt), sense: sense, patrolDirection: dir)
        self.brain = brain

        // Apply. Clamped to the patrol run so no behaviour can walk an enemy off its
        // own platform — a graph should not be able to author a fall.
        let next = node.position.x + intent.vx * dt
        node.position.x = min(max(next, minX), maxX)
        if intent.jumpVelocity > 0 {
            airborneUntil = 0.45
            node.run(.sequence([
                .moveBy(x: 0, y: intent.jumpVelocity * 0.16, duration: 0.22).eased(),
                .moveBy(x: 0, y: -intent.jumpVelocity * 0.16, duration: 0.22).eased(),
            ]))
        }
        if airborneUntil > 0 { airborneUntil -= Double(dt) }

        if intent.facing != 0 { rig.xScale = intent.facing < 0 ? -1 : 1 }
        alertMark.alpha = intent.flash ? 1 : 0
        isDangerous = intent.dangerous
        isVulnerable = intent.vulnerable
        wantsShot = intent.shoot
        // Contact damage follows the state, so a stunned enemy stops hurting the
        // player — the classic unfair hitbox, expressed as data.
        node.physicsBody?.categoryBitMask = intent.dangerous
            ? PhysicsCategory.enemy : PhysicsCategory.none
    }

    /// Seconds left of a leap. Kinematic enemies have no gravity, so a hop is an
    /// action rather than an impulse — but the graph still needs `grounded` to mean
    /// something.
    private var airborneUntil: Double = 0
}
