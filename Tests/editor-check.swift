// Headless check for the Format menu's wrap commands. No frameworks, no fixtures.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/EditorActions.swift Tests/editor-check.swift \
//          -o /tmp/editor-check && /tmp/editor-check
//
// The point it defends: ⌘B and ⌘I edit the reader's file. Deciding whether a
// selection is "already wrapped" from the two characters next to it is wrong in
// two ways that both delete text — an empty selection between a pair of markers
// looked wrapped and lost both of them, and a bold word looked italic to ⌘I,
// which took one star off each side and turned bold into italic. The decision
// lives in `wrapEdit`, which is why it can be driven from here without an app.
import AppKit

@main
struct EditorCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    /// The document and selection a wrap command would leave behind.
    static func apply(_ marker: String, to text: String, selecting selection: NSRange)
        -> (text: String, selection: NSRange)? {
        guard let edit = EditorActions.wrapEdit(marker, in: text as NSString, selection: selection)
        else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement),
                edit.selection)
    }

    static func check(_ name: String, _ marker: String, _ text: String, _ selection: NSRange,
                      becomes expected: String, selecting expectedSelection: NSRange? = nil) {
        guard let result = apply(marker, to: text, selecting: selection) else {
            check(name, false, "refused the edit")
            return
        }
        check(name, result.text == expected, "got \u{201C}\(result.text)\u{201D}, wanted \u{201C}\(expected)\u{201D}")
        if let expectedSelection {
            check("\(name) — selection",
                  NSEqualRanges(result.selection, expectedSelection),
                  "got \(NSStringFromRange(result.selection)), wanted \(NSStringFromRange(expectedSelection))")
        }
    }

    static func main() {
        // Plain wrapping, and taking it off again.
        check("italic wraps a word", "*", "word", NSRange(location: 0, length: 4),
              becomes: "*word*", selecting: NSRange(location: 1, length: 4))
        check("italic unwraps its own word", "*", "*word*", NSRange(location: 1, length: 4),
              becomes: "word", selecting: NSRange(location: 0, length: 4))
        check("bold unwraps its own word", "**", "**word**", NSRange(location: 2, length: 4),
              becomes: "word")
        check("strikethrough unwraps", "~~", "~~gone~~", NSRange(location: 2, length: 4),
              becomes: "gone")
        check("highlight unwraps", "==", "==hi==", NSRange(location: 2, length: 2),
              becomes: "hi")
        check("inline code unwraps", "`", "`code`", NSRange(location: 1, length: 4),
              becomes: "code")

        // P3-04, first half: asterisks stack, so a run of two is bold and ⌘I has
        // nothing of its own to remove there.
        check("italic on a bold word adds, never strips", "*", "**word**", NSRange(location: 2, length: 4),
              becomes: "***word***")
        check("italic on bold-italic removes the italic", "*", "***word***", NSRange(location: 3, length: 4),
              becomes: "**word**")
        check("bold on bold-italic leaves the italic", "**", "***word***", NSRange(location: 3, length: 4),
              becomes: "*word*")
        check("bold on an italic word adds", "**", "*word*", NSRange(location: 1, length: 4),
              becomes: "***word***")

        // P3-04, second half: an empty selection can only ever add.
        check("empty selection between two stars keeps them", "*", "**", NSRange(location: 1, length: 0),
              becomes: "****", selecting: NSRange(location: 2, length: 0))
        check("empty selection opens a bold pair", "**", "ab", NSRange(location: 1, length: 0),
              becomes: "a****b", selecting: NSRange(location: 3, length: 0))
        check("empty selection inside a code pair keeps it", "`", "``", NSRange(location: 1, length: 0),
              becomes: "````")

        // Edges of the document: the old code built a range starting one marker
        // before the selection and only then asked whether it existed.
        check("selection at the very start", "**", "word", NSRange(location: 0, length: 4),
              becomes: "**word**")
        check("selection at the very end", "*", "a*b*", NSRange(location: 2, length: 1),
              becomes: "ab")
        check("a selection past the end is refused",
              apply("*", to: "abc", selecting: NSRange(location: 2, length: 5)) == nil)

        // Positive control: the sieve above does say "already wrapped" for the
        // one case everything else is measured against.
        check("positive control: one star each side is italic",
              apply("*", to: "*x*", selecting: NSRange(location: 1, length: 1))?.text == "x")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
