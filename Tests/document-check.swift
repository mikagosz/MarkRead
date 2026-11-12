// Headless check for MarkdownDocument. No frameworks, no fixtures.
//
//   cd "Xcode programy/MarkRead"
//   swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//          MarkRead/MarkdownDocument.swift Tests/document-check.swift \
//          -o /tmp/document-check && /tmp/document-check
//
// The point it defends: opening a file and saving it back without editing must
// produce the same bytes. Everything MarkRead does to a note is decoration, so a
// byte that changes here is a byte the program lost.
//
// Pass a folder as an argument to run the same check over real notes:
//   /tmp/document-check ~/Documents/MyVault
import Foundation

@main
struct DocumentCheck {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    static let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("markread-document-check-\(UUID().uuidString)")

    /// Writes `bytes`, opens it, saves it untouched, and returns the bytes after.
    static func roundTrip(_ bytes: Data, name: String) -> Data? {
        let url = scratch.appendingPathComponent(name)
        do {
            try bytes.write(to: url)
            let document = try MarkdownDocument(url: url)
            try document.save(force: true)
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    /// What the dynamic audit of 2026-11-12 found in saving, one case each,
    /// every one with a control that shows the check can fail.
    static func dynamicAuditFixes() {
        let fm = FileManager.default
        func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
        func inode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int) ?? -1 }
        func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
        func refuses(_ document: MarkdownDocument, _ wanted: (MarkdownDocument.SaveError) -> Bool) -> Bool {
            do { try document.save(); return false } catch let error as MarkdownDocument.SaveError {
                return wanted(error)
            } catch { return false }
        }

        // D-S-P1-02: a symbolic link stays a link, the real note gets the edit.
        let real = scratch.appendingPathComponent("vault/real.md")
        let link = scratch.appendingPathComponent("elsewhere/link.md")
        try? fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("original\n".utf8).write(to: real)
        try? fm.createSymbolicLink(at: link, withDestinationURL: real)
        check("positive control: link.md is a symbolic link", isLink(link))
        if let document = try? MarkdownDocument(url: link) {
            document.text = "original\nedit\n"
            try? document.save()
            check("D-S-P1-02 a symbolic link is still a link after saving", isLink(link))
            check("D-S-P1-02 the note the link points at has the edit", bytes(real) == Data("original\nedit\n".utf8))
        }

        // D-S-P1-03: a change with an older, equal or slightly newer date is a change.
        for (name, offset) in [("older", -600.0), ("equal", 0.0), ("+0.3 s", 0.3), ("+2 s (control)", 2.0)] {
            let url = scratch.appendingPathComponent("mtime-\(abs(name.hashValue)).md")
            try? Data("MINE\n".utf8).write(to: url)
            let known = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
            guard let document = try? MarkdownDocument(url: url) else { continue }
            document.text = "MINE\nedit\n"
            try? Data("FROM THE OTHER MAC\n".utf8).write(to: url)
            try? fm.setAttributes([.modificationDate: known.addingTimeInterval(offset)], ofItemAtPath: url.path)
            check("D-S-P1-03 changed on disk, date \(name) → refused",
                  refuses(document) { if case .changedOnDisk = $0 { true } else { false } })
            check("D-S-P1-03 the other version is still there (\(name))", bytes(url) == Data("FROM THE OTHER MAC\n".utf8))
        }
        // Control the other way: only the date moved, the bytes did not.
        let touched = scratch.appendingPathComponent("touched.md")
        try? Data("same\n".utf8).write(to: touched)
        if let document = try? MarkdownDocument(url: touched) {
            document.text = "same\nedit\n"
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: touched.path)
            check("D-S-P1-03 control: a new date on the same bytes saves normally", (try? document.save()) != nil)
        }

