# Auto-update integrations — design (task #993)

Status: design draft — 2026-08-19. Implementation to follow when CI is
green and this doc is reviewed.

## Problem

Today the update worker (`src/app/integration_updates.rs`) polls the
crates.io API + git ls-remote every 6h and paints a `↑ Update
available` chip on the marketplace tab when an installed integration
binary has a newer version upstream. But the *installation* itself is
still a manual click — click the chip, wait for the shell to reappear,
paste `cargo install --locked --force <name>`, hit enter. Users who
maintain 10+ integrations end up either doing this ritual weekly or
just letting the chips accumulate.

## What auto-update should do

When the worker detects an update AND the user has opted in for that
integration, fire the install command in a background Pty and toast
the outcome. No modal, no confirm — the opt-in was the consent.

## Opt-in surface

Three levels, most specific wins:

1. **Per-integration override** in `~/.config/mnml/integrations/<id>.toml`:

   ```toml
   [integrations.mnml-forge-bitbucket]
   auto_update = true
   ```

   Setting on a specific integration overrides the global default.

2. **Global default** in `~/.config/mnml/config.toml`:

   ```toml
   [integrations]
   auto_update_cargo = false   # crates.io installs, default OFF
   auto_update_git   = false   # git installs — always OFF unless
                               # explicitly true, since git branches
                               # can move underneath you
   ```

3. **Shipped default**: `false` for everything. The chip stays visible;
   nothing auto-fires until the user opts in.

## Safety guardrails

- **Source-typed defaults.** The global toggle is split into
  `_cargo` and `_git` because they carry different risk profiles.
  Crates.io versions are semver-frozen and reviewed; git HEAD is
  whatever landed on `main` five minutes ago.
- **No skip-hooks / no --dangerous flags.** The install command is
  the same one the click path already runs: `cargo install --locked
  --force <name>`. Same permissions, same audit trail (crates2.json
  updates identically).
- **Rate cap.** At most one auto-install per integration per 24h.
  If a install fails, back off — don't retry until the next scheduled
  sweep.
- **Failure surfacing.** A non-zero exit from `cargo install` toasts
  the error + KEEPS the update chip visible so the user sees the
  problem. Success toasts + drops the chip on the next sweep.
- **Off by default** — no user gets auto-installed to without an
  explicit config change.
- **Per-integration disable is always honored** even when the global
  toggle is on.

## Wiring

- `Config::integrations.auto_update_cargo: bool` (default false)
- `Config::integrations.auto_update_git:   bool` (default false)
- `IntegrationManifestOverride::auto_update: Option<bool>` (already
  extensible via `[integrations.<id>]` — see #933).
- New helper `effective_auto_update(id, kind) -> bool` in
  `integration_updates.rs`, tests for the precedence chain.
- Worker: after a successful update-check sweep, iterate the results;
  for each with `is_update_available() && effective_auto_update()`,
  spawn `cargo install --locked --force <name>` in a Pty pane labelled
  `auto-update: <id>`. Track last-attempted time to enforce the 24h
  rate cap.
- Persist last-attempted timestamps in the same
  `integration-updates.json` cache the sweep already writes.

## UI

- **Settings overlay:** two toggle rows under an `── Integrations ──`
  section:
  - Auto-update from crates.io  ·  [off] / on
  - Auto-update from git         ·  [off] / on
- **Marketplace right-click menu:** per-integration item `Auto-update:
  ● / ○` — click toggles the per-integration override, persists to
  the manifest.
- **Toast on outcome:** `↑ auto-updated bitbucket 0.3.15 → 0.3.16`
  or `× auto-update failed for bitbucket: <trimmed cargo stderr>`.

## What's NOT in this design

- **Auto-uninstall** — never. A removed dep isn't the same as
  "user wants it gone".
- **Auto-downgrade** — never. `latest > current` is the only trigger.
- **Auto-restart mnml after a core update** — out of scope. Users may
  update `mnml-bridge` under their integrations; a core-mnml update is
  its own separate release channel.
- **Confirming semver-major bumps** — a stricter version-diff check
  is worth adding later, but v1 treats "current != latest" as
  "attempt install" and trusts cargo's `--locked` to prevent breaking
  changes from silently landing (lock file resolves once, doesn't
  cascade).

## Order of operations for a shipping PR

1. Land the config + override fields, no worker changes. Adds the two
   `[integrations] auto_update_*` keys + the per-manifest field. Tests
   for the resolver. Merge.
2. Land the worker branch that actually fires `cargo install`. Tests
   for the rate cap + failure-surface + skip-when-off. Merge.
3. Land the Settings row + marketplace right-click menu item. Merge.

Three small merges rather than one big one keeps blast radius small
per release, and each step is user-visible + reversible on its own.

## Open questions before implementation

- Where does the auto-install Pty pane live in the layout? Options:
  (a) tucked into a bottom dock so users can see progress without
  disrupting focus, (b) run headless (no visible pane) and only surface
  via toast. Leaning (b) — the whole point of auto-update is to be
  invisible when it works.
- Do we skip auto-update when the mnml AI-usage worker or other Rust-
  in-flight worker holds `.cargo/` locks? cargo will queue on the
  index lock naturally, but a stuck install would gum up the next
  sweep. Time out at 90s and log a warning if the install hasn't
  completed.
