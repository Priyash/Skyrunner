import SpriteKit
import UIKit

/// Normal-mapped 2D lighting — the effect that makes flat painted art read as
/// sculpted. SpriteKit lights every sprite that has a `normalTexture` and a
/// matching `lightingBitMask`, so we generate normals from the art itself
/// (`SKTexture.generatingNormalMap`) rather than shipping hand-authored maps.
///
/// Category assignment (bit masks are the whole API surface here):
///   .actors     — hero, enemies, props: lit + cast shadows
///   .platforms  — ground: lit + cast shadows
///   .backdrop   — frieze layers: lit only, never cast (they're far away)
enum LightCategory {
    static let key:     UInt32 = 1 << 0   // main sun/key light
    static let rim:     UInt32 = 1 << 1   // cool fill from behind
    static let point:   UInt32 = 1 << 2   // local glows (coins, portals)
    static let all:     UInt32 = key | rim | point
}

/// Builds and owns a scene's lights. Attach to the camera so the key light
/// tracks the player without per-frame cost.
final class LightingRig {

    private let key = SKLightNode()
    private let rim = SKLightNode()
    private var points: [SKLightNode] = []
    /// SpriteKit costs a full lighting pass per enabled light per lit sprite, so
    /// the count on screen has to be bounded — not the count in the level.
    var maxActivePointLights = 4
    private var installedSceneSize: CGSize = .zero

    /// - Parameter warm: key light colour; `cool` is the opposing rim.
    init(warm: SKColor = SKColor(red: 1.0, green: 0.94, blue: 0.78, alpha: 1),
         cool: SKColor = SKColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1),
         ambient: SKColor = SKColor(white: 0.62, alpha: 1)) {

        key.categoryBitMask = LightCategory.key
        key.lightColor = warm
        key.ambientColor = ambient
        key.shadowColor = SKColor(red: 0.06, green: 0.05, blue: 0.14, alpha: 0.45)
        key.falloff = 0.9
        key.zPosition = 500

        rim.categoryBitMask = LightCategory.rim
        rim.lightColor = cool
        rim.ambientColor = .black          // rim adds only; ambient comes from key
        rim.shadowColor = .clear
        rim.falloff = 1.4
        rim.zPosition = 500
    }

    /// Build from the current session overrides, so a scripted `setTimeOfDay` or
    /// `setLighting` survives the scene rebuild that level edits force.
    convenience init(overrides: EngineOverrides) {
        let light = overrides.effectiveLighting
        self.init(warm: DayCycle.color(light.warm),
                  cool: DayCycle.color(light.cool),
                  ambient: SKColor(white: light.ambient, alpha: 1))
    }

    /// Place the lights relative to the camera (call once, after camera setup).
    func install(on camera: SKCameraNode, sceneSize: CGSize) {
        installedSceneSize = sceneSize
        key.position = CGPoint(x: -sceneSize.width * 0.18, y: sceneSize.height * 0.46)
        rim.position = CGPoint(x: sceneSize.width * 0.34, y: sceneSize.height * 0.30)
        camera.addChild(key)
        camera.addChild(rim)
    }

    /// Point the key light where the time of day says the sun is, and tint the
    /// shadows to match.
    ///
    /// A dawn scene lit from directly overhead reads as a mistake even when the
    /// colours are right — direction is half of what "time of day" means.
    func orient(timeOfDay t: CGFloat, sceneSize: CGSize) {
        let clamped = min(max(t, 0), 1)
        // dawn: low from the left, noon: high, dusk: low from the right
        let angle = (0.12 + 0.76 * clamped) * .pi
        let radius = max(sceneSize.width, 1) * 0.42
        key.removeAllActions()
        key.position = CGPoint(x: -cos(angle) * radius,
                               y: sin(angle) * sceneSize.height * 0.55 + 40)
        rim.position = CGPoint(x: cos(angle) * radius * 0.8,
                               y: sceneSize.height * 0.30)
        // Long shadows at the ends of the day are cooler and softer.
        let noonness = 1 - abs(clamped - 0.5) * 2
        key.shadowColor = SKColor(red: 0.06 + 0.05 * (1 - noonness),
                                  green: 0.05 + 0.03 * (1 - noonness),
                                  blue: 0.14 + 0.10 * (1 - noonness),
                                  alpha: 0.30 + 0.22 * noonness)
        key.falloff = 0.75 + 0.4 * (1 - noonness)
    }

    /// Keep only the nearest lights enabled.
    ///
    /// Called as the camera moves, not per light per frame: the sort is over the
    /// level's point lights, which is a handful, and the result changes rarely.
    func cullPointLights(around position: CGPoint, in scene: SKNode) {
        guard points.count > maxActivePointLights else {
            for light in points { light.isEnabled = true }
            return
        }
        let ranked = points.map { light -> (SKLightNode, CGFloat) in
            let world = light.parent?.convert(light.position, to: scene) ?? light.position
            return (light, hypot(world.x - position.x, world.y - position.y))
        }.sorted { $0.1 < $1.1 }
        for (index, entry) in ranked.enumerated() {
            entry.0.isEnabled = index < maxActivePointLights
        }
    }

    /// A light that flickers like a flame — irregular, never a clean sine.
    @discardableResult
    func addFlickerLight(at position: CGPoint, color: SKColor,
                         falloff: CGFloat = 2.4, on parent: SKNode) -> SKLightNode {
        let light = addPointLight(at: position, color: color, falloff: falloff,
                                  on: parent)
        // Two mismatched periods, so the pattern never obviously repeats.
        light.run(.repeatForever(.sequence([
            .customAction(withDuration: 0.7) { node, t in
                guard let l = node as? SKLightNode else { return }
                let f = 0.82 + 0.18 * sin(t * 9) * cos(t * 3.7)
                l.falloff = falloff / max(f, 0.4)
            },
        ])))
        return light
    }

    /// Subtle drift keeps lighting from looking baked.
    func animate() {
        key.run(.repeatForever(.sequence([
            .moveBy(x: 26, y: -10, duration: 6).eased(),
            .moveBy(x: -26, y: 10, duration: 6).eased(),
        ])))
    }

    /// A local light — coins, portals, glowing flowers.
    @discardableResult
    func addPointLight(at position: CGPoint, color: SKColor,
                       falloff: CGFloat = 2.0, on parent: SKNode) -> SKLightNode {
        let light = SKLightNode()
        light.categoryBitMask = LightCategory.point
        light.lightColor = color
        light.ambientColor = .black
        light.shadowColor = .clear
        light.falloff = falloff
        light.position = position
        parent.addChild(light)
        points.append(light)
        return light
    }

    func setEnabled(_ on: Bool) {
        key.isEnabled = on
        rim.isEnabled = on
        points.forEach { $0.isEnabled = on }
    }
}

