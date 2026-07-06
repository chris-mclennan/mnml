---
review: button-dialogs-http-sidebar-keys-standard
agent: design-critic
date: 2026-07-06
---

## TL;DR

The button-dialog migration (`confirm_dialog_buttons`, 14 destructive confirms
across 10 commits) is well-executed where it matters most: Esc/Cancel semantics
are uniform, and the "default-focus Cancel for irreversible ops, default-focus
primary for user-just-asked-for-it ops" split is deliberate and documented, not
an accident. The two sharpest issues this round are (1) a real dead key — the
`AiToolConfirm` dialog visually underlines **D**eny as its hotkey but the
generic key-dispatch only recognizes literal `c`/`n` for the cancel slot, so
`d` does nothing; and (2) the brand-new `+ New chain`/`+ New collection`
palette mirrors (this round's own commit) expose that the pre-existing
`+ New env` sidebar chip was *never* given one — a keyboard-only user cannot
create an HTTP env file at all except by clicking. A smaller but persistent
thread: `task.run` sits in `group: "ai"` though it's a plain Pty-spawning
command (an 11th `term`-grouped sibling exists and is the obvious home), and
the `[keys.standard]` onboarding stub's own worked example rebinds a chord to
a command id (`task.build`) that doesn't exist in the registry.

## Issues found

### 1. `AiToolConfirm`'s underlined "Deny" hotkey is a dead key · severity: high
**What:** The generic confirm-dialog renderer underlines the first alpha
character of *both* button labels as the visual hotkey, but the key-dispatch
for the cancel-side button only ever matches literal `c`/`n` — never the
label's actual hotkey letter.
**Why it matters:** `AiToolConfirm` is the one dialog in the 11-kind
`confirm_buttons` table whose cancel-side label isn't literally "Cancel" —
it's `" Deny "`. The dialog renders with **D**eny underlined (via
`confirm_buttons()`'s `hk()` helper picking the first alpha char), which is
the app's own visual promise "press this letter." A user who reads the
underline and presses `d` gets nothing — no toast, no state change, silent
no-op — mid an AI tool-permission gate, which is exactly the kind of prompt
where a stuck keystroke is disorienting (was it denied? do I need to press
again?). `Esc`/`n`/`c` still work, so this isn't a permanent dead end, but the
underline is actively misleading.
**Evidence:**
- `src/ui/prompt.rs:339-354` — `confirm_labels(AiToolConfirm) = ("  Allow  ", " Deny ")`.
- `src/ui/prompt.rs:360-374` — `confirm_buttons()` computes+underlines the
  hotkey index from each label's own text (so "D" gets underlined for Deny).
- `src/tui/handlers/overlay.rs:460-477` — the actual key handler:
  ```rust
  KeyCode::Char(c) => {
      let low = c.to_ascii_lowercase();
      let (primary_label, _) = crate::ui::prompt::confirm_labels(&p.kind).unwrap();
      let primary_hk = primary_label.chars().find(|c| c.is_ascii_alphabetic())...;
      let hit_primary = matches!(primary_hk, Some(pk) if pk == low) || low == 'y';
      let hit_cancel = low == 'c' || low == 'n';   // <-- hardcoded, ignores the real label
      ...
  }
  ```
**Proposed fix:** Compute `hit_cancel` the same way `hit_primary` is computed
— from the actual cancel label's first alpha char (`confirm_labels(&p.kind).1`)
— rather than hardcoding `'c' | 'n'`. Keep `'n'`/`'c'` as *additional* aliases
(so "Cancel"-labeled dialogs keep working exactly as today) but add the
per-label letter so "Deny" answers to `d`, and any future non-Cancel label
answers to its own underlined letter automatically.

### 2. `+ New env` sidebar chip has no palette-command mirror — keyboard dead end · severity: high
**What:** This round's own commit (`b10f8d9`) added `:http.new_chain` and
`:http.new_collection` explicitly as "mirror of `+ New chain`/`+ New
collection` in the HTTP sidebar" so the feature is reachable without a mouse.
The pre-existing `+ New env` chip in the same sidebar, which opens the
identical style of prompt (`HttpNewEnv`), was never given the same mirror.
**Why it matters:** `App::http_new_env_prompt` has exactly one call site in
the whole codebase — the mouse-down handler for that chip's `Rect`. There is
no `http.new_env` (or similar) command, no chord, nothing in the palette or
help overlay. A keyboard-only user (the profile this review is explicitly
checking for) has no discoverable way to create a new `.env` file from
inside mnml — they'd have to know to create the file on disk manually or
open a Pty pane. The env section is the *first* of the three "+ New X" rows
in the sidebar (env/chains/collections), so this is the most-likely one a new
user hits first and finds it doesn't respond to `Ctrl+Shift+P`.
**Evidence:**
- `src/app/http.rs:574` — `pub fn http_new_env_prompt(&mut self)`.
- `src/tui/mouse/down_left.rs:2065-2068` — sole caller.
- `src/command.rs:3592-3610` — `http.new_chain` / `http.new_collection` exist
  and explicitly say "Mirror of `+ New chain` in the HTTP sidebar" in their
  doc comment, confirming the intended pattern that `new_env` missed.
**Proposed fix:** Add `http.new_env` to the registry (`group: "http"`,
`run: |app| app.http_new_env_prompt()`), mirroring the exact shape of the two
siblings added this round.

### 3. `task.run` is filed under `group: "ai"`, not `group: "term"` · severity: medium
**What:** Every other command whose `id` starts with `ai.` lives in
`group: "ai"` (the pattern holds for all ~35 `ai.*` commands checked). The
one exception is `task.run` — `id: "task.run"`, but `group: "ai"` — despite
its job being "run a configured task in a terminal pane" (spawns a Pty), and
despite a `term` group already existing with 10 sibling commands for exactly
this class of action.
**Why it matters:** `Command.group` isn't decorative — `src/app/help.rs`
builds the `?` help-overlay's section headers directly from it
(`if cmd.group != last_group { rows.push(HelpRow::Section(cmd.group)); }`),
and the palette/help listing shows `group · title · id`
(`src/app/picker.rs:397`). A user scanning the "ai" section for "which
AI/Claude commands exist" gets a task-runner interleaved with Claude
commands; a user scanning "term" for "how do I run a task in a terminal"
won't find it there at all. This is exactly the `group:` mis-shelving the
review brief calls out.
**Evidence:** `src/command.rs:4778-4784`.
**Proposed fix:** `group: "term"`.

### 4. `[keys.standard]` onboarding stub rebinds a chord to a nonexistent command id · severity: medium
**What:** `KEYS_STANDARD_STUB` (auto-appended to `config.toml` the first time
a user opens keybinding customization) ships three worked examples. The
second is:
```toml
# example: add F5 → run the build task
# "f5" = "task.build"
```
`task.build` does not exist anywhere in the command registry — the closest
real command is `task.run` (opens a task picker, no single "build" task
shortcut).
**Why it matters:** This is the exact onboarding moment the stub's own
comment promises will work: "the body documents the schema + shows 3
examples... so the user has concrete patterns to copy." A user who
uncomments this line verbatim and presses F5 gets `app.toast("no such
command: task.build")` (`src/command.rs:110`) — their very first attempt at
the brand-new `[keys.standard]` feature fails, with no indication that the
example itself was the problem rather than their edit.
**Evidence:** `src/app/mod.rs:99-105` (stub text); `src/command.rs:4778-4784`
(`task.run` is the only `task.*` id that exists); `src/command.rs:110`
(unknown-command toast).
**Proposed fix:** Either register a real `task.build` command (if "run the
task named `build`" is a wanted shortcut — e.g. skip the picker and run the
task literally named `build` from `[tasks.build]` if configured), or change
the stub's example to `"f5" = "task.run"` so copy-pasting it actually works.

### 5. Destructive vs. benign confirm-button dialogs share identical chrome · severity: low
**What:** `draw_generic_confirm` gives every one of its 9 `PromptKind`s
(delete branch / stash drop / tag delete / discard hunk / discard file /
kill / **merge** / **rebase** / install) the same fixed `" Confirm "` block
title and the same cyan `row_highlight_menu()` focus style — there is no
color or title differentiation between "this is destructive and
reflog/git-gc-bounded" (drop, discard, kill) and "this just runs a normal git
op" (merge, rebase) or "this is purely additive" (install).
**Why it matters:** The app has an established severity-color vocabulary
elsewhere (`ToastLevel::Error → red`, `src/ui/toast_stack.rs:134`) that these
dialogs don't participate in. It's a minor miscalibration risk, not a
functional one — a user who has learned "the confirm dialog looks scary, so
this must be destructive" gets the same visual weight for accepting a
routine `git merge`.
**Evidence:** `src/ui/prompt.rs:465-542` (`draw_generic_confirm`); title is
hardcoded `" Confirm "` regardless of kind, vs. `DeleteConfirm`'s bespoke
`" Delete "` title (`src/ui/prompt.rs:398`).
**Proposed fix:** Low priority — if touched, either (a) title the dialog with
the primary-button verb (`" Kill "`, `" Merge "`, `" Install "`, mirroring
`DeleteConfirm`'s bespoke-title pattern already established), or (b) leave as
is; this is the smallest issue in the set.

## Patterns that are working well

- **Cancel-focus-by-default is deliberately risk-calibrated, not
  accidental.** `GitDeleteBranchConfirm`, `GitStashDrop`, `GitTagDelete`,
  `DiffDiscardHunk`, `GitDiscardFile`, `ClaudeKillConfirm`,
  `GitMergeConfirm`, `GitRebaseConfirm`, and `AiToolConfirm` all explicitly
  set `cursor = 1` (Cancel/Deny focused) with a comment explaining why, while
  `ToolInstallConfirm`/`SiblingInstallConfirm`/`TreeMoveConfirm` explicitly
  set `cursor = 0` (primary focused) because "the user just asked for this."
  That's the right split and it's documented at each call site
  (`src/app/git.rs`, `src/app/mod.rs`), not a copy-paste accident.
- **Esc is uniformly "cancel the dialog" across every button-dialog kind** —
  `DeleteConfirm`, the 9-kind generic branch, and `QuitConfirm` all route Esc
  to the cancel action with no special cases (`src/tui/handlers/overlay.rs:398,442,489`).
- **The `run_confirm_button` "synthesize the magic string, replay through the
  unchanged accept handler" adapter is a clean migration shape.** Old
  type-to-confirm accept handlers (`p.input.trim() == "drop"`, etc.) didn't
  need to be touched or duplicated — the button dialog just writes the
  expected string into `Prompt.input` before calling `prompt_accept()`
  (`src/app/mod.rs:5353-5406`). Low risk of the UI and the business logic
  drifting apart.
- **The "+ New X" sidebar-chip idiom is consistent across ENVS/CHAINS/
  COLLECTIONS** — same green bold `+ New …` row, same position (bottom of
  section), same click-target pattern. This round's new palette mirrors for
  two of the three follow that idiom correctly (finding #2 is a gap, not a
  wrong pattern).

## Out of scope but noted

- Several `PromptKind` doc comments (`GitStashDrop`, `GitTagDelete`,
  `DiffDiscardHunk`, `GitDiscardFile`, `GitDeleteBranchConfirm`) still read
  "Accept ⇒ ... *iff* the typed text matches the literal word ... exactly" —
  stale from before the button-dialog migration. The *behavior* is fine (the
  synthesized-string adapter in finding "Patterns that are working well"
  keeps it correct), but the doc comments in `src/prompt.rs` no longer
  describe what the user sees. Worth a documentation pass, not a UX fix.
- The `.rqst/` vs `.mnml/` path split (history/captured/env/lookups still
  under `.rqst/`, chains/collections/auth-presets under `.mnml/`) predates
  this round and is a known, intentional migration-compat shim (`for sub in
  [".mnml", ".rqst"]` fallback reads exist throughout `src/app/http.rs`).
  Flagging only because this round's new command titles
  (`http.new_chain: "...in .mnml/chains/"` sitting right next to
  `http.history: "...open .rqst/history.jsonl"`) make the split newly
  visible side-by-side in the palette list — not something to fix as part of
  this round, but worth a dedicated migration pass eventually.
