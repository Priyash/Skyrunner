import SpriteKit

/// A data-driven particle system: `particle/1`.
///
/// What it replaces. `FX/Effects.swift` was three hardcoded functions — dust, burst,
/// float-text — and two `SKEmitterNode`s in the whole engine. Every new effect meant a
/// new Swift function, which is the same constraint that capped enemy count before
/// behaviours became data. A platformer of this kind lives on effect density: dust on
/// every step, sparks on every hit, leaves in the wind, splash, embers, magic.
///
/// Design decisions, each of which is load-bearing:
///
/// * **Presets are data, spawning is code.** A `ParticleSpec` is `Codable` and
///   validatable offline; `ParticleLibrary` turns one into a pooled emitter. An
///   embedded expression language would be more flexible and none of those things.
/// * **Pooled, not allocated per burst.** `SKEmitterNode` is expensive to build —
///   creating one per coin pickup is a frame hitch you can feel. Emitters are recycled
///   through a fixed-size pool, and the pool is per-preset because an emitter's
///   configuration is baked in.
/// * **Textures are generated, not shipped.** A particle texture is a 16px blob; a
///   round-trip through the asset pipeline for that would be silly, and generating it
///   means a new preset needs no art at all.
/// * **A hard cap on live emitters.** Effects are the easiest thing in a game to
///   overspend on, and the failure mode is a frame-rate cliff under exactly the
///   conditions that matter (a busy fight). The cap makes that impossible.
struct ParticleSpec: Codable, Equatable {

    static let currentFormat = "particle/1"

    /// The shape a particle is drawn as. Generated at load, so a preset needs no art.
    enum Shape: String, Codable {
        /// Soft round falloff. Dust, smoke, glow, embers.
        case blob
        /// Hard-edged disc. Sparks, coins, debris.
        case disc
        /// A short bar, oriented by travel. Rain, streaks, slashes.
        case streak
        /// Four-pointed star. Magic, pickups, twinkle.
        case star
        /// A leaf-ish rounded triangle. Foliage, petals, paper.
        case leaf
    }

    /// How particles are emitted over time.
    enum Kind: String, Codable {
        /// A fixed number, all at once, then done. Impacts.
        case burst
        /// A steady rate until stopped. Torches, waterfalls, wind.
        case stream
    }

    var format: String = ParticleSpec.currentFormat
    var name: String
    var kind: Kind = .burst
    var shape: Shape = .blob

    /// Particles per burst, or per second for a stream.
    var count: Int = 16
    var lifetime: Double = 0.6
    var lifetimeRange: Double = 0.25

    /// Points per second.
    var speed: CGFloat = 120
    var speedRange: CGFloat = 60
    /// Emission cone, in degrees. 360 is omnidirectional.
    var spread: CGFloat = 360
    /// Cone centre, in degrees, 0 = right, 90 = up.
    var direction: CGFloat = 90

    /// Particle size in points at birth, and how it changes over life.
    var size: CGFloat = 8
    var sizeRange: CGFloat = 4
    /// Multiplier applied across the lifetime: <1 shrinks, >1 grows.
    var sizeScale: CGFloat = 0.6

    var alpha: CGFloat = 0.9
    var alphaRange: CGFloat = 0.2

    /// RGB 0…255. Two colours are blended across the lifetime, which is most of what
    /// makes an effect read as *hot* or *cold* rather than as coloured dots.
    var colour: [Int] = [255, 255, 255]
    var colourEnd: [Int]?

    /// Points per second². Negative y falls.
    var gravity: CGFloat = -240
    /// Extra spin, degrees per second.
    var spin: CGFloat = 0
    var spinRange: CGFloat = 0
    /// Additive blending — right for anything that emits light, wrong for dust.
    var additive: Bool = false
    /// Emission area, in points: a splash across a puddle rather than from a point.
    var spawnWidth: CGFloat = 0
    var spawnHeight: CGFloat = 0

