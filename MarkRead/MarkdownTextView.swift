import AppKit
import SwiftUI

/// Imperative handle on the live text view, so menu commands can act on the
/// selection without SwiftUI having to own the text.
@Observable
final class EditorHandle {
    weak var textView: NSTextView?
    /// What the editor currently believes about itself, for the debug bridge.
    /// Rendering decisions are invisible from outside; this makes them answerable
    /// instead of guessable.
    @ObservationIgnored var diagnostics: (() -> [String: Any])?
}

/// NSTextView that follows links on a plain click.
///
/// AppKit only follows links by itself in a *non*-editable text view; in an
/// editable one a click just moves the caret. Since MarkRead is an editor whose
/// whole point is working links, the hit test is done here explicitly.
/// Option-click still places the caret, which is how you edit link text.
final class LiveMarkdownTextView: NSTextView {

    var onLinkClick: ((URL) -> Void)?
    /// Draws rendered tables over the space their hidden source lines reserve.
    var drawTables: ((NSRect) -> Void)?
    /// Links inside a rendered table: its glyphs are suppressed, so the normal
    /// hit test has nothing to find there.
    var tableLink: ((NSPoint) -> URL?)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTables?(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.option),
           let url = tableLink?(convert(event.locationInWindow, from: nil)) {
            onLinkClick?(url)
            return
        }
        guard !event.modifierFlags.contains(.option), let url = link(at: event) else {
            super.mouseDown(with: event)
            return
        }
        onLinkClick?(url)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tableLink?(point) != nil || link(at: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func link(at event: NSEvent) -> URL? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let point = NSPoint(x: local.x - origin.x, y: local.y - origin.y)

        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        // glyphIndex(for:) clamps to the nearest glyph, so a click in the empty
        // space past the end of a line would "hit" the last character. Reject
        // anything outside the glyph's own box.
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                             in: textContainer)
        guard box.contains(point) else { return nil }

        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length else { return nil }
        return textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }
}

/// SwiftUI wrapper around the editor.
struct MarkdownEditor: NSViewRepresentable {

    @Binding var text: String
    let handle: EditorHandle
    let onLinkClick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, built explicitly. The highlighter needs an NSLayoutManager
        // for hit testing and visible-range maths, and reaching for
        // `.layoutManager` on a TextKit 2 view downgrades it silently — better to
        // ask for the stack we actually use.
        // SHORTCUT: TextKit 1 tops out on very large documents. Notes are far
        // below that; the way out is a TextKit 2 viewport-based highlighter.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = LiveMarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.onLinkClick = onLinkClick
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Without these the view cannot grow past the frame it was created with,
        // which for a programmatically built NSTextView is the zero rect — the
        // document stays one screen tall and nothing scrolls. `maxSize` defaults
        // to the initial frame size, not to infinity.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.typingAttributes = MarkdownStyle.baseAttributes
        textView.backgroundColor = .textBackgroundColor

        // Every one of these rewrites the user's characters behind their back.
        // In a markdown editor that is data loss: "--" becomes an em dash, plain
        // quotes become curly ones, and the file no longer says what it said.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        layout.delegate = context.coordinator
        textView.drawTables = { [weak coordinator = context.coordinator] rect in
            coordinator?.drawTables(in: rect)
        }
        textView.tableLink = { [weak coordinator = context.coordinator] point in
            coordinator?.tableLink(at: point)
        }
        handle.textView = textView

