import Foundation
import CoreGraphics

/// AnimKit — a from-scratch 2D skeletal animation runtime.
///
/// Data model mirrors the industry-standard structure (Spine/DragonBones), so
/// rigs authored in Spine or in the bundled Rig Editor both load here:
///
///   SkeletonData (shared, immutable)  →  Skeleton (per-instance pose)
///     bones      hierarchy + setup pose
///     slots      draw order + which attachment is shown
///     attachments  region (image), mesh (deformable), or box (hit region)
///     skins      swappable attachment sets
///     ik         inverse-kinematics constraints
///     animations timelines keyed on bones/slots/deform
///
/// Immutable setup data is loaded once and shared by every instance; each game
/// object gets its own `Skeleton` + `AnimationState`. That split is what keeps
/// dozens of animated actors cheap.

// MARK: - Setup data (immutable, shared)

struct BoneData {
    let name: String
    let parentIndex: Int?     // nil = root
    var length: CGFloat = 0
    var x: CGFloat = 0        // setup pose, parent-local
    var y: CGFloat = 0
    var rotation: CGFloat = 0 // degrees
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    /// Shear, in degrees. Skew is what lets a cut-out limb lean into a motion
    /// without the seam sliding — Spine authors it heavily on cloth and hair.
    var shearX: CGFloat = 0
    var shearY: CGFloat = 0
    /// If true this bone ignores parent rotation (useful for floating limbs).
    var inheritRotation: Bool = true
}

/// One bone's pull on one mesh vertex.
struct MeshInfluence {
    let bone: Int
    let offset: CGPoint      // vertex position in that bone's local space
    let weight: CGFloat
}

enum AttachmentData {
    /// A textured quad parented to a slot's bone.
    case region(image: String, x: CGFloat, y: CGFloat, rotation: CGFloat,
                width: CGFloat, height: CGFloat, scaleX: CGFloat, scaleY: CGFloat)
    /// A deformable mesh: vertices in bone space, triangles, UVs, and
    /// optional per-vertex bone weights (Spine weighted meshes). When
    /// `weights` is present each vertex is driven by several bones at once —
    /// true skinning rather than rigid parenting.
    case mesh(image: String, vertices: [CGPoint], uvs: [CGPoint], triangles: [Int],
              weights: [[MeshInfluence]]?, width: CGFloat, height: CGFloat)
    /// Non-rendering hit region.
    case box(vertices: [CGPoint])
}

struct SlotData {
    let name: String
    let boneIndex: Int
    var defaultAttachment: String? = nil
    var colorRGBA: [CGFloat] = [1, 1, 1, 1]
    var additive: Bool = false
}

struct IKConstraintData {
    let name: String
    let boneIndices: [Int]    // 1 = single-bone aim, 2 = two-bone solver
    let targetBoneIndex: Int
    var mix: CGFloat = 1
    var bendPositive: Bool = true
    /// Let the chain stretch when the target is out of reach, instead of
    /// straightening and stopping short — the difference between a leg that
    /// reaches for a ledge and one that gives up.
    var stretch: Bool = false
    /// Distance (points) by which the solve eases off near full extension, so a
    /// leg doesn't snap straight. Spine's "softness".
    var softness: CGFloat = 0
}

final class SkeletonData {
    var bones: [BoneData] = []
    var slots: [SlotData] = []
    /// skin name → (slot name → attachment name → data)
    var skins: [String: [String: [String: AttachmentData]]] = [:]
    var ikConstraints: [IKConstraintData] = []
    var animations: [String: AnimationClip] = [:]
    var defaultSkin = "default"

    func boneIndex(named name: String) -> Int? { bones.firstIndex { $0.name == name } }
    func slotIndex(named name: String) -> Int? { slots.firstIndex { $0.name == name } }

    func attachment(slot: String, name: String, skin: String? = nil) -> AttachmentData? {
        let s = skin ?? defaultSkin
        return skins[s]?[slot]?[name] ?? skins["default"]?[slot]?[name]
    }
}

// MARK: - Runtime pose (per instance)

/// A posed bone. `world*` values are recomputed each frame by updateWorldTransform().
struct Bone {
    let data: BoneData
    var x: CGFloat
    var y: CGFloat
    var rotation: CGFloat
    var scaleX: CGFloat
    var scaleY: CGFloat
    var shearX: CGFloat
    var shearY: CGFloat

    // world transform (a,b,c,d,worldX,worldY) — a 2x3 affine matrix
    var a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1
    var worldX: CGFloat = 0, worldY: CGFloat = 0

