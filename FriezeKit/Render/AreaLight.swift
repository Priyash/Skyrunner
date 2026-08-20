import SpriteKit

/// Soft area light — a glowing rectangle or edge that casts smooth illumination.
///
/// SpriteKit's `SKLightNode` is a point light: infinitely small, with a sharp
/// falloff boundary that looks correct only for bulbs and small flames. An area
/// light — a window, a ceiling strip, a campfire bed — needs softer shadows that
/// blur toward the edge of the lit zone. The approximation here spreads N point
/// lights across the area so their halos overlap into a roughly uniform soft field.
///
/// Four sources suffice for visual softness at game-camera distances. Eight is the
/// practical maximum before you can see discrete light seams.
final class AreaLight {

    // MARK: - Scene node

    /// Add this to the scene graph. Its children are the sub-lights.
    let container: SKNode

    // MARK: - Configuration

    /// Emitted colour (RGB; split evenly across sub-lights so N lights sum to `intensity`).
    var color: SKColor = .white {
        didSet { distribute() }
    }

    /// Overall brightness, baked into the light colour components (0…1 typical range).
    var intensity: CGFloat = 1 {
        didSet { distribute() }
    }

    /// SpriteKit falloff exponent. 1 = linear, 2 = quadratic.
    var falloff: CGFloat = 1 {
        didSet { for l in lights { l.falloff = falloff } }
    }

    /// Category mask — controls which sprite nodes respond to this light.
    /// Defaults to `LightCategory.point`.
    var category: UInt32 = LightCategory.point {
        didSet { for l in lights { l.categoryBitMask = category } }
    }

    var isEnabled: Bool = true {
        didSet { for l in lights { l.isEnabled = isEnabled } }
    }

    // MARK: - Flicker

    /// Flicker magnitude: 0 = steady, 1 = strong candle-style flicker.
    var flicker: CGFloat = 0
    private var flickerPhase: CGFloat = 0

    // MARK: - Init

    private var lights: [SKLightNode] = []

    /// Build an area light spread across a rectangle.
    /// - Parameters:
    ///   - rect:     The lit rectangle in the container's coordinate space.
    ///   - sources:  Sub-light count (clamped 2…8).
    ///   - zPosition: Z depth of the container node.
    init(rect: CGRect, sources: Int = 4, zPosition: CGFloat = 0) {
        container = SKNode()
        container.zPosition = zPosition
        let count = max(2, min(8, sources))
        for i in 0..<count {
            let t = count == 1 ? 0.5 : CGFloat(i) / CGFloat(count - 1)
            let light = SKLightNode()
            // Spread along the diagonal of the rect so coverage extends into corners.
            light.position = CGPoint(x: rect.minX + rect.width  * t,
                                     y: rect.minY + rect.height * t)
            light.categoryBitMask = LightCategory.point
            light.falloff = 1
            light.isEnabled = true
            container.addChild(light)
            lights.append(light)
        }
        distribute()
    }

    /// Build an area light along a straight edge — a ceiling strip, a neon sign.
    convenience init(from start: CGPoint, to end: CGPoint,
                     sources: Int = 4, zPosition: CGFloat = 0) {
        let rect = CGRect(
            x:      min(start.x, end.x),
            y:      min(start.y, end.y),
            width:  max(1, abs(end.x - start.x)),
            height: max(1, abs(end.y - start.y)))
        self.init(rect: rect, sources: sources, zPosition: zPosition)
    }

    // MARK: - Update

    /// Advance flicker. Call once per frame; zero-cost when `flicker == 0`.
    func update(dt: CGFloat) {
        guard flicker > 0.001 else { return }
        flickerPhase += dt
        let f  = sin(flickerPhase * 13.7) * 0.6 + sin(flickerPhase * 7.3) * 0.4
        let mod = 1 + f * flicker * 0.35
        applyToLights(intensity: max(0, intensity * CGFloat(mod)))
    }

    // MARK: - Private

    private func distribute() {
        applyToLights(intensity: intensity)
    }

    private func applyToLights(intensity: CGFloat) {
        guard !lights.isEmpty else { return }
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let perLight = intensity / CGFloat(lights.count)
        let c = SKColor(red: r * perLight, green: g * perLight,
                        blue: b * perLight, alpha: 1)
        for light in lights { light.lightColor = c }
    }
}
