# MarkRead

A small macOS Markdown reader and editor. It opens a `.md` file fast, shows it
formatted with working links, and lets you edit it in place.

## The one design rule

**The text in the editor is the file.** The buffer holds the raw markdown —
the same bytes that are on disk — and formatting is applied as *decoration*
over those characters. Nothing is ever converted to another representation and
serialized back.

That is not a stylistic preference. An editor that parses markdown into a rich
model and re-writes it on save loses whatever its parser does not understand:
backticks around a shell command, an escaped `\*`, `~~strikethrough~~`,
formatting inside a heading. MarkRead cannot lose those, because it never
rewrites the line they are on.

The property is checked, not assumed. `Tests/document-check.swift` opens a file,
saves it untouched, and compares bytes.

## Hidden, not removed

Syntax that carries no meaning once the text is formatted — heading hashes,
emphasis stars, backticks, and above all the `](https://…)` half of every link —
is **not drawn** while the caret is on another line. Put the caret on the line
and it comes back, which is how you edit it.

The characters are never touched. Their glyphs are suppressed in
`layoutManager(_:shouldGenerateGlyphs:…)`, so the buffer, the undo stack and the
file all still contain every byte. This is what makes a table of links readable
at all: in a real note the URLs are longer than the rows they belong to.

## What it does

- Live preview in one column: headings, emphasis, code, tables, task lists,
  block quotes and Obsidian callouts are styled where they sit.
- **Working links.** Named links, bare URLs, relative paths and `[[Wiki Links]]`
  are all clickable. A wiki link resolves against the folder in the sidebar;
  a relative path resolves against the file you are reading. Option-click places
  the caret instead, for editing link text.
- A sidebar listing every note under a chosen folder, with a filter field.
- Editing commands under the Format menu: bold, italic, strikethrough,
  highlight, inline code, headings 1–3, lists, tasks, quotes, code blocks, links.
- Save refuses to run when the file changed on disk since it was opened, and
  offers to overwrite or reload.
- macOS text substitutions (smart quotes, em dashes, auto-correct) are switched
  off. In a markdown file those are data loss.

## Layout

| File | What lives there |
|---|---|
| `MarkdownSyntax.swift` | `Decoration`, and the line-level `BlockMap` (fences, front matter) |
| `MarkdownScanner.swift` | Pure markdown → `[Decoration]`. No UI, no side effects. |
| `MarkdownStyle.swift` | `Decoration` → text attributes |
| `MarkdownTables.swift` | Second pass for tables: dims pipes, hides the `\|---\|` row |
| `MarkdownTableRenderer.swift` | Lays out and draws tables as real tables |
| `MarkdownTextView.swift` | The NSTextView, link hit-testing, visible-range highlighting |
| `MarkdownDocument.swift` | One open file: read, save, conflict detection |
| `FolderIndex.swift` | The sidebar's file list and wiki-link resolution |
| `AppState.swift` | What one window is looking at; where links are followed |
| `EditorActions.swift` | The Format menu commands |

## Tests

Headless, no frameworks, no fixtures. Both run in under a second.

```sh
swiftc -parse-as-library MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
       Tests/scanner-check.swift -o /tmp/scanner-check && /tmp/scanner-check

swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
       MarkRead/MarkdownDocument.swift Tests/document-check.swift \
       -o /tmp/document-check && /tmp/document-check
```

`document-check` takes optional folder arguments and will round-trip every `.md`
underneath them:

```sh
/tmp/document-check ~/Documents/SomeVault
```

## Performance

Re-highlighting on a keystroke costs one linear pass for the block map plus the
lines actually on screen — measured at roughly 5.6 ms together on a 212 000
character, 3 544 line note. Off-screen text is styled when it scrolls into view.

`MarkdownTextView` uses TextKit 1 explicitly, because the highlighter needs a
layout manager for hit testing and visible-range maths. That tops out on very
large documents; the way past it is a TextKit 2 viewport-based highlighter.

## Tables

Tables are laid out and drawn as real tables — bordered cells, per-cell word
wrapping, a shaded header — while the markdown behind them is untouched.

The trick is that no space is created and no character is moved. Each source line
of the table is given a paragraph style whose line height equals the height of
the row it holds, and all of its glyphs are suppressed. The renderer then draws
each row into the space its own line reserved: one source line, one table row.
Put the caret inside the table and the whole block reverts to markdown, which is
how you edit it.

Column widths use **water filling**, not proportional shrinking: a column
narrower than its fair share keeps its natural width and only the wide columns
are capped. Shrinking everything by the same ratio takes as much from a date
column as from a description, and a date column too narrow for `25.08.2026`
wraps every row for nothing.

Cell text is switched from the row's monospaced face to the body face — except
runs marked `.markReadCode`, which are genuinely code. A narrow column plus a
monospaced font breaks words mid-syllable.

An earlier attempt aligned columns with a kerning attribute instead. It is worth
knowing why that is gone: it works on a narrow table and is worse than nothing on
a wide one, because a seven-column table does not fit the window, every padded
row wraps onto three display lines, and the columns land somewhere different on
each of them.

## On swift-markdown

[swift-markdown](https://github.com/swiftlang/swift-markdown) is the parser Xcode
and DocC use (cmark-gfm underneath), and matching it exactly is the only way to
be sure a file reads the way Xcode reads it. MarkRead does **not** use it for
live styling, for two reasons.

`Document(parsing:)` parses the whole document; the highlighter here re-runs on
every keystroke and is line-local by design, which is what keeps it inside a
frame budget on a 200 000-character note. And the library's `MarkupFormatter`
rebuilds text from the AST on the way out, which would rewrite indentation, blank
lines and list markers on a plain open-and-save — the exact failure this program
exists to avoid.

Where it would earn its place is as an *oracle in the tests*: parse a corpus with
swift-markdown and check that this scanner agrees about where the blocks and
inline spans are. That does not touch the fast path and would catch the edge
cases a line scanner gets wrong (reference links, lazy continuation, nested
emphasis).

## Requirements

macOS 26 or later. Built with Xcode 27 and Swift 6.

## Privacy

MarkRead does not connect to the network. It reads and writes the Markdown files
you point it at, and nothing else. Following a link hands the URL to your default
browser; that is the only thing that leaves the app.

## Licence

The MIT licence in [LICENSE](LICENSE) covers the source code.

It does **not** cover the application artwork in `MarkRead/markread icon.icon`,
which is Copyright (c) 2026 mikagosz, all rights reserved. See [NOTICE](NOTICE).
If you fork this project, replace the icon with your own.
