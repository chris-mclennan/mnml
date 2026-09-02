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

/// The on-disk shape of one entry.
///
/// ONE definition, used by both the append path and the prune rewrite —
/// they had the format string each, and a future escaping fix landing in
/// only one would silently desync the two writers of the same file.
///
/// Field order is load-bearing: `text` is last, so a message whose own
/// content contains `"text":"` or `"level":"` cannot be found ahead of
/// the real field by `field()`'s first-match search.
fn format_entry(m: &LoggedMessage) -> String {
    format!(
        "{{\"at\":{},\"level\":\"{}\",\"text\":\"{}\"}}\n",
        m.at,
        level_str(m.level),
        esc(&m.text)
    )
}

/// One JSONL line → an entry, dropping anything older than `cutoff`.
///
/// `None` for a line that will not parse, which includes the truncated
/// final line a crash mid-write leaves. Skipping it beats failing the
/// load — that crash is the reason this file exists.
fn parse_line(l: &str, cutoff: u64) -> Option<LoggedMessage> {
    let at = num_field(l, "at")?;
    if at < cutoff {
        return None;
    }
    Some(LoggedMessage {
        text: unesc(field(l, "text")?),
        level: level_of(field(l, "level").unwrap_or("info")),
        at,
    })
}

/// Temp file plus rename. A truncating write interrupted midway leaves
/// an EMPTY file, losing the whole history to exactly the crash this log
/// exists to survive.
///
/// The temp name carries the pid: two mnml instances on one workspace is
/// a pattern this project expects, and a shared fixed name would let
/// them clobber each other's temp file mid-write.
fn write_atomically(path: &Path, body: String) {
    let tmp = path.with_extension(format!("jsonl.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, body).is_ok() && std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// How many appends before the file is pruned again.
const PRUNE_EVERY: usize = 200;

impl crate::app::App {
    /// Append one entry to the on-disk log.
    ///
    /// Failures are SILENT. A toast that cannot be written is not worth a
    /// second toast about the write failing — that path leads to a loop,
    /// since the failure toast would also try to write.
    pub fn persist_message(&mut self, m: &LoggedMessage) {
        if !self.persist_messages {
            return;
        }
        let path = message_log_path(&self.workspace);
        // Try the open FIRST and only create the directory if that
        // fails. `create_dir_all` on every toast is a wasted syscall
        // after the first, and this runs on the thread that renders.
        let line = format_entry(m);
        let open = || {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
        };
        let f = match open() {
            Ok(f) => Some(f),
            Err(_) => {
                let made = path
                    .parent()
                    .is_some_and(|d| std::fs::create_dir_all(d).is_ok());
                if made { open().ok() } else { None }
            }
        };
        if let Some(mut f) = f {
            let _ = f.write_all(line.as_bytes());
        }
        // Prune periodically, not only at startup. mnml sessions are
        // long-lived by design (`./run.sh watch`), and a chatty source —
        // the Claude usage endpoint 429s on a 5-minute poll across three
        // accounts — appends steadily. Pruning only on launch let the
        // file grow for the life of the session.
        self.messages_since_prune += 1;
        if self.messages_since_prune >= PRUNE_EVERY {
            self.messages_since_prune = 0;
            self.prune_persisted_messages(crate::app::MESSAGE_LOG_MAX);
        }
    }

    /// Drop stale and overflow entries from the FILE, leaving the
    /// in-memory log alone. Shared by the startup load and the periodic
    /// prune so the two cannot drift on what "stale" means.
    fn prune_persisted_messages(&self, cap: usize) {
        let path = message_log_path(&self.workspace);
        let Ok(body) = std::fs::read_to_string(&path) else {
            return;
        };
        let read_lines = body.lines().count();
        let cutoff = now_unix().saturating_sub(MAX_AGE_SECS);
        let mut kept: Vec<LoggedMessage> =
            body.lines().filter_map(|l| parse_line(l, cutoff)).collect();
        if kept.len() > cap {
            kept.drain(..kept.len() - cap);
        }
        if kept.len() != read_lines {
            write_atomically(&path, kept.iter().map(format_entry).collect());
        }
    }

    /// Read the persisted log into `message_log`, pruning as it goes.
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
        let read_lines = body.lines().count();
        let cutoff = now_unix().saturating_sub(MAX_AGE_SECS);
        let mut out: Vec<LoggedMessage> =
            body.lines().filter_map(|l| parse_line(l, cutoff)).collect();
        if out.len() > cap {
            out.drain(..out.len() - cap);
        }
        if out.len() != read_lines {
            write_atomically(&path, out.iter().map(format_entry).collect());
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
        self.unread_errors = 0;
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

    /// Review finding — the gap that made the whole feature miss its
    /// most important case.
    ///
    /// `notify()` routes EVERY `ToastLevel::Error` through
    /// `toast_persistent`, which pushed to `message_log` but never
    /// persisted and never counted. So an integration error — pinned
    /// precisely because it matters — reached neither the on-disk
    /// history nor the badge. Nothing tested `notify()`, only
    /// `toast_leveled`, which is how it shipped.
    #[test]
    fn a_pinned_error_reaches_the_disk_and_the_badge() {
        let (d, mut app) = app();
        app.toast_persistent("some-id", "integration exploded", ToastLevel::Error);

        assert_eq!(
            app.unread_message_count(),
            1,
            "a pinned error did not light the badge"
        );
        let on_disk = std::fs::read_to_string(message_log_path(d.path()))
            .expect("a pinned error was never written to disk");
        assert!(
            on_disk.contains("integration exploded"),
            "persisted file is missing the pinned error:\n{on_disk}"
        );
    }

    /// Review finding — the badge painted the WRONG COLOUR.
    ///
    /// It re-scanned `message_log.iter().rev().take(unread)`, but
    /// `unread` counts only warnings and errors while the log also holds
    /// Info. One Info toast after an error pushed the error out of the
    /// window, so an unread error rendered in the warning colour.
    #[test]
    fn an_info_toast_after_an_error_does_not_downgrade_the_badge() {
        let (_d, mut app) = app();
        app.toast_leveled("could not save", ToastLevel::Error);
        app.toast_leveled("saved other.rs", ToastLevel::Info);

        assert_eq!(app.unread_message_count(), 1, "info was counted as unread");
        assert!(
            app.unread_errors > 0,
            "an unread error was forgotten, so the badge paints as a warning"
        );
    }

    /// The unread count must never promise more than the history can
    /// show — the log is capped, so a count above the cap points at
    /// entries the picker has already dropped.
    #[test]
    fn the_unread_count_cannot_exceed_what_the_log_holds() {
        let (_d, mut app) = app();
        for i in 0..(crate::app::MESSAGE_LOG_MAX + 50) {
            app.toast_leveled(format!("problem {i}"), ToastLevel::Warn);
        }
        assert!(
            app.unread_message_count() <= app.message_log.len(),
            "unread {} > {} entries actually in the log",
            app.unread_message_count(),
            app.message_log.len()
        );
    }

    /// The prune rewrite must not be able to leave an empty file. A
    /// plain truncating write interrupted midway loses the ENTIRE
    /// history — to exactly the crash this log exists to survive.
    #[test]
    fn the_prune_rewrite_goes_through_a_temp_file() {
        let (d, _app) = app();
        let p = message_log_path(d.path());
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        let old = now_unix() - (MAX_AGE_SECS + 60);
        let recent = now_unix();
        std::fs::write(
            &p,
            format!(
                "{{\"at\":{old},\"level\":\"info\",\"text\":\"ancient\"}}\n\
                 {{\"at\":{recent},\"level\":\"error\",\"text\":\"keep me\"}}\n"
            ),
        )
        .unwrap();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.load_persisted_messages(200);

        let on_disk = std::fs::read_to_string(&p).unwrap();
        assert!(on_disk.contains("keep me"), "pruning lost a live entry");
        assert!(!on_disk.contains("ancient"), "pruning did not reach disk");
        // No debris left behind.
        assert!(
            !p.with_extension("jsonl.tmp").exists(),
            "the temp file was not renamed away"
        );
    }

    /// Review finding — the prune only ran at startup, so a long-lived
    /// session (which is how mnml is normally used) appended forever.
    #[test]
    fn the_file_is_pruned_during_a_session_not_only_at_startup() {
        let (d, mut app) = app();
        // Enough to cross the prune threshold TWICE. The first crossing
        // is a no-op (the file is still under the cap), so a test that
        // only reached it proves nothing — the first version of this
        // test passed with pruning disabled entirely.
        let n = PRUNE_EVERY * 3;
        for i in 0..n {
            app.toast_leveled(format!("msg {i}"), ToastLevel::Info);
        }
        let lines = std::fs::read_to_string(message_log_path(d.path()))
            .unwrap()
            .lines()
            .count();
        // Pruned, the file settles at the cap (200). Unpruned it holds
        // every entry (600). The bound sits clear of both — an earlier
        // version picked one BELOW the pruned result, so it failed
        // whether the fix was present or not.
        assert!(
            lines <= crate::app::MESSAGE_LOG_MAX + 50,
            "wrote {n} entries and the file still holds {lines} lines — it \
             is never pruned mid-session"
        );
    }

    /// Review finding — a pinned toast refreshed in place by repeat
    /// calls with the same id wrote a new disk line and bumped the badge
    /// each time. A flaky integration polling every few minutes turned
    /// the badge into a poll counter and flooded the log with restated
    /// duplicates, evicting real messages.
    #[test]
    fn restating_the_same_pinned_message_does_not_inflate_the_badge() {
        let (_d, mut app) = app();
        for _ in 0..5 {
            app.toast_persistent("claude-usage", "HTTP 429", ToastLevel::Error);
        }
        assert_eq!(
            app.unread_message_count(),
            1,
            "five restatements of one problem counted as {} unread",
            app.unread_message_count()
        );

        // A CHANGED message on the same id is a new fact and must count.
        app.toast_persistent("claude-usage", "HTTP 500", ToastLevel::Error);
        assert_eq!(
            app.unread_message_count(),
            2,
            "a genuinely new message on the same id was swallowed"
        );
    }

    /// Review finding — `--sandbox` refuses to READ the log so the user
    /// gets a brand-new-user view, but still wrote to it. A throwaway
    /// session on a real workspace permanently contaminated the next
    /// normal session with noise the sandbox never displayed.
    #[test]
    fn sandbox_mode_does_not_write_to_the_workspaces_history() {
        let (d, mut app) = app();
        app.persist_messages = false;
        app.toast_leveled("throwaway", ToastLevel::Error);
        assert!(
            !message_log_path(d.path()).exists(),
            "sandbox wrote into the real workspace's history"
        );
        // The in-memory log still works — only the disk is off limits.
        assert!(app.message_log.iter().any(|m| m.text == "throwaway"));
    }

    /// The COUNT is the sign the log has something unread, so it must
    /// appear when it should and clear when it should not.
    ///
    /// This test asserted the bell itself vanished at zero. That was the
    /// behaviour until 2026-09-02, when it gained three states: the bell
    /// is now always present (quiet when idle) and only the count comes
    /// and goes.
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
        // The bell itself REMAINS, and stays clickable — it is how you
        // reach the history when there is nothing new. Only the COUNT
        // clears. It used to disappear entirely at zero; three states
        // replaced that so the lane stops reflowing on every message
        // (user ask 2026-09-02).
        assert!(
            app.rects.statusline_notif_chip.is_some(),
            "the idle bell left no click rect — the history becomes \
             unreachable from the statusline once you have read it"
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
