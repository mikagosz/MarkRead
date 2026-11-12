// Headless check that typing patches the editor's bookkeeping correctly.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -D DEBUG \
//          MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
//          MarkRead/MarkdownTableRenderer.swift MarkRead/MarkdownTextView.swift \
//          Tests/incremental-check.swift -o /tmp/incremental-check \
//   && /tmp/incremental-check
//
// Since 0.3.4 a keystroke no longer rebuilds everything: the block map is
// patched, styled lines and laid-out tables are moved, and only the edited lines
// are worked out again (dynamic audit 2026-11-12, D-S-P1-01, D-S-P3-04). That is
// only safe if what was moved still matches what a fresh start would compute.
// This types into a real NSTextView — insertions, deletions, newlines, pipes,
// fences, undo — and after every edit asks the editor to compare itself with
// the text. Fixed seed, so a failure can be replayed.
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
struct IncrementalCheck {
    static var failures = 0
    static var seed: UInt64 = 42

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    static func random(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(max(1, n)))
    }

    static func note(frontMatter: Bool) -> String {
        var lines: [String] = frontMatter ? ["---", "title: x", "---"] : []
        lines += ["# Heading with **bold**", "", "Text with `code`, ~~gone~~ and ==marked== and [a link](https://e.invalid).", ""]
        lines += ["```swift", "let x = 1", "```", ""]
        lines += ["| a | b |", "|---|---|"] + (1 ... 120).map { "| [r\($0)](https://e.invalid/\($0)) | **\($0)** |" }
        lines += ["", "> quote with *italic*", "", "- [ ] task", "- item", ""]
        lines += (1 ... 80).map { "Paragraph \($0) with __under__ and a [[wiki]] link." }
        lines += ["", "| c | d |", "|---|---|", "| 1 | 2 |", ""]
        return lines.joined(separator: "\n")
    }

    static func run(frontMatter: Bool, edits: Int) {
        let handle = EditorHandle()
        let size = NSSize(width: 900, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Root(text: note(frontMatter: frontMatter), handle: handle))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        guard let textView = handle.textView else { check("editor exists", false); return }
        window.makeFirstResponder(textView)
        let label = frontMatter ? "with front matter" : "without front matter"

        let start = handle.diagnostics?()["problems"] as? [String] ?? ["no report"]
        check("\(label): consistent before typing", start.isEmpty, "\(start)")

        let pieces = ["x", "\n", "|", " | ", "```\n", "| a | b |\n", "~~", "**", "`", "[[", "\n\n", "> ", "- "]
        var firstProblem: (Int, String, [String])?
        for step in 0 ..< edits {
            let length = (textView.string as NSString).length
            let location = random(length + 1)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            var what: String
            switch random(10) {
            case 0, 1:
                textView.deleteBackward(nil)
                what = "delete before \(location)"
            case 2:
                let span = min(random(30), length - location)
                textView.setSelectedRange(NSRange(location: location, length: span))
                textView.insertText("", replacementRange: textView.selectedRange())
                what = "delete \(span) at \(location)"
            case 3:
                textView.undoManager?.undo()
                what = "undo"
            default:
                let piece = pieces[random(pieces.count)]
                textView.insertText(piece, replacementRange: textView.selectedRange())
                what = "insert \(piece.debugDescription) at \(location)"
            }
            if random(8) == 0, let scroll = textView.enclosingScrollView {
                let y = CGFloat(random(Int(max(1, textView.frame.height - scroll.contentSize.height))))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                what += ", scroll"
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            let problems = handle.diagnostics?()["problems"] as? [String] ?? ["no report"]
            if !problems.isEmpty, firstProblem == nil { firstProblem = (step, what, problems) }
        }
        check("\(label): consistent after each of \(edits) edits", firstProblem == nil,
              firstProblem.map { "— step \($0.0) (\($0.1)): \($0.2)" } ?? "")

        // Positive control: the check has to be able to see a spoilt map.
        handle.spoilForCheck?()
        let spoilt = handle.diagnostics?()["problems"] as? [String] ?? []
        check("\(label): control — a spoilt map is noticed", !spoilt.isEmpty)
        window.orderOut(nil)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        run(frontMatter: false, edits: 600)
        run(frontMatter: true, edits: 200)
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
