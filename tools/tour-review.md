# Reviewing the tour's shots

You are reading PNGs of mnml-zig's REAL ghostty window (`tools/tour.sh`,
`tools/tour.sh sweep`, or `tools/look.sh shot`). Each `NN-name.png` has a
`NN-name.txt` beside it — the `screen.txt` of the same frame — and the
tour's state list (`tools/tour/tour.py`, `STATES`) says what each shot is
meant to show. The headless corpus already proved the TEXT is right; you
are here for what text cannot show. Open every flagged shot (the run's
`flagged.txt`) and at least skim the rest.

For each shot, look for:

1. **Faded or dimmed surfaces that should not be.** A pane rail, a label,
   a selected row, a chip that reads as greyed out. Only the stepped-back
   (unfocused) pane's rail and deliberately muted hints are dim.
2. **Glyph fallbacks.** A `?`, an empty box, tofu, a replacement
   character, or a plain letter where a Nerd Font / MnmlSymbols icon
   belongs (the rail, tab bar, tree file icons, statusline chips, the
   dock). Compare the same spot in a neighbouring shot.
3. **Wrong-size glyphs.** An icon visibly smaller or larger than its
   neighbours, clipped on one side, or overlapping the next cell.
4. **Blank rows that should not be there.** Especially above a prompt
   in a shell pane, under a header, or at the top of a list.
5. **Overlapping chrome.** A popup drawn over the statusline or rail when
   it should sit inside the editor area, two borders on top of each
   other, a toast covering the thing the state is about.
6. **Truncated labels.** `…` or a cut word where the width clearly had
   room; a header or chip cut mid-word; counts clipped.
7. **The wrong focus cue.** Which pane holds the keys should be obvious:
   its rail bright (the other dimmed), the mode chip naming the right
   surface (`TREE`, `EDIT`, `VIEW`, `HELP`…), the cursor in that pane.
8. **Differences from the Rust screens.** `docs/ui-spec/rust-*.txt` (and
   the `zig-*.txt` dumps for Zig-only surfaces) are what mnml-zig must
   look like. A layout, word, glyph or order that differs is a finding
   unless `docs/ui-spec/README.md` names it as deliberate.
9. **Anything a person would call broken**: misaligned columns, a colour
   that clashes with the theme, text on a background it cannot be read
   on, a scrollbar that does not match its content.

Report each finding as: the shot name, the cells (col,row from the
`.txt`), what you see, what it should be, and how sure you are. Do not
report the masked moving parts (the clock, the version hash, "as of Ns
ago") or a difference the run's own diff already explains.
