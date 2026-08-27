// Headless check of the list the sidebar shows: pinned notes, recent notes, and
// the folder — including that they are still there after a relaunch.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/NoteLibrary.swift Tests/library-check.swift \
//          -o /tmp/library-check && /tmp/library-check
//
// The fault it defends against, reported 2026-08-27: "open one note and then
// another and the list still shows only the current one". The sidebar was
// reading `NSDocumentController.recentDocumentURLs`, and on this Mac that list
// is empty however many notes have been opened — measured in the app's own
// `…ApplicationRecentDocuments/com.mikagosz.markread.sfl4`, which held no items
// after two notes were opened one after the other.
//
// Everything here runs against its own UserDefaults suite, so a check never
// touches the list the real app is showing.
import Foundation

@main
struct LibraryCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    static let suiteName = "com.mikagosz.MarkRead.library-check"

    static func fresh() -> (NoteLibrary, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        return (NoteLibrary(defaults: defaults), defaults)
    }

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/markread-library-check/\(name)")
    }

    static func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    static func main() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let directory = URL(fileURLWithPath: "/tmp/markread-library-check")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // MARK: the reported fault
        var (library, defaults) = fresh()
        library.noteOpened(url("one.md"))
        library.noteOpened(url("two.md"))
        check("a second note does not replace the first",
              names(library.recents) == ["two.md", "one.md"], "— got \(names(library.recents))")

        // MARK: it survives a relaunch
        var reopened = NoteLibrary(defaults: defaults)
        check("the list is still there after a relaunch",
              names(reopened.recents) == ["two.md", "one.md"], "— got \(names(reopened.recents))")

        // MARK: opening the same note again
        library.noteOpened(url("one.md"))
        check("reopening a note moves it up instead of doubling it",
              names(library.recents) == ["one.md", "two.md"], "— got \(names(library.recents))")

        // MARK: the same file spelled two ways
        library.noteOpened(URL(fileURLWithPath: "/tmp/markread-library-check/./one.md"))
        check("two spellings of one path are one note",
              names(library.recents) == ["one.md", "two.md"], "— got \(names(library.recents))")

        // MARK: pinning
        library.pin([url("two.md")])
        check("a pinned note leaves the recent list",
              names(library.pinned) == ["two.md"] && names(library.recents) == ["one.md"],
              "— pinned \(names(library.pinned)), recent \(names(library.recents))")
        library.noteOpened(url("two.md"))
        check("opening a pinned note does not put it in recent as well",
              names(library.recents) == ["one.md"], "— got \(names(library.recents))")
        library.pin([url("two.md")])
        check("pinning twice pins once", library.pinned.count == 1, "— got \(names(library.pinned))")

        // MARK: the bound, and what it may not touch
        for index in 0 ..< (NoteLibrary.recentsLimit + 5) {
            library.noteOpened(url("bulk\(index).md"))
        }
        check("the recent list stops at its limit",
              library.recents.count == NoteLibrary.recentsLimit, "— got \(library.recents.count)")
        check("a pinned note is not pushed off by twenty-five new ones",
              names(library.pinned) == ["two.md"], "— got \(names(library.pinned))")

        // MARK: order by hand
        library.pin([url("alpha.md"), url("beta.md")])
        check("dropped notes arrive in the order they were dropped",
              names(library.pinned) == ["two.md", "alpha.md", "beta.md"],
              "— got \(names(library.pinned))")
        library.movePinned(from: IndexSet(integer: 2), to: 0)
        check("pinned notes can be reordered",
              names(library.pinned) == ["beta.md", "two.md", "alpha.md"],
              "— got \(names(library.pinned))")

        // MARK: taking things out
        library.unpin(url("two.md"))
        check("unpinning removes it", names(library.pinned) == ["beta.md", "alpha.md"],
              "— got \(names(library.pinned))")
        let firstRecent = library.recents.first!
        library.forget(firstRecent)
        check("a recent note can be forgotten",
              !library.recents.contains { NoteLibrary.same($0, firstRecent) })

        // MARK: the folder
        library.rememberFolder(URL(fileURLWithPath: "/tmp/markread-library-check"))
        reopened = NoteLibrary(defaults: defaults)
        check("the folder is remembered across a relaunch",
              reopened.folder?.lastPathComponent == "markread-library-check",
              "— got \(String(describing: reopened.folder))")
        library.rememberFolder(nil)
        reopened = NoteLibrary(defaults: defaults)
        check("closing the folder is remembered too", reopened.folder == nil,
              "— got \(String(describing: reopened.folder))")

        // MARK: a file that is not there
        //
        // The rule being defended: a note on a share that is not mounted is
        // marked, never dropped. A list that pruned itself would empty itself
        // the one morning the NAS was off.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        (library, defaults) = fresh()
        let there = url("present.md")
        let gone = url("absent.md")
        try? "here".write(to: there, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: gone)
        library.pin([there, gone])
        // The look at the disk is deliberately off the main thread; give it one.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        check("a missing note is marked", library.isMissing(gone))
        check("control: a note that is there is not marked", !library.isMissing(there))
        check("a missing note is kept in the list",
              library.pinned.count == 2, "— got \(names(library.pinned))")

        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
