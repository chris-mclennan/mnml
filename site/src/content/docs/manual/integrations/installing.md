---
title: Installing integrations
description: How mnml detects which `mnml-*` siblings are installed, how the rail's INTEGRATIONS section relates to the bufferline launcher strip, and how to add or remove integrations on your machine.
---

mnml ships with chips for every first-party sibling (Bitbucket, GitHub, Jira, AWS CodeBuild, Lambda, CloudWatch Logs, S3, DynamoDB, …) the moment you install it — *before* you've installed any of the siblings themselves. The chip strip is the **menu**; whether each one resolves to a real binary on your machine is a separate question that mnml answers at render time.

This page is the "I see Jira in the sidebar — did I set it up?" page. It covers the two icon surfaces, how detection works, and how to add or remove a sibling without editing TOML by hand.

## Two surfaces, two truths

mnml has two places integration icons appear, and they are driven by two different config arrays:

| Surface | Config | What it means |
|---|---|---|
| Top-right **bufferline launcher chip strip** (colored chips) | `[[ui.launcher_icon]]` | Quick-launch chips you've explicitly pinned. Defaults to **empty**. |
| Left rail **`> INTEGRATIONS` section** (plain glyphs) | `[[ui.integration_icon]]` | The integration menu — defaults to **every first-party sibling**, even uninstalled ones. |

Both arrays share the same shape (`id` / `glyph` / `fallback` / `command` / `color` / `tooltip`); they just paint in different places. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference.

The mental model:

- The **bufferline strip** is your dock — small, opinionated, only contains things you've explicitly put there.
- The **INTEGRATIONS rail** is your start menu — wide, lists everything, fades out the things you haven't installed yet.

:::note
Setting either array in your config *replaces* the built-in defaults — it doesn't append. If you want a custom rail integration alongside the defaults, copy the shipped list from `src/config.rs` into your `~/.config/mnml/config.toml` first, then add your entry.
:::

## How mnml detects installation

The INTEGRATIONS section paints a dim red `(<bin> not installed)` suffix next to any row whose `command` is `:host.launch <binary>` when the binary isn't found. That probe runs at render time when the Integrations activity-bar section is the active one. It's how the rail stays honest — the chip for `mnml-tracker-jira` is always *present*, but it tells you the truth about whether you've installed the binary.

The probe today is a literal `which <binary>` call against your shell's `PATH`. That's the v1 surface; the well-known-locations fallback in the table below is the **intended v0.x detection logic**:

| OS | Locations checked (in order) |
|---|---|
| macOS | `$PATH` → `~/.cargo/bin` → `/opt/homebrew/bin` (Apple Silicon) → `/usr/local/bin` (Intel) |
| Linux | `$PATH` → `~/.cargo/bin` → `/home/linuxbrew/.linuxbrew/bin` → `/usr/local/bin` |
| Windows | `%PATH%` → `%USERPROFILE%\.cargo\bin` → `%LOCALAPPDATA%\Programs\` |

Why the fallback matters: **macOS .app bundles don't inherit your shell's `PATH`**. If you launch mnml.app from Finder/Spotlight, its environment is the minimal system `PATH` the launcher gives it — your `~/.zshrc` never runs. Without the fallback, you'd `cargo install mnml-forge-bitbucket`, see it appear in any shell, then double-click mnml.app and watch the Bitbucket chip wear `(mnml-forge-bitbucket not installed)` despite the binary sitting one directory over. Checking the standard `cargo install` location (`~/.cargo/bin`) and the standard Homebrew prefix directly sidesteps the entire PATH-inheritance question.

Internal palette commands (no prefix — e.g. `ai.claude_code`, `http.send`) and tmnl host commands (`tmnl:<host_id>`) are always assumed available because they don't shell out. They never wear the missing-binary badge.

## Adding a sibling

There are two ways to install a sibling and wire its chip into the rail. Pick the one that matches how you work.

### The `+` button on the rail *(coming soon)*

:::caution
The `+` overlay below describes the intended flow — mnml v0.x ships with the chip strip + detection, and the install overlay follows shortly. Until then, use the manual `cargo install` flow further down.
:::

Click the `+` chip at the bottom of the INTEGRATIONS section and an overlay lists every first-party sibling mnml knows about, each with its install status:

```
┌─ Install integrations ───────────────────────────────────────┐
│ ✓  mnml-forge-bitbucket       Bitbucket pipelines + PRs      │
│ ✗  mnml-forge-github          GitHub Actions + PRs           │
│ ✗  mnml-tracker-jira          Jira tracker                   │
│ ✓  mnml-aws-codebuild         AWS CodeBuild + logs           │
│ ✗  mnml-aws-cloudwatch-logs   CloudWatch Logs live tail      │
│ …                                                             │
└──────────────────────────────────────────────────────────────┘
  ↑↓/jk move  ·  y yank install cmd  ·  i install  ·  Enter add to rail  ·  q close
