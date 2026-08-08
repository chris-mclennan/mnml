---
title: Platform support
description: What runs where — macOS, Linux, and Windows as first-class platforms, with the Windows-specific gotchas around the Git Bash + MinGW toolchain.
---

mnml runs as a single Rust binary on macOS, Linux, and Windows. All three are first-class: `cargo test` runs the full unit suite (1196 tests) and the `.test` e2e suite (222 tests) on ubuntu-latest, macos-latest, and windows-latest on every push. Windows went green on 2026-08-03 and now ships alongside macOS and Linux from the same release train.

This page covers what "supported" means per platform, the Windows-specific choices (why `x86_64-pc-windows-gnu` and not `msvc`, why `.test` uses Git-for-Windows bash), and the source-build story for anyone compiling from a checkout rather than installing a prebuilt.

## Supported targets

The release train publishes prebuilt artifacts for these targets via [`cargo-dist`](https://opensource.dev/dist/):

| Platform | Target triple | Formats |
|---|---|---|
| macOS · Apple Silicon | `aarch64-apple-darwin` | `.tar.xz`, `installer.sh` |
| macOS · Intel | `x86_64-apple-darwin` | `.tar.xz`, `installer.sh` |
| Linux · x86_64 | `x86_64-unknown-linux-gnu` | `.tar.xz`, `installer.sh` |
| Linux · arm64 | `aarch64-unknown-linux-gnu` | `.tar.xz`, `installer.sh` |
| Windows · x86_64 | `x86_64-pc-windows-gnu` | `.zip`, `installer.ps1`, `.msi`* |

*(2026-08-07: dropped `.dmg` / `.pkg` — mnml is a TUI editor; macOS developers install via `cargo install`, Homebrew, or the tarball. Windows `.msi` is retained as a build artifact because [winget](https://learn.microsoft.com/windows/package-manager/) requires it as the download source for `winget install mnml`, but it's not the recommended path — use `winget`, `cargo install mnml-rs`, or the `.zip` directly.)*

Everything is downloadable from the [Install page](/install/) or via a one-liner installer (`curl … | sh` on Unix, `irm … | iex` on Windows).

### About the Windows target choice

The Windows artifact is built for `x86_64-pc-windows-gnu` (the MinGW-w64 toolchain), not the more common `x86_64-pc-windows-msvc`. This is not a preference — it's a hard constraint from mnml's terminal-emulation dependency.

mnml embeds a headless VT100 parser via `libghostty-vt` (the same engine Ghostty uses). Upstream Ghostty explicitly marks `x86_64-windows-msvc` as "doesn't work yet" in their own CI matrix, and mnml's Windows CI reproduced the exact failure — a runtime `STATUS_ACCESS_VIOLATION` in `ghostty_terminal_vt_write` regardless of build flags, across seven independent CI cycles. The supported combo upstream is `windows-gnu`, so that's what mnml ships.

Practical consequences:

- The x86_64 build runs correctly on both native x86_64 Windows and arm64 Windows (via Microsoft's x86_64 emulation).
- Native `aarch64-pc-windows-msvc` builds are on hold until upstream Ghostty gets MSVC support working.
- If you'd rather build for MSVC yourself, `cargo build` will fail at link time inside `mnml-libghostty-vt-sys` — that's expected. Track upstream Ghostty for status.

### About `libghostty-vt` vendoring

mnml owns its bindings to `libghostty-vt` through two first-party crates in the workspace — `mnml-libghostty-vt-sys` (the `-sys` crate: build script + bindgen) and `mnml-libghostty-vt` (the safe Rust wrapper). You don't need to install `libghostty` separately.

The `-sys` crate has two link paths, both compiled in by default so the build "just works" on every host:

- **`source-build`** (default) — git-clones ghostty at a pinned commit into `OUT_DIR` and runs `zig build`. Adds 2–5 minutes to a cold build; subsequent builds hit the `zig-cache` + cargo incremental cache and are fast.
- **`pkg-config`** — resolves `libghostty-vt-static` via `PKG_CONFIG_PATH`. Present so a future prebuilt setup can plug in without touching the crate; currently a no-op because no `.pc` ships in the tree. Downstream users who bring their own prebuilt can still opt in.

The vendored headers under `vendor/libghostty-vt/include/ghostty/` are re-generated whenever the pinned commit moves, so bindgen output and link ABI stay lock-step.

## Building from source

The prebuilts are the recommended install path. If you're checking out the repo (contributing, running locally, or targeting a platform we don't ship for), you need the prerequisites for the source-build path.

### Prerequisites — all platforms

- A Rust toolchain matching the workspace's `rust-version` (currently 1.90+) — installed via [rustup](https://rustup.rs/).
- **`zig` 0.16.0** — required by `mnml-libghostty-vt-sys`'s build script. Older 0.15.x won't build the pinned ghostty commit; newer versions haven't been tested.
- **`git`** on `PATH` — the build script clones ghostty at the pinned commit on first build.

Install zig:

```sh
# macOS
brew install zig                              # currently 0.16.x on Homebrew
# or specifically pin:
brew install zig@0.16

# Linux
# grab the tarball from https://ziglang.org/download/ and put `zig` on PATH

# Windows (via scoop)
scoop install zig
```

Verify:

```sh
zig version   # → 0.16.0 (or newer minor within 0.16)
git --version
```

Then:

```sh
git clone https://github.com/chris-mclennan/mnml
cd mnml
cargo build --release
./target/release/mnml
```

The first build downloads and compiles the vendored ghostty sources; the log will show a `libghostty-vt: pkg-config unavailable, falling back to zig source-build` warning line — that's expected.

### macOS notes

If `zig` isn't on your default shell `PATH` (Homebrew installs to `/opt/homebrew/opt/zig/bin` on Apple Silicon), the `./run.sh` and `./dev.sh` helpers in the repo prepend it for you. For a plain `cargo build`, add it to your shell profile yourself.

### Linux notes

Distro-packaged `zig` is typically too old. Grab the 0.16.0 tarball from [ziglang.org/download](https://ziglang.org/download/) and drop `zig` into `~/.local/bin` (or wherever you keep out-of-band tools).

### Windows notes

Building from source on Windows requires all three of:

1. **Rust toolchain with the `x86_64-pc-windows-gnu` target** installed:

   ```sh
   rustup target add x86_64-pc-windows-gnu
   ```

2. **MinGW-w64 GCC** on `PATH` — needed as the linker for the `-pc-windows-gnu` target. GitHub's `windows-latest` runners preinstall it under `C:\ProgramData\mingw64\`; for local dev, install it via MSYS2, chocolatey (`choco install mingw`), or scoop (`scoop install mingw`).

3. **`zig` 0.16.0** — same as above. `scoop install zig` is the least friction.

Then build with the explicit target:

```sh
cargo build --release --target x86_64-pc-windows-gnu
```

The MSVC target is deliberately not supported — see [About the Windows target choice](#about-the-windows-target-choice).

## Running `.test` e2e scripts on Windows

mnml's `.test` DSL (`mnml test` and `cargo test`) drives the real `App` against a virtual terminal backend. Some steps execute a `shell:` line — arbitrary Unix shell (`mkdir -p`, pipes, `sort`) — to set up workspace fixtures. On macOS and Linux mnml exec's `$SHELL -c "<cmd>"`; Windows needs a POSIX shell that speaks the same syntax.

### The WSL trap

On a default Windows install, `bash` on `PATH` resolves to `C:\Windows\System32\bash.exe` — the **WSL launcher**, not a POSIX shell. On GitHub's `windows-latest` runners (and any dev box without a WSL distro installed) that binary is present but has no distro behind it, so every `.test` `shell:` step dies with:

> WSL has no installed distributions.

That's not a bug in your test — it's the platform quietly steering you at an empty WSL install.

### The fix — Git for Windows

mnml probes for a Git-for-Windows `bash.exe` at these paths, in order:

```
C:\Program Files\Git\bin\bash.exe
C:\Program Files\Git\usr\bin\bash.exe
C:\Program Files (x86)\Git\bin\bash.exe
C:\Program Files (x86)\Git\usr\bin\bash.exe
```

Git for Windows preinstalls on the CI runners and is the most common dev-box shell setup, so this covers ~all cases out of the box. If nothing matches, `.test` shell steps fail with a clear error rather than reproducing the WSL trap silently.

Install [Git for Windows](https://git-scm.com/downloads/win) and you're set.

### Overriding the bash path

If you use MSYS2, Cygwin, or a Git installed to a non-default location, point mnml at your bash explicitly:

```powershell
$env:MNML_BASH = "C:\msys64\usr\bin\bash.exe"
mnml test
```

The env var wins over the probe order. Any POSIX-compatible `bash` works — mnml runs `<bash> -c "<cmd>"` and reads stdout/stderr.

## CI matrix

Every push to `main` and every pull request runs the full test suite on all three platforms via [`.github/workflows/ci.yml`](https://github.com/chris-mclennan/mnml/blob/main/.github/workflows/ci.yml):

| OS | Runner image | Target | Tests |
|---|---|---|---|
| macOS | `macos-latest` (arm64) | host | `cargo test` (parallel) |
| Linux | `ubuntu-latest` (x86_64) | host | `cargo test` (parallel) |
| Windows | `windows-latest` (x86_64) | `x86_64-pc-windows-gnu` | `cargo test --target x86_64-pc-windows-gnu -- --test-threads=1 --nocapture` |

The Windows job runs single-threaded with `--nocapture` because the default parallel harness only prints "ok" *after* a test completes — if a test crashes mid-run, the name never surfaces and bisection is painful. Serial + streaming output means the crashing test's name shows up in the log immediately before the crash. macOS and Linux stay parallel for speed.

`clippy` runs with `-D warnings` on all three platforms and every target; `rustfmt --check` runs on the host toolchain. Any warning or format drift fails the build.

## What isn't supported

- **`x86_64-pc-windows-msvc`** — see above; blocked upstream.
- **`aarch64-pc-windows-msvc`** — no arm64 Windows prebuilt today. Runs fine on arm64 Windows via emulation using the x86_64 MSI.
- **`x86_64-unknown-linux-musl`** — no musl prebuilt. `cargo build --target x86_64-unknown-linux-musl` may work if you supply zig + the target's libc, but nothing in CI validates it.
- **FreeBSD / OpenBSD / other BSDs** — no CI coverage; contributions welcome but you're the first person on that path.
- **32-bit anything** — not built, not tested.

## Next

- [Install](/install/) — download links + one-liner installers for each platform.
- [First run](/getting-started/) — launch flags, config precedence, and the initial keys.
- [Troubleshooting](/troubleshooting/) — install-time and launch-time issues, including Windows-specific fixes.
- [In-app updater](/manual/updates/) — how the launch-time release check works on each OS.
- [Headless & .test](/manual/headless/) — the file-IPC channel and the `.test` DSL these platform notes support.
