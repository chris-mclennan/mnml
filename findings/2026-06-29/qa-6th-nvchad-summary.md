---
agent: nvchad-user
severity: SEV-summary
---

# QA-6th NvChad hunt — executive summary

**Counts**: SEV-1: 0 · SEV-2: 2 · SEV-3: 1

**45-minute judgment**: mnml at 029b0fe feels solidly vim-shaped for the editing fundamentals. Operator-motion inclusivity (`de`, `ce`, `cw`-equals-`ce`, `dw`-includes-trailing-space, `d$`) all behave to Vim spec. `Ctrl+R Ctrl+W` and `Ctrl+R Ctrl+A` in INSERT correctly insert the word/WORD under cursor (previously eaten by the lowercase-register-paste arm — that fix held). `[c`/`]c` git-hunk chords coexist with `Ctrl+Shift+[/]` fold chords without collision. Drag-select in NORMAL correctly enters VISUAL with the right anchor, right-click in the editor body opens a clean context menu, and the scroll wheel scrolls without leaving NORMAL — the mouse.rs refactor (this iteration's biggest risk) is clean for vim users. Substitute `/g` works, `:q` on a dirty buffer politely refuses, `:w` saves, marks (`ma`, `'a`) land, basic motions (`hjkl`, `gg`/`G`/`3G`, `w`/`b`/`e`, `f<char>`, `%`, `/`, `?`) all behave. Three rough edges remain: `:%s/.../gc` silently no-ops (no confirm UI, no replacement); HTTP block nav (`http.next_block` / `http.prev_block`) silently fails to move the cursor on `.curl` files even though `http.send` parses the same file fine (the d60f36c fix only verified extension acceptance, not cursor movement); and `Ctrl+o` doesn't unwind in-buffer jumps from `G`/`gg`/search (cross-file history works, in-buffer doesn't). None blocks day-to-day editing; the substitute-confirm and HTTP-nav misses are the ones a returning user will notice first.

## Findings
1. SEV-2 — `qa-6th-nvchad-http-block-nav.md` — `http.next_block` / `http.prev_block` silently no-op on `.curl`
2. SEV-2 — `qa-6th-nvchad-subst-confirm.md` — `:%s/foo/bar/gc` confirm flag silently dropped, no replacement
3. SEV-3 — `qa-6th-nvchad-jumplist-G.md` — `Ctrl+o` doesn't unwind in-buffer jumps (G / gg / search)

## Verified clean (no finding)
- yy / dd / p / u / Ctrl+R
- gg / G / 3G / hjkl / w / b / e / f<char> / %
- /search forward, ?reverse, marks (`ma` / `'a`)
- `de` / `ye` / `ce` (inclusive on e-motion's destination char)
- `cw` equals `ce` (no trailing space eaten)
- `dw` includes trailing space (vim convention)
- `d$` / `c$` / `y$` inclusive of last char
- `Ctrl+R Ctrl+W` and `Ctrl+R Ctrl+A` in INSERT (insert word/WORD under cursor)
- `]c` / `[c` (git-hunk chord coexists with fold chord)
- `Ctrl+Shift+[` / `Ctrl+Shift+]` keymap accepts the chord (parse confirmed)
- `editor.toggle_fold` via command id runs (visual confirm needs a foldable buffer; tested empty fold on plain `.txt`)
- Mouse drag in NORMAL enters VISUAL with correct anchor
- Right-click in editor body opens context menu (Go to definition / Find references / Hover info / Rename / Toggle fold / etc.)
- Scroll wheel scrolls without leaving NORMAL
- `<leader>tr` opens right panel · `<leader>t]` cycles next tab · `<leader>t[` cycles prev · `<leader>tx` closes active tab
- `:q` on dirty buffer refuses with `unsaved changes — use :q! to discard`
- `:%s/foo/bar/g` (no `/c`) replaces all matches across the buffer
