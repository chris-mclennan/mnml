//! `git fetch` / `git pull` / `git push` — the daily sync triad.
//!
//! All three shell out to the system `git` and return `(summary, error)`
//! tuples in the established style. The caller (the App) routes the
//! summary to a toast.
//!
//! Safety notes:
//! - `fetch` is always safe (read-only). Default `--all --prune` so every
//!   tracked remote's refs are refreshed and gone-upstream branches drop
//!   their tracking marks.
//! - `pull` runs `git pull --ff-only` to avoid surprise merge commits.
//!   Conflicts / non-fast-forward cases land in the error path with
//!   git's own message so the user knows to fall back to manual merge.
//! - `push` runs `git push` (no `--force`). Refuses to bypass safety
//!   even on user request — force-push is intentionally not exposed
//!   through the palette; users who really need it can drop to a pty.

use std::path::Path;
use std::process::Command;

fn run(workspace: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(workspace)
        .output()
        .map_err(|e| format!("spawn git: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let pick_line = |s: &str| {
        s.lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .map(str::to_string)
    };
    if out.status.success() {
        // Git tends to write progress + final summary to stderr; pick from
        // either with stdout-first preference.
        let last_stdout = stdout
            .lines()
            .rfind(|l| !l.trim().is_empty())
            .map(str::trim);
        let last_stderr = stderr
            .lines()
            .rfind(|l| !l.trim().is_empty())
            .map(str::trim);
        Ok(last_stdout.or(last_stderr).unwrap_or("ok").to_string())
    } else {
        Err(pick_line(&stderr)
            .or_else(|| pick_line(&stdout))
            .unwrap_or_else(|| format!("git {} failed", args.first().copied().unwrap_or(""))))
    }
}

/// `git fetch --all --prune` — refresh every tracked remote's refs +
/// drop tracking marks for branches that disappeared upstream.
pub fn fetch_all(workspace: &Path) -> Result<String, String> {
    run(workspace, &["fetch", "--all", "--prune"])
}

/// `git pull --ff-only` — pull the upstream of the current branch but
/// only if it fast-forwards. Refuses on divergent histories so the user
/// has to choose between merge / rebase manually.
pub fn pull_ff_only(workspace: &Path) -> Result<String, String> {
    run(workspace, &["pull", "--ff-only"])
}

/// `git push` — publish the current branch to its tracked upstream. No
/// `--force` / `--force-with-lease`; users who need that drop to a pty.
pub fn push(workspace: &Path) -> Result<String, String> {
    run(workspace, &["push"])
}

/// `git push --set-upstream origin <current>` — first-time push for a
/// branch that doesn't yet have an upstream. The caller (App) detects
/// the "no upstream" error from `push` and falls back to this when the
/// current branch is non-empty.
pub fn push_set_upstream(workspace: &Path, branch: &str) -> Result<String, String> {
    run(workspace, &["push", "--set-upstream", "origin", branch])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn init_bare(d: &Path) {
        let _ = Command::new("git")
            .args(["init", "--bare", "-q"])
            .current_dir(d)
            .output();
    }

    fn init_repo(d: &Path) {
        for args in [
            &["init", "-q", "-b", "main"][..],
            &["config", "user.email", "t@example.com"][..],
            &["config", "user.name", "Test"][..],
            &["config", "commit.gpgsign", "false"][..],
        ] {
            let _ = Command::new("git").args(args).current_dir(d).output();
        }
    }

    #[test]
    fn fetch_all_on_repo_without_remote_succeeds_silently() {
        // No remote configured → fetch --all is a no-op success.
        let d = tempfile::tempdir().unwrap();
        init_repo(d.path());
        let r = fetch_all(d.path());
        assert!(r.is_ok(), "{r:?}");
    }

    #[test]
    fn push_set_upstream_creates_remote_branch() {
        let bare = tempfile::tempdir().unwrap();
        init_bare(bare.path());
        let work = tempfile::tempdir().unwrap();
        init_repo(work.path());
        // Wire `origin` to the bare repo + make a commit.
        let _ = Command::new("git")
            .args(["remote", "add", "origin", bare.path().to_str().unwrap()])
            .current_dir(work.path())
            .output();
        std::fs::write(work.path().join("a.txt"), "alpha").unwrap();
        let _ = Command::new("git")
            .args(["add", "."])
            .current_dir(work.path())
            .output();
        let _ = Command::new("git")
            .args(["commit", "-m", "first"])
            .current_dir(work.path())
            .output();
        let r = push_set_upstream(work.path(), "main");
        assert!(r.is_ok(), "{r:?}");
    }
}
