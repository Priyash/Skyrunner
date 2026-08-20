import Foundation
import CoreGraphics

/// FriezeKit — a UbiArt-inspired layer-presentation runtime for iOS/iPadOS.
/// A scene is hi-res painted layers ("friezes") placed at depths 0…1
/// (0 = far, 1 = near). The gameplay plane sits at `focus`. The runtime bakes
/// atmosphere ONCE at load (haze tint + depth-of-field blur per layer), then
/// scrolls each layer at depth/focus of the camera speed — so per-frame cost
/// is just sprite transforms. Authoring/preview happens in the Python
/// composer; this file defines the shared JSON contract.
struct FriezeScene: Decodable {
    struct Layer: Decodable {
        let image: String        // bundle image name (ship @2x/@3x variants)
        let x: CGFloat           // camera-space offset from screen center, points
        let y: CGFloat
        let depth: CGFloat       // 0 far … 1 near; focus = gameplay plane
        var scale: CGFloat? = nil
        var flipX: Bool? = nil
        /// Repeat horizontally so a level of any length never runs out of
        /// backdrop. Without it, a layer has to be authored wider than the
        /// longest level it will ever appear in — a constraint that quietly
        /// caps level length.
        var tile: Bool? = nil
        /// Constant drift, points per second: clouds and fog that move on their
        /// own rather than only when the camera does.
        var drift: CGFloat? = nil
        /// Gentle sway in points, and how fast — foliage breathing.
        var sway: CGFloat? = nil
        var swayRate: CGFloat? = nil
        /// Vertical parallax multiplier. Defaults to the horizontal rate; set it
        /// lower for a sky that shouldn't rise as fast as the camera climbs.
        var verticalRate: CGFloat? = nil
        /// Points of wind sway at full strength. 0 (the default) leaves the plane
        /// rigid, which is what every layer did before deformation existed.
        ///
        /// Scaled by depth at runtime: a far canopy barely moves and a foreground vine
        /// sways hard, because uniform sway across the depth stack destroys the
        /// parallax the backdrop exists to create.
        var wind: CGFloat? = nil
        /// Pin the *top* lattice edge instead of the bottom — right for anything
        /// hanging from above, which would otherwise detach from the ceiling.
        var windPinTop: Bool? = nil
        /// Painted spline geometry on this plane.
        ///
        /// This is what a UbiArt backdrop actually *is* — friezes at depth, not
        /// flat pictures. A layer can now be a curve extrusion instead of (or as
        /// well as) an image, and it gets the same parallax, haze and depth-of-field
        /// the image path gets.
        var frises: [FriseSpec]? = nil
        /// Scattered instances on this plane — trunks, rocks, bushes.
        ///
        /// One full-width image per plane is the limitation that makes procedural
        /// backdrops look like wallpaper: everything at a given distance is the same
        /// picture repeating. Props break that by placing N copies of a small image
        /// at deterministic pseudo-random positions and scales.
        var props: [Prop]? = nil
        /// Pixels per scene point in the `@3x` file. Defaults to 3 — what the
        /// suffix alone implies.
        ///
        /// A scene point is not a view point: `.aspectFill` scales 844×390 up to
        /// the view first, so an iPad Pro needs 5.3 px per scene point and a plain
        /// `@3x` asset is magnified. Shipping denser art fixes that, but UIKit
        /// still reports its size as pixels ÷ suffix — so without this the
        /// backdrop would be laid out twice too big.
        var density: CGFloat? = nil
    }
    /// Scattered prop instances on a backdrop plane — trunks, rocks, bushes.
    struct Prop: Decodable {
        let image: String              // bundle image name (no @2x/@3x suffix)
        let count: Int                 // number of instances to place
        let span: CGFloat              // horizontal spread in scene points
        let y: CGFloat                 // vertical center in camera space
        var yJitter: CGFloat = 8       // ± vertical jitter in points
        var scale: CGFloat = 1         // uniform size multiplier
        var scaleJitter: CGFloat = 0.15  // ± fractional scale variation
        var flipChance: CGFloat = 0.5  // 0…1 probability of a horizontal flip
        var seed: Int = 42             // LCG seed for deterministic placement
        var density: CGFloat? = nil    // pixels per scene point (@3x = 3)
    }

    struct Rays: Decodable {
        let x: CGFloat
        let y: CGFloat
        let angles: [CGFloat]    // degrees from vertical
        let color: [Int]
        let alpha: CGFloat
        let width: CGFloat
    }
    struct Fireflies: Decodable {
        let count: Int
        let color: [Int]
    }

    let focus: CGFloat
    let haze: CGFloat            // 0…1 strength of atmospheric tint at depth 0
    let dofPointsPerDepth: CGFloat  // blur radius (pt) per unit |depth − focus|
    let sky: [[Int]]             // gradient stops, index 0 = bottom
    let layers: [Layer]
    var rays: Rays? = nil
    var fireflies: Fireflies? = nil
    var vignette: CGFloat? = nil

    /// Load "<name>.json" from the main bundle; nil if absent (callers keep a
    /// procedural fallback, so shipping without frieze assets still works).
    static func load(named name: String) -> FriezeScene? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let scene = try? JSONDecoder().decode(FriezeScene.self, from: data)
        else { return nil }
        return scene
    }

    /// Middle sky stop — the atmospheric tint target for hazing.
    var hazeColor: (CGFloat, CGFloat, CGFloat) {
        guard !sky.isEmpty else { return (0.6, 0.75, 0.9) }
        let s = sky[sky.count / 2]
        guard s.count >= 3 else { return (0.6, 0.75, 0.9) }
        return (CGFloat(s[0]) / 255, CGFloat(s[1]) / 255, CGFloat(s[2]) / 255)
    }
}
