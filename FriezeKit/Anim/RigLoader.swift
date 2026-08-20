import Foundation
import CoreGraphics

/// Loads skeleton rigs from JSON. Two dialects are supported:
///
///  • **Spine JSON** (`.json` exported from the Spine editor) — the widely used
///    industry format. We read the public export schema: bones, slots, skins,
///    ik, animations. Attachment images are matched by name against bundle
///    images or an SKTextureAtlas.
///  • **AnimKit rig** (`"format": "animkit-rig/1"`) — what the bundled Rig
///    Editor writes. Same data model, flatter and easier to hand-edit.
///
/// Both produce a `SkeletonData` that the runtime treats identically.
enum RigLoader {

    enum LoadError: Error { case notFound(String), malformed(String) }

    static func load(named name: String, bundle: Bundle = .main) throws -> SkeletonData {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw LoadError.notFound(name)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.malformed(name)
        }
        if let fmt = root["format"] as? String, fmt.hasPrefix("animkit-rig") {
            return try parseAnimKit(root)
        }
        return try parseSpine(root)
    }

    // MARK: - Shared helpers

    private static func f(_ any: Any?, _ fallback: CGFloat = 0) -> CGFloat {
        if let n = any as? NSNumber { return CGFloat(n.doubleValue) }
        return fallback
    }

    private static func curve(from any: Any?) -> Curve {
        if let s = any as? String { return s == "stepped" ? .stepped : .linear }
        if let a = any as? [Any], a.count >= 4 {
            return .bezier(cx1: f(a[0]), cy1: f(a[1]), cx2: f(a[2]), cy2: f(a[3]))
        }
        return .linear
    }

    /// Bones must be ordered parent-before-child for the single-pass transform.
    private static func topoSort(_ raw: [[String: Any]]) throws -> [[String: Any]] {
        var byName: [String: [String: Any]] = [:]
        for b in raw { if let n = b["name"] as? String { byName[n] = b } }
        var ordered: [[String: Any]] = []
        var placed = Set<String>()
        var guardCount = 0
        while ordered.count < raw.count {
            guardCount += 1
            if guardCount > raw.count + 2 { throw LoadError.malformed("bone cycle") }
            for b in raw {
                guard let n = b["name"] as? String, !placed.contains(n) else { continue }
                let parent = b["parent"] as? String
                if parent == nil || placed.contains(parent!) {
                    ordered.append(b); placed.insert(n)
                }
            }
        }
        return ordered
    }

    private static func parseBones(_ raw: [[String: Any]], into out: SkeletonData) throws {
        let ordered = try topoSort(raw)
        var indexByName: [String: Int] = [:]
        for (i, b) in ordered.enumerated() {
            guard let name = b["name"] as? String else { throw LoadError.malformed("bone name") }
            indexByName[name] = i
        }
        for b in ordered {
            guard let name = b["name"] as? String else { continue }
            var parentIndex: Int? = nil
            if let p = b["parent"] as? String { parentIndex = indexByName[p] }
            var bone = BoneData(name: name, parentIndex: parentIndex)
            bone.length = f(b["length"])
            bone.x = f(b["x"]); bone.y = f(b["y"])
            bone.rotation = f(b["rotation"])
            bone.scaleX = f(b["scaleX"], 1); bone.scaleY = f(b["scaleY"], 1)
            bone.shearX = f(b["shearX"]); bone.shearY = f(b["shearY"])
            if let inherit = b["inheritRotation"] as? Bool { bone.inheritRotation = inherit }
            if let transform = b["transform"] as? String {
                bone.inheritRotation = !transform.contains("noRotation")
            }
            out.bones.append(bone)
        }
    }

    private static func parseAttachment(_ name: String, _ dict: [String: Any]) -> AttachmentData? {
        let type = (dict["type"] as? String) ?? "region"
        let image = (dict["path"] as? String) ?? (dict["image"] as? String) ?? name
        switch type {
        case "mesh", "skinnedmesh", "weightedmesh":
            guard let verts = dict["vertices"] as? [Any],
                  let uvsRaw = dict["uvs"] as? [Any],
                  let tris = dict["triangles"] as? [Any] else { return nil }

            var uvs: [CGPoint] = []
            var i = 0
            while i + 1 < uvsRaw.count {
                uvs.append(CGPoint(x: f(uvsRaw[i]), y: f(uvsRaw[i + 1]))); i += 2
            }
            let vertexCount = uvs.count

            var points: [CGPoint] = []
            var weights: [[MeshInfluence]]? = nil

            if verts.count == vertexCount * 2 {
                // Unweighted: plain x,y pairs in attachment space.
                i = 0
                while i + 1 < verts.count {
                    points.append(CGPoint(x: f(verts[i]), y: f(verts[i + 1]))); i += 2
                }
            } else {
                // Spine weighted encoding, per vertex:
                //   boneCount, then boneCount × (boneIndex, x, y, weight)
                var built: [[MeshInfluence]] = []
                i = 0
                while i < verts.count {
                    let n = Int(f(verts[i])); i += 1
                    guard n > 0, i + n * 4 <= verts.count else { break }
                    var infl: [MeshInfluence] = []
                    var blendedX: CGFloat = 0, blendedY: CGFloat = 0
                    for _ in 0..<n {
                        let bone = Int(f(verts[i]))
                        let vx = f(verts[i + 1]), vy = f(verts[i + 2])
                        let w = f(verts[i + 3])
                        i += 4
                        infl.append(MeshInfluence(bone: bone,
                                                  offset: CGPoint(x: vx, y: vy),
                                                  weight: w))
                        blendedX += vx * w; blendedY += vy * w
                    }
                    built.append(infl)
                    points.append(CGPoint(x: blendedX, y: blendedY))  // setup pose
                }
                if !built.isEmpty { weights = built }
            }
            return .mesh(image: image, vertices: points, uvs: uvs,
                         triangles: tris.map { Int(f($0)) }, weights: weights,
                         width: f(dict["width"], 0), height: f(dict["height"], 0))
        case "boundingbox":
            guard let verts = dict["vertices"] as? [Any] else { return nil }
            var points: [CGPoint] = []
            var i = 0
            while i + 1 < verts.count {
                points.append(CGPoint(x: f(verts[i]), y: f(verts[i + 1]))); i += 2
            }
            return .box(vertices: points)
        default:
            return .region(image: image, x: f(dict["x"]), y: f(dict["y"]),
                           rotation: f(dict["rotation"]),
                           width: f(dict["width"], 1), height: f(dict["height"], 1),
                           scaleX: f(dict["scaleX"], 1), scaleY: f(dict["scaleY"], 1))
        }
    }

    private static func parseSlots(_ raw: [[String: Any]], into out: SkeletonData) {
        for s in raw {
            guard let name = s["name"] as? String,
                  let boneName = s["bone"] as? String,
                  let boneIndex = out.boneIndex(named: boneName) else { continue }
            var slot = SlotData(name: name, boneIndex: boneIndex)
            slot.defaultAttachment = s["attachment"] as? String
            if let hex = s["color"] as? String, hex.count >= 8 {
                let chars = Array(hex)
                var comps: [CGFloat] = []
                for i in stride(from: 0, to: 8, by: 2) {
                    comps.append(CGFloat(Int(String(chars[i...i+1]), radix: 16) ?? 255) / 255)
                }
                slot.colorRGBA = comps
            }
            if let blend = s["blend"] as? String { slot.additive = blend == "additive" }
            out.slots.append(slot)
        }
    }

    private static func parseIK(_ raw: [[String: Any]], into out: SkeletonData) {
        for c in raw {
            guard let name = c["name"] as? String,
                  let boneNames = c["bones"] as? [String],
                  let targetName = c["target"] as? String,
                  let target = out.boneIndex(named: targetName) else { continue }
            let indices = boneNames.compactMap { out.boneIndex(named: $0) }
            guard !indices.isEmpty else { continue }
            var ik = IKConstraintData(name: name, boneIndices: indices, targetBoneIndex: target)
            ik.mix = f(c["mix"], 1)
            ik.stretch = (c["stretch"] as? Bool) ?? false
            ik.softness = f(c["softness"])
            // Spine writes either `bendPositive` (bool) or `bendDirection` (±1).
            if let bp = c["bendPositive"] as? Bool {
                ik.bendPositive = bp
            } else {
                ik.bendPositive = f(c["bendDirection"], 1) >= 0
            }
            out.ikConstraints.append(ik)
        }
    }

    private static func parseAnimations(_ raw: [String: Any], into out: SkeletonData) {
        for (animName, body) in raw {
            guard let body = body as? [String: Any] else { continue }
            var timelines: [Timeline] = []

            if let bonesDict = body["bones"] as? [String: Any] {
                for (boneName, tracksAny) in bonesDict {
                    guard let bi = out.boneIndex(named: boneName),
                          let tracks = tracksAny as? [String: Any] else { continue }
                    if let rot = tracks["rotate"] as? [[String: Any]] {
                        let keys = rot.map {
                            Keyframe(time: TimeInterval(f($0["time"])),
                                     value: f($0["value"] ?? $0["angle"]),
                                     curve: curve(from: $0["curve"]))
                        }.sorted { $0.time < $1.time }
                        timelines.append(RotateTimeline(boneIndex: bi, keys: keys))
                    }
                    if let tr = tracks["translate"] as? [[String: Any]] {
                        let sorted = tr.sorted { f($0["time"]) < f($1["time"]) }
                        let xk = sorted.map { Keyframe(time: TimeInterval(f($0["time"])),
                                                       value: f($0["x"]), curve: curve(from: $0["curve"])) }
                        let yk = sorted.map { Keyframe(time: TimeInterval(f($0["time"])),
                                                       value: f($0["y"]), curve: curve(from: $0["curve"])) }
                        timelines.append(TranslateTimeline(boneIndex: bi, xKeys: xk, yKeys: yk))
                    }
                    if let sh = tracks["shear"] as? [[String: Any]] {
                        let sorted = sh.sorted { f($0["time"]) < f($1["time"]) }
                        let xk = sorted.map { Keyframe(time: TimeInterval(f($0["time"])),
                                                      value: f($0["x"]), curve: curve(from: $0["curve"])) }
                        let yk = sorted.map { Keyframe(time: TimeInterval(f($0["time"])),
                                                      value: f($0["y"]), curve: curve(from: $0["curve"])) }
                        timelines.append(ShearTimeline(boneIndex: bi, xKeys: xk, yKeys: yk))
                    }
                    if let sc = tracks["scale"] as? [[String: Any]] {
                        let sorted = sc.sorted { f($0["time"]) < f($1["time"]) }
                        let xk = sorted.map { Keyframe(time: TimeInterval(f($0["time"])),
                                                       value: f($0["x"], 1), curve: curve(from: $0["curve"])) }
                        let yk = sorted.map { Keyframe(time: TimeInterval(f($0["time"])),
                                                       value: f($0["y"], 1), curve: curve(from: $0["curve"])) }
                        timelines.append(ScaleTimeline(boneIndex: bi, xKeys: xk, yKeys: yk))
                    }
                }
            }

            if let slotsDict = body["slots"] as? [String: Any] {
                for (slotName, tracksAny) in slotsDict {
                    guard let si = out.slotIndex(named: slotName),
                          let tracks = tracksAny as? [String: Any] else { continue }
                    if let att = tracks["attachment"] as? [[String: Any]] {
                        let keys = att.map {
                            Keyframe<String?>(time: TimeInterval(f($0["time"])),
                                              value: $0["name"] as? String)
                        }.sorted { $0.time < $1.time }
                        timelines.append(AttachmentTimeline(slotIndex: si, keys: keys))
                    }
                    if let col = tracks["color"] as? [[String: Any]] {
                        let keys: [Keyframe<[CGFloat]>] = col.compactMap {
                            guard let hex = $0["color"] as? String, hex.count >= 8 else { return nil }
                            let chars = Array(hex)
                            var comps: [CGFloat] = []
                            for i in stride(from: 0, to: 8, by: 2) {
                                comps.append(CGFloat(Int(String(chars[i...i+1]), radix: 16) ?? 255) / 255)
                            }
                            return Keyframe(time: TimeInterval(f($0["time"])), value: comps,
                                            curve: curve(from: $0["curve"]))
                        }.sorted { $0.time < $1.time }
                        timelines.append(ColorTimeline(slotIndex: si, keys: keys))
                    }
                }
            }

            if let deformRoot = body["deform"] as? [String: Any] {
                for (_, slotsAny) in deformRoot {
                    guard let slotsDict = slotsAny as? [String: Any] else { continue }
                    for (slotName, attsAny) in slotsDict {
                        guard let si = out.slotIndex(named: slotName),
                              let atts = attsAny as? [String: Any] else { continue }
                        for (_, framesAny) in atts {
                            guard let frames = framesAny as? [[String: Any]] else { continue }
                            let keys: [Keyframe<[CGPoint]>] = frames.map { fr in
                                var pts: [CGPoint] = []
                                if let verts = fr["vertices"] as? [Any] {
                                    var i = 0
                                    while i + 1 < verts.count {
                                        pts.append(CGPoint(x: f(verts[i]), y: f(verts[i + 1]))); i += 2
                                    }
                                }
                                return Keyframe(time: TimeInterval(f(fr["time"])), value: pts,
                                                curve: curve(from: fr["curve"]))
                            }.sorted { $0.time < $1.time }
                            timelines.append(DeformTimeline(slotIndex: si, keys: keys))
                        }
                    }
                }
            }

            // Draw order. Spine writes each key as the *offsets* that change:
            // {"offsets":[{"slot":"name","offset":n}]}. Replaying that into a
            // full order is the loader's job, because the runtime should not have
            // to know the export dialect.
            if let orders = body["drawOrder"] as? [[String: Any]] {
                var keys: [Keyframe<[Int]>] = []
                for frame in orders {
                    var order = Array(out.slots.indices)
                    if let offsets = frame["offsets"] as? [[String: Any]] {
                        // Build the unchanged remainder, then place shifted slots.
                        var shifted: [Int: Int] = [:]
                        for entry in offsets {
                            guard let name = entry["slot"] as? String,
                                  let index = out.slotIndex(named: name) else { continue }
                            shifted[index] = index + Int(f(entry["offset"]))
                        }
                        var result = [Int?](repeating: nil, count: order.count)
                        for (index, target) in shifted where result.indices.contains(target) {
                            result[target] = index
                        }
                        var pool = order.filter { shifted[$0] == nil }
                        for i in result.indices where result[i] == nil {
                            result[i] = pool.isEmpty ? i : pool.removeFirst()
                        }
                        order = result.map { $0 ?? 0 }
                    }
                    keys.append(Keyframe(time: TimeInterval(f(frame["time"])), value: order))
                }
                if !keys.isEmpty {
                    timelines.append(DrawOrderTimeline(
                        keys: keys.sorted { $0.time < $1.time }))
                }
            }

            if let iks = body["ik"] as? [String: Any] {
                for (name, framesAny) in iks {
                    guard let index = out.ikConstraints.firstIndex(where: { $0.name == name }),
                          let frames = framesAny as? [[String: Any]] else { continue }
                    let keys = frames.map {
                        Keyframe(time: TimeInterval(f($0["time"])),
                                 value: f($0["mix"], 1), curve: curve(from: $0["curve"]))
                    }.sorted { $0.time < $1.time }
                    timelines.append(IKTimeline(constraintIndex: index, keys: keys))
                }
            }

            if let events = body["events"] as? [[String: Any]] {
                let keys = events.compactMap { e -> Keyframe<String>? in
                    guard let n = e["name"] as? String else { return nil }
                    return Keyframe(time: TimeInterval(f(e["time"])), value: n)
                }.sorted { $0.time < $1.time }
                if !keys.isEmpty { timelines.append(EventTimeline(keys: keys)) }
            }

            out.animations[animName] = AnimationClip(name: animName, timelines: timelines)
        }
    }

    // MARK: - Dialects

    private static func parseSpine(_ root: [String: Any]) throws -> SkeletonData {
        let out = SkeletonData()
        guard let bones = root["bones"] as? [[String: Any]] else {
            throw LoadError.malformed("no bones array")
        }
        try parseBones(bones, into: out)
        parseSlots((root["slots"] as? [[String: Any]]) ?? [], into: out)
        parseIK((root["ik"] as? [[String: Any]]) ?? [], into: out)

        if let skins = root["skins"] as? [[String: Any]] {          // Spine 3.8+
            for skin in skins {
                guard let skinName = skin["name"] as? String,
                      let attachments = skin["attachments"] as? [String: Any] else { continue }
                var built: [String: [String: AttachmentData]] = [:]
                for (slotName, attsAny) in attachments {
                    guard let atts = attsAny as? [String: Any] else { continue }
                    var slotAtts: [String: AttachmentData] = [:]
                    for (attName, dAny) in atts {
                        if let d = dAny as? [String: Any],
                           let parsed = parseAttachment(attName, d) { slotAtts[attName] = parsed }
                    }
                    built[slotName] = slotAtts
                }
                out.skins[skinName] = built
            }
        } else if let skins = root["skins"] as? [String: Any] {      // legacy
            for (skinName, slotsAny) in skins {
                guard let slots = slotsAny as? [String: Any] else { continue }
                var built: [String: [String: AttachmentData]] = [:]
                for (slotName, attsAny) in slots {
                    guard let atts = attsAny as? [String: Any] else { continue }
                    var slotAtts: [String: AttachmentData] = [:]
                    for (attName, dAny) in atts {
                        if let d = dAny as? [String: Any],
                           let parsed = parseAttachment(attName, d) { slotAtts[attName] = parsed }
                    }
                    built[slotName] = slotAtts
                }
                out.skins[skinName] = built
            }
        }
        parseAnimations((root["animations"] as? [String: Any]) ?? [:], into: out)
        return out
    }

    private static func parseAnimKit(_ root: [String: Any]) throws -> SkeletonData {
        // Same shape as Spine minus the versioning cruft, so reuse the parsers.
        return try parseSpine(root)
    }
}
