import XCTest
import SpriteKit
@testable import SkyRunner

/// The animation state machine and blend trees.
///
/// Every case here was first validated by porting the runner to Python and
/// stepping it frame by frame — which is how two of them were found to be wrong in
/// the *test* rather than the engine (both asserted a pure pose during an active
/// crossfade). The graph's value is that its behaviour is checkable at all; a
/// chain of `if` statements in an update loop is not.
final class AnimGraphTests: XCTestCase {

    private let durations: [String: TimeInterval] = [
        "idle": 1.8, "run": 0.52, "jump": 0.5, "fall": 0.6, "land": 0.24,
        "dash": 0.16, "climb": 0.72, "punch": 0.21, "hurt": 0.34, "victory": 0.9,
    ]

    private func runner() -> AnimGraphRunner {
        AnimGraphRunner(graph: .player(), clipDurations: durations)
    }

    private func params(_ build: (inout AnimGraph.Parameters) -> Void)
        -> AnimGraph.Parameters {
        var p = AnimGraph.Parameters()
        build(&p)
        return p
    }

    /// Step past a crossfade so a blend can be measured on its own.
    private func settle(_ runner: inout AnimGraphRunner, frames: Int,
                        _ p: AnimGraph.Parameters) -> [String: CGFloat] {
        var last: [AnimGraph.Playing] = []
        for _ in 0..<frames { last = runner.step(dt: 1.0 / 60, parameters: p) }
        return last.reduce(into: [:]) { $0[$1.clip, default: 0] += $1.weight }
    }

    // MARK: Structure

