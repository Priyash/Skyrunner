import SpriteKit
import UIKit
import CoreImage

/// The runtime stage. Attach to the camera; call `update(camX:)` each frame.
///
/// Parallax model: a layer at `depth` scrolls at `depth / focus` of camera
/// speed. As camera children, sprites are screen-locked by default, so each
/// frame we counter-offset by `camX * rate` — rate 1 (gameplay plane) is
/// fully world-locked, rate → 0 (far sky) barely moves, rate > 1
/// (foreground) sweeps past faster than the world. Identical math to the
/// Python composer, so what you previewed offline is what ships.
final class FriezeStage: SKNode {

    private struct Plane {
        /// One entry per copy: a tiled layer is the same texture repeated, and
        /// each copy needs its own base offset.
        ///
        /// `SKNode`, not `SKSpriteNode`, because a plane can now be spline geometry
        /// or a scatter of props rather than a single picture.
        let nodes: [SKNode]
        /// The subset that can be tinted directly. Shapes and effect nodes can't,
        /// so they get `overlays` instead.
        let tintables: [SKSpriteNode]
        /// Sky-coloured wash over non-sprite content — this is what haze *is*, and
        /// it is also how the time-of-day dial reaches geometry it can't recolour.
        let overlays: [SKSpriteNode]
        let baseX: CGFloat
        let baseY: CGFloat
        let rate: CGFloat
        let verticalRate: CGFloat
        let span: CGFloat            // width of one copy, for the wrap
        let tiled: Bool
        let drift: CGFloat
        let sway: CGFloat
        let swayRate: CGFloat
        let depth: CGFloat
    }
    private var planes: [Plane] = []
    /// Wind and impact deformation. Nil until a layer asks for it, so a rigid backdrop
    /// costs exactly nothing.
    private var deformer: BackdropDeformer?
    private var elapsed: TimeInterval = 0
    private var focus: CGFloat = 0.5

    /// Build from a bundled scene JSON; nil lets callers fall back to any
    /// procedural background.
    static func load(named name: String, sceneSize: CGSize) -> FriezeStage? {
        guard let scene = FriezeScene.load(named: name) else { return nil }
        // Verify at least one layer image is actually in the bundle —
        // otherwise fall back rather than showing an empty backdrop.
        guard scene.layers.contains(where: { UIImage(named: $0.image) != nil })
        else { return nil }
        return FriezeStage(scene: scene, sceneSize: sceneSize)
    }