```

Keys:

| Chord | Action |
|---|---|
| `↑↓` / `j k` | Move selection |
| `y` | Yank the focused sibling's `cargo install --git …` command to the OS clipboard |
| `i` | Install it now — mnml spawns a Pty pane running the `cargo install` command and watches for completion |
| `Enter` | On an installed sibling: ensure its `[[ui.integration_icon]]` entry is present in your config (no-op if already there) |
| `q` / `Esc` | Close the overlay |

`i` is the bulk fast path: you don't have to leave mnml, copy a command, switch terminals, run it, and come back. The Pty pane spawned by `i` is a regular pane — when `cargo install` exits, the pane stays open with the output for you to scroll, and the next render of the rail picks up the now-installed binary (the missing-binary badge drops off).

### Manual install commands

If you'd rather skip the overlay (or you're on an older mnml), every sibling installs with the same shape:

```sh
cargo install --git https://github.com/chris-mclennan/mnml-forge-bitbucket
cargo install --git https://github.com/chris-mclennan/mnml-forge-github
cargo install --git https://github.com/chris-mclennan/mnml-forge-gitlab
cargo install --git https://github.com/chris-mclennan/mnml-forge-azdevops
cargo install --git https://github.com/chris-mclennan/mnml-tracker-jira
cargo install --git https://github.com/chris-mclennan/mnml-aws-codebuild
cargo install --git https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs
cargo install --git https://github.com/chris-mclennan/mnml-aws-amplify
cargo install --git https://github.com/chris-mclennan/mnml-aws-lambda
cargo install --git https://github.com/chris-mclennan/mnml-aws-eventbridge
cargo install --git https://github.com/chris-mclennan/mnml-fs-s3
cargo install --git https://github.com/chris-mclennan/mnml-db-dynamodb
cargo install --git https://github.com/chris-mclennan/mnml-test-playwright
cargo install --git https://github.com/chris-mclennan/mnml-test-cypress
```

Pin a specific tag when reproducibility matters:

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-lambda --tag v0.1.0
```

The default `[[ui.integration_icon]]` set already references every first-party sibling — so once the binary is on your `PATH` (or in `~/.cargo/bin`, which `cargo install` writes to by default), the chip just works. No additional config required.

## Removing a sibling

Two things can happen depending on what you want:

1. **Stop displaying its chip** — remove or comment out its `[[ui.integration_icon]]` entry in `~/.config/mnml/config.toml`. Because the array replaces (rather than merges with) the defaults, you'll need to have copied the full default list into your config first; from there, just delete the entry you don't want.

2. **Uninstall the binary** — `cargo uninstall mnml-<class>-<name>`. The chip will still render (the entry is still in your config), but it'll wear the `(<bin> not installed)` badge until you reinstall or remove the entry.

## Troubleshooting

### "I installed via `cargo install` but mnml.app from Finder doesn't see the chip"

