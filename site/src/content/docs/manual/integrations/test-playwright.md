---
title: Playwright trace viewer
description: mnml-test-playwright — a terminal viewer for Playwright trace.zip files. Per-action timeline, console messages, errors, stdio with type-toggle filters. The test runner stays in mnml core; this is just the trace viewer.
---

[`mnml-test-playwright`](https://github.com/chris-mclennan/mnml-test-playwright) is a terminal viewer for Playwright `trace.zip` files — the artifact each failing (or `trace: 'on'`) Playwright test drops in `test-results/<test>/`. Browse the per-action timeline, console messages, errors, and stdio with type-toggle filters. Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol.

```
┌─ trace ──────────────────────────────────────────────────────────┐
│ checkout.spec.ts:24 · filters:  actions  console  errors  stdio  │
└──────────────────────────────────────────────────────────────────┘
┌─ events (47/89) ─────────────────────────────────────────────────┐
│ ▸ ▶    0.012s  page.goto https://shop.example.com                │
│   ▶    1.203s  page.fill #email = user@example.com               │
│   ▶    1.412s  page.click [data-testid="submit"]                 │
│   ●    1.518s  Error: Timeout 30000ms exceeded                   │
│   …                                                              │
└──────────────────────────────────────────────────────────────────┘
  ↑↓/jk · a/c/e/s · E errors-only · R show-all · r reload · q quit
```

## What stays in mnml core

The Playwright **test runner** (`tests.run`, `tests.run_file`, `tests.run_cursor`, the flaky-tests history view, the "heal with AI" flow) **stays in mnml core**. Those need tight editor integration — run the test for the buffer you have open, jump to the failing assertion's source line, edit the spec from the same window.

What lives in this sibling is the **trace viewer** — the read-only side. Useful when:

- You're inspecting a `trace.zip` from CI without running mnml.
- You want a dedicated pane for trace browsing rather than the inline trace render mnml ships.
- You're sharing a trace with a collaborator who doesn't run mnml — they install one binary, get a real viewer.

This split landed 2026-06-06; the in-tree `Pane::Trace` was removed.

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-test-playwright mnml-test-playwright
```

## Usage

```sh
# Open a single trace.zip
mnml-test-playwright path/to/trace.zip

# Print version and exit (no auth or config to validate — trace files are self-contained)
mnml-test-playwright --check
```

The path is **positional** — no config file in v0.1. Trace files are self-contained ZIPs (test name, action timeline, console messages, network requests, screenshots, snapshots) so there's nothing to set up.

Each Playwright test that runs with `trace: 'retain-on-failure'` (or `'on'`) drops a `trace.zip` under `test-results/<test>/`; point this viewer at that file.

## Layout

One main column — a scrollable event list. The header shows the test file + line and the currently-active filter chips.

Each event row carries:

- A type chip — `▶` action / `📜` console / `●` error / `›` stdio
- The relative timestamp from test start (`0.012s`, `1.518s`, etc.)
- A summary — for actions, the method + args; for console, the message; for errors, the stack frame's top line.

Filtering is non-destructive — toggling a chip hides those rows from the list (`events (47/89)` — 47 visible of 89 total) but doesn't drop them from memory. Toggle back on to see them again.

## Filter presets

The four single-key toggles plus two presets:

| Key | Action |
|---|---|
| `a` | Toggle **Actions** |
| `c` | Toggle **Console** |
| `e` | Toggle **Errors** |
| `s` | Toggle **Stdio** |
| `E` | Preset — errors only (everything else off) |
| `R` | Preset — show all kinds |

Default on open: all four kinds visible.

## Keys

| Chord | Action |
|---|---|
| `↑` / `k` | Move selection up |
| `↓` / `j` | Move selection down |
| `PgUp` / `PgDn` | Page up / down |
| `g` / `G` | Top / bottom |
| `a` / `c` / `e` / `s` | Toggle Actions / Console / Errors / Stdio |
| `E` | Errors-only preset |
| `R` | Show-all preset |
| `r` | Reload trace from disk (re-opens the ZIP) |
| `q` / `Esc` / `Ctrl+C` | Quit |

`r` is useful when the trace file is being overwritten by a re-run — reload to pick up the new events without restarting the binary.

## Two run modes

### Standalone

```sh
mnml-test-playwright path/to/trace.zip
```

The TUI takes over until you `q`.

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-test-playwright path/to/trace.zip
```

mnml spawns it with `--blit <socket>` and renders the streamed cells into a native `Pane::BlitHost`. The pane becomes a normal mnml pane — splittable, focusable, key-routed. `Ctrl+E` releases focus back to the layout tree. See [Building integrations](/manual/integrations/building/) for the protocol mechanism.

The positional `trace.zip` path is passed through verbatim — useful for wiring it into a tmnl chord or palette command that opens a fresh trace on demand.

## Wire it into mnml's left rail

If you want a one-click chip in mnml's rail that opens the last failing trace, drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "playwright_trace"
glyph    = "\U000F0668"            # nf-md-play_circle (TOML 8-digit form)
fallback = "P"
command  = ":host.launch mnml-test-playwright last-failure-trace.zip"
color    = "purple"
tooltip  = "Open last Playwright trace"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults, so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference.

You can also point `command` at a shell-resolved path via `:host.launch mnml-test-playwright $(find test-results -name trace.zip | head -1)` — though that requires the shell to expand before the ex-cmdline runs, which mnml's parser doesn't do today. For dynamic paths, the easier route is a thin wrapper script that calls `mnml-test-playwright` with the discovered path.

## Status

**v0.1 (this release)** — Trace viewer only. No flaky-test history view, no test runner, no detail panel for individual events (errors render their first stack line; the full trace is in the ZIP). v0.2 may grow:

- A flaky-tests history view that reads mnml's per-workspace `.mnml/test-history.json` (predicated on a real use case for "I want this without running mnml").
- A detail panel for the focused event — full stack on errors, full args on actions, full network request/response on network rows.
- Snapshot / screenshot rendering inline (currently the trace ZIP carries snapshot HTML that the viewer doesn't unpack).

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-test-playwright](https://github.com/chris-mclennan/mnml-test-playwright). MIT-licensed. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
