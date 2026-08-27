import Foundation

/// Where a piece of markdown sits and how it should look.
///
/// The scanner never rewrites text. It only reports ranges into the *raw*
/// markdown, so the buffer the user edits stays byte-for-byte the file on disk.
/// That is the whole design: there is no second representation to fall out of
/// sync with, and nothing to serialize back.
nonisolated struct Decoration: Equatable {
    nonisolated enum Style: Equatable {
        /// Syntax punctuation that stays on screen, dimmed: the `>` of a quote,
        /// a list bullet, a horizontal rule.
        case marker
        /// Syntax punctuation that is *not drawn* while the caret is elsewhere:
        /// heading hashes, emphasis stars, backticks, and above all the
        /// `](https://…)` half of a link.
        ///
        /// The characters stay in the buffer and in the file — only their glyphs
        /// are suppressed. Put the caret on the line and they come back, which is
        /// how you edit them. Hiding is why a table of links is readable at all:
        /// the URLs are usually longer than the row they belong to.
        case hiddenMarker
        case heading(Int)
        case bold
        case italic
        case boldItalic
        case strikethrough
        case highlight
        /// Inline code span or a line inside a fenced block.
        case code
        /// A line inside a fenced block, or one of its fences.
        ///
        /// Separate from `code` for one reason: an inline span paints its own
        /// background, a block must **not**. The block's background is a drawn
        /// box, and a per-run background under it paints a second, differently
        /// shaped rectangle that shows as a strip sticking out of the box.
        case codeBlock
        /// The language name on a fence line — ```` ```swift ````. Xcode is the
        /// only look that colours it; everywhere else it stays code-coloured.
        case infoString
        case link(String)
        case wikiLink(String)
        case listMarker
        case taskMarker(Bool)
        case quote
        case calloutLabel
        case frontMatter
        case tableRow
        /// Padding after this character, measured in monospaced character
        /// widths, so the next column starts where it should.
        ///
        /// This is how tables line up without a single character being inserted:
        /// the padding is a `.kern` attribute, not a run of spaces. Spaces would
        /// have to be written back to the file.
        case tableCellPad(Int)
        case rule
    }

    let range: NSRange
    let style: Style
}

/// Line-level classification of the document, computed in one linear pass.
///
/// Fenced code and YAML front matter are the only constructs whose meaning
/// depends on lines far above, so they are the only thing that needs a
/// whole-document scan. Everything else is decided from the line itself, which
/// is what keeps re-highlighting cheap enough to run on every keystroke.
///
/// Deliberately allocation-free: the classification reads characters straight
/// out of the NSString instead of building a String per line. On a 20 000-line
/// file that is the difference between a rebuild you can do on every keystroke
/// and one you cannot.
nonisolated struct BlockMap {
    nonisolated enum Kind: Equatable {
        case normal
        case fence          // the ``` line itself
        case code           // inside a fenced block
        case frontMatter    // inside (or on the --- of) YAML front matter
    }

    /// One entry per line, in document order.
    let lines: [(range: NSRange, kind: Kind)]
    /// True when a front-matter block was opened and never closed — see `build`.
    let openFrontMatter: Bool

    static func build(_ text: NSString) -> BlockMap {
        let first = build(text, allowFrontMatter: true)
        // An opening "---" that never closes is not front matter, it is a
        // horizontal rule on line 1. Without this second pass the whole file
        // would render as dimmed metadata.
        if first.openFrontMatter { return build(text, allowFrontMatter: false) }
        return first
    }

    private static func build(_ text: NSString, allowFrontMatter: Bool) -> BlockMap {
        var result: [(NSRange, Kind)] = []
        result.reserveCapacity(max(16, text.length / 40))
        var location = 0
        var inFence = false
        var fenceChar: unichar = 0
        var fenceCount = 0
        var inFrontMatter = false
        var lineIndex = 0

        // `location < length`, plus the no-progress guard below. Asking
        // `lineRange(for:)` about the position one past the last character of a
        // file that does not end in a newline hands back the *last line* again,
        // not an empty range there — so a loop keyed on `<=` never advances.
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            // Fences live inside blockquotes too — "> ```bash" opens a code block
            // just as "```bash" does. Stripping the quote markers first is what
            // makes those blocks come out as code instead of prose. Found by the
            // swift-markdown oracle on real notes.
            let core = unquoted(text, trimmed(text, lineRange))

            var kind: Kind = .normal

            if allowFrontMatter, lineIndex == 0, isRun(text, core, of: 0x2D, exactly: 3) {
                inFrontMatter = true
                kind = .frontMatter
            } else if inFrontMatter {
                kind = .frontMatter
                if isRun(text, core, of: 0x2D, exactly: 3) || isRun(text, core, of: 0x2E, exactly: 3) {
                    inFrontMatter = false
                }
            } else if inFence {
                if leadingRun(text, core, of: fenceChar) >= fenceCount {
                    inFence = false
                    kind = .fence
                } else {
                    kind = .code
                }
            } else if let (char, count) = openingFence(text, core) {
                inFence = true
                fenceChar = char
                fenceCount = count
                kind = .fence
            }

            result.append((lineRange, kind))
            lineIndex += 1

            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
        return BlockMap(lines: result, openFrontMatter: inFrontMatter)
    }

    // MARK: - Character helpers (no allocation)

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// `line` without surrounding whitespace or line terminators.
    private static func trimmed(_ text: NSString, _ line: NSRange) -> NSRange {
        var start = line.location
        var end = NSMaxRange(line)
        while start < end, isSpace(text.character(at: start)) || isNewline(text.character(at: start)) {
            start += 1
        }
        while end > start {
            let c = text.character(at: end - 1)
            guard isSpace(c) || isNewline(c) else { break }
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// The range without any leading blockquote markers (`>` and the space
    /// after each). Front matter cannot be quoted, so only fences care.
    private static func unquoted(_ text: NSString, _ range: NSRange) -> NSRange {
        var result = range
        while result.length > 0, text.character(at: result.location) == 0x3E {   // >
            result.location += 1
            result.length -= 1
            if result.length > 0, isSpace(text.character(at: result.location)) {
                result.location += 1
                result.length -= 1
            }
        }
        return result
    }

    /// How many `ch` the range starts with.
    private static func leadingRun(_ text: NSString, _ range: NSRange, of ch: unichar) -> Int {
        var n = 0
        while n < range.length, text.character(at: range.location + n) == ch { n += 1 }
        return n
    }

    /// True when the range is exactly `count` copies of `ch` and nothing else.
    private static func isRun(_ text: NSString, _ range: NSRange, of ch: unichar, exactly count: Int) -> Bool {
        range.length == count && leadingRun(text, range, of: ch) == count
    }

    /// ``` or ~~~ (three or more), optionally followed by a language tag.
    private static func openingFence(_ text: NSString, _ core: NSRange) -> (unichar, Int)? {
        for ch: unichar in [0x60, 0x7E] {          // ` and ~
            let run = leadingRun(text, core, of: ch)
            if run >= 3 { return (ch, run) }
        }
        return nil
    }

    /// Index of the first line whose range contains `location`, or the last line.
    /// Returns 0 for an empty map; callers clamp against `lines.count` anyway.
    func lineIndex(containing location: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