    var problems: [String] {
        var out: [String] = []
        if format != ParticleSpec.currentFormat {
            out.append("format is '\(format)', expected '\(ParticleSpec.currentFormat)'")
        }
        if name.isEmpty { out.append("particle preset needs a name") }
        // Bounds are chosen to be *generous but finite*: the point is to make a typo
        // impossible to ship, not to police taste.
        if count < 1 || count > 400 { out.append("count \(count) is outside 1…400") }
        if lifetime <= 0 || lifetime > 12 {
            out.append("lifetime \(lifetime)s is outside 0…12")
        }
        if lifetimeRange < 0 || lifetimeRange > lifetime {
            out.append("lifetimeRange \(lifetimeRange) must be 0…lifetime, or some "
                       + "particles would be born already dead")
        }
        if speed < 0 || speed > 2000 { out.append("speed \(speed) is outside 0…2000") }
        if speedRange < 0 { out.append("speedRange cannot be negative") }
        if spread < 0 || spread > 360 {
            out.append("spread \(spread)° is outside 0…360")
        }
        if size <= 0 || size > 200 { out.append("size \(size) is outside 0…200") }
        if sizeRange < 0 { out.append("sizeRange cannot be negative") }
        if sizeScale <= 0 || sizeScale > 8 {
            out.append("sizeScale \(sizeScale) is outside 0…8")
        }
        if alpha <= 0 || alpha > 1 { out.append("alpha \(alpha) is outside 0…1") }
        if colour.count < 3 { out.append("colour needs RGB") }
        if let end = colourEnd, end.count < 3 { out.append("colourEnd needs RGB") }
        if abs(gravity) > 4000 { out.append("gravity \(gravity) exceeds ±4000") }
        if spawnWidth < 0 || spawnHeight < 0 {
            out.append("spawn area cannot be negative")
        }
        // A stream with a huge count is the one combination that will melt a device.
        if kind == .stream, count > 120 {
            out.append("a stream at \(count)/s is more than the cap allows; use a "
                       + "burst or lower the rate")
        }
        return out
    }
}

/// Builds, pools and fires emitters from presets.
///
/// One instance per scene. `ParticleLibrary.install(in:)` attaches it; `emit` is the
/// only thing gameplay calls.
final class ParticleLibrary {

    /// Live emitters allowed at once.
    ///
    /// Effects are the easiest thing to overspend on and the failure mode is a
    /// frame-rate cliff during a busy fight — exactly when it matters most. Refusing
    /// the 33rd simultaneous effect is invisible; dropping to 20fps is not.
    static let maxLive = 32

    private var specs: [String: ParticleSpec] = [:]
    private var pools: [String: [SKEmitterNode]] = [:]
    private var live: [(node: SKEmitterNode, until: TimeInterval, preset: String)] = []
    private weak var host: SKNode?
    /// Textures are shared across every emitter of a shape — one 32px texture each.
    private static var textures: [ParticleSpec.Shape: SKTexture] = [:]

    init(host: SKNode) {
        self.host = host
        for preset in ParticleSpec.shipped() where preset.problems.isEmpty {
            specs[preset.name] = preset
        }
        // Bundled presets override built-ins of the same name, so a project can retune
        // an effect without touching code.
        for preset in ParticleLibrary.loadBundled() where preset.problems.isEmpty {
            specs[preset.name] = preset
        }
    }

    var presetNames: [String] { specs.keys.sorted() }
    var liveCount: Int { live.count }
    func spec(named name: String) -> ParticleSpec? { specs[name] }

    /// Fire a preset at a point. Silently ignored if the preset is unknown or the cap
    /// is reached — an effect is never worth a crash or a stall.
    @discardableResult
    func emit(_ name: String, at position: CGPoint, now: TimeInterval,
              angle: CGFloat? = nil) -> SKEmitterNode? {
        guard let spec = specs[name], let host, live.count < ParticleLibrary.maxLive
        else { return nil }
        let emitter = borrow(spec)
        emitter.position = position
        if let angle { emitter.emissionAngle = angle }
        emitter.resetSimulation()
        emitter.particleBirthRate = spec.kind == .burst
            ? CGFloat(spec.count) * 60      // a burst is one frame's worth
            : CGFloat(spec.count)
        if spec.kind == .burst {
            emitter.numParticlesToEmit = spec.count
        } else {
            emitter.numParticlesToEmit = 0
        }
        if emitter.parent == nil { host.addChild(emitter) }
        // Reclaim after the last particle can possibly have died. Tracked here rather
        // than with an `SKAction` so the pool is authoritative and a scene teardown
        // cannot leave an emitter orphaned mid-action.
        let alive = spec.lifetime + spec.lifetimeRange
            + (spec.kind == .stream ? 2.0 : 0)
        live.append((emitter, now + alive + 0.1, spec.name))
        return emitter
    }

