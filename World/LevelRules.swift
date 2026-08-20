import Foundation

/// The tile alphabet and the level-design rules — as data.
///
/// `Levels.swift` documents these rules in a header comment for whoever
/// hand-edits a map. That is no help to the two things that now also author
/// levels — the visual editor (`Tools/LevelEditor.html`) and the command API
/// (`FriezeKit/Core/EngineAPI.swift`) — so the alphabet and the rules live here
/// in machine-readable form: one table, one validator, three callers. The
/// editor's JavaScript mirrors this file deliberately, the same way the Python
/// composer mirrors the frieze parallax math.
enum TileSymbol {

    struct Tile {
        let symbol: Character
        let name: String
        /// terrain | pickup | actor | hazard | marker
        let category: String
        /// Needs solid ground in the tile directly below it.
        let needsGround: Bool
        /// Must NOT have ground directly below — platforms hang in the air.
        let needsAir: Bool
        /// At most one per level.
        let unique: Bool
        let note: String
    }

    static let legend: [Tile] = [
        Tile(symbol: ".", name: "empty", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "air"),
        Tile(symbol: "X", name: "ground", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "solid; horizontal runs merge into one body"),
        Tile(symbol: "/", name: "slope up-right", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "45° ramp rising to the right; run up it, no jump needed"),
        Tile(symbol: "\\", name: "slope up-left", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "45° ramp rising to the left"),
        Tile(symbol: "P", name: "one-way platform", category: "terrain",
             needsGround: false, needsAir: true, unique: false,
             note: "jump up through it, land on top"),
        Tile(symbol: "M", name: "moving platform", category: "terrain",
             needsGround: false, needsAir: true, unique: false,
             note: "sine drive, ±\(Int(Tuning.moverTravel))pt; carries the player"),
        Tile(symbol: ">", name: "conveyor right", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "carries whatever stands on it at \(Int(Tuning.conveyorSpeed))pt/s"),
        Tile(symbol: "<", name: "conveyor left", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "as above, leftward"),
        Tile(symbol: "!", name: "spring", category: "terrain",
             needsGround: true, needsAir: false, unique: false,
             note: "launches to ~\(Int(Tuning.springLaunch / 40))  tiles; ignores jump input"),
        Tile(symbol: "D", name: "crate", category: "terrain",
             needsGround: true, needsAir: false, unique: false,
             note: "solid until punched or pounded; drops a coin"),
        Tile(symbol: "L", name: "climbable vine", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "hold up/down to climb; jump to leave"),
        Tile(symbol: "#", name: "crusher", category: "hazard",
             needsGround: false, needsAir: true, unique: false,
             note: "drops on a cycle, kills on the way down, retracts"),
        Tile(symbol: "~", name: "updraft", category: "terrain",
             needsGround: false, needsAir: false, unique: false,
             note: "column of rising air; carries the player up while inside"),
        Tile(symbol: "@", name: "checkpoint", category: "marker",
             needsGround: true, needsAir: false, unique: false,
             note: "respawn point once touched; several per level is fine"),
        Tile(symbol: "C", name: "coin", category: "pickup",
             needsGround: false, needsAir: false, unique: false,
             note: "magnetic within \(Int(Tuning.magnetRadius))pt; combos up to ×\(Tuning.comboMaxMultiplier)"),
        Tile(symbol: "S", name: "spawn", category: "marker",
             needsGround: true, needsAir: false, unique: true,
             note: "exactly one per level"),
        Tile(symbol: "F", name: "goal portal", category: "marker",
             needsGround: true, needsAir: false, unique: true,
             note: "one per level, or none on a boss level"),
        Tile(symbol: "E", name: "enemy", category: "actor",
             needsGround: true, needsAir: false, unique: false,
             note: "patrols its platform, chases on sight; stompable"),
        Tile(symbol: "N", name: "villager", category: "actor",
             needsGround: true, needsAir: false, unique: false,
             note: "friendly; waves and speaks"),
        Tile(symbol: "B", name: "bird", category: "actor",
             needsGround: true, needsAir: false, unique: false,
             note: "perched; startles and flies off"),
        Tile(symbol: "K", name: "boss", category: "actor",
             needsGround: true, needsAir: false, unique: true,
             note: "King Blob; the portal appears where he falls"),
        Tile(symbol: "^", name: "crystal", category: "hazard",
             needsGround: true, needsAir: false, unique: false,
             note: "touching it costs a life"),
    ]

