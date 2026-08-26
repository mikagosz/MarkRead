import AppKit

/// A markdown table, laid out and drawn as a real table.
///
/// How this stays compatible with "the text is the file": the table's characters
/// are still in the buffer, their glyphs are suppressed, and each source line is
/// given the height its rendered row needs via a paragraph style. The renderer
/// then draws into the space those empty lines reserve. One source line, one
/// table row — so a row always lands exactly where its line is.
///
/// Nothing here writes to the document. It reads the already-styled attributed
/// text out of the storage and keeps its own copies.
@MainActor
final class TableLayout {

    struct Cell {
        /// Own TextKit stack: used to measure, to draw, and to hit-test links.
        /// One stack per cell is more than a text attribute needs, and exactly
        /// what per-cell wrapping requires.
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        var frame: CGRect = .zero
    }

    struct Row {
        var cells: [Cell]
        var height: CGFloat = 0
        var isHeader = false
        /// Index of this row's source line in the document.
        var line: Int
    }

    /// Source lines this table occupies, delimiter row included.
    let lines: ClosedRange<Int>
    /// The line holding `| --- | --- |`, drawn as the header rule.
    let delimiterLine: Int?
    private(set) var rows: [Row] = []
    private(set) var columnWidths: [CGFloat] = []
    let width: CGFloat

    static let cellPaddingX: CGFloat = 10
    static let cellPaddingY: CGFloat = 6
    static let minimumColumnWidth: CGFloat = 54

    // MARK: - Building

    /// - Parameters:
    ///   - storage: the document, already styled — cells inherit link colour,
    ///     bold, code background and so on for free.
    ///   - hidden: ranges whose glyphs are suppressed, removed from the cell copy
    ///     so a `](https://…)` does not take part in the column width.
    init?(storage: NSTextStorage, map: BlockMap, lines: ClosedRange<Int>,
          hidden: [Int: [NSRange]], width: CGFloat) {
        guard width > Self.minimumColumnWidth, lines.upperBound < map.lines.count else { return nil }
        self.lines = lines
        self.width = width

        let text = storage.string as NSString
        var delimiter: Int?
        var parsed: [(line: Int, cells: [NSRange])] = []
        for line in lines {
            let cells = MarkdownTables.cellRanges(text, map.lines[line].range)
            guard !cells.isEmpty else { continue }
            if MarkdownTables.isDelimiter(cells, text) { delimiter = line; continue }
            parsed.append((line, cells))
        }
        self.delimiterLine = delimiter
        guard parsed.count >= 1 else { return nil }

        // Cell text: the styled substring with hidden runs taken out. Removal
        // happens on a copy — the document keeps every character.
        var built: [Row] = []
        for (index, row) in parsed.enumerated() {
            var cells: [Cell] = []
            for range in row.cells {
                let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
                for hiddenRange in (hidden[row.line] ?? []).sorted(by: { $0.location > $1.location }) {
                    let overlap = NSIntersectionRange(hiddenRange, range)
                    guard overlap.length > 0 else { continue }
                    piece.deleteCharacters(in: NSRange(location: overlap.location - range.location,
                                                       length: overlap.length))
                }
                Self.trim(piece)
                Self.useProportionalFont(piece)
                cells.append(Self.makeCell(piece))
            }
            built.append(Row(cells: cells, isHeader: index == 0 && delimiter != nil, line: row.line))
        }
        self.rows = built
        measure()
    }

    private static func makeCell(_ text: NSAttributedString) -> Cell {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return Cell(storage: storage, layout: layout, container: container)
    }

