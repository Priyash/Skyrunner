import SpriteKit

/// Skeletal version of the hero. Exposes the SAME API as the procedural
/// `PlayerCharacter`, so `GameScene` is unchanged — it just asks the factory
/// for whichever implementation has assets available.
///
/// Rig authoring: `Tools/RigEditor.html` (or Spine) → `Assets/Rigs/hero_rig.json`.
final class SkeletalPlayer: SKNode, PlayerRig {

    private let node: SkeletonNode
    private(set) var facing: CGFloat = 1
    private var pose: PlayerPose = .normal
    private var lastAnim = ""
    private var punchUntil: TimeInterval = 0
    private var landUntil: TimeInterval = 0
    private var hurtUntil: TimeInterval = 0
    /// Victory is sticky: it is the last thing that plays, so it must not be
    /// undone by the next frame's grounded/speed parameters.
    private var victoryLatched = false
    private var elapsed: TimeInterval = 0

    /// Clips that loop. Everything else plays once and is crossfaded out of.
    private static let loopingClips: Set<String> = ["idle", "run", "fall", "climb"]

    /// The state machine, when the rig has the clips to drive it.
    ///
    /// Nil for a rig that doesn't — an older hand-authored rig with five clips
    /// keeps the previous `if`-chain path, which still works. The graph is the
    /// better path (parameterised rates, real blends, `clipFinished` instead of
    /// timers) but it must not be the *only* path, or shipping a rig would mean
    /// shipping a graph.
    private var runner: AnimGraphRunner?
    private var parameters = AnimGraph.Parameters()
    private var lastPlaying: [AnimGraph.Playing] = []

    /// The best clip this rig actually has.
    ///
    /// A rig is data, and data can be older than the code — an artist's rig with
    /// only the original five clips must not freeze the character the first time
    /// gameplay asks for `dash`.
    private func clipFor(_ preferred: String, _ fallback: String = "idle") -> String {
        if node.skeleton.data.animations[preferred] != nil { return preferred }
        if node.skeleton.data.animations[fallback] != nil { return fallback }
        return lastAnim.isEmpty ? "idle" : lastAnim
    }

