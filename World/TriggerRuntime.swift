import SpriteKit

/// Evaluates a level's triggers and reports what fired.
///
/// Deliberately does **not** perform the actions. It answers "which actions should
/// happen this frame", and the scene performs them — the same split as
/// `PlayerMotion`, and for the same reason: firing logic is where the bugs live
/// (double-fires, ordering, sequencing gates) and it is only cheap to pin down if it
/// can be stepped without a scene.
struct TriggerRuntime {

    /// What the runtime needs to know about the frame.
    struct World {
        var playerRect: CGRect = .zero
        var elapsed: Double = 0
        var coins: Int = 0
        var enemiesDefeated: Int = 0
    }

    private let triggers: [TriggerSpec]
    private let rows: Int
    private let tile: CGFloat
    /// Cached rects: recomputing per trigger per frame is pure waste, and a level
    /// can carry dozens.
    private let regions: [CGRect?]
    private var wasInside: [Bool]
    private var fired: Set<String> = []
    private var started = false

    init(triggers: [TriggerSpec], rows: Int, tile: CGFloat = Tuning.tileSize) {
        // Structurally broken triggers are dropped here rather than at the scene, so
        // one bad trigger cannot take a level's other set pieces down with it.
        self.triggers = triggers.filter { $0.structuralProblems.isEmpty }
        self.rows = rows
        self.tile = tile
        regions = self.triggers.map { $0.region?.rect(rows: rows, tile: tile) }
        wasInside = Array(repeating: false, count: self.triggers.count)
    }

    var count: Int { triggers.count }
    var firedNames: [String] { fired.sorted() }

    /// Regions, for the debug overlay and the editor.
    func debugRegions() -> [(name: String, rect: CGRect, fired: Bool)] {
        triggers.indices.compactMap { index in
            guard let rect = regions[index] else { return nil }
            return (triggers[index].name, rect, fired.contains(triggers[index].name))
        }
    }

    /// One frame. Returns the actions to perform, in trigger order then action order —
    /// ordering is defined so a set piece that spawns *then* shakes reads the same
    /// every run.
    mutating func step(world: World) -> [TriggerAction] {
        var out: [TriggerAction] = []
        // `afterTrigger` is resolved against what had fired *before this frame*.
        //
        // Without the snapshot, a chain of triggers sharing a region all fire on the
        // same frame: the first one fires, joins `fired`, and the second's gate is
        // already open by the time the loop reaches it. That makes sequencing mean
        // nothing, which is the opposite of what it is for.
        let firedBefore = fired

        for (index, trigger) in triggers.enumerated() {
            let overlapping = regions[index].map { $0.intersects(world.playerRect) }
                ?? false
            let gateOpen = satisfies(trigger.requires, world: world,
                                     firedBefore: firedBefore)
            // A gated trigger counts as *not entered* until its gate opens.
            //
            // Otherwise walking into the room before clearing it consumes the entry
            // edge, and the door can never open however many enemies you defeat
            // afterwards — the player is inside, so `inside && !wasInside` is false
            // forever.
            let inside = overlapping && gateOpen
            defer { wasInside[index] = inside }

            if trigger.once, fired.contains(trigger.name) { continue }
            guard gateOpen else { continue }

            let hit: Bool
            switch trigger.when {
            case .start:  hit = !started
            case .enter:  hit = inside && !wasInside[index]
            case .exit:   hit = !inside && wasInside[index]
            case .inside: hit = inside
            }
            guard hit else { continue }
            fired.insert(trigger.name)
            out += trigger.actions
        }
        started = true
        return out
    }

    private func satisfies(_ requirement: TriggerSpec.Requirement?, world: World,
                           firedBefore: Set<String>) -> Bool {
        guard let requirement else { return true }
        if let after = requirement.afterSeconds, world.elapsed < after { return false }
        if let coins = requirement.coinsAtLeast, world.coins < coins { return false }
        if let kills = requirement.enemiesDefeated,
           world.enemiesDefeated < kills { return false }
        if let previous = requirement.afterTrigger, !firedBefore.contains(previous) {
            return false
        }
        return true
    }

    /// Death and respawn must re-arm the set pieces, or dying inside a chase leaves
    /// the player in a level whose triggers have all been consumed.
    mutating func reset() {
        fired.removeAll()
        started = false
        for index in wasInside.indices { wasInside[index] = false }
    }
}

/// The advancing lethal wall a `hazardWall` action creates.
///
/// Its own type because it needs per-frame motion, a physics body, and a visual —
/// and because "the chase" is the single most recognisable set piece in the genre, so
/// it deserves to be a first-class thing rather than a special case in the scene.
final class HazardWall: SKNode {

    private let speed: CGFloat
    private let sceneHeight: CGFloat

    init(startX: CGFloat, speed: CGFloat, sceneHeight: CGFloat) {
        self.speed = speed
        self.sceneHeight = sceneHeight
        super.init()
        position = CGPoint(x: startX, y: 0)

        // Visual: a soft leading edge plus a solid body. The gradient is what makes
        // it read as *coming* rather than as a wall that happens to be there.
        let body = SKSpriteNode(color: SKColor(red: 0.55, green: 0.10, blue: 0.18,
                                              alpha: 0.92),
                               size: CGSize(width: 900, height: sceneHeight * 2))
        body.anchorPoint = CGPoint(x: 1, y: 0.5)
        body.position = CGPoint(x: 0, y: sceneHeight / 2)
        addChild(body)

        let edge = SKSpriteNode(color: SKColor(red: 1.0, green: 0.45, blue: 0.25,
                                              alpha: 0.85),
                                size: CGSize(width: 26, height: sceneHeight * 2))
        edge.anchorPoint = CGPoint(x: 1, y: 0.5)
        edge.position = CGPoint(x: 12, y: sceneHeight / 2)
        edge.blendMode = .add
        addChild(edge)
        edge.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.5, duration: 0.28),
            .fadeAlpha(to: 0.9, duration: 0.28),
        ])))

        // A thin sensor at the leading edge, not a body the width of the wall: the
        // wall is 900pt wide for looks, and a hazard body that size would kill the
        // player from off-screen.
        let sensor = SKPhysicsBody(rectangleOf: CGSize(width: 20,
                                                       height: sceneHeight * 2),
                                   center: CGPoint(x: -10, y: sceneHeight / 2))
        sensor.isDynamic = false
        sensor.categoryBitMask = PhysicsCategory.hazard
        sensor.contactTestBitMask = PhysicsCategory.player
        sensor.collisionBitMask = 0
        physicsBody = sensor
        zPosition = 120
        name = "hazardWall"
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(dt: CGFloat) {
        position.x += speed * dt
    }
}
