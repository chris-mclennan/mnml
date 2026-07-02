---
title: Cross-host PR workflow
description: Fly across Bitbucket / GitHub / GitLab / Azure DevOps PRs without leaving mnml. The `pr.picker` palette command fans out to every installed `mnml-forge-*` sibling and shows the merged result in one fuzzy picker. The rail's Open-PRs subsection lights up automatically when you're on a branch that has an open PR.
---

mnml runs across whichever code-hosting forges you're using day-to-day. When the [SCM viewers were split out of core](/manual/integrations/community/) into standalone `mnml-forge-*` siblings in 2026-06, two pieces of the cross-host workflow were rewired through a small JSON contract those siblings expose: the `pr.picker` fuzzy picker and the rail's "Open PRs" subsection.

This page covers the workflow. For the per-forge viewers' UX, see [Bitbucket](/manual/integrations/forge-bitbucket/) / [GitHub](/manual/integrations/forge-github/) / [GitLab](/manual/integrations/forge-gitlab/) / [Azure DevOps](/manual/integrations/forge-azdevops/).

## `pr.picker` — one fuzzy list, every host

```
> __                                    47 items
  BB  example-api      #2487  fix auth retry on 401            chris    2h
  GH  chris-mclennan/mnml  #82  CDP browser split             chris    4h
  GL  acme/api        !314   bump axios for CVE-2024-…        bob      6h
  AZ  api             #421   feat/v2 → main                   alice   12h
  BB  example-platform #2492  redshift dms backfill            …        1d
  …
```

- **Bound to** `<leader>P p` (vim mode) or open from the palette as `pr.picker`.
- Sorted by **most-recent activity** (`updated_at` desc) — what's actively being reviewed surfaces first.
- Host-tag chips (`BB` / `GH` / `GL` / `AZ`) prefix each row so you know which forge you're jumping to.

### Two-level accept

| Key | Action |
|---|---|
| `Enter` | Open the focused PR's web URL in your browser |
| `Tab` | Cross-nav — jump to the matching pipeline / build / Actions run for that PR |

The PickerItem id encodes `url\x1Fhost\x1Fowner\x1Frepo\x1Fbranch` so both `Enter` and `Tab` pull what they need from the same row. Tab dispatches to the matching `mnml-forge-*` sibling's `--find-pipeline-for-pr --json` mode (see below); on success it opens the returned URL in your browser, on miss it toasts an explanation.

### Caching

The picker runs the first time you press `<leader>P p` (or on a stale cache) — fans out to all installed forge siblings in parallel, blocks ~1–3 seconds while their HTTP calls complete, caches the result for 5 minutes. Subsequent invocations within that window open instantly.

| Command | What it does |
|---|---|
| `pr.picker` | Open the picker (using cached PRs when fresh, sync-fetching otherwise) |
| `pr.refresh` | Force a background re-fetch; toast lands when done |

Both are wired into `<leader>P p` / `<leader>P r` (vim mode), or palette-runnable as `pr.picker` / `pr.refresh`.

## Rail "Open PRs" subsection

