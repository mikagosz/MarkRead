// Headless check for what a click on a link may do. No frameworks, no fixtures.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/AppState.swift MarkRead/MarkdownDocument.swift \
//          MarkRead/FolderIndex.swift MarkRead/MarkdownStyle.swift \
//          MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
//          MarkRead/MarkdownTables.swift MarkRead/MarkdownTableRenderer.swift \
//          MarkRead/MarkdownTextView.swift MarkRead/EditorActions.swift \
//          Tests/links-check.swift -o /tmp/links-check && /tmp/links-check
//
// The point it defends: a note is a document that can come from anyone, and
// `NSWorkspace.open` on an app, a script or anything with the executable bit set
// *runs* it. Only files the system calls documents may be opened; everything
// else is revealed in Finder. The decision is made by content type, so a file
// type nobody thought of lands on the safe side.
import AppKit

@main
struct LinksCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    static let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("markread-links-check-\(UUID().uuidString)")

    @discardableResult
    static func file(_ name: String, executable: Bool = false) -> URL {
        let url = scratch.appendingPathComponent(name)
        try? Data("x".utf8).write(to: url)
        if executable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    static func main() {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Documents: opened where they are.
        for name in ["picture.png", "scan.pdf", "notes.txt", "sheet.csv", "clip.mp4"] {
            check("opens in place: \(name)", AppState.isOpenableDocument(file(name)))
        }

        // Not documents: shown in Finder, never handed to the system to run.
        for name in ["installer.command", "run.sh", "thing.scpt", "panel.prefPane",
                     "bookmark.webloc", "archive.zip", "blob.xyz", "noextension"] {
            check("revealed, not run: \(name)", !AppState.isOpenableDocument(file(name)))
        }

        // A bundle is a directory the system launches.
        let bundle = scratch.appendingPathComponent("Something.app")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        check("revealed, not run: Something.app", !AppState.isOpenableDocument(bundle))
        check("revealed, not run: a plain folder",
              !AppState.isOpenableDocument(scratch))

        // The trap an extension list cannot see: a text file with the executable
        // bit set is a script whatever it is called.
        check("revealed, not run: executable bit on a .txt",
              !AppState.isOpenableDocument(file("innocent.txt", executable: true)))

        // Positive control: the same sieve does say yes to a plain document, so a
        // "no" above means something.
        check("positive control: an ordinary .txt is openable",
              AppState.isOpenableDocument(file("ordinary.txt")))
        // And a real application on this machine, if there is one.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) {
            check("revealed, not run: a real installed app",
                  !AppState.isOpenableDocument(calculator))
        }

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