    static let allowed: Set<Character> = Set(legend.map(\.symbol))

    /// What input is allowed to contain, which is the legend plus a space.
    ///
    /// A space is an accepted spelling of empty. Everything that hands rows to
    /// the engine writes them with spaces — the editor, the AI planner, a level
    /// typed in a JSON file, `normalize` when it pads a ragged row — because a
    /// grid of dots is unreadable to a human. `normalize` folds them to `.`, so
    /// this is the only place that has to know.
    static let accepted: Set<Character> = allowed.union([" "])

    /// Empty air, however it was spelled.
    static func isEmpty(_ symbol: Character) -> Bool { symbol == "." || symbol == " " }

    /// For error messages: the alphabet as one readable string.
    static let allowedText: String = String(legend.map(\.symbol))

    static func tile(_ symbol: Character) -> Tile? {
        legend.first { $0.symbol == symbol }
    }

    static func name(for symbol: Character) -> String {
        tile(symbol)?.name ?? "unknown"
    }

    /// `spawnActor` kinds → the symbol they write. Sugar over `setTile`, but it
    /// means a producer can say "put an enemy here" without learning the
    /// alphabet first.
    static let actorKinds: [String: Character] = [
        "enemy": "E", "villager": "N", "bird": "B",
        "crate": "D", "coin": "C", "boss": "K",
    ]

    static var actorKindList: [String] { actorKinds.keys.sorted() }

    /// Tiles that block movement (for reachability) — ground, crates, platforms,
    /// slopes, conveyors and springs are all things you can stand on.
    static let solid: Set<Character> = ["X", "D", "M", "P", "/", "\\", ">", "<", "!"]

    /// Tiles a body can occupy. Ground and crates fill their cell; platforms are
    /// thin, so you stand on the cell above them and can also pass through.
    static func isPassable(_ symbol: Character) -> Bool {
        symbol != "X" && symbol != "D"
    }

    /// Tiles that carry the player upward for free, so reachability may climb
    /// through them without a jump.
    static let lifts: Set<Character> = ["L", "~", "!"]

    static var legendJSON: [[String: Any]] {
        legend.map {
            ["symbol": String($0.symbol), "name": $0.name, "category": $0.category,
             "needsGround": $0.needsGround, "needsAir": $0.needsAir,
             "unique": $0.unique, "note": $0.note]
        }
    }
}

/// Validates a map against the rules the level builder assumes.
///
/// Written for generated content: an LLM (or a hurried human) produces a map
/// that parses fine and is unplayable — spawn in mid-air, goal across a
/// five-tile pit, a crystal wedged under a two-tile ceiling. Every check returns
/// prose a producer can act on, and nothing here ever blocks a command: the
/// engine builds what it was told and reports what it thinks of it.
enum LevelRules {

    static let maxRows = 64
    static let maxColumns = 512

    /// Movement envelope, derived from the tuning the player actually runs at.
    /// jumpVelocity 880 with gravity −18 (×150pt/m) → apex ≈ 143pt ≈ 3.5 tiles
    /// and ≈ 0.65s of airtime, which at 260pt/s carries ≈ 4.2 tiles across.
    static let maxJumpUp = 3
    static let maxJumpAcross = 4
    /// Falling covers more ground than jumping does.
    static let maxDropAcross = 5
    /// A dash is 0.16s at 620pt/s ≈ 2.5 tiles, and it can be spent in the air —
    /// so a dash-jump clears noticeably more than a jump.
    static let maxDashAcross = 7
    /// A spring throws you 1360²/(2·2700) ≈ 342pt ≈ 8.5 tiles up.
    static let maxSpringUp = 8

