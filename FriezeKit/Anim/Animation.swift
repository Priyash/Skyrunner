import Foundation
import CoreGraphics

// MARK: - Keyframes & curves

enum Curve {
    case linear
    case stepped
    /// Cubic Bézier ease, as authored in Spine's curve editor.
    case bezier(cx1: CGFloat, cy1: CGFloat, cx2: CGFloat, cy2: CGFloat)

    /// Map normalized time → normalized value.
    func apply(_ t: CGFloat) -> CGFloat {
        switch self {
        case .linear: return t
        case .stepped: return 0
        case .bezier(let cx1, let cy1, let cx2, let cy2):
            // Newton iterations on x(s) = t, then evaluate y(s).
            var s = t
            for _ in 0..<6 {
                let mt = 1 - s
                let x = 3 * mt * mt * s * cx1 + 3 * mt * s * s * cx2 + s * s * s
                let dx = 3 * mt * mt * cx1 + 6 * mt * s * (cx2 - cx1) + 3 * s * s * (1 - cx2)
                if abs(dx) < 0.0001 { break }
                s -= (x - t) / dx
                s = max(0, min(1, s))
            }
            let mt = 1 - s
            return 3 * mt * mt * s * cy1 + 3 * mt * s * s * cy2 + s * s * s
        }
    }
}

struct Keyframe<T> {
    let time: TimeInterval
    let value: T
    var curve: Curve = .linear
}

// MARK: - Timelines

protocol Timeline {
    var duration: TimeInterval { get }
    /// alpha 0…1 = mix weight; additive = add on top of the current pose.
    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool)
}

/// Shared interpolation helper for scalar keyframe tracks.
private func sample(_ keys: [Keyframe<CGFloat>], _ time: TimeInterval) -> CGFloat? {
    guard let first = keys.first else { return nil }
    if time <= first.time { return first.value }
    guard let last = keys.last else { return nil }
    if time >= last.time { return last.value }
    var i = 0
    while i < keys.count - 1, keys[i + 1].time <= time { i += 1 }
    let k0 = keys[i], k1 = keys[i + 1]
    let span = max(k1.time - k0.time, 0.0001)
    let t = CGFloat((time - k0.time) / span)
    let e = k0.curve.apply(t)
    return k0.value + (k1.value - k0.value) * e
}

/// Bone rotation over time (degrees).
struct RotateTimeline: Timeline {
    let boneIndex: Int
    let keys: [Keyframe<CGFloat>]
    var duration: TimeInterval { keys.last?.time ?? 0 }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.bones.indices.contains(boneIndex),
              let v = sample(keys, time) else { return }
        var bone = skeleton.bones[boneIndex]
        if additive {
            bone.rotation += v * alpha
        } else {
            let setup = bone.data.rotation
            var delta = (setup + v) - bone.rotation
            delta = delta.truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            bone.rotation += delta * alpha
        }
        skeleton.bones[boneIndex] = bone
    }
}

/// Bone translation over time (parent-local points).
struct TranslateTimeline: Timeline {
    let boneIndex: Int
    let xKeys: [Keyframe<CGFloat>]
    let yKeys: [Keyframe<CGFloat>]
    var duration: TimeInterval { max(xKeys.last?.time ?? 0, yKeys.last?.time ?? 0) }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.bones.indices.contains(boneIndex) else { return }
        var bone = skeleton.bones[boneIndex]
        if let dx = sample(xKeys, time) {
            let target = additive ? bone.x + dx : bone.data.x + dx
            bone.x += (target - bone.x) * alpha
        }
        if let dy = sample(yKeys, time) {
            let target = additive ? bone.y + dy : bone.data.y + dy
            bone.y += (target - bone.y) * alpha
        }
        skeleton.bones[boneIndex] = bone
    }
}

