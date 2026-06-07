---
title: In-app updater
description: mnml's launch-time release check and one-command install flow across macOS, Linux, and Windows.
---

mnml watches its own releases. On launch a background thread pings the GitHub releases API, and if the latest tag differs from the running version a toast fires hinting at `:update.install_latest`. That command spawns a Pty pane that downloads the right artifact for your platform, SHA256-verifies it against the published `sha256.sum`, and runs the platform-native installer — `installer` on macOS, `install` to `~/.cargo/bin` on Linux, `msiexec` (UAC-elevated) on Windows.

The updater is deliberately split into two halves so neither blocks the other: a passive check that costs one HTTP request a session, and an active install that you opt into when you're ready to take the new version.

## Launch-time check

When mnml starts, `src/update_check.rs` spawns a single background thread that:

1. GETs `https://api.github.com/repos/chris-mclennan/mnml/releases/latest` with a 10-second timeout.
2. Parses `tag_name` from the response and strips the leading `v`.
3. Compares to the built-in `CARGO_PKG_VERSION` via plain string equality.
4. Stashes the result on a shared `Arc<UpdateCheck>` that `App::tick` polls.

The first tick after the data arrives surfaces a one-shot toast:

```
mnml v0.1.5 available — :update.install_latest  ·  https://github.com/chris-mclennan/mnml/releases/tag/v0.1.5
```

The toast fires once per session — dismissing it (or just letting it time out) won't trigger another for the same version. The check is intentionally simple: string equality on the tag, no semver parsing. The only false-positive case is running a local dev build whose `Cargo.toml` version equals the latest published tag; the session-once flag stops the toast from reappearing if you ignore it.

### Opting out

```toml
# ~/.config/mnml/config.toml
[ui]
check_updates = false   # skip the GitHub API call on launch
```

Default is `true`. The check is also skipped automatically when:

- `--headless` is set (no toast surface).
- `--blit` is set (mnml is running as a native pane inside tmnl; the host shows toasts, not the guest).

## Installing an update

The toast hints at `:update.install_latest`. Run it from the ex-command line (vim mode), the command palette (`Ctrl-Shift-P` → "Update mnml"), or any keymap you've bound to it. There's no default chord — updates are rare enough that the palette / ex-cmd is fine.

The command:

1. Reads `latest_version` from the launch-time check. If the check is disabled, hasn't resolved, or returned no newer version, you get a toast (`update check disabled or not started` / `no newer mnml release found`) and nothing else happens.
2. Writes the platform-specific install script to a temp file (chmod 755 on Unix).
3. Opens a `Pane::Pty` running the script via `bash` (macOS / Linux) or `powershell -File` (Windows).

The Pty pane shows download progress, the SHA256 verification, the install step, and any admin / UAC prompt live. The currently-running mnml process keeps working throughout — its binary is in memory, not re-read from disk. When the script finishes:

```
──────────────────────────────────────────────────────
  Quit mnml (Ctrl+Q) and relaunch to use v0.1.5.
  Your current session is still running the old binary.
──────────────────────────────────────────────────────
```

Quit with `Ctrl+Q` (or `:qa!` in vim mode) and relaunch to pick up the new version. The flow deliberately avoids the "kill the process that's running the install" circle — no self-exec dance, no in-place binary swap. You get to decide when to take the new version.

## Per-platform installers

Each script is templated at compile time via `cfg!` macros so the binary ships with exactly one script branch baked in. Architecture is also resolved at compile time (`aarch64` vs `x86_64`), so the script downloads the artifact that matches the binary you're running.

### macOS

```text
1/4  downloading sha256.sum…
2/4  downloading mnml-rs-aarch64-apple-darwin.pkg…
3/4  verifying SHA256…
     expected: 3f1c2a98b5e7d4c1f8a6e2b9…
     actual:   3f1c2a98b5e7d4c1f8a6e2b9…
     ✓ verified
4/4  installing — this will prompt for your admin password
Password:
```

A bash script. Downloads `mnml-rs-<target>.pkg` (Apple Silicon: `aarch64-apple-darwin`; Intel: `x86_64-apple-darwin`), verifies via `shasum -a 256`, and runs `sudo installer -pkg <file> -target /`. The sudo prompt appears inside the Pty pane — type your password directly there. Installs to the same location Homebrew + the standalone `.pkg` use, so a subsequent `brew upgrade mnml` won't conflict.

### Linux

```text
1/4  downloading sha256.sum…
2/4  downloading mnml-rs-x86_64-unknown-linux-gnu.tar.xz…
3/4  verifying SHA256…
     ✓ verified
4/4  extracting + installing to ~/.cargo/bin/mnml…
     ✓ installed: /home/chris/.cargo/bin/mnml
```

A bash script. Downloads `mnml-rs-<target>.tar.xz` (`aarch64-unknown-linux-gnu` or `x86_64-unknown-linux-gnu`), verifies via `sha256sum`, extracts the tarball, and `install -m 0755`s the binary to `~/.cargo/bin/mnml`. No sudo — `~/.cargo/bin` is on a Rust user's `PATH` and is user-writable. If you installed mnml somewhere else (`/usr/local/bin`, a `.deb`, your distro's package manager), the in-app updater drops a fresh binary in `~/.cargo/bin` that will shadow the system copy as long as `~/.cargo/bin` appears earlier on `PATH`.

### Windows

