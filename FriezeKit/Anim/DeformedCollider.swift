import SpriteKit

/// Deformed-mesh collision — collision geometry that follows the *drawn* shape.
///
/// A cut-out puppet can get away with one capsule: the art barely leaves it. A
/// skinned, deforming rig cannot. A thrown punch reaches half a body-length past
/// the capsule, a wind-up pulls the fist back inside it, and a stretched jump
/// pose is nothing like the box that supposedly contains it. UbiArt solved this
/// by letting the animation drive the collision volumes; this is the same idea
/// in the space SpriteKit gives us.
///
/// The geometry comes from exactly the lattice the renderer draws with
/// (`MeshSkinning.solveWorld` — one code path, so hulls can never drift from
/// pixels), reduced to convex hulls because that is what both SpriteKit's
/// polygon bodies and a fast separating-axis test require.
///
/// Three modes, cheap → faithful:
///   • `.box`     — the shipped static body. Nothing is computed.
///   • `.hull`    — one convex hull around the whole deformed rig.
///   • `.perSlot` — a hull per deforming limb; as a physics body, a compound.
enum ColliderMode: String, CaseIterable {
    case box, hull, perSlot

    static var allNames: [String] { allCases.map(\.rawValue) }

    /// True when the mode has to be re-solved as the pose changes.
    var followsDeformation: Bool { self != .box }
}

/// Convex-geometry helpers. Deliberately free functions over `[CGPoint]`: the
/// same code serves collision, the debug overlay, and gameplay queries, and it
/// is testable without a scene.
enum Geometry2D {