/// Bone scale over time.
struct ScaleTimeline: Timeline {
    let boneIndex: Int
    let xKeys: [Keyframe<CGFloat>]
    let yKeys: [Keyframe<CGFloat>]
    var duration: TimeInterval { max(xKeys.last?.time ?? 0, yKeys.last?.time ?? 0) }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.bones.indices.contains(boneIndex) else { return }
        var bone = skeleton.bones[boneIndex]
        if let sx = sample(xKeys, time) {
            let target = additive ? bone.scaleX + (sx - 1) : bone.data.scaleX * sx
            bone.scaleX += (target - bone.scaleX) * alpha
        }
        if let sy = sample(yKeys, time) {
            let target = additive ? bone.scaleY + (sy - 1) : bone.data.scaleY * sy
            bone.scaleY += (target - bone.scaleY) * alpha
        }
        skeleton.bones[boneIndex] = bone
    }
}

/// Bone shear over time — the skew that keeps cut-out limbs from reading as
/// rigid boards when they lean into a motion.
struct ShearTimeline: Timeline {
    let boneIndex: Int
    let xKeys: [Keyframe<CGFloat>]
    let yKeys: [Keyframe<CGFloat>]
    var duration: TimeInterval { max(xKeys.last?.time ?? 0, yKeys.last?.time ?? 0) }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.bones.indices.contains(boneIndex) else { return }
        var bone = skeleton.bones[boneIndex]
        if let sx = sample(xKeys, time) {
            let target = additive ? bone.shearX + sx : bone.data.shearX + sx
            bone.shearX += (target - bone.shearX) * alpha
        }
        if let sy = sample(yKeys, time) {
            let target = additive ? bone.shearY + sy : bone.data.shearY + sy
            bone.shearY += (target - bone.shearY) * alpha
        }
        skeleton.bones[boneIndex] = bone
    }
}

/// Reorders slots mid-clip.
///
/// Without it, a punching hand can only ever be in front of the body or behind
/// it for the whole animation; with it, the hand passes in front on the way out
/// and behind on the way back, which is most of what sells a Rayman punch.
struct DrawOrderTimeline: Timeline {
    /// Each key is a complete slot order (indices), which is how Spine exports it
    /// — a delta list would have to be replayed from the clip start to be correct.
    let keys: [Keyframe<[Int]>]
    var duration: TimeInterval { keys.last?.time ?? 0 }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        // Order is discrete: there is no half-way between two draw orders, so the
        // strongest track wins outright rather than blending.
        guard alpha > 0.5, let first = keys.first else { return }
        var order = first.value
        for k in keys where k.time <= time { order = k.value }
        guard order.count == skeleton.slots.count else { return }
        skeleton.drawOrder = order
    }
}

/// Fades an IK constraint in and out.
struct IKTimeline: Timeline {
    let constraintIndex: Int
    let keys: [Keyframe<CGFloat>]
    var duration: TimeInterval { keys.last?.time ?? 0 }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.ikMix.indices.contains(constraintIndex),
              let v = sample(keys, time) else { return }
        let current = skeleton.ikMix[constraintIndex]
        skeleton.ikMix[constraintIndex] = current + (v - current) * alpha
    }
}

/// Swap which attachment a slot shows (stepped by nature).
struct AttachmentTimeline: Timeline {
    let slotIndex: Int
    let keys: [Keyframe<String?>]
    var duration: TimeInterval { keys.last?.time ?? 0 }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard alpha > 0.5, skeleton.slots.indices.contains(slotIndex),
              let first = keys.first else { return }
        var value = first.value
        for k in keys where k.time <= time { value = k.value }
        skeleton.slots[slotIndex].attachmentName = value
    }
}

