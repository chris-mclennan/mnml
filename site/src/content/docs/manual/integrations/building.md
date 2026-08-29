---
title: Building integrations
description: How to build an mnml integration — usually as a pure launcher TOML (no code, ship the manifest), rarely as a binary sibling that speaks the mnml-bridge SDK. When to pick each, worked examples, and how to publish to the marketplace.
---

An integration is either a **launcher TOML** (no code, no binary — the manifest is the whole thing) or a **binary sibling** (a standalone ratatui CLI that mnml hosts as a Pty pane, optionally speaking the [`mnml-bridge`](https://crates.io/crates/mnml-bridge) SDK for richer host integration).

There's no mnml plugin runtime, no compiled extension format, no shared crate you have to link against. A launcher is a text file; a binary sibling is any Rust CLI you'd write anyway. Both flavors ship through the same [Marketplace](/manual/integrations/marketplace/) — pick whichever fits what you're building.

As of 2026-08, the first-party ecosystem consists of exactly two repos (`chris-mclennan/mnml`, `chris-mclennan/mnml-integrations`). The previous "35+ first-party siblings" model was retired — nearly every real integration turned out to be a wrapper around an existing CLI, and a launcher TOML is a lighter shape for that. The binary-sibling path still exists for genuine custom UI, but it's the escape hatch, not the default.

## Which flavor?

| If your integration... | Ship it as a |
|---|---|
| Shells to an existing CLI (`htop`, `lazygit`, `k9s`, `gh`, `pg_dump`) | Pure launcher |
| Runs a one-liner shell script | Pure launcher |
| Opens files or URLs based on workspace / cursor context | Pure launcher |
| Wraps a vendor CLI (`aws`, `gcloud`, `az`, `docker`, `kubectl`) | Pure launcher |
| Needs a custom UI (a database browser, a service dashboard, a file tree) | Binary sibling |
| Wants to talk back to mnml (post toasts, drive badges, drive statusline segments) | Binary sibling (via `mnml-bridge`) |
| Wants to render inside an mnml pane (not a Pty) | Binary sibling with the Mount tier of `mnml-bridge` |

The default answer is pure launcher. Most of the value of an integration is in the chip + the palette command + a `run` string — and all of that lives in a manifest. Reach for a binary sibling when you're building genuine UI, or when the "wrap a CLI" story doesn't cover what you need.

## Path A — pure launcher

A launcher is one TOML file. Minimum viable:

```toml
# ~/.config/mnml/integrations/htop.toml (or ship it via a launcher-manifest repo)
id    = "htop"
label = "htop"

[chip]
glyph    = "\u{F085A}"       # any Nerd Font glyph
fallback = "H"
color    = "green"
enabled  = true

[[commands]]
id    = "htop.open"
title = "htop: open"
group = "system"
keys  = ["<leader>ih"]
run   = ":term htop"
```

Drop it in `~/.config/mnml/integrations/` (or run `marketplace.refresh` after adding it to a source-configured repo) and mnml renders the chip on the next `integrations.refresh` or restart.

See [Launcher manifests](/manual/integrations/launcher-manifests/) for the full schema — chip visuals, palette commands, context-menu additions, menu-bar entries, statusline segments, notification policy, preconditions.

### Template variables

Every `run` string is passed through the launcher template engine before dispatch. Available tokens:

| Token | Meaning |
|---|---|
| `{{workspace}}` | Absolute path of the active workspace root |
| `{{workspace_name}}` | Basename of the workspace |
| `{{current_file}}` | Active file path relative to workspace |
| `{{current_file_abs}}` | Absolute path of the current file |
| `{{current_file_dir}}` | Directory of the current file |
| `{{cursor_line}}` / `{{cursor_col}}` | 1-indexed cursor position |
| `{{selection}}` | Selected text (single line only in v1) |

Unrecognized tokens stay literal — a typo like `{{workspce}}` isn't silently dropped. See [Launcher manifests → template variables](/manual/integrations/launcher-manifests/#template-variables) for the deep reference.

### Publishing a launcher to the marketplace

Two paths:

1. **Contribute to the reference catalog.** PR your launcher TOML into `chris-mclennan/mnml-integrations` under `launchers/<id>.toml`. It appears in every mnml install's Marketplace tab on the next `marketplace.refresh`, tagged `Provenance::Official`. The bar is deliberately low — no code review beyond "does this manifest parse and does the `run` command make sense."
2. **Host your own catalog.** Any GitHub repo with launcher TOMLs directly under a folder becomes an installable source. Users add it via `[[marketplace.source]]`:

    ```toml
    [[marketplace.source]]
    type = "github_launcher_folder"
    id = "acme"
    repo = "acme-corp/mnml-tools"
    path = "launchers"
    ```

    Entries fetched from a user-added source tag as `Provenance::Community`. Handy for organizations shipping internal launchers, or for authors who want a curated catalog under their own control.

See [Marketplace → contributing](/manual/integrations/marketplace/#contributing-to-the-reference-launcher-catalog) for the reference-repo flow.

## Path B — binary sibling

A binary sibling is a standalone ratatui CLI. mnml hosts it as a Pty pane; splittable, focusable, key-routed like any other pane. Two deployment modes:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Mode 1: Standalone                                                 │
│                                                                     │
│  $ mnml-db-postgres                                                 │
│  → ratatui TUI in your current terminal                             │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  Mode 2: Pty pane inside mnml                                       │
│                                                                     │
│  :term mnml-db-postgres                                             │
│  → mnml spawns the binary as a Pty pane                             │
└─────────────────────────────────────────────────────────────────────┘
```

Both modes require nothing from your code beyond being a normal ratatui TUI. Add the `mnml-bridge` SDK when you want to talk back — post toasts, drive badges, open files in mnml's editor, render into an mnml pane rather than a Pty.

### Naming convention

`mnml-<class>-<name>` — e.g.:

- `mnml-db-postgres`, `mnml-db-mysql`, `mnml-db-clickhouse`
- `mnml-tracker-jira`, `mnml-tracker-linear`, `mnml-tracker-shortcut`
- `mnml-forge-bitbucket`, `mnml-forge-github`, `mnml-forge-gitlab`
- `mnml-aws-codebuild`, `mnml-aws-cloudwatch-logs`, `mnml-aws-amplify`

The `mnml-` prefix is the only "rule" — it's how `cargo search mnml-` and the marketplace's `mnml-integration` keyword search find your crate. Class names are convention; coin a new one if nothing fits.

### Config convention

```
~/.config/mnml-<class>-<name>.toml
```

Secrets in a separate `~/.config/mnml-<class>-<name>/token` file with `chmod 600`. On first run, when the config doesn't exist, scaffold a template and exit with instructions — don't blow up.

### CLI convention

```sh
mnml-<thing>                   # launch the TUI
mnml-<thing> --check           # print resolved config + auth state, exit 0/1
mnml-<thing> --install         # write the mnml integration manifest
mnml-<thing> --uninstall       # delete the mnml integration manifest
```

`--check` is the "is my setup right?" command. `--install` and `--uninstall` come from the `mnml-bridge` SDK — see below.

### Self-installing with `mnml-bridge`

The SDK writes your integration manifest for you. Add the dep:

```toml
[dependencies]
mnml-bridge = "0.3"
```

Wire a `--install` / `--uninstall` pair into your CLI:

```rust
// src/install.rs
use anyhow::Result;
use mnml_bridge::{
    ChipSpec, CommandSpec, IntegrationSpec,
    install_integration, uninstall_integration,
};

pub fn install() -> Result<()> {
    install_integration(&IntegrationSpec {
        id: "your-thing".into(),
        name: "Your Thing".into(),
        version: Some(env!("CARGO_PKG_VERSION").into()),
        binary: Some("mnml-your-thing".into()),
        category: Some("db".into()),
        chip: Some(ChipSpec {
            glyph: "\u{F0411}".into(),
            fallback: "Y".into(),
            color: "blue".into(),
            tooltip: Some("Open your thing".into()),
            enabled: true,
            in_palette_bar: false,
            badge_key: Some("your-thing".into()),
        }),
        commands: vec![CommandSpec {
            id: "your-thing.open".into(),
            title: "Your Thing: open".into(),
            group: Some("integrations".into()),
            keys: vec!["<leader>iY".into()],
            run: ":term mnml-your-thing".into(),
        }],
        ..Default::default()
    })?;
    Ok(())
}

pub fn uninstall() -> Result<()> {
    uninstall_integration("your-thing")?;
    Ok(())
}
```

Dispatch in `main.rs` before your auth / config loads:

```rust
if cli.install { return install::install(); }
if cli.uninstall { return install::uninstall(); }
```

`install_integration` writes `~/.config/mnml/integrations/your-thing.toml`. If a user has customized the chip via mnml's Edit overlay, their `<id>.override.toml` sidecar stays put and re-merges over your fresh install — user tweaks survive an upgrade.

The `IntegrationSpec` shape mirrors the [`IntegrationManifest`](/manual/integrations/launcher-manifests/#full-schema) TOML schema field-for-field. Setting `binary: None` produces a launcher-style manifest; setting `binary: Some(...)` produces a binary-sibling manifest.

### Publishing a binary sibling to the marketplace

Publish to crates.io with the `mnml-integration` keyword in your `Cargo.toml`:

```toml
[package]
name = "mnml-db-postgres"
version = "0.2.0"
keywords = ["mnml-integration", "postgres", "database"]
description = "PostgreSQL browser for mnml — connection tabs, query playground"
```

That's it. Every mnml install with the default marketplace sources will pick up your crate on the next `marketplace.refresh`. The `description` becomes the row subtitle; downloads and last-updated get pulled from the crates.io API for sort order. Entries via the shipping `crates.io` source tag as `Provenance::Official`.

### Runtime helpers (Bridge tier 2 + 3)

`mnml-bridge` exposes fire-and-forget helpers for talking back to the host — toasts, progress notifications, activity badges, statusline segments, OS notifications. All are silent no-ops when the sibling isn't running under mnml.

```rust
mnml_bridge::toast_info("uploaded");
mnml_bridge::toast_error("build failed");

mnml_bridge::progress_start("build", "Compiling…");
mnml_bridge::progress_update("build", Some("Linking…"), Some(80));
mnml_bridge::progress_end("build", mnml_bridge::ProgressStatus::Success);

mnml_bridge::set_activity_badge("your-thing", 3);
mnml_bridge::statusline_set_segment(
    "your-thing.status", mnml_bridge::SegmentSide::Right,
    "◇ 3 failing", Some("red"), Some("your-thing.open"),
    150, 4, 20,
);
mnml_bridge::notify(
    "Your Thing", "3 tests failed",
    mnml_bridge::NotifyOpts {
        level: mnml_bridge::ToastLevel::Error,
        sound: false,
        source: Some("your-thing".into()),
    },
);
```

See [Bridge & Mount](/manual/bridge-mount/) for the tier-by-tier walkthrough, and the Mount tier (opt-in `client` feature) for siblings that want to render into an mnml pane instead of a Pty.

### Sibling icons

Ship your own SVG glyph via `mnml-bridge::install_integration` — mnml copies it to `~/.config/mnml/glyphs/<id>.svg`, assigns a codepoint in the sibling PUA range (`U+F1C00-F1CFF`), and bakes it into the mnml symbols font on `integrations.bake_sibling_glyphs`. Your manifest's own `glyph` field takes precedence if set; the SVG only kicks in when `glyph` is empty.

Uninstall via `mnml-bridge::uninstall_integration` (or the mnml right-click **Remove** menu) wipes the manifest, override sidecar, `<id>.svg`, and the assignments-file entry together — one gesture, everything gone.

## Shelling out to vendor CLIs (the AWS pattern)

If your integration wraps a vendor CLI (`aws`, `gcloud`, `az`, `gh`, `docker`, `kubectl`), consider a pure launcher first. The launcher's `run` template drops the vendor CLI into a Pty pane — the CLI's own credential chain does the auth, no SDK code, no token refresh logic.

When a launcher doesn't cover your needs — you want a custom UI on top of the CLI's output — the "no SDK; shell out" pattern is still the recommended shape for a binary sibling:

- Every backend call is a `std::process::Command::new("aws").args([...])` subprocess.
- The CLI's credential chain (env vars → shared credentials → SSO → IAM role) authenticates the call.
- All invocations use `--output json`; you `serde_json::from_slice` the stdout.

Trades subprocess latency (~300-800ms cold) for zero SDK deps, `aws sso login` support out of the box, and forward compatibility with new CLI features.

For AWS-shaped services this pattern removes hundreds of lines of auth code. For non-CLI backends (Redis, Postgres, MongoDB), reach for a native driver — subprocess overhead per query isn't acceptable at interactive latencies.

## Cross-sibling handoffs

When one sibling's data points at another's surface — a Lambda function's logs live in CloudWatch, an S3 bucket's events feed an EventBridge rule — the natural move is a single-key handoff. The mechanism is a plain `std::process::Command::new("mnml-<other-sibling>").spawn()` — no IPC, no shared state, just the binary path on `$PATH`. If it's installed it'll resolve; if not, toast that it's missing and move on.

Pass context as CLI flags: `--log-group /aws/lambda/<fn>`, `--bucket <name>`, `--pr <url>`. The receiving sibling parses its own flags and opens directly to the relevant view.

## Reference

- [Launcher manifests](/manual/integrations/launcher-manifests/) — the schema every manifest (launcher or binary) follows.
- [Marketplace](/manual/integrations/marketplace/) — how the Marketplace tab discovers your crate / launcher, and how provenance is tagged.
- [Bridge & Mount](/manual/bridge-mount/) — the four-tier protocol siblings use for host integration.
- [Installing integrations](/manual/integrations/installing/) — how users install what you ship, and how their sidecar overrides work.
- [Integrations overview](/manual/integrations/overview/) — the "two flavors + one on-disk shape" model.
