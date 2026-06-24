//! mnml — a NvChad-style terminal IDE built on ratatui.

use std::process::ExitCode;

mod app;
mod editor;
mod input;
mod layout;
mod pane;
mod ui;

fn main() -> ExitCode {
    let workspace = std::env::args()
        .nth(1)
        .unwrap_or_else(|| ".".into());

    match mnml::run(&workspace) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("mnml: {e}");
            ExitCode::FAILURE
        }
    }
}
