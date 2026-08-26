import Foundation
import Markdown

// Checks MarkdownScanner against swift-markdown — the parser Xcode and DocC use.
//
//   cd Tests/Oracle
//   swift run -c release oracle ~/some/vault
//
// The scanner here is line-local by design, so perfect agreement is not the goal
// and a mismatch is not automatically a bug. What this defends is narrower and
// worth defending: where swift-markdown says "this span is a link / inline code /
// a heading of level N", MarkRead must not disagree — those are exactly the
// constructs the program promises to show correctly.

// MARK: - Offsets

/// swift-markdown reports positions as 1-based line and column counted in UTF-8
/// bytes. Everything here works in UTF-16 offsets, because that is what NSRange
/// and NSString use. Polish text makes the difference real, not theoretical:
/// "ż" is two bytes and one UTF-16 unit.
struct OffsetTable {
    private let utf16ForByte: [Int]
    private let lineStartByte: [Int]

    init(_ text: String) {
        var map: [Int] = []
        map.reserveCapacity(text.utf8.count + 1)
        var lines: [Int] = [0]
        var utf16 = 0
        var byte = 0
        for character in text {
            let bytes = String(character).utf8.count
            for _ in 0 ..< bytes { map.append(utf16) }
            byte += bytes
            utf16 += character.utf16.count
            if character == "\n" { lines.append(byte) }
        }
        map.append(utf16)
        self.utf16ForByte = map
        self.lineStartByte = lines
    }

    func utf16Offset(line: Int, column: Int) -> Int? {
        let index = line - 1
        guard index >= 0, index < lineStartByte.count else { return nil }
        let byte = lineStartByte[index] + (column - 1)
        guard byte >= 0, byte < utf16ForByte.count else { return nil }
        return utf16ForByte[byte]
    }

