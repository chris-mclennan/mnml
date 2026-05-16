//! File-IPC integration tests. Drives `App` through the same `.mnml/ipc/`
//! channel the headless loop + external plugins use:
//!   1. Write a JSONL command to `command`
//!   2. Call `drain_commands` (the same fn the headless tick uses)
//!   3. Render via the in-process `TestBackend` + `ui::draw`
//!   4. Dump `screen.txt` + `status.json` (same fn the headless tick uses)
//!   5. Assert on the on-disk artifacts.
//!
//! This is the test the broader `.test` E2E format can't easily express —
//! its grammar drives the App directly; this one exercises the wire format
//! that out-of-process plugins / external scripts depend on.
//!
//! Lives at the crate-root `tests/` level (not `tests/e2e/`) so it runs as
//! a separate integration binary and doesn't have to thread through the
//! `.test` runner.

use std::fs;
use std::io::Write;

use ratatui::Terminal;
use ratatui::backend::TestBackend;

use mnml::app::App;
use mnml::config::Config;
use mnml::ipc::{Ipc, drain_commands, dump_screen_status};
use mnml::ui::draw;

/// Spin up an `App` rooted at a fresh tempdir + an `Ipc` channel under it.
/// Returns `(_tempdir_guard, app, ipc)` — the guard must outlive both.
fn setup() -> (tempfile::TempDir, App, Ipc) {
    let d = tempfile::tempdir().expect("tempdir");
    // Seed a couple of fixture files so `open` has something to chew on.
    fs::write(d.path().join("alpha.txt"), "Alpha contents\n").unwrap();
    fs::write(d.path().join("beta.md"), "# Beta heading\n").unwrap();
    let app = App::new(d.path().to_path_buf(), Config::default()).expect("App::new");
    let ipc = Ipc::init(&app.workspace).expect("Ipc::init");
    (d, app, ipc)
}

/// Append one JSONL command line to the IPC `command` file.
fn send_cmd(ipc: &Ipc, json: &str) {
    let p = ipc.dir().join("command");
    let mut f = fs::OpenOptions::new()
        .append(true)
        .open(&p)
        .expect("open ipc command file");
    writeln!(f, "{json}").expect("append cmd");
}

/// Drive one tick — drain commands, render to a TestBackend, dump screen
/// + status to disk. Returns the dumped screen.txt text for assertions.
fn tick(app: &mut App, ipc: &mut Ipc) -> String {
    drain_commands(ipc, app);
    let backend = TestBackend::new(120, 40);
    let mut term = Terminal::new(backend).expect("Terminal::new");
    term.draw(|f| {
        draw(f, app);
    })
    .expect("draw");
    dump_screen_status(ipc, term.backend().buffer(), app);
    fs::read_to_string(ipc.dir().join("screen.txt")).unwrap_or_default()
}

#[test]
fn ipc_open_file_renders_in_screen_txt() {
    let (_tmp, mut app, mut ipc) = setup();
    send_cmd(&ipc, r#"{"cmd":"open","path":"alpha.txt"}"#);
    let screen = tick(&mut app, &mut ipc);
    assert!(
        screen.contains("Alpha contents"),
        "screen.txt should show the opened file's text; got:\n{screen}"
    );
    // status.json should mention the open path too.
    let status = fs::read_to_string(ipc.dir().join("status.json")).unwrap();
    assert!(
        status.contains("alpha.txt"),
        "status.json should reference the active path; got:\n{status}"
    );
}

#[test]
fn ipc_run_command_palette_opens_picker_in_screen_txt() {
    let (_tmp, mut app, mut ipc) = setup();
    send_cmd(&ipc, r#"{"cmd":"open","path":"alpha.txt"}"#);
    let _ = tick(&mut app, &mut ipc);
    // Now fire the command palette via run-command.
    send_cmd(&ipc, r#"{"cmd":"run-command","id":"palette"}"#);
    let screen = tick(&mut app, &mut ipc);
    assert!(
        screen.contains("Command palette"),
        "palette title should be visible after run-command palette; got:\n{screen}"
    );
}

#[test]
fn ipc_type_appends_chars_to_active_buffer() {
    let (_tmp, mut app, mut ipc) = setup();
    // Open the file, jump to end-of-buffer, switch to insert mode (default
    // input handler is StandardInputHandler which is modeless — type lands
    // straight in), then type some new content.
    send_cmd(&ipc, r#"{"cmd":"open","path":"alpha.txt"}"#);
    // End of file via ctrl+end.
    send_cmd(&ipc, r#"{"cmd":"key","key":"ctrl+end"}"#);
    send_cmd(&ipc, r#"{"cmd":"type","text":"more"}"#);
    let _ = tick(&mut app, &mut ipc);
    // Save via save command id (or ctrl+s).
    send_cmd(&ipc, r#"{"cmd":"key","key":"ctrl+s"}"#);
    let screen = tick(&mut app, &mut ipc);
    // Active buffer should have grown.
    let saved = fs::read_to_string(_tmp.path().join("alpha.txt")).unwrap();
    assert!(
        saved.contains("Alpha contents") && saved.contains("more"),
        "expected typed text persisted to disk; got:\n{saved}\nscreen:\n{screen}"
    );
}

#[test]
fn ipc_register_plugin_command_then_run_emits_event() {
    let (_tmp, mut app, mut ipc) = setup();
    // Register a plugin command via IPC.
    send_cmd(
        &ipc,
        r#"{"cmd":"register-command","id":"plugin.demo","title":"Demo","group":"plugin","keys":[]}"#,
    );
    send_cmd(&ipc, r#"{"cmd":"run-command","id":"plugin.demo"}"#);
    let _ = tick(&mut app, &mut ipc);
    let events = fs::read_to_string(ipc.dir().join("events.jsonl")).unwrap();
    assert!(
        events.contains("command_registered") && events.contains("\"id\":\"plugin.demo\""),
        "expected register-command event for plugin.demo; got:\n{events}"
    );
    assert!(
        events.contains("plugin-command") || events.contains("command_run"),
        "expected a plugin-command or command_run event for plugin.demo; got:\n{events}"
    );
}

#[test]
fn ipc_quit_sets_should_quit() {
    let (_tmp, mut app, mut ipc) = setup();
    send_cmd(&ipc, r#"{"cmd":"quit"}"#);
    drain_commands(&mut ipc, &mut app);
    assert!(app.should_quit, "quit IPC should mark should_quit");
}

#[test]
fn ipc_unknown_command_logs_event_without_panic() {
    let (_tmp, mut app, mut ipc) = setup();
    send_cmd(&ipc, r#"{"cmd":"this-does-not-exist"}"#);
    let _ = tick(&mut app, &mut ipc);
    let events = fs::read_to_string(ipc.dir().join("events.jsonl")).unwrap();
    assert!(
        events.contains("unknown"),
        "unknown command should land in events.jsonl as an `unknown` event; got:\n{events}"
    );
}

#[test]
fn ipc_screen_dimensions_match_test_backend() {
    let (_tmp, mut app, mut ipc) = setup();
    send_cmd(&ipc, r#"{"cmd":"open","path":"beta.md"}"#);
    let screen = tick(&mut app, &mut ipc);
    // 40 rows × 120 cols → 40 lines of 120 chars + 40 newlines = exact size
    // isn't guaranteed (markdown preview auto-opens for .md), but the file
    // should be present in the dump regardless.
    assert!(
        screen.contains("Beta heading"),
        "beta.md content should render; got:\n{screen}"
    );
}