    init(data: BoneData) {
        self.data = data
        x = data.x; y = data.y
        rotation = data.rotation
        scaleX = data.scaleX; scaleY = data.scaleY
        shearX = data.shearX; shearY = data.shearY
    }

    mutating func resetToSetup() {
        x = data.x; y = data.y
        rotation = data.rotation
        scaleX = data.scaleX; scaleY = data.scaleY
        shearX = data.shearX; shearY = data.shearY
    }

    var worldRotationDegrees: CGFloat { atan2(b, a) * 180 / .pi }
    var worldScaleX: CGFloat { sqrt(a * a + b * b) }
}

struct Slot {
    let data: SlotData
    var attachmentName: String?
    var colorRGBA: [CGFloat]
    /// Per-vertex deform offsets for mesh attachments (bone space).
    var deform: [CGPoint] = []

    init(data: SlotData) {
        self.data = data
        attachmentName = data.defaultAttachment
        colorRGBA = data.colorRGBA
    }
}

/// A posable skeleton instance.
final class Skeleton {
    let data: SkeletonData
    var bones: [Bone]
    var slots: [Slot]
    var skin: String
    var flipX = false
    /// Slot indices in draw order. Animated by `DrawOrderTimeline`, which is how
    /// a hand passes in front of the body mid-punch and behind it on the way back.
    var drawOrder: [Int]
    /// Per-instance IK mix, so a constraint can be faded in by an animation
    /// instead of being on for the whole clip.
    var ikMix: [CGFloat]

    init(data: SkeletonData) {
        self.data = data
        bones = data.bones.map(Bone.init)
        slots = data.slots.map(Slot.init)
        skin = data.defaultSkin
        drawOrder = Array(data.slots.indices)
        ikMix = data.ikConstraints.map(\.mix)
    }

    func setToSetupPose() {
        drawOrder = Array(data.slots.indices)
        for i in ikMix.indices where i < data.ikConstraints.count {
            ikMix[i] = data.ikConstraints[i].mix
        }
        for i in bones.indices { bones[i].resetToSetup() }
        for i in slots.indices {
            slots[i].attachmentName = slots[i].data.defaultAttachment
            slots[i].colorRGBA = slots[i].data.colorRGBA
            slots[i].deform = []
        }
    }

    /// Compose local transforms down the hierarchy, then apply IK.
    /// Bones are stored parent-before-child so one pass suffices.
    func updateWorldTransform() {
        for i in bones.indices {
            var bone = bones[i]
            let (la, lb, lc, ld) = Skeleton.localAxes(bone)

            if let p = bone.data.parentIndex {
                let parent = bones[p]
                bone.a = parent.a * la + parent.c * lb
                bone.b = parent.b * la + parent.d * lb
                bone.c = parent.a * lc + parent.c * ld
                bone.d = parent.b * lc + parent.d * ld
                bone.worldX = parent.a * bone.x + parent.c * bone.y + parent.worldX
                bone.worldY = parent.b * bone.x + parent.d * bone.y + parent.worldY
                if !bone.data.inheritRotation {
                    // Keep world orientation independent of the parent's rotation
                    bone.a = la; bone.b = lb; bone.c = lc; bone.d = ld
                }
            } else {
                bone.a = la; bone.b = lb; bone.c = lc; bone.d = ld
                bone.worldX = bone.x; bone.worldY = bone.y
            }
            bones[i] = bone
        }

        for (index, ik) in data.ikConstraints.enumerated() {
            var constraint = ik
            if ikMix.indices.contains(index) { constraint.mix = ikMix[index] }
            applyIK(constraint)
            // Re-solve descendants of the affected chain. Bones are stored
            // parent-before-child, so everything after the last touched bone
            // may depend on it. Clamp the range: a chain ending on the final
            // bone would otherwise form an invalid Range.
            if let last = constraint.boneIndices.max(), last + 1 < bones.count {
                for i in (last + 1)..<bones.count { recomputeWorld(i) }
            }
        }
    }

