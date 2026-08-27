//! Binary entry. Subcommand dispatch:
//!   - `mnml [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless]`
//!     — the TUI (or the headless virtual-screen + file-IPC harness with `--headless`).
//!   - `mnml run FILE [--env NAME] [--workspace DIR]` — send one `.curl` / `.http`
//!     request, after `{{VAR}}` substitution from `.mnml/env/<NAME>.env`.
//!   - `mnml chain run FILE [--env NAME] [--workspace DIR]` — run a `.chain.json`.
//!   - `mnml discover SPEC [--out DIR] [--base-url URL]` — OpenAPI/Swagger → `.curl` stubs.
//!
//! Later phases add `mnml test GLOB`, `mnml ipc …`.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use mnml::app::App;
use mnml::config::Config;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1).peekable();
    match args.peek().map(String::as_str) {
        Some("run") => {
            args.next();
            run_subcommand(args.collect())
        }
        Some("chain") => {
            args.next();
            // `mnml chain run FILE …` (the `run` word is optional).
            if matches!(args.peek().map(String::as_str), Some("run")) {
                args.next();
            }
            chain_subcommand(args.collect())
        }
        Some("discover") => {
            args.next();
            discover_subcommand(args.collect())
        }
        Some("sync") => {
            args.next();
            sync_subcommand(args.collect())
        }
        Some("sync-check") => {
            args.next();
            sync_check_subcommand(args.collect())
        }
        Some("proxy") => {
            args.next();
            proxy_subcommand(args.collect())
        }
        Some("test") => {
            args.next();
            test_subcommand(args.collect())
        }
        Some("commands") => {
            // `mnml commands` — dump the full command registry to
            // stdout, grouped + sorted, using the same text builder
            // the in-app `:commands` scratch buffer uses. Handy for
            // audits or generating a CHANGELOG-friendly list.
            let text = mnml::command::build_commands_reference_text_public(&[]);
            print!("{text}");
            ExitCode::SUCCESS
        }
        _ => {
            // TUI path only — `--sandbox` self-redirect belongs here
            // and NOT ahead of subcommand dispatch (`mnml run FILE
            // --sandbox` shouldn't silently redirect HOME/XDG on a
            // one-shot request). Runs BEFORE `run_tui` so every
            // downstream HOME lookup — including config load — sees
            // the redirected path.
            maybe_reexec_for_sandbox();
            run_tui(args.collect())
        }
    }
}

// ───────────────────────── `--sandbox` self-redirect ──────────────

/// True when `$HOME` looks like a sandbox tempdir (either under the
/// system temp root, or named `mnml-sandbox-*`). Used both by the
/// self-redirect probe and by the in-app banner logic so a bare
/// `mnml --sandbox` invocation without the redirect gets caught.
fn home_is_sandbox_tempdir() -> bool {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .is_some_and(|home| {
            let tmp = std::env::temp_dir();
            home.starts_with(&tmp)
                || home
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("mnml-sandbox-"))
        })
}

/// If `--sandbox` is on argv but `$HOME` isn't a tempdir yet, create
/// one + re-exec ourselves with `HOME` + `XDG_CONFIG_HOME` redirected.
/// Runs BEFORE any config load so every downstream HOME lookup sees
/// the new path. On second entry (post-exec) `home_is_sandbox_tempdir`
/// is true → we return early and continue normally.
fn maybe_reexec_for_sandbox() {
    let raw: Vec<String> = std::env::args().collect();
    if !raw.iter().any(|a| a == "--sandbox") {
        return;
    }
    if home_is_sandbox_tempdir() {
        return;
    }
    // Best-effort GC of prior sandbox dirs. Since exec() replaces the
    // process image, we can't rely on Drop/atexit to clean up on
    // exit; instead prune anything older than 6h at the top of every
    // new sandbox session. Keeps `/tmp` from accumulating dead
    // `mnml-sandbox-*` dirs indefinitely.
    gc_stale_sandbox_tempdirs();
    // Create the sandbox root. Shell out to `mktemp` for portability
    // — `std::env::temp_dir()` gives the parent but not a fresh dir.
    let out = std::process::Command::new("mktemp")
        .args(["-d", "-t", "mnml-sandbox-XXXXXXXX"])
        .output();
    let root = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => {
            eprintln!("mnml: --sandbox: failed to create tempdir");
            std::process::exit(1);
        }
    };
    let xdg = format!("{root}/xdg");
    let workspace = format!("{root}/workspace");
    let _ = std::fs::create_dir_all(&xdg);
    let _ = std::fs::create_dir_all(&workspace);
    // nvchad-user SEV-3 2026-08-05 — if no workspace positional was
    // passed, inject the sandbox workspace so mnml doesn't fall
    // back to CWD (which is often the user's real project dir on a
    // bare `mnml --sandbox` invocation). If they DID pass one, honor
    // their choice.
    //
    // Skip both the flag itself AND the value that immediately
    // follows a value-taking flag (`--input vim` → "vim" is not a
    // positional). Otherwise `mnml --sandbox --input vim` would
    // falsely detect "vim" as a workspace and skip the injection.
    const VALUE_FLAGS: &[&str] = &["--input", "--config", "--show"];
    let mut has_workspace_arg = false;
    let mut skip_next = false;
    for a in raw.iter().skip(1) {
        if skip_next {
            skip_next = false;
            continue;
        }
        if a.starts_with('-') {
            if VALUE_FLAGS.contains(&a.as_str()) {
                skip_next = true;
            }
            continue;
        }
        // Ignore the binary basename if it somehow appears (shouldn't
        // in normal argv but harmless).
        if a.eq_ignore_ascii_case("mnml") {
            continue;
        }
        has_workspace_arg = true;
        break;
    }
    let mut child_args: Vec<String> = raw[1..].to_vec();
    if !has_workspace_arg {
        child_args.push(workspace.clone());
    }
    eprintln!("mnml: --sandbox self-redirect: HOME={root}");
    // Unix: exec() replaces the current process image — no fork, no
    // wait, no double-mnml running. Windows: no exec in stdlib, so
    // spawn + wait + propagate the child's exit code. Costs one extra
    // process for the lifetime of the sandbox — fine, sandbox mode
    // isn't the hot path.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let err = std::process::Command::new(&raw[0])
            .args(&child_args)
            .env("HOME", &root)
            .env("XDG_CONFIG_HOME", &xdg)
            .exec();
        eprintln!("mnml: --sandbox: exec failed: {err}");
        std::process::exit(1);
    }
    #[cfg(not(unix))]
    {
        match std::process::Command::new(&raw[0])
            .args(&child_args)
            .env("HOME", &root)
            .env("XDG_CONFIG_HOME", &xdg)
            .status()
        {
            Ok(status) => std::process::exit(status.code().unwrap_or(1)),
            Err(err) => {
                eprintln!("mnml: --sandbox: spawn failed: {err}");
                std::process::exit(1);
            }
        }
    }
}

