import SpriteKit

/// King Blob — a three-hit boss. Pattern: telegraphed squish → hop at the
/// player → heavy landing → repeat. Each hit makes him faster and angrier.
/// Damage him by stomping his head, punching, or ground-pounding nearby.
final class Boss {

    private enum State {
        case idle(until: TimeInterval)
        case hopping
        case hurt(until: TimeInterval)
    }

    let node: SKNode
    private let rig: SKNode
    private let crown = SKNode()
    private(set) var hp = Tuning.bossHP
    private var state: State = .idle(until: 0)
    private var vy: CGFloat = 0
    private var vx: CGFloat = 0
    private let groundY: CGFloat
    var isDead: Bool { hp <= 0 }

    /// True during the hurt flicker — touching him then is safe.
    var isReeling: Bool {
        if case .hurt = state { return true }
        return false
    }

    /// Vulnerable while grounded and not already reeling.
    var isVulnerable: Bool {
        if case .hurt = state { return false }
        if case .hopping = state { return false }
        return !isDead
    }

    private var phaseSpeedup: CGFloat { 1 + CGFloat(Tuning.bossHP - hp) * 0.18 }

    init(position: CGPoint) {
        let (container, rig) = Decor.enemy()
        rig.setScale(2.3)
        self.rig = rig
        self.node = container
        node.position = position
        groundY = position.y

        // Crown: three golden points
        let crownPath = CGMutablePath()
        crownPath.move(to: CGPoint(x: -14, y: 0))
        for i in 0..<3 {
            let x = CGFloat(i) * 14 - 14
            crownPath.addLine(to: CGPoint(x: x + 7, y: 11))
            crownPath.addLine(to: CGPoint(x: x + 14, y: 0))
        }
        crownPath.closeSubpath()
        let crownShape = SKShapeNode(path: crownPath)
        crownShape.fillColor = SKColor(red: 1.0, green: 0.82, blue: 0.15, alpha: 1)
        crownShape.strokeColor = SKColor(red: 0.80, green: 0.58, blue: 0.02, alpha: 1)
        crownShape.lineWidth = 2
        crown.addChild(crownShape)
        crown.position = CGPoint(x: 0, y: 34)
        node.addChild(crown)

        node.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 64, height: 54))
        node.physicsBody?.isDynamic = false
        node.physicsBody?.categoryBitMask = PhysicsCategory.enemy
        node.physicsBody?.collisionBitMask = PhysicsCategory.none
        node.zPosition = 9
    }

    /// Returns true on the frame the boss lands (for shake + SFX).
    func update(dt: CGFloat, now: TimeInterval, playerPos: CGPoint) -> Bool {
        guard !isDead else { return false }
        switch state {
        case .idle(let until):
            if until == 0 {
                state = .idle(until: now + Tuning.bossIdleBase)
                return false
            }
            // Telegraph: compressing squish that "charges" the hop
            let remain = max(0, until - now)
            let squish = 1 - CGFloat(0.25 * (1 - remain / Tuning.bossIdleBase))
            rig.yScale = 2.3 * squish
            rig.xScale = (playerPos.x >= node.position.x ? 1 : -1) * 2.3 * (2 - squish)
            if now >= until {
                let dir: CGFloat = playerPos.x >= node.position.x ? 1 : -1
                vx = dir * Tuning.bossHopVX * phaseSpeedup
                vy = Tuning.bossHopVY
                rig.yScale = 2.3 * 1.15
                state = .hopping
            }

        case .hopping:
            vy += Tuning.gravity * 150 * dt   // same 150pt/m scale as the world
            node.position.x += vx * dt
            node.position.y += vy * dt
            if vy < 0 { rig.yScale = 2.3 * 0.95 }
            if node.position.y <= groundY && vy < 0 {
                node.position.y = groundY
                vy = 0
                rig.yScale = 2.3
                rig.xScale = (vx >= 0 ? 1 : -1) * 2.3
                let idleTime = max(0.45, Tuning.bossIdleBase - Double(Tuning.bossHP - hp) * 0.25)
                state = .idle(until: now + idleTime)
                return true // landed this frame
            }

        case .hurt(let until):
            if now >= until {
                state = .idle(until: now + 0.5)
            }
        }
        return false
    }

    /// Apply one hit. Returns true if this hit killed him.
    func hit(now: TimeInterval) -> Bool {
        guard isVulnerable else { return false }
        hp -= 1
        if let scene = node.scene {
            Audio.shared.play(isDead ? "boss_die" : "boss_hit", on: scene)
            // Duck the music under the sting, then let it come back. A boss hit
            // that the soundtrack talks over doesn't land.
            Audio.shared.duck(to: isDead ? 0.2 : 0.45, for: isDead ? 1.4 : 0.5)
            (scene as? GameScene)?.screenImpact(isDead ? 1.3 : 0.7)
        }
        state = .hurt(until: now + Tuning.bossHurtInvuln)
        rig.run(.repeat(.sequence([.fadeAlpha(to: 0.3, duration: 0.09),
                                   .fadeAlpha(to: 1.0, duration: 0.09)]), count: 5))
        if isDead {
            crown.run(.sequence([                       // crown pops off
                .group([.moveBy(x: 30, y: 90, duration: 0.5).eased(),
                        .rotate(byAngle: 1.8, duration: 0.5)]),
                .moveBy(x: 10, y: -140, duration: 0.4),
                .fadeOut(withDuration: 0.2),
            ]))
            node.physicsBody = nil
            rig.run(.sequence([
                .group([.scale(to: 0.1, duration: 0.55).eased(),
                        .rotate(byAngle: .pi * 4, duration: 0.55)]),
                .fadeOut(withDuration: 0.1),
            ]))
        }
        return isDead
    }
}