    func range(_ source: SourceRange) -> NSRange? {
        guard let start = utf16Offset(line: source.lowerBound.line, column: source.lowerBound.column),
              let end = utf16Offset(line: source.upperBound.line, column: source.upperBound.column),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Collecting what the oracle says

struct Expectation {
    enum Kind: String { case link, inlineCode, heading, strong, emphasis, codeBlock }
    let kind: Kind
    let range: NSRange
    let detail: String
}

struct Collector: MarkupWalker {
    let table: OffsetTable
    var found: [Expectation] = []

    mutating func record(_ kind: Expectation.Kind, _ markup: Markup, _ detail: String) {
        guard let source = markup.range, let range = table.range(source) else { return }
        found.append(Expectation(kind: kind, range: range, detail: detail))
    }

    mutating func visitLink(_ link: Link) {
        record(.link, link, link.destination ?? "")
        descendInto(link)
    }
    mutating func visitInlineCode(_ code: InlineCode) {
        record(.inlineCode, code, code.code)
    }
    mutating func visitHeading(_ heading: Heading) {
        record(.heading, heading, String(heading.level))
        descendInto(heading)
    }
    mutating func visitStrong(_ strong: Strong) {
        record(.strong, strong, "")
        descendInto(strong)
    }
    mutating func visitEmphasis(_ emphasis: Emphasis) {
        record(.emphasis, emphasis, "")
        descendInto(emphasis)
    }
    mutating func visitCodeBlock(_ block: CodeBlock) {
        record(.codeBlock, block, "")
    }
}

// MARK: - Comparing

struct Tally {
    var checked = 0
    var agreed = 0
    var examples: [String] = []

    mutating func add(_ ok: Bool, _ example: @autoclosure () -> String) {
        checked += 1
        if ok { agreed += 1 } else if examples.count < 4 { examples.append(example()) }
    }

    var percent: Double { checked == 0 ? 100 : Double(agreed) / Double(checked) * 100 }
}

func decorations(_ text: NSString) -> [Decoration] {
    let map = BlockMap.build(text)
    return MarkdownScanner.decorations(text: text, map: map, lines: 0 ..< map.lines.count)
}

/// True when some decoration of a matching style overlaps `range`.
func agrees(_ expectation: Expectation, _ decorations: [Decoration], _ text: NSString) -> Bool {
    let overlapping = decorations.filter { NSIntersectionRange($0.range, expectation.range).length > 0 }
    switch expectation.kind {
    case .link:
        return overlapping.contains {
            if case .link(let target) = $0.style { return target == expectation.detail || expectation.detail.isEmpty }
            if case .wikiLink = $0.style { return true }
            return false
        }
    case .inlineCode:
        return overlapping.contains { $0.style == .code }
    case .heading:
        return overlapping.contains {
            if case .heading(let level) = $0.style { return String(level) == expectation.detail }
            return false
        }
    case .strong:
        return overlapping.contains { $0.style == .bold || $0.style == .boldItalic }
    case .emphasis:
        return overlapping.contains { $0.style == .italic || $0.style == .boldItalic }
    case .codeBlock:
        return overlapping.contains { $0.style == .code }
    }
}

// MARK: - Main

let roots = Array(CommandLine.arguments.dropFirst())
guard !roots.isEmpty else {
    print("użycie: oracle <katalog> [katalog…]")
    exit(2)
}

var files: [URL] = []
for root in roots {
    let url = URL(fileURLWithPath: root)
    guard let walker = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
    for case let file as URL in walker where file.pathExtension.lowercased() == "md" {
        files.append(file)
    }
}

var tallies: [Expectation.Kind: Tally] = [:]
var parsed = 0
let started = Date()

for file in files {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    parsed += 1
    let ns = text as NSString
    let document = Document(parsing: text)
    var collector = Collector(table: OffsetTable(text))
    collector.visit(document)
    let mine = decorations(ns)

    for expectation in collector.found {
        var tally = tallies[expectation.kind] ?? Tally()
        tally.add(agrees(expectation, mine, ns),
                  "\(file.lastPathComponent): \(ns.substring(with: expectation.range).prefix(60).debugDescription)")
        tallies[expectation.kind] = tally
    }
}

print("plików: \(parsed), czas: \(Int(Date().timeIntervalSince(started) * 1000)) ms\n")
print(String(format: "%-12@ %8@ %8@ %8@", "konstrukcja" as NSString, "wg cmark" as NSString,
             "zgodnych" as NSString, "%" as NSString))
var worst = 100.0
for kind in [Expectation.Kind.heading, .link, .inlineCode, .codeBlock, .strong, .emphasis] {
    guard let tally = tallies[kind] else { continue }
    print(String(format: "%-12@ %8d %8d %7.1f%%", kind.rawValue as NSString,
                 tally.checked, tally.agreed, tally.percent))
    worst = min(worst, tally.percent)
}
print()
for kind in [Expectation.Kind.heading, .link, .inlineCode, .codeBlock, .strong, .emphasis] {
    guard let tally = tallies[kind], !tally.examples.isEmpty else { continue }
    print("rozbieżności — \(kind.rawValue):")
    for example in tally.examples { print("   \(example)") }
}

// Floors, measured on a real corpus rather than guessed. They are not 100% and
// are not meant to be — what is left below each one is a deliberate design
// difference, not a defect:
//
//   heading    front matter. cmark without the extension reads "name: x" over
//              "---" as a setext heading; an Obsidian editor must not.
//   inlineCode the same: code spans inside front matter are metadata here.
//   strong /   multi-line emphasis. This scanner is line-local by design, which
//   emphasis   is what keeps re-styling inside a frame budget on a large note.
//   codeBlock  code blocks indented by four spaces. Same reason, and the same
//              decision: BlockMap is a per-line state machine that knows fences
//              and front matter, and it is rebuilt on every keystroke. Seeing an
//              indented block is not one more condition — it has to remember
//              whether the line before was blank (an indented block cannot
//              interrupt a paragraph) and tell four spaces of code from four
//              spaces of list continuation. Fenced blocks are seen, inside
//              blockquotes too; indented ones are out of scope.
//
// A drop below a floor means something broke. Raise a floor when a real fix
// earns it — link and codeBlock were raised once already, after this oracle
// found that a link labelled with code was dropped and that fences inside
// blockquotes were not seen.
//
// 🔴 Do not lower a floor to make the run go green. codeBlock went the other way
// exactly once, 98.0 → 97.0 on 2026-08-27, and only because the cause had been
// measured first and turned out to be the design difference above rather than a
// regression: 1092 of 1120 spans agree (97.5%) on a 667-file corpus, the same
// oracle built against the previous swift-markdown revision gives the identical
// number, and a synthetic file holding one indented and one fenced block scores
// 50% with the indented one as the mismatch. The corpus had grown by notes that
// paste measurement output as an indented block; nothing in the scanner moved.
// Without that chain of measurements, a red oracle means the code is wrong, not
// the floor.
let floors: [Expectation.Kind: Double] = [
    .heading: 92.0, .link: 99.5, .inlineCode: 99.0,
    .codeBlock: 97.0, .strong: 83.0, .emphasis: 67.0,
]
var failed = false
for (kind, floor) in floors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    guard let tally = tallies[kind] else { continue }
    if tally.percent < floor {
        failed = true
        print(String(format: "SPADEK: %@ %.1f%% < próg %.1f%%", kind.rawValue as NSString,
                     tally.percent, floor))
    }
}
print(failed ? "\nWYROCZNIA: SPADEK ZGODNOŚCI" : "\nWyrocznia: zgodność w normie.")
exit(failed ? 1 : 0)