/// Prune old `mnml-sandbox-*` directories from the system temp root.
/// Called before creating a new sandbox tempdir so `/tmp` doesn't
/// accumulate dead sessions (exec-based self-redirect can't rely on
/// process-exit cleanup). Any dir with mtime older than 6h is
/// removed; younger ones (possibly a live integration session) are
/// left alone. Best-effort — errors are swallowed.
fn gc_stale_sandbox_tempdirs() {
    const STALE_SECS: u64 = 6 * 3600;
    let tmp = std::env::temp_dir();
    let Ok(entries) = std::fs::read_dir(&tmp) else {
        return;
    };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with("mnml-sandbox-") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(mtime) = meta.modified() else { continue };
        let Ok(age) = now.duration_since(mtime) else {
            continue;
        };
        if age.as_secs() > STALE_SECS {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

// ───────────────────────── `.test` E2E runner ─────────────────────

fn test_subcommand(argv: Vec<String>) -> ExitCode {
    // `mnml test ...` is invoked explicitly by the user — they typed
    // the path or wildcard. Authorize `shell` steps by default. The
    // gate exists for the `cargo test` discovery path on a cloned
    // untrusted repo, not for explicit invocations.
    // untouched-surfaces-hunt-2026-06-08 SEV-2 #5.
    // SAFETY: process-global env-var write before any e2e step
    // executes. The variable is read once per Step::Shell; setting
    // it here can't race anything since the harness runs single-
    // threaded under `mnml test`.
    if std::env::var("MNML_E2E_ALLOW_SHELL").is_err() {
        unsafe {
            std::env::set_var("MNML_E2E_ALLOW_SHELL", "1");
        }
    }
    let paths: Vec<PathBuf> = argv
        .into_iter()
        .filter(|a| !a.starts_with('-'))
        .map(PathBuf::from)
        .collect();
    let paths = if paths.is_empty() {
        vec![PathBuf::from("tests/e2e")]
    } else {
        paths
    };

    let mut total = 0usize;
    let mut failed = 0usize;
    for root in &paths {
        let (outcomes, _) = mnml::e2e::run_path(root);
        if outcomes.is_empty() {
            eprintln!("mnml test: no .test files under {}", root.display());
        }
        for o in outcomes {
            total += 1;
            if o.passed {
                println!("  ok   {}", o.name);
            } else {
                failed += 1;
                println!("  FAIL {} — {}", o.name, o.message.unwrap_or_default());
            }
        }
    }
    println!("\n{}/{} passed", total - failed, total);
    if failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

// ───────────────────────── Demo mode ─────────────────────────────

/// The bundled demo workspace lives in the mnml source tree at
/// `demo/workspace/`. Booting `--demo` directly against that path
/// would let any autosave / tree operation / git command mutate the
/// user's real mnml checkout (dirtying git status, or worse). So we
/// mirror it into a stable per-user cache dir + boot from there. The
/// cache is refreshed when the source tree is newer (see `stamp`),
/// so iterating on fixtures still works: edit `demo/workspace/…`,
/// rebuild, next `--demo` launch picks up the change.
///
/// `$MNML_DEMO_WORKSPACE` bypasses the copy — used when a developer
/// wants to iterate on demo content directly. The env value is
/// trusted as-is (they picked it).
fn resolve_demo_workspace() -> Result<PathBuf, String> {
    if let Some(over) = std::env::var_os("MNML_DEMO_WORKSPACE") {
        let p = PathBuf::from(over);
        if !p.is_dir() {
            return Err(format!(
                "$MNML_DEMO_WORKSPACE not a directory: {}",
                p.display()
            ));
        }
        return Ok(p);
    }
    let src = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("demo/workspace");
    if !src.is_dir() {
        return Err(format!(
            "demo workspace not found at {}. If mnml was built from a distributed \
             tarball (no `demo/` shipped), set $MNML_DEMO_WORKSPACE to point at one.",
            src.display()
        ));
    }
    // Use the same data_root as the rest of mnml (respects portable
    // mode + XDG). demo-workspace lives beside integrations/ + glyphs/.
    let cache_root = mnml::data_root::data_root().join("demo-workspace");
    let stamp = cache_root.join(".mnml-demo-stamp");
    // Freshness: the newest mtime anywhere under `demo/workspace/` beats
    // the stamp → refresh. Watching a single sentinel file misses every
    // edit that doesn't touch that file (README, .http, src/*.ts,
    // findings, the other override.toml). Walking the tree is cheap for
    // this size (~30 files) and gets us the honest answer.
    let src_mtime = max_mtime_recursive(&src).ok();
    let cache_mtime = std::fs::metadata(&stamp).and_then(|m| m.modified()).ok();
    let refresh = match (src_mtime, cache_mtime) {
        (Some(s), Some(c)) => s > c,
        _ => true,
    };
    if refresh {
        // Atomic-swap: build into an integration dir, then rename over the
        // live cache. Prevents a second concurrent `--demo` launch
        // from copying into a directory a first instance is reading
        // (torn files, remove_dir_all pulling files from under it).
        // rename() over an existing dir works on Unix; on Windows we
        // fall back to remove+rename which loses atomicity but the
        // window is small.
        // Per-PID suffix on both scratch paths — two concurrent
        // `mnml --demo` launches would otherwise race on the same
        // `.staging` / `.old` directories, remove_dir_all-ing each
        // other's in-progress writes.
        let pid = std::process::id();
        let staging = cache_root.with_extension(format!("staging.{pid}"));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging)
            .map_err(|e| format!("create staging {}: {e}", staging.display()))?;
        copy_dir_recursive(&src, &staging).map_err(|e| format!("seed demo workspace: {e}"))?;
        // Seed the fictional git history from the shipped tarball.
        // See `demo/workspace-git.tar.gz`. Failure isn't fatal — the
        // workspace still boots, git panels just show "not a repo" —
        // but we surface it via eprintln! (silent-forever would leave
        // the user confused about missing history) and skip stamping
        // so the next launch retries.
        let tarball = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("demo/workspace-git.tar.gz");
        let mut tar_ok = true;
        if tarball.is_file() {
            match std::process::Command::new("tar")
                .arg("xzf")
                .arg(&tarball)
                .arg("-C")
                .arg(&staging)
                .status()
            {
                Ok(s) if s.success() => {}
                Ok(s) => {
                    eprintln!(
                        "mnml --demo: `tar xzf {}` exited {} — git history \
                         won't seed. Install tar (macOS/Linux ship it; Windows: \
                         WSL / Git Bash).",
                        tarball.display(),
                        s
                    );
                    tar_ok = false;
                }
                Err(e) => {
                    eprintln!(
                        "mnml --demo: could not run `tar`: {e}. Git history \
                         won't seed."
                    );
                    tar_ok = false;
                }
            }
        }
        // Swap-out-old pattern: evict the current cache_root to a
        // sibling `.old.<pid>` FIRST, then rename staging into place.
        // POSIX rename(2) only replaces an *empty* directory — the
        // prior version pointed it at a populated cache_root and
        // ENOTEMPTY-failed on every refresh after the first (I'd
        // misread the rename semantics). Works uniformly on Unix +
        // Windows; a concurrent reader mid-swap still sees a
        // consistent tree (either via `.old.<pid>` briefly, or the
        // new one). Narrow TOCTOU remains: two concurrent processes
        // observing a stale cache can interleave their evict-renames
        // — not worth a lockfile for a demo-mode tool.
        let old = cache_root.with_extension(format!("old.{pid}"));
        let _ = std::fs::remove_dir_all(&old);
        if cache_root.exists() {
            std::fs::rename(&cache_root, &old).map_err(|e| format!("evict old demo cache: {e}"))?;
        }
        std::fs::rename(&staging, &cache_root).map_err(|e| format!("swap demo cache: {e}"))?;
        let _ = std::fs::remove_dir_all(&old);
        // Only stamp on full success — a broken tar shouldn't cache
        // as "done" and prevent the next launch from retrying.
        if tar_ok {
            let _ = std::fs::write(&stamp, "");
        }
    }
    Ok(cache_root)
}

/// Walk `root` recursively and return the newest mtime found. Skips
/// entries we can't stat (permissions, races). Cheap for the demo
/// workspace (~30 files); don't call on a huge tree.
fn max_mtime_recursive(root: &Path) -> std::io::Result<std::time::SystemTime> {
    let mut best = std::fs::metadata(root)?.modified()?;
    for entry in std::fs::read_dir(root)? {
        let Ok(entry) = entry else { continue };
        let Ok(ft) = entry.file_type() else { continue };
        if ft.is_dir() {
            if let Ok(m) = max_mtime_recursive(&entry.path())
                && m > best
            {
                best = m;
            }
        } else if let Ok(m) = entry.metadata().and_then(|m| m.modified())
            && m > best
        {
            best = m;
        }
    }
    Ok(best)
}

fn copy_dir_recursive(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if ft.is_dir() {
            std::fs::create_dir_all(&to)?;
            copy_dir_recursive(&from, &to)?;
        } else if ft.is_file() {
            std::fs::copy(&from, &to)?;
        } else {
            // Symlink or other special entry — signal skip so a future
            // addition to demo/workspace/ doesn't silently vanish.
            eprintln!(
                "mnml --demo: skipping non-regular file {} (only files + dirs are copied)",
                from.display()
            );
        }
    }
    Ok(())
}

/// TCP-probe `localhost:7071` — the mock server's port. Cheap check
/// before we try to spawn a duplicate. Doesn't distinguish "our
/// server" from "someone else on 7071" — best-effort; a wrong
/// listener leaves integration panes hitting the wrong service.
fn mock_server_reachable() -> bool {
    use std::net::{SocketAddr, TcpStream};
    use std::time::Duration;
    let addr: SocketAddr = "127.0.0.1:7071".parse().unwrap();
    TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok()
}

/// Spawn `demo/server/server.py` in the background. Returns whether
/// the spawn succeeded — the caller surfaces failure as a toast so
/// the user isn't left staring at empty integration panes wondering
/// why. Fire-and-forget after that: the child outlives mnml, which
/// is fine because the next `--demo` launch reuses it via the port
/// probe.
fn spawn_mock_server_background() -> bool {
    let script = std::env::var_os("MNML_DEMO_SERVER")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("demo/server/server.py"));
    if !script.is_file() {
        eprintln!("mnml --demo: mock server not found at {}", script.display());
        return false;
    }
    // `python3` on Unix, `python` on Windows (typical). Try each.
    for interp in ["python3", "python"] {
        if std::process::Command::new(interp)
            .arg(&script)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .is_ok()
        {
            return true;
        }
    }
    false
}

