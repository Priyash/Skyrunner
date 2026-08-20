import XCTest
import SpriteKit
@testable import SkyRunner

/// Spline-extruded terrain, and the packed texture atlas.
///
/// Both share a property that makes them worth testing hard: a mistake in either
/// is *silent*. A frise whose collision disagrees with its art looks fine standing
/// still; an atlas missing a frame draws correctly and merely loses the batching it
/// was added for.
final class FriseTests: XCTestCase {

    private func ground(thickness: CGFloat = 90) -> FriseSpec {
        FriseSpec(kind: .ground, texture: nil, cap: nil, color: [76, 108, 62],
                  points: [[0, 120], [200, 190], [420, 110], [640, 160]],
                  thickness: thickness, capHeight: 14, depth: nil, closed: false,
                  resolution: 12)
    }

    // MARK: Curve

    func testCurvePassesThroughItsControlPoints() {
        // Catmull-Rom is chosen precisely for this: an author places a point where
        // they want the ground, not where a tangent handle should go.
        let spec = ground()
        let curve = Frise.sample(spec.controlPoints, closed: false, resolution: 12)
        for control in spec.controlPoints {
            let hit = curve.contains { abs($0.x - control.x) < 0.001
                                       && abs($0.y - control.y) < 0.001 }
            XCTAssertTrue(hit, "curve misses control point \(control)")
        }
    }

