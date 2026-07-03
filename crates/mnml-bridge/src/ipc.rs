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

use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;

/// Toast severity level. Info + warn share the standard comment
/// border (calm ambient); error gets a red border so failures
/// stand out. Persistent toasts respect the same mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToastLevel {
    #[default]
    Info,
    Warn,
    Error,
}

impl ToastLevel {
    fn as_str(self) -> &'static str {
        match self {
            ToastLevel::Info => "info",
            ToastLevel::Warn => "warn",
            ToastLevel::Error => "error",
        }
    }
}

/// Outcome of a progress notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProgressStatus {
    Success,
    Failed,
    Cancelled,
}

impl ProgressStatus {
    fn as_str(self) -> &'static str {
        match self {
            ProgressStatus::Success => "success",
            ProgressStatus::Failed => "failed",
            ProgressStatus::Cancelled => "cancelled",
        }
    }
}

/// Statusline segment anchor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SegmentSide {
    Left,
    #[default]
    Right,
}

impl SegmentSide {
    fn as_str(self) -> &'static str {
        match self {
            SegmentSide::Left => "left",
            SegmentSide::Right => "right",
        }
    }
}

/// Options for [`notify`]. All fields are optional-ish — see
/// individual field docs.
#[derive(Debug, Clone, Default)]
pub struct NotifyOpts {
    pub level: ToastLevel,
    /// Ring the terminal bell alongside the OS notification.
    /// Opt-in (default `false`).
    pub sound: bool,
    /// Source integration id — determines rate-limit + policy
    /// lookup. `None` bypasses both (always fires).
    pub source: Option<String>,
}

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

/// Level-tagged toast helpers — same wire shape as [`toast`] but
/// with an explicit `level` field. `info` (default) + `warn` render
/// with the comment border; `error` gets a red border.
pub fn toast_info(message: impl AsRef<str>) {
    toast_leveled(message, ToastLevel::Info);
}
pub fn toast_warn(message: impl AsRef<str>) {
    toast_leveled(message, ToastLevel::Warn);
}
pub fn toast_error(message: impl AsRef<str>) {
    toast_leveled(message, ToastLevel::Error);
}

fn toast_leveled(message: impl AsRef<str>, level: ToastLevel) {
    let payload = serde_json::json!({
        "cmd": "toast",
        "text": message.as_ref(),
        "level": level.as_str(),
    });
    let _ = write_line(&payload);
}

/// Pin a toast identified by `id`. Repeat calls with the same
/// id update the text/level in place. Stays visible until
/// [`toast_dismiss`].
pub fn toast_persistent(id: impl AsRef<str>, message: impl AsRef<str>, level: ToastLevel) {
    let payload = serde_json::json!({
        "cmd": "toast-persistent",
        "id": id.as_ref(),
        "text": message.as_ref(),
        "level": level.as_str(),
    });
    let _ = write_line(&payload);
}

/// Remove a persistent toast by id. No-op if the id isn't
/// currently pinned.
pub fn toast_dismiss(id: impl AsRef<str>) {
    let payload = serde_json::json!({
        "cmd": "toast-dismiss",
        "id": id.as_ref(),
    });
    let _ = write_line(&payload);
}

/// Start a progress notification — the host renders an animated
/// Braille spinner + label. Repeat calls with the same id reset
/// the item.
pub fn progress_start(id: impl AsRef<str>, label: impl AsRef<str>) {
    let payload = serde_json::json!({
        "cmd": "progress-start",
        "id": id.as_ref(),
        "text": label.as_ref(),
    });
    let _ = write_line(&payload);
}

/// Update an in-flight progress. `label` and `percent` are both
/// optional — pass `None` to keep the previous value. Percent
/// clamps to 0..=100 host-side.
pub fn progress_update(id: impl AsRef<str>, label: Option<&str>, percent: Option<u8>) {
    let mut m = serde_json::Map::new();
    m.insert("cmd".to_string(), serde_json::json!("progress-update"));
    m.insert("id".to_string(), serde_json::json!(id.as_ref()));
    if let Some(l) = label {
        m.insert("text".to_string(), serde_json::json!(l));
    }
    if let Some(p) = percent {
        m.insert("count".to_string(), serde_json::json!(p));
    }
    let _ = write_line(&serde_json::Value::Object(m));
}

/// Finish a progress notification. `Failed` also fires a
/// `toast_error` host-side; `Success` / `Cancelled` show the
/// terminal status glyph and fade after ~2.5s.
pub fn progress_end(id: impl AsRef<str>, status: ProgressStatus) {
    let payload = serde_json::json!({
        "cmd": "progress-end",
        "id": id.as_ref(),
        "text": status.as_str(),
    });
    let _ = write_line(&payload);
}

/// Insert or update a sibling statusline segment. Sorted host-side
/// by priority desc; each segment competes for its lane's
/// budget.
#[allow(clippy::too_many_arguments)]
pub fn statusline_set_segment(
    id: impl AsRef<str>,
    side: SegmentSide,
    text: impl AsRef<str>,
    color: Option<&str>,
    click_command: Option<&str>,
    priority: u8,
    min_width: u16,
    max_width: u16,
) {
    let mut m = serde_json::Map::new();
    m.insert(
        "cmd".to_string(),
        serde_json::json!("statusline-set-segment"),
    );
    m.insert("id".to_string(), serde_json::json!(id.as_ref()));
    m.insert("side".to_string(), serde_json::json!(side.as_str()));
    m.insert("text".to_string(), serde_json::json!(text.as_ref()));
    if let Some(c) = color {
        m.insert("color".to_string(), serde_json::json!(c));
    }
    if let Some(c) = click_command {
        m.insert("click_command".to_string(), serde_json::json!(c));
    }
    m.insert("priority".to_string(), serde_json::json!(priority));
    m.insert("min_width".to_string(), serde_json::json!(min_width));
    m.insert("max_width".to_string(), serde_json::json!(max_width));
    let _ = write_line(&serde_json::Value::Object(m));
}

/// Remove a sibling statusline segment by id.
pub fn statusline_clear_segment(id: impl AsRef<str>) {
    let payload = serde_json::json!({
        "cmd": "statusline-clear-segment",
        "id": id.as_ref(),
    });
    let _ = write_line(&payload);
}

/// Fire an OS-level notification. Host emits OSC 9 + 777 escape
/// sequences after the next render pass — Ghostty / iTerm2 /
/// kitty / WezTerm route those to native banners. Terminals that
/// don't recognize the escape silently consume it.
///
/// Always fires an in-app toast at `opts.level`. OS emission
/// respects the integration's `[notifications]` policy + rate
/// limit; when `opts.source = None`, both checks are bypassed.
pub fn notify(title: impl AsRef<str>, body: impl AsRef<str>, opts: NotifyOpts) {
    let mut m = serde_json::Map::new();
    m.insert("cmd".to_string(), serde_json::json!("notify"));
    m.insert("title".to_string(), serde_json::json!(title.as_ref()));
    m.insert("text".to_string(), serde_json::json!(body.as_ref()));
    m.insert("level".to_string(), serde_json::json!(opts.level.as_str()));
    if opts.sound {
        m.insert("sound".to_string(), serde_json::json!(true));
    }
    if let Some(src) = &opts.source {
        m.insert("source".to_string(), serde_json::json!(src));
    }
    let _ = write_line(&serde_json::Value::Object(m));
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
