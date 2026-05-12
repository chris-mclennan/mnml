//! The headless frontend: renders into a `TestBackend` virtual screen and is
//! driven entirely from the file-IPC channel. Shares `app.rs` + `ui::draw` +
//! `tui::dispatch_*` with the terminal loop so behavior matches. This is the
//! substrate the `.test` E2E runner will stand on.

use std::time::Duration;

use ratatui::Terminal;
use ratatui::backend::TestBackend;

use crate::app::App;
use crate::ipc::{self, Ipc};
use crate::ui;

const POLL_SLEEP: Duration = Duration::from_millis(40);

pub fn run(mut app: App) -> Result<(), String> {
    let (w, h) = screen_size();
    let backend = TestBackend::new(w, h);
    let mut terminal = Terminal::new(backend).map_err(|e| format!("headless terminal: {e}"))?;
    let mut ipc = Ipc::init(&app.workspace).map_err(|e| format!("ipc init: {e}"))?;
    ipc.append_event(&format!(
        "{{\"event\":\"start\",\"cols\":{w},\"rows\":{h},\"ipc\":{:?}}}",
        ipc.dir().display().to_string()
    ));

    loop {
        app.tick();
        terminal.draw(|f| ui::draw(f, &mut app)).map_err(|e| format!("render: {e}"))?;
        dump(&ipc, &terminal, &app);
        if app.should_quit {
            break;
        }
        let cmds = ipc.poll();
        if cmds.is_empty() {
            std::thread::sleep(POLL_SLEEP);
            continue;
        }
        for c in &cmds {
            let ev = ipc::apply(&mut app, c);
            ipc.append_event(&ev);
        }
    }

    // Final dump so the host sees the end state.
    terminal.draw(|f| ui::draw(f, &mut app)).map_err(|e| format!("render: {e}"))?;
    dump(&ipc, &terminal, &app);
    ipc.append_event("{\"event\":\"exit\"}");
    Ok(())
}

fn dump(ipc: &Ipc, terminal: &Terminal<TestBackend>, app: &App) {
    ipc.write_screen(&ipc::screen_to_text(terminal.backend().buffer()));
    ipc.write_status(&ipc::status_json(app));
}

fn screen_size() -> (u16, u16) {
    let parse = |k: &str, d: u16| -> u16 {
        std::env::var(k).ok().and_then(|v| v.parse::<u16>().ok()).filter(|&n| n >= 10).unwrap_or(d)
    };
    (parse("MNML_COLS", 120), parse("MNML_ROWS", 40))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use std::fs;

    #[test]
    fn renders_a_buffer_into_the_virtual_screen() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("hello.txt"), "Hello, mnml!\nsecond line").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&d.path().join("hello.txt"));

        let backend = TestBackend::new(100, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| ui::draw(f, &mut app)).unwrap();
        let text = ipc::screen_to_text(terminal.backend().buffer());
        assert!(text.contains("Hello, mnml!"), "screen was:\n{text}");
        assert!(text.contains("hello.txt"), "bufferline/statusline should name the file:\n{text}");
    }

    #[test]
    fn status_json_reflects_open_file() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("x.rs"), "fn main() {}").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&d.path().join("x.rs"));
        let j = ipc::status_json(&app);
        assert!(j.contains("\"focus\":\"pane\""), "{j}");
        assert!(j.contains("x.rs"), "{j}");
    }
}
