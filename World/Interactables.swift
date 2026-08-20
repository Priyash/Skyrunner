import SpriteKit

/// The pieces that make a platformer feel like a *place* rather than a set of
/// ledges: slopes you run up, conveyors that carry you, springs, crushers,
/// updraft columns, vines and checkpoints.
///
/// Each one is a builder (visual + physics body) plus, where it needs one, a
/// controller that owns its per-frame behaviour. Keeping them here rather than in
/// `GameScene` means the scene's update loop reads as a list of systems instead
/// of a pile of special cases — and each system can be reasoned about alone.
enum Interactable {

    // MARK: Slopes

    /// A 45° ramp.
    ///
    /// SpriteKit has no slope primitive: a triangle polygon body is the whole
    /// trick. The subtlety is the *controller*, not the shape — a character
    /// driven by `velocity.dx` alone climbs a ramp by repeatedly colliding with
    /// it, which reads as stuttering. `PlayerMotion.slopeAdjust` projects the
    /// run onto the surface instead, so a slope feels like ground that happens
    /// to be tilted.
    static func slope(tile t: CGFloat, risingRight: Bool) -> SKNode {
        let node = SKSpriteNode(texture: Painter.dirt(size: CGSize(width: t, height: t)))
        node.size = CGSize(width: t, height: t)

        let path = CGMutablePath()
        let half = t / 2
        if risingRight {
            path.move(to: CGPoint(x: -half, y: -half))
            path.addLine(to: CGPoint(x: half, y: half))
            path.addLine(to: CGPoint(x: half, y: -half))
        } else {
            path.move(to: CGPoint(x: -half, y: half))
            path.addLine(to: CGPoint(x: half, y: -half))
            path.addLine(to: CGPoint(x: -half, y: -half))
        }
        path.closeSubpath()

        // Mask the dirt sprite to the triangle, so the art matches the body.
        let mask = SKShapeNode(path: path)
        mask.fillColor = .white
        mask.strokeColor = .clear
        let crop = SKCropNode()
        crop.maskNode = mask
        crop.addChild(node)

        let container = SKNode()
        container.addChild(crop)

        // A lit edge along the ramp face reads the incline at a glance.
        let edge = SKShapeNode()
        let line = CGMutablePath()
        if risingRight {
            line.move(to: CGPoint(x: -half, y: -half))
            line.addLine(to: CGPoint(x: half, y: half))
        } else {
            line.move(to: CGPoint(x: -half, y: half))
            line.addLine(to: CGPoint(x: half, y: -half))
        }
        edge.path = line
        edge.strokeColor = SKColor(red: 0.42, green: 0.78, blue: 0.36, alpha: 1)
        edge.lineWidth = 5
        edge.lineCap = .round
        edge.zPosition = 1
        container.addChild(edge)

        let body = SKPhysicsBody(polygonFrom: path)
        body.isDynamic = false
        body.friction = 0
        body.restitution = 0
        body.categoryBitMask = PhysicsCategory.ground
        container.physicsBody = body
        return container
    }

    // MARK: Conveyors

    static func conveyor(size: CGSize, rightward: Bool) -> SKNode {
        let node = Decor.ground(size: size)
        // Chevrons that animate in the carry direction — the only honest way to
        // show which way a floor is pulling before you step on it.
        let count = max(2, Int(size.width / 22))
        for i in 0..<count {
            let arrow = SKLabelNode(fontNamed: "AvenirNext-Bold")
            arrow.text = rightward ? "›" : "‹"
            arrow.fontSize = 15
            arrow.fontColor = SKColor(white: 1, alpha: 0.7)
            arrow.verticalAlignmentMode = .center
            let x = -size.width / 2 + CGFloat(i) * 22 + 11
            arrow.position = CGPoint(x: x, y: size.height / 2 - 3)
            arrow.zPosition = 3
            node.addChild(arrow)
            arrow.run(.repeatForever(.sequence([
                .wait(forDuration: Double(i) * 0.06),
                .fadeAlpha(to: 0.25, duration: 0.3),
                .fadeAlpha(to: 0.7, duration: 0.3),
            ])))
        }
        let body = SKPhysicsBody(rectangleOf: size)
        body.isDynamic = false
        body.friction = 0
        body.restitution = 0
        body.categoryBitMask = PhysicsCategory.conveyor
        node.physicsBody = body
        return node
    }

    // MARK: Springs