    static var documentedRules: [String] {
        ["exactly one S (spawn)",
         "exactly one F (goal), or exactly one K (boss) and no F",
         "S, F, E, ^, N, B, D, K, !, @ need ground directly below; M, P and # must not",
         "interior gaps in the bottom row ≤ \(maxDashAcross - 1) tiles (a dash clears them)",
         "vertical climbs ≤ \(maxJumpUp) tiles per jump, horizontal ≤ \(maxJumpAcross) "
            + "(≤ \(maxDashAcross) with a dash, ≤ \(maxSpringUp) up off a spring)",
         "never place ^ with ground ≤ 2 tiles directly above it (unjumpable)",
         "an updraft (~) or vine (L) column wants to be ≥ 2 tiles tall to be usable",
         "the goal must be reachable from the spawn"]
    }

    /// Pad every row to the same width with '.' — the level builder assumes a
    /// rectangle, and a hand-written or generated map rarely is one.
    /// Pad every row to the widest, and canonicalise empty to `.`.
    ///
    /// Both halves matter downstream. Ragged rows index out of bounds during the
    /// build; mixed spelling of empty means the same level compares unequal to
    /// itself depending on which tool last touched it, which shows up as a
    /// spurious "level edited" in the state document.
    static func normalize(_ rows: [String]) -> [String] {
        let width = rows.map(\.count).max() ?? 0
        return rows.map { row in
            String(row.map { $0 == " " ? "." : $0 })
                + String(repeating: ".", count: max(0, width - row.count))
        }
    }

    /// Every violation found, as prose. Empty means the map obeys the rules.
    static func validate(_ rawRows: [String]) -> [String] {
        validate(rawRows, solidCells: [])
    }

