---
severity: SEV-2
status: fixed
---
# Find-in-files prompt prefills the previous query unselected — typing appends to it, and `Ctrl+A` moves the caret to the start instead of selecting

**Command id:** `find.grep` (`ctrl+shift+f`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"key","key":"ctrl+shift+f"}
{"cmd":"type","text":"charlie one"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":1200}
{"cmd":"key","key":"ctrl+shift+f"}
{"cmd":"snapshot"}
{"cmd":"type","text":"bravo line"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+a"}
{"cmd":"type","text":"X"}
{"cmd":"snapshot"}
```

**screen.txt** (second and third snapshots, the prompt line):
```
╭ Find in files ───────────────────────────────────────────╮
│ charlie onebravo line                                    │
```
and after `ctrl+a` + `X`: `│ Xcharlie onebravo line`. Submitting runs the concatenation (`walk: no matches for "bravo linebravo (line|BL) [23]"` in the first session).

**Expected**: VS Code's search box keeps the last query *selected* — typing replaces it, `Ctrl+A` selects all. The NOTES/FINDINGS prompts already got this treatment (`Prompt.seed`, finding `vscode-new-note-prefill-appends`, fixed in `d00d837`); its own notes flagged the picker's `Ctrl+A` as the same idiom left open.
**Actual**: the grep prompt seeds the previous pattern as plain text with the caret at the end; the text field's `ctrl+a` is home, not select-all. A `Ctrl+Shift+F` → type → Enter reflex searches for garbage every second time.

**Source pointer**: the `find.grep` prompt in `src/app/cmd_find.zig` / `src/app/grep.zig` (the prompt is opened with the last query as `text`, not via `Prompt.seed`); `src/ui/prompt.zig` / `text_field.zig` `ctrl+a`.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `fix(grep): the find-in-files prompt seeds the last query as a selection`.

`grep.openQueryPrompt` uses `Prompt.seed` for both prefills (the editor's
find query, then the open Search pane's), so typing replaces and Enter
reruns. `Prompt.handleKey` takes `Ctrl+A` as select-all (VS Code) before the
text field sees it as home. Unit test in `prompt.zig`;
`tests/e2e-zig/grep_prompt_seed.test`. The picker's `Ctrl+A` is a separate
idiom and untouched.
