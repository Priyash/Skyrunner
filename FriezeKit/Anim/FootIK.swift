import SpriteKit

/// Ground-adaptive foot placement IK.
///
/// A character walking on a slope with feet at the skeleton's authored (flat-ground)
/// position slides rather than steps. FootIK raycasts downward from each foot's
/// current world position, finds the terrain contact point, and smoothly blends
/// the IK targets toward it. A complementary hip offset keeps leg lengths plausible
/// when the slope is steep.
///
/// Design: the authored pose is the *base*. IK is an additive correction on top,
/// so on flat ground the character looks exactly as the animator drew it. This
/// mirrors UbiArt's foot-contact approach.
///
/// Usage:
/// ```swift
/// // Once, at setup:
/// var footIK = FootIKSolver()
///
/// // Each frame, after skeleton.updateWorldTransform() and before rendering:
/// let leftWorld  = skeleton.bones[leftTipIndex].worldPosition(in: node)
/// let rightWorld = skeleton.bones[rightTipIndex].worldPosition(in: node)
/// let result = footIK.solve(leftFoot: leftWorld, rightFoot: rightWorld,
///                           physics: physicsWorld, dt: dt)
/// // Feed result.left / result.right back as IK constraint target positions.
/// ```

struct FootIKSolver {

    // MARK: Configuration

    /// Distance to cast the ray upward from the nominal foot position before
    /// shooting downward — prevents the ray starting inside the ground on slopes.
    var probeUp: CGFloat = 24
    /// Maximum distance to search downward for terrain.
    var probeDown: CGFloat = 70
    /// Physics category mask to hit. Defaults to all standable geometry.
    var category: UInt32 = PhysicsCategory.standable
    /// How fast the foot snaps toward the detected surface. Lower = smoother step.
    var trackSpeed: CGFloat = 9
    /// Maximum hip raise in points — prevents over-stretching on extreme terrain.
    var maxHipRaise: CGFloat = 22
    /// Blend factor 0..1. At 0 foot IK is off (authored pose); at 1 fully adaptive.
    var blend: CGFloat = 1

    // MARK: State

    private var leftSmooth: CGPoint = .zero
    private var rightSmooth: CGPoint = .zero
    private var initialized = false

    // MARK: Solve

    struct Result {
        var left: CGPoint
        var right: CGPoint
        /// Positive = hip should be raised to keep leg lengths valid.
        var hipRaise: CGFloat
    }

    /// Solve one frame.
    /// - Parameters:
    ///   - leftFoot:  Left foot tip position in scene coordinates.
    ///   - rightFoot: Right foot tip position in scene coordinates.
    ///   - physics:   The scene's physics world.
    ///   - dt:        Delta time in seconds.
    /// - Returns: Blended IK targets plus a hip-raise amount.
    mutating func solve(leftFoot: CGPoint,
                        rightFoot: CGPoint,
                        physics: SKPhysicsWorld,
                        dt: CGFloat) -> Result {
        if !initialized {
            leftSmooth  = leftFoot
            rightSmooth = rightFoot
            initialized = true
        }

        let leftHit  = probe(from: leftFoot,  physics: physics)
        let rightHit = probe(from: rightFoot, physics: physics)

        let rate = min(1, trackSpeed * dt)
        if let h = leftHit {
            leftSmooth.x  += (h.x - leftSmooth.x)  * rate
            leftSmooth.y  += (h.y - leftSmooth.y)  * rate
        }
        if let h = rightHit {
            rightSmooth.x += (h.x - rightSmooth.x) * rate
            rightSmooth.y += (h.y - rightSmooth.y) * rate
        }

        // Hip raise: when both feet land below the authored height, lift the hips
        // to keep both upper-leg lengths within reach.
        let leftDelta  = leftSmooth.y  - leftFoot.y
        let rightDelta = rightSmooth.y - rightFoot.y
        let rawRaise   = max(0, -(leftDelta + rightDelta) * 0.5)
        let hipRaise   = min(maxHipRaise, rawRaise) * blend

        // Blend between authored position and terrain-locked target.
        func lerped(_ authored: CGPoint, _ target: CGPoint) -> CGPoint {
            CGPoint(x: authored.x + (target.x - authored.x) * blend,
                    y: authored.y + (target.y - authored.y) * blend)
        }

        return Result(
            left:     lerped(leftFoot,  leftSmooth),
            right:    lerped(rightFoot, rightSmooth),
            hipRaise: hipRaise
        )
    }

    mutating func reset() { initialized = false }

    // MARK: - Private

    private func probe(from foot: CGPoint, physics: SKPhysicsWorld) -> CGPoint? {
        let start = CGPoint(x: foot.x, y: foot.y + probeUp)
        let end   = CGPoint(x: foot.x, y: foot.y - probeDown)
        var result: CGPoint? = nil
        physics.enumerateBodies(alongRayStart: start, end: end) { body, point, _, stop in
            guard body.categoryBitMask & self.category != 0 else { return }
            result = point
            stop.pointee = true
        }
        return result
    }
}