    init?(rigNamed name: String = "hero_rig") {
        guard let data = try? RigLoader.load(named: name) else { return nil }
        // A packed page when `make atlas` produced one, loose textures otherwise.
        // The rig JSON is unchanged either way — it names images, and the atlas is
        // purely a delivery optimisation.
        let atlasName = name.replacingOccurrences(of: "_rig", with: "_atlas")
        node = SkeletonNode(skeletonData: data,
                            atlas: PackedAtlas(named: atlasName))
        super.init()
        addChild(node)

        // Secondary motion on any bone the rig tagged with a spring value.
        for bone in data.bones where bone.name == "tuft" {
            node.addSecondaryMotion(bone: bone.name, stiffness: 240, damping: 15)
        }
        // Crossfades — the difference between snapping and flowing.
        node.setMix(from: "idle", to: "run", duration: 0.12)
        node.setMix(from: "run", to: "idle", duration: 0.18)
        node.setMix(from: "run", to: "jump", duration: 0.08)
        node.setMix(from: "jump", to: "run", duration: 0.14)
        node.setMix(from: "jump", to: "idle", duration: 0.16)
        node.setMix(from: "jump", to: "fall", duration: 0.10)
        node.setMix(from: "fall", to: "land", duration: 0.04)   // impact is abrupt
        node.setMix(from: "land", to: "idle", duration: 0.10)
        node.setMix(from: "land", to: "run", duration: 0.08)
        node.setMix(from: "run", to: "dash", duration: 0.05)
        node.setMix(from: "dash", to: "run", duration: 0.10)
        node.setMix(from: "idle", to: "climb", duration: 0.12)
        node.setMix(from: "climb", to: "idle", duration: 0.14)

        // Drive the graph only if every clip it names exists. A partial graph
        // would silently freeze on the first missing state.
        let graph = AnimGraph.player()
        let available = Set(data.animations.keys)
        if graph.problems(availableClips: available).isEmpty {
            runner = AnimGraphRunner(graph: graph, clipDurations: node.clipDurations)
        }
        node.play("idle")
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: PlayerRig

    func update(dt: CGFloat, moveInput: CGFloat, grounded: Bool, vy: CGFloat) {
        elapsed += TimeInterval(dt)
        if moveInput != 0 {
            facing = moveInput > 0 ? 1 : -1
            node.flipX = facing < 0
        }

        if runner != nil {
            driveGraph(dt: dt, moveInput: moveInput, grounded: grounded, vy: vy)
            node.update(TimeInterval(dt))
            return
        }

        // Track 0: locomotion. Pose (set by gameplay) wins over raw state, so
        // hover / wall-slide / ground-pound / dash / climb read correctly.
        //
        // Rising and falling are different clips now: a single "jump" pose held
        // through the whole arc is the thing that made airborne motion look
        // weightless. `clipFor` degrades to a clip the rig actually has, so a
        // hand-authored rig with only the original five still animates.
        let want: String
        if punchUntil > elapsed { want = clipFor("punch") }
        else if landUntil > elapsed, grounded { want = clipFor("land", "idle") }
        else if pose == .dash { want = clipFor("dash", "jump") }
        else if pose == .climb { want = clipFor("climb", "idle") }
        else if pose == .pound { want = clipFor("fall", "jump") }
        else if pose == .wallSlide { want = clipFor("fall", "jump") }
        else if !grounded { want = vy < -60 ? clipFor("fall", "jump") : clipFor("jump") }
        else if moveInput != 0 { want = clipFor("run") }
        else { want = clipFor("idle") }
        if want != lastAnim {
            node.play(want, loop: SkeletalPlayer.loopingClips.contains(want))
            lastAnim = want
        }

        // Track 1: additive airborne lean, weighted by vertical speed —
        // procedural layering on top of keyframed motion. Skipped while
        // hovering: the helicopter pose should stay level, not lean.
        if !grounded, pose != .hover {
            let lean = min(1, abs(vy) / 900)
            node.play("jump", track: 1, loop: false, additive: true, alpha: lean * 0.4)
        } else {
            node.state.clearTrack(1)
        }

        node.update(TimeInterval(dt))
    }

    /// One step of the state machine, translated into weighted tracks.
    ///
    /// Track 0 carries the dominant clip; track 1 carries the second at its own
    /// weight with `additive: false`, which is a *replace* blend at partial alpha
    /// — that is what a crossfade is. Additive here would add two poses together
    /// and double every rotation.
    private func driveGraph(dt: CGFloat, moveInput: CGFloat, grounded: Bool,
                            vy: CGFloat) {
        parameters.set("grounded", grounded)
        parameters.set("speed", abs(moveInput) * 260)
        parameters.set("vy", vy)
        parameters.set("dashing", pose == .dash)
        parameters.set("climbing", pose == .climb)
        parameters.set("climbSpeed", pose == .climb ? abs(vy) : 0)
        parameters.set("punch", punchUntil > elapsed)
        parameters.set("hurt", hurtUntil > elapsed)
        parameters.set("victory", victoryLatched)

        guard var runner else { return }
        let playing = runner.step(dt: TimeInterval(dt), parameters: parameters)
        self.runner = runner
        guard !playing.isEmpty else { return }

        let ordered = playing.sorted { $0.weight > $1.weight }
        let primary = ordered[0]
        if lastPlaying.first?.clip != primary.clip {
            node.play(primary.clip, track: 0,
                      loop: SkeletalPlayer.loopingClips.contains(primary.clip))
        }
        node.setRate(primary.rate, track: 0)

        // Only blend a second clip when it is worth a track: below ~12% it is
        // invisible and costs a full skeleton apply.
        if ordered.count > 1, ordered[1].weight > 0.12 {
            let secondary = ordered[1]
            if lastPlaying.count < 2 || lastPlaying[1].clip != secondary.clip {
                node.play(secondary.clip, track: 1,
                          loop: SkeletalPlayer.loopingClips.contains(secondary.clip),
                          additive: false, alpha: secondary.weight)
            }
            node.setRate(secondary.rate, track: 1)
        } else if lastPlaying.count > 1 {
            node.state.clearTrack(1)
        }
        lastPlaying = ordered
        lastAnim = primary.clip
    }

    /// What state the graph is in, for debugging and for the state document.
    var animationState: String? { runner?.current }

    func setPose(_ p: PlayerPose) { pose = p }

    func playPunch() {
        punchUntil = elapsed + 0.21
        node.play("punch", loop: false)
        lastAnim = "punch"
    }

    func playLand() {
        // Prefer the authored impact clip; the root squash is the fallback for a
        // rig that hasn't got one, and it is what shipped before `land` existed.
        if node.skeleton.data.animations["land"] != nil {
            landUntil = elapsed + 0.24
            node.play("land", loop: false)
            lastAnim = "land"
        } else {
            node.run(.sequence([
                .scaleX(to: 1.24, y: 0.76, duration: 0.05),
                .scaleX(to: 1.0, y: 1.0, duration: 0.13),
            ]))
        }
    }

    /// The level-complete pose. One-shot and held, because it is the last thing
    /// the player sees.
    func playVictory() {
        victoryLatched = true
        guard node.skeleton.data.animations["victory"] != nil else { return }
        node.play("victory", loop: false)
        lastAnim = "victory"
        landUntil = 0
        punchUntil = 0
    }

    func playHurt() {
        hurtUntil = elapsed + 0.34
        node.play("hurt", loop: false)
        lastAnim = "hurt"
        run(.sequence([.fadeAlpha(to: 0.3, duration: 0.08),
                       .fadeAlpha(to: 1.0, duration: 0.08),
                       .fadeAlpha(to: 0.3, duration: 0.08),
                       .fadeAlpha(to: 1.0, duration: 0.08)]))
    }

    func startAutoIdle() { node.play("idle") }

    // MARK: Deformed-mesh collision

    /// Every tracked limb hull, in `target` space. Empty until a collider mode
    /// is set (the engine default is `.box`), so gameplay keeps its box logic
    /// unless someone asks for animation-following volumes.
    func hitRegions(in target: SKNode) -> [[CGPoint]] {
        node.hitRegions(in: target)
    }

    /// The punching fist. Named slots are how the rig tells gameplay *which*
    /// deformed volume is the attack — the reason a wind-up doesn't connect and
    /// a full extension reaches past the character box.
    func attackRegion(in target: SKNode) -> [CGPoint]? {
        let slot = facing < 0 ? "slot_hand_l" : "slot_hand_r"
        guard let index = node.skeleton.data.slotIndex(named: slot) else { return nil }
        let points = node.collisionPoints(slotIndex: index)
        guard points.count >= 3 else { return nil }
        return Geometry2D.convexHull(points.map { node.convert($0, to: target) })
    }

    func setColliderMode(_ mode: ColliderMode, slots: [String]) {
        node.setColliderMode(mode, slots: slots)
    }

    func setColliderDebugDraw(_ on: Bool) {
        node.setColliderDebugDraw(on)
    }

    func applyRigLighting() {
        node.applyLighting()
    }

    func hullBounds(in target: SKNode) -> CGRect? {
        node.collider.bounds(in: target)
    }

    func sweptHit(from start: CGPoint, to end: CGPoint, radius: CGFloat,
                  in target: SKNode) -> Bool {
        node.collider.sweep(from: start, to: end, radius: radius, in: target)
    }
}

/// Shared interface so gameplay code never cares which rig it drives.
protocol PlayerRig: SKNode {
    var facing: CGFloat { get }
    func update(dt: CGFloat, moveInput: CGFloat, grounded: Bool, vy: CGFloat)
    func setPose(_ p: PlayerPose)
    func playPunch()
    func playLand()
    func playHurt()
    /// The level-complete pose. Optional: a rig without one simply keeps idling.
    func playVictory()
    func startAutoIdle()

