---
title: AI panes
description: Run Claude Code, Codex, or any AI CLI as embedded pty panes — with auto-naming from ticket prefixes, a multi-session tab strip, and launcher icons.
---

mnml doesn't bundle a model. What it does is run AI CLIs (`claude`, `codex`, whatever you have on `$PATH`) as **first-class panes inside the split tree** — with the same tab-strip, focus, and resize machinery every other pane gets — and a few mnml-specific niceties layered on top: a multi-session tab strip with `+` and `×`, auto-naming from ticket-key prefixes, and a launcher-icon row for one-click spawn.

This page is about the **pane-and-session surface** for AI tooling. For the on-selection actions (explain / fix / refactor / write-tests) and the agentic API backend, see the broader AI track in the [feature inventory](https://github.com/chris-mclennan/mnml/blob/main/FEATURES.md#ai).

## What an AI pane is

An AI pane is a `Pane::Pty` — exactly the same primitive that backs `:term` and the embedded shell — running an AI CLI as its child. The reader thread pumps the child's bytes into a vt100 grid; the renderer reads cells back out and paints them into the pane. Outbound keystrokes go through the pty's write half on the UI thread.

There's no separate "Claude integration" — the pane is a terminal, the integration is "we spawn `claude` with the right flags." That means:

- The pty pane resizes when you resize the split. The child sees SIGWINCH and redraws.
- The pty pane's scrollback is `Shift+PgUp` / wheel like any terminal — 5000 lines of vt100 history.
- The child speaks every escape sequence its TUI emits — including OSC window-title escapes — and mnml reads them.
- When the child exits, the pane shows `[process exited — Ctrl+W to close]` on the bottom row. You can leave it sitting there to scroll the transcript, or close it.

What mnml adds on top of the bare pty:

- **A per-pane tab strip** on the top row. Lists every `Pane::Pty` in the workspace, plus a `+` to spawn a new Claude session as a tab of this leaf and an `×` per tab to close it.
- **Auto-naming from ticket prefixes** — see below.
- **Launcher icons** in the bufferline / sidebar rail for one-click spawn.
- **`.mnml/CLAUDE.md` injection** for Claude Code: if your workspace has one, it's passed as `--append-system-prompt` so the assistant orients before message #1.
- **Session-id capture** for Claude Code — mnml allocates a `--session-id` up front so the broader AI track can mirror the transcript or resume the session later via `claude --resume`.

## Opening a Claude Code pane

Three equivalent ways:

```vim
:ai.claude_code          " ex-command (palette ID is verbatim)
```

From the command palette (`Ctrl-Shift-P` in standard mode, `<leader> f c` in vim) — type `claude code` and pick **AI: open Claude Code (right dock)**.

From the leader chord (vim mode): `<leader> a c`.

Or click the **Claude** chip in the bufferline-right launcher strip / the integrations rail (whichever your config has them in — defaults put Claude + Codex in the rail's INTEGRATIONS section; the bufferline launcher row defaults to empty, but you can populate it via `[[ui.launcher_icon]]`).

The pane docks as a **vertical split to the right** of the active leaf — the IDE-canonical "chat panel" placement. If a Claude pane is already open, `ai.claude_code` reveals it (focuses + scrolls into view) instead of spawning a duplicate. To explicitly add a *new* Claude session as a sibling tab of the existing one, use:

```vim
:ai.claude_code_new      " always spawn — never reuse
```

The fresh session pops up next to the existing one in the same pane's tab strip; press `Tab` (or click the chip) to switch.

### What flags Claude gets

```text
claude --session-id <uuid> \
       --append-system-prompt "<contents of .mnml/CLAUDE.md, if present>" \
       [<initial prompt, if ai.chat seeded one>]
```

The session id is mnml-allocated so the wider AI track can mirror or resume the conversation. `CLAUDE.md` injection is silent — if the file is missing or empty, the flag is skipped.

## Opening a Codex pane

Same shape, different binary:

```vim
:ai.codex                " palette: AI: open Codex (right dock)
```

Vim chord: `<leader> a x`. Codex gets no special flags — mnml just spawns `codex` in the workspace cwd. The same "reveal if already open" toggle applies.

## The pty tab strip

Any pty pane (Claude, Codex, shell, a `task`) gets a one-row tab strip across its top. The strip is per-pane — if you have two pty panes side-by-side, both carry their own strip showing every pty session in the workspace.

```text
 claude code  ×   codex  ×   terminal (zsh)  ×   +
└─────────────┘ └────────┘ └────────────────┘ └─┘
   active           dim            dim         new
```

| Click target | Action |
|---|---|
| A tab body (e.g. `claude code`) | Switch this leaf to show that session |
| The `×` after a tab | Close that pty session (kills the child + drops the pane) |
| The `+` at the right end | Spawn a **new Claude Code** session as a tab of this leaf |

The active session's chip is highlighted in `orange`; inactive ones are dimmed. An exited session shows `✗` after its name (the child is gone but the scrollback's still there until you `×` it).

Labels are truncated at 18 chars. Long names get an ellipsis — the full name lives in the OSC window title, which the tab name is derived from.

> The `+` button always spawns Claude Code (the most common case). To add a Codex / shell / task tab to the same leaf, open it via its palette command and the split machinery will land it in a sibling pane; you can then move it into the same leaf via window-management chords.

## Auto-naming from ticket prefixes

Pty sessions resolve their tab name by priority:

1. **User rename** (`:rename <name>` while focused — wins always)
2. **Ticket scan** — if `[ui] ticket_prefixes` is set, the most-recently-rendered `<prefix><digits>` token from the visible scrollback
3. **OSC window title** — whatever the child program sets via `ESC]0;…` / `ESC]2;…` (Claude Code sets this; so do most modern CLIs)
4. **Profile label** — the binary's default (e.g. `claude code`, `codex`)

The ticket-scan step is the headline feature for AI sessions. Configure it:

```toml
[ui]
ticket_prefixes = ["TE-", "MIX-", "PROJ-"]
```

Now, when you're in a Claude Code session discussing `TE-1234`, the tab label automatically updates from `claude code` to `TE-1234` as soon as that token shows up on screen. Multiple sessions discussing different tickets get distinct labels.

The scan is **globally rightmost-wins**: if scrollback contains `PROJ-77`, then `MIX-123`, then `TE-5`, the tab shows `TE-5` (because it's the most-recent row in the row-major grid, regardless of which prefix matched). When a newer ticket scrolls past, the label updates to track the most recent one. The scan only runs when `display_name` is unset — your explicit `:rename` is never overridden.

Empty `ticket_prefixes` (the default) skips the scan entirely — no perf cost.

If Claude is currently "thinking" (its TUI shows a spinner glyph + `…`), the tab appends the live spinner: `TE-1234 ✽`. The glyph animates frame-to-frame; the name stays put so the tab's still identifiable.

## The per-leaf tab-strip AI chips

Every leaf's tab strip (top-right corner, next to the terminal glyph and the H/V split buttons) carries **Claude Code** and **Codex** launcher chips by default. Right-click either chip for a placement menu; left-click opens a new session using the default placement.

```
… [ ⚛ Claude ][ ▸ Codex ][ $ ][ ⊟ ][ ⊞ ]
```

The chips are on by default via `[ui] tab_bar_ai_icon = "both"`. Set to `"none"` to hide them entirely, or `"claude_code"` / `"codex"` to show only one. When the leaf is too narrow to fit both AI chips plus the terminal + H/V cluster (which is load-bearing), AI chips are dropped one at a time from the right — Codex first, then Claude Code. Terminal + H/V are never dropped.

### Left-click — new session (default placement)

Left-click either chip to fire the corresponding `ai.claude_code_new` / `ai.codex_new` command — a fresh session opens to the right of the active leaf (the IDE-canonical "chat panel" placement).

### Right-click — placement menu

Right-click either chip for a context menu:

```
Claude Code launcher
  Open new Claude Code session (right dock)
  Toggle existing Claude Code pane
  Place new session in left half
  Place new session in right half
  Place new session in top half
  Place new session in bottom half
```

The menu is symmetric for both chips. The four halves-only placements route through eight palette commands:

| Command | Places new session in |
|---|---|
| `ai.claude_code_new_left` | Left half of the active leaf |
| `ai.claude_code_new_right` | Right half of the active leaf |
| `ai.claude_code_new_top` | Top half of the active leaf |
| `ai.claude_code_new_bottom` | Bottom half of the active leaf |
| `ai.codex_new_left` / `_right` / `_top` / `_bottom` | Same for Codex |

Under the hood: right / bottom placements call `open_pty_dir(dir)` which spawns the new pane in the second position by default. Left / top placements call the same then `swap_siblings_containing(new_id)` so the new pane ends up on the requested side.

Quarters (top-left, top-right, etc.) are deferred — they'd need a recursive split; no signal yet that users want them badly enough to justify the layout complexity.

Bind any of the 8 palette commands under `[keys.global]` if you want chord-driven placement.

## The launcher-icon strip

There are two launcher rows in mnml. Both are config-driven and both can fire any registered command.

### Bufferline launcher chips — `[[ui.launcher_icon]]`

The right edge of the bufferline. Each entry renders as a 4-cell colored chip. Defaults to empty in the current build — add entries to populate it:

```toml
[[ui.launcher_icon]]
id       = "claude"
glyph    = "\u{F8B0}"           # mnml-patched Claude Spark
fallback = "✻"                  # ASCII / --ascii fallback
command  = "ai.claude_code"     # registered command id
color    = "orange"
tooltip  = "Claude Code"

[[ui.launcher_icon]]
id       = "codex"
glyph    = "\u{F8B1}"
fallback = "▸_"
command  = "ai.codex"
color    = "cyan"
tooltip  = "Codex"
```

The `command` field accepts two shapes:

- A **registered command id** (e.g. `"ai.claude_code"`, `"mixr.show"`) — dispatched through the same path as a palette click.
- A **colon-prefixed ex-cmdline string** (e.g. `":term myapp arg1 arg2"`) — fed through `run_ex_command`. This is how you wire a custom Pty-pane integration to a chip.

Hover any chip to see its tooltip. Click to fire.

### Integration-rail icons — `[[ui.integration_icon]]`

The left sidebar's rail has an INTEGRATIONS section under GIT. Same shape as launcher chips but rendered as plain monochrome glyphs (no chip background) to fit the muted aesthetic. **This is where Claude + Codex live by default** — alongside Bitbucket, HTTP, AWS CodeBuild, GitHub Actions.

Override with `[[ui.integration_icon]]` blocks in config; passing an empty array removes the section. The default set ships Claude (orange Spark glyph at U+F8B0) and Codex (cyan glyph at U+F8B1) — both patched into the user's Nerd Font by `scripts/patch_nerd_font.py`. Without the patch, the fallbacks (`✻` and `▸_`) evoke the brands using stock Unicode.

## Launching custom sibling binaries

`:term <binary> [args…]` spawns an **out-of-process binary** as a Pty pane. Database viewers, ticket browsers, log tailers, Playwright dashboards — anything with a TUI can be a sibling.

```vim
:term myapp                  " spawn `myapp` in a Pty pane
:term psql-viewer host=prod  " spawn with args
```

Closing the pane terminates the child.

Drop a `[[ui.launcher_icon]]` entry pointing at `":term myapp"` to get a one-click chip; no mnml code changes needed.

## Multi-session tactics

A few patterns the tab strip enables:

- **One pane per ticket.** With `ticket_prefixes` set, opening a fresh Claude session per ticket gives you a tab strip of `TE-1234 / TE-1290 / TE-1301 / +` automatically — switch contexts with a click.
- **Claude + Codex side-by-side.** Open `:ai.claude_code` then `:ai.codex` — they land in separate panes on the right (Codex below / next to Claude depending on split state). Different tabs of the same strip; same ergonomics.
- **Resume a session.** Claude Code sessions started by mnml have a known `--session-id`. The wider AI track exposes `ai.session_view` to mirror the transcript, and `BinaryProfile::claude_code_resume(workspace, session_id)` to re-attach interactively — useful after a `Ctrl-C` on a long-running task.
- **Headless verification.** AI panes work under `mnml --headless` — the file-IPC channel can drive a Claude session for E2E scripts. See the headless docs (or `tests/e2e/`) for examples.

## The spend report — `:ai.spend_today`

A side-pane that totals every Claude / Codex session touched in the last 24 hours, grouped by workspace, with sortable columns (workspace / tokens / cost).

```vim
:ai.spend_today          " palette: AI: open today's spend report
```

Opens a `Pane::SpendReport` as a horizontal split off the active leaf (or re-uses an existing one if you've called it before — only one spend pane per session). Within the pane:

| Key | Action |
|---|---|
| `s` | Cycle the sort key: workspace → tokens → cost → workspace |
| Click any column header | Cycle to that sort key, or flip asc/desc on the current one |
| `r` | Re-scan from disk |
| `Esc` | Return focus to the previous pane |

### Background scan + the `· computing…` chip

Scanning every `.jsonl` under `~/.claude/projects/` can take 1-2 seconds on a machine with many active workspaces (per-file cap is 10 MB, but they add up). The scan runs on a **background std thread** so the UI stays responsive:

- The pane opens immediately with an empty snapshot and `loading = true`.
- The title bar shows `AI spend (24h) · sort: cost ↓ · computing…` while the worker is in flight.
- `App::tick` calls `poll_pending()` on every loop iteration; when the channel drains, the snapshot swaps in and a totals toast fires (`"AI spend (24h): N sessions · $X.XXXX"`).
- `r` (refresh) signals the prior worker to abort via an `Arc<AtomicBool>` flag and spawns a fresh one. The worker checks the flag between every JSONL file, so closing the pane or hitting `r` stops it within a few hundred ms — no orphaned 2-second background scan after you've moved on.
- Closing the pane (`Drop`) also flips the abort flag, so the worker bails on the next file boundary.

The toast fires from `App::tick` — not at `:ai.spend_today` time. The old inline-toast at fire time was always unreachable because `loading` was `true` at that point; the post-drain path makes the totals announcement land when there's actually something to announce.

![:ai.spend_today opens the SpendReport pane immediately with a "· computing…" chip; the worker drains; the snapshot fills in; a "today: N sessions · $X.XXXX" toast lands at the bottom](../../../assets/tapes/spend-report-bg-thread.gif)

## Where to go next

- [Editing](/manual/editing/) — vim or standard keymap; the same edits work whether you're typing into Claude or into a `.rs` file
- [Git](/manual/git/) — the AI commit-message action (`C` in the staging view) shells out to the same `claude -p` that backs the panes
- [HTTP client](/manual/http/) — another pane class with its own dedicated UI
- The [keybinding reference](/reference/keybindings/) for every default chord, including the `<leader> a *` AI group
