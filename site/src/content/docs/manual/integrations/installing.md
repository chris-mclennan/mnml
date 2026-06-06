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
| Left rail **`> INTEGRATIONS` section** (plain glyphs) | `[[ui.integration_icon]]` | The integration menu — defaults to **every first-party sibling**; uninstalled siblings are filtered out of the collapsed strip until you install them. |

Both arrays share the same shape (`id` / `glyph` / `fallback` / `command` / `color` / `tooltip`); they just paint in different places. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference.

The mental model:

- The **bufferline strip** is your dock — small, opinionated, only contains things you've explicitly put there.
- The **INTEGRATIONS rail** is your start menu — narrow strip of installed siblings on the left, with a `+` chip that opens a discovery overlay listing everything else mnml knows about.

:::note
Setting either array in your config *replaces* the built-in defaults — it doesn't append. If you want a custom rail integration alongside the defaults, copy the shipped list from `src/config.rs` into your `~/.config/mnml/config.toml` first, then add your entry.
:::

## How mnml detects installation

When the rail's INTEGRATIONS section is collapsed (a horizontal strip of icons), mnml filters it to only show siblings whose binary actually resolves. Missing siblings disappear entirely from the strip — they don't appear dim. The `+` chip stays put so you can re-add them.

The probe is in-process (no `which` fork) and walks two location classes in order — `$PATH` first, then a per-OS list of well-known install dirs. Results are cached per session and cleared on a successful install or via the `integrations.refresh` palette command.

| OS | Locations checked (in order) |
|---|---|
| macOS | `$PATH` → `~/.cargo/bin` → `/opt/homebrew/bin` (Apple Silicon) → `/usr/local/bin` (Intel) |
| Linux | `$PATH` → `~/.cargo/bin` → `/home/linuxbrew/.linuxbrew/bin` → `/usr/local/bin` |
| Windows | `%PATH%` → `%USERPROFILE%\.cargo\bin` → `%LOCALAPPDATA%\Programs\` |

Why the fallback matters: **macOS .app bundles don't inherit your shell's `PATH`**. If you launch mnml.app from Finder/Spotlight, its environment is the minimal system `PATH` the launcher gives it — your `~/.zshrc` never runs. Without the fallback, you'd `cargo install mnml-forge-bitbucket`, see it appear in any shell, then double-click mnml.app and watch the Bitbucket chip vanish despite the binary sitting one directory over. Checking the standard `cargo install` location (`~/.cargo/bin`) and the standard Homebrew prefix directly sidesteps the entire PATH-inheritance question.

Internal palette commands (no prefix — e.g. `ai.claude_code`, `http.send`) and tmnl host commands (`tmnl:<host_id>`) are always assumed available because they don't shell out. They never get filtered out.

## Adding a sibling

There are two ways to install a sibling and wire its chip into the rail. Pick the one that matches how you work.

### The `+` button on the rail

Click the `+` chip at the right edge of the `> INTEGRATIONS` header (or run `:integrations.add` from the palette) and an overlay drops in listing every first-party sibling mnml knows about, grouped by category, each tagged with its install status:

```
┌─ + Add integration ──────────────────────────────────────────┐
│  ── AWS ────────────────────────────────────────────────────  │
│ ▸ ✓  mnml-aws-codebuild           installed (in rail)        │
│   ✗  mnml-aws-cloudwatch-logs     not installed              │
│   ✓  mnml-aws-lambda              installed                  │
│   ✗  mnml-aws-eventbridge         not installed              │
│  ── Databases ──────────────────────────────────────────────  │
│   ✗  mnml-db-dynamodb             not installed              │
│  ── Forges (SCM) ───────────────────────────────────────────  │
│   ✓  mnml-forge-bitbucket         installed                  │
│   …                                                          │
│ ↑↓ move · Enter add to rail · i install (cargo) · y yank …   │
└──────────────────────────────────────────────────────────────┘
```

A row's status is one of three:

| Glyph | State | What `Enter` does |
|---|---|---|
| `✓` green | `installed (in rail)` — binary detected AND already in `[[ui.integration_icon]]` | Toasts "already in rail" |
| `✓` cyan | `installed` — binary detected, not yet a chip | Adds the chip + persists to TOML |
| `✗` red | `not installed` — binary not on `$PATH` or in any well-known dir | Toasts a hint to press `i` or `y` |

Keys:

| Chord | Action |
|---|---|
| `↑↓` / `j k` | Move selection (wraps; section headers are skipped) |
| `Enter` | Status-dependent (see table above) |
| `i` | Install — spawn a Pty pane running `cargo install --git <url> --tag <pinned> <binary>` |
| `y` | Yank the same `cargo install …` command to the OS clipboard |
| `Esc` / `q` | Close the overlay |
| mouse wheel | Same as `↑↓` |

#### `Enter` — add to rail (and persist)

On an `installed` (cyan) row, `Enter` appends an `[[ui.integration_icon]]` entry to the in-memory config and immediately rewrites `~/.config/mnml/config.toml` so the chip survives a restart. The success toast reports the exact path written:

```
added mnml-aws-lambda to rail · persisted to /Users/you/.config/mnml/config.toml
```

The rewrite is line-based and surgical. mnml strips any existing `[[ui.integration_icon]]` blocks (and the managed-section banner, if previously written) and appends a fresh banner + the full current icon list. Everything outside those blocks — other tables, your comments, blank-line spacing — is preserved verbatim. The rewrite is idempotent: a strip-and-append twice produces the same file as once.

The banner mnml writes looks like this; you can recognise it on next inspection:

```toml
# ── mnml-managed integration icons ──────────────────────────────────
# Written by the `+ Add integration` overlay. Edit by hand or via the
# overlay — re-saves replace this section in place.

