// Headless check for what colour a construct ends up in. No frameworks, no fixtures.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
//          Tests/style-check.swift -o /tmp/style-check && /tmp/style-check
//
// The point it defends: colouring emphasis is only safe because the paint goes
// on where the run is *still plain body text*. Bold inside a heading already has
// the heading's colour, a bold link already has the link's, and code inside a
// table row already has code's — paint over any of them and that construct
// silently loses the colour it was given first. That rule is invisible on
// screen until the day somebody drops it.
import AppKit

@main
struct StyleCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    /// The whole pipeline the editor runs: block map, scanner, table pass, style.
    static func styled(_ markdown: String) -> NSTextStorage {
        let ns = markdown as NSString
        let storage = NSTextStorage(string: markdown)
        let map = BlockMap.build(ns)
        var decorations = MarkdownScanner.decorations(text: ns, map: map, lines: 0 ..< map.lines.count)
        decorations += MarkdownTables.decorations(text: ns, map: map, lines: 0 ..< map.lines.count,
                                                  existing: decorations)
        MarkdownStyle.apply(decorations, to: storage, resetting: NSRange(location: 0, length: ns.length))
        return storage
    }

    /// The colour on the first character of `word`.
    static func colour(of word: String, in markdown: String) -> NSColor? {
        let storage = styled(markdown)
        let at = (markdown as NSString).range(of: word).location
        guard at != NSNotFound else { return nil }
        return storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
    }

    static func font(of word: String, in markdown: String) -> NSFont? {
        let storage = styled(markdown)
        let at = (markdown as NSString).range(of: word).location
        guard at != NSNotFound else { return nil }
        return storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
    }

    static func check(_ name: String, _ word: String, in markdown: String, is expected: NSColor) {
        let got = colour(of: word, in: markdown)
        check(name, got == expected, "got \(got?.description ?? "nil"), wanted \(expected.description)")
    }

    static func main() {
        // Positive control: an ordinary word is left alone, so every "is
        // coloured" below means something.
        check("a plain paragraph keeps the label colour", "paragraph", in: "A plain paragraph.",
              is: .labelColor)

        // The colours P2-10 asked for.
        check("bold is coloured", "bold", in: "A **bold** word.", is: MarkdownStyle.Palette.emphasis!)
        check("italic is coloured", "slanted", in: "A *slanted* word.", is: MarkdownStyle.Palette.emphasis!)
        check("a heading is coloured", "Heading", in: "# Heading", is: MarkdownStyle.Palette.heading(1))
        check("code is coloured", "swift", in: "Run `swift build` now.", is: MarkdownStyle.Palette.code!)
        check("a raw table row is coloured", "alpha", in: "| alpha | beta |\n|---|---|\n| c | d |",
              is: MarkdownStyle.Palette.tableRow!)

        // The rule itself: emphasis never paints over a colour that is already
        // there. Each of these was the reason bold and italic stayed grey.
        let heading = "# Heading with **bold** inside"
        check("bold inside a heading keeps the heading colour", "bold", in: heading,
              is: MarkdownStyle.Palette.heading(1))
        // ...and is genuinely bold there, so the check above cannot pass just
        // because the emphasis was never seen.
        let boldInHeading = font(of: "bold", in: heading)
        check("bold inside a heading is still bold and heading-sized",
              boldInHeading?.fontDescriptor.symbolicTraits.contains(.bold) == true
                  && (boldInHeading?.pointSize ?? 0) > MarkdownStyle.bodySize,
              "got \(boldInHeading?.description ?? "nil")")

        check("a bold link keeps the link colour", "label", in: "**[label](https://example.dev)**",
              is: .linkColor)
        check("code inside a table row keeps the code colour", "swift",
              in: "| `swift` | beta |\n|---|---|\n| c | d |", is: MarkdownStyle.Palette.code!)
        check("a link inside a table row keeps the link colour", "label",
              in: "| [label](https://example.dev) | beta |\n|---|---|\n| c | d |", is: .linkColor)

        // A block quote dims its whole line before the emphasis inside it is
        // reached, and that dimming is the point of a quote.
        check("bold inside a quote keeps the quote colour", "word",
              in: "> quoted **word** here", is: .secondaryLabelColor)

        // The three looks. Switching one on has to change what `apply` writes,
        // or the picker in Settings is a control that does nothing — which is
        // exactly what `bodySize` was before 0.2.2.
        func use(_ look: MarkdownStyle.Look) {
            UserDefaults.standard.set(look.rawValue, forKey: MarkdownStyle.Appearance.lookKey)
            MarkdownStyle.Appearance.reload()
        }
        defer {
            UserDefaults.standard.removeObject(forKey: MarkdownStyle.Appearance.lookKey)
            MarkdownStyle.Appearance.reload()
        }

        use(.xcode)
        // 🔴 The measured half of this file. Every number below is a key from
        // Xcode's own `Default (Dark).xccolortheme`, where body text is 10 pt —
        // so a size is checked as a *ratio* against `bodySize`, which the reader
        // can change. If one of these ever fails, read the theme file again
        // before touching the constant: the point of the look is that it is
        // copied, not tuned by eye.
        check("Like Xcode: headings invent no colour", "Heading", in: "# Heading",
              is: MarkdownStyle.Palette.text)
        check("Like Xcode: bold invents no colour", "bold", in: "A **bold** word.",
              is: MarkdownStyle.Palette.text)
        check("Like Xcode: code keeps its colour", "swift", in: "Run `swift build` now.",
              is: MarkdownStyle.Palette.code!)
        // Positive control for the two checks above: "no invented colour" under
        // this look is Xcode's own white, *not* `labelColor` — which is white at
        // 0.85 and reads a shade grey beside the real thing. Without this, both
        // checks would pass just as well if the palette had never changed.
        check("Like Xcode: the body colour is Xcode's, not the system label colour",
              MarkdownStyle.Palette.text != .labelColor)
        // DVTMarkupTextPrimaryHeadingFont 24 / DVTMarkupTextNormalFont 10.
        check("Like Xcode: H1 is 2.4x body",
              font(of: "Heading", in: "# Heading")?.pointSize == (MarkdownStyle.bodySize * 2.4).rounded(),
              "\(font(of: "Heading", in: "# Heading")?.pointSize ?? -1)")
        // DVTMarkupTextSecondaryHeadingFont 18.
        check("Like Xcode: H2 is 1.8x body",
              font(of: "Heading", in: "## Heading")?.pointSize == (MarkdownStyle.bodySize * 1.8).rounded())
        // DVTMarkupTextOtherHeadingFont 14 — one size for level three and below,
        // not a ladder that keeps shrinking.
        check("Like Xcode: H3 and H4 are the same 1.4x body",
              font(of: "Heading", in: "### Heading")?.pointSize == (MarkdownStyle.bodySize * 1.4).rounded()
              && font(of: "Heading", in: "#### Heading")?.pointSize
                 == (MarkdownStyle.bodySize * 1.4).rounded())
        // The fonts are `.AppleSystemUIFont`, not the Bold variant.
        check("Like Xcode: a heading is not bold",
              font(of: "Heading", in: "# Heading")?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        // DVTMarkupTextOtherHeadingColor — white at half alpha, where H1 is at
        // full. Compared by alpha rather than by identity: the colour is dynamic.
        check("Like Xcode: H3 is dimmer than H1",
              (colour(of: "Heading", in: "### Heading")?.usingColorSpace(.sRGB)?.alphaComponent ?? 1) < 0.75)
        // DVTMarkupTextCodeFont 10 — the same size as body, where MarkRead's own
        // look sets code a point smaller.
        check("Like Xcode: code is the same size as body",
              font(of: "swift", in: "Run `swift build` now.")?.pointSize == MarkdownStyle.bodySize)
        // Not from the theme file — that has no spacing key. From
        // `SourceEditorLayoutManager.calculateLineSpacing`: Xcode renders
        // markdown in the source editor, one source line per line, and adds
        // `ceil(font.leading)` and nothing else. The gap between two blocks is
        // the blank line in the file, which this program also has.
        check("Like Xcode: no invented paragraph spacing",
              MarkdownStyle.paragraph.paragraphSpacing == 0,
              "\(MarkdownStyle.paragraph.paragraphSpacing)")
        check("Like Xcode: line spacing is the font's own leading",
              MarkdownStyle.paragraph.lineSpacing == ceil(MarkdownStyle.body.leading),
              "\(MarkdownStyle.paragraph.lineSpacing)")
        // Xcode's theme has no blockquote key at all — a quote is prose, and the
        // dimmed `>` in front is what tells it apart.
        check("Like Xcode: a quote is not dimmed", "Ważne", in: "> Ważne: coś tam",
              is: MarkdownStyle.Palette.text)

        use(.plain)
        check("Plain: headings carry no colour", "Heading", in: "# Heading", is: .labelColor)
        check("Plain: code carries no colour", "swift", in: "Run `swift build` now.", is: .labelColor)
        check("Plain: a link still carries one", "label", in: "[label](https://example.dev)",
              is: .linkColor)
        check("Plain: a heading is still bigger than body text",
              (font(of: "Heading", in: "# Heading")?.pointSize ?? 0) > MarkdownStyle.bodySize)

        use(.markRead)
        check("switching back restores the accent", "Heading", in: "# Heading",
              is: MarkdownStyle.Palette.heading(1))
        // Positive control for the two spacing checks above: MarkRead's own look
        // still sets its own spacing, so "zero" under Xcode is a decision and
        // not a value that went missing everywhere.
        check("MarkRead keeps its own paragraph spacing",
              MarkdownStyle.paragraph.paragraphSpacing == 6)
        check("MarkRead keeps a dimmed quote", "Ważne", in: "> Ważne: coś tam",
              is: .secondaryLabelColor)

        // The code face. Every family the picker offers has to be fixed-pitch,
        // and anything else has to be refused rather than merely not offered —
        // a raw markdown table is aligned by hand with spaces, so a proportional
        // face turns its columns back into ragged text.
        func useCodeFamily(_ name: String) {
            UserDefaults.standard.set(name, forKey: MarkdownStyle.Appearance.monoFamilyKey)
            MarkdownStyle.Appearance.reload()
        }
        defer {
            UserDefaults.standard.removeObject(forKey: MarkdownStyle.Appearance.monoFamilyKey)
            MarkdownStyle.Appearance.reload()
        }

        check("the default code face is fixed-pitch",
              MarkdownStyle.isFixedPitch(MarkdownStyle.mono),
              MarkdownStyle.mono.description)
        check("every offered family is fixed-pitch",
              !MarkdownStyle.monospacedFamilies.isEmpty
                  && MarkdownStyle.monospacedFamilies.allSatisfy { family in
                      guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]),
                                              size: 12) else { return false }
                      return MarkdownStyle.isFixedPitch(font)
                  },
              MarkdownStyle.monospacedFamilies.joined(separator: ", "))

        if let offered = MarkdownStyle.monospacedFamilies.first {
            useCodeFamily(offered)
            check("a chosen fixed-pitch family reaches the code font",
                  MarkdownStyle.mono.familyName == offered,
                  "got \(MarkdownStyle.mono.familyName ?? "nil"), wanted \(offered)")
            check("code is set in the chosen face",
                  font(of: "swift", in: "Run `swift build` now.")?.familyName == offered)
            check("a raw table row is set in it too",
                  font(of: "alpha", in: "| alpha | beta |\n|---|---|\n| c | d |")?.familyName == offered)
            check("body text is not", font(of: "word", in: "A word.")?.familyName != offered)
        }

        // The one that matters: a proportional family written straight into the
        // plist must not reach the code font.
        useCodeFamily("Helvetica")
        check("a proportional family is refused", MarkdownStyle.monoFamily == nil,
              "got \(MarkdownStyle.monoFamily ?? "nil")")
        check("and the code font stays fixed-pitch",
              MarkdownStyle.isFixedPitch(MarkdownStyle.mono), MarkdownStyle.mono.description)
        useCodeFamily("")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