        textView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            // Table column widths depend on how wide the editor is, so a resize
            // has to rebuild them. Without this the first layout — the one that
            // finally gives the view a width — never produces a table.
            MainActor.assumeIsolated { coordinator?.highlightVisible() }
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.highlightVisible() }
        }

        context.coordinator.replaceText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onLinkClick = onLinkClick
        handle.textView = textView
        // Only when the document was swapped underneath us — echoing the user's
        // own keystrokes back into the storage would reset the caret on every
        // character typed.
        if textView.string != text {
            context.coordinator.replaceText(text)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        for observer in [coordinator.scrollObserver, coordinator.frameObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        private let parent: MarkdownEditor
        weak var textView: LiveMarkdownTextView?
        weak var scrollView: NSScrollView?
        var scrollObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?

        private var map = BlockMap(lines: [], openFrontMatter: false)
        /// The document as an NSString, kept so glyph generation does not bridge
        /// the whole string on every call.
        private var nsText: NSString = ""
        /// Hidden ranges per line, filled lazily. Glyph generation can ask about a
        /// line before it has been styled, so a miss computes that one line rather
        /// than leaving its markers on screen for a frame.
        private var hiddenByLine: [Int: [NSRange]] = [:]
        /// The line the caret sits on, drawn with its syntax visible so it can be
        /// edited. Nil when the editor does not have focus — then nothing is
        /// revealed and the document reads as a finished page.
        private var revealedLine: NSRange?
        /// Rendered tables, one entry per source line they cover. A table whose
        /// caret is inside is absent here and shows as plain markdown, which is
        /// how you edit it.
        private var tablesByLine: [Int: TableLayout] = [:]
        /// Lines already styled since the last text change. Scrolling re-runs the
        /// highlighter constantly; without this it restyled the same 120 lines and
        /// rebuilt every table — one TextKit stack per cell — on every tick of the
        /// scroll bar, which is what made scrolling a long note stutter.
        private var styledRange: ClosedRange<Int>?
        /// Laid-out tables kept by their first line, so scrolling back to one does
        /// not build it again. Dropped when the text or the width changes.
        private var tableCache: [Int: TableLayout] = [:]
        private var tableCacheWidth: CGFloat = 0
        /// Editor width the styled lines were laid out at. Column widths depend on
        /// it, so a change has to throw the record away — see `highlightVisible`.
        private var styledWidth: CGFloat = 0
        /// Counters for the debug bridge: how much work scrolling actually costs.
        private var styleRuns = 0
        private var styledLineCount = 0
        private var styleMillis = 0.0
        private var tablesBuilt = 0

        init(_ parent: MarkdownEditor) {
            self.parent = parent
            super.init()
            parent.handle.diagnostics = { [weak self] in self?.report() ?? [:] }
        }

        private func report() -> [String: Any] {
            [
                "lines": map.lines.count,
                "containerWidth": textView?.textContainer?.size.width ?? 0,
                "viewWidth": textView?.bounds.width ?? 0,
                "hiddenLinesCached": hiddenByLine.count,
                "tableLines": tablesByLine.count,
                "tables": Set(tablesByLine.values.map { $0.lines.lowerBound }).count,
                "revealedLine": revealedLine.map { "\($0.location)..\($0.length)" } ?? "none",
                "rows": {
                    let rects = lineRects()
                    return tablesByLine.keys.sorted().prefix(12).map { line -> [String: Any] in
                        [
                            "line": line,
                            "wantedHeight": tablesByLine[line]?.height(forLine: line) ?? -1,
                            "rectY": rects[line]?.minY ?? -1,
                            "rectH": rects[line]?.height ?? -1,
                        ]
                    }
                }(),
                "columns": tablesByLine.values.first?.columnWidths.map { Int($0) } ?? [],
                "styleRuns": styleRuns,
                "styledLineCount": styledLineCount,
                "styleMillis": (styleMillis * 10).rounded() / 10,
                "tablesBuilt": tablesBuilt,
                "frameHeight": textView?.frame.height ?? -1,
                "laidOutHeight": {
                    guard let textView, let layoutManager = textView.layoutManager,
                          let container = textView.textContainer else { return CGFloat(-1) }
                    layoutManager.ensureLayout(for: container)
                    return layoutManager.usedRect(for: container).height
                }(),
                "visibleHeight": scrollView?.contentView.bounds.height ?? -1,
            ]
        }

        /// Loads a different document into the view and highlights what shows.
        func replaceText(_ new: String) {
            guard let textView, let storage = textView.textStorage else { return }
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: new)
            storage.endEditing()
            textView.undoManager?.removeAllActions()
            rebuildMap()
            textView.scroll(.zero)
            highlightVisible()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            rebuildMap()
            highlightVisible()
            // Otherwise the caret keeps whatever the character to its left had —
            // keep typing after a link and the new text joins the link.
            textView.typingAttributes = MarkdownStyle.baseAttributes
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateRevealedLine()
        }

        private func rebuildMap() {
            guard let textView, let storage = textView.textStorage else { return }
            nsText = storage.string as NSString
            map = BlockMap.build(nsText)
            hiddenByLine.removeAll(keepingCapacity: true)
            tablesByLine.removeAll(keepingCapacity: true)
            tableCache.removeAll(keepingCapacity: true)
            styledRange = nil
            revealedLine = nil
            updateRevealedLine()
        }

        // MARK: - Revealing the caret's line

        private func updateRevealedLine() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let focused = textView.window?.firstResponder === textView
            let caret = min(textView.selectedRange().location, nsText.length)
            let wanted: NSRange? = focused && nsText.length > 0
                ? nsText.lineRange(for: NSRange(location: caret, length: 0))
                : nil
            guard wanted != revealedLine else { return }

            let previous = revealedLine
            revealedLine = wanted
            // Both lines change appearance: the old one hides its syntax again,
            // the new one shows it.
            for range in [previous, wanted].compactMap({ $0 }) {
                let safe = NSIntersectionRange(range, NSRange(location: 0, length: nsText.length))
                guard safe.length > 0 else { continue }
                layoutManager.invalidateGlyphs(forCharacterRange: safe, changeInLength: 0,
                                               actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
            }

            // A table is drawn or shown as markdown depending on where the caret
            // is, and that decision is made in `buildTables` — which only runs
            // from `highlightVisible`. Without this, clicking inside a table
            // revealed one line of raw markdown *underneath* the drawn table
            // while every other line kept its row height: the table appeared to
            // fall apart. Restyling the visible window costs a few milliseconds.
            if tableTouched(previous) || tableTouched(wanted) {
                // Styling is incremental now, so asking for a re-highlight is not
                // enough on its own — these lines count as already done. Drop the
                // record so the visible window is genuinely restyled.
                styledRange = nil
                highlightVisible()
            }
        }

        /// True when the range falls inside a block that is (or was) a table.
        private func tableTouched(_ range: NSRange?) -> Bool {
            guard let range else { return false }
            let line = map.lineIndex(containing: range.location)
            return tablesByLine[line] != nil || isTableRow(line)
        }

        // MARK: - Glyph suppression

        /// Suppresses the glyphs of hidden markers.
        ///
        /// This is the one mechanism that lets the buffer stay byte-identical to
        /// the file while still reading like a rendered document: the characters
        /// are all there, they are simply not drawn. Returning 0 means "use the
        /// default glyphs", so untouched runs cost nothing.
        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>,
                           font: NSFont,
                           forGlyphRange glyphRange: NSRange) -> Int {
            guard !map.lines.isEmpty else { return 0 }

            var adjusted = [NSLayoutManager.GlyphProperty]()
            adjusted.reserveCapacity(glyphRange.length)
            var changed = false
            for offset in 0 ..< glyphRange.length {
                if isHidden(characterIndexes[offset]) {
                    adjusted.append(.null)
                    changed = true
                } else {
                    adjusted.append(properties[offset])
                }
            }
            guard changed else { return 0 }

            layoutManager.setGlyphs(glyphs, properties: adjusted,
                                    characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
            return glyphRange.length
        }

        private func isHidden(_ index: Int) -> Bool {
            if let revealedLine, NSLocationInRange(index, revealedLine) { return false }
            for range in hiddenRanges(forLine: map.lineIndex(containing: index))
            where NSLocationInRange(index, range) {
                return true
            }
            return false
        }

        private func hiddenRanges(forLine line: Int) -> [NSRange] {
            if let cached = hiddenByLine[line] { return cached }
            guard line < map.lines.count else { return [] }
            let ranges = MarkdownScanner
                .decorations(text: nsText, map: map, lines: line ..< line + 1)
                .compactMap { $0.style == .hiddenMarker ? $0.range : nil }
            hiddenByLine[line] = ranges
            return ranges
        }

        // MARK: - Highlighting

        /// Restyles the lines on screen (plus a margin), and nothing else.
        ///
        /// Highlighting the whole document on every keystroke is what makes
        /// editors like this feel slow. Off-screen text is styled when it
        /// scrolls into view, which is the only moment it can be looked at.
        func highlightVisible() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  !map.lines.isEmpty else { return }

            let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            let margin = 60
            let firstLine = max(0, map.lineIndex(containing: charRange.location) - margin)
            let lastLine = min(map.lines.count - 1,
                               map.lineIndex(containing: max(0, NSMaxRange(charRange) - 1)) + margin)
            guard firstLine <= lastLine else { return }

            // Tables are laid out for a particular editor width, and the first
            // highlight runs before the view has one — at zero width every table
            // is skipped. Without this the lines were then marked "styled" and
            // never revisited, so the tables simply never appeared once the real
            // width arrived. Any width change starts the record over.
            let available = editorWidth()
            if available != styledWidth {
                styledWidth = available
                styledRange = nil
                tableCache.removeAll(keepingCapacity: true)
                tablesByLine.removeAll(keepingCapacity: true)
            }

            // Style only what has not been styled yet. Attributes stay on the
            // storage once written, so scrolling back over old lines costs
            // nothing and scrolling forward costs only the new lines.
            var pending: [(Int, Int)] = []
            if let styled = styledRange {
                if firstLine < styled.lowerBound { pending.append((firstLine, styled.lowerBound - 1)) }
                if lastLine > styled.upperBound { pending.append((styled.upperBound + 1, lastLine)) }
                styledRange = min(firstLine, styled.lowerBound) ... max(lastLine, styled.upperBound)
            } else {
                pending.append((firstLine, lastLine))
                styledRange = firstLine ... lastLine
            }
            for (from, to) in pending { style(from: from, to: to) }
        }

        /// Everything the styling of one span of lines needs, done once.
        private func style(from firstLine: Int, to lastLine: Int) {
            let started = Date()
            defer {
                styleRuns += 1
                styledLineCount += max(0, lastLine - firstLine + 1)
                styleMillis += Date().timeIntervalSince(started) * 1000
            }
            guard let textView,
                  let storage = textView.textStorage,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  firstLine <= lastLine, lastLine < map.lines.count else { return }

            let start = map.lines[firstLine].range.location
            let end = NSMaxRange(map.lines[lastLine].range)
            let reset = NSRange(location: start, length: min(end, storage.length) - start)
            guard reset.length > 0 else { return }

            var decorations = MarkdownScanner.decorations(
                text: nsText,
                map: map,
                lines: firstLine ..< (lastLine + 1)
            )
            // Second pass: tables need to see their neighbouring rows, which a
            // per-line scanner cannot. It only adds decorations.
            decorations += MarkdownTables.decorations(
                text: nsText,
                map: map,
                lines: firstLine ..< (lastLine + 1),
                existing: decorations
            )
            MarkdownStyle.apply(decorations, to: storage, resetting: reset)

            // Refresh the hidden-marker cache for exactly the lines just styled,
            // then let the layout manager regenerate their glyphs.
            for line in firstLine ... lastLine { hiddenByLine[line] = [] }
            for decoration in decorations where decoration.style == .hiddenMarker {
                let line = map.lineIndex(containing: decoration.range.location)
                hiddenByLine[line, default: []].append(decoration.range)
            }

            buildTables(from: firstLine, to: lastLine, storage: storage, container: container)

            layoutManager.invalidateGlyphs(forCharacterRange: reset, changeInLength: 0,
                                           actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: reset, actualCharacterRange: nil)
        }

        // MARK: - Tables

        /// Lays out every table among the styled lines and reserves the vertical
        /// space it needs.
        ///
        /// The space comes from the source lines themselves: each one is given a
        /// paragraph style whose line height is the height of the row it holds,
        /// and all of its glyphs are hidden. One source line, one table row — so
        /// `drawTables` can put a row exactly where its line ended up, without
        /// tracking any geometry of its own.
        private func buildTables(from firstLine: Int, to lastLine: Int,
                                 storage: NSTextStorage, container: NSTextContainer) {
            let available = editorWidth()
            guard available > TableLayout.minimumColumnWidth else { return }

            var line = firstLine
            while line <= lastLine {
                guard isTableRow(line) else {
                    line += 1
                    continue
                }
                var last = line
                while last + 1 <= lastLine, isTableRow(last + 1) { last += 1 }
                defer { line = last + 1 }

                let block = line ... last
                // Caret inside: leave the markdown alone so it can be edited.
                if let revealedLine, block.contains(map.lineIndex(containing: revealedLine.location)) {
                    for row in block { tablesByLine[row] = nil }
                    continue
                }
                if tableCacheWidth != available {
                    tableCache.removeAll(keepingCapacity: true)
                    tableCacheWidth = available
                }
                let table: TableLayout
                if let cached = tableCache[block.lowerBound], cached.lines == block {
                    table = cached
                } else if let built = TableLayout(storage: storage, map: map, lines: block,
                                                  hidden: hiddenByLine, width: available) {
                    tableCache[block.lowerBound] = built
                    tablesBuilt += 1
                    table = built
                } else {
                    continue
                }

                for row in block {
                    tablesByLine[row] = table
                    let range = map.lines[row].range
                    guard NSMaxRange(range) <= storage.length else { continue }

                    let paragraph = NSMutableParagraphStyle()
                    let height = table.height(forLine: row) ?? 1
                    paragraph.minimumLineHeight = height
                    paragraph.maximumLineHeight = height
                    paragraph.lineSpacing = 0
                    paragraph.paragraphSpacing = 0
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: range)

                    // The whole line is drawn by the renderer, so none of its own
                    // glyphs may appear.
                    hiddenByLine[row] = [range.withoutTrailingNewlines(in: nsText)]
                }
            }
        }

        /// Usable text width. Taken from the text view, not the container:
        /// `widthTracksTextView` fills the container in during layout, so before
        /// the first layout the container still reads zero.
        private func editorWidth() -> CGFloat {
            guard let textView, let container = textView.textContainer else { return 0 }
            return textView.bounds.width
                - textView.textContainerInset.width * 2
                - container.lineFragmentPadding * 2
        }

        private func isTableRow(_ line: Int) -> Bool {
            guard line >= 0, line < map.lines.count, map.lines[line].kind == .normal else { return false }
            let range = map.lines[line].range
            var index = range.location
            let end = NSMaxRange(range)
            while index < end {
                let char = nsText.character(at: index)
                if char == 0x20 || char == 0x09 { index += 1; continue }
                return char == 0x7C
            }
            return false
        }

        /// Where each source line ended up, in view coordinates.
        ///
        /// Built by walking the laid-out line fragments and asking each one which
        /// characters it holds — the opposite direction from
        /// `lineFragmentRect(forGlyphAt: glyphIndexForCharacter(...))`, which
        /// cannot be trusted here. Measured: on a table line, where every glyph
        /// is suppressed, that call returned the *previous* fragment for six
        /// lines out of eleven, so rows drew on top of one another. A fragment
        /// asked about its own range cannot be off by one.
        private func lineRects() -> [Int: CGRect] {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  !map.lines.isEmpty else { return [:] }

            let origin = textView.textContainerOrigin
            let visible = (scrollView?.contentView.bounds ?? textView.visibleRect)
                .offsetBy(dx: -origin.x, dy: -origin.y)
                .insetBy(dx: 0, dy: -400)
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)

            var result: [Int: CGRect] = [:]
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragment, _ in
                let characters = layoutManager.characterRange(forGlyphRange: fragment,
                                                              actualGlyphRange: nil)
                guard characters.length > 0 else { return }
                let line = self.map.lineIndex(containing: characters.location)
                // A wrapped paragraph produces several fragments; the row belongs
                // at the first one.
                if result[line] == nil {
                    result[line] = rect.offsetBy(dx: origin.x, dy: origin.y)
                }
            }
            return result
        }

        func drawTables(in dirtyRect: NSRect) {
            guard !tablesByLine.isEmpty else { return }
            let rects = lineRects()
            for (line, table) in tablesByLine {
                guard let rect = rects[line], rect.intersects(dirtyRect) else { continue }
                table.draw(line: line, in: rect)
            }
        }

        func tableLink(at point: NSPoint) -> URL? {
            let rects = lineRects()
            for (line, table) in tablesByLine {
                guard let rect = rects[line], rect.contains(point) else { continue }
                return table.link(inLine: line,
                                  at: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY))
            }
            return nil
        }
    }
}

nonisolated private extension NSRange {
    func withoutTrailingNewlines(in text: NSString) -> NSRange {
        var result = self
        while result.length > 0 {
            let last = text.character(at: NSMaxRange(result) - 1)
            guard last == 10 || last == 13 else { break }
            result.length -= 1
        }
        return result
    }
}
