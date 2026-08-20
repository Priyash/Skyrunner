import SpriteKit

/// Where a rig gets its textures from.
///
/// Two implementations, and the reason for the abstraction is that they arrive by
/// completely different routes: `SKTextureAtlas` is produced by Xcode's build-time
/// `.atlas` folder compilation, and `PackedAtlas` is produced by
/// `Tools/atlas_packer.py`. The rig should not care, and neither should the code
/// that builds one.
protocol TextureProvider {
    func texture(named name: String) -> SKTexture?
    var frameNames: [String] { get }
}

extension SKTextureAtlas: TextureProvider {
    func texture(named name: String) -> SKTexture? {
        textureNames.contains(name) ? textureNamed(name) : nil
    }
    var frameNames: [String] { textureNames }
}

/// A texture atlas packed by `Tools/atlas_packer.py`, format `atlas/1`.
///
/// Why this exists rather than `SKTextureAtlas(named:)`. Xcode's build-time atlas
/// wants a `Name.atlas` *folder* of loose images, which fights the flat resource
/// layout every loader here depends on, and it can only be verified by running a
/// build. This reads a page PNG plus a JSON frame map — both plain bundle
/// resources — and hands out `SKTexture(rect:in:)` sub-textures of the one page.
///
/// The batching win is the point: seven sub-textures of one page are seven draws
/// SpriteKit can batch into one, against seven separate textures it cannot. A
/// character costs one bind per frame instead of one per limb.
///
/// Sub-textures require an **untrimmed** page, which is why the packer defaults
/// to no trimming: a trimmed frame is smaller than the image it came from, so
/// using it would need a per-attachment position and size correction that nothing
/// here applies. `trimmed` is read and refused rather than silently mis-drawn.
final class PackedAtlas: TextureProvider {

    private let page: SKTexture
    private let frames: [String: CGRect]        // normalised, origin bottom-left
    let scale: Int

    var frameNames: [String] { Array(frames.keys) }

    /// Load `<name>.json` + its page from the bundle. Nil when either is absent,
    /// so a build without a packed atlas simply falls back to loose textures —
    /// the same graceful-degradation rule the rig and frieze loaders follow.
    init?(named name: String, bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              root["format"] as? String == "atlas/1",
              let frameMap = root["frames"] as? [String: [String: Any]],
              let pageNames = root["pages"] as? [String],
              let pageName = pageNames.first
        else { return nil }

        // Multiple pages would need per-frame page lookup; the packer only splits
        // when a single page overflows, and nothing here is close. Refuse rather
        // than silently drawing every frame from page one.
        guard pageNames.count == 1 else { return nil }
        // A trimmed page cannot be used as a drop-in substitution — see above.
        guard (root["trimmed"] as? Bool) != true else { return nil }

        let stem = (pageName as NSString).deletingPathExtension
        guard let image = UIImage(named: stem) ?? UIImage(named: pageName) else {
            return nil
        }
        page = SKTexture(image: image)
        scale = root["scale"] as? Int ?? 3

        // Pixel rects → normalised rects, flipping y: the packer writes rows from
        // the top (image convention) and `SKTexture(rect:in:)` measures from the
        // bottom (texture convention). Getting this backwards mirrors every limb
        // vertically, which looks like a rigging bug rather than an atlas bug.
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        var built: [String: CGRect] = [:]
        for (frameName, frame) in frameMap {
            guard let x = (frame["x"] as? NSNumber)?.doubleValue,
                  let y = (frame["y"] as? NSNumber)?.doubleValue,
                  let w = (frame["w"] as? NSNumber)?.doubleValue,
                  let h = (frame["h"] as? NSNumber)?.doubleValue,
                  w > 0, h > 0, width > 0, height > 0 else { continue }
            built[frameName] = CGRect(x: CGFloat(x) / width,
                                      y: 1 - CGFloat(y + h) / height,
                                      width: CGFloat(w) / width,
                                      height: CGFloat(h) / height)
        }
        guard !built.isEmpty else { return nil }
        frames = built
    }

    private var cache: [String: SKTexture] = [:]

    func texture(named name: String) -> SKTexture? {
        if let hit = cache[name] { return hit }
        guard let rect = frames[name] else { return nil }
        let texture = SKTexture(rect: rect, in: page)
        // Painted art is scaled continuously by `.aspectFill`, so linear
        // filtering is right; nearest would alias every edge.
        texture.filteringMode = .linear
        cache[name] = texture
        return texture
    }

    /// Preload the page so the first frame that draws a limb doesn't stall.
    func preload(_ done: @escaping () -> Void) {
        SKTexture.preload([page], withCompletionHandler: done)
    }
}
