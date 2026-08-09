---
title: Marketplace
description: mnml's federated integration marketplace — how the Installed / Marketplace tabs pull entries from crates.io and GitHub launcher-manifest folders, how Official vs Community provenance is tagged, and how to add your own source.
---

The Marketplace tab is mnml's shopfront for integrations. It's federated by design: mnml doesn't run a central registry, and no repo name is baked into the query path. Two sources ship as defaults, both fully overridable, and anyone can point mnml at their own launcher-manifest repo to run a private catalog.

This page covers the mechanics — sources, cache, provenance, config schema, and how installs actually land on disk. For the "what is an integration in the first place" model see [Integrations overview](/manual/integrations/overview/); for hand-authoring a launcher TOML see [Launcher manifests](/manual/integrations/launcher-manifests/).

## What the tab shows

Open the activity-bar Integrations panel, then click the **Marketplace** tab (or press `/` to filter). Two kinds of row appear:

```
 [app]        mnml-db-postgres     (crates.io)
    PostgreSQL browser for mnml — connection tabs, query playground

 [launcher]   htop                 (chris-mclennan/mnml-integrations)
    Interactive process viewer — shells to `htop`
```

- **`[app]`** rows (orange tag) — crates published with the `mnml-integration` keyword. These have a binary that gets installed via `cargo install`.
- **`[launcher]`** rows (cyan tag) — TOML manifests under a configured GitHub folder. These have no binary; the manifest itself is the whole integration.

Left-click any row to install. See [Install actions](#install-actions) below for what each kind does.

The tab also shows any `enabled = false` integrations you already have on disk — those render above the marketplace rows so "already-installed but not on the rail" doesn't get lost.

## Default sources

Out of the box, mnml queries two sources (defined in `src/marketplace.rs::default_sources`):

| Source id | Type | What it queries |
|---|---|---|
| `crates.io` | `crates_keyword` | `https://crates.io/api/v1/crates?keyword=mnml-integration&per_page=100` |
| `chris-mclennan/mnml-integrations` | `github_launcher_folder` | `https://api.github.com/repos/chris-mclennan/mnml-integrations/contents/launchers` |

Both are fully configurable. Turning off `use_defaults` replaces them entirely; leaving it on merges any additional `[[marketplace.source]]` entries you configure alongside them.

## Provenance — Official vs Community

Every entry in the tab carries a `Provenance` field, tagged at fetch time by matching the entry's `source_id` against the shipped defaults:

- **Official** — entry comes from a source whose id appears in `default_sources()`. Today that's `crates.io` (any crate with the `mnml-integration` keyword) and `chris-mclennan/mnml-integrations`.
- **Community** — everything else. A user-added source with a custom id, an internal crates-io keyword, a third-party launcher-folder repo.

The gatekeeper isn't a manifest field — any author could set one — it's who has write access to the source repo or crates-io keyword. That's exactly what the default-sources list catalogs.

The tag survives cache round-trips (`~/.cache/mnml/marketplace.json`). Old cache entries from before provenance shipped deserialize as **Community**, and any future variant this build doesn't recognize also lands there — the fallback is deliberately the safer under-count (no false-Official labels on unknown data).

Visible badging and Official-first sorting in the Marketplace tab are the next follow-up; today the tag is populated and cached, and the API is stable for consumers reading the JSON directly. To confirm what's Official on the current source list:

```sh
cat ~/.cache/mnml/marketplace.json | jq '.entries[] | select(.provenance == "official") | .id'
```

## Config schema

Everything below is optional — an empty `[marketplace]` block is the same as no block at all.

```toml
[marketplace]
enabled = true             # master switch. false → tab is empty, no fetches happen.
cache_ttl_secs = 3600      # cache lifetime in seconds. Default 3600 (1h).
use_defaults = true        # merge shipping defaults with user sources.
                           # false = user sources are the entire list.

# Additional sources — appended when use_defaults = true,
# or the entire source list when use_defaults = false.
[[marketplace.source]]
type = "crates_keyword"
id = "my-org-crates"
keyword = "my-org-integration"

[[marketplace.source]]
type = "github_launcher_folder"
id = "my-org-launchers"
repo = "my-org/mnml-tools"
path = "launchers"
```

Two source types are supported today:

### `crates_keyword`

Queries `https://crates.io/api/v1/crates?keyword=<keyword>&per_page=100`. Every result that comes back becomes an `[app]` row. mnml renders the crate `name` as the label, `description` as the subtitle, and the returned `downloads` / `updated_at` as sort metadata.

There's nothing special about the shipping `mnml-integration` keyword — any keyword works. If your organization publishes crates under a shared tag, add a source for it and those crates show up alongside the shipping defaults. Their `Provenance` will be Community (your source id isn't in `default_sources()`) — that's the correct labeling; only crates.io's `mnml-integration` keyword is gatekept as Official.

