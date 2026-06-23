---
title: GitLab forge viewer
description: mnml-forge-gitlab — a GitLab Merge Requests + Pipelines viewer (standalone or hosted as an mnml pane). Configurable tabs per-project or instance-spanning via `mode = mine|reviewing`. Works against gitlab.com or any self-hosted instance via `base_url`.
---

[`mnml-forge-gitlab`](https://github.com/chris-mclennan/mnml-forge-gitlab) is a terminal GitLab viewer. Runs **standalone in any terminal**. It's the GitLab side of the **forge** integration class — sibling to [`mnml-forge-bitbucket`](/manual/integrations/forge-bitbucket/), [`mnml-forge-github`](/manual/integrations/forge-github/), and [`mnml-forge-azdevops`](/manual/integrations/forge-azdevops/). See [Building integrations](/manual/integrations/building/) for the model.

```
┌─ gitlab ─────────────────────────────────────────────────────────┐
│ ▸1.Mine (5)  2.Reviewing (8)  3.api MRs (12)  4.api CI (30)      │
└──────────────────────────────────────────────────────────────────┘
┌─ Mine ───────────────────────────────────────────────────────────┐
│ !    │ STATE  │ PROJECT     │ SRC → DEST          │ TITLE        │
│ !421 │ opened │ org/api     │ feat/x → main       │ Add /v2 …    │
│ !418 │ opened │ org/web     │ chore/deps → main   │ Bump axios … │
│ …                                                                 │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · Enter/o open · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-forge-gitlab mnml-forge-gitlab
```

Homebrew tap + binary releases will follow once the binary stabilises.

## Setup

1. **Create a GitLab personal access token** at <https://gitlab.com/-/user_settings/personal_access_tokens>. For self-hosted: `https://<your-gitlab>/-/user_settings/personal_access_tokens`.

   Minimum scope: **read_api**. Both `mode = "mine"` / `mode = "reviewing"` rely on `read_api` calling `/user` at startup to resolve your numeric `id`.

2. **Save the PAT** to `~/.config/mnml-forge-gitlab/token` with `chmod 600`:

   ```sh
   mkdir -p ~/.config/mnml-forge-gitlab
   pbpaste > ~/.config/mnml-forge-gitlab/token   # or paste it in $EDITOR
   chmod 600 ~/.config/mnml-forge-gitlab/token
   ```

3. **Run once** to scaffold the config template:

   ```sh
   mnml-forge-gitlab
   ```

   Writes `~/.config/mnml-forge-gitlab.toml` and exits with instructions. Edit `base_url` (only needed for self-hosted) and the `[[tabs]]` list.

4. **Re-run** — the TUI launches with your configured tabs.

5. **Verify** the resolved config + auth state without launching the TUI:

   ```sh
   mnml-forge-gitlab --check
   ```

   Hits `/user` to confirm the PAT works.

## Self-hosted GitLab

The top-level `base_url` field points the client at the API root. It defaults to `https://gitlab.com/api/v4`. For self-hosted instances, set it explicitly:

```toml
base_url = "https://gitlab.mycorp.com/api/v4"
```

All endpoints (MRs, pipelines, `/user`) hit the same `base_url`; there's no separate per-tab override. The PAT must come from the same instance — gitlab.com PATs don't work against self-hosted and vice versa.

## Tab kinds

Each `[[tabs]]` entry is one tab. The `kind` field (defaults to `merge_requests`) decides what the tab shows:

| `kind` | What it shows | Required fields |
|---|---|---|
| `merge_requests` (default) | MR list, with state filter + optional mine/reviewing modes | one of `project` / `mode` |
| `pipelines` | Recent pipelines for a project, newest-first | `project` (optional `ref_name`) |

MR-specific fields (`state`, `mode`) are ignored on `pipelines` tabs; `ref_name` is ignored on `merge_requests` tabs.

```toml
[[tabs]]
name = "Reviewing"
mode = "reviewing"               # kind defaults to merge_requests

[[tabs]]
name = "api pipelines"
kind = "pipelines"
project = "your-group/api"

[[tabs]]
name = "api MRs"
project = "your-group/api"
state = "opened"
```

### Merge-request tab shapes

Three shapes for `kind = "merge_requests"`:

#### Per-project

```toml
[[tabs]]
name    = "api MRs"
project = "your-group/api"
state   = "opened"             # opened / closed / merged / all
```

`project` accepts either the `group/path` URL form (URL-encoded automatically) or a numeric project ID.

#### `mode = "mine"` — MRs you opened

```toml
[[tabs]]
name = "Mine"
mode = "mine"
```

Spans every project you can see on the instance. Translates to `GET /merge_requests?author_id=<your-id>`. Resolves the current user's `id` once at startup via `/user` (needs `read_api` scope).

#### `mode = "reviewing"` — MRs you're a reviewer on

```toml
[[tabs]]
name = "Reviewing"
mode = "reviewing"
```

Same as `mine` but with `reviewer_id` instead of `author_id`.

The `state` field (`opened` / `closed` / `merged` / `all`) applies to all three shapes. `all` drops the `state=` query param so server-side defaults apply.

### Pipelines tabs

`kind = "pipelines"` lists recent pipelines for one project, ordered server-side by `created_at` descending. The `STATUS` column renders GitLab's verbatim status — `created`, `waiting_for_resource`, `preparing`, `pending`, `running`, `success`, `failed`, `canceled`, `skipped`, `manual`, `scheduled`.

```toml
# All branches.
[[tabs]]
name    = "api pipelines"
kind    = "pipelines"
project = "your-group/api"

# Narrowed to one branch.
[[tabs]]
name     = "main pipelines"
kind     = "pipelines"
project  = "your-group/api"
ref_name = "main"
```

The optional `ref_name` filter narrows to a single git ref (branch or tag); omit it to see every branch.

### Default scaffold

The first-run template ships with **4 tabs** plus a commented-out branch-filtered pipelines example:

| Tab | Kind | Notes |
|---|---|---|
| Mine | `merge_requests` | `mode = "mine"` |
| Reviewing | `merge_requests` | `mode = "reviewing"` |
| your-project MRs | `merge_requests` | Per-project, state `opened` |
| your-project pipelines | `pipelines` | All branches |

Edit or replace freely; you're not locked in.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused MR or pipeline in your browser |
| `y` | Yank focused row's URL to the OS clipboard |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

Auto-refresh runs every `refresh_interval_secs` seconds (default `60`, set to `0` to disable).

## Two run modes

### Standalone

Just run `mnml-forge-gitlab` in any terminal. The TUI takes over until you `q`.

### Hosted as a mnml Pty pane

```vim
:term mnml-forge-gitlab
```

mnml spawns it in a Pty pane — splittable, focusable, key-routed like any other pane.

## Wire it into mnml's left rail

`mnml-forge-gitlab` ships as a default chip in mnml's rail under **INTEGRATIONS** — no config needed if you've kept the built-in defaults. To customise the icon, drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "gitlab"
glyph    = "\U0000F296"            # nf-fa-gitlab (TOML 8-digit form)
fallback = "L"
command  = ":term mnml-forge-gitlab"
color    = "orange"
tooltip  = "Open GitLab MRs + Pipelines"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults, so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference and the `\UXXXXXXXX` Nerd-Font escape convention.

## Status

**v0.1 (this release)** — Merge Requests + Pipelines tabs, instance-spanning `mine` / `reviewing` MR modes, gitlab.com or self-hosted via `base_url`, no detail panel yet (`Enter` opens the MR / pipeline page in the browser). A right-half MR detail panel with notes / diff is queued for v0.2.

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-forge-gitlab](https://github.com/chris-mclennan/mnml-forge-gitlab). MIT-licensed and built around the same `ratatui` substrate mnml uses, so most of its UI patterns will look familiar. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
