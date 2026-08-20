import SpriteKit

final class GameScene: SKScene, SKPhysicsContactDelegate {

    // MARK: - Setup

    private let levelIndex: Int
    private var levelMap: [[Character]] = []
    private var levelWidth: CGFloat = 0
    private var levelHeight: CGFloat = 0

    private let player: PlayerRig = PlayerRigFactory.make()
    private var spawnPoint = CGPoint.zero
    private let cam = SKCameraNode()
    private var parallax: ParallaxController?
    private var frieze: FriezeStage?
    /// Kept so level-authored decor can be handed to the stage with the same haze
    /// and focus settings the image layers use.
    private var friezeScene: FriezeScene?
    /// The post chain. Holds the world and the backdrop; the HUD stays outside it
    /// so the interface isn't vignetted and bloomed along with the art.
    private var post: PostProcess?
    /// Built from the session overrides, so a scripted `setTimeOfDay` survives
    /// the rebuild that level edits force.
    private let lighting = LightingRig(overrides: .shared)
    private var hotReloader: HotReloader?
    /// The machine surface: applies `Documents/engine.json`, answers into
    /// `Documents/EngineOut/`.
    private var bridge: EngineBridge?
    private let overrides = EngineOverrides.shared

    private var lives = Tuning.startingLives
    private var coinsThisRun = 0
    private var isGameOver = false
    private var levelFinished = false

    // Input / animation state
    private var moveInput: CGFloat = 0
    private var jumpHeld = false
    private var lastGroundedTime: TimeInterval = -1
    private var jumpRequestedTime: TimeInterval = -1
    private var currentTimeCache: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0
    private var wasGrounded = false
    private var shakeTime: CGFloat = 0
    private var touchOwners: [UITouch: String] = [:]

    // Combat state
    private var punchReadyTime: TimeInterval = 0
    private var pounding = false
    private var poundHangUntil: TimeInterval = 0
    /// Where the pound began, so the impact can be tested as a swept segment.
    private var poundStart = CGPoint.zero
    /// A punch stays "open" for the length of the swing, because with deformed
    /// collision the fist is not where the character is — it arrives.
    private var punchOpenUntil: TimeInterval = -1
    private var punchResolved = true
    /// Hazards and enemies whose box touched us but whose art did not. Re-tested
    /// each frame: SpriteKit fires `didBegin` once, so a graze that later becomes
    /// a real hit would otherwise never be noticed.
    private var grazing: [SKNode] = []
    /// Direction of the last connecting blow, from the collision contact — used
    /// to throw effects away from the impact rather than out of a centre point.
    private var lastHitNormal = CGVector(dx: 1, dy: 0)

    // Wall movement state
    private var wallDir: CGFloat = 0
    private var lastWallTime: TimeInterval = -10
    private var inputLockUntil: TimeInterval = -10
    private var lockDir: CGFloat = 0
    private var wallDustTimer: CGFloat = 0

    // Combo
    private var comboCount = 0
    private var lastCoinTime: TimeInterval = -10

    // HUD
    private let coinLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private let livesLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")

    // World actors
    private var enemies: [Enemy] = []
    private var villagers: [Villager] = []
    private var birds: [Bird] = []
    private var coins: [SKNode] = []
    private var crates: [SKNode] = []
    private var oneWays: [SKNode] = []
    private var boss: Boss?
    private var bossPortalPoint = CGPoint.zero
    private struct Mover { let node: SKNode; let baseX: CGFloat; var lastX: CGFloat }
    private var movers: [Mover] = []
    private var elapsed: TimeInterval = 0

    // Interactables
    private var crushers: [Interactable.Crusher] = []
    private var springs: [SKNode] = []
    private var conveyors: [(node: SKNode, direction: CGFloat)] = []
    private var climbables: [SKNode] = []
    private var updrafts: [SKNode] = []
    private var checkpoints: [SKNode] = []

    /// Movement abilities: dash, climb, ledge grab, slope projection. Kept as a
    /// value type so the feel of the game can be tested without a device.
    private var motion = PlayerMotion()
    /// Where a death sends you back to — the spawn until a checkpoint is claimed.
    private var respawnPoint = CGPoint.zero
    /// Edge detection for the dash sound: `isDashing` is true for the whole dash,
    /// so playing on the state would retrigger every frame.
    private var wasDashing = false
    /// Next time the hover rotor loop needs retriggering.
    private var hoverSoundUntil: TimeInterval = 0
    /// Set pieces. Evaluated every frame, performed here.
    private var triggerRuntime: TriggerRuntime?
    /// Authored framing: zones, zoom, locks, chase.
    private var director: CameraDirector?
    private var hazardWalls: [HazardWall] = []
    private var enemiesDefeated = 0
    /// Retuning from a `tuning` action, so respawn can put it back.
    private var tuningTouched = false
    /// Band streaming: what makes a 500-tile level cost the same as a 50-tile one.
    private var streamer: LevelStreamer?
    /// Data-driven effects. Pooled and capped, so effect density costs nothing extra.
    private var fx: ParticleLibrary?
#if DEBUG
    /// In-engine editing. DEBUG only: it is a development tool, and a release binary
    /// should not carry it or pay for it.
    private var editor: EditorOverlay?
    private var editorPanAnchor: CGPoint?
#endif
    private var verticalInput: CGFloat = 0
    private var dashRequested = false
    /// Light culling and backdrop retinting run a few times a second, not every
    /// frame — neither changes fast enough to be worth per-frame cost.
    private var lightCullTimer: CGFloat = 0

    /// Hulls converted into scene space, cached for the frame that built them.
    ///
    /// Combat, graze re-testing and contact confirmation all want the same
    /// regions in the same frame, and each conversion walks every hull point
    /// through `SKNode.convert`. Caching by frame keeps the deformed path at one
    /// conversion per frame instead of three, and the cache can never go stale:
    /// it is discarded the moment the frame number changes.
    private var hullCache: [[CGPoint]] = []
    private var hullCacheFrame: Int = -1
    private var frameNumber = 0

    private func playerHitRegions() -> [[CGPoint]] {
        if hullCacheFrame == frameNumber { return hullCache }
        hullCache = player.hitRegions(in: self)
        hullCacheFrame = frameNumber
        return hullCache
    }

    init(levelIndex: Int) {
        self.levelIndex = levelIndex
        super.init(size: Tuning.sceneSize)
        scaleMode = .aspectFill
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        backgroundColor = SKColor(red: 0.45, green: 0.72, blue: 0.98, alpha: 1)
        // Overrides shadow `Tuning` rather than replacing it: whatever a script
        // or the AI set is in force here, and `reset` puts the shipped numbers
        // back without a relaunch.
        overrides.currentLevelIndex = levelIndex
        overrides.levelTimeOfDay = LevelLibrary.timeOfDay(at: levelIndex)
        // The level's own track. `playMusic` ignores a repeat of what is already
        // playing, so re-entering a level does not restart the soundtrack.
        Audio.shared.playMusic(LevelLibrary.music(at: levelIndex))
        physicsWorld.gravity = CGVector(dx: 0, dy: overrides.effectiveGravity)
        physicsWorld.contactDelegate = self

        buildLevel()
        setupPlayer()
        setupCamera()
        setupHUD()
        setupControls()
        spawnButterflies()
        setupLighting()
        guard setupEngineAPI(view: view) else { return }
        setupHotReload()
    }

    /// Normal-mapped lighting: key + rim on the camera, normals generated from
    /// each sprite's own art and cached. Done once at scene build.
    private func setupLighting() {
        lighting.install(on: cam, sceneSize: size)
        // Direction before drift: `animate` adds a small wander on top of
        // whatever the time of day set, so the order matters.
        lighting.orient(timeOfDay: overrides.timeOfDay ?? overrides.levelTimeOfDay
                                   ?? DayCycle.defaultTime,
                        sceneSize: size)
        lighting.animate()
        // Local lights on the things that glow, then culled to the nearest few.
        for coin in coins.prefix(24) {
            lighting.addPointLight(at: .zero,
                                   color: SKColor(red: 1.0, green: 0.86, blue: 0.3,
                                                  alpha: 1),
                                   falloff: 3.2, on: coin)
        }
        for spring in springs {
            lighting.addFlickerLight(at: CGPoint(x: 0, y: 6),
                                     color: SKColor(red: 1.0, green: 0.75, blue: 0.25,
                                                    alpha: 1),
                                     falloff: 2.8, on: spring)
        }
        // Gameplay layer: lit and casting.
        // Terrain and world furniture *receive* shadows; the actors that move over it
        // *cast* them. Giving one sprite both roles makes it shadow itself, which reads
        // as dirt rather than as depth — see `NormalMapper.ShadowRole`.
        for node in children where node !== cam {
            NormalMapper.applyRecursively(from: node, shadows: .receiver)
        }
        // The player is the primary caster: it is the thing whose shadow the player
        // is actually looking for.
        NormalMapper.applyRecursively(from: player, shadows: .caster)
        // The rig re-lights its own slots afterwards: it knows each slot's image
        // name, so a hand-authored `<image>_n` map wins over a generated one.
        player.applyRigLighting()
        buildFrises()
        installPostProcess()
        // Set pieces and framing, both from the level file. Built last so a trigger
        // that moves a named node can find it.
        let rows = overrides.rows(forLevel: levelIndex)?.count ?? levelMap.count
        triggerRuntime = TriggerRuntime(triggers: LevelLibrary.triggers(at: levelIndex),
                                        rows: rows)
        director = CameraDirector(spec: LevelLibrary.camera(at: levelIndex),
                                  tile: Tuning.tileSize)
        // Effects attach to the post chain so they are graded and bloomed with the
        // rest of the frame — an additive spark outside the chain reads as a decal.
        fx = ParticleLibrary(host: post ?? self)
        installStreaming()
        // Backdrop: lit only — distant layers casting shadows looks wrong.
        if let frieze {
            NormalMapper.applyRecursively(from: frieze,
                                          categories: LightCategory.key,
                                          shadows: .receiver, contrast: 1.1)
        }
    }

