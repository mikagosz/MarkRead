import AppKit
import SwiftUI

/// Imperative handle on the live text view, so menu commands can act on the
/// selection without SwiftUI having to own the text.
@Observable
final class EditorHandle {
    weak var textView: NSTextView?
    #if DEBUG
    /// What the editor currently believes about itself, for the debug bridge.
    /// Rendering decisions are invisible from outside; this makes them answerable
    /// instead of guessable.
    ///
    /// DEBUG only. The bridge that reads it is plugged in locally for a
    /// measurement and unplugged before a push, so in a shipping build this
    /// closure was written on every launch and read by nothing.
    @ObservationIgnored var diagnostics: (() -> [String: Any])?
    /// Spoils the editor's own bookkeeping on purpose, so the consistency check
    /// in `Tests/incremental-check.swift` can show it notices. DEBUG only.
    @ObservationIgnored var spoilForCheck: (() -> Void)?
    #endif
}

/// NSTextView that follows links on a plain click.
///
/// AppKit only follows links by itself in a *non*-editable text view; in an
/// editable one a click just moves the caret. Since MarkRead is an editor whose
/// whole point is working links, the hit test is done here explicitly.
/// Option-click still places the caret, which is how you edit link text.
final class LiveMarkdownTextView: NSTextView {

    var onLinkClick: ((URL) -> Void)?
    /// The link under the pointer, or nil. Half of every `](…)` is deliberately
    /// not drawn, so without this there is nothing on screen that says where a
    /// link goes before it is clicked.
    var onLinkHover: ((URL?) -> Void)?
    /// A file dropped on the editor. Without an owner, AppKit treats it as text
    /// and pastes its path into the open note.
    var onFileDrop: ((URL) -> Void)?
    /// Draws rendered tables over the space their hidden source lines reserve.
    var drawTables: ((NSRect) -> Void)?

    /// Draws the box behind a fenced code block. Separate from `drawTables`
    /// because it has to land *under* the glyphs, and `draw(_:)` runs after
    /// them.
    var drawCodeBoxes: ((NSRect) -> Void)?
    /// Links inside a rendered table: its glyphs are suppressed, so the normal
    /// hit test has nothing to find there.
    var tableLink: ((NSPoint) -> URL?)?