// ───────────────────────── TUI / headless ─────────────────────────

struct TuiArgs {
    workspace: PathBuf,
    headless: bool,
    input_style: Option<String>,
    ascii: bool,
    config_path: Option<PathBuf>,
    startup_picker: bool,
    /// Sandbox mode: launched via `./run.sh sandbox` in a tempdir
    /// with `$HOME` + `$XDG_CONFIG_HOME` redirected. mnml treats
    /// this as first-launch (welcome overlay fires, empty
    /// integrations dir, no session to restore). Adds a persistent
    /// banner reminding the user their real config is safe.
    sandbox: bool,
    /// After startup, dispatch `view.activity_<name>` to open a
    /// specific activity-bar section — e.g. `--show integrations`
    /// lands the user on the Integrations panel. Skipped if the
    /// command id doesn't resolve.
    show_panel: Option<String>,
    /// Demo mode: point mnml at the bundled `demo/workspace/`
    /// (populated Notely / Bloom Labs sample repo with fixtures for
    /// jira / bitbucket / github). If a mock API server isn't
    /// already running on `localhost:7071`, spawn `demo/server/server.py`
    /// in the background so the integration panes render populated
    /// data. Used for screenshots + demo videos; real config is
    /// never touched.
    demo: bool,
}

fn parse_tui_args(argv: Vec<String>) -> Result<TuiArgs, String> {
    let mut workspace: Option<PathBuf> = None;
    let mut headless = false;
    let mut input_style = None;
    let mut ascii = false;
    let mut config_path = None;
    let mut startup_picker = false;
    let mut no_workspace = false;
    let mut sandbox = false;
    let mut show_panel: Option<String> = None;
    let mut demo = false;

    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--headless" => headless = true,
            "--ascii" => ascii = true,
            "--input" => {
                input_style = Some(
                    it.next()
                        .ok_or("--input needs a value (vim|standard)".to_string())?,
                );
            }
            "--config" => {
                config_path = Some(PathBuf::from(
                    it.next().ok_or("--config needs a path".to_string())?,
                ));
            }
            "--startup-picker" => startup_picker = true,
            "--no-workspace" => no_workspace = true,
            "--sandbox" => sandbox = true,
            "--demo" => demo = true,
            "--show" => {
                show_panel = Some(
                    it.next()
                        .ok_or("--show needs a panel name (e.g. integrations)".to_string())?,
                );
            }
            "-h" | "--help" => {
                println!(
                    "mnml — NvChad-style terminal IDE\n\n\
                     usage:\n  \
                       mnml [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless] [--startup-picker] [--no-workspace] [--sandbox] [--demo] [--show PANEL]\n  \
                       mnml run FILE [--env NAME] [--workspace DIR]\n\n\
                     flags:\n  \
                       --startup-picker      show a JetBrains-style chooser overlay on launch\n                                         (also enabled by MNML_STARTUP_PICKER=1)\n  \
                       --no-workspace        land in the empty-state ($HOME) instead of resolving\n                                         [startup] default_workspace; used by the .app icon\n                                         launcher so clicking the icon doesn't auto-open a folder\n  \
                       --sandbox             show a persistent \"sandbox mode\" banner. Meant to be\n                                         paired with `./run.sh sandbox`, which redirects HOME +\n                                         XDG_CONFIG_HOME to a tempdir so your real config stays\n                                         untouched. Use to see what a brand-new user would see.\n                                         If HOME isn't actually redirected the banner downgrades\n                                         to a warning so you don't get a false safety promise.\n  \
                       --show PANEL          after startup, focus the given activity-bar section\n                                         (e.g. `--show integrations`). PANEL is any suffix of\n                                         `view.activity_<panel>` — integrations, sessions, agents,\n                                         http, explorer, search, debug, notes.\n"
                );
                std::process::exit(0);
            }
            s if s.starts_with('-') => return Err(format!("unknown flag: {s}")),
            s => {
                if workspace.is_some() {
                    return Err(format!("unexpected extra argument: {s}"));
                }
                workspace = Some(PathBuf::from(s));
            }
        }
    }

    // `--demo` overrides workspace resolution — always boots against
    // a per-user cache copy of the bundled `demo/workspace/`, seeded
    // + git-history-populated by `resolve_demo_workspace()`. Any
    // user-supplied workspace is ignored (they can bypass with the
    // `$MNML_DEMO_WORKSPACE` env override for fixture iteration).
    // Booting from a cache copy — not the source tree — keeps the
    // mnml checkout clean if the user autosaves or edits during a
    // screenshot session.
    if demo {
        let ws = resolve_demo_workspace().map_err(|e| format!("--demo: {e}"))?;
        // Trust the bundled demo fixture. Its integration overrides
        // carry `[env]` blocks (pointing Jira / Bitbucket / GitHub at
        // the local mock server), which the workspace-trust scanner
        // correctly reads as executable-adjacent claims — so without
        // this, `--demo` would boot with those overrides suppressed
        // and the demo would try to reach the real Atlassian.
        //
        // Recording a real trust entry rather than adding a
        // "sandbox means trusted" bypass: `--sandbox` can be pointed
        // at ANY directory, so a blanket exemption would hand an
        // untrusted repo the very execution path the gate exists to
        // close. This trusts one specific directory that mnml ships
        // and copies itself. In `--demo` the store lives under the
        // sandboxed HOME, so the entry is throwaway too.
        let claims = mnml::workspace_trust::scan(&ws);
        if !claims.is_empty() {
            let fp = mnml::workspace_trust::fingerprint(&claims);
            if let Err(e) = mnml::workspace_trust::trust(&ws, &fp) {
                eprintln!("mnml: --demo could not trust the demo workspace: {e}");
            }
        }
        workspace = Some(ws);
    }

    // Workspace resolution order:
    //   1. Positional `[WORKSPACE]` arg (explicit user intent)
    //   2. `--no-workspace` flag → $HOME (the empty-state landing).
    //      Set by the icon launcher so clicking the app icon doesn't
    //      auto-open the default workspace; user picks from the
    //      "Open file / Open folder / Open default workspace" panel.
    //   3. `[startup] default_workspace` from `~/.config/mnml/config.toml`
    //      — scaffold the folder + a starter README if missing so first
    //      launch lands on a usable scratch workspace
    //   4. `current_dir()` (legacy fallback)
    let workspace = workspace
        .or_else(|| {
            if no_workspace {
                // Force the empty-state landing by resolving to
                // $HOME. `is_empty_workspace` / `is_home_workspace`
                // both detect this and render the landing panel.
                return std::env::var_os("HOME").map(PathBuf::from);
            }
            let p = mnml::config::resolve_default_workspace()?;
            if !p.exists()
                && let Err(e) = mnml::config::scaffold_workspace(&p)
            {
                eprintln!(
                    "mnml: default_workspace {} couldn't be scaffolded ({e}); falling back to cwd",
                    p.display()
                );
                return None;
            }
            Some(p)
        })
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let workspace = workspace
        .canonicalize()
        .map_err(|e| format!("cannot open workspace {}: {e}", workspace.display()))?;
    Ok(TuiArgs {
        workspace,
        headless,
        input_style,
        ascii,
        config_path,
        startup_picker,
        sandbox,
        show_panel,
        demo,
    })
}

