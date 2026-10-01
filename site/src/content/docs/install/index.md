---
title: Install
description: Install mnml from a prebuilt binary or a package manager on macOS, Linux or Windows.
---

mnml is one binary per platform with no runtime to install. Every
release is built for:

| Platform | Architectures |
| -------- | ------------- |
| macOS | Apple silicon (`aarch64`), Intel (`x86_64`) |
| Linux | `x86_64`, `aarch64` |
| Windows | `x86_64` |

Every binary is a ReleaseSafe build for a baseline CPU of its
architecture, so it runs on any machine of that kind and keeps its
safety checks on.

## macOS and Linux

The installer downloads the archive for your machine, checks its sha256,
and puts `mnml` in `~/.local/bin` (set `MNML_INSTALL_DIR` to put it
somewhere else):

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/chris-mclennan/mnml/releases/latest/download/mnml-installer.sh | sh
```

Or with [Homebrew](https://brew.sh), on macOS or Linux:

```sh
brew install chris-mclennan/tap/mnml
```

## Windows

The installer puts `mnml.exe` in `%LOCALAPPDATA%\mnml\bin` and adds that
folder to your user `PATH`:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://github.com/chris-mclennan/mnml/releases/latest/download/mnml-installer.ps1 | iex"
```

Or with [winget](https://learn.microsoft.com/windows/package-manager/):

```powershell
winget install ChrisMcLennan.mnml
```

> [!WARNING]
> The Windows build is compiled and packaged on every release, but it
> has not yet been run end to end the way the macOS and Linux builds
> are. Expect rough edges, and please report them.
> [`docs/WINDOWS.md`](https://github.com/chris-mclennan/mnml/blob/main/docs/WINDOWS.md)
> keeps the honest list of what is proven there and what is not.

## Linux packages

Every release carries a `.deb` for Debian and Ubuntu and an `.rpm` for
Fedora and RHEL, for both `x86_64` and `aarch64`:

```sh
sudo apt install ./mnml-x86_64-unknown-linux-gnu.deb      # Debian / Ubuntu
sudo dnf install ./mnml-x86_64-unknown-linux-gnu.rpm      # Fedora / RHEL
```

The packages install `/usr/bin/mnml`, the example Lua scripts under
`/usr/share/mnml/lua`, and mnml's symbols font under
`/usr/share/mnml/fonts`.

## By hand

Each release on
[GitHub](https://github.com/chris-mclennan/mnml/releases/latest) has
the raw archives — `mnml-<triple>.tar.xz`, or `.zip` on Windows — each
with a `.sha256` beside it, and `sha256.sum` for all of them. Unpack
one and put `mnml` anywhere on your `PATH`.

| Triple | For |
| ------ | --- |
| `aarch64-apple-darwin` | macOS, Apple silicon |
| `x86_64-apple-darwin` | macOS, Intel |
| `x86_64-unknown-linux-gnu` | Linux, x86_64 |
| `aarch64-unknown-linux-gnu` | Linux, aarch64 |
| `x86_64-pc-windows-gnu` | Windows, x86_64 (also as an `.msi`) |

## Official and community channels

Everything above is published by the mnml project itself:

- **The GitHub release assets** and the two **installer scripts** are
  built and uploaded by the release workflow in the mnml repository.
- **The Homebrew tap**, `chris-mclennan/tap`, is updated by a workflow
  in the mnml repository when a release is published.
- **winget** is Microsoft's community manifest repository. mnml submits
  each new version there as a pull request, which Microsoft's review
  merges on its own schedule — so a new release can reach `winget` some
  time after it reaches the other channels.

mnml is not in Homebrew's core formulae, any Linux distribution's
repositories, or crates.io. (`cargo install mnml-rs` installs 0.2.22,
the last release of the Rust generation, and stays there.)

## Before you start: a font

mnml draws file icons, chips and the sidebar rail with
[Nerd Font](https://www.nerdfonts.com/) symbols. If your terminal font is
not a Nerd Font, the first-launch wizard can install *Symbols Nerd Font
Mono* for you — or run `mnml --ascii` to use plain characters instead.
See [Help](/docs/help#icons-show-as-boxes-or-question-marks).

## Integrations are separate

The installers and packages install mnml and nothing else. Jira,
Bitbucket and other integrations are released on their own and
installed from inside mnml; see [Integrations](/docs/integrations).

## Next

[Getting Started](/docs/getting-started) walks through the first
launch. To build mnml yourself instead, see
[Build from Source](/docs/install/build).

To look around before mnml has any of your settings, run
`mnml --sandbox` for a throwaway home, or `mnml --demo` for a ready-made
sample project; [Try It First](/docs/install/try) explains both (macOS
and Linux).

## Coming from mnml 0.2.x

Configuration is `config.zon` now, and 0.3.0 does not read the old
`config.toml`. Convert it on 0.2.22 **before** you upgrade; the
[0.3.0 release notes](/docs/install/release-notes/0-3-0#your-config-run-the-converter-first)
walk through it.
