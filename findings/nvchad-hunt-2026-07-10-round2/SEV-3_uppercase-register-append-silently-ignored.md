# [SEV-3] Uppercase register `"A` (append) silently ignored

## Reproduction

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"\"ayy"}
{"cmd":"type","text":"j"}
{"cmd":"type","text":"\"Ayy"}
{"cmd":"type","text":"G"}
{"cmd":"type","text":"o"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"\"ap"}
{"cmd":"snapshot"}
```

## Expected

Vim: `"ayy` yanks line 1 into register `a`. `j` moves to line 2. `"Ayy`
_appends_ line 2 to register `a` (uppercase register name = append). `G`
to last line, `o` opens a new line, `"ap` pastes register `a` = should
paste both line 1 AND line 2.

## Actual

The paste after `"ap` only contains line 1. `"A` silently did NOT append
line 2 — register `a` still contains only line 1's content.

## Source pointer

`src/input/vim.rs:1670-1676` — the Register-prefix arm accepts the next
key ONLY if `c.is_ascii_lowercase() || c.is_ascii_digit() || c == '+' ||
c == '_'`. Uppercase A–Z fall through without setting
`pending_register` and without recording an "append" flag — so `"Ayy`
degrades to `yy` into the default register, silently losing the append
intent.

## Notes

Vim's uppercase-register-append (`:h quote_alpha`) is one of the standard
tricks for building up a multi-selection yank without a macro. Two ways
to fix: accept `A..=Z` in the prefix arm, lower it, AND set a
`register_append` flag that `Editor::yank_to_register` consults; or
implement it as a separate `PendingOp::AppendYank` state.
