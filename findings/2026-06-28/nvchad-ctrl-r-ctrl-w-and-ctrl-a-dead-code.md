---
agent: nvchad-user
severity: SEV-2
---

## SEV-2 `Ctrl+R Ctrl+W` and `Ctrl+R Ctrl+A` in INSERT silently paste register 'w'/'a' instead of word-under-cursor

**Reproduction**:
```
{"cmd":"open","path":"sample.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"type","text":"f"}              // f<char>: jump to char on line
{"cmd":"type","text":"l"}              // → cursor lands on 'l' of "lazy" (col 36)
{"cmd":"key","key":"o"}                // open new line below in INSERT
{"cmd":"key","key":"ctrl+r"}
{"cmd":"key","key":"ctrl+w"}           // vim canonical: insert word-under-cursor ("lazy")
{"cmd":"key","key":"escape"}
{"cmd":"snapshot"}
// New line 2 is EMPTY. Should contain "lazy".
```

Same shape for `Ctrl+R Ctrl+A` (insert WORD-under-cursor).

**Expected**: vim insert canon — `<C-R><C-W>` types the word the cursor sits on into the buffer; `<C-R><C-A>` types the whitespace-delimited WORD. Used reflexively when refactoring (yank the symbol name into a search-replace, into a fresh comment, etc.). The `editor.insert_word_under_cursor` and `editor.insert_bigword_under_cursor` commands exist (registered in `src/command.rs:1113-1124`) and DO work via direct `run-command`.

**Actual**: The chord is consumed but does nothing visible. The handler treats the second key as a register letter — Ctrl+W's `KeyCode::Char('w')` matches `c.is_ascii_lowercase()` and falls into the register-paste arm. If register 'w' is empty (the usual case), the paste is a no-op. If a user happened to yank into register 'w' earlier, they'd get a confusing paste of that prior content instead.

**Source pointer**: `src/input/vim.rs:796-822` — the `insert_waiting_for_register` branch. The lowercase-letter check at line 803 comes BEFORE the `c == 'w' && ctrl` check at line 810. Because `'w'` is lowercase, the FIRST arm always wins and the `ctrl` arm is unreachable:

```rust
let valid = c.is_ascii_lowercase() || c == '0' || c == '+' || c == '_' || c == '"';
if valid {
    return InputResult::Ops(vec![SetRegisterHint(Some(c)), Paste]);
}
// `Ctrl+R Ctrl+W` — paste the word under the cursor inline
if c == 'w' && ctrl {        // ← dead code, never reached
    ...
}
```

Fix shape: gate the lowercase-letter arm on `!ctrl`, or reorder so the Ctrl+W/Ctrl+A arms come first.

**Notes**: The command IDs (`editor.insert_word_under_cursor` / `editor.insert_bigword_under_cursor`) are real and palette-reachable, so users CAN do it — just not via the canonical vim chord. Cheatsheet's "vim insert" section already advertises `Ctrl+R "` and `Ctrl+R a..z` but not the Ctrl+W/Ctrl+A sub-chords (probably correct now that they're broken; restore when fixed).