/// Slot tint/alpha over time.
struct ColorTimeline: Timeline {
    let slotIndex: Int
    let keys: [Keyframe<[CGFloat]>]
    var duration: TimeInterval { keys.last?.time ?? 0 }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.slots.indices.contains(slotIndex), let first = keys.first else { return }
        if keys.count == 1 || time <= first.time {
            skeleton.slots[slotIndex].colorRGBA = first.value
            return
        }
        var i = 0
        while i < keys.count - 1, keys[i + 1].time <= time { i += 1 }
        if i == keys.count - 1 {
            skeleton.slots[slotIndex].colorRGBA = keys[i].value
            return
        }
        let k0 = keys[i], k1 = keys[i + 1]
        let t = CGFloat((time - k0.time) / max(k1.time - k0.time, 0.0001))
        let e = k0.curve.apply(t)
        var out: [CGFloat] = []
        for c in 0..<4 {
            let a = k0.value[c], b = k1.value[c]
            out.append(a + (b - a) * e)
        }
        let cur = skeleton.slots[slotIndex].colorRGBA
        skeleton.slots[slotIndex].colorRGBA = (0..<4).map { cur[$0] + (out[$0] - cur[$0]) * alpha }
    }
}

/// Mesh vertex deformation (free-form warping of hand-drawn art).
struct DeformTimeline: Timeline {
    let slotIndex: Int
    let keys: [Keyframe<[CGPoint]>]
    var duration: TimeInterval { keys.last?.time ?? 0 }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        guard skeleton.slots.indices.contains(slotIndex), let first = keys.first else { return }
        var verts = first.value
        if keys.count > 1, time > first.time {
            var i = 0
            while i < keys.count - 1, keys[i + 1].time <= time { i += 1 }
            if i < keys.count - 1 {
                let k0 = keys[i], k1 = keys[i + 1]
                let t = CGFloat((time - k0.time) / max(k1.time - k0.time, 0.0001))
                let e = k0.curve.apply(t)
                verts = zip(k0.value, k1.value).map {
                    CGPoint(x: $0.x + ($1.x - $0.x) * e, y: $0.y + ($1.y - $0.y) * e)
                }
            } else {
                verts = keys[i].value
            }
        }
        let cur = skeleton.slots[slotIndex].deform
        if cur.count == verts.count, alpha < 1 {
            skeleton.slots[slotIndex].deform = zip(cur, verts).map {
                CGPoint(x: $0.x + ($1.x - $0.x) * alpha, y: $0.y + ($1.y - $0.y) * alpha)
            }
        } else {
            skeleton.slots[slotIndex].deform = verts
        }
    }
}

/// Fires named events at times (footsteps, SFX, hit frames).
struct EventTimeline: Timeline {
    let keys: [Keyframe<String>]
    var duration: TimeInterval { keys.last?.time ?? 0 }
    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {}
    func events(from: TimeInterval, to: TimeInterval) -> [String] {
        keys.filter { $0.time > from && $0.time <= to }.map(\.value)
    }
}

// MARK: - Clip

final class AnimationClip {
    let name: String
    let timelines: [Timeline]
    let duration: TimeInterval
    var loops: Bool

    init(name: String, timelines: [Timeline], loops: Bool = true) {
        self.name = name
        self.timelines = timelines
        self.duration = timelines.map(\.duration).max() ?? 0
        self.loops = loops
    }

    func apply(to skeleton: Skeleton, time: TimeInterval, alpha: CGFloat, additive: Bool) {
        for t in timelines { t.apply(to: skeleton, time: time, alpha: alpha, additive: additive) }
    }

    var eventTimeline: EventTimeline? { timelines.compactMap { $0 as? EventTimeline }.first }
}

// MARK: - Animation state (tracks, crossfade, additive layers)

/// Plays clips on numbered tracks. Track 0 is the base pose; higher tracks
/// layer on top (set `additive` for breathing//lean-style overlays). Crossfade
/// between clips on the same track happens automatically via `mixDuration`.
/// How a track combines with what is already posed.
///
/// `replace` is the ordinary case. `add` layers a delta on top — the airborne
/// lean over a run cycle. `first` only writes where nothing has written yet, so a
/// low-priority idle can fill in the bones a higher track leaves alone instead of
/// fighting it.
enum MixBlend { case replace, add, first }