    static func spring(tile t: CGFloat) -> SKNode {
        let container = SKNode()
        let base = SKShapeNode(rectOf: CGSize(width: t * 0.8, height: t * 0.22),
                               cornerRadius: 4)
        base.fillColor = SKColor(red: 0.30, green: 0.32, blue: 0.42, alpha: 1)
        base.strokeColor = SKColor(red: 0.16, green: 0.18, blue: 0.26, alpha: 1)
        base.lineWidth = 2
        base.position = CGPoint(x: 0, y: -t * 0.32)
        container.addChild(base)

        let pad = SKShapeNode(rectOf: CGSize(width: t * 0.7, height: t * 0.2),
                              cornerRadius: 6)
        pad.fillColor = SKColor(red: 1.0, green: 0.78, blue: 0.22, alpha: 1)
        pad.strokeColor = SKColor(red: 0.72, green: 0.45, blue: 0.05, alpha: 1)
        pad.lineWidth = 2.5
        pad.position = CGPoint(x: 0, y: -t * 0.1)
        pad.name = "pad"
        container.addChild(pad)

        for i in 0..<3 {                      // coil
            let coil = SKShapeNode(rectOf: CGSize(width: t * 0.5 - CGFloat(i) * 3, height: 3),
                                   cornerRadius: 1.5)
            coil.fillColor = SKColor(white: 0.75, alpha: 0.9)
            coil.strokeColor = .clear
            coil.position = CGPoint(x: 0, y: -t * 0.2 - CGFloat(i) * 4)
            container.addChild(coil)
        }

        let body = SKPhysicsBody(rectangleOf: CGSize(width: t * 0.7, height: t * 0.3),
                                 center: CGPoint(x: 0, y: -t * 0.2))
        body.isDynamic = false
        body.friction = 0
        body.restitution = 0
        body.categoryBitMask = PhysicsCategory.spring
        container.physicsBody = body
        return container
    }

    /// Squash the pad on launch — the feedback that says *that* was the spring.
    static func fireSpring(_ node: SKNode) {
        guard let pad = node.childNode(withName: "pad") else { return }
        pad.removeAllActions()
        pad.run(.sequence([
            .scaleY(to: 0.35, duration: 0.04),
            .scaleY(to: 1.25, duration: 0.09),
            .scaleY(to: 1.0, duration: 0.10),
        ]))
    }

    // MARK: Climbable vines

