import XCTest
@testable import SkyRunner

/// Level-design rules.
///
/// These are the rules the visual editor, the AI planner and the runtime all
/// have to agree on, and there are three implementations of them:
/// `World/LevelRules.swift`, the mirror in `Tools/ai_director.py`, and the one
/// in `Tools/LevelEditor.html`. This suite pins the Swift one, which is the
/// authority the other two are ported from — so a drift shows up as a failing
/// test rather than as a level that validates in the editor and is unplayable in
/// the game.
final class LevelRulesTests: XCTestCase {

    // MARK: Legend integrity

    func testLegendSymbolsAreUnique() {
        let symbols = TileSymbol.legend.map(\.symbol)
        XCTAssertEqual(symbols.count, Set(symbols).count,
                       "two tiles share a symbol, so one is unreachable from data")
        XCTAssertEqual(TileSymbol.allowed.count, symbols.count)
        XCTAssertEqual(TileSymbol.allowedText.count, symbols.count)
    }

    func testEverySolidTileIsInTheLegend() {
        for symbol in TileSymbol.solid {
            XCTAssertNotNil(TileSymbol.tile(symbol),
                            "'\(symbol)' is solid but has no legend entry, so the "
                            + "editor can't offer it and the docs don't describe it")
        }
        for symbol in TileSymbol.lifts {
            XCTAssertNotNil(TileSymbol.tile(symbol))
        }
    }

    func testSolidTilesAreNotPassable() {
        // The reachability search and the physics build read these two sets
        // independently. If a tile were in both, the search would walk through a
        // wall and bless an impossible level.
        for symbol in TileSymbol.solid {
            XCTAssertFalse(TileSymbol.isPassable(symbol),
                           "'\(symbol)' is both solid and passable")
        }
    }

    func testLegendJSONDescribesEveryTile() {
        // The editor builds its palette from this, so a missing key is a blank
        // button rather than an error.
        let json = TileSymbol.legendJSON
        XCTAssertEqual(json.count, TileSymbol.legend.count)
        for entry in json {
            XCTAssertNotNil(entry["symbol"] as? String)
            XCTAssertNotNil(entry["name"] as? String)
            XCTAssertNotNil(entry["category"] as? String)
        }
    }

    func testActorKindsMapToLegendSymbols() {
        for (kind, symbol) in TileSymbol.actorKinds {
            XCTAssertNotNil(TileSymbol.tile(symbol),
                            "actor kind '\(kind)' maps to unknown symbol '\(symbol)'")
        }
        XCTAssertEqual(TileSymbol.actorKindList.count, TileSymbol.actorKinds.count)
    }

    // MARK: normalize

    func testNormalizePadsToTheWidestRow() {
        let rows = LevelRules.normalize(["XX", "XXXXX", ""])
        XCTAssertEqual(rows.map(\.count), [5, 5, 5])
        XCTAssertEqual(rows[0], "XX...",
                       "padding is '.', and a space folds to '.' — one spelling of "
                       + "empty, or the same level compares unequal to itself")
    }

    func testNormalizeIsIdempotent() {
        let once = LevelRules.normalize(["X", "XXX"])
        XCTAssertEqual(LevelRules.normalize(once), once)
    }

    func testNormalizeFoldsSpacesToDots() {
        // Everything that writes rows writes spaces (the editor, the planner, a
        // hand-typed file) because a grid of dots is unreadable. Exactly one
        // spelling may survive normalization.
        XCTAssertEqual(LevelRules.normalize(["S  F", "XXXX"]), ["S..F", "XXXX"])
    }

    func testSpaceIsAcceptedInputAndDotIsCanonical() {
        XCTAssertTrue(TileSymbol.accepted.contains(" "))
        XCTAssertFalse(TileSymbol.allowed.contains(" "),
                       "the legend itself must not gain a space — it is an input "
                       + "spelling, not a tile the editor should offer")
        XCTAssertTrue(TileSymbol.isEmpty(" "))
        XCTAssertTrue(TileSymbol.isEmpty("."))
        XCTAssertFalse(TileSymbol.isEmpty("X"))
    }

    func testNormalizeHandlesEmptyInput() {
        XCTAssertEqual(LevelRules.normalize([]), [])
    }

    // MARK: validate

    func testEveryShippedLevelValidates() {
        // The strongest single assertion in the suite: whatever the rules say,
        // the game's own content has to satisfy them.
        for (index, rows) in Levels.all.enumerated() {
            let problems = LevelRules.validate(rows)
            XCTAssertTrue(problems.isEmpty,
                          "shipped level \(index) violates its own rules: "
                          + problems.joined(separator: "; "))
        }
    }

