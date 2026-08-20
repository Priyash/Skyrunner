import SpriteKit
import AVFoundation
import QuartzCore

/// Sound: effects, music, and a mixer that remembers what the player set.
///
/// This replaced a seven-line stub that ran `SKAction.playSoundFileNamed` and had
/// no volume, no music, and no way to tell a missing file from a silent one. Three
/// things forced the rewrite:
///
///   * **Volume.** `playSoundFileNamed` has none. A game without a volume control
///     is not shippable, and the control has to reach the effects, not just music.
///   * **Music.** There wasn't any. `AVAudioPlayer` loops sample-accurately and
///     fades natively (`setVolume(_:fadeDuration:)`), which is the whole feature.
///   * **Missing files were invisible.** `play` is deliberately a no-op when a
///     sound is absent, which means a typo behaves exactly like a sound that was
///     never added. `soundNames` and `musicNames` exist so the tests and the asset
///     audit can walk them against the bundle.
///
/// Sounds are synthesized by `Tools/audio_director.py` — `make audio` regenerates
/// the whole set, so a new effect is a few lines of parameters rather than a
/// licensing question.
final class Audio {

    static let shared = Audio()

    /// Every effect the game asks for. Walked by `AssetTests`.
    static let soundNames = [
        "jump", "land", "coin", "stomp", "pop", "hurt", "pound", "dash",
        "spring", "checkpoint", "crusher", "hover", "win", "boss_hit",
        "boss_die", "menu",
    ]

    /// Every music track. `theme_menu` is the front end; the rest are named by
    /// level files, so a level chooses its own music.
    static let musicNames = [
        "theme_menu", "theme_grove", "theme_hollow", "theme_ridge",
        "theme_arena", "theme_evening",
    ]

    // MARK: Mixer

    private enum Key {
        static let sfx = "audio.sfxVolume"
        static let music = "audio.musicVolume"
    }

    // Explicit backing stores rather than `didSet` clamping: assigning a
    // property inside its own `didSet` re-enters the setter, which is a puzzle to
    // read and one edit away from an infinite loop.
    private var storedSFXVolume: Float
    private var storedMusicVolume: Float

    /// 0…1. Persisted, because a player who turns the music down means it.
    var sfxVolume: Float {
        get { storedSFXVolume }
        set {
            storedSFXVolume = max(0, min(1, newValue))
            UserDefaults.standard.set(storedSFXVolume, forKey: Key.sfx)
        }
    }

    var musicVolume: Float {
        get { storedMusicVolume }
        set {
            storedMusicVolume = max(0, min(1, newValue))
            UserDefaults.standard.set(storedMusicVolume, forKey: Key.music)
            // Apply now, or the slider appears dead until the next track starts.
            music?.setVolume(storedMusicVolume * duckScale, fadeDuration: 0.08)
        }
    }

    // MARK: State

    /// A small ring of players per effect, so two coins can overlap.
    ///
    /// One player per sound would cut the first coin off when the second landed —
    /// `AVAudioPlayer` restarts rather than layering. Three is enough for the
    /// densest thing the game does (a coin run) and costs a few hundred KB.
    private var pools: [String: [AVAudioPlayer]] = [:]
    private var cursor: [String: Int] = [:]
    private var music: AVAudioPlayer?
    private var musicName: String?
    private var duckScale: Float = 1
    private var unduckAt: TimeInterval = 0
    /// Sounds that aren't in the bundle, remembered so a missing file costs one
    /// failed load rather than one per play.
    private var missing: Set<String> = []

    private static let poolSize = 3

    private init() {
        let defaults = UserDefaults.standard
        storedSFXVolume = defaults.object(forKey: Key.sfx) as? Float ?? 0.85
        storedMusicVolume = defaults.object(forKey: Key.music) as? Float ?? 0.55

        // `.ambient` on purpose: a platformer must not stop the player's podcast.
        // Failing to configure the session is not worth crashing over — the game
        // just plays through whatever the system default is.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Effects

    /// Play an effect. A missing file is silence, never an error — the same
    /// contract the old implementation had, and what lets the game ship before
    /// every sound exists.
    ///
    /// `node` is unused now that playback goes through `AVAudioPlayer`; it stays
    /// in the signature because every call site passes one and a scene-relative
    /// sound is the obvious next feature.
    func play(_ name: String, on node: SKNode? = nil) {
        guard sfxVolume > 0, !missing.contains(name) else { return }
        guard let player = borrow(name) else { return }
        player.volume = sfxVolume
        player.currentTime = 0
        player.play()
    }

    /// Duck the music briefly — for a boss hit or a level-complete sting, where
    /// the effect has to cut through and the music must get out of the way.
    func duck(to scale: Float = 0.35, for seconds: TimeInterval = 0.6) {
        duckScale = max(0, min(1, scale))
        unduckAt = CACurrentMediaTime() + seconds
        music?.setVolume(musicVolume * duckScale, fadeDuration: 0.08)
    }

    /// Called from the scene's update. Cheap: one comparison unless a duck is
    /// pending.
    func update() {
        guard duckScale < 1, CACurrentMediaTime() >= unduckAt else { return }
        duckScale = 1
        music?.setVolume(musicVolume, fadeDuration: 0.35)
    }

    private func borrow(_ name: String) -> AVAudioPlayer? {
        if let pool = pools[name] {
            guard !pool.isEmpty else { return nil }
            let index = (cursor[name] ?? 0) % pool.count
            cursor[name] = index + 1
            return pool[index]
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            missing.insert(name)
            return nil
        }
        var pool: [AVAudioPlayer] = []
        for _ in 0..<Audio.poolSize {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { break }
            player.prepareToPlay()          // decode now, not on the first frame
            pool.append(player)
        }
        guard !pool.isEmpty else {
            missing.insert(name)
            return nil
        }
        pools[name] = pool
        cursor[name] = 1
        return pool[0]
    }

    // MARK: Music

    /// Start, change, or stop the music.
    ///
    /// Passing the track that is already playing does nothing — worth stating,
    /// because scenes call this from `didMove(to:)` and a restart on every scene
    /// transition would make the soundtrack stutter at every level boundary.
    /// `nil` fades out.
    func playMusic(_ name: String?, fade: TimeInterval = 0.8) {
        guard name != musicName else { return }
        guard let name else {
            stopMusic(fade: fade)
            return
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            // Same rule as effects: missing music is silence.
            stopMusic(fade: fade)
            musicName = nil
            return
        }
        let outgoing = music
        outgoing?.setVolume(0, fadeDuration: fade)
        // Hold the old player alive for the length of its own fade, or the
        // crossfade is a cut.
        if let outgoing {
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { outgoing.stop() }
        }

        player.numberOfLoops = -1           // the tracks are seamless by design
        player.volume = 0
        player.prepareToPlay()
        player.play()
        player.setVolume(musicVolume * duckScale, fadeDuration: fade)
        music = player
        musicName = name
    }

    func stopMusic(fade: TimeInterval = 0.6) {
        guard let player = music else { return }
        player.setVolume(0, fadeDuration: fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { player.stop() }
        music = nil
        musicName = nil
    }

    /// What is playing, for the state document the machine surface publishes.
    var currentMusic: String? { musicName }
}
