import SpriteKit

/// Weighted mesh skinning — the piece that separates "cut-out puppet" from
/// genuinely hand-drawn deformation. A vertex can be influenced by several
/// bones at once, so elbows bend, cloth stretches, and a hand-painted limb
/// deforms as one continuous surface instead of hinging at a seam.
///
/// Rendering path: `SKWarpGeometryGrid` — Apple's native mesh-warp on
/// SKSpriteNode. It runs on the GPU inside SpriteKit's own pipeline, so we get
/// real per-vertex deformation without hand-writing a Metal renderer and
/// without leaving the batching/compositing the rest of the game uses.
///
/// A warp grid is a regular (cols+1)×(rows+1) lattice in unit space [0,1].
/// We bind each lattice point to bones by weight, so any authored mesh —
/// including Spine weighted meshes — maps onto it.
enum MeshSkinning {

    /// One lattice point's binding: which bones move it, and by how much.
    struct VertexBinding {
        /// (boneIndex, offset in that bone's local space, weight)
        let influences: [(bone: Int, offset: CGPoint, weight: CGFloat)]
        /// Where this point sits in the sprite's unit space (0…1).
        let unitPosition: CGPoint
        /// The authored vertices this lattice point was blended from, with
        /// their blend weights. Animated `deform` timelines are keyed per
        /// *authored vertex*, so without this mapping a deform array would be
        /// applied to lattice indices — silently warping the wrong corners of
        /// the mesh.
        let sources: [(vertex: Int, weight: CGFloat)]
    }

    /// A prepared skin: the static bindings plus the source grid they warp.
    struct SkinnedMesh {
        let cols: Int
        let rows: Int
        let bindings: [VertexBinding]
        let sourceGrid: SKWarpGeometryGrid
        /// Sprite size in points, used to convert world offsets to unit space.
        let size: CGSize
        /// Bone whose space the sprite node itself is parented to.
        let anchorBone: Int
    }