```text
1/4  downloading sha256.sum…
2/4  downloading mnml-rs-x86_64-pc-windows-msvc.msi…
3/4  verifying SHA256…
     expected: 8c4e91d2a7f3b5e6c9d8a1f4…
     actual:   8c4e91d2a7f3b5e6c9d8a1f4…
     ✓ verified
4/4  installing — Windows will show a UAC elevation prompt
```

A PowerShell script. Downloads `mnml-rs-<target>.msi` (`x86_64-pc-windows-msvc` today; `aarch64-pc-windows-msvc` ships when we add an ARM64 Windows runner), verifies via `Get-FileHash`, then launches the installer with elevation:

```powershell
Start-Process -FilePath 'msiexec.exe' `
  -ArgumentList '/i', "`"$msiPath`"", '/qb!' `
  -Verb RunAs -Wait -PassThru
```

- `-Verb RunAs` triggers the UAC elevation prompt — the Windows dialog pops in front of mnml; click "Yes".
- `/qb!` is msiexec's "basic UI, no modal at end" mode. You see a progress bar, but there's no final "Finish" dialog the user has to click through.
- `-Wait` keeps the Pty pane alive until the elevated msiexec finishes, so you see whether it succeeded.

The script also surfaces non-zero msiexec exit codes (`✗ msiexec exited with code N`) and cleans up the temp dir on success. After install, it prompts `Press Enter to close this pane.` so you can read the relaunch hint before the pane goes away.

### Other platforms

BSDs and other unknown OSes fall through to a stub that points you at the release URL for manual download:

```text
── mnml in-app update ──
  version: v0.1.5

In-app install isn't wired for this platform.
Download the installer manually:
  https://github.com/chris-mclennan/mnml/releases/download/v0.1.5/

Press Enter to close this pane.
```

If you're on FreeBSD, OpenBSD, NetBSD, or an OS we haven't seen, the artifacts on the GitHub release should still install via the platform's normal tooling.

## SHA256 verification

Every installer downloads two files: the platform artifact and the `sha256.sum` published alongside it. The script computes the artifact's hash locally and compares to the published value:

| Platform | Hash tool | Format read |
|---|---|---|
| macOS | `shasum -a 256` | `<hash>  *<artifact>` (BSD checksum format) |
| Linux | `sha256sum` | `<hash>  *<artifact>` (coreutils format) |
| Windows | `Get-FileHash -Algorithm SHA256` | first hex64 token in the line matching the artifact name |

Mismatch refuses to install and the script exits non-zero:

```
     ✗ SHA256 mismatch — refusing to install
```

### Threat model

The check defends against partial downloads, CDN corruption, and a transparent proxy injecting a different binary. It does **not** defend against a compromised GitHub Releases page that publishes a forged `sha256.sum` alongside a forged artifact — that's the same exposure normal users have when downloading manually. mnml doesn't currently ship a separate signing chain (gpg / sigstore / cargo-dist's signing); when it does, this section will document it. For now, the SHA256 step gives you "the bytes you got match the bytes the release page advertises", which is what `curl | sh` flows give you and no more.

## Troubleshooting

**The launch toast never appears.** Check three things in order:

1. `[ui] check_updates` in `~/.config/mnml/config.toml` — if it's `false`, the background thread doesn't spawn.
2. You're not running with `--headless` or `--blit` — the check is skipped in both modes.
3. The version you're running is genuinely behind. The check uses string equality on the tag; a local build whose `Cargo.toml` equals the latest published tag will look like "already on latest". Run `mnml --version` and cross-check against `https://github.com/chris-mclennan/mnml/releases/latest`.

**`update check disabled or not started`.** The command ran but `App.update_check` is `None`. Same three causes as above — most often, you set `check_updates = false` or launched headless.

**`no newer mnml release found`.** The check completed but the latest tag matches the running version. Nothing to install.

**`update: couldn't write install script: <error>`.** mnml failed to write the script to `std::env::temp_dir()`. Usually a disk-full or permissions issue on the temp dir.

**SHA256 mismatch.** The script exits 1 and the Pty pane stays open with the mismatch printed. Retry the install — if it persists, the release artifact is probably mid-upload or got re-uploaded out of sync with `sha256.sum`. File an issue at [github.com/chris-mclennan/mnml/issues](https://github.com/chris-mclennan/mnml/issues).

**macOS sudo prompt won't take input.** The Pty pane's input must be focused. Click into it, or use the keymap that focuses the pty pane (default: `Ctrl-E` releases focus from the editor; then click or `Tab` into the pane).

**Windows UAC was cancelled.** msiexec exits non-zero, the script prints the code, and the install is rolled back by Windows. Re-run `:update.install_latest`.

**Windows "press Enter to close" doesn't close the pane.** That's the script waiting — press Enter inside the pty pane (not in the editor). Or kill the pane with the close-pane keymap.

**You want to skip the in-app updater entirely.** Use the same installer flow that gave you mnml the first time — `brew upgrade mnml`, redownload the `.pkg` / `.msi` from the [Install](/install/) page, or `cargo install mnml-rs`. The in-app updater is a convenience, not the only path.

## Next

- [Install](/install/) — first-time install flows for every platform
- [Configuration](/manual/settings/) — `[ui] check_updates` and other toggles
- [Headless & .test](/manual/headless/) — the mode that skips the update check
- [Troubleshooting](/troubleshooting/) — more diagnostics beyond the updater