/// The time-of-day ramp behind `setTimeOfDay`: one dial (0 dawn → 0.5 noon →
/// 1 dusk) resolved into the three colours `LightingRig` takes.
///
/// A director changing the hour of a level shouldn't have to pick three RGB
/// triples that agree with each other — that is a lighting artist's job, done
/// once, here. The noon stop is deliberately identical to `LightingRig`'s own
/// defaults, so `setTimeOfDay(0.5)` reproduces the shipped look exactly rather
/// than something close to it.
enum DayCycle {

    static let defaultTime: CGFloat = 0.5

    private struct Stop {
        let t: CGFloat
        let warm: [CGFloat]
        let cool: [CGFloat]
        let ambient: CGFloat
    }

    private static let stops: [Stop] = [
        Stop(t: 0.00, warm: [1.00, 0.72, 0.52], cool: [0.36, 0.42, 0.78], ambient: 0.42),
        Stop(t: 0.50, warm: [1.00, 0.94, 0.78], cool: [0.45, 0.62, 0.95], ambient: 0.62),
        Stop(t: 1.00, warm: [1.00, 0.55, 0.30], cool: [0.28, 0.34, 0.62], ambient: 0.38),
    ]

    /// Interpolated components at `t`, clamped to the ends of the day.
    static func lighting(at t: CGFloat)
        -> (warm: [CGFloat], cool: [CGFloat], ambient: CGFloat) {
        let time = min(max(t, 0), 1)
        guard let first = stops.first, let last = stops.last else {
            return ([1, 0.94, 0.78], [0.45, 0.62, 0.95], 0.62)
        }
        if time <= first.t { return (first.warm, first.cool, first.ambient) }
        if time >= last.t { return (last.warm, last.cool, last.ambient) }
        var i = 0
        while i < stops.count - 1, stops[i + 1].t <= time { i += 1 }
        let a = stops[i], b = stops[min(i + 1, stops.count - 1)]
        let span = max(b.t - a.t, 0.0001)
        let f = (time - a.t) / span
        func mix(_ x: [CGFloat], _ y: [CGFloat]) -> [CGFloat] {
            zip(x, y).map { $0 + ($1 - $0) * f }
        }
        return (mix(a.warm, b.warm), mix(a.cool, b.cool),
                a.ambient + (b.ambient - a.ambient) * f)
    }

