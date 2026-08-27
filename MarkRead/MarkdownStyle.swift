import AppKit

/// Turns `Decoration`s into text attributes.
///
/// Every style here is *decoration*: it changes how a range looks and never what
/// it says. Nothing in this file inserts, removes or replaces a character, which
/// is why opening a file in MarkRead cannot damage it.
extension NSAttributedString.Key {
    /// Marks a run that is genuinely code, as opposed to one that merely got a
    /// monospaced font for layout reasons (a table row). The table renderer needs
    /// to tell those apart: it swaps rows to a proportional face so words stop
    /// breaking mid-syllable, and must leave real code alone.
    static let markReadCode = NSAttributedString.Key("markReadCode")
}

enum MarkdownStyle {

    /// URL scheme standing in for `[[Wiki Links]]`, which are not real URLs.
    static let wikiScheme = "markread-wiki"

    static func wikiURL(for target: String) -> URL? {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        return URL(string: "\(wikiScheme):\(encoded)")
    }

    static func wikiTarget(from url: URL) -> String? {
        guard url.scheme == wikiScheme else { return nil }
        let rest = String(url.absoluteString.dropFirst(wikiScheme.count + 1))
        return rest.removingPercentEncoding ?? rest
    }


    // MARK: - Xcode's own numbers

    /// Xcode's markdown appearance, read out of Xcode itself.
    ///
    /// Not eyeballed from a screenshot and not invented here: every value below
    /// is a key from
    /// `Xcode.app/Contents/SharedFrameworks/DVTUserInterfaceKit.framework/Resources/`
    /// `FontAndColorThemes/Default (Dark).xccolortheme` and its `(Light)` twin,
    /// under `DVTMarkupText*`. That is the file Xcode renders a `.md` file from,
    /// so matching it is the only thing "looks like Xcode" can honestly mean.
    ///
    /// Xcode sets body text at **10 pt**, so the sizes are kept here as *ratios*
    /// against body rather than as points — the reader picks a size in Settings
    /// and the proportions have to survive it. 24/10, 18/10 and 14/10.
    ///
    /// 🔴 These are copied values. If they are ever wrong, the fix is to read the
    /// theme file again, not to nudge them until a screenshot looks close.
    enum XcodeTheme {
        /// `DVTMarkupTextPrimaryHeadingFont` — 24 pt against a 10 pt body.
        static let h1Scale: CGFloat = 2.4
        /// `DVTMarkupTextSecondaryHeadingFont` — 18 pt.
        static let h2Scale: CGFloat = 1.8
        /// `DVTMarkupTextOtherHeadingFont` — 14 pt, and it is *one* size for
        /// every level from three down, not a ladder.
        static let otherHeadingScale: CGFloat = 1.4
        /// `DVTMarkupTextCodeFont` — 10 pt, the same size as the body. MarkRead's
        /// own look sets code a point smaller; Xcode does not.
        static let codeScale: CGFloat = 1.0

        /// Headings are `.AppleSystemUIFont`, i.e. **regular**. Xcode does not
        /// set them bold; the size is what tells them apart.
        static let headingWeight: NSFont.Weight = .regular

        /// `DVTMarkupTextOtherHeadingColor` — white at half alpha. H1 and H2 are
        /// at full alpha, H3 and below are not.
        static let otherHeadingAlpha: CGFloat = 0.5
        /// `DVTMarkupTextInlineCodeColor` — 70% alpha over the text colour.
        static let codeAlpha: CGFloat = 0.7

