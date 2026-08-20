import XCTest
import SpriteKit
@testable import SkyRunner

/// Presentation: shadow roles, light cookies, backdrop deformation, particles, and the
/// in-engine editor.
///
/// The unifying property is that every one of these fails *silently* when it's wrong.
/// A sprite that shadows itself just looks dirty; a particle preset with a bad curve
/// just looks flat; an editor that paints two spawns produces a level that fails
/// validation with no clue why.
final class PresentationTests: XCTestCase {

    // MARK: Shadow roles — the self-shadowing bug

    func testShadowRolesAreDistinct() {
        // The bug this encodes: the old code set `shadowCastBitMask` and
        // `shadowedBitMask` to the same mask on the same sprite, so every sprite cast a
        // shadow onto itself. A role must do one or the other.
        XCTAssertEqual(NormalMapper.ShadowRole.caster.cast, LightCategory.key)
        XCTAssertEqual(NormalMapper.ShadowRole.caster.receive, 0,
                       "a caster must not also receive, or it shadows itself")
        XCTAssertEqual(NormalMapper.ShadowRole.receiver.receive, LightCategory.key)
        XCTAssertEqual(NormalMapper.ShadowRole.receiver.cast, 0)
        XCTAssertEqual(NormalMapper.ShadowRole.none.cast, 0)
        XCTAssertEqual(NormalMapper.ShadowRole.none.receive, 0)
        // `.both` exists for thick geometry and is deliberately opt-in.
        XCTAssertEqual(NormalMapper.ShadowRole.both.cast, LightCategory.key)
        XCTAssertEqual(NormalMapper.ShadowRole.both.receive, LightCategory.key)
    }

    func testApplyingARoleSetsOnlyThatMask() {
        let sprite = SKSpriteNode(texture: SKTexture(imageNamed: "hero_body"))
        NormalMapper.apply(to: sprite, shadows: .caster)
        XCTAssertEqual(sprite.shadowCastBitMask, LightCategory.key)
        XCTAssertEqual(sprite.shadowedBitMask, 0)
        NormalMapper.apply(to: sprite, shadows: .receiver)
        XCTAssertEqual(sprite.shadowCastBitMask, 0)
        XCTAssertEqual(sprite.shadowedBitMask, LightCategory.key)
    }

    func testLightingBitMaskIsSetSoTheSpriteIsLitAtAll() {
        let sprite = SKSpriteNode(texture: SKTexture(imageNamed: "hero_body"))
        NormalMapper.apply(to: sprite, categories: LightCategory.key, shadows: .none)
        XCTAssertEqual(sprite.lightingBitMask, LightCategory.key)
        XCTAssertNotNil(sprite.normalTexture, "no normal map means flat lighting")
    }

    // MARK: Light cookies

    func testEveryCookiePatternProducesATexture() {
        for pattern in LightCookie.Pattern.allCases {
            let texture = LightCookie.texture(for: pattern)
            XCTAssertGreaterThan(texture.size().width, 0, "\(pattern) has no texture")
        }
    }

    func testCookieTexturesAreCachedNotRebuilt() {
        // Rebuilding a 512×256 render per cookie would be a visible hitch.
        let a = LightCookie.texture(for: .dapple)
        let b = LightCookie.texture(for: .dapple)
        XCTAssertTrue(a === b)
    }

    func testCookieMultipliesRatherThanAddsAGreyFilm() {
        let node = LightCookie.make(.dapple, sceneSize: CGSize(width: 844, height: 390))
        XCTAssertEqual(node.blendMode, .multiply,
                       "a cookie removes light; additive would wash the frame out")
        XCTAssertGreaterThan(node.size.width, 844,
                             "oversized, or drifting exposes an edge")
    }

    func testCookieStrengthClamps() {
        let node = LightCookie.make(.blinds, sceneSize: CGSize(width: 844, height: 390),
                                    strength: 5)
        XCTAssertLessThanOrEqual(node.alpha, 1)
    }

    func testSeededRandomIsDeterministic() {
        // A cookie generated differently each run means the same level looks different
        // every time it is entered.
        var a = SeededRandom(seed: 99)
        var b = SeededRandom(seed: 99)
        for _ in 0..<20 {
            XCTAssertEqual(a.next(in: 0...1), b.next(in: 0...1), accuracy: 1e-12)
        }
    }

    func testSeededRandomStaysInRange() {
        var generator = SeededRandom(seed: 7)
        for _ in 0..<200 {
            let value = generator.next(in: 18...64)
            XCTAssertTrue((18...64).contains(value), "\(value) escaped its range")
        }
    }

    // MARK: Backdrop deformation

