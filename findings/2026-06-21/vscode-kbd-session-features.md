---
date: 2026-06-21
hunt: vscode-keyboard-purist
scope: features shipped this session
driver: headless file-IPC, --input standard, /tmp/mnml-kbd-hunt workspace
---

# mnml VS Code Keyboard-Purist Hunt — 2026-06-21 (this-session features)

**Counts: 0 SEV-1, 4 SEV-2, 5 SEV-3.**

Question driving this hunt: can every feature shipped this session be reached *without* a mouse?

| Feature | Reachable | Notes |
| ------- | --------- | ----- |
| Claude Agents dashboard — all chords, multi-select, filters, group, sort, drill-down cycle | YES | every chord exercised via headless IPC; `v` cycles drill-down, `g` group, `s` sort, `space` multi-select, `R` clears multi, `0..4` state, `>`/`<` source, `w` workspace, `Ctrl+L` clear, `/` filter, `Enter` open transcript |
| Claude Agents dashboard — clickable Files panel row → open file | **NO** | mouse-only · see S2-01 |
| Websocket pane — open via palette | YES | `ws.connect` palette opens a URL prompt + spawns pane |
| Websocket pane — type messages, scroll log, close | PARTIAL | message-typing has no Home/End/Left/Right edit · Esc destroys the connection rather than blurring · see S2-02, S3-01 |
| peek_definition overlay — navigate, scroll, close | YES (with one quirk) | `Esc`/`j`/`k`/`Up`/`Down`/`PgUp`/`PgDn` all routed; **any other key closes the overlay AND falls through to the editor as input** · see S3-02 |
| Diagnostics severity filter (`s`) | YES | confirmed `s` cycles in `tui.rs:2468` |
| Git worktree picker / merge picker / rebase picker — keyboard-accessible end-to-end | YES | use the standard `Picker` flow (↑↓ select, Enter accept, Esc cancel); all reachable from palette via `git.worktree_list`, `git.worktree_add`, `git.worktree_remove`, `git.merge`, `git.rebase` |
| File-row click in dashboard's Files panel — keyboard equivalent | **NO** | see S2-01 (the loud one) |

## SEV-2

**S2-01 — No keyboard path to open a file from the Claude Agents Files drill-down panel (mouse-only feature).**
The drill-down's Files view (`v` cycle → "Files") lists `recent_files` from the focused session. Help overlay even spells this out:
`(Files panel) click  ·  open the file in an editor pane`.
Verified live: a session with two `Edit` rows renders cleanly; pressing Enter opens the *transcript* (`ClaudeAgentsAction::OpenTranscript`), not the highlighted file. There is no `OpenFile` variant of `ClaudeAgentsAction`, no chord to "focus the drill panel", no way to move a cursor onto a file row inside the panel. Mouse-only — wiring is in `src/tui.rs:4881-4893`: `app.rects.claude_drill_files` is consulted only by the mouse-click handler.
The keyboard-purist persona cannot reach this feature without the mouse. SEV-2.

**S2-02 — Websocket pane Esc destroys the connection (and the data it accumulated) instead of blurring focus.**
`src/tui.rs:1793-1796`: `KeyCode::Esc → p.close()`. Header advertises `enter=send · esc=close · ctrl+e=tree`. Verified live: after sending one message, Esc transitions the pane state to "closing". The pane stays visible but the websocket is gone. A keyboard user reflexively pressing Esc to "step out of the input" loses their live connection. VS Code parity would have Esc step focus to the surrounding chrome and leave the connection alive. The advertised `Ctrl+E` (focus tree) is the chord that does what Esc should do.

**S2-03 — Websocket pane input has no caret editing.**
`src/tui.rs:1828-1832` only handles `Char(c)` push. No `KeyCode::Left`, `KeyCode::Right`, `KeyCode::Home`, `KeyCode::End`, `KeyCode::Delete` arms. `Backspace` (1803) pops the last char but doesn't update `input_cursor` symmetrically (input_cursor never decrements past a multi-byte char correctly because `c.len_utf8()` was already added at push time but on backspace we only subtract from one path). Verified live: typed "helloX" → pressed Home → typed "X" — got "helloXX" (Home ignored, caret stuck at end). Sending a longer URL or JSON blob with a typo near the start requires backspacing the entire tail.

**S2-04 — F11 (zen / full-screen) still unbound.**
This was SEV-2 #S2-05 in vscode-keyboard-2026-06-10. The fix made it into `command.rs:286-291` as `view.zen` but with `keys: &[]`. Verified live: F11 sent via IPC → no chrome change, tree still visible. Persona expects F11 to toggle the chrome-stripped writing surface; palette-only access burns muscle memory.

## SEV-3

**S3-01 — Websocket pane: header lies about `ctrl+e=tree`, but actually works (alias `Ctrl+C` too).**
The header `enter=send · esc=close · ctrl+e=tree` is mostly accurate, but `Ctrl+C` is *also* bound to close the connection (`src/tui.rs:1810-1813`), shadowing the standard Ctrl+C-as-copy reflex. A user copying a session's transcript out by hammering Ctrl+C from an adjacent pane that accidentally lands focus here loses the connection. Header should also advertise `Ctrl+C close` if that binding stays.