    /// A bone's local 2×2, rotation + scale + shear.
    ///
    /// Shear has to enter *here* rather than as a post-multiply, because it skews
    /// the axes the children inherit — applying it later would shear the art but
    /// not the hierarchy, and the seams would slide apart.
    static func localAxes(_ bone: Bone) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let rot = bone.rotation * .pi / 180
        let shx = bone.shearX * .pi / 180
        let shy = bone.shearY * .pi / 180
        let a = cos(rot + shy) * bone.scaleX
        let b = sin(rot + shy) * bone.scaleX
        let c = cos(rot + .pi / 2 + shx) * bone.scaleY
        let d = sin(rot + .pi / 2 + shx) * bone.scaleY
        return (a, b, c, d)
    }

    private func recomputeWorld(_ i: Int) {
        var bone = bones[i]
        let (la, lb, lc, ld) = Skeleton.localAxes(bone)
        if let p = bone.data.parentIndex {
            let parent = bones[p]
            bone.a = parent.a * la + parent.c * lb
            bone.b = parent.b * la + parent.d * lb
            bone.c = parent.a * lc + parent.c * ld
            bone.d = parent.b * lc + parent.d * ld
            bone.worldX = parent.a * bone.x + parent.c * bone.y + parent.worldX
            bone.worldY = parent.b * bone.x + parent.d * bone.y + parent.worldY
        } else {
            bone.a = la; bone.b = lb; bone.c = lc; bone.d = ld
            bone.worldX = bone.x; bone.worldY = bone.y
        }
        bones[i] = bone
    }

    /// One-bone aim, or the classic analytic two-bone solver (law of cosines).
    private func applyIK(_ ik: IKConstraintData) {
        guard ik.mix > 0, bones.indices.contains(ik.targetBoneIndex) else { return }
        let target = bones[ik.targetBoneIndex]

        if ik.boneIndices.count == 1 {
            let i = ik.boneIndices[0]
            guard bones.indices.contains(i) else { return }
            var bone = bones[i]
            let dx = target.worldX - bone.worldX
            let dy = target.worldY - bone.worldY
            let desired = atan2(dy, dx) * 180 / .pi
            let delta = shortestDelta(from: bone.worldRotationDegrees, to: desired)
            bone.rotation += delta * ik.mix
            bones[i] = bone
            recomputeWorld(i)
            return
        }

        guard ik.boneIndices.count >= 2 else { return }
        let pi = ik.boneIndices[0], ci = ik.boneIndices[1]
        guard bones.indices.contains(pi), bones.indices.contains(ci) else { return }
        var parent = bones[pi]
        var child = bones[ci]
        let l1 = max(parent.data.length, 0.0001)
        let l2 = max(child.data.length, 0.0001)

        let dx = target.worldX - parent.worldX
        let dy = target.worldY - parent.worldY
        let dist = max(sqrt(dx * dx + dy * dy), 0.0001)
        let baseAngle = atan2(dy, dx)

        var a1: CGFloat, a2: CGFloat
        // Softness eases the last few points of extension so the chain doesn't
        // snap straight; stretch lets it lengthen instead of falling short.
        var reach = l1 + l2
        if ik.softness > 0, dist > reach - ik.softness {
            let over = min(dist - (reach - ik.softness), ik.softness)
            reach -= ik.softness * (1 - (1 - over / ik.softness) * (1 - over / ik.softness))
        }
        if dist >= reach {
            a1 = baseAngle
            a2 = 0
            if ik.stretch, reach > 0.0001 {
                let scale = min(dist / reach, 1.6)
                parent.scaleX *= scale
                child.scaleX *= scale
            }
        } else {
            let cosA2 = max(-1, min(1, (dist * dist - l1 * l1 - l2 * l2) / (2 * l1 * l2)))
            a2 = acos(cosA2) * (ik.bendPositive ? 1 : -1)
            let cosA1 = max(-1, min(1, (dist * dist + l1 * l1 - l2 * l2) / (2 * dist * l1)))
            a1 = baseAngle - acos(cosA1) * (ik.bendPositive ? 1 : -1)
        }

        let parentTargetDeg = a1 * 180 / .pi
        let d1 = shortestDelta(from: parent.worldRotationDegrees, to: parentTargetDeg)
        parent.rotation += d1 * ik.mix
        bones[pi] = parent
        recomputeWorld(pi)
        recomputeWorld(ci)

        child = bones[ci]
        let childTargetDeg = (a1 + a2) * 180 / .pi
        let d2 = shortestDelta(from: child.worldRotationDegrees, to: childTargetDeg)
        child.rotation += d2 * ik.mix
        bones[ci] = child
        recomputeWorld(ci)
    }

    private func shortestDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    func bone(named name: String) -> Bone? {
        guard let i = data.boneIndex(named: name) else { return nil }
        return bones[i]
    }

    func setBoneRotation(_ name: String, _ degrees: CGFloat) {
        guard let i = data.boneIndex(named: name) else { return }
        bones[i].rotation = degrees
    }
}
