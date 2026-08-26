import Foundation
import Observation

/// One markdown file, open for reading and editing.
///
/// The text held here *is* the file: it is what was read, it is what gets
/// written, and nothing converts it to another representation in between.
@Observable
final class MarkdownDocument {

    enum LoadError: LocalizedError {
        /// The bytes could not be read at all: no permission, an unmounted
        /// volume, a file deleted in between.
        case unreadable(URL, underlying: String)
        /// The bytes were read but are not text in any encoding we can guess.
        case notText(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let url, let underlying):
                "Could not open \(url.lastPathComponent): \(underlying)"
            case .notText(let url):
                "\(url.lastPathComponent) is not text in any encoding this app can read."
            }
        }
    }

    enum SaveError: LocalizedError {
        case changedOnDisk(URL)
        case writeFailed(URL, underlying: String)
        /// The text no longer fits the encoding the file was read with. Never
        /// resolved here: switching encodings rewrites every byte in the file,
        /// including the ones nobody touched, so the user is asked first.
        case notRepresentable(URL, encoding: String.Encoding)
        var errorDescription: String? {
            switch self {
            case .changedOnDisk(let url):
                "\(url.lastPathComponent) changed on disk since it was opened."
            case .writeFailed(let url, let underlying):
                "Could not save \(url.lastPathComponent): \(underlying)"
            case .notRepresentable(let url, let encoding):
                "\(url.lastPathComponent) was read as \(String.localizedName(of: encoding)) and now contains characters that encoding cannot store."
            }
        }
    }

    private(set) var url: URL
    /// The raw markdown. Assigning marks the document dirty.
    var text: String { didSet { if text != oldValue { isDirty = true } } }
    private(set) var isDirty = false
    /// Encoding the file was read with, reused on save so a Latin-1 note does not
    /// silently become UTF-8 (and vice versa).
    private(set) var encoding: String.Encoding
    /// Modification date at the moment of the last successful read or write.
    /// Save refuses to run when the file on disk is newer than this.
    private(set) var knownModified: Date?
    /// Whether the file began with a UTF-8 byte order mark.
    ///
    /// Decoding as UTF-8 swallows the BOM, so writing the decoded string back
    /// silently drops three bytes. Measured across 3331 real notes: one file had
    /// one, and one file is enough — this program's whole promise is that saving
    /// changes nothing it was not asked to change.
    private(set) var hadByteOrderMark = false

    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    var displayName: String { url.lastPathComponent }

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Not `try?`. Swallowing the reason turned "no permission" and "the
            // volume went away" into "could not read as text", which is a
            // sentence about the file's contents — and untrue about both.
            throw LoadError.unreadable(url, underlying: error.localizedDescription)
        }

        var used: String.Encoding = .utf8
        var bom = false
        let contents: String
        let body = data.starts(with: Self.byteOrderMark) ? data.dropFirst(3) : data[...]
        if let utf8 = String(data: body, encoding: .utf8) {
            contents = utf8
            used = .utf8
            bom = body.count != data.count
        } else if let guessed = try? String(contentsOf: url, usedEncoding: &used) {
            // A non-UTF-8 file: whatever leading bytes it has belong to that
            // encoding and are already part of what was decoded.
            contents = guessed
        } else {
            throw LoadError.notText(url)
        }

        self.url = url
        self.text = contents
        self.encoding = used
        self.hadByteOrderMark = bom
        self.knownModified = Self.modificationDate(of: url)
        self.isDirty = false
    }

    // MARK: - Saving

    /// Writes the buffer back to the same file.
    ///
    /// - Parameter force: skip the on-disk change check. Only ever passed after
    ///   the user has been shown the conflict and chosen to overwrite.
    func save(force: Bool = false, convertingToUTF8: Bool = false) throws {
        if !force, let known = knownModified,
           let current = Self.modificationDate(of: url),
           current > known.addingTimeInterval(0.5) {
            throw SaveError.changedOnDisk(url)
        }
        let target: String.Encoding = convertingToUTF8 ? .utf8 : encoding
        guard let encoded = text.data(using: target) else {
            // No silent `?? text.data(using: .utf8)` here. A Latin-1 note that
            // gains one character outside its code page would have been rewritten
            // whole as UTF-8 — every byte in the file, not just the new ones —
            // while `encoding` still said Latin-1, so the next save tried the
            // same doomed conversion again. The caller asks the user instead.
            throw SaveError.notRepresentable(url, encoding: encoding)
        }
        let data = hadByteOrderMark ? Self.byteOrderMark + encoded : encoded
        // Read before the write, put back after it: see `extendedAttributes`.
        let attributes = Self.extendedAttributes(of: url)
        do {
            // Atomic: a crash mid-write leaves the previous file intact rather
            // than a truncated one.
            try data.write(to: url, options: .atomic)
        } catch {
            throw SaveError.writeFailed(url, underlying: error.localizedDescription)
        }
        Self.restore(attributes, to: url)
        if convertingToUTF8 { encoding = .utf8 }
        knownModified = Self.modificationDate(of: url)
        isDirty = false
    }

    // MARK: - Extended attributes

    /// Everything the system keeps beside the bytes: Finder tags, Spotlight
    /// comments, provenance, whatever else was put there.
    ///
    /// `.atomic` writes a temporary file and renames it over the old one, so the
    /// file that survives is a *new* file and starts with none of these. POSIX
    /// permissions are copied by the rename; extended attributes are not.
    /// Measured 2026-08-26 on the local disk and inside the iCloud vault: a red
    /// Finder tag and a custom xattr were gone after one save, with a positive
    /// control showing both present beforehand. Saving must change nothing it was
    /// not asked to change, so they are carried across by hand.
    static func extendedAttributes(of url: URL) -> [(name: String, data: Data)] {
        let path = url.path
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, 0) > 0 else { return [] }

        var found: [(name: String, data: Data)] = []
        for piece in names.split(separator: 0) {
            let name = String(decoding: piece.map(UInt8.init(bitPattern:)), as: UTF8.self)
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { continue }
            var buffer = Data(count: length)
            let read = buffer.withUnsafeMutableBytes {
                getxattr(path, name, $0.baseAddress, length, 0, 0)
            }
            guard read > 0 else { continue }
            found.append((name, buffer))
        }
        return found
    }

    /// Puts them back on the file the atomic write left behind.
    ///
    /// Failures are ignored on purpose and one by one: some attributes are the
    /// system's own (`com.apple.provenance` is set on the new file already) and
    /// refusing to write them must not fail a save that has already succeeded.
    static func restore(_ attributes: [(name: String, data: Data)], to url: URL) {
        let path = url.path
        for (name, data) in attributes {
            _ = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
    }

    /// Re-reads the file, throwing away unsaved edits. Used by "Reload" after a
    /// conflict.
    func revert() throws {
        let fresh = try MarkdownDocument(url: url)
        text = fresh.text
        encoding = fresh.encoding
        hadByteOrderMark = fresh.hadByteOrderMark
        knownModified = fresh.knownModified
        isDirty = false
    }

    /// True when the file changed underneath us since the last read or write.
    var changedOnDisk: Bool {
        guard let known = knownModified, let current = Self.modificationDate(of: url) else { return false }
        return current > known.addingTimeInterval(0.5)
    }

    /// Deliberately FileManager and not `url.resourceValues(forKeys:)`.
    ///
    /// URL caches resource values on the instance. Since `self.url` is one
    /// long-lived object, `resourceValues` kept handing back the date read when
    /// the file was opened — so a file edited by something else still looked
    /// untouched and the conflict check below never fired. Caught by
    /// `Tests/document-check.swift`; the attribute call does not cache.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
