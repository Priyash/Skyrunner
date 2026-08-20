import SpriteKit

/// In-engine editing: paint the level while the game is running.
///
/// The gap this closes. Every other authoring surface here is external — an HTML editor,
/// a Python generator, a command file. That works, but it means the loop is *edit,
/// switch app, rebuild, look*. UbiArt's defining productivity feature was that you
/// edited the level inside the running game and saw the result immediately, and no
/// amount of good offline tooling substitutes for it.
///
/// What it does:
///   * paint and erase tiles by touch, with a palette
///   * pan and zoom the camera freely, decoupled from the player
///   * **play from here** — drop the spawn under your finger and resume
///   * undo, back to the state the level loaded in
///   * write the edited level out to `Documents/` where the desktop bridge collects it
///
/// Deliberate constraints:
///   * **DEBUG only.** It is a development tool; it must not ship in a release binary,
///     and it must not cost a release binary anything.
///   * **Gameplay is frozen while editing.** Painting a platform under a moving player
///     produces a physics resolution nobody asked for.
///   * **The scene rebuilds on exit, not per stroke.** The level graph is built once at
///     load — that is the same trade the command API makes, and rebuilding per tile
///     would be unusable.
///   * **It never writes into the app bundle.** It cannot; a device app has no access.
///     It writes to `Documents/`, which is exactly how the existing bridge already
///     moves data back to the host.
final class EditorOverlay: SKNode {

    /// What the overlay asks the scene to do. The overlay owns *interaction*; the scene
    /// owns the world — the same split as `TriggerRuntime` and `PlayerMotion`.
    enum Request {
        /// Rebuild with these rows.
        case apply(rows: [String])
        /// Rebuild with these rows and spawn the player at this cell.
        case playFrom(rows: [String], col: Int, row: Int)
        /// Leave edit mode, discarding nothing (rows already applied).
        case close
        /// Pan the camera by a delta in scene points.
        case pan(dx: CGFloat, dy: CGFloat)
        /// Multiply the camera scale.
        case zoom(factor: CGFloat)
    }

    var onRequest: ((Request) -> Void)?

    private var rows: [String]
    private let original: [String]
    private var undoStack: [[String]] = []
    private let tile: CGFloat
    private let sceneSize: CGSize

    /// The glyph the brush paints. `.` erases.
    private var brush: Character = "X"
    private var painting = false
    private var lastPaintedCell: (col: Int, row: Int)?

    // UI
    private let paletteBar = SKNode()
    private let statusLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private var swatches: [Character: SKShapeNode] = [:]
    private let gridOverlay = SKNode()

    /// The palette. A curated subset, not the whole 22-glyph legend: a touch palette
    /// with 22 entries is unusable, and these are the tiles you actually place while
    /// blocking out a level. The full legend stays available in the HTML editor.
    private static let paletteGlyphs: [Character] =
        [".", "X", "P", "M", "D", "C", "E", "^", "!", "@", "L", "F"]

    init(rows: [String], tile: CGFloat, sceneSize: CGSize) {
        self.rows = LevelRules.normalize(rows)
        self.original = self.rows
        self.tile = tile
        self.sceneSize = sceneSize
        super.init()
        zPosition = 900
        isUserInteractionEnabled = false      // the scene routes touches to us
        buildChrome()
        refreshStatus()
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) not supported") }

    var editedRows: [String] { rows }

    // MARK: Chrome

