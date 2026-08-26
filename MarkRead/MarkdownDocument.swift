import Foundation
import Observation

/// One markdown file, open for reading and editing.
///
/// The text held here *is* the file: it is what was read, it is what gets
/// written, and nothing converts it to another representation in between.
@Observable
final class MarkdownDocument {

    enum LoadError: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                "Could not read \(url.lastPathComponent) as text."
            }
        }
    }

    enum SaveError: LocalizedError {
        case changedOnDisk(URL)
        case writeFailed(URL, underlying: String)
        var errorDescription: String? {
            switch self {
            case .changedOnDisk(let url):
                "\(url.lastPathComponent) changed on disk since it was opened."
            case .writeFailed(let url, let underlying):
                "Could not save \(url.lastPathComponent): \(underlying)"
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
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(url) }

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
            throw LoadError.unreadable(url)
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
    func save(force: Bool = false) throws {
        if !force, let known = knownModified,
           let current = Self.modificationDate(of: url),
           current > known.addingTimeInterval(0.5) {
            throw SaveError.changedOnDisk(url)
        }
        guard let encoded = text.data(using: encoding) ?? text.data(using: .utf8) else {
            throw SaveError.writeFailed(url, underlying: "text is not representable")
        }
        let data = hadByteOrderMark ? Self.byteOrderMark + encoded : encoded
        do {
            // Atomic: a crash mid-write leaves the previous file intact rather
            // than a truncated one.
            try data.write(to: url, options: .atomic)
        } catch {
            throw SaveError.writeFailed(url, underlying: error.localizedDescription)
        }
        knownModified = Self.modificationDate(of: url)
        isDirty = false
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
