---
title: Jira tickets viewer
description: mnml-tickets-jira — a standalone Jira ticket viewer (and blit-host integration) for mnml. Configurable tabs from literal JQL or auto-resolved release fixVersions; runs in your terminal or as a hosted mnml pane.
---

[`mnml-tickets-jira`](https://github.com/chris-mclennan/mnml-tickets-jira) is a standalone terminal viewer for Jira tickets, configurable through your normal mnml config conventions. It's the first integration in the planned **multi-view class** — database viewers (`mnml-db-postgres`, …), ticket viewers (`mnml-tickets-{linear,github,gitlab,jira}`), and the Playwright runner all follow this same out-of-process, blit-hosted pattern.

```
┌─ tickets ────────────────────────────────────────────────────────┐
│ ▸1.Testing (12)  2.Current (47)  3.Next (8)  4.Mobile (3)  5.Mine │
└──────────────────────────────────────────────────────────────────┘
┌─ Testing ────────────────────────────────────────────────────────┐
│ KEY      STATUS    ASSIGNEE        UPDATED     SUMMARY           │
│ TE-1234  Testing   chrismclennan   2026-06-02  Bufferline drops… │
│ TE-1235  Testing   andrew          2026-06-01  AI panel margin…  │
│ …                                                                │
└──────────────────────────────────────────────────────────────────┘
  refreshing Testing…   1-9 tab · ↑↓/jk move · Enter/o open · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-tickets-jira mnml-tickets-jira
```

Homebrew tap + binary releases will follow once the binary stabilises.

## Setup

1. **Get a Jira API token** from <https://id.atlassian.com/manage-profile/security/api-tokens>.

2. **Save it** to `~/.config/mnml-tickets-jira/token` with `chmod 600`:

   ```sh
   mkdir -p ~/.config/mnml-tickets-jira
   pbpaste > ~/.config/mnml-tickets-jira/token   # or paste it in $EDITOR
   chmod 600 ~/.config/mnml-tickets-jira/token
   ```

3. **Run once** to scaffold the config template:

   ```sh
   mnml-tickets-jira
   ```

   On first launch with no config, it writes `~/.config/mnml-tickets-jira.toml` and exits with instructions. Edit `jira_url`, `email`, and the `[[tabs]]` list.

4. **Re-run** — the TUI launches with your configured tabs.

5. **Verify** the resolved config + auth state without launching the TUI:

   ```sh
   mnml-tickets-jira --check
   ```

## Tab modes

Each `[[tabs]]` entry is one tab. Two modes are supported:

### Literal JQL

```toml
[[tabs]]
name = "Mine"
jql  = "reporter = currentUser() ORDER BY updated DESC"
```

Full control. You maintain version strings, component names, and any filters. The JQL is sent verbatim to Jira's search API.

### Auto-resolved from release list

```toml
# First unreleased fixVersion of project TE.
[[tabs]]
name    = "Current"
mode    = "current_release"
project = "TE"

# Second unreleased fixVersion of TE, filtered to the Mobile component.
[[tabs]]
name      = "Mobile"
mode      = "next_release"
project   = "TE"
component = "Mobile"
```

| `mode` | Resolves to |
|---|---|
| `current_release` | Earliest unreleased `fixVersion` of `project` |
| `next_release` | Second-earliest unreleased `fixVersion` (falls back to `current_release` if only one exists) |

The optional `component` field narrows the resolved JQL to a single component — useful for splitting "Mobile" / "API" / "Web" lanes off the same release.

Tab names are free-form — they're what shows in the tab strip.

### Default scaffold

The first-run template ships with **5 tabs**:

| Tab | Mode |
|---|---|
| Testing | Literal JQL — issues in the `Testing` status |
| Current | `current_release` |
| Next | `next_release` |
| Mobile | `next_release` + `component = "Mobile"` |
| Mine | Literal JQL — `reporter = currentUser()` |

Edit or replace freely; you're not locked in.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused ticket in your browser |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

Auto-refresh runs every `refresh_interval_secs` seconds (default `60`, set to `0` to disable).

## Two run modes

### Standalone

Just run `mnml-tickets-jira` in any terminal. The TUI takes over until you `q`.

### Blit-host (hosted by mnml)

When mnml-tickets-jira is invoked as `mnml-tickets-jira --blit <socket>`, it speaks tmnl-protocol over the given Unix-domain socket instead of crossterm. mnml's `:host.launch` ex-command spawns it that way and renders the streamed cells into a regular mnml pane:

```vim
:host.launch mnml-tickets-jira
```

The pane becomes a normal mnml pane — splittable, focusable, key-routed through the `Pane::BlitHost` dispatch path. `Ctrl+E` releases focus back to the layout tree. See the [Blit-host integration class](/manual/settings/#the-launcher-icon-strips) section for the underlying mechanism.

## Wire it into mnml's left rail

To get a one-click chip in mnml's rail under **INTEGRATIONS** (between Claude Code / Codex / Bitbucket / HTTP / etc.), drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "jira"
glyph    = "\U000F0411"            # nf-md-jira (TOML 8-digit form)
fallback = "J"
command  = ":host.launch mnml-tickets-jira"
color    = "blue"
tooltip  = "Open Jira tickets"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults (Claude Code / Codex / Bitbucket / HTTP / CodeBuild / GitHub), so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference and the `\UXXXXXXXX` Nerd-Font escape convention.

## Roadmap

**v0.1 (current):**

- Standalone TUI mode
- Configurable JQL or auto-resolved release tabs
- 1-9 tab switching · ↑↓ navigation · open-in-browser · refresh
- `--check` mode for config + auth verification

**Planned:**

- Blit-host mode (`--blit <socket>`) so mnml can `:host.launch` it as a hosted pane
- Right-half ticket detail panel (description + comments + transitions)
- Status transition picker (`t` opens a "move to → " menu)
- In-tab search/filter overlay (`/`)
- Watcher / star toggle
- Per-tab column override

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-tickets-jira](https://github.com/chris-mclennan/mnml-tickets-jira). It's MIT-licensed and built around the same `ratatui` substrate mnml uses, so most of its UI patterns will look familiar.