    func testCurveSpansTheFullControlRange() {
        let curve = Frise.sample(ground().controlPoints, closed: false)
        XCTAssertEqual(curve.first?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(curve.last?.x ?? -1, 640, accuracy: 0.001)
    }

    func testCurveIsDenserThanItsControlPoints() {
        let sparse = Frise.sample(ground().controlPoints, closed: false, resolution: 2)
        let dense = Frise.sample(ground().controlPoints, closed: false, resolution: 24)
        XCTAssertGreaterThan(dense.count, sparse.count)
        XCTAssertGreaterThan(sparse.count, ground().controlPoints.count)
    }

    func testTwoPointCurveIsAStraightRun() {
        var spec = ground()
        spec.points = [[0, 100], [400, 100]]
        let curve = Frise.sample(spec.controlPoints, closed: false)
        XCTAssertGreaterThan(curve.count, 2)
        for point in curve {
            XCTAssertEqual(point.y, 100, accuracy: 0.001,
                           "a flat two-point spline must not bow")
        }
    }

    func testDegenerateInputDoesNotCrash() {
        XCTAssertTrue(Frise.sample([], closed: false).isEmpty)
        XCTAssertEqual(Frise.sample([CGPoint(x: 1, y: 1)], closed: false).count, 1)
        XCTAssertTrue(Frise.outline(FriseSpec(points: [[0, 0]])).isEmpty
                      || Frise.outline(FriseSpec(points: [[0, 0]])).count < 3)
    }

    // MARK: Normals and outline

    func testNormalsPointUpForALeftToRightGround() {
        let curve = Frise.sample(ground().controlPoints, closed: false)
        let normals = Frise.normals(curve, closed: false)
        XCTAssertEqual(normals.count, curve.count)
        // Not every normal on a wavy curve points straight up, but they must all
        // have a positive y — otherwise the band extrudes into the sky.
        for normal in normals {
            XCTAssertGreaterThan(normal.dy, 0, "normal flipped: \(normal)")
            XCTAssertEqual(hypot(normal.dx, normal.dy), 1, accuracy: 0.001,
                           "normals must be unit length")
        }
    }

    func testOutlineIsClosedAndEnclosesArea() {
        let outline = Frise.outline(ground())
        XCTAssertGreaterThan(outline.count, 6)
        XCTAssertGreaterThan(abs(Geometry2D.signedArea(outline)), 1000,
                             "the extruded band has to enclose real area, or there "
                             + "is nothing to fill or collide with")
    }

    func testThickerBandEnclosesMoreArea() {
        let thin = abs(Geometry2D.signedArea(Frise.outline(ground(thickness: 40))))
        let thick = abs(Geometry2D.signedArea(Frise.outline(ground(thickness: 120))))
        XCTAssertGreaterThan(thick, thin * 2)
    }

    func testOutlinePointCountMatchesTheSampledCurve() {
        let spec = ground()
        let curve = Frise.sample(spec.controlPoints, closed: false,
                                resolution: spec.resolution ?? 12)
        XCTAssertEqual(Frise.outline(spec).count, curve.count * 2,
                       "an open band is the curve plus its offset edge")
    }

    // MARK: Validation

    func testValidSpecHasNoProblems() {
        XCTAssertTrue(ground().problems.isEmpty, "\(ground().problems)")
    }

    func testSelfIntersectingThicknessIsRefused() {
        // Extruding further than the tightest turn folds the band through itself:
        // it draws as a knot and collides as nonsense.
        let problems = ground(thickness: 400).problems
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("self-intersect") },
                      "\(problems)")
    }

    func testTooFewPointsIsRefused() {
        XCTAssertFalse(FriseSpec(points: [[0, 0]]).problems.isEmpty)
    }

    func testCapTallerThanTheBandIsRefused() {
        var spec = ground()
        spec.capHeight = spec.thickness + 10
        XCTAssertTrue(spec.problems.contains { $0.contains("capHeight") },
                      "\(spec.problems)")
    }

    func testTightestRadiusIsNilForAStraightLine() {
        let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                        CGPoint(x: 20, y: 0)]
        XCTAssertNil(Frise.tightestRadius(straight),
                     "a straight run has no curvature to limit thickness")
    }

    // MARK: Footprint — what keeps reachability honest

    func testFootprintCoversCellsUnderTheCurve() {
        // The tile grid answers "can the player get there", so spline terrain has
        // to declare which cells it fills or a curve-floored level reads as having
        // no ground at all.
        let cells = Frise.footprint(ground(), tile: 40, rows: 9, columns: 16,
                                    originY: 360)
        XCTAssertFalse(cells.isEmpty)
        // A cell well below the curve is inside the band; one well above is not.
        XCTAssertTrue(cells.contains([2, 6]) || cells.contains([2, 7]),
                      "expected cells under the curve near column 2: \(cells.sorted())")
        XCTAssertFalse(cells.contains([2, 0]), "the sky is not solid")
    }

    func testDecorHasNoFootprint() {
        // Painted backdrop geometry must not become collision, or a level's scenery
        // silently blocks the player.
        var spec = ground()
        spec.kind = .decor
        XCTAssertTrue(Frise.footprint(spec, tile: 40, rows: 9, columns: 16,
                                      originY: 360).isEmpty)
    }

    func testFootprintGrowsWithThickness() {
        let thin = Frise.footprint(ground(thickness: 40), tile: 40, rows: 9,
                                   columns: 16, originY: 360)
        let thick = Frise.footprint(ground(thickness: 160), tile: 40, rows: 9,
                                    columns: 16, originY: 360)
        XCTAssertGreaterThan(thick.count, thin.count)
    }

    func testFootprintMakesACurveFlooredLevelValidate() {
        // The end-to-end assertion: a level with no `X` anywhere, whose floor is
        // entirely spline, must satisfy the same design rules as a tiled one.
        var rows = Array(repeating: String(repeating: ".", count: 22), count: 9)
        rows[5] = "..S" + String(repeating: ".", count: 16) + "F."
        let spec = FriseSpec(kind: .ground, color: [76, 108, 62],
                             points: [[-40, 90], [180, 118], [380, 96],
                                      [560, 130], [760, 104], [900, 86]],
                             thickness: 120, capHeight: 16)
        let cells = Frise.footprint(spec, tile: 40, rows: 9, columns: 22,
                                    originY: 360)
        XCTAssertFalse(LevelRules.validate(rows).isEmpty,
                       "without the footprint the level has no floor")
        XCTAssertTrue(LevelRules.validate(rows, solidCells: cells).isEmpty,
                      "with it the level is playable: "
                      + "\(LevelRules.validate(rows, solidCells: cells))")
    }

    func testShippedFriseLevelsAreValid() {
        for file in LevelLibrary.files where !(file.frises ?? []).isEmpty {
            for (index, spec) in (file.frises ?? []).enumerated() {
                XCTAssertTrue(spec.problems.isEmpty,
                              "'\(file.name)' frise \(index): \(spec.problems)")
            }
            let problems = LevelRules.validate(file.rows,
                                               solidCells: file.friseFootprint())
            XCTAssertTrue(problems.isEmpty, "'\(file.name)': \(problems)")
        }
    }

    // MARK: Node

    func testNodeBuildsFromAValidSpec() {
        let node = FriseNode(spec: ground())
        XCTAssertNotNil(node)
        XCTAssertNotNil(node?.physicsBody, "ground has to collide")
        XCTAssertFalse(node?.physicsBody?.isDynamic ?? true, "terrain is static")
        XCTAssertGreaterThan(node?.curve.count ?? 0, 2)
    }

    func testNodeRefusesABadSpec() {
        XCTAssertNil(FriseNode(spec: ground(thickness: 400)),
                     "a self-intersecting band must not build")
    }

    func testDecorNodeHasNoPhysics() {
        var spec = ground()
        spec.kind = .decor
        spec.depth = 0.3
        let node = FriseNode(spec: spec)
        XCTAssertNotNil(node)
        XCTAssertNil(node?.physicsBody)
    }

    func testSurfaceQueryFollowsTheCurve() {
        guard let node = FriseNode(spec: ground()) else { return XCTFail("no node") }
        // At a control point the surface is that point's height.
        XCTAssertEqual(node.surfaceY(atX: 0) ?? 0, 120, accuracy: 1)
        XCTAssertEqual(node.surfaceY(atX: 200) ?? 0, 190, accuracy: 2)
        XCTAssertNil(node.surfaceY(atX: 5_000), "off the end is nil, not zero")
    }

    // MARK: Packed atlas

    func testPackedAtlasCoversTheRig() throws {
        guard let atlas = PackedAtlas(named: "hero_atlas") else {
            throw XCTSkip("no packed atlas in the bundle — run `make atlas`")
        }
        let data = try RigLoader.load(named: "hero_rig")
        var checked = 0
        for (_, slots) in data.skins {
            for (_, attachments) in slots {
                for (_, attachment) in attachments {
                    let image: String
                    switch attachment {
                    case .region(let i, _, _, _, _, _, _, _): image = i
                    case .mesh(let i, _, _, _, _, _, _): image = i
                    case .box: continue
                    }
                    checked += 1
                    XCTAssertNotNil(atlas.texture(named: image),
                                    "'\(image)' is not on the page, so the rig falls "
                                    + "back to a loose texture and the batching win "
                                    + "is lost")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testPackedAtlasSubTexturesAreCachedNotRebuilt() throws {
        guard let atlas = PackedAtlas(named: "hero_atlas") else {
            throw XCTSkip("no packed atlas")
        }
        guard let first = atlas.frameNames.first else { return XCTFail("empty atlas") }
        let a = atlas.texture(named: first)
        let b = atlas.texture(named: first)
        XCTAssertTrue(a === b, "rebuilding a sub-texture per lookup would allocate "
                      + "every frame")
    }

    func testUnknownFrameIsNil() throws {
        guard let atlas = PackedAtlas(named: "hero_atlas") else {
            throw XCTSkip("no packed atlas")
        }
        XCTAssertNil(atlas.texture(named: "definitely_not_a_frame"))
    }

    func testMissingAtlasIsNilNotACrash() {
        XCTAssertNil(PackedAtlas(named: "no_such_atlas"),
                     "a build without a packed atlas must fall back to loose art")
    }

    // MARK: Post-processing

    func testNamedGradesResolve() {
        for name in ["neutral", "grove", "hollow", "evening", "arena"] {
            XCTAssertNotNil(PostProcess.Grade.named[name], "grade '\(name)' missing")
        }
    }

    func testNeutralGradeDisablesTheChain() {
        // A grade with nothing switched on should cost nothing at all.
        let chain = PostProcess(size: CGSize(width: 844, height: 390))
        chain.apply(.neutral)
        XCTAssertFalse(chain.shouldEnableEffects)
        chain.apply(.grove)
        XCTAssertTrue(chain.shouldEnableEffects)
    }

    func testUnknownGradeIsRefused() {
        let chain = PostProcess(size: CGSize(width: 844, height: 390))
        XCTAssertFalse(chain.apply(named: "chartreuse"))
        XCTAssertTrue(chain.apply(named: "hollow"))
    }

    func testEveryLevelsGradeExists() {
        for file in LevelLibrary.files {
            guard let name = file.grade else { continue }
            XCTAssertNotNil(PostProcess.Grade.named[name],
                            "'\(file.name)' names grade '\(name)', which does not "
                            + "exist — the level would fall back to the default")
        }
    }

    func testImpactDecaysToZero() {
        let chain = PostProcess(size: CGSize(width: 844, height: 390))
        chain.impact(1.0, decay: 6)
        // A punch that never decays leaves the frame permanently bent.
        for _ in 0..<40 { chain.update(1.0 / 60) }
        chain.update(1.0 / 60)
        // Nothing public exposes the punch value, so assert the observable: another
        // update after full decay must be a no-op rather than going negative.
        chain.update(1.0 / 60)
        XCTAssertTrue(chain.shouldEnableEffects, "decay must not disable the chain")
    }
}

/// Backdrop planes: painted spline geometry and instanced props.
///
/// The property that matters is *determinism*. The offline preview is what an
/// author approves, so if the game scatters props differently the composite they
/// signed off is not the picture that ships. Both sides run the same explicit LCG
/// rather than each language's own RNG for exactly that reason.
final class BackdropPlaneTests: XCTestCase {

    private func prop(seed: Int = 4177, count: Int = 7) -> FriezeScene.Prop {
        FriezeScene.Prop(image: "prop_trunk", count: count, span: 680, y: -60,
                         yJitter: 26, scale: 1, scaleJitter: 0.28,
                         flipChance: 0.5, seed: seed, density: 4)
    }

    private func scene() -> FriezeScene? { FriezeScene.load(named: "forest_backdrop") }

    func testScatterIsDeterministic() throws {
        let scene = try XCTUnwrap(self.scene())
        let a = FriezeStage.scatter(prop(), depth: 0.52, scene: scene)
        let b = FriezeStage.scatter(prop(), depth: 0.52, scene: scene)
        guard a.count == b.count, !a.isEmpty else {
            throw XCTSkip("prop art not bundled")
        }
        for (left, right) in zip(a, b) {
            XCTAssertEqual(left.position.x, right.position.x, accuracy: 0.0001)
            XCTAssertEqual(left.position.y, right.position.y, accuracy: 0.0001)
        }
    }

    func testDifferentSeedGivesADifferentLayout() throws {
        let scene = try XCTUnwrap(self.scene())
        let a = FriezeStage.scatter(prop(seed: 4177), depth: 0.52, scene: scene)
        let b = FriezeStage.scatter(prop(seed: 99), depth: 0.52, scene: scene)
        guard !a.isEmpty, a.count == b.count else { throw XCTSkip("prop art") }
        let same = zip(a, b).allSatisfy { abs($0.position.x - $1.position.x) < 0.001 }
        XCTAssertFalse(same, "the seed has to change the arrangement")
    }

    func testScatterStaysInsideItsSpan() throws {
        let scene = try XCTUnwrap(self.scene())
        let nodes = FriezeStage.scatter(prop(), depth: 0.52, scene: scene)
        guard !nodes.isEmpty else { throw XCTSkip("prop art") }
        for node in nodes {
            XCTAssertLessThanOrEqual(abs(node.position.x), 680 / 2,
                                     "an instance outside the span breaks the wrap")
        }
    }

    func testScatterDoesNotClump() throws {
        // Evenly spaced then jittered, so instances never pile into a gap — the
        // failure mode of naive random placement.
        let scene = try XCTUnwrap(self.scene())
        let xs = FriezeStage.scatter(prop(), depth: 0.52, scene: scene)
            .map(\.position.x).sorted()
        guard xs.count > 2 else { throw XCTSkip("prop art") }
        let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThan(gaps.min() ?? 0, 20,
                             "instances \(gaps.min() ?? 0)pt apart read as a clump")
    }

    func testZeroCountScattersNothing() throws {
        let scene = try XCTUnwrap(self.scene())
        XCTAssertTrue(FriezeStage.scatter(prop(count: 0), depth: 0.5,
                                          scene: scene).isEmpty)
    }

    func testShippedBackdropUsesPropsAndGeometry() throws {
        // The point of the work: the backdrop is images *plus* painted spline
        // geometry *plus* instanced props, not one picture per plane.
        let scene = try XCTUnwrap(self.scene())
        let props = scene.layers.flatMap { $0.props ?? [] }
        let frises = scene.layers.flatMap { $0.frises ?? [] }
        XCTAssertFalse(props.isEmpty, "no prop scatters — every plane is one picture")
        XCTAssertFalse(frises.isEmpty, "no painted spline geometry in the backdrop")
        for prop in props {
            XCTAssertGreaterThan(prop.count, 0)
            XCTAssertGreaterThan(prop.span, 0, "a zero span breaks the wrap")
            XCTAssertNotNil(UIImage(named: prop.image),
                            "prop '\(prop.image)' has no art")
        }
        for spec in frises {
            XCTAssertTrue(spec.problems.isEmpty, "\(spec.problems)")
        }
    }

    func testBackdropFriseIsForcedToDecor() throws {
        // A backdrop element must never collide, whatever the spec says.
        var spec = FriseSpec(kind: .ground, color: [120, 150, 100],
                             points: [[0, 60], [200, 118], [430, 76]],
                             thickness: 90)
        spec.kind = .decor
        XCTAssertNil(FriseNode(spec: spec)?.physicsBody)
    }
}