### `github_launcher_folder`

Fetches `https://api.github.com/repos/<repo>/contents/<path>`, filters to files ending in `.toml`, and downloads each one via `download_url`. Each successful download is parsed as an [`IntegrationManifest`](/manual/integrations/launcher-manifests/) and rendered as a `[launcher]` row.

Files that fail to parse are skipped with a stderr message — one bad manifest in a folder doesn't fail the whole source. If you host launcher manifests in a private repo, [gh auth token acceleration](#github-rate-limits) picks up the credential automatically.

### Adding a private catalog

Point mnml at any GitHub repo + folder path and it appears alongside the reference launchers:

```toml
[[marketplace.source]]
type = "github_launcher_folder"
id = "acme"
repo = "acme-corp/mnml-tools"
path = "launchers"
```

Then run `marketplace.refresh`. Every `.toml` file under `launchers/` in `acme-corp/mnml-tools` now renders as an installable row, tagged `(acme)` and with `Provenance::Community`.

The `id` field is just a display tag — it can be anything, it doesn't need to match the repo name. Keep it short (renders in the tab as `(acme)` next to each row) so users can tell your entries apart from the reference catalog. Note that even if you point a user-added source at the exact same repo as the reference catalog under a different id, its entries will still tag as Community — the provenance check is purely on the source id, not the underlying URL.

## Cache

Marketplace fetches are cached at `~/.cache/mnml/marketplace.json`. The cache file carries:

- Every entry from every source's last successful fetch (including the per-entry `Provenance`).
- The Unix timestamp of the last write (`fetched_at`).
- The TTL that was in effect when the cache was written (`ttl_secs`).

On launch mnml loads the cache into `marketplace_entries` — so the tab renders instantly, even before the first fetch completes. On `marketplace.refresh` a fresh fetch runs on background threads (one per source) and results merge in as each source completes. Sources that fail are logged to stderr; the cache falls back to the previous entries for that source.

Cache TTL is advisory. mnml doesn't auto-refresh when the TTL expires — you drive it explicitly via `marketplace.refresh`. The TTL is metadata for future stale-while-revalidate behavior and for tools that inspect the file offline.

To force a full re-fetch, run `marketplace.refresh` after deleting the cache:

```sh
rm ~/.cache/mnml/marketplace.json
```

Missing / malformed cache files are silent no-ops — mnml renders empty and waits for the next refresh.

## Install actions

Left-click on a Marketplace row dispatches based on the entry `kind`:

### `[app]` rows — `cargo install`

mnml spawns a Pty pane running:

```sh
cargo install --force <crate-name> && $HOME/.cargo/bin/<crate-name> --install
```

