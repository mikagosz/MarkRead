import Foundation

/// Turns raw markdown into a list of `Decoration`s over the *same* character
/// offsets.
///
/// Pure and `nonisolated` on purpose: it takes a string, returns value types,
/// touches no UI, and can therefore be compiled and exercised on its own with
/// `swiftc` (see `Tests/scanner-check.swift`).
nonisolated enum MarkdownScanner {

    // MARK: - Patterns
    //
    // Compiled once and shared. NSRegularExpression is Sendable in this SDK, so
    // these need no isolation annotation — the compiler rejects one as redundant.

    private static func re(_ pattern: String) -> NSRegularExpression {
        // Force-try: these are literals fixed at compile time. A bad one is a
        // programmer error that must fail loudly on the first run, not silently
        // disable a piece of highlighting.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let escapeRE = re(#"\\[\\`*_{}\[\]()#+\-.!~=|>]"#)
    private static let codeSpanRE = re(#"(`+)([^`\n]+?)(\1)"#)
    private static let imageRE = re(#"(!\[)([^\]\n]*)(\]\()([^)\s]+)((?:\s+"[^"\n]*")?\))"#)
    private static let linkRE = re(#"(\[)([^\]\n]+)(\]\()([^)\s]+)((?:\s+"[^"\n]*")?\))"#)
    /// GFM autolink: `<https://example.com>`. The angle brackets are syntax and
    /// have no business being on screen.
    private static let autolinkRE = re(#"(<)((?:https?|mailto|ftp):[^>\s]+)(>)"#)
    private static let wikiRE = re(#"(\[\[)([^\[\]\n|]+)(?:\|([^\[\]\n]+))?(\]\])"#)
    private static let boldItalicRE = re(#"(\*\*\*)(?!\s)([^*\n]+?)(?<!\s)(\*\*\*)"#)
    private static let boldStarRE = re(#"(?<!\*)(\*\*)(?!\s)((?:[^*\n]|\*(?!\*))+?)(?<!\s)(\*\*)(?!\*)"#)
    private static let boldUnderRE = re(#"(?<![\w_])(__)(?!\s)([^\n]+?)(?<!\s)(__)(?![\w_])"#)
    private static let italicStarRE = re(#"(?<![*\w])(\*)(?!\s)([^*\n]+?)(?<!\s)(\*)(?![*\w])"#)
    private static let italicUnderRE = re(#"(?<![\w_])(_)(?!\s)([^_\n]+?)(?<!\s)(_)(?![\w_])"#)
    private static let strikeRE = re(#"(~~)(?!\s)([^\n]+?)(?<!\s)(~~)"#)
    private static let highlightRE = re(#"(==)(?!\s)([^\n]+?)(?<!\s)(==)"#)

    private static let headingRE = re(#"^(#{1,6})([ \t]+)(.*)$"#)
    private static let quoteRE = re(#"^([ \t]*>+[ \t]?)"#)
    private static let calloutRE = re(#"^(\[!\w+\][-+]?)(.*)$"#)
    private static let taskRE = re(#"^([ \t]*)([-*+])([ \t]+)(\[[ xX]\])([ \t]+)"#)
    private static let listRE = re(#"^([ \t]*)([-*+]|\d+[.)])([ \t]+)"#)
    private static let ruleRE = re(#"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)

    private static let detector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: - Entry point

    /// Decorations for the lines of `map` whose index falls in `lines`.
    ///
    /// Callers pass only the lines they are about to draw. Highlighting the whole
    /// document on every keystroke is what makes editors like this feel slow, and
    /// nothing here needs it: block context already arrived in `map`.
    static func decorations(text: NSString, map: BlockMap, lines: Range<Int>) -> [Decoration] {
        var out: [Decoration] = []
        let clamped = max(0, lines.lowerBound) ..< min(map.lines.count, lines.upperBound)
        for index in clamped {
            let (lineRange, kind) = map.lines[index]
            guard lineRange.length > 0 else { continue }
            scan(line: lineRange, kind: kind, text: text, into: &out)
        }
        return out
    }

    // MARK: - One line

    private static func scan(line lineRange: NSRange, kind: BlockMap.Kind,
                             text: NSString, into out: inout [Decoration]) {
        // Trailing newline is never decorated: a background colour on it paints a
        // stripe to the end of the line fragment and looks like a rendering bug.
        var content = lineRange
        while content.length > 0 {
            let last = text.character(at: NSMaxRange(content) - 1)
            guard last == 10 || last == 13 else { break }
            content.length -= 1
        }
        guard content.length > 0 else { return }

        switch kind {
        case .frontMatter:
            out.append(Decoration(range: content, style: .frontMatter))
            return
        case .code:
            out.append(Decoration(range: content, style: .codeBlock))
            return
        case .fence:
            out.append(Decoration(range: content, style: .codeBlock))
            // Xcode's preview shows a box and a language name, never the
            // backticks that produced them. They are hidden the way every other
            // marker is — glyphs suppressed, characters untouched, and the caret
            // on that line brings them back.
            let (run, info) = fenceParts(text, content)
            if let run { out.append(Decoration(range: run, style: .hiddenMarker)) }
            if let info { out.append(Decoration(range: info, style: .infoString)) }
            return
        case .normal:
            break
        }

        if ruleRE.firstMatch(in: text as String, range: content) != nil {
            out.append(Decoration(range: content, style: .rule))
            return
        }

        var inline = content

        // Blockquote / Obsidian callout. The prefix is a marker, the rest reads
        // as quoted text and can still hold links and emphasis.
        if let m = quoteRE.firstMatch(in: text as String, range: inline) {
            let prefix = m.range(at: 1)
            out.append(Decoration(range: prefix, style: .marker))
            let rest = NSRange(location: NSMaxRange(prefix),
                               length: NSMaxRange(inline) - NSMaxRange(prefix))
            out.append(Decoration(range: rest, style: .quote))
            if let c = calloutRE.firstMatch(in: text as String, range: rest) {
                out.append(Decoration(range: c.range(at: 1), style: .calloutLabel))
            }
            inline = rest
        }

        if let m = headingRE.firstMatch(in: text as String, range: inline) {
            let hashes = m.range(at: 1)
            let level = hashes.length
            out.append(Decoration(range: NSUnionRange(hashes, m.range(at: 2)), style: .hiddenMarker))
            let body = m.range(at: 3)
            out.append(Decoration(range: body, style: .heading(level)))
            inline = body
        } else if let m = taskRE.firstMatch(in: text as String, range: inline) {
            out.append(Decoration(range: m.range(at: 2), style: .listMarker))
            let box = m.range(at: 4)
            let checked = text.substring(with: box).lowercased().contains("x")
            out.append(Decoration(range: box, style: .taskMarker(checked)))
            let start = NSMaxRange(m.range(at: 5))
            inline = NSRange(location: start, length: NSMaxRange(inline) - start)
        } else if let m = listRE.firstMatch(in: text as String, range: inline) {
            out.append(Decoration(range: m.range(at: 2), style: .listMarker))
            let start = NSMaxRange(m.range(at: 3))
            inline = NSRange(location: start, length: NSMaxRange(inline) - start)
        } else if text.substring(with: inline).trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            // Monospaced so the columns of a hand-aligned table line up.
            out.append(Decoration(range: inline, style: .tableRow))
        }

        guard inline.length > 0 else { return }
        scanInline(inline, text: text, into: &out)
    }

    // MARK: - Inline markup

    private static func scanInline(_ region: NSRange, text: NSString, into out: inout [Decoration]) {
        var claimed = [Bool](repeating: false, count: region.length)
        let origin = region.location
        let source = text as String

        func isFree(_ r: NSRange) -> Bool {
            let start = r.location - origin
            guard start >= 0, start + r.length <= claimed.count else { return false }
            for i in start ..< (start + r.length) where claimed[i] { return false }
            return true
        }
        /// True when everything already claimed inside `outer` lies within `inner`.
        func claimedOnlyInside(_ outer: NSRange, _ inner: NSRange) -> Bool {
            let start = outer.location - origin
            guard start >= 0, start + outer.length <= claimed.count else { return false }
            for offset in start ..< (start + outer.length) where claimed[offset] {
                let absolute = offset + origin
                guard NSLocationInRange(absolute, inner) else { return false }
            }
            return true
        }
        func take(_ r: NSRange) {
            let start = r.location - origin
            guard start >= 0, start + r.length <= claimed.count else { return }
            for i in start ..< (start + r.length) { claimed[i] = true }
        }

        /// Runs one pattern, ignoring matches that overlap something already
        /// decorated. Precedence is therefore just call order below.
        func pass(_ regex: NSRegularExpression, _ handle: (NSTextCheckingResult) -> [Decoration]) {
            for m in regex.matches(in: source, range: region) where isFree(m.range) {
                out.append(contentsOf: handle(m))
                take(m.range)
            }
        }

        // Escapes go first and are claimed but undecorated, so that a `\*` can
        // never open emphasis.
        // SHORTCUT: claiming the whole match means a legitimate emphasis run that
        // *overlaps* an escape is dropped rather than parsed. Way out is a real
        // inline parser; not worth it until a real file trips on it.
        for m in escapeRE.matches(in: source, range: region) where isFree(m.range) {
            take(m.range)
        }

        pass(codeSpanRE) { m in
            [Decoration(range: m.range(at: 1), style: .hiddenMarker),
             Decoration(range: m.range(at: 2), style: .code),
             Decoration(range: m.range(at: 3), style: .hiddenMarker)]
        }
        // Links are allowed to overlap what the code-span pass already claimed,
        // as long as the overlap sits inside the link's own label. Without this
        // exception a link whose text is code — `[`START-TUTAJ.md`](…)`, a shape
        // that turns up constantly in real notes — was rejected wholesale and
        // silently stopped being a link. Found by the swift-markdown oracle.
        func passLink(_ regex: NSRegularExpression) {
            for m in regex.matches(in: source, range: region) {
                let label = m.range(at: 2)
                guard isFree(m.range) || claimedOnlyInside(m.range, label) else { continue }
                out.append(contentsOf: [
                    Decoration(range: m.range(at: 1), style: .hiddenMarker),
                    Decoration(range: label, style: .link(text.substring(with: m.range(at: 4)))),
                    Decoration(range: NSUnionRange(m.range(at: 3), m.range(at: 5)), style: .hiddenMarker),
                ])
                take(m.range)
            }
        }
        passLink(imageRE)
        passLink(linkRE)
        pass(autolinkRE) { m in
            [Decoration(range: m.range(at: 1), style: .hiddenMarker),
             Decoration(range: m.range(at: 2), style: .link(text.substring(with: m.range(at: 2)))),
             Decoration(range: m.range(at: 3), style: .hiddenMarker)]
        }
        pass(wikiRE) { m in
            let target = text.substring(with: m.range(at: 2))
            let label = m.range(at: 3).location == NSNotFound ? m.range(at: 2) : m.range(at: 3)
            var pieces = [Decoration(range: m.range(at: 1), style: .hiddenMarker),
                          Decoration(range: label, style: .wikiLink(target)),
                          Decoration(range: m.range(at: 4), style: .hiddenMarker)]
            if m.range(at: 3).location != NSNotFound {
                // "[[target|label]]" — the target half is plumbing. Hide it up to
                // and including the "|", which sits between the two capture
                // groups and so belongs to neither.
                let target = m.range(at: 2)
                let upToPipe = NSRange(location: target.location,
                                       length: m.range(at: 3).location - target.location)
                pieces.insert(Decoration(range: upToPipe, style: .hiddenMarker), at: 1)
            }
            return pieces
        }

        let emphasis: [(NSRegularExpression, Decoration.Style)] = [
            (boldItalicRE, .boldItalic),
            (boldStarRE, .bold),
            (boldUnderRE, .bold),
            (italicStarRE, .italic),
            (italicUnderRE, .italic),
            (strikeRE, .strikethrough),
            (highlightRE, .highlight),
        ]
        for (regex, style) in emphasis {
            pass(regex) { m in
                [Decoration(range: m.range(at: 1), style: .hiddenMarker),
                 Decoration(range: m.range(at: 2), style: style),
                 Decoration(range: m.range(at: 3), style: .hiddenMarker)]
            }
        }

        // Bare URLs last, over whatever is left. Anything already inside a link
        // or a code span has been claimed above, so this cannot double-decorate.
        if let detector {
            for m in detector.matches(in: source, range: region) {
                guard isFree(m.range), let url = m.url else { continue }
                out.append(Decoration(range: m.range, style: .link(url.absoluteString)))
                take(m.range)
            }
        }
    }

    /// A fence line split into its run of backticks (or tildes) and the
    /// language name after it.
    ///
    /// A closing fence carries nothing after its run, so the second half comes
    /// back nil there without this needing to know which of the two it is
    /// looking at.
    private static func fenceParts(_ text: NSString, _ line: NSRange) -> (NSRange?, NSRange?) {
        var index = line.location
        let end = NSMaxRange(line)
        while index < end, isBlank(text.character(at: index)) { index += 1 }
        guard index < end else { return (nil, nil) }
        let marker = text.character(at: index)
        guard marker == 96 || marker == 126 else { return (nil, nil) }   // ` or ~
        let runStart = index
        while index < end, text.character(at: index) == marker { index += 1 }
        let run = NSRange(location: runStart, length: index - runStart)

        while index < end, isBlank(text.character(at: index)) { index += 1 }
        var last = end
        while last > index, isBlank(text.character(at: last - 1)) { last -= 1 }
        guard last > index else { return (run, nil) }
        return (run, NSRange(location: index, length: last - index))
    }

    private static func isBlank(_ char: unichar) -> Bool { char == 32 || char == 9 }

}
