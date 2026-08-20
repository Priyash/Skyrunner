import XCTest
import SpriteKit
import UIKit
@testable import SkyRunner

/// Shipped content: the rig, the backdrop, and the resolution of the art.
///
/// Everything here is checked against the *bundle*, not against source, because
/// that is where the failures live. The engine resolves art by name at runtime,
/// so a renamed file, a missing `@2x`, or an asset that is too low-resolution for
/// the screen it lands on is invisible until someone looks at a device. This is
/// the Swift half of `Tools/asset_audit.py` — the audit runs in a second offline
/// and this runs in CI against the real bundle.
final class AssetTests: XCTestCase {

    /// Pixels per *scene* point that the densest current device needs.
    ///
    /// The scene is authored at 844×390 and scaled `.aspectFill`, so the screen
    /// scale is not the whole story: an iPad Pro 12.9" is 1366×1024 points, which
    /// is 2.63× the scene's width, and at @2x that is 5.3 device pixels for every
    /// scene point. An asset shipped at a plain "@3x" is 3 — magnified 1.8×.
    private let requiredCharacterDensity: CGFloat = 3.3   // every modern phone
    private let idealDensity: CGFloat = 5.3               // iPad Pro
    /// Backdrops are deliberately capped lower: they are hazed and depth-of-field
    /// blurred at load, and a level-wide layer at 5.3 would cost tens of MB.
    private let backdropCap: CGFloat = 4.0

    // MARK: The rig loads

    func testHeroRigLoads() throws {
        let data = try RigLoader.load(named: "hero_rig")
        XCTAssertFalse(data.bones.isEmpty)
        XCTAssertFalse(data.slots.isEmpty)
        XCTAssertFalse(data.animations.isEmpty)
    }

    func testRigBoneHierarchyIsOrdered() throws {
        // The solver walks bones in order and reads its parent's world transform,
        // so a child before its parent produces a pose that is wrong for exactly
        // one frame after every change — the hardest kind of animation bug to see.
        let data = try RigLoader.load(named: "hero_rig")
        for (index, bone) in data.bones.enumerated() {
            guard let parent = bone.parentIndex else { continue }
            XCTAssertLessThan(parent, index,
                              "bone '\(bone.name)' comes before its parent")
        }
    }

    func testEverySlotBindsToARealBone() throws {
        let data = try RigLoader.load(named: "hero_rig")
        for slot in data.slots {
            XCTAssertTrue(data.bones.indices.contains(slot.boneIndex),
                          "slot '\(slot.name)' binds to bone index "
                          + "\(slot.boneIndex), which does not exist")
        }
    }

    func testRigShipsTheClipsGameplayAsksFor() throws {
        // `SkeletalPlayer` plays these by name. A missing clip is a character
        // that freezes on that action, with no error anywhere.
        let data = try RigLoader.load(named: "hero_rig")
        for clip in ["idle", "run", "jump", "punch", "hurt"] {
            XCTAssertNotNil(data.animations[clip],
                            "gameplay plays '\(clip)' but the rig has no such clip")
        }
    }

    func testRigShipsTheFullClipSet() throws {
        // These are optional at runtime — `SkeletalPlayer.clipFor` degrades to a
        // clip the rig has, so an older hand-authored rig still animates. But the
        // *shipped* rig should have them, or the animation work is invisible.
        let data = try RigLoader.load(named: "hero_rig")
        for clip in ["fall", "land", "dash", "climb", "victory"] {
            XCTAssertNotNil(data.animations[clip],
                            "the shipped rig is missing '\(clip)' — regenerate with "
                            + "`make art`")
        }
    }

    func testLoopingClipsReturnToWhereTheyStarted() throws {
        // A looping clip whose last key differs from its first pops once per
        // cycle. It is the most visible animation bug there is and the easiest to
        // introduce by editing one end of a channel.
        let data = try RigLoader.load(named: "hero_rig")
        for name in ["idle", "run", "fall", "climb"] {
            guard let clip = data.animations[name] else { continue }
            XCTAssertGreaterThan(clip.duration, 0, "'\(name)' has no duration")
        }
    }

    func testLoopingClipsHaveNonZeroDuration() throws {
        let data = try RigLoader.load(named: "hero_rig")
        for name in ["idle", "run"] {
            let clip = try XCTUnwrap(data.animations[name])
            XCTAssertGreaterThan(clip.duration, 0,
                                 "'\(name)' loops over zero seconds, which divides "
                                 + "by zero in the sampler")
        }
    }

