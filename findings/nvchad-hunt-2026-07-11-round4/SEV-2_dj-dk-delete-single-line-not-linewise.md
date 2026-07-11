# [SEV-2] `dj` / `dk` / `d3j` delete only the cursor line — not linewise vertical motion

## Reproduction

sample.txt (13 lines):
```
Line 01 alpha
Line 02 beta
Line 03 gamma
Line 04 delta
Line 05 epsilon
Line 06 zeta
Line 07 eta
Line 08 theta
Line 09 iota
Line 10 kappa
foo bar
foo baz
foo qux
```

### `dj` from line 6

```jsonl
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"5"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"j"}
```
Result: only Line 06 zeta is deleted. Line 07 eta survives. File
shrinks 13 → 12.

### `dk` from line 5

```jsonl
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"4"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"k"}
```
Result: only Line 04 delta is deleted. Line 05 epsilon survives.
File shrinks 13 → 12.

### `d3j` from line 5 — deletes 3 lines, not 4

```jsonl
{"cmd":"type","text":"3dj"}
```
Result: Line 05, Line 06, Line 07 deleted (3 lines). File shrinks
13 → 10.

## Expected

Vim vertical motions (`j` / `k` / `+` / `-` / `_`) used with a
line-motion operator convert the operation to **linewise** — meaning
the current line AND the destination line (and everything between)
are affected.

- `dj` from line 6 → 2 lines deleted (6 and 7).
- `dk` from line 5 → 2 lines deleted (4 and 5).
- `d3j` from line 5 → 4 lines deleted (cursor + 3 below = 5,6,7,8).

## Actual

mnml treats `dj` as "delete from cursor to same column on next line"
(charwise diff), which because both lines are same-length ends up
deleting only the cursor's line worth of characters at column 1 —
observed as one full line removed. This is a textbook charwise-vs-
linewise motion bug in the operator loop.

## Source pointer

Unknown — grep the vim input handler's operator-pending
dispatch. Look for the motion → operator conversion when the motion
kind is `MotionKind::Line` (j/k/+/-/_) — that conversion is either
missing or set to charwise.

Suspect files: `src/input/vim/*.rs` (operator apply / motion apply);
also grep for `MoveDown` / `MoveUp` usage inside `d`/`y`/`c`
operator handling.

## Notes

`dd` works (drops the current line), `d2d` deletes 2 lines. But
`d1j` / `d2j` — the equivalent normal-form for "delete N+1 lines" —
is subtly wrong. This bites users who type
`dj` / `yj` / `cj` as shorthand for "operate on this line and the
next". Same shape almost certainly affects `yj` / `y3j` / `cj` /
`>j` / `<k`.

Priority — one of the most common vim idioms for quick 2-line
edits is `dj` at the top of a stanza. This finding likely explains
several downstream "why doesn't my dj work" complaints.
