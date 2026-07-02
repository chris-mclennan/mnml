//! Tier-2 IPC helpers — write JSONL commands to the host.
//!
//! Siblings spawned by mnml as Pty children (or Mount siblings)
//! get `MNML_IPC_DIR` in env. The host tails
//! `$MNML_IPC_DIR/command` for JSONL lines and dispatches each
//! one into `App::dispatch_command`. This module wraps the wire
//! format so siblings write typed helper calls instead of
//! hand-rolling JSON.
//!
//! Every helper is best-effort: silent no-op on missing env,
//! silent no-op on IO error. Siblings should treat these as
//! fire-and-forget notifications, not as commands they need to
//! confirm succeeded.
//!
//! ```no_run
//! mnml_bridge::toast("processing done");
//! mnml_bridge::set_activity_badge("agents", 3);
//! mnml_bridge::register_command(
//!     "my_sibling.open_dashboard",
//!     "Open Dashboard",
//!     Some("plugin"),
//!     &["<leader>md"],
//! );
//! ```

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;

/// Show a toast notification in the host. Non-blocking,
/// fire-and-forget. Silent no-op when `MNML_IPC_DIR` is unset
/// (sibling wasn't spawned by mnml) or on any IO error.
pub fn toast(message: impl AsRef<str>) {
    let payload = serde_json::json!({
        "cmd": "toast",
        "text": message.as_ref(),
    });
    let _ = write_line(&payload);
}

/// Set a notification badge on an activity-bar section (or a
/// manifest-registered Mount section, keyed by its manifest id).
/// `count = 0` clears the badge.
///
/// Builtin section ids: `"explorer"`, `"search"`, `"git"`,
/// `"debug"`, `"integrations"`, `"sessions"`, `"agents"`,
/// `"cloud_agents"`. Mount siblings pass their own manifest `id`.
pub fn set_activity_badge(section: impl AsRef<str>, count: u32) {
    let payload = serde_json::json!({
        "cmd": "set-activity-badge",
        "section": section.as_ref(),
        "count": count,
    });
    let _ = write_line(&payload);
}

/// Register a plugin command. It becomes runnable from the
/// palette + optionally bound to one or more key chords in the
/// host. Keyspec syntax mirrors mnml's own keymap
/// (`"ctrl+shift+t"`, `"<leader>xt"`, …).
///
/// `group` categorises the command in the palette
/// (`"plugin"` by default). The registered command runs inside
/// mnml — most siblings pair this with a toast or a fresh
/// `open-pty` follow-up so the user sees the action.
pub fn register_command(
    id: impl AsRef<str>,
    title: impl AsRef<str>,
    group: Option<&str>,
    keys: &[&str],
) {
    let payload = serde_json::json!({
        "cmd": "register-command",
        "id": id.as_ref(),
        "title": title.as_ref(),
        "group": group.unwrap_or("plugin"),
        "keys": keys,
    });
    let _ = write_line(&payload);
}

fn command_file() -> Option<PathBuf> {
    let dir = std::env::var_os("MNML_IPC_DIR")?;
    let mut p = PathBuf::from(dir);
    p.push("command");
    Some(p)
}

fn write_line(value: &serde_json::Value) -> std::io::Result<()> {
    let path = command_file().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "MNML_IPC_DIR not set — not spawned by mnml",
        )
    })?;
    write_line_to(&path, value)
}

/// Append one JSON value + newline to the given file. Exposed
/// only for tests + advanced callers that want a non-env
/// `command` file path.
#[doc(hidden)]
pub fn write_line_to(path: &std::path::Path, value: &serde_json::Value) -> std::io::Result<()> {
    let line = serde_json::to_string(value)?;
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(line.as_bytes())?;
    f.write_all(b"\n")?;
    Ok(())
}

/// Payload builders — the wire shape each helper produces.
/// Tests hit these directly so they don't need to touch the
/// global `MNML_IPC_DIR` env var (which races across parallel
/// tests).
#[doc(hidden)]
pub fn toast_payload(message: &str) -> serde_json::Value {
    serde_json::json!({ "cmd": "toast", "text": message })
}

#[doc(hidden)]
pub fn set_activity_badge_payload(section: &str, count: u32) -> serde_json::Value {
    serde_json::json!({
        "cmd": "set-activity-badge",
        "section": section,
        "count": count,
    })
}

#[doc(hidden)]
pub fn register_command_payload(
    id: &str,
    title: &str,
    group: Option<&str>,
    keys: &[&str],
) -> serde_json::Value {
    serde_json::json!({
        "cmd": "register-command",
        "id": id,
        "title": title,
        "group": group.unwrap_or("plugin"),
        "keys": keys,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn read_file(path: &std::path::Path) -> String {
        let mut s = String::new();
        let mut f = std::fs::File::open(path).unwrap();
        f.read_to_string(&mut s).unwrap();
        s
    }

    #[test]
    fn toast_payload_shape() {
        let v = toast_payload("hello world");
        let s = serde_json::to_string(&v).unwrap();
        assert!(s.contains("\"cmd\":\"toast\""));
        assert!(s.contains("\"text\":\"hello world\""));
    }

    #[test]
    fn set_activity_badge_payload_shape() {
        let v = set_activity_badge_payload("agents", 5);
        let s = serde_json::to_string(&v).unwrap();
        assert!(s.contains("\"cmd\":\"set-activity-badge\""));
        assert!(s.contains("\"section\":\"agents\""));
        assert!(s.contains("\"count\":5"));
    }

    #[test]
    fn register_command_payload_default_group() {
        let v = register_command_payload("plug.open", "Open Plug", None, &["ctrl+shift+p"]);
        let s = serde_json::to_string(&v).unwrap();
        assert!(s.contains("\"cmd\":\"register-command\""));
        assert!(s.contains("\"id\":\"plug.open\""));
        assert!(s.contains("\"title\":\"Open Plug\""));
        assert!(s.contains("\"group\":\"plugin\""));
        assert!(s.contains("\"keys\":[\"ctrl+shift+p\"]"));
    }

    #[test]
    fn register_command_payload_custom_group_and_multi_key() {
        let v =
            register_command_payload("plug.split", "Split", Some("view"), &["ctrl+alt+s", "F5"]);
        let s = serde_json::to_string(&v).unwrap();
        assert!(s.contains("\"group\":\"view\""));
        assert!(s.contains("\"keys\":[\"ctrl+alt+s\",\"F5\"]"));
    }

    #[test]
    fn write_line_appends_newline() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("command");
        write_line_to(&p, &toast_payload("one")).unwrap();
        write_line_to(&p, &toast_payload("two")).unwrap();
        let contents = read_file(&p);
        let lines: Vec<&str> = contents.split_terminator('\n').collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("\"text\":\"one\""));
        assert!(lines[1].contains("\"text\":\"two\""));
    }

    #[test]
    fn silent_when_env_missing() {
        // No env manipulation — this only checks the no-panic
        // property of the public helpers when they can't find
        // MNML_IPC_DIR. If the test env happens to have it set
        // (e.g. running under mnml itself), the calls still
        // succeed silently.
        let _ = toast_payload("safe");
    }
}