    /// Stop a stream early and let its particles die out.
    func stop(_ emitter: SKEmitterNode) {
        emitter.particleBirthRate = 0
    }

    /// Reclaim finished emitters. Called once per frame from the scene.
    func update(now: TimeInterval) {
        guard !live.isEmpty else { return }
        var index = 0
        while index < live.count {
            if now >= live[index].until {
                let entry = live.remove(at: index)
                entry.node.particleBirthRate = 0
                entry.node.removeFromParent()
                pools[entry.preset, default: []].append(entry.node)
            } else {
                index += 1
            }
        }
    }

    private func borrow(_ spec: ParticleSpec) -> SKEmitterNode {
        if var pool = pools[spec.name], let node = pool.popLast() {
            pools[spec.name] = pool
            return node
        }
        return ParticleLibrary.build(spec)
    }

    // MARK: Building

    private static func build(_ spec: ParticleSpec) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = texture(for: spec.shape)
        emitter.particleLifetime = CGFloat(spec.lifetime)
        emitter.particleLifetimeRange = CGFloat(spec.lifetimeRange)
        emitter.particleSpeed = spec.speed
        emitter.particleSpeedRange = spec.speedRange
        emitter.emissionAngle = spec.direction * .pi / 180
        emitter.emissionAngleRange = spec.spread * .pi / 180
        emitter.particleSize = CGSize(width: spec.size, height: spec.size)
        emitter.particleScaleRange = spec.sizeRange / max(spec.size, 1)
        // `particleScaleSpeed` is per second, so a lifetime-relative scale has to be
        // divided by the lifetime — getting this wrong makes short effects barely
        // change size and long ones invert.
        emitter.particleScaleSpeed = (spec.sizeScale - 1) / CGFloat(max(spec.lifetime, 0.01))
        emitter.particleAlpha = spec.alpha
        emitter.particleAlphaRange = spec.alphaRange
        emitter.particleAlphaSpeed = -spec.alpha / CGFloat(max(spec.lifetime, 0.01))
        emitter.particleColor = colour(spec.colour)
        emitter.particleColorBlendFactor = 1
        if let end = spec.colourEnd {
            emitter.particleColorSequence = SKKeyframeSequence(
                keyframeValues: [colour(spec.colour), colour(end)],
                times: [0, NSNumber(value: 1)])
        }
        emitter.yAcceleration = spec.gravity
        emitter.particleRotationSpeed = spec.spin * .pi / 180
        emitter.particleRotationRange = spec.spinRange * .pi / 180
        emitter.particleBlendMode = spec.additive ? .add : .alpha
        emitter.particlePositionRange = CGVector(dx: spec.spawnWidth,
                                                dy: spec.spawnHeight)
        // Emit in scene space, not emitter space: a burst attached to a moving node
        // should leave its particles behind, not drag them along.
        emitter.targetNode = nil
        emitter.zPosition = 90
        emitter.name = "fx.\(spec.name)"
        return emitter
    }

    private static func colour(_ rgb: [Int]) -> SKColor {
        SKColor(red: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255,
                blue: CGFloat(rgb[2]) / 255, alpha: 1)
    }

    /// A particle texture, generated once per shape.
    static func texture(for shape: ParticleSpec.Shape) -> SKTexture {
        if let hit = textures[shape] { return hit }
        let side = 32
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            let radius = CGFloat(side) / 2 - 1
            switch shape {
            case .blob:
                // Radial falloff: the only shape that needs a gradient, and the reason
                // dust and smoke read as soft rather than as circles.
                let colours = [UIColor.white.withAlphaComponent(1).cgColor,
                               UIColor.white.withAlphaComponent(0).cgColor]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colours as CFArray,
                                             locations: [0, 1]) {
                    cg.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                          endCenter: centre, endRadius: radius,
                                          options: [])
                }
            case .disc:
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2))
            case .streak:
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(x: 2, y: centre.y - 2.5,
                               width: CGFloat(side) - 4, height: 5))
            case .star:
                cg.setFillColor(UIColor.white.cgColor)
                // Four points, drawn as two crossed tapers — cheaper than a polygon
                // and it reads better small.
                for rotation in [0.0, Double.pi / 2] {
                    cg.saveGState()
                    cg.translateBy(x: centre.x, y: centre.y)
                    cg.rotate(by: CGFloat(rotation))
                    cg.move(to: CGPoint(x: 0, y: radius))
                    cg.addLine(to: CGPoint(x: radius * 0.22, y: 0))
                    cg.addLine(to: CGPoint(x: 0, y: -radius))
                    cg.addLine(to: CGPoint(x: -radius * 0.22, y: 0))
                    cg.closePath()
                    cg.fillPath()
                    cg.restoreGState()
                }
            case .leaf:
                cg.setFillColor(UIColor.white.cgColor)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: centre.x, y: centre.y + radius))
                path.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y - radius),
                                  control: CGPoint(x: centre.x + radius, y: centre.y))
                path.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y + radius),
                                  control: CGPoint(x: centre.x - radius * 0.3,
                                                   y: centre.y))
                cg.addPath(path)
                cg.fillPath()
            }
        }
        let texture = SKTexture(image: image)
        textures[shape] = texture
        return texture
    }

    private static func loadBundled() -> [ParticleSpec] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                         subdirectory: nil) else { return [] }
        let decoder = JSONDecoder()
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let spec = try? decoder.decode(ParticleSpec.self, from: data),
                  spec.format == ParticleSpec.currentFormat
            else { return nil }
            return spec
        }
    }
}

