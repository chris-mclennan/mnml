---
title: Integrations overview
description: mnml's integration model — a rail chip driven by a TOML manifest, with sidecar `<id>.override.toml` files carrying user tweaks. Two flavors — pure launchers (no code) and binary siblings — with one discovery surface (the Marketplace tab) and one on-disk shape.
---

An **integration** in mnml is a `~/.config/mnml/integrations/<id>.toml` manifest that declares a rail chip, some palette commands, and (optionally) statusline / context-menu / menu-bar surfaces. The manifest is the ground truth: mnml core no longer ships a hardcoded list of "known siblings", and installing an integration means dropping a TOML file — usually via the Marketplace tab, occasionally by hand.

This is a different model from the "37 first-party siblings" arrangement mnml shipped through mid-2026. As of 2026-08 the entire first-party ecosystem consists of exactly three GitHub repos — `chris-mclennan/mnml`, `chris-mclennan/mnml-integrations`, and `chris-mclennan/mnml-tattle-tests` — and mnml core carries exactly **three built-in chips**: `browser`, `claude_code`, `codex`. Everything else lives in installable manifests. The catalog you browse from inside mnml is federated: crates.io keyword search + one or more GitHub launcher-manifest folders, both fetched at runtime and merged.

## The two flavors

Every integration manifest declares `binary = "..."`. The value decides which flavor it is:

| Flavor | `binary` value | What it does | Example |
|---|---|---|---|
| **Pure launcher** | `binary = None` (omitted) | Templated `run` strings shell out to external CLIs. No compiled sibling. Ships as one TOML file. | `htop.toml` runs `:term htop` |
| **Binary sibling** | `binary = "mnml-xxx"` | Chip actions delegate to a compiled Rust binary that speaks the [Bridge SDK](/manual/bridge-mount/). Ships as a `cargo install`-able crate. | A community-authored `mnml-db-postgres` |

Both flavors use the same manifest schema and both land in the same on-disk location. The rail can't tell them apart at render time — mnml only distinguishes them at spawn time, when a launcher's `{{workspace}}`-style substitutions get expanded before shelling out.

Pure launchers are the recommended shape for almost everything: a launcher is a couple of dozen lines of TOML, it doesn't require the author to publish a crate, and it works with any CLI on the user's `$PATH` (`htop`, `lazygit`, `k9s`, whatever). Binary siblings are the escape hatch for things that need real UI — a database browser, an S3 file tree, a Kubernetes dashboard — where a compiled TUI produces a better result than shelling to a CLI.

## Where a manifest lives

mnml scans two directories on startup (workspace beats user on id collision):

```
<workspace>/.mnml/integrations/<id>.toml   # workspace-local
~/.config/mnml/integrations/<id>.toml      # user-global
```

To re-scan without a restart:

```vim
:integrations.refresh
```

Manifests dropped anywhere else are ignored. The `id` field inside the file is authoritative; the filename is convention only. Two files with the same `id` in the two folders — workspace wins.

## Overrides live next to the manifest

Every user customization to an installed integration — a different glyph, a new color, `enabled` flipped on, whether the chip pins to the palette bar — is persisted as a **sidecar file** in the same folder:

```
~/.config/mnml/integrations/<id>.toml            # canonical (from marketplace / install)
~/.config/mnml/integrations/<id>.override.toml   # your tweaks
```

At scan time the override is deep-merged over the base, per field, only for the fields the override actually sets. This means:

- **You can safely re-run an install** — the base manifest gets rewritten, your `override.toml` doesn't move, and your customizations survive.
- **You can revert to canonical** by deleting the override file.
- **Uninstall wipes both** — see [Installing → the right-click chip menu](/manual/integrations/installing/#the-right-click-chip-menu).

Right-click a chip → **Edit…** opens the edit overlay. Save writes an `<id>.override.toml`. If the id belongs to one of the three hardcoded built-ins (`browser` / `claude_code` / `codex`), there's no base manifest for the override to merge over — so the save promotes to a full authored `<id>.toml` instead. Both cases feel identical from the outside; internally the file mnml wrote depends on whether a base already existed.

The narrower "reorder the rail" gesture doesn't touch either file — chip order is persisted separately as `[ui] integration_icon_order = ["id1", "id2", …]` in your primary config, so the sidecar files stay purely about per-chip visuals.

## Precedence

Four layers stack. Higher layers override lower ones for the same `id`:

1. **Built-in defaults** — `browser`, `claude_code`, `codex` baked into mnml core.
2. **Base manifest** — `<workspace>/.mnml/integrations/<id>.toml` or `~/.config/mnml/integrations/<id>.toml`.
3. **Override sidecar** — `<id>.override.toml`, deep-merged per field.
4. **User order** — `[ui] integration_icon_order` in `~/.config/mnml/config.toml` sorts the effective list.

Legacy `[[ui.integration_icon]]` blocks in your config still parse (see [Installing → user-config overrides](/manual/integrations/installing/#user-config-overrides)), but new customizations write to the sidecar file instead. The right-click **Edit…** flow, the detail-pane buttons, and the Enable / Disable toggle all use the sidecar.

## Discovery: the Marketplace tab

The activity-bar Integrations panel has two tabs:

- **Installed** — every integration that currently has an `enabled = true` chip (default is `enabled = false`, so a fresh install is quiet). Rows here are the daily-driver rail.
- **Marketplace** — every integration that's declared but not enabled, plus everything mnml learned about from the configured marketplace sources. Rows here are what you'd add next.

`marketplace.refresh` (palette) fires a background fetch against every configured source. Two sources ship by default:

| Source | What it fetches | Rendered as |
|---|---|---|
| **crates.io** | Every crate published with the `mnml-integration` keyword. Anyone can publish. | `[app]` |
| **chris-mclennan/mnml-integrations** (`launchers/` folder) | Every `.toml` file directly under `launchers/`. The reference launcher catalog. | `[launcher]` |

Neither is baked in — both come from `default_sources()` in `src/marketplace.rs` and can be replaced by setting `use_defaults = false` in `[marketplace]`. See [Marketplace](/manual/integrations/marketplace/) for the full source-config schema.

Left-click any Marketplace row to install. For launchers, mnml blocking-fetches the TOML and drops it in `~/.config/mnml/integrations/<id>.toml` — no compile step, chip lands in ~200ms. For apps, mnml spawns `cargo install <name>` in a Pty pane so you can watch the build; the sibling's own `--install` step (if it has one) is a separate follow-up the user runs after cargo finishes.

## Official vs community

Every marketplace entry is tagged **Official** or **Community** at fetch time. The rule is simple: if the source's `id` matches one of the ids in `default_sources()`, the entry is Official. Everything else — a user-added source, a custom launcher-manifest repo, an internal crates-io keyword — is Community.

The gatekeeper isn't a manifest field (any author could set that) — it's who has write access to the source repo or the crates.io keyword. `chris-mclennan/mnml-integrations` and the `mnml-integration` crates keyword are the two Official sources today. Add a source under any other id and its entries are Community, even if you copy the same launcher TOMLs verbatim.

At render time the effect is currently type-only: entries carry their `Provenance` in the marketplace cache (`~/.cache/mnml/marketplace.json`), and older caches without the field deserialize as Community (safe under-count — no false-Official labels ever appear on unknown data). Visible badging and Official-first sort are a follow-up.

## Adding your own — three paths

Depending on what you're wiring up:

| Path | When to use it | Reference |
|---|---|---|
| **Marketplace install** | Someone else already published the integration. Click Install. | [Installing](/manual/integrations/installing/) |
| **`launcher.add_local`** | A private local launcher that isn't worth sharing (workspace-specific shell script, personal `htop` wrapper). Palette command opens an edit overlay. | [Launcher manifests](/manual/integrations/launcher-manifests/#add-a-local-launcher-in-app) |
| **Hand-authored manifest** | Full control — write `~/.config/mnml/integrations/<id>.toml` in your editor and run `:integrations.refresh`. | [Launcher manifests](/manual/integrations/launcher-manifests/) |

For the first two, mnml writes the TOML for you. For the third, the file is yours.

## Absorbed launcher pattern

Before the launcher template shipped (2026-08), per-workspace "run my custom Claude launcher" overrides lived in an ad-hoc `[workspace] claude_launcher` config key. That's gone — the launcher-template model absorbs it. A workspace-local `<workspace>/.mnml/integrations/claude-custom.toml` with a templated `run` command replaces the old override, and any manifest can reference `{{workspace}}` to scope its behavior to the active project. See [Launcher manifests → template variables](/manual/integrations/launcher-manifests/#template-variables) for the full substitution vocabulary.

## The manifest itself

The full schema lives in `src/integration_manifest.rs`. A minimal launcher is three lines plus one command:

```toml
id    = "htop"
label = "htop"

[[commands]]
id    = "htop.open"
title = "htop: open"
run   = ":term htop"
```

A binary sibling adds one line:

```toml
id     = "postgres"
label  = "PostgreSQL"
binary = "mnml-db-postgres"

[[commands]]
id    = "postgres.open"
title = "PostgreSQL: open"
run   = ":term mnml-db-postgres"
```

Every other field — `chip`, `context_menu`, `statusline`, `notifications`, `requires`, `settings`, detail-pane metadata — is optional and additive. See [Launcher manifests](/manual/integrations/launcher-manifests/) for the reference walkthrough.

## Next

- [Installing integrations](/manual/integrations/installing/) — Marketplace tab, precedence, on-disk paths, the sidecar override.
- [Marketplace](/manual/integrations/marketplace/) — how sources are configured, cache TTL, provenance, adding a private launcher catalog.
- [Launcher manifests](/manual/integrations/launcher-manifests/) — the full schema, template variables, worked examples.
- [Building integrations](/manual/integrations/building/) — authoring a launcher, or (rarely) a binary sibling.
- [Community integrations](/manual/integrations/community/) — how the federated model works in practice.