    /// Andrew's monotone chain. Returns the hull **counter-clockwise**, which is
    /// what `SKPhysicsBody(polygonFrom:)` demands — a clockwise path there
    /// produces a body that behaves inside-out.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        guard lower.count > 1, upper.count > 1 else { return points }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : points
    }

    /// Positive for a counter-clockwise polygon; used to rank hulls by size and
    /// to sanity-check winding before a body is built from one.
    static func signedArea(_ poly: [CGPoint]) -> CGFloat {
        guard poly.count >= 3 else { return 0 }
        var total: CGFloat = 0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            total += a.x * b.y - b.x * a.y
        }
        return total / 2
    }

    /// Reverse a polygon that came out clockwise. A mirrored transform — a rig
    /// facing left is `xScale = -1` — flips winding, and
    /// `SKPhysicsBody(polygonFrom:)` builds an inside-out body from a clockwise
    /// path, so every hull is normalised the moment it changes space.
    static func counterClockwise(_ poly: [CGPoint]) -> [CGPoint] {
        signedArea(poly) < 0 ? Array(poly.reversed()) : poly
    }

    /// Drop vertices until the polygon fits `maxVertices`, keeping the corners
    /// that carry the shape (largest turn first). A 5×5 lattice hull is usually
    /// 8–10 points already; this only bites on dense authored meshes, where a
    /// 30-vertex physics body would cost far more than it buys.
    static func simplified(_ poly: [CGPoint], maxVertices: Int) -> [CGPoint] {
        guard poly.count > maxVertices, maxVertices >= 3 else { return poly }
        var pts = poly
        while pts.count > maxVertices {
            var flattest = 0
            var smallest = CGFloat.greatestFiniteMagnitude
            for i in pts.indices {
                let prev = pts[(i - 1 + pts.count) % pts.count]
                let next = pts[(i + 1) % pts.count]
                let area = abs((pts[i].x - prev.x) * (next.y - prev.y)
                               - (pts[i].y - prev.y) * (next.x - prev.x))
                if area < smallest { smallest = area; flattest = i }
            }
            pts.remove(at: flattest)
        }
        return pts
    }

    /// Ray casting, so it holds for either winding.
    static func contains(_ poly: [CGPoint], point p: CGPoint) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let t = (p.y - a.y) / (b.y - a.y)
                if p.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Separating-axis test for two convex polygons: if any edge normal
    /// separates their projections they cannot be touching.
    ///
    /// Written without the obvious `for poly in [a, b]` because that literal
    /// allocates an array of arrays on every call, and this is called several
    /// times per actor per frame.
    static func overlaps(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        return !separated(a, a, b) && !separated(b, a, b)
    }

    /// True if any edge normal of `edges` separates `a` from `b`.
    private static func separated(_ edges: [CGPoint],
                                  _ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        for i in edges.indices {
            let p1 = edges[i], p2 = edges[(i + 1) % edges.count]
            let ex = -(p2.y - p1.y), ey = p2.x - p1.x
            let length = sqrt(ex * ex + ey * ey)
            guard length > 0.0001 else { continue }
            let ax = ex / length, ay = ey / length
            var minA = CGFloat.greatestFiniteMagnitude
            var maxA = -CGFloat.greatestFiniteMagnitude
            for p in a {
                let d = p.x * ax + p.y * ay
                if d < minA { minA = d }
                if d > maxA { maxA = d }
            }
            var minB = CGFloat.greatestFiniteMagnitude
            var maxB = -CGFloat.greatestFiniteMagnitude
            for p in b {
                let d = p.x * ax + p.y * ay
                if d < minB { minB = d }
                if d > maxB { maxB = d }
            }
            if maxA < minB || maxB < minA { return true }
        }
        return false
    }

    /// How two convex polygons overlap, not just whether.
    ///
    /// The separating-axis test already computes everything needed for the
    /// minimum translation vector; throwing it away and returning a bool means
    /// gameplay can only ask "did it hit", never "from which side, and how far
    /// in" — so knockback direction, push-out and hit sparks all end up guessed
    /// from centre points instead of from the contact.
    struct Contact {
        /// Unit vector pointing out of `a`, along the shallowest overlap.
        let normal: CGVector
        /// How deep the overlap is, in points.
        let depth: CGFloat
    }

    static func contact(_ a: [CGPoint], _ b: [CGPoint]) -> Contact? {
        guard a.count >= 3, b.count >= 3 else { return nil }
        var bestDepth = CGFloat.greatestFiniteMagnitude
        var bestAxis = CGVector(dx: 0, dy: 0)

        func test(_ edges: [CGPoint]) -> Bool {
            for i in edges.indices {
                let p1 = edges[i], p2 = edges[(i + 1) % edges.count]
                let ex = -(p2.y - p1.y), ey = p2.x - p1.x
                let length = sqrt(ex * ex + ey * ey)
                guard length > 0.0001 else { continue }
                let ax = ex / length, ay = ey / length
                var minA = CGFloat.greatestFiniteMagnitude
                var maxA = -CGFloat.greatestFiniteMagnitude
                for p in a {
                    let d = p.x * ax + p.y * ay
                    if d < minA { minA = d }
                    if d > maxA { maxA = d }
                }
                var minB = CGFloat.greatestFiniteMagnitude
                var maxB = -CGFloat.greatestFiniteMagnitude
                for p in b {
                    let d = p.x * ax + p.y * ay
                    if d < minB { minB = d }
                    if d > maxB { maxB = d }
                }
                if maxA < minB || maxB < minA { return false }
                // Overlap on this axis; keep the shallowest one seen so far.
                let overlap = min(maxA - minB, maxB - minA)
                if overlap < bestDepth {
                    bestDepth = overlap
                    // Point the axis from b toward a so callers can push a out of b.
                    let centreA = centroid(a), centreB = centroid(b)
                    let sign: CGFloat =
                        (centreB.x - centreA.x) * ax + (centreB.y - centreA.y) * ay > 0 ? -1 : 1
                    bestAxis = CGVector(dx: ax * sign, dy: ay * sign)
                }
            }
            return true
        }

        guard test(a), test(b) else { return nil }
        return Contact(normal: bestAxis, depth: bestDepth)
    }

    static func centroid(_ poly: [CGPoint]) -> CGPoint {
        guard !poly.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in poly { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(poly.count), y: y / CGFloat(poly.count))
    }

    /// Split a possibly-concave polygon into convex pieces.
    ///
    /// A convex hull of a deforming limb throws away exactly the shape that makes
    /// it interesting: the notch between two fingers, the gap under a bent knee.
    /// This walks the outline, cuts at the first reflex vertex it can resolve, and
    /// recurses — the classic ear-cut split. Bounded depth, because a pathological
    /// outline should degrade to "one hull" rather than spin.
    static func convexPieces(_ poly: [CGPoint], depth: Int = 6) -> [[CGPoint]] {
        guard poly.count > 3, depth > 0 else { return [poly] }
        let ccw = counterClockwise(poly)
        let n = ccw.count

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        // First reflex vertex: where the outline turns the wrong way.
        for i in 0..<n {
            let prev = ccw[(i - 1 + n) % n], here = ccw[i], next = ccw[(i + 1) % n]
            guard cross(prev, here, next) < -0.01 else { continue }
            // Cut to the furthest vertex that keeps both halves simple: the one
            // whose diagonal stays inside the polygon.
            for step in 2..<(n - 1) {
                let j = (i + step) % n
                let a = sliceIndices(ccw, from: i, to: j)
                let b = sliceIndices(ccw, from: j, to: i)
                guard a.count >= 3, b.count >= 3 else { continue }
                if signedArea(a) > 0.5, signedArea(b) > 0.5 {
                    return convexPieces(a, depth: depth - 1)
                        + convexPieces(b, depth: depth - 1)
                }
            }
            break
        }
        return [ccw]
    }

    private static func sliceIndices(_ poly: [CGPoint], from: Int, to: Int) -> [CGPoint] {
        var out: [CGPoint] = []
        var i = from
        let n = poly.count
        var guardCount = 0
        while guardCount <= n {
            out.append(poly[i])
            if i == to { break }
            i = (i + 1) % n
            guardCount += 1
        }
        return out
    }

    static func overlaps(_ poly: [CGPoint], circleAt centre: CGPoint,
                         radius: CGFloat) -> Bool {
        guard poly.count >= 3 else { return false }
        if contains(poly, point: centre) { return true }
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if distance(from: centre, toSegment: a, b) <= radius { return true }
        }
        return false
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// A rect as a counter-clockwise polygon — the bridge between the engine's
    /// box-shaped actors and hull tests.
    static func polygon(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func path(_ poly: [CGPoint]) -> CGPath? {
        guard poly.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.move(to: poly[0])
        for p in poly.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// A polyline, open or closed. The open form is for strokes — a frise's lit rim
    /// follows the top curve only, and closing it would draw a line back along the
    /// underside.
    static func path(_ points: [CGPoint], closed: Bool) -> CGPath? {
        guard points.count >= 2 else { return nil }
        let path = CGMutablePath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.closeSubpath() }
        return path
    }

    /// The four corners of a sprite in another node's space, animation included.
    /// This is what lets a *procedural* rig (no skeleton, no mesh) expose
    /// animation-following hit volumes too: every limb is a sprite.
    static func quad(of sprite: SKSpriteNode, in target: SKNode) -> [CGPoint] {
        let size = sprite.size
        let anchor = sprite.anchorPoint
        let local = [
            CGPoint(x: -anchor.x * size.width, y: -anchor.y * size.height),
            CGPoint(x: (1 - anchor.x) * size.width, y: -anchor.y * size.height),
            CGPoint(x: (1 - anchor.x) * size.width, y: (1 - anchor.y) * size.height),
            CGPoint(x: -anchor.x * size.width, y: (1 - anchor.y) * size.height),
        ]
        return counterClockwise(local.map { sprite.convert($0, to: target) })
    }

    /// Every sprite quad under a node, in `target` space — a whole rig's worth
    /// of hit regions, from a node tree that knows nothing about collision.
    static func quads(under node: SKNode, in target: SKNode,
                      minimumSide: CGFloat = 4, limit: Int = 12) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        func walk(_ n: SKNode) {
            guard out.count < limit else { return }
            if let sprite = n as? SKSpriteNode, sprite.scene != nil,
               sprite.size.width >= minimumSide, sprite.size.height >= minimumSide,
               !sprite.isHidden, sprite.alpha > 0.05 {
                out.append(quad(of: sprite, in: target))
            }
            for child in n.children { walk(child) }
        }
        walk(node)
        return out
    }
}

