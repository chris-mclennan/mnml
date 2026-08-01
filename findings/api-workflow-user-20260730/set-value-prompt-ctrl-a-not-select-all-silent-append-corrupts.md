---
finding: set-value-prompt-ctrl-a-not-select-all-silent-append-corrupts
severity: SEV-3
surface: request-pane
---

**Repro**: numbered steps (headless IPC harness).

1. Workspace with `.rqst/env/dev.env` containing `SHARED_ONLY_RQST=from-rqst`
   (not present in `.mnml/env/dev.env`).
2. Open a `.curl` request that references `{{SHARED_ONLY_RQST}}` in a header
   value, switch the Edit-tab to Headers (`ctrl+]`).
3. Right-click the `{{SHARED_ONLY_RQST}}` var token → context menu → click
   **Set value…**. Prompt opens seeded with the current resolved value:
   `Value for SHARED_ONLY_RQST: from-rqst`.
4. Press `Ctrl+A` (the universal "select all" expectation from every GUI
   text field, and the readline "move to start of line" binding used in
   most terminal apps) intending to select/clear the seeded text, then type
   a replacement: `{"cmd":"key","key":"ctrl+a"}` →
   `{"cmd":"type","text":"from-mnml-set-value"}` → Enter.

**Expected**: Either (a) `Ctrl+A` selects all so typing replaces the seeded
value, or (b) at minimum `Ctrl+A` moves the cursor to the start of the line
(readline convention) so the corruption is at least visible/obvious before
Enter. Either way the user should end up with a clean, intentional value.

**Actual**: `Ctrl+A` is silently swallowed (falls through to the `_ => {}`
arm in `handle_prompt_key` — no `KeyCode::Char('a') if ctrl` arm exists).
The cursor stays exactly where it was (end of the seeded text), so the
typed replacement is silently **appended** instead of replacing anything.
Hitting Enter commits the corrupted concatenation straight to disk with no
warning:

```
$ cat .rqst/env/dev.env
SHARED_ONLY_RQST=from-rqstfrom-mnml-set-value
```

The toast even echoes the corrupted value back
(`wrote SHARED_ONLY_RQST=from-rqstfrom-mnml-set-value`) but a user skimming
a toast is unlikely to notice a mashed-together string is wrong.

Root cause: `src/tui/handlers/overlay.rs::handle_prompt_key` (the shared
plain-text-input branch used by `Set value…` and all similar
seeded-value prompts) supports `Home`/`End`/`Left`/`Right`/`Ctrl+U`
(clear-all)/`Ctrl+W` (delete-word)/`Ctrl+V` (paste) but has **no**
`Ctrl+A` (select-all or move-home) and no `Ctrl+E` (move-end) binding —
both are near-universal terminal/readline conventions users will reach for
on a seeded field. `Ctrl+U` *does* clear the line correctly, so the prompt
isn't literally append-only, but the specific gesture most users try first
on a pre-filled field silently does nothing instead of either working or
erroring.

**IPC trace** (relevant events):
```
{"event":"command_run","id":...}  (right-click → context menu → Set value…)
prompt opens: "Value for SHARED_ONLY_RQST: from-rqst"
key ctrl+a  → no visible change (cursor unmoved)
type "from-mnml-set-value" → appended at end
key enter → toast: "wrote SHARED_ONLY_RQST=from-rqstfrom-mnml-set-value"
```
Confirmed on disk: `.rqst/env/dev.env` line becomes
`SHARED_ONLY_RQST=from-rqstfrom-mnml-set-value`.

**Notes**: `src/tui/handlers/overlay.rs:766-807` (the plain-text prompt key
match inside `handle_prompt_key`). Relates to the project's own
`overlay-text-field-affordances` convention note ("new overlay text field?
Ship with cursor/arrow/paste/paste-drop from day one — never append-only").
This prompt does have arrow/Home/End/paste, so it's not the from-scratch
gap that note describes, but the missing `Ctrl+A`/`Ctrl+E` bindings on a
prompt that's specifically *seeded* with existing content (unlike a normal
empty-input prompt) make the append-corruption failure mode easy to hit by
accident. Suggested fix: bind `Ctrl+A` → select-all-then-replace-on-type
(or at minimum move-home to match `Home`), and `Ctrl+E` → move-end, in the
same match arm as the existing `Home`/`End` bindings.
