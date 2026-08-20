import SpriteKit
import CoreImage
import UIKit

/// Bakes atmosphere into layer textures ONCE at load. This is the whole
/// performance strategy: no SKEffectNode, no per-frame Core Image — every
/// layer is a plain textured sprite by the time the scene runs, so the GPU
/// does nothing per frame beyond ordinary compositing.
enum FriezeBaker {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// image → hazed (blended toward sky by depth) → blurred (by |depth−focus|).
    static func bake(imageNamed name: String,
                     depth: CGFloat,
                     scene: FriezeScene) -> SKTexture? {
        guard let src = UIImage(named: name) else { return nil }

        // 1) Atmospheric haze: farther layers tint toward the sky color.
        //    sourceAtop fill preserves the alpha silhouette exactly.
        let hazeAmount = max(0, scene.focus - depth) / max(scene.focus, 0.001)
            * scene.haze
        var img = src
        if hazeAmount > 0.01 {
            let (r, g, b) = scene.hazeColor
            let format = UIGraphicsImageRendererFormat.preferred()
            format.scale = src.scale
            let renderer = UIGraphicsImageRenderer(size: src.size, format: format)
            img = renderer.image { ctx in
                src.draw(at: .zero)
                ctx.cgContext.setBlendMode(.sourceAtop)
                ctx.cgContext.setFillColor(UIColor(red: r, green: g, blue: b,
                                                   alpha: hazeAmount).cgColor)
                ctx.cgContext.fill(CGRect(origin: .zero, size: src.size))
            }
        }

        // 2) Depth-of-field: gaussian blur by distance from the focal plane,
        //    clamped→blurred→cropped so edges don't fade to transparent.
        let blurPoints = abs(depth - scene.focus) * scene.dofPointsPerDepth
        if blurPoints > 0.75, let ci = CIImage(image: img) {
            let sigma = blurPoints * img.scale * 0.5
            let blurred = ci.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(sigma))
                .cropped(to: ci.extent)
            if let cg = ciContext.createCGImage(blurred, from: blurred.extent) {
                let tex = SKTexture(cgImage: cg)
                tex.usesMipmaps = true
                return tex
            }
        }
        let tex = SKTexture(image: img)
        tex.usesMipmaps = true
        return tex
    }

    /// Point size for a baked sprite (UIImage already accounts for @2x/@3x).
    /// On-screen size in scene points.
    ///
    /// `UIImage.size` is pixels ÷ the suffix it matched, so a deliberately dense
    /// asset reports a larger size than it should occupy. Dividing by how much
    /// denser it is than nominal puts it back — and defaulting `density` to 3
    /// keeps every existing scene laying out exactly as before.
    static func pointSize(imageNamed name: String, scale extra: CGFloat,
                          density: CGFloat = 3) -> CGSize {
        guard let img = UIImage(named: name) else { return .zero }
        let correction = max(density, 0.1) / 3
        return CGSize(width: img.size.width * extra / correction,
                      height: img.size.height * extra / correction)
    }

    /// Soft radial glow texture for fireflies / light dots.
    static func glowTexture(radius: CGFloat, color: UIColor) -> SKTexture {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: radius, y: radius)
            cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                  endCenter: c, endRadius: radius, options: [])
        }
        return SKTexture(image: img)
    }

    /// Vignette overlay: transparent center, darkened corners.
    static func vignetteTexture(size: CGSize, strength: CGFloat) -> SKTexture {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                          UIColor.black.withAlphaComponent(0).cgColor,
                          UIColor.black.withAlphaComponent(strength).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.62, 1]) else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                  endCenter: c,
                                  endRadius: max(size.width, size.height) * 0.72,
                                  options: [.drawsAfterEndLocation])
        }
        return SKTexture(image: img)
    }

    /// Vertical sky gradient (stop 0 = bottom) with the same look as the
    /// composer's, sized for the camera.
    static func skyTexture(stops rawStops: [[Int]], size: CGSize) -> SKTexture {
        // CGGradient needs >= 2 stops; duplicate or substitute as needed.
        var stops = rawStops.filter { $0.count >= 3 }
        if stops.isEmpty { stops = [[40, 110, 160], [150, 200, 235]] }
        if stops.count == 1 { stops.append(stops[0]) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 256))
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = stops.map {
                UIColor(red: CGFloat($0[0]) / 255, green: CGFloat($0[1]) / 255,
                        blue: CGFloat($0[2]) / 255, alpha: 1).cgColor
            } as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: nil) else { return }
            cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 256),
                                  end: .zero, options: [])
        }
        return SKTexture(image: img)
    }
}
