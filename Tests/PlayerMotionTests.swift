import XCTest
import SpriteKit
@testable import SkyRunner

/// The player movement state machine.
///
/// `PlayerMotion` is a value type with no scene, no physics body and no clock of
/// its own, precisely so that this file can exist: movement precedence is the
/// part of a platformer that most often breaks in ways playtesting finds late
/// ("the dash cancelled my ledge grab"), and it is cheap to pin exactly.
final class PlayerMotionTests: XCTestCase {

    private var motion = PlayerMotion()

    override func setUp() {
        super.setUp()
        motion = PlayerMotion()
    }

    private func grounded() -> PlayerMotion.World {
        var w = PlayerMotion.World()
        w.grounded = true
        return w
    }

    // MARK: Ordinary running

    func testRunSpeedFollowsInput() {
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1),
                            world: grounded(), velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dx, 260, accuracy: 0.001)
    }

    func testRunSpeedIsTheOverriddenValueNotTheCompiledOne() {
        // The command API can retune movement at runtime; if this read `Tuning`
        // directly, `setRunSpeed` would silently do nothing.
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: -1),
                            world: grounded(), velocity: .zero,
                            runSpeed: 400, jumpVelocity: 880)
        XCTAssertEqual(v.dx, -400, accuracy: 0.001)
    }

    func testFacingTracksInputAndPersistsWhenNeutral() {
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: -1), world: grounded(),
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(motion.facing, -1)
        _ = motion.step(now: 0.1, dt: 1 / 60, input: .init(), world: grounded(),
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(motion.facing, -1, "releasing the stick must not reset facing")
    }

    func testConveyorCarryAddsToRunSpeed() {
        var world = grounded()
        world.carry = 90
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dx, 350, accuracy: 0.001)
    }

    func testVerticalVelocityIsPreservedWhileRunning() {
        // Movement code must not stomp gravity's work, or the player floats.
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: grounded(),
                            velocity: CGVector(dx: 0, dy: -420),
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dy, -420, accuracy: 0.001)
    }

    // MARK: Dash

    func testDashOverridesRunSpeed() {
        let v = motion.step(now: 1, dt: 1 / 60, input: .init(move: 1, dashPressed: true),
                            world: grounded(), velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.isDashing)
        XCTAssertEqual(v.dx, Tuning.dashSpeed, accuracy: 0.001)
        XCTAssertEqual(v.dy, 0, accuracy: 0.001, "a dash is flat, not ballistic")
    }

    func testDashUsesFacingWhenNoDirectionIsHeld() {
        _ = motion.step(now: 1, dt: 1 / 60, input: .init(move: -1), world: grounded(),
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: 1.1, dt: 1 / 60, input: .init(dashPressed: true),
                            world: grounded(), velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dx, -Tuning.dashSpeed, accuracy: 0.001)
    }

    func testDashEndsWithMomentumNotAStall() {
        _ = motion.step(now: 1, dt: 1 / 60, input: .init(move: 1, dashPressed: true),
                        world: grounded(), velocity: .zero,
                        runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: 1 + Tuning.dashTime + 0.001, dt: 1 / 60,
                            input: .init(), world: grounded(), velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isDashing)
        XCTAssertEqual(v.dx, Tuning.dashEndSpeed, accuracy: 0.001,
                       "a dash that ends in a dead stop reads as a hitch")
    }

    func testDashRespectsItsCooldown() {
        _ = motion.step(now: 1, dt: 1 / 60, input: .init(move: 1, dashPressed: true),
                        world: grounded(), velocity: .zero,
                        runSpeed: 260, jumpVelocity: 880)
        let midCooldown = 1 + Tuning.dashTime + 0.01
        XCTAssertFalse(motion.dashAvailable(now: midCooldown))
        _ = motion.step(now: midCooldown, dt: 1 / 60, input: .init(),
                        world: grounded(), velocity: .zero,
                        runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: midCooldown, dt: 1 / 60,
                            input: .init(move: 1, dashPressed: true),
                            world: grounded(), velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isDashing, "dash re-fired inside its cooldown")
        XCTAssertEqual(v.dx, 260, accuracy: 0.001)
        XCTAssertTrue(motion.dashAvailable(now: 1 + Tuning.dashCooldown + 0.001))
    }

    func testDashSuspendsGravity() {
        _ = motion.step(now: 1, dt: 1 / 60, input: .init(move: 1, dashPressed: true),
                        world: grounded(), velocity: .zero,
                        runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.suspendsGravity,
                      "the scene reads this to stop applying gravity; a dash that "
                      + "falls is not a dash")
    }

    // MARK: Ledge hang

    func testLedgeGrabRequiresPushingIntoTheWallWhileFalling() {
        var world = PlayerMotion.World()
        world.ledgeDirection = 1
        // Pushing away: no grab.
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: -1), world: world,
                        velocity: CGVector(dx: 0, dy: -100),
                        runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isHanging)
        // Pushing in while falling: grab.
        let v = motion.step(now: 0.1, dt: 1 / 60, input: .init(move: 1), world: world,
                            velocity: CGVector(dx: 0, dy: -100),
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.isHanging)
        XCTAssertEqual(v.dx, 0, accuracy: 0.001)
        XCTAssertEqual(v.dy, 0, accuracy: 0.001, "a hang is motionless")
    }

    func testLedgeGrabDoesNotTriggerWhileRisingFast() {
        // Otherwise a jump up a wall sticks to every ledge on the way past.
        var world = PlayerMotion.World()
        world.ledgeDirection = 1
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                        velocity: CGVector(dx: 0, dy: 800),
                        runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isHanging)
    }

    func testJumpFromAHangClimbsUp() {
        var world = PlayerMotion.World()
        world.ledgeDirection = 1
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                        velocity: CGVector(dx: 0, dy: -100),
                        runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: 0.1, dt: 1 / 60, input: .init(jumpPressed: true),
                            world: world, velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isHanging)
        XCTAssertGreaterThan(v.dy, 0)
        XCTAssertGreaterThan(v.dx, 0, "climbing up moves onto the ledge, not off it")
    }

    func testPullingAwayDropsFromAHang() {
        var world = PlayerMotion.World()
        world.ledgeDirection = 1
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                        velocity: CGVector(dx: 0, dy: -100),
                        runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: 0.1, dt: 1 / 60, input: .init(move: -1), world: world,
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isHanging)
        XCTAssertLessThan(v.dx, 0)
    }

    func testHangTimesOut() {
        var world = PlayerMotion.World()
        world.ledgeDirection = 1
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                        velocity: CGVector(dx: 0, dy: -100),
                        runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.isHanging)
        _ = motion.step(now: Tuning.ledgeHangTime + 0.1, dt: 1 / 60, input: .init(),
                        world: world, velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isHanging, "hanging forever is a free rest stop")
    }

    // MARK: Climbing

    func testClimbNeedsVerticalIntentNotJustContact() {
        var world = PlayerMotion.World()
        world.onClimbable = true
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(), world: world,
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isClimbing, "brushing a vine must not grab it")
        let v = motion.step(now: 0.1, dt: 1 / 60, input: .init(vertical: 1),
                            world: world, velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.isClimbing)
        XCTAssertEqual(v.dy, Tuning.climbSpeed, accuracy: 0.001)
    }

    func testLeavingTheVineEndsTheClimb() {
        var world = PlayerMotion.World()
        world.onClimbable = true
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(vertical: 1), world: world,
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        world.onClimbable = false
        _ = motion.step(now: 0.1, dt: 1 / 60, input: .init(vertical: 1), world: world,
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.isClimbing)
        XCTAssertFalse(motion.suspendsGravity, "gravity has to come back on")
    }

    func testJumpOffAVineLaunchesAway() {
        var world = PlayerMotion.World()
        world.onClimbable = true
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1, vertical: 1),
                        world: world, velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: 0.1, dt: 1 / 60, input: .init(jumpPressed: true),
                            world: world, velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertGreaterThan(v.dy, 0)
        XCTAssertLessThan(v.dx, 0, "you push off the surface you were holding")
    }

    // MARK: Springs

    func testSpringLaunchesWithoutAJumpPress() {
        var world = grounded()
        world.touchingSpring = true
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(), world: world,
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dy, Tuning.springLaunch, accuracy: 0.001)
        XCTAssertTrue(motion.firedSpring, "the scene needs this to play the SFX once")
    }

    func testSpringDoesNotRefireWhileAlreadyRising() {
        var world = grounded()
        world.touchingSpring = true
        _ = motion.step(now: 0, dt: 1 / 60, input: .init(), world: world,
                        velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        let v = motion.step(now: 0.1, dt: 1 / 60, input: .init(), world: world,
                            velocity: CGVector(dx: 0, dy: Tuning.springLaunch),
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertFalse(motion.firedSpring)
        XCTAssertEqual(v.dy, Tuning.springLaunch, accuracy: 0.001,
                       "velocity is passed through, not re-added")
    }

    func testDashBeatsSpring() {
        // Precedence is the whole point of this type: a dash through a spring
        // pad must dash, or the mechanic becomes unusable in spring rooms.
        var world = grounded()
        world.touchingSpring = true
        let v = motion.step(now: 1, dt: 1 / 60, input: .init(move: 1, dashPressed: true),
                            world: world, velocity: .zero,
                            runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.isDashing)
        XCTAssertEqual(v.dy, 0, accuracy: 0.001)
    }

    // MARK: Slopes and updrafts

    func testSlopeProjectsMotionAlongTheSurface() {
        var world = grounded()
        // A 45° ramp rising to the right.
        let s = CGFloat(1 / 2.0.squareRoot())
        world.groundNormal = CGVector(dx: -s, dy: s)
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertGreaterThan(v.dx, 0)
        XCTAssertGreaterThan(v.dy, 0, "running up a ramp has to gain height, not "
                             + "bounce off it")
        // Speed along the surface, so the horizontal component is reduced.
        XCTAssertLessThan(v.dx, 260 * Tuning.slopeAssist)
    }

    func testDownhillDoesNotLaunchThePlayer() {
        var world = grounded()
        let s = CGFloat(1 / 2.0.squareRoot())
        world.groundNormal = CGVector(dx: s, dy: s)     // ramp falling to the right
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertLessThanOrEqual(v.dy, 0, "downhill must bias into the surface, or "
                                 + "the player bunny-hops down every ramp")
    }

    func testFlatGroundIsNotTreatedAsASlope() {
        var world = grounded()
        world.groundNormal = CGVector(dx: 0, dy: 1)
        let v = motion.step(now: 0, dt: 1 / 60, input: .init(move: 1), world: world,
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dx, 260, accuracy: 0.001,
                       "flat ground must not get the slope-assist multiplier")
    }

    func testUpdraftLiftsButDoesNotCapFasterMotion() {
        var world = PlayerMotion.World()
        world.inUpdraft = true
        let lifted = motion.step(now: 0, dt: 1 / 60, input: .init(), world: world,
                                 velocity: CGVector(dx: 0, dy: -300),
                                 runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(lifted.dy, Tuning.updraftLift, accuracy: 0.001)
        let faster = motion.step(now: 0.1, dt: 1 / 60, input: .init(), world: world,
                                 velocity: CGVector(dx: 0, dy: Tuning.updraftLift + 400),
                                 runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(faster.dy, Tuning.updraftLift + 400, accuracy: 0.001,
                       "an updraft is a floor on vertical speed, not a ceiling")
    }

    // MARK: Reset

    func testResetClearsEveryOverride() {
        _ = motion.step(now: 1, dt: 1 / 60, input: .init(move: 1, dashPressed: true),
                        world: grounded(), velocity: .zero,
                        runSpeed: 260, jumpVelocity: 880)
        XCTAssertTrue(motion.isDashing)
        motion.reset()
        XCTAssertFalse(motion.isDashing)
        XCTAssertFalse(motion.suspendsGravity)
        // Respawning mid-dash used to leave the player sliding into the wall that
        // killed them.
        let v = motion.step(now: 1.01, dt: 1 / 60, input: .init(), world: grounded(),
                            velocity: .zero, runSpeed: 260, jumpVelocity: 880)
        XCTAssertEqual(v.dx, 0, accuracy: 0.001)
    }
}
