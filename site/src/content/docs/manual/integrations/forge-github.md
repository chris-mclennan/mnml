---
title: GitHub forge viewer
description: mnml-forge-github — a GitHub Issues + PRs + Actions viewer (standalone or hosted as an mnml pane). Configurable tabs backed by GitHub's issue-search API and the Actions workflow-runs API, sibling to mnml-forge-bitbucket / mnml-forge-gitlab / mnml-forge-azdevops in the "forge" integration class.
---

[`mnml-forge-github`](https://github.com/chris-mclennan/mnml-forge-github) is a terminal GitHub viewer. Runs **standalone in any terminal**. Configurable through your normal mnml config conventions — see [Building integrations](/manual/integrations/building/) for the model.

It's the GitHub side of the **forge** integration class — sibling to [`mnml-forge-bitbucket`](/manual/integrations/forge-bitbucket/), [`mnml-forge-gitlab`](/manual/integrations/forge-gitlab/), and [`mnml-forge-azdevops`](/manual/integrations/forge-azdevops/). v0.2 ships two tab kinds — Issues / PRs via GitHub's unified `/search/issues` endpoint (the `pull_request` marker on each result lets the viewer style PRs differently from issues), and Actions workflow runs scoped to one repo (with an optional branch filter). The eventual direction is a full multi-tab forge view — Issues / PRs / Actions / Releases — mirroring how `mnml-forge-bitbucket` grew.

```
┌─ github ─────────────────────────────────────────────────────────┐
│ ▸1.Mine (12)  2.Reported (5)  3.PRs (8)                          │
└──────────────────────────────────────────────────────────────────┘
┌─ Mine ───────────────────────────────────────────────────────────┐
│ KIND   REPO                  KEY    STATE  AUTHOR        UPDATED   TITLE
│ issue  chris-mclennan/mnml   #128   open   chris-mclennan 2026-06-03 Fix…
│ PR     chris-mclennan/mixr   #45    open   chris-mclennan 2026-06-02 Add…
│ …                                                                │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · Enter/o open · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-forge-github mnml-forge-github
```

Homebrew tap + binary releases will follow once the binary stabilises.

## Setup

1. **Generate a GitHub PAT** at <https://github.com/settings/tokens>. A classic token with `repo` scope works (or just `public_repo` if you only need public repos). Fine-grained PATs need **Issues: read** + **Pull requests: read** on the repos you want to query.

2. **Save the token** to `~/.config/mnml-forge-github/token` with `chmod 600`:

   ```sh
   mkdir -p ~/.config/mnml-forge-github
   pbpaste > ~/.config/mnml-forge-github/token   # or paste it in $EDITOR
   chmod 600 ~/.config/mnml-forge-github/token
   ```

3. **Run once** to scaffold the config template:

   ```sh
   mnml-forge-github
   ```

   On first launch with no config, it writes `~/.config/mnml-forge-github.toml` and exits with instructions. Edit the `[[tabs]]` list to taste.

4. **Re-run** — the TUI launches with your configured tabs.

5. **Verify** the resolved config + auth state without launching the TUI:

   ```sh
   mnml-forge-github --check
   ```

## Tab kinds

Each `[[tabs]]` entry is one tab. The `kind` field (defaults to `issues`) decides what the tab shows:

| `kind` | What it shows | Required fields |
|---|---|---|
| `issues` (default) | Issues / PRs via the `/search/issues` endpoint — covers both | `query` |
| `actions` | Workflow runs for one `owner/repo`, newest-first | `repo` (`owner/name`); optional `branch` |

`query` is ignored on `actions` tabs; `repo` / `branch` are ignored on `issues` tabs.

```toml
[[tabs]]
name = "Mine"
query = "is:open assignee:@me"      # kind defaults to issues

[[tabs]]
name = "mnml CI"
kind = "actions"
repo = "chris-mclennan/mnml"

[[tabs]]
name = "main CI"
kind = "actions"
repo = "chris-mclennan/mnml"
branch = "main"
```

### Issues / PRs tabs

`kind = "issues"` is backed by GitHub's issue-search `query` — the same syntax as the search box on github.com. Because `/search/issues` covers **both Issues and PRs**, a single tab can mix them; the viewer surfaces the difference in the `KIND` column and via magenta/cyan row styling. Use `is:issue` or `is:pr` to scope.

```toml
# Across all repos: open issues assigned to you.
[[tabs]]
name = "Mine"
query = "is:open is:issue assignee:@me"

# Open PRs you're involved in (review-requested, assigned, author).
[[tabs]]
name = "PRs"
query = "is:open is:pr involves:@me"

# Repo-scoped — open bugs on a specific repo.
[[tabs]]
name = "mnml bugs"
query = "repo:chris-mclennan/mnml is:open is:issue label:bug"
```

Reference: [GitHub's issue-search syntax docs](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests).

### Actions tabs

`kind = "actions"` lists recent workflow runs for a single `owner/repo`, ordered server-side by `created_at` descending. The `STATUS` column collapses GitHub's two-stage state into one chip via `WorkflowRun::status_chip()` — `queued` / `running` while in flight, then the `conclusion` (`success` / `failure` / `cancelled` / `skipped` / `neutral` / …) once the run completes.

```toml
# All branches.
[[tabs]]
name = "mnml CI"
kind = "actions"
repo = "chris-mclennan/mnml"

# Narrowed to one branch.
[[tabs]]
name = "main CI"
kind = "actions"
repo = "chris-mclennan/mnml"
branch = "main"
```

Pagination isn't wired in v0.2 — the viewer fetches the first page only.

### Default scaffold

The first-run template ships with **4 tabs**, plus two commented-out Actions examples:

| Tab | Kind | Notes |
|---|---|---|
| Mine | `issues` | `query = "is:open assignee:@me"` |
| My PRs | `issues` | `query = "is:open is:pr author:@me"` |
| Reviewing | `issues` | `query = "is:open is:pr review-requested:@me"` |
| mnml bugs | `issues` | Repo-scoped — swap in a repo you care about |

Edit or replace freely; you're not locked in. Tabs are switched via `1`-`9` keys (or click) and ordered left → right. Auto-refresh runs every `refresh_interval_secs` seconds (default `60`, set to `0` to disable).

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused issue / PR / workflow run in your browser |
| `y` | Yank focused row's URL to the OS clipboard |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

Just run `mnml-forge-github` in any terminal. The TUI takes over until you `q`.

### Hosted as a mnml Pty pane

```vim
:term mnml-forge-github
```

mnml spawns it in a Pty pane — splittable, focusable, key-routed like any other pane.

## Wire it into mnml's left rail

To get a one-click chip in mnml's rail under **INTEGRATIONS** (between Claude Code / Codex / Bitbucket / HTTP / etc.), drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "github"
glyph    = "\U000F02A4"            # nf-md-github (TOML 8-digit form)
fallback = "G"
command  = ":term mnml-forge-github"
color    = "white"
tooltip  = "Open GitHub issues + PRs"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults (Claude Code / Codex / Bitbucket / HTTP / CodeBuild / GitHub), so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference and the `\UXXXXXXXX` Nerd-Font escape convention.

## Status & roadmap

**v0.2 (this release)** — adds `kind = "actions"` (workflow runs for one `owner/repo`, optional branch filter). v0.1 Issues / PRs search (now `kind = "issues"`) is unchanged, so existing configs keep working without edits — the kind field defaulted in.

**v0.1** — standalone TUI, configurable tabs via GitHub issue-search queries (Issues and PRs in a single endpoint), `1`-`9` tab switching, arrow navigation, open-in-browser, manual + interval refresh, KIND-column differentiation between issues and PRs.

**v0.3 direction** — paralleling `mnml-forge-bitbucket`'s evolution into a full forge view, the next pass adds a right-half detail panel (body + comments + reviews), a filter editor overlay (`/`) on top of the per-tab query, status transitions (close / reopen / merge), watcher (subscribe) toggle, comment posting, bulk operations across selected rows, and inline label / assignee edits. Beyond v0.3, the "forge" framing is meant to grow into dedicated Issues / PRs / Actions / Releases tab dimensions per repo, not just a flat search list.

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-forge-github](https://github.com/chris-mclennan/mnml-forge-github). MIT-licensed and built around the same `ratatui` substrate mnml uses, so most of its UI patterns will look familiar. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