    static func colors(at t: CGFloat) -> (warm: SKColor, cool: SKColor, ambient: SKColor) {
        let light = lighting(at: t)
        return (color(light.warm), color(light.cool),
                SKColor(white: light.ambient, alpha: 1))
    }

    /// RGB(A) components → a colour, tolerant of short arrays because these
    /// numbers arrive from JSON.
    static func color(_ components: [CGFloat]) -> SKColor {
        guard components.count >= 3 else { return .white }
        return SKColor(red: components[0], green: components[1], blue: components[2],
                       alpha: components.count > 3 ? components[3] : 1)
    }
}

/// Applies lighting to sprites: generates a normal map from the sprite's own
/// texture and sets the bit masks. Normal generation is expensive, so results
/// are cached per texture — call freely during scene build, never per frame.
enum NormalMapper {

    private static var cache: [ObjectIdentifier: SKTexture] = [:]

    /// - Parameters:
    ///   - smoothness / contrast: `generatingNormalMap` tuning. Higher contrast
    ///     = more pronounced relief; painted cartoon art wants moderate values.
    static func normal(for texture: SKTexture,
                       smoothness: CGFloat = 0.6,
                       contrast: CGFloat = 1.6) -> SKTexture {
        let id = ObjectIdentifier(texture)
        if let cached = cache[id] { return cached }
        let normal = texture.generatingNormalMap(withSmoothness: smoothness,
                                                 contrast: contrast)
        cache[id] = normal
        return normal
    }

    /// An authored normal map if one is bundled beside the art, generated
    /// otherwise.
    ///
    /// Generated normals infer relief from luminance, which guesses wrong exactly
    /// where art is most deliberate — a painted highlight becomes a bump. Naming
    /// convention: `hero_body` → `hero_body_n`. Falling back automatically means
    /// an artist can hand-author only the assets that need it.
    static func normal(forImageNamed name: String, texture: SKTexture,
                       smoothness: CGFloat = 0.6,
                       contrast: CGFloat = 1.6) -> SKTexture {
        if let authored = authoredCache[name] { return authored }
        if UIImage(named: name + "_n") != nil {
            let map = SKTexture(imageNamed: name + "_n")
            map.filteringMode = .linear
            authoredCache[name] = map
            return map
        }
        return normal(for: texture, smoothness: smoothness, contrast: contrast)
    }

    private static var authoredCache: [String: SKTexture] = [:]

    /// What part a sprite plays in shadowing.
    ///
    /// The distinction matters, and getting it wrong was a real bug here: the previous
    /// code set `shadowCastBitMask` *and* `shadowedBitMask` to the same mask on the same
    /// sprite, so every sprite both cast a shadow and received one from the same light —
    /// which means it shadows itself. The symptom is a muddy, dirty-looking sprite that
    /// no amount of normal-map tuning fixes, because the problem isn't the normals.
    ///
    /// So a sprite is normally one or the other:
    ///   * **casters** are things that block light: the player, enemies, props, crates
    ///   * **receivers** are things shadows land on: terrain, ground, the backdrop
    ///   * `.both` exists for genuinely thick geometry where self-shadowing reads as
    ///     form rather than as dirt, and it is deliberately not the default
    enum ShadowRole {
        case none, caster, receiver, both