fn run_tui(argv: Vec<String>) -> ExitCode {
    let args = match parse_tui_args(argv) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("mnml: {e}");
            return ExitCode::FAILURE;
        }
    };

    let mut config = Config::load(args.config_path.as_deref(), &args.workspace);
    if let Some(style) = args.input_style {
        config.editor.input_style = style;
    }
    if args.ascii {
        config.ui.ascii_icons = true;
    }
    if config.ui.theme != "onedark" && mnml::ui::theme::set(&config.ui.theme).is_none() {
        eprintln!(
            "mnml: unknown theme {:?} — using onedark (try one of: {})",
            config.ui.theme,
            mnml::ui::theme::names().join(", ")
        );
    }
    // Materialise the resolved active theme (even the default) to
    // `~/.config/mnml/current-theme.toml` so the family — mixr, the
    // `mnml-*` integrations — can follow mnml's colours from one source of truth.
    mnml::ui::theme::write_current(&mnml::ui::theme::cur());

    // Inject demo-mode integration env vars BEFORE App::new (which triggers
    // maybe_refresh_marketplace_on_startup + other background threads
    // that call reqwest, which reads proxy env vars concurrently). Doing
    // set_var here — single-threaded, no snapshots taken yet — sidesteps
    // the UB the safety contract cares about. See the block's own SAFETY
    // comment. Gated on !args.headless so `.test` E2E scripts don't
    // accidentally set the vars in the test process.
    //
    // Also strips the user's `[[workspaces]]` from the loaded config
    // so demo screenshots don't show real workspace favorites in the
    // tree rail alongside the demo tree. Their actual config file on
    // disk is untouched — this is just the in-memory copy for this
    // process. Same rationale for `[[bitbucket.repos]]` and any other
    // config that would surface real work.
    if args.demo && !args.headless {
        // Task #933 — demo env vars now flow through each
        // `demo/workspace/.mnml/integrations/<id>.override.toml`'s
        // `[env]` block (see `IntegrationManifestOverride`) instead
        // of a process-global `unsafe std::env::set_var` here.
        // Workspace init runs single-threaded so the config-workspace
        // wipe still stays here — that's not env-var-set territory.
        config.workspaces.clear();
    }

    let explicit_config_path = args.config_path.clone();
    let mut app = match App::new(args.workspace, config) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("mnml: {e}");
            return ExitCode::FAILURE;
        }
    };
    app.explicit_config_path = explicit_config_path;
    // Warm the Nerd Fonts glyph catalog off the render thread — ~30ms
    // to parse the bundled 533KB JSON into a HashMap. Done eagerly so
    // the first `integrations.icon_picker` open feels instant instead
    // of taking a beat while the catalog builds.
    std::thread::spawn(|| {
        let _ = mnml::nerd_glyphs::catalog();
    });
    // Re-open last session's buffers (no-op when [session] restore = false).
    // Sandbox mode also skips restore — the whole point is a fresh
    // "brand-new user" look, so restoring the user's real dock
    // widgets / open tabs / layout from a session.json would defeat
    // that. User report 2026-08-05: sandbox showed Note 1 / Note 2
    // from the real ~/Projects/mnml/.mnml/session.json.
    if !args.sandbox {
        app.try_restore_session();
    }
    // #878 step 2 (2026-08-19) — apply the declarative
    // `[[startup.layout]]` block, gated internally on layout-empty +
    // panes-empty so a real session restore always wins. Skip in
    // sandbox mode for the same reason session restore is skipped —
    // the sandbox wants a brand-new-user view. Not gated on --demo
    // here because `--demo` sets up its own state via
    // `--sandbox` + `apply_demo_state`; if that changes, the gate
    // inside `apply_startup_layout` still no-ops.
    if !args.sandbox {
        app.apply_startup_layout();
    }
    // Workspace trust — must come AFTER session restore + startup
    // layout so the dialog lands on top of the finished UI rather than
    // being clobbered by it. The exec keys it gates were already
    // suppressed at `Config::load` time, so nothing has run by now;
    // this only asks whether to turn them on. Silent unless the
    // workspace actually declares something executable.
    //
    // Skipped in sandbox/demo for the same reason session restore is:
    // those modes present a curated first-run view, and the demo
    // workspace's own manifests are mnml's, not a stranger's.
    if !args.sandbox {
        app.maybe_prompt_workspace_trust();
    }
    // #851 phase 3 — one-shot aggressive migration of any legacy
    // `[[ui.integration_icon]]` blocks in ~/.config/mnml/config.toml
    // into `<id>.override.toml` sidecars. Idempotent — no-op on
    // installs that have never had legacy blocks (which is most of
    // them after the 2026-08-01 flip). Toasts on non-zero migrate
    // count so users see the change.
    // 2026-08-04 — one-shot cleanup for retired-id manifests left
    // behind by the buggy pre-c7d781b7 migration. Silent unless
    // it actually finds files (rare).
    let cleaned = mnml::app::discovery::cleanup_retired_id_manifests();
    if cleaned > 0 {
        app.toast(format!(
            "cleaned up {cleaned} retired-integration manifest file(s) (slack/bitbucket/etc.)"
        ));
    }
    match mnml::app::discovery::migrate_legacy_integration_icon_blocks() {
        Ok((0, _)) => {}
        Ok((n, warns)) => {
            app.toast(format!(
                "migrated {n} legacy [[ui.integration_icon]] block(s) → override sidecars \
                 (backup in ~/.config/mnml/backups/)"
            ));
            for w in warns {
                app.toast(format!("migrate warn: {w}"));
            }
        }
        Err(e) => app.toast(format!("migrate: {e}")),
    }
    // #867 — per-user first-run: portable-vs-normal data layout choice.
    // Fires exactly once per user (guarded by `.user-welcomed` in
    // data_root). If the user picks Portable, this immediately requests
    // a restart so `data_root()`'s cached probe re-resolves against the
    // freshly-created `mnml-data/`. Ordering matters: this runs BEFORE
    // the workspace welcome overlay so we don't stack two prompts.
    // R10 keyboard SEV-1 (2026-08-11) — headless auto-launch left the
    // wizard hidden forever behind the portable-choice prompt, which
    // fires ahead of the wizard and blocks its paint via the
    // `app.prompt.is_some()` deferral in `first_launch_overlay::draw`.
    // Interactive users dismiss the prompt with Enter/click; headless
    // drivers can't, so the wizard sat blocked. Skip the interactive
    // prompt in headless — a headless caller can still choose portable
    // via `mnml.choose_data_layout` on the palette.
    if !args.headless {
        app.maybe_show_portable_choice_on_launch();
    }
    // First-launch onboarding overlay. If the user has never dismissed it
    // in this workspace (no `.mnml/.welcomed` marker), open it.
    app.maybe_show_welcome_on_launch();
    // #1205 — launch-time tofu check: toast when any integration
    // glyph is certain to render as `?` (mnml PUA not baked, or a
    // force-routed codepoint the target font lacks).
    app.glyph_audit_startup_check();
    // Global first-launch wizard — one-time-ever setup (AI backend,
    // input style, Nerd Font check, tool installs). Gated by
    // `[ui] first_launch_complete`. Runs AFTER the per-workspace
    // welcome so the welcome is the first thing users see when
    // they open an unfamiliar workspace, but the wizard runs
    // (once ever) BEFORE they've configured anything.
    if !app.config.ui.first_launch_complete {
        app.open_first_launch();
    }
    // Task #975 (2026-08-17) — deprecation notice when a user has BOTH
    // the new `[ai.routing.claude]` key AND the legacy `[ai] backend`.
    // The new key silently wins in `configured_backend`; surface the
    // fact so the legacy line can be deleted at leisure. Toast +
    // eprintln so it lands in both the visible UI and any log tail.
    if mnml::ai::has_legacy_and_new_claude(&app.config.ai) {
        let msg = "[ai] backend is deprecated — [ai.routing.claude] backend wins. \
                   Delete the legacy key to silence this notice.";
        eprintln!("mnml: {msg}");
        app.toast(msg);
    }
    // If we just came back from `app.reset_to_defaults`, the fresh
    // ~/.config/mnml/ has a `.last-reset-from` marker pointing at
    // the backup — surface it as a persistent toast with the restore
    // one-liner so the user isn't left wondering where their config went.
    app.maybe_show_reset_toast();
    // Interactive-only: if the on-disk marketplace cache is missing
    // or past its TTL, kick off a silent background refresh so
    // catalog changes reconcile without needing manual ⟳. Lives in
    // `main.rs` (not `App::new`) so the test suite / headless / E2E
    // never touches the network.
    app.maybe_refresh_marketplace_on_startup();
    // Startup workspace picker (--startup-picker / MNML_STARTUP_PICKER=1).
    if mnml::app::App::want_startup_picker(args.startup_picker) {
        app.startup_picker = Some(mnml::app::StartupPickerState::default());
    }
    // Sandbox mode banner + optional panel focus. The `./run.sh sandbox`
    // wrapper redirects $HOME + $XDG_CONFIG_HOME to a tempdir BEFORE
    // launching mnml — this flag just signals "paint the banner." We
    // verify HOME actually points at a tempdir before promising safety
    // (reviewer 2026-08-03): a bare `mnml --sandbox` invocation without
    // the wrapper would happily paint "sandboxed" while writing to the
    // real ~/.config/mnml/. When we detect that gap, the banner
    // downgrades to a warning so the user isn't lied to.
    if args.sandbox {
        if home_is_sandbox_tempdir() {
            app.toast_persistent(
                "sandbox-mode",
                "SANDBOX MODE — real config safe. Nothing here persists. \
                 Exit to discard.",
                mnml::app::ToastLevel::Info,
            );
        } else {
            app.toast_persistent(
                "sandbox-mode",
                "--sandbox flag set but $HOME is NOT redirected to a tempdir. \
                 This session will touch your real ~/.config/mnml/. Use \
                 `./run.sh sandbox` for a true sandbox.",
                mnml::app::ToastLevel::Warn,
            );
        }
    }
    if let Some(panel) = &args.show_panel {
        let cmd_id = format!("view.activity_{panel}");
        // Fire via the shared command registry so unknown names get a
        // toast rather than silently no-oping. Doesn't kick until after
        // the tick loop starts; harmless if the id doesn't resolve.
        mnml::command::run(&cmd_id, &mut app);
    }
    // Demo mode banner + mock-server autospawn. Real integrations
    // never see demo data outside this workspace (per-workspace
    // manifest overrides in demo/workspace/.mnml/integrations/*.override.toml
    // point at localhost:7071; without --demo those files aren't in
    // the resolution path). Gated on `!args.headless` so `.test` E2E
    // scripts adding `--demo` don't accidentally bind a listener or
    // fire persistent toasts.
    if args.demo && !args.headless {
        app.toast_persistent(
            "demo-mode",
            "DEMO MODE — Notely (Bloom Labs) sample workspace. Integrations \
             hit localhost:7071 (mock). Real config safe.",
            mnml::app::ToastLevel::Info,
        );
        // Env injection has already happened above (before App::new).
        if !mock_server_reachable() {
            let spawned = spawn_mock_server_background();
            if !spawned {
                // Toast the failure so the user isn't left wondering why
                // integration panes are stuck on "connection refused" —
                // Windows without python installed is the common case.
                app.toast_persistent(
                    "demo-mock-failed",
                    "Demo mode: could not spawn mock server. Install python3 \
                     and re-run, or start `demo/server/server.py` by hand.",
                    mnml::app::ToastLevel::Warn,
                );
            }
        }
    }
    // Background GitHub-releases probe. Skipped in headless (no
    // toast surface). Notification-only — no in-app installer.
    if !args.headless {
        app.update_check = Some(mnml::update_check::UpdateCheck::spawn());
    }

    let result = if args.headless {
        mnml::headless::run(app)
    } else {
        mnml::tui::run(app)
    };

    match result {
        // 75 (EX_TEMPFAIL) is the agreed "rebuild + relaunch me" code that `run.sh` loops on.
        Ok(true) => ExitCode::from(75),
        Ok(false) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("mnml: {e}");
            ExitCode::FAILURE
        }
    }
}