This is the macOS `PATH`-inheritance problem. Your shell sees `~/.cargo/bin/mnml-tracker-jira` because your `.zshrc` adds `~/.cargo/bin` to `PATH`; the .app bundle launched from Finder doesn't run your `.zshrc`, so it doesn't see that addition.

mnml's well-known-locations fallback covers `~/.cargo/bin` directly — but if you're on a version of mnml that's only doing the `PATH` probe today, the workaround is either:

- Launch mnml from a shell (`mnml` from your terminal) instead of from Finder/Spotlight, or
- Add `~/.cargo/bin` to the launcher's curated PATH by editing `/Applications/mnml.app/Contents/MacOS/launcher.sh`.

### "I want `which mnml-aws-X` to work in my shell too"

`cargo install` writes binaries to `~/.cargo/bin`. If your shell doesn't have that on `PATH`, add this line to your shell init:

```sh
# zsh — ~/.zshrc
export PATH="$HOME/.cargo/bin:$PATH"
```

```sh
# bash — ~/.bashrc or ~/.bash_profile
export PATH="$HOME/.cargo/bin:$PATH"
```

```fish
# fish — ~/.config/fish/config.fish
fish_add_path $HOME/.cargo/bin
```

```powershell
# PowerShell — $PROFILE
$env:PATH = "$HOME\.cargo\bin;$env:PATH"
```

After a shell restart, `which mnml-aws-codebuild` resolves and any tooling that walks `PATH` (other editors, `make` targets, scripts) finds it.

### "Windows can't find `cargo`"

Install Rust via [rustup.rs](https://rustup.rs). The installer adds `%USERPROFILE%\.cargo\bin` to your `PATH` automatically — open a new PowerShell after installing and `cargo --version` should resolve.

### "I installed the sibling but the chip's still red"

Three things to check, in order:

1. Run `which mnml-<class>-<name>` in the same shell you launched mnml from. If that resolves, mnml's probe should too — try `Ctrl+B` twice to rerender the rail.
2. If `which` doesn't resolve, the binary isn't on your shell `PATH`. See "I want `which …` to work in my shell" above.
3. If `which` resolves *and* the chip still says missing, you're hitting the macOS .app `PATH` case. Launch mnml from your shell to confirm, then fix the launcher's PATH (see the first troubleshooting entry).

The `--check` flag on each sibling is the orthogonal verification — `mnml-tracker-jira --check` prints the resolved config + whether auth works. That's separate from "can mnml see the binary?"; it's "can the binary see *its* backend?".

## For sibling authors

Any binary named `mnml-*-*` placed in any of the well-known locations is detected by mnml's rail probe — there's no manifest, no registration, no manifest. As long as your binary:

1. Is named `mnml-<class>-<name>` (the prefix is the only naming rule).
2. Lives on `PATH` or in `~/.cargo/bin` (which `cargo install` writes to by default).
3. Either runs standalone or speaks the blit-host protocol when invoked with `--blit <socket>`.

…it'll resolve. Users can wire its chip with the same `[[ui.integration_icon]]` block any other sibling uses.

The full anatomy of an integration — directory layout, the `tmnl-protocol` dependency, the `blit.rs` file you copy, the `--check` convention — lives in [Building integrations](/manual/integrations/building/).

## Next

- [Building integrations](/manual/integrations/building/) — anatomy of a sibling: standalone, pty, or hosted blit pane.
- [Activity bar](/manual/activity-bar/) — the **Integrations** section is one of five activity-bar sections; click the puzzle-piece icon to switch to it.
- [Settings & configuration](/manual/settings/) — full reference for `[[ui.integration_icon]]` and `[[ui.launcher_icon]]`.
- [Community integrations](/manual/integrations/community/) — directory of community-built siblings.
- [Bitbucket forge viewer](/manual/integrations/forge-bitbucket/) — a concrete example: the install, config, and chip wiring end-to-end.
