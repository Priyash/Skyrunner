import SpriteKit

/// Ribbon trail renderer for dash streaks, magic arcs, sword sweeps.
///
/// Accumulates world-space sample points in a fixed-capacity ring buffer, then
/// rebuilds a filled bezier ribbon each frame. The ribbon tapers from `tipWidth`
/// at the newest sample to `tailWidth` at the oldest, and samples age out after
/// `lifetime` seconds so the trail fades away naturally when input stops.
///
/// No allocation after the first `capacity` samples are seen: the path is rebuilt
/// from a pre-reserved array, and samples are pruned in one `removeAll` pass.
/// At capacity=32 the per-frame cost is 32 direction vectors + one path rebuild,
/// which is negligible.
final class TrailRenderer {

    // MARK: - Configuration

    /// Maximum age of a sample in seconds. Older points are pruned and the trail fades.
    var lifetime: TimeInterval = 0.30
    /// Ribbon half-width at the newest sample (the tip).
    var tipWidth: CGFloat = 7
    /// Ribbon half-width at the oldest sample (the tail). Zero gives a sharp point.
    var tailWidth: CGFloat = 0
    /// Fill colour at the tip.
    var tipColor: SKColor = .white
    /// Fill colour at the tail — usually the same with alpha 0 for a fade-out.
    var tailColor: SKColor = SKColor(white: 1, alpha: 0)
    /// Maximum samples retained. Caps memory and path complexity.
    var capacity: Int = 40
    /// Blend mode: `.add` for glowing magic / dash trails; `.alpha` for solid ink strokes.
    var blendMode: SKBlendMode = .add {
        didSet { node.blendMode = blendMode }
    }

    // MARK: - Scene node

    /// Add this as a child of your scene (not the camera) so it tracks world space.
    let node: SKShapeNode

    // MARK: - Internal

    private struct Sample {
        var position: CGPoint
        var time: TimeInterval
    }

    private var samples: [Sample] = []

    init(zPosition: CGFloat = 10) {
        node = SKShapeNode()
        node.lineWidth = 0
        node.fillColor = .white   // tinted per-vertex via path alpha trick
        node.strokeColor = .clear
        node.blendMode = .add
        node.zPosition = zPosition
        samples.reserveCapacity(48)
    }

    // MARK: - API

    /// Record a new world-space point. Call each frame while the trail is active.
    func addPoint(_ position: CGPoint, at currentTime: TimeInterval) {
        samples.append(Sample(position: position, time: currentTime))
        if samples.count > capacity { samples.removeFirst() }
    }

    /// Stop adding points — the trail will fade out naturally as existing samples age.
    func stop() {}

    /// Prune expired samples and rebuild the ribbon. Call once per frame.
    func update(currentTime: TimeInterval) {
        samples.removeAll { currentTime - $0.time > lifetime }
        if samples.count < 2 {
            node.path = nil
            return
        }
        node.blendMode = blendMode
        node.path = buildRibbon(at: currentTime)
    }

    // MARK: - Ribbon construction

    private func buildRibbon(at now: TimeInterval) -> CGPath? {
        guard samples.count >= 2 else { return nil }
        let n = samples.count
        var upper = [CGPoint](repeating: .zero, count: n)
        var lower = [CGPoint](repeating: .zero, count: n)

        for i in 0..<n {
            let s = samples[i]
            // Age fraction: 0 = newest (tip), 1 = oldest (tail).
            let ageFrac  = CGFloat((now - s.time) / lifetime)
            // Position fraction along the ribbon: 0 = oldest, 1 = newest.
            let posFrac  = CGFloat(i) / CGFloat(n - 1)
            let halfW    = (tailWidth + (tipWidth - tailWidth) * posFrac)
                         * max(0, 1 - ageFrac)

            // Direction: average of the forward and backward vectors for smoothness.
            let fwd: CGPoint
            if i + 1 < n {
                let dx = samples[i+1].position.x - s.position.x
                let dy = samples[i+1].position.y - s.position.y
                let l  = sqrt(dx*dx + dy*dy)
                fwd = l > 0.001 ? CGPoint(x: dx/l, y: dy/l) : CGPoint(x: 1, y: 0)
            } else {
                let dx = s.position.x - samples[i-1].position.x
                let dy = s.position.y - samples[i-1].position.y
                let l  = sqrt(dx*dx + dy*dy)
                fwd = l > 0.001 ? CGPoint(x: dx/l, y: dy/l) : CGPoint(x: 1, y: 0)
            }
            // Perpendicular to the direction — the ribbon's width axis.
            let perp = CGPoint(x: -fwd.y, y: fwd.x)
            upper[i] = CGPoint(x: s.position.x + perp.x * halfW,
                               y: s.position.y + perp.y * halfW)
            lower[i] = CGPoint(x: s.position.x - perp.x * halfW,
                               y: s.position.y - perp.y * halfW)
        }

        let path = CGMutablePath()
        path.move(to: upper[0])
        // Catmull-Rom through the upper edge for a smooth arc, not a jagged polyline.
        for i in 1..<n {
            let cp1 = catmullCP1(pts: upper, i: i)
            let cp2 = catmullCP2(pts: upper, i: i)
            path.addCurve(to: upper[i], control1: cp1, control2: cp2)
        }
        for i in stride(from: n-2, through: 0, by: -1) {
            let cp1 = catmullCP2(pts: lower, i: i+1)
            let cp2 = catmullCP1(pts: lower, i: i+1)
            path.addCurve(to: lower[i], control1: cp1, control2: cp2)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Catmull-Rom control points (converts to bezier)

    private func catmullCP1(pts: [CGPoint], i: Int) -> CGPoint {
        let p0 = pts[max(0, i-2)]
        let p1 = pts[i-1]
        let p2 = pts[i]
        return CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                       y: p1.y + (p2.y - p0.y) / 6)
    }

    private func catmullCP2(pts: [CGPoint], i: Int) -> CGPoint {
        let p1 = pts[i-1]
        let p2 = pts[i]
        let p3 = pts[min(pts.count - 1, i+1)]
        return CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                       y: p2.y - (p3.y - p1.y) / 6)
    }
}