/// Owns one rig's deformed collision state: the solved hulls, an optional
/// physics body built from them, and the debug overlay.
///
/// Rebuild costs are split deliberately. Hulls are re-solved every frame — a few
/// hundred multiplies, and gameplay queries must not lag the pose. Physics
/// *bodies* are re-made at `bodyRefreshInterval` frames, because
/// `SKPhysicsBody(polygonFrom:)` re-triangulates on every call and swapping a
/// body resets contact state; every few frames is invisible and affordable.
final class DeformedCollider {

    private weak var rig: SkeletonNode?

    private(set) var mode: ColliderMode = .box
    /// Slot names to track; empty means every slot that can produce geometry.
    private(set) var slotFilter: [String] = []
    /// Hulls in the rig's own coordinate space, counter-clockwise.
    private(set) var hulls: [[CGPoint]] = []

    /// Frames between physics-body rebuilds (1 = every frame).
    var bodyRefreshInterval = 3
    /// Vertices per hull handed to SpriteKit.
    var maxHullVertices = 12
    /// Sub-bodies in a `.perSlot` compound; the largest hulls win.
    var maxSubBodies = 8

    private var sinceBody = 0
    private var debugNode: SKShapeNode?
    private var debugEnabled = false

    init(rig: SkeletonNode) { self.rig = rig }

