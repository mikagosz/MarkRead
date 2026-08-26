import Foundation
import Observation

/// The markdown files under one folder, for the sidebar.
@Observable
final class FolderIndex {

    nonisolated struct Entry: Identifiable, Hashable {
        let url: URL
        /// Path relative to the indexed root, used as the sidebar label.
        let relativePath: String
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        /// The folder part, or "" for files sitting directly in the root.
        var parent: String {
            let parts = relativePath.split(separator: "/")
            return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
        }
    }

    private(set) var root: URL?
    private(set) var entries: [Entry] = []
    private(set) var isScanning = false

    /// Free-text filter typed in the sidebar.
    var filter: String = ""

    var filtered: [Entry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.relativePath.localizedCaseInsensitiveContains(needle) }
    }

    func open(_ folder: URL) {
        root = folder
        isScanning = true
        entries = []
        Task {
            let found = await Self.scan(folder)
            self.entries = found
            self.isScanning = false
        }
    }

    func clear() {
        root = nil
        entries = []
        filter = ""
    }

    /// Best match for a `[[Wiki Link]]` target: exact relative path first, then
    /// file name, case-insensitively. Returns nil when the folder holds no such
    /// note — the caller then says so rather than opening the wrong file.
    func resolveWikiLink(_ target: String, near origin: URL?) -> URL? {
        let wanted = target.hasSuffix(".md") ? String(target.dropLast(3)) : target
        let byPath = entries.first { $0.relativePath.caseInsensitiveCompare(wanted + ".md") == .orderedSame }
        if let byPath { return byPath.url }

        let matches = entries.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        if matches.count <= 1 { return matches.first?.url }
        // Several notes share the name — prefer the one nearest the file we are
        // reading, which is what a link inside that file almost always means.
        if let origin {
            let originFolder = origin.deletingLastPathComponent().path
            if let sibling = matches.first(where: { $0.url.deletingLastPathComponent().path == originFolder }) {
                return sibling.url
            }
        }
        return matches.first?.url
    }

    // MARK: - Scanning

    /// Folders that never hold notes worth listing and can be very large.
    nonisolated private static let skipped: Set<String> = [
        ".git", ".obsidian", ".trash", "node_modules", ".build", ".swiftpm", "DerivedData",
    ]

    nonisolated private static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    nonisolated private static func scan(_ root: URL) async -> [Entry] {
        await Task.detached(priority: .userInitiated) { walk(root) }.value
    }

    /// Synchronous on purpose: FileManager's directory enumerator cannot be
    /// iterated from an async context, so the walk stays a plain function and the
    /// caller above is the only thing that knows about concurrency.
    nonisolated private static func walk(_ root: URL) -> [Entry] {
            let fm = FileManager.default
            guard let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            let rootPath = root.standardizedFileURL.path
            var found: [Entry] = []
            for case let url as URL in walker {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let path = url.standardizedFileURL.path
                let relative = path.hasPrefix(rootPath + "/")
                    ? String(path.dropFirst(rootPath.count + 1))
                    : url.lastPathComponent
                found.append(Entry(url: url, relativePath: relative))
            }
            return found.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }
}
