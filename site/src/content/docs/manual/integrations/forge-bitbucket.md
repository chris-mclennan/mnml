---
title: Bitbucket forge viewer
description: mnml-forge-bitbucket — a Bitbucket Cloud pull-request, pipelines, and branches viewer (standalone or hosted as an mnml pane). Configurable tabs per-repo or workspace-spanning via `mode = mine|reviewing`, with a right-half PR detail panel and approve/unapprove toggle.
---

[`mnml-forge-bitbucket`](https://github.com/chris-mclennan/mnml-forge-bitbucket) is a terminal Bitbucket Cloud viewer. Runs **standalone in any terminal**. It's the first shipped member of the `forge` integration class — sibling repos `mnml-forge-github` and a future `mnml-forge-gitlab` follow the same shape. See [Building integrations](/manual/integrations/building/) for the model.

```
┌─ bitbucket PRs ──────────────────────────────────────────────────┐
│ ▸1.Mine (3)  2.Reviewing (7)  3.example-api PRs (12)              │
└──────────────────────────────────────────────────────────────────┘
┌─ Mine ───────────────────────────────────────────────────────────┐
│ REPO              │ PR     │ STATE │ AUTHOR  │ BRANCH → DEST     │
│ acme/api    │ #1234  │ OPEN  │ Chris   │ chris/fix → main  │
│ acme/web    │ #821   │ OPEN  │ Chris   │ chris/redesign…   │
│ …                                                                │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · Enter/o open · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-forge-bitbucket mnml-forge-bitbucket
```

Homebrew tap + binary releases will follow once the binary stabilises.

## Setup

1. **Create a Bitbucket app password** at <https://bitbucket.org/account/settings/app-passwords/>.

   Minimum scopes: **Pull requests: Read**. Add **Account: Read** if you want `mode = "mine"` / `mode = "reviewing"` tabs (those need `/2.0/user` to resolve your `account_id`) or the `a` approve toggle.

2. **Save the app password** to `~/.config/mnml-forge-bitbucket/token` with `chmod 600`:

   ```sh
   mkdir -p ~/.config/mnml-forge-bitbucket
   pbpaste > ~/.config/mnml-forge-bitbucket/token   # or paste it in $EDITOR
   chmod 600 ~/.config/mnml-forge-bitbucket/token
   ```

3. **Run once** to scaffold the config template:

   ```sh
   mnml-forge-bitbucket
   ```

   On first launch with no config, it writes `~/.config/mnml-forge-bitbucket.toml` and exits with instructions. Edit `email`, `workspace`, and the `[[tabs]]` list.

4. **Re-run** — the TUI launches with your configured tabs.

5. **Verify** the resolved config + auth state without launching the TUI:

   ```sh
   mnml-forge-bitbucket --check
   ```

   Hits `/2.0/user` to confirm the app password works.

## Tab kinds

Each `[[tabs]]` entry is one tab. The `kind` field (defaults to `pull_requests`) decides what the tab shows:

| `kind` | What it shows | Required fields |
|---|---|---|
| `pull_requests` (default) | PR list, with state filter + optional mine/reviewing modes | one of `repo` / `mode` / `q` |
| `pipelines` | Recent builds for a repo, newest-first | `repo` |
| `branches` | Branches in a repo, sorted by latest commit | `repo` |

PR-specific fields (`state`, `mode`, `q`) are ignored on `pipelines` and `branches` tabs.

```toml
[[tabs]]
name = "Reviewing"
mode = "reviewing"          # kind defaults to pull_requests

[[tabs]]
name = "example-api pipelines"
kind = "pipelines"
repo = "example-api"

[[tabs]]
name = "example-api branches"
kind = "branches"
repo = "example-api"
```

### Pull-request tab shapes

Three shapes for `kind = "pull_requests"`:

#### Per-repo

```toml
[[tabs]]
name  = "example-api PRs"
repo  = "example-api"
state = "OPEN"             # OPEN / MERGED / DECLINED / SUPERSEDED
```

Uses the default workspace from the top of the config. Override per-tab with `workspace = "otherws"` if needed.

#### `mode = "mine"` — PRs you opened

```toml
[[tabs]]
name = "Mine"
mode = "mine"
```

Resolves to a workspace-spanning BBQL query — `author.account_id = "<your-id>"`. Requires **Account: Read** on the app password.

#### `mode = "reviewing"` — PRs you're a reviewer on

```toml
[[tabs]]
name = "Reviewing"
mode = "reviewing"
```

Same as `mine` but with `reviewers.account_id = "<your-id>"`.

#### Custom BBQL

For finer-grained control you can supply a raw Bitbucket Query Language string via `q`. Either as the only filter (no `mode`, no `repo`) or layered on top of an auto-mode tab:

```toml
[[tabs]]
name  = "Stale PRs"
repo  = "example-api"
state = "OPEN"
q     = "updated_on <= 2026-05-01T00:00:00+00:00"
```

BBQL reference: <https://developer.atlassian.com/cloud/bitbucket/rest/intro/#filtering-and-sorting-results>

### Default scaffold

The first-run template ships with **5 tabs**:

| Tab | Kind | Notes |
|---|---|---|
| Mine | `pull_requests` | `mode = "mine"` |
| Reviewing | `pull_requests` | `mode = "reviewing"` |
| your-repo PRs | `pull_requests` | per-repo, state `OPEN` |
| your-repo pipelines | `pipelines` | newest-first builds |
| your-repo branches | `branches` | sorted by latest commit |

Edit or replace freely; you're not locked in.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused PR (or pipeline / branch) in your browser |
| `y` | Yank focused row's URL to the OS clipboard |
| `d` | Toggle right-half PR detail panel |
| `Ctrl+U` / `Ctrl+D` | Scroll detail panel up / down (when open) |
| `a` | Toggle your approval on the focused PR (detail panel must be open) |
| `r` | Refresh active tab (+ detail if open) |
| `q` / `Esc` / `Ctrl+C` | Quit |

Auto-refresh runs every `refresh_interval_secs` seconds (default `60`, set to `0` to disable).

### Detail panel

`d` opens a right-half panel for the focused PR: header (state · branches · author · updated · approval chip), then title, description, then up to the last 20 comments (most-recent first). Detail content is lazy-loaded on first focus and cached per `(workspace, repo, id)` — arrow-keying through a long list only fetches once per PR.

`r` while the detail panel is open invalidates the cached detail for the focused PR and re-fetches both the list and the detail — useful after a new comment landed server-side.

The approval chip shows either `✓ you approved · N total` or `○ not approved · N total`. `N` is the count of approving participants on the PR (including you).

### Approve / unapprove

`a` (with the detail panel open) toggles your approval. The viewer reads the current state from the cached participant record and POSTs or DELETEs `/pullrequests/{id}/approve` accordingly, then drops the cache so a re-fetch picks up the new state. Requires **Account: Read** on the app password — otherwise the viewer can't resolve your `account_id` and the toggle is a no-op with an explanatory toast.

## Two run modes

### Standalone

Just run `mnml-forge-bitbucket` in any terminal. The TUI takes over until you `q`.

### Hosted as a mnml Pty pane

```vim
:term mnml-forge-bitbucket
```

mnml spawns it in a Pty pane — splittable, focusable, key-routed like any other pane.

## Wire it into mnml's left rail

To get a one-click chip in mnml's rail under **INTEGRATIONS** (alongside Claude Code / Codex / Jira / HTTP / etc.), drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "bitbucket"
glyph    = "\U000F0093"            # nf-md-bitbucket (TOML 8-digit form)
fallback = "B"
command  = ":term mnml-forge-bitbucket"
color    = "blue"
tooltip  = "Open Bitbucket PRs"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults (Claude Code / Codex / Bitbucket / HTTP / CodeBuild / GitHub), so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference and the `\UXXXXXXXX` Nerd-Font escape convention.

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-forge-bitbucket](https://github.com/chris-mclennan/mnml-forge-bitbucket). MIT-licensed and built around the same `ratatui` substrate mnml uses, so most of its UI patterns will look familiar. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
