import SpriteKit

/// Renders and collides a `FriseSpec`.
///
/// Three pieces, in draw order: the extruded body (textured fill), the cap strip
/// along the top edge, and a lit rim line. The physics body comes from the same
/// outline the body is filled with, so what you see is what you stand on.
///
/// Why `SKShapeNode` rather than a custom mesh: SpriteKit gives no vertex-buffer
/// API, and `SKShapeNode` has `fillTexture`, which tiles a texture across an
/// arbitrary path in a single draw. That is exactly the primitive a frise needs.
/// The cap is a strip of quads instead, because a texture that must follow the
/// curve's *direction* cannot be a flat fill.
final class FriseNode: SKNode {

    let spec: FriseSpec
    /// The sampled top curve, kept so gameplay can query the surface.
    private(set) var curve: [CGPoint] = []
    private(set) var outline: [CGPoint] = []

    init?(spec: FriseSpec) {
        self.spec = spec
        super.init()
        guard spec.problems.isEmpty else { return nil }

        let closed = spec.closed ?? false
        curve = Frise.sample(spec.controlPoints, closed: closed,
                             resolution: spec.resolution ?? 12)
        outline = Frise.outline(spec)
        guard outline.count >= 3, let path = Geometry2D.path(outline) else { return nil }

        addChild(makeBody(path: path))
        if spec.capHeight > 0, !closed { addChild(makeCap()) }
        addChild(makeRim())

        if spec.kind != .decor { attachPhysics(path: path) }
        if spec.kind == .decor, let authored = spec.name { name = authored }
        // Decor sits in the backdrop's depth order; terrain sits at the play plane.
        zPosition = spec.kind == .decor
            ? -300 + (spec.depth ?? 0.5) * 200
            : -5
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Pieces

    private func makeBody(path: CGPath) -> SKShapeNode {
        let body = SKShapeNode(path: path)
        body.lineWidth = 0
        body.strokeColor = .clear
        let tint = spec.color.flatMap { rgb -> SKColor? in
            guard rgb.count >= 3 else { return nil }
            return SKColor(red: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255,
                           blue: CGFloat(rgb[2]) / 255, alpha: 1)
        }
        if let name = spec.texture, let image = UIImage(named: name) {
            body.fillTexture = SKTexture(image: image)
            // `fillColor` multiplies the texture, so white keeps the painting as
            // painted and a colour tints it — which is how one cliff texture
            // serves a green jungle and a grey mountain.
            body.fillColor = tint ?? .white
        } else {
            body.fillColor = tint ?? SKColor(red: 0.29, green: 0.42, blue: 0.25, alpha: 1)
        }
        body.blendMode = .alpha
        return body
    }

    /// Cap strip: a quad per curve segment, extruded down by `capHeight`.
    ///
    /// Built as one `SKShapeNode` per run rather than a sprite per segment — a
    /// hundred sprites along a hill is a hundred draws, and the cap is a solid
    /// colour band in most art anyway.
    private func makeCap() -> SKNode {
        let normals = Frise.normals(curve, closed: false)
        var top = curve
        var bottom = zip(curve, normals).map {
            CGPoint(x: $0.0.x - $0.1.dx * spec.capHeight,
                    y: $0.0.y - $0.1.dy * spec.capHeight)
        }
        if top.count > bottom.count { top.removeLast(top.count - bottom.count) }
        if bottom.count > top.count { bottom.removeLast(bottom.count - top.count) }
        let strip = top + bottom.reversed()
        let node = SKShapeNode(path: Geometry2D.path(strip) ?? CGMutablePath())
        node.lineWidth = 0
        node.strokeColor = .clear
        if let name = spec.cap, let image = UIImage(named: name) {
            node.fillTexture = SKTexture(image: image)
            node.fillColor = .white
        } else {
            // A lighter version of the body reads as a lit lip, which is what the
            // reference frames do with grass on rock.
            let base = spec.color ?? [74, 106, 64]
            node.fillColor = SKColor(red: min(1, CGFloat(base[0]) / 255 * 1.5),
                                     green: min(1, CGFloat(base[1]) / 255 * 1.45),
                                     blue: min(1, CGFloat(base[2]) / 255 * 1.3),
                                     alpha: 1)
        }
        node.zPosition = 1
        return node
    }

    /// A bright hairline on the very top edge. Cheap, and it is most of what makes
    /// painted 2D terrain read as *lit* rather than as a flat cutout.
    private func makeRim() -> SKNode {
        let line = SKShapeNode(path: Geometry2D.path(curve, closed: spec.closed ?? false)
                               ?? CGMutablePath())
        line.strokeColor = SKColor(white: 1, alpha: 0.28)
        line.lineWidth = 2
        line.fillColor = .clear
        line.zPosition = 2
        line.blendMode = .add
        return line
    }

    private func attachPhysics(path: CGPath) {
        // Edge chain, not polygon: `polygonFrom:` needs convexity and terrain is
        // never convex. An edge chain takes the exact outline, is static, and
        // produces contact normals — which the slope code already projects along,
        // so a curved hill runs correctly with no new gameplay logic.
        let body = SKPhysicsBody(edgeChainFrom: path)
        body.isDynamic = false
        body.restitution = 0
        body.friction = 0.9
        switch spec.kind {
        case .platform:
            // One-ways are driven by the scene: it toggles the category each frame
            // depending on whether the player is above the pad, so the body starts
            // uncategorised exactly like a tile `P` run does.
            body.categoryBitMask = PhysicsCategory.none
            body.friction = 0
        default:
            body.categoryBitMask = PhysicsCategory.ground
            body.collisionBitMask = PhysicsCategory.player | PhysicsCategory.enemy
            body.contactTestBitMask = PhysicsCategory.player
        }
        physicsBody = body
        // The authored name wins: it is what a trigger addresses.
        name = spec.name ?? (spec.kind == .platform ? "frise.platform"
                                                   : "frise.ground")
    }

    // MARK: Queries

    /// Surface height at a world x, or nil when the frise doesn't span it.
    ///
    /// Useful for placing props on a frise, and for the editor's snapping — the
    /// reason it lives here rather than in the editor is that both need the *same*
    /// answer the physics gives.
    func surfaceY(atX x: CGFloat) -> CGFloat? {
        guard curve.count >= 2 else { return nil }
        for index in 0..<(curve.count - 1) {
            let a = curve[index], b = curve[index + 1]
            let (lo, hi) = a.x <= b.x ? (a, b) : (b, a)
            guard x >= lo.x, x <= hi.x, hi.x - lo.x > 0.0001 else { continue }
            let t = (x - lo.x) / (hi.x - lo.x)
            return lo.y + (hi.y - lo.y) * t
        }
        return nil
    }
}
