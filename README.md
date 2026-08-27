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
  block quotes and Obsidian callouts are styled where they sit. Tables are drawn
  with a closed, rounded frame. Whichever look is on, a colour is only ever laid
  on a run that is still plain body text, so bold inside a heading keeps the
  heading's colour rather than punching a hole in it.
- **Working links.** Named links, bare URLs, relative paths and `[[Wiki Links]]`
  are all clickable. A wiki link resolves against the folder in the sidebar, or
  against the note's own folder when no folder is open; a relative path resolves
  against the file you are reading. Option-click places the caret instead, for
  editing link text. Where a link goes is shown at the bottom of the window while
  the pointer is over it — necessary, because the `](…)` half is not drawn.
- A sidebar listing every note under a chosen folder, with a filter field, and
  "Close Folder" to let go of it again. With no folder open the list shows the
  note you have open and the ones you opened before it.
- Drop a `.md` file on the window to open it.
- **New Note** (⌘N, or the pencil in the toolbar): the save panel picks the name
  and the place, the file is created empty and opened like any other. There is no
  such thing here as a document without a file.
- Settings (⌘,) for the reading face, its size, and one of four **looks**. A
  Markdown file stores no appearance of its own — every program that opens it
  invents one — so rather than guess, MarkRead offers four:

  - **MarkRead** — headings in the system accent, emphasis and code coloured.
  - **Like Xcode** — matched to Xcode's own theme file rather than to a
    screenshot. Three heading sizes, none of them bold, level three and below at
    half alpha, code at body size, and Xcode's own background, border and link
    colours. Spacing follows the same source: the font's leading and no paragraph
    spacing at all, because the gap between two blocks is the blank line already
    standing between them in the file.
  - **Plain** — no colour except links; headings differ by size only.
  - **Dark Claude color** — the Claude Code palette. Unlike the other three this
    one is a *theme* rather than an appearance: it keeps its dark colours with the
    Mac set to light, so it carries its own editor background, caret and
    selection.

  Code, table rows and front matter take a **code font** of their own, and only
  fixed-pitch faces are offered for it — a table shown as raw markdown is hand-aligned text, and
  hand-aligned columns only line up when every character is the same width. A
  proportional family is refused outright, not merely left out of the picker.
- Editing commands under the Format menu: bold, italic, strikethrough,
  highlight, inline code, headings 1–3, lists, tasks, quotes, code blocks, links.
- Save refuses to run when the file changed on disk since it was opened, and
  offers to overwrite or reload.
- Saving preserves the file's extended attributes — Finder tags, Spotlight
  comments — which an atomic write drops by default, and does nothing at all when
  there is nothing to save.
- macOS text substitutions (smart quotes, em dashes, auto-correct) are switched
  off. In a markdown file those are data loss.

## Installing

There is no installer and no signed release: build it and copy it.

1. Open `MarkRead.xcodeproj` in Xcode and build (⌘B). The app lands in
   `~/Library/Developer/Xcode/DerivedData/…/Build/Products/`.
2. Copy `MarkRead.app` to `/Applications`. Running it from DerivedData works, but
   the copy is what survives a clean build.
3. To open every `.md` with it: select a file in Finder, ⌘I, "Open with" →
   MarkRead → "Change All…". MarkRead declares itself an *alternate* handler for
   `.md` (`LSHandlerRank = Alternate`), so it never takes the extension over on
   its own.

To uninstall, delete the app. Two small files stay behind on disk:

```
~/Library/Preferences/com.mikagosz.MarkRead.plist
~/Library/Application Support/com.apple.sharedfilelist/…/com.mikagosz.markread.sfl4
```

The first is window geometry, sidebar state and the two Settings values (font
family and text size); the second is the list of recently opened documents.
Neither holds anything else.

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
| `SettingsView.swift` | The Settings scene: look, reading face, text size, code face |

## Tests

Headless, no frameworks. All seven run in under a second. Two of them read a
fixture from `Tests/Fixtures/`; the rest carry their own input.

```sh
swiftc -parse-as-library MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
       MarkRead/MarkdownTables.swift \
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

The third checks what a click on a link is allowed to do:

```sh
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
       MarkRead/AppState.swift MarkRead/MarkdownDocument.swift MarkRead/FolderIndex.swift \
       MarkRead/MarkdownStyle.swift MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
       MarkRead/MarkdownTables.swift MarkRead/MarkdownTableRenderer.swift \
       MarkRead/MarkdownTextView.swift MarkRead/EditorActions.swift \
       Tests/links-check.swift -o /tmp/links-check && /tmp/links-check
```

The fourth checks the Format menu's wrap commands, which edit the file: an empty
selection between two markers must not swallow them, and a bold word must not
come back italic because ⌘I found one star on each side.

```sh
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
       MarkRead/EditorActions.swift Tests/editor-check.swift \
       -o /tmp/editor-check && /tmp/editor-check