    /// Build lattice bindings from an authored mesh.
    ///
    /// - `vertices`: mesh vertices in attachment space (unweighted meshes) —
    ///   used only to compute the bounds the lattice spans.
    /// - `weights`: optional per-vertex bone influences (Spine weighted mesh).
    ///   When present, each lattice point takes the influences of its nearest
    ///   authored vertices, inverse-distance blended, so an artist's weight
    ///   painting carries over to the warp lattice.
    static func prepare(vertices: [CGPoint],
                        weights: [[(bone: Int, offset: CGPoint, weight: CGFloat)]]?,
                        anchorBone: Int,
                        size: CGSize,
                        cols: Int = 4,
                        rows: Int = 4) -> SkinnedMesh? {
        guard cols > 0, rows > 0, size.width > 0, size.height > 0 else { return nil }

        // Lattice in unit space, row-major from bottom-left (SpriteKit order).
        var unitPositions: [CGPoint] = []
        for r in 0...rows {
            for c in 0...cols {
                unitPositions.append(CGPoint(x: CGFloat(c) / CGFloat(cols),
                                             y: CGFloat(r) / CGFloat(rows)))
            }
        }

        // Attachment-space bounds, so we can locate lattice points among the
        // authored vertices.
        let minX = vertices.map(\.x).min() ?? -size.width / 2
        let maxX = vertices.map(\.x).max() ?? size.width / 2
        let minY = vertices.map(\.y).min() ?? -size.height / 2
        let maxY = vertices.map(\.y).max() ?? size.height / 2
        let spanX = max(maxX - minX, 0.0001)
        let spanY = max(maxY - minY, 0.0001)

        var bindings: [VertexBinding] = []
        bindings.reserveCapacity(unitPositions.count)

        for unit in unitPositions {
            let target = CGPoint(x: minX + unit.x * spanX, y: minY + unit.y * spanY)

            // Inverse-distance ranking of the k nearest authored vertices. Used
            // both to inherit painted bone weights and to resample animated
            // deform offsets, so the two always agree about which authored
            // vertices a lattice point stands for.
            let k = min(3, vertices.count)
            let ranked = vertices.enumerated()
                .map { (i, v) -> (Int, CGFloat) in
                    let dx = v.x - target.x, dy = v.y - target.y
                    return (i, sqrt(dx * dx + dy * dy))
                }
                .sorted { $0.1 < $1.1 }
                .prefix(k)

            var spatialTotal: CGFloat = 0
            for (_, dist) in ranked { spatialTotal += 1 / max(dist, 0.5) }
            let sources: [(vertex: Int, weight: CGFloat)] = spatialTotal > 0
                ? ranked.map { (vertex: $0.0, weight: (1 / max($0.1, 0.5)) / spatialTotal) }
                : []

            guard let weights, !weights.isEmpty, weights.count == vertices.count else {
                // Unweighted mesh: rigidly follow the anchor bone.
                bindings.append(VertexBinding(
                    influences: [(bone: anchorBone, offset: target, weight: 1)],
                    unitPosition: unit, sources: sources))
                continue
            }

            var pool: [Int: (offset: CGPoint, weight: CGFloat)] = [:]
            var totalW: CGFloat = 0
            for (vi, dist) in ranked {
                let spatial = 1 / max(dist, 0.5)
                totalW += spatial
                for inf in weights[vi] {
                    let w = inf.weight * spatial
                    if var existing = pool[inf.bone] {
                        existing.weight += w
                        // Offsets averaged in the influencing bone's space.
                        existing.offset = CGPoint(
                            x: (existing.offset.x + inf.offset.x) / 2,
                            y: (existing.offset.y + inf.offset.y) / 2)
                        pool[inf.bone] = existing
                    } else {
                        pool[inf.bone] = (inf.offset, w)
                    }
                }
            }
            guard totalW > 0, !pool.isEmpty else {
                bindings.append(VertexBinding(
                    influences: [(bone: anchorBone, offset: target, weight: 1)],
                    unitPosition: unit, sources: sources))
                continue
            }
            // Normalize so the influences sum to 1 — otherwise the mesh
            // inflates or collapses as bones move.
            let sum = pool.values.reduce(CGFloat(0)) { $0 + $1.weight }
            let influences = pool.map { (bone: $0.key,
                                         offset: $0.value.offset,
                                         weight: $0.value.weight / sum) }
            bindings.append(VertexBinding(influences: influences, unitPosition: unit,
                                          sources: sources))
        }

        guard let grid = try? makeGrid(cols: cols, rows: rows) else { return nil }
        return SkinnedMesh(cols: cols, rows: rows, bindings: bindings,
                           sourceGrid: grid, size: size, anchorBone: anchorBone)
    }

    private static func makeGrid(cols: Int, rows: Int) throws -> SKWarpGeometryGrid {
        SKWarpGeometryGrid(columns: cols, rows: rows)
    }

    /// SKWarpGeometryGrid exposes positions one at a time; collect them so a
    /// new grid can be built each frame with the same source lattice.
    static func sourcePositions(of grid: SKWarpGeometryGrid) -> [SIMD2<Float>] {
        (0..<grid.vertexCount).map { grid.sourcePosition(at: $0) }
    }

    /// Solve the lattice for the current pose in **skeleton space**.
    ///
    /// Each lattice point is placed by summing, over its influencing bones,
    /// `weight × (bone world transform applied to the bound offset)` — the
    /// standard linear-blend skinning sum. Animated free-form deform rides on
    /// top of skinning.
    ///
    /// This is also what `DeformedCollider` reads, so collision hulls are built
    /// from the very points the renderer draws with: one solver, no second
    /// implementation to drift out of step with the art.
    static func solveWorld(mesh: SkinnedMesh,
                           skeleton: Skeleton,
                           deform: [CGPoint]) -> [CGPoint] {
        var out = [CGPoint](repeating: .zero, count: mesh.bindings.count)
        solveWorld(mesh: mesh, skeleton: skeleton, deform: deform, into: &out)
        return out
    }