        /// `DVTMarkupTextNormalColor`: pure white in the dark theme, pure black
        /// in the light one — *not* `labelColor`, which is white at 0.85.
        static let normal = dynamic(dark: (1, 1, 1, 1), light: (0, 0, 0, 1))
        /// `DVTMarkupTextInlineCodeColor`.
        static let inlineCode = dynamic(dark: (1, 1, 1, codeAlpha), light: (0, 0, 0, codeAlpha))
        /// `DVTMarkupTextLinkColor`.
        static let link = dynamic(dark: (0.33, 0.247124, 0.894195, 1),
                                  light: (0.055, 0.055, 1, 1))
        /// `DVTMarkupTextBackgroundColor` — the fill behind a code block.
        static let markupBackground = dynamic(dark: (0.18856, 0.195, 0.22444, 1),
                                              light: (0.96, 0.96, 0.96, 1))
        /// `DVTMarkupTextBorderColor` — the line around it, and around a table.
        static let markupBorder = dynamic(dark: (0.253475, 0.2594, 0.286485, 1),
                                          light: (0.8832, 0.8832, 0.8832, 1))
        /// `xcode.syntax.string` — the colour Xcode puts on a fenced block's
        /// language name.
        static let infoString = dynamic(dark: (0.989117, 0.41558, 0.365684, 1),
                                        light: (0.77, 0.102, 0.086, 1))

        /// One colour that resolves per appearance, so the light theme's values
        /// are used in light mode instead of being dimmed versions of the dark
        /// ones.
        private static func dynamic(dark: (CGFloat, CGFloat, CGFloat, CGFloat),
                                    light: (CGFloat, CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let c = isDark ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
            }
        }
    }

    // MARK: - Fonts

    /// What the reader picked in Settings, kept in `UserDefaults` and cached in
    /// the two properties below.
    ///
    /// Cached on purpose rather than read on every access: `body`, `mono` and
    /// `heading` are asked for once per decoration, which on a long note is
    /// thousands of times per keystroke.
    /// The three looks a reader can pick between.
    ///
    /// They exist because the same `.md` file carries no appearance of its own:
    /// what a note looks like is invented by whichever program opens it, so
    /// "the same as everywhere else" has to mean "the same as one named
    /// program". Rather than guess which one, MarkRead offers the three that
    /// were actually on the table.
    enum Look: String, CaseIterable, Identifiable {
        /// What MarkRead settled on by itself: the system accent on headings,
        /// colour on emphasis and code.
        case markRead
        /// Xcode's markdown preview, matched against Xcode's own theme file
        /// rather than against a screenshot — see `XcodeTheme`. Three heading
        /// sizes, none of them bold, no colour on emphasis, code in a box.
        case xcode
        /// No colour this program invented. Links keep theirs, headings are told
        /// apart by size, and that is the lot.
        case plain

        var id: String { rawValue }

        var name: String {
            switch self {
            case .markRead: "MarkRead"
            case .xcode: "Like Xcode"
            case .plain: "Plain"
            }
        }

        var detail: String {
            switch self {
            case .markRead: "Headings in the system accent, emphasis and code coloured."
            case .xcode: "Matched to Xcode's own theme: three heading sizes, no bold, code in a box."
            case .plain: "No colour except links. Headings differ by size only."
            }
        }
    }

    enum Appearance {
        static let sizeKey = "bodySize"
        static let familyKey = "bodyFontFamily"
        static let monoFamilyKey = "codeFontFamily"
        static let lookKey = "look"
        static let defaultSize: Double = 15
        static let sizeRange: ClosedRange<Double> = 11 ... 28

        /// Posted when either setting changes. The open editor listens, because
        /// every column width and every laid-out table it holds was measured for
        /// the font that has just been replaced.
        static let didChange = Notification.Name("MarkReadAppearanceDidChange")

        static func reload() {
            MarkdownStyle.bodySize = storedSize()
            MarkdownStyle.bodyFamily = storedFamily()
            MarkdownStyle.monoFamily = storedMonoFamily()
            MarkdownStyle.look = storedLook()
            NotificationCenter.default.post(name: didChange, object: nil)
        }

        static func storedLook() -> Look {
            guard let raw = UserDefaults.standard.string(forKey: lookKey),
                  let look = Look(rawValue: raw) else { return .markRead }
            return look
        }