```

The fifth checks what colour a construct ends up in — that emphasis never paints
over a colour something else was given first, and that each look's numbers are
the ones it claims:

```sh
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
       MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
       MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
       Tests/style-check.swift -o /tmp/style-check && /tmp/style-check
```

The sixth reads the colours back out of `Tests/Fixtures/palette.md` — a page
holding every construct at once — and compares them with the hex values the
palette names. It runs under the **light** appearance deliberately: a theme that
keeps its dark colours whatever the Mac is set to will hide anything still
reaching past the palette for a system colour, because that comes out dark on a
dark ground.

```sh
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
       MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
       MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
       Tests/palette-check.swift -o /tmp/palette-check && /tmp/palette-check
```

The seventh draws a table into a bitmap and samples the pixels of its frame,
against a fixture whose rows alternate between ending in a link and ending in
plain text. A table whose cells all end the same way cannot show the fault it
defends against — a border drawn in whatever colour the last glyph left behind:

```sh
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
       MarkRead/MarkdownSyntax.swift MarkRead/MarkdownScanner.swift \
       MarkRead/MarkdownTables.swift MarkRead/MarkdownStyle.swift \
       MarkRead/MarkdownTableRenderer.swift \
       Tests/table-border-check.swift -o /tmp/table-border-check \
  && /tmp/table-border-check
```

### Seeing a change

`Tests/render-shot.swift` is not a test but a pair of eyes: it builds the real
editor in an off-screen window and saves what it drew, so work on a look stops
being a matter of opinion. It takes the look, a scroll fraction, an appearance
and a window width — the appearance is set on the window, not on the machine, so
both can be checked without touching what the Mac is set to.

```sh
./render-shot note.md xcode /tmp/out.png 0.8 light 620
```

### The oracle

`Tests/Oracle` is a separate Swift package that checks this project's line
scanner against [swift-markdown](https://github.com/swiftlang/swift-markdown) —
the parser Xcode and DocC use — over a corpus of real notes:

```sh
cd Tests/Oracle
swift run -c release oracle ~/Documents/SomeVault
```

It prints, per construct, how many spans cmark found, how many this scanner
agrees with, and the percentage; a construct falling below its recorded threshold
exits non-zero. The thresholds are **not** 100%, on purpose. The scanner is
line-local by design — that is what keeps re-highlighting inside a frame budget
on a 200 000-character note — so emphasis spanning several lines is the largest
known gap. The oracle exists to notice a *drop*, not to demand a parser this
program deliberately does not have.

It is a separate package so that swift-markdown never becomes a dependency of the
app itself.

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

Where it earns its place is as an *oracle in the tests*, and that is where it
lives: `Tests/Oracle` parses a corpus with swift-markdown and checks that this
scanner agrees about where the blocks and inline spans are. That does not touch
the fast path, and it catches the edge cases a line scanner gets wrong (reference
links, lazy continuation, nested emphasis). See "The oracle" above for how to run
it and what its thresholds mean.

## Requirements

macOS 26 or later. Built with Xcode 27 and Swift 6.

## Privacy and what a click can do

MarkRead does not connect to the network: there is no `URLSession` in it and
nothing is sent anywhere. It reads and writes the Markdown files you point it at,
plus the two files listed under "Installing".

Following a link is the one thing that reaches outside the app, and a note is a
document that can come from anyone, so it is worth being exact about it:

| What you click | What happens |
|---|---|
| `http`, `https`, `mailto`, `obsidian` | handed to your default handler |
| any other scheme (`vnc:`, `x-apple-helpbook:`, …) | you are asked first, with the full target shown |
| a Markdown file | opened in MarkRead |
| another document — image, PDF, text, audio, video, spreadsheet, presentation | opened with its default app |
| anything else, including apps, scripts, executables, bundles and file types not listed above | **revealed in Finder, never launched** |

The last row is the point. `NSWorkspace.open` on a `.app`, a `.command` or a
plain file with the executable bit set *runs* it, and the target is not visible in
a rendered document until you hover it. Deciding by content type rather than by a
list of dangerous extensions means a type nobody thought of lands on the safe side
by default.

## Licence

The MIT licence in [LICENSE](LICENSE) covers the source code.

The app has no third-party dependencies. The test oracle depends on
[swift-markdown](https://github.com/swiftlang/swift-markdown), which is licensed
under Apache 2.0 with a Runtime Library Exception; it is pinned to a release and
is not linked into the application.

It does **not** cover the application artwork in `MarkRead/markread icon.icon`,
which is Copyright (c) 2026 mikagosz, all rights reserved. See [NOTICE](NOTICE).
If you fork this project, replace the icon with your own.