You watch the build live. When `cargo` exits cleanly, the binary lands in `~/.cargo/bin` (which mnml's PATH detection covers even under Finder-launched .app bundles) and the sibling's own `--install` subcommand runs immediately after, writing `~/.config/mnml/integrations/<id>.toml`.

Two footguns this shape closes:

- **`--force`** — without it, `cargo install` skips silently when the crate is already installed at any version. That made "click Install to upgrade" a no-op. `--force` reinstalls unconditionally so a fresh build always lands.
- **`$HOME/.cargo/bin/<name>` explicit path** — without the full path, the `--install` shell resolve runs whichever `<name>` PATH finds first. A stale copy in `~/.local/bin/` or another PATH entry could win and write its old manifest, leaving you with a fresh binary in `~/.cargo/bin/` but an outdated manifest on disk. Targeting the cargo-bin path directly bypasses PATH order.

If a sibling doesn't ship an `--install` subcommand, the second shell fails (or the `&&` chain short-circuits) — fall back to hand-authoring the manifest per [Launcher manifests](/manual/integrations/launcher-manifests/).

For existing stale copies elsewhere on PATH — installed before `--force` shipped, or copied around by hand — see [Installing → Diagnostics](/manual/integrations/installing/#diagnostics) for the `integrations.audit_shadowed_binaries` command that quarantines them.

### `[launcher]` rows — download TOML

mnml does one blocking HTTP GET against the launcher's `download_url` (from the GitHub Contents API), parses the response as an `IntegrationManifest`, verifies the `id` matches the row you clicked, and writes the whole file to:

```
~/.config/mnml/integrations/<id>.toml
```

Blocking is fine here — launcher TOMLs are kilobytes and the request completes in ~200ms. On success mnml toasts `installed <id> → <path>` and immediately re-scans the integrations folder so the chip appears on the Installed tab without a restart.

Rejection cases:

- **Malformed TOML** — mnml refuses to write. Toast: `install failed: parse toml: <error>`.
- **`id` mismatch** — the row's `id` and the fetched manifest's `id` field disagree. Toast: `install failed: manifest id "foo" doesn't match expected "bar"`. Safety net against a GitHub folder being renamed mid-fetch.
- **HTTP error** — GitHub returned non-2xx. Toast: `install failed: fetch: <error>`.

## GitHub rate limits

Unauthenticated GitHub API calls are capped at 60 requests/hour per IP. That's tight when a source has many launcher files (one API call for the folder listing + one download per file). mnml's fetcher auto-detects a `gh` CLI token to lift the ceiling to 5000/hour:

```sh
gh auth login       # one-time
```

If `gh auth token` returns a token, every GitHub request adds `Authorization: Bearer <token>`. Neither path fails — the cache absorbs the rate-limit difference. If you don't have `gh` and you're hitting the 60/hr ceiling, install `gh` and log in once; refresh will pick up the token automatically.

## Palette commands

| Command | What it does |
|---|---|
| `marketplace.refresh` | Fire a fresh fetch against every configured source. Non-blocking — results merge in as each source completes. |
| `integrations.refresh` | Re-scan the two `integrations/` folders. Run this after a launcher install to see the new chip. |
| `integrations.refresh_binary_cache` | Drop cached `is_binary_installed` lookups so a freshly-cargo-installed sibling resolves without restart. |
| `launcher.add_local` | Skip the marketplace and hand-author a local launcher via the edit overlay. See [Launcher manifests](/manual/integrations/launcher-manifests/#add-a-local-launcher-in-app). |

## Contributing to the reference launcher catalog

The `chris-mclennan/mnml-integrations` repo is a plain Git repo with launcher manifests under `launchers/`. To add a launcher:

1. Fork the repo.
2. Add `launchers/<your-id>.toml` following the [Launcher manifests](/manual/integrations/launcher-manifests/) schema.
3. Open a PR.

The bar is deliberately low — the launcher should parse as a valid `IntegrationManifest`, have a working `run` command against a CLI most users have installed, and not be a wrapper for something malicious. There's no code review beyond "does this manifest make sense" — the catalog is discoverability, not an audit.

Merged manifests appear in every mnml install's Marketplace tab on the next `marketplace.refresh`, and (because they came in via the default source) they carry `Provenance::Official`.

## Next

- [Installing integrations](/manual/integrations/installing/) — Marketplace clicks, `--install` for binary siblings, sidecar overrides.
- [Launcher manifests](/manual/integrations/launcher-manifests/) — the schema every marketplace launcher speaks.
- [Integrations overview](/manual/integrations/overview/) — the "two flavors + one on-disk shape" model.
- [Building integrations](/manual/integrations/building/) — publishing your own launcher or binary sibling.
- [Community integrations](/manual/integrations/community/) — where to find and share what others have published.
