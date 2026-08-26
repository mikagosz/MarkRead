import AppKit

/// The "full editing options" half: menu commands that wrap or prefix the
/// selection with markdown syntax.
///
/// They work on the text view's own storage through `insertText(_:replacementRange:)`,
/// which means every one of them lands in the undo stack for free and needs no
/// bookkeeping here.
enum EditorActions {

    /// Wraps the selection in `marker`, or unwraps it when it is already wrapped.
    static func wrap(_ marker: String, in textView: NSTextView?) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let text = storage.string as NSString

        let markerLength = (marker as NSString).length
        let outer = NSRange(location: selection.location - markerLength,
                            length: selection.length + markerLength * 2)
        if outer.location >= 0, NSMaxRange(outer) <= text.length,
           text.substring(with: outer).hasPrefix(marker),
           text.substring(with: outer).hasSuffix(marker) {
            // Already emphasised — take it off rather than nesting.
            let inner = text.substring(with: selection)
            guard textView.shouldChangeText(in: outer, replacementString: inner) else { return }
            textView.insertText(inner, replacementRange: outer)
            textView.setSelectedRange(NSRange(location: outer.location, length: (inner as NSString).length))
            return
        }

        let selected = text.substring(with: selection)
        let replacement = marker + selected + marker
        guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
        textView.insertText(replacement, replacementRange: selection)
        textView.setSelectedRange(NSRange(location: selection.location + markerLength,
                                          length: (selected as NSString).length))
    }

    /// Sets (or clears) the heading level of every line the selection touches.
    static func heading(_ level: Int, in textView: NSTextView?) {
        transformLines(in: textView) { line in
            var stripped = line
            while stripped.hasPrefix("#") { stripped.removeFirst() }
            if stripped.hasPrefix(" ") { stripped.removeFirst() }
            guard level > 0 else { return stripped }
            return String(repeating: "#", count: level) + " " + stripped
        }
    }

    /// Toggles a bullet on every line the selection touches.
    static func bulletList(in textView: NSTextView?) {
        transformLines(in: textView) { line in
            line.hasPrefix("- ") ? String(line.dropFirst(2)) : "- " + line
        }
    }

    /// Toggles a task checkbox, and ticks one that is already there.
    static func task(in textView: NSTextView?) {
        transformLines(in: textView) { line in
            if line.hasPrefix("- [ ] ") { return "- [x] " + line.dropFirst(6) }
            if line.lowercased().hasPrefix("- [x] ") { return "- " + line.dropFirst(6) }
            if line.hasPrefix("- ") { return "- [ ] " + line.dropFirst(2) }
            return "- [ ] " + line
        }
    }

    static func quote(in textView: NSTextView?) {
        transformLines(in: textView) { line in
            line.hasPrefix("> ") ? String(line.dropFirst(2)) : "> " + line
        }
    }

    /// Wraps the selection as a link, putting the caret where the URL goes.
    static func link(in textView: NSTextView?) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let label = (storage.string as NSString).substring(with: selection)
        let replacement = "[\(label)]()"
        guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
        textView.insertText(replacement, replacementRange: selection)
        // Caret between the parentheses, ready for a paste.
        textView.setSelectedRange(NSRange(location: selection.location + (label as NSString).length + 3,
                                          length: 0))
    }

    static func codeBlock(in textView: NSTextView?) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let selected = (storage.string as NSString).substring(with: selection)
        let replacement = "```\n" + selected + "\n```"
        guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
        textView.insertText(replacement, replacementRange: selection)
    }

    // MARK: - Line-wise editing

    /// Applies `transform` to every line the selection touches, as one undoable
    /// edit, and leaves the same lines selected afterwards.
    private static func transformLines(in textView: NSTextView?, _ transform: (String) -> String) {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        let lineRange = text.lineRange(for: selection)

        let block = text.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        let rebuilt = lines.map(transform).joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")

        guard textView.shouldChangeText(in: lineRange, replacementString: rebuilt) else { return }
        textView.insertText(rebuilt, replacementRange: lineRange)
        textView.setSelectedRange(NSRange(location: lineRange.location,
                                          length: (rebuilt as NSString).length))
    }
}