    private func setupHotReload() {
        #if DEBUG
        guard let docs = HotReloader.documentsURL else { return }
        hotReloader = HotReloader(directory: docs) { [weak self] in
            guard let self else { return }
            // A command document may be what changed. Apply it *before*
            // rebuilding, so the new scene is built from the new overrides —
            // and only rebuild for asset edits or commands that need it.
            if let receipt = self.bridge?.poll(), !receipt.needsReload {
                self.bridge?.publish()
            } else {
                self.requestReload()
            }
        }
        #endif
    }

    /// Bring the machine surface up: apply anything already waiting in the
    /// inbox, hand the session's collider settings to the actors that just
    /// spawned, and publish the world for whoever is driving.
    ///
    /// Returns false when the scene is being replaced, so `didMove` stops
    /// setting up a scene that is already on its way out.
    @discardableResult
    private func setupEngineAPI(view: SKView) -> Bool {
        let bridge = EngineBridge(scene: self)
        self.bridge = bridge
        player.setColliderMode(overrides.colliderMode, slots: overrides.colliderSlots)
        player.setColliderDebugDraw(overrides.showColliders)
        view.showsPhysics = overrides.showColliders

        if let receipt = bridge.poll(), receipt.needsReload {
            requestReload()
            return false
        }
        bridge.publish()
        return true
    }

    /// Rebuild this level with the current overrides.
    ///
    /// Deferred by one turn of the run loop: presenting a scene from inside
    /// `didMove` or a file-system callback runs while SpriteKit is mid-frame.
    /// The normal-map cache is keyed by texture identity, and a rebuild paints
    /// fresh textures, so it is dropped here rather than left to grow.
    private func requestReload() {
        guard let view else { return }
        let index = levelIndex
        DispatchQueue.main.async {
            NormalMapper.clearCache()
            view.presentScene(GameScene(levelIndex: index))
        }
    }

    // MARK: - Level construction

    private func buildLevel() {
        // Rows come from the override table, which falls back to the compiled
        // `Levels` — so an edited or generated map builds through exactly the
        // same path as a shipped one. Defensive: a bad index or malformed map
        // must not crash the app.
        guard let raw = overrides.rows(forLevel: levelIndex) else { return }
        let maxLen = raw.map(\.count).max() ?? 0
        guard !raw.isEmpty, maxLen > 0 else { return }
        levelMap = raw.map { row -> [Character] in
            var chars = Array(row)
            while chars.count < maxLen { chars.append(".") }
            return chars
        }

        let t = Tuning.tileSize
        let rows = levelMap.count
        let cols = maxLen
        levelWidth = CGFloat(cols) * t
        levelHeight = CGFloat(rows) * t

        func center(col: Int, row: Int) -> CGPoint {
            CGPoint(x: (CGFloat(col) + 0.5) * t,
                    y: (CGFloat(rows - 1 - row) + 0.5) * t)
        }

        var crystalIndex = 0
        for row in 0..<rows {
            var col = 0
            while col < cols {
                let ch = levelMap[row][col]
                switch ch {
                case "X":
                    let start = col
                    while col < cols, levelMap[row][col] == "X" { col += 1 }
                    let runLen = col - start
                    let node = Decor.ground(size: CGSize(width: CGFloat(runLen) * t, height: t))
                    let left = center(col: start, row: row)
                    node.position = CGPoint(x: left.x + CGFloat(runLen - 1) * t / 2, y: left.y)
                    node.physicsBody = SKPhysicsBody(rectangleOf: node.size)
                    node.physicsBody?.isDynamic = false
                    node.physicsBody?.friction = 0
                    node.physicsBody?.restitution = 0
                    node.physicsBody?.categoryBitMask = PhysicsCategory.ground
                    addChild(node)
                    continue
                case "P":
                    // One-way pads also merge into runs
                    let start = col
                    while col < cols, levelMap[row][col] == "P" { col += 1 }
                    let runLen = col - start
                    let size = CGSize(width: CGFloat(runLen) * t, height: 12)
                    let pad = Decor.oneWayPad(size: size)
                    let left = center(col: start, row: row)
                    pad.position = CGPoint(x: left.x + CGFloat(runLen - 1) * t / 2, y: left.y)
                    pad.physicsBody = SKPhysicsBody(rectangleOf: size)
                    pad.physicsBody?.isDynamic = false
                    pad.physicsBody?.friction = 0
                    pad.physicsBody?.restitution = 0
                    pad.physicsBody?.categoryBitMask = PhysicsCategory.none // toggled per frame
                    addChild(pad)
                    oneWays.append(pad)
                    continue
                case "C":
                    let coin = Decor.coin()
                    coin.position = center(col: col, row: row)
                    coin.name = "coin.\(coins.count)"
                    coin.physicsBody = SKPhysicsBody(circleOfRadius: 10)
                    coin.physicsBody?.isDynamic = false
                    coin.physicsBody?.categoryBitMask = PhysicsCategory.coin
                    coin.physicsBody?.collisionBitMask = PhysicsCategory.none
                    addChild(coin)
                    coins.append(coin)
                case "E":
                    let (minX, maxX) = patrolBounds(col: col, row: row, tile: t, rows: rows)
                    let enemy = Enemy(position: center(col: col, row: row),
                                      minX: minX, maxX: maxX,
                                      behaviour: LevelLibrary.enemyBehaviour(at: levelIndex))
                    enemy.node.name = "enemy.\(enemies.count)"
                    addChild(enemy.node)
                    enemies.append(enemy)
                case "N":
                    let v = Villager(position: center(col: col, row: row))
                    v.node.name = "villager.\(villagers.count)"
                    addChild(v.node)
                    villagers.append(v)
                case "B":
                    let b = Bird(position: center(col: col, row: row))
                    b.node.name = "bird.\(birds.count)"
                    addChild(b.node)
                    birds.append(b)
                case "D":
                    let crate = Decor.crate(tile: t)
                    crate.position = center(col: col, row: row)
                    crate.name = "crate.\(crates.count)"
                    crate.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: t * 0.9, height: t * 0.9))
                    crate.physicsBody?.isDynamic = false
                    crate.physicsBody?.friction = 0
                    crate.physicsBody?.restitution = 0
                    crate.physicsBody?.categoryBitMask = PhysicsCategory.ground
                    addChild(crate)
                    crates.append(crate)
                case "K":
                    let b = Boss(position: center(col: col, row: row))
                    b.node.name = "boss"
                    addChild(b.node)
                    boss = b
                    bossPortalPoint = center(col: max(0, cols - 5), row: row)
                case "/", "\\":
                    let ramp = Interactable.slope(tile: t, risingRight: ch == "/")
                    ramp.position = center(col: col, row: row)
                    ramp.name = "slope.\(col).\(row)"
                    addChild(ramp)
                case ">", "<":
                    // Conveyors merge into runs like ground does, so a belt of
                    // any length is one body and one carry value.
                    let start = col
                    while col < cols, levelMap[row][col] == ch { col += 1 }
                    let runLen = col - start
                    let size = CGSize(width: CGFloat(runLen) * t, height: t)
                    let belt = Interactable.conveyor(size: size, rightward: ch == ">")
                    let left = center(col: start, row: row)
                    belt.position = CGPoint(x: left.x + CGFloat(runLen - 1) * t / 2,
                                            y: left.y)
                    belt.name = "conveyor.\(conveyors.count)"
                    addChild(belt)
                    conveyors.append((belt, ch == ">" ? 1 : -1))
                    continue
                case "!":
                    let spring = Interactable.spring(tile: t)
                    spring.position = center(col: col, row: row)
                    spring.name = "spring.\(springs.count)"
                    addChild(spring)
                    springs.append(spring)
                case "L":
                    let vine = Interactable.vine(tile: t, index: climbables.count)
                    vine.position = center(col: col, row: row)
                    vine.name = "vine.\(climbables.count)"
                    vine.zPosition = 5
                    addChild(vine)
                    climbables.append(vine)
                case "~":
                    let column = Interactable.updraft(tile: t)
                    column.position = center(col: col, row: row)
                    column.name = "updraft.\(updrafts.count)"
                    column.zPosition = 6
                    addChild(column)
                    updrafts.append(column)
                case "@":
                    let flag = Interactable.checkpoint(tile: t)
                    flag.position = center(col: col, row: row)
                    flag.name = "checkpoint.\(checkpoints.count)"
                    addChild(flag)
                    checkpoints.append(flag)
                case "#":
                    // Find the floor beneath so the crusher knows how far to
                    // travel, rather than guessing a fixed distance.
                    var floorRow = row + 1
                    while floorRow < rows, !"XDMP/\\><!".contains(levelMap[floorRow][col]) {
                        floorRow += 1
                    }
                    let floorY = center(col: col, row: min(floorRow, rows - 1)).y
                    let crusher = Interactable.Crusher(
                        position: center(col: col, row: row), tile: t, floorY: floorY,
                        phaseOffset: Double(crushers.count) * 0.55)
                    crusher.node.name = "crusher.\(crushers.count)"
                    addChild(crusher.node)
                    crushers.append(crusher)
                case "M":
                    let size = CGSize(width: 84, height: 20)
                    let node = Decor.movingPlatform(size: size)
                    node.position = center(col: col, row: row)
                    node.name = "mover.\(movers.count)"
                    node.physicsBody = SKPhysicsBody(rectangleOf: size)
                    node.physicsBody?.isDynamic = false
                    node.physicsBody?.friction = 0
                    node.physicsBody?.restitution = 0
                    node.physicsBody?.categoryBitMask = PhysicsCategory.ground
                    addChild(node)
                    movers.append(Mover(node: node, baseX: node.position.x, lastX: node.position.x))
                case "^":
                    let shard = Decor.crystal(tile: t, index: crystalIndex)
                    crystalIndex += 1
                    shard.position = center(col: col, row: row)
                    shard.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: t * 0.8, height: t * 0.6),
                                                      center: CGPoint(x: 0, y: -t * 0.15))
                    shard.physicsBody?.isDynamic = false
                    shard.physicsBody?.categoryBitMask = PhysicsCategory.hazard
                    shard.physicsBody?.collisionBitMask = PhysicsCategory.none
                    addChild(shard)
                case "F":
                    spawnPortal(at: {
                        var p = center(col: col, row: row); p.y += t * 0.3; return p
                    }())
                case "S":
                    spawnPoint = center(col: col, row: row)
                default:
                    break
                }
                col += 1
            }
        }

        // A map with no 'S' would drop the player through the world; fall back
        // to standing on the first tile of the bottom row.
        if spawnPoint == .zero {
            spawnPoint = CGPoint(x: t * 1.5, y: t * 1.5)
        }
    }

    private func spawnPortal(at position: CGPoint) {
        let portal = Decor.portal(tile: Tuning.tileSize)
        portal.position = position
        portal.name = "portal"
        portal.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 34, height: Tuning.tileSize * 2))
        portal.physicsBody?.isDynamic = false
        portal.physicsBody?.categoryBitMask = PhysicsCategory.finish
        portal.physicsBody?.collisionBitMask = PhysicsCategory.none
        addChild(portal)
    }

    private func patrolBounds(col: Int, row: Int, tile t: CGFloat, rows: Int) -> (CGFloat, CGFloat) {
        let below = row + 1
        guard below < rows else { return (0, levelWidth) }
        var lo = col, hi = col
        while lo - 1 >= 0, levelMap[below][lo - 1] == "X" { lo -= 1 }
        while hi + 1 < levelMap[below].count, levelMap[below][hi + 1] == "X" { hi += 1 }
        let margin = t * 0.4
        return ((CGFloat(lo) * t) + margin, (CGFloat(hi + 1) * t) - margin)
    }

    private func spawnButterflies() {
        // Narrow levels would otherwise form an invalid Range and trap.
        let lo: CGFloat = 60
        let hi = max(lo + 1, levelWidth - 60)
        for _ in 0..<3 {
            let b = Butterfly.spawn(at: CGPoint(x: CGFloat.random(in: lo...hi),
                                                y: CGFloat.random(in: 150...260)))
            addChild(b)
        }
    }

    private func setupPlayer() {
        respawnPoint = spawnPoint
        player.position = spawnPoint
        player.zPosition = 10
        // The API addresses actors by node name.
        player.name = "player"
        let body = SKPhysicsBody(rectangleOf: CGSize(width: 26, height: 34))
        body.allowsRotation = false
        body.friction = 0
        body.restitution = 0
        body.linearDamping = 0
        body.usesPreciseCollisionDetection = true   // ground pound is FAST
        body.categoryBitMask = PhysicsCategory.player
        body.collisionBitMask = PhysicsCategory.ground
        body.collisionBitMask = PhysicsCategory.standable
        body.contactTestBitMask = PhysicsCategory.coin | PhysicsCategory.enemy
            | PhysicsCategory.hazard | PhysicsCategory.finish
            | PhysicsCategory.checkpoint | PhysicsCategory.ground
        player.physicsBody = body
        addChild(player)
    }

    private func setupCamera() {
        camera = cam
        cam.position = clampCamera(to: player.position)
        addChild(cam)
        // FriezeKit backdrop (hi-res painted layers) when bundled;
        // procedural parallax otherwise — the game always has a background.
        // `loadFrieze` swaps which scene is asked for.
        // Explicit `loadFrieze` wins, then whatever this level's file asked
        // for, then the shipped default. Before the level format existed every
        // level in the game necessarily looked like the same place.
        let backdrop = overrides.friezeOverride
            ?? LevelLibrary.frieze(at: levelIndex)
            ?? "forest_backdrop"
        friezeScene = FriezeScene.load(named: backdrop)
        if let stage = FriezeStage.load(named: backdrop, sceneSize: size) {
            // Scene space, not camera space: the post node has to contain the
            // backdrop (bloom on the backlight is most of the visual win) and it
            // cannot contain the camera. `FriezeStage` was already driven by
            // explicit `camX`/`camY`, so it only needs its root synced.
            addChild(stage)
            frieze = stage
        } else {
            parallax = ParallaxController(camera: cam, sceneSize: size)
        }
    }

    // MARK: - HUD & controls

    private func setupHUD() {
        let hudCoin = SKShapeNode(circleOfRadius: 9)
        hudCoin.fillColor = SKColor(red: 1.0, green: 0.80, blue: 0.12, alpha: 1)
        hudCoin.strokeColor = SKColor(red: 0.85, green: 0.55, blue: 0.02, alpha: 1)
        hudCoin.lineWidth = 2
        hudCoin.position = CGPoint(x: -size.width / 2 + 30, y: size.height / 2 - 32)
        hudCoin.zPosition = 200
        cam.addChild(hudCoin)

        coinLabel.fontSize = 21
        coinLabel.fontColor = .white
        coinLabel.horizontalAlignmentMode = .left
        coinLabel.verticalAlignmentMode = .center
        coinLabel.position = CGPoint(x: -size.width / 2 + 46, y: size.height / 2 - 32)
        coinLabel.zPosition = 200
        cam.addChild(coinLabel)

#if DEBUG
        // A way in without the bridge. DEBUG only, and deliberately small and dim: it
        // is a development affordance, not part of the game's interface.
        let editButton = SKShapeNode(rectOf: CGSize(width: 30, height: 24),
                                     cornerRadius: 6)
        editButton.position = CGPoint(x: size.width / 2 - 26, y: -size.height / 2 + 24)
        editButton.fillColor = SKColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 0.7)
        editButton.strokeColor = SKColor(white: 1, alpha: 0.25)
        editButton.name = "hud.edit"
        let editLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        editLabel.text = "✎"
        editLabel.fontSize = 14
        editLabel.verticalAlignmentMode = .center
        editLabel.name = "hud.edit"
        editButton.addChild(editLabel)
        cam.addChild(editButton)
