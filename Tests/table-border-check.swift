// Headless check that a drawn table's frame is one colour all the way round.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
//          MarkRead/MarkdownTableRenderer.swift \
//          Tests/table-border-check.swift -o /tmp/table-border-check \
//   && /tmp/table-border-check
//
// The fault it defends against, reported 2026-08-27 and reproduced here:
// `NSColor.set()` sets the *stroke* colour as well as the fill, and
// `NSLayoutManager.drawGlyphs` calls `set` on every run's foreground colour. A
// border colour chosen before the glyph loop and stroked after it is therefore
// gone by the time the path is stroked, and the frame comes out in whatever
// colour the last glyph in that row happened to be — blue under a row ending in
// a link, white under a row ending in plain text.
//
// 🔴 This is not something reading the code makes obvious and not something a
// screenshot settles either: the two colours only differ where the *content*
// differs, so a table whose cells all end the same way looks perfect. The
// fixture alternates on purpose. See `Tests/Fixtures/table-border.md`.
import AppKit

@main
struct TableBorderCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    /// The editor's pipeline, minus the view: block map, scanner, table pass, style.
    static func styled(_ markdown: String) -> (NSTextStorage, BlockMap) {
        let storage = NSTextStorage(string: markdown)
        let text = storage.string as NSString
        let map = BlockMap.build(text)
        let whole = 0 ..< map.lines.count
        var decorations = MarkdownScanner.decorations(text: text, map: map, lines: whole)
        decorations += MarkdownTables.decorations(text: text, map: map, lines: whole,
                                                  existing: decorations)
        MarkdownStyle.apply(decorations, to: storage,
                            resetting: NSRange(location: 0, length: storage.length))
        return (storage, map)
    }

    /// Draws one table row on its own, at its own size, and hands back the pixels.
    ///
    /// One bitmap per row rather than one for the whole table: a row is drawn
    /// into the rect its source line was given, so this is the same call the
    /// text view makes, and the left edge of the frame always lands at x = 0.
    /// Inset the drawing so the frame lands **whole** inside one pixel column.
    ///
    /// The frame is a one-point line centred on the rect's edge. At x = 0 half
    /// of it falls outside the bitmap; at x = 1 it straddles two columns and
    /// every sample comes back as a half-and-half blend with whatever is behind
    /// it — which is how the header row, with its own fill, ended up reading a
    /// different "border colour" from the body rows even when the border was
    /// right. At 1.5 the line covers the column from 1.0 to 2.0 exactly, and the
    /// pixel is the border and nothing else.
    static let inset: CGFloat = 1.5

    static func draw(_ table: TableLayout, line: Int, height: CGFloat) -> NSBitmapImageRep? {
        let width = Int(ceil(table.tableWidth + inset * 2))
        guard width > 2, height > 2,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: Int(ceil(height + inset * 2)), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        CGRect(x: 0, y: 0, width: CGFloat(width), height: height + inset * 2).fill()
        table.draw(line: line, in: CGRect(x: inset, y: inset,
                                          width: table.tableWidth, height: height))
        context.flushGraphics()
        NSGraphicsContext.current = saved
        return rep
    }

    /// The colour of the frame's left edge, sampled at the row's waist so a
    /// corner arc cannot be what gets measured.
    static func leftEdgeColour(_ rep: NSBitmapImageRep) -> NSColor? {
        rep.colorAt(x: 1, y: rep.pixelsHigh / 2)
    }

    static func describe(_ colour: NSColor?) -> String {
        guard let c = colour?.usingColorSpace(.deviceRGB) else { return "nil" }
        return String(format: "r%.3f g%.3f b%.3f", c.redComponent, c.greenComponent, c.blueComponent)
    }

    static func close(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.02) -> Bool {
        guard let a = a?.usingColorSpace(.deviceRGB), let b = b?.usingColorSpace(.deviceRGB)
        else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    static func main() {
        // Fixed appearance: the border colour is dynamic, and a check that
        // resolves it against whatever the machine is set to is not a check.
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            run()
        }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() {
        // The Xcode look on purpose: its border is an opaque colour, so a
        // sampled pixel can be compared with the palette directly. Under the
        // other looks the border is `separatorColor` — white at low alpha — and
        // the sample would be a blend with whatever is behind it, which tests
        // the background as much as the border.
        UserDefaults.standard.set(MarkdownStyle.Look.xcode.rawValue,
                                  forKey: MarkdownStyle.Appearance.lookKey)
        MarkdownStyle.Appearance.reload()
        defer {
            UserDefaults.standard.removeObject(forKey: MarkdownStyle.Appearance.lookKey)
            MarkdownStyle.Appearance.reload()
        }

        let path = "Tests/Fixtures/table-border.md"
        guard let markdown = try? String(contentsOfFile: path, encoding: .utf8) else {
            check("the fixture is readable", false, path)
            return
        }

        let (storage, map) = styled(markdown)
        // The table is the run of rows at the end of the fixture.
        let rows = (0 ..< map.lines.count).filter {
            MarkdownTables.cellRanges(storage.string as NSString, map.lines[$0].range).count > 1
        }
        // Seven source lines: the header, the `|---|` delimiter, and five body
        // rows. The delimiter is drawn as the rule under the header, not as a row.
        check("the fixture holds one table of seven source lines",
              rows.count == 7 && rows.last! - rows.first! == 6, "\(rows)")
        guard rows.count == 7 else { return }

        guard let table = TableLayout(storage: storage, map: map,
                                      lines: rows.first! ... rows.last!,
                                      hidden: [:], width: 900) else {
            check("the table lays out", false)
            return
        }

        // 🔴 The invariant the drawing now rests on: every line the table owns
        // — the delimiter included — hands back a height. `Coordinator.rowRects`
        // stacks the table from one anchor using exactly these numbers, so a nil
        // here would silently shorten the stack and slide every row below it up.
        // The view-layer fault this replaced is verified by rendering, not here:
        // it was a line *fragment* disagreeing with the height that was reserved,
        // and there is no fragment without a text view.
        for line in table.lines {
            check("line \(line) has a height to be stacked with",
                  table.height(forLine: line) != nil)
        }
        check("the delimiter's height is the thin rule, not a row",
              table.delimiterLine.flatMap { table.height(forLine: $0) } == 1)

        // Every body row's left edge, sampled.
        var edges: [(line: Int, colour: NSColor?)] = []
        for line in rows where line != table.delimiterLine {
            guard let height = table.height(forLine: line),
                  let rep = draw(table, line: line, height: height) else { continue }
            edges.append((line, leftEdgeColour(rep)))
        }
        check("every row was drawn", edges.count == 6, "\(edges.count)")

        // 🔴 The check itself. Rows two and four end in plain text, rows one,
        // three and five end in a link — under the fault these came out in two
        // different colours.
        let first = edges.first?.colour
        for edge in edges.dropFirst() {
            check("row \(edge.line) has the same border colour as the first",
                  close(first, edge.colour),
                  "\(describe(edge.colour)) vs \(describe(first))")
        }

        // ...and it is the colour the look asked for, not merely a consistent
        // accident.
        check("the border is the colour the palette names",
              close(first, MarkdownStyle.Palette.border.usingColorSpace(.deviceRGB)),
              "\(describe(first)) vs \(describe(MarkdownStyle.Palette.border))")

        // Positive control. Without this, all of the above would pass just as
        // happily if every sample were reading the same empty background: the
        // link in the last cell has to be a genuinely different colour from the
        // border, or there was never anything for the border to be repainted in.
        // rows[0] is the header and rows[1] the delimiter, so the first body
        // row — the one ending in a bare link — is rows[2].
        guard let height = table.height(forLine: rows[2]),
              let rep = draw(table, line: rows[2], height: height) else {
            check("the control row was drawn", false)
            return
        }
        // The bluest pixel in the row, wherever it is: the link is the only
        // strongly blue thing there, and hunting for the extreme rather than for
        // the first match keeps antialiasing from deciding the answer.
        var linkPixel: NSColor?
        var bluest: CGFloat = 0
        for y in stride(from: 2, to: rep.pixelsHigh - 2, by: 2) {
            for x in stride(from: 2, to: rep.pixelsWide - 2, by: 1) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let blueness = pixel.blueComponent - pixel.redComponent
                if blueness > bluest { bluest = blueness; linkPixel = pixel }
            }
        }
        check("the control: the bluest pixel is properly blue", bluest > 0.2, "\(bluest)")
        check("the control: the last cell really does hold a blue link",
              linkPixel != nil, "no blue pixel found")
        check("the control: that blue is not the border colour",
              linkPixel != nil && !close(linkPixel, first),
              "\(describe(linkPixel)) vs \(describe(first))")
    }
}
