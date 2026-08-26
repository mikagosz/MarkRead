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
    /// True when the walk hit one of its ceilings and the list is a prefix.
    private(set) var truncated = false

    /// Which scan the entries belong to. A slower walk of a bigger folder used
    /// to land on top of a newer one, leaving the sidebar listing a folder that
    /// is no longer open.
    private var generation = 0

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
        truncated = false
        generation += 1
        let mine = generation
        Task {
            let found = await Self.scan(folder)
            guard mine == self.generation else { return }
            self.entries = found.entries
            self.truncated = found.truncated
            self.isScanning = false
        }
    }

    func clear() {
        // Anything still walking belongs to a folder nobody is looking at now.
        generation += 1
        root = nil
        entries = []
        filter = ""
        truncated = false
        isScanning = false
    }

    /// Puts a note that has just been created into the list.
    ///
    /// Cheaper than walking the tree again for one file, and the alternative —
    /// leaving it out until the next scan — means a note you just made is
    /// missing from the folder you made it in.
    func noteCreated(_ url: URL) {
        guard let root else { return }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/"), !entries.contains(where: { $0.url == url }) else { return }
        entries.append(Entry(url: url, relativePath: String(path.dropFirst(rootPath.count + 1))))
        entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
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

    /// Ceilings on one scan. Choosing the Desktop by mistake produced a flat list
    /// of 114 notes, two thirds of them from somebody else's demo vault two
    /// levels down — a list nobody asked for and, until "Close Folder", could not
    /// be got rid of.
    nonisolated private static let maximumDepth = 8
    nonisolated private static let maximumFiles = 5_000

    nonisolated struct Scan {
        var entries: [Entry] = []
        var truncated = false
    }

    nonisolated private static func scan(_ root: URL) async -> Scan {
        await Task.detached(priority: .userInitiated) { walk(root) }.value
    }

    /// A folder holding `.obsidian` is the root of somebody's vault. Chosen
    /// deliberately it is scanned like any other; met *inside* another folder it
    /// is left alone.
    nonisolated private static func isVaultRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path)
    }

    /// Synchronous on purpose: FileManager's directory enumerator cannot be
    /// iterated from an async context, so the walk stays a plain function and the
    /// caller above is the only thing that knows about concurrency.
    nonisolated private static func walk(_ root: URL) -> Scan {
            let fm = FileManager.default
            guard let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return Scan() }

            let rootPath = root.standardizedFileURL.path
            var found: [Entry] = []
            var truncated = false
            for case let url as URL in walker {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if skipped.contains(url.lastPathComponent) || isVaultRoot(url) {
                        walker.skipDescendants()
                    } else if walker.level >= maximumDepth {
                        walker.skipDescendants()
                        truncated = true
                    }
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let path = url.standardizedFileURL.path
                let relative = path.hasPrefix(rootPath + "/")
                    ? String(path.dropFirst(rootPath.count + 1))
                    : url.lastPathComponent
                found.append(Entry(url: url, relativePath: relative))
                if found.count >= maximumFiles {
                    truncated = true
                    break
                }
            }
            return Scan(entries: found.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }, truncated: truncated)
    }
}
