---
severity: SEV-2
status: open
---
# FINDINGS `n` / `findings.new` with a bare name writes `<name>.md` for the panel and *also* an empty `<name>` — and opens the extension-less twin in the editor

**Command id:** `findings.new` (`n` in the FINDINGS panel). Reproduced on two fresh launches, 2/2 (`vs-probe`, `vs-probe2`).

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"run-command","id":"view.activity_findings"}
{"cmd":"wait_ms","ms":300}
{"cmd":"run-command","id":"findings.new"}
{"cmd":"snapshot"}
{"cmd":"type","text":"vs-probe2"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

**screen.txt**: the prompt `╭ New finding in .mnml/findings/ ─╮ │ finding-1.md` — typing replaces the seed (good). After Enter the tab strip reads `alpha.zig   vs-probe2   +`, the editor shows an empty buffer (`1`), `status.json` `activeFile` = `…/.mnml/findings/vs-probe2` (no extension), while the panel lists `MED  vs-probe2  vs-probe2  now`.
```
$ ls -la .mnml/findings | grep vs-probe2
-rw-r--r--  0 vs-probe2
-rw-r--r-- 51 vs-probe2.md      ← "---\nseverity: medium\nstatus: open\n---\n# vs-probe2"
```
`findings.resolve` / `findings.delete` then act on `vs-probe2.md` (toasts say so) and the bare `vs-probe2` stays behind, tracked in git via the `!.mnml/findings/` carve-out.

**Expected**: one file, `vs-probe2.md`, opened in the editor with its frontmatter (the fix for `vscode-new-note-prefill-appends` says "both accept paths append `.md` to a bare name"). NOTES does this correctly (`alpha-note.md` only).
**Actual**: `acceptNew` builds the `.md` path for the write but opens/creates the un-suffixed one; the user edits an empty stray file and their text never reaches the finding the panel shows.

**Source pointer**: `src/findings.zig:504-534` — `const text = try notes.withMdExt(arena, text_in)` at `:506`, but the `openPath(abs)` at `:534` is fed a path built from `text_in`.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
