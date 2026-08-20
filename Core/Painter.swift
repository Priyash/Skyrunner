import SpriteKit
import UIKit

/// Procedurally PAINTS every texture in the game at device resolution —
/// UIGraphicsImageRenderer inherits the screen scale, so a 40pt tile is
/// rendered as a 120px bitmap on a 3× iPhone. No image assets, no banding,
/// no blur.
enum Painter {

    // MARK: - Gradients & atmosphere

    /// Vertical gradient (index 0 = bottom) with a light noise dither so
    /// smooth skies never band.
    static func gradient(size: CGSize, colors: [UIColor]) -> SKTexture {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let cgColors = colors.map(\.cgColor) as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: space, colors: cgColors, locations: nil) {
                cg.drawLinearGradient(grad,
                                      start: CGPoint(x: 0, y: size.height),
                                      end: CGPoint(x: 0, y: 0),
                                      options: [])
            }
            // Dither: tiny alternating specks break up gradient banding
            let count = Int(size.width * size.height / 220)
            for i in 0..<count {
                cg.setFillColor((i % 2 == 0 ? UIColor.white : UIColor.black)
                                    .withAlphaComponent(0.025).cgColor)
                cg.fill(CGRect(x: .random(in: 0..<size.width),
                               y: .random(in: 0..<size.height), width: 1, height: 1))
            }
        }
        return SKTexture(image: img)
    }

    /// Soft radial glow: solid center fading to clear.
    static func glow(radius: CGFloat, color: UIColor = .white) -> SKTexture {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let cgColors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: space, colors: cgColors, locations: [0, 1]) else { return }
            let center = CGPoint(x: radius, y: radius)
            cg.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                                  endCenter: center, endRadius: radius, options: [])
        }
        return SKTexture(image: img)
    }

    /// Fluffy cloud with painted volume: a cool shadow underside, white body,
    /// and a bright top.
    static func cloud() -> SKTexture {
        let size = CGSize(width: 164, height: 88)
        let puffs = [CGRect(x: 10, y: 32, width: 70, height: 45),
                     CGRect(x: 45, y: 14, width: 75, height: 60),
                     CGRect(x: 87, y: 34, width: 65, height: 42)]
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.72, green: 0.78, blue: 0.92, alpha: 1).cgColor)
            for p in puffs { cg.fillEllipse(in: p.offsetBy(dx: 0, dy: 5)) }      // shadow
            cg.setFillColor(UIColor.white.cgColor)
            for p in puffs { cg.fillEllipse(in: p) }                             // body
            cg.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            for p in puffs { cg.fillEllipse(in: p.insetBy(dx: p.width * 0.18, dy: p.height * 0.22)
                                             .offsetBy(dx: -2, dy: -4)) }        // crown
        }
        return SKTexture(image: img)
    }

    // MARK: - Cartoon shading primitives

    /// The core cartoon trick: a sphere with radial shading + glossy highlight
    /// + bold outline. Replaces every flat circle in the game.
    static func ball(radius: CGFloat, base: UIColor, outline: UIColor? = nil) -> SKTexture {
        pill(size: CGSize(width: radius * 2, height: radius * 2), base: base, outline: outline)
    }

    /// Shaded ellipse — same treatment for non-circular parts (feet, blobs).
    static func pill(size body: CGSize, base: UIColor, outline: UIColor? = nil) -> SKTexture {
        let inset: CGFloat = 2
        let size = CGSize(width: body.width + inset * 2, height: body.height + inset * 2)
        let rect = CGRect(x: inset, y: inset, width: body.width, height: body.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            cg.saveGState()
            cg.addEllipse(in: rect)
            cg.clip()
            let colors = [base.adjusted(brightness: 0.16).cgColor,
                          base.cgColor,
                          base.adjusted(brightness: -0.20).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
                cg.drawRadialGradient(grad,
                    startCenter: CGPoint(x: size.width * 0.38, y: size.height * 0.32), startRadius: 0,
                    endCenter: CGPoint(x: size.width * 0.50, y: size.height * 0.55),
                    endRadius: max(body.width, body.height) * 0.68,
                    options: [.drawsAfterEndLocation])
            }
            let hl = [UIColor.white.withAlphaComponent(0.70).cgColor,
                      UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            if let g2 = CGGradient(colorsSpace: space, colors: hl, locations: [0, 1]) {
                let c = CGPoint(x: size.width * 0.36, y: size.height * 0.27)
                cg.drawRadialGradient(g2, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: min(body.width, body.height) * 0.34,
                                      options: [])
            }
            cg.restoreGState()
            if let outline {
                cg.setStrokeColor(outline.cgColor)
                cg.setLineWidth(2.5)
                cg.strokeEllipse(in: rect.insetBy(dx: 1.25, dy: 1.25))
            }
        }
        return SKTexture(image: img)
    }

    // MARK: - World surfaces

    /// Dirt slab: vertical shading, speckled texture, dark seam under the
    /// grass line.
    static func dirt(size: CGSize) -> SKTexture {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let top = UIColor(red: 0.68, green: 0.47, blue: 0.29, alpha: 1)
            let bottom = UIColor(red: 0.46, green: 0.29, blue: 0.17, alpha: 1)
            if let grad = CGGradient(colorsSpace: space,
                                     colors: [top.cgColor, bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: .zero,
                                      end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Speckles: pebble dots in two tones
            let count = max(6, Int(size.width * size.height / 260))
            for i in 0..<count {
                let dark = i % 3 != 0
                cg.setFillColor((dark ? UIColor(red: 0.38, green: 0.24, blue: 0.13, alpha: 0.55)
                                      : UIColor(red: 0.80, green: 0.60, blue: 0.40, alpha: 0.5)).cgColor)
                let r = CGFloat.random(in: 1.5...4)
                cg.fillEllipse(in: CGRect(x: .random(in: 2..<max(3, size.width - 6)),
                                          y: .random(in: 6..<max(7, size.height - 4)),
                                          width: r * 1.5, height: r))
            }
            // Shadow seam at the very top (sits under the grass cap)
            if let seam = CGGradient(colorsSpace: space,
                                     colors: [UIColor.black.withAlphaComponent(0.30).cgColor,
                                              UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawLinearGradient(seam, start: .zero, end: CGPoint(x: 0, y: 7), options: [])
            }
        }
        return SKTexture(image: img)
    }

    /// Grass cap with individual blades poking above the lip and a sunny
    /// highlight along the top. Canvas is 26pt tall: blades live in the top
    /// 8pt, the rounded cap fills the lower 18pt.
    static func grassCap(width: CGFloat) -> SKTexture {
        let size = CGSize(width: width, height: 26)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let mid = UIColor(red: 0.30, green: 0.74, blue: 0.32, alpha: 1)
            // Blades first, so the cap overlaps their roots
            cg.setFillColor(mid.cgColor)
            var x: CGFloat = 4
            while x < width - 4 {
                let h = CGFloat.random(in: 5...9)
                let lean = CGFloat.random(in: -2...2)
                cg.move(to: CGPoint(x: x, y: 12))
                cg.addLine(to: CGPoint(x: x + 1.6 + lean, y: 12 - h))
                cg.addLine(to: CGPoint(x: x + 3.2, y: 12))
                cg.closePath()
                cg.fillPath()
                x += CGFloat.random(in: 7...15)
            }
            // Cap: rounded, vertically shaded
            let capRect = CGRect(x: 0, y: 8, width: width, height: 18)
            let capPath = UIBezierPath(roundedRect: capRect, cornerRadius: 9)
            cg.saveGState()
            cg.addPath(capPath.cgPath)
            cg.clip()
            let bright = UIColor(red: 0.45, green: 0.90, blue: 0.42, alpha: 1)
            let deep = UIColor(red: 0.18, green: 0.58, blue: 0.24, alpha: 1)
            if let grad = CGGradient(colorsSpace: space,
                                     colors: [bright.cgColor, deep.cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 8),
                                      end: CGPoint(x: 0, y: 26), options: [])
            }
            // Sunlit rim along the top of the cap
            cg.setFillColor(UIColor.white.withAlphaComponent(0.4).cgColor)
            cg.fill(CGRect(x: 4, y: 9, width: width - 8, height: 2.5))
            cg.restoreGState()
        }
        return SKTexture(image: img)
    }

    /// Rolling ridge for the parallax hills: soft (or peaked) silhouette with
    /// vertical shading and a sunlit rim along its crest.
    static func hillRidge(width: CGFloat, amplitude: CGFloat, peaks: Bool,
                          color: UIColor) -> SKTexture {
        let baseDepth: CGFloat = 140
        let size = CGSize(width: width, height: amplitude + baseDepth)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: amplitude))
            var x: CGFloat = 0
            var up = true
            while x < width {
                let next = x + (peaks ? 130 : 170)
                let h = up ? amplitude : amplitude * 0.35
                if peaks {
                    path.addLine(to: CGPoint(x: (x + next) / 2, y: amplitude - h))
                    path.addLine(to: CGPoint(x: next, y: amplitude))
                } else {
                    path.addQuadCurve(to: CGPoint(x: next, y: amplitude),
                                      control: CGPoint(x: (x + next) / 2, y: amplitude - h))
                }
                x = next
                up.toggle()
            }
            path.addLine(to: CGPoint(x: width, y: size.height))
            path.closeSubpath()

            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            if let grad = CGGradient(colorsSpace: space,
                                     colors: [color.adjusted(brightness: 0.14).cgColor,
                                              color.adjusted(brightness: -0.12).cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: .zero,
                                      end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Crest rim light: stroke the silhouette inside the clip
            cg.addPath(path)
            cg.setStrokeColor(color.adjusted(brightness: 0.28).cgColor)
            cg.setLineWidth(9)
            cg.strokePath()
            cg.restoreGState()
        }
        return SKTexture(image: img)
    }

    // MARK: - Props

    /// Beveled gold coin face with a crescent glint.
    static func coinFace(radius: CGFloat) -> SKTexture {
        let inset: CGFloat = 2
        let side = radius * 2 + inset * 2
        let size = CGSize(width: side, height: side)
        let rect = CGRect(x: inset, y: inset, width: radius * 2, height: radius * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            cg.saveGState()
            cg.addEllipse(in: rect)
            cg.clip()
            let colors = [UIColor(red: 1.00, green: 0.95, blue: 0.55, alpha: 1).cgColor,
                          UIColor(red: 1.00, green: 0.80, blue: 0.12, alpha: 1).cgColor,
                          UIColor(red: 0.82, green: 0.55, blue: 0.03, alpha: 1).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
                cg.drawRadialGradient(grad,
                    startCenter: CGPoint(x: side * 0.38, y: side * 0.32), startRadius: 0,
                    endCenter: CGPoint(x: side * 0.5, y: side * 0.55), endRadius: radius * 1.3,
                    options: [.drawsAfterEndLocation])
            }
            cg.restoreGState()
            // Rim + inner ring
            cg.setStrokeColor(UIColor(red: 0.78, green: 0.50, blue: 0.02, alpha: 1).cgColor)
            cg.setLineWidth(2.5)
            cg.strokeEllipse(in: rect.insetBy(dx: 1.25, dy: 1.25))
            cg.setStrokeColor(UIColor(red: 1.0, green: 0.97, blue: 0.72, alpha: 0.9).cgColor)
            cg.setLineWidth(1.8)
            cg.strokeEllipse(in: rect.insetBy(dx: radius * 0.42, dy: radius * 0.42))
            // Crescent glint
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.75).cgColor)
            cg.setLineWidth(2.2)
            cg.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: radius * 0.62,
                      startAngle: -2.5, endAngle: -0.9, clockwise: false)
            cg.strokePath()
        }
        return SKTexture(image: img)
    }

    /// Faceted crystal shard with internal gradient and a glint line.
    static func crystal(tile t: CGFloat, index: Int) -> SKTexture {
        let size = CGSize(width: t + 4, height: t + 4)
        let base: UIColor = index % 2 == 0
            ? UIColor(red: 0.25, green: 0.80, blue: 1.00, alpha: 1)
            : UIColor(red: 1.00, green: 0.40, blue: 0.72, alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let ox: CGFloat = 2, oy: CGFloat = 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: ox, y: oy + t))
            path.addLine(to: CGPoint(x: ox + t * 0.35, y: oy + 6))
            path.addLine(to: CGPoint(x: ox + t * 0.60, y: oy + t * 0.60))
            path.addLine(to: CGPoint(x: ox + t * 0.80, y: oy + t * 0.22))
            path.addLine(to: CGPoint(x: ox + t, y: oy + t))
            path.closeSubpath()
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            if let grad = CGGradient(colorsSpace: space,
                                     colors: [base.adjusted(brightness: 0.22).cgColor,
                                              base.cgColor,
                                              base.adjusted(brightness: -0.18).cgColor] as CFArray,
                                     locations: [0, 0.6, 1]) {
                cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: oy),
                                      end: CGPoint(x: 0, y: oy + t), options: [])
            }
            // Facet glints
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            cg.setLineWidth(1.6)
            cg.move(to: CGPoint(x: ox + t * 0.35, y: oy + 6))
            cg.addLine(to: CGPoint(x: ox + t * 0.42, y: oy + t))
            cg.move(to: CGPoint(x: ox + t * 0.80, y: oy + t * 0.22))
            cg.addLine(to: CGPoint(x: ox + t * 0.74, y: oy + t))
            cg.strokePath()
            cg.restoreGState()
            cg.addPath(path)
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            cg.setLineWidth(1.6)
            cg.strokePath()
        }
        return SKTexture(image: img)
    }

    /// Wooden crate: grain, cross planks with their own shading, nails,
    /// bold outline.
    static func crate(side s: CGFloat) -> SKTexture {
        let size = CGSize(width: s + 4, height: s + 4)
        let rect = CGRect(x: 2, y: 2, width: s, height: s)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
            cg.saveGState()
            cg.addPath(path.cgPath)
            cg.clip()
            if let grad = CGGradient(colorsSpace: space,
                                     colors: [UIColor(red: 0.87, green: 0.66, blue: 0.38, alpha: 1).cgColor,
                                              UIColor(red: 0.70, green: 0.48, blue: 0.24, alpha: 1).cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 2),
                                      end: CGPoint(x: 0, y: 2 + s), options: [])
            }
            // Grain lines
            cg.setStrokeColor(UIColor(red: 0.55, green: 0.36, blue: 0.16, alpha: 0.4).cgColor)
            cg.setLineWidth(1.4)
            for i in 1...4 {
                let y = 2 + s * CGFloat(i) / 5 + .random(in: -1.5...1.5)
                cg.move(to: CGPoint(x: 4, y: y))
                cg.addLine(to: CGPoint(x: 2 + s - 2, y: y + .random(in: -1.5...1.5)))
            }
            cg.strokePath()
            // Cross planks
            for angle in [CGFloat(0.78), -0.78] {
                cg.saveGState()
                cg.translateBy(x: size.width / 2, y: size.height / 2)
                cg.rotate(by: angle)
                let plank = CGRect(x: -s * 0.62, y: -4, width: s * 1.24, height: 8)
                cg.setFillColor(UIColor(red: 0.74, green: 0.52, blue: 0.27, alpha: 1).cgColor)
                cg.fill(plank)
                cg.setFillColor(UIColor.white.withAlphaComponent(0.22).cgColor)
                cg.fill(CGRect(x: -s * 0.62, y: -4, width: s * 1.24, height: 2.4))
                cg.restoreGState()
            }
            // Nails
            cg.setFillColor(UIColor(red: 0.35, green: 0.24, blue: 0.11, alpha: 1).cgColor)
            for (nx, ny) in [(8, 8), (Int(s) - 4, 8), (8, Int(s) - 4), (Int(s) - 4, Int(s) - 4)] {
                cg.fillEllipse(in: CGRect(x: CGFloat(nx) - 1.5, y: CGFloat(ny) - 1.5, width: 3.5, height: 3.5))
            }
            cg.restoreGState()
            cg.addPath(path.cgPath)
            cg.setStrokeColor(UIColor(red: 0.50, green: 0.32, blue: 0.13, alpha: 1).cgColor)
            cg.setLineWidth(3)
            cg.strokePath()
        }
        return SKTexture(image: img)
    }
}

// MARK: - Color helpers

extension UIColor {
    func adjusted(brightness delta: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s,
                       brightness: max(0, min(1, b + delta)), alpha: a)
    }
}
