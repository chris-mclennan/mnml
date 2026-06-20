---
title: Cmdline popup
description: The floating completion popup that auto-shows above the `:` cmdline — tiered fuzzy scoring, recent-first ordering, click-to-accept rows, and an in-flight HTTP indicator.
---

The cmdline is the `:` ex-command line — type `:w` to write, `:colo gruvbox` to swap theme, `:http.send` to fire the active request. The **cmdline popup** is the floating completion box that auto-rises above the cmdline whenever there are two or more matches for what you've typed. You don't have to learn it; it shows up the moment you start typing.

It's mnml's answer to two questions a new user asks every five minutes: *what's the command I want?* and *what did I just run?* The popup answers both — tiered fuzzy scoring puts the right command on top, and an empty cmdline brings up your recent history.

## When the popup shows

The popup renders when:

1. The `:` cmdline is open (vim mode `:`, standard mode `Ctrl+;`, or a click on the cmdline_bar at the bottom of the screen).
2. There are **two or more** matches for the current token. A single match means the line is already canonical — the popup would just echo what you typed.
3. If the cmdline is **empty**, the popup shows up to 16 recent commands (most-recent first) so you can re-fire something with one keystroke.

The box floats *upward* from the cmdline. The width is computed from the widest visible row (id + title + key hint), capped at 110 cells; the height is up to 8 visible rows + an `(N more — Tab to cycle)` row when there are more matches than fit + a chord-hint footer.

## What each row shows

```
  ★ http.send           HTTP: send active request                    <leader>hs
    http.send_streaming HTTP: send active request as an SSE stream
    http.bench          HTTP: bench active request 10× (concurrent)
    http.history        HTTP: open .rqst/history.jsonl picker        <leader>hh
    http.lookup         HTTP: lookup-based env-var picker            <leader>hl
```

Three columns:

- **Marker + id** — the command id (`http.send`, not `:`). A `★` in the marker column means the row is also in your recent-commands list — high-traffic commands stay at the top regardless of alphabetical order.
- **Title** — the human-readable label the command registry holds, dimmed.
- **Key hint** — the bound chord (`<leader>hs`, `Ctrl+S`, etc) on the right, when one is bound. Tracks `[keys.global]` / `[keys.vim]` / `[keys.standard]` from your config so what you see is what you actually have to type.

The selected row paints with a `bg3` background and bold weight. Selected starts at row 0 on each fresh query and resets whenever the cmdline text changes.

## Tiered fuzzy scoring

The popup doesn't do glob-style prefix matching alone — it scores every command in the registry and sorts highest-first. The tiers, top to bottom:

| Tier | Score | What matches |
|---|---|---|
| **T1** | 300 | The command id **starts with** your token. Typing `http.s` puts `http.send`, `http.sync`, `http.save_response`, `http.set_method.*`, `http.save_mock` at the top. |
| **T2** | 200 | The command id **contains** your token as a substring. Typing `http` puts `http.send`, `http.bench`, every `*.http.*` command in the registry. |
| **T3** | 150 | A legacy vim `EX_COMPLETION_NAMES` entry prefix-matches the token (`:wr` → `write`, `:ta` → `tabclose`). Below T2 so your muscle memory survives but registry-id matches still outrank. |
| **T4** | 100 | The command's **title** contains the token, but only when you've typed 3+ characters. Typing `send` (4 chars) finds `http.send` even though the id is `http.send` (its title is "HTTP: send active request"). Gated to 3+ chars to avoid flooding on short tokens. |

Plus a **recency bump**: any command you've recently fired gets `+50` (most recent), `+49`, `+48`, … added to its tier score. So your last 50 commands stay near the top within their tier.

Ties break alphabetically by command id. The popup deduplicates rows by id so the same command doesn't appear twice (which can happen when both T1 and T3 fire).

This is why typing `:s` in a fresh session shows `http.send`, `picker.symbols`, `git.status_pane`, etc. (all start with `s`), and after you've run `http.bench` a few times, `:s` puts `http.send` first (recency bump) instead of one of the alphabetical leaders.

## Navigating the popup

| Key | Action |
|---|---|
| `Tab` / `Down` | Move selected row down |
| `Shift+Tab` / `Up` | Move selected row up |
| `Page Down` | Move down a page (8 rows) |
| `Page Up` | Move up a page |
| `Home` | Jump to first row |
| `End` | Jump to last row |
| `Enter` | Run the selected command (and append it to recent commands) |
| `Esc` | Close the cmdline without running |
| Mouse click | Click any visible row to accept it |
| Mouse hover | Hover over rows to preview (no auto-fire) |

The footer at the bottom of the box echoes the navigation chord summary so first-time users don't have to guess: `Tab/↓ next · Shift+Tab/↑ prev · Enter run · Esc cancel`.

