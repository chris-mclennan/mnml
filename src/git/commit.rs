//! `git commit -m <message>` — the in-IDE commit. Commits whatever is already
//! staged; surfacing "nothing staged" is left to the caller (`git commit`
//! reports it). Stage hunks via the diff pane (`git.stage_hunk`) first.

use std::path::Path;
use std::process::Command;

/// Run `git commit -m <message>` in `workspace`. `Ok` carries a one-line summary
/// (git's `[branch sha] subject`); `Err` carries git's first error line.
pub fn commit(workspace: &Path, message: &str) -> Result<String, String> {
    let out = Command::new("git")
        .args(["commit", "-m", message])
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