    /// - Parameter solidCells: `[column, row]` cells that are solid ground even
    ///   though the glyph grid says air — a spline frise's footprint. Terrain can
    ///   come from curves now, and the reachability search still has to know where
    ///   the floor is, so the geometry declares it rather than the grid guessing.
    static func validate(_ rawRows: [String],
                         solidCells: Set<[Int]>) -> [String] {
        var out: [String] = []
        let rows = normalize(rawRows)
        guard !rows.isEmpty, let width = rows.map(\.count).max(), width > 0 else {
            return ["level is empty"]
        }
        let grid = rows.map(Array.init)
        let height = grid.count

        func at(_ col: Int, _ row: Int) -> Character {
            guard grid.indices.contains(row), grid[row].indices.contains(col) else { return "." }
            let glyph = grid[row][col]
            // A frise's footprint is solid ground even where the glyph grid says
            // air. Substituting here means all eight solidity tests below see it
            // without each one having to ask — and an author's explicit glyph
            // always wins, because only empty cells are filled in.
            if glyph == ".", solidCells.contains([col, row]) { return "X" }
            return glyph
        }

        // Counts: uniqueness and the boss/goal exclusivity rule.
        var positions: [Character: [(col: Int, row: Int)]] = [:]
        for r in 0..<height {
            for c in 0..<width {
                let ch = at(c, r)
                if ch != "." { positions[ch, default: []].append((c, r)) }
            }
        }
        // An unknown glyph builds as empty air, so a typo silently deletes a
        // platform. `setLevel` refuses one at the API boundary, but a hand-written
        // level file or the compiled table never passed through that check.
        for symbol in positions.keys.sorted() where !accepted.contains(symbol) {
            let where_ = positions[symbol]!.first!
            out.append("unknown tile '\(symbol)' at column \(where_.col), row "
                       + "\(where_.row) — legal symbols are \(allowedText)")
        }

        let spawns = positions["S"]?.count ?? 0
        if spawns == 0 { out.append("no spawn: add exactly one S") }
        if spawns > 1 { out.append("\(spawns) spawns: exactly one S is allowed") }

        let goals = positions["F"]?.count ?? 0
        let bosses = positions["K"]?.count ?? 0
        if goals == 0 && bosses == 0 {
            out.append("no exit: add one F, or one K for a boss level")
        }
        if goals > 1 { out.append("\(goals) goals: exactly one F is allowed") }
        if bosses > 1 { out.append("\(bosses) bosses: exactly one K is allowed") }
        if goals > 0 && bosses > 0 {
            out.append("boss levels have no static F — the portal appears when K goes down")
        }

        // Support rules, per tile.
        for tile in TileSymbol.legend where tile.needsGround || tile.needsAir {
            for p in positions[tile.symbol] ?? [] {
                let below = p.row + 1
                if tile.needsGround {
                    guard below < height else {
                        out.append("\(tile.name) at (\(p.col),\(p.row)) is on the bottom row "
                                   + "— nothing under it")
                        continue
                    }
                    if !TileSymbol.solid.contains(at(p.col, below)) {
                        out.append("\(tile.name) at (\(p.col),\(p.row)) has no ground below")
                    }
                }
                if tile.needsAir, below < height, TileSymbol.solid.contains(at(p.col, below)) {
                    out.append("\(tile.name) at (\(p.col),\(p.row)) sits on ground — "
                               + "platforms must hang in the air")
                }
            }
        }

        // Crystals need headroom, or they can't be jumped over.
        for p in positions["^"] ?? [] {
            for dr in 1...2 where p.row - dr >= 0 {
                if TileSymbol.solid.contains(at(p.col, p.row - dr)) {
                    out.append("crystal at (\(p.col),\(p.row)) has a ceiling \(dr) tile(s) "
                               + "above — unjumpable")
                    break
                }
            }
        }

        // Interior gaps in the floor. A trailing or leading gap is a deliberate
        // pit (level 2 ends over one); a hole *between* two floor runs is the
        // one that has to be crossable — with a dash, that is 6 tiles.
        let floor = height - 1
        var run = 0
        var sawGround = false
        for c in 0..<width {
            if TileSymbol.solid.contains(at(c, floor)) {
                if sawGround, run > maxDashAcross - 1 {
                    out.append("floor gap of \(run) tiles at column \(c - run) — "
                               + "\(maxDashAcross - 1) is the most a dash can clear")
                }
                sawGround = true
                run = 0
            } else if sawGround {
                run += 1
            }
        }

        // Lift columns need height to be worth placing.
        for symbol in TileSymbol.lifts where symbol != "!" {
            for p in positions[symbol] ?? [] {
                let above = at(p.col, p.row - 1) == symbol
                let below = at(p.col, p.row + 1) == symbol
                if !above && !below {
                    out.append("\(TileSymbol.name(for: symbol)) at (\(p.col),\(p.row)) "
                               + "is a single tile — stack at least two to be usable")
                }
            }
        }

        out.append(contentsOf: reachability(grid: grid, width: width, height: height,
                                            positions: positions))
        return out
    }

    // MARK: Reachability