        var cast: UInt32 { self == .caster || self == .both ? LightCategory.key : 0 }
        var receive: UInt32 { self == .receiver || self == .both ? LightCategory.key : 0 }
    }

    /// Light a sprite and give it a shadowing role.
    static func apply(to sprite: SKSpriteNode,
                      categories: UInt32 = LightCategory.all,
                      shadows: ShadowRole = .none,
                      smoothness: CGFloat = 0.6,
                      contrast: CGFloat = 1.6) {
        guard let tex = sprite.texture else { return }
        sprite.normalTexture = normal(for: tex, smoothness: smoothness, contrast: contrast)
        sprite.lightingBitMask = categories
        sprite.shadowCastBitMask = shadows.cast
        sprite.shadowedBitMask = shadows.receive
    }

    /// Recursively light every sprite under a node — one call for a whole rig
    /// or a whole backdrop.
    static func applyRecursively(from node: SKNode,
                                 categories: UInt32 = LightCategory.all,
                                 shadows: ShadowRole = .none,
                                 contrast: CGFloat = 1.6) {
        if let sprite = node as? SKSpriteNode, sprite.texture != nil {
            apply(to: sprite, categories: categories,
                  shadows: shadows, contrast: contrast)
        }
        for child in node.children {
            applyRecursively(from: child, categories: categories,
                             shadows: shadows, contrast: contrast)
        }
    }

    /// Source compatibility for the old boolean. `true` meant "cast *and* receive",
    /// which is the self-shadowing bug — so it maps to `.caster`, which is what every
    /// call site actually wanted.
    // Attribute messages must be a single literal — no concatenation allowed.
    @available(*, deprecated, message: "use `shadows:`; a bool cannot say whether a sprite casts or receives, and setting both self-shadows it")
    static func applyRecursively(from node: SKNode,
                                 categories: UInt32 = LightCategory.all,
                                 castsShadows: Bool,
                                 contrast: CGFloat = 1.6) {
        applyRecursively(from: node, categories: categories,
                         shadows: castsShadows ? .caster : .none, contrast: contrast)
    }

    static func clearCache() { cache.removeAll(); authoredCache.removeAll() }
}

/// DEBUG-only asset hot-reload. Watches a directory of JSON/PNG assets and
/// fires a callback when anything changes, so a rig or frieze scene can be
/// re-tweaked in the editor and seen in the running game without a rebuild.
///
/// Point it at a folder inside the app's Documents directory (accessible via
/// Finder file sharing or the simulator's data container) and drop authored
/// files there while the game runs.
final class HotReloader {

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init?(directory: URL, onChange: @escaping () -> Void) {
        #if DEBUG
        self.onChange = onChange
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.descriptor, fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
        #else
        return nil   // never ships in Release
        #endif
    }

    /// Editors write several files in quick succession; coalesce them.
    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit {
        source?.cancel()
    }

    /// Convenience: the app's Documents directory.
    static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}

/// Light cookies — patterned shadow overlays.
///
/// **What this is and is not.** `SKLightNode` has no cookie or gobo property: you
/// cannot hand SpriteKit a mask and have it project through the light. So a cookie
/// here is an additive/multiplicative *overlay* drawn in front of the lit content, in
/// camera space, with a generated pattern. It is a convincing fake for the thing that
/// matters — dappled light through a canopy, bars through a window, caustics under
/// water — and it is honest to call it a fake, because it does not respond to the
/// light's position the way a real projected cookie would.
///
/// It is cheap: one sprite, one generated texture per pattern, and an optional drift
/// animation. That is exactly the right trade for an effect whose whole job is to break
/// up flat light.
enum LightCookie {

    enum Pattern: String, CaseIterable {
        /// Soft irregular blobs — light through leaves. The one you want most.
        case dapple
        /// Hard parallel bars — a window, a grate, a cell.
        case blinds
        /// A cross-barred window frame.
        case window
        /// Wobbling bright lines — underwater.
        case caustic
    }

    private static var cache: [Pattern: SKTexture] = [:]

