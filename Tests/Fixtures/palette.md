---
title: Every construct this program colours
note: front matter is a construct too — it should be muted, not body-coloured
---

# Heading one — the largest, and its own colour

Body text. Everything on this page is here so that a look can be *checked*
rather than admired: each construct below names the palette key it is supposed
to be drawn in, so a wrong colour is visible without a colour picker.

## Heading two

### Heading three

#### Heading four — and five and six share this one

##### Heading five

Inline: **bold text**, *italic text*, ***both at once***, `inline code`,
~~struck out~~, ==highlighted==, a [real link](https://example.dev) and a
[[Wiki Link]].

- A bulleted list, where the bullet has its own colour
- Second item, so the marker repeats
  - Nested item

1. An ordered list
2. Second item

- [x] A finished task
- [ ] An unfinished one

> A blockquote. Its text is dimmer than body text, and the `>` in front of it is
> a marker, dimmer still.

> [!warning] A callout label carries the brand accent
> The rest of a callout reads as a quote.

```swift
// A fenced block: the language name above is coloured, the code is not.
let terracotta = "#DA7756"
print(terracotta)
```

Text between two blocks, so the rule below has something to sit between.

---

| Construct | Palette key | What to look at |
|---|---|---|
| Table header | `cdTableHeaderBg` | the ground behind this row |
| Table border | `cdTableBorder` | 🔴 must be **one colour** all the way round |
| A cell with a link | `cdLink` | [Listing](https://example.dev) |
| A cell ending in text | — | plain, so the border has two cases to fail |
| A cell with `code` | `cdInlineCodeText` | terracotta, not grey |

Last paragraph, so the table has a bottom edge to draw against.
