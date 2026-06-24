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

/// One entry from `git stash list`. `stash_ref` is the `stash@{N}` form
/// used to address it for apply / drop / show. `branch` is the branch the
/// stash was created on (parsed from the standard "WIP on branch:" /
/// "On branch:" prefix). `subject` is the commit subject or message.
#[derive(Debug, Clone)]
pub struct StashEntry {
    pub stash_ref: String,
    pub branch: String,
    pub subject: String,
}

/// List every stash via `git stash list`. Returns an empty vec when
/// there are no stashes (or git fails). Each line of the form
/// `stash@{0}: WIP on main: deadbeef subject` parses into one entry.
pub fn list(workspace: &Path) -> Vec<StashEntry> {
    let out = match Command::new("git")
        .args(["stash", "list", "--pretty=%gd%x09%gs"])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let (refname, message) = line.split_once('\t')?;
            // message: "WIP on <branch>: <hash> <subject>" or "On <branch>: <message>"
            let (branch, subject) = parse_stash_message(message);
            Some(StashEntry {
                stash_ref: refname.trim().to_string(),
                branch,
                subject,
            })
        })
        .collect()
}

/// Split a `git stash list --pretty=%gs` message into `(branch, subject)`.
/// Handles both auto-generated ("WIP on main: deadbeef subject") and
/// user-message ("On main: explicit message") forms.
fn parse_stash_message(msg: &str) -> (String, String) {
    let trimmed = msg.trim_start_matches("WIP on ").trim_start_matches("On ");
    if let Some((branch, rest)) = trimmed.split_once(':') {
        let rest = rest.trim();
        // For WIP form, strip the leading short-hash if present.
        let rest_no_hash = rest.split_once(' ').map(|(h, s)| {
            if h.len() >= 7 && h.chars().all(|c| c.is_ascii_hexdigit()) {
                s
            } else {
                rest
            }
        });
        return (
            branch.trim().to_string(),
            rest_no_hash.unwrap_or(rest).to_string(),
        );
    }
    (String::new(), trimmed.to_string())
}

/// `git stash pop <ref>` — apply + drop the named stash (vs the bare
/// `pop` above which always targets the top of the stash list).
pub fn pop_ref(workspace: &Path, stash_ref: &str) -> Result<String, String> {
    let out = Command::new("git")
        .args(["stash", "pop", stash_ref])
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(format!("popped {stash_ref}"))
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git stash pop failed")
            .trim()
            .to_string())
    }
}

/// `git stash apply <ref>` — apply the named stash, keeping it in the
/// stash list (unlike `pop`).
pub fn apply(workspace: &Path, stash_ref: &str) -> Result<String, String> {
    let out = Command::new("git")
        .args(["stash", "apply", stash_ref])
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(format!("applied {stash_ref}"))
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git stash apply failed")
            .trim()
            .to_string())
    }
}

/// `git stash drop <ref>` — drop the named stash from the stash list
/// without applying. Indices shift: dropping `stash@{0}` makes
/// `stash@{1}` the new `stash@{0}`, etc.
pub fn drop_stash(workspace: &Path, stash_ref: &str) -> Result<String, String> {
    let out = Command::new("git")
        .args(["stash", "drop", stash_ref])
        .current_dir(workspace)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(format!("dropped {stash_ref}"))
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("git stash drop failed")
            .trim()
            .to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wip_message_with_short_hash() {
        let (br, sub) = parse_stash_message("WIP on main: deadbee initial work");
        assert_eq!(br, "main");
        assert_eq!(sub, "initial work");
    }

    #[test]
    fn parses_user_message_form() {
        let (br, sub) = parse_stash_message("On feature/login: refactor auth");
        assert_eq!(br, "feature/login");
        assert_eq!(sub, "refactor auth");
    }

    #[test]
    fn parses_message_without_colon_safely() {
        let (br, sub) = parse_stash_message("some weird message");
        assert_eq!(br, "");
        assert_eq!(sub, "some weird message");
    }
}
