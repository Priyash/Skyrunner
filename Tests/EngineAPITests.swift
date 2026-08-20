import XCTest
import SpriteKit
@testable import SkyRunner

/// The command surface — the engine's machine-drivable API.
///
/// This is the contract an agent or an editor programs against, so the important
/// property is not "does it work" but "does it fail *safely and legibly*". Bad
/// input arrives constantly from a model: out-of-range numbers, wrong types,
/// `1e400`, unknown ops. Every one has to come back as a rejection with a reason
/// rather than a crash, a trap, or a silently broken game.
final class EngineAPITests: XCTestCase {

    private var saved: EngineOverrides.Snapshot!

    override func setUp() {
        super.setUp()
        // The overrides object is a singleton by design (the running scene reads
        // it every frame), so each test brackets its own changes.
        saved = EngineOverrides.shared.snapshot()
        EngineOverrides.shared.reset()
    }

    override func tearDown() {
        EngineOverrides.shared.restore(saved)
        super.tearDown()
    }

    // MARK: Parsing

    func testParsesASingleCommand() {
        let (commands, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setRunSpeed", "value": 300}]}
            """)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(commands.count, 1)
        guard case .setRunSpeed(let v) = commands[0] else {
            return XCTFail("wrong command: \(commands[0])")
        }
        XCTAssertEqual(v, 300, accuracy: 0.001)
    }

    func testParsesABareArrayToo() {
        // Models emit both shapes; refusing one is a pointless round trip.
        let (commands, errors) = EngineScript.parse(text: """
            [{"op": "reload"}]
            """)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(commands.count, 1)
    }

    func testUnknownOpIsRejectedByNameNotIgnored() {
        let (commands, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setGravity", "value": -20},
                          {"op": "makeItFun"}]}
            """)
        XCTAssertEqual(commands.count, 1, "the good command still applies")
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("makeItFun"),
                      "the error has to name the op so the caller can fix it: "
                      + "\(errors)")
    }

    func testMalformedJSONIsAnErrorNotACrash() {
        let (commands, errors) = EngineScript.parse(text: "{not json at all")
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(errors.isEmpty)
    }

    func testMissingValueIsRejected() {
        let (_, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setRunSpeed"}]}
            """)
        XCTAssertEqual(errors.count, 1)
    }

    func testWrongTypeIsRejected() {
        let (_, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setRunSpeed", "value": "fast"}]}
            """)
        XCTAssertEqual(errors.count, 1, "a string where a number belongs must not "
                       + "become 0")
    }

    // MARK: Clamping

    func testOutOfRangeValuesAreClampedNotRefused() {
        // A model that asks for gravity −900 wants "much heavier", and clamping
        // gives it the strongest legal answer instead of a dead end.
        let (commands, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setGravity", "value": -900},
                          {"op": "setRunSpeed", "value": 99999},
                          {"op": "setJumpVelocity", "value": 1},
                          {"op": "setCameraLead", "value": -5}]}
            """)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(commands.count, 4)
        guard case .setGravity(let g) = commands[0],
              case .setRunSpeed(let r) = commands[1],
              case .setJumpVelocity(let j) = commands[2],
              case .setCameraLead(let c) = commands[3] else {
            return XCTFail("commands parsed to the wrong cases")
        }
        XCTAssertEqual(g, -60, accuracy: 0.001)
        XCTAssertEqual(r, 700, accuracy: 0.001)
        XCTAssertEqual(j, 300, accuracy: 0.001)
        XCTAssertEqual(c, 0, accuracy: 0.001)
    }

    func testNonFiniteNumbersAreRejectedRatherThanTrapping() {
        // `Int(1e400)` and `Int(Double.nan)` trap in Swift — a crash reachable
        // from a text file the model writes. This is the single nastiest input
        // this surface takes.
        let (commands, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setRunSpeed", "value": 1e400},
                          {"op": "setTile", "col": 1e400, "row": 0, "symbol": "X"}]}
            """)
        XCTAssertTrue(commands.isEmpty, "a non-finite number must not become a command")
        XCTAssertEqual(errors.count, 2)
    }

    func testSymbolMustBeInTheLegend() {
        let (commands, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setTile", "col": 0, "row": 0, "symbol": "%"}]}
            """)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(errors.isEmpty, "an unknown glyph would build as empty air")
    }

    func testColliderModeMustBeAKnownMode() {
        let (ok, okErrors) = EngineScript.parse(text: """
            {"commands": [{"op": "setColliderMode", "mode": "perSlot"}]}
            """)
        XCTAssertTrue(okErrors.isEmpty, "\(okErrors)")
        XCTAssertEqual(ok.count, 1)
        let (bad, badErrors) = EngineScript.parse(text: """
            {"commands": [{"op": "setColliderMode", "mode": "quantum"}]}
            """)
        XCTAssertTrue(bad.isEmpty)
        XCTAssertFalse(badErrors.isEmpty)
    }

    // MARK: Receipts

    func testReceiptJSONIsParseableAndReportsBothSides() {
        // The receipt is the only thing a caller sees, so it has to be machine
        // readable — a model correcting itself parses this, it doesn't read prose.
        let scene = SKScene(size: CGSize(width: 844, height: 390))
        let interpreter = EngineInterpreter(scene: scene)
        let (commands, _) = EngineScript.parse(text: """
            {"commands": [{"op": "setRunSpeed", "value": 300},
                          {"op": "setTile", "col": 0, "row": 9999, "symbol": "X"}]}
            """)
        let receipt = interpreter.apply(commands)
        guard let data = receipt.jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return XCTFail("receipt is not valid JSON:\n\(receipt.jsonText)")
        }
        XCTAssertNotNil(object["applied"] as? [String])
        XCTAssertNotNil(object["rejected"] as? [String])
        XCTAssertFalse(receipt.applied.isEmpty)
        XCTAssertFalse(receipt.rejected.isEmpty,
                       "a row past the end of the level has to be refused")
    }

    func testLevelEditsRequestAReload() {
        // Tiles change the physics graph, which is built once at load. Callers
        // rely on this flag to know a further read-back would be stale.
        let scene = SKScene(size: CGSize(width: 844, height: 390))
        let interpreter = EngineInterpreter(scene: scene)
        let (commands, _) = EngineScript.parse(text: """
            {"commands": [{"op": "setLevel", "rows": ["S  F", "XXXX"]}]}
            """)
        XCTAssertTrue(interpreter.apply(commands).needsReload)
    }

    func testTuningChangesDoNotRequestAReload() {
        let scene = SKScene(size: CGSize(width: 844, height: 390))
        let interpreter = EngineInterpreter(scene: scene)
        let (commands, _) = EngineScript.parse(text: """
            {"commands": [{"op": "setRunSpeed", "value": 300}]}
            """)
        XCTAssertFalse(interpreter.apply(commands).needsReload,
                       "retuning is live; asking for a reload would throw away "
                       + "the player's position for nothing")
    }

    func testLevelEditsCarryDesignWarnings() {
        // A level that parses but cannot be finished is the failure mode that
        // matters for AI authoring, so the receipt reports it.
        let scene = SKScene(size: CGSize(width: 844, height: 390))
        let interpreter = EngineInterpreter(scene: scene)
        let far = String(repeating: " ", count: LevelRules.maxDashAcross + 6)
        let (commands, _) = EngineScript.parse(text: """
            {"commands": [{"op": "setLevel",
                           "rows": ["S\(far)F", "X\(far)X"]}]}
            """)
        let receipt = interpreter.apply(commands)
        XCTAssertFalse(receipt.warnings.isEmpty,
                       "an unreachable goal must be warned about, not accepted "
                       + "silently")
    }

    // MARK: Overrides

    func testOverridesShadowCompiledTuning() {
        XCTAssertEqual(EngineOverrides.shared.effectiveRunSpeed, Tuning.runSpeed)
        EngineOverrides.shared.runSpeed = 333
        XCTAssertEqual(EngineOverrides.shared.effectiveRunSpeed, 333)
        EngineOverrides.shared.reset()
        XCTAssertEqual(EngineOverrides.shared.effectiveRunSpeed, Tuning.runSpeed,
                       "reset has to fall back to the shipped value")
    }

    func testSnapshotAndRestoreIsExact() {
        // This is what makes an AI experiment reversible: try a tuning, measure,
        // roll back precisely.
        EngineOverrides.shared.runSpeed = 411
        EngineOverrides.shared.colliderMode = .perSlot
        EngineOverrides.shared.setLevelOverride(["S F", "XXX"], for: 2)
        let mark = EngineOverrides.shared.snapshot()

        EngineOverrides.shared.runSpeed = 120
        EngineOverrides.shared.colliderMode = .box
        EngineOverrides.shared.reset()
        EngineOverrides.shared.restore(mark)

        XCTAssertEqual(EngineOverrides.shared.runSpeed, 411)
        XCTAssertEqual(EngineOverrides.shared.colliderMode, .perSlot)
        XCTAssertEqual(EngineOverrides.shared.rows(forLevel: 2) ?? [], ["S.F", "XXX"],
                       "stored rows are normalized, so the space came back as '.'")
    }

    func testLevelOverrideIsKeyedToItsLevel() {
        // Regression: an edit to level 1 used to follow the player into level 2,
        // which looked like the next level had been corrupted.
        EngineOverrides.shared.setLevelOverride(["S F", "XXX"], for: 1)
        XCTAssertEqual(EngineOverrides.shared.rows(forLevel: 1) ?? [], ["S.F", "XXX"])
        XCTAssertNotEqual(EngineOverrides.shared.rows(forLevel: 2) ?? [],
                          ["S.F", "XXX"])
        XCTAssertEqual(EngineOverrides.shared.rows(forLevel: 2) ?? [],
                       Levels.all.indices.contains(2) ? Levels.all[2] : [])
    }

    func testEditsToSeveralLevelsCoexist() {
        // Regression: overrides were one level's rows plus the index they
        // belonged to, so editing level 2 silently discarded the edit to level 1
        // — an agent building a four-level game could only hold one in flight.
        EngineOverrides.shared.setLevelOverride(["S.F", "XXX"], for: 0)
        EngineOverrides.shared.setLevelOverride(["S..F", "XXXX"], for: 1)
        XCTAssertEqual(EngineOverrides.shared.rows(forLevel: 0) ?? [], ["S.F", "XXX"])
        XCTAssertEqual(EngineOverrides.shared.rows(forLevel: 1) ?? [], ["S..F", "XXXX"])
        XCTAssertEqual(EngineOverrides.shared.editedLevels, [0, 1])
    }

    func testClearingOneLevelsEditLeavesTheOthers() {
        EngineOverrides.shared.setLevelOverride(["S.F", "XXX"], for: 0)
        EngineOverrides.shared.setLevelOverride(["S..F", "XXXX"], for: 1)
        EngineOverrides.shared.clearLevelOverride(for: 0)
        XCTAssertEqual(EngineOverrides.shared.editedLevels, [1])
        XCTAssertEqual(EngineOverrides.shared.rows(forLevel: 0) ?? [],
                       Levels.all.indices.contains(0) ? Levels.all[0] : [],
                       "clearing has to fall back to the level's own rows")
    }

    func testSpaceIsAcceptedByTheCommandSurface() {
        // Everything that writes rows writes spaces, and `setLevel` used to
        // reject them — so the documented example did not parse.
        let (commands, errors) = EngineScript.parse(text: """
            {"commands": [{"op": "setLevel", "rows": ["S  F", "XXXX"]},
                          {"op": "setTile", "col": 1, "row": 0, "symbol": " "}]}
            """)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(commands.count, 2)
        guard case .setTile(_, _, let symbol) = commands[1] else {
            return XCTFail("wrong command")
        }
        XCTAssertEqual(symbol, ".", "a space has to be folded to the canonical empty")
    }

    func testLevelOverrideIsNormalizedOnTheWayIn() {
        EngineOverrides.shared.setLevelOverride(["S", "XXXX"], for: 0)
        let rows = EngineOverrides.shared.rows(forLevel: 0) ?? []
        XCTAssertEqual(Set(rows.map(\.count)).count, 1,
                       "ragged rows would index out of bounds during the build")
    }

    func testRowsForAnUnknownLevelIsNil() {
        XCTAssertNil(EngineOverrides.shared.rows(forLevel: 9_999))
    }

    // MARK: Self-description

    func testSchemaIsValidJSONAndCoversEveryOp() {
        // The schema is how an agent discovers the API without being told. If an
        // op exists but isn't described, the model cannot call it.
        guard let data = EngineSchema.jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let ops = object["ops"] as? [[String: Any]] else {
            return XCTFail("schema is not valid JSON")
        }
        XCTAssertGreaterThan(ops.count, 10)
        let described = Set(ops.compactMap { $0["op"] as? String })
        for op in ["setLevel", "setTile", "fillRegion", "setSpawn", "loadFrieze",
                   "setLighting", "setTimeOfDay", "spawnActor", "playAnimation",
                   "setAnimationMix", "setColliderMode", "setSkin", "setGravity",
                   "setRunSpeed", "setJumpVelocity", "setCameraLead",
                   "showColliders", "reset", "reload"] {
            XCTAssertTrue(described.contains(op), "op '\(op)' is callable but "
                          + "missing from the self-describing schema")
        }
        for op in ops {
            XCTAssertNotNil(op["doc"] as? String, "\(op["op"] ?? "?") has no doc")
        }
    }

    func testSchemaPublishesTheSameLegendTheRulesEnforce() {
        guard let data = EngineSchema.jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return XCTFail("schema is not valid JSON")
        }
        if let tiles = object["tiles"] as? [[String: Any]] {
            XCTAssertEqual(tiles.count, TileSymbol.legend.count,
                           "the published palette drifted from the enforced one")
        }
    }

    func testStateSnapshotWorksWithoutAScene() {
        // The bridge writes state on demand, including before the first scene
        // exists; a nil scene must produce a valid document, not a crash.
        let text = EngineSnapshot.jsonText(of: nil)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return XCTFail("state is not valid JSON:\n\(text)")
        }
        XCTAssertNotNil(object["tuning"])
    }

    func testStateReportsShippedVersusOverriddenTuning() {
        EngineOverrides.shared.runSpeed = 321
        let text = EngineSnapshot.jsonText(of: nil)
        XCTAssertTrue(text.contains("321"),
                      "state has to show the value actually in force, or a caller "
                      + "cannot tell whether its command took effect")
    }

    // MARK: Round trip

    func testEveryDocumentedOpParses() {
        // Guards the case where the schema promises an op whose parser was never
        // written — discoverable, callable, and broken.
        let samples: [String] = [
            #"{"op": "setLevel", "rows": ["S F", "XXX"]}"#,
            #"{"op": "setTile", "col": 0, "row": 0, "symbol": "X"}"#,
            #"{"op": "fillRegion", "col": 0, "row": 0, "width": 2, "height": 1, "symbol": "X"}"#,
            #"{"op": "setSpawn", "col": 1, "row": 0}"#,
            #"{"op": "loadFrieze", "name": "forest_backdrop"}"#,
            #"{"op": "setLighting", "warm": [1,0.9,0.7], "cool": [0.3,0.4,0.6], "ambient": 0.5}"#,
            #"{"op": "setTimeOfDay", "t": 0.3}"#,
            #"{"op": "spawnActor", "kind": "enemy", "col": 3, "row": 1}"#,
            #"{"op": "playAnimation", "actor": "player", "clip": "run"}"#,
            #"{"op": "setAnimationMix", "from": "idle", "to": "run", "duration": 0.12}"#,
            #"{"op": "setColliderMode", "mode": "hull"}"#,
            #"{"op": "setSkin", "actor": "player", "skin": "default"}"#,
            #"{"op": "setGravity", "value": -18}"#,
            #"{"op": "setRunSpeed", "value": 260}"#,
            #"{"op": "setJumpVelocity", "value": 880}"#,
            #"{"op": "setCameraLead", "value": 0.16}"#,
            #"{"op": "showColliders", "value": true}"#,
            #"{"op": "reset"}"#,
            #"{"op": "reload"}"#,
        ]
        for sample in samples {
            let (commands, errors) = EngineScript.parse(
                text: "{\"commands\": [\(sample)]}")
            XCTAssertEqual(commands.count, 1, "did not parse: \(sample) — \(errors)")
            XCTAssertTrue(errors.isEmpty, "\(sample): \(errors)")
        }
    }
}
