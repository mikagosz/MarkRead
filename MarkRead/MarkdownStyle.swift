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
        /// Xcode's markdown preview: headings and emphasis carry no colour at
        /// all, and the table header is the coloured thing instead.
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
            case .xcode: "No colour on headings or emphasis; the table header carries it instead."
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
        let size = bodySize - 1
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
        /// Every heading level. Where it follows the accent it does so rather
        /// than fixing a hue that would clash with somebody else's.
        static var heading: NSColor {
            switch look {
            case .markRead: .controlAccentColor
            case .xcode, .plain: .labelColor
            }
        }
        /// Inline code and fenced blocks. The background tint alone is easy to
        /// miss on a busy line.
        static var code: NSColor? {
            switch look {
            case .markRead: .systemPink
            case .xcode: .systemPink
            case .plain: nil
            }
        }
        /// Bold and italic. Quieter than the heading accent on purpose — a page
        /// where every emphasised word shouts reads worse than a flat one.
        static var emphasis: NSColor? {
            switch look {
            case .markRead: .systemIndigo
            case .xcode, .plain: nil
            }
        }
        /// A table row *as raw markdown*, which is the only state this colour is
        /// ever seen in: the drawn table puts its cells back to `labelColor`,
        /// because a whole table tinted in one hue reads as faded rather than as
        /// a table. See `MarkdownTableRenderer.useBodyColour`.
        static var tableRow: NSColor? {
            switch look {
            case .markRead: .systemTeal
            case .xcode, .plain: nil
            }
        }
        /// The header row of a *drawn* table — the one thing Xcode colours and
        /// MarkRead did not.
        static var tableHeader: NSColor? {
            switch look {
            case .markRead: nil
            case .xcode: .systemPink
            case .plain: nil
            }
        }
        /// Whether a drawn table's header row is set in bold.
        static var tableHeaderIsBold: Bool { look != .markRead }
    }

    // MARK: - Paragraph

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        style.paragraphSpacing = 6
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
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
                    .foregroundColor: Palette.heading,
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
                    .foregroundColor: Palette.code ?? NSColor.labelColor,
                    .backgroundColor: NSColor.quaternarySystemFill,
                    .markReadCode: true,
                ], range: r)

            case .link(let target):
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .cursor: NSCursor.pointingHand,
                ]
                if let url = URL(string: target) { attributes[.link] = url }
                storage.addAttributes(attributes, range: r)

            case .wikiLink(let target):
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.linkColor,
                    .cursor: NSCursor.pointingHand,
                ]
                if let url = wikiURL(for: target) { attributes[.link] = url }
                storage.addAttributes(attributes, range: r)

            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)

            case .taskMarker(let done):
                storage.addAttributes([
                    .foregroundColor: done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .font: adding(.bold, to: mono),
                ], range: r)

            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)

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
            guard value as? NSColor == NSColor.labelColor else { return }
            storage.addAttribute(.foregroundColor, value: colour, range: subrange)
        }
    }
}