The git rail (left rail's `── GIT ──` section) carries an **Open PRs** subsection per repo. Each row shows a PR for the active repo's remote URL — the host-tag chip, the PR number, the title. Rows are matched against `remote.origin.url` (HTTPS or SSH form, trailing `.git` tolerant), so multi-host setups Just Work.

When you're on a branch that's the source of an open PR, that row lights up — same `●` marker the active branch gets. Useful glance: "Am I working on something that's already in review?"

The rail PR data is the **same cache** the picker uses. So:

- Run `pr.picker` once to seed it
- The rail's Open-PRs subsection refreshes on every git operation (branch switch, commit, etc.)
- Stale cache (>5 min) automatically re-fetches in the background on the next git operation that needs it

Empty cache → empty rail subsection — install `mnml-forge-bitbucket` / `mnml-forge-github` / etc. and configure them once.

## How it works — the JSON contract

Each forge sibling exposes two CLI flags that mnml fans out to:

### `--list-prs --json`

```sh
mnml-forge-bitbucket --list-prs --json
mnml-forge-github    --list-prs --json
mnml-forge-gitlab    --list-prs --json
mnml-forge-azdevops  --list-prs --json
```

Each prints (single JSON object, to stdout):

```json
{
  "host": "bitbucket",
  "prs": [
    {
      "id": "2487",
      "url": "https://bitbucket.org/example-org/example-api/pull-requests/2487",
      "owner": "example-org",
      "repo": "example-api",
      "title": "fix auth retry on 401",
      "author": "chris",
      "source_branch": "fix/auth-retry",
      "dest_branch": "main",
      "state": "open",
      "updated_at": "2026-06-06T15:43:00Z",
      "remote_url_https": "https://bitbucket.org/example-org/example-api.git",
      "remote_url_ssh": "git@bitbucket.org:example-org/example-api.git"
    }
  ]
}
```

- Per-sibling errors land on stderr; mnml skips that host and surfaces the others' results
- Exit `0` on success (even with zero PRs); non-zero on auth / network failure
- Missing binaries (sibling not installed) are silently skipped

#### Per-host caveats

- **GitHub** — the Issues API doesn't return `head.ref`, so `source_branch` and `dest_branch` are `null` for GH PRs. The cross-nav Tab still works for the URL-only fallback (opens Actions for the repo, most-recent run), but the precise "this branch's pipeline" jump is unavailable on GH.
- **GitLab** — supports self-hosted instances via the sibling's `base_url` config; the JSON shape is the same.
- **Azure DevOps** — `owner` is `<org>/<project>` (not just org), since AZ scopes repos under nested project paths.
- **Bitbucket** — `mode = "mine"` / `mode = "reviewing"` tabs without an explicit `repo` are skipped in headless mode (BB Cloud's API doesn't have a workspace-wide PR list); configure per-repo tabs alongside if you need full coverage.

### `--find-pipeline-for-pr --json`

```sh
mnml-forge-bitbucket --find-pipeline-for-pr \
    --owner example-org --repo example-api --branch fix/auth-retry --json
# → { "url": "https://bitbucket.org/example-org/example-api/pipelines/results/47" }

mnml-forge-bitbucket --find-pipeline-for-pr \
    --owner example-org --repo example-api --branch no-such-branch --json
# → { "url": null }
```

Each sibling implements this against its own host's pipelines / Actions / builds API. Mnml's `pr.picker` Tab handler shells out to whichever sibling matches the focused row's `host` field.

## Keyboard story (full)

After all this, the cross-host PR workflow is one of three keychords:

```
<leader>P p   pr.picker     fuzzy pick across all forge hosts
<leader>P r   pr.refresh    background re-fetch
<leader>i b   forge.open_bitbucket   open BB viewer
<leader>i g   forge.open_github      open GH viewer
<leader>i l   forge.open_gitlab      open GL viewer
<leader>i z   forge.open_azdevops    open AZ viewer
<leader>i c   forge.open_codebuild   open AWS CodeBuild viewer
```

Inside any sibling viewer, the family-idiom keys work everywhere: `j`/`k`/`↑`/`↓` move, `1`-`9` switch tabs, `Tab` / `Shift+Tab` cycle, `Enter` / `o` open in browser, **`y` yank URL**, `r` refresh, `q` / `Esc` quit. The Bitbucket viewer adds `d` for details and `a` for approve/unapprove.

## When this came together

The cross-host workflow was added in 2026-06-06 after the SCM split-out audit found the `pr.picker` cross-host fuzzy + the rail's Open-PRs subsection were the two real losses from removing the in-tree SCM panes. Both are restored via the JSON contract above — see the [SCM hosts split](/manual/integrations/community/) memo for the full audit.

## Next

- [Building integrations](/manual/integrations/building/) — write your own forge sibling against this same JSON contract
- [Settings](/manual/settings/#keybindings) — rebind the `<leader>P p` / `<leader>i b` chords if `<leader>i` collides with something in your `[keys.global]`
- [Community integrations](/manual/integrations/community/) — the directory of installed forge siblings
