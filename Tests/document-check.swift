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
        exit(failures == 0 ? 0 : 1)
    }
}