    func testDeformerIgnoresZeroAmplitude() {
        // A rigid backdrop must cost exactly nothing: no lattice, no per-frame work.
        let deformer = BackdropDeformer()
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 200, height: 100))
        deformer.adopt(sprite, depth: 0.5, amplitude: 0)
        XCTAssertEqual(deformer.targetCount, 0)
        XCTAssertNil(sprite.warpGeometry)
    }

    func testAdoptingInstallsALattice() {
        let deformer = BackdropDeformer()
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 200, height: 100))
        deformer.adopt(sprite, depth: 0.8, amplitude: 20)
        XCTAssertEqual(deformer.targetCount, 1)
        XCTAssertNotNil(sprite.warpGeometry)
    }

    func testWindMovesTheLatticeAndTheAnchorStaysPut() throws {
        let deformer = BackdropDeformer()
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 400, height: 200))
        deformer.adopt(sprite, depth: 0.9, amplitude: 30, pinBottom: true)
        deformer.update(dt: 0.4, cameraX: 0)
        let grid = try XCTUnwrap(sprite.warpGeometry as? SKWarpGeometryGrid)

        // Bottom row (the pinned edge) must be exactly where it started, or the whole
        // layer slides and reads as the camera moving.
        let columns = grid.numberOfColumns
        let rows = grid.numberOfRows
        for column in 0...columns {
            let pinned = grid.destPosition(at: rows * (columns + 1) + column)
            let source = grid.sourcePosition(at: rows * (columns + 1) + column)
            XCTAssertEqual(pinned.x, source.x, accuracy: 1e-5,
                           "the anchored row moved")
        }
        // The free edge must have moved, or wind is doing nothing.
        var moved = false
        for column in 0...columns {
            let free = grid.destPosition(at: column)
            let source = grid.sourcePosition(at: column)
            if abs(free.x - source.x) > 1e-6 { moved = true }
        }
        XCTAssertTrue(moved, "the unpinned edge did not sway")
    }

    func testWindOffIsAnEarlyOut() throws {
        let deformer = BackdropDeformer()
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 400, height: 200))
        deformer.adopt(sprite, depth: 0.9, amplitude: 30)
        deformer.wind = 0
        deformer.update(dt: 0.4, cameraX: 0)
        let grid = try XCTUnwrap(sprite.warpGeometry as? SKWarpGeometryGrid)
        for index in 0..<((grid.numberOfColumns + 1) * (grid.numberOfRows + 1)) {
            XCTAssertEqual(grid.destPosition(at: index).x,
                           grid.sourcePosition(at: index).x, accuracy: 1e-6)
        }
    }

    func testRipplesExpireAndAreCapped() {
        let deformer = BackdropDeformer()
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 400, height: 200))
        deformer.adopt(sprite, depth: 0.9, amplitude: 30)
        for _ in 0..<20 { deformer.impact(atSceneX: 100, strength: 1) }
        XCTAssertLessThanOrEqual(deformer.rippleCount, 7,
                                 "an effect that can be spammed must be bounded")
        deformer.update(dt: 1.5, cameraX: 0)
        XCTAssertEqual(deformer.rippleCount, 0, "ripples must decay away")
    }

    // MARK: Particles

    func testEveryShippedPresetIsValid() {
        let presets = ParticleSpec.shipped()
        XCTAssertGreaterThanOrEqual(presets.count, 12)
        for preset in presets {
            XCTAssertTrue(preset.problems.isEmpty,
                          "'\(preset.name)': \(preset.problems)")
        }
        let names = presets.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate preset names")
    }

    func testEveryGameplayEventMapsToARealPreset() {
        let known = Set(ParticleSpec.shipped().map(\.name))
        for (event, preset) in ParticleSpec.events {
            XCTAssertTrue(known.contains(preset),
                          "event '\(event)' fires '\(preset)', which does not exist")
        }
    }

    func testPresetValidationCatchesTheRealMistakes() {
        var spec = ParticleSpec(name: "x")
        XCTAssertTrue(spec.problems.isEmpty)
        // A lifetime range wider than the lifetime means particles born already dead.
        spec.lifetimeRange = spec.lifetime + 1
        XCTAssertTrue(spec.problems.contains { $0.contains("lifetimeRange") },
                      "\(spec.problems)")
        spec = ParticleSpec(name: "x")
        spec.kind = .stream
        spec.count = 400
        XCTAssertFalse(spec.problems.isEmpty, "an unbounded stream rate must be refused")
        spec = ParticleSpec(name: "")
        XCTAssertFalse(spec.problems.isEmpty)
    }

    func testLibraryPoolsAndCaps() {
        let host = SKNode()
        let library = ParticleLibrary(host: host)
        XCTAssertFalse(library.presetNames.isEmpty)
        // Fire past the cap: the extra calls must be refused, not queued or crash.
        for index in 0..<(ParticleLibrary.maxLive + 10) {
            library.emit("hit_spark", at: .zero, now: Double(index) * 0.001)
        }
        XCTAssertLessThanOrEqual(library.liveCount, ParticleLibrary.maxLive)
        // Advance past every lifetime; everything must be reclaimed.
        library.update(now: 60)
        XCTAssertEqual(library.liveCount, 0)
        // And the pool is reused rather than reallocated.
        library.emit("hit_spark", at: .zero, now: 61)
        XCTAssertEqual(library.liveCount, 1)
    }

    func testUnknownPresetIsSilent() {
        let library = ParticleLibrary(host: SKNode())
        XCTAssertNil(library.emit("no_such_effect", at: .zero, now: 0))
    }

    func testEveryParticleShapeGeneratesATexture() {
        for shape in [ParticleSpec.Shape.blob, .disc, .streak, .star, .leaf] {
            XCTAssertGreaterThan(ParticleLibrary.texture(for: shape).size().width, 0,
                                 "\(shape) produced no texture")
        }
    }

    // MARK: In-engine editor

    func testEditorPaintsAndUndoes() {
        let overlay = EditorOverlay(rows: ["...", "...", "XXX"],
                                    tile: 40, sceneSize: CGSize(width: 844, height: 390))
        XCTAssertEqual(overlay.editedRows.count, 3)
        XCTAssertEqual(overlay.editedRows[2], "XXX")
    }

    func testEditorNormalizesItsInput() {
        // Ragged rows would index out of bounds while painting.
        let overlay = EditorOverlay(rows: ["X", "XXXX"], tile: 40,
                                    sceneSize: CGSize(width: 844, height: 390))
        XCTAssertEqual(Set(overlay.editedRows.map(\.count)).count, 1)
    }

    func testEditorStartsFromTheLevelItWasGiven() {
        let rows = ["..S...", "XXXXXX"]
        let overlay = EditorOverlay(rows: rows, tile: 40,
                                    sceneSize: CGSize(width: 844, height: 390))
        XCTAssertEqual(overlay.editedRows, LevelRules.normalize(rows))
    }
}