    /// The same solve, writing into a caller-owned buffer.
    ///
    /// This runs for every mesh slot of every animated rig, every frame. The
    /// arithmetic is cheap; a fresh array each time is not, and it is the kind of
    /// allocation that shows up as frame-time jitter rather than as a hot line in
    /// a profile. Callers keep one buffer per slot and reuse it.
    static func solveWorld(mesh: SkinnedMesh,
                           skeleton: Skeleton,
                           deform: [CGPoint],
                           into out: inout [CGPoint]) {
        if out.count != mesh.bindings.count {
            out = [CGPoint](repeating: .zero, count: mesh.bindings.count)
        }
        let bones = skeleton.bones
        for (index, binding) in mesh.bindings.enumerated() {
            // Animated free-form deform rides on top of skinning. Keys are
            // authored per mesh vertex, so resample them through the same
            // inverse-distance mapping the weights came from.
            var dx: CGFloat = 0, dy: CGFloat = 0
            if !deform.isEmpty {
                for source in binding.sources where deform.indices.contains(source.vertex) {
                    dx += deform[source.vertex].x * source.weight
                    dy += deform[source.vertex].y * source.weight
                }
            }
            var wx: CGFloat = 0, wy: CGFloat = 0
            for inf in binding.influences {
                guard bones.indices.contains(inf.bone) else { continue }
                let bone = bones[inf.bone]
                let ox = inf.offset.x + dx, oy = inf.offset.y + dy
                wx += (bone.a * ox + bone.c * oy + bone.worldX) * inf.weight
                wy += (bone.b * ox + bone.d * oy + bone.worldY) * inf.weight
            }
            out[index] = CGPoint(x: wx, y: wy)
        }
    }

    /// Destination positions in unit space, ready for
    /// `SKWarpGeometryGrid(... destinationPositions:)` — the skinning solve
    /// above, brought back into the sprite's own 0…1 space.
    static func solve(mesh: SkinnedMesh,
                      skeleton: Skeleton,
                      deform: [CGPoint]) -> [SIMD2<Float>] {
        unitSpace(solveWorld(mesh: mesh, skeleton: skeleton, deform: deform),
                  mesh: mesh, skeleton: skeleton)
    }

    /// skeleton space → the sprite's unit space (sprite centred on its anchor
    /// bone), by inverting the anchor bone's transform.
    static func unitSpace(_ points: [CGPoint],
                          mesh: SkinnedMesh,
                          skeleton: Skeleton) -> [SIMD2<Float>] {
        let anchor = skeleton.bones.indices.contains(mesh.anchorBone)
            ? skeleton.bones[mesh.anchorBone] : nil

        // Invert the anchor bone's transform so results land in sprite space.
        let ia: CGFloat, ib: CGFloat, ic: CGFloat, id: CGFloat
        let ax: CGFloat, ay: CGFloat
        if let anchor {
            let det = anchor.a * anchor.d - anchor.b * anchor.c
            let invDet = abs(det) < 0.00001 ? 0 : 1 / det
            ia = anchor.d * invDet;  ib = -anchor.b * invDet
            ic = -anchor.c * invDet; id = anchor.a * invDet
            ax = anchor.worldX;      ay = anchor.worldY
        } else {
            ia = 1; ib = 0; ic = 0; id = 1; ax = 0; ay = 0
        }

        var out: [SIMD2<Float>] = []
        out.reserveCapacity(points.count)

        for p in points {
            // skeleton → anchor-local
            let lx = ia * (p.x - ax) + ic * (p.y - ay)
            let ly = ib * (p.x - ax) + id * (p.y - ay)
            // anchor-local → unit space (sprite is centred on its anchor)
            let ux = lx / mesh.size.width + 0.5
            let uy = ly / mesh.size.height + 0.5
            out.append(SIMD2<Float>(Float(ux), Float(uy)))
        }
        return out
    }
}
