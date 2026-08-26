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
    enum Appearance {
        static let sizeKey = "bodySize"
        static let familyKey = "bodyFontFamily"
        static let defaultSize: Double = 15
        static let sizeRange: ClosedRange<Double> = 11 ... 28

        /// Posted when either setting changes. The open editor listens, because
        /// every column width and every laid-out table it holds was measured for
        /// the font that has just been replaced.
        static let didChange = Notification.Name("MarkReadAppearanceDidChange")

        static func reload() {
            MarkdownStyle.bodySize = storedSize()
            MarkdownStyle.bodyFamily = storedFamily()
            NotificationCenter.default.post(name: didChange, object: nil)
        }

        /// The stored size, or the default when nothing is stored. Clamped, so a
        /// value written into the plist by hand cannot leave the app unreadable.
        static func storedSize() -> CGFloat {
            let stored = UserDefaults.standard.double(forKey: sizeKey)
            guard stored > 0 else { return CGFloat(defaultSize) }
            return CGFloat(min(max(stored, sizeRange.lowerBound), sizeRange.upperBound))
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
    /// whatever the reader picked for the text: table columns are padded in
    /// whole monospaced advances, and a proportional face there takes the
    /// alignment with it.
    static var mono: NSFont { .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular) }

    /// Width of one monospaced character. Table padding is expressed in these,
    /// so the scanner can stay free of AppKit.
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
    enum Palette {
        /// Every heading level. Follows the system accent rather than fixing a
        /// hue that would clash with somebody else's.
        static var heading: NSColor { .controlAccentColor }
        /// Inline code and fenced blocks. The background tint alone is easy to
        /// miss on a busy line.
        static var code: NSColor { .systemPink }
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
                addTrait(.bold, storage, r)
            case .italic:
                addTrait(.italic, storage, r)
            case .boldItalic:
                addTrait([.bold, .italic], storage, r)

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
                    .foregroundColor: Palette.code,
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

            case .tableCellPad(let units):
                storage.addAttribute(.kern, value: CGFloat(units) * monoAdvance, range: r)

            case .rule:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            }
        }
    }

    private static func addTrait(_ traits: NSFontDescriptor.SymbolicTraits,
                                 _ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = value as? NSFont ?? body
            storage.addAttribute(.font, value: adding(traits, to: current), range: subrange)
        }
    }
}
