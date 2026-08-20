import Foundation
import CoreGraphics

/// A level as a file: `level/1`.
///
/// Why this exists. Levels used to be a Swift literal, which made the visual
/// editor a *drawing* tool rather than the pipeline — you drew a level, then
/// copy-pasted rows into `Levels.swift` and rebuilt. Everything else in the
/// engine is already data resolved by name at runtime (rigs, backdrops, lighting),
/// and levels were the one thing that wasn't.
///
/// Now the editor writes `Assets/Levels/<name>.json` through the local bridge and
/// the game reads it out of the bundle. The compiled table in `Levels.builtIn`
/// stays as the fallback, so a build with no level files still ships a playable
/// game — the same graceful-degradation rule the rig and frieze loaders follow.
///
/// ```json
/// {
///   "format": "level/1",
///   "name": "grove",
///   "order": 10,
///   "title": "Sunlit Grove",
///   "frieze": "forest_backdrop",
///   "timeOfDay": 0.45,
///   "music": "theme_grove",
///   "grade": "grove",
///   "camera": {"zones": [{"col": 30, "width": 12, "zoom": 1.3}]},
///   "triggers": [{"name": "ambush", "region": {"col": 18, "width": 2},
///                 "actions": [{"do": "spawn", "kind": "enemy", "col": 22,
///                              "row": 7, "count": 3}]}],
///   "rows": ["S    C   F",
///            "XXXXXXXXXX"]
/// }
/// ```
struct LevelFile: Codable {

    static let currentFormat = "level/1"

    var format: String
    /// File-stem identity, used by the editor and the bridge to address a level.
    var name: String
    /// Sort key. Sparse on purpose (10, 20, 30…) so a level can be inserted
    /// between two others without renumbering every file after it.
    var order: Int
    /// Shown on the menu. Falls back to the name.
    var title: String?
    /// Backdrop for this level. Previously global, which meant every level in the
    /// game looked the same place.
    var frieze: String?
    /// 0 dawn … 1 dusk. Drives the lighting rig, so a level can be an evening.
    var timeOfDay: CGFloat?
    /// Music track for this level, e.g. `theme_grove`. Absent means silence, which
    /// is a legitimate choice for a level built around a sound cue.
    var music: String?
    /// Colour-grade name — `grove`, `hollow`, `evening`, `arena`, `neutral`.
    /// The grade does more for a level's identity than any single asset, so it
    /// belongs in the level file next to the backdrop and the music.
    var grade: String?
    var rows: [String]
    /// Spline-extruded terrain and painted backdrop geometry. Additive to the tile
    /// grid: a level can be all tiles, all frises, or any mix.
    var frises: [FriseSpec]?
    /// Set pieces: when the player reaches here, do this. The thing that makes a
    /// level a designed moment rather than a room.
    var triggers: [TriggerSpec]?
    /// Framing. Absent means follow-with-lead everywhere, which is what every level
    /// did before framing was authorable.
    var camera: CameraSpec?
    /// Behaviour graph for this level's enemies, e.g. `behaviour_hopper`. Absent
    /// keeps the built-in machine, so an old level is unchanged.
    var enemyBehaviour: String?

    var displayTitle: String { title ?? name }

    /// Grid cells the frises make solid.
    ///
    /// The tile grid stays the authority for *design rules* — reachability is
    /// answered on the grid — so spline terrain has to declare its footprint or a
    /// level built from curves reads as one with no ground at all.
    func friseFootprint(tile: CGFloat = Tuning.tileSize) -> Set<[Int]> {
        guard let frises else { return [] }
        let normalized = LevelRules.normalize(rows)
        let columns = normalized.map(\.count).max() ?? 0
        // Row 0 is the top of the grid, and the scene's origin is at the bottom,
        // so the top edge sits at rows × tile.
        let originY = CGFloat(normalized.count) * tile
        var cells: Set<[Int]> = []
        for spec in frises {
            cells.formUnion(Frise.footprint(spec, tile: tile, rows: normalized.count,
                                            columns: columns, originY: originY))
        }
        return cells
    }

    /// Problems that make the file unusable, as opposed to design warnings —
    /// which are `LevelRules.validate`'s job and are reported separately so a
    /// work-in-progress level still loads.
    var structuralProblems: [String] {
        var out: [String] = []
        if format != LevelFile.currentFormat {
            out.append("format is '\(format)', expected '\(LevelFile.currentFormat)'")
        }
        if name.isEmpty { out.append("name is empty") }
        if rows.isEmpty { out.append("no rows") }
        if rows.count > LevelRules.maxRows {
            out.append("\(rows.count) rows exceeds the \(LevelRules.maxRows) limit")
        }
        if let width = rows.map(\.count).max(), width > LevelRules.maxColumns {
            out.append("\(width) columns exceeds the \(LevelRules.maxColumns) limit")
        }
        for (index, spec) in (frises ?? []).enumerated() {
            for problem in spec.problems {
                out.append("frise \(index) (\(spec.kind.rawValue)): \(problem)")
            }
        }
        var seen: Set<String> = []
        for spec in triggers ?? [] {
            out += spec.structuralProblems
            if !seen.insert(spec.name).inserted {
                out.append("two triggers are both named '\(spec.name)', so "
                           + "`afterTrigger` cannot address either")
            }
        }
        // A sequencing gate that names a trigger this level doesn't have can never
        // open — the set piece would silently never fire.
        let names = Set((triggers ?? []).map(\.name))
        for spec in triggers ?? [] {
            if let previous = spec.requires?.afterTrigger, !names.contains(previous) {
                out.append("'\(spec.name)' waits for trigger '\(previous)', which "
                           + "this level does not define")
            }
        }
        // A `move` action naming geometry this level doesn't have is a set piece
        // that silently does nothing — the gate never opens and there is no error
        // anywhere. Tile runs are merged and anonymous, so the only addressable
        // geometry is a named frise.
        let addressable = Set((frises ?? []).compactMap(\.name))
        for spec in triggers ?? [] {
            for action in spec.actions {
                if case .move(let target, _, _, _) = action,
                   !addressable.contains(target) {
                    out.append("'\(spec.name)' moves '\(target)', which no frise in "
                               + "this level is named — give a frise "
                               + "\"name\": \"\(target)\"")
                }
            }
        }
        out += camera?.structuralProblems ?? []
        return out
    }
}

