import SpriteKit

/// What gameplay is doing, as far as the rig needs to know.
///
/// `dash` and `climb` arrived with the clips for them: before that the skeletal
/// rig showed a jump pose while dashing, because a dash is airborne and nothing
/// distinguished it.
enum PlayerPose { case normal, hover, pound, wallSlide, dash, climb }

/// "Blip" — limbless cartoon hero: round body, floating hands & feet, all
/// animated procedurally with squash-and-stretch, blinking, a helicopter-hair
/// hover, and a cartoon stars-around-the-head hurt reaction.
final class PlayerCharacter: SKNode, PlayerRig {

    // Visual rig is separate from the (physics-carrying) container so we can
    // flip/squash freely without touching the physics body.
    private let rig = SKNode()
    private let bodyShape: SKSpriteNode
    private let head: SKSpriteNode
    private let handL: SKSpriteNode
    private let handR: SKSpriteNode
    private let footL: SKSpriteNode
    private let footR: SKSpriteNode
    private let eyeL = SKShapeNode(ellipseOf: CGSize(width: 7, height: 9))
    private let eyeR = SKShapeNode(ellipseOf: CGSize(width: 7, height: 9))
    private let pupilL = SKShapeNode(circleOfRadius: 2.2)
    private let pupilR = SKShapeNode(circleOfRadius: 2.2)
    private let tuft = SKNode()

    private var phase: Double = 0
    private(set) var facing: CGFloat = 1
    private var squashX: CGFloat = 1
    private var squashY: CGFloat = 1
    private var pose: PlayerPose = .normal

    private let orange = SKColor(red: 1.00, green: 0.58, blue: 0.10, alpha: 1)
    private let outline = SKColor(red: 0.75, green: 0.38, blue: 0.02, alpha: 1)