    // MARK: Configuration

    func setMode(_ mode: ColliderMode, slots: [String] = []) {
        self.mode = mode
        slotFilter = slots
        hulls = []
        sinceBody = 0
        refresh()
    }

    func setDebugDraw(_ on: Bool) {
        debugEnabled = on
        if !on {
            debugNode?.removeFromParent()
            debugNode = nil
        }
        updateDebug()
    }

    // MARK: Solve

    /// Re-solve the hulls for the current pose. Called once per frame by
    /// `SkeletonNode.update(_:)`; a no-op in `.box` mode, so the feature costs
    /// literally nothing until it is switched on.
    func refresh() {
        guard let rig, mode.followsDeformation else {
            if !hulls.isEmpty { hulls = [] }
            updateDebug()
            return
        }

        var perSlot: [[CGPoint]] = []
        var pooled: [CGPoint] = []
        for index in rig.collidableSlotIndices(matching: slotFilter) {
            let points = rig.collisionPoints(slotIndex: index)
            guard points.count >= 3 else { continue }
            if mode == .perSlot {
                // Decompose rather than hull: the notch between two shapes is
                // usually the reason a limb was authored as a mesh at all.
                for piece in Geometry2D.convexPieces(points) {
                    let hull = Geometry2D.simplified(Geometry2D.convexHull(piece),
                                                     maxVertices: maxHullVertices)
                    if hull.count >= 3 { perSlot.append(hull) }
                }
            } else {
                pooled.append(contentsOf: points)
            }
        }

        if mode == .hull {
            let hull = Geometry2D.simplified(Geometry2D.convexHull(pooled),
                                             maxVertices: maxHullVertices)
            perSlot = hull.count >= 3 ? [hull] : []
        } else if perSlot.count > maxSubBodies {
            // Keep the limbs that matter: the biggest hulls.
            perSlot = perSlot
                .sorted { abs(Geometry2D.signedArea($0)) > abs(Geometry2D.signedArea($1)) }
                .prefix(maxSubBodies)
                .map { $0 }
        }

        hulls = perSlot
        updateDebug()
    }

    // MARK: Queries (the half of collision that never needs a physics body)

    /// Hulls converted into another node's space — scene space, usually, since
    /// that is where gameplay compares things. Winding is re-normalised, because
    /// the rig's own flip is a mirror transform.
    func hulls(in target: SKNode) -> [[CGPoint]] {
        guard let rig, rig.scene != nil, !hulls.isEmpty else { return [] }
        guard target !== rig else { return hulls }
        return hulls.map {
            Geometry2D.counterClockwise($0.map { rig.convert($0, to: target) })
        }
    }

    /// Contact detail against a polygon: which way, and how deep.
    ///
    /// This is what lets knockback point away from the blow and hit sparks land on
    /// the surface rather than at a centre point.
    func contact(with polygon: [CGPoint], in target: SKNode) -> Geometry2D.Contact? {
        var best: Geometry2D.Contact?
        for hull in hulls(in: target) {
            guard let c = Geometry2D.contact(hull, polygon) else { continue }
            if best == nil || c.depth > best!.depth { best = c }
        }
        return best
    }

    /// Bounding box of every hull, in `target` space — the cheap rejection test
    /// gameplay should do before asking for anything exact.
    ///
    /// A scene with twenty hazards would otherwise run a full SAT against every
    /// limb of every actor each frame. One box comparison first turns that into
    /// arithmetic on four floats.
    func bounds(in target: SKNode) -> CGRect? {
        let all = hulls(in: target)
        guard !all.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        for hull in all {
            for p in hull {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Does a moving circle touch these hulls over the course of one step?
    ///
    /// Discrete tests miss fast movers — a ground pound covers 25 points per
    /// frame, and a thin hazard between two samples is simply never hit. Sampling
    /// along the sweep at the circle's own radius closes that gap without a full
    /// continuous solver.
    func sweep(from start: CGPoint, to end: CGPoint, radius: CGFloat,
               in target: SKNode) -> Bool {
        let all = hulls(in: target)
        guard !all.isEmpty else { return false }
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int(distance / max(radius, 1)))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t)
            for hull in all where Geometry2D.overlaps(hull, circleAt: p, radius: radius) {
                return true
            }
        }
        return false
    }