    /// Swaps the row's monospaced face for the body face, except on real code.
    ///
    /// Table rows are monospaced in the raw markdown view so that hand-aligned
    /// columns line up. Inside a rendered cell that font only costs width, and a
    /// narrow column plus a wide font breaks words in the middle
    /// ("doświadczeni/em"). A run that is actually code keeps its face — that is
    /// what `.markReadCode` is for.
    private static func useProportionalFont(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard text.attribute(.markReadCode, at: range.location, effectiveRange: nil) == nil,
                  let font = value as? NSFont else { return }
            // Only bold and italic carry over. Copying the whole trait set drags
            // `.monoSpace` along with it, and the system font obligingly resolves
            // back to a monospaced face — the swap then does nothing at all,
            // which is exactly what it did the first time round.
            let traits = font.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
            let descriptor = MarkdownStyle.bodyFont(ofSize: MarkdownStyle.bodySize - 1).fontDescriptor
                .withSymbolicTraits(traits)
            if let swapped = NSFont(descriptor: descriptor, size: MarkdownStyle.bodySize - 1) {
                text.addAttribute(.font, value: swapped, range: range)
            }
        }
        // Cells wrap inside their own column, and must not inherit the tall line
        // height the table's source lines were given to reserve vertical space.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5
        text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
    }

    /// Drops the spaces a table author put around a cell's text.
    ///
    /// Counted first and deleted once. Asking `text.string` from inside the loop
    /// built the whole cell again for every single space it took off.
    private static func trim(_ text: NSMutableAttributedString) {
        let string = text.string as NSString
        let space: unichar = 32
        var start = 0
        var end = string.length
        while start < end, string.character(at: start) == space { start += 1 }
        while end > start, string.character(at: end - 1) == space { end -= 1 }
        if end < string.length { text.deleteCharacters(in: NSRange(location: end, length: string.length - end)) }
        if start > 0 { text.deleteCharacters(in: NSRange(location: 0, length: start)) }
    }

    // MARK: - Measuring

    private func measure() {
        let columns = rows.map(\.cells.count).max() ?? 0
        guard columns > 0 else { return }

        // Natural width: what each column would take without wrapping.
        var natural = [CGFloat](repeating: Self.minimumColumnWidth, count: columns)
        for row in rows {
            for (index, cell) in row.cells.enumerated() where index < columns {
                let size = cell.storage.size()
                natural[index] = max(natural[index], ceil(size.width) + Self.cellPaddingX * 2)
            }
        }

        let total = natural.reduce(0, +)
        if total <= width {
            // Everything fits: give the slack to the widest column so the table
            // fills the line instead of ending in the middle of it.
            columnWidths = natural
            if let widest = natural.indices.max(by: { natural[$0] < natural[$1] }) {
                columnWidths[widest] += width - total
            }
        } else {
            // Water filling, not proportional shrinking.
            //
            // Shrinking every column by the same ratio takes the same share from
            // "Data" as from "Stanowisko", and a date column that cannot hold
            // "25.08.2026" wraps every single row for nothing. Here a column
            // narrower than its fair share keeps its natural width, and only the
            // columns above the share are capped — measured on the job-offer
            // table, this is the difference between two wrapped rows and seven.
            columnWidths = natural
            var settled = [Bool](repeating: false, count: natural.count)
            var remaining = width
            while true {
                let open = settled.indices.filter { !settled[$0] }
                guard !open.isEmpty else { break }
                let share = remaining / CGFloat(open.count)
                let fitting = open.filter { natural[$0] <= share }
                if fitting.isEmpty {
                    for index in open { columnWidths[index] = max(Self.minimumColumnWidth, share) }
                    break
                }
                for index in fitting {
                    columnWidths[index] = natural[index]
                    settled[index] = true
                    remaining -= natural[index]
                }
            }
        }

        // Row heights come from the tallest wrapped cell.
        for rowIndex in rows.indices {
            var height = Self.cellPaddingY * 2
            for (index, _) in rows[rowIndex].cells.enumerated() where index < columnWidths.count {
                let inner = max(1, columnWidths[index] - Self.cellPaddingX * 2)
                rows[rowIndex].cells[index].container.size = CGSize(width: inner,
                                                                    height: CGFloat.greatestFiniteMagnitude)
                let cell = rows[rowIndex].cells[index]
                cell.layout.ensureLayout(for: cell.container)
                let used = cell.layout.usedRect(for: cell.container)
                height = max(height, ceil(used.height) + Self.cellPaddingY * 2)
            }
            rows[rowIndex].height = height

            var x: CGFloat = 0
            for index in rows[rowIndex].cells.indices where index < columnWidths.count {
                rows[rowIndex].cells[index].frame = CGRect(x: x, y: 0,
                                                           width: columnWidths[index],
                                                           height: height)
                x += columnWidths[index]
            }
        }
    }

    /// Height this table's row on `line` needs, or nil when the line is the
    /// delimiter (which becomes the header rule and needs almost nothing).
    func height(forLine line: Int) -> CGFloat? {
        if line == delimiterLine { return 1 }
        return rows.first { $0.line == line }?.height
    }

    // MARK: - Drawing

    /// Draws one row into the rect its source line was given.
    func draw(line: Int, in rect: CGRect) {
        guard let row = rows.first(where: { $0.line == line }) else {
            // The delimiter line: a single rule under the header.
            if line == delimiterLine {
                NSColor.separatorColor.setFill()
                CGRect(x: rect.minX, y: rect.minY, width: tableWidth, height: 1).fill()
            }
            return
        }

        if row.isHeader {
            NSColor.quaternarySystemFill.setFill()
            CGRect(x: rect.minX, y: rect.minY, width: tableWidth, height: row.height).fill()
        }

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.lineWidth = 1

        for (index, cell) in row.cells.enumerated() where index < columnWidths.count {
            let frame = cell.frame.offsetBy(dx: rect.minX, dy: rect.minY)
            let glyphs = cell.layout.glyphRange(for: cell.container)
            cell.layout.drawGlyphs(forGlyphRange: glyphs,
                                   at: CGPoint(x: frame.minX + Self.cellPaddingX,
                                               y: frame.minY + Self.cellPaddingY))
            if index > 0 {
                border.move(to: CGPoint(x: frame.minX, y: frame.minY))
                border.line(to: CGPoint(x: frame.minX, y: frame.maxY))
            }
        }

        // Row rule, except under the header where the delimiter line draws it.
        if !row.isHeader {
            border.move(to: CGPoint(x: rect.minX, y: rect.minY))
            border.line(to: CGPoint(x: rect.minX + tableWidth, y: rect.minY))
        }
        border.stroke()
    }

    var tableWidth: CGFloat { columnWidths.reduce(0, +) }

    // MARK: - Hit testing

    /// The link under `point`, where `point` is relative to the row's rect.
    func link(inLine line: Int, at point: CGPoint) -> URL? {
        guard let row = rows.first(where: { $0.line == line }) else { return nil }
        for cell in row.cells where cell.frame.contains(point) {
            let local = CGPoint(x: point.x - cell.frame.minX - Self.cellPaddingX,
                                y: point.y - cell.frame.minY - Self.cellPaddingY)
            var fraction: CGFloat = 0
            let glyph = cell.layout.glyphIndex(for: local, in: cell.container,
                                               fractionOfDistanceThroughGlyph: &fraction)
            guard glyph < cell.layout.numberOfGlyphs else { return nil }
            let box = cell.layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                               in: cell.container)
            guard box.contains(local) else { return nil }
            let index = cell.layout.characterIndexForGlyph(at: glyph)
            guard index < cell.storage.length else { return nil }
            return cell.storage.attribute(.link, at: index, effectiveRange: nil) as? URL
        }
        return nil
    }

    // Cell ranges and the `|---|` row are recognised by `MarkdownTables`, which
    // is the single place that knows how a table row is written. This file used
    // to carry its own copy of both.
}