// MARK: - The shipped presets

extension ParticleSpec {

    /// Fourteen presets covering what a platformer actually needs.
    ///
    /// Written out rather than generated because a preset *is* art direction: the
    /// numbers are the effect. They are grouped by what triggers them, which is also
    /// the order in which you notice them missing.
    static func shipped() -> [ParticleSpec] {
        [
            // ── movement ────────────────────────────────────────────────────
            ParticleSpec(name: "step_dust", kind: .burst, shape: .blob, count: 5,
                         lifetime: 0.34, lifetimeRange: 0.12, speed: 46,
                         speedRange: 24, spread: 110, direction: 90, size: 9,
                         sizeRange: 4, sizeScale: 1.7, alpha: 0.5, alphaRange: 0.15,
                         colour: [214, 202, 176], gravity: -60, spawnWidth: 8),
            ParticleSpec(name: "land_dust", kind: .burst, shape: .blob, count: 14,
                         lifetime: 0.44, lifetimeRange: 0.16, speed: 130,
                         speedRange: 60, spread: 70, direction: 90, size: 13,
                         sizeRange: 6, sizeScale: 2.0, alpha: 0.62,
                         colour: [222, 210, 184], gravity: -120, spawnWidth: 16),
            ParticleSpec(name: "dash_streak", kind: .burst, shape: .streak, count: 10,
                         lifetime: 0.24, lifetimeRange: 0.08, speed: 210,
                         speedRange: 80, spread: 26, direction: 180, size: 18,
                         sizeRange: 6, sizeScale: 0.4, alpha: 0.7,
                         colour: [220, 240, 255], colourEnd: [120, 180, 255],
                         gravity: 0, additive: true, spawnHeight: 14),
            ParticleSpec(name: "hover_wind", kind: .stream, shape: .blob, count: 26,
                         lifetime: 0.5, lifetimeRange: 0.2, speed: 90,
                         speedRange: 40, spread: 60, direction: 270, size: 10,
                         sizeRange: 5, sizeScale: 1.6, alpha: 0.35,
                         colour: [232, 240, 248], gravity: -200, spawnWidth: 20),

            // ── impacts ─────────────────────────────────────────────────────
            ParticleSpec(name: "hit_spark", kind: .burst, shape: .star, count: 18,
                         lifetime: 0.4, lifetimeRange: 0.16, speed: 260,
                         speedRange: 130, spread: 360, size: 11, sizeRange: 5,
                         sizeScale: 0.3, alpha: 1.0,
                         colour: [255, 246, 190], colourEnd: [255, 132, 40],
                         gravity: -420, spin: 220, spinRange: 180, additive: true),
            ParticleSpec(name: "stomp_puff", kind: .burst, shape: .blob, count: 20,
                         lifetime: 0.42, lifetimeRange: 0.14, speed: 190,
                         speedRange: 90, spread: 150, direction: 90, size: 15,
                         sizeRange: 7, sizeScale: 1.9, alpha: 0.8,
                         colour: [190, 150, 240], colourEnd: [110, 70, 180],
                         gravity: -260, spawnWidth: 18),
            ParticleSpec(name: "pound_shock", kind: .burst, shape: .disc, count: 26,
                         lifetime: 0.5, lifetimeRange: 0.16, speed: 330,
                         speedRange: 120, spread: 46, direction: 0, size: 14,
                         sizeRange: 6, sizeScale: 0.5, alpha: 0.9,
                         colour: [255, 220, 160], colourEnd: [200, 90, 40],
                         gravity: -180, additive: true, spawnHeight: 8),
            ParticleSpec(name: "crate_debris", kind: .burst, shape: .leaf, count: 22,
                         lifetime: 0.9, lifetimeRange: 0.3, speed: 240,
                         speedRange: 120, spread: 360, size: 12, sizeRange: 6,
                         sizeScale: 0.9, alpha: 1.0, colour: [186, 132, 74],
                         gravity: -900, spin: 320, spinRange: 260),

            // ── pickups and progress ────────────────────────────────────────
            ParticleSpec(name: "coin_sparkle", kind: .burst, shape: .star, count: 12,
                         lifetime: 0.5, lifetimeRange: 0.2, speed: 150,
                         speedRange: 70, spread: 360, size: 10, sizeRange: 5,
                         sizeScale: 0.35, alpha: 1.0,
                         colour: [255, 240, 150], colourEnd: [255, 190, 60],
                         gravity: -140, spin: 300, spinRange: 200, additive: true),
            ParticleSpec(name: "checkpoint_flare", kind: .burst, shape: .blob,
                         count: 30, lifetime: 0.8, lifetimeRange: 0.3, speed: 120,
                         speedRange: 60, spread: 40, direction: 90, size: 16,
                         sizeRange: 8, sizeScale: 1.4, alpha: 0.8,
                         colour: [150, 255, 210], colourEnd: [40, 160, 255],
                         gravity: 40, additive: true, spawnWidth: 14),
            ParticleSpec(name: "goal_burst", kind: .burst, shape: .star, count: 60,
                         lifetime: 1.2, lifetimeRange: 0.5, speed: 300,
                         speedRange: 160, spread: 360, size: 14, sizeRange: 7,
                         sizeScale: 0.4, alpha: 1.0,
                         colour: [255, 252, 220], colourEnd: [255, 160, 220],
                         gravity: -260, spin: 260, spinRange: 220, additive: true),

            // ── ambience: streams a level leaves running ─────────────────────
            ParticleSpec(name: "falling_leaves", kind: .stream, shape: .leaf, count: 6,
                         lifetime: 4.0, lifetimeRange: 1.5, speed: 26,
                         speedRange: 16, spread: 50, direction: 270, size: 13,
                         sizeRange: 6, sizeScale: 1.0, alpha: 0.85,
                         colour: [148, 196, 96], colourEnd: [206, 172, 84],
                         gravity: -34, spin: 90, spinRange: 140, spawnWidth: 420),
            ParticleSpec(name: "embers", kind: .stream, shape: .blob, count: 14,
                         lifetime: 2.2, lifetimeRange: 0.9, speed: 44,
                         speedRange: 26, spread: 44, direction: 90, size: 7,
                         sizeRange: 4, sizeScale: 0.5, alpha: 0.9,
                         colour: [255, 200, 120], colourEnd: [220, 80, 40],
                         gravity: 42, additive: true, spawnWidth: 120),
            ParticleSpec(name: "waterfall_mist", kind: .stream, shape: .blob,
                         count: 30, lifetime: 1.1, lifetimeRange: 0.5, speed: 70,
                         speedRange: 40, spread: 120, direction: 90, size: 18,
                         sizeRange: 9, sizeScale: 2.2, alpha: 0.32,
                         colour: [226, 244, 255], gravity: -60, spawnWidth: 40),
        ]
    }

    /// Which preset a gameplay event fires. Named events rather than call sites, so
    /// retuning what a stomp looks like is one line here.
    static let events: [String: String] = [
        "step": "step_dust", "land": "land_dust", "dash": "dash_streak",
        "hover": "hover_wind", "punch": "hit_spark", "stomp": "stomp_puff",
        "pound": "pound_shock", "crate": "crate_debris", "coin": "coin_sparkle",
        "checkpoint": "checkpoint_flare", "goal": "goal_burst",
    ]
}
