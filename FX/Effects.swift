import SpriteKit

enum Effects {
    private static let dot = Painter.glow(radius: 8)

    /// One-shot radial burst (coins, stomps, deaths).
    static func burst(at position: CGPoint, in scene: SKScene,
                      color: SKColor, count: Int = 14, speed: CGFloat = 160) {
        let e = SKEmitterNode()
        e.particleTexture = dot
        e.particleBirthRate = 800
        e.numParticlesToEmit = count
        e.particleLifetime = 0.55
        e.particleLifetimeRange = 0.2
        e.particleSpeed = speed
        e.particleSpeedRange = speed * 0.6
        e.emissionAngleRange = .pi * 2
        e.particleAlpha = 0.95
        e.particleAlphaSpeed = -1.7
        e.particleScale = 0.45
        e.particleScaleRange = 0.2
        e.particleScaleSpeed = -0.5
        e.particleColor = color
        e.particleColorBlendFactor = 1
        e.particleBlendMode = .add
        e.yAcceleration = -300
        e.position = position
        e.zPosition = 50
        scene.addChild(e)
        e.run(.sequence([.wait(forDuration: 1.2), .removeFromParent()]))
    }

    /// Small dust puff at the feet on landing.
    static func dust(at position: CGPoint, in scene: SKScene) {
        burst(at: position, in: scene,
              color: SKColor(white: 1, alpha: 0.9), count: 7, speed: 70)
    }

    /// Floating combo text: "+2 ×3" style feedback that drifts up and fades.
    static func floatText(_ text: String, at position: CGPoint, in scene: SKScene,
                          color: SKColor = SKColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1)) {
        let l = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        l.text = text
        l.fontSize = 17
        l.fontColor = color
        l.position = position
        l.zPosition = 60
        l.setScale(0.5)
        scene.addChild(l)
        l.run(.sequence([
            .group([.scale(to: 1.0, duration: 0.15).eased(),
                    .moveBy(x: 0, y: 34, duration: 0.7).eased(),
                    .sequence([.wait(forDuration: 0.35), .fadeOut(withDuration: 0.35)])]),
            .removeFromParent(),
        ]))
    }
    // NOTE: screen shake lives in GameScene (a decaying offset added to the
    // camera position each frame) — an SKAction on the camera would fight
    // the per-frame `cam.position =` assignment in update().
}
