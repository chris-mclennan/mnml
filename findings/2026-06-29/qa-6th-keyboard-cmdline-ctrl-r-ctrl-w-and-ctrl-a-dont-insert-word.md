---
agent: vscode-user-keyboard
severity: SEV-2
---

# Vim cmdline `Ctrl+R Ctrl+W` / `Ctrl+R Ctrl+A` don't insert word under cursor

**Verified on:** HEAD 029b0fe · `--input vim` · NORMAL → cmdline

**Repro**
1. Switch to vim (`run-command editor.use_vim`).
2. Open a buffer; position cursor inside a word (e.g. `greeting` on line 2 of a hello-world `.rs`).
3. Type `:` to open cmdline.
4. Send `{"cmd":"key","key":"ctrl+r"}` then `{"cmd":"key","key":"ctrl+w"}`.

**Expected** (matches Neovim, Vim, IdeaVim, VS Code Vim ext)
Cmdline buffer becomes `:greeting` (the word under cursor at the time `:` was opened).

The same with `Ctrl+R Ctrl+A` should yield the WORD (whitespace-delimited token) under cursor.

**Actual**
- `Ctrl+R` is silently consumed. No "register insert pending" indicator (which Vim shows as a literal `"` glyph).
- The follow-up `Ctrl+W` does nothing (cmdline stays `:`).
- Variant `Ctrl+R Ctrl+A` produces a stray `r` character with the cursor positioned to the LEFT of it (`:▏r`) — i.e. one of the two key events was treated as a literal-character insert with wrong cursor placement.

**Why this hurts**
"Find the next reference to the word I'm on" via `:%s/<C-r><C-w>/foo/g` is the canonical vim refactor pattern. Without it the refactor flow falls back to typing the word out by hand. The cheatsheet implies vim cmdline mostly works (`vim.dot_repeat` / `vim.macro_replay` are registered) but this fundamental input is missing.

**Suggested scope (not implementing)**
Add a `Ctrl+R` pending-register state to the cmdline input handler that recognises the special registers `Ctrl+W` (word) / `Ctrl+A` (WORD) / `Ctrl+L` (line under cursor) plus the named registers `0`-`9`, `a`-`z`, `+`, `"`.

**Related**
`src/input/vim.rs:2349-2363` (bracket prefix handling has the right pattern of "consume only when no Ctrl"); cmdline handling lives separately and doesn't appear to have a register-insert state.
