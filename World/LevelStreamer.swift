import SpriteKit

/// Streams a level's world nodes in and out around the camera.
///
/// The scale problem this solves. The level builder creates every node up front — 49
/// `addChild` sites, all of it resident from load — and nothing was ever culled. For a
/// 50-tile level that is fine. For the 200–500 tile levels a real game has, every
/// off-screen platform still costs a physics body in the broadphase and a node in the
/// scene traversal, every frame, forever.
///
/// Bands, not per-node culling. Nodes are partitioned by their x into fixed-width
/// bands once, at load; each frame the bands inside a window around the camera are
/// attached and the rest are detached. Per-node visibility tests would cost more than
/// they save at this node count, and band boundaries never change so the partition is
/// computed exactly once.
///
/// **Detached, not hidden.** `isHidden` stops a node drawing but leaves its physics
/// body in the world, which is most of the cost. Removing from the parent removes the
/// body with it. Static bodies rebuild for free when the band comes back, which is why
/// this is safe for terrain and would not be for anything mid-simulation — hence the
/// exemptions below.
final class LevelStreamer {

    /// A node the streamer must never detach, and why it is decided by *geometry*
    /// rather than by a list: anything spanning more than a couple of bands is
    /// level-scale scenery (a frise, a backdrop) whose band membership is meaningless.
    private static let spanExemptBands = 2

    private let bandWidth: CGFloat
    /// Bands either side of the camera's own band that stay attached. One is enough to
    /// cover the screen; two gives a band of slack so a fast camera never outruns it.
    private let radius: Int

    private struct Slot {
        let node: SKNode
        let parent: SKNode
    }
    private var bands: [Int: [Slot]] = [:]
    private var attached: Set<Int> = []
    private var lastBand: Int?
    /// Nodes exempt from streaming, kept only so `count` can report honestly.
    private var exemptCount = 0

    init(bandWidth: CGFloat = 320, radius: Int = 2) {
        self.bandWidth = max(80, bandWidth)
        self.radius = max(1, radius)
    }

    private func band(for x: CGFloat) -> Int { Int((x / bandWidth).rounded(.down)) }

    /// Partition nodes into bands. Anything too wide, or without a sensible x, is left
    /// alone and never detached.
    ///
    /// - Returns: how many nodes are being streamed.
    @discardableResult
    func adopt(_ nodes: [SKNode], parent: SKNode) -> Int {
        var streamed = 0
        for node in nodes {
            let frame = node.calculateAccumulatedFrame()
            let spans = frame.width > bandWidth * CGFloat(LevelStreamer.spanExemptBands)
            guard !spans, frame.width.isFinite, node.position.x.isFinite else {
                exemptCount += 1
                continue
            }
            bands[band(for: node.position.x), default: []]
                .append(Slot(node: node, parent: parent))
            streamed += 1
        }
        // Everything starts attached; the first `update` detaches what is far away.
        attached = Set(bands.keys)
        return streamed
    }

    /// Attach the window around `cameraX`, detach the rest.
    ///
    /// Early-outs when the camera has not changed band, which is the common case: this
    /// runs every frame and must cost nothing when nothing moved.
    func update(cameraX: CGFloat) {
        let centre = band(for: cameraX)
        guard centre != lastBand else { return }
        lastBand = centre

        let wanted = Set((centre - radius)...(centre + radius))
        for index in wanted.subtracting(attached) {
            for slot in bands[index] ?? [] where slot.node.parent == nil {
                slot.parent.addChild(slot.node)
            }
        }
        for index in attached.subtracting(wanted) {
            for slot in bands[index] ?? [] where slot.node.parent != nil {
                slot.node.removeFromParent()
            }
        }
        attached = wanted.intersection(Set(bands.keys))
    }

    /// Bring everything back — for a level-wide query, or before tearing down.
    func attachAll() {
        for (index, slots) in bands {
            for slot in slots where slot.node.parent == nil {
                slot.parent.addChild(slot.node)
            }
            attached.insert(index)
        }
        lastBand = nil
    }

    // MARK: Reporting, for the debug overlay and the state document

    var bandCount: Int { bands.count }
    var streamedCount: Int { bands.values.reduce(0) { $0 + $1.count } }
    var exemptedCount: Int { exemptCount }
    var attachedCount: Int {
        attached.reduce(0) { $0 + (bands[$1]?.count ?? 0) }
    }
    /// What fraction of the level is live. The number that says whether this is doing
    /// anything: on a long level it should be small.
    var liveFraction: Double {
        streamedCount == 0 ? 1 : Double(attachedCount) / Double(streamedCount)
    }
}