    private func buildChrome() {
        // A dim wash, so it is unmistakable that the game is not running.
        let wash = SKSpriteNode(color: SKColor(red: 0.05, green: 0.08, blue: 0.16,
                                              alpha: 0.22),
                                size: CGSize(width: sceneSize.width * 1.2,
                                             height: sceneSize.height * 1.2))
        wash.zPosition = -1
        addChild(wash)

        // Palette along the bottom.
        paletteBar.position = CGPoint(x: 0, y: -sceneSize.height / 2 + 26)
        addChild(paletteBar)
        let spacing: CGFloat = 34
        let startX = -CGFloat(EditorOverlay.paletteGlyphs.count - 1) * spacing / 2
        for (index, glyph) in EditorOverlay.paletteGlyphs.enumerated() {
            let swatch = SKShapeNode(rectOf: CGSize(width: 30, height: 30),
                                     cornerRadius: 7)
            swatch.position = CGPoint(x: startX + CGFloat(index) * spacing, y: 0)
            swatch.fillColor = EditorOverlay.colour(for: glyph)
            swatch.strokeColor = SKColor(white: 1, alpha: glyph == brush ? 0.95 : 0.25)
            swatch.lineWidth = glyph == brush ? 3 : 1.5
            swatch.name = "editor.brush.\(glyph)"

            let label = SKLabelNode(fontNamed: "Menlo-Bold")
            label.text = glyph == "." ? "⌫" : String(glyph)
            label.fontSize = 15
            label.verticalAlignmentMode = .center
            label.fontColor = SKColor(white: 1, alpha: 0.95)
            label.name = swatch.name
            swatch.addChild(label)
            paletteBar.addChild(swatch)
            swatches[glyph] = swatch
        }

        // Buttons along the top.
        let actions: [(String, String)] = [("undo", "↶ Undo"), ("play", "▶ Play here"),
                                           ("save", "⇩ Save"), ("close", "✕ Done")]
        var x = -sceneSize.width / 2 + 62
        for (name, title) in actions {
            let button = SKShapeNode(rectOf: CGSize(width: 104, height: 30),
                                     cornerRadius: 8)
            button.position = CGPoint(x: x, y: sceneSize.height / 2 - 26)
            button.fillColor = SKColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 0.92)
            button.strokeColor = SKColor(white: 1, alpha: 0.3)
            button.name = "editor.action.\(name)"
            let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            label.text = title
            label.fontSize = 13
            label.verticalAlignmentMode = .center
            label.name = button.name
            button.addChild(label)
            addChild(button)
            x += 112
        }

