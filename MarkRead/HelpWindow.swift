import AppKit
import SwiftUI

// The Help window: a big title, then sections with a picture of the app on one side and the steps on the
// other, sides taking turns. Numbered points on a picture match the numbered steps.
//
// The pictures are drawn by MarkRead itself, on sample data: the main window and Settings are rendered off
// screen from the very same SwiftUI views, fed with a few made-up notes in a temporary folder and a separate
// settings store (`AppState(defaults:)`). Nothing of the user's notes, list or settings gets in, and nothing
// real is written. The Format menu, which cannot be rendered, is drawn with the menu's own titles.

@MainActor
final class HelpWindow {
    static let shared = HelpWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = HelpContent.windowTitle.current
            w.isReleasedWhenClosed = false
            // The window first, the pictures once it is on screen: drawing them holds the run loop for a moment.
            w.contentView = NSHostingView(rootView: HelpRoot())
            // A fixed height: an `idealHeight` alone gave the window 432 pt (measured in DeskMount 0.1.50).
            w.setContentSize(NSSize(width: HelpPage.width, height: HelpPage.height))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Sample data

/// A sample world for the pictures: its own settings store and a temporary notes folder, both removed
/// once the pictures are made.
@MainActor
enum HelpSample {
    static let suite = "com.mikagosz.MarkRead.help-sample"

    private static func t(_ pl: String, _ en: String) -> String { HelpContent.polish ? pl : en }

    static var tripName: String { t("Wyjazd nad morze", "Trip to the coast") }
    static var routeName: String { t("Trasa", "Route") }

