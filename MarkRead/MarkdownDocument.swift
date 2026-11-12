import CryptoKit
import Darwin
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
        /// Nothing is at the path any more: the file was moved, renamed or
        /// deleted while it was open. Writing would quietly bring it back.
        case missingOnDisk(URL)
        /// The file is read-only (locked in Finder, `chmod 444`). The folder may
        /// still allow a rename, so a save would go through — the user is asked.
        case readOnly(URL)
        case writeFailed(URL, underlying: String)
        /// The text no longer fits the encoding the file was read with. Never
        /// resolved here: switching encodings rewrites every byte in the file,
        /// including the ones nobody touched, so the user is asked first.
        case notRepresentable(URL, encoding: String.Encoding)
        var errorDescription: String? {
            switch self {
            case .changedOnDisk(let url):
                "\(url.lastPathComponent) changed on disk since it was opened."
            case .missingOnDisk(let url):
                "\(url.lastPathComponent) is no longer where it was opened from."
            case .readOnly(let url):
                "\(url.lastPathComponent) is read-only."
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
    /// What the file looked like at the last successful read or write.
    ///
    /// Not the modification date alone. A date only moves one way in the check
    /// that used it — "newer by more than half a second" — and a file put back
    /// with an *older* date (`cp -p`, `rsync -t`, a restore from backup, iCloud
    /// from a Mac whose clock is behind) looked untouched, so the next save wiped
    /// the other version (dynamic audit 2026-11-12, D-S-P1-03). Size and a digest
    /// of the bytes say whether the contents are still ours, whatever the date.
    private var known: Snapshot?
    /// The byte order mark the file began with, written back in front of the text.
    ///
    /// Decoding swallows the BOM, so writing the decoded string back silently
    /// drops it. Measured across 3331 real notes: one file had one, and one file is
    /// enough — this program's whole promise is that saving changes nothing it was
    /// not asked to change. Kept as bytes, not a flag: a UTF-16 big-endian file
    /// came back little-endian, every byte different (D-S-P3-01).
    private(set) var byteOrderMark = Data()
    var hadByteOrderMark: Bool { !byteOrderMark.isEmpty }

    private struct Snapshot: Equatable {
        let size: Int
        let digest: Data

        init(_ data: Data) {
            size = data.count
            digest = Data(SHA256.hash(data: data))
        }
    }

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

        guard let decoded = Self.decode(data, hint: Self.recordedEncoding(of: url)) else { throw LoadError.notText(url) }

        self.url = url
        self.text = decoded.text
        self.encoding = decoded.encoding
        self.byteOrderMark = decoded.bom
        self.known = Snapshot(data)
        self.isDirty = false
    }

    // MARK: - Reading the bytes

    /// Text, the encoding it is in, and the byte order mark in front of it.
    ///
    /// Every answer here must give back the same bytes when encoded again —
    /// checked at the end, not trusted. `String(contentsOf:usedEncoding:)` used
    /// to do the guessing: it turned UTF-16 big-endian with a BOM into
    /// little-endian on save, and refused Latin-1, Windows-1250, Mac Roman and
    /// UTF-16 without a BOM as "not text" (D-S-P3-01, D-S-P3-02).
    static func decode(_ data: Data, hint: String.Encoding? = nil) -> (text: String, encoding: String.Encoding, bom: Data)? {
        let marks: [(Data, String.Encoding)] = [
            (Data([0xEF, 0xBB, 0xBF]), .utf8),
            (Data([0xFF, 0xFE, 0x00, 0x00]), .utf32LittleEndian),   // before UTF-16 LE: same first two bytes
            (Data([0x00, 0x00, 0xFE, 0xFF]), .utf32BigEndian),
            (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFE, 0xFF]), .utf16BigEndian),
        ]
        for (mark, encoding) in marks where data.starts(with: mark) {
            let body = Data(data.dropFirst(mark.count))
            if let text = String(data: body, encoding: encoding), text.data(using: encoding) == body {
                return (text, encoding, mark)
            }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8, Data()) }
        // What TextEdit and other editors record beside the bytes beats any guess.
        if let hint, let text = String(data: data, encoding: hint), text.data(using: hint) == data {
            return (text, hint, Data())
        }
        if let encoding = utf16WithoutMark(data),
           let text = String(data: data, encoding: encoding),
           text.data(using: encoding) == data, !hasControlCharacters(text) {
            return (text, encoding, Data())
        }
        // One byte per character. Any byte sequence decodes in Latin-1, so a PNG
        // with `.md` on it would "open" — control bytes are what tell text from
        // binary. Windows-1250 first: the Polish code page, and it agrees with
        // Latin-1 on most Western letters. Which one is right cannot be known from
        // the bytes; what matters is that saving gives the same bytes back.
        guard !data.contains(where: isBinaryByte), !looksLikeDamagedUTF8(data) else { return nil }
        for encoding in [String.Encoding.windowsCP1250, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), text.data(using: encoding) == data {
                return (text, encoding, Data())
            }
        }
        return nil
    }

    /// `com.apple.TextEncoding` — how macOS records a text file's encoding,
    /// e.g. `iso-8859-1;513`.
    static func recordedEncoding(of url: URL) -> String.Encoding? {
        let name = "com.apple.TextEncoding"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0, length < 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length,
              let value = String(bytes: buffer, encoding: .utf8),
              let charset = value.split(separator: ";").first else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(String(charset) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// UTF-16 without a BOM shows itself in the zero bytes: plain text is mostly
    /// ASCII, and each ASCII character has a zero on the same side every time.
    private static func utf16WithoutMark(_ data: Data) -> String.Encoding? {
        guard data.count >= 2, data.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (index, byte) in data.enumerated() where byte == 0 {
            if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let units = data.count / 2
        if oddZeros * 10 >= units * 3, evenZeros * 10 < units { return .utf16LittleEndian }
        if evenZeros * 10 >= units * 3, oddZeros * 10 < units { return .utf16BigEndian }
        return nil
    }

    /// UTF-8 with a bad byte or a cut-off end — not a one-byte encoding. Opened
    /// as Windows-1250 it would show every Polish letter as two wrong ones, and
    /// the next save would mix two encodings in one file. Refused as before.
    private static func looksLikeDamagedUTF8(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var valid = 0, invalid = 0, index = 0
        while index < bytes.count {
            let lead = bytes[index]
            let length = lead < 0x80 ? 1 : lead >= 0xC2 && lead <= 0xDF ? 2 : lead >= 0xE0 && lead <= 0xEF ? 3
                : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0
            if length == 1 { index += 1; continue }
            if length > 0, index + length <= bytes.count,
               bytes[(index + 1) ..< (index + length)].allSatisfy({ $0 & 0xC0 == 0x80 }) {
                valid += 1
                index += length
            } else {
                invalid += 1
                index += 1
            }
        }
        return valid > 0 && valid >= invalid
    }

    private static func isBinaryByte(_ byte: UInt8) -> Bool {
        (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0C && byte != 0x0D) || byte == 0x7F
    }

    private static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x80 && isBinaryByte(UInt8($0.value)) }
    }

    // MARK: - Saving

    /// Writes the buffer back to the same file.
    ///
    /// - Parameter force: skip the on-disk checks (changed, moved or deleted).
    ///   Only ever passed after the user has been shown the problem and chosen
    ///   to write anyway.
    /// - Parameter allowReadOnly: write a read-only file. Only after asking.
    func save(force: Bool = false, convertingToUTF8: Bool = false, allowReadOnly: Bool = false) throws {
        // The file the path points at, not the path. `.atomic` renamed the new
        // bytes over the *name*, so a symbolic link became an ordinary file: the
        // real note kept its old text and the edit went into a copy nobody else
        // sees (dynamic audit 2026-11-12, D-S-P1-02).
        let target = url.resolvingSymlinksInPath()
        let path = target.path
        var info = stat()
        let exists = stat(path, &info) == 0

        if exists, (info.st_mode & S_IFMT) == S_IFDIR {
            throw SaveError.writeFailed(url, underlying: "there is a folder at that path now")
        }
        if !force {
            // Moved or deleted while open: writing used to recreate the file in
            // the old place without a word — two files where there was one, or a
            // deleted note back from the dead (D-S-P2-03).
            guard exists else { throw SaveError.missingOnDisk(url) }
            if let known, Self.snapshot(of: target) != known {
                throw SaveError.changedOnDisk(url)
            }
        }
        // The rename below needs only the folder to be writable, so a locked
        // file was replaced without a question (D-S-P2-01).
        if exists, !allowReadOnly, Darwin.access(path, W_OK) != 0 {
            throw SaveError.readOnly(url)
        }

        let targetEncoding: String.Encoding = convertingToUTF8 ? .utf8 : encoding
        guard let encoded = text.data(using: targetEncoding) else {
            // No silent `?? text.data(using: .utf8)` here. A Latin-1 note that
            // gains one character outside its code page would have been rewritten
            // whole as UTF-8 — every byte in the file, not just the new ones —
            // while `encoding` still said Latin-1, so the next save tried the
            // same doomed conversion again. The caller asks the user instead.
            throw SaveError.notRepresentable(url, encoding: encoding)
        }
        // Converting to UTF-8 drops a UTF-16 or UTF-32 mark; a UTF-8 one stays.
        let mark = (convertingToUTF8 && targetEncoding != encoding && byteOrderMark != Data([0xEF, 0xBB, 0xBF]))
            ? Data() : byteOrderMark
        let data = mark + encoded

        // Said here, about the folder: otherwise the message names the
        // temporary file the rename would have used.
        if !(exists && info.st_nlink > 1), Darwin.access(target.deletingLastPathComponent().path, W_OK) != 0 {
            throw SaveError.writeFailed(url, underlying: "the folder it is in does not allow saving")
        }
        do {
            if exists, info.st_nlink > 1 {
                try Self.writeInPlace(data, to: path, mode: info.st_mode)
            } else {
                try Self.writeReplacing(data, at: target, mode: exists ? info.st_mode : nil)
            }
        } catch {
            throw SaveError.writeFailed(url, underlying: error.localizedDescription)
        }
        if convertingToUTF8 {
            encoding = .utf8
            byteOrderMark = mark
        }
        known = Snapshot(data)
        isDirty = false
    }

    /// A hard link is one file under two names. Renaming new bytes over one name
    /// split them: the other name kept the old text (D-S-P3-03). So the bytes go
    /// into the file itself. Not atomic — a crash mid-write can leave it short —
    /// which is the price of keeping both names on the same note.
    private static func writeInPlace(_ data: Data, to path: String, mode: mode_t) throws {
        let writable = Darwin.access(path, W_OK) == 0
        if !writable { chmod(path, (mode & 0o7777) | S_IWUSR) }
        defer { if !writable { chmod(path, mode & 0o7777) } }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
    }

    /// New bytes in a file beside the old one, then one rename over it: a crash
    /// leaves either the old file or the new one, never half of each.
    ///
    /// Done by hand instead of `.atomic` so the new file gets everything before
    /// it takes the old one's place: extended attributes first (see
    /// `extendedAttributes`), permissions last. Restoring attributes *after* the
    /// rename failed on a read-only file — `setxattr` needs write access — and
    /// the error was swallowed, so a locked note lost its Finder tag (D-S-P2-01).
    private static func writeReplacing(_ data: Data, at target: URL, mode: mode_t?) throws {
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).markread-\(UUID().uuidString)")
        try data.write(to: temporary, options: .withoutOverwriting)
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: temporary) } }
        if mode != nil { restore(extendedAttributes(of: target), to: temporary) }
        if let mode { chmod(temporary.path, mode & 0o7777) }
        guard rename(temporary.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        moved = true
    }

    /// Size and digest of what is on disk now; `nil` when it cannot be read.
    private static func snapshot(of url: URL) -> Snapshot? {
        (try? Data(contentsOf: url)).map(Snapshot.init)
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

    /// Puts them on the new file before it replaces the old one.
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
        byteOrderMark = fresh.byteOrderMark
        known = fresh.known
        isDirty = false
    }

    /// True when the file changed underneath us since the last read or write.
    /// Also true when the file is gone: what is on disk is not what was read.
    var changedOnDisk: Bool {
        guard let known else { return false }
        return Self.snapshot(of: url.resolvingSymlinksInPath()) != known
    }
}
