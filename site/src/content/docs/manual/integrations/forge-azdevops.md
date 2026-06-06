---
title: Azure DevOps forge viewer
description: mnml-forge-azdevops — an Azure DevOps Pull Requests + Builds viewer (standalone or hosted as an mnml pane). Configurable tabs per-repo or project-spanning via `mode = mine|reviewing`, with optional repo/branch/definition narrowers on Build tabs.
---

[`mnml-forge-azdevops`](https://github.com/chris-mclennan/mnml-forge-azdevops) is a terminal Azure DevOps viewer. Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol. It's the Azure DevOps side of the **forge** integration class — sibling to [`mnml-forge-bitbucket`](/manual/integrations/forge-bitbucket/), [`mnml-forge-github`](/manual/integrations/forge-github/), and [`mnml-forge-gitlab`](/manual/integrations/forge-gitlab/). See [Building integrations](/manual/integrations/building/) for the model.

```
┌─ azure devops ───────────────────────────────────────────────────┐
│ ▸1.Mine (4)  2.Reviewing (6)  3.api PRs (12)  4.Builds (50)      │
└──────────────────────────────────────────────────────────────────┘
┌─ Mine ───────────────────────────────────────────────────────────┐
│ ID    │ STATUS  │ REPO     │ SRC → DEST          │ TITLE         │
│ #421  │ active  │ api      │ feat/x → main       │ Add /v2 …     │
│ #418  │ active  │ web      │ chore/deps → main   │ Bump axios …  │
│ …                                                                 │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · Enter/o open · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-forge-azdevops mnml-forge-azdevops
```

Homebrew tap + binary releases will follow once the binary stabilises.

## Setup

1. **Create an Azure DevOps PAT** at `https://dev.azure.com/<org>/_usersSettings/tokens`.

   Minimum scopes: **Code (Read)** for PR tabs and **Build (Read)** for Build tabs. Add **User Profile (Read)** if you want `mode = "mine"` / `mode = "reviewing"` tabs — those resolve the current user's GUID via `/_apis/connectionData` at startup.

2. **Save the PAT** to `~/.config/mnml-forge-azdevops/token` with `chmod 600`:

   ```sh
   mkdir -p ~/.config/mnml-forge-azdevops
   pbpaste > ~/.config/mnml-forge-azdevops/token   # or paste it in $EDITOR
   chmod 600 ~/.config/mnml-forge-azdevops/token
   ```

3. **Run once** to scaffold the config template:

   ```sh
   mnml-forge-azdevops
   ```

   Writes `~/.config/mnml-forge-azdevops.toml` and exits with instructions. Edit `org`, `project`, and the `[[tabs]]` list.

4. **Re-run** — the TUI launches with your configured tabs.

5. **Verify** the resolved config + auth state without launching the TUI:

   ```sh
   mnml-forge-azdevops --check
   ```

   Hits `/_apis/connectionData` to confirm the PAT works.

## Auth shape

Azure DevOps PATs go on the wire as **HTTP Basic with an empty username and the PAT as the password** — that's the platform's documented convention, not a quirk of this viewer. The client base64-encodes `:<token>` and sends `Authorization: Basic <encoded>` on every request. There is no Bearer-token variant.

## Config

```toml
org     = "your-org"      # required: <org> in dev.azure.com/<org>/
project = "your-project"  # optional default; tabs can override

refresh_interval_secs = 60
```

`org` is required at the top level. `project` is an optional default — every tab must end up with one, either inherited from the top or set inline via `project = "..."` on the row. A tab can also override the org per-row with `org = "..."` if you operate across multiple organizations under a single PAT.

## Tab kinds

Each `[[tabs]]` entry is one tab. The `kind` field (defaults to `pull_requests`) decides what the tab shows:

| `kind` | What it shows | Required fields |
|---|---|---|
| `pull_requests` (default) | PR list, with state filter + optional mine/reviewing modes | one of `repo` / `mode` |
| `builds` | Recent builds for the project, newest-first | none (project-scoped); optional `repo` / `branch` / `definition` |

PR-specific fields (`state`, `mode`) are ignored on `builds` tabs; `branch` / `definition` are ignored on `pull_requests` tabs.

```toml
[[tabs]]
name = "Reviewing"
mode = "reviewing"           # kind defaults to pull_requests

[[tabs]]
name = "api PRs"
repo  = "api"
state = "active"

[[tabs]]
name = "Builds"
kind  = "builds"
```

### Pull-request tab shapes

Three shapes for `kind = "pull_requests"`:

#### Per-repo

```toml
[[tabs]]
name  = "api PRs"
repo  = "api"
state = "active"           # active / completed / abandoned / all
```

`repo` is the `<repo>` segment in `dev.azure.com/<org>/<project>/_git/<repo>`. Uses the default org + project from the top of the config unless overridden inline.

#### `mode = "mine"` — PRs you created

```toml
[[tabs]]
name = "Mine"
mode = "mine"
```

Project-spanning — hits `GET /{org}/{project}/_apis/git/pullrequests?searchCriteria.creatorId=<your-guid>`. Resolves the current user's GUID once at startup via `/_apis/connectionData` (needs **User Profile (Read)**).

#### `mode = "reviewing"` — PRs you're a reviewer on

```toml
[[tabs]]
name = "Reviewing"
mode = "reviewing"
```

Same as `mine` but with `searchCriteria.reviewerId` instead of `creatorId`.

The `state` field (`active` / `completed` / `abandoned` / `all`) applies to all three shapes. `all` drops the `searchCriteria.status` query param.

### Builds tabs

`kind = "builds"` is project-scoped by default; every narrower is optional. The `STATUS` column collapses Azure DevOps's two-stage state into one chip via `Build::status_chip()` — `queued` while not-started, `running` while in-progress, then the `result` (`succeeded` / `failed` / `cancelled` / `partiallySucceeded` / …) once the build completes.

```toml
# All builds in the project.
[[tabs]]
name = "Builds"
kind = "builds"

# Narrowed to one repo + one branch.
[[tabs]]
name   = "api main"
kind   = "builds"
repo   = "api"
branch = "main"

# Narrowed to one pipeline definition (by numeric ID).
[[tabs]]
name       = "release pipeline"
kind       = "builds"
definition = 42
```

The `branch` filter accepts both short names (`main`) and full refs (`refs/heads/main`) — the client normalizes short names to `refs/heads/<name>` before querying. `definition` is the pipeline-definition ID (visible in the URL on dev.azure.com), not the name.

### Default scaffold

The first-run template ships with **4 tabs** plus a commented-out repo+branch builds example:

| Tab | Kind | Notes |
|---|---|---|
| Mine | `pull_requests` | `mode = "mine"` |
| Reviewing | `pull_requests` | `mode = "reviewing"` |
| your-repo PRs | `pull_requests` | Per-repo, state `active` |
| Builds | `builds` | Project-scoped, all repos / branches |

Edit or replace freely; you're not locked in.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused PR or build in your browser |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

Auto-refresh runs every `refresh_interval_secs` seconds (default `60`, set to `0` to disable).

## Two run modes

### Standalone

Just run `mnml-forge-azdevops` in any terminal. The TUI takes over until you `q`.

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-forge-azdevops
```

mnml spawns it with `--blit <socket>` and renders the streamed cells into a native `Pane::BlitHost`. The pane becomes a normal mnml pane — splittable, focusable, key-routed. `Ctrl+E` releases focus back to the layout tree. See [Building integrations](/manual/integrations/building/) for the protocol mechanism.

## Wire it into mnml's left rail

`mnml-forge-azdevops` ships as a default chip in mnml's rail under **INTEGRATIONS** — no config needed if you've kept the built-in defaults. To customise the icon, drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "azdevops"
glyph    = "\U0000EBE8"            # nf-cod-azure (TOML 8-digit form)
fallback = "A"
command  = ":host.launch mnml-forge-azdevops"
color    = "blue"
tooltip  = "Open Azure DevOps PRs + builds"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults, so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference and the `\UXXXXXXXX` Nerd-Font escape convention.

## Status

**v0.1 (this release)** — Pull Requests + Builds tabs, project-spanning `mine` / `reviewing` PR modes, optional `repo` / `branch` / `definition` narrowers on Build tabs, no detail panel yet (`Enter` opens the PR / build page in the browser). A right-half PR detail panel with comments / diff is queued for v0.2 alongside the comments / iterations endpoints.

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-forge-azdevops](https://github.com/chris-mclennan/mnml-forge-azdevops). MIT-licensed and built around the same `ratatui` substrate mnml uses, so most of its UI patterns will look familiar. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