    /// Convex hit regions that follow the animation, in `target`'s space.
    func hitRegions(in target: SKNode) -> [[CGPoint]]
    /// The attacking limb's region, when the rig can point at one.
    func attackRegion(in target: SKNode) -> [CGPoint]?
    func setColliderMode(_ mode: ColliderMode, slots: [String])
    func setColliderDebugDraw(_ on: Bool)
    /// Re-light the rig using its own image names, so authored normal maps win.
    func applyRigLighting()
    /// Bounding box of the hit regions — the cheap rejection before exact tests.
    func hullBounds(in target: SKNode) -> CGRect?
    /// Did a circle moving from `start` to `end` touch this rig on the way?
    func sweptHit(from start: CGPoint, to end: CGPoint, radius: CGFloat,
                  in target: SKNode) -> Bool
}

/// Defaults for rigs with no skeleton: a procedural rig is still a tree of
/// sprites, and a sprite's four transformed corners are a perfectly good
/// animation-following volume. So collision quality degrades gracefully instead
/// of switching off — the same reason the game ships with a procedural hero at
/// all.
extension PlayerRig {

    func hitRegions(in target: SKNode) -> [[CGPoint]] {
        guard EngineOverrides.shared.colliderMode.followsDeformation,
              scene != nil else { return [] }
        return Geometry2D.quads(under: self, in: target)
    }

    func attackRegion(in target: SKNode) -> [CGPoint]? { nil }
    /// A procedural rig has no authored clips, so there is nothing to play.
    func playVictory() {}
    func setColliderMode(_ mode: ColliderMode, slots: [String]) {}
    func setColliderDebugDraw(_ on: Bool) {}
    /// A procedural rig has no named assets, so generated normals are all there
    /// is — the scene's recursive pass already applied them.
    func applyRigLighting() {}

    func hullBounds(in target: SKNode) -> CGRect? {
        let regions = hitRegions(in: target)
        guard !regions.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        for region in regions {
            for p in region {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func sweptHit(from start: CGPoint, to end: CGPoint, radius: CGFloat,
                  in target: SKNode) -> Bool {
        // No hulls: fall back to the character box, which is what the box-mode
        // collider would have used anyway.
        let box = hullBounds(in: target) ?? CGRect(x: position.x - 13, y: position.y - 17,
                                                   width: 26, height: 34)
        let polygon = Geometry2D.polygon(of: box)
        let steps = max(1, Int(hypot(end.x - start.x, end.y - start.y) / max(radius, 1)))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t)
            if Geometry2D.overlaps(polygon, circleAt: p, radius: radius) { return true }
        }
        return false
    }
}

enum PlayerRigFactory {
    /// Skeletal rig when its JSON + art are bundled; procedural otherwise.
    /// Shipping without rig assets still yields a fully playable game.
    static func make() -> PlayerRig {
        if let skeletal = SkeletalPlayer() { return skeletal }
        return PlayerCharacter()
    }
}
