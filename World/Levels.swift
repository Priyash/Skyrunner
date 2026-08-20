import Foundation

/// Levels are ASCII maps. One character = one tile (40pt).
///   X = solid ground        C = coin
///   S = player spawn        E = enemy (AI: patrol → alert → chase)
///   ^ = crystal (hazard)    F = goal portal
///   N = friendly villager   B = perched bird (flees when approached)
///   M = moving platform     P = one-way platform (jump up through it)
///   D = breakable crate (punch or ground pound; drops a coin)
///   K = boss (King Blob) — boss levels have NO static F; the portal
///       appears when he goes down
///   . = empty
/// Row 0 is the TOP of the level. All rows in a level are the same length.
/// Design rules the engine assumes:
///   • S, F, E, ^, N, B, D, K need ground (X) directly below; M and P must NOT
///   • bottom-row gaps ≤ 3 tiles; vertical climbs ≤ 3 tiles per jump
///   • never place ^ with ground ≤ 2 tiles directly above it (unjumpable)
///   • exactly one S; exactly one F, or exactly one K and no F
enum Levels {

    /// Every playable level, in order.
    ///
    /// Bundled `level/1` files when there are any, the compiled table otherwise.
    /// Call sites are unchanged by design: this used to *be* the literal, and the
    /// point of the file format is that nothing downstream has to care where rows
    /// came from.
    static var all: [[String]] { LevelLibrary.rows }

    /// Names for the menu, parallel to `all`.
    static var titles: [String] { LevelLibrary.titles }

    /// The fallback table, compiled in.
    ///
    /// Kept so a build with no level files is still a playable game — the same
    /// rule `RigLoader` and `FriezeScene` follow. `Tools/level_export.py` wrote
    /// these out as files; this is the safety net, not the source of truth.
    static let builtIn: [[String]] = [
        // ── Level 1: movement + jumping basics ──────────────
        [
            "..............................................",
            "..............................................",
            "...................C..........................",
            "..................XXX.........................",
            "..........C...........................BC.C....",
            ".........XXX...........C.............XXXXX....",
            "......................XXX.....................",
            "..S...N.............D.........E...........F...",
            "XXXXXXXXXX..XXXXXXXXXXX..XXXXXXXXXXXXXXXXXXXX.",
        ],
        // ── Level 2: spikes, a pit, and a moving platform ───
        [
            "................................................",
            "................................................",
            "...........C....................................",
            "...........XXX.........C.C.C....................",
            ".....C..........E......XXXXX....................",
            "....XXX........XXXX............E........F.......",
            "..............................XXXXX..M.XXXX.....",
            "..S.....^^.........^^^..D.N.....................",
            "XXXXXXXXXXXXXXXXXXXXXXXXXXXXX...................",
        ],
        // ── Level 3: precision gaps + spike runs ────────────
        [
            "..................................................",
            "..................................................",
            "..................................................",
            "........C.........................................",
            ".......XXX.....C.....................C.C.C........",
            "..............XXX.........E........XXXXXXX........",
            "........PPP...............XXXXX...................",
            "..S..^^...B.......E.............^^......N...F.....",
            "XXXXXXXXXXXX...XXXXXXXX...XXXXXXXXX...XXXXXXXXXXXX",
        ],
        // ── Level 4: BOSS: King Blob's arena ────────────────
        [
            "..............................",
            "..............................",
            "..............................",
            "..............................",
            "X............................X",
            "X............................X",
            "X...C.....C........C.....C...X",
            "XS...........K...............X",
            "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        ],
    ]
}
