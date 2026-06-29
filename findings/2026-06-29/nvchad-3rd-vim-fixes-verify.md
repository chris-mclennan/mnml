---
agent: nvchad-user
severity: SEV-3
verifies: 4ab2730, 54301a9, b767b8cf
---

# Vim qa-sweep fix verification — all 5 items CONFIRMED

Drove `~/Projects/mnml/target/release/mnml --headless --input vim /tmp/mnml-vim-verify-fix` against a 3-line buffer (`The quick brown fox jumps over the lazy dog\nabcdefghij\nshort`) plus a small `code.rs` for the fold tests.

Note: items 1–4 land in **4ab2730** (`src/input/vim.rs`); item 5 (fold chords escaping the bracket prefix) actually shipped earlier in **b767b8cf** (`src/input/vim.rs:2322,2327`), not 4ab2730 — call this out only because the verify prompt attributed it to 4ab2730. The behavior is correct either way.

---

## 1. `de` / `ye` / `ce` off-by-one — CONFIRMED FIXED

Repro: `gg w w y e` then `$ p` on line 1.

- Result: line 1 became `The quick brown fox jumps over the lazy dogbrown` — paste appended **"brown"** (5 chars), not "brow" (4).
- Same buffer, `gg w w d e`: line 1 became `The quick  fox jumps over the lazy dog` — `de` removed exactly "brown" (5 chars), trailing space preserved (matches `:help de`).
- Same buffer, `gg w w c e`: line 1 became `The quick  fox …`, cursor at col 11 (where `b` had been), `mode = INSERT`. Inclusive end + INSERT entry, both right.

Source: `src/input/vim.rs:1996-2009` — the new `inclusive` branch pushes an extra `MoveRight` when the motion is `e`/`E`/`$`/`End`, which extends `SelectStart..cursor` so the destination char is included.

## 2. `cw` = `ce` mapping — CONFIRMED FIXED

Repro: `gg w w c w` then `BIG <Esc>` on "brown".

- Result: line 1 became `The quick BIG fox jumps over the lazy dog` — the space between `BIG` and `fox` is preserved. Old broken form would have produced `BIGfox`.

Source: `src/input/vim.rs:1977-1985` — the `effective_code` swap rewrites `w`→`e` (and `W`→`E`) when the operator is `Change`. Matches `:help cw` ("special case: cw does not include the white space after a word, because 'cw' is interpreted as 'ce'…").

## 3. `d$` / `c$` / `y$` inclusive — CONFIRMED FIXED

Buffer line 2: `abcdefghij` (10 chars).

- `gg j 4l d$` → line 2 becomes `abcd`. From col 5 (`e`) through col 10 (`j`) deleted = 6 chars inclusive. Newline preserved (line 3 still present).
- From line 3 col 1 (`short`) → `d$` leaves an empty line 3 (still 3 lines in buffer, cursor on line 3 col 1).
- `gg 0 f l y$` then `j $ p` → line 2 becomes `abcdlazy dog`. Yanked exactly **"lazy dog"** (8 chars), including the trailing `g`.
- `gg 0 f l c$` → line 1 becomes `The quick  fox jumps over the` (trailing space, `lazy dog` gone), cursor col 31, `mode = INSERT`.

Same `MoveRight` mechanism as item 1 — `$`/`End` flagged inclusive.

## 4. `Ctrl+R Ctrl+W` / `Ctrl+R Ctrl+A` in INSERT — CONFIRMED FIXED

Buffer line 1 after positioning on "brown", `i`, `<C-R><C-W>`, `<Esc>`:
- Line 1: `The quick brownbrown fox …` — inserted **"brown"** (word under cursor), did **not** paste from register `w`.

Buffer line 2 mutated to `foo-bar baz`, cursor on `f` of `foo-bar`, `i`, `<C-R><C-A>`, `<Esc>`:
- Line 2: `foo-barfoo-bar baz` — inserted **"foo-bar"** (the bigWORD, whitespace-delimited), not just "foo". This confirms `<C-A>` routes to the bigword command, not register `a`.

Source: `src/input/vim.rs:796-822` — the `ctrl`-modifier chord arms (`c == 'w' && ctrl`, `c == 'a' && ctrl`) are now checked **before** the lowercase `is_ascii_lowercase()` register-paste arm. Comment block in the diff calls out the ordering bug explicitly.

## 5. `Ctrl+Shift+[` / `Ctrl+Shift+]` folds in NORMAL — CONFIRMED FIXED

Opened `/tmp/mnml-vim-verify-fix/code.rs` with a 5-line `fn hello() { … }` block. Cursor on line 2 (inside `hello`'s body), `Ctrl+Shift+[`:
- Screen redraws line 1 as `fn hello() {    ⋯ 4 hidden`, status-row toast: `folded 4 lines`. The bracket prefix did **not** swallow the chord; `editor.toggle_fold` fired via the global keymap.

Same buffer, `Ctrl+Shift+]`:
- Fold removed; status-row toast: `unfolded 1 fold(s)`. `editor.unfold_all` fired.

Source: `src/input/vim.rs:2322,2327` — the `KeyCode::Char('[')` / `KeyCode::Char(']')` arms now carry `if !ctrl` guards, so Ctrl-modified bracket events fall through the vim prefix machine to the global keymap (`src/command.rs:649,660`) where Ctrl+Shift+[/] are bound. Bare `[c` / `]c` / `[d` / `]d` still enter their respective bracket-prefix.

---

## Summary

All 5 items behave as documented in commits 4ab2730 / b767b8cf. No regressions observed in adjacent flows (`u`/redo unwound the fixes cleanly between sub-tests, `Esc` returned to NORMAL each time, no panics in `mnml.out`).

Relevant absolute paths:
- `/Users/chrismclennan/Projects/mnml/src/input/vim.rs:796-822` — Ctrl+R Ctrl+W/A ordering fix
- `/Users/chrismclennan/Projects/mnml/src/input/vim.rs:1977-2009` — cw→ce swap + inclusive-motion `MoveRight`
- `/Users/chrismclennan/Projects/mnml/src/input/vim.rs:2322,2327` — bracket prefix `if !ctrl` guard
- `/Users/chrismclennan/Projects/mnml/src/command.rs:649,660` — fold keybindings the chord now reaches
