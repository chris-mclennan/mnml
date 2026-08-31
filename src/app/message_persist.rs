//! Persistence + the unread count for `App::message_log`.
//!
//! **User ask 2026-08-30:** "make way of seeing latest toasts", then
//! "same store just persisted and accessed with a notifications icon
//! somewhere?".
//!
//! The store and its history view already existed — `message_log`,
//! `:messages` / `messages.show`, and a picker showing entries newest
//! first with level icons and local times. Every `toast_leveled` records
//! into it, including under `:silent`. Only two things were missing: the
//! log died with the process, and nothing on screen said it had anything
//! in it.
//!
//! Written as JSONL, appended per entry rather than dumped on quit. A
//! crash is exactly when you want to know what the last message said, and
//! a quit-time dump loses precisely that case. Toasts are user-paced, so
//! one small append each is not a cost worth optimising away.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::app::{LoggedMessage, ToastLevel, now_unix};

/// Entries older than this are dropped when the log is read.
///
/// Without it the file grows forever and the history fills with noise
/// from last month — which makes the one message you are looking for
/// harder to find, not easier.
const MAX_AGE_SECS: u64 = 7 * 24 * 60 * 60;

/// Per WORKSPACE, not global. Most messages name workspace files
/// ("unsaved changes in src/foo.rs"), so they are meaningless in another
/// project.
pub fn message_log_path(workspace: &Path) -> PathBuf {
    workspace.join(".mnml").join("messages.jsonl")
}

fn level_str(l: ToastLevel) -> &'static str {
    match l {
        ToastLevel::Error => "error",
        ToastLevel::Warn => "warn",
        ToastLevel::Info => "info",
    }
}

fn level_of(s: &str) -> ToastLevel {
    match s {
        "error" => ToastLevel::Error,
        "warn" => ToastLevel::Warn,
        _ => ToastLevel::Info,
    }
}

/// Minimal hand-rolled JSON escape — the text is arbitrary user-facing
/// message content, so quotes, backslashes and newlines all occur.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn unesc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('"') => out.push('"'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                let hex: String = it.by_ref().take(4).collect();
                if let Ok(n) = u32::from_str_radix(&hex, 16)
                    && let Some(c) = char::from_u32(n)
                {
                    out.push(c);
                }
            }
            Some(other) => out.push(other),
            None => break,
        }
    }
    out
}

/// Pull one string field out of a flat JSON object. Deliberately not a
/// general parser — the writer is right here, the shape is fixed, and a
/// dependency for four fields is not worth it.
fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let pat = format!("\"{key}\":\"");
    let start = line.find(&pat)? + pat.len();
    let rest = &line[start..];
    // Find the closing quote that is not escaped.
    let mut prev_backslash = false;
    for (i, c) in rest.char_indices() {
        if c == '"' && !prev_backslash {
            return Some(&rest[..i]);
        }
        prev_backslash = c == '\\' && !prev_backslash;
    }
    None
}