/// Every level the build can play, in order.
///
/// Bundled files win; the compiled table answers when there are none. The result
/// is computed once — a level list that changed under a running scene would
/// invalidate the index the player is standing in.
enum LevelLibrary {

    /// The index, when the bundle has one. This is the launch-time cost: one small
    /// file rather than a decode of every level.
    static let index: LevelIndex? = LevelIndex.load()

    /// Level identities in play order — name, order, title. Never rows.
    static let entries: [LevelIndex.Entry] = {
        if let index {
            return index.levels.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        }
        // No index: fall back to scanning and decoding, which is what shipped before
        // and is still correct — just O(levels) at launch. `Tools/level_index.py`
        // generates the index; the audit reports when it is missing or stale.
        return legacyScan().map {
            LevelIndex.Entry(name: $0.name, order: $0.order, title: $0.title,
                             cols: $0.rows.map(\.count).max(), rows: $0.rows.count)
        }
    }()

    /// Full contents for a level, decoded on demand and cached.
    static func file(at index: Int) -> LevelFile? {
        guard entries.indices.contains(index) else { return nil }
        return LevelStore.shared.level(named: entries[index].name)
    }

    /// Rows only, which is what the scene builder consumes.
    ///
    /// Indexed access rather than an eager array: `Levels.all` used to materialise
    /// every level's rows, which is exactly the thing that does not scale.
    static func rows(at index: Int) -> [String]? {
        guard let file = file(at: index) else {
            return Levels.builtIn.indices.contains(index)
                ? Levels.builtIn[index] : nil
        }
        return LevelRules.normalize(file.rows)
    }

    /// Every level's rows. Kept for the validator and the tests, which genuinely do
    /// want all of them — and deliberately *not* used by the runtime.
    static var rows: [[String]] {
        guard !entries.isEmpty else { return Levels.builtIn }
        return entries.indices.compactMap { rows(at: $0) }
    }

    static var count: Int { entries.isEmpty ? Levels.builtIn.count : entries.count }

    /// Names in play order, for the menu and for tooling. Straight from the index, so
    /// drawing a menu of a thousand levels costs one file read.
    static var titles: [String] {
        entries.isEmpty
            ? (1...max(Levels.builtIn.count, 1)).map { "Level \($0)" }
            : entries.map(\.displayTitle)
    }

    /// Every level, fully decoded.
    ///
    /// For the validator and the tests, which genuinely want all of them. The
    /// **runtime must not call this** — decoding every level is precisely the cost
    /// the index exists to avoid, and at a thousand levels it is a second of launch.
    static var files: [LevelFile] { entries.indices.compactMap { file(at: $0) } }

    /// Problems found while loading, so `make verify` and the tests can report them
    /// instead of a level silently vanishing from the menu.
    static var loadProblems: [String] {
        var out = index?.problems ?? []
        // An index that names a level whose file is missing or broken is the failure
        // mode the index introduces, so it is the one worth reporting loudly.
        for entry in entries where LevelStore.shared.level(named: entry.name) == nil {
            out.append("index lists '\(entry.name)' but \(entry.name).json is "
                       + "missing or does not decode")
        }
        return out
    }

    /// The pre-index behaviour: scan the bundle and decode everything.
    private static func legacyScan() -> [LevelFile] {
        // Resources are bundled flat (every loader here resolves by bare name),
        // so there is no subdirectory to enumerate — filter the bundle's JSON by
        // what decodes as a level. There are a handful of JSON files in total, so
        // the cost is nil and the alternative is a naming convention that a hand-
        // written file can get wrong.
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil) else { return [] }
        var found: [LevelFile] = []
        var problems: [String] = []
        let decoder = JSONDecoder()
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            // A rig or a frieze scene has no `format: level/1`, so it fails here
            // and is skipped — this is the filter, not an error path.
            guard let file = try? decoder.decode(LevelFile.self, from: data),
                  file.format == LevelFile.currentFormat else { continue }
            let structural = file.structuralProblems
            if structural.isEmpty {
                found.append(file)
            } else {
                problems.append("\(url.lastPathComponent): "
                                + structural.joined(separator: "; "))
            }
        }
        // Two files claiming the same slot would order unpredictably between
        // runs, which reads as levels shuffling themselves.
        var seen: Set<Int> = []
        for file in found.sorted(by: { $0.name < $1.name }) where !seen.insert(file.order).inserted {
            problems.append("order \(file.order) is used by more than one level "
                            + "(including '\(file.name)')")
        }
        loadProblems = problems
        return found.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }
}
