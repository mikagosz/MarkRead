# Table border regression

Reported 2026-08-27: a table drew its border blue under some rows and white under
others. The rows that came out blue were the ones whose **last** cell ended in a
link; the rows that came out white ended in plain text.

Cause: `NSColor.set()` sets the stroke colour as well as the fill, and
`NSLayoutManager.drawGlyphs` calls `set` on every run's foreground colour. The
border colour was chosen *before* the glyph loop and stroked *after* it, so the
frame was drawn in whatever colour the last glyph run left behind.

What makes this file catch it: the rows alternate between ending in a link and
ending in plain text, so a border that follows the text changes colour from row
to row. A table whose cells all end the same way cannot show the fault at all.

| Date | Role | Company | Rate | Source |
|---|---|---|---|---|
| 23.08.2026 | Manual tester | Company One | no data | [Listing](https://example.dev) |
| 23.08.2026 | Test engineer | Company Two | 100–120 | [Listing](https://example.dev) *(unstable link)* |
| 22.08.2026 | Automation engineer | Company Three | 100–115 | [Listing](https://example.dev) |
| 22.08.2026 | Automation tester | Company Four | 8 000–13 000 | [Listing](https://example.dev) *(unstable link)* |
| 18.08.2026 | Test automation | Company Five | no data | [Listing](https://example.dev) |
