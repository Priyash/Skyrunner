import SpriteKit

/// Builders for every cartoon world piece. Physics setup stays identical to
/// the original engine — only the visuals changed.
enum Decor {

    // MARK: Ground: warm dirt, bright rounded grass cap, flowers & pebbles

    static func ground(size: CGSize) -> SKSpriteNode {
        // Painted dirt slab (speckles, shading, top seam baked in)
        let node = SKSpriteNode(texture: Painter.dirt(size: size))
        node.size = size

        // Painted grass cap: blades live in the top 8pt of a 26pt canvas,
        // so center the cap sprite with its 18pt band flush to the slab top.
        let cap = SKSpriteNode(texture: Painter.grassCap(width: size.width))
        cap.size = CGSize(width: size.width, height: 26)
        cap.position = CGPoint(x: 0, y: size.height / 2 - 5)
        cap.zPosition = 1
        node.addChild(cap)

        // Flowers on wider platforms (kept as nodes so they can pulse)
        if size.width >= 120 {
            for _ in 0..<Int(size.width / 160) + 1 {
                let x = CGFloat.random(in: -size.width/2 + 14 ... size.width/2 - 14)
                let stem = SKSpriteNode(color: SKColor(red: 0.16, green: 0.55, blue: 0.20, alpha: 1),
                                        size: CGSize(width: 2.5, height: 10))
                stem.position = CGPoint(x: x, y: size.height / 2 + 5)
                stem.zPosition = 2
                node.addChild(stem)
                let color: SKColor = [SKColor(red: 1.0, green: 0.35, blue: 0.55, alpha: 1),
                                      SKColor(red: 1.0, green: 0.75, blue: 0.15, alpha: 1),
                                      SKColor(red: 0.55, green: 0.45, blue: 1.0, alpha: 1)].randomElement()!
                let bloom = SKSpriteNode(texture: Painter.ball(radius: 4.5, base: color))
                bloom.position = CGPoint(x: x, y: size.height / 2 + 11)
                bloom.zPosition = 2
                node.addChild(bloom)
                bloom.run(.repeatForever(.sequence([
                    .scale(to: 1.15, duration: Double.random(in: 0.8...1.4)),
                    .scale(to: 1.0, duration: Double.random(in: 0.8...1.4)),
                ])))
            }
        }
        return node
    }

    // MARK: Moving platform: compact grass pad with visible side arrows

    static func movingPlatform(size: CGSize) -> SKSpriteNode {
        let node = ground(size: size)
        for (x, sym) in [(-size.width / 2 - 10, "◂"), (size.width / 2 + 10, "▸")] {
            let arrow = SKLabelNode(fontNamed: "AvenirNext-Bold")
            arrow.text = sym
            arrow.fontSize = 13
            arrow.fontColor = SKColor(white: 1, alpha: 0.75)
            arrow.verticalAlignmentMode = .center
            arrow.position = CGPoint(x: x, y: 0)
            node.addChild(arrow)
            arrow.run(.repeatForever(.sequence([
                .fadeAlpha(to: 0.3, duration: 0.6),
                .fadeAlpha(to: 0.75, duration: 0.6),
            ])))
        }
        return node
    }


    // MARK: Crate: breakable wooden box (punch or ground pound)

    static func crate(tile t: CGFloat) -> SKNode {
        let s = t * 0.9
        let box = SKSpriteNode(texture: Painter.crate(side: s))
        box.size = CGSize(width: s + 4, height: s + 4)
        return box
    }

    // MARK: One-way platform: thin bright pad you can jump up through

    static func oneWayPad(size: CGSize) -> SKShapeNode {
        let pad = SKShapeNode(rectOf: size, cornerRadius: size.height / 2)
        pad.fillColor = SKColor(red: 0.45, green: 0.88, blue: 0.50, alpha: 1)
        pad.strokeColor = SKColor(red: 0.22, green: 0.62, blue: 0.28, alpha: 1)
        pad.lineWidth = 2.5
        let sheen = SKShapeNode(rectOf: CGSize(width: size.width * 0.86, height: 3), cornerRadius: 1.5)
        sheen.fillColor = SKColor(white: 1, alpha: 0.55)
        sheen.strokeColor = .clear
        sheen.position = CGPoint(x: 0, y: size.height / 2 - 4)
        pad.addChild(sheen)
        return pad
    }

    // MARK: Coin: glowing, spinning, floating

    static func coin() -> SKNode {
        let container = SKNode()

        let halo = SKSpriteNode(texture: Painter.glow(radius: 20,
                                color: UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)))
        halo.blendMode = .add
        halo.alpha = 0.7
        container.addChild(halo)
        halo.run(.repeatForever(.sequence([.fadeAlpha(to: 0.35, duration: 0.7),
                                           .fadeAlpha(to: 0.7, duration: 0.7)])))