// ───────────────────────── `mnml run FILE` ─────────────────────────

fn run_subcommand(argv: Vec<String>) -> ExitCode {
    let mut file: Option<PathBuf> = None;
    let mut env_name: Option<String> = None;
    let mut workspace: Option<PathBuf> = None;

    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--env" | "-e" => match it.next() {
                Some(v) => env_name = Some(v),
                None => {
                    eprintln!("mnml run: --env needs a value");
                    return ExitCode::FAILURE;
                }
            },
            "--workspace" | "-w" => match it.next() {
                Some(v) => workspace = Some(PathBuf::from(v)),
                None => {
                    eprintln!("mnml run: --workspace needs a path");
                    return ExitCode::FAILURE;
                }
            },
            "-h" | "--help" => {
                println!("usage: mnml run FILE [--env NAME] [--workspace DIR]");
                return ExitCode::SUCCESS;
            }
            s if s.starts_with('-') => {
                eprintln!("mnml run: unknown flag: {s}");
                return ExitCode::FAILURE;
            }
            s => {
                if file.is_some() {
                    eprintln!("mnml run: unexpected extra argument: {s}");
                    return ExitCode::FAILURE;
                }
                file = Some(PathBuf::from(s));
            }
        }
    }

    let Some(file) = file else {
        eprintln!("usage: mnml run FILE [--env NAME] [--workspace DIR]");
        return ExitCode::FAILURE;
    };
    match do_run(&file, env_name.as_deref(), workspace.as_deref()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("mnml run: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Shared `FILE [--env NAME] [--workspace DIR]` parsing for `run` / `chain`.
fn parse_file_env_ws(
    argv: Vec<String>,
    usage: &str,
) -> Result<(PathBuf, Option<String>, Option<PathBuf>), String> {
    let (mut file, mut env_name, mut workspace) = (None, None, None);
    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--env" | "-e" => env_name = Some(it.next().ok_or("--env needs a value")?),
            "--workspace" | "-w" => {
                workspace = Some(PathBuf::from(it.next().ok_or("--workspace needs a path")?))
            }
            "-h" | "--help" => return Err(format!("__help__{usage}")),
            s if s.starts_with('-') => return Err(format!("unknown flag: {s}")),
            s if file.is_none() => file = Some(PathBuf::from(s)),
            s => return Err(format!("unexpected extra argument: {s}")),
        }
    }
    Ok((file.ok_or("missing FILE")?, env_name, workspace))
}