**S3-02 — peek_definition overlay falls through on any non-listed key.**
`src/tui.rs:447`: `_ => app.peek_overlay = None, // fall through`. Verified by reading the match arms: only `Esc`, `Up`, `Down`, `j`, `k`, `PgUp`, `PgDn` return early. Typing `a` while peek is up: closes the overlay AND the `a` is consumed as editor input. VS Code's peek overlay is modal — keypresses are swallowed until Esc/Enter/click-outside. mnml mixes the modal pattern (Esc closes) with auto-dismiss-on-anything (fall through). One stray keystroke after running `lsp.peek_definition_overlay` types into the source file. Not destructive, but surprising.

**S3-03 — Claude Agents dashboard's `Enter` chord is double-bound and Files-panel-blind.**
Enter is bound to `OpenTranscript` (`tui.rs:2060-2062`) regardless of which drill-down view is active. The right "secondary" Enter for the Files panel would be "open the highlighted file" — but there's no notion of selection *inside* the drill panel (only the row selection above). Suggested fix: when `p.detail == DetailView::Files`, give the panel its own selection cursor and have Enter target it. Currently the Files panel is mouse-only (S2-01) for that reason.

**S3-04 — `ws.connect` palette command is the *only* entry point for the Websocket pane — no dedicated chord.**
Not a bug per se (palette-only is fine for niche features), but the dashboard advertises websocket as one of the headline features shipped this session. Persona expectation: at least `ws.connect` would surface in the cheatsheet under a chord like `<leader>w`. Currently `keys: &[]`. Reachable, just inconvenient.

**S3-05 — `ai.write_branch_name`, `ai.recompose_branch`, `lsp.peek_definition`, `lsp.peek_definition_overlay`, `git.merge`, `git.rebase`, `git.worktree_*` — all reachable but all keyboard-naked.**
Every new command this session was registered with `keys: &[]`. Acceptable for one-shot palette commands, but at this rate the palette is the only discoverability surface. The cheatsheet pane is the right place to land these. No SEV-2 — palette access is real keyboard access.

## What works (confirmed clean for this session's features)

- **Claude Agents dashboard chord coverage** is excellent: `j/k/↑/↓` move, `PgUp/PgDn` page, `Home/End` jump, `Shift+PgUp/PgDn` scroll drill-down, `F1/?` help, `r` refresh, `y/c` yank id/cwd, `v` cycle drill-down (Summary → Todos → Files → Bash → Agents), `/` filter, `0/1/2/3/4` state filter, `>`/`<` source filter, `w` workspace-only, `Ctrl+L` clear filters, `g` group cycle, `s` sort cycle, `o` resume, `T` resume-in-tmnl-tab, `K` SIGTERM (escalates), `e` export markdown, `space` multi-select, `R` clear multi-select, `p` pause auto-refresh, `t/Enter` open transcript, `Esc` focus tree, `q` close pane.
- **peek_definition overlay** scroll + close: `Esc`/`j`/`k`/`↑`/`↓`/`PgUp`/`PgDn` all routed correctly.
- **Diagnostics severity filter** `s` works (tui.rs:2468).
- **Git worktree picker / merge picker / rebase picker** all use the standard `Picker` flow which is fully keyboard-driven (verified by code path — they hit `PickerKind::GitMergeInto`, `PickerKind::GitRebaseOnto`, `PickerKind::GitWorktreeOpen`, `PickerKind::GitWorktreeRemove`).
- **Settings overlay** still works (Ctrl+, opens, ↑↓ move, ←→ adjust, Enter save, Esc cancel).
- **Command palette** (Ctrl+Shift+P) still reaches every new command this session.

## Executive summary

For most of the features shipped this session, **the keyboard-purist persona is in good shape**. The Claude Agents dashboard is a model of keyboard accessibility — every chord is documented, the help overlay reflects reality, and a workflow of "Ctrl+Shift+P → `:ai.agents_dashboard` → `j`/`k` → `v` → `t`/`Enter` → `Esc` → `Ctrl+W`" gets through the day clean.

The one loud finding is **S2-01**: the dashboard's drill-down Files panel is mouse-only. The help overlay confesses this in its line "`(Files panel) click  ·  open the file in an editor pane`" — there's no keyboard equivalent because the panel has no selection cursor of its own. For a feature whose pitch is "drill-down into what an agent did," not being able to keyboard-jump to a file an agent edited is a real gap; the workaround is to copy the file path out of the panel by reading the screen and `Ctrl+P`-ing it back in, which defeats the purpose of having the path right there.

The Websocket pane is the other rough surface: Esc destroys the connection (S2-02), no caret editing in the input row (S2-03), and `Ctrl+C` overlaps with the system copy reflex (S3-01). These are fixable by adding a `Ctrl+E` blur (already exists, just doc it harder), wiring standard input editing into the WS input, and dropping the Ctrl+C-as-close binding.

F11 zen-mode is still unbound a session after it was flagged (S2-04) — the fix for the previous keyboard hunt added the command but never bound the chord. Quick win.

Bottom line: a VS Code purist can use this session's new features without touching the mouse for everything *except* the Files panel in the agents dashboard. That one is the loud one.
