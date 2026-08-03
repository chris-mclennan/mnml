---
title: Troubleshooting
description: Common install / launch issues — Windows source-build prerequisites, the WSL bash trap for `.test`, the macOS Tahoe "Intel-based apps" warning, and how to recover.
---

## Nightly bundle

`./scripts/build-app.sh --nightly` builds a second macOS bundle at `target/mnml-nightly.app` that's distinct from the stable `mnml.app`:

- **Different bundle identifier** (`sh.mnml.app.nightly` vs `sh.mnml.app`) — both can live in `/Applications/` at once, both can be dock-pinned independently, Cmd-Tab shows them as separate apps.
- **Inverted-color icon palette** — cool blue ground + charcoal `mnml` wordmark, so the two are visually distinguishable at a glance.
- **The launcher execs your latest cargo build directly** (`$HOME/Projects/mnml/target/release/mnml`) instead of packaging a snapshot binary into the bundle. Rebuild with `cargo build --release` and the next launch of `mnml-nightly.app` picks up the new code — no rebundling, no `cp` into `/Applications/`.

Use case: pin nightly to the dock for one-click access to whatever's currently in your local `target/release/`, while the stable bundle in `/Applications/` stays untouched at the last DMG you installed.

**Not part of release CI** — nightly is a local maintainer convenience. There's no nightly DMG, no auto-update, no signed artifact. Build it yourself with `./scripts/build-app.sh --nightly` and copy the result wherever you want it. Source: `scripts/build-app.sh`, `scripts/launcher-nightly.sh`, `scripts/Info-nightly.plist`.

## "Intel-based apps" warning on macOS Tahoe (26)

If you installed an mnml DMG older than v0.1.2 and you're running macOS Tahoe (26) or later, you may see this warning the first time you launch mnml:

> **Support Ending for Intel-based Apps.** This version will not open in a future release of macOS.

mnml ships native arm64 binaries for Apple Silicon. The warning is a false positive — the cause was a missing `LSMinimumSystemVersion = 11.0` key in the `.app` bundle's `Info.plist`. Without that key, Tahoe falls back to its legacy heuristics and classifies anything declaring `LSMinimumSystemVersion < 11.0` (pre-Big-Sur, the macOS version where Apple Silicon shipped) as a legacy Intel app, regardless of the actual binary architecture.

**Fixed in v0.1.2 and later.** If you see the warning, redownload the latest DMG from the [Install](/install/) page or:

```sh
brew upgrade chris-mclennan/tap/mnml
```

You can confirm you're on a fixed build:

```sh
defaults read /Applications/mnml.app/Contents/Info.plist LSMinimumSystemVersion
# 11.0
```

If it still prints `10.14` or doesn't exist, your bundle is pre-v0.1.2 — update.

## Windows

Windows is a first-class supported platform as of 2026-08-03 — the full test suite runs green on `windows-latest` on every push. The MSI installer covers most users; the notes below are for source builds and `.test` e2e scripts.

For the deeper "why this target, not that one" background, see [Platform support](/manual/platform-support/).

### `.test` shell steps die with "WSL has no installed distributions"

The default `bash` on Windows resolves to `C:\Windows\System32\bash.exe` — the **WSL launcher**, not a POSIX shell. If WSL isn't installed (or has no distro), every `.test` step containing a `shell:` line fails with a WSL error.

mnml sidesteps this by probing for a Git-for-Windows `bash.exe` at these paths, in order:

```
C:\Program Files\Git\bin\bash.exe
C:\Program Files\Git\usr\bin\bash.exe
C:\Program Files (x86)\Git\bin\bash.exe
C:\Program Files (x86)\Git\usr\bin\bash.exe
```

Install [Git for Windows](https://git-scm.com/downloads/win) — mnml picks it up automatically the next launch. If you use MSYS2, Cygwin, or Git in a non-default location, point mnml at your bash explicitly:

```powershell
$env:MNML_BASH = "C:\msys64\usr\bin\bash.exe"
mnml test
```

The env var wins over the probe order.

### `cargo build` fails inside `mnml-libghostty-vt-sys` — "zig: command not found"

`mnml-libghostty-vt-sys` source-builds `libghostty-vt` from a pinned upstream ghostty commit on the first build. That path needs **`zig` 0.16.0** and **`git`** on `PATH`.

```powershell
# Install via scoop
scoop install zig

# Verify
zig version   # → 0.16.0 or newer 0.16.x
git --version
```

Older zig 0.15.x won't build the pinned commit — upgrade if you have it.

### `linker gcc.exe not found` when building for `x86_64-pc-windows-gnu`

The `-pc-windows-gnu` target uses the MinGW-w64 GCC linker. On GitHub's `windows-latest` runners this is preinstalled under `C:\ProgramData\mingw64\`, but a fresh local install may not have it on `PATH`.

Install MinGW-w64 via one of:

```powershell
scoop install mingw
choco install mingw
# or MSYS2: https://www.msys2.org/
```

Then confirm:

```powershell
gcc --version
```

If `gcc` isn't found, add `C:\ProgramData\mingw64\bin` (or wherever your installer put it) to your `PATH`.

### "Why not the MSVC toolchain?"

Because upstream `libghostty-vt` doesn't support MSVC — their own CI matrix marks `x86_64-windows-msvc` as "doesn't work yet". mnml reproduced the crash (a `STATUS_ACCESS_VIOLATION` in `ghostty_terminal_vt_write`) across seven independent CI cycles before switching to `-pc-windows-gnu`. The MSI installs and runs identically on x86_64 and arm64 Windows (arm64 via Microsoft's emulation).

If you'd rather target MSVC, `cargo build --target x86_64-pc-windows-msvc` will fail at the `mnml-libghostty-vt-sys` link step — that's expected. Track [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) for MSVC status.

## `zig` not found on macOS

The Homebrew `zig` formula installs to `/opt/homebrew/opt/zig/bin` (Apple Silicon). If that dir isn't on your shell's default `PATH`, `cargo build` from a fresh terminal will fail at the `mnml-libghostty-vt-sys` source-build step with `zig: No such file or directory`.

The `./run.sh` and `./dev.sh` helpers in the repo prepend it automatically. For plain `cargo build`, add it to your shell profile yourself:

```sh
# ~/.zshrc or ~/.bashrc
export PATH="/opt/homebrew/opt/zig/bin:$PATH"
```

Verify with `zig version` — it should print `0.16.0` or a newer 0.16.x.
