# [SEV-3] `key "shift+g"` chord doesn't fire G motion

## Reproduction

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"shift+g"}
{"cmd":"snapshot"}
```

hello.txt has 6 non-empty lines.

## Expected

After `gg` (line 1), `Shift+G` moves cursor to end of buffer — line 6.

## Actual

Cursor stays at line 1. `{"cmd":"key","key":"G"}` (uppercase G with no
modifier) DOES work, so it's specifically the `shift+g` spec that's inert.

## Source pointer

- `src/input/keymap.rs:363-368` — `parse_key_spec("shift+g")` returns
  `KeyEvent { code: Char('g'), modifiers: SHIFT }` because the parser
  strips the `shift+` prefix then hands the remaining `g` (lowercase) to
  `key_code`.
- `src/input/vim.rs:537` — the motion table matches `KeyCode::Char('G')`
  (uppercase), no case-insensitive fallback. `Char('g') + SHIFT` doesn't
  match, so `G` is never dispatched.
- Same story for any other uppercase-letter motion driven via `shift+<letter>`:
  `shift+w`, `shift+b`, `shift+e`, `shift+a`, `shift+i`, `shift+o`,
  `shift+h`, `shift+l`, `shift+m` — all shipped-vim commands.

## Notes

Real users hitting Shift+G on a terminal WITHOUT kitty keyboard protocol
receive `Char('G')` (uppercase, no modifier) — so `G` works interactively
on Ghostty in vanilla mode. But on ghostty with kitty protocol enabled
(`enable_kitty_keyboard = true`), the terminal reports `Char('g')` +
`SHIFT` — and the motion table then misses. Also breaks every headless
test script that uses the vim-canonical `"shift+<letter>"` spec.

Fix: normalize the `KeyEvent` at parse time by upcasing the char and
dropping the SHIFT bit for `A..=Z`, or (better) apply `Chord::of`-style
normalization at dispatch entry — same shape it already does for the
static keymap resolver.