fn chain_subcommand(argv: Vec<String>) -> ExitCode {
    let usage = "usage: mnml chain run FILE [--env NAME] [--workspace DIR]";
    let (file, env_name, workspace) = match parse_file_env_ws(argv, usage) {
        Ok(t) => t,
        Err(e) if e.starts_with("__help__") => {
            println!("{}", &e["__help__".len()..]);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("mnml chain: {e}\n{usage}");
            return ExitCode::FAILURE;
        }
    };
    // api-workflow SEV-2 2026-07-11: walk up from the chain file's
    // directory to find a `.mnml/` marker (same rationale as
    // `do_run` in the integration `run` command). Without this,
    // `mnml chain run .mnml/chains/oauth.chain.json` from the
    // project root defaulted the workspace to `.mnml/chains/` and
    // couldn't find `auth/login.curl` (which resolves against
    // `<workspace>/.mnml/requests/`).
    let ws = workspace
        .or_else(|| {
            let start = file.parent()?;
            let mut cur: &Path = start;
            loop {
                if cur.join(".mnml").is_dir() || cur.join(".rqst").is_dir() {
                    return Some(cur.to_path_buf());
                }
                let Some(parent) = cur.parent() else {
                    break;
                };
                cur = parent;
            }
            Some(start.to_path_buf())
        })
        .unwrap_or_else(|| PathBuf::from("."));
    let mut out = String::new();
    let result = mnml::http::chain::run(&file, &ws, env_name.as_deref(), &mut out, None);
    print!("{out}");
    match result {
        Ok(()) => {
            println!("✓ chain passed");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mnml chain: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `mnml proxy --url URL [--workspace DIR] [--seconds N] [--idle-ms N]
/// [--quiet]` — headless CDP capture. Spawns headless Chrome,
/// navigates to URL, captures every Network.requestWillBeSent into
/// `<workspace>/.rqst/captured/log.jsonl`, exits on timeout or
/// network quiescence. Phase 4 of the rqst→mnml port-back —
/// covers the same surface as rqst's `rqst proxy` for headless /
/// CI / scripted captures (the in-app `http.capture_now` covers
/// the interactive case).
fn proxy_subcommand(argv: Vec<String>) -> ExitCode {
    let usage =
        "usage: mnml proxy --url URL [--workspace DIR] [--seconds N] [--idle-ms N] [--quiet]";
    let mut opts = mnml::http::proxy::Options::default();
    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--url" => match it.next() {
                Some(v) => opts.url = v,
                None => {
                    eprintln!("mnml proxy: --url needs a value");
                    return ExitCode::FAILURE;
                }
            },
            "--workspace" | "-w" => match it.next() {
                Some(v) => opts.workspace = PathBuf::from(v),
                None => {
                    eprintln!("mnml proxy: --workspace needs a path");
                    return ExitCode::FAILURE;
                }
            },
            "--seconds" => match it.next().and_then(|s| s.parse::<u64>().ok()) {
                Some(s) => opts.max_seconds = Some(s),
                None => {
                    eprintln!("mnml proxy: --seconds needs a positive integer");
                    return ExitCode::FAILURE;
                }
            },
            "--idle-ms" => match it.next().and_then(|s| s.parse::<u64>().ok()) {
                Some(ms) => opts.idle_ms = ms,
                None => {
                    eprintln!("mnml proxy: --idle-ms needs a positive integer");
                    return ExitCode::FAILURE;
                }
            },
            "--quiet" => opts.verbose = false,
            "-h" | "--help" => {
                println!("{usage}");
                return ExitCode::SUCCESS;
            }
            s => {
                eprintln!("mnml proxy: unexpected arg: {s}");
                return ExitCode::FAILURE;
            }
        }
    }
    if opts.url.trim().is_empty() {
        eprintln!("{usage}");
        return ExitCode::FAILURE;
    }
    if opts.workspace.as_path() == std::path::Path::new(".") {
        opts.workspace = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    }
    match mnml::http::proxy::run(opts) {
        Ok(n) => {
            println!("ok — {n} requests captured");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mnml proxy: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `mnml sync [--workspace DIR]` — read sources.json + regenerate
/// every swagger source's `.curl` stubs. The same operation the
/// `http.sync` palette command runs in-app, exposed as a CLI for
/// scripting / cron / one-off batches.
fn sync_subcommand(argv: Vec<String>) -> ExitCode {
    let usage = "usage: mnml sync [--workspace DIR] [--normalize]\n  reads <workspace>/.mnml/sources.json (or .rqst/sources.json) and regenerates .curl stubs per swagger source\n  --normalize / -n : swap ISO timestamps + lowercase UUIDs for {{$isoTimestamp}} / {{$uuid}}";
    let mut workspace: Option<PathBuf> = None;
    let mut normalize = false;
    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--workspace" | "-w" => match it.next() {
                Some(v) => workspace = Some(PathBuf::from(v)),
                None => {
                    eprintln!("mnml sync: --workspace needs a path");
                    return ExitCode::FAILURE;
                }
            },
            "--normalize" | "-n" => normalize = true,
            "-h" | "--help" => {
                println!("{usage}");
                return ExitCode::SUCCESS;
            }
            s => {
                eprintln!("mnml sync: unexpected arg: {s}");
                return ExitCode::FAILURE;
            }
        }
    }
    let ws =
        workspace.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    match mnml::http::sources::run_sync_with_normalize(&ws, normalize) {
        Ok((trace, total)) => {
            print!("{trace}");
            println!("ok — {total} stubs written");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mnml sync: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `mnml sync-check [--workspace DIR]` — dry-run drift check.
/// Same logic as the `http.sync_check` palette command; writes
/// the drift trace to stdout instead of a scratch pane.
fn sync_check_subcommand(argv: Vec<String>) -> ExitCode {
    let usage = "usage: mnml sync-check [--workspace DIR] [--normalize]\n  reports added/removed/changed .curl files without writing anything\n  --normalize / -n : compare against normalized bodies (see `mnml sync --help`)";
    let mut workspace: Option<PathBuf> = None;
    let mut normalize = false;
    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--workspace" | "-w" => match it.next() {
                Some(v) => workspace = Some(PathBuf::from(v)),
                None => {
                    eprintln!("mnml sync-check: --workspace needs a path");
                    return ExitCode::FAILURE;
                }
            },
            "--normalize" | "-n" => normalize = true,
            "-h" | "--help" => {
                println!("{usage}");
                return ExitCode::SUCCESS;
            }
            s => {
                eprintln!("mnml sync-check: unexpected arg: {s}");
                return ExitCode::FAILURE;
            }
        }
    }
    let ws =
        workspace.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    match mnml::http::sources::check_sync_with_normalize(&ws, normalize) {
        Ok((trace, drift)) => {
            print!("{trace}");
            if drift == 0 {
                println!("ok — no drift");
                ExitCode::SUCCESS
            } else {
                println!("drift — {drift} file(s) differ");
                // Non-zero exit code so CI can `mnml sync-check`
                // as a gate. Distinct from FAILURE (2) so scripts
                // can distinguish "drift found" from "the tool
                // crashed".
                ExitCode::from(2)
            }
        }
        Err(e) => {
            eprintln!("mnml sync-check: {e}");
            ExitCode::FAILURE
        }
    }
}

