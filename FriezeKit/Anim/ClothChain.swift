import QuartzCore
import SpriteKit

/// Verlet integration chain simulation for capes, hair, tassels, and cloth.
///
/// Why Verlet and not a spring: explicit Euler (force → velocity → position)
/// blows up when stiffness is high or dt is large. Verlet is inherently stable
/// because velocity is implicit — it comes from the difference between the
/// current and previous positions, so the damping term multiplies the whole
/// update and keeps the chain from exploding.
///
/// The chain is N points linked by fixed-length constraints. Point 0 is pinned to
/// a bone each frame by the caller; the rest follow under gravity and wind. After
/// each frame the positions can be mapped onto skeleton bones so the rig renderer
/// sees them as ordinary animated bones.

// MARK: - Point

struct ChainPoint {
    var position: CGPoint
    /// Verlet stores previous position, not velocity.
    var previous: CGPoint
    var pinned: Bool = false
    /// Relative mass — heavier points sag more under gravity.
    var mass: CGFloat = 1
}

// MARK: - Chain

final class ClothChain {

    var points: [ChainPoint]
    private let restLengths: [CGFloat]

    /// Constraint relaxation iterations per frame — more is stiffer but costlier.
    /// 4–6 is the sweet spot for cloth; 2–3 for a loose tail.
    var iterations: Int = 5
    /// Gravity in points/s². Match the scene: SpriteKit default is ≈ −2700.
    var gravity: CGFloat = -2700
    /// 0 = frictionless, 0.02–0.05 = natural cloth damping.
    var damping: CGFloat = 0.035
    /// How strongly the chain responds to wind. Scale with BackdropDeformer.wind.
    var windResponse: CGFloat = 0.6
    /// 0…1. Drive from `BackdropDeformer.wind` or a gust trigger.
    var wind: CGFloat = 0

    /// Build a chain from authored rest positions.
    /// - Parameters:
    ///   - points: World positions defining the rest shape.
    ///   - restLength: Override per-segment rest length; defaults to point spacing.
    init(points: [CGPoint], restLength: CGFloat? = nil) {
        self.points = points.enumerated().map { i, p in
            ChainPoint(position: p, previous: p, pinned: i == 0)
        }
        var lengths: [CGFloat] = []
        for i in 0..<points.count - 1 {
            let dx = points[i+1].x - points[i].x
            let dy = points[i+1].y - points[i].y
            lengths.append(restLength ?? sqrt(dx*dx + dy*dy))
        }
        restLengths = lengths
    }

    // MARK: Root

    /// Pin point 0 to `root` — call every frame before `update()`.
    func setRoot(_ root: CGPoint) {
        guard !points.isEmpty else { return }
        points[0].position = root
        points[0].previous = root
    }

    // MARK: Simulation

    /// Advance the chain by `dt` seconds.
    func update(dt: CGFloat) {
        guard points.count > 1, dt > 0 else { return }
        let dt2 = dt * dt
        // Wind oscillates via two incommensurate frequencies so it never feels mechanical.
        let t = CGFloat(CACurrentMediaTime())
        let windForce = (sin(t * 2.1) * 0.65 + sin(t * 3.7) * 0.35)
                      * wind * windResponse * 180

        // Verlet integrate non-pinned points.
        for i in points.indices where !points[i].pinned {
            let px = points[i].position.x
            let py = points[i].position.y
            let velX = (px - points[i].previous.x) * (1 - damping)
            let velY = (py - points[i].previous.y) * (1 - damping)
            points[i].previous = points[i].position
            points[i].position.x = px + velX + windForce * dt2
            points[i].position.y = py + velY + gravity * points[i].mass * dt2
        }

        // Jakobsen constraint relaxation — satisfy all segment lengths iteratively.
        for _ in 0..<iterations {
            for seg in 0..<restLengths.count {
                let dx = points[seg+1].position.x - points[seg].position.x
                let dy = points[seg+1].position.y - points[seg].position.y
                let dist = sqrt(dx*dx + dy*dy)
                guard dist > 0.0001 else { continue }
                let correction = (dist - restLengths[seg]) / dist * 0.5
                let cx = dx * correction
                let cy = dy * correction
                if !points[seg].pinned {
                    points[seg].position.x += cx
                    points[seg].position.y += cy
                }
                if !points[seg+1].pinned {
                    points[seg+1].position.x -= cx
                    points[seg+1].position.y -= cy
                }
            }
        }
    }

    // MARK: Output

    /// Write point positions into the matching range of `bones`.
    /// Typically `bones` is the skeleton's `bones` array and `startIndex` is
    /// the first cloth bone.
    func applyToBones(_ bones: inout [Bone], startIndex: Int = 0) {
        let count = min(points.count, bones.count - startIndex)
        for i in 0..<count {
            bones[startIndex + i].worldX = points[i].position.x
            bones[startIndex + i].worldY = points[i].position.y
        }
    }

    /// Return all current point positions as world CGPoints.
    var positions: [CGPoint] { points.map(\.position) }
}
