//! Binary entry. Subcommand dispatch:
//!   - `mnml [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless]`
//!     — the TUI (or the headless virtual-screen + file-IPC harness with `--headless`).
//!   - `mnml run FILE [--env NAME] [--workspace DIR]` — send one `.curl` / `.http`
//!     request, after `{{VAR}}` substitution from `.mnml/env/<NAME>.env`.
//!
//! Later phases add `mnml chain run FILE`, `mnml test GLOB`, `mnml ipc …`.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use mnml::app::App;
use mnml::config::Config;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1).peekable();
    if matches!(args.peek().map(String::as_str), Some("run")) {
        args.next();
        return run_subcommand(args.collect());
    }
    run_tui(args.collect())
}

// ───────────────────────── TUI / headless ─────────────────────────

struct TuiArgs {
    workspace: PathBuf,
    headless: bool,
    input_style: Option<String>,
    ascii: bool,
    config_path: Option<PathBuf>,
}

fn parse_tui_args(argv: Vec<String>) -> Result<TuiArgs, String> {
    let mut workspace: Option<PathBuf> = None;
    let mut headless = false;
    let mut input_style = None;
    let mut ascii = false;
    let mut config_path = None;

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
            "-h" | "--help" => {
                println!(
                    "mnml — NvChad-style terminal IDE\n\n\
                     usage:\n  \
                       mnml [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless]\n  \
                       mnml run FILE [--env NAME] [--workspace DIR]\n"
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

    let workspace =
        workspace.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let workspace = workspace
        .canonicalize()
        .map_err(|e| format!("cannot open workspace {}: {e}", workspace.display()))?;
    Ok(TuiArgs {
        workspace,
        headless,
        input_style,
        ascii,
        config_path,
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

    let app = match App::new(args.workspace, config) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("mnml: {e}");
            return ExitCode::FAILURE;
        }
    };

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

fn do_run(file: &Path, env_name: Option<&str>, workspace: Option<&Path>) -> Result<(), String> {
    use mnml::http::{self, template::EnvSet};

    let raw = std::fs::read_to_string(file)
        .map_err(|e| format!("cannot read {}: {e}", file.display()))?;

    // Workspace for env-file resolution: explicit, else the file's directory.
    let ws = workspace
        .map(Path::to_path_buf)
        .or_else(|| file.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."));
    let env = EnvSet::select(&ws, env_name);
    if let Some(name) = &env.name {
        eprintln!("env: {name}");
    }

    let missing = http::template::unresolved(&raw, &env);
    if !missing.is_empty() {
        eprintln!("warning: unresolved variables: {}", missing.join(", "));
    }
    let expanded = http::template::expand(&raw, &env);
    let req = http::parse(&expanded).map_err(|e| e.to_string())?;

    println!("→ {} {}", req.method, req.url);
    let resp = http::send(&req)?;
    println!(
        "← {} {}  ({} ms)",
        resp.status,
        resp.status_text,
        resp.elapsed.as_millis()
    );
    // A few interesting response headers.
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

    // Non-2xx is a failed run (assertions land in a later pass).
    if !(200..300).contains(&resp.status) {
        return Err(format!("HTTP {}", resp.status));
    }
    Ok(())
}
