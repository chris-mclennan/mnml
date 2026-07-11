# [SEV-3] `3.` (count prefix on dot-repeat) fires only once

## Reproduction

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"type","text":"dw"}
{"cmd":"type","text":"3."}
{"cmd":"snapshot"}
```

hello.txt line 1: `foo bar baz qux`

## Expected

Vim: `dw` at col 1 deletes `foo `. `3.` repeats the last change 3 times
— should delete `bar `, `baz `, then `qux`. Line 1 ends empty.

## Actual

`3.` runs the last change ONCE, not 3 times. Line 1 = `baz qux` after
the sequence (only `bar ` was removed by `.` — the `3` count was
dropped).

Manual proof: `dw` then `.` then `.` (typed as three separate `.` keys)
DOES correctly do 3 deletions — line ends with `qux`.

## Source pointer

Unknown exact file:line. The dot-repeat handler in `src/input/vim.rs`
runs the recorded op sequence but doesn't multiply by the count prefix
that armed before `.`.

## Notes

`:h .` — "if a count is used, the count of the last change is replaced
by [count]" — mnml drops the count instead of substituting. Common vim
idiom for macro-lite ("do this thing N times"), so real users notice.
