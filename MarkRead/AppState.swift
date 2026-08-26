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
        enum Kind { case message, saveConflict }
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
        folder.open(url)
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
            folder.open(url)
            return
        }
        openFile(url)
    }

    func openFile(_ url: URL) {
        if let current = document, current.isDirty, current.url != url {
            // Losing typed text to a stray click in the sidebar is exactly the
            // kind of thing the ladder says not to economise on.
            alert = Alert(title: "Unsaved changes",
                          detail: "Save or revert \(current.displayName) before opening another file.")
            return
        }
        do {
            document = try MarkdownDocument(url: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // Opening a loose file with no folder chosen yet: index its own
            // folder, so wiki links and the sidebar have somewhere to look.
            if folder.root == nil {
                folder.open(url.deletingLastPathComponent())
            }
        } catch {
            alert = Alert(title: "Could not open", detail: error.localizedDescription)
        }
    }

    // MARK: - Saving

    func save() {
        guard let document else { return }
        do {
            try document.save()
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
            guard let resolved = folder.resolveWikiLink(target, near: document?.url) else {
                alert = Alert(title: "No such note",
                              detail: "Nothing named “\(target)” under \(folder.root?.lastPathComponent ?? "the current folder").")
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
                NSWorkspace.shared.open(url)
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

    private static let editableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    private func openLocal(_ url: URL) {
        if Self.editableExtensions.contains(url.pathExtension.lowercased()) {
            openFile(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