    /// Runs `make` with a sample window state over a folder of made-up notes, then removes both.
    static func with<T>(_ make: @MainActor (AppState, UserDefaults) -> T) -> T {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MarkRead-help-\(UUID().uuidString)", isDirectory: true)
        // The folder's own name is what the list shows; the temporary path above it never appears.
        let root = base.appendingPathComponent(t("Notatki", "Notes"), isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        let notes = write(into: root)
        let state = AppState(defaults: defaults)
        state.openFolder(root)
        // Two pinned, two opened lately, newest last; the trip note is on screen.
        state.library.pin([notes.reading, notes.route])
        state.library.noteOpened(notes.bread)
        state.library.noteOpened(notes.meeting)
        // Opened without going on the list: a selected row draws as a black bar off screen (its highlight is
        // the window server's), so the note on screen is one the list does not show.
        state.document = try? MarkdownDocument(url: notes.trip)
        return make(state, defaults)
    }

    private struct Notes { let trip, route, reading, bread, meeting: URL }

    private static func write(into root: URL) -> Notes {
        let fm = FileManager.default
        func note(_ path: String, _ text: String) -> URL {
            let url = root.appendingPathComponent(path + ".md")
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let trip = note("../" + tripName, t("""
            # Wyjazd nad morze

            Trzy dni na rowerze, **lekki bagaż**. Trasa i noclegi są w [[Trasa]].

            ## Do spakowania

            - [x] Namiot
            - [ ] Kurtka przeciwdeszczowa
            - [ ] Zapasowa dętka

            > [!tip] Prom
            > Bilet na prom najlepiej kupić tydzień wcześniej.

            ## Koszty

            | Co | Ile |
            |---|---|
            | Prom | 40 zł |
            | Kemping | 3 × 35 zł |
            | Jedzenie | 150 zł |

            ```
            dzień 1: 62 km
            dzień 2: 48 km
            ```
            """, """
            # Trip to the coast

            Three days by bike, **light luggage**. Route and places to stay are in [[Route]].

            ## Packing

            - [x] Tent
            - [ ] Rain jacket
            - [ ] Spare inner tube

            > [!tip] Ferry
            > Best to buy the ferry ticket a week ahead.

            ## Costs

            | What | How much |
            |---|---|
            | Ferry | €12 |
            | Camping | 3 × €9 |
            | Food | €40 |

            ```
            day 1: 62 km
            day 2: 48 km
            ```
            """))
        let route = note(routeName, t("# Trasa\n\nDzień 1 wzdłuż rzeki, dzień 2 przez las.\n", "# Route\n\nDay 1 along the river, day 2 through the forest.\n"))
        let reading = note(t("Do przeczytania", "Reading list"), t("# Do przeczytania\n\n- [ ] Książka o ogrodach\n", "# Reading list\n\n- [ ] A book about gardens\n"))
        let bread = note(t("Przepisy/Chleb na zakwasie", "Recipes/Sourdough bread"),
                         t("# Chleb na zakwasie\n\n500 g mąki, 350 ml wody.\n", "# Sourdough bread\n\n500 g flour, 350 ml water.\n"))
        let meeting = note(t("Praca/Spotkanie w czwartek", "Work/Thursday meeting"),
                           t("# Spotkanie w czwartek\n\n- przegląd tygodnia\n", "# Thursday meeting\n\n- review of the week\n"))
        _ = note(t("Pomysły", "Ideas"), t("# Pomysły\n\nOgród na balkonie.\n", "# Ideas\n\nA garden on the balcony.\n"))
        return Notes(trip: trip, route: route, reading: reading, bread: bread, meeting: meeting)
    }
}

/// Bitmaps of the app's own windows on sample data, made when the Help window opens.
@MainActor
struct HelpPictures {
    let main: NSImage
    let links: NSImage
    let settings: NSImage
    let settingsSize: NSSize

    static let windowSize = NSSize(width: 1000, height: 640)
    /// Low enough that the bar lands in the blank line under the first heading, covering no text.
    static let linksSize = NSSize(width: 1000, height: 234)

    static func make() -> HelpPictures {
        HelpSample.with { state, defaults in
            let main = Render.window(ContentView(app: state, picture: true), size: windowSize, title: HelpSample.tripName, settle: 0.6)
            // The bar at the bottom of the editor, as when the pointer rests on the link to the route note.
            state.hoverLink(MarkdownStyle.wikiURL(for: HelpSample.routeName))
            // A low window: the bar stands just under the paragraph with the link instead of over the code further down.
            let links = Render.window(ContentView(app: state, picture: true), size: linksSize, title: HelpSample.tripName, settle: 0.3)
            let settingsView = SettingsView().defaultAppStorage(defaults)
            let size = NSHostingController(rootView: settingsView).sizeThatFits(in: CGSize(width: 460, height: 2000))
            let settings = Render.window(settingsView, size: size, title: "", settle: 0.15)
            return HelpPictures(main: main, links: links, settings: settings, settingsSize: size)
        }
    }
}

@MainActor
enum Render {
    /// A view drawn into a bitmap at twice its size, so it stays sharp on a Retina screen.
    static func bitmap(_ v: NSView) -> NSImage {
        let b = v.bounds
        guard b.width >= 1, b.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = b.size
        v.cacheDisplay(in: b, to: rep)
        let image = NSImage(size: b.size)
        image.addRepresentation(rep)
        return image
    }

    /// A window's content rendered off screen and invisible, in a real titled window so its toolbar is drawn
    /// too — the whole frame is the bitmap, the content running under the title bar as in the app.
    /// `titled: false` draws the content alone (the page export).
    /// `settle`: how long the run loop turns first, for the folder walk and the editor's late layout.
    static func window<V: View>(_ view: V, size: NSSize, titled: Bool = true, title: String, settle: TimeInterval) -> NSImage {
        // Drawn as the window in front: an invisible window is never key, and its controls would be drawn dimmed.
        let controller = NSHostingController(rootView: view.environment(\.controlActiveState, .key))
        controller.sizingOptions = []
        let w = NSWindow(contentViewController: controller)
        w.styleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        w.isReleasedWhenClosed = false
        w.title = title
        w.appearance = NSApp.effectiveAppearance
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.setContentSize(size)
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let frame = (titled ? w.contentView?.superview : w.contentView) ?? NSView()
        // The sidebar's material blends with what is behind the window, which a bitmap never sees.
        let plain = NSAppearance(named: w.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua)
        func withinWindow(_ v: NSView) {
            if let effect = v as? NSVisualEffectView {
                effect.blendingMode = .withinWindow
                effect.state = .active
                // Its vibrant appearance draws the list's text through the missing backdrop, dimmed.
                effect.appearance = plain
            }
            if v.appearance?.name.rawValue.contains("Vibrant") == true { v.appearance = plain }
            v.subviews.forEach(withinWindow)
        }
        withinWindow(frame)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        frame.layoutSubtreeIfNeeded()
        frame.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        var image = NSImage()
        w.effectiveAppearance.performAsCurrentDrawingAppearance { image = bitmap(frame) }
        w.orderOut(nil)
        w.contentViewController = nil
        return image
    }
}

extension NSImage {
    /// A piece of the picture, in points from its top-left corner — like a cut-out screenshot.
    func cutOut(_ r: CGRect) -> NSImage {
        if r == CGRect(origin: .zero, size: size) { return self }
        return NSImage(size: r.size, flipped: false) { _ in
            self.draw(in: NSRect(x: -r.minX, y: r.maxY - self.size.height, width: self.size.width, height: self.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: - The page

/// The window's content: a spinner while the pictures are drawn, then the page.
private struct HelpRoot: View {
    @State private var pictures: HelpPictures?

    var body: some View {
        if let pictures {
            HelpPage(pictures: pictures)
        } else {
            ProgressView()
                .frame(width: HelpPage.width, height: HelpPage.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear {
                    // A moment later, so the window with the spinner is drawn before the run loop is held.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pictures = HelpPictures.make() }
                }
        }
    }
}

struct HelpPage: View {
    static let width: CGFloat = 960
    static var height: CGFloat { min(900, (NSScreen.main?.visibleFrame.height ?? 900) - 80) }

    let pictures: HelpPictures
    /// For the bitmap of the whole page (`--export-help`): no scrolling, every section unfolded.
    var wholePage = false

    var body: some View {
        if wholePage {
            content.frame(width: Self.width).background(Color(nsColor: .windowBackgroundColor))
        } else {
            // Opens at the title: without the anchor the window came up scrolled a little way down.
            ScrollView { content }
                .defaultScrollAnchor(.top)
                .frame(width: Self.width, height: Self.height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(HelpContent.sections.enumerated()), id: \.offset) { i, s in
                Divider().padding(.horizontal, 60)
                HelpSectionView(section: s, pictureLeft: i % 2 == 0, pictures: pictures, expanded: wholePage)
            }
            Divider().padding(.horizontal, 60)
            goodToKnow
            FractalSignature()
        }
        .padding(.bottom, 40)
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 96, height: 96)
            Text(verbatim: HelpContent.title.current).font(.system(size: 40, weight: .semibold))
            Text(verbatim: HelpContent.intro.current)
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            WindowPicture(image: pictures.main, crop: Crop(rect: CGRect(origin: .zero, size: HelpPictures.windowSize), points: []),
                          maxWidth: 840)
                .padding(.top, 8)
        }
        .padding(.top, 44).padding(.bottom, 48).padding(.horizontal, 60)
    }

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: HelpContent.goodToKnow.current).font(.system(size: 30, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)],
                      spacing: 20) {
                ForEach(HelpContent.cards, id: \.symbol) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: c.symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        Text(verbatim: c.title.current).font(.headline)
                        Text(verbatim: c.text.current).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .padding(.top, 40).padding(.horizontal, 60)
    }
}

private struct HelpSectionView: View {
    let section: HelpContent.Section
    let pictureLeft: Bool
    let pictures: HelpPictures
    @State var expanded: Bool

    /// The whole window is wide: its picture stands under the text, across the page.
    private var wide: Bool { section.picture == .window }

    var body: some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 28) {
                    text
                    picture.frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 44) {
                    if pictureLeft { picture }
                    text
                    if !pictureLeft { picture }
                }
            }
        }
        .padding(.vertical, 44).padding(.horizontal, 60)
    }

