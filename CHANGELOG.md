# Changelog

## 3.0.1
- Generic examples in the comment-style guidance; no team-specific terms.

## 3.0.0
- Moved to the Strong Force Analytics org; install from the `sfa-plugins` marketplace.
- Card writing and executing guidance: card description style (scenario, solution, steps),
  checklist mirrors the steps, comment style that matches the board's own voice.
- Write mechanics in one place: non-ASCII through files (enforced by `_tr_guard`), one write
  per call, verify what landed.
- More lessons: nested list indent, cover images, GET-only `tr_get`, PowerShell for emoji.
- `tr_card_create` reads the description file with `cat` (fixes curl exit 26 on Windows).
- No hard-coded board, list or member IDs.
