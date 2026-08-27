import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Everything one MarkRead window is looking at.
@Observable
final class AppState {

    /// Shared because the app delegate has to reach it when Finder hands over a
    /// file, and AppKit gives no other route into the SwiftUI scene.
    static let shared = AppState()

    var document: MarkdownDocument?
    let folder = FolderIndex()
    let editor = EditorHandle()

    var alert: Alert?
    /// What is typed in the sidebar's filter field. One field for all three
    /// sections, so it belongs to the window rather than to the folder.
    var sidebarFilter: String = ""
    /// Where the link under the pointer goes, in the form a person reads.
    ///
    /// Shown at the bottom of the window. The editor hides half of every
    /// `](…)` on purpose, so this is the only thing on screen that says what a
    /// link will open before it is opened.
    private(set) var hoveredLink: String?
    /// What the sidebar remembers: pinned notes, notes opened lately, and the
    /// folder that was open last time. Its own list, on purpose —
    /// `NSDocumentController.recentDocumentURLs` was measured empty on this Mac
    /// however many notes had been opened, which is why the sidebar only ever
    /// showed the note on screen.
    let library: NoteLibrary

    /// `defaults` is a seam for the checks, and nothing else: a headless render
    /// of the sidebar must not write into the list the real app is showing.
    init(defaults: UserDefaults = .standard) {
        library = NoteLibrary(defaults: defaults)
        // The folder survives a relaunch. The note on screen does not: reopening
        // a file means reading it, and reading a file the reader has not asked
        // for yet is how an editor loses the argument about whose text it is.
        if let remembered = library.folder {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: remembered.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                folder.open(remembered)
            }
        }
    }
    /// Real state, not a constant. It used to be a `Bool` fed into
    /// `.constant(...)`, which meant the toolbar button next to the system's own
    /// sidebar toggle did nothing at all — two identical icons, one of them
    /// inert. The system provides the button; this only has to hold the state so
    /// the View menu can reach it too.
    var splitVisibility: NavigationSplitViewVisibility = .all

    var sidebarVisible: Bool { splitVisibility != .detailOnly }

    func toggleSidebar() {
        splitVisibility = sidebarVisible ? .detailOnly : .all
    }

    struct Alert: Identifiable {
        enum Kind { case message, saveConflict, confirmOpen(URL), encodingChange }
        let id = UUID()
        let title: String
        let detail: String
        var kind: Kind = .message
    }

    /// The .md types this app opens. Measured on this machine: "public.markdown"
    /// does not exist, the system type for .md is Daring Fireball's.
    static var markdownTypes: [UTType] {
        [UTType("net.daringfireball.markdown"), UTType(filenameExtension: "md")].compactMap { $0 }
    }

    // MARK: - Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Markdown file, or a folder to browse."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    /// Opening a folder and remembering it are one action, so there is no path
    /// through the app that lists a folder without writing it down.
    func openFolder(_ url: URL) {
        folder.open(url)
        library.rememberFolder(url)
    }

    /// Makes an empty note and opens it.
    ///
    /// The file exists on disk before a single character is typed into it, and
    /// that is deliberate: the whole app rests on "the buffer is the file". A
    /// document with no `url` would take saving, conflict detection and
    /// reloading with it.
    func newNote() {
        // Asked here rather than left to `openFile`: refusing down there would
        // leave a new empty file on disk that nobody asked for.
        if let current = document, current.isDirty {
            alert = Alert(title: "Unsaved changes",
                          detail: "Save or revert \(current.displayName) before starting a new note.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.nameFieldStringValue = "Untitled.md"
        panel.message = "Where should the new note go?"
        // The folder in the sidebar first, then the folder of the note on screen.
        panel.directoryURL = folder.root ?? document?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The panel has already asked about replacing an existing file;
            // asking a second time here would not make the answer any truer.
            try Data().write(to: url)
        } catch {
            alert = Alert(title: "Could not create", detail: error.localizedDescription)
            return
        }
        openFile(url)
        folder.noteCreated(url)
    }

    /// Routes a file or folder to the right place. Called from the Open panel,
    /// from the sidebar, and from Finder via the app delegate.
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            alert = Alert(title: "Not found", detail: url.path)
            return
        }
        if isDirectory.boolValue {
            openFolder(url)
            return
        }
        openFile(url)
    }

    func openFile(_ url: URL) {
        if let current = document, Self.sameFile(current.url, url) {
            // The file is already open, and re-reading it here is what the guard
            // below used to wave through: control fell straight into the reload,
            // the buffer was replaced with the bytes from disk, and the typed
            // text was gone. With a dirty buffer it was worse than gone — the
            // replacement took the whole process with it. Reloading on purpose
            // is "Reload from Disk".
            return
        }
        if let current = document, current.isDirty {
            // Losing typed text to a stray click in the sidebar is exactly the
            // kind of thing the ladder says not to economise on.
            alert = Alert(title: "Unsaved changes",
                          detail: "Save or revert \(current.displayName) before opening another file.")
            return
        }
        do {
            document = try MarkdownDocument(url: url)
            library.noteOpened(url)
            // Deliberately does *not* index the file's folder. It used to, and a
            // single note opened from the Desktop pulled 114 files out of two
            // unrelated vaults into the sidebar. With no folder chosen the
            // sidebar shows this note and the ones opened before it.
        } catch {
            alert = Alert(title: "Could not open", detail: error.localizedDescription)
        }
    }

    /// Two URLs naming the same file. Finder, `open -a` and a relative link all
    /// arrive with different spellings of the same path. One implementation, in
    /// `NoteLibrary`, because the sidebar has to answer the same question about
    /// the same files.
    static func sameFile(_ a: URL, _ b: URL) -> Bool { NoteLibrary.same(a, b) }

    // MARK: - Saving

    func save() {
        guard let document else { return }
        // A save with nothing to save still rewrote the file from scratch, and
        // every rewrite is another chance to lose the file's Finder tag.
        guard document.isDirty else { return }
        do {
            try document.save()
        } catch MarkdownDocument.SaveError.notRepresentable(_, let encoding) {
            alert = Alert(
                title: "Different encoding",
                detail: "\(document.displayName) was read as \(String.localizedName(of: encoding)) and now contains characters that encoding cannot store. Saving as UTF-8 rewrites the whole file, including the parts you did not touch.",
                kind: .encodingChange)
        } catch MarkdownDocument.SaveError.changedOnDisk {
            alert = Alert(title: "Changed on disk",
                          detail: "\(document.displayName) was modified by something else since you opened it. Overwrite it with your version, or reload and lose your edits?",
                          kind: .saveConflict)
        } catch {
            alert = Alert(title: "Could not save", detail: error.localizedDescription)
        }
    }

    func saveOverwriting() {
        guard let document else { return }
        do { try document.save(force: true) } catch {
            alert = Alert(title: "Could not save", detail: error.localizedDescription)
        }
    }

    /// Only ever reached through the question above: converting rewrites every
    /// byte of the file, not just the new ones.
    func saveAsUTF8() {
        guard let document else { return }
        do { try document.save(convertingToUTF8: true) } catch {
            alert = Alert(title: "Could not save", detail: error.localizedDescription)
        }
    }

    func closeFolder() {
        folder.clear()
        library.rememberFolder(nil)
    }

    // MARK: - The sidebar's own list

    /// Notes dropped on the sidebar, or handed over several at a time by Finder.
    ///
    /// Folders among them are opened as folders — dropping a folder on a list of
    /// notes means "list this", not "remember this file".
    func add(_ urls: [URL]) {
        var notes: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                openFolder(url)
            } else if Self.isNote(url) {
                notes.append(url)
            }
        }
        library.pin(notes)
    }

    /// What may be pinned: the extensions this app can actually edit. Dropping a
    /// PDF on the note list would make a row that opens something else.
    static func isNote(_ url: URL) -> Bool {
        editableExtensions.contains(url.pathExtension.lowercased())
    }

    func unpin(_ url: URL) { library.unpin(url) }
    func forget(_ url: URL) { library.forget(url) }
    func pin(_ url: URL) { library.pin([url]) }

    func reloadFromDisk() {
        guard let document else { return }
        do { try document.revert() } catch {
            alert = Alert(title: "Could not reload", detail: error.localizedDescription)
        }
    }

    // MARK: - Links

    /// One place where every clickable thing in a document is decided.
    func follow(_ url: URL) {
        if let target = MarkdownStyle.wikiTarget(from: url) {
            guard let resolved = resolveWiki(target) else {
                let where_ = folder.root?.lastPathComponent ?? document?.url.deletingLastPathComponent().lastPathComponent
                alert = Alert(title: "No such note",
                              detail: "Nothing named \u{201C}\(target)\u{201D} under \(where_ ?? "the current folder").")
                return
            }
            openFile(resolved)
            return
        }

        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto", "obsidian":
                NSWorkspace.shared.open(url)
            case "file":
                openLocal(url)
            default:
                // Naming four safe schemes was no filter at all while the default
                // branch handed everything else to the same call: `vnc:`,
                // `x-apple-helpbook:` and whatever else a note carries went
                // straight to the system. Now they ask, with the whole target on
                // screen — which the reader cannot get at any other way, because
                // half of every `](…)` is not drawn.
                alert = Alert(title: "Open this link?", detail: url.absoluteString,
                              kind: .confirmOpen(url))
            }
            return
        }

        // A relative link such as "notes/other.md" or "#heading". Resolve it
        // against the file being read.
        guard let base = document?.url.deletingLastPathComponent() else { return }
        let path = url.relativePath
        guard !path.isEmpty, !path.hasPrefix("#") else { return }
        openLocal(URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL)
    }

    /// A `[[Wiki Link]]`: the indexed folder first, then the note's own folder.
    ///
    /// The second half is what keeps a link between two notes sitting next to
    /// each other working now that opening a file no longer indexes its whole
    /// directory tree behind the user's back.
    private func resolveWiki(_ target: String) -> URL? {
        if let found = folder.resolveWikiLink(target, near: document?.url) { return found }
        guard let base = document?.url.deletingLastPathComponent() else { return nil }
        let name = target.lowercased().hasSuffix(".md") ? target : target + ".md"
        let candidate = base.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static let editableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// What a click may open in place, asked of the system rather than of a list
    /// of file extensions.
    ///
    /// A list of *dangerous* extensions can only ever name the ones somebody
    /// thought of — `.app`, `.command`, `.tool`, `.workflow`, `.terminal`,
    /// `.scpt`, and a plain file with the executable bit set and no extension at
    /// all. So the question is turned around: these are the things that get
    /// opened, everything else is shown in Finder instead of being run.
    private static let openableTypes: [UTType] = [
        .image, .pdf, .plainText, .rtf, .audiovisualContent, .spreadsheet, .presentation,
    ]
    /// Checked first, because several of these also conform to something above
    /// (a shell script is plain text).
    private static let neverOpenedTypes: [UTType] = [
        .application, .executable, .unixExecutable, .script, .osaScript, .shellScript,
        .systemPreferencesPane, .internetLocation,
    ]

    private func openLocal(_ url: URL) {
        if Self.editableExtensions.contains(url.pathExtension.lowercased()) {
            openFile(url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert = Alert(title: "Not found", detail: url.path)
            return
        }
        if Self.isOpenableDocument(url) {
            NSWorkspace.shared.open(url)
        } else {
            // Shown, not run. Someone who really wants to run it still can, and
            // will see what they are running when they do.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// True for a file the system calls a document and does not call executable.
    static func isOpenableDocument(_ url: URL) -> Bool {
        // A fresh URL for every question: URL caches resource values on the
        // instance, which has fooled this project once already.
        let fresh = URL(fileURLWithPath: url.path)
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isDirectoryKey, .isPackageKey,
                                         .isExecutableKey, .isSymbolicLinkKey]
        guard let values = try? fresh.resourceValues(forKeys: keys),
              let type = values.contentType else { return false }
        if values.isDirectory == true || values.isPackage == true
            || values.isSymbolicLink == true || values.isExecutable == true { return false }
        if neverOpenedTypes.contains(where: { type.conforms(to: $0) }) { return false }
        return openableTypes.contains { type.conforms(to: $0) }
    }

    // MARK: - Hovering

    func hoverLink(_ url: URL?) {
        hoveredLink = url.map(describe)
    }

    /// A link target as a person reads it: a wiki link by name, a file by path,
    /// anything else in full so an unusual scheme is impossible to miss.
    private func describe(_ url: URL) -> String {
        if let target = MarkdownStyle.wikiTarget(from: url) { return "[[\(target)]]" }
        if url.isFileURL { return abbreviated(url) }
        if url.scheme == nil, let base = document?.url.deletingLastPathComponent() {
            return abbreviated(URL(fileURLWithPath: url.relativePath, relativeTo: base).standardizedFileURL)
        }
        return url.absoluteString
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
