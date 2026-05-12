//! Binary entry. Subcommand dispatch — for P0 just `mnml [WORKSPACE] [flags]`
//! (TUI) and `mnml --headless [WORKSPACE]` (virtual-screen + file-IPC). Later
//! phases add `mnml run FILE`, `mnml chain run FILE`, `mnml test GLOB`, `mnml ipc …`.

use std::path::PathBuf;
use std::process::ExitCode;

use mnml::app::App;
use mnml::config::Config;

struct Args {
    workspace: PathBuf,
    headless: bool,
    input_style: Option<String>,
    ascii: bool,
    config_path: Option<PathBuf>,
}

fn parse_args() -> Result<Args, String> {
    let mut workspace: Option<PathBuf> = None;
    let mut headless = false;
    let mut input_style = None;
    let mut ascii = false;
    let mut config_path = None;

    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--headless" => headless = true,
            "--ascii" => ascii = true,
            "--input" => {
                input_style = Some(
                    it.next()
                        .ok_or_else(|| "--input needs a value (vim|standard)".to_string())?,
                );
            }
            "--config" => {
                config_path = Some(PathBuf::from(
                    it.next()
                        .ok_or_else(|| "--config needs a path".to_string())?,
                ));
            }
            "-h" | "--help" => {
                println!(
                    "mnml — NvChad-style terminal IDE\n\n\
                     usage: mnml [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless]\n"
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
    Ok(Args {
        workspace,
        headless,
        input_style,
        ascii,
        config_path,
    })
}

fn main() -> ExitCode {
    let args = match parse_args() {
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
