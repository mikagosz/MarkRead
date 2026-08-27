// Renders a note through MarkRead's real editor and writes a PNG.
//
// Not a test: a pair of eyes. The look work was being done blind — read the
// code, guess the pixels — and this is what stops that. It builds the actual
// `MarkdownEditor`, with the actual styling, in an off-screen window, and
// saves what it drew.
//
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//     <MarkRead sources> render-shot.swift -o shot
//   ./shot <note.md> <markRead|xcode|plain> <out.png> [scrollFraction] [dark|light]
//
// The appearance is set on the window, not on the system: a look has to be
// checkable in both without touching what the machine is set to.
import AppKit
import SwiftUI

struct Root: View {
    @State var text: String
    let handle = EditorHandle()
    var body: some View {
        MarkdownEditor(text: $text, handle: handle,
                       onLinkClick: { _ in }, onLinkHover: { _ in }, onFileDrop: { _ in })
    }
}

@main
struct Shot {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4 else { print("usage: shot <note> <look> <out.png> [fraction]"); exit(2) }
        let fraction = args.count > 4 ? Double(args[4]) ?? 0 : 0
        let appearance: NSAppearance.Name = (args.count > 5 && args[5] == "light") ? .aqua : .darkAqua

        UserDefaults.standard.set(args[2], forKey: MarkdownStyle.Appearance.lookKey)
        MarkdownStyle.Appearance.reload()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let text = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? "# nothing to render"
        let size = NSSize(width: 1000, height: 1300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: Root(text: text))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)

        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        if fraction > 0, let scroll = firstScrollView(in: host),
           let documentView = scroll.documentView {
            let y = (documentView.frame.height - scroll.contentSize.height) * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("no bitmap"); exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("no png"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: args[3]))
        print("written \(args[3])")
        exit(0)
    }

    static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}
