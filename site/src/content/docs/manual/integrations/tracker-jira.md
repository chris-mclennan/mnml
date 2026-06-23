---
title: Jira tickets viewer
description: mnml-tracker-jira — a Jira ticket viewer (standalone or hosted as an mnml pane). Configurable tabs from literal JQL or auto-resolved release fixVersions, with detail panel, status transitions, inline assignee/fixVersion editing, bulk ops, comment posting, and watcher toggle.
---

[`mnml-tracker-jira`](https://github.com/chris-mclennan/mnml-tracker-jira) is a terminal Jira viewer. Runs **standalone in any terminal**. Configurable through your normal mnml config conventions — see [Building integrations](/manual/integrations/building/) for the model.

```
┌─ tickets ────────────────────────────────────────────────────────┐
│ ▸1.Testing (12)  2.Current (47)  3.Next (8)  4.Mobile (3)  5.Mine │
└────────┬─────────────────────────────────────────────────────────┘
┌─ Testing─┼──────────────┐┌─ TE-1234 ★ watching (4 total) ──────┐
│ KEY      │ STATUS  …    ││ Bug · Highest · @chrismclennan       │
│ TE-1234▸│ Testing …    ││ fixVersion: 6.4 · reporter: andrew    │
│ TE-1235  │ Testing …    ││                                       │
│ …                       ││ When the bufferline drops a tab on   │
│                         ││ window resize the next render panic… │
│                         ││                                       │
│                         ││ comments (3, most-recent first):     │
│                         ││  ▸ chrismclennan · 2026-06-02         │
│                         ││    repro on 0.1.2 too, fix forthcoming│
└─────────────────────────┘└──────────────────────────────────────┘
  d toggle detail · t transition · / filter · w watch · c comment · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-tracker-jira mnml-tracker-jira
```

Homebrew tap + binary releases will follow once the binary stabilises.

## Setup

1. **Get a Jira API token** from <https://id.atlassian.com/manage-profile/security/api-tokens>.

2. **Save it** to `~/.config/mnml-tracker-jira/token` with `chmod 600`:

   ```sh
   mkdir -p ~/.config/mnml-tracker-jira
   pbpaste > ~/.config/mnml-tracker-jira/token   # or paste it in $EDITOR
   chmod 600 ~/.config/mnml-tracker-jira/token
   ```

3. **Run once** to scaffold the config template:

   ```sh
   mnml-tracker-jira
   ```

   On first launch with no config, it writes `~/.config/mnml-tracker-jira.toml` and exits with instructions. Edit `jira_url`, `email`, and the `[[tabs]]` list.

4. **Re-run** — the TUI launches with your configured tabs.

5. **Verify** the resolved config + auth state without launching the TUI:

   ```sh
   mnml-tracker-jira --check
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

### Per-tab column override

Each `[[tabs]]` entry can override the default column set via `columns = [...]`. Default (when unset) is `["key", "status", "assignee", "updated", "summary"]`. Valid values: `key`, `status`, `assignee`, `reporter`, `priority`, `type`, `updated`, `fix_version`, `summary`. `summary` is the only column that fills remaining width — put it last.

```toml
[[tabs]]
name = "Mine"
jql  = "reporter = currentUser() ORDER BY updated DESC"
columns = ["key", "priority", "status", "updated", "summary"]
```

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused ticket in your browser |
| `d` | Toggle right-half detail panel |
| `Ctrl+U` / `Ctrl+D` | Scroll detail panel up / down (when open) |
| `/` | Open filter editor (substring match against key + summary) |
| `t` | Open status transition picker (operates on multi-selection if non-empty) |
| `a` | Open assignee picker (operates on multi-selection if non-empty) |
| `f` | Open fixVersion picker (operates on multi-selection if non-empty) |
| `c` | Open inline comment editor (detail panel must be open) — `Ctrl+S` posts, `Esc` cancels |
| `w` | Toggle watch on focused ticket |
| `Space` | Toggle focused row in multi-selection set |
| `r` | Refresh active tab (+ detail if open) |
| `Esc` | Cascade: clear selection → clear filter → close detail → quit |
| `q` / `Ctrl+C` | Quit |

Auto-refresh runs every `refresh_interval_secs` seconds (default `60`, set to `0` to disable).

### Detail panel

`d` opens a right-half panel for the focused ticket: header (type / status / priority / assignee / reporter / fixVersion / watcher chip), then description, then the last 10 comments (most-recent first). The narrative content is lazy-loaded on first focus and cached per-issue key — arrow-keying through a long list only fetches once per ticket. `Ctrl+U` / `Ctrl+D` scroll inside the panel. `r` invalidates the cached detail and re-fetches.

Atlassian Document Format (Jira's rich-text JSON) is rendered as plain text: inline marks (bold, italic, links) are stripped; block structure (paragraphs, bullet lists, code blocks) is preserved by newlines.

### Multi-selection + bulk ops

`Space` toggles the focused row into a per-tab selection set, marked visually in the leftmost column. With at least one row selected, `t` / `a` / `f` operate on every selected ticket in parallel (with an error tally if any fail). Selection clears on tab switch and after a successful bulk op.

### Inline comment posting

With the detail panel open, `c` drops a one-block editor at the bottom of the panel. Multi-line via `Enter`. `Ctrl+S` posts via the Jira REST API (`POST /issue/{key}/comment`); `Esc` discards. The posted comment shows up in the detail panel as soon as the request resolves — no manual refresh needed.

## Two run modes

### Standalone

Just run `mnml-tracker-jira` in any terminal. The TUI takes over until you `q`.

### Hosted as a mnml Pty pane

```vim
:term mnml-tracker-jira
```

mnml spawns it in a Pty pane — splittable, focusable, key-routed like any other pane.

## Wire it into mnml's left rail

To get a one-click chip in mnml's rail under **INTEGRATIONS** (between Claude Code / Codex / Bitbucket / HTTP / etc.), drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "jira"
glyph    = "\U000F0411"            # nf-md-jira (TOML 8-digit form)
fallback = "J"
command  = ":term mnml-tracker-jira"
color    = "blue"
tooltip  = "Open Jira tickets"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults (Claude Code / Codex / Bitbucket / HTTP / CodeBuild / GitHub), so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference and the `\UXXXXXXXX` Nerd-Font escape convention.

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-tracker-jira](https://github.com/chris-mclennan/mnml-tracker-jira). MIT-licensed and built around the same `ratatui` substrate mnml uses, so most of its UI patterns will look familiar. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
