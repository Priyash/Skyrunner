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
        let columns: Int
        let rows: Int
        /// 0 far … 1 near, for amplitude.
        let depth: CGFloat
        /// Points of horizontal sway at full strength.
        let amplitude: CGFloat
        /// Phase offset so planes don't sway in lockstep, which reads as one sheet.
        let phase: CGFloat
        /// Which lattice row is pinned: 0 = top edge, rows = bottom edge.
        let pinnedRow: Int
    }

    private var targets: [Target] = []
    private var elapsed: TimeInterval = 0

    /// An impact ripple: origin in scene space, plus its remaining life.
    private struct Ripple {
        let x: CGFloat
        let strength: CGFloat
        var age: TimeInterval
        let duration: TimeInterval   // variable so heavy impacts linger longer
    }
    private var ripples: [Ripple] = []

    /// Wind strength, 0…1. A level can dial this; a trigger can gust it.
    var wind: CGFloat = 1

    /// Instantaneous gust: adds a decaying wind spike. Useful for boss slam,
    /// explosion, or transition into a windy zone.
    func gust(strength: CGFloat = 1, duration: TimeInterval = 1.2) {
        let spike = min(1, max(0, strength))
        // Animate by temporarily boosting wind and decaying it back. Callers
        // drive this via the TriggerRuntime; the deformer does not own the timer.
        // Instead, inject a short-lived pseudo-ripple at the scene centre that
        // creates a lateral shove across the whole backdrop.
        if ripples.count > 6 { ripples.removeFirst() }
        ripples.append(Ripple(x: 0, strength: spike * 0.8, age: 0, duration: duration))
    }

    /// Adopt a sprite. `pinBottom` is right for anything rooted at the ground; a
    /// hanging canopy should pin its *top* instead, or it detaches from the ceiling.
    /// `resolution` selects the lattice density: 4 = distant/cheap, 6 = default, 8 = hero.
    func adopt(_ sprite: SKSpriteNode, depth: CGFloat, amplitude: CGFloat,
               pinBottom: Bool = true, resolution: Int = 6) {
        guard amplitude > 0.01 else { return }
        let cols = max(3, min(12, resolution))
        let rows = max(3, min(12, resolution))
        let grid = SKWarpGeometryGrid(columns: cols, rows: rows)
        sprite.warpGeometry = grid
        var source: [SIMD2<Float>] = []
        source.reserveCapacity((cols + 1) * (rows + 1))
        for row in 0...rows {
            for column in 0...cols {
                source.append(SIMD2(Float(column) / Float(cols),
                                    Float(row)    / Float(rows)))
            }
        }
        targets.append(Target(sprite: sprite, source: source,
                              columns: cols, rows: rows,
                              depth: depth, amplitude: amplitude,
                              // Deterministic phase from depth — same scene, same sway.
                              phase: depth * 11.7,
                              pinnedRow: pinBottom ? rows : 0))
    }

    /// A local shove — a ground pound, a boss landing, an explosion.
    ///
    /// `x` is in scene points; each plane converts it into its own space, so the same
    /// impact bends near foliage more than far.
    func impact(atSceneX x: CGFloat, strength: CGFloat = 1) {
        if ripples.count > 6 { ripples.removeFirst() }
        let s = min(2, strength)
        // Duration scales with strength so a heavy hit lingers.
        ripples.append(Ripple(x: x, strength: s, age: 0, duration: 0.6 + Double(s) * 0.3))
    }

    /// One frame. Cost is `targets × (cols+1)×(rows+1)` point writes.
    func update(dt: TimeInterval, cameraX: CGFloat) {
        elapsed += dt
        for index in ripples.indices { ripples[index].age += dt }
        ripples.removeAll { $0.age > $0.duration }
        guard !targets.isEmpty, wind > 0.001 || !ripples.isEmpty else { return }

        let time = CGFloat(elapsed)
        for target in targets {
            guard let grid = target.sprite.warpGeometry as? SKWarpGeometryGrid else { continue }
            let cols   = target.columns
            let rows   = target.rows
            let width  = max(target.sprite.size.width,  1)
            let height = max(target.sprite.size.height, 1)
            let originX = target.sprite.position.x - width / 2
            var destination = [SIMD2<Float>]()
            destination.reserveCapacity(target.source.count)

            for row in 0...rows {
                let distanceFromPin = abs(row - target.pinnedRow)
                let influence = CGFloat(distanceFromPin) / CGFloat(rows)
                for column in 0...cols {
                    let unitX = CGFloat(column) / CGFloat(cols)
                    let point = target.source[row * (cols + 1) + column]

                    // Multi-octave wind turbulence.
                    // Octave 1: slow primary sway — the trunk motion.
                    var offsetX  = sin(time * 1.15 + target.phase + unitX * 2.4) * 0.55
                    // Octave 2: medium flutter — the branch motion.
                    offsetX     += sin(time * 2.7  + target.phase * 1.7 + unitX * 5.1) * 0.32
                    // Octave 3: rapid quiver — the leaf surface texture.
                    offsetX     += sin(time * 6.1  + target.phase * 3.1 + unitX * 11.3) * 0.13
                    offsetX     *= target.amplitude * wind * influence

                    var offsetY: CGFloat = 0
                    if !ripples.isEmpty {
                        let sceneX = originX + unitX * width
                        for ripple in ripples {
                            let distance = abs(sceneX - ripple.x)
                            let radius: CGFloat = 320
                            guard distance < radius else { continue }
                            let falloff  = 1 - distance / radius
                            let decay    = CGFloat(1 - ripple.age / ripple.duration)
                            let wave     = sin(CGFloat(ripple.age) * 20 - distance * 0.025)
                            let push     = wave * falloff * (decay * decay)
                                         * ripple.strength * target.amplitude * 1.5
                            offsetX     += push * 0.55 * influence
                            // Vertical ripple: foliage bobs as the pressure wave passes.
                            offsetY     += push * 0.40 * influence
                        }
                    }
                    destination.append(SIMD2(
                        point.x + Float(offsetX / width),
                        point.y + Float(offsetY / height)))
                }
            }
            target.sprite.warpGeometry = grid.replacingByDestinationPositions(
                positions: destination)
        }
    }

    var targetCount: Int { targets.count }
    var rippleCount: Int { ripples.count }
}
