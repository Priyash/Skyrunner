import CoreGraphics
import Foundation

/// The player's movement state machine — dash, climb, ledge grab, slopes and the
/// carriers that override them.
///
/// Deliberately a plain value type with no SpriteKit in sight: it takes a
/// description of the world around the player and returns the velocity to apply.
/// That makes the part of the game most likely to feel wrong the part that can be
/// exercised without a device, and it keeps `GameScene.update` readable as the
/// order in which systems get a say.
///
/// Precedence matters more than any individual rule. From strongest to weakest:
/// dash, ledge hang, climb, spring, updraft, then ordinary run-and-jump. A dash
/// that can be cancelled by a conveyor, or a ledge grab that loses to gravity,
/// feels broken in a way no amount of tuning fixes.
struct PlayerMotion {

    enum Mode: Equatable {
        case normal
        case dashing
        case climbing
        case ledgeHang
    }

    /// What the scene has probed about the player's surroundings this frame.
    struct World {
        var grounded = false
        /// Surface normal of the ground under the player, if any. A 45° ramp
        /// gives roughly (∓0.707, 0.707).
        var groundNormal: CGVector? = nil
        var wallAhead = false
        var onClimbable = false
        var inUpdraft = false
        /// Horizontal carry from a conveyor or moving platform, pt/s.
        var carry: CGFloat = 0
        /// A lip within grabbing distance, and which way it faces (±1).
        var ledgeDirection: CGFloat = 0
        var touchingSpring = false
    }

    /// What the player is asking for.
    struct Input {
        var move: CGFloat = 0
        var vertical: CGFloat = 0
        var jumpPressed = false
        var jumpHeld = false
        var dashPressed = false
    }

    private(set) var mode: Mode = .normal
    private(set) var facing: CGFloat = 1
    /// Set for one frame when a spring fires, so the scene can play its squash.
    private(set) var firedSpring = false

    private var dashUntil: TimeInterval = -1
    private var dashReadyAt: TimeInterval = 0
    private var dashDirection: CGFloat = 1
    private var hangUntil: TimeInterval = -1
    private var hangDirection: CGFloat = 0

    var isDashing: Bool { mode == .dashing }
    var isClimbing: Bool { mode == .climbing }
    var isHanging: Bool { mode == .ledgeHang }
    /// Gravity is suspended in these modes; the scene drives velocity instead.
    var suspendsGravity: Bool { mode != .normal }

    func dashAvailable(now: TimeInterval) -> Bool { now >= dashReadyAt }

    /// One step. Returns the velocity to write onto the physics body.
    mutating func step(now: TimeInterval, dt: CGFloat, input: Input, world: World,
                       velocity: CGVector, runSpeed: CGFloat,
                       jumpVelocity: CGFloat) -> CGVector {
        firedSpring = false
        if input.move != 0 { facing = input.move > 0 ? 1 : -1 }

        // ── dash ───────────────────────────────────────────────────────────
        if mode == .dashing {
            if now >= dashUntil {
                mode = .normal
                // Hand back a run-speed's worth of momentum rather than
                // stopping dead: a dash that ends in a stall reads as a bug.
                return CGVector(dx: dashDirection * Tuning.dashEndSpeed,
                                dy: velocity.dy)
            }
            return CGVector(dx: dashDirection * Tuning.dashSpeed, dy: 0)
        }
        if input.dashPressed, now >= dashReadyAt, mode != .ledgeHang {
            mode = .dashing
            dashDirection = input.move != 0 ? (input.move > 0 ? 1 : -1) : facing
            dashUntil = now + Tuning.dashTime
            dashReadyAt = now + Tuning.dashCooldown
            return CGVector(dx: dashDirection * Tuning.dashSpeed, dy: 0)
        }

        // ── ledge hang ─────────────────────────────────────────────────────
        if mode == .ledgeHang {
            if input.jumpPressed {
                mode = .normal
                // Climbing up beats hanging: launch up and slightly inward.
                return CGVector(dx: hangDirection * runSpeed * 0.4,
                                dy: Tuning.ledgeClimbBoost)
            }
            // Pulling away from the wall, or the timer running out, drops you.
            if now >= hangUntil || (input.move != 0 && input.move * hangDirection < 0) {
                mode = .normal
                return CGVector(dx: -hangDirection * runSpeed * 0.3, dy: 0)
            }
            return .zero
        }
        if !world.grounded, world.ledgeDirection != 0,
           velocity.dy <= Tuning.ledgeGrabFallWindow,
           input.move * world.ledgeDirection > 0 {
            mode = .ledgeHang
            hangDirection = world.ledgeDirection
            hangUntil = now + Tuning.ledgeHangTime
            return .zero
        }

        // ── climbing ───────────────────────────────────────────────────────
        if mode == .climbing {
            if input.jumpPressed {
                mode = .normal
                return CGVector(dx: -facing * Tuning.climbJumpAway, dy: jumpVelocity * 0.82)
            }
            if !world.onClimbable {
                mode = .normal
            } else {
                return CGVector(dx: input.move * Tuning.climbSpeed * 0.45,
                                dy: input.vertical * Tuning.climbSpeed)
            }
        } else if world.onClimbable, input.vertical != 0 {
            mode = .climbing
            return CGVector(dx: 0, dy: input.vertical * Tuning.climbSpeed)
        }

        // ── springs ────────────────────────────────────────────────────────
        // Checked before the jump so a spring is never "eaten" by a held jump
        // button, and it launches whether or not the player asked to jump.
        if world.touchingSpring, velocity.dy <= 1 {
            firedSpring = true
            return CGVector(dx: velocity.dx, dy: Tuning.springLaunch)
        }

        // ── ordinary motion ────────────────────────────────────────────────
        var vx = input.move * runSpeed + world.carry
        var vy = velocity.dy

        // Slopes: project the run along the surface instead of driving into it.
        // Without this a ramp is climbed by a series of collisions, which the
        // eye reads as stuttering.
        if world.grounded, let n = world.groundNormal, abs(n.dx) > 0.05, input.move != 0 {
            let along = CGVector(dx: n.dy, dy: -n.dx)          // rotate −90°
            let sign: CGFloat = along.dx * input.move >= 0 ? 1 : -1
            let speed = abs(input.move) * runSpeed * Tuning.slopeAssist
            vx = along.dx * sign * speed
            // Downhill: bias into the surface so the player doesn't launch off
            // every crest and bunny-hop down the ramp.
            vy = min(vy, along.dy * sign * speed)
        }

        if world.inUpdraft {
            vy = max(vy, Tuning.updraftLift)
        }

        return CGVector(dx: vx, dy: vy)
    }

    /// Cancel every override — used on damage and respawn, where leaving the
    /// player mid-dash or hanging off a ledge that no longer exists is a bug.
    mutating func reset() {
        mode = .normal
        dashUntil = -1
        hangUntil = -1
        hangDirection = 0
        firedSpring = false
    }
}
