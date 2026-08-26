// Headless check for MarkdownScanner. No frameworks, no fixtures.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift \
//          Tests/scanner-check.swift -o /tmp/scanner-check && /tmp/scanner-check
//
// The point it defends: decorations describe the raw text and never replace it,
// so for every input the character count stays identical and every reported
// range lands inside the document.
import Foundation

@main
struct ScannerCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("ok    \(name)")
        } else {
            failures += 1
            print("FAIL  \(name) \(detail())")
        }
    }

    static func decorations(_ markdown: String) -> (NSString, [Decoration]) {
        let text = markdown as NSString
        let map = BlockMap.build(text)
        return (text, MarkdownScanner.decorations(text: text, map: map, lines: 0 ..< map.lines.count))
    }

    static func styles(_ markdown: String) -> [Decoration.Style] {
        decorations(markdown).1.map(\.style)
    }

    /// The text covered by the first decoration carrying `style`.
    static func covered(_ markdown: String, _ style: Decoration.Style) -> String? {
        let (text, decos) = decorations(markdown)
        guard let d = decos.first(where: { $0.style == style }) else { return nil }
        return text.substring(with: d.range)
    }

    static func main() {
        let corpus = [
            "# Heading with **bold** and [docs](https://example.com)",
            "Run `swift build` in the folder",
            "text with \\* escaped star",
            "~~struck~~ and ==marked==",
            "- [ ] open task\n- [x] done task",
            "> [!warning] Careful\n> second line",
            "| col | col2 |\n| --- | --- |",
            "---\ntags: [a, b]\n---\n\nbody",
            "```swift\nlet x = **not bold**\n```",
            "snake_case_name stays plain",
            "[[Wiki Link]] and [[target|label]]",
            "bare http://127.0.0.1:8765/ping link",
            "",
            "\n\n\n",
        ]

        // 1. Nothing is ever rewritten: the scanner returns ranges only, so the
        //    document it describes is the document it was given.
        for markdown in corpus {
            let (text, decos) = decorations(markdown)
            let inBounds = decos.allSatisfy {
                $0.range.location >= 0 && NSMaxRange($0.range) <= text.length
            }
            check("ranges in bounds: \(markdown.prefix(24).debugDescription)", inBounds)
        }

        // 2. Positive control — the sieve returns one for things that are there.
        check("heading detected", styles("# Title").contains(.heading(1)))
        check("h3 detected", styles("### Title").contains(.heading(3)))
        check("bold detected", styles("a **b** c").contains(.bold))
        check("italic detected", styles("a *b* c").contains(.italic))
        check("code span detected", styles("a `b` c").contains(.code))
        check("strike detected", styles("~~x~~").contains(.strikethrough))
        check("highlight detected", styles("==x==").contains(.highlight))
        check("table row detected", styles("| a | b |").contains(.tableRow))
        // "---" on line 1 opens front matter, so a rule has to be tested lower down.
        check("rule detected", styles("text\n\n---\n").contains(.rule))
        check("unclosed front matter is a rule, not metadata",
              styles("---\n\nplain body\n").contains(.rule))

        // 3. The three constructs NoteM's round-trip destroyed. Here they are
        //    decorated in place, which is why they cannot be lost.
        // Backticks are marked hidden, not removed — they are still characters
        // in the buffer, which `Tests/document-check.swift` proves by bytes.
        check("code span keeps its backticks",
              covered("Run `swift build` now", .hiddenMarker) == "`")
        check("code span content is the command",
              covered("Run `swift build` now", .code) == "swift build")
        check("escaped star is not emphasis",
              !styles("text with \\* star").contains(.italic))
        check("strikethrough content", covered("~~gone~~", .strikethrough) == "gone")

        // 4. Things that must NOT be styled.
        check("snake_case is not italic", !styles("my_var_name here").contains(.italic))
        check("fence body is code, not bold",
              !styles("```\nlet x = **a**\n```").contains(.bold))
        check("front matter is not a rule",
              styles("---\ntags: x\n---\n").allSatisfy { $0 == .frontMatter })

        // 5. Links — the reason this program exists.
        check("markdown link target",
              styles("[docs](https://example.com)").contains(.link("https://example.com")))
        check("link label is what gets clicked",
              covered("[docs](https://example.com)", .link("https://example.com")) == "docs")
        check("bare url detected",
              styles("see http://127.0.0.1:8765 now").contains(.link("http://127.0.0.1:8765")))
        check("url inside code span is not a link",
              !styles("`http://127.0.0.1:8765`").contains(.link("http://127.0.0.1:8765")))
        check("angle autolink is a link",
              styles("see <https://example.com> now").contains(.link("https://example.com")))
        check("angle autolink hides its brackets",
              covered("<https://example.com>", .hiddenMarker) == "<")
        check("angle autolink shows only the url",
              covered("<https://example.com>", .link("https://example.com")) == "https://example.com")
        check("wiki link target", styles("[[Note]]").contains(.wikiLink("Note")))
        check("piped wiki link keeps target",
              styles("[[Target|Label]]").contains(.wikiLink("Target")))
        check("piped wiki link shows label",
              covered("[[Target|Label]]", .wikiLink("Target")) == "Label")
        // The "|" sits between two capture groups and belongs to neither; if it
        // is not hidden explicitly it shows up as "|Label" on screen.
        check("piped wiki link hides the pipe",
              decorations("[[Target|Label]]").1.contains {
                  $0.style == .hiddenMarker && $0.range.length == "Target|".count
              })

        // 6. Tasks and callouts.
        check("open task", styles("- [ ] thing").contains(.taskMarker(false)))
        check("done task", styles("- [x] thing").contains(.taskMarker(true)))
        check("callout label", covered("> [!warning] Careful", .calloutLabel) == "[!warning]")

        // 7. Line map keeps every character exactly once.
        for markdown in corpus {
            let text = markdown as NSString
            let map = BlockMap.build(text)
            let total = map.lines.reduce(0) { $0 + $1.range.length }
            check("line map covers text: \(markdown.prefix(16).debugDescription)",
                  total == text.length, "got \(total), want \(text.length)")
        }

        // 8. Table rows, asked about a text shorter than the map describing it.
        //
        // Not a hypothetical: AppKit sends a selection notification from inside
        // `endEditing()`, so between replacing the storage and rebuilding the map
        // there is a window in which the map is one document behind the string.
        // Reading a range from the old map then walked off the end of the new one
        // and killed the process.
        let short = "krotki" as NSString
        check("table row test clamps to the live string",
              MarkdownTables.isRow(short, NSRange(location: 40, length: 12)) == false)
        check("table row test clamps a range that starts inside and runs past the end",
              MarkdownTables.isRow(short, NSRange(location: 3, length: 99)) == false)
        // Positive control: the same call does recognise a real row, so the two
        // "false" answers above mean something.
        let row = "  | a | b |\n" as NSString
        check("positive control: a real table row is still recognised",
              MarkdownTables.isRow(row, NSRange(location: 0, length: row.length)))
        check("a paragraph is not a table row",
              MarkdownTables.isRow("zwykly akapit" as NSString, NSRange(location: 0, length: 13)) == false)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
