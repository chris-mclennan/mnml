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
        _ => run_tui(args.collect()),
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

// ───────────────────────── TUI / headless ─────────────────────────

struct TuiArgs {
    workspace: PathBuf,
    headless: bool,
    input_style: Option<String>,
    ascii: bool,
    config_path: Option<PathBuf>,
    startup_picker: bool,
}

fn parse_tui_args(argv: Vec<String>) -> Result<TuiArgs, String> {
    let mut workspace: Option<PathBuf> = None;
    let mut headless = false;
    let mut input_style = None;
    let mut ascii = false;
    let mut config_path = None;
    let mut startup_picker = false;
    let mut no_workspace = false;

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
            "-h" | "--help" => {
                println!(
                    "mnml — NvChad-style terminal IDE\n\n\
                     usage:\n  \
                       mnml [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless] [--startup-picker] [--no-workspace]\n  \
                       mnml run FILE [--env NAME] [--workspace DIR]\n\n\
                     flags:\n  \
                       --startup-picker      show a JetBrains-style chooser overlay on launch\n                                         (also enabled by MNML_STARTUP_PICKER=1)\n  \
                       --no-workspace        land in the empty-state ($HOME) instead of resolving\n                                         [startup] default_workspace; used by the .app icon\n                                         launcher so clicking the icon doesn't auto-open a folder\n"
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
    // `mnml-*` siblings — can follow mnml's colours from one source of truth.
    mnml::ui::theme::write_current(&mnml::ui::theme::cur());

    let mut app = match App::new(args.workspace, config) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("mnml: {e}");
            return ExitCode::FAILURE;
        }
    };
    // Re-open last session's buffers (no-op when [session] restore = false).
    app.try_restore_session();
    // First-launch onboarding overlay. If the user has never dismissed it
    // in this workspace (no `.mnml/.welcomed` marker), open it.
    app.maybe_show_welcome_on_launch();
    // Startup workspace picker (--startup-picker / MNML_STARTUP_PICKER=1).
    if mnml::app::App::want_startup_picker(args.startup_picker) {
        app.startup_picker = Some(mnml::app::StartupPickerState::default());
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
    let ws = workspace
        .or_else(|| file.parent().map(Path::to_path_buf))
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
    let usage = "usage: mnml discover SPEC [--out DIR] [--base-url URL] [--normalize] [--edge-cases]\n  SPEC is a local OpenAPI/Swagger JSON file or an http(s):// URL";
    let (mut spec, mut out, mut base_url) = (None::<String>, None::<PathBuf>, None::<String>);
    let mut normalize = false;
    let mut edge_cases = false;
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
    }) {
        Ok(n) => {
            println!("wrote {n} .curl stub(s) under {}", out.display());
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

    // Workspace for env-file resolution: explicit, else the file's directory.
    let ws = workspace
        .map(Path::to_path_buf)
        .or_else(|| file.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."));
    let mut env = EnvSet::select(&ws, env_name);
    if let Some(name) = &env.name {
        eprintln!("env: {name}");
    }

    // Parse the request (its url/headers/body still hold `{{vars}}`), then the
    // `@`-directives. `apply_pre` runs `@set-header` / `@set-env` before we
    // expand the request's own fields, so `{{NAME}}` can reference `@set-env`s.
    let script = http::script::parse(&raw);
    let mut req = http::parse(&raw).map_err(|e| e.to_string())?;
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
