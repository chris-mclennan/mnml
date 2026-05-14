//! `git stash` shell-outs — push (with an optional message) and pop. The
//! always-include-untracked flag (`-u`) is on by default since the most
//! frustrating "stash didn't catch my new file" surprise is exactly that.

use std::path::Path;
use std::process::Command;

/// Run `git stash push -u [-m <message>]` in `workspace`. Returns git's
/// first informational line on success ("Saved working directory and index
/// state ..."), or its first stderr line on failure.
pub fn push(workspace: &Path, message: Option<&str>) -> Result<String, String> {
    let mut args: Vec<&str> = vec!["stash", "push", "-u"];
    if let Some(m) = message
        && !m.trim().is_empty()
    {
        args.push("-m");
        args.push(m);
    }
    let out = Command::new("git")
        .args(&args)
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("stashed")
            .trim()
            .to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git stash push failed")
            .trim()
            .to_string())
    }
}

/// Run `git stash pop` in `workspace`. Returns git's last informational line
/// on success ("On branch ..."), or its first stderr line on failure (which
/// is also where merge-conflict warnings land).
pub fn pop(workspace: &Path) -> Result<String, String> {
    let out = Command::new("git")
        .args(["stash", "pop"])
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .rfind(|l| !l.trim().is_empty())
            .unwrap_or("popped")
            .trim()
            .to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git stash pop failed")
            .trim()
            .to_string())
    }
}