    /// A cookie node, sized to the scene and ready to attach to the camera.
    ///
    /// - Parameters:
    ///   - strength: 0…1. How dark the shadowed parts get.
    ///   - drift: points per second of horizontal travel. Dapple should always drift a
    ///     little — static dappling reads as a texture on the screen rather than as
    ///     light in the world.
    static func make(_ pattern: Pattern, sceneSize: CGSize, strength: CGFloat = 0.35,
                     scale: CGFloat = 1.6, drift: CGFloat = 6,
                     tint: SKColor = SKColor(white: 0, alpha: 1)) -> SKSpriteNode {
        let node = SKSpriteNode(texture: texture(for: pattern))
        // Oversized so drifting never exposes an edge.
        node.size = CGSize(width: sceneSize.width * scale * 2,
                           height: sceneSize.height * scale * 2)
        node.color = tint
        node.colorBlendFactor = 1
        node.alpha = max(0, min(1, strength))
        // Multiply, so the pattern *removes* light rather than adding a grey film.
        node.blendMode = .multiply
        node.zPosition = 300
        node.name = "cookie.\(pattern.rawValue)"
        if drift > 0.01 {
            let distance = sceneSize.width * scale
            let seconds = Double(distance / max(drift, 0.01))
            node.run(.repeatForever(.sequence([
                .moveBy(x: -distance, y: 0, duration: seconds),
                .moveBy(x: distance, y: 0, duration: 0),
            ])))
        }
        return node
    }

    /// The pattern texture, generated once. Tiling horizontally so a drifting cookie
    /// never runs out.
    static func texture(for pattern: Pattern) -> SKTexture {
        if let hit = cache[pattern] { return hit }
        let size = CGSize(width: 512, height: 256)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            // White = full light, black = shadowed, because the node multiplies.
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setFillColor(UIColor.black.cgColor)
            var generator = SeededRandom(seed: 20_260_820)

            switch pattern {
            case .dapple:
                // Overlapping soft ellipses, then blurred by drawing many with low
                // alpha — a real blur pass would cost more than it is worth here.
                for _ in 0..<70 {
                    let r = CGFloat(generator.next(in: 18...64))
                    let x = CGFloat(generator.next(in: -60...572))
                    let y = CGFloat(generator.next(in: -40...296))
                    cg.setFillColor(UIColor.black.withAlphaComponent(0.16).cgColor)
                    cg.fillEllipse(in: CGRect(x: x - r, y: y - r * 0.8,
                                              width: r * 2, height: r * 1.6))
                }
            case .blinds:
                let step: CGFloat = 34
                var y: CGFloat = 0
                while y < size.height {
                    cg.fill(CGRect(x: 0, y: y, width: size.width, height: step * 0.42))
                    y += step
                }
            case .window:
                cg.setFillColor(UIColor.black.withAlphaComponent(0.9).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                cg.setFillColor(UIColor.white.cgColor)
                // Four panes with a frame between them.
                for column in 0..<2 {
                    for row in 0..<2 {
                        cg.fill(CGRect(x: 40 + CGFloat(column) * 224,
                                       y: 30 + CGFloat(row) * 108,
                                       width: 184, height: 86))
                    }
                }
            case .caustic:
                for _ in 0..<26 {
                    let y = CGFloat(generator.next(in: 0...256))
                    let amplitude = CGFloat(generator.next(in: 4...16))
                    let thickness = CGFloat(generator.next(in: 2...7))
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: 0, y: y))
                    var x: CGFloat = 0
                    while x < size.width {
                        x += 16
                        path.addLine(to: CGPoint(
                            x: x, y: y + sin(x / 40) * amplitude))
                    }
                    cg.setStrokeColor(UIColor.black.withAlphaComponent(0.30).cgColor)
                    cg.setLineWidth(thickness)
                    cg.addPath(path)
                    cg.strokePath()
                }
            }
        }
        let texture = SKTexture(image: image)
        cache[pattern] = texture
        return texture
    }
}

/// A tiny deterministic generator.
///
/// Not `SystemRandomNumberGenerator`: a cookie texture is generated at load and must be
/// identical every run, or the same level looks different each time it is entered.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 33) / Double(UInt64(1) << 31)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