        let face = SKSpriteNode(texture: Painter.coinFace(radius: 10))
        container.addChild(face)

        face.run(.repeatForever(.sequence([                 // spin
            .scaleX(to: 0.25, duration: 0.45).eased(),
            .scaleX(to: 1.0, duration: 0.45).eased(),
        ])))
        container.run(.repeatForever(.sequence([            // float
            .moveBy(x: 0, y: 5, duration: 0.8).eased(),
            .moveBy(x: 0, y: -5, duration: 0.8).eased(),
        ])))
        return container
    }

    // MARK: Enemy: wobbling grumpy blob with pattering feet

    /// Returns (container-for-physics, rig-to-flip-when-turning).
    static func enemy() -> (SKNode, SKNode) {
        let container = SKNode()
        let rig = SKNode()
        container.addChild(rig)

        let blob = SKSpriteNode(texture: Painter.pill(
            size: CGSize(width: 32, height: 26),
            base: SKColor(red: 0.62, green: 0.35, blue: 0.95, alpha: 1),
            outline: SKColor(red: 0.40, green: 0.18, blue: 0.70, alpha: 1)))
        rig.addChild(blob)

        for (x, px) in [(CGFloat(6), CGFloat(8)), (CGFloat(-4), CGFloat(-2))] {
            let eye = SKShapeNode(circleOfRadius: 4.5)
            eye.fillColor = .white
            eye.strokeColor = .clear
            eye.position = CGPoint(x: x, y: 4)
            rig.addChild(eye)
            let pupil = SKShapeNode(circleOfRadius: 2)
            pupil.fillColor = .black
            pupil.strokeColor = .clear
            pupil.position = CGPoint(x: px, y: 4)
            rig.addChild(pupil)
        }
        // Angry brow
        let brow = SKSpriteNode(color: SKColor(red: 0.35, green: 0.15, blue: 0.60, alpha: 1),
                                size: CGSize(width: 16, height: 3))
        brow.position = CGPoint(x: 1, y: 10)
        brow.zRotation = -0.25
        rig.addChild(brow)

        for x in [CGFloat(-8), 8] {
            let foot = SKSpriteNode(texture: Painter.pill(
                size: CGSize(width: 10, height: 6),
                base: SKColor(red: 0.40, green: 0.18, blue: 0.70, alpha: 1)))
            foot.position = CGPoint(x: x, y: -13)
            rig.addChild(foot)
            foot.run(.repeatForever(.sequence([
                .moveBy(x: 0, y: 3, duration: 0.14),
                .moveBy(x: 0, y: -3, duration: 0.14),
            ])))
        }

        blob.run(.repeatForever(.sequence([                 // jelly wobble
            .scaleX(to: 1.08, y: 0.92, duration: 0.28).eased(),
            .scaleX(to: 0.94, y: 1.06, duration: 0.28).eased(),
        ])))
        return (container, rig)
    }

    // MARK: Hazard: glinting crystal shards

    static func crystal(tile t: CGFloat, index: Int) -> SKSpriteNode {
        let shard = SKSpriteNode(texture: Painter.crystal(tile: t, index: index))
        shard.size = CGSize(width: t + 4, height: t + 4)
        shard.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.8, duration: 0.5),
            .fadeAlpha(to: 1.0, duration: 0.5),
        ])))
        return shard
    }

    // MARK: Goal: swirling star portal

    static func portal(tile t: CGFloat) -> SKNode {
        let container = SKNode()

        let halo = SKSpriteNode(texture: Painter.glow(radius: 34,
                                color: UIColor(red: 0.4, green: 1.0, blue: 0.8, alpha: 1)))
        halo.blendMode = .add
        container.addChild(halo)
        halo.run(.repeatForever(.sequence([.scale(to: 1.3, duration: 0.8),
                                           .scale(to: 1.0, duration: 0.8)])))

        let ring = SKShapeNode(circleOfRadius: 20)
        ring.strokeColor = SKColor(red: 0.20, green: 0.90, blue: 0.70, alpha: 1)
        ring.lineWidth = 5
        ring.fillColor = SKColor(red: 0.10, green: 0.45, blue: 0.40, alpha: 0.35)
        container.addChild(ring)

        let star = SKShapeNode(path: starPath(points: 5, outer: 11, inner: 4.5))
        star.fillColor = SKColor(red: 1.0, green: 0.95, blue: 0.4, alpha: 1)
        star.strokeColor = .clear
        container.addChild(star)
        star.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 3)))
        return container
    }

    private static func starPath(points: Int, outer: CGFloat, inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<(points * 2) {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
            let p = CGPoint(x: cos(a) * r, y: sin(a) * r)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

extension SKAction {
    func eased() -> SKAction {
        timingMode = .easeInEaseOut
        return self
    }
}