    private var hoverArea: NSTrackingArea?
    private var hovered: URL?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTables?(dirtyRect)
    }

    /// The one hook that runs before the text is drawn. A code block's box is
    /// background — putting it in `draw(_:)` would paint it over the code.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBoxes?(rect)
    }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.option), let url = target(of: event) else {
            super.mouseDown(with: event)
            return
        }
        onLinkClick?(url)
    }

    override func cursorUpdate(with event: NSEvent) {
        if target(of: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Hovering

    /// `cursorUpdate` alone is not enough to report a target: AppKit sends it
    /// when the cursor rectangle changes, which says nothing about crossing from
    /// one link to the next.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(hover: target(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        report(hover: nil)
    }

    /// Whatever is clickable under the pointer: a link inside a rendered table
    /// first, since its glyphs are suppressed and the normal hit test is blind
    /// to them, then an ordinary link.
    private func target(of event: NSEvent) -> URL? {
        tableLink?(convert(event.locationInWindow, from: nil)) ?? link(at: event)
    }

    private func report(hover url: URL?) {
        guard url != hovered else { return }
        hovered = url
        onLinkHover?(url)
    }

    // MARK: - Dropped files

    // No `registerForDraggedTypes` call here on purpose: that method *replaces*
    // the list, and NSTextView already registers nineteen types of its own,
    // file URLs among them. The drop therefore arrives at this view either way —
    // what was missing is an owner for it.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        droppedFile(sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    /// Handled here and never handed to `super`. Measured: a note dropped on the
    /// window inserted 121 characters of its own path into the *open* document
    /// and left it dirty — one ⌘S from permanent litter in the user's file.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = droppedFile(sender) else { return super.performDragOperation(sender) }
        report(hover: nil)
        onFileDrop?(url)
        return true
    }

    private func droppedFile(_ sender: any NSDraggingInfo) -> URL? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.first as? URL
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
    let onLinkHover: (URL?) -> Void
    let onFileDrop: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    /// Hands the view and its coordinator the closures of *this* struct value.
    ///
    /// Called from `makeNSView` and again from every `updateNSView`, because
    /// SwiftUI builds a fresh `MarkdownEditor` — with a fresh binding — each time
    /// the open document changes. Nothing here may be captured once and kept.
    private func bind(_ coordinator: Coordinator, _ textView: LiveMarkdownTextView) {
        let binding = $text
        coordinator.onTextChange = { binding.wrappedValue = $0 }
        textView.onLinkClick = onLinkClick
        textView.onLinkHover = onLinkHover
        textView.onFileDrop = onFileDrop
    }

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
        textView.backgroundColor = MarkdownStyle.Palette.editorBackground
        textView.insertionPointColor = MarkdownStyle.Palette.caret
        textView.selectedTextAttributes = [
            .backgroundColor: MarkdownStyle.Palette.selectionBackground
        ]

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
        scrollView.backgroundColor = MarkdownStyle.Palette.editorBackground

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        bind(context.coordinator, textView)
        layout.delegate = context.coordinator
        textView.drawCodeBoxes = { [weak coordinator = context.coordinator] rect in
            coordinator?.drawCodeBoxes(in: rect)
        }
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

        context.coordinator.appearanceObserver = NotificationCenter.default.addObserver(
            forName: MarkdownStyle.Appearance.didChange,
            object: nil,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.restyleForAppearance() }
        }

        context.coordinator.replaceText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        bind(context.coordinator, textView)
        handle.textView = textView
        // Only when the document was swapped underneath us — echoing the user's
        // own keystrokes back into the storage would reset the caret on every
        // character typed.
        if textView.string != text {
            context.coordinator.replaceText(text)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        for observer in [coordinator.scrollObserver, coordinator.frameObserver,
                         coordinator.appearanceObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        /// Writes the buffer back into the document that is on screen *now*.
        ///
        /// This used to be a stored copy of the `MarkdownEditor` struct, and that
        /// copy carried a `@Binding` to whichever document was open when the
        /// coordinator was built. `updateNSView` refreshed the link handler but
        /// could not refresh a `let`, so after opening a second note every
        /// keystroke was written into the *first* document: the visible one never
        /// became dirty, ⌘S and the Save button stayed grey, and the text was
        /// gone at the next click. Confirmed on the running app.
        var onTextChange: (String) -> Void = { _ in }
        weak var textView: LiveMarkdownTextView?
        weak var scrollView: NSScrollView?
        var scrollObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?
        var appearanceObserver: NSObjectProtocol?

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
        /// Where each source line ended up, and the band it was measured for.
        ///
        /// Building this walks every laid-out fragment in an 800 px tall band.
        /// Hovering and `cursorUpdate` ask for it on every mouse-moved event, so
        /// it is kept until the layout changes (`didCompleteLayoutFor`) or the
        /// view scrolls somewhere else.
        private var lineRectsCache: [Int: CGRect] = [:]
        private var lineRectsKey: CGRect?
        #if DEBUG
        /// Counters for the debug bridge: how much work scrolling actually costs.
        private var styleRuns = 0
        private var styledLineCount = 0
        private var styleMillis = 0.0
        private var tablesBuilt = 0
        #endif

        init(handle: EditorHandle) {
            super.init()
            #if DEBUG
            handle.diagnostics = { [weak self] in self?.report() ?? [:] }
            handle.spoilForCheck = { [weak self] in
                guard let self, self.map.lines.count > 1 else { return }
                self.map = BlockMap(lines: Array(self.map.lines.dropLast()), openFrontMatter: false)
            }
            #endif
        }

        #if DEBUG
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
                "problems": consistencyProblems(),
            ]
        }

        /// Everything the editor keeps about the text, checked against the text.
        ///
        /// After an edit only the touched lines are worked out again and the
        /// rest is moved (`applyEdit`). This says whether what was moved still
        /// matches what a fresh start would compute.
        private func consistencyProblems() -> [String] {
            guard let storage = textView?.textStorage else { return ["no storage"] }
            var problems: [String] = []
            let text = storage.string as NSString
            let fresh = BlockMap.build(text)
            if fresh.lines.count != map.lines.count {
                problems.append("map has \(map.lines.count) lines, a fresh one \(fresh.lines.count)")
            } else if let bad = fresh.lines.indices.first(where: {
                fresh.lines[$0].range != map.lines[$0].range || fresh.lines[$0].kind != map.lines[$0].kind
            }) {
                problems.append("map differs from a fresh one at line \(bad)")
            }
            for (line, ranges) in hiddenByLine.sorted(by: { $0.key < $1.key }) {
                guard line < map.lines.count else { problems.append("hidden ranges kept for line \(line), past the end"); continue }
                let whole = map.lines[line].range
                if ranges.contains(where: { $0.location < whole.location || NSMaxRange($0) > NSMaxRange(whole) }) {
                    problems.append("hidden range outside line \(line)")
                }
                guard !isTableRow(line) else { continue }
                let expected = MarkdownScanner.decorations(text: text, map: fresh, lines: line ..< line + 1)
                    .compactMap { $0.style == .hiddenMarker ? $0.range : nil }
                if ranges != expected { problems.append("hidden ranges of line \(line) differ from the scanner") }
            }
            for (line, table) in tablesByLine.sorted(by: { $0.key < $1.key }) {
                if !table.lines.contains(line) { problems.append("line \(line) points at a table on \(table.lines)") }
                if !isTableRow(line) { problems.append("line \(line) is drawn as a table row but is not one") }
            }
            return Array(problems.prefix(8))
        }
        #endif

        /// Loads a different document into the view and highlights what shows.
        func replaceText(_ new: String) {
            guard let textView, let storage = textView.textStorage else { return }
            // Everything derived from the outgoing text has to be gone *before*
            // `endEditing()`, not two lines after it. AppKit trims the selection
            // to the new length from inside that call and sends
            // `textViewDidChangeSelection` there and then, which runs
            // `updateRevealedLine` → `tableTouched` → `isTableRow` — all of them
            // readers of this map. Measured four times on the running app: the
            // map still described the longer previous document, the read went
            // past the end of the new string, and the process died with an
            // NSRangeException, taking the unsaved text with it. No window, no
            // question, nothing on screen.
            forgetTextState()
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: new)
            storage.endEditing()
            textView.undoManager?.removeAllActions()
            rebuildMap()
            textView.scroll(.zero)
            highlightVisible()
        }

        /// The reader changed the face or its size in Settings.
        ///
        /// Everything this coordinator holds was measured for the old font:
        /// column widths, the laid-out tables, and the record of which lines are
        /// already styled. The text itself does not change, so the block map and
        /// the hidden ranges — both of them character positions — survive.
        func restyleForAppearance() {
            guard let textView, let storage = textView.textStorage else { return }
            textView.typingAttributes = MarkdownStyle.baseAttributes
            // The ground moves with the look: `claudeDark` carries its own, the
            // rest follow the Mac. Missing these leaves the new palette's text
            // on the old palette's background.
            textView.backgroundColor = MarkdownStyle.Palette.editorBackground
            textView.enclosingScrollView?.backgroundColor = MarkdownStyle.Palette.editorBackground
            textView.insertionPointColor = MarkdownStyle.Palette.caret
            textView.selectedTextAttributes = [
                .backgroundColor: MarkdownStyle.Palette.selectionBackground
            ]
            tableCache.removeAll(keepingCapacity: true)
            tablesByLine.removeAll(keepingCapacity: true)
            styledRange = nil
            lineRectsKey = nil
            // Restyling only the visible window would leave every line outside it
            // in the old size until it was scrolled to. Putting the whole
            // document back to plain body text first costs one pass and is the
            // only thing here that touches lines nobody is looking at.
            storage.setAttributes(MarkdownStyle.baseAttributes,
                                  range: NSRange(location: 0, length: storage.length))
            highlightVisible()
        }

        /// The one change NSTextView announced before `textDidChange`, in the
        /// coordinates of the text before it.
        private var pendingEdit: (range: NSRange, inserted: Int)?
        private var announcedEdits = 0

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            // `nil` is an attribute-only change; the text stays as it is.
            if let replacementString {
                announcedEdits += 1
                pendingEdit = (affectedCharRange, (replacementString as NSString).length)
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            onTextChange(textView.string)
            // Exactly one announced change → patch what it touched. Anything else
            // (several ranges at once, a change nobody announced) → start over,
            // which is always right and only slow.
            let edit = announcedEdits == 1 ? pendingEdit : nil
            pendingEdit = nil
            announcedEdits = 0
            if let edit, applyEdit(edit) {
                highlightVisible()
            } else {
                rebuildMap()
                highlightVisible()
            }
            // Otherwise the caret keeps whatever the character to its left had —
            // keep typing after a link and the new text joins the link.
            textView.typingAttributes = MarkdownStyle.baseAttributes
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateRevealedLine()
        }

        /// True while the storage holds text the map does not describe yet.
        ///
        /// AppKit sends the selection change from *inside* the storage edit —
        /// before `textDidChange` — so `updateRevealedLine` used to restyle the
        /// new text with the old map. Backspace in any row of a table being
        /// edited read past the end of the string and took the process down,
        /// unsaved text with it (dynamic audit 2026-11-12, found while fixing
        /// D-S-P1-01: D-S-P1-04). `textDidChange` catches up and reveals the
        /// caret's line itself.
        ///
        /// The length, not "an edit was announced": an announced edit that
        /// never happens would leave the editor unstyled for good. A change that
        /// keeps the length cannot reach past the end, and `textDidChange`
        /// restyles what it touched a moment later.
        ///
        /// Against the map, not `nsText`: that is the storage's own live string,
        /// so it is always exactly as long as the storage.
        private var textIsAhead: Bool {
            (textView?.textStorage?.length ?? 0) != (map.lines.last.map { NSMaxRange($0.range) } ?? 0)
        }

        private func rebuildMap() {
            guard let textView, let storage = textView.textStorage else { return }
            forgetTextState()
            nsText = storage.string as NSString
            map = BlockMap.build(nsText)
            updateRevealedLine()
        }

        /// Brings everything that describes the text up to date after one edit,
        /// touching only the lines it changed.
        ///
        /// Until 0.3.4 every keystroke threw it all away: the block map, the
        /// styled lines, every laid-out table. A table is restyled whole — its
        /// column widths come from all of its rows — so a character typed in the
        /// heading *above* a 10 000-row table cost 4.4 s, and 30 000 rows froze
        /// the program (dynamic audit 2026-11-12, D-S-P1-01). Lines above the
        /// edit are untouched; lines below only moved, and their attributes
        /// moved with the text in the storage — so the caches move with them.
        ///
        /// Returns false when the edit cannot be patched; the caller rebuilds.
        private func applyEdit(_ edit: (range: NSRange, inserted: Int)) -> Bool {
            guard let textView, let storage = textView.textStorage, !map.lines.isEmpty else { return false }
            let newText = storage.string as NSString
            guard let patch = BlockMap.patched(map, text: newText, location: edit.range.location,
                                               removed: edit.range.length, inserted: edit.inserted)
            else { return false }
            let old = map
            let first = patch.first, oldLast = patch.oldLast, newLast = patch.newLast
            let lineDelta = newLast - oldLast
            let charDelta = edit.inserted - edit.range.length

            /// Where an old line is now; nil for the lines the edit replaced.
            func moved(_ line: Int) -> Int? {
                line < first ? line : (line > oldLast ? line + lineDelta : nil)
            }
            func movedRange(_ range: NSRange, _ line: Int) -> NSRange {
                line > oldLast ? NSRange(location: range.location + charDelta, length: range.length) : range
            }

            map = patch.map
            nsText = newText
            lineRectsKey = nil
            knownTables.removeAll()

            var hidden: [Int: [NSRange]] = [:]
            hidden.reserveCapacity(hiddenByLine.count)
            for (line, ranges) in hiddenByLine {
                guard let now = moved(line) else { continue }
                hidden[now] = line > oldLast ? ranges.map { movedRange($0, line) } : ranges
            }
            hiddenByLine = hidden

            // The edited lines, in the new numbering, and any table they reach.
            var restyleFrom = first, restyleTo = newLast
            let editedHasRow = (first ... max(first, newLast)).contains { isTableRow($0) }
            let caret = min(textView.selectedRange().location, newText.length)
            let caretLine = map.lineIndex(containing: caret)

            var seen = Set<ObjectIdentifier>()
            var keptCache: [Int: TableLayout] = [:]
            var keptByLine: [Int: TableLayout] = [:]
            var keptTables = Set<ObjectIdentifier>()
            for table in Array(tableCache.values) + Array(tablesByLine.values) {
                guard seen.insert(ObjectIdentifier(table)).inserted else { continue }
                let lower = table.lines.lowerBound, upper = table.lines.upperBound
                let overlaps = lower <= oldLast && upper >= first
                let adjacent = upper == first - 1 || lower == oldLast + 1
                if overlaps || (adjacent && editedHasRow) {
                    // Its rows changed, or it may have grown into the edit.
                    let from = lower < first ? lower : first
                    let to = upper > oldLast ? upper + lineDelta : newLast
                    restyleFrom = min(restyleFrom, from)
                    restyleTo = max(restyleTo, to)
                    continue
                }
                if lower > oldLast { table.shift(by: lineDelta) }
                keptTables.insert(ObjectIdentifier(table))
            }
            for (key, table) in tableCache where keptTables.contains(ObjectIdentifier(table)) {
                if let now = moved(key) { keptCache[now] = table }
            }
            for (line, table) in tablesByLine where keptTables.contains(ObjectIdentifier(table)) {
                if let now = moved(line) { keptByLine[now] = table }
            }
            tableCache = keptCache
            tablesByLine = keptByLine

            (restyleFrom, restyleTo) = wholeTables((restyleFrom, restyleTo))
            // A very long table that holds the caret shows as markdown, not as a
            // grid, so nothing is laid out for it — only its pipes are padded to
            // line up. Restyling all of it on every keystroke is what made typing
            // inside one crawl; the rows around the caret are what is on screen.
            // The rest is restyled whole once the caret leaves the table.
            let window = 200
            if restyleTo - restyleFrom > 2 * window, isTableRow(caretLine) {
                restyleFrom = max(restyleFrom, first - window)
                restyleTo = min(restyleTo, newLast + window)
            }

            if let styled = styledRange {
                let lower = moved(styled.lowerBound) ?? first
                let upper = moved(styled.upperBound) ?? newLast
                styledRange = lower <= upper ? lower ... upper : nil
            }

            // The caret's line keeps its syntax visible. Re-reading it here, in
            // the new numbering, is what stops `updateRevealedLine` from taking
            // a keystroke for a move into a table.
            if let revealed = revealedLine {
                let line = old.lineIndex(containing: revealed.location)
                if moved(line) != nil {
                    revealedLine = movedRange(revealed, line)
                } else {
                    revealedLine = newText.lineRange(for: NSRange(location: caret, length: 0))
                }
            }

            if restyleFrom <= restyleTo, restyleTo < map.lines.count {
                style(from: restyleFrom, to: restyleTo)
                if let styled = styledRange,
                   restyleFrom <= styled.upperBound + 1, restyleTo >= styled.lowerBound - 1 {
                    styledRange = min(restyleFrom, styled.lowerBound) ... max(restyleTo, styled.upperBound)
                }
            }
            updateRevealedLine()
            return true
        }

        /// Drops everything that describes the current text.
        ///
        /// Safe to call at any moment, including one where the storage is being
        /// rewritten: an empty map and an empty string make every reader below
        /// return "nothing here" instead of reading a range that no longer
        /// exists. `rebuildMap` fills it all in again.
        private func forgetTextState() {
            map = BlockMap(lines: [], openFrontMatter: false)
            nsText = ""
            knownTables.removeAll()
            hiddenByLine.removeAll(keepingCapacity: true)
            tablesByLine.removeAll(keepingCapacity: true)
            tableCache.removeAll(keepingCapacity: true)
            styledRange = nil
            revealedLine = nil
            lineRectsKey = nil
        }

        // MARK: - Revealing the caret's line

        private func updateRevealedLine() {
            guard let textView, let layoutManager = textView.layoutManager, !textIsAhead else { return }
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
            if (tableTouched(previous) || tableTouched(wanted)), !sameTable(previous, wanted) {
                // Styling is incremental now, so asking for a re-highlight is not
                // enough on its own — these lines count as already done. Drop the
                // record so the visible window is genuinely restyled.
                styledRange = nil
                highlightVisible()
            }
        }

        /// True when both lines are rows of one table that is showing as markdown.
        ///
        /// Moving the caret inside such a table changes nothing about it: it
        /// stays markdown. Restyling it anyway — the whole table, column widths
        /// and all — ran on every keystroke and every arrow key (D-S-P1-01).
        private func sameTable(_ a: NSRange?, _ b: NSRange?) -> Bool {
            guard let a, let b else { return false }
            let first = map.lineIndex(containing: a.location)
            let second = map.lineIndex(containing: b.location)
            let low = min(first, second), high = max(first, second)
            guard high - low <= 5_000, tablesByLine[low] == nil, tablesByLine[high] == nil else { return false }
            return (low ... high).allSatisfy { isTableRow($0) }
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
            // TextKit 1 makes glyphs for the whole document the first time the
            // view is sized, and each miss here ran the scanner on one line: a
            // million-line file was scanned line by line before the window
            // showed anything (dynamic audit 2026-11-12, D-S-P3-04). Only lines
            // near what is styled can be on screen; the rest get their markers
            // hidden by `style`, which regenerates their glyphs when they come
            // into view. Not cached, so that later answer is not shadowed.
            let near = 500
            if let styled = styledRange {
                guard line >= styled.lowerBound - near, line <= styled.upperBound + near else { return [] }
            } else if line > near {
                return []
            }
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
        private var highlighting = false
        private var highlightAgain = false

        /// Laying out the window can resize the text view, and the resize
        /// notification calls straight back in here. Measured on a 10 000-row
        /// table: that recursion went hundreds of frames deep and the first
        /// drawing took 17 s (D-S-P3-04). One pass at a time; a call that
        /// arrives during a pass asks for one more after it.
        func highlightVisible() {
            if highlighting {
                highlightAgain = true
                return
            }
            highlighting = true
            defer { highlighting = false }
            var passes = 0
            repeat {
                highlightAgain = false
                highlightVisibleOnce()
                passes += 1
            } while highlightAgain && passes < 4
        }

        private func highlightVisibleOnce() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  !map.lines.isEmpty, !textIsAhead else { return }

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
            // A table is measured from every row it has, so a span that begins
            // or ends in the middle of one produces a *piece* of table with its
            // own column widths — and the piece without the `|---|` row does not
            // even know it has a header. That is the reported split: the top of
            // the table on one grid, the bottom on another. So each span is
            // grown until neither end sits inside a table, which is the one
            // place where "style only what is new" has to give ground.
            for (from, to) in pending.map(wholeTables) {
                style(from: from, to: to)
                if let styled = styledRange {
                    styledRange = min(from, styled.lowerBound) ... max(to, styled.upperBound)
                }
            }
        }

        /// Grows a span of lines until it starts and ends outside a table.
        ///
        /// Only ends that are *inside* a table move; a span that already begins
        /// on ordinary text is returned untouched. A table longer than the
        /// styling window is therefore styled and measured in one piece — the
        /// only unit its column widths can be computed from.
        private func wholeTables(_ span: (Int, Int)) -> (Int, Int) {
            var (first, last) = span
            if !isLargeTable(first) {
                while first > 0, isTableRow(first), isTableRow(first - 1) { first -= 1 }
            }
            if !isLargeTable(last) {
                while last < map.lines.count - 1, isTableRow(last), isTableRow(last + 1) { last += 1 }
            }
            return (first, last)
        }

        /// Tables longer than this are not drawn as a grid; they stay markdown.
        ///
        /// Every cell of a drawn table is its own text layout. At 100 000 rows
        /// that was 2.3 GB and 67 s before the window showed anything, and the
        /// pipes of a raw table are lined up from all of its rows too (dynamic
        /// audit 2026-11-12, D-S-P1-01). A table that long is data, not a page
        /// to read, so it is shown the way the file has it.
        static let largestDrawnTable = 2_000

        /// The tables measured since the text last changed.
        private var knownTables: [ClosedRange<Int>] = []

        /// All the lines of the table `line` belongs to, or nil off a table.
        private func tableExtent(_ line: Int) -> ClosedRange<Int>? {
            guard isTableRow(line) else { return nil }
            if let known = knownTables.first(where: { $0.contains(line) }) { return known }
            var first = line, last = line
            while first > 0, isTableRow(first - 1) { first -= 1 }
            while last < map.lines.count - 1, isTableRow(last + 1) { last += 1 }
            knownTables.append(first ... last)
            return first ... last
        }

        private func isLargeTable(_ line: Int) -> Bool {
            (tableExtent(line)?.count ?? 0) > Self.largestDrawnTable
        }

        /// Everything the styling of one span of lines needs, done once.
        private func style(from firstLine: Int, to lastLine: Int) {
            #if DEBUG
            let started = Date()
            defer {
                styleRuns += 1
                styledLineCount += max(0, lastLine - firstLine + 1)
                styleMillis += Date().timeIntervalSince(started) * 1000
            }
            #endif
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
            // A table too long to draw is shown as it is in the file: padding
            // its pipes would mean measuring every one of its rows.
            if (firstLine ... lastLine).contains(where: { isLargeTable($0) }) {
                decorations.removeAll { decoration in
                    guard case .tableCellPad = decoration.style else { return false }
                    return isLargeTable(map.lineIndex(containing: decoration.range.location))
                }
            }
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
            lineRectsKey = nil
        }

        /// Any relayout moves lines, so the measured rectangles are stale.
        func layoutManager(_ layoutManager: NSLayoutManager,
                           didCompleteLayoutFor textContainer: NSTextContainer?,
                           atEnd layoutFinishedFlag: Bool) {
            lineRectsKey = nil
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

            // One edit for all the row heights. Each `addAttribute` outside it is
            // an edit of its own, and every edit re-checks the attributes of the
            // whole range — row by row that was quadratic: 14 s to first show a
            // 10 000-row table, nearly all of it here (dynamic audit 2026-11-12).
            storage.beginEditing()
            defer { storage.endEditing() }

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
                if isLargeTable(line) {
                    for row in block { tablesByLine[row] = nil }
                    continue
                }
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
                    #if DEBUG
                    tablesBuilt += 1
                    #endif
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
                    hiddenByLine[row] = [range.trimmedNewlines(in: nsText)]
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

        /// `line < map.lines.count` says nothing about how long the string is —
        /// the map can outlive the text it describes by the width of one AppKit
        /// notification. `MarkdownTables.isRow` clamps to what `nsText` really
        /// holds, and is the only implementation of this test in the project.
        private func isTableRow(_ line: Int) -> Bool {
            guard line >= 0, line < map.lines.count, map.lines[line].kind == .normal else { return false }
            return MarkdownTables.isRow(nsText, map.lines[line].range)
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
            if let lineRectsKey, lineRectsKey == visible { return lineRectsCache }
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
            lineRectsCache = result
            lineRectsKey = visible
            return result
        }

        // MARK: - Code blocks

        /// True for a line that is inside a fenced block or is one of its fences.
        private func isCodeLine(_ line: Int) -> Bool {
            guard line >= 0, line < map.lines.count else { return false }
            switch map.lines[line].kind {
            case .fence, .code: return true
            case .normal, .frontMatter: return false
            }
        }

        /// Draws one rounded box per fenced code block, the way Xcode draws one.
        ///
        /// Until 0.2.7 a code block had no box at all: every run carried its own
        /// `.backgroundColor`, so the fill stopped where each line's text
        /// stopped and the block was a stack of ragged strips instead of a
        /// shape. The run background stays — same colour, so it cannot show —
        /// and this puts the shape underneath it.
        ///
        /// Only the laid-out lines are looked at, so this stays cheap on a long
        /// document. A block that runs off the top or bottom of the window has
        /// its box extended past the edge rather than closed there, otherwise
        /// scrolling through a long block draws a border across the middle of
        /// the screen.
        func drawCodeBoxes(in dirtyRect: NSRect) {
            let rects = lineRects()
            guard !rects.isEmpty else { return }
            let radius = TableLayout.cornerRadius

            var lines = rects.keys.filter { isCodeLine($0) }.sorted()
            while let first = lines.first {
                var last = first
                lines.removeFirst()
                while let next = lines.first, next == last + 1 {
                    last = next
                    lines.removeFirst()
                }

                var box = CGRect.null
                for line in first ... last {
                    guard let rect = rects[line] else { continue }
                    box = box.union(rect)
                }
                guard !box.isNull else { continue }
                // Off-screen ends: push the edge (and its corners) out of sight.
                // A closed end gets Xcode's breathing room instead.
                let padding: CGFloat = 4
                if isCodeLine(first - 1) {
                    box.origin.y -= radius + 2
                    box.size.height += radius + 2
                } else {
                    box.origin.y -= padding
                    box.size.height += padding
                }
                box.size.height += isCodeLine(last + 1) ? radius + 2 : padding
                guard box.intersects(dirtyRect) else { continue }

                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: radius, yRadius: radius)
                MarkdownStyle.Palette.codeBackground.setFill()
                path.fill()
                MarkdownStyle.Palette.border.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        /// Where each of a table's rows is drawn.
        ///
        /// 🔴 Anchored once and then stacked by the rows' **own** heights, rather
        /// than asking the layout for a rectangle per source line.
        ///
        /// Measured 2026-08-27 on a 620-point window: a row whose paragraph style
        /// carried `maximumLineHeight = 48` — the right number, still there in the
        /// storage at drawing time — was handed a line fragment **18 points**
        /// tall, and the row after it began 30 points too high. Two rows drew on
        /// top of each other and the frame ran through the middle of them, which
        /// is what "the border does not work" looked like. Every other row in the
        /// same table got exactly the height it asked for, so this is not the
        /// reserved height being wrong; it is one fragment disagreeing with it.
        ///
        /// The table knows its own geometry and does not need to ask twice. One
        /// rectangle from the layout fixes the table in place; everything below
        /// follows from `height(forLine:)`, which is the same number the space was
        /// reserved with. A fragment that comes back the wrong size can then push
        /// the table a few points out of its hole — it can no longer fold the
        /// table in on itself.
        private func rowRects(for table: TableLayout, in rects: [Int: CGRect]) -> [Int: CGRect] {
            // The anchor is the topmost row the layout will admit to. Usually
            // that is the table's first line; when the table is scrolled off the
            // top it is whichever row is on screen, and the rows above it are
            // subtracted to find where the table starts.
            guard let anchorLine = table.lines.first(where: { rects[$0] != nil }),
                  let anchor = rects[anchorLine] else { return [:] }
            var top = anchor.minY
            for line in table.lines where line < anchorLine {
                top -= table.height(forLine: line) ?? 1
            }

            var result: [Int: CGRect] = [:]
            var y = top
            for line in table.lines {
                let height = table.height(forLine: line) ?? 1
                result[line] = CGRect(x: anchor.minX, y: y, width: anchor.width, height: height)
                y += height
            }
            return result
        }

        /// Every table with a row among the laid-out lines, each listed once.
        private func visibleTables() -> [TableLayout] {
            var seen = Set<Int>()
            return tablesByLine.keys.sorted().compactMap { line in
                guard let table = tablesByLine[line],
                      seen.insert(table.lines.lowerBound).inserted else { return nil }
                return table
            }
        }

        func drawTables(in dirtyRect: NSRect) {
            guard !tablesByLine.isEmpty else { return }
            let rects = lineRects()
            for table in visibleTables() {
                for (line, rect) in rowRects(for: table, in: rects)
                where rect.intersects(dirtyRect) {
                    table.draw(line: line, in: rect)
                }
            }
        }

        func tableLink(at point: NSPoint) -> URL? {
            // Nothing drawn means nothing to hit, and this is asked on every
            // mouse-moved event — same early exit as `drawTables`.
            guard !tablesByLine.isEmpty else { return nil }
            let rects = lineRects()
            // The same geometry the drawing uses, for the same reason: a click has
            // to land in the cell it looks like it landed in.
            for table in visibleTables() {
                for (line, rect) in rowRects(for: table, in: rects) where rect.contains(point) {
                    return table.link(inLine: line,
                                      at: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY))
                }
            }
            return nil
        }
    }
}

// `NSRange.trimmedNewlines(in:)` lives in MarkdownTables.swift — this file used
// to carry a second copy of it under a different name.