[[ui.integration_icon]]
id = "lambda"
glyph = ""
fallback = "L"
command = ":host.launch mnml-aws-lambda"
color = "orange"
tooltip = "AWS Lambda"
```

You can still hand-edit the file. The strip pass only matches the `[[ui.integration_icon]]` header line and the banner comment; a custom integration_icon block you wrote yourself will be picked up by the in-memory config on next launch — and the next overlay-driven add will rewrite it back out alongside the new entry.

If the filesystem write fails (no `$HOME`, no write permission, locked file), `Enter` still succeeds in-memory and the toast tells you the chip is runtime-only:

```
added mnml-aws-lambda to rail (runtime only — persist failed: write /...: Permission denied)
```

#### `i` — install in a Pty pane

On a `not installed` (red) row, `i` closes the overlay, opens a fresh Pty pane in the current layout, and runs the resolved `cargo install --git <repo> --tag <pinned> <binary>` for that catalog entry. You watch the build live; once `cargo` exits cleanly the binary lands in `~/.cargo/bin` (which the detector already probes), so the next time you open the overlay the row flips from red `✗ not installed` to cyan `✓ installed`. Press `Enter` then to add the chip + persist.

The overlay closes during install because you want the Pty's output, not the picker. Re-open the overlay (`+` chip, or `:integrations.add`) when the build finishes.

If the Pty pane immediately exits with `cargo: command not found`, you don't have Rust on your `$PATH` from inside mnml — either install Rust via [rustup.rs](https://rustup.rs) and relaunch mnml from a fresh shell, or use `y` and run the install from a terminal that does have `cargo`.

`y` is the same command, copied to the clipboard for use outside mnml — handy if you'd rather review it before running, or pin a different tag than the catalog default.

## Auto-discovery

The `+` overlay isn't limited to the first-party catalog. Any binary named `mnml-<class>-<name>` that lives on `PATH` (or in one of the well-known install dirs from the [detection table](#how-mnml-detects-installation)) is surfaced automatically — community siblings, forks, and your own `mnml-*-*` scratch tools all appear without a PR to mnml or a config edit.

The sweep runs once per overlay-open session and is cached for that session. Opening the `+` overlay calls `integration_detect::clear_all_caches()` first, so a sibling you `cargo install`-ed in another shell shows up the moment you re-open the overlay — no `:integrations.refresh` needed. The reserved names `mnml` (the editor itself) and `mnml-info` are filtered out.

Discovered rows render in the same category sections as catalog rows, with a `· auto-discovered` chip appended to the status text so you can tell where the entry came from:

```
── Trackers ──────────────────────────────────────────────
  ✓  mnml-tracker-jira            installed (in rail)
  ✓  mnml-tracker-linear          installed · auto-discovered