    static func vine(tile t: CGFloat, index: Int) -> SKNode {
        let container = SKNode()
        let strand = SKShapeNode()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -t / 2))
        path.addQuadCurve(to: CGPoint(x: 0, y: t / 2),
                          control: CGPoint(x: (index % 2 == 0 ? 5 : -5), y: 0))
        strand.path = path
        strand.strokeColor = SKColor(red: 0.28, green: 0.58, blue: 0.26, alpha: 1)
        strand.lineWidth = 5
        strand.lineCap = .round
        container.addChild(strand)
        for side in [-1.0, 1.0] {
            let leaf = SKShapeNode(ellipseOf: CGSize(width: 13, height: 7))
            leaf.fillColor = SKColor(red: 0.40, green: 0.74, blue: 0.32, alpha: 1)
            leaf.strokeColor = .clear
            leaf.position = CGPoint(x: CGFloat(side) * 7,
                                    y: CGFloat(index % 3) * 6 - 6)
            leaf.zRotation = CGFloat(side) * 0.4
            container.addChild(leaf)
        }
        // Sensor only: climbing is a controller state, not a collision response.
        let body = SKPhysicsBody(rectangleOf: CGSize(width: t * 0.5, height: t))
        body.isDynamic = false
        body.categoryBitMask = PhysicsCategory.climbable
        body.collisionBitMask = PhysicsCategory.none
        container.physicsBody = body
        return container
    }

    // MARK: Updraft columns

    static func updraft(tile t: CGFloat) -> SKNode {
        let container = SKNode()
        let shaft = SKShapeNode(rectOf: CGSize(width: t * 0.9, height: t), cornerRadius: 6)
        shaft.fillColor = SKColor(red: 0.62, green: 0.86, blue: 1.0, alpha: 0.16)
        shaft.strokeColor = SKColor(red: 0.72, green: 0.92, blue: 1.0, alpha: 0.30)
        shaft.lineWidth = 1.5
        container.addChild(shaft)
        for i in 0..<3 {                      // rising motes
            let mote = SKShapeNode(circleOfRadius: 2.5)
            mote.fillColor = SKColor(white: 1, alpha: 0.7)
            mote.strokeColor = .clear
            mote.position = CGPoint(x: CGFloat(i - 1) * 9, y: -t / 2)
            container.addChild(mote)
            mote.run(.repeatForever(.sequence([
                .wait(forDuration: Double(i) * 0.25),
                .group([.moveBy(x: 0, y: t, duration: 0.9),
                        .fadeOut(withDuration: 0.9)]),
                .run { mote.position.y = -t / 2; mote.alpha = 1 },
            ])))
        }
        let body = SKPhysicsBody(rectangleOf: CGSize(width: t * 0.9, height: t))
        body.isDynamic = false
        body.categoryBitMask = PhysicsCategory.updraft
        body.collisionBitMask = PhysicsCategory.none
        container.physicsBody = body
        return container
    }

    // MARK: Checkpoints

    static func checkpoint(tile t: CGFloat) -> SKNode {
        let container = SKNode()
        let pole = SKShapeNode(rectOf: CGSize(width: 4, height: t * 1.5), cornerRadius: 2)
        pole.fillColor = SKColor(white: 0.85, alpha: 1)
        pole.strokeColor = SKColor(white: 0.55, alpha: 1)
        pole.position = CGPoint(x: 0, y: t * 0.4)
        container.addChild(pole)

        let flag = SKShapeNode(path: {
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 22, y: -6))
            p.addLine(to: CGPoint(x: 0, y: -13))
            p.closeSubpath()
            return p
        }())
        flag.fillColor = SKColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)
        flag.strokeColor = SKColor(red: 0.15, green: 0.32, blue: 0.70, alpha: 1)
        flag.lineWidth = 2
        flag.position = CGPoint(x: 2, y: t * 1.05)
        flag.name = "flag"
        container.addChild(flag)

        let body = SKPhysicsBody(rectangleOf: CGSize(width: t * 0.6, height: t * 1.6),
                                 center: CGPoint(x: 0, y: t * 0.4))
        body.isDynamic = false
        body.categoryBitMask = PhysicsCategory.checkpoint
        body.collisionBitMask = PhysicsCategory.none
        container.physicsBody = body
        return container
    }

    /// Claim it: the flag turns gold and snaps up. Idempotent, because the
    /// contact fires every time the player walks back through.
    static func claimCheckpoint(_ node: SKNode) -> Bool {
        guard let flag = node.childNode(withName: "flag") as? SKShapeNode,
              flag.userData?["claimed"] == nil else { return false }
        flag.userData = ["claimed": true]
        flag.fillColor = SKColor(red: 1.0, green: 0.82, blue: 0.22, alpha: 1)
        flag.strokeColor = SKColor(red: 0.72, green: 0.50, blue: 0.05, alpha: 1)
        flag.run(.sequence([.scale(to: 1.4, duration: 0.12),
                            .scale(to: 1.0, duration: 0.14)]))
        return true
    }

    // MARK: Crushers

    /// A block that drops, holds, and grinds back up.
    ///
    /// Kinematic rather than dynamic: a falling *dynamic* body would push the
    /// player through the floor and fight the character controller. Driving the
    /// position directly keeps the motion exact and repeatable, which is what a
    /// timing hazard needs.
    final class Crusher {
        enum Phase { case idle, falling, holding, rising }

        let node: SKNode
        private let topY: CGFloat
        private var bottomY: CGFloat
        private var phase: Phase = .idle
        private var until: TimeInterval = 0

        /// True while it is coming down — the only window in which it kills.
        var isDangerous: Bool { phase == .falling }

        init(position: CGPoint, tile t: CGFloat, floorY: CGFloat, phaseOffset: TimeInterval) {
            let box = SKSpriteNode(texture: Painter.crate(side: t * 0.95))
            box.size = CGSize(width: t, height: t)
            let spikes = SKShapeNode(path: {
                let p = CGMutablePath()
                let n = 4
                for i in 0..<n {
                    let x = -t / 2 + t * (CGFloat(i) + 0.5) / CGFloat(n)
                    p.move(to: CGPoint(x: x - t / CGFloat(n) / 2, y: -t / 2))
                    p.addLine(to: CGPoint(x: x, y: -t / 2 - 8))
                    p.addLine(to: CGPoint(x: x + t / CGFloat(n) / 2, y: -t / 2))
                }
                return p
            }())
            spikes.fillColor = SKColor(white: 0.72, alpha: 1)
            spikes.strokeColor = SKColor(white: 0.35, alpha: 1)
            spikes.lineWidth = 1.5
            box.addChild(spikes)

            let container = SKNode()
            container.addChild(box)
            container.position = position
            let body = SKPhysicsBody(rectangleOf: CGSize(width: t, height: t + 8),
                                     center: CGPoint(x: 0, y: -4))
            body.isDynamic = false
            body.friction = 0
            body.restitution = 0
            body.categoryBitMask = PhysicsCategory.ground
            body.contactTestBitMask = PhysicsCategory.player
            container.physicsBody = body

            self.node = container
            self.topY = position.y
            self.bottomY = floorY + t * 0.55
            self.until = phaseOffset
        }

        func update(now: TimeInterval, dt: CGFloat) {
            switch phase {
            case .idle:
                if now >= until { phase = .falling }
            case .falling:
                node.position.y += Tuning.crusherFallSpeed * dt
                if node.position.y <= bottomY {
                    node.position.y = bottomY
                    phase = .holding
                    until = now + Tuning.crusherHold
                    // On the landing frame only. Playing this during `.falling`
                    // would grind continuously and drown the level.
                    if let scene = node.scene { Audio.shared.play("crusher", on: scene) }
                }
            case .holding:
                if now >= until { phase = .rising }
            case .rising:
                node.position.y += Tuning.crusherRetractSpeed * dt
                if node.position.y >= topY {
                    node.position.y = topY
                    phase = .idle
                    until = now + Tuning.crusherIdle
                }
            }
        }
    }
}
