import SpriteKit

/// Friendly villager: idles, then waves and pops a speech bubble when the
/// player comes close. Purely charming — no gameplay effect.
final class Villager {
    let node = SKNode()
    private let rig = SKNode()
    private let hand = SKShapeNode(circleOfRadius: 4.5)
    private let bubble = SKNode()
    private var lastGreeting: TimeInterval = -10

    init(position: CGPoint) {
        node.position = position
        node.zPosition = 5
        node.addChild(rig)

        let body = SKShapeNode(circleOfRadius: 11)
        body.fillColor = SKColor(red: 0.25, green: 0.78, blue: 0.72, alpha: 1)
        body.strokeColor = SKColor(red: 0.10, green: 0.50, blue: 0.46, alpha: 1)
        body.lineWidth = 2.5
        body.position = CGPoint(x: 0, y: -5)
        rig.addChild(body)

        for x in [CGFloat(-3.5), 3.5] {
            let eye = SKShapeNode(circleOfRadius: 2.6)
            eye.fillColor = .white
            eye.strokeColor = .clear
            eye.position = CGPoint(x: x, y: 1)
            body.addChild(eye)
            let pupil = SKShapeNode(circleOfRadius: 1.2)
            pupil.fillColor = .black
            pupil.strokeColor = .clear
            pupil.position = CGPoint(x: x, y: 1)
            body.addChild(pupil)
        }

        let hat = SKShapeNode(rectOf: CGSize(width: 14, height: 7), cornerRadius: 3)
        hat.fillColor = SKColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1)
        hat.strokeColor = .clear
        hat.position = CGPoint(x: 0, y: 8)
        body.addChild(hat)

        hand.fillColor = SKColor(red: 0.25, green: 0.78, blue: 0.72, alpha: 1)
        hand.strokeColor = SKColor(red: 0.10, green: 0.50, blue: 0.46, alpha: 1)
        hand.lineWidth = 2
        hand.position = CGPoint(x: 13, y: 0)
        rig.addChild(hand)

        // Speech bubble ("Hi!") — hidden until greeting
        let bg = SKShapeNode(rectOf: CGSize(width: 40, height: 24), cornerRadius: 10)
        bg.fillColor = .white
        bg.strokeColor = SKColor(white: 0.6, alpha: 1)
        bg.lineWidth = 1.5
        bubble.addChild(bg)
        let txt = SKLabelNode(fontNamed: "AvenirNext-Bold")
        txt.text = "Hi!"
        txt.fontSize = 14
        txt.fontColor = SKColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1)
        txt.verticalAlignmentMode = .center
        bubble.addChild(txt)
        bubble.position = CGPoint(x: 18, y: 30)
        bubble.alpha = 0
        node.addChild(bubble)

        rig.run(.repeatForever(.sequence([                 // idle bob
            .moveBy(x: 0, y: 3, duration: 0.9).eased(),
            .moveBy(x: 0, y: -3, duration: 0.9).eased(),
        ])))
    }

    func update(now: TimeInterval, playerPos: CGPoint) {
        let dx = playerPos.x - node.position.x
        let dy = playerPos.y - node.position.y
        guard abs(dx) < 95, abs(dy) < 70, now - lastGreeting > 4 else { return }
        lastGreeting = now
        // Wave + bubble pop
        hand.run(.sequence([
            .moveBy(x: 2, y: 10, duration: 0.15).eased(),
            .repeat(.sequence([.rotate(byAngle: 0.5, duration: 0.12),
                               .rotate(byAngle: -0.5, duration: 0.12)]), count: 3),
            .moveBy(x: -2, y: -10, duration: 0.2).eased(),
        ]))
        bubble.setScale(0.3)
        bubble.run(.sequence([
            .group([.fadeIn(withDuration: 0.15), .scale(to: 1.0, duration: 0.18).eased()]),
            .wait(forDuration: 1.4),
            .fadeOut(withDuration: 0.3),
        ]))
    }
}

/// Perched bird that startles and flies off when the player gets close.
final class Bird {
    let node = SKNode()
    private let wing = SKShapeNode()
    private var fled = false