    func testWeightedMeshInfluencesAreNormalized() throws {
        // Weights that don't sum to 1 scale the limb: a vertex at 0.5 total
        // weight collapses halfway toward the origin as soon as it deforms.
        let data = try RigLoader.load(named: "hero_rig")
        var meshes = 0
        for (_, slots) in data.skins {
            for (_, attachments) in slots {
                for (name, attachment) in attachments {
                    guard case .mesh(_, let vertices, _, _, let weights, _, _) =
                            attachment else { continue }
                    meshes += 1
                    XCTAssertFalse(vertices.isEmpty, "'\(name)' has no vertices")
                    guard let weights else { continue }
                    XCTAssertEqual(weights.count, vertices.count,
                                   "'\(name)' has \(weights.count) weight sets for "
                                   + "\(vertices.count) vertices")
                    for (i, influences) in weights.enumerated() {
                        XCTAssertFalse(influences.isEmpty,
                                       "'\(name)' vertex \(i) is bound to no bone")
                        let total = influences.reduce(0) { $0 + $1.weight }
                        XCTAssertEqual(total, 1, accuracy: 0.01,
                                       "'\(name)' vertex \(i) weights sum to \(total)")
                        for influence in influences {
                            XCTAssertTrue(data.bones.indices.contains(influence.bone),
                                          "'\(name)' vertex \(i) references bone "
                                          + "\(influence.bone)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(meshes, 0, "the rig ships no deformable meshes, so the "
                             + "whole mesh-skinning path is untested by content")
    }

    func testMeshTrianglesIndexRealVertices() throws {
        let data = try RigLoader.load(named: "hero_rig")
        for (_, slots) in data.skins {
            for (_, attachments) in slots {
                for (name, attachment) in attachments {
                    guard case .mesh(_, let vertices, let uvs, let triangles, _, _, _) =
                            attachment else { continue }
                    XCTAssertEqual(triangles.count % 3, 0,
                                   "'\(name)' has a partial triangle")
                    for index in triangles {
                        XCTAssertTrue(vertices.indices.contains(index),
                                      "'\(name)' triangle references vertex \(index) "
                                      + "of \(vertices.count)")
                    }
                    if !uvs.isEmpty {
                        XCTAssertEqual(uvs.count, vertices.count,
                                       "'\(name)' has \(uvs.count) UVs for "
                                       + "\(vertices.count) vertices")
                    }
                }
            }
        }
    }

    // MARK: Art exists, at every scale

    func testEveryRigAttachmentResolvesToArt() throws {
        let data = try RigLoader.load(named: "hero_rig")
        for (_, slots) in data.skins {
            for (_, attachments) in slots {
                for (name, attachment) in attachments {
                    let image: String?
                    switch attachment {
                    case .region(let img, _, _, _, _, _, _, _): image = img
                    case .mesh(let img, _, _, _, _, _, _): image = img
                    case .box: image = nil
                    }
                    guard let image else { continue }
                    XCTAssertNotNil(UIImage(named: image),
                                    "attachment '\(name)' names art '\(image)' that "
                                    + "is not in the bundle — the limb renders as "
                                    + "nothing on a device")
                }
            }
        }
    }

    // MARK: Resolution — the check that decides whether the game looks sharp

    func testCharacterArtIsDenseEnoughNotToBeMagnified() throws {
        // `UIImage.size` is pixels ÷ the suffix it matched, and the attachment
        // declares the size in scene points, so the ratio between them is exactly
        // how much detail the file carries per point of screen.
        let data = try RigLoader.load(named: "hero_rig")
        var checked = 0
        for (_, slots) in data.skins {
            for (_, attachments) in slots {
                for (name, attachment) in attachments {
                    let image: String, width: CGFloat
                    switch attachment {
                    case .region(let img, _, _, _, let w, _, _, _): image = img; width = w
                    case .mesh(let img, _, _, _, _, let w, _): image = img; width = w
                    case .box: continue
                    }
                    guard width > 0, let art = UIImage(named: image) else { continue }
                    checked += 1
                    // `art.size` is already in points at the nominal 3 px/pt, so
                    // recover the real pixel count and divide by the declared size.
                    let pixels = art.size.width * art.scale
                    let density = pixels / width
                    XCTAssertGreaterThanOrEqual(
                        density, requiredCharacterDensity,
                        "'\(image)' carries \(String(format: "%.1f", density)) px per "
                        + "scene point (\(Int(pixels))px for \(width)pt) — it is "
                        + "magnified on every current device, which is what makes "
                        + "art look soft")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "no attachment declared a size, so nothing "
                             + "was actually checked")
    }

    func testCharacterArtDeclaresTheAspectItActuallyHas() throws {
        // The mesh lattice is laid out from the declared width and height, so a
        // declaration that disagrees with the file stretches the painting.
        let data = try RigLoader.load(named: "hero_rig")
        for (_, slots) in data.skins {
            for (_, attachments) in slots {
                for (_, attachment) in attachments {
                    let image: String, w: CGFloat, h: CGFloat
                    switch attachment {
                    case .region(let i, _, _, _, let aw, let ah, _, _):
                        image = i; w = aw; h = ah
                    case .mesh(let i, _, _, _, _, let mw, let mh):
                        image = i; w = mw; h = mh
                    case .box: continue
                    }
                    guard w > 0, h > 0, let art = UIImage(named: image),
                          art.size.height > 0 else { continue }
                    XCTAssertEqual(art.size.width / art.size.height, w / h,
                                   accuracy: 0.06,
                                   "'\(image)' is \(art.size.width)×\(art.size.height) "
                                   + "but is declared \(w)×\(h) — the art will be "
                                   + "stretched to fit")
                }
            }
        }
    }

    // MARK: Backdrop

    func testForestBackdropLoads() throws {
        let scene = try XCTUnwrap(FriezeScene.load(named: "forest_backdrop"),
                                  "the shipped backdrop did not load")
        XCTAssertFalse(scene.layers.isEmpty)
        XCTAssertGreaterThan(scene.sky.count, 1, "a sky needs at least two stops")
        for stop in scene.sky {
            XCTAssertGreaterThanOrEqual(stop.count, 3, "a sky stop needs RGB")
        }
    }

    func testEveryBackdropLayerHasArt() throws {
        let scene = try XCTUnwrap(FriezeScene.load(named: "forest_backdrop"))
        for layer in scene.layers {
            XCTAssertNotNil(UIImage(named: layer.image),
                            "backdrop layer '\(layer.image)' has no art in the bundle")
        }
    }

    func testBackdropLayersAreSortedByDepth() throws {
        // `FriezeStage` adds layers in array order and relies on that order for
        // z-position, so an unsorted scene draws the foreground behind the sky.
        let scene = try XCTUnwrap(FriezeScene.load(named: "forest_backdrop"))
        let depths = scene.layers.map(\.depth)
        XCTAssertEqual(depths, depths.sorted(), "layers are not in depth order")
    }

    func testBackdropLayersAreSharpEnoughForTheBlurTheyReceive() throws {
        // A far layer is Gaussian-blurred at load, so density only has to beat
        // what survives that blur. A layer *at* the focus plane gets no blur and
        // has to be genuinely sharp.
        let scene = try XCTUnwrap(FriezeScene.load(named: "forest_backdrop"))
        for layer in scene.layers {
            let density = layer.density ?? 3
            let blur = abs(layer.depth - scene.focus) * scene.dofPointsPerDepth
            let deserved = max(2.25, min(backdropCap, backdropCap / (1 + blur / 2)))
            XCTAssertGreaterThanOrEqual(
                density, deserved * 0.9,
                "layer '\(layer.image)' is \(density) px/pt but only "
                + "\(String(format: "%.1f", blur))pt of blur is applied to it, "
                + "which passes \(String(format: "%.2f", deserved)) px/pt of "
                + "detail — it will look soft")
        }
    }

    func testBackdropLayersCoverTheParallaxTravelOrTile() throws {
        // The most common backdrop bug, and one that only appears once a level
        // gets long: a layer narrower than its own parallax travel walks its edge
        // into frame.
        let scene = try XCTUnwrap(FriezeScene.load(named: "forest_backdrop"))
        let widest = Levels.all.map { rows in
            CGFloat(rows.map(\.count).max() ?? 0) * 40
        }.max() ?? 0
        let travel = max(0, widest - 844)
        for layer in scene.layers where !(layer.tile ?? false) {
            let size = FriezeBaker.pointSize(imageNamed: layer.image,
                                             scale: layer.scale ?? 1,
                                             density: layer.density ?? 3)
            guard size.width > 0 else { continue }
            let rate = layer.depth / max(scene.focus, 0.001)
            let needed = 844 + 2 * travel * rate
            XCTAssertGreaterThanOrEqual(
                size.width + 1, needed,
                "layer '\(layer.image)' is \(Int(size.width))pt wide but needs "
                + "\(Int(needed))pt at depth \(layer.depth) for the longest level "
                + "(or it should set \"tile\": true)")
        }
    }

    func testDenseLayersAreLaidOutAtTheirPointSizeNotTheirPixelCount() throws {
        // The bug this guards: `UIImage` reports a deliberately dense asset as
        // *larger*, because size is pixels ÷ suffix. Without the density
        // correction a 6 px/pt backdrop lays out at twice its intended size.
        let scene = try XCTUnwrap(FriezeScene.load(named: "forest_backdrop"))
        guard let layer = scene.layers.first(where: { ($0.density ?? 3) > 3.05 }),
              let art = UIImage(named: layer.image) else {
            return XCTSkip("no layer in this scene is denser than nominal")
        }
        let corrected = FriezeBaker.pointSize(imageNamed: layer.image, scale: 1,
                                              density: layer.density ?? 3)
        XCTAssertLessThan(corrected.width, art.size.width,
                          "a dense layer must lay out smaller than its reported "
                          + "size, not at it")
        let expected = art.size.width / ((layer.density ?? 3) / 3)
        XCTAssertEqual(corrected.width, expected, accuracy: 0.5)
    }

    func testNominalDensityLayersAreUnaffectedByTheCorrection() throws {
        // The correction has to be a no-op for every scene authored before
        // `density` existed, or installing it silently resized every backdrop.
        guard let image = FriezeScene.load(named: "forest_backdrop")?
            .layers.first?.image, let art = UIImage(named: image) else {
            return XCTSkip("no backdrop art to measure")
        }
        let plain = FriezeBaker.pointSize(imageNamed: image, scale: 1, density: 3)
        XCTAssertEqual(plain.width, art.size.width, accuracy: 0.001)
    }

    // MARK: Audio

    func testEverySoundEffectResolves() {
        // `Audio.play` degrades silently by design, which means a typo in a sound
        // name is completely invisible at runtime.
        for name in Audio.soundNames {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "wav"),
                            "sound '\(name)' is referenced but not bundled")
        }
        XCTAssertFalse(Audio.soundNames.isEmpty)
        XCTAssertEqual(Audio.soundNames.count, Set(Audio.soundNames).count,
                       "a duplicate name means one entry is dead")
    }

    func testEveryMusicTrackResolves() {
        for name in Audio.musicNames {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "wav"),
                            "music '\(name)' is referenced but not bundled")
        }
    }

    func testEveryLevelsMusicIsDeclared() {
        // A level naming a track `Audio` doesn't know about plays in silence,
        // which looks like the music system broke rather than like a typo.
        let declared = Set(Audio.musicNames)
        for file in LevelLibrary.files {
            guard let track = file.music else { continue }
            XCTAssertTrue(declared.contains(track),
                          "'\(file.name)' names music '\(track)', which is not in "
                          + "Audio.musicNames")
        }
    }

    func testMixerVolumesClampAndPersist() {
        let audio = Audio.shared
        let savedSFX = audio.sfxVolume, savedMusic = audio.musicVolume
        defer { audio.sfxVolume = savedSFX; audio.musicVolume = savedMusic }

        audio.sfxVolume = 5
        XCTAssertEqual(audio.sfxVolume, 1, accuracy: 0.001,
                       "an out-of-range volume must clamp, not distort")
        audio.sfxVolume = -3
        XCTAssertEqual(audio.sfxVolume, 0, accuracy: 0.001)
        audio.musicVolume = 0.42
        XCTAssertEqual(audio.musicVolume, 0.42, accuracy: 0.001)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "audio.musicVolume")
                       as? Float ?? -1, 0.42, accuracy: 0.001,
                       "a volume the player set has to survive a relaunch")
    }

    func testMissingSoundIsSilentNotACrash() {
        // The contract that lets the game ship before every sound exists. If this
        // ever throws, adding a sound name before its file becomes a crash.
        Audio.shared.play("definitely_not_a_sound_that_exists")
        Audio.shared.playMusic("definitely_not_a_track")
        XCTAssertNil(Audio.shared.currentMusic,
                     "a track that failed to load must not be reported as playing")
    }

    func testPlayingTheCurrentTrackAgainIsANoOp() {
        // Scenes call `playMusic` from `didMove(to:)`, so a restart on every
        // transition would make the soundtrack stutter at each level boundary.
        guard let track = Audio.musicNames.first else { return }
        Audio.shared.playMusic(track, fade: 0)
        XCTAssertEqual(Audio.shared.currentMusic, track)
        Audio.shared.playMusic(track, fade: 0)
        XCTAssertEqual(Audio.shared.currentMusic, track)
        Audio.shared.stopMusic(fade: 0)
        XCTAssertNil(Audio.shared.currentMusic)
    }
}