        /// The stored size, or the default when nothing is stored. Clamped, so a
        /// value written into the plist by hand cannot leave the app unreadable.
        static func storedSize() -> CGFloat {
            let stored = UserDefaults.standard.double(forKey: sizeKey)
            guard stored > 0 else { return CGFloat(defaultSize) }
            return CGFloat(min(max(stored, sizeRange.lowerBound), sizeRange.upperBound))
        }

        /// The stored face for code, or nil for the system monospaced one.
        ///
        /// 🔴 A family that is not fixed-pitch is refused here, not merely
        /// discouraged in the picker. A markdown table shown as raw text is
        /// aligned by hand with spaces: give it a proportional face and its
        /// columns stop being columns. The picker offers only fixed-pitch
        /// families; this is what stops a value typed straight into the plist,
        /// or a family that changed since it was chosen, from doing the damage
        /// anyway.
        static func storedMonoFamily() -> String? {
            guard let name = UserDefaults.standard.string(forKey: monoFamilyKey), !name.isEmpty,
                  let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: name]),
                                    size: 12),
                  MarkdownStyle.isFixedPitch(font)
            else { return nil }
            return name
        }

        /// The stored family, or nil for the system font. A family that has been
        /// uninstalled since it was chosen counts as nil rather than as a font
        /// that cannot be built.
        static func storedFamily() -> String? {
            guard let name = UserDefaults.standard.string(forKey: familyKey), !name.isEmpty,
                  NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: name]), size: 12) != nil
            else { return nil }
            return name
        }
    }

    /// Body text size in points. Not a constant since 0.2.2 — Settings writes it.
    private(set) static var bodySize: CGFloat = Appearance.storedSize()
    /// Family the reader chose for body text, or nil for the system font.
    private(set) static var bodyFamily: String? = Appearance.storedFamily()
    /// Family the reader chose for code, or nil for the system monospaced face.
    private(set) static var monoFamily: String? = Appearance.storedMonoFamily()
    /// Which of the three looks is on.
    private(set) static var look: Look = Appearance.storedLook()

    /// True for a face whose every character is the same width.
    ///
    /// Both tests, because they disagree: `isFixedPitch` is measured from the
    /// font's own metrics, the symbolic trait is what the designer declared, and
    /// a face can carry one without the other.
    static func isFixedPitch(_ font: NSFont) -> Bool {
        font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    /// Families a reader may pick for code. Measured on this machine: five out
    /// of a hundred and eighty. Built once — asking 180 families for a font is
    /// not something to do while a picker is drawing.
    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter {
        guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: $0]), size: 12)
        else { return false }
        return isFixedPitch(font)
    }

    /// The reading face at an arbitrary size: the one place that knows whether
    /// that is the system font or a family from Settings.
    static func bodyFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let bodyFamily else { return .systemFont(ofSize: size, weight: weight) }
        var descriptor = NSFontDescriptor(fontAttributes: [.family: bodyFamily])
        if weight != .regular {
            // Asked for by weight rather than by unioning symbolic traits: a
            // wholesale trait copy drags `.monoSpace` along with it and the
            // substitution silently does nothing.
            descriptor = descriptor.addingAttributes(
                [.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static var body: NSFont { bodyFont(ofSize: bodySize) }
    /// Code, table rows and front matter stay on the system monospaced face
    /// whatever the reader picked for the text.
    ///
    /// Not because of `monoAdvance` below — nothing emits `.tableCellPad`, so
    /// that branch is dormant. The reason is plainer: a markdown table shown as
    /// raw text is *hand-aligned* text, and hand-aligned columns only line up in
    /// a fixed-pitch face. Code stops reading as code in a proportional one.
    /// Which is why Settings offers a face for code, and offers only fixed-pitch
    /// ones — `Appearance.storedMonoFamily` refuses anything else outright.
    static var mono: NSFont {
        // Xcode sets code at the same size as body; MarkRead's own look drops it
        // a point. `XcodeTheme.codeScale` is the measured 10/10.
        let size = look == .xcode ? (bodySize * XcodeTheme.codeScale).rounded() : bodySize - 1
        guard let monoFamily,
              let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: monoFamily]),
                                size: size)
        else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return font
    }

    /// Width of one monospaced character, for `.tableCellPad`.
    ///
    /// 🔴 Dormant: nothing produces that decoration. Aligning columns by kerning
    /// was measured and abandoned — it works on a narrow table and is *worse
    /// than nothing* on a wide one, where the padded rows wrap and the columns
    /// land somewhere different on each wrapped line. Kept as the record of a
    /// road already walked; do not wire it back up.
    static var monoAdvance: CGFloat { ("0" as NSString).size(withAttributes: [.font: mono]).width }

    static func heading(_ level: Int) -> NSFont {
        // Xcode has three heading sizes, not five, and sets none of them bold —
        // see `XcodeTheme`. MarkRead's own ladder is the five-step one.
        if look == .xcode {
            let scale: CGFloat = switch level {
            case 1: XcodeTheme.h1Scale
            case 2: XcodeTheme.h2Scale
            default: XcodeTheme.otherHeadingScale
            }
            return bodyFont(ofSize: (bodySize * scale).rounded(), weight: XcodeTheme.headingWeight)
        }
        let scale: CGFloat = switch level {
        case 1: 1.85
        case 2: 1.5
        case 3: 1.28
        case 4: 1.14
        default: 1.05
        }
        return bodyFont(ofSize: (bodySize * scale).rounded(), weight: .bold)
    }

    /// Adds a trait to whatever font a range already has, so that bold inside a
    /// heading stays heading-sized instead of snapping back to body size.
    private static func adding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Colours

    /// Headings and code used to carry no colour at all: both were drawn in the
    /// same `labelColor` as the paragraph around them, which is what made a
    /// document look flat next to an editor that colours its markup. One place
    /// to change them.
    /// Every colour this program invents, in one place, per `Look`. A `nil`
    /// means "leave whatever colour the text already had", which is not the same
    /// as painting it `labelColor`: a link inside that run keeps its own.
    enum Palette {
        /// The colour plain body text is set in, and the one `paintIfPlain`
        /// treats as "nothing has claimed this run yet".
        ///
        /// Under `.xcode` this is Xcode's `DVTMarkupTextNormalColor` — pure
        /// white or pure black — and deliberately **not** `labelColor`, which is
        /// white at 0.85 and reads a shade grey next to the real thing.
        static var text: NSColor {
            switch look {
            case .xcode: XcodeTheme.normal
            case .markRead, .plain: .labelColor
            }
        }
        /// A heading of this level. Xcode gives level three and below half alpha
        /// and leaves one and two at full; the other looks colour every level
        /// the same.
        static func heading(_ level: Int) -> NSColor {
            switch look {
            case .markRead: .controlAccentColor
            case .xcode: level >= 3
                ? XcodeTheme.normal.withAlphaComponent(XcodeTheme.otherHeadingAlpha)
                : XcodeTheme.normal
            case .plain: .labelColor
            }
        }
        /// Inline code and fenced blocks.
        static var code: NSColor? {
            switch look {
            case .markRead: .systemPink
            case .xcode: XcodeTheme.inlineCode
            case .plain: nil
            }
        }
        /// The fill behind code. Xcode has its own; the other looks borrow the
        /// system's faintest fill.
        static var codeBackground: NSColor {
            switch look {
            case .xcode: XcodeTheme.markupBackground
            case .markRead, .plain: .quaternarySystemFill
            }
        }
        /// The line around a code block and around a table.
        static var border: NSColor {
            switch look {
            case .xcode: XcodeTheme.markupBorder
            case .markRead, .plain: .separatorColor
            }
        }
        /// A fenced block's language name — the one thing Xcode colours inside a
        /// code block, in the same red it uses for a string literal.
        static var infoString: NSColor? {
            switch look {
            case .xcode: XcodeTheme.infoString
            case .markRead, .plain: nil
            }
        }
        /// A blockquote's text.
        ///
        /// Xcode's theme has no blockquote key at all: a quote is `markupProse`
        /// like any other paragraph and carries the ordinary text colour. The
        /// `>` in front of it stays a marker, dimmed like every other marker,
        /// which is what tells the quote apart there.
        static var quote: NSColor {
            switch look {
            case .xcode: text
            case .markRead, .plain: .secondaryLabelColor
            }
        }
        /// A list's bullet or number. Xcode sets them in the same colour as the
        /// item's text; MarkRead's own look steps them back so the text leads.
        static var listMarker: NSColor {
            switch look {
            case .xcode: text
            case .markRead, .plain: .secondaryLabelColor
            }
        }
        /// Links. Xcode's markdown link colour is its own value, several shades
        /// more violet than the system's.
        static var link: NSColor {
            switch look {
            case .xcode: XcodeTheme.link
            case .markRead, .plain: .linkColor
            }
        }
        /// Bold and italic. Xcode puts no colour on either — only weight and
        /// slant — and neither does `plain`.
        static var emphasis: NSColor? {
            switch look {
            case .markRead: .systemIndigo
            case .xcode, .plain: nil
            }
        }
        /// A table row *as raw markdown*, which is the only state this colour is
        /// ever seen in: the drawn table puts its cells back to the body colour,
        /// because a whole table tinted in one hue reads as faded rather than as
        /// a table. See `MarkdownTableRenderer.useBodyColour`.
        static var tableRow: NSColor? {
            switch look {
            case .markRead: .systemTeal
            case .xcode, .plain: nil
            }
        }
        /// The header row of a *drawn* table.
        ///
        /// 🔴 Was `.systemPink` under `.xcode` until 2026-08-27, on the guess
        /// that "Xcode colours the table header". It does not — the theme file
        /// has no such key, and the pink was this program's invention wearing
        /// Xcode's name. Nothing here is coloured now.
        static var tableHeader: NSColor? { nil }
        /// The fill behind a drawn table's header row.
        static var tableHeaderFill: NSColor {
            switch look {
            case .xcode: XcodeTheme.markupBackground
            case .markRead, .plain: .quaternarySystemFill
            }
        }
        /// Whether a drawn table's header row is set in bold.
        static var tableHeaderIsBold: Bool { look != .markRead }
    }

    // MARK: - Paragraph

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if look == .xcode {
            // 🔴 Xcode invents no spacing, and this is the one part of the look
            // that is not in the theme file — it is in the editor.
            //
            // Xcode renders markdown *inside the source editor*, one source line
            // per line, so `SourceEditorLayoutManager.calculateLineSpacing`
            // is the whole rule: `ceil(font.leading)` plus the reader's own
            // "additional line spacing", which is zero by default. There is no
            // paragraph spacing anywhere — the gap between two blocks is the
            // blank line that stands between them in the file.
            //
            // MarkRead shows the same source lines, blank ones included, so
            // copying that means adding nothing: a `paragraphSpacing` on top
            // would be spacing this program invented, laid over a gap the file
            // already provides. It is what made lists look airy next to Xcode's.
            style.lineSpacing = ceil(body.leading)
            style.paragraphSpacing = 0
            return style
        }
        style.lineSpacing = 2.5
        style.paragraphSpacing = 6
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: Palette.text, .paragraphStyle: paragraph]
    }

    // MARK: - Applying

    /// Resets `range` to plain body text, then lays the decorations over it.
    ///
    /// The reset matters: re-highlighting an edited line has to undo whatever the
    /// previous pass put there, or deleting a `*` leaves the text italic forever.
    static func apply(_ decorations: [Decoration], to storage: NSTextStorage, resetting range: NSRange) {
        storage.beginEditing()
        defer { storage.endEditing() }

        storage.setAttributes(baseAttributes, range: range)

        for decoration in decorations {
            let r = decoration.range
            guard r.location != NSNotFound, r.length > 0,
                  NSMaxRange(r) <= storage.length else { continue }

            switch decoration.style {
            case .marker, .hiddenMarker:
                // Colour matters only while the caret reveals the line; the rest
                // of the time these glyphs are not drawn at all.
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)

            case .heading(let level):
                storage.addAttributes([
                    .font: heading(level),
                    .foregroundColor: Palette.heading(level),
                ], range: r)

            case .bold:
                addTrait(.bold, storage, r, colour: Palette.emphasis)
            case .italic:
                addTrait(.italic, storage, r, colour: Palette.emphasis)
            case .boldItalic:
                addTrait([.bold, .italic], storage, r, colour: Palette.emphasis)

            case .strikethrough:
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: r)

            case .highlight:
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: r)

            case .code:
                storage.addAttributes([
                    .font: mono,
                    .foregroundColor: Palette.code ?? Palette.text,
                    .backgroundColor: Palette.codeBackground,
                    .markReadCode: true,
                ], range: r)

            case .codeBlock:
                // No `.backgroundColor` here on purpose — see `Decoration.Style`.
                storage.addAttributes([
                    .font: mono,
                    .foregroundColor: Palette.code ?? Palette.text,
                    .markReadCode: true,
                ], range: r)

            case .infoString:
                if let colour = Palette.infoString {
                    storage.addAttribute(.foregroundColor, value: colour, range: r)
                }

            case .link(let target):
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: Palette.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .cursor: NSCursor.pointingHand,
                ]
                if let url = URL(string: target) { attributes[.link] = url }
                storage.addAttributes(attributes, range: r)

            case .wikiLink(let target):
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: Palette.link,
                    .cursor: NSCursor.pointingHand,
                ]
                if let url = wikiURL(for: target) { attributes[.link] = url }
                storage.addAttributes(attributes, range: r)

            case .listMarker:
                storage.addAttribute(.foregroundColor, value: Palette.listMarker, range: r)

            case .taskMarker(let done):
                storage.addAttributes([
                    .foregroundColor: done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .font: adding(.bold, to: mono),
                ], range: r)

            case .quote:
                storage.addAttribute(.foregroundColor, value: Palette.quote, range: r)

            case .calloutLabel:
                storage.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .font: adding(.bold, to: body),
                ], range: r)

            case .frontMatter:
                storage.addAttributes([
                    .font: mono,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: r)

            case .tableRow:
                storage.addAttribute(.font, value: mono, range: r)
                if let colour = Palette.tableRow { paintIfPlain(colour, storage, r) }

            case .tableCellPad(let units):
                storage.addAttribute(.kern, value: CGFloat(units) * monoAdvance, range: r)

            case .rule:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            }
        }
    }

    private static func addTrait(_ traits: NSFontDescriptor.SymbolicTraits,
                                 _ storage: NSTextStorage, _ range: NSRange,
                                 colour: NSColor? = nil) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = value as? NSFont ?? body
            storage.addAttribute(.font, value: adding(traits, to: current), range: subrange)
        }
        if let colour { paintIfPlain(colour, storage, range) }
    }

    /// Colours only the part of `range` that is still plain body text.
    ///
    /// Deliberately not private: the table renderer paints a drawn header row by
    /// the same rule, so that code or a link inside a header cell keeps its own
    /// colour.
    ///
    /// This is the whole reason emphasis can be coloured at all. A bold word
    /// *inside a heading* already carries the heading's colour by the time this
    /// runs, and painting over it would strip the heading's own colour off
    /// exactly one word — which is why bold and italic were left grey when the
    /// headings first got theirs. Same for a bold link, and for code or a link
    /// sitting in a table row.
    static func paintIfPlain(_ colour: NSColor, _ storage: NSMutableAttributedString, _ range: NSRange) {
        storage.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            guard value as? NSColor == Palette.text else { return }
            storage.addAttribute(.foregroundColor, value: colour, range: subrange)
        }
    }
}
