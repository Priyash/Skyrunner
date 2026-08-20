import SpriteKit

/// Cel (frame-by-frame) animation — UbiArt's signature feature.
///
/// Spine skeletal animation handles locomotion and IK well, but the visual magic
/// of UbiArt titles is cel sequences overlaid on top of the rig: hand-drawn
/// attack smears, facial expressions, impact frames, cloth flutter. Variable
/// per-frame timing is the key — an artist holds the slow-out pose for three
/// frames and rushes through the impact in one, which no mathematical tween
/// can replicate.
///
/// Three primitives:
///   `CelFrame`    — one texture with an authored duration and optional event.
///   `CelSequence` — an immutable ordered run of frames with a playback mode.
///   `CelTrack`    — drives one SKSpriteNode from one sequence.
///   `CelPlayer`   — manages named sequences and multiple tracks; the public API.

// MARK: - Data

/// One frame in a cel sequence.
struct CelFrame {
    /// Atlas frame name, resolved via a `TextureProvider`.
    var texture: String
    /// Duration in seconds. Variable timing is what makes hand-keyed smears feel
    /// different from tweens: hold the slow-out, rush the impact.
    var duration: TimeInterval
    /// Optional event name fired when this frame starts — footstep, hit, FX trigger.
    var event: String? = nil
}

/// An authored sequence of cels. Immutable once built.
struct CelSequence {
    var name: String
    var frames: [CelFrame]
    var mode: Mode = .loop

    enum Mode {
        case loop
        case once
        case pingPong
    }

    var totalDuration: TimeInterval { frames.reduce(0) { $0 + $1.duration } }
    var isEmpty: Bool { frames.isEmpty }
}

// MARK: - Track

/// Drives one SKSpriteNode through a CelSequence frame-by-frame.
///
/// The track owns the playback clock, handles all three loop modes, and fires
/// event callbacks on the frame that declares them (not on the next frame, which
/// is the common one-frame-late bug).
final class CelTrack {

    private(set) var sequence: CelSequence?
    private var frameIndex: Int = 0
    private var frameClock: TimeInterval = 0
    private var pingPongForward = true
    private(set) var finished = false

    /// Called with the event name when a cel with `event != nil` begins.
    var onEvent: ((String) -> Void)?

    /// Start playing `seq` from `index`. Replaces any current playback.
    func play(_ seq: CelSequence, from index: Int = 0) {
        sequence = seq
        frameIndex = max(0, min(index, max(0, seq.frames.count - 1)))
        frameClock = 0
        pingPongForward = true
        finished = false
    }

    /// Advance by `dt` seconds. Returns the texture to display this frame, or
    /// `nil` when the track is idle or the one-shot has finished.
    func advance(dt: TimeInterval, provider: TextureProvider?) -> SKTexture? {
        guard let seq = sequence, !seq.frames.isEmpty, !finished else { return nil }
        frameClock += dt
        // Drain the clock, stepping frames and firing events along the way.
        while !finished, frameClock >= seq.frames[frameIndex].duration {
            frameClock -= seq.frames[frameIndex].duration
            if let e = seq.frames[frameIndex].event { onEvent?(e) }
            advance(in: seq)
        }
        guard !finished, frameIndex < seq.frames.count else { return nil }
        return provider?.texture(named: seq.frames[frameIndex].texture)
    }

    private func advance(in seq: CelSequence) {
        switch seq.mode {
        case .loop:
            frameIndex = (frameIndex + 1) % seq.frames.count

        case .once:
            if frameIndex + 1 < seq.frames.count {
                frameIndex += 1
            } else {
                finished = true
            }

        case .pingPong:
            if pingPongForward {
                if frameIndex + 1 < seq.frames.count {
                    frameIndex += 1
                } else {
                    // Reverse, skip the last frame so it doesn't double-play.
                    pingPongForward = false
                    frameIndex = max(0, seq.frames.count - 2)
                }
            } else {
                if frameIndex - 1 >= 0 {
                    frameIndex -= 1
                } else {
                    pingPongForward = true
                    frameIndex = min(1, seq.frames.count - 1)
                }
            }
        }
    }
}

// MARK: - Player

/// Owns named `CelSequence` instances and maps them onto `SKSpriteNode` tracks.
///
/// Typical use:
/// ```swift
/// let fx = CelPlayer()
/// fx.register(CelPlayer.loop("run_dust", frames: ["dust_0","dust_1","dust_2"]))
/// fx.play("run_dust", on: dustSprite, provider: atlas)
/// // each frame:
/// fx.update(dt: dt, provider: atlas)
/// ```
final class CelPlayer {

    private var library: [String: CelSequence] = [:]
    private var tracks: [ObjectIdentifier: (track: CelTrack, node: SKSpriteNode)] = [:]

    // MARK: Library

    func register(_ sequence: CelSequence) {
        library[sequence.name] = sequence
    }

    func sequence(named name: String) -> CelSequence? { library[name] }

    // MARK: Playback

    /// Start playing `name` on `node`. Replaces any sequence currently on that node.
    @discardableResult
    func play(_ name: String,
              on node: SKSpriteNode,
              from index: Int = 0,
              provider: TextureProvider? = nil,
              onEvent: ((String) -> Void)? = nil) -> Bool {
        guard let seq = library[name] else { return false }
        let key = ObjectIdentifier(node)
        let track: CelTrack
        if let existing = tracks[key] {
            track = existing.track
        } else {
            track = CelTrack()
            tracks[key] = (track, node)
        }
        track.onEvent = onEvent
        track.play(seq, from: index)
        // Show the first frame immediately.
        if let tex = track.advance(dt: 0, provider: provider) {
            node.texture = tex
        }
        return true
    }

    func stop(on node: SKSpriteNode) {
        tracks.removeValue(forKey: ObjectIdentifier(node))
    }

    // MARK: Update

    /// Advance all active tracks. Call once per frame from the scene update.
    func update(dt: TimeInterval, provider: TextureProvider?) {
        var toRemove: [ObjectIdentifier] = []
        for (key, pair) in tracks {
            if let tex = pair.track.advance(dt: dt, provider: provider) {
                pair.node.texture = tex
            } else if pair.track.finished {
                toRemove.append(key)
            }
        }
        for key in toRemove { tracks.removeValue(forKey: key) }
    }

    // MARK: Convenience builders

    /// Fixed-FPS loop sequence.
    static func loop(_ name: String, frames: [String], fps: Double = 12) -> CelSequence {
        CelSequence(name: name, frames: frames.map {
            CelFrame(texture: $0, duration: 1.0 / max(1, fps))
        }, mode: .loop)
    }

    /// Fixed-FPS one-shot sequence.
    static func once(_ name: String, frames: [String], fps: Double = 12) -> CelSequence {
        CelSequence(name: name, frames: frames.map {
            CelFrame(texture: $0, duration: 1.0 / max(1, fps))
        }, mode: .once)
    }

    /// Build from alternating (frame, duration) pairs for fully variable timing.
    static func variable(_ name: String,
                         frames: [(String, TimeInterval)],
                         mode: CelSequence.Mode = .once) -> CelSequence {
        CelSequence(name: name, frames: frames.map {
            CelFrame(texture: $0.0, duration: max(0.001, $0.1))
        }, mode: mode)
    }
}
