//! `git reflog` reader — the "where did HEAD just go?" recovery surface.
//! Each entry has a `HEAD@{N}` selector, a short SHA, an operation
//! label (`commit`, `checkout`, `rebase`, …), and the action description.
//! Useful for "I just rebased and lost a commit, find HEAD before the
//! rebase" flows — picking an entry opens its commit as a diff so the
//! user can `git reset --hard HEAD@{N}` from a pty if they want it back.

use std::path::Path;
use std::process::Command;

/// One reflog entry. `selector` is the `HEAD@{N}` form, useful for any
/// `git reset --hard <selector>` follow-up. `op` is the operation tag
/// (e.g. `commit`, `commit (amend)`, `checkout`, `rebase: aborting`).
#[derive(Debug, Clone)]
pub struct ReflogEntry {
    /// `HEAD@{N}` — vim-compatible selector that survives further
    /// reflog moves.
    pub selector: String,
    /// 9-char SHA prefix.
    pub short_hash: String,
    /// Full SHA — for opening the commit diff or copying.
    pub full_hash: String,
    /// "commit", "checkout: moving from X to Y", "rebase: aborting", …
    pub op: String,
    /// The subject line of the change (or the action description for
    /// non-commit ops).
    pub subject: String,
    /// Relative time string ("5 minutes ago", "2 days ago", …) — direct
    /// from `%gr`. Mirrored to a `String` since the renderer joins it
    /// into a label.
    pub relative_time: String,
}

/// Read up to `limit` reflog entries (newest first). Returns an empty
/// vec when there's no reflog yet (fresh clone) or git fails.
pub fn list(workspace: &Path, limit: usize) -> Vec<ReflogEntry> {
    let limit = limit.clamp(1, 1000);
    // `%H` full hash, `%h` short, `%gd` selector, `%gs` reflog subject,
    // `%gr` relative time — tab-separated.
    let fmt = "%H%x09%h%x09%gd%x09%gr%x09%gs";
    let out = match Command::new("git")
        .args([
            "reflog",
            &format!("-n{limit}"),
            &format!("--pretty=format:{fmt}"),
        ])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut parts = line.split('\t');
            let full_hash = parts.next()?.to_string();
            let short_hash = parts.next()?.to_string();
            let selector = parts.next()?.to_string();
            let relative_time = parts.next()?.to_string();
            let gs = parts.next()?.to_string();
            // `%gs` is `"<op>: <subject>"` for most ops; for amend it's
            // `"commit (amend): <subject>"`. Split on the first `: ` to
            // separate op from subject.
            let (op, subject) = match gs.split_once(": ") {
                Some((o, s)) => (o.to_string(), s.to_string()),
                None => (gs.clone(), String::new()),
            };
            Some(ReflogEntry {
                selector,
                short_hash,
                full_hash,
                op,
                subject,
                relative_time,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn init_repo(d: &Path) {
        for args in [
            &["init", "-q", "-b", "main"][..],
            &["config", "user.email", "t@example.com"][..],
            &["config", "user.name", "Test"][..],
            &["config", "commit.gpgsign", "false"][..],
        ] {
            let _ = Command::new("git").args(args).current_dir(d).output();
        }
        std::fs::write(d.join("a.txt"), "hi").unwrap();
        let _ = Command::new("git")
            .args(["add", "-A"])
            .current_dir(d)
            .output();
        let _ = Command::new("git")
            .args(["commit", "-qm", "initial"])
            .current_dir(d)
            .output();
        std::fs::write(d.join("a.txt"), "hi2").unwrap();
        let _ = Command::new("git")
            .args(["commit", "-aqm", "second"])
            .current_dir(d)
            .output();
    }

    #[test]
    fn list_returns_reflog_entries_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        init_repo(dir.path());
        let entries = list(dir.path(), 10);
        assert!(
            entries.len() >= 2,
            "expected ≥ 2 entries, got {}",
            entries.len()
        );
        // Most recent = the "second" commit, with selector HEAD@{0}.
        assert_eq!(entries[0].selector, "HEAD@{0}");
        assert!(entries[0].subject.contains("second") || entries[0].op.contains("second"));
    }

    #[test]
    fn list_returns_empty_for_non_repo() {
        let dir = tempfile::tempdir().unwrap();
        let entries = list(dir.path(), 10);
        assert!(entries.is_empty());
    }
}
