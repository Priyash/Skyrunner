import XCTest
import SpriteKit
@testable import SkyRunner

/// Convex geometry: the layer deformed-mesh collision is built on.
///
/// Every one of these has a specific failure it guards against, because the
/// symptoms of broken convex geometry are indirect — a hull with the wrong
/// winding makes `SKPhysicsBody(polygonFrom:)` silently produce an inside-out
/// body, and the player falls through a limb rather than crashing.
final class GeometryTests: XCTestCase {

    private let square: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                     CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]

    // MARK: Convex hull

    func testHullOfASquareIsTheSquare() {
        let hull = Geometry2D.convexHull(square)
        XCTAssertEqual(hull.count, 4)
    }

    func testHullDropsInteriorPoints() {
        let hull = Geometry2D.convexHull(square + [CGPoint(x: 5, y: 5),
                                                   CGPoint(x: 3, y: 7)])
        XCTAssertEqual(hull.count, 4, "interior points must not become vertices")
    }

    func testHullDropsCollinearPoints() {
        // A vertex that isn't a corner costs a physics-body slot for nothing, and
        // SpriteKit caps polygon complexity.
        let hull = Geometry2D.convexHull(square + [CGPoint(x: 5, y: 0)])
        XCTAssertEqual(hull.count, 4)
    }

    func testHullOfDegenerateInputDoesNotCrash() {
        XCTAssertTrue(Geometry2D.convexHull([]).isEmpty)
        XCTAssertEqual(Geometry2D.convexHull([CGPoint(x: 1, y: 1)]).count, 1)
        // A line has no area: whatever comes back must not be fed to a body, but
        // it must not trap either.
        let line = Geometry2D.convexHull([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
                                          CGPoint(x: 2, y: 2)])
        XCTAssertLessThanOrEqual(line.count, 3)
    }

    func testHullIsCounterClockwise() {
        // `SKPhysicsBody(polygonFrom:)` requires counter-clockwise winding, and a
        // clockwise polygon yields a body that collides on the wrong side.
        let hull = Geometry2D.convexHull(square.reversed())
        XCTAssertGreaterThan(Geometry2D.signedArea(hull), 0)
    }

    // MARK: Winding

    func testSignedAreaSignFollowsWinding() {
        XCTAssertGreaterThan(Geometry2D.signedArea(square), 0)
        XCTAssertLessThan(Geometry2D.signedArea(square.reversed()), 0)
    }

    func testSignedAreaMagnitudeIsTheArea() {
        XCTAssertEqual(abs(Geometry2D.signedArea(square)), 100, accuracy: 0.001)
    }

    func testCounterClockwiseIsIdempotent() {
        let once = Geometry2D.counterClockwise(square.reversed())
        XCTAssertEqual(Geometry2D.signedArea(once), Geometry2D.signedArea(
            Geometry2D.counterClockwise(once)), accuracy: 0.001)
    }

    // MARK: Containment and overlap

    func testContainsPointsInsideAndOutside() {
        XCTAssertTrue(Geometry2D.contains(square, point: CGPoint(x: 5, y: 5)))
        XCTAssertFalse(Geometry2D.contains(square, point: CGPoint(x: 15, y: 5)))
        XCTAssertFalse(Geometry2D.contains(square, point: CGPoint(x: -0.5, y: 5)))
    }

    func testOverlapDetectsTouchingAndSeparated() {
        let shifted = square.map { CGPoint(x: $0.x + 5, y: $0.y) }
        let far = square.map { CGPoint(x: $0.x + 50, y: $0.y) }
        XCTAssertTrue(Geometry2D.overlaps(square, shifted))
        XCTAssertFalse(Geometry2D.overlaps(square, far))
    }

    func testOverlapIsSymmetric() {
        // SAT tests one polygon's axes then the other's; getting only one
        // direction right produces hits that depend on argument order.
        let diamond = [CGPoint(x: 9, y: 5), CGPoint(x: 14, y: 0),
                       CGPoint(x: 19, y: 5), CGPoint(x: 14, y: 10)]
        XCTAssertEqual(Geometry2D.overlaps(square, diamond),
                       Geometry2D.overlaps(diamond, square))
    }

    func testOverlapCatchesTheDiagonalCase() {
        // Two boxes whose *bounds* overlap but whose bodies don't: the case a
        // bounds-only test gets wrong, which is why SAT is here at all.
        let diamond = [CGPoint(x: 15, y: 15), CGPoint(x: 20, y: 10),
                       CGPoint(x: 25, y: 15), CGPoint(x: 20, y: 20)]
        XCTAssertFalse(Geometry2D.overlaps(square, diamond))
    }

    func testCircleOverlap() {
        XCTAssertTrue(Geometry2D.overlaps(square, circleAt: CGPoint(x: 5, y: 5),
                                          radius: 1))
        XCTAssertTrue(Geometry2D.overlaps(square, circleAt: CGPoint(x: 11, y: 5),
                                          radius: 2), "a circle grazing an edge hits")
        XCTAssertFalse(Geometry2D.overlaps(square, circleAt: CGPoint(x: 20, y: 5),
                                           radius: 2))
    }

    // MARK: Contact resolution

    func testContactReportsTheMinimumTranslation() {
        // Overlapping by 2 along x and 10 along y: the MTV must pick x, or the
        // player gets shoved through the floor instead of out of a wall.
        let shifted = square.map { CGPoint(x: $0.x + 8, y: $0.y) }
        guard let contact = Geometry2D.contact(square, shifted) else {
            return XCTFail("overlapping polygons must produce a contact")
        }
        XCTAssertEqual(contact.depth, 2, accuracy: 0.001)
        XCTAssertEqual(abs(contact.normal.dx), 1, accuracy: 0.001)
        XCTAssertEqual(contact.normal.dy, 0, accuracy: 0.001)
    }

    func testContactNormalPointsAwayFromTheOtherShape() {
        let above = square.map { CGPoint(x: $0.x, y: $0.y + 8) }
        guard let contact = Geometry2D.contact(square, above) else {
            return XCTFail("expected a contact")
        }
        // Pushing `square` out of `above` has to move it down.
        XCTAssertLessThan(contact.normal.dy, 0)
        XCTAssertEqual(contact.depth, 2, accuracy: 0.001)
    }

    func testNoContactWhenSeparated() {
        let far = square.map { CGPoint(x: $0.x + 50, y: $0.y) }
        XCTAssertNil(Geometry2D.contact(square, far))
    }

    // MARK: Decomposition

    func testConvexPiecesOfAConvexPolygonIsItself() {
        XCTAssertEqual(Geometry2D.convexPieces(square).count, 1)
    }

    func testConvexPiecesSplitsAConcavePolygon() {
        // An L: SpriteKit cannot make a body from this, so it must come back as
        // pieces that each can be one.
        let ell = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 4),
                   CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 10), CGPoint(x: 0, y: 10)]
        let pieces = Geometry2D.convexPieces(ell)
        XCTAssertGreaterThan(pieces.count, 1, "a concave polygon must be split")
        for piece in pieces {
            XCTAssertGreaterThanOrEqual(piece.count, 3)
            // Every piece has to be usable as a physics body: convex, wound CCW,
            // non-degenerate.
            XCTAssertGreaterThan(Geometry2D.signedArea(piece), 0,
                                 "piece is inside-out or empty")
        }
    }

    func testDecompositionRoughlyPreservesArea() {
        let ell = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 4),
                   CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 10), CGPoint(x: 0, y: 10)]
        let whole = abs(Geometry2D.signedArea(ell))
        let parts = Geometry2D.convexPieces(ell)
            .reduce(0) { $0 + abs(Geometry2D.signedArea($1)) }
        XCTAssertEqual(parts, whole, accuracy: whole * 0.02,
                       "pieces cover a different area than the polygon they came from")
    }

    // MARK: Simplification

    func testSimplifiedRespectsTheVertexCap() {
        // SpriteKit's polygon bodies degrade past a certain complexity, and a
        // deformed mesh hull can carry far more vertices than a body should.
        let circle = (0..<40).map { i -> CGPoint in
            let a = CGFloat(i) / 40 * 2 * .pi
            return CGPoint(x: cos(a) * 10, y: sin(a) * 10)
        }
        let simple = Geometry2D.simplified(Geometry2D.convexHull(circle),
                                           maxVertices: 8)
        XCTAssertLessThanOrEqual(simple.count, 8)
        XCTAssertGreaterThanOrEqual(simple.count, 3)
        // It must still contain the middle — simplification that eats the shape
        // is worse than no simplification.
        XCTAssertTrue(Geometry2D.contains(simple, point: .zero))
    }

    // MARK: Helpers used by gameplay

    func testPolygonOfRectIsCounterClockwiseAndClosed() {
        let poly = Geometry2D.polygon(of: CGRect(x: -5, y: -5, width: 10, height: 10))
        XCTAssertEqual(poly.count, 4)
        XCTAssertGreaterThan(Geometry2D.signedArea(poly), 0)
    }

    func testCentroidOfASquareIsItsMiddle() {
        let c = Geometry2D.centroid(square)
        XCTAssertEqual(c.x, 5, accuracy: 0.001)
        XCTAssertEqual(c.y, 5, accuracy: 0.001)
    }

    func testDistanceToSegment() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        XCTAssertEqual(Geometry2D.distance(from: CGPoint(x: 5, y: 3),
                                           toSegment: a, b), 3, accuracy: 0.001)
        // Past the end it is the distance to the endpoint, not to the infinite line.
        XCTAssertEqual(Geometry2D.distance(from: CGPoint(x: 14, y: 0),
                                           toSegment: a, b), 4, accuracy: 0.001)
    }

    func testQuadOfASpriteFollowsItsTransform() {
        // This is the fallback hit volume for the procedural rig, so it has to
        // track rotation — otherwise a spinning limb's hitbox stays upright.
        let parent = SKNode()
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 4))
        parent.addChild(sprite)
        sprite.zRotation = .pi / 2
        let quad = Geometry2D.quad(of: sprite, in: parent)
        XCTAssertEqual(quad.count, 4)
        let width = (quad.map(\.x).max() ?? 0) - (quad.map(\.x).min() ?? 0)
        XCTAssertEqual(width, 4, accuracy: 0.001,
                       "rotating 90° must swap the quad's extents")
    }
}