### Standard mode bypass

In standard input mode, `Ctrl+]` / `Ctrl+[` are bound to **editor.indent_line** / **outdent_line** at the global chord chain. When a Request pane is focused in Edit view, those same chords need to cycle the Edit-view tab strip ([HTTP edit tabs](/manual/http-edit-tabs/)). The dispatcher intercepts `Ctrl+]` / `Ctrl+[` (and `Ctrl+1..6`) before the global chord chain when the focused pane is a Request pane in Edit view, so the tab cycling works in both input modes without a per-mode keymap entry.

The same intercept site means the popup's `Tab` cycling stays a popup concern — the dispatcher checks for an open cmdline first, so when the popup is up `Tab` advances the selected row regardless of input mode.

## Click affordances

The whole popup is mouse-driven if you want:

- **Click a row** → selects and accepts it (same as `Enter` on the selected row).
- **Click the cmdline bar** itself (the row at the bottom of the screen) → opens the cmdline if it's not already open. The hit area is the full bar; mouse path doesn't require knowing the `:` / `Ctrl+;` chord.
- **Hover over rows** highlights without accepting. Useful when scanning a long popup.

## The empty cmdline — recent commands

When the cmdline is empty (you just typed `:`, or opened `Ctrl+;` from tree focus), the popup renders your recent-commands list, most recent first:

```
  ★ http.send
  ★ git.status_pane
  ★ http.bench
  ★ picker.files
  ★ ai.claude_code
```

Every row carries the `★` recent marker (every row is from the recent list, by definition). One keystroke after `:` to land in the popup; `Enter` to re-fire. Useful when you want to immediately re-run something you just did.

The recent list is in-memory only — it resets on each launch. Up to 50 commands tracked.

## The in-flight HTTP indicator

When any of the long-running HTTP operations is on the wire — **bench**, **sync**, or **lookup** — the cmdline bar shows a status indicator pinned to the right side:

```
   bench summary — 10 samples in 1842 ms…                ⟳ bench (12s) running…
```

The format: `⟳ <op> (<elapsed>s) running…`, with multiple in-flight ops comma-joined (`⟳ bench (4s), sync (12s) running…`). Elapsed counts from the moment the worker thread spawned. The indicator is bold orange so it stands out against the dim toast echo on the left.

### Aborting from the cmdline bar

Two ways to stop an in-flight op:

- **Click the indicator** — fires `:http.abort` against every in-flight operation. The op's worker polls a shared `AtomicBool` between iterations and exits at the next boundary; the indicator clears within a tick.
- **`Esc` on the cmdline** — same effect. If `:` is open and an HTTP op is in flight, `Esc` aborts the in-flight HTTP work in addition to closing the cmdline.

The indicator's click rect is narrower than the rest of the cmdline bar so clicking it doesn't fall through to "open the cmdline" — the narrow rect is checked first by the mouse dispatcher.

`send` / `send_streaming` don't show in the indicator because they're per-pane (the Request pane shows its own Sending / Streaming state). Only the long-running fan-out ops do.

## Toast `[name]` mentions

When a command toasts a message that includes a bracketed pane name — typical for HTTP operations that open a scratch pane, like `bench summary → [bench-trace]` or `sync done → [http-sync-trace]` — the bracketed portion renders in **yellow + bold + underlined** instead of dim grey. Clicking it switches focus to that scratch pane.

The reveal is substring-matched against pane titles, so a toast saying `[bench-trace]` reveals the first pane whose title contains `bench-trace`. Bracketed mentions in command output without a matching pane no-op gracefully (the click does nothing).

## Configuration

The popup's border color is a Color-row setting in `[Settings overlay](/manual/settings/#color-rows-v2)`:

```toml
[ui]
cmdline_popup_border_color = "61afef"  # 6-char hex, no leading #
```

Default tracks the theme's accent. Edit in the overlay (`:settings`) under `── UI ──` → **Cmdline popup border color** for a live-edit preview — typing the hex updates the swatch and repaints the popup in real time.

Other knobs: there are no others. Popup width, height, recent-list cap, and tier weights are compile-time constants — open the source if you want to tune them.

## Next

- [HTTP client](/manual/http/) — the surface the popup most frequently completes against (`:http.send`, `:http.bench`, …)
- [HTTP edit tabs](/manual/http-edit-tabs/) — Request-pane tab cycling shares the same chord intercept site as the popup
- [Settings & configuration](/manual/settings/) — `ui.cmdline_popup_border_color` is the first Color-row consumer
- [Editing](/manual/editing/) — `:` is the vim ex-command line; the popup applies to that surface too
- [Chord chains](/manual/chord-chains/) — `Ctrl+;` / `:` / leader chords all funnel through the same dispatcher
