import CoreGraphics

enum PhysicsCategory {
    static let none:   UInt32 = 0
    static let player: UInt32 = 1 << 0
    static let ground: UInt32 = 1 << 1
    static let coin:   UInt32 = 1 << 2
    static let enemy:  UInt32 = 1 << 3
    static let hazard: UInt32 = 1 << 4
    static let finish: UInt32 = 1 << 5
    /// Interactables that read as terrain to the solver but need per-frame
    /// gameplay behaviour: conveyors, springs, crushers.
    static let spring:     UInt32 = 1 << 6
    static let conveyor:   UInt32 = 1 << 7
    static let climbable:  UInt32 = 1 << 8
    static let updraft:    UInt32 = 1 << 9
    static let checkpoint: UInt32 = 1 << 10
    /// Anything the player can stand on. Ray casts test this rather than
    /// enumerating categories at each call site.
    static let standable: UInt32 = ground | conveyor | spring
}

enum Tuning {
    static let tileSize: CGFloat = 40
    static let sceneSize = CGSize(width: 844, height: 390)
    static let startingLives = 3

    // SpriteKit gravity is in m/s² with 150pt = 1m, so -18 → 2700 pt/s².
    // jumpVelocity 880 → apex ≈ 880²/(2·2700) ≈ 143pt ≈ 3.5 tiles.
    static let gravity: CGFloat = -18
    static let runSpeed: CGFloat = 260
    static let jumpVelocity: CGFloat = 880
    static let coyoteTime: TimeInterval = 0.10    // grace period after leaving a ledge
    static let jumpBuffer: TimeInterval = 0.12    // press jump slightly before landing
    static let jumpCutMultiplier: CGFloat = 0.45  // release early → shorter jump
    static let hoverFallSpeed: CGFloat = -95      // helicopter-hair max fall speed
    static let enemyStompBounce: CGFloat = 500

    // Dash: a burst that ignores gravity, then hands velocity back to the run.
    // 0.16s at 620pt/s covers ~2.5 tiles — far enough to clear a gap the jump
    // can't, short enough that it never replaces jumping.
    static let dashSpeed: CGFloat = 620
    static let dashTime: TimeInterval = 0.16
    static let dashCooldown: TimeInterval = 0.42
    static let dashEndSpeed: CGFloat = 300        // speed handed back on exit

    // Ledge grab: hang from a lip, then jump or drop off it.
    static let ledgeGrabFallWindow: CGFloat = -60 // must be descending to catch
    static let ledgeHangTime: TimeInterval = 1.4  // auto-release, so you can't camp
    static let ledgeClimbBoost: CGFloat = 940

    // Climbing (vines / ladders)
    static let climbSpeed: CGFloat = 165
    static let climbJumpAway: CGFloat = 220

    // Slopes: 45° tiles. A slope you can't run up reads as a wall, so the
    // controller pushes along the surface rather than into it.
    static let slopeAssist: CGFloat = 1.05        // speed multiplier along a slope
    static let slopeSnapDistance: CGFloat = 14    // stick to the surface downhill

    // Interactables
    static let springLaunch: CGFloat = 1360
    static let conveyorSpeed: CGFloat = 190
    static let updraftLift: CGFloat = 430         // terminal rise inside a column
    static let crusherFallSpeed: CGFloat = -1250
    static let crusherRetractSpeed: CGFloat = 150
    static let crusherIdle: TimeInterval = 1.1
    static let crusherHold: TimeInterval = 0.45

    // Enemy AI
    static let enemyPatrolSpeed: CGFloat = 70
    static let enemyChaseSpeed: CGFloat = 118
    static let enemyAlertRange: CGFloat = 250     // vision distance (facing only)
    static let enemyGiveUpRange: CGFloat = 330
    static let enemyAlertDelay: TimeInterval = 0.35

    // Coins
    static let magnetRadius: CGFloat = 74
    static let magnetPull: CGFloat = 420
    static let comboWindow: TimeInterval = 1.2
    static let comboMaxMultiplier = 5

    // Camera
    static let cameraLead: CGFloat = 0.16         // seconds of velocity to look ahead
    static let cameraSmoothing: CGFloat = 9       // lerp rate (per second)

    // Moving platforms
    static let moverTravel: CGFloat = 55          // ± horizontal travel
    static let moverSpeed: CGFloat = 1.1          // radians/sec of the sine drive

    // Enemy AI
    static let enemyPatrolSpeed: CGFloat = 70
    static let enemyChaseSpeed: CGFloat = 118
    static let enemyAlertRange: CGFloat = 250     // vision distance (facing only)
    static let enemyGiveUpRange: CGFloat = 330
    static let enemyAlertDelay: TimeInterval = 0.35

    // Coins
    static let magnetRadius: CGFloat = 74
    static let magnetPull: CGFloat = 420
    static let comboWindow: TimeInterval = 1.2
    static let comboMaxMultiplier = 5

    // Camera
    static let cameraLead: CGFloat = 0.16         // seconds of velocity to look ahead
    static let cameraSmoothing: CGFloat = 9       // lerp rate (per second)

    // Moving platforms
    static let moverTravel: CGFloat = 55          // ± horizontal travel
    static let moverSpeed: CGFloat = 1.1          // radians/sec of the sine drive

    // Combat
    static let punchRange: CGFloat = 55
    static let punchCooldown: TimeInterval = 0.35
    static let poundHangTime: TimeInterval = 0.12
    static let poundSpeed: CGFloat = -1500
    static let poundKillRadius: CGFloat = 85

    // Wall movement
    static let wallSlideMaxFall: CGFloat = -140
    static let wallJumpLockTime: TimeInterval = 0.18
    static let wallCoyote: TimeInterval = 0.08

    // Boss
    static let bossHP = 3
    static let bossHopVX: CGFloat = 210
    static let bossHopVY: CGFloat = 720
    static let bossIdleBase: TimeInterval = 1.15
    static let bossHurtInvuln: TimeInterval = 1.0
}

enum ProductID {
    static let removeAds = "com.yourcompany.platformer.removeads"
    static let coins500  = "com.yourcompany.platformer.coins500"
}