    func contains(_ point: CGPoint, in target: SKNode) -> Bool {
        hulls(in: target).contains { Geometry2D.contains($0, point: point) }
    }

    func overlaps(_ polygon: [CGPoint], in target: SKNode) -> Bool {
        hulls(in: target).contains { Geometry2D.overlaps($0, polygon) }
    }

    func overlaps(circleAt centre: CGPoint, radius: CGFloat, in target: SKNode) -> Bool {
        hulls(in: target).contains {
            Geometry2D.overlaps($0, circleAt: centre, radius: radius)
        }
    }

    /// Which tracked slot a point lands in — for "what did I just hit?".
    func slot(at point: CGPoint, in target: SKNode) -> String? {
        guard let rig else { return nil }
        let indices = rig.collidableSlotIndices(matching: slotFilter)
        for (i, hull) in hulls(in: target).enumerated() where
            Geometry2D.contains(hull, point: point) {
            guard mode == .perSlot, indices.indices.contains(i),
                  rig.skeleton.slots.indices.contains(indices[i]) else { return nil }
            return rig.skeleton.slots[indices[i]].data.name
        }
        return nil
    }

    // MARK: Physics bodies

    /// A body for the current hulls, in `space`'s coordinate system (defaults to
    /// the rig itself). Returns nil in `.box` mode or before the first solve —
    /// callers keep whatever body they already had.
    func makeBody(in space: SKNode? = nil) -> SKPhysicsBody? {
        guard let rig, mode.followsDeformation, !hulls.isEmpty else { return nil }
        let target = space ?? rig
        let shapes = hulls(in: target).compactMap { hull -> SKPhysicsBody? in
            // A degenerate or clockwise hull would make an inside-out body.
            guard hull.count >= 3, Geometry2D.signedArea(hull) > 0.5,
                  let path = Geometry2D.path(hull) else { return nil }
            return SKPhysicsBody(polygonFrom: path)
        }
        guard !shapes.isEmpty else { return nil }
        return shapes.count == 1 ? shapes[0] : SKPhysicsBody(bodies: shapes)
    }

    /// Swap `node`'s body for one built from the current hulls, at most every
    /// `bodyRefreshInterval` frames.
    ///
    /// The new body inherits the old one's *role* — category and collision
    /// masks, dynamic flag, velocity, damping — because a collider must not
    /// quietly redefine what an actor is or stop it mid-air. Best suited to
    /// static and kinematic actors: a rebuilt body loses SpriteKit's contact
    /// bookkeeping, so anything that depends on begin/end pairs should query the
    /// hulls directly instead.
    func attachBody(to node: SKNode) {
        guard mode.followsDeformation, !hulls.isEmpty else { return }
        sinceBody += 1
        guard sinceBody >= max(1, bodyRefreshInterval) else { return }
        sinceBody = 0
        guard let body = makeBody(in: node) else { return }
        if let old = node.physicsBody {
            body.isDynamic = old.isDynamic
            body.affectedByGravity = old.affectedByGravity
            body.allowsRotation = old.allowsRotation
            body.categoryBitMask = old.categoryBitMask
            body.collisionBitMask = old.collisionBitMask
            body.contactTestBitMask = old.contactTestBitMask
            body.friction = old.friction
            body.restitution = old.restitution
            body.linearDamping = old.linearDamping
            body.angularDamping = old.angularDamping
            body.velocity = old.velocity
            body.angularVelocity = old.angularVelocity
        }
        node.physicsBody = body
    }

    // MARK: Debug overlay

    /// One shape node holding every hull — the authoring view of this feature,
    /// and the thing that makes `showColliders` tell the truth about a rig whose
    /// physics body is still a box.
    private func updateDebug() {
        guard debugEnabled, let rig else { return }
        let node: SKShapeNode
        if let existing = debugNode {
            node = existing
        } else {
            node = SKShapeNode()
            node.strokeColor = SKColor(red: 0.2, green: 1.0, blue: 0.6, alpha: 0.9)
            node.fillColor = SKColor(red: 0.2, green: 1.0, blue: 0.6, alpha: 0.12)
            node.lineWidth = 1.5
            node.zPosition = 900
            node.name = "debug.hulls"
            rig.addChild(node)
            debugNode = node
        }
        guard !hulls.isEmpty else { node.path = nil; return }
        let combined = CGMutablePath()
        for hull in hulls {
            guard let path = Geometry2D.path(hull) else { continue }
            combined.addPath(path)
        }
        node.path = combined
    }
}