#endif

        livesLabel.fontSize = 21
        livesLabel.fontColor = SKColor(red: 1.0, green: 0.35, blue: 0.40, alpha: 1)
        livesLabel.horizontalAlignmentMode = .right
        livesLabel.verticalAlignmentMode = .center
        livesLabel.position = CGPoint(x: size.width / 2 - 26, y: size.height / 2 - 32)
        livesLabel.zPosition = 200
        cam.addChild(livesLabel)

        refreshHUD()
    }

    private func refreshHUD() {
        coinLabel.text = "\(coinsThisRun)"
        livesLabel.text = String(repeating: "♥", count: max(0, lives))
    }

    private func makeButton(name: String, label: String, at pos: CGPoint, radius: CGFloat = 34) -> SKNode {
        let bg = SKShapeNode(circleOfRadius: radius)
        bg.fillColor = SKColor(white: 0, alpha: 0.28)
        bg.strokeColor = SKColor(white: 1, alpha: 0.55)
        bg.lineWidth = 2.5
        bg.position = pos
        bg.name = name
        bg.zPosition = 200
        let l = SKLabelNode(fontNamed: "AvenirNext-Bold")
        l.text = label
        l.fontSize = radius * 0.76
        l.verticalAlignmentMode = .center
        l.name = name
        bg.addChild(l)
        return bg
    }

    private func setupControls() {
        cam.addChild(makeButton(name: "btnLeft", label: "◀",
                                at: CGPoint(x: -size.width / 2 + 60, y: -size.height / 2 + 60)))
        cam.addChild(makeButton(name: "btnRight", label: "▶",
                                at: CGPoint(x: -size.width / 2 + 150, y: -size.height / 2 + 60)))
        cam.addChild(makeButton(name: "btnJump", label: "▲",
                                at: CGPoint(x: size.width / 2 - 60, y: -size.height / 2 + 60)))
        // Action: punch on the ground, ground pound in the air
        cam.addChild(makeButton(name: "btnAction", label: "●",
                                at: CGPoint(x: size.width / 2 - 145, y: -size.height / 2 + 52), radius: 28))
        cam.addChild(makeButton(name: "btnDash", label: "»",
                                at: CGPoint(x: size.width / 2 - 138, y: -size.height / 2 + 118),
                                radius: 26))
        // Climb steering: only meaningful on a vine, so it sits out of the way.
        cam.addChild(makeButton(name: "btnUp", label: "▲",
                                at: CGPoint(x: -size.width / 2 + 105, y: -size.height / 2 + 124),
                                radius: 22))
        cam.addChild(makeButton(name: "btnDown", label: "▼",
                                at: CGPoint(x: -size.width / 2 + 105, y: -size.height / 2 + 74),
                                radius: 22))
    }

    // MARK: - Touch handling

    private func controlName(at location: CGPoint) -> String? {
        for node in nodes(at: location) {
            guard let n = node.name else { continue }
            if n.hasPrefix("btn") || n.hasPrefix("ui.") { return n }
#if DEBUG
            if n == "hud.edit" { return n }
#endif
        }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
#if DEBUG
        if let editor, let touch = touches.first {
            // The overlay is a camera child, so chrome is hit-tested in camera space
            // and painting resolves in scene space. Passing both avoids the overlay
            // needing to know about the camera at all.
            _ = editor.handleTouch(cameraPoint: touch.location(in: cam),
                                   scenePoint: touch.location(in: self),
                                   phase: .began)
            return
        }
#endif
        for touch in touches {
            guard let name = controlName(at: touch.location(in: self)) else { continue }
            touchOwners[touch] = name
            handlePress(name)
        }
    }

