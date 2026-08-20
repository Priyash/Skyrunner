import SpriteKit

/// Nine layers of depth, all attached to the camera and slid against camera
/// movement each frame:
///   1 sky gradient   2 sun+halo        3 far mountains (5%)
///   4 clouds (5–14%) 5 far hills (10%) 6 near hills (22%)
///   7 flying birds   8 light rays      9 drifting dust motes
final class ParallaxController {
    private struct Layer { let node: SKNode; let factor: CGFloat; let baseX: CGFloat }
    private var layers: [Layer] = []

    init(camera: SKCameraNode, sceneSize: CGSize) {
        // 1 — Sky gradient, fixed to camera
        let sky = SKSpriteNode(texture: Painter.gradient(
            size: CGSize(width: 64, height: 256),
            colors: [
                UIColor(red: 1.00, green: 0.93, blue: 0.60, alpha: 1),   // warm horizon
                UIColor(red: 0.45, green: 0.85, blue: 0.95, alpha: 1),   // teal
                UIColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 1),   // deep blue top
            ]))
        sky.size = CGSize(width: sceneSize.width * 1.3, height: sceneSize.height * 1.3)
        sky.zPosition = -200
        camera.addChild(sky)

        // 2 — Sun with lazily rotating rays + additive halo
        let sun = SKShapeNode(circleOfRadius: 26)
        sun.fillColor = SKColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 1)
        sun.strokeColor = .clear
        sun.position = CGPoint(x: -sceneSize.width / 2 + 90, y: sceneSize.height / 2 - 70)
        sun.zPosition = -190
        let rays = SKNode()
        for i in 0..<8 {
            let ray = SKSpriteNode(color: SKColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 0.5),
                                   size: CGSize(width: 5, height: 22))
            let a = CGFloat(i) / 8 * .pi * 2
            ray.position = CGPoint(x: cos(a) * 38, y: sin(a) * 38)
            ray.zRotation = a + .pi / 2
            rays.addChild(ray)
        }
        sun.addChild(rays)
        rays.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 24)))
        let halo = SKSpriteNode(texture: Painter.glow(radius: 60, color: UIColor(red: 1, green: 0.9, blue: 0.4, alpha: 1)))
        halo.blendMode = .add
        halo.setScale(1.4)
        sun.addChild(halo)
        camera.addChild(sun)

        // 3 — Far mountains, barely moving
        addRidge(to: camera, sceneSize: sceneSize, factor: 0.05,
                 color: SKColor(red: 0.55, green: 0.60, blue: 0.85, alpha: 1),
                 baseY: -sceneSize.height / 2 + 108, peaks: true, amplitude: 110, z: -180)

        // 4 — Drifting clouds. The parallax controller writes the CONTAINER's
        // position each frame, so the drift action lives on the child sprite —
        // otherwise the two would fight over the same node's position.
        let cloudTex = Painter.cloud()
        for i in 0..<4 {
            let holder = SKNode()
            holder.zPosition = -175
            let baseX = -sceneSize.width / 2 + CGFloat(i) * (sceneSize.width / 3.2)
            let y = sceneSize.height / 2 - CGFloat.random(in: 50...130)
            holder.position = CGPoint(x: baseX, y: y)
            camera.addChild(holder)
            let c = SKSpriteNode(texture: cloudTex)
            c.alpha = 0.85
            c.setScale(CGFloat.random(in: 0.5...0.9))
            holder.addChild(c)
            c.run(.repeatForever(.sequence([
                .moveBy(x: 14, y: 0, duration: Double.random(in: 5...9)),
                .moveBy(x: -14, y: 0, duration: Double.random(in: 5...9)),
            ])))
            layers.append(Layer(node: holder, factor: CGFloat.random(in: 0.05...0.14), baseX: baseX))
        }

        // 5 & 6 — Rolling hills, two depths
        addRidge(to: camera, sceneSize: sceneSize, factor: 0.10,
                 color: SKColor(red: 0.55, green: 0.80, blue: 0.55, alpha: 1),
                 baseY: -sceneSize.height / 2 + 70, peaks: false, amplitude: 60, z: -170)
        addRidge(to: camera, sceneSize: sceneSize, factor: 0.22,
                 color: SKColor(red: 0.36, green: 0.68, blue: 0.42, alpha: 1),
                 baseY: -sceneSize.height / 2 + 40, peaks: false, amplitude: 85, z: -160)

        // 7 — Distant birds gliding across the sky, forever
        for i in 0..<2 {
            let flock = SKNode()
            flock.zPosition = -178
            camera.addChild(flock)
            for j in 0..<3 {
                let birdPath = CGMutablePath()
                birdPath.move(to: CGPoint(x: -6, y: 0))
                birdPath.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -3, y: 4))
                birdPath.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: 3, y: 4))
                let bird = SKShapeNode(path: birdPath)
                bird.strokeColor = SKColor(white: 0.2, alpha: 0.55)
                bird.lineWidth = 2
                bird.position = CGPoint(x: CGFloat(j) * 22 - 22, y: CGFloat(j % 2) * 10)
                flock.addChild(bird)
            }
            let y = sceneSize.height / 2 - CGFloat(70 + i * 55)
            let fromX = -sceneSize.width / 2 - 80
            let toX = sceneSize.width / 2 + 80
            flock.position = CGPoint(x: fromX, y: y)
            flock.run(.repeatForever(.sequence([
                .wait(forDuration: Double(i) * 6),
                .move(to: CGPoint(x: toX, y: y + 20), duration: 16),
                .run { flock.position = CGPoint(x: fromX, y: y) },
            ])))
        }

        // 8 — Soft light rays from the top
        for (x, rot) in [(sceneSize.width * -0.18, CGFloat(0.32)), (sceneSize.width * 0.08, 0.22)] {
            let ray = SKSpriteNode(color: SKColor(white: 1, alpha: 0.07),
                                   size: CGSize(width: 60, height: sceneSize.height * 1.4))
            ray.position = CGPoint(x: x, y: sceneSize.height * 0.25)
            ray.zRotation = rot
            ray.zPosition = -150
            camera.addChild(ray)
            ray.run(.repeatForever(.sequence([
                .fadeAlpha(to: 0.4, duration: 3.2).eased(),
                .fadeAlpha(to: 1.0, duration: 3.2).eased(),
            ])))
        }

        // 9 — Drifting dust motes (screen-space ambience)
        let motes = SKEmitterNode()
        motes.particleTexture = Painter.glow(radius: 5)
        motes.particleBirthRate = 2.5
        motes.particleLifetime = 7
        motes.particleSpeed = 12
        motes.particleSpeedRange = 8
        motes.emissionAngle = .pi * 0.15
        motes.emissionAngleRange = .pi
        motes.particleAlpha = 0.35
        motes.particleAlphaRange = 0.2
        motes.particleAlphaSpeed = -0.05
        motes.particleScale = 0.35
        motes.particleScaleRange = 0.25
        motes.particlePositionRange = CGVector(dx: sceneSize.width, dy: sceneSize.height)
        motes.zPosition = -140
        camera.addChild(motes)

        layers.append(contentsOf: []) // (clouds & ridges already registered)
    }

    private func addRidge(to camera: SKCameraNode, sceneSize: CGSize, factor: CGFloat,
                          color: SKColor, baseY: CGFloat, peaks: Bool, amplitude: CGFloat, z: CGFloat) {
        let width = sceneSize.width + 700
        let ridge = SKSpriteNode(texture: Painter.hillRidge(width: width, amplitude: amplitude,
                                                            peaks: peaks, color: color))
        ridge.size = CGSize(width: width, height: amplitude + 140)
        // The old shape spanned y ∈ [-140, amplitude] around `baseY`; a
        // center-anchored sprite of that height sits at the same place when
        // offset by (amplitude − 140)/2.
        ridge.position = CGPoint(x: 0, y: baseY + (amplitude - 140) / 2)
        ridge.zPosition = z
        camera.addChild(ridge)
        layers.append(Layer(node: ridge, factor: factor, baseX: 0))
    }

    func update(camX: CGFloat) {
        for layer in layers {
            layer.node.position.x = layer.baseX - camX * layer.factor
        }
    }
}