    override init() {
        // Painted, shaded parts — the cartoon-ball look, at device resolution.
        let orangeC = SKColor(red: 1.00, green: 0.58, blue: 0.10, alpha: 1)
        let outlineC = SKColor(red: 0.75, green: 0.38, blue: 0.02, alpha: 1)
        let creamC = SKColor(red: 1.00, green: 0.93, blue: 0.80, alpha: 1)
        bodyShape = SKSpriteNode(texture: Painter.ball(radius: 12, base: orangeC, outline: outlineC))
        head = SKSpriteNode(texture: Painter.ball(radius: 11, base: orangeC, outline: outlineC))
        handL = SKSpriteNode(texture: Painter.ball(radius: 5, base: creamC, outline: outlineC))
        handR = SKSpriteNode(texture: Painter.ball(radius: 5, base: creamC, outline: outlineC))
        let shoe = SKColor(red: 0.90, green: 0.22, blue: 0.18, alpha: 1)
        let shoeLine = SKColor(red: 0.55, green: 0.10, blue: 0.08, alpha: 1)
        footL = SKSpriteNode(texture: Painter.pill(size: CGSize(width: 13, height: 8),
                                                   base: shoe, outline: shoeLine))
        footR = SKSpriteNode(texture: Painter.pill(size: CGSize(width: 13, height: 8),
                                                   base: shoe, outline: shoeLine))
        super.init()
        addChild(rig)

        bodyShape.position = CGPoint(x: 0, y: -6)
        rig.addChild(bodyShape)
        let belly = SKSpriteNode(texture: Painter.pill(size: CGSize(width: 14, height: 15), base: creamC))
        belly.position = CGPoint(x: 0, y: -2)
        belly.zPosition = 1
        bodyShape.addChild(belly)

        head.position = CGPoint(x: 0, y: 10)
        head.zPosition = 2
        rig.addChild(head)

        eyeL.position = CGPoint(x: -3.5, y: 2)
        eyeR.position = CGPoint(x: 3.5, y: 2)
        for eye in [eyeL, eyeR] {
            eye.fillColor = .white
            eye.strokeColor = .clear
            head.addChild(eye)
            // Random blinking, forever
            eye.run(.repeatForever(.sequence([
                .wait(forDuration: 2.6, withRange: 2.4),
                .scaleY(to: 0.08, duration: 0.06),
                .scaleY(to: 1.0, duration: 0.09),
            ])))
        }
        pupilL.fillColor = .black; pupilL.strokeColor = .clear
        pupilR.fillColor = .black; pupilR.strokeColor = .clear
        pupilL.position = CGPoint(x: -2.5, y: 2)
        pupilR.position = CGPoint(x: 4.5, y: 2)
        head.addChild(pupilL)
        head.addChild(pupilR)

        // Hair tuft — doubles as the helicopter rotor while hovering
        let tuftPath = CGMutablePath()
        tuftPath.move(to: CGPoint(x: -4, y: 0))
        tuftPath.addQuadCurve(to: CGPoint(x: 2, y: 12), control: CGPoint(x: -6, y: 10))
        tuftPath.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 6, y: 4))
        tuftPath.closeSubpath()
        let tuftShape = SKShapeNode(path: tuftPath)
        tuftShape.fillColor = orange
        tuftShape.strokeColor = outline
        tuftShape.lineWidth = 2
        tuft.addChild(tuftShape)
        tuft.position = CGPoint(x: 0, y: 8)
        head.addChild(tuft)

        for limb in [handL, handR, footL, footR] {
            limb.zPosition = 3
            rig.addChild(limb)
        }
        restPose()
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    private func restPose() {
        handL.position = CGPoint(x: -15, y: -4)
        handR.position = CGPoint(x: 15, y: -4)
        footL.position = CGPoint(x: -7, y: -19)
        footR.position = CGPoint(x: 7, y: -19)
    }

    /// Drive the animation each frame from gameplay state.
    func update(dt: CGFloat, moveInput: CGFloat, grounded: Bool, vy: CGFloat) {
        if moveInput != 0 { facing = moveInput > 0 ? 1 : -1 }

        if grounded && moveInput != 0 {
            phase += Double(dt) * 15                       // run cycle
            let s = CGFloat(sin(phase)), c = CGFloat(cos(phase))
            footL.position = CGPoint(x: -7 + s * 8, y: -19 + max(0, c) * 5)
            footR.position = CGPoint(x: 7 - s * 8, y: -19 + max(0, -c) * 5)
            handL.position = CGPoint(x: -15 - s * 5, y: -4 + abs(s) * 3)
            handR.position = CGPoint(x: 15 + s * 5, y: -4 + abs(s) * 3)
            rig.zRotation = facing * -0.08                 // lean into the run
            bodyShape.position.y = -6 + abs(s) * 1.5       // bounce
            tuft.zRotation = 0
        } else if grounded {
            phase += Double(dt) * 3                        // idle breathe
            let s = CGFloat(sin(phase))
            restPose()
            rig.zRotation = 0
            bodyShape.position.y = -6 + s * 1.2
            head.position.y = 10 + s * 1.8
            tuft.zRotation = 0
        } else if pose == .hover {
            phase += Double(dt) * 40                       // rotor spin
            tuft.zRotation = CGFloat(sin(phase)) * 1.1     // fast whirl
            handL.position = CGPoint(x: -13, y: 2)
            handR.position = CGPoint(x: 13, y: 2)
            footL.position = CGPoint(x: -6, y: -17)
            footR.position = CGPoint(x: 6, y: -17)
            rig.zRotation = 0
        } else if pose == .pound {
            phase += Double(dt) * 30
            handL.position = CGPoint(x: -12, y: 8)         // fists up, feet together
            handR.position = CGPoint(x: 12, y: 8)
            footL.position = CGPoint(x: -4, y: -20)
            footR.position = CGPoint(x: 4, y: -20)
            rig.zRotation = CGFloat(sin(phase)) * 0.12     // furious wobble
            tuft.zRotation = 0
        } else if pose == .wallSlide {
            phase += Double(dt) * 22
            handL.position = CGPoint(x: 14, y: 4)          // both hands grip the wall
            handR.position = CGPoint(x: 16, y: -2)
            let s = CGFloat(sin(phase))
            footL.position = CGPoint(x: 6 + s * 2, y: -18) // feet scramble
            footR.position = CGPoint(x: 9 - s * 2, y: -15)
            rig.zRotation = facing * 0.10                  // lean back off the wall
            tuft.zRotation = 0
        } else {
            handL.position = CGPoint(x: -14, y: 6)         // airborne
            handR.position = CGPoint(x: 14, y: 6)
            footL.position = CGPoint(x: -6, y: -16)
            footR.position = CGPoint(x: 6, y: -16)
            rig.zRotation = facing * -0.05
            tuft.zRotation = 0
        }

        // Squash & stretch, eased toward targets
        let stretch = (grounded || pose == .hover || pose == .wallSlide) ? 0 : min(0.18, abs(vy) / 3500)
        squashY += ((1 + stretch) - squashY) * min(1, dt * 12)
        squashX += ((1 - stretch * 0.55) - squashX) * min(1, dt * 12)
        rig.yScale = squashY
        rig.xScale = facing * squashX

        // Pupils look where you're going
        let look = facing * 1.2
        pupilL.position.x = -2.5 + look
        pupilR.position.x = 4.5 + look
    }

    func setPose(_ p: PlayerPose) { pose = p }

    /// Rayman-style punch: the lead fist rockets out and snaps back.
    func playPunch() {
        handR.removeAction(forKey: "punch")
        handR.run(.sequence([
            .moveTo(x: 30, duration: 0.06),
            .wait(forDuration: 0.05),
            .moveTo(x: 15, duration: 0.10).eased(),
        ]), withKey: "punch")
    }

    /// Quick landing squash (call on the airborne→grounded transition).
    func playLand() {
        squashY = 0.72
        squashX = 1.28
    }

    /// Cartoon hurt: blink out + stars circling the head.
    func playHurt() {
        run(.sequence([.fadeAlpha(to: 0.25, duration: 0.08),
                       .fadeAlpha(to: 1.0, duration: 0.08),
                       .fadeAlpha(to: 0.25, duration: 0.08),
                       .fadeAlpha(to: 1.0, duration: 0.08)]))
        let orbit = SKNode()
        orbit.position = CGPoint(x: 0, y: 26)
        addChild(orbit)
        for i in 0..<3 {
            let star = SKLabelNode(fontNamed: "AvenirNext-Bold")
            star.text = "✦"
            star.fontSize = 13
            star.fontColor = SKColor(red: 1.0, green: 0.9, blue: 0.3, alpha: 1)
            let a = CGFloat(i) / 3 * .pi * 2
            star.position = CGPoint(x: cos(a) * 16, y: sin(a) * 7)
            orbit.addChild(star)
        }
        orbit.run(.sequence([
            .group([.rotate(byAngle: .pi * 3, duration: 0.9),
                    .fadeOut(withDuration: 0.9)]),
            .removeFromParent(),
        ]))
    }

    /// Self-running idle for non-gameplay screens (menu mascot).
    func startAutoIdle() {
        rig.run(.repeatForever(.sequence([
            .moveBy(x: 0, y: 6, duration: 0.7).eased(),
            .moveBy(x: 0, y: -6, duration: 0.7).eased(),
        ])))
    }
}