    init(scene: FriezeScene, sceneSize: CGSize) {
        super.init()

        // Sky — screen-locked, behind everything.
        let sky = SKSpriteNode(texture: FriezeBaker.skyTexture(stops: scene.sky,
                                                               size: sceneSize))
        sky.size = CGSize(width: sceneSize.width * 1.3, height: sceneSize.height * 1.3)
        sky.zPosition = -400
        addChild(sky)

        // Layers, far → near. Background sits behind gameplay (negative z),
        // foreground (depth > focus) renders over it.
        focus = scene.focus
        for layer in scene.layers.sorted(by: { $0.depth < $1.depth }) {
            guard let tex = FriezeBaker.bake(imageNamed: layer.image,
                                             depth: layer.depth, scene: scene)
            else { continue }
            let size = FriezeBaker.pointSize(imageNamed: layer.image,
                                             scale: layer.scale ?? 1,
                                             density: layer.density ?? 3)
            let z: CGFloat = layer.depth > scene.focus
                ? 150 + layer.depth * 100          // foreground overlay
                : -300 + layer.depth * 200         // backdrop, far → near
            let tiled = layer.tile ?? false
            // Three copies is enough for any scroll rate: one on screen and one
            // waiting on each side, recycled by the wrap in `update`.
            let copies = tiled ? 3 : 1
            var nodes: [SKSpriteNode] = []
            for i in 0..<copies {
                let sprite = SKSpriteNode(texture: tex)
                sprite.size = size
                sprite.xScale = (layer.flipX ?? false) ? -1 : 1
                sprite.position = CGPoint(x: layer.x + CGFloat(i - copies / 2) * size.width,
                                          y: layer.y)
                sprite.zPosition = z
                addChild(sprite)
                nodes.append(sprite)
            }
            // Wind, if the layer asked for it. Adopted per copy so a tiled layer's
            // three sprites each sway independently rather than in lockstep.
            if let wind = layer.wind, wind > 0.01 {
                if deformer == nil { deformer = BackdropDeformer() }
                for sprite in nodes {
                    deformer?.adopt(sprite, depth: layer.depth,
                                    amplitude: wind,
                                    pinBottom: !(layer.windPinTop ?? false))
                }
            }
            let rate = layer.depth / max(scene.focus, 0.001)
            planes.append(Plane(nodes: nodes, tintables: nodes, overlays: [],
                                baseX: layer.x, baseY: layer.y,
                                rate: rate,
                                verticalRate: layer.verticalRate ?? rate,
                                span: max(size.width, 1), tiled: tiled,
                                drift: layer.drift ?? 0,
                                sway: layer.sway ?? 0,
                                swayRate: layer.swayRate ?? 0.6,
                                depth: layer.depth))
        }

        // Spline geometry and prop scatters, plane by plane. Same depth ordering,
        // same parallax, same haze and depth of field as an image layer — which is
        // the point: a backdrop element should not be second-class because it
        // happens to be a curve.
        for layer in scene.layers.sorted(by: { $0.depth < $1.depth }) {
            if let frises = layer.frises, !frises.isEmpty {
                addGeometryPlane(content: frises.compactMap { spec -> SKNode? in
                    var decor = spec
                    decor.kind = .decor          // a backdrop never collides
                    return FriseNode(spec: decor)
                }, layer: layer, scene: scene, sceneSize: sceneSize)
            }
            if let props = layer.props, !props.isEmpty {
                addGeometryPlane(content: props.flatMap {
                    FriezeStage.scatter($0, depth: layer.depth, scene: scene)
                }, layer: layer, scene: scene, sceneSize: sceneSize)
            }
        }

        // Volumetric shafts — additive, slowly pulsing.
        if let rays = scene.rays {
            let color = SKColor(red: CGFloat(rays.color[0]) / 255,
                                green: CGFloat(rays.color[1]) / 255,
                                blue: CGFloat(rays.color[2]) / 255, alpha: 1)
            for (i, ang) in rays.angles.enumerated() {
                let ray = SKSpriteNode(color: color,
                                       size: CGSize(width: rays.width,
                                                    height: sceneSize.height * 1.7))
                ray.alpha = rays.alpha
                ray.blendMode = .add
                ray.anchorPoint = CGPoint(x: 0.5, y: 1)
                ray.position = CGPoint(x: rays.x, y: rays.y)
                ray.zRotation = -ang * .pi / 180
                ray.zPosition = -90
                addChild(ray)
                ray.run(.repeatForever(.sequence([
                    .wait(forDuration: Double(i) * 0.7),
                    .fadeAlpha(to: rays.alpha * 0.45, duration: 2.6),
                    .fadeAlpha(to: rays.alpha, duration: 2.6),
                ])))
            }
        }

        // Fireflies — one emitter, additive glow particles drifting.
        if let ff = scene.fireflies {
            let color = UIColor(red: CGFloat(ff.color[0]) / 255,
                                green: CGFloat(ff.color[1]) / 255,
                                blue: CGFloat(ff.color[2]) / 255, alpha: 1)
            let e = SKEmitterNode()
            e.particleTexture = FriezeBaker.glowTexture(radius: 8, color: color)
            e.particleBirthRate = CGFloat(ff.count) / 6.0
            e.particleLifetime = 6
            e.particleLifetimeRange = 3
            e.particleSpeed = 10
            e.particleSpeedRange = 8
            e.emissionAngleRange = .pi * 2
            e.particleAlpha = 0.55
            e.particleAlphaRange = 0.3
            e.particleAlphaSpeed = -0.08
            e.particleScale = 0.5
            e.particleScaleRange = 0.35
            e.particleBlendMode = .add
            e.particlePositionRange = CGVector(dx: sceneSize.width,
                                               dy: sceneSize.height * 0.8)
            e.zPosition = -60
            addChild(e)
        }

        // Vignette — screen-locked, on top of everything.
        if let strength = scene.vignette, strength > 0.01 {
            let v = SKSpriteNode(texture: FriezeBaker.vignetteTexture(
                size: CGSize(width: 256, height: 128), strength: strength))
            v.size = CGSize(width: sceneSize.width * 1.05,
                            height: sceneSize.height * 1.05)
            v.zPosition = 400
            addChild(v)
        }
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Adopt a level's `decor` frises as backdrop planes.
    ///
    /// They live in the *level* file (that is where an author draws them) but they
    /// belong to the *backdrop* (that is where they have to be parallaxed, hazed and
    /// blurred). Before this they were built at a fixed z in scene space, which
    /// meant painted spline scenery slid past at exactly the speed of the ground —
    /// the one thing a backdrop must not do.
    func adoptDecor(_ specs: [FriseSpec], scene: FriezeScene, sceneSize: CGSize) {
        for spec in specs where spec.kind == .decor {
            let depth = spec.depth ?? 0.3
            let layer = FriezeScene.Layer(image: "", x: 0, y: 0, depth: depth,
                                          frises: [spec])
            addGeometryPlane(content: [FriseNode(spec: spec)].compactMap { $0 },
                             layer: layer, scene: scene, sceneSize: sceneSize)
        }
    }

    /// Wrap non-image content in a plane: depth-of-field blurred, hazed, parallaxed.
    ///
    /// `SKEffectNode` with `shouldRasterize` is exactly right here and nowhere else
    /// in the engine: backdrop geometry never changes, so it is rasterised once at
    /// load and then costs one textured quad per frame — the blur is free after the
    /// first frame. The post chain can't do that because the frame changes every
    /// tick.
    private func addGeometryPlane(content: [SKNode], layer: FriezeScene.Layer,
                                  scene: FriezeScene, sceneSize: CGSize) {
        guard !content.isEmpty else { return }
        let rate = layer.depth / max(scene.focus, 0.001)
        let z: CGFloat = layer.depth > scene.focus
            ? 150 + layer.depth * 100
            : -300 + layer.depth * 200
        let tiled = layer.tile ?? false
        // Prop scatters carry their own span; spline geometry is measured.
        let span = layer.props?.first?.span
            ?? max(1, content.reduce(CGFloat(0)) {
                max($0, $1.calculateAccumulatedFrame().maxX) })
        let copies = tiled ? 3 : 1

        // Depth of field, matching `FriezeBaker`'s formula so geometry and images
        // at the same depth are blurred by the same amount.
        let blur = abs(layer.depth - scene.focus) * scene.dofPointsPerDepth
        // Haze: how far this plane washes toward the sky. Same ramp as the baker.
        let hazeStrength = scene.haze
            * max(0, 1 - layer.depth / max(scene.focus, 0.001)) * 0.9
        let sky = scene.hazeColor

        var nodes: [SKNode] = []
        var overlays: [SKSpriteNode] = []
        for copy in 0..<copies {
            let holder: SKNode
            if blur > 0.4 {
                let effect = SKEffectNode()
                effect.shouldEnableEffects = true
                effect.shouldRasterize = true      // static content: blur once
                effect.filter = CIFilter(name: "CIGaussianBlur",
                                         parameters: ["inputRadius": blur])
                holder = effect
            } else {
                holder = SKNode()
            }
            for node in content {
                // Each copy needs its own nodes; a node has one parent.
                guard let clone = node.copy() as? SKNode else { continue }
                holder.addChild(clone)
            }
            if hazeStrength > 0.01 {
                let bounds = holder.calculateAccumulatedFrame()
                let wash = SKSpriteNode(color: SKColor(red: sky.0, green: sky.1,
                                                       blue: sky.2, alpha: 1),
                                        size: CGSize(width: max(bounds.width, 1),
                                                     height: max(bounds.height, 1)))
                wash.position = CGPoint(x: bounds.midX, y: bounds.midY)
                wash.alpha = hazeStrength
                wash.zPosition = 50
                holder.addChild(wash)
                overlays.append(wash)
            }
            holder.zPosition = z
            holder.position = CGPoint(x: layer.x + CGFloat(copy - copies / 2) * span,
                                      y: layer.y)
            addChild(holder)
            nodes.append(holder)
        }
        planes.append(Plane(nodes: nodes, tintables: [], overlays: overlays,
                            baseX: layer.x, baseY: layer.y, rate: rate,
                            verticalRate: layer.verticalRate ?? rate,
                            span: span, tiled: tiled,
                            drift: layer.drift ?? 0, sway: layer.sway ?? 0,
                            swayRate: layer.swayRate ?? 0.6, depth: layer.depth))
    }

    /// Deterministic prop scatter.
    ///
    /// A linear congruential generator rather than `SystemRandomNumberGenerator`:
    /// the offline preview has to place every instance in the same spot, and that
    /// means both sides run the *same* arithmetic from the same seed. A platform
    /// RNG gives no such guarantee.
    static func scatter(_ prop: FriezeScene.Prop, depth: CGFloat,
                        scene: FriezeScene) -> [SKNode] {
        guard prop.count > 0, let image = UIImage(named: prop.image) else { return [] }
        let texture = SKTexture(image: image)
        let density = max(prop.density ?? 3, 0.1)
        let size = CGSize(width: image.size.width * 3 / density * prop.scale,
                          height: image.size.height * 3 / density * prop.scale)
        var state = UInt64(bitPattern: Int64(prop.seed)) &* 6_364_136_223_846_793_005 &+ 1
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Double(state >> 33) / Double(UInt64(1) << 31))
        }
        var out: [SKNode] = []
        for index in 0..<prop.count {
            let sprite = SKSpriteNode(texture: texture)
            // Evenly spaced then jittered, so instances never clump into a gap.
            let slot = (CGFloat(index) + 0.5) / CGFloat(prop.count)
            let jitterX = (next() - 0.5) * prop.span / CGFloat(prop.count)
            let scale = 1 + (next() - 0.5) * 2 * prop.scaleJitter
            sprite.size = CGSize(width: size.width * scale, height: size.height * scale)
            sprite.position = CGPoint(x: slot * prop.span + jitterX - prop.span / 2,
                                      y: prop.y + (next() - 0.5) * 2 * prop.yJitter)
            if next() < prop.flipChance { sprite.xScale = -1 }
            // Nearer instances draw over farther ones within the plane, which is
            // what stops a scatter looking like a decal sheet.
            sprite.zPosition = sprite.size.height / 100
            out.append(sprite)
        }
        return out
    }

    /// Per-frame cost: a multiply-add per layer copy, plus one modulo for tiled
    /// layers. Still nothing that scales with level size.
    ///
    /// `camY` matters as soon as a level is taller than the screen: without
    /// vertical parallax the backdrop slides with the camera as a flat sheet,
    /// which reads as the world being painted on the inside of a box.
    func update(camX: CGFloat, camY: CGFloat = 0, dt: TimeInterval = 0) {
        elapsed += dt
        deformer?.update(dt: dt, cameraX: camX)
        for plane in planes {
            let drift = plane.drift * CGFloat(elapsed)
            let sway = plane.sway == 0 ? 0
                : sin(CGFloat(elapsed) * plane.swayRate + plane.depth * 6) * plane.sway
            let y = plane.baseY - camY * plane.verticalRate + sway * 0.35
            for (i, node) in plane.nodes.enumerated() {
                var x = plane.baseX - camX * plane.rate + drift + sway
                if plane.tiled {
                    let offset = CGFloat(i - plane.nodes.count / 2) * plane.span
                    // Wrap into [-span, span) around the camera so the same three
                    // sprites cover an arbitrarily long level.
                    var local = (x + offset).truncatingRemainder(dividingBy: plane.span)
                    if local > plane.span / 2 { local -= plane.span }
                    if local < -plane.span / 2 { local += plane.span }
                    x = local + CGFloat(i - plane.nodes.count / 2) * plane.span
                } else {
                    x += CGFloat(i - plane.nodes.count / 2) * plane.span
                }
                node.position = CGPoint(x: x, y: y)
            }
        }
    }

    /// Shove the backdrop — a ground pound, a boss landing. Ignored when no layer
    /// declared wind, since there is no lattice to deform.
    func impact(atSceneX x: CGFloat, strength: CGFloat = 1) {
        deformer?.impact(atSceneX: x, strength: strength)
    }

    /// Gust the wind. A trigger can run a gale across a level.
    func setWind(_ strength: CGFloat) {
        deformer?.wind = max(0, min(3, strength))
    }

    /// Retint every layer toward a colour — the time-of-day dial reaching the
    /// backdrop, which is otherwise baked at load and stuck at noon.
    ///
    /// Nearer layers take less of the tint: the whole point of aerial perspective
    /// is that distance is what colour-shifts.
    func retint(_ colour: SKColor, strength: CGFloat) {
        for plane in planes {
            let distance = max(0, 1 - plane.depth / max(focus, 0.001))
            let blend = min(1, max(0, strength * (0.35 + 0.65 * distance)))
            for node in plane.tintables {
                node.color = colour
                node.colorBlendFactor = blend
            }
            // Geometry can't take a colour blend, so its haze wash carries the
            // tint instead — same visual result, and it keeps the dial reaching
            // every plane rather than only the image ones.
            for wash in plane.overlays {
                wash.color = colour
                wash.colorBlendFactor = min(1, blend * 1.4)
            }
        }
    }
}
