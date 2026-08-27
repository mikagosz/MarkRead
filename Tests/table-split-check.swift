// Headless check that a table is never laid out in pieces.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -D DEBUG \
//          MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
//          MarkRead/MarkdownTableRenderer.swift MarkRead/MarkdownTextView.swift \
//          Tests/table-split-check.swift -o /tmp/table-split-check \
//   && /tmp/table-split-check
//
// The fault it defends against, reported 2026-08-27: open a long note, scroll to
// the bottom, and the table down there is drawn on two different grids — the top
// rows on one set of column widths, the rows below them on another, the second
// set without a header. Hiding the sidebar moved the split rather than fixing it.
//
// Cause: styling is incremental, so a scroll styles the span
// `(alreadyStyled.upperBound + 1) ... newLastLine`. When that span begins inside
// a table, `buildTables` groups only the rows it can see and measures a *piece*
// of the table — and column widths come from the rows a piece happens to hold.
//
// 🔴 A screenshot cannot settle this and neither can a single render: the split
// only appears after the editor has been scrolled *through* the table in more
// than one step, which is why this drives a real scroll view rather than jumping
// straight to the bottom.
import AppKit
import SwiftUI

struct Root: View {
    @State var text: String
    let handle: EditorHandle
    var body: some View {
        MarkdownEditor(text: $text, handle: handle,
                       onLinkClick: { _ in }, onLinkHover: { _ in }, onFileDrop: { _ in })
    }
}

@main
struct TableSplitCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    /// A note whose table sits far enough down that reaching it takes several
    /// styling passes, and is long enough to straddle the edge of one.
    static func note(tableRows: Int) -> String {
        var lines: [String] = ["# A long note", ""]
        for index in 1 ... 220 {
            lines.append("Paragraph \(index) — ordinary text, long enough to take a whole line on its own.")
            lines.append("")
        }
        lines.append("| Data | Stanowisko | Firma | Lokalizacja | Stawka | Link |")
        lines.append("|---|---|---|---|---|---|")
        for index in 1 ... tableRows {
            lines.append("| 2\(index).08.2026 | Test Automation Engineer with Python \(index) "
                         + "| YOUR ITEAMS | Warszawa, Wola | 90–115 zł netto+VAT/godz. "
                         + "| [Pracuj.pl](https://example.invalid/\(index)) |")
        }
        lines.append("")
        for index in 1 ... 40 {
            lines.append("Closing paragraph \(index).")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.standard.set("system", forKey: MarkdownStyle.Appearance.lookKey)
        MarkdownStyle.Appearance.reload()

        let handle = EditorHandle()
        // Small window on purpose: the styling window is the visible rect plus a
        // 60-line margin, so a short view is what makes a scroll arrive in steps.
        let size = NSSize(width: 900, height: 460)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: Root(text: note(tableRows: 160), handle: handle))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        guard let scroll = firstScrollView(in: host), let document = scroll.documentView else {
            print("FAIL  no scroll view"); exit(1)
        }

        // Scroll the way a reader does: down in steps, to the bottom.
        var worstTables = 0
        var worstFraction = 0.0
        for step in 0 ... 40 {
            let fraction = Double(step) / 40.0
            let y = (document.frame.height - scroll.contentSize.height) * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let report = handle.diagnostics?() ?? [:]
            let tables = report["tables"] as? Int ?? 0
            if tables > worstTables { worstTables = tables; worstFraction = fraction }
        }

        check("one table stays one table while scrolling down", worstTables <= 1,
              "— laid out as \(worstTables) tables at fraction \(worstFraction)")

        // Same note, read from the bottom up: the span styled then runs backwards
        // and its *upper* end is the one that can land inside the table.
        worstTables = 0
        for step in stride(from: 40, through: 0, by: -1) {
            let fraction = Double(step) / 40.0
            let y = (document.frame.height - scroll.contentSize.height) * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let report = handle.diagnostics?() ?? [:]
            worstTables = max(worstTables, report["tables"] as? Int ?? 0)
        }
        check("one table stays one table while scrolling back up", worstTables <= 1,
              "— laid out as \(worstTables) tables")

        // Hiding the sidebar while standing inside the table: a width change
        // throws every measurement away and restyles from wherever the reader is
        // looking, so the table is now cut at *that* edge instead. This is the
        // half of the report that reads "it repairs itself where I am looking
        // and breaks further up".
        let inside = (document.frame.height - scroll.contentSize.height) * 0.85
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, inside)))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.setContentSize(NSSize(width: 1180, height: 460))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 1180, height: 460))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        worstTables = 0
        for step in stride(from: 40, through: 0, by: -1) {
            let fraction = Double(step) / 40.0
            let y = (document.frame.height - scroll.contentSize.height) * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let report = handle.diagnostics?() ?? [:]
            worstTables = max(worstTables, report["tables"] as? Int ?? 0)
        }
        check("one table stays one table after the width changes", worstTables <= 1,
              "— laid out as \(worstTables) tables")

        // Positive control: the counter this all rests on has to be able to see a
        // second table, or every zero above means nothing.
        let twoHandle = EditorHandle()
        let twoWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        twoWindow.appearance = NSAppearance(named: .darkAqua)
        let twoTables = "| a | b |\n|---|---|\n| 1 | 2 |\n\ntext\n\n| c | d |\n|---|---|\n| 3 | 4 |\n"
        let twoHost = NSHostingView(rootView: Root(text: twoTables, handle: twoHandle))
        twoHost.frame = NSRect(origin: .zero, size: size)
        twoWindow.contentView = twoHost
        twoWindow.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        twoWindow.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        let twoReport = twoHandle.diagnostics?() ?? [:]
        check("control: two tables are counted as two", (twoReport["tables"] as? Int ?? 0) == 2,
              "— counted \(twoReport["tables"] ?? "nothing")")

        // What the whole-table rule costs, so it is a number and not a hope.
        let cost = handle.diagnostics?() ?? [:]
        print("\ncost — tables built: \(cost["tablesBuilt"] ?? "?"), "
              + "style runs: \(cost["styleRuns"] ?? "?"), "
              + "lines styled: \(cost["styledLineCount"] ?? "?"), "
              + "style ms: \(cost["styleMillis"] ?? "?")")

        print(failures == 0 ? "\nall good" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}
