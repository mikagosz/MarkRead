// Headless check that every construct comes out in the hex the palette names.
//
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
//          Tests/palette-check.swift -o /tmp/palette-check && /tmp/palette-check
//
// Written because a look cannot be checked on a file that has nothing in it: a
// `.swift` file opened in a markdown reader shows no headings, no emphasis and
// no table, so every construct comes out in body colour and the palette looks
// like it never arrived. `Tests/Fixtures/palette.md` puts all of them on one
// page; this reads the colours back out of the styled text and compares them
// with the hex values in `MarkdownStyle.ClaudeTheme`.
//
// 🔴 Run under the **light** appearance on purpose. `claudeDark` is a theme and
// keeps its dark colours whatever the Mac is set to, so a construct that quietly
// reaches past the palette for a system colour — `tertiaryLabelColor` and
// friends — comes out dark-on-dark and is caught here. Five did, when this was
// first run: the markers, front matter, the rule and both task markers.
import AppKit

@main
struct PaletteCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    static func styled(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage(string: markdown)
        let text = storage.string as NSString
        let map = BlockMap.build(text)
        let whole = 0 ..< map.lines.count
        var decorations = MarkdownScanner.decorations(text: text, map: map, lines: whole)
        decorations += MarkdownTables.decorations(text: text, map: map, lines: whole,
                                                  existing: decorations)
        MarkdownStyle.apply(decorations, to: storage,
                            resetting: NSRange(location: 0, length: storage.length))
        return storage
    }

    /// The colour the first occurrence of `word` ended up in, as `#RRGGBB`.
    static func hex(of word: String, in storage: NSTextStorage) -> String? {
        let range = (storage.string as NSString).range(of: word)
        guard range.location != NSNotFound,
              let colour = storage.attribute(.foregroundColor, at: range.location,
                                             effectiveRange: nil) as? NSColor,
              let srgb = colour.usingColorSpace(.sRGB)
        else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()))
    }

    static func main() {
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { run() }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() {
        UserDefaults.standard.set(MarkdownStyle.Look.claudeDark.rawValue,
                                  forKey: MarkdownStyle.Appearance.lookKey)
        MarkdownStyle.Appearance.reload()
        defer {
            UserDefaults.standard.removeObject(forKey: MarkdownStyle.Appearance.lookKey)
            MarkdownStyle.Appearance.reload()
        }

        guard let markdown = try? String(contentsOfFile: "Tests/Fixtures/palette.md",
                                         encoding: .utf8) else {
            check("the fixture is readable", false); return
        }
        let storage = styled(markdown)

        // Word to find → the hex it must come out in. Every value here is from
        // ClaudeDarkTheme.swift; none of them is a measurement of what the code
        // happens to do.
        let expected: [(String, String, String)] = [
            ("Body text",        "#ECECEC", "cdTextPrimary"),
            ("Heading one",      "#F5F5F5", "cdHeading1"),
            ("Heading two",      "#EDEDED", "cdHeading2"),
            ("Heading three",    "#E3E3E3", "cdHeading3"),
            ("Heading four",     "#D6D6D6", "cdHeadingRest"),
            ("Heading five",     "#D6D6D6", "cdHeadingRest (same as four)"),
            ("bold text",        "#FFFFFF", "cdBold"),
            ("inline code",      "#E8977B", "cdInlineCodeText"),
            ("struck out",       "#8A8A8A", "cdStrikethrough"),
            ("real link",        "#6BAAF7", "cdLink"),
            ("Wiki Link",        "#6BAAF7", "cdLink"),
            ("A blockquote",     "#B0B0B0", "cdBlockquoteText"),
            ("!warning",         "#DA7756", "cdAccent"),
            ("A fenced block",   "#E0E0E0", "cdCodeText"),
            ("swift",            "#9CDCA4", "cdCodeString, the language name"),
            ("title:",           "#7A7A7A", "cdTextMuted, front matter"),
            ("---",              "#7A7A7A", "cdTextMuted, the rule — see Palette.rule"),
        ]
        for (word, want, key) in expected {
            let got = hex(of: word, in: storage)
            check("\(key.padding(toLength: 34, withPad: " ", startingAt: 0)) \(want)",
                  got == want, "got \(got ?? "nil") for “\(word)”")
        }

        check("cdItalic                           #D8D8D8",
              hex(of: "italic text", in: storage) == "#D8D8D8",
              "got \(hex(of: "italic text", in: storage) ?? "nil")")

        // 🔴 The point of running under the light appearance. Any construct still
        // reaching for a system colour resolves dark here, on this theme's dark
        // ground.
        let ground = MarkdownStyle.Palette.editorBackground.usingColorSpace(.sRGB)!
        for (word, label) in [("title:", "front matter"), ("[x]", "a done task"),
                              ("[ ]", "an open task"), ("---", "the horizontal rule")] {
            let range = (storage.string as NSString).range(of: word)
            guard range.location != NSNotFound,
                  let colour = (storage.attribute(.foregroundColor, at: range.location,
                                                  effectiveRange: nil) as? NSColor)?
                      .usingColorSpace(.sRGB) else { continue }
            check("\(label) is readable on this theme's ground under a light Mac",
                  colour.brightnessComponent - ground.brightnessComponent > 0.15,
                  "text \(colour.brightnessComponent) vs ground \(ground.brightnessComponent)")
        }
    }
}