```

Category and chip color are derived from the class prefix. New sibling authors targeting one of these classes get a sensible default icon for free; anything outside the table falls through to `Other`:

| `class` prefix | Category | Default chip color |
|---|---|---|
| `aws` | AWS | yellow |
| `db` | Databases | teal |
| `forge` | Forges (SCM) | blue |
| `tracker` | Trackers | purple |
| `fs` | Filesystems | orange |
| `test` | Test runners | green |
| anything else | Other | cyan |

The glyph is always a generic nerd-font cog (`nf-fa-cog`, ``). The fallback is the first two characters of `<name>`, uppercased. If you want a richer per-tool glyph or a distinct color, that's exactly what the hardcoded catalog gives you — open a PR adding your sibling to `src/family_catalog.rs`.

Catalog rows and auto-discovered rows differ on two of the overlay keys, because auto-discovered entries are installed by definition and mnml doesn't know their source repo:

| Key | Catalog row | Auto-discovered row |
|---|---|---|
| `Enter` | Adds chip + persists to `config.toml` | Same — adds chip + persists |
| `i` | Spawns a Pty running `cargo install …` | No-op (toasts "already installed — nothing to install") |
| `y` | Copies the `cargo install …` command | No-op (toasts "install source unknown, no command to yank") |

:::tip[For sibling authors]
Ship a binary named `mnml-<class>-<name>` and put it on `PATH` (or in `~/.cargo/bin`, which `cargo install` writes to). It appears in every mnml user's `+` overlay the next time they open it — no registry, no manifest, no PR. A catalog entry in mnml itself is still worth it for users who want one-keystroke install via `i`/`y` and a richer per-tool icon, but discoverability is free.
:::

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

1. **Stop displaying its chip** — remove or comment out its `[[ui.integration_icon]]` entry in `~/.config/mnml/config.toml`. The next `Enter`-driven add via the `+` overlay will rewrite the section without it. If you'd rather edit by hand, the block is plain TOML inside the `# ── mnml-managed integration icons ──` banner.

2. **Uninstall the binary** — `cargo uninstall mnml-<class>-<name>`. The chip disappears from the collapsed rail on the next render (detection is in-process, cached per session — run `:integrations.refresh` if you want to clear it sooner). The `[[ui.integration_icon]]` entry stays in your config; if you reinstall the binary, the chip comes back.

## Troubleshooting

### "I installed via `cargo install` but mnml.app from Finder doesn't see the chip"

This is the macOS `PATH`-inheritance problem. Your shell sees `~/.cargo/bin/mnml-tracker-jira` because your `.zshrc` adds `~/.cargo/bin` to `PATH`; the .app bundle launched from Finder doesn't run your `.zshrc`, so it doesn't see that addition.

mnml's well-known-locations fallback covers `~/.cargo/bin` directly, so the chip *should* resolve. If it doesn't, the binary likely landed somewhere unusual — check `cargo install --list` to see where it went. The fallback list (see table above) doesn't probe arbitrary directories; if your install prefix is non-standard, either:

- Add the target dir to the launcher's curated PATH by editing `/Applications/mnml.app/Contents/MacOS/launcher.sh`, or
- Move the binary into `~/.cargo/bin` (a symlink works), or
- Launch mnml from a shell (`mnml` from your terminal) instead of from Finder/Spotlight.

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

### "I installed the sibling but the chip's not showing"

Three things to check, in order:

1. Run `:integrations.refresh` to clear the per-session detection cache. The collapsed-rail strip filters to detected binaries only — a stale cache from before your install is the most common cause.
2. Run `which mnml-<class>-<name>` in the same shell you launched mnml from. If that resolves but the chip's still missing, you're hitting the macOS .app `PATH` case — launch mnml from your shell to confirm, then fix the launcher's PATH (see the first troubleshooting entry).
3. If `which` doesn't resolve and `cargo install --list` shows it lives somewhere outside `~/.cargo/bin`, see the previous entry — the well-known fallback list is fixed.

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
