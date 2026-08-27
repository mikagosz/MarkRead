import Foundation
import Observation

/// What the sidebar remembers between launches: the notes pinned to it, the
/// notes opened lately, and the folder that was open.
///
/// This used to be `NSDocumentController.recentDocumentURLs`, and it was empty.
/// Measured 2026-08-27 on this Mac: after opening two notes in a row the app's
/// own `…/com.apple.sharedfilelist/…ApplicationRecentDocuments/…sfl4` still held
/// no items at all — and neither did any other application's on this machine —
/// so the list the sidebar was reading had never had anything in it. The
/// reported symptom, "open one note and then another and the list still shows
/// only the current one", is that list being empty and the sidebar showing the
/// open document out of its own state.
///
/// So the app keeps its own list. Nothing here asks the system anything.
@Observable
final class NoteLibrary {

    /// Notes dropped on the sidebar. Ordered by hand, never dropped on their own.
    private(set) var pinned: [URL] = []
    /// Notes opened lately, newest first. Bounded — a list that never forgets is
    /// a list nobody reads to the bottom of.
    private(set) var recents: [URL] = []
    /// The folder the sidebar is listing, remembered so it is still there after a
    /// relaunch. `nil` when no folder is open.
    private(set) var folder: URL?

    static let recentsLimit = 20

    private let defaults: UserDefaults
    private enum Key {
        static let pinned = "library.pinned"
        static let recents = "library.recents"
        static let folder = "library.folder"
    }

    /// Paths, not bookmarks, and not archived URLs.
    ///
    /// Bookmarks buy one thing this app cannot use — following a file that was
    /// renamed while the app was closed — and cost a resolve on every launch that
    /// can block on a network volume. Paths are also readable in
    /// `defaults read com.mikagosz.MarkRead`, which is where anyone would look
    /// when the list comes back wrong.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinned = (defaults.stringArray(forKey: Key.pinned) ?? []).map { URL(fileURLWithPath: $0) }
        recents = (defaults.stringArray(forKey: Key.recents) ?? []).map { URL(fileURLWithPath: $0) }
        if let path = defaults.string(forKey: Key.folder) { folder = URL(fileURLWithPath: path) }
        refreshAvailability()
    }

    // MARK: - Pinning

    /// Adds notes to the pinned section, keeping the order they arrived in.
    ///
    /// A note that was in the recent list moves out of it: it is in the sidebar
    /// for good now, and having it in both sections twice is just noise.
    func pin(_ urls: [URL]) {
        for url in urls where !contains(pinned, url) {
            pinned.append(url)
        }
        recents.removeAll { url in urls.contains { Self.same($0, url) } }
        save()
    }

    func unpin(_ url: URL) {
        pinned.removeAll { Self.same($0, url) }
        save()
    }

    func isPinned(_ url: URL) -> Bool { contains(pinned, url) }

    /// Reordering the pinned section by dragging inside it.
    ///
    /// Written out rather than taken from `move(fromOffsets:toOffset:)`, which
    /// SwiftUI adds — this file is the model and has no business importing the
    /// view layer to reorder an array. `destination` is SwiftUI's: the index the
    /// rows land *before*, counted in the list as it looks now.
    func movePinned(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { pinned[$0] }
        var rest = pinned
        for index in source.sorted(by: >) { rest.remove(at: index) }
        let removedBefore = source.filter { $0 < destination }.count
        let landing = min(max(0, destination - removedBefore), rest.count)
        rest.insert(contentsOf: moving, at: landing)
        pinned = rest
        save()
    }

    // MARK: - Recents

    /// Records that a note was opened. Pinned notes are left where they are.
    func noteOpened(_ url: URL) {
        guard !isPinned(url) else { return }
        recents.removeAll { Self.same($0, url) }
        recents.insert(url, at: 0)
        if recents.count > Self.recentsLimit { recents.removeLast(recents.count - Self.recentsLimit) }
        save()
    }

    func forget(_ url: URL) {
        recents.removeAll { Self.same($0, url) }
        save()
    }

    func clearRecents() {
        recents.removeAll()
        save()
    }

    // MARK: - Folder

    func rememberFolder(_ url: URL?) {
        folder = url
        save()
    }

    // MARK: - Missing files

    /// Paths that were not there the last time anyone looked.
    ///
    /// Used to grey a row out and **never** to delete one. Half of these notes
    /// live on an iCloud drive or on a share that is not always mounted, and a
    /// list that pruned itself on startup would quietly empty itself the one
    /// morning the NAS was off. Removing a row stays the reader's decision.
    private(set) var missing: Set<String> = []

    func isMissing(_ url: URL) -> Bool { missing.contains(url.path) }

    /// Looks at the disk once, off the main thread.
    ///
    /// 🔴 Not asked from inside the row-drawing code, however tempting that is:
    /// `fileExists` on a share that has gone away does not answer quickly, and
    /// a list of twenty notes redrawn on every keystroke of the filter field
    /// would make the whole window wait for a NAS to time out.
    func refreshAvailability() {
        let paths = (pinned + recents).map(\.path)
        Task {
            let gone = await Self.scanMissing(paths)
            self.missing = gone
        }
    }

    nonisolated private static func scanMissing(_ paths: [String]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            var gone: Set<String> = []
            for path in paths where !FileManager.default.fileExists(atPath: path) { gone.insert(path) }
            return gone
        }.value
    }

    // MARK: - Identity

    /// One spelling of a file path, so the same note arriving from Finder, from
    /// a relative link and from this list is recognised as one note.
    nonisolated static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func contains(_ list: [URL], _ url: URL) -> Bool {
        list.contains { Self.same($0, url) }
    }

    private func save() {
        defaults.set(pinned.map(\.path), forKey: Key.pinned)
        defaults.set(recents.map(\.path), forKey: Key.recents)
        if let folder { defaults.set(folder.path, forKey: Key.folder) }
        else { defaults.removeObject(forKey: Key.folder) }
        refreshAvailability()
    }
}