fn discover_subcommand(argv: Vec<String>) -> ExitCode {
    let usage = "usage: mnml discover SPEC [--out DIR] [--base-url URL] [--normalize] [--edge-cases] [--force]\n  SPEC is a local OpenAPI/Swagger JSON file or an http(s):// URL\n  --force overwrites existing .curl files (default: skip existing)";
    let (mut spec, mut out, mut base_url) = (None::<String>, None::<PathBuf>, None::<String>);
    let mut normalize = false;
    let mut edge_cases = false;
    let mut force = false;
    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--out" | "-o" => match it.next() {
                Some(v) => out = Some(PathBuf::from(v)),
                None => {
                    eprintln!("mnml discover: --out needs a path");
                    return ExitCode::FAILURE;
                }
            },
            "--base-url" => match it.next() {
                Some(v) => base_url = Some(v),
                None => {
                    eprintln!("mnml discover: --base-url needs a value");
                    return ExitCode::FAILURE;
                }
            },
            "--normalize" | "-n" => normalize = true,
            "--edge-cases" | "-e" => edge_cases = true,
            "--force" | "-f" => force = true,
            "-h" | "--help" => {
                println!("{usage}");
                return ExitCode::SUCCESS;
            }
            s if s.starts_with('-') => {
                eprintln!("mnml discover: unknown flag: {s}");
                return ExitCode::FAILURE;
            }
            s if spec.is_none() => spec = Some(s.to_string()),
            s => {
                eprintln!("mnml discover: unexpected extra argument: {s}");
                return ExitCode::FAILURE;
            }
        }
    }
    let Some(spec) = spec else {
        eprintln!("{usage}");
        return ExitCode::FAILURE;
    };
    let out = out.unwrap_or_else(|| PathBuf::from(".mnml/requests"));
    match mnml::http::discover::run(&mnml::http::discover::Options {
        spec,
        out: out.clone(),
        base_url,
        normalize,
        edge_cases,
        force,
    }) {
        Ok((written, skipped)) => {
            if skipped > 0 {
                println!(
                    "wrote {written} .curl stub(s) under {} ({skipped} existing skipped — use --force to overwrite)",
                    out.display()
                );
            } else {
                println!("wrote {written} .curl stub(s) under {}", out.display());
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mnml discover: {e}");
            ExitCode::FAILURE
        }
    }
}

