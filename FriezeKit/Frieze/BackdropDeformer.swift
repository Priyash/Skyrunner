import SpriteKit

/// Runtime deformation for backdrop planes: wind, and impact ripples.
///
/// Why it matters. A parallax backdrop made of rigid sprites reads as painted glass —
/// it has depth but no *life*. Real UbiArt backdrops breathe: foliage sways, a nearby
/// impact shoves the canopy, a gust runs across the frame. That motion is most of what
/// separates "layered images" from "a place".
///
/// The mechanism already exists in this engine: `MeshSkinning` drives rig meshes through
/// `SKWarpGeometryGrid`, which is a lattice of source and destination points SpriteKit
/// warps a texture between. The same primitive applied to a backdrop sprite gives wind
/// for the cost of updating a handful of points per frame.
///
/// Two decisions worth stating:
///
/// * **Anchored edges.** The lattice row that touches the ground is pinned. Without it
///   the whole layer slides, which reads as the camera moving rather than as the
///   foliage moving — the single most common mistake in this effect.
/// * **Amplitude scales with depth.** A distant canopy barely moves; a foreground vine
///   sways hard. Uniform sway across the depth stack destroys the parallax the backdrop
///   exists to create.
final class BackdropDeformer {

    /// One deformed plane.
    private struct Target {
        let sprite: SKSpriteNode
        let source: [SIMD2<Float>]
        /// 0 far … 1 near, for amplitude.
        let depth: CGFloat
        /// Points of horizontal sway at full strength.
        let amplitude: CGFloat
        /// Phase offset so planes don't sway in lockstep, which reads as one sheet.
        let phase: CGFloat
        /// Which lattice rows are pinned: 0 = top edge, 1 = bottom edge.
        let pinnedRow: Int
    }

    /// Lattice resolution. Small on purpose: `SKWarpGeometryGrid` interpolates, and a
    /// 4×4 grid is 25 points to update per plane per frame. A 16×16 grid looks
    /// identical for wind and costs 289.
    private static let columns = 4
    private static let rows = 4

    private var targets: [Target] = []
    private var elapsed: TimeInterval = 0

    /// An impact ripple: origin in the plane's own space, plus its remaining life.
    private struct Ripple {
        let x: CGFloat
        let strength: CGFloat
        var age: TimeInterval
    }
    private var ripples: [Ripple] = []

    /// Wind strength, 0…1. A level can dial this, and a trigger can gust it.
    var wind: CGFloat = 1

    /// Adopt a sprite. `pinBottom` is right for anything rooted at the ground; a
    /// hanging canopy should pin its *top* instead, or it detaches from the ceiling.
    func adopt(_ sprite: SKSpriteNode, depth: CGFloat, amplitude: CGFloat,
               pinBottom: Bool = true) {
        guard amplitude > 0.01 else { return }
        let grid = SKWarpGeometryGrid(columns: BackdropDeformer.columns,
                                      rows: BackdropDeformer.rows)
        sprite.warpGeometry = grid
        // The source lattice is a regular unit grid; capture it once because every
        // frame's destination is computed as an offset from it.
        var source: [SIMD2<Float>] = []
        for row in 0...BackdropDeformer.rows {
            for column in 0...BackdropDeformer.columns {
                source.append(SIMD2(Float(column) / Float(BackdropDeformer.columns),
                                    Float(row) / Float(BackdropDeformer.rows)))
            }
        }
        targets.append(Target(sprite: sprite, source: source, depth: depth,
                              amplitude: amplitude,
                              // Deterministic phase from the depth, so the same scene
                              // sways identically every run.
                              phase: depth * 11.7,
                              pinnedRow: pinBottom ? BackdropDeformer.rows : 0))
    }

    /// A local shove — a ground pound, a boss landing, an explosion.
    ///
    /// `x` is in scene points; each plane converts it into its own space, so the same
    /// impact bends near foliage more than far.
    func impact(atSceneX x: CGFloat, strength: CGFloat = 1) {
        // Cap the queue: an effect that can be spammed must not grow without bound.
        if ripples.count > 6 { ripples.removeFirst() }
        ripples.append(Ripple(x: x, strength: min(2, strength), age: 0))
    }

    /// One frame. Cost is `targets × 25` point writes, plus the ripple decay.
    func update(dt: TimeInterval, cameraX: CGFloat) {
        elapsed += dt
        for index in ripples.indices { ripples[index].age += dt }
        ripples.removeAll { $0.age > 0.9 }
        guard !targets.isEmpty, wind > 0.001 || !ripples.isEmpty else { return }

        let time = CGFloat(elapsed)
        for target in targets {
            guard let grid = target.sprite.warpGeometry as? SKWarpGeometryGrid else {
                continue
            }
            let width = max(target.sprite.size.width, 1)
            // The plane's left edge in scene space, for ripple lookup.
            let originX = target.sprite.position.x - width / 2
            var destination: [SIMD2<Float>] = []
            destination.reserveCapacity(target.source.count)

            for row in 0...BackdropDeformer.rows {
                // Pinned row does not move at all; influence ramps away from it.
                let distanceFromPin = abs(row - target.pinnedRow)
                let influence = CGFloat(distanceFromPin) / CGFloat(BackdropDeformer.rows)
                for column in 0...BackdropDeformer.columns {
                    let unitX = CGFloat(column) / CGFloat(BackdropDeformer.columns)
                    let point = target.source[row * (BackdropDeformer.columns + 1)
                                              + column]

                    // Wind: two sines at different rates so it never looks like a
                    // metronome, scaled by how far this point is from the anchor.
                    var offsetX = sin(time * 1.15 + target.phase + unitX * 2.4)
                        * 0.62
                    offsetX += sin(time * 2.7 + target.phase * 1.7 + unitX * 5.1) * 0.38
                    offsetX *= target.amplitude * wind * influence

                    // Ripples: a decaying bump centred on the impact, falling off with
                    // distance so a hit shoves what is near it and nothing else.
                    var offsetY: CGFloat = 0
                    if !ripples.isEmpty {
                        let sceneX = originX + unitX * width
                        for ripple in ripples {
                            let distance = abs(sceneX - ripple.x)
                            guard distance < 260 else { continue }
                            let falloff = 1 - distance / 260
                            let decay = CGFloat(1 - ripple.age / 0.9)
                            let wave = sin(CGFloat(ripple.age) * 18 - distance * 0.03)
                            let push = wave * falloff * decay * decay
                                * ripple.strength * target.amplitude * 1.4
                            offsetX += push * 0.6 * influence
                            offsetY += push * 0.35 * influence
                        }
                    }
                    // Offsets are in *unit* space, so divide by the sprite's size.
                    destination.append(SIMD2(
                        point.x + Float(offsetX / width),
                        point.y + Float(offsetY / max(target.sprite.size.height, 1))))
                }
            }
            target.sprite.warpGeometry = grid.replacingByDestinationPositions(
                positions: destination)
        }
    }

    var targetCount: Int { targets.count }
    var rippleCount: Int { ripples.count }
}