final class AnimationState {
    final class TrackEntry {
        var clip: AnimationClip
        /// Per-track, so two instances of the same clip can loop differently —
        /// mutating `clip.loops` would leak across every actor sharing it.
        var loops: Bool
        var time: TimeInterval = 0
        var alpha: CGFloat = 1
        var additive: Bool = false
        var blend: MixBlend = .replace
        var timeScale: CGFloat = 1
        /// Previous clip being crossfaded out.
        var mixingFrom: TrackEntry?
        var mixDuration: TimeInterval = 0
        var mixTime: TimeInterval = 0
        var lastAppliedTime: TimeInterval = 0

        init(clip: AnimationClip, loops: Bool) {
            self.clip = clip
            self.loops = loops
        }

        /// True once a non-looping clip has played through.
        var isComplete: Bool { !loops && time >= clip.duration }
    }

    private(set) var tracks: [Int: TrackEntry] = [:]
    /// Default crossfade used when a track switches clips.
    var defaultMix: TimeInterval = 0.16
    /// Per-pair overrides, keyed "from→to" — Spine's "mix times".
    var mixTimes: [String: TimeInterval] = [:]
    var onEvent: ((String) -> Void)?

    func setAnimation(_ clip: AnimationClip, track: Int = 0,
                      loop: Bool? = nil, additive: Bool = false, alpha: CGFloat = 1,
                      blend: MixBlend? = nil) {
        let entry = TrackEntry(clip: clip, loops: loop ?? clip.loops)
        entry.additive = additive
        entry.blend = blend ?? (additive ? .add : .replace)
        entry.alpha = alpha
        if let current = tracks[track], current.clip !== clip {
            entry.mixingFrom = current
            entry.mixDuration = mixTimes["\(current.clip.name)→\(clip.name)"] ?? defaultMix
        }
        tracks[track] = entry
    }

    func clearTrack(_ track: Int) { tracks[track] = nil }

    func isPlaying(_ name: String, track: Int = 0) -> Bool {
        tracks[track]?.clip.name == name
    }

    func update(_ dt: TimeInterval) {
        for (_, entry) in tracks {
            let prev = entry.time
            entry.time += dt * Double(entry.timeScale)
            if entry.loops, entry.clip.duration > 0 {
                entry.time = entry.time.truncatingRemainder(dividingBy: entry.clip.duration)
            } else {
                entry.time = min(entry.time, entry.clip.duration)
            }
            if let events = entry.clip.eventTimeline, let cb = onEvent {
                let from = entry.time < prev ? -1 : prev   // handle loop wrap
                for e in events.events(from: from, to: entry.time) { cb(e) }
            }
            if let from = entry.mixingFrom {
                entry.mixTime += dt
                from.time += dt * Double(from.timeScale)
                if from.loops, from.clip.duration > 0 {
                    from.time = from.time.truncatingRemainder(dividingBy: from.clip.duration)
                }
                if entry.mixTime >= entry.mixDuration { entry.mixingFrom = nil }
            }
        }
    }

    /// Reset to setup, then apply tracks in order so higher tracks layer on top.
    func apply(to skeleton: Skeleton) {
        skeleton.setToSetupPose()
        for key in tracks.keys.sorted() {
            guard let entry = tracks[key] else { continue }
            var weight = entry.alpha
            if let from = entry.mixingFrom, entry.mixDuration > 0 {
                let t = CGFloat(min(1, entry.mixTime / entry.mixDuration))
                from.clip.apply(to: skeleton, time: from.time,
                                alpha: entry.alpha * (1 - t), additive: from.additive)
                weight = entry.alpha * t
            }
            // `first` writes only where an earlier track hasn't: apply it with
            // full weight *before* the others on the bones it owns, which for a
            // fill-in idle is the whole point.
            let additive = entry.blend == .add || entry.additive
            entry.clip.apply(to: skeleton, time: entry.time,
                             alpha: entry.blend == .first ? min(weight, 1) : weight,
                             additive: additive)
        }
        skeleton.updateWorldTransform()
    }
}
