---
severity: SEV-2
status: open
---
# `ci"` / `di"` / `yi"` with the cursor before the first quote on the line do nothing (Neovim uses the first quoted string after the cursor)

**Command ids:** text objects `i"` / `a"` (`editor.select_inner_quote`, `src/editor/select.zig` `enclosingQuotePairOnLine`).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"Oname = \"world\";"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"0ci\"X"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
{"cmd":"type","text":"0di\""}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after 0ci"X<Esc>:   1 Xname = "world";      cursor 1:1
after 0di":         1 Xname = "world";      (unchanged)
```

**Expected**: `ci"` from column 1 changes `world` → the line becomes `name = "";` with the cursor between the quotes (Neovim `current_quote()`: when the cursor is not inside a quoted string, the first quoted string after it on the line is used — `:help i"`, and the most common way people type `ci"`).

**Actual**: nothing is selected; `c` falls through to plain Insert at the cursor so the typed text lands at column 1 (`Xname`), `di"` / `yi"` are silent no-ops. `ci"` with the cursor *inside* the quotes (including an empty `""`) works.

**Source pointer**: `src/editor/select.zig:106` `enclosingQuotePairOnLine` only returns a pair that *contains* the cursor (`ed.cursor >= o and ed.cursor <= i`); there is no forward-search fallback; `quote()` at line 123 returns silently when it is null.