fn do_run(file: &Path, env_name: Option<&str>, workspace: Option<&Path>) -> Result<(), String> {
    use mnml::http::{self, template::EnvSet};

    let raw = std::fs::read_to_string(file)
        .map_err(|e| format!("cannot read {}: {e}", file.display()))?;

    // Workspace for env-file resolution: explicit, else walk up from
    // the file's directory looking for a `.mnml/` or `.rqst/` marker.
    // Prior behavior defaulted to the file's PARENT dir, which broke
    // `mnml run .mnml/requests/health.curl` from the project root
    // because the workspace became `.mnml/requests/` — no env files
    // there. api-workflow SEV-2 2026-07-11.
    let ws = workspace
        .map(Path::to_path_buf)
        .or_else(|| {
            let start = file.parent()?;
            let mut cur: &Path = start;
            loop {
                if cur.join(".mnml").is_dir() || cur.join(".rqst").is_dir() {
                    return Some(cur.to_path_buf());
                }
                let Some(parent) = cur.parent() else {
                    break;
                };
                cur = parent;
            }
            Some(start.to_path_buf())
        })
        .unwrap_or_else(|| PathBuf::from("."));
    // api-round-12 SEV-1 2026-07-14 — was 2-tier `EnvSet::select`
    // (no config_default, no literal "dev" fallback). In a
    // `.mnml`-only workspace with no override / $MNML_ENV, it
    // returned empty and every `{{VAR}}` stayed literal, killing
    // `mnml run file.http` unless the user remembered `--env dev`.
    // Route through the shared 5-tier resolver so CLI matches App.
    let mut env = EnvSet::select_with_full_fallback(&ws, env_name, None);
    if let Some(name) = &env.name {
        eprintln!("env: {name}");
    }

    // Parse the request (its url/headers/body still hold `{{vars}}`), then the
    // `@`-directives. `apply_pre` runs `@set-header` / `@set-env` before we
    // expand the request's own fields, so `{{NAME}}` can reference `@set-env`s.
    // api-round-10 SEV-2 2026-07-12 — pass the file's parent as the
    // base_dir so `-F name=@relpath` uploads resolve against the
    // request file's directory, not the process CWD. Matches the
    // Request pane's behavior post-round-8.
    let script = http::script::parse(&raw);
    let base_dir = file.parent();
    let mut req = http::parse_with_base(&raw, base_dir).map_err(|e| e.to_string())?;
    http::script::apply_pre(&script, &mut req, &mut env);

    let mut missing: Vec<String> = Vec::new();
    let mut collect = |s: &str| {
        for m in http::template::unresolved(s, &env) {
            if !missing.contains(&m) {
                missing.push(m);
            }
        }
    };
    collect(&req.url);
    for (_, v) in &req.headers {
        collect(v);
    }
    if let Some(b) = &req.body {
        collect(b);
    }
    if !missing.is_empty() {
        eprintln!("warning: unresolved variables: {}", missing.join(", "));
    }
    req.url = http::template::expand(&req.url, &env);
    for (_, v) in &mut req.headers {
        *v = http::template::expand(v, &env);
    }
    if let Some(b) = &mut req.body {
        *b = http::template::expand(b, &env);
    }

    println!("→ {} {}", req.method, req.url);
    let send_result = http::send(&req);
    // api-workflow SEV-2 2026-07-11: CLI `mnml run` used to skip
    // history.jsonl entirely (only the TUI send path called
    // history::append). Log both success and failure so
    // `:http.history` in the TUI can recall CLI runs and
    // ad-hoc `jq` queries over `.rqst/history.jsonl` see them.
    // Global mirror (~/.config/mnml/history-global.jsonl) makes
    // cross-workspace search work too.
    match &send_result {
        Ok(resp) => {
            let body_bytes = resp.body.len();
            http::history::append_with_global_mirror(
                &ws,
                &http::history::Entry {
                    method: &req.method,
                    url: &req.url,
                    status: Some(resp.status),
                    duration_ms: Some(resp.elapsed.as_millis()),
                    body_bytes: Some(body_bytes),
                    error: None,
                    headers: Some(&req.headers),
                    request_body: req.body.as_deref(),
                },
            );
        }
        Err(e) => {
            http::history::append_with_global_mirror(
                &ws,
                &http::history::Entry {
                    method: &req.method,
                    url: &req.url,
                    status: None,
                    duration_ms: None,
                    body_bytes: None,
                    error: Some(e.as_str()),
                    headers: Some(&req.headers),
                    request_body: req.body.as_deref(),
                },
            );
        }
    }
    let resp = send_result?;
    println!(
        "← {} {}  ({} ms)",
        resp.status,
        resp.status_text,
        resp.elapsed.as_millis()
    );
    for name in ["content-type", "content-length", "location", "x-request-id"] {
        if let Some(v) = resp.header(name) {
            println!("  {name}: {v}");
        }
    }
    println!();
    if resp.looks_like_json() {
        match serde_json::from_str::<serde_json::Value>(&resp.body) {
            Ok(v) => println!(
                "{}",
                serde_json::to_string_pretty(&v).unwrap_or(resp.body.clone())
            ),
            Err(_) => println!("{}", resp.body),
        }
    } else {
        println!("{}", resp.body);
    }

    // `@assert` directives — print pass/fail; a failure fails the run.
    let mut failed = 0usize;
    if !script.assertions.is_empty() {
        println!();
        for r in http::script::run_assertions(&script, resp.status, &resp.headers, &resp.body) {
            if r.passed {
                println!("  ✓ {}", r.label);
            } else {
                failed += 1;
                match &r.detail {
                    Some(d) => println!("  ✗ {} — {d}", r.label),
                    None => println!("  ✗ {}", r.label),
                }
            }
        }
    }

    // `@capture` directives — show what got captured (into the env, for chains).
    let captured = http::script::apply_captures(&script, &resp.headers, &resp.body, &mut env);
    if !captured.is_empty() {
        println!();
        for (name, value) in &captured {
            println!("  ⇒ {name} = {value}");
        }
    }

    if failed > 0 {
        return Err(format!("{failed} assertion(s) failed"));
    }
    // With no assertions, a non-2xx is the failure signal.
    if script.assertions.is_empty() && !(200..300).contains(&resp.status) {
        return Err(format!("HTTP {}", resp.status));
    }
    Ok(())
}
