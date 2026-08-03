---
title: Community integrations
description: mnml integrations don't live in a central directory — they're discovered at runtime via the Marketplace tab. This page explains where to find what's out there, how to contribute a launcher, and how the Official / Community split works.
---

mnml doesn't maintain a hardcoded catalog of "official" integrations. The first-party surface is three GitHub repos — `chris-mclennan/mnml`, `chris-mclennan/mnml-integrations`, and `chris-mclennan/mnml-tattle-tests` — and everything else installable comes from the [Marketplace](/manual/integrations/marketplace/). That's a federated discovery model with two shipping sources (crates.io keyword search + one reference GitHub folder) and unlimited user-configurable sources. Any integration in any of those sources is one click away from installed.

This page is the "where do I go to find integrations, and how do I add mine" page.

## Where to browse

The primary answer is: inside mnml, open the activity-bar Integrations panel and click **Marketplace**. If the tab is empty, run `:marketplace.refresh` and give it a few seconds — a background fetch runs against every configured source.

The shipping default sources:

- **crates.io** — every crate published with the `mnml-integration` keyword. Renders as `[app]` rows. `cargo install` on click.
- **[`chris-mclennan/mnml-integrations`](https://github.com/chris-mclennan/mnml-integrations)** — the reference launcher catalog. Every `.toml` file under `launchers/` becomes an installable row. Renders as `[launcher]` rows. Download-and-write on click.

Both of these are the closest thing mnml has to a "community integrations" list — they're the low-friction way to publish something that everyone with a default install sees. Entries from either source are tagged `Provenance::Official`; user-added sources are `Provenance::Community` (see [Marketplace → provenance](/manual/integrations/marketplace/#provenance--official-vs-community)).

## Contributing a launcher

Launchers are the recommended shape for anything that wraps an existing CLI — `htop`, `lazygit`, `k9s`, `pg_dump`, `docker compose`, `terraform`, whatever. No code to write, no crate to publish.

1. Fork [`chris-mclennan/mnml-integrations`](https://github.com/chris-mclennan/mnml-integrations).
2. Add `launchers/<your-id>.toml`. See [Launcher manifests](/manual/integrations/launcher-manifests/) for the schema.
3. Open a PR.

The bar is deliberately low — the manifest should parse as a valid `IntegrationManifest`, and the `run` command should invoke a CLI most users can install with one line. No code review beyond "does this launcher make sense" — the catalog is discoverability, not an audit.

Once merged, your launcher appears in every mnml user's Marketplace tab on their next `marketplace.refresh`, tagged Official.

## Publishing a binary sibling

If you're publishing a Rust CLI as a mnml integration, tag its `Cargo.toml` with the `mnml-integration` keyword and publish to crates.io:

```toml
[package]
name = "mnml-db-postgres"
version = "0.2.0"
keywords = ["mnml-integration", "postgres", "database"]
description = "PostgreSQL browser for mnml — connection tabs, query playground"
```

That's the whole registration step. The default `[[marketplace.source]] type = "crates_keyword"` picks up every crate with that keyword regardless of author, and the entry tags Official (the source id `crates.io` matches a default). See [Building integrations → publishing a binary sibling to the marketplace](/manual/integrations/building/#publishing-a-binary-sibling-to-the-marketplace) for the full flow.

Bundle a `--install` subcommand (via `mnml-bridge`) so users get a one-line follow-up after `cargo install <your-crate>`:

```sh
cargo install mnml-db-postgres
mnml-db-postgres --install
```

The `--install` step writes your integration manifest to `~/.config/mnml/integrations/<id>.toml`. On next `integrations.refresh` (or restart), the chip and palette commands appear.

## Running your own catalog

Any GitHub repo with launcher TOMLs directly under a folder becomes an installable source. Add it in user config:

```toml
[[marketplace.source]]
type = "github_launcher_folder"
id = "acme"
repo = "acme-corp/mnml-tools"
path = "launchers"
```

Entries fetched from a user-added source tag as `Provenance::Community` — not because they're lower quality, but because the gatekeeper (who has write access to the repo) is the user's own trust decision, not something mnml can vet.

Handy for:

- Organizations shipping internal launchers to their engineering team.
- Individuals who want a curated catalog under their own control.
- Communities around a specific stack (dev-ops launchers, embedded launchers, ML launchers) that want a focused list rather than the reference catalog's broad one.

The catalog is public if the repo is public; private-repo catalogs need `gh auth token` on the reader's machine so the fetch has 5000 req/hr against the GitHub API — see [Marketplace → GitHub rate limits](/manual/integrations/marketplace/#github-rate-limits).

## Existing integrations

The community around mnml is early. As launchers land in the reference catalog and binaries land on crates.io, they'll show up in the Marketplace tab automatically — this manual doesn't try to list them exhaustively (any such list would go stale the instant someone publishes a new crate).

To see what's currently installable: `:marketplace.refresh` from inside mnml, then browse the Marketplace tab. Sort by downloads (for crates.io apps) or by label (default) to get a sense of the landscape.

## The retired 37-sibling ecosystem

Through mid-2026 mnml maintained ~37 first-party sibling repos — one per forge / cloud / database / messaging integration, each shipping its own `cargo install`-able binary. That model was consolidated in 2026-08. The remaining first-party repos are just three:

- **`chris-mclennan/mnml`** — the editor itself + the built-in `browser` / `claude_code` / `codex` chips.
- **`chris-mclennan/mnml-integrations`** — the reference launcher catalog. Community PRs land here.
- **`chris-mclennan/mnml-tattle-tests`** — internal test fixtures. Not user-facing.

The dozens of `mnml-forge-*`, `mnml-aws-*`, `mnml-msg-*`, `mnml-tracker-*` repos are gone; the launcher-manifest model absorbed almost every one of them. The handful that needed genuine custom UI (a real database browser, say) are now expected to publish via crates.io under any author, marked with the `mnml-integration` keyword — no first-party gatekeeping.

The palette commands that pointed at those siblings (`forge.open_bitbucket`, `forge.open_dynamodb`, and ~20 more) were removed alongside the repos. Anything a user still installs from the marketplace registers its own commands via the manifest's `[[commands]]` blocks, so a chord that used to fire `forge.open_lambda` now comes from whatever `mnml-aws-lambda`'s current manifest declares.

If you're porting a workflow from the older ecosystem: install the sibling from the marketplace (if it's been re-published there), and its manifest brings its own commands + chords back with it. The migration is uneventful; the palette entries just come from a different source.

## Next

- [Marketplace](/manual/integrations/marketplace/) — federated discovery, source config, cache, provenance.
- [Installing integrations](/manual/integrations/installing/) — the Installed / Marketplace tabs, sidecar overrides, hand-editing config.
- [Launcher manifests](/manual/integrations/launcher-manifests/) — the schema every marketplace launcher follows.
- [Building integrations](/manual/integrations/building/) — authoring a launcher or (rarely) a binary sibling.
- [Integrations overview](/manual/integrations/overview/) — the model.
