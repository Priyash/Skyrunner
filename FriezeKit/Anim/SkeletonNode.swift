import SpriteKit
import UIKit

/// Renders a `Skeleton` with SpriteKit. Each slot gets a persistent node
/// (SKSpriteNode for regions, SKShapeNode-backed mesh for deform attachments);
/// per frame we only push transforms — no node churn, no allocation.
///
/// Also provides *secondary motion*: springy follow-through on tagged bones
/// (hair, cloth, floating limbs) computed procedurally on top of the keyframed
/// pose, which is what sells hand-drawn liveliness.
final class SkeletonNode: SKNode {

    let skeleton: Skeleton
    let state = AnimationState()

    private var slotNodes: [SKNode?] = []
    private var meshNodes: [Int: SKSpriteNode] = [:]
    /// Prepared skinning lattices, one per mesh slot (built once).
    private var skins: [Int: MeshSkinning.SkinnedMesh] = [:]
    /// The warp grid's source lattice, cached per slot.
    ///
    /// `SKWarpGeometryGrid` only exposes its vertices one at a time, so reading
    /// them back costs a call and an allocation per vertex. They never change —
    /// the *destination* positions are what animate — so querying them every
    /// frame was pure waste: 25 calls per mesh slot per frame at 60fps.
    private var sourceLattices: [Int: [SIMD2<Float>]] = [:]
    /// Reused solve buffer per mesh slot, so a deforming rig allocates nothing
    /// per frame.
    private var solveScratch: [Int: [CGPoint]] = [:]
    private var textureCache: [String: SKTexture] = [:]
    /// Where textures come from. A packed page batches every limb into one bind;
    /// loose images are the fallback.
    private let atlas: TextureProvider?
    /// Remembers what kind of node each slot currently holds, so switching a
    /// slot between region and mesh attachments rebuilds instead of leaving a
    /// stale node behind.
    private enum SlotKind { case none, region, mesh }
    private var slotKinds: [SlotKind] = []

    /// boneName → spring state for secondary motion.
    private struct Spring {
        var stiffness: CGFloat
        var damping: CGFloat
        var velocity: CGFloat = 0
        var offset: CGFloat = 0
        var lastParentRotation: CGFloat = 0
    }
    private var springs: [Int: Spring] = [:]

    /// Deformed-mesh collision for this rig. Created on first touch and idle
    /// until a mode is set — `.box` solves nothing, so a rig that doesn't ask
    /// for animation-following collision pays nothing for the feature.
    private(set) lazy var collider = DeformedCollider(rig: self)

