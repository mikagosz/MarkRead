import Foundation

/// Column alignment for markdown tables.
///
/// A table is the one construct whose appearance cannot be decided from a single
/// line — a cell's width depends on every other row. So this runs as a second
/// pass over lines the scanner has already looked at, and reports only extra
/// decorations.
///
/// It inserts nothing. Columns are padded with a kerning attribute measured in
/// character widths, and the `|---|---|` row is marked hidden rather than
/// removed. The file never learns that any of this happened.
nonisolated enum MarkdownTables {

    /// Extra decorations aligning any tables among `lines`.
    ///
    /// - Parameter existing: what the scanner already produced for the same
    ///   lines. Needed because a cell holding a link is *visually* shorter than
    ///   its characters — the `](url)` half is not drawn — and padding computed
    ///   on raw length would be wrong by exactly the length of the URL.
    static func decorations(text: NSString, map: BlockMap, lines: Range<Int>,
                            existing: [Decoration]) -> [Decoration] {
        var hidden: [Int: [NSRange]] = [:]
        for decoration in existing where decoration.style == .hiddenMarker {
            hidden[map.lineIndex(containing: decoration.range.location), default: []]
                .append(decoration.range)
        }

        var out: [Decoration] = []
        var index = lines.lowerBound
        while index < lines.upperBound {
            guard index < map.lines.count, isTableRow(text, map.lines[index]) else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < min(lines.upperBound, map.lines.count),
                  isTableRow(text, map.lines[last + 1]) {
                last += 1
            }
            align(rows: index ... last, text: text, map: map, hidden: hidden, into: &out)
            index = last + 1
        }
        return out
    }

    // MARK: - Detection

    private static func isTableRow(_ text: NSString, _ line: (range: NSRange, kind: BlockMap.Kind)) -> Bool {
        guard line.kind == .normal else { return false }
        return text.substring(with: line.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("|")
    }

    /// `| --- | :--: |` — the row that only says where the header ends.
    private static func isDelimiter(_ cells: [NSRange], _ text: NSString) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = text.substring(with: cell).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return false }
            return body.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    // MARK: - One table

    private static func align(rows: ClosedRange<Int>, text: NSString, map: BlockMap,
                              hidden: [Int: [NSRange]], into out: inout [Decoration]) {
        // Parse every row into pipe positions and cell ranges.
        var parsed: [(line: Int, pipes: [Int], cells: [NSRange])] = []
        for line in rows {
            let range = map.lines[line].range
            let (pipes, cells) = split(text, range)
            guard !cells.isEmpty else { continue }
            parsed.append((line, pipes, cells))
        }
        guard parsed.count >= 2 else { return }

        // NOT aligned by padding, and that is a measured decision.
        //
        // Padding cells out to equal widths with a kerning attribute works, and
        // on a narrow table it looks right. On a wide one it is actively worse
        // than doing nothing: a seven-column table of job offers does not fit the
        // window, so every padded row wraps onto three display lines and the
        // columns land in different places on each of them. Alignment without
        // per-cell wrapping cannot hold, and per-cell wrapping means a real table
        // layout, not a text attribute.
        //
        // What is left here is the part that helps unconditionally: the pipes
        // recede, and the `|---|---|` row stops being drawn.
        for row in parsed {
            if isDelimiter(row.cells, text) {
                // Nothing in this row is information. Hide it whole; what is left
                // is a thin gap under the header, which is what it meant anyway.
                out.append(Decoration(range: map.lines[row.line].range.trimmedNewlines(in: text),
                                      style: .hiddenMarker))
                continue
            }
            for pipe in row.pipes {
                out.append(Decoration(range: NSRange(location: pipe, length: 1), style: .marker))
            }
        }
    }

    /// Positions of the unescaped `|` in a line, and the ranges between them.
    private static func split(_ text: NSString, _ line: NSRange) -> ([Int], [NSRange]) {
        var pipes: [Int] = []
        var index = line.location
        let end = NSMaxRange(line)
        while index < end {
            let char = text.character(at: index)
            if char == 0x7C {                                   // |
                let escaped = index > line.location && text.character(at: index - 1) == 0x5C  // backslash
                if !escaped { pipes.append(index) }
            }
            index += 1
        }
        guard pipes.count >= 2 else { return (pipes, []) }

        var cells: [NSRange] = []
        for i in 0 ..< (pipes.count - 1) {
            let start = pipes[i] + 1
            let length = pipes[i + 1] - start
            cells.append(NSRange(location: start, length: max(0, length)))
        }
        return (pipes, cells)
    }

    /// Characters in `cell` that are actually drawn.
    private static func visibleLength(_ cell: NSRange, hiddenIn hidden: [NSRange]) -> Int {
        var length = cell.length
        for range in hidden {
            length -= NSIntersectionRange(cell, range).length
        }
        return max(0, length)
    }
}

nonisolated private extension NSRange {
    /// The range without its trailing line terminator.
    func trimmedNewlines(in text: NSString) -> NSRange {
        var result = self
        while result.length > 0 {
            let last = text.character(at: NSMaxRange(result) - 1)
            guard last == 10 || last == 13 else { break }
            result.length -= 1
        }
        return result
    }
}
