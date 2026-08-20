import XCTest
@testable import SkyRunner

/// The `level/1` file format and the library that loads it.
///
/// Levels used to be a Swift literal, which made the editor a drawing tool you
/// copy-pasted out of. Now they are files the editor writes and the bundle
/// carries — which means a whole class of failure moved from "impossible" to
/// "possible and silent": a level that fails to decode simply vanishes from the
/// menu. Everything here exists to make that loud.
final class LevelFileTests: XCTestCase {

    // MARK: The library loads what shipped

    func testLevelFilesLoadWithoutProblems() {
        // `loadProblems` is populated during `LevelLibrary.load()`, so touching
        // `files` first is what makes this meaningful.
        _ = LevelLibrary.files
        XCTAssertTrue(LevelLibrary.loadProblems.isEmpty,
                      "level files failed to load: "
                      + LevelLibrary.loadProblems.joined(separator: "; "))
    }

    func testTheGameHasSomethingToPlay() {
        // Either files or the compiled fallback — but not neither, which would be
        // a build that launches to an empty menu.
        XCTAssertFalse(Levels.all.isEmpty)
    }

    func testLevelFilesAreShippedNotJustTheFallback() {
        // If this fails the format works but the content never got migrated, and
        // every level would silently be the compiled copy.
        XCTAssertFalse(LevelLibrary.files.isEmpty,
                       "no level/1 files in the bundle — the game is running on "
                       + "Levels.builtIn, so editing a file does nothing")
    }

    func testOrdersAreUniqueAndSorted() {
        // Two levels claiming one slot would order unpredictably between runs,
        // which a player reads as the levels shuffling themselves.
        let orders = LevelLibrary.files.map(\.order)
        XCTAssertEqual(orders, orders.sorted(), "files are not in play order")
        XCTAssertEqual(orders.count, Set(orders).count,
                       "duplicate order values: \(orders)")
    }