    init(skeletonData: SkeletonData, atlas: TextureProvider? = nil) {
        skeleton = Skeleton(data: skeletonData)
        self.atlas = atlas
        super.init()
        buildSlotNodes()
        state.onEvent = { [weak self] name in self?.onEvent?(name) }
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Fired by EventTimeline keys (footsteps, hit frames…).
    var onEvent: ((String) -> Void)?

    // MARK: Setup

    /// Atlas first (batched draws), then a loose bundle image. Misses are
    /// cached as nil-equivalent by simply not caching, which is fine because
    /// a missing image is a content error surfaced once at load.
    private func texture(_ name: String) -> SKTexture? {
        if let cached = textureCache[name] { return cached }
        var tex: SKTexture?
        if let atlas, let packed = atlas.texture(named: name) {
            tex = packed
        } else if UIImage(named: name) != nil {
            tex = SKTexture(imageNamed: name)
        }
        if let tex {
            tex.filteringMode = .linear
            textureCache[name] = tex
        }
        return tex
    }

    private func buildSlotNodes() {
        slotNodes = Array(repeating: nil, count: skeleton.slots.count)
        slotKinds = Array(repeating: .none, count: skeleton.slots.count)
        for i in skeleton.slots.indices {
            let container = SKNode()
            container.zPosition = CGFloat(i)          // slot order = draw order
            addChild(container)
            slotNodes[i] = container
        }
    }

    /// Mark a bone for springy follow-through (hair, tails, cloth).
    func addSecondaryMotion(bone name: String, stiffness: CGFloat = 220,
                            damping: CGFloat = 14) {
        guard let i = skeleton.data.boneIndex(named: name) else { return }
        springs[i] = Spring(stiffness: stiffness, damping: damping,
                            lastParentRotation: 0)
    }

    // MARK: Playback

    func play(_ animation: String, track: Int = 0, loop: Bool = true,
              additive: Bool = false, alpha: CGFloat = 1) {
        guard let clip = skeleton.data.animations[animation] else { return }
        state.setAnimation(clip, track: track, loop: loop, additive: additive, alpha: alpha)
    }

    /// Playback rate for a track. `TrackEntry` already scales its own time, so a
    /// speed-parameterised state only needs this hook — which is the difference
    /// between a run cycle that matches the ground and one that slides.
    func setRate(_ rate: CGFloat, track: Int = 0) {
        state.tracks[track]?.timeScale = max(0.01, rate)
    }

    /// Clip durations, for an `AnimGraphRunner` that has to know when a one-shot
    /// has played through.
    var clipDurations: [String: TimeInterval] {
        skeleton.data.animations.mapValues(\.duration)
    }

    /// Swap the attachment set. Prepared skins are dropped so the new skin's
    /// meshes are rebound rather than inheriting the old skin's lattice.
    func setSkin(_ name: String) {
        guard skeleton.data.skins[name] != nil, skeleton.skin != name else { return }
        skeleton.skin = name
        skins.removeAll()
        sourceLattices.removeAll()
        solveScratch.removeAll()
        for i in slotKinds.indices { slotKinds[i] = .none }
        for container in slotNodes { container?.removeAllChildren() }
        meshNodes.removeAll()
    }

    var availableSkins: [String] { skeleton.data.skins.keys.sorted() }

    func setMix(from: String, to: String, duration: TimeInterval) {
        state.mixTimes["\(from)→\(to)"] = duration
    }

    var flipX: Bool {
        get { skeleton.flipX }
        set { skeleton.flipX = newValue; xScale = newValue ? -1 : 1 }
    }

    /// Call once per frame.
    func update(_ dt: TimeInterval) {
        state.update(dt)
        state.apply(to: skeleton)
        applySecondaryMotion(dt)
        syncNodes()
        // Collision last: it reads the pose the renderer just drew.
        collider.refresh()
    }

    /// Damped-spring lag: bones overshoot and settle after their parent moves.
    private func applySecondaryMotion(_ dt: TimeInterval) {
        guard !springs.isEmpty else { return }
        let h = CGFloat(min(dt, 1.0 / 30.0))
        var changed = false
        // Snapshot keys: mutating `springs` while iterating it is undefined.
        for i in springs.keys.sorted() {
            guard var spring = springs[i],
                  skeleton.bones.indices.contains(i) else { continue }
            let parentRotation = skeleton.bones[i].data.parentIndex
                .map { skeleton.bones[$0].worldRotationDegrees } ?? 0
            let delta = parentRotation - spring.lastParentRotation
            spring.lastParentRotation = parentRotation
            // impulse from parent movement, then spring back toward zero
            spring.velocity -= delta * 6
            let accel = -spring.stiffness * spring.offset - spring.damping * spring.velocity
            spring.velocity += accel * h
            spring.offset += spring.velocity * h
            spring.offset = max(-45, min(45, spring.offset))
            skeleton.bones[i].rotation += spring.offset
            springs[i] = spring
            changed = true
        }
        if changed { skeleton.updateWorldTransform() }
    }

    // MARK: Rendering

    private func syncNodes() {
        // Draw order can be animated, so z has to be re-derived each frame rather
        // than fixed at build time. Assigning by position in `drawOrder` keeps the
        // cost to one float write per slot.
        for (z, slotIndex) in skeleton.drawOrder.enumerated()
        where slotNodes.indices.contains(slotIndex) {
            slotNodes[slotIndex]?.zPosition = CGFloat(z)
        }
        for (i, slot) in skeleton.slots.enumerated() {
            guard let container = slotNodes[i] else { continue }
            guard let attName = slot.attachmentName,
                  let att = skeleton.data.attachment(slot: slot.data.name,
                                                     name: attName, skin: skeleton.skin) else {
                container.isHidden = true
                continue
            }
            container.isHidden = false
            let bone = skeleton.bones[slot.data.boneIndex]

            switch att {
            case .region(let image, let ax, let ay, let arot, let aw, let ah, let asx, let asy):
                let sprite: SKSpriteNode
                if slotKinds[i] == .region, let existing = container.children.first as? SKSpriteNode {
                    sprite = existing
                } else {
                    container.removeAllChildren()
                    meshNodes[i] = nil               // drop any stale mesh node
                    sprite = SKSpriteNode()
                    container.addChild(sprite)
                    slotKinds[i] = .region
                }
                if let tex = texture(image), sprite.texture !== tex {
                    sprite.texture = tex
                }
                sprite.size = CGSize(width: aw * asx, height: ah * asy)
                // attachment offset is in bone space → transform by the bone matrix
                let wx = bone.a * ax + bone.c * ay + bone.worldX
                let wy = bone.b * ax + bone.d * ay + bone.worldY
                sprite.position = CGPoint(x: wx, y: wy)
                sprite.zRotation = (bone.worldRotationDegrees + arot) * .pi / 180
                let c = slot.colorRGBA
                sprite.alpha = c.count > 3 ? c[3] : 1
                sprite.color = SKColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
                sprite.colorBlendFactor = (c[0] + c[1] + c[2]) < 2.97 ? 0.6 : 0
                sprite.blendMode = slot.data.additive ? .add : .alpha

            case .mesh(let image, let vertices, _, _, let weights, let mw, let mh):
                // Weighted mesh skinning on the GPU: a warp lattice bound to
                // multiple bones per vertex, so painted limbs deform as one
                // continuous surface instead of hinging at a seam.
                let node: SKSpriteNode
                if slotKinds[i] == .mesh, let existing = meshNodes[i] {
                    node = existing
                } else {
                    container.removeAllChildren()
                    node = SKSpriteNode(texture: texture(image))
                    container.addChild(node)
                    meshNodes[i] = node
                    slotKinds[i] = .mesh
                    skins[i] = nil
                }
                if let tex = texture(image), node.texture !== tex { node.texture = tex }

                // Size from the attachment, falling back to the mesh bounds.
                var size = CGSize(width: mw, height: mh)
                if size.width <= 0 || size.height <= 0 {
                    let xs = vertices.map(\.x), ys = vertices.map(\.y)
                    size = CGSize(width: max((xs.max() ?? 1) - (xs.min() ?? 0), 1),
                                  height: max((ys.max() ?? 1) - (ys.min() ?? 0), 1))
                }
                node.size = size

                if skins[i] == nil {
                    skins[i] = MeshSkinning.prepare(
                        vertices: vertices,
                        weights: weights?.map { $0.map {
                            (bone: $0.bone, offset: $0.offset, weight: $0.weight) } },
                        anchorBone: slot.data.boneIndex,
                        size: size)
                    if let mesh = skins[i] {
                        node.warpGeometry = mesh.sourceGrid
                        // Read the source lattice once — it is static.
                        sourceLattices[i] = MeshSkinning.sourcePositions(of: mesh.sourceGrid)
                        solveScratch[i] = Array(repeating: .zero, count: mesh.bindings.count)
                    }
                }
                if let mesh = skins[i], let source = sourceLattices[i] {
                    var scratch = solveScratch[i] ?? []
                    MeshSkinning.solveWorld(mesh: mesh, skeleton: skeleton,
                                            deform: slot.deform, into: &scratch)
                    solveScratch[i] = scratch
                    let dest = MeshSkinning.unitSpace(scratch, mesh: mesh,
                                                      skeleton: skeleton)
                    if dest.count == source.count {
                        node.warpGeometry = SKWarpGeometryGrid(
                            columns: mesh.cols, rows: mesh.rows,
                            sourcePositions: source,
                            destinationPositions: dest)
                    }
                }
                // The lattice already carries world placement, so the node
                // itself sits on its anchor bone unrotated.
                node.position = CGPoint(x: bone.worldX, y: bone.worldY)
                node.zRotation = bone.worldRotationDegrees * .pi / 180
                let c = slot.colorRGBA
                node.alpha = c.count > 3 ? c[3] : 1
                node.blendMode = slot.data.additive ? .add : .alpha

            case .box:
                container.isHidden = true
            }
        }
    }

    private func worldPoint(_ p: CGPoint, _ bone: Bone) -> CGPoint {
        CGPoint(x: bone.a * p.x + bone.c * p.y + bone.worldX,
                y: bone.b * p.x + bone.d * p.y + bone.worldY)
    }

    /// World-space points of a bounding-box attachment — for gameplay hit
    /// regions that follow the animation (deformed-mesh-aware collision).
    func boxPoints(slot name: String) -> [CGPoint]? {
        guard let si = skeleton.data.slotIndex(named: name) else { return nil }
        let slot = skeleton.slots[si]
        guard let attName = slot.attachmentName,
              case .box(let verts)? = skeleton.data.attachment(slot: name, name: attName,
                                                               skin: skeleton.skin)
        else { return nil }
        let bone = skeleton.bones[slot.data.boneIndex]
        return verts.map { worldPoint($0, bone) }
    }

    /// Light this rig's sprites using each slot's *image name*, so a bundled
    /// `<image>_n` normal map is picked up instead of one inferred from
    /// luminance.
    ///
    /// The generic recursive walk can't do this: an `SKSpriteNode` doesn't know
    /// which asset it was built from, and generated normals guess relief from
    /// brightness — which is wrong exactly where painted art is most deliberate.
    func applyLighting(categories: UInt32 = LightCategory.all,
                       shadows: NormalMapper.ShadowRole = .caster,
                       contrast: CGFloat = 1.6) {
        for i in skeleton.slots.indices {
            guard let att = attachment(ofSlot: i) else { continue }
            let image: String
            switch att {
            case .region(let name, _, _, _, _, _, _, _): image = name
            case .mesh(let name, _, _, _, _, _, _): image = name
            case .box: continue
            }
            let sprite = (slotNodes[i]?.children.first as? SKSpriteNode) ?? meshNodes[i]
            guard let sprite, let tex = sprite.texture else { continue }
            sprite.normalTexture = NormalMapper.normal(forImageNamed: image,
                                                       texture: tex, contrast: contrast)
            sprite.lightingBitMask = categories
            // A rig is a caster, not a receiver. Setting both made every limb
            // shadow the limb behind it, which is the muddy look this fixes.
            sprite.shadowCastBitMask = shadows.cast
            sprite.shadowedBitMask = shadows.receive
        }
    }

    // MARK: - Deformed-mesh collision

    var colliderMode: ColliderMode { collider.mode }
    var colliderHullCount: Int { collider.hulls.count }

    /// Slots currently showing a deformable mesh — the ones where "deformed
    /// collision" is not a figure of speech.
    var meshSlotNames: [String] {
        skeleton.slots.indices.compactMap { i -> String? in
            guard case .mesh? = attachment(ofSlot: i) else { return nil }
            return skeleton.slots[i].data.name
        }
    }

    func setColliderMode(_ mode: ColliderMode, slots: [String] = []) {
        collider.setMode(mode, slots: slots)
    }

    func setColliderDebugDraw(_ on: Bool) {
        collider.setDebugDraw(on)
    }

    /// Hit regions in another node's space (scene space, for gameplay). Falls
    /// back to nothing in `.box` mode — callers keep their own box logic.
    func hitRegions(in target: SKNode) -> [[CGPoint]] {
        collider.hulls(in: target)
    }

    /// Slots that can produce collision geometry, in draw order. An empty
    /// `names` list means "everything visible"; naming slots is how an author
    /// says *the fists and feet matter, the cape doesn't*.
    func collidableSlotIndices(matching names: [String]) -> [Int] {
        skeleton.slots.indices.filter { i in
            guard let att = attachment(ofSlot: i), slotNodes[i]?.isHidden != true
            else { return false }
            // Bounding boxes are hit-only volumes: included when asked for by
            // name, never swept up by "everything".
            if case .box = att, names.isEmpty { return false }
            return names.isEmpty || names.contains(skeleton.slots[i].data.name)
        }
    }

    /// The outline of one slot in this rig's own coordinate space.
    ///
    /// Mesh slots return the solved skinning lattice — the deformed shape
    /// itself. Region slots return the sprite's four transformed corners, so a
    /// rig of cut-out parts still gets per-limb volumes that follow the
    /// animation. Box attachments return their authored vertices.
    func collisionPoints(slotIndex i: Int) -> [CGPoint] {
        guard skeleton.slots.indices.contains(i), let att = attachment(ofSlot: i) else {
            return []
        }
        let slot = skeleton.slots[i]
        guard skeleton.bones.indices.contains(slot.data.boneIndex) else { return [] }
        let bone = skeleton.bones[slot.data.boneIndex]

        switch att {
        case .mesh:
            if let mesh = skins[i] {
                return MeshSkinning.solveWorld(mesh: mesh, skeleton: skeleton,
                                               deform: slot.deform)
            }
            // Not yet prepared (first frame): fall back to the drawn quad.
            if let sprite = meshNodes[i] {
                return Geometry2D.quad(of: sprite, in: self)
            }
            return []

        case .region:
            guard let sprite = slotNodes[i]?.children.first as? SKSpriteNode,
                  sprite.parent != nil else { return [] }
            return Geometry2D.quad(of: sprite, in: self)

        case .box(let verts):
            return verts.map { worldPoint($0, bone) }
        }
    }

    /// The attachment a slot is currently showing, if any.
    private func attachment(ofSlot i: Int) -> AttachmentData? {
        guard skeleton.slots.indices.contains(i) else { return nil }
        let slot = skeleton.slots[i]
        guard let name = slot.attachmentName else { return nil }
        return skeleton.data.attachment(slot: slot.data.name, name: name,
                                        skin: skeleton.skin)
    }
}
