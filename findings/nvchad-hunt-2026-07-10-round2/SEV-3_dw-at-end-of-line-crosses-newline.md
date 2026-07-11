# [SEV-3] `dw` at end of line deletes across newline, joining next line

## Reproduction

hello.txt:
```
alpha
beta
gamma
```

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"type","text":"dw"}
{"cmd":"snapshot"}
```

## Expected

Vim: `dw` on the only word of a line deletes the word but stops at end
of line (`:h word-motions` — "Special case: `cw` and `dw` don't include
the space after a word on the last word of the line"). Result:

```
(empty line 1)
beta
gamma
```

## Actual

Line 1 becomes `beta` — mnml's `dw` consumed the trailing newline and
pulled `beta` up.

```
beta
gamma
```

## Source pointer

Unknown exact file:line. `MoveWordRight` motion at end-of-line advances
to the start of the next word on the next line — vim's special case
just needs the `dw` operator wrap to detect "did motion cross a newline
from a line-final word" and clamp to end-of-line.

## Notes

Bites vim users daily. Common pattern: `dw` to blank the last word on a
line without joining lines. `dW`/`cw`/`ce` should all get the same
treatment.