    func testNamesAreUniqueAndFileSafe() {
        let names = LevelLibrary.files.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate level names")
        let legal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(name.unicodeScalars.allSatisfy(legal.contains),
                          "'\(name)' is not a safe file stem / bundle key")
        }
    }

    func testRowsMatchTheFilesInOrder() {
        // `Levels.all` is what the scene builder consumes; if it ever stops
        // agreeing with `files`, level N plays level M's map.
        XCTAssertEqual(Levels.all.count, LevelLibrary.files.count)
        for (index, file) in LevelLibrary.files.enumerated() {
            XCTAssertEqual(Levels.all[index], LevelRules.normalize(file.rows),
                           "level \(index) ('\(file.name)') does not match its file")
        }
    }

    func testTitlesAreParallelToLevels() {
        // The menu indexes titles by level number, so a length mismatch is an
        // out-of-range crash on the level select.
        XCTAssertEqual(Levels.titles.count, Levels.all.count)
        for title in Levels.titles {
            XCTAssertFalse(title.isEmpty)
        }
    }

    // MARK: Every level is playable

    func testEveryLevelFileObeysTheDesignRules() {
        for file in LevelLibrary.files {
            let problems = LevelRules.validate(file.rows)
            XCTAssertTrue(problems.isEmpty,
                          "'\(file.name)' (order \(file.order)) violates the rules: "
                          + problems.joined(separator: "; "))
        }
    }

    func testEveryFallbackLevelObeysTheDesignRulesToo() {
        // The fallback is only reached on a build with no level files, which is
        // exactly when nobody is looking at it — so it has to be correct.
        XCTAssertFalse(Levels.builtIn.isEmpty)
        for (index, rows) in Levels.builtIn.enumerated() {
            let problems = LevelRules.validate(rows)
            XCTAssertTrue(problems.isEmpty,
                          "fallback level \(index): "
                          + problems.joined(separator: "; "))
        }
    }

    func testEveryLevelIsRectangularAfterNormalization() {
        for file in LevelLibrary.files {
            let widths = Set(LevelRules.normalize(file.rows).map(\.count))
            XCTAssertEqual(widths.count, 1,
                           "'\(file.name)' has ragged rows after normalization")
        }
    }

    // MARK: Presentation the file declares

    func testDeclaredBackdropsExist() {
        // A level naming a backdrop that isn't bundled falls back to procedural
        // parallax, which looks like the hi-res art broke rather than like a typo.
        for file in LevelLibrary.files {
            guard let frieze = file.frieze else { continue }
            XCTAssertNotNil(FriezeScene.load(named: frieze),
                            "'\(file.name)' names backdrop '\(frieze)', which is "
                            + "not in the bundle")
        }
    }

    func testDeclaredTimeOfDayIsInRange() {
        for file in LevelLibrary.files {
            guard let time = file.timeOfDay else { continue }
            XCTAssertTrue((0...1).contains(time),
                          "'\(file.name)' has timeOfDay \(time), outside 0…1")
        }
    }

    func testPerLevelPresentationIsReadableByIndex() {
        // This is what `GameScene` calls, and an off-by-one here would give every
        // level its neighbour's backdrop.
        for (index, file) in LevelLibrary.files.enumerated() {
            XCTAssertEqual(LevelLibrary.frieze(at: index), file.frieze)
            XCTAssertEqual(LevelLibrary.timeOfDay(at: index), file.timeOfDay)
        }
        XCTAssertNil(LevelLibrary.frieze(at: 9_999))
        XCTAssertNil(LevelLibrary.file(at: -1))
    }

    // MARK: Structural validation

    func testStructuralProblemsCatchAMalformedFile() {
        var file = LevelFile(format: "level/1", name: "x", order: 0, title: nil,
                             frieze: nil, timeOfDay: nil, rows: ["S.F", "XXX"])
        XCTAssertTrue(file.structuralProblems.isEmpty)

        file.format = "level/2"
        XCTAssertFalse(file.structuralProblems.isEmpty,
                       "a future format version must not be loaded as this one")

        file.format = "level/1"
        file.rows = []
        XCTAssertFalse(file.structuralProblems.isEmpty)

        file.rows = Array(repeating: "X", count: LevelRules.maxRows + 1)
        XCTAssertFalse(file.structuralProblems.isEmpty,
                       "an oversize grid would wedge the reachability search")

        file.rows = [String(repeating: "X", count: LevelRules.maxColumns + 1)]
        XCTAssertFalse(file.structuralProblems.isEmpty)
    }

    func testDisplayTitleFallsBackToTheName() {
        let file = LevelFile(format: "level/1", name: "grove", order: 10, title: nil,
                             frieze: nil, timeOfDay: nil, rows: ["S.F", "XXX"])
        XCTAssertEqual(file.displayTitle, "grove")
    }

    func testFileRoundTripsThroughJSON() {
        // The editor writes this JSON and the game reads it; a Codable change on
        // one side that the other doesn't expect is a level that stops loading.
        let original = LevelFile(format: "level/1", name: "grove", order: 10,
                                 title: "Sunlit Grove", frieze: "forest_backdrop",
                                 timeOfDay: 0.4, rows: ["S.F", "XXX"])
        do {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(LevelFile.self, from: data)
            XCTAssertEqual(decoded.name, original.name)
            XCTAssertEqual(decoded.order, original.order)
            XCTAssertEqual(decoded.title, original.title)
            XCTAssertEqual(decoded.frieze, original.frieze)
            XCTAssertEqual(decoded.timeOfDay, original.timeOfDay)
            XCTAssertEqual(decoded.rows, original.rows)
        } catch {
            XCTFail("round trip failed: \(error)")
        }
    }

    func testOptionalFieldsMayBeAbsent() {
        // The minimum a hand-written file has to contain. If this breaks, the
        // documented example stops working.
        let json = Data("""
            {"format": "level/1", "name": "bare", "order": 5,
             "rows": ["S.F", "XXX"]}
            """.utf8)
        do {
            let file = try JSONDecoder().decode(LevelFile.self, from: json)
            XCTAssertEqual(file.name, "bare")
            XCTAssertNil(file.title)
            XCTAssertNil(file.frieze)
            XCTAssertTrue(file.structuralProblems.isEmpty)
        } catch {
            XCTFail("a minimal level file must decode: \(error)")
        }
    }
}