    init(position: CGPoint) {
        node.position = position
        node.zPosition = 5

        let body = SKShapeNode(ellipseOf: CGSize(width: 16, height: 12))
        body.fillColor = SKColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 1)
        body.strokeColor = SKColor(red: 0.70, green: 0.35, blue: 0.10, alpha: 1)
        body.lineWidth = 2
        node.addChild(body)

        let eye = SKShapeNode(circleOfRadius: 1.6)
        eye.fillColor = .black
        eye.strokeColor = .clear
        eye.position = CGPoint(x: 4, y: 2)
        node.addChild(eye)

        let beakPath = CGMutablePath()
        beakPath.move(to: CGPoint(x: 8, y: 1))
        beakPath.addLine(to: CGPoint(x: 13, y: -1))
        beakPath.addLine(to: CGPoint(x: 8, y: -3))
        beakPath.closeSubpath()
        let beak = SKShapeNode(path: beakPath)
        beak.fillColor = SKColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)
        beak.strokeColor = .clear
        node.addChild(beak)

        let wingPath = CGMutablePath()
        wingPath.move(to: CGPoint(x: -6, y: 0))
        wingPath.addQuadCurve(to: CGPoint(x: 4, y: 2), control: CGPoint(x: -2, y: 8))
        wingPath.addLine(to: CGPoint(x: -2, y: -1))
        wingPath.closeSubpath()
        wing.path = wingPath
        wing.fillColor = SKColor(red: 0.80, green: 0.40, blue: 0.15, alpha: 1)
        wing.strokeColor = .clear
        node.addChild(wing)

        node.run(.repeatForever(.sequence([                // perch hop
            .wait(forDuration: 1.8, withRange: 1.6),
            .moveBy(x: 0, y: 4, duration: 0.1),
            .moveBy(x: 0, y: -4, duration: 0.12),
        ])))
    }

    func update(playerPos: CGPoint) {
        guard !fled else { return }
        let dx = playerPos.x - node.position.x
        let dy = playerPos.y - node.position.y
        guard abs(dx) < 85, abs(dy) < 70 else { return }
        fled = true
        node.removeAllActions()
        wing.run(.repeatForever(.sequence([                // flap
            .scaleY(to: -0.8, duration: 0.09),
            .scaleY(to: 1.0, duration: 0.09),
        ])))
        let away: CGFloat = dx >= 0 ? -1 : 1               // fly away from player
        node.run(.sequence([
            .group([.moveBy(x: away * 220, y: 240, duration: 1.1).eased(),
                    .fadeOut(withDuration: 1.1)]),
            .removeFromParent(),
        ]))
    }
}

/// Action-driven butterfly that wanders near the flowers. Zero per-frame cost.
enum Butterfly {
    static func spawn(at position: CGPoint) -> SKNode {
        let node = SKNode()
        node.position = position
        node.zPosition = 4
        let color = [SKColor(red: 1.0, green: 0.5, blue: 0.7, alpha: 1),
                     SKColor(red: 0.6, green: 0.6, blue: 1.0, alpha: 1),
                     SKColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1)].randomElement()!
        for side in [CGFloat(-1), 1] {
            let wing = SKShapeNode(ellipseOf: CGSize(width: 8, height: 11))
            wing.fillColor = color
            wing.strokeColor = SKColor(white: 0, alpha: 0.25)
            wing.lineWidth = 1
            wing.position = CGPoint(x: side * 4, y: 0)
            node.addChild(wing)
            wing.run(.repeatForever(.sequence([
                .scaleX(to: 0.3, duration: 0.12),
                .scaleX(to: 1.0, duration: 0.12),
            ])))
        }
        // Lazy wander loop
        var hops: [SKAction] = []
        for _ in 0..<4 {
            hops.append(.moveBy(x: CGFloat.random(in: -60...60),
                                y: CGFloat.random(in: -30...30),
                                duration: Double.random(in: 1.4...2.4)).eased())
        }
        hops.append(.move(to: position, duration: 1.8).eased())   // come home
        node.run(.repeatForever(.sequence(hops)))
        return node
    }
}