    func testShippedGraphIsStructurallySound() {
        let problems = AnimGraph.player().problems(availableClips: Set(durations.keys))
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    func testGraphIsCheckedAgainstTheRigsRealClips() throws {
        // The graph is only driven when the rig can supply every clip, so this is
        // the assertion that the shipped rig and the shipped graph agree.
        let data = try RigLoader.load(named: "hero_rig")
        let problems = AnimGraph.player()
            .problems(availableClips: Set(data.animations.keys))
        XCTAssertTrue(problems.isEmpty,
                      "the shipped rig cannot drive the shipped graph: \(problems)")
    }

    func testMissingClipIsReportedNotIgnored() {
        let problems = AnimGraph.player().problems(availableClips: ["idle"])
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("run") })
    }

    func testUnreachableStateIsReported() {
        let graph = AnimGraph(states: [
            .init(name: "a", clip: .single("idle")),
            .init(name: "orphan", clip: .single("run")),
        ], transitions: [], initial: "a")
        XCTAssertTrue(graph.problems(availableClips: ["idle", "run"])
            .contains { $0.contains("orphan") },
                      "a state nothing transitions into can never play")
    }

    func testDegenerateBlendIsReported() {
        let graph = AnimGraph(states: [
            .init(name: "a", clip: .blend1D(["jump", "fall"], parameter: "vy",
                                            range: .init(0, 0))),
        ], transitions: [], initial: "a")
        XCTAssertFalse(graph.problems(availableClips: ["jump", "fall"]).isEmpty,
                       "a zero-width blend range divides by zero in spirit")
    }

    // MARK: Span

    func testDescendingSpanIsNotInverted() {
        // `ClosedRange` traps when built descending, which is why `Span` exists: a
        // falling vy runs +320 → −520 and inverting it by hand is how blend trees
        // end up backwards.
        let span = AnimGraph.Span(320, -520)
        XCTAssertEqual(span.fraction(320), 0, accuracy: 0.0001)
        XCTAssertEqual(span.fraction(-520), 1, accuracy: 0.0001)
        XCTAssertEqual(span.fraction(-100), 0.5, accuracy: 0.02)
    }

    func testSpanClampsOutsideItsEnds() {
        let span = AnimGraph.Span(90, 420)
        XCTAssertEqual(span.fraction(0), 0, accuracy: 0.0001)
        XCTAssertEqual(span.fraction(9_999), 1, accuracy: 0.0001)
    }

    func testDegenerateSpanDoesNotDivideByZero() {
        XCTAssertEqual(AnimGraph.Span(5, 5).fraction(5), 0, accuracy: 0.0001)
    }

    // MARK: Locomotion

    func testIdleToRunAndBackWithHysteresis() {
        var r = runner()
        _ = r.step(dt: 1 / 60, parameters: params { $0.set("grounded", true) })
        XCTAssertEqual(r.current, "idle")
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(260)) })
        XCTAssertEqual(r.current, "run")
        // 30 is below the 40 that enters `run` but above the 25 that leaves it —
        // the gap is deliberate, or the animation flickers at walking pace.
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(30)) })
        XCTAssertEqual(r.current, "run", "hysteresis gap collapsed")
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(5)) })
        XCTAssertEqual(r.current, "idle")
    }

    func testRunRateFollowsGroundSpeed() {
        var r = runner()
        for _ in 0..<3 {
            _ = r.step(dt: 1 / 60, parameters: params {
                $0.set("grounded", true); $0.set("speed", CGFloat(90)) })
        }
        let slow = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(90)) })
        let fast = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(420)) })
        XCTAssertEqual(slow.first { $0.clip == "run" }?.rate ?? 0, 0.72, accuracy: 0.02)
        XCTAssertEqual(fast.first { $0.clip == "run" }?.rate ?? 0, 1.55, accuracy: 0.02)
    }

    // MARK: Blending

    func testAirBlendsRiseToFallAcrossTheApex() {
        var r = runner()
        let rising = settle(&r, frames: 10, params {
            $0.set("grounded", false); $0.set("vy", CGFloat(320)) })
        XCTAssertGreaterThan(rising["jump"] ?? 0, 0.99, "\(rising)")

        let apex = settle(&r, frames: 1, params {
            $0.set("grounded", false); $0.set("vy", CGFloat(-100)) })
        XCTAssertTrue((0.1...0.9).contains(apex["jump"] ?? 0)
                      && (0.1...0.9).contains(apex["fall"] ?? 0),
                      "the apex must be a real blend, not a switch: \(apex)")

        let falling = settle(&r, frames: 1, params {
            $0.set("grounded", false); $0.set("vy", CGFloat(-520)) })
        XCTAssertGreaterThan(falling["fall"] ?? 0, 0.99, "\(falling)")
    }

    func testBlendWeightsAlwaysSumToOne() {
        var r = runner()
        for vy in stride(from: CGFloat(320), through: CGFloat(-560), by: -40) {
            let playing = r.step(dt: 1 / 60, parameters: params {
                $0.set("grounded", false); $0.set("vy", vy) })
            let total = playing.reduce(0) { $0 + $1.weight }
            XCTAssertEqual(total, 1, accuracy: 0.0001,
                           "weights sum to \(total) at vy \(vy)")
        }
    }

    func testFallWeightIsMonotonicInVerticalSpeed() {
        // A wobble here is a limb that twitches at the apex.
        var r = runner()
        _ = settle(&r, frames: 10, params {
            $0.set("grounded", false); $0.set("vy", CGFloat(320)) })
        var previous: CGFloat = -1
        for vy in stride(from: CGFloat(320), through: CGFloat(-560), by: -40) {
            let playing = r.step(dt: 1 / 60, parameters: params {
                $0.set("grounded", false); $0.set("vy", vy) })
            let weight = playing.first { $0.clip == "fall" }?.weight ?? 0
            XCTAssertGreaterThanOrEqual(weight, previous - 0.0001,
                                        "fall weight fell at vy \(vy)")
            previous = weight
        }
    }

    func testCrossfadeReportsBothStates() {
        var r = runner()
        _ = settle(&r, frames: 20, params { $0.set("grounded", true) })
        let playing = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(300)) })
        XCTAssertEqual(playing.count, 2, "a crossfade has two contributors")
        XCTAssertEqual(playing.reduce(0) { $0 + $1.weight }, 1, accuracy: 0.0001)
    }

    // MARK: Priority and timing

    func testHurtInterruptsADash() {
        var r = runner()
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("dashing", true) })
        XCTAssertEqual(r.current, "dash")
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("dashing", true); $0.set("hurt", true) })
        XCTAssertEqual(r.current, "hurt", "priority 90 must beat priority 60")
    }

    func testVictoryOutranksEverything() {
        var r = runner()
        _ = r.step(dt: 1 / 60, parameters: params { $0.set("hurt", true) })
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("hurt", true); $0.set("victory", true) })
        XCTAssertEqual(r.current, "victory")
    }

    func testClipFinishedWaitsTheClipOut() {
        var r = runner()
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("punch", true) })
        XCTAssertEqual(r.current, "punch")
        // Halfway through its 0.21s, still playing.
        for _ in 0..<6 { _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true) }) }
        XCTAssertEqual(r.current, "punch", "a one-shot must not be cut off early")
        for _ in 0..<12 { _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true) }) }
        XCTAssertEqual(r.current, "idle", "and it must leave once it has played")
    }

    func testMinimumTimeProtectsTheLandingPose() {
        var r = runner()
        for _ in 0..<4 { _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", false); $0.set("vy", CGFloat(-400)) }) }
        let landed = params { $0.set("grounded", true); $0.set("speed", CGFloat(240)) }
        _ = r.step(dt: 1 / 60, parameters: landed)
        XCTAssertEqual(r.current, "land")
        _ = r.step(dt: 1 / 60, parameters: landed)
        XCTAssertEqual(r.current, "land",
                       "minimumTime must hold the impact pose for more than a frame")
        for _ in 0..<8 { _ = r.step(dt: 1 / 60, parameters: landed) }
        XCTAssertEqual(r.current, "run", "and then hand off to locomotion")
    }

    func testStateTimeResetsOnTransition() {
        var r = runner()
        for _ in 0..<30 { _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true) }) }
        XCTAssertGreaterThan(r.stateTime, 0.4)
        _ = r.step(dt: 1 / 60, parameters: params {
            $0.set("grounded", true); $0.set("speed", CGFloat(300)) })
        XCTAssertEqual(r.stateTime, 0, accuracy: 0.0001,
                       "a stale state time would fire clipFinished immediately")
    }
}
