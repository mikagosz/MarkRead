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
        let text = storage.string as NSString
        guard let edit = wrapEdit(marker, in: text, selection: textView.selectedRange()) else { return }
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(edit.selection)
    }

    /// What ⌘B, ⌘I and their neighbours would do: the range to replace, what to
    /// put there, and where the selection lands afterwards.
    ///
    /// Split out of `wrap` so the whole decision can be driven from a headless
    /// check — an `NSTextView` needs a running app, and this is the only part of
    /// the command that can be wrong.
    static func wrapEdit(_ marker: String, in text: NSString, selection: NSRange)
        -> (range: NSRange, replacement: String, selection: NSRange)? {
        guard selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= text.length else { return nil }
        let markerLength = (marker as NSString).length
        guard markerLength > 0 else { return nil }
        let selected = text.substring(with: selection)

        // An empty selection can only ever add. A caret parked between the two
        // stars of `**` is somebody about to type an emphasised word, not a
        // request to delete both of them — which is what happened here, because
        // the two markers around a zero-length selection look exactly like a
        // wrapped one.
        if selection.length > 0, isWrapped(marker as NSString, in: text, around: selection) {
            let outer = NSRange(location: selection.location - markerLength,
                                length: selection.length + markerLength * 2)
            return (outer, selected,
                    NSRange(location: outer.location, length: (selected as NSString).length))
        }

        let replacement = marker + selected + marker
        return (selection, replacement,
                NSRange(location: selection.location + markerLength,
                        length: (selected as NSString).length))
    }

    /// True when `marker` already sits on both sides of the selection *and*
    /// taking it off means removing this command's own emphasis.
    ///
    /// Looking only at the characters the marker is long is not enough for the
    /// asterisk, because asterisks stack: one is italic, two are bold, three are
    /// both. ⌘I next to `**bold**` found a `*` on each side, took one off each
    /// side, and turned bold into italic — a command that claims to remove
    /// emphasis quietly changing which emphasis is there. So the whole run is
    /// counted: a one-character marker is present only when the run is odd.
    private static func isWrapped(_ marker: NSString, in text: NSString, around selection: NSRange) -> Bool {
        let length = marker.length
        guard selection.location - length >= 0,
              NSMaxRange(selection) + length <= text.length,
              text.substring(with: NSRange(location: selection.location - length, length: length)) == marker as String,
              text.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == marker as String
        else { return false }

        // `~~`, `==` and a backtick do not stack — they are either there or they
        // are not, and the two comparisons above have already settled it.
        let unit = marker.character(at: 0)
        guard unit == ("*" as NSString).character(at: 0) || unit == ("_" as NSString).character(at: 0),
              marker as String == String(repeating: String(UnicodeScalar(unit)!), count: length)
        else { return true }

        let run = min(run(of: unit, before: selection.location, in: text),
                      run(of: unit, after: NSMaxRange(selection), in: text))
        return length == 1 ? run % 2 == 1 : run >= length
    }

    /// How many `character`s run backwards from `index`, which is exclusive.
    private static func run(of character: unichar, before index: Int, in text: NSString) -> Int {
        var count = 0
        var at = index - 1
        while at >= 0, text.character(at: at) == character { count += 1; at -= 1 }
        return count
    }

    /// How many `character`s run forwards from `index`, which is inclusive.
    private static func run(of character: unichar, after index: Int, in text: NSString) -> Int {
        var count = 0
        var at = index
        while at < text.length, text.character(at: at) == character { count += 1; at += 1 }
        return count
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
