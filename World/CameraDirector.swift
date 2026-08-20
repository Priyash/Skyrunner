import SpriteKit

/// Authorable camera framing.
///
/// The camera was clamp-plus-lead and nothing else, which means every room in the
/// game is framed identically. Rayman does the opposite: a big vertical shaft zooms
/// out, a boss arena locks, a chase pushes forward whether the player keeps up or
/// not. That is framing as *design*, and it has to be data for a designer to author
/// it.
///
/// ```json
/// "camera": {
///   "zoom": 1.0,
///   "zones": [
///     {"col": 30, "width": 12, "zoom": 1.35},
///     {"col": 44, "width": 6, "mode": "lock", "atCol": 47, "atRow": 4}
///   ]
/// }
/// ```
struct CameraSpec: Codable, Equatable {

    enum Mode: String, Codable {
        /// Follow the player, with velocity lead. The default everywhere.
        case follow
        /// Hold a fixed point — a boss arena, a puzzle room you must see all of.
        case lock
        /// Follow horizontally, hold the vertical. Stops a bumpy floor from making
        /// the whole frame bob, which is the most common camera complaint in a 2D
        /// platformer.
        case lockY
        /// Advance at a fixed speed regardless of the player. The chase.
        case chase
    }

    /// One framing override over a span of columns.
    struct Zone: Codable, Equatable {
        var col: Int
        var width: Int
        var mode: Mode = .follow
        var zoom: CGFloat?
        /// For `.lock`: the point to hold, in tile coordinates.
        var atCol: Int?
        var atRow: Int?
        /// For `.chase`: points per second.
        var speed: CGFloat?
        /// Seconds to blend into this zone's framing. A hard cut reads as a glitch
        /// unless it is deliberate.
        var blend: Double = 0.5

        func contains(x: CGFloat, tile: CGFloat) -> Bool {
            let left = CGFloat(col) * tile
            return x >= left && x < left + CGFloat(max(width, 1)) * tile
        }
    }

    /// Level-wide default zoom. 1 is the authored 844×390 framing; larger sees more.
    var zoom: CGFloat = 1
    /// Seconds of velocity to look ahead. Overrides the engine default when set.
    var lead: CGFloat?
    var zones: [Zone] = []

    var structuralProblems: [String] {
        var out: [String] = []
        if zoom < 0.5 || zoom > 2.5 {
            out.append("camera zoom \(zoom) is outside 0.5…2.5")
        }
        if let lead, lead < 0 || lead > 0.6 {
            out.append("camera lead \(lead) is outside 0…0.6")
        }
        for (index, zone) in zones.enumerated() {
            if zone.width < 1 { out.append("camera zone \(index) needs width ≥ 1") }
            if zone.col < 0 { out.append("camera zone \(index) starts off the grid") }
            if let z = zone.zoom, z < 0.5 || z > 2.5 {
                out.append("camera zone \(index) zoom \(z) is outside 0.5…2.5")
            }
            if zone.mode == .lock, zone.atCol == nil {
                out.append("camera zone \(index) locks but has no atCol")
            }
            if zone.mode == .chase, (zone.speed ?? 0) <= 0 {
                out.append("camera zone \(index) chases but has no speed")
            }
            if zone.blend < 0 || zone.blend > 4 {
                out.append("camera zone \(index) blend \(zone.blend)s is outside 0…4")
            }
        }
        // Overlapping zones would make framing depend on array order, which reads as
        // the camera changing its mind at a boundary.
        let sorted = zones.sorted { $0.col < $1.col }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.col + a.width > b.col {
            out.append("camera zones at col \(a.col) and \(b.col) overlap")
        }
        return out
    }
}

/// Resolves the framing for a frame: which zone applies, what mode, what zoom.
///
/// A value type with no scene, for the same reason `PlayerMotion` is: framing is
/// exactly the kind of logic that is easy to get subtly wrong and cheap to pin down
/// once it can be stepped in a test.
struct CameraDirector {

    private let spec: CameraSpec
    private let tile: CGFloat
    /// Blend state, so a zone change eases rather than cuts.
    private(set) var zoom: CGFloat
    private(set) var mode: CameraSpec.Mode = .follow
    private var targetZoom: CGFloat
    private var blendRate: CGFloat = 2
    /// For `.chase`, the camera's own x — it advances whether the player does or not.
    private(set) var chaseX: CGFloat = 0
    private var chaseSpeed: CGFloat = 0
    private var lockPoint: CGPoint?
    private var activeZone: Int?

    init(spec: CameraSpec, tile: CGFloat) {
        self.spec = spec
        self.tile = tile
        zoom = max(0.5, min(2.5, spec.zoom))
        targetZoom = zoom
    }

    var lead: CGFloat? { spec.lead }

    /// Advance one frame. `playerX` picks the zone; the result is what the scene
    /// should apply to its camera.
    mutating func step(dt: CGFloat, playerX: CGFloat,
                       playerY: CGFloat) -> (position: CGPoint?, zoom: CGFloat,
                                             mode: CameraSpec.Mode) {
        let found = spec.zones.firstIndex { $0.contains(x: playerX, tile: tile) }
        if found != activeZone {
            activeZone = found
            if let index = found {
                let zone = spec.zones[index]
                mode = zone.mode
                targetZoom = max(0.5, min(2.5, zone.zoom ?? spec.zoom))
                blendRate = zone.blend > 0.001 ? 1 / CGFloat(zone.blend) : 100
                chaseSpeed = zone.speed ?? 0
                if zone.mode == .chase, chaseX <= 0 { chaseX = playerX }
                if zone.mode == .lock, let atCol = zone.atCol {
                    lockPoint = CGPoint(x: (CGFloat(atCol) + 0.5) * tile,
                                        y: (CGFloat(zone.atRow ?? 4) + 0.5) * tile)
                } else {
                    lockPoint = nil
                }
            } else {
                mode = .follow
                targetZoom = max(0.5, min(2.5, spec.zoom))
                blendRate = 2
                lockPoint = nil
                chaseSpeed = 0
            }
        }
        // Exponential ease, framerate-independent.
        if abs(zoom - targetZoom) > 0.0005 {
            zoom += (targetZoom - zoom) * min(1, blendRate * dt)
        } else {
            zoom = targetZoom
        }
        if mode == .chase, chaseSpeed > 0 {
            chaseX += chaseSpeed * dt
        }
        switch mode {
        case .lock:
            return (lockPoint, zoom, mode)
        case .chase:
            return (CGPoint(x: chaseX, y: playerY), zoom, mode)
        case .lockY, .follow:
            return (nil, zoom, mode)
        }
    }

    /// A trigger overriding the framing mid-level. This is how a set piece changes
    /// the camera without the level file having to predict where the player will be.
    mutating func override(mode: CameraSpec.Mode, zoom: CGFloat?, speed: CGFloat?,
                          playerX: CGFloat, blend: Double = 0.6) {
        self.mode = mode
        activeZone = nil                      // stop zone resolution fighting it
        if let zoom { targetZoom = max(0.5, min(2.5, zoom)) }
        blendRate = blend > 0.001 ? 1 / CGFloat(blend) : 100
        if mode == .chase {
            chaseSpeed = speed ?? 180
            chaseX = playerX
        }
    }

    mutating func reset() {
        mode = .follow
        activeZone = nil
        targetZoom = max(0.5, min(2.5, spec.zoom))
        chaseSpeed = 0
        chaseX = 0
        lockPoint = nil
    }
}
