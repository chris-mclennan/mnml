# [SEV-2] `:5,10>` (range indent) is off-by-one — only 5 lines indented, not 6

## Reproduction

sample.txt (13 lines, Line 01 alpha … foo qux):
```jsonl
{"cmd":"type","text":":e! sample.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"type","text":":5,10>"}
{"cmd":"key","key":"enter"}
```

Result: lines 5-9 (Line 05..Line 09) receive a 4-space indent; **line 10
(Line 10 kappa) does not**. Toast confirms `:> 4..9` (0-indexed).

Compare `:5,10d` on the same file: **6 lines deleted (Line 05..Line 10)**.
So `d` treats the range inclusive but `>` treats it half-open.

## Expected

Vim: `:5,10>` indents the 6 lines 5..=10 (inclusive on both ends).
Same semantics as `:5,10d`, `:5,10y`, `:5,10j`.

## Actual

`indent_lines_range` at `src/app/mod.rs:9568-9597` places cursor at
`start_line`, `SelectLine`s (which selects line 4 linewise-inclusive),
then does `MoveDown` `(end_line - start_line)` times = 5. But the
resulting linewise selection stops one row short of line 10 — the last
`MoveDown` doesn't extend the linewise range across the final boundary,
so `Indent` only touches lines 4..8 (0-indexed) = 5..9 (1-indexed).

The comparable line-count delta happens for the `d` path because
`delete_lines` computes byte offsets `[line_start(start), line_end(end)+1)`
directly rather than driving a selection. The selection-driven path
under-counts by one row.

## Source pointer

- `src/app/mod.rs:9568-9597` — `indent_lines_range` (the buggy path).
- `src/app/mod.rs:9527` — `delete_lines` (the working path).

## Notes

Also affects `:5,10<` outdent (same helper). Fix shape: either loop
`end_line - start_line + 1` times, OR reuse the byte-range approach
from `delete_lines` and apply `Indent` per-line without a selection.
Consistency with `d`/`y`/`j` is the criterion.