    private var picture: some View {
        Group {
            switch section.picture {
            case .window: WindowPicture(image: pictures.main, crop: HelpCrops.window, maxWidth: 840)
            case .sidebar: WindowPicture(image: pictures.main, crop: HelpCrops.sidebar)
            case .editor: WindowPicture(image: pictures.main, crop: HelpCrops.editor)
            case .format: FormatMenuPicture()
            case .links: WindowPicture(image: pictures.links, crop: HelpCrops.links)
            case .settings: WindowPicture(image: pictures.settings, crop: HelpCrops.settings(pictures.settingsSize))
            }
        }
        .frame(width: wide ? nil : 440)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: section.title.current).font(.system(size: 30, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: section.lead.current).font(.system(size: 15)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Marker(number: i + 1, small: true)
                        Text(verbatim: step.current).font(.system(size: 14)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let more = section.more {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(expanded ? HelpContent.less.current : HelpContent.more.current,
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link)
                if expanded {
                    Text(verbatim: more.current).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Format menu, drawn with the menu's own titles and shortcuts — an open menu cannot be rendered.
private struct FormatMenuPicture: View {
    private let groups: [[(String, String)]] = [
        [("Bold", "⌘B"), ("Italic", "⌘I"), ("Strikethrough", "⇧⌘X"), ("Highlight", "⇧⌘H"), ("Inline Code", "⌘E")],
        [("Heading 1", "⌃⌘1"), ("Heading 2", "⌃⌘2"), ("Heading 3", "⌃⌘3"), ("Body Text", "⌃⌘0")],
        [("Bulleted List", "⇧⌘L"), ("Task", "⇧⌘T"), ("Block Quote", "⇧⌘'"), ("Code Block", "⇧⌘E")],
        [("Link", "⌘K")],
    ]

    var body: some View {
        Frame {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    HStack(alignment: .top, spacing: 0) {
                        // The group's number in the margin, level with its first row.
                        Marker(number: i + 1).frame(width: 44, height: 24)
                        VStack(spacing: 0) {
                            ForEach(g, id: \.0) { item in
                                HStack {
                                    Text(verbatim: item.0)
                                    Spacer()
                                    Text(verbatim: item.1).foregroundStyle(.secondary)
                                }
                                .font(.system(size: 13))
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                            }
                            if i < groups.count - 1 { Divider().padding(.vertical, 5).padding(.horizontal, 12) }
                        }
                        .frame(width: 260)
                        .background(Color.primary.opacity(0.06))
                    }
                }
            }
            .padding(.vertical, 24)
            .frame(width: 440, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Cut-outs and points

/// Where to cut a window and where its numbered points stand, in points of the window.
/// x < 0: the point stands in the margin on the left, level with the row — it covers no text.
struct Crop {
    let rect: CGRect
    let points: [CGPoint?]
}

/// Measured on `--export-help`.
enum HelpCrops {
    private static func m(_ y: CGFloat) -> CGPoint { CGPoint(x: -1, y: y) }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static let window = Crop(rect: CGRect(origin: .zero, size: HelpPictures.windowSize),
                             points: [p(226, 26), p(200, 110), p(520, 183), p(972, 62)])
    /// The sidebar from the filter field down to the folder bar.
    static let sidebar = Crop(rect: CGRect(x: 0, y: 55, width: 240, height: 585),
                              points: [m(19), m(55), m(167), m(288)])
    /// The editor below the title bar; points level with a heading, the task list and the table.
    static let editor = Crop(rect: CGRect(x: 240, y: 52, width: 560, height: 588),
                             points: [m(26), m(186), m(448)])
    static let links = Crop(rect: CGRect(x: 240, y: 52, width: 560, height: HelpPictures.linksSize.height - 52),
                            points: [p(400, 58), p(100, 161)])
    /// Settings below the title bar, ending above Updates: its last-check date is the real one.
    static func settings(_ size: NSSize) -> Crop {
        Crop(rect: CGRect(x: 0, y: 36, width: size.width, height: min(size.height - 36, 376)),
             points: [m(57), m(232), m(307)])
    }
}

/// A window picture in a section: the cut-out, its frame and the numbered points.
/// Never enlarged beyond 1:1 — bigger than the window it would look like a screenshot under a magnifier.
struct WindowPicture: View {
    let image: NSImage
    let crop: Crop
    var maxWidth: CGFloat = 440
    private let margin: CGFloat = 36

    var body: some View {
        let r = crop.rect
        let left: CGFloat = crop.points.contains { ($0?.x ?? 0) < 0 } ? margin : 0
        let w = min(maxWidth - left, r.width)
        let scale = w / r.width
        let h = r.height * scale
        Frame {
            HStack(spacing: 0) {
                Color.clear.frame(width: left, height: h)
                Image(nsImage: image.cutOut(r)).resizable().interpolation(.high).frame(width: w, height: h)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(crop.points.enumerated()), id: \.offset) { i, p in
                        if let p {
                            Marker(number: i + 1).position(x: p.x < 0 ? margin / 2 + 2 : left + p.x * scale, y: p.y * scale)
                        }
                    }
                }
                .frame(width: left + w, height: h, alignment: .topLeading)
            }
        }
    }
}

/// The numbered point on a picture, and the same number in front of a step.
struct Marker: View {
    let number: Int
    var small = false

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: small ? 11 : 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: small ? 20 : 26, height: small ? 20 : 26)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: small ? 0 : 2))
            .shadow(color: .black.opacity(small ? 0 : 0.35), radius: 3, y: 1)
    }
}

/// Rounded card with a soft shadow — the frame every picture sits in.
struct Frame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// The Fractal 8 Dev signature at the end of Help, set like the hero of fractal8.eu: the logo large behind,
/// under the same veil as the site's video (darker at the edges and towards the bottom), and the text over
/// its lower part — "ENDLESS RECURSION" spaced 0.42 em in the accent (#7ee8f2 dark, #0a8796 light), then
/// "Fractal 8 Dev" in SF Pro Bold drawn together by −0.045 em with the site's gradient, then the site's line.
private struct FractalSignature: View {
    @Environment(\.colorScheme) private var scheme
    private static let logo: NSImage? = Bundle.main.url(forResource: "studio-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        let dark = scheme == .dark
        let back = Color(nsColor: .windowBackgroundColor)
        let accent = dark ? Color(red: 126 / 255, green: 232 / 255, blue: 242 / 255) : Color(red: 10 / 255, green: 135 / 255, blue: 150 / 255)
        let gradient = LinearGradient(stops: [
            .init(color: dark ? .white : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255), location: 0.4),
            .init(color: dark ? Color(red: 159 / 255, green: 163 / 255, blue: 171 / 255) : Color(red: 91 / 255, green: 95 / 255, blue: 102 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .bottom) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high).frame(width: 560, height: 560)
                    .opacity(dark ? 0.75 : 0.55)
                    .frame(height: 440, alignment: .top)
                    .clipped()
                    // The site's veil (styles.css, .hero-sticky::after): edges and the bottom sink into the background.
                    .overlay(RadialGradient(stops: [.init(color: .clear, location: 0.35), .init(color: back.opacity(0.75), location: 1)],
                                            center: .center, startRadius: 0, endRadius: 300))
                    .overlay(LinearGradient(stops: [.init(color: back.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                                    .init(color: back.opacity(0.55), location: 0.62), .init(color: back, location: 0.92)],
                                            startPoint: .top, endPoint: .bottom))
            }
            VStack(spacing: 0) {
                Text(verbatim: "ENDLESS RECURSION")
                    .font(.system(size: 12)).tracking(12 * 0.42).foregroundStyle(accent)
                    .padding(.bottom, 16)
                Text(verbatim: "Fractal 8 Dev")
                    .font(.system(size: 76, weight: .bold)).tracking(-76 * 0.045)
                    .foregroundStyle(gradient)
                Text(verbatim: HelpContent.signatureLine.current)
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(.top, 40)
    }
}

// MARK: - Bitmap of the Help page, for checking it without opening a window

/// `MarkRead --export-help <folder> -AppleLanguages '(pl)'`: draws the Help page and the window pictures into
/// PNG files and quits, from `MarkReadApp.init` — before any window opens.
enum HelpExport {
    static func runIfRequested() {
        let a = CommandLine.arguments
        let lang = HelpContent.polish ? "pl" : "en"
        // `--export-help-window <folder>`: the Help window as the app shows it (pictures made the way `show()`
        // makes them, the page in a scroll view), to check what the user sees, not only the export.
        if let i = a.firstIndex(of: "--export-help-window"), i + 1 < a.count {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let folder = URL(fileURLWithPath: a[i + 1], isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let size = NSSize(width: HelpPage.width, height: 900)
                let host = NSHostingView(rootView: HelpPage(pictures: HelpPictures.make()))
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                host.frame = NSRect(origin: .zero, size: size)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                save(Render.bitmap(host), folder.appendingPathComponent("help-window-\(lang).png"))
            }
            exit(0)
        }
        guard let i = a.firstIndex(of: "--export-help"), i + 1 < a.count else { return }
        MainActor.assumeIsolated {
            let folder = URL(fileURLWithPath: a[i + 1], isDirectory: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let p = HelpPictures.make()
            for (name, image) in [("main", p.main), ("links", p.links), ("settings", p.settings)] {
                save(image, folder.appendingPathComponent("window-\(name)-\(lang).png"))
            }
            let page = HelpPage(pictures: p, wholePage: true)
            // The height measured at the fixed width — `fittingSize` measures without it and cuts the top and bottom off.
            let h = NSHostingController(rootView: page)
                .sizeThatFits(in: CGSize(width: HelpPage.width, height: CGFloat.greatestFiniteMagnitude)).height
            save(Render.window(page, size: NSSize(width: HelpPage.width, height: ceil(h)), titled: false, title: "", settle: 0.3),
                 folder.appendingPathComponent("help-\(lang).png"))
        }
        exit(0)
    }

    private static func save(_ image: NSImage, _ url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        FileHandle.standardOutput.write(Data("\(url.path) \(Int(image.size.width))×\(Int(image.size.height))\n".utf8))
    }
}