fn num_field(line: &str, key: &str) -> Option<u64> {
    let pat = format!("\"{key}\":");
    let start = line.find(&pat)? + pat.len();
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

impl crate::app::App {
    /// Append one entry to the on-disk log.
    ///
    /// Failures are SILENT. A toast that cannot be written is not worth a
    /// second toast about the write failing — that path leads to a loop,
    /// since the failure toast would also try to write.
    pub fn persist_message(&self, m: &LoggedMessage) {
        let path = message_log_path(&self.workspace);
        let Some(dir) = path.parent() else {
            return;
        };
        if std::fs::create_dir_all(dir).is_err() {
            return;
        }
        let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        else {
            return;
        };
        let _ = writeln!(
            f,
            "{{\"at\":{},\"level\":\"{}\",\"text\":\"{}\"}}",
            m.at,
            level_str(m.level),
            esc(&m.text)
        );
    }

    /// Read the persisted log, dropping stale entries and keeping the
    /// newest `cap`.
    ///
    /// Unparseable lines are skipped rather than failing the load: a
    /// truncated final line from a crash mid-write is exactly the case
    /// this file exists for, and losing the whole history to it would be
    /// perverse.
    pub fn load_persisted_messages(&mut self, cap: usize) {
        let path = message_log_path(&self.workspace);
        let Ok(body) = std::fs::read_to_string(&path) else {
            return;
        };
        let cutoff = now_unix().saturating_sub(MAX_AGE_SECS);
        let mut out: Vec<LoggedMessage> = body
            .lines()
            .filter_map(|l| {
                let at = num_field(l, "at")?;
                if at < cutoff {
                    return None;
                }
                Some(LoggedMessage {
                    text: unesc(field(l, "text")?),
                    level: level_of(field(l, "level").unwrap_or("info")),
                    at,
                })
            })
            .collect();
        if out.len() > cap {
            out.drain(..out.len() - cap);
        }
        // Rewrite whenever pruning changed anything, so the file cannot
        // grow without bound across sessions.
        if out.len() != body.lines().count() {
            let rewritten: String = out
                .iter()
                .map(|m| {
                    format!(
                        "{{\"at\":{},\"level\":\"{}\",\"text\":\"{}\"}}\n",
                        m.at,
                        level_str(m.level),
                        esc(&m.text)
                    )
                })
                .collect();
            let _ = std::fs::write(&path, rewritten);
        }
        // Persisted entries go BEFORE anything this session produced.
        out.append(&mut self.message_log);
        self.message_log = out;
    }

    /// Warnings and errors the user has not looked at since last opening
    /// the history.
    ///
    /// Info is excluded on purpose: a badge that lights up for "saved
    /// foo.rs" trains you to ignore it, and then it is not there when an
    /// error arrives.
    ///
    /// A plain counter, NOT a timestamp comparison. Entries carry
    /// whole-second times, so "seen at T" either misses a warning raised
    /// in the same second as the open (badge silent on a real error) or
    /// keeps counting one from earlier in that second (badge stuck lit).
    /// A clock is the wrong instrument for "since you last looked".
    ///
    /// In-memory only: the badge means "since you last looked", and a new
    /// session is a fresh look. The HISTORY is the durable part.
    pub fn unread_message_count(&self) -> usize {
        self.unread_messages
    }

    /// Mark everything currently logged as seen. Called when the history
    /// is opened.
    pub fn mark_messages_seen(&mut self) {
        self.unread_messages = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::App;
    use crate::config::Config;

    fn app() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    #[test]
    fn a_message_survives_a_restart() {
        let (d, mut app) = app();
        app.toast_leveled("disk on fire", ToastLevel::Error);
        assert!(message_log_path(d.path()).is_file(), "nothing was written");

        // A "restart": a fresh App on the same workspace.
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.load_persisted_messages(200);
        assert!(
            app2.message_log.iter().any(|m| m.text == "disk on fire"),
            "the message did not survive: {:?}",
            app2.message_log
        );
    }

    /// Text is arbitrary user-facing content — paths with backslashes,
    /// quoted filenames, embedded newlines all occur. A naive writer
    /// corrupts the file and takes the whole history with it.
    #[test]
    fn messages_with_quotes_newlines_and_backslashes_round_trip() {
        let (d, mut app) = app();
        let nasty = "can't open \"C:\\Users\\x\"\nsecond line\ttabbed";
        app.toast_leveled(nasty, ToastLevel::Warn);

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.load_persisted_messages(200);
        assert!(
            app2.message_log.iter().any(|m| m.text == nasty),
            "round trip mangled the text: {:?}",
            app2.message_log.iter().map(|m| &m.text).collect::<Vec<_>>()
        );
    }

    /// A crash mid-write leaves a truncated final line. Losing the entire
    /// history to it would be perverse — that crash is exactly why the
    /// file exists.
    #[test]
    fn a_truncated_final_line_does_not_lose_the_rest() {
        let (d, mut app) = app();
        app.toast_leveled("first", ToastLevel::Error);
        app.toast_leveled("second", ToastLevel::Error);
        let p = message_log_path(d.path());
        let mut body = std::fs::read_to_string(&p).unwrap();
        body.push_str("{\"at\":123,\"level\":\"err");
        std::fs::write(&p, body).unwrap();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.load_persisted_messages(200);
        assert_eq!(
            app2.message_log.len(),
            2,
            "a torn line cost us the history: {:?}",
            app2.message_log
        );
    }

    #[test]
    fn entries_older_than_the_age_limit_are_dropped_and_the_file_shrinks() {
        let (d, _app) = app();
        let p = message_log_path(d.path());
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        let old = now_unix() - (MAX_AGE_SECS + 60);
        let recent = now_unix();
        std::fs::write(
            &p,
            format!(
                "{{\"at\":{old},\"level\":\"info\",\"text\":\"ancient\"}}\n\
                 {{\"at\":{recent},\"level\":\"info\",\"text\":\"fresh\"}}\n"
            ),
        )
        .unwrap();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.load_persisted_messages(200);
        assert_eq!(app2.message_log.len(), 1, "{:?}", app2.message_log);
        assert_eq!(app2.message_log[0].text, "fresh");
        // And the pruning must reach DISK, or the file grows forever.
        let on_disk = std::fs::read_to_string(&p).unwrap();
        assert!(
            !on_disk.contains("ancient"),
            "pruned in memory only — the file still grows:\n{on_disk}"
        );
    }

    /// The badge is the only on-screen sign the log has anything in it,
    /// so it must appear when it should and vanish when it should not.
    #[test]
    fn the_badge_appears_only_when_there_is_something_unread() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        let mut term = Terminal::new(TestBackend::new(140, 12)).unwrap();

        let screen = |t: &mut Terminal<TestBackend>, app: &mut App| -> String {
            t.draw(|fr| crate::ui::draw(fr, app)).unwrap();
            let buf = t.backend().buffer();
            (0..12)
                .map(|y| (0..140).map(|x| buf[(x, y)].symbol()).collect::<String>())
                .collect::<Vec<_>>()
                .join("\n")
        };

        let before = screen(&mut term, &mut app);
        assert!(
            !before.contains("! 1"),
            "badge painted with nothing unread:\n{before}"
        );

        app.toast_leveled("could not save", ToastLevel::Error);
        let after = screen(&mut term, &mut app);
        assert!(after.contains("! 1"), "no badge after an error:\n{after}");
        // And it must register a click target — a badge you cannot click
        // is just decoration.
        assert!(
            app.rects.statusline_notif_chip.is_some(),
            "the badge registered no click rect"
        );

        app.mark_messages_seen();
        let cleared = screen(&mut term, &mut app);
        assert!(
            !cleared.contains("! 1"),
            "badge survived reading the history:\n{cleared}"
        );
        assert!(
            app.rects.statusline_notif_chip.is_none(),
            "a hidden badge left a live click rect behind"
        );
    }

    /// Info must not light the badge. One that flashes for "saved
    /// foo.rs" trains you to ignore it, and then it is not there when an
    /// error arrives.
    #[test]
    fn only_warnings_and_errors_count_as_unread() {
        let (_d, mut app) = app();
        app.toast_leveled("saved foo.rs", ToastLevel::Info);
        assert_eq!(app.unread_message_count(), 0, "info lit the badge");
        app.toast_leveled("could not save", ToastLevel::Error);
        assert_eq!(app.unread_message_count(), 1);
    }

    #[test]
    fn opening_the_history_clears_the_unread_count() {
        let (_d, mut app) = app();
        app.toast_leveled("bad", ToastLevel::Error);
        assert_eq!(app.unread_message_count(), 1, "precondition");
        app.mark_messages_seen();
        assert_eq!(
            app.unread_message_count(),
            0,
            "the badge stayed lit after the history was read"
        );
        // A NEW problem must light it again.
        app.toast_leveled("worse", ToastLevel::Error);
        assert_eq!(app.unread_message_count(), 1, "the badge stopped working");
    }
}
