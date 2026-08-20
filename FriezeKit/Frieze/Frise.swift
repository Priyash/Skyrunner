import SpriteKit

/// A **frise**: spline-extruded, textured, collidable geometry.
///
/// This is the tool UbiArt was built around and the one thing the tile grid can't
/// express. You place a handful of control points, a smooth curve is fitted
/// through them, and the curve is extruded into a solid band that carries a
/// painted body texture, a lit cap along its top edge, and exact collision.
///
/// Why it matters more than "curved ground looks nicer": a tile grid quantises
/// terrain to 40pt steps, so every slope is a staircase and every hill is a
/// ziggurat. A frise is continuous, which is what makes a Rayman silhouette
/// possible at all — and because the collision comes from the *same* curve as the
/// art, what you see is exactly what you stand on.
///
/// ```json
/// { "kind": "ground", "texture": "cliff", "thickness": 90, "closed": false,
///   "points": [[0, 120], [200, 160], [420, 96], [640, 140]] }
/// ```
///
/// Design decisions worth stating:
///
/// * **Catmull-Rom, not Bézier handles.** The curve passes *through* the control
///   points. An author places points where they want the ground to be; handles
///   would mean placing points where the ground isn't.
/// * **Edge-chain physics.** `SKPhysicsBody(polygonFrom:)` requires convexity, and
///   terrain is never convex. `edgeChainFrom:` takes an arbitrary path, is cheap,
///   and gives contact normals that the existing slope code already reads — so
///   running up a frise projects along the surface with no new gameplay code.
/// * **Extruded along the normal**, not straight down, so an overhang is possible.
///   The cost is that a thickness larger than the curve's radius of curvature
///   self-intersects; `problems` reports that rather than drawing a knot.
struct FriseSpec: Codable, Equatable {

    enum Kind: String, Codable {
        /// Solid terrain. Collides, casts shadow, sits at the gameplay plane.
        case ground
        /// Collides only from above — a ledge you can jump up through.
        case platform
        /// No collision at all: painted spline geometry for the backdrop, which is
        /// what a UbiArt backdrop actually is.
        case decor
    }

    /// Addressable name, for a trigger's `move` action.
    ///
    /// Tile runs are merged and anonymous, so a gate that has to rise cannot be a
    /// tile — it has to be geometry with an identity. A named frise is that, and it
    /// reuses the collision and painting the terrain system already has.
    var name: String?
    var kind: Kind = .ground
    /// Body fill texture, tiled. Absent uses `color`.
    var texture: String?
    /// Cap strip along the top edge — grass, moss, snow.
    var cap: String?
    /// RGB 0…255, used when there is no texture and to tint one.
    var color: [Int]?
    /// Control points in scene points, left to right. The curve runs through them.
    var points: [[CGFloat]]
    /// How far the band extends from the curve, in points.
    var thickness: CGFloat = 80
    /// Cap strip height in points.
    var capHeight: CGFloat = 14
    /// 0 far … 1 near. Only meaningful for `.decor`, which the backdrop places by
    /// depth exactly like a parallax layer.
    var depth: CGFloat?
    /// Close the curve into a loop — an island, a boulder, a hole's rim.
    var closed: Bool?
    /// Samples per segment. More is smoother and costs vertices; 12 is invisible
    /// from smooth at gameplay scale.
    var resolution: Int?

    var controlPoints: [CGPoint] {
        points.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    /// Problems that make the frise unusable or wrong-looking.
    var problems: [String] {
        var out: [String] = []
        let control = controlPoints
        if control.count < 2 {
            out.append("needs at least 2 control points, has \(control.count)")
        }
        if thickness <= 0 { out.append("thickness must be positive") }
        if capHeight < 0 { out.append("capHeight cannot be negative") }
        if capHeight > thickness {
            out.append("capHeight \(capHeight) exceeds thickness \(thickness), so "
                       + "the cap would swallow the body")
        }
        for (index, point) in points.enumerated() where point.count < 2 {
            out.append("point \(index) needs [x, y]")
        }
        // Self-intersection check: extruding further than the tightest turn folds
        // the band over itself, which draws as a knot and collides as nonsense.
        let curve = Frise.sample(control, closed: closed ?? false,
                                 resolution: resolution ?? 12)
        if let radius = Frise.tightestRadius(curve), radius < thickness {
            out.append("thickness \(Int(thickness)) is larger than the tightest "
                       + "curve radius (\(Int(radius))) — the band self-intersects; "
                       + "reduce thickness or spread the control points")
        }
        return out
    }
}

/// Curve maths, free functions so the validator and the tools can use them
/// without a scene — the same reason `Geometry2D` is shaped this way.
enum Frise {