    func testMissingSpawnIsRejected() {
        let problems = LevelRules.validate(["   ", "XXX"])
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.lowercased().contains("spawn") },
                      "expected a spawn complaint, got \(problems)")
    }

    func testUnknownSymbolIsRejected() {
        // Regression: `validate` used to have no such check, so a typo built as
        // empty air and silently deleted a platform. Only `setLevel` caught it,
        // which meant a hand-written level file never got checked at all.
        let problems = LevelRules.validate(["S %", "XXX"])
        XCTAssertTrue(problems.contains { $0.contains("%") },
                      "expected the unknown glyph to be named, got \(problems)")
        XCTAssertTrue(problems.contains { $0.contains("column") },
                      "the message has to say where, got \(problems)")
    }

    func testFloatingGroundTileIsRejected() {
        // A coin in mid-air is fine; an enemy standing on nothing is a bug the
        // author cannot see in a text grid.
        let rows = ["E  ",
                    "   ",
                    "XXX"]
        let problems = LevelRules.validate(["S" + rows[0].dropFirst()] + rows.dropFirst())
        XCTAssertFalse(problems.isEmpty)
    }

    // MARK: reachability

    func testFlatWalkIsReachable() {
        let problems = LevelRules.validate(["S     F",
                                           "XXXXXXX"])
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    func testGapWithinJumpRangeIsReachable() {
        // maxJumpAcross tiles of air, so the far side must be blessed.
        let gap = String(repeating: " ", count: LevelRules.maxJumpAcross)
        let problems = LevelRules.validate(["S" + gap + "F",
                                           "X" + gap + "X"])
        XCTAssertTrue(problems.isEmpty, "a \(LevelRules.maxJumpAcross)-tile gap "
                      + "should clear: \(problems)")
    }

    func testGapBeyondEveryMovementIsRejected() {
        // Wider than a dash, with no spring or lift to help: genuinely stranded.
        let gap = String(repeating: " ", count: LevelRules.maxDashAcross + 4)
        let problems = LevelRules.validate(["S" + gap + "F",
                                           "X" + gap + "X"])
        XCTAssertFalse(problems.isEmpty,
                       "an unreachable goal has to be reported, or the AI planner "
                       + "will happily ship a level that cannot be finished")
    }

    func testDashClearsAGapAJumpCannot() {
        // The gap sits between the jump and dash limits, so it is only passable
        // because the dash exists — which is exactly what the rule encodes.
        let width = (LevelRules.maxJumpAcross + LevelRules.maxDashAcross) / 2
        XCTAssertGreaterThan(width, LevelRules.maxJumpAcross)
        let gap = String(repeating: " ", count: width)
        let problems = LevelRules.validate(["S" + gap + "F",
                                           "X" + gap + "X"])
        XCTAssertTrue(problems.isEmpty, "dash gap of \(width) rejected: \(problems)")
    }

    func testFlatJumpAcrossIsAllowed() {
        // Regression: an earlier reachability pass required a height change, so
        // a level-to-level hop over a pit read as unreachable.
        let problems = LevelRules.validate(["S   F",
                                           "X   X"])
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    func testPlatformHigherThanAJumpIsUnreachable() {
        // The goal sits on a proper platform — so this fails the reachability
        // rule and nothing else. An earlier version put the goal on air, which
        // failed the needs-ground rule instead and would have passed even if
        // reachability were broken.
        var rows = ["....F.", "....X."]
        for _ in 0..<(LevelRules.maxJumpUp + 3) { rows.append("......") }
        rows.append("S.....")
        rows.append("XXXXXX")
        let problems = LevelRules.validate(rows)
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.lowercased().contains("reach") },
                      "expected a reachability complaint, got \(problems)")
    }

    func testSpringMakesATallClimbReachable() {
        // The same height, with a spring under it: the rule has to know that the
        // spring changes the answer, or level design has to avoid the mechanic.
        var rows = ["....F.", "....X."]
        for _ in 0..<(LevelRules.maxJumpUp + 3) { rows.append("......") }
        rows.append("S...!.")
        rows.append("XXXXXX")
        XCTAssertTrue(LevelRules.validate(rows).isEmpty,
                      "\(LevelRules.validate(rows))")
    }

    func testDocumentedRulesCoverTheLimits() {
        // These strings are what the AI planner is shown as its constraints, so
        // a limit that isn't mentioned is a limit the model will violate.
        let text = LevelRules.documentedRules.joined(separator: " ")
        for limit in [LevelRules.maxJumpUp, LevelRules.maxJumpAcross,
                      LevelRules.maxDashAcross, LevelRules.maxSpringUp] {
            XCTAssertTrue(text.contains("\(limit)"),
                          "limit \(limit) is enforced but undocumented")
        }
    }

    func testOversizeGridIsRejectedRatherThanHanging() {
        // The flood fill is O(rows × cols × moves); an unbounded grid from a
        // malformed command would wedge the app rather than fail.
        let wide = String(repeating: "X", count: LevelRules.maxColumns + 10)
        XCTAssertFalse(LevelRules.validate(["S", wide]).isEmpty)
    }
}
