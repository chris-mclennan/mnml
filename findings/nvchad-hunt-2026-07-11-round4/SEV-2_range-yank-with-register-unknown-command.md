# [SEV-2] `:{range}y a` (yank to named register) fails — "unknown command"

## Reproduction

sample.txt (13 lines):
```
Line 01 alpha
...
foo qux
```

Bare yank works:
```jsonl
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"j"}
{"cmd":"type","text":":'<,'>y"}
{"cmd":"key","key":"enter"}
```
Toast: `:y 0..2 (3 line(s))` — succeeds.

Same yank routed into register `a` fails:
```jsonl
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"j"}
{"cmd":"type","text":":'<,'>y a"}
{"cmd":"key","key":"enter"}
```
Toast: `:'<,'>y a — unknown command`

Also fails: `:5,10y b`, `:.,+3y z`, `:'a,'by A`.

## Expected

Vim's `:{range}y[ank] {reg}` yanks the range into `{reg}`. Same for
`:{range}d {reg}` (delete to register). This is the canonical way
to accumulate multiple selections into a named register.

## Actual

`parse_line_range` returns `("y a", …)` as the remainder. The
range dispatcher in `src/app/ex_commands.rs:508-530` matches on
`remainder.trim() == "y" | "yank" | "ya"` (exact strings), so `y a`
falls through — the register-name argument breaks the match.

## Source pointer

`src/app/ex_commands.rs:513-516` — the `y | yank | ya` arm compares
the whole trimmed remainder, ignoring the optional trailing register
letter that vim's grammar allows.

## Notes

Fix shape: split remainder on whitespace, match on the first token,
capture the second as an optional register (1 ASCII letter/digit).
Also `d {reg}` in the same arm.