        // D-S-P2-01: a read-only file asks first, and keeps its tags when it is written.
        let locked = scratch.appendingPathComponent("locked.md")
        try? Data("locked\n".utf8).write(to: locked)
        try? (locked as NSURL).setResourceValue(["Czerwony"], forKey: .tagNamesKey)
        chmod(locked.path, 0o444)
        if let document = try? MarkdownDocument(url: locked) {
            document.text = "locked\nedit\n"
            check("D-S-P2-01 a read-only file is not written without asking",
                  refuses(document) { if case .readOnly = $0 { true } else { false } })
            check("D-S-P2-01 …and is untouched", bytes(locked) == Data("locked\n".utf8))
            try? document.save(allowReadOnly: true)
            check("D-S-P2-01 after asking the edit is written", bytes(locked) == Data("locked\nedit\n".utf8))
            let tags = (try? URL(fileURLWithPath: locked.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            check("D-S-P2-01 the Finder tag survives on a read-only file", tags == ["Czerwony"], "\(tags)")
            let mode = (try? fm.attributesOfItem(atPath: locked.path))?[.posixPermissions] as? Int ?? -1
            check("D-S-P2-01 it is still read-only", mode == 0o444, String(mode, radix: 8))
        }
        chmod(locked.path, 0o644)

        // D-S-P2-03: moved or deleted while open → asked, not recreated.
        for kind in ["deleted", "moved"] {
            let url = scratch.appendingPathComponent("gone-\(kind).md")
            let away = scratch.appendingPathComponent("gone-\(kind)-moved.md")
            try? Data("x\n".utf8).write(to: url)
            guard let document = try? MarkdownDocument(url: url) else { continue }
            document.text = "x\nedit\n"
            if kind == "deleted" { try? fm.removeItem(at: url) } else { try? fm.moveItem(at: url, to: away) }
            check("D-S-P2-03 \(kind): save asks",
                  refuses(document) { if case .missingOnDisk = $0 { true } else { false } })
            check("D-S-P2-03 \(kind): nothing recreated at the old path", !fm.fileExists(atPath: url.path))
            try? document.save(force: true)
            check("D-S-P2-03 \(kind): \"Save Here\" writes it back", bytes(url) == Data("x\nedit\n".utf8))
        }

        // D-S-P3-01, D-S-P3-02: every encoding comes back byte for byte.
        let text = "# Zażółć gęślą jaźń\nlinia ü é\n"
        let encodings: [(String, Data)] = [
            ("UTF-16 BE + BOM", Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!),
            ("UTF-16 LE + BOM", Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
            ("UTF-16 BE", text.data(using: .utf16BigEndian)!),
            ("UTF-16 LE", text.data(using: .utf16LittleEndian)!),
            ("UTF-32 LE + BOM", Data([0xFF, 0xFE, 0, 0]) + text.data(using: .utf32LittleEndian)!),
            ("Windows-1250", text.data(using: .windowsCP1250)!),
            ("Latin-1", "# Grüße\nlinia ü é\n".data(using: .isoLatin1)!),
            ("Mac Roman", "# Café\nlinia ü é ©\n".data(using: .macOSRoman)!),
        ]
        for (name, original) in encodings {
            let after = roundTrip(original, name: "enc-\(abs(name.hashValue)).md")
            check("D-S-P3-01/02 \(name) opens and saves byte for byte", after == original,
                  "\(original.count) B in, \(after?.count.description ?? "nil (refused)") B out")
        }
        let be = scratch.appendingPathComponent("be-edit.md")
        try? (Data([0xFE, 0xFF]) + "ab\n".data(using: .utf16BigEndian)!).write(to: be)
        if let document = try? MarkdownDocument(url: be) {
            document.text = "abc\n"
            try? document.save()
            check("D-S-P3-01 an edited UTF-16 BE file stays big-endian with its BOM",
                  bytes(be) == Data([0xFE, 0xFF]) + "abc\n".data(using: .utf16BigEndian)!)
        }
        // Control: binary with .md on it is still refused.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data((0 ..< 256).map { UInt8($0) })
        let pngURL = scratch.appendingPathComponent("picture.md")
        try? png.write(to: pngURL)
        check("control: a PNG named .md is still refused", (try? MarkdownDocument(url: pngURL)) == nil)
        let cut = scratch.appendingPathComponent("cut-utf8.md")
        try? Data("# Zażółć gęślą".utf8).dropLast().write(to: cut)
        check("control: UTF-8 with its last character cut off is still refused", (try? MarkdownDocument(url: cut)) == nil)

        // D-S-P3-03: a hard link keeps both names on one file.
        let one = scratch.appendingPathComponent("hard-one.md")
        let two = scratch.appendingPathComponent("hard-two.md")
        try? Data("shared\n".utf8).write(to: one)
        try? fm.linkItem(at: one, to: two)
        check("positive control: the two names share an inode", inode(one) == inode(two))
        if let document = try? MarkdownDocument(url: one) {
            document.text = "shared\nedit\n"
            try? document.save()
            check("D-S-P3-03 both names still share one file", inode(one) == inode(two))
            check("D-S-P3-03 the other name sees the edit", bytes(two) == Data("shared\nedit\n".utf8))
        }

        // No temporary file left beside the notes by any of the saves above.
        let leftovers = (fm.enumerator(atPath: scratch.path)?.allObjects as? [String] ?? [])
            .filter { $0.contains(".markread-") }
        check("no temporary files left behind", leftovers.isEmpty, "\(leftovers)")
    }

    static func main() {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let bom = Data([0xEF, 0xBB, 0xBF])

        let cases: [(String, Data)] = [
            ("plain ascii", Data("# Title\n\nBody.\n".utf8)),
            ("no trailing newline", Data("# Title\n\nBody.".utf8)),
            ("crlf line endings", Data("# Title\r\n\r\nBody.\r\n".utf8)),
            ("utf-8 accents", Data("# Zażółć gęślą jaźń\n\nżółw — ćma\n".utf8)),
            ("utf-8 BOM", bom + Data("# MIT License\n\nCopyright\n".utf8)),
            ("emoji", Data("# 🗒️ Inbox\n\n- [x] ✅ done\n".utf8)),
            ("empty file", Data()),
            ("only newlines", Data("\n\n\n".utf8)),
            ("tabs and trailing spaces", Data("- item\t\n  indented   \n".utf8)),
            ("code fence with backticks", Data("```sh\nswift build\n```\n".utf8)),
            ("backslash escapes", Data("text with \\* star and \\_under\\_\n".utf8)),
        ]

        for (name, bytes) in cases {
            let after = roundTrip(bytes, name: "\(abs(name.hashValue)).md")
            check("byte-identical: \(name)", after == bytes,
                  "\(bytes.count) B in, \(after?.count.description ?? "nil") B out")
        }

        // The BOM specifically: it must survive, and it must not be invented.
        if let withBOM = roundTrip(bom + Data("x\n".utf8), name: "bom.md") {
            check("BOM preserved", withBOM.starts(with: bom))
        }
        if let without = roundTrip(Data("x\n".utf8), name: "nobom.md") {
            check("BOM not invented", !without.starts(with: bom))
        }

        // Positive control: the comparison must notice a change that is real.
        let url = scratch.appendingPathComponent("control.md")
        try? Data("before\n".utf8).write(to: url)
        if let document = try? MarkdownDocument(url: url) {
            check("clean document is not dirty", !document.isDirty)
            document.text = "after\n"
            check("edited document is dirty", document.isDirty)
            try? document.save(force: true)
            let after = (try? Data(contentsOf: url)) ?? Data()
            check("positive control: a real edit does reach the file",
                  after == Data("after\n".utf8))
            check("saved document is clean again", !document.isDirty)
        }

        // Conflict detection: a file touched behind our back must refuse to save.
        let contested = scratch.appendingPathComponent("contested.md")
        try? Data("one\n".utf8).write(to: contested)
        if let document = try? MarkdownDocument(url: contested) {
            document.text = "mine\n"
            // Two seconds: the check allows half a second of filesystem slack.
            try? Data("theirs\n".utf8).write(to: contested)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: contested.path)
            var refused = false
            do { try document.save() } catch { refused = true }
            check("save refuses when the file changed on disk", refused)
            check("overwrite still possible when asked for",
                  (try? document.save(force: true)) != nil)
        }

        // Extended attributes: saving must not strip what the system keeps beside
        // the bytes. The byte-identity cases above are blind to this — they write
        // to fresh temporary files, which have no attributes to lose, so their
        // zero was a dead zero for this whole category.
        let tagged = scratch.appendingPathComponent("tagged.md")
        try? Data("before\n".utf8).write(to: tagged)
        _ = Data("probe".utf8).withUnsafeBytes {
            setxattr(tagged.path, "com.example.probe", $0.baseAddress, 5, 0, 0)
        }
        try? (tagged as NSURL).setResourceValue(["Czerwony"], forKey: .tagNamesKey)

        // Every read on a fresh URL: URL caches resource values on the instance,
        // which is how the conflict check was fooled once already.
        func tagNames(_ url: URL) -> [String] {
            let fresh = URL(fileURLWithPath: url.path)
            return (try? fresh.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        }
        func hasProbe(_ url: URL) -> Bool {
            getxattr(url.path, "com.example.probe", nil, 0, 0, 0) > 0
        }

        check("positive control: the tag and the xattr are there before saving",
              tagNames(tagged) == ["Czerwony"] && hasProbe(tagged))
        if let document = try? MarkdownDocument(url: tagged) {
            document.text = "after\n"
            try? document.save(force: true)
            check("Finder tag survives a save", tagNames(tagged) == ["Czerwony"],
                  "\(tagNames(tagged))")
            check("custom xattr survives a save", hasProbe(tagged))
            check("the edit still reached the file",
                  (try? Data(contentsOf: tagged)) == Data("after\n".utf8))
        }

        // Encoding: a note read as Latin-1 must not be rewritten as UTF-8 behind
        // the user's back. The save refuses; converting is a separate, asked-for
        // step that also records the new encoding.
        //
        // The `com.apple.TextEncoding` xattr is how macOS records the encoding of
        // a text file (TextEdit writes it). Without it the same bytes cannot be
        // decoded at all — measured: `String(contentsOf:usedEncoding:)` throws.
        let latin = scratch.appendingPathComponent("latin.md")
        let latinBytes = "Gr\u{FC}\u{DF}e\n".data(using: .isoLatin1)!
        try? latinBytes.write(to: latin)
        let hint = Data("iso-8859-1;513".utf8)
        _ = hint.withUnsafeBytes {
            setxattr(latin.path, "com.apple.TextEncoding", $0.baseAddress, hint.count, 0, 0)
        }
        if let document = try? MarkdownDocument(url: latin) {
            check("a non-UTF-8 note keeps its own encoding", document.encoding == .isoLatin1,
                  "\(document.encoding)")
            document.text += "note \u{1F5D2}\n"
            // The premise of the next check, stated out loud rather than assumed.
            check("positive control: that character really does not fit the encoding",
                  "\u{1F5D2}".data(using: document.encoding) == nil)
            var refused = false
            do { try document.save(force: true) } catch { refused = true }
            check("save refuses rather than switching encoding silently", refused)
            check("the file on disk is untouched after the refusal",
                  (try? Data(contentsOf: latin)) == latinBytes)
            try? document.save(force: true, convertingToUTF8: true)
            check("converting when asked writes UTF-8",
                  (try? Data(contentsOf: latin)) == Data("Gr\u{FC}\u{DF}e\nnote \u{1F5D2}\n".utf8))
            check("the new encoding is remembered", document.encoding == .utf8)
        } else {
            check("a non-UTF-8 note opens at all", false, "MarkdownDocument threw")
        }

        dynamicAuditFixes()

        // Optional: every .md under a folder given on the command line.
        for path in CommandLine.arguments.dropFirst() {
            var checked = 0, differ = 0
            let root = URL(fileURLWithPath: path)
            if let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let file as URL in walker where file.pathExtension.lowercased() == "md" {
                    guard let original = try? Data(contentsOf: file) else { continue }
                    checked += 1
                    if roundTrip(original, name: "corpus-\(checked).md") != original {
                        differ += 1
                        if differ <= 5 { print("      differs: \(file.path)") }
                    }
                }
            }
            check("corpus byte-identical: \(path) (\(checked) files)", differ == 0, "\(differ) differ")
        }

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) FAILED")
        // `exit` skips the `defer` above, which left this folder behind in the
        // system's temporary directory on every run.
        try? FileManager.default.removeItem(at: scratch)
        exit(failures == 0 ? 0 : 1)
    }
}
