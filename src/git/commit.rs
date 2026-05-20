//! `git commit -m <message>` — the in-IDE commit. Commits whatever is already
//! staged; surfacing "nothing staged" is left to the caller (`git commit`
//! reports it). Stage hunks via the diff pane (`git.stage_hunk`) first.

use std::path::Path;
use std::process::Command;

/// Run `git commit -m <message>` in `workspace`. `Ok` carries a one-line summary
/// (git's `[branch sha] subject`); `Err` carries git's first error line.
pub fn commit(workspace: &Path, message: &str) -> Result<String, String> {
    run_commit(workspace, &["commit", "-m", message])
}

/// Run `git commit --amend -m <message>` — rewrite HEAD's message in place
/// without changing its tree. Safe on HEAD even if it's already published, in
/// the sense that nothing is destroyed locally (the old commit lingers as a
/// reflog entry); the user has to push --force-with-lease to share it.
pub fn amend(workspace: &Path, message: &str) -> Result<String, String> {
    run_commit(workspace, &["commit", "--amend", "-m", message])
}

/// `git show HEAD` for use as input to an "AI: rewrite this commit message"
/// prompt. Returns the patch text on success; the error path is best-effort —
/// "no HEAD yet" / "not a repo" / `git` not on PATH all collapse to `Err`.
pub fn show_head(workspace: &Path) -> Result<String, String> {
    let out = Command::new("git")
        .args(["show", "HEAD", "--no-color", "--stat", "-p"])
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git show failed")
            .trim()
            .to_string())
    }
}

/// `git cherry-pick <hash>` — apply the commit on top of HEAD. Conflicts
/// land in the error path with git's own message (the user resolves +
/// runs `git cherry-pick --continue` from a pty).
pub fn cherry_pick(workspace: &Path, hash: &str) -> Result<String, String> {
    run_commit(workspace, &["cherry-pick", hash])
}

/// `git revert --no-edit <hash>` — create a new commit that undoes
/// `hash`. `--no-edit` reuses the default `Revert "..."` message without
/// opening an editor. Conflicts land in the error path.
pub fn revert(workspace: &Path, hash: &str) -> Result<String, String> {
    run_commit(workspace, &["revert", "--no-edit", hash])
}

/// `git log -1 --pretty=%B HEAD` — the existing HEAD message (subject + body).
/// Empty / error ⇒ empty string. Used to seed the recompose prompt's "current
/// message" context for the AI.
pub fn head_message(workspace: &Path) -> String {
    Command::new("git")
        .args(["log", "-1", "--pretty=%B", "HEAD"])
        .current_dir(workspace)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// `git rev-parse <rev>` — resolve a revspec (`HEAD`, `HEAD~1`, a
/// hash, …) to a full commit hash. `None` when the revspec doesn't
/// resolve (empty repo, `HEAD~1` on a root commit, not a repo).
pub fn rev_parse(workspace: &Path, rev: &str) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "--verify", "--quiet", rev])
        .current_dir(workspace)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let h = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!h.is_empty()).then_some(h)
}

/// `git reset --soft <rev>` — move the current branch ref to `<rev>`
/// without touching the index or working tree. The vehicle for
/// undo/redo of a commit: every change the commit introduced stays
/// staged, ready to re-commit. Non-destructive.
pub fn reset_soft(workspace: &Path, rev: &str) -> Result<(), String> {
    let out = Command::new("git")
        .args(["reset", "--soft", rev])
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or("git reset failed")
            .to_string())
    }
}

fn run_commit(workspace: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    if out.status.success() {
        return Ok(stdout
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("committed")
            .trim()
            .to_string());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let pick = |s: &str| {
        s.lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .map(str::to_string)
    };
    Err(pick(&stderr)
        .or_else(|| pick(&stdout))
        .unwrap_or_else(|| "git commit failed".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn init_repo() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        // git init + identity (CI / sandboxed shells may lack a global one).
        for args in [
            &["init", "-q"][..],
            &["config", "user.email", "t@example.com"][..],
            &["config", "user.name", "Test"][..],
            &["config", "commit.gpgsign", "false"][..],
        ] {
            let _ = Command::new("git")
                .args(args)
                .current_dir(d.path())
                .output();
        }
        d
    }

    fn git_ok(d: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args(args)
            .current_dir(d)
            .output()
            .expect("git");
        assert!(out.status.success(), "git {args:?} failed: {out:?}");
    }

    #[test]
    fn amend_rewrites_head_message() {
        let d = init_repo();
        std::fs::write(d.path().join("a.txt"), "alpha").unwrap();
        git_ok(d.path(), &["add", "."]);
        commit(d.path(), "first commit").unwrap();

        // Sanity: HEAD message is "first commit".
        assert_eq!(head_message(d.path()), "first commit");

        // Amend it.
        amend(d.path(), "rewritten subject").unwrap();
        assert_eq!(head_message(d.path()), "rewritten subject");

        // And `show_head` still produces a patch (the tree didn't change, but
        // the commit object is fresh — the patch is still present).
        let s = show_head(d.path()).unwrap();
        assert!(s.contains("a.txt"));
    }
}