        statusLabel.fontSize = 12
        statusLabel.fontColor = SKColor(white: 1, alpha: 0.8)
        statusLabel.horizontalAlignmentMode = .right
        statusLabel.position = CGPoint(x: sceneSize.width / 2 - 14,
                                       y: sceneSize.height / 2 - 32)
        addChild(statusLabel)
        addChild(gridOverlay)
    }

    /// Palette colours by category, so the bar is readable at a glance rather than
    /// twelve identical squares with letters on.
    private static func colour(for glyph: Character) -> SKColor {
        switch glyph {
        case ".": return SKColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 0.95)
        case "X", "P", "M": return SKColor(red: 0.36, green: 0.52, blue: 0.30, alpha: 1)
        case "D": return SKColor(red: 0.60, green: 0.42, blue: 0.22, alpha: 1)
        case "C": return SKColor(red: 0.95, green: 0.78, blue: 0.18, alpha: 1)
        case "E": return SKColor(red: 0.76, green: 0.28, blue: 0.34, alpha: 1)
        case "^": return SKColor(red: 0.52, green: 0.34, blue: 0.86, alpha: 1)
        case "!": return SKColor(red: 0.24, green: 0.66, blue: 0.86, alpha: 1)
        case "@": return SKColor(red: 0.22, green: 0.78, blue: 0.56, alpha: 1)
        case "L": return SKColor(red: 0.40, green: 0.66, blue: 0.34, alpha: 1)
        case "F": return SKColor(red: 0.98, green: 0.52, blue: 0.20, alpha: 1)
        default: return SKColor(white: 0.5, alpha: 1)
        }
    }

    private func refreshStatus() {
        let problems = LevelRules.validate(rows)
        let width = rows.map(\.count).max() ?? 0
        statusLabel.text = problems.isEmpty
            ? "\(width)×\(rows.count)  ✓ valid    brush \(brush)"
            : "\(width)×\(rows.count)  \(problems.count) issue(s)    brush \(brush)"
        statusLabel.fontColor = problems.isEmpty
            ? SKColor(red: 0.6, green: 0.95, blue: 0.7, alpha: 0.9)
            : SKColor(red: 1.0, green: 0.75, blue: 0.4, alpha: 0.95)
    }

    // MARK: Touch routing
    //
    // The scene forwards touches: the overlay is a camera child, so a tap has to be
    // interpreted in two spaces — chrome in camera space, painting in scene space.

    /// - Returns: true if the overlay consumed the touch.
    func handleTouch(cameraPoint: CGPoint, scenePoint: CGPoint,
                     phase: Phase) -> Bool {
        switch phase {
        case .began:
            if let hit = chromeHit(at: cameraPoint) {
                perform(hit)
                return true
            }
            painting = true
            lastPaintedCell = nil
            undoStack.append(rows)
            if undoStack.count > 40 { undoStack.removeFirst() }
            paint(at: scenePoint)
            return true
        case .moved:
            guard painting else { return false }
            paint(at: scenePoint)
            return true
        case .ended:
            painting = false
            lastPaintedCell = nil
            if !undoStack.isEmpty { onRequest?(.apply(rows: rows)) }
            return true
        }
    }

    enum Phase { case began, moved, ended }

    private func chromeHit(at point: CGPoint) -> String? {
        for node in nodes(at: point) {
            if let name = node.name, name.hasPrefix("editor.") { return name }
        }
        return nil
    }

    private func perform(_ name: String) {
        if name.hasPrefix("editor.brush.") {
            let glyph = Character(String(name.dropFirst("editor.brush.".count)))
            select(brush: glyph)
            return
        }
        switch name {
        case "editor.action.undo":
            if let previous = undoStack.popLast() {
                rows = previous
                refreshStatus()
                onRequest?(.apply(rows: rows))
            }
        case "editor.action.play":
            // Spawn where the spawn glyph currently is; the grid is the authority so a
            // "play here" that disagreed with `S` would be confusing.
            if let cell = firstCell(of: "S") {
                onRequest?(.playFrom(rows: rows, col: cell.col, row: cell.row))
            } else {
                onRequest?(.apply(rows: rows))
            }
        case "editor.action.save":
            save()
        case "editor.action.close":
            onRequest?(.close)
        default:
            break
        }
    }

    private func select(brush glyph: Character) {
        brush = glyph
        for (candidate, swatch) in swatches {
            swatch.strokeColor = SKColor(white: 1, alpha: candidate == glyph ? 0.95 : 0.25)
            swatch.lineWidth = candidate == glyph ? 3 : 1.5
        }
        refreshStatus()
    }

    // MARK: Painting

    private func cell(at scenePoint: CGPoint) -> (col: Int, row: Int)? {
        let height = CGFloat(rows.count) * tile
        let col = Int((scenePoint.x / tile).rounded(.down))
        // Row 0 is the top of the grid; the scene's origin is at the bottom.
        let row = Int(((height - scenePoint.y) / tile).rounded(.down))
        guard col >= 0, row >= 0, row < rows.count,
              col < (rows.map(\.count).max() ?? 0) else { return nil }
        return (col, row)
    }

    private func paint(at scenePoint: CGPoint) {
        guard let target = cell(at: scenePoint) else { return }
        // Dragging across one cell must not re-write it every frame; the check also
        // stops the undo stack filling with identical states.
        if let last = lastPaintedCell, last == target { return }
        lastPaintedCell = target
        var glyphs = Array(rows[target.row])
        guard target.col < glyphs.count else { return }
        // Unique markers move rather than duplicate: two spawns is invalid, and
        // silently creating one would make the level fail validation with no clue why.
        if let existing = TileSymbol.tile(brush), existing.unique,
           let previous = firstCell(of: brush), previous != target {
            var oldRow = Array(rows[previous.row])
            oldRow[previous.col] = "."
            rows[previous.row] = String(oldRow)
            glyphs = Array(rows[target.row])
        }
        glyphs[target.col] = brush
        rows[target.row] = String(glyphs)
        refreshStatus()
    }

    private func firstCell(of glyph: Character) -> (col: Int, row: Int)? {
        for (rowIndex, row) in rows.enumerated() {
            if let offset = Array(row).firstIndex(of: glyph) {
                return (offset, rowIndex)
            }
        }
        return nil
    }

    // MARK: Saving

    /// Write the edited level to `Documents/`, which is the only place a device app can
    /// write and exactly where the existing bridge already looks.
    private func save() {
        let problems = LevelRules.validate(rows)
        let document: [String: Any] = [
            "format": "level/1",
            "name": "edited",
            "order": 999,
            "title": "Edited in engine",
            "rows": rows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.prettyPrinted]),
              let directory = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        else {
            statusLabel.text = "could not serialise the level"
            return
        }
        let url = directory.appendingPathComponent("edited.json")
        do {
            try data.write(to: url)
            statusLabel.text = problems.isEmpty
                ? "saved edited.json ✓ valid"
                : "saved edited.json — \(problems.count) issue(s)"
            statusLabel.fontColor = SKColor(red: 0.6, green: 0.95, blue: 0.7, alpha: 0.95)
        } catch {
            statusLabel.text = "save failed: \(error.localizedDescription)"
        }
    }
}
