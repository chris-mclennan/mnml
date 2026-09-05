---
severity: SEV-2
status: open
---
# NOTES `n`: the prompt's prefilled `note-1.md` is not selected, so typing appends — the note is saved without `.md` and never appears in the panel

**Command id:** `view.activity_notes` then `n` (new note). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"run-command","id":"view.activity_notes"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"n"}
{"cmd":"snapshot"}
{"cmd":"type","text":"my note"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```
**screen.txt** (prompt):
```
╭ New note in .mnml/notes/ ──────────────────╮
│ note-1.md                                  │
```
After Enter: `ls .mnml/notes/` → `note-1.mdmy note`; the panel header still reads `NOTES (0)`; a tab titled `note-1.mdmy note` opens. `status.json` `activeFile` = `.../.mnml/notes/note-1.mdmy note`.

**Expected**: a prefilled name is selected (VS Code convention for rename/new-name inputs: typing replaces the selection), or the extension is appended by the app; either way the note must show up in NOTES.
**Actual**: the caret sits at the end of the prefill, the typed text is concatenated, the file lacks `.md`, and NOTES filters it out — from the user's side the note "vanished". The same "prefill is not a selection" idiom bites the `Ctrl+P` picker: `ctrl+a` moves the caret to the start instead of selecting all, so re-typing yields `vscdoechrlie`.

**Source pointer**: the notes `n` prompt in `src/app/notes*.zig` / `Prompt` prefill handling in `src/ui/prompt.zig` (`text_field` has no initial-selection state).