    /// Can the player get from the spawn to the exit?
    ///
    /// Deliberately **optimistic**: jumps ignore what they'd clip on the way up,
    /// so this can call an impossible level possible — it will not call a
    /// possible level impossible. A validator that cried wolf on hand-made
    /// levels would just be switched off.
    private static func reachability(grid: [[Character]], width: Int, height: Int,
                                     positions: [Character: [(col: Int, row: Int)]]) -> [String] {
        guard let start = positions["S"]?.first else { return [] }
        let exit = positions["F"]?.first ?? positions["K"]?.first
        guard let exit else { return [] }

        func at(_ col: Int, _ row: Int) -> Character {
            guard grid.indices.contains(row), grid[row].indices.contains(col) else { return "." }
            return grid[row][col]
        }

        /// A cell you can stand in: passable, with something solid underfoot.
        func standable(_ col: Int, _ row: Int) -> Bool {
            guard col >= 0, col < width, row >= 0, row < height else { return false }
            guard TileSymbol.isPassable(at(col, row)) else { return false }
            if TileSymbol.lifts.contains(at(col, row)) { return true }
            return TileSymbol.solid.contains(at(col, row + 1))
        }

        var seen = Set<Int>()
        func key(_ c: Int, _ r: Int) -> Int { r * (width + 1) + c }

        // The spawn itself may be drawn one tile above its floor; snap down to
        // the first cell that can actually be stood in.
        var origin: (col: Int, row: Int)? = nil
        for dr in 0...3 where standable(start.col, start.row + dr) {
            origin = (start.col, start.row + dr)
            break
        }
        guard let origin else {
            return ["spawn at (\(start.col),\(start.row)) has no floor to stand on"]
        }

        var frontier = [origin]
        seen.insert(key(origin.col, origin.row))
        var reachedExit = false

        while let cell = frontier.popLast() {
            if abs(cell.col - exit.col) <= 1 && abs(cell.row - exit.row) <= 1 {
                reachedExit = true
                break
            }
            var next: [(col: Int, row: Int)] = []

            // Walk.
            for dc in [-1, 1] where standable(cell.col + dc, cell.row) {
                next.append((cell.col + dc, cell.row))
            }
            // Jump: up to maxJumpUp rows up, maxJumpAcross columns across.
            // `dr == 0` is the flat hop over a gap — the most common jump in the
            // game, and the one whose omission makes a validator cry wolf.
            for dr in 0...maxJumpUp {
                for dc in -maxJumpAcross...maxJumpAcross
                where standable(cell.col + dc, cell.row - dr) {
                    next.append((cell.col + dc, cell.row - dr))
                }
            }
            // Dash: further across, but it does not gain height on its own, so
            // it only reaches level or lower ground.
            for dr in 0...1 {
                for dc in -maxDashAcross...maxDashAcross
                where standable(cell.col + dc, cell.row - dr) {
                    next.append((cell.col + dc, cell.row - dr))
                }
            }
            // Springs throw you far higher than a jump; a spring anywhere within
            // reach opens up everything above it.
            if at(cell.col, cell.row + 1) == "!" || at(cell.col, cell.row) == "!" {
                for dr in 1...maxSpringUp {
                    for dc in -maxJumpAcross...maxJumpAcross
                    where standable(cell.col + dc, cell.row - dr) {
                        next.append((cell.col + dc, cell.row - dr))
                    }
                }
            }
            // Vines and updrafts: ascend or descend the column for free, then
            // step off either side at any height.
            if TileSymbol.lifts.contains(at(cell.col, cell.row)) {
                var r = cell.row
                while r > 0, TileSymbol.lifts.contains(at(cell.col, r - 1)) {
                    r -= 1
                    next.append((cell.col, r))
                    for dc in [-1, 1] where standable(cell.col + dc, r) {
                        next.append((cell.col + dc, r))
                    }
                }
            }
            // Entering a lift column from beside it.
            for dc in [-1, 1] where TileSymbol.lifts.contains(at(cell.col + dc, cell.row)) {
                next.append((cell.col + dc, cell.row))
            }
            // Drop: step off an edge and land on the first floor below.
            for dc in -maxDropAcross...maxDropAcross {
                let c = cell.col + dc
                guard c >= 0, c < width else { continue }
                var r = cell.row + 1
                while r < height {
                    if standable(c, r) { next.append((c, r)); break }
                    if TileSymbol.solid.contains(at(c, r)) { break }
                    r += 1
                }
            }

            for step in next where !seen.contains(key(step.col, step.row)) {
                seen.insert(key(step.col, step.row))
                frontier.append(step)
            }
        }

        guard !reachedExit else { return [] }
        let what = positions["F"]?.first != nil ? "goal" : "boss"
        return ["\(what) at (\(exit.col),\(exit.row)) is not reachable from the spawn "
                + "(≤\(maxJumpUp) up / ≤\(maxJumpAcross) across per jump, "
                + "≤\(maxDashAcross) with a dash, springs and vines included)"]
    }
}