    /// Sample a Catmull-Rom spline through `control` into a dense polyline.
    ///
    /// Uniform (not chordal) parameterisation: with hand-placed points a few tens
    /// of points apart the difference is invisible, and uniform is one line.
    static func sample(_ control: [CGPoint], closed: Bool,
                       resolution: Int = 12) -> [CGPoint] {
        guard control.count >= 2 else { return control }
        let steps = max(2, min(64, resolution))
        var out: [CGPoint] = []
        let count = control.count
        let last = closed ? count - 1 : count - 2
        for index in 0...max(0, last) {
            // Endpoints are duplicated on an open curve so the first and last
            // segments keep their tangents instead of flattening.
            let p0 = control[closed ? (index - 1 + count) % count : max(0, index - 1)]
            let p1 = control[closed ? index % count : index]
            let p2 = control[closed ? (index + 1) % count : min(count - 1, index + 1)]
            let p3 = control[closed ? (index + 2) % count : min(count - 1, index + 2)]
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                out.append(catmullRom(p0, p1, p2, p3, t))
            }
        }
        if !closed, let end = control.last { out.append(end) }
        return out
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint,
                                   _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2
                   + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x),
                       y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    /// Outward unit normals along a polyline. For a left-to-right ground curve
    /// these point up, which is why the band extrudes *down* by negating them.
    static func normals(_ curve: [CGPoint], closed: Bool) -> [CGVector] {
        guard curve.count >= 2 else { return [] }
        var out: [CGVector] = []
        for index in curve.indices {
            let previous = curve[closed ? (index - 1 + curve.count) % curve.count
                                        : max(0, index - 1)]
            let next = curve[closed ? (index + 1) % curve.count
                                    : min(curve.count - 1, index + 1)]
            var dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length; dy /= length
            out.append(CGVector(dx: -dy, dy: dx))     // rotate +90°
        }
        return out
    }

    /// Radius of the tightest turn, or nil for a straight line. Used to refuse a
    /// thickness that would fold the band through itself.
    static func tightestRadius(_ curve: [CGPoint]) -> CGFloat? {
        guard curve.count >= 3 else { return nil }
        var tightest = CGFloat.greatestFiniteMagnitude
        for index in 1..<(curve.count - 1) {
            let a = curve[index - 1], b = curve[index], c = curve[index + 1]
            let ab = hypot(b.x - a.x, b.y - a.y)
            let bc = hypot(c.x - b.x, c.y - b.y)
            let ca = hypot(a.x - c.x, a.y - c.y)
            // Circumradius = abc / 4·area; a zero area is a straight run.
            let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            guard area > 0.01 else { continue }
            tightest = min(tightest, ab * bc * ca / (4 * area))
        }
        return tightest == .greatestFiniteMagnitude ? nil : tightest
    }

    /// The closed outline of the extruded band: the curve, then the offset edge
    /// back. This is both the fill path and the collision path — one shape, so the
    /// art and the physics cannot disagree.
    static func outline(_ spec: FriseSpec) -> [CGPoint] {
        let control = spec.controlPoints
        let closed = spec.closed ?? false
        let curve = sample(control, closed: closed,
                           resolution: spec.resolution ?? 12)
        guard curve.count >= 2 else { return [] }
        let ns = normals(curve, closed: closed)
        let inner = zip(curve, ns).map {
            CGPoint(x: $0.0.x - $0.1.dx * spec.thickness,
                    y: $0.0.y - $0.1.dy * spec.thickness)
        }
        return closed ? curve : curve + inner.reversed()
    }

    /// Grid cells the band covers, for the reachability validator.
    ///
    /// The tile grid stays the authority for *design rules* — "can the player get
    /// there" is answered on the grid — so a frise has to declare its footprint or
    /// a level built from splines would read as one with no ground at all. Point
    /// sampling of the outline polygon at cell centres: cheap, and it never
    /// over-reports, which is the safe direction for a reachability check.
    static func footprint(_ spec: FriseSpec, tile: CGFloat, rows: Int,
                          columns: Int, originY: CGFloat) -> Set<[Int]> {
        guard spec.kind != .decor else { return [] }
        let polygon = outline(spec)
        guard polygon.count >= 3 else { return [] }
        var cells: Set<[Int]> = []
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -minX
        var minY = minX, maxY = -minX
        for p in polygon {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let firstCol = max(0, Int(minX / tile)), lastCol = min(columns - 1, Int(maxX / tile))
        guard firstCol <= lastCol else { return [] }
        for column in firstCol...lastCol {
            for row in 0..<rows {
                // Row 0 is the top of the level, matching the glyph grid.
                let centre = CGPoint(x: (CGFloat(column) + 0.5) * tile,
                                     y: originY - (CGFloat(row) + 0.5) * tile)
                guard centre.y >= minY, centre.y <= maxY else { continue }
                if Geometry2D.contains(polygon, point: centre) {
                    cells.insert([column, row])
                }
            }
        }
        return cells
    }
}
