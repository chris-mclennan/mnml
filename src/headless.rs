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

/// Run headless (virtual screen + file-IPC). `Ok(true)` ⇒ restart requested.
pub fn run(mut app: App) -> Result<bool, String> {
    let (w, h) = screen_size();
    let backend = TestBackend::new(w, h);
    let mut terminal = Terminal::new(backend).map_err(|e| format!("headless terminal: {e}"))?;
    let mut ipc = Ipc::init(&app.workspace).map_err(|e| format!("ipc init: {e}"))?;
    ipc.append_event(&format!(
        "{{\"event\":\"start\",\"mode\":\"headless\",\"cols\":{w},\"rows\":{h},\"ipc\":{:?}}}",
        ipc.dir().display().to_string()
    ));

    // qa-5th 2026-06-29 SEV-2: install a SIGTERM/SIGINT/SIGHUP
    // signal handler so the host gets a death certificate even
    // when the process is killed externally (kill -TERM, Ctrl+C
    // on the controlling terminal, parent shell exits, etc.).
    // signal-hook only sets a flag — the AS-safe contract — and
    // the main loop polls + emits the shutdown event before
    // exiting cleanly. SIGKILL remains uncatchable by design.
    let sigterm_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let signals_registered = {
        let mut any_err = false;
        for sig in [
            signal_hook::consts::SIGTERM,
            signal_hook::consts::SIGINT,
            signal_hook::consts::SIGHUP,
        ] {
            if signal_hook::flag::register(sig, sigterm_flag.clone()).is_err() {
                any_err = true;
            }
        }
        !any_err
    };
    if !signals_registered {
        ipc.append_event(
            r#"{"event":"warn","note":"signal-hook register failed; SIGTERM won't emit death certificate"}"#,
        );
    }

    app.run_startup_tasks();

    loop {
        if sigterm_flag.load(std::sync::atomic::Ordering::Relaxed) {
            // qa-7th code-review W-3 2026-06-30 — preserve session
            // state on signal-induced shutdown so the host can
            // restore open files / layout / scroll on next launch.
            app.save_session_on_quit();
            ipc.append_event(
                r#"{"event":"exit","reason":"signal","note":"SIGTERM/SIGINT/SIGHUP — early exit"}"#,
            );
            return Ok(false);
        }
        app.tick();
        // Chord-chain timeout fallback — same call the terminal loop
        // makes between tick() and draw(). Without this, a `Ctrl+K`
        // press in headless mode never times out into `whichkey.leader`
        // because no key arrives to advance the state machine.
        crate::tui::tick_chord_chain(&mut app);
        terminal
            .draw(|f| ui::draw(f, &mut app))
            .map_err(|e| format!("render: {e}"))?;
        ipc::dump_screen_status(&ipc, terminal.backend().buffer(), &app);
        if app.should_quit {
            app.save_session_on_quit();
            break;
        }
        let any = ipc::drain_commands(&mut ipc, &mut app);
        ipc::drain_plugin_events(&ipc, &mut app);
        if !any {
            std::thread::sleep(POLL_SLEEP);
        }
    }

    // Final dump so the host sees the end state.
    terminal
        .draw(|f| ui::draw(f, &mut app))
        .map_err(|e| format!("render: {e}"))?;
    ipc::dump_screen_status(&ipc, terminal.backend().buffer(), &app);
    ipc.append_event(if app.restart_requested {
        "{\"event\":\"exit\",\"restart\":true}"
    } else {
        "{\"event\":\"exit\"}"
    });
    Ok(app.restart_requested)
}

fn screen_size() -> (u16, u16) {
    let parse = |k: &str, d: u16| -> u16 {
        std::env::var(k)
            .ok()
            .and_then(|v| v.parse::<u16>().ok())
            .filter(|&n| n >= 10)
            .unwrap_or(d)
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
        assert!(
            text.contains("hello.txt"),
            "bufferline/statusline should name the file:\n{text}"
        );
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
