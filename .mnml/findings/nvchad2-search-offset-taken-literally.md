---
severity: SEV-3
status: fixed
---
# `/pat/e` (search offsets) is searched as the literal text `pat/e` → "no matches"

**Command ids:** `/` search line (`src/app/find.zig` / `cmd_find.zig`).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":5\n"}
{"cmd":"type","text":"/juliet/e\n"}
{"cmd":"snapshot"}
{"cmd":"type","text":"/juliet/e+1\n"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
│ no matches for "juliet/e" │
│ no matches for "juliet/e+1" │      cursor unchanged at 5:1
```

**Expected**: `/juliet/e` lands on the last character of the next `juliet` (4:6), `/e+1` one past it; `/pat/+1`, `/pat/s-1`, `/pat/b` likewise (`:help search-offset`). At minimum an unsupported-offset toast rather than a failed literal search.

**Actual**: everything after the pattern's closing `/` is part of the pattern; the search fails silently apart from the toast. Two launches (also with `/greet/e` in b.zig).

**Source pointer**: `src/app/cmd_find.zig` — the `/` line hands the whole string to the finder; no split on an unescaped `/`.

## Fix

Commit `01dcd8e` — the vim accept splits `/pat/offset` (`e[±N]`, `s[±N]`, `b[±N]`, `[±]N`), stores the offset on the find state and lands through it; `n` / `N` keep it. Test: `tests/e2e-zig/vim_search_offset.test`.
