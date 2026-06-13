# nvchad-user — mnml bug hunt — 2026-06-10

## Executive summary

- SEV-1: 4
- SEV-2: 10
- SEV-3: 5

After ~45 minutes pretending to be an NvChad user driving headless vim mode at `/tmp/mnml-nvchad-hunt`, mnml feels **broadly vim-shaped on the surface** (modal state machine works, `i/Esc/v/V/:` flips modes, most operators land, leader+which-key fires, splits/tabs have the right ex-commands) **but the cliff edges are exactly where muscle memory falls over**. Three classes dominate:

1. **`Ctrl+R` and `<leader>r` are footguns** — both should be redo / rename-ish in any vim-flavored UI, but mnml wires them to "recent files picker" and "restart mnml". `u u u Ctrl-r` blows away the running app.
2. **`ZZ` and `:q` quit the app instead of closing the buffer.** Close one buffer, lose them all.
3. **`/` search dialog is broken** — input field never clears between uses, so successive searches concatenate ("sixeighteight"). No history. `type` of `/foo\n` doesn't reliably submit because the overlay's Enter handling is keystroke-batch-sensitive.

Plenty of bones are right: `gg`, `5G`, `yy/p`, `dd`, `dw`, `ciw`, `f<char>`, `%`, marks (`ma`/`'a`), macros (`qa…q` + `@a`), `:vsplit`/`:split`/`Ctrl+W h/l/c`, `:tabnew`/`gt`/`gT`/`:tabclose`, `:%s/x/y/g`, range delete (`:3,5d`), settings overlay nav, leader-fb/ff/fg pickers.

---

## SEV-1

### S1-01 — `Ctrl+R` opens recent-files picker, overrides vim redo

`Ctrl+R` in NORMAL mode is `:h CTRL-R` — redo. mnml's global `recent-files` command swallows it first. After `u u u`, reflexive `Ctrl+R` fires the picker overlay instead of redoing. Source: `src/input/keymap.rs:125-139` reserves `Ctrl+W/G/D/U/E/Y` for vim mode but not `Ctrl+R`.

### S1-02 — `<leader>r` = "restart mnml" wipes the running app

Visible in the which-key popup as `r → restart mnml`. `events.jsonl` shows `{"event":"exit","restart":true}`; mnml exits and `run.sh` rebuilds. Source: `src/whichkey.rs` chord entry under root `+<leader>`.

### S1-03 — `ZZ` quits the entire app instead of closing the buffer

`status.json` shows `quit: true`. Any unsaved work elsewhere is at risk. Probably mapped to `app.quit` / `buffer.close_and_save` with the wrong scope; `ZQ` likely matches.

### S1-04 — `/` find dialog never clears its input buffer between uses

`/` then `five`, `Enter`, then `/` reopens with `five` still in the field. New chars append (`fiveeight`); statusline shows `no matches for "fiveeight"`. Source: Find overlay state in `src/ui/` persists across opens; needs reset on enter.

---

## SEV-2

- **S2-01** `:q` quits the entire app even when other buffers are open. Should close just the current window when others remain.
- **S2-02** `:%s/.../.../g` is not a single undo step — needs one `u` per replaced line.
- **S2-03** `/foo<CR>` typed as one `type` payload doesn't reliably submit; literal text gets appended to the stale prompt buffer.
- **S2-04** `p` paste after `$` (end-of-line) pastes onto the next line — `$` lands cursor at col 9 (past last char), p writes at start of line 2.
- **S2-05** `G` (bare) lands on a phantom line past the last line (`cursor.line = 11` on 10-line file). `10G` works. Bare-`G` handler uses trailing-newline byte instead of `last_line_index`. Same family: `Ctrl-D` on a small file.
- **S2-06** Macro count prefix `5@a` is silent no-op. `5dd`, `5G` work — macro-replay is the outlier.
- **S2-07** `Ctrl+W l` from tree focus does not move focus to editor pane. Tree consumes `l` as "expand right". Tree handler should recognize `Ctrl+W` as window-prefix.
- **S2-08** `:e!` and `:edit!` don't reload the buffer from disk — `!` suffix dropped by ex parser.
- **S2-09** `:bd!` does not force-close a dirty buffer — same `!`-suffix-drop bug.
- **S2-10** Unfocused-tab editor `Ctrl+W c` behavior unclear; close-pty-pane missing (cross-ref with vscode-keyboard S1-01).

---

## SEV-3

- **S3-01** `Ctrl+W >` / `<` / `+` / `-` (resize splits) do nothing — mouse-drag works, keyboard path missing.
- **S3-02** `$` lands one cell past EOL (col 9 on 8-char line). Companion to S2-05.
- **S3-03** VISUAL-LINE (`V`) and VISUAL-BLOCK (`Ctrl-V`) both report mode as `VISUAL`. NvChad statusline distinguishes them.
- **S3-04** `V` (visual line) snaps cursor down one line on entry.
- **S3-05** `*` doesn't advance cursor to the next match. Statusline shows search registered; cursor stays put.

---

## What I tested and found clean

Motions: `gg`, `G`-with-count (`5G`, `10G`), `j/k/h/l`, `f<char>`, `%` bracket-match. Operators: `dd`, `dw`, `D`, `cc`, `ciw`, `yy`. Single-step `u` (small edits). Substitute `:%s/x/y/g`. Range delete `:3,5d` (single undo correctly atomic). Save `:w`. Buffer cycle `:bn`/`:bp`/`:bnext`/`:bprev`. Close clean buffer `:bd`. Splits `:vsplit`/`:split`/`Ctrl+W h/l/c`. Tabs `:tabnew`/`gt`/`gT`/`:tabclose`. Marks `ma`/`'a`. Macros `qa…q`+`@a` (no count). Visual `v` + motion + `y` + `p`. Settings overlay nav. Welcome overlay dismissal. Leader chords `<leader>e` (tree toggle), `<leader>ff`, `<leader>fb`. Which-key popup. `:settings`, `:help`. `Ctrl+B` tree toggle.

## Process notes for future hunts

- `parse_key_spec` in `src/input/keymap.rs:188` does **not** support chord sequences like `"ctrl+w h"` or `"leader f f"`. Multi-step chords must be sent as separate `key` commands.
- `parse_key_spec` does **not** recognize `super+` / `cmd+`, only `ctrl/shift/alt/meta`. `Cmd+W` etc. unreachable via IPC.
- The headless loop exits the moment `should_quit` flips. SEV-1/2 findings that kill the process leave subsequent IPC commands queued with no consumer. Restart between such tests.
