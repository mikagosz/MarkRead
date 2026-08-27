// Renders the real sidebar, with a list in it, and writes a PNG.
//
// A pair of eyes, like `render-shot`, for the half of the window that one does
// not cover. "Pinned, recent and the folder must not read as one list" is a
// claim about pixels, and this is what makes it answerable.
//
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//     <MarkRead sources> sidebar-shot.swift -o sidebar-shot
//   ./sidebar-shot <folder of notes> <out.png> [dark|light]
//
// It writes to its own UserDefaults suite, so it never touches the list the
// installed app is showing.
import AppKit
import SwiftUI

@main
struct SidebarShot {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: sidebar-shot <folder> <out.png> [dark|light]"); exit(2) }
        let folder = URL(fileURLWithPath: args[1])
        let appearance: NSAppearance.Name = (args.count > 3 && args[3] == "light") ? .aqua : .darkAqua

        let suite = "com.mikagosz.MarkRead.sidebar-shot"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MarkdownStyle.Appearance.reload()

        let state = AppState(defaults: defaults)
        // A believable list: two notes pinned by hand, three opened lately, and
        // a folder underneath them.
        let notes = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard notes.count >= 2 else { print("need at least two .md files in \(folder.path)"); exit(2) }
        state.add(Array(notes.prefix(2)))
        for note in notes.dropFirst(2).prefix(3) { state.library.noteOpened(note) }
        state.openFolder(folder)

        let size = NSSize(width: 900, height: 620)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: ContentView(app: state))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)
        // The folder walk is a Task; the list is empty until it lands.
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("no bitmap"); exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("no png"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: args[2]))
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("written \(args[2])")
        exit(0)
    }
}