#if DEBUG
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let editor, let touch = touches.first else { return }
        _ = editor.handleTouch(cameraPoint: touch.location(in: cam),
                               scenePoint: touch.location(in: self), phase: .moved)
    }
#endif

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
#if DEBUG
        if let editor, let touch = touches.first {
            _ = editor.handleTouch(cameraPoint: touch.location(in: cam),
                                   scenePoint: touch.location(in: self), phase: .ended)
            return
        }
#endif
        for touch in touches {
            if let name = touchOwners.removeValue(forKey: touch) { handleRelease(name) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func handlePress(_ name: String) {
#if DEBUG
        if name == "hud.edit" {
            toggleEditor()
            return
        }
#endif
        switch name {
        case "btnLeft":  moveInput = -1
        case "btnRight": moveInput = 1
        case "btnJump":
            jumpHeld = true
            jumpRequestedTime = currentTimeCache
        case "btnAction":
            if wasGrounded { punch() } else { startPound() }
        case "btnDash":
            dashRequested = true
        case "btnUp":   verticalInput = 1
        case "btnDown": verticalInput = -1
        case "ui.retry": restartLevel()
        case "ui.revive": tryRevive()
        case "ui.next": goToNextLevel()
        case "ui.menu": goToMenu()
        default: break
        }
    }

    private func handleRelease(_ name: String) {
        switch name {
        case "btnLeft":  if moveInput == -1 { moveInput = 0 }
        case "btnRight": if moveInput == 1 { moveInput = 0 }
        case "btnJump":
            jumpHeld = false
            if let body = player.physicsBody, body.velocity.dy > 120, !pounding,
               !motion.suspendsGravity {
                body.velocity.dy *= Tuning.jumpCutMultiplier   // variable jump height
            }
        case "btnUp":   if verticalInput == 1 { verticalInput = 0 }
        case "btnDown": if verticalInput == -1 { verticalInput = 0 }
        default: break
        }
    }

    // MARK: - Combat

    /// Open a punch. Resolution happens in `update` for as long as the swing
    /// lasts, because with deformed-mesh collision the fist is not where the
    /// character is — it travels, and it connects when the *drawn* hand reaches
    /// something. In `.box` collider mode there is no hull to test and the first
    /// update resolves it by range, exactly as before.
    private func punch() {
        guard currentTimeCache >= punchReadyTime, !isGameOver, !levelFinished else { return }
        punchReadyTime = currentTimeCache + Tuning.punchCooldown
        player.playPunch()
        punchOpenUntil = currentTimeCache + Tuning.punchCooldown * 0.6
        punchResolved = false
    }

    /// One hit per swing, nearest first. Returns true once something is struck.
    @discardableResult
    private func resolvePunch() -> Bool {
        let facing = player.facing
        // The fist's own convex hull, in scene space, if the rig exposes one.
        let fist = player.attackRegion(in: self)

        func connects(_ position: CGPoint, size: CGSize,
                      extra: CGFloat = 0, vTol: CGFloat = 44) -> Bool {
            if let fist {
                let box = CGRect(x: position.x - size.width / 2,
                                 y: position.y - size.height / 2,
                                 width: size.width, height: size.height)
                // Contact rather than overlap: the normal tells us which way the
                // hit landed, so the burst throws away from the fist instead of
                // puffing symmetrically out of a centre point.
                guard let hit = Geometry2D.contact(fist, Geometry2D.polygon(of: box))
                else { return false }
                lastHitNormal = hit.normal
                return true
            }
            let dx = (position.x - player.position.x) * facing
            return dx > 4 && dx < Tuning.punchRange + extra
                && abs(position.y - player.position.y) < vTol
        }

        for enemy in enemies where connects(enemy.node.position,
                                            size: CGSize(width: 30, height: 26)) {
            popEnemy(enemy.node)
            return true
        }
        let crateSide = Tuning.tileSize * 0.9
        for crate in crates where connects(crate.position,
                                           size: CGSize(width: crateSide, height: crateSide)) {
            breakCrate(crate)
            return true
        }
        if let boss, !boss.isDead,
           connects(boss.node.position, size: CGSize(width: 76, height: 62),
                    extra: 24, vTol: 62) {
            damageBoss()
            return true
        }
        return false
    }

    private func startPound() {
        guard !pounding, !isGameOver, !levelFinished else { return }
        pounding = true
        poundStart = player.position
        poundHangUntil = currentTimeCache + Tuning.poundHangTime
    }

    private func poundImpact() {
        pounding = false
        shakeTime = 0.28
        Audio.shared.play("pound", on: self)
        Effects.dust(at: CGPoint(x: player.position.x, y: player.position.y - 18), in: self)
        Effects.burst(at: CGPoint(x: player.position.x, y: player.position.y - 16), in: self,
                      color: SKColor(white: 1, alpha: 0.9), count: 12, speed: 200)

        // Swept, not sampled: a pound falls 25pt per frame, and a discrete
        // radius check at the impact frame misses anything it passed through on
        // the way down.
        for enemy in enemies {
            let d = Geometry2D.distance(from: enemy.node.position,
                                        toSegment: poundStart, player.position)
            if d < Tuning.poundKillRadius {
                lastHitNormal = CGVector(dx: 0, dy: -1)
                popEnemy(enemy.node)
            }
        }
        for crate in crates {
            let d = hypot(crate.position.x - player.position.x,
                          crate.position.y - player.position.y)
            if d < Tuning.poundKillRadius { breakCrate(crate) }
        }
        if let boss, !boss.isDead,
           abs(boss.node.position.x - player.position.x) < Tuning.poundKillRadius + 30,
           abs(boss.node.position.y - player.position.y) < 80 {
            damageBoss()
        }
    }

    private func popEnemy(_ node: SKNode) {
        emit("punch", at: node.position)
        // Let a graph-driven enemy know, so `hurt` transitions fire before it dies —
        // a stagger state is only reachable if the hit is reported.
        for enemy in enemies where enemy.node === node { enemy.registerHit() }
        // Counted so a trigger can gate on it — "the door opens when the room is
        // clear" is one of the two or three most useful set pieces there is.
        enemiesDefeated += 1
        let origin = CGPoint(x: node.position.x + lastHitNormal.dx * 8,
                             y: node.position.y + lastHitNormal.dy * 8)
        Effects.burst(at: origin, in: self,
                      color: SKColor(red: 0.62, green: 0.35, blue: 0.95, alpha: 1), count: 18)
        Audio.shared.play("pop", on: self)
        enemies.removeAll { $0.node === node }
        node.removeFromParent()
        coinsThisRun += 2
        Effects.floatText("+2", at: node.position, in: self)
        refreshHUD()
    }

    private func breakCrate(_ crate: SKNode) {
        Effects.burst(at: crate.position, in: self,
                      color: SKColor(red: 0.80, green: 0.58, blue: 0.30, alpha: 1), count: 14, speed: 130)
        Audio.shared.play("pop", on: self)
        crates.removeAll { $0 === crate }
        crate.removeFromParent()
        coinsThisRun += 1
        Effects.floatText("+1", at: crate.position, in: self)
        refreshHUD()
    }

    private func damageBoss() {
        guard let boss, boss.isVulnerable else { return }
        let died = boss.hit(now: currentTimeCache)
        Effects.burst(at: boss.node.position, in: self,
                      color: SKColor(red: 0.62, green: 0.35, blue: 0.95, alpha: 1), count: 22, speed: 200)
        Effects.floatText("HIT!", at: CGPoint(x: boss.node.position.x, y: boss.node.position.y + 44),
                          in: self, color: SKColor(red: 1.0, green: 0.4, blue: 0.35, alpha: 1))
        Audio.shared.play("stomp", on: self)
        emit("stomp", at: player.position)
        shakeTime = 0.18
        if died { bossDefeated() }
    }

    private func bossDefeated() {
        Audio.shared.play("win", on: self)
        emit("goal", at: player.position)
        coinsThisRun += 10
        refreshHUD()
        if let boss {
            Effects.floatText("+10  KO!", at: CGPoint(x: boss.node.position.x,
                                                      y: boss.node.position.y + 60), in: self)
            for i in 0..<3 {
                run(.sequence([.wait(forDuration: Double(i) * 0.2), .run { [weak self] in
                    guard let self else { return }
                    Effects.burst(at: CGPoint(x: boss.node.position.x + CGFloat.random(in: -40...40),
                                              y: boss.node.position.y + CGFloat.random(in: -20...40)),
                                  in: self,
                                  color: SKColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1),
                                  count: 20, speed: 220)
                }]))
            }
        }
        run(.sequence([.wait(forDuration: 0.9), .run { [weak self] in
            guard let self else { return }
            self.spawnPortal(at: CGPoint(x: self.bossPortalPoint.x,
                                         y: self.bossPortalPoint.y + Tuning.tileSize * 0.3))
            Effects.burst(at: self.bossPortalPoint, in: self,
                          color: SKColor(red: 0.3, green: 1.0, blue: 0.7, alpha: 1), count: 20, speed: 180)
        }]))
    }

    // MARK: - Game loop

    /// Spline terrain and painted spline backdrop geometry, from the level file.
    ///
    /// Additive to the tile grid on purpose: a level can be all tiles, all curves,
    /// or a mix — tiles for the blocky platforming furniture, curves for the ground
    /// and the silhouette. The footprint the shapes declare is what keeps the
    /// grid-based reachability check honest about where the floor is.
    private func buildFrises() {
        let specs = LevelLibrary.frises(at: levelIndex)
        // Decor belongs to the backdrop, which is what parallaxes, hazes and
        // depth-of-field blurs it. Handing it to the stage rather than parenting it
        // here is the difference between painted scenery and a sticker on the
        // gameplay plane.
        if let frieze, let scene = friezeScene {
            frieze.adoptDecor(specs, scene: scene, sceneSize: size)
        }
        for spec in specs where spec.kind != .decor {
            guard let node = FriseNode(spec: spec) else {
                // A bad frise is content, not a crash: skip it and leave the rest
                // of the level playable. `make verify` reports it offline.
                continue
            }
            addChild(node)
            if spec.kind == .platform {
                // Same one-way handling as a tile `P` run: the scene toggles the
                // category per frame from the player's position.
                oneWays.append(node)
            }
            NormalMapper.applyRecursively(from: node, shadows: .receiver)
        }
    }

    /// Wrap the world in the post chain.
    ///
    /// Done by *reparenting* after the build rather than by threading a container
    /// through twenty `addChild` sites — the scene graph is the same either way,
    /// and this keeps the world-building code readable.
    ///
    /// The cost worth knowing: `SKEffectNode` renders its subtree to an
    /// intermediate texture sized to that subtree's accumulated frame, which for a
    /// 50-tile level is roughly 2000×390pt — about four screens. That is the price
    /// of a single-pass chain in SpriteKit, and it is why this is switchable:
    /// `showPostProcess(false)` (or the `setPostProcess` command) drops it to zero
    /// by disabling effects, leaving the node as a plain container.
    private func installPostProcess() {
        guard post == nil else { return }
        let chain = PostProcess(size: size)
        // Everything except the camera. The camera carries the HUD and the lights;
        // lights work by category bitmask, so they still light sprites inside the
        // chain.
        for node in children where node !== cam && node !== chain {
            node.removeFromParent()
            chain.addChild(node)
        }
        addChild(chain)
        post = chain
        // An explicit `setGrade` wins, then the level file's own grade, then a
        // guess from the time of day, then the default. Same precedence as the
        // backdrop and the lighting.
        if let name = overrides.grade, chain.apply(named: name) {
            // applied
        } else if let name = LevelLibrary.grade(at: levelIndex),
                  chain.apply(named: name) {
            // applied
        } else if let time = LevelLibrary.timeOfDay(at: levelIndex), time > 0.66 {
            chain.apply(.evening)
        } else {
            chain.apply(.grove)
        }
        chain.shouldEnableEffects = chain.shouldEnableEffects && overrides.postProcess
    }

    /// Turn the chain on or off at runtime — the `setPostProcess` command, and the
    /// escape hatch if a device can't afford it.
    func showPostProcess(_ on: Bool) {
        post?.shouldEnableEffects = on
    }

#if DEBUG
    /// Enter or leave in-engine editing.
    ///
    /// Gameplay freezes while editing — painting a platform under a moving player
    /// produces a physics resolution nobody asked for — and the scene rebuilds on
    /// *exit* rather than per stroke, because the level graph is built once at load.
    /// That is the same trade the command API makes.
    /// Is the editor open? Read by the command interpreter so `editLevel` is a *set*
    /// rather than a blind toggle.
    var isEditing: Bool { editor != nil }

    func toggleEditor() {
        if let editor {
            editor.removeFromParent()
            self.editor = nil
            isPaused = false
            physicsWorld.speed = 1
            return
        }
        guard let rows = overrides.rows(forLevel: levelIndex) else { return }
        let overlay = EditorOverlay(rows: rows, tile: Tuning.tileSize, sceneSize: size)
        overlay.onRequest = { [weak self] request in self?.handle(request) }
        cam.addChild(overlay)
        editor = overlay
        // Freeze the simulation but keep the scene rendering, so the overlay is live.
        physicsWorld.speed = 0
        // The streamer must stop hiding bands: an author needs to see the level they
        // are editing, not a two-band window of it.
        streamer?.attachAll()
    }

    private func handle(_ request: EditorOverlay.Request) {
        switch request {
        case .apply(let rows):
            // Recorded, not rebuilt: rebuilding per stroke is unusable, and the
            // override is what a reload will pick up.
            overrides.setLevelOverride(rows, for: levelIndex)
        case .playFrom(let rows, _, _):
            overrides.setLevelOverride(rows, for: levelIndex)
            physicsWorld.speed = 1
            editor?.removeFromParent()
            editor = nil
            requestReload()
        case .close:
            editor?.removeFromParent()
            editor = nil
            physicsWorld.speed = 1
            // Rebuild so the painted tiles become real geometry.
            requestReload()
        case .pan(let dx, let dy):
            cam.position = CGPoint(x: cam.position.x - dx, y: cam.position.y - dy)
        case .zoom(let factor):
            cam.setScale(min(3, max(0.5, cam.xScale * factor)))
        }
    }
#endif

    /// Fire a named effect. A missing preset or a full pool is silence, never an
    /// error — an effect is never worth a stall.
    func emit(_ event: String, at position: CGPoint, angle: CGFloat? = nil) {
        guard let fx, let preset = ParticleSpec.events[event] else { return }
        fx.emit(preset, at: position, now: currentTimeCache, angle: angle)
    }

    /// Kick the frame. Impacts read far harder with a distortion than without one.
    func screenImpact(_ strength: CGFloat) {
        post?.impact(strength)
        // The backdrop reacts too: a pound that bends the frame but leaves the
        // foliage rigid reads as a camera effect rather than as force in the world.
        frieze?.impact(atSceneX: player.position.x, strength: strength)
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(lastUpdateTime > 0 ? currentTime - lastUpdateTime : 1.0 / 60.0, 1.0 / 30.0))
        lastUpdateTime = currentTime
        frameNumber &+= 1
        currentTimeCache = currentTime
        elapsed += Double(dt)
        // Before the gameplay guard: a duck has to lift again even on the frame
        // the player dies, or the music stays quiet through the game-over screen.
        Audio.shared.update()
        fx?.update(now: currentTime)

        guard !isGameOver, !levelFinished, let body = player.physicsBody else { return }

        // Wall-jump input lock briefly overrides steering
        let effectiveInput: CGFloat = currentTime < inputLockUntil ? lockDir : moveInput

        // Crushers run before the ground probe, so the player is tested against
        // where the block *is* this frame rather than where it was. A descending
        // block covers 20pt per frame, so the hit is a *swept* test: sampling
        // only end positions lets it pass through a player between frames.
        for crusher in crushers {
            let before = crusher.node.position
            crusher.update(now: currentTime, dt: dt)
            guard crusher.isDangerous, !isGameOver else { continue }
            if player.sweptHit(from: before, to: crusher.node.position,
                               radius: Tuning.tileSize * 0.5, in: self) {
                shakeTime = max(shakeTime, 0.24)
                loseLife()
            }
        }

        // Moving platforms
        var moverDeltas: [ObjectIdentifier: CGFloat] = [:]
        for i in movers.indices {
            let newX = movers[i].baseX + CGFloat(sin(elapsed * Double(Tuning.moverSpeed))) * Tuning.moverTravel
            moverDeltas[ObjectIdentifier(movers[i].node)] = newX - movers[i].lastX
            movers[i].node.position.x = newX
            movers[i].lastX = newX
        }

        // One-way platforms: solid only when the player's feet are above them
        // and not rising — so you can jump up through and land on top.
        let feetY = player.position.y - 17
        for pad in oneWays {
            let top = pad.position.y + 6
            let solid = feetY >= top - 2 && body.velocity.dy <= 40
            pad.physicsBody?.categoryBitMask = solid ? PhysicsCategory.ground : PhysicsCategory.none
        }

        // Grounded check — also identifies WHAT we're standing on, and how it is
        // tilted, which is what makes slopes work.
        let support = supportProbe()
        let grounded = support != nil
        if grounded { lastGroundedTime = currentTime }
        if grounded && !wasGrounded {
            player.playLand()
            Audio.shared.play("land", on: self)
            emit("land", at: CGPoint(x: player.position.x, y: player.position.y - 18))
            Effects.dust(at: CGPoint(x: player.position.x, y: player.position.y - 18), in: self)
            if pounding { poundImpact(); screenImpact(0.9) }
        }
        wasGrounded = grounded

        // Ride moving platforms
        if let supportNode = support?.body.node,
           let delta = moverDeltas[ObjectIdentifier(supportNode)] {
            player.position.x += delta
        }

        // Conveyors: the belt under your feet adds to your own speed rather than
        // replacing it, so you can still walk against one — slowly.
        var carry: CGFloat = 0
        if let node = support?.body.node {
            for belt in conveyors where belt.node === node {
                carry = belt.direction * Tuning.conveyorSpeed
            }
        }

        // ── movement abilities ─────────────────────────────────────────────
        // Dash, ledge hang, climb, spring and updraft all *replace* ordinary
        // motion, in that order of precedence. `PlayerMotion` owns the rules; the
        // scene's job is only to describe the surroundings and apply the answer.
        var world = PlayerMotion.World()
        world.grounded = grounded
        world.groundNormal = support?.normal
        world.carry = carry
        world.onClimbable = overlapping(climbables, pad: 2) != nil
        world.inUpdraft = overlapping(updrafts, pad: 2) != nil
        world.touchingSpring = grounded
            && support?.body.categoryBitMask == PhysicsCategory.spring
        world.ledgeDirection = pounding ? 0 : ledgeAhead()
        world.wallAhead = effectiveInput != 0 && wallAhead(dir: effectiveInput)

        var input = PlayerMotion.Input()
        input.move = effectiveInput
        input.vertical = verticalInput
        input.jumpPressed = (currentTime - jumpRequestedTime) <= Tuning.jumpBuffer
        input.jumpHeld = jumpHeld
        input.dashPressed = dashRequested
        dashRequested = false

        if pounding {
            // A ground pound outranks everything: it is the one move that must
            // not be steerable or interruptible.
            motion.reset()
            body.velocity = currentTime < poundHangUntil
                ? .zero
                : CGVector(dx: 0, dy: Tuning.poundSpeed)
        } else {
            body.velocity = motion.step(now: currentTime, dt: dt, input: input,
                                        world: world, velocity: body.velocity,
                                        runSpeed: overrides.effectiveRunSpeed,
                                        jumpVelocity: overrides.effectiveJumpVelocity)
            body.affectedByGravity = !motion.suspendsGravity
            if motion.firedSpring, let node = support?.body.node {
                Interactable.fireSpring(node)
                Audio.shared.play("spring", on: self)
                Effects.dust(at: CGPoint(x: player.position.x, y: player.position.y - 18),
                             in: self)
                jumpRequestedTime = -1
            }
            if motion.isDashing && !wasDashing {
                Audio.shared.play("dash", on: self)
                emit("dash", at: player.position,
                     angle: player.facing < 0 ? 0 : .pi)
            }
            wasDashing = motion.isDashing
            if motion.isDashing || motion.isClimbing || motion.isHanging {
                jumpRequestedTime = -1        // consumed by the ability
            }
        }
        let overriding = motion.suspendsGravity

        // Wall slide (not while pounding or grounded; must push into the wall while falling)
        var wallSliding = false
        if !overriding && !grounded && !pounding && body.velocity.dy < 0
            && effectiveInput != 0 && wallAhead(dir: effectiveInput) {
            wallSliding = true
            wallDir = effectiveInput
            lastWallTime = currentTime
            if body.velocity.dy < Tuning.wallSlideMaxFall {
                body.velocity.dy = Tuning.wallSlideMaxFall
            }
            wallDustTimer -= dt
            if wallDustTimer <= 0 {
                wallDustTimer = 0.18
                Effects.dust(at: CGPoint(x: player.position.x + wallDir * 13, y: player.position.y),
                             in: self)
            }
        }

        // Jump: normal (coyote + buffer) or wall jump
        let canJump = (currentTime - lastGroundedTime) <= Tuning.coyoteTime
        let wantsJump = (currentTime - jumpRequestedTime) <= Tuning.jumpBuffer
        if wantsJump && !pounding && !overriding {
            if canJump && body.velocity.dy <= 1 {
                body.velocity = CGVector(dx: body.velocity.dx,
                                         dy: overrides.effectiveJumpVelocity)
                jumpRequestedTime = -1
                lastGroundedTime = -1
                Audio.shared.play("jump", on: self)
            } else if !grounded && (currentTime - lastWallTime) <= Tuning.wallCoyote
                        && body.velocity.dy < 60 {
                // Wall jump: launch up and away, steering locked for a beat
                body.velocity = CGVector(dx: 0, dy: overrides.effectiveJumpVelocity * 0.92)
                lockDir = -wallDir
                inputLockUntil = currentTime + Tuning.wallJumpLockTime
                jumpRequestedTime = -1
                lastWallTime = -10
                Audio.shared.play("jump", on: self)
                Effects.dust(at: CGPoint(x: player.position.x + wallDir * 13, y: player.position.y),
                             in: self)
            }
        }

        // Helicopter hover: hold jump while falling (never during a pound/slide)
        let hoverActive = !grounded && !pounding && !wallSliding && !overriding
            && jumpHeld && body.velocity.dy < 0
        if hoverActive && body.velocity.dy < Tuning.hoverFallSpeed {
            body.velocity.dy = Tuning.hoverFallSpeed
        }

        // Pose + animation
        // The rotor is a loop, so it is retriggered while hovering rather than
        // played once. `hover.wav` is exactly 11 rotor cycles, which is why
        // retriggering it does not click.
        if hoverActive {
            if currentTime >= hoverSoundUntil {
                Audio.shared.play("hover", on: self)
                hoverSoundUntil = currentTime + 0.40
            }
        } else {
            hoverSoundUntil = 0
        }

        // Precedence mirrors `PlayerMotion`'s: whichever ability is actually
        // driving the body is the one the rig should show.
        let pose: PlayerPose
        if motion.isDashing { pose = .dash }
        else if motion.isClimbing { pose = .climb }
        else if pounding { pose = .pound }
        else if wallSliding { pose = .wallSlide }
        else if hoverActive { pose = .hover }
        else { pose = .normal }
        player.setPose(pose)
        player.update(dt: dt, moveInput: effectiveInput, grounded: grounded, vy: body.velocity.dy)

        // Combat against the deformed rig. The rig update above refreshed its
        // hulls, so the fist tested here is the fist that was just drawn.
        if !punchResolved, currentTime <= punchOpenUntil, resolvePunch() {
            punchResolved = true
        }
        if !grazing.isEmpty { resolveGrazes() }

        // Actors
        for enemy in enemies { enemy.update(dt: dt, now: currentTime, playerPos: player.position) }
        for v in villagers { v.update(now: currentTime, playerPos: player.position) }
        for b in birds { b.update(playerPos: player.position) }
        if let boss, !boss.isDead {
            let landed = boss.update(dt: dt, now: currentTime, playerPos: player.position)
            if landed {
                shakeTime = max(shakeTime, 0.22)
                Audio.shared.play("stomp", on: self)
                Effects.dust(at: CGPoint(x: boss.node.position.x, y: boss.node.position.y - 26),
                             in: self)
            }
        }

        // Coin magnetism
        for coin in coins {
            let dx = player.position.x - coin.position.x
            let dy = player.position.y - coin.position.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < Tuning.magnetRadius && dist > 1 {
                coin.position.x += dx / dist * Tuning.magnetPull * dt
                coin.position.y += dy / dist * Tuning.magnetPull * dt
            }
        }

        // Fell off the level
        if player.position.y < -80 { loseLife() }

        // Camera: predictive lead + smoothing + decaying shake
        // Set pieces first: a trigger can change the framing this very frame, and
        // resolving the camera before firing would apply last frame's decision.
        stepTriggers(dt: dt)

        // Authored framing. `lock` and `chase` supply a position outright; `follow`
        // and `lockY` fall through to the ordinary follow below.
        let framing = director?.step(dt: dt, playerX: player.position.x,
                                     playerY: player.position.y)
        if let zoom = framing?.zoom {
            // `SKCameraNode` zooms by scaling: >1 sees more of the world.
            cam.setScale(zoom)
        }
        var desired = player.position
        desired.x += body.velocity.dx * (director?.lead ?? overrides.effectiveCameraLead)
        if let point = framing?.position {
            desired = point
        } else if framing?.mode == .lockY {
            desired.y = cam.position.y
        }
        desired = clampCamera(to: desired)
        let k = min(1, dt * Tuning.cameraSmoothing)
        var next = CGPoint(x: cam.position.x + (desired.x - cam.position.x) * k,
                           y: cam.position.y + (desired.y - cam.position.y) * k)
        if shakeTime > 0 {
            shakeTime -= dt
            let f = shakeTime * 24
            next.x += CGFloat.random(in: -f...f)
            next.y += CGFloat.random(in: -f...f)
        }
        cam.position = next
        // Cheap: early-outs unless the camera crossed a band boundary.
        streamer?.update(cameraX: next.x)
        for wall in hazardWalls { wall.update(dt: dt) }
        // The backdrop root tracks the camera because it is no longer a camera
        // child; its internal parallax still comes from camX/camY.
        frieze?.position = cam.position
        frieze?.update(camX: cam.position.x, camY: cam.position.y, dt: TimeInterval(dt))
        post?.update(dt)
        // Lighting follows the camera: cull to the nearest few point lights, and
        // let the backdrop take the time-of-day tint the baked layers can't.
        lightCullTimer -= dt
        if lightCullTimer <= 0 {
            lightCullTimer = 0.25
            lighting.cullPointLights(around: cam.position, in: self)
            if let frieze {
                let light = overrides.effectiveLighting
                frieze.retint(DayCycle.color(light.warm),
                              strength: 0.30 * (1 - light.ambient))
            }
        }
        parallax?.update(camX: cam.position.x)
    }

    /// What the player is standing on, and the surface normal there.
    ///
    /// The normal is the whole reason this returns a tuple: a 45° ramp reports
    /// roughly (∓0.707, 0.707), and `PlayerMotion` projects the run along it.
    /// The ray is cast a little deeper than the old six points so a downhill run
    /// stays attached to the surface instead of skipping along it.
    private func supportProbe() -> (body: SKPhysicsBody, normal: CGVector)? {
        let feetY = player.position.y - 18
        var found: (SKPhysicsBody, CGVector)?
        for offsetX in [-11.0, 0.0, 11.0] {
            let start = CGPoint(x: player.position.x + offsetX, y: feetY)
            let end = CGPoint(x: start.x, y: feetY - Tuning.slopeSnapDistance)
            physicsWorld.enumerateBodies(alongRayStart: start, end: end) {
                body, _, normal, stop in
                if body.categoryBitMask & PhysicsCategory.standable != 0 {
                    found = (body, normal)
                    stop.pointee = true
                }
            }
            if let found { return (found.0, found.1) }
        }
        return nil
    }

    /// A lip the player can catch: a wall at chest height with clear air just
    /// above it. Returns the direction the player must be pressing (±1), or 0.
    private func ledgeAhead() -> CGFloat {
        for dir in [player.facing, -player.facing] where dir != 0 {
            let wallY = player.position.y + 4
            let openY = player.position.y + 24
            var wall = false, open = true
            physicsWorld.enumerateBodies(
                alongRayStart: CGPoint(x: player.position.x + dir * 12, y: wallY),
                end: CGPoint(x: player.position.x + dir * 22, y: wallY)) { body, _, _, stop in
                if body.categoryBitMask & PhysicsCategory.standable != 0 {
                    wall = true; stop.pointee = true
                }
            }
            guard wall else { continue }
            physicsWorld.enumerateBodies(
                alongRayStart: CGPoint(x: player.position.x + dir * 12, y: openY),
                end: CGPoint(x: player.position.x + dir * 22, y: openY)) { body, _, _, stop in
                if body.categoryBitMask & PhysicsCategory.standable != 0 {
                    open = false; stop.pointee = true
                }
            }
            if open { return dir }
        }
        return 0
    }

    /// Cheap overlap against a sensor list — cheaper than physics contacts for
    /// things the player is *inside* rather than colliding with.
    private func overlapping(_ nodes: [SKNode], pad: CGFloat = 0) -> SKNode? {
        let box = CGRect(x: player.position.x - 12 - pad, y: player.position.y - 17 - pad,
                         width: 24 + pad * 2, height: 34 + pad * 2)
        for node in nodes where node.parent != nil {
            let t = Tuning.tileSize
            let rect = CGRect(x: node.position.x - t / 2, y: node.position.y - t / 2,
                              width: t, height: t)
            if rect.intersects(box) { return node }
        }
        return nil
    }

    /// Two short horizontal rays toward `dir` — true if a wall is hugging us.
    private func wallAhead(dir: CGFloat) -> Bool {
        for offsetY in [CGFloat(2), -10] {
            let start = CGPoint(x: player.position.x + dir * 14, y: player.position.y + offsetY)
            let end = CGPoint(x: start.x + dir * 7, y: start.y)
            var hit = false
            physicsWorld.enumerateBodies(alongRayStart: start, end: end) { body, _, _, stop in
                if body.categoryBitMask == PhysicsCategory.ground {
                    hit = true
                    stop.pointee = true
                }
            }
            if hit { return true }
        }
        return false
    }

    /// Hand the world's static furniture to the streamer.
    ///
    /// Done by adoption after the build, for the same reason the post chain is: the
    /// alternative is threading a container through every one of the builder's 49
    /// `addChild` sites, and the scene graph ends up identical either way.
    ///
    /// Deliberately excluded, because detaching any of these breaks something:
    ///   * the **player** — mid-simulation, and detaching it ends the game
    ///   * **enemies and NPCs** — they move, so their band membership is not static
    ///   * the **camera**, **HUD**, **backdrop** and the **post chain** itself
    ///   * anything spanning more than two bands, which the streamer rejects itself
    ///     (a level-wide frise has no meaningful band)
    private func installStreaming() {
        let host = post ?? self
        let moving: Set<ObjectIdentifier> = Set(
            ([player] + enemies.map(\.node) + villagers.map(\.node)
              + birds.map(\.node) + crushers.map(\.node) + oneWays)
                .map { ObjectIdentifier($0) })
        let candidates = host.children.filter { node in
            node !== cam && node !== frieze
                && !(node is PostProcess) && !(node is HazardWall)
                && !moving.contains(ObjectIdentifier(node))
        }
        let streamer = LevelStreamer(bandWidth: Tuning.tileSize * 8, radius: 2)
        streamer.adopt(candidates, parent: host)
        self.streamer = streamer
    }

    /// Evaluate the level's triggers and perform whatever fired.
    private func stepTriggers(dt: CGFloat) {
        guard var runtime = triggerRuntime else { return }
        var world = TriggerRuntime.World()
        world.playerRect = bodyRect(of: player)
        world.elapsed = elapsed
        world.coins = coinsThisRun
        world.enemiesDefeated = enemiesDefeated
        let actions = runtime.step(world: world)
        triggerRuntime = runtime
        for action in actions { perform(action) }
    }

    /// One trigger action. Kept as a flat switch on purpose: this is the list of
    /// everything a level can make happen, and it should be readable as exactly that.
    private func perform(_ action: TriggerAction) {
        switch action {
        case .spawn(let kind, let col, let row, let count, let spacing):
            guard let symbol = TileSymbol.actorKinds[kind] else { return }
            for index in 0..<count {
                spawnActor(symbol: symbol, col: col + index * spacing, row: row)
            }

        case .hazardWall(let fromCol, let speed):
            let wall = HazardWall(startX: CGFloat(fromCol) * Tuning.tileSize,
                                  speed: speed, sceneHeight: levelHeight)
            (post ?? self).addChild(wall)
            hazardWalls.append(wall)

        case .camera(let mode, let zoom, let speed):
            director?.override(mode: mode, zoom: zoom, speed: speed,
                               playerX: player.position.x)

        case .move(let target, let dx, let dy, let seconds):
            // Searched by name across the whole tree: a gate is a tile-built node, so
            // the scene has no typed reference to it.
            let found = (post ?? self).children.flatMap { [$0] + $0.children }
                .filter { $0.name == target }
            for node in found {
                node.run(.moveBy(x: dx, y: dy, duration: seconds).eased())
            }

        case .shake(let strength):
            shakeTime = max(shakeTime, min(0.6, strength * 0.4))
            screenImpact(strength)

        case .sound(let name):
            Audio.shared.play(name, on: self)

        case .music(let name):
            Audio.shared.playMusic(name)

        case .grade(let name):
            _ = post?.apply(named: name)

        case .text(let message, let seconds):
            let where_ = CGPoint(x: cam.position.x, y: cam.position.y + 70)
            Effects.floatText(message, at: where_, in: self)
            _ = seconds        // the effect owns its own lifetime

        case .tuning(let run, let jump, let gravity):
            // Through `EngineOverrides` rather than onto the body directly, so the
            // state document reports it and `reset` puts it back.
            if let run { overrides.runSpeed = run }
            if let jump { overrides.jumpVelocity = jump }
            if let gravity {
                overrides.gravity = gravity
                physicsWorld.gravity = CGVector(dx: 0, dy: gravity)
            }
            tuningTouched = true

        case .checkpoint:
            respawnPoint = player.position

        case .finish:
            finishLevel()
        }
    }

    /// Spawn one actor at a grid cell — the shared path for `spawnActor` commands and
    /// `spawn` trigger actions, so an ambush produces exactly what the level builder
    /// would have.
    private func spawnActor(symbol: Character, col: Int, row: Int) {
        let t = Tuning.tileSize
        let position = CGPoint(x: (CGFloat(col) + 0.5) * t,
                               y: levelHeight - (CGFloat(row) + 0.5) * t)
        switch symbol {
        case "E":
            // Patrol bounds from the ground run under the spawn point, the same way
            // the level builder derives them — a spawned enemy that patrols into a
            // pit is worse than one that doesn't spawn.
            let half = Tuning.tileSize * 2.5
            let enemy = Enemy(position: position, minX: position.x - half,
                              maxX: position.x + half,
                              behaviour: LevelLibrary.enemyBehaviour(at: levelIndex))
            enemy.node.name = "enemy.\(enemies.count)"
            (post ?? self).addChild(enemy.node)
            enemies.append(enemy)
            NormalMapper.applyRecursively(from: enemy.node, shadows: .caster)
        case "C":
            let coin = Decor.coin()
            coin.position = position
            coin.name = "coin.spawned.\(coins.count)"
            (post ?? self).addChild(coin)
            coins.append(coin)
        default:
            break
        }
    }

    private func clampCamera(to target: CGPoint) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let x = min(max(target.x, halfW), max(levelWidth - halfW, halfW))
        let y = min(max(target.y, halfH), max(levelHeight - halfH, halfH))
        return CGPoint(x: x, y: y)
    }

    // MARK: - Contacts

    func didBegin(_ contact: SKPhysicsContact) {
        guard !isGameOver, !levelFinished else { return }
        let other = contact.bodyA.categoryBitMask == PhysicsCategory.player ? contact.bodyB : contact.bodyA
        guard let otherNode = other.node else { return }

        switch other.categoryBitMask {
        case PhysicsCategory.coin:
            collectCoin(otherNode)

        case PhysicsCategory.enemy:
            if let boss, otherNode === boss.node {
                handleBossContact()
                return
            }
            let falling = (player.physicsBody?.velocity.dy ?? 0) < -50
            let above = player.position.y > otherNode.position.y + 14
            if pounding || (falling && above) {
                // Stomps stay generous: landing on something reads as a hit even
                // if the drawn foot is a few points shy.
                popEnemy(otherNode)
                if !pounding {
                    player.physicsBody?.velocity = CGVector(dx: player.physicsBody?.velocity.dx ?? 0,
                                                            dy: Tuning.enemyStompBounce)
                    Audio.shared.play("stomp", on: self)
                }
                shakeTime = max(shakeTime, 0.12)
            } else if !drawnBodyMisses(otherNode) {
                loseLife()
            }

        case PhysicsCategory.hazard:
            if !drawnBodyMisses(otherNode) { loseLife() }

        case PhysicsCategory.checkpoint:
            if Interactable.claimCheckpoint(otherNode) {
                respawnPoint = CGPoint(x: otherNode.position.x, y: otherNode.position.y + 4)
                Audio.shared.play("checkpoint", on: self)
                emit("checkpoint", at: otherNode.position)
                Effects.floatText("Checkpoint", at: CGPoint(x: otherNode.position.x,
                                                            y: otherNode.position.y + 60),
                                  in: self,
                                  color: SKColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1))
            }

        case PhysicsCategory.ground:
            // Ground normally isn't a contact at all — only a crusher tests for
            // it, and only while it is descending does it kill.
            if crushers.contains(where: { $0.node === otherNode && $0.isDangerous }) {
                shakeTime = max(shakeTime, 0.24)
                if !drawnBodyMisses(otherNode) { loseLife() }
            }

        case PhysicsCategory.finish:
            finishLevel()

        default:
            break
        }
    }

    /// True when the box says we were touched but the drawn body was not.
    ///
    /// This is the payoff of deformed-mesh collision on the receiving end: a
    /// character box is bigger than the art in nearly every pose, so "the box
    /// clipped a spike" is not the same claim as "you were hit". A miss is
    /// remembered rather than dropped — SpriteKit fires `didBegin` exactly once,
    /// so a hazard you are standing inside could otherwise never hurt you no
    /// matter how the animation moved afterwards.
    ///
    /// In `.box` collider mode there are no hulls and the box remains the truth,
    /// which is why the shipped game plays identically until a collider mode is
    /// asked for.
    private func drawnBodyMisses(_ node: SKNode) -> Bool {
        let regions = playerHitRegions()
        guard !regions.isEmpty else { return false }
        let rect = bodyRect(of: node)
        // Broadphase first: one box comparison rejects most candidates before any
        // separating-axis work happens.
        if let box = player.hullBounds(in: self), !box.intersects(rect) { return true }
        let polygon = Geometry2D.polygon(of: rect)
        if regions.contains(where: { Geometry2D.overlaps($0, polygon) }) { return false }
        if !grazing.contains(where: { $0 === node }) { grazing.append(node) }
        return true
    }

    /// Re-test remembered grazes: a hit the moment the art reaches them,
    /// forgotten once the boxes come apart.
    private func resolveGrazes() {
        let regions = playerHitRegions()
        guard !regions.isEmpty else { grazing.removeAll(); return }
        let playerBox = CGRect(x: player.position.x - 13, y: player.position.y - 17,
                               width: 26, height: 34)
        var survivors: [SKNode] = []
        for node in grazing where node.parent != nil {
            let rect = bodyRect(of: node)
            guard rect.intersects(playerBox) else { continue }
            let polygon = Geometry2D.polygon(of: rect)
            if regions.contains(where: { Geometry2D.overlaps($0, polygon) }) {
                grazing.removeAll()
                loseLife()
                return
            }
            survivors.append(node)
        }
        grazing = survivors
    }

    /// An actor's physics-body rect in scene space. The bodies are built in
    /// `buildLevel`, so these sizes are read off that code rather than guessed
    /// from the art (`calculateAccumulatedFrame` would include glow halos).
    private func bodyRect(of node: SKNode) -> CGRect {
        let t = Tuning.tileSize
        switch node.physicsBody?.categoryBitMask {
        case PhysicsCategory.hazard:
            return CGRect(x: node.position.x - t * 0.4, y: node.position.y - t * 0.45,
                          width: t * 0.8, height: t * 0.6)
        case PhysicsCategory.enemy:
            let size = node === boss?.node
                ? CGSize(width: 76, height: 62)
                : CGSize(width: 30, height: 26)
            return CGRect(x: node.position.x - size.width / 2,
                          y: node.position.y - size.height / 2,
                          width: size.width, height: size.height)
        default:
            return node.calculateAccumulatedFrame()
        }
    }

    private func handleBossContact() {
        guard let boss, !boss.isDead else { return }
        let falling = (player.physicsBody?.velocity.dy ?? 0) < -50
        let above = player.position.y > boss.node.position.y + 30
        if pounding || (falling && above) {
            if boss.isVulnerable {
                damageBoss()
            }
            if !pounding {
                player.physicsBody?.velocity = CGVector(dx: player.physicsBody?.velocity.dx ?? 0,
                                                        dy: Tuning.enemyStompBounce)
            }
        } else if !boss.isReeling, !drawnBodyMisses(boss.node) {
            loseLife()   // he hurts to touch — except during his hurt flicker
        }
    }

    private func collectCoin(_ node: SKNode) {
        if currentTimeCache - lastCoinTime <= Tuning.comboWindow {
            comboCount = min(comboCount + 1, Tuning.comboMaxMultiplier)
        } else {
            comboCount = 1
        }
        lastCoinTime = currentTimeCache
        let gained = comboCount
        coinsThisRun += gained

        Audio.shared.play("coin", on: self)
        Effects.burst(at: node.position, in: self,
                      color: SKColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1))
        Effects.floatText(comboCount > 1 ? "+\(gained) ×\(comboCount)" : "+1",
                          at: CGPoint(x: node.position.x, y: node.position.y + 10), in: self)
        coins.removeAll { $0 === node }
        node.removeFromParent()
        refreshHUD()
    }

    // MARK: - Lives / win / lose

    private func loseLife() {
        guard !isGameOver else { return }
        lives -= 1
        comboCount = 0
        pounding = false
        grazing.removeAll()
        punchResolved = true
        motion.reset()
        player.physicsBody?.affectedByGravity = true
        verticalInput = 0
        refreshHUD()
        Audio.shared.play("hurt", on: self)
        Effects.burst(at: player.position, in: self,
                      color: SKColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1), count: 16)
        shakeTime = 0.2
        if lives <= 0 {
            showGameOver()
        } else {
            player.physicsBody?.velocity = .zero
            player.position = respawnPoint
            player.playHurt()
            // Re-arm: dying inside a chase must not leave a level whose set pieces
            // have all been consumed.
            triggerRuntime?.reset()
            director?.reset()
            cam.setScale(1)
            for wall in hazardWalls { wall.removeFromParent() }
            hazardWalls.removeAll()
            if tuningTouched {
                overrides.runSpeed = nil
                overrides.jumpVelocity = nil
                overrides.gravity = nil
                physicsWorld.gravity = CGVector(dx: 0, dy: Tuning.gravity)
                tuningTouched = false
            }
        }
    }

    private func finishLevel() {
        levelFinished = true
        player.playVictory()
        // Duck under the fanfare, and let the level's track come back up for the
        // results screen rather than cutting it.
        Audio.shared.duck(to: 0.3, for: 1.6)
        player.physicsBody?.velocity = .zero
        player.setPose(.normal)
        GameData.shared.addCoins(coinsThisRun)
        GameData.shared.maxUnlockedLevel = levelIndex + 1
        Audio.shared.play("win", on: self)
        Effects.burst(at: player.position, in: self,
                      color: SKColor(red: 0.3, green: 1.0, blue: 0.7, alpha: 1), count: 24, speed: 220)

        let hasNext = levelIndex + 1 < Levels.all.count
        let panel = overlayPanel(title: "Level Complete!",
                                 subtitle: "+\(coinsThisRun) coins")
        if hasNext {
            panel.addChild(overlayButton(name: "ui.next", text: "Next Level", y: -20))
        }
        panel.addChild(overlayButton(name: "ui.menu", text: "Menu", y: hasNext ? -78 : -20))
        cam.addChild(panel)

        if !GameData.shared.adsRemoved {
            AdsManager.shared.showInterstitial()
        }
    }

    private func showGameOver() {
        isGameOver = true
        player.physicsBody?.velocity = .zero
        player.setPose(.normal)
        let panel = overlayPanel(title: "Game Over", subtitle: "Coins collected: \(coinsThisRun)")
        panel.addChild(overlayButton(name: "ui.revive", text: "▶ Watch Ad: +1 Life", y: -14))
        panel.addChild(overlayButton(name: "ui.retry", text: "Retry Level", y: -72))
        panel.addChild(overlayButton(name: "ui.menu", text: "Menu", y: -130))
        panel.name = "gameOverPanel"
        cam.addChild(panel)
    }

    private func tryRevive() {
        AdsManager.shared.showRewardedAd { [weak self] rewarded in
            guard let self, rewarded else { return }
            self.cam.childNode(withName: "gameOverPanel")?.removeFromParent()
            self.isGameOver = false
            self.lives = 1
            self.refreshHUD()
            self.player.position = self.respawnPoint
            self.player.physicsBody?.velocity = .zero
            self.motion.reset()
        }
    }

    // MARK: - Overlay helpers & navigation

    private func overlayPanel(title: String, subtitle: String) -> SKNode {
        let panel = SKShapeNode(rectOf: CGSize(width: 360, height: 300), cornerRadius: 22)
        panel.fillColor = SKColor(red: 0.12, green: 0.10, blue: 0.28, alpha: 0.92)
        panel.strokeColor = SKColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 0.9)
        panel.lineWidth = 4
        panel.zPosition = 300
        panel.setScale(0.6)
        panel.run(.scale(to: 1.0, duration: 0.25).eased())

        let t = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        t.text = title
        t.fontSize = 30
        t.fontColor = SKColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 1)
        t.position = CGPoint(x: 0, y: 92)
        panel.addChild(t)

        let s = SKLabelNode(fontNamed: "AvenirNext-Medium")
        s.text = subtitle
        s.fontSize = 18
        s.fontColor = SKColor(white: 1, alpha: 0.85)
        s.position = CGPoint(x: 0, y: 58)
        panel.addChild(s)
        return panel
    }

    private func overlayButton(name: String, text: String, y: CGFloat) -> SKNode {
        let b = SKShapeNode(rectOf: CGSize(width: 280, height: 48), cornerRadius: 16)
        b.fillColor = SKColor(red: 0.98, green: 0.45, blue: 0.15, alpha: 1)
        b.strokeColor = SKColor(red: 0.75, green: 0.28, blue: 0.05, alpha: 1)
        b.lineWidth = 3
        b.position = CGPoint(x: 0, y: y)
        b.name = name
        let l = SKLabelNode(fontNamed: "AvenirNext-Bold")
        l.text = text
        l.fontSize = 19
        l.verticalAlignmentMode = .center
        l.name = name
        b.addChild(l)
        return b
    }

    private func restartLevel() {
        view?.presentScene(GameScene(levelIndex: levelIndex),
                           transition: .fade(withDuration: 0.4))
    }

    private func goToNextLevel() {
        let next = levelIndex + 1
        guard Levels.all.indices.contains(next) else { goToMenu(); return }
        view?.presentScene(GameScene(levelIndex: next),
                           transition: .fade(withDuration: 0.4))
    }

    private func goToMenu() {
        view?.presentScene(MenuScene.make(size: Tuning.sceneSize),
                           transition: .fade(withDuration: 0.4))
    }
}
