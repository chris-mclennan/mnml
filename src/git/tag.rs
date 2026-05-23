//! `git tag` — create / delete tags + push them upstream.
//!
//! Tags name a specific commit (release marker, build pin, etc.). All three
//! ops shell out to `git` and return `(summary, error)` tuples in the same
//! style as `sync.rs`.

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

/// `git tag <name> [<commit>]` — lightweight tag pointing at `commit` (or HEAD
/// when `commit` is None).
#[allow(dead_code)]
pub fn create_lightweight(
    workspace: &Path,
    name: &str,
    commit: Option<&str>,
) -> Result<String, String> {
    let mut args: Vec<&str> = vec!["tag", name];
    if let Some(c) = commit {
        args.push(c);
    }
    run(workspace, &args)?;
    Ok(match commit {
        Some(c) => format!("tagged {} @ {}", name, &c[..c.len().min(9)]),
        None => format!("tagged {name} @ HEAD"),
    })
}

/// `git tag -a <name> -m <msg> [<commit>]` — annotated tag (carries a message,
/// author, timestamp; shows up in `git log` more prominently than lightweight).
pub fn create_annotated(
    workspace: &Path,
    name: &str,
    message: &str,
    commit: Option<&str>,
) -> Result<String, String> {
    let mut args: Vec<&str> = vec!["tag", "-a", name, "-m", message];
    if let Some(c) = commit {
        args.push(c);
    }
    run(workspace, &args)?;
    Ok(match commit {
        Some(c) => format!("tagged {} @ {} (annotated)", name, &c[..c.len().min(9)]),
        None => format!("tagged {name} @ HEAD (annotated)"),
    })
}

/// `git tag -d <name>` — delete the local tag. To remove an already-pushed tag
/// from the remote, call `delete_remote` separately.
pub fn delete_local(workspace: &Path, name: &str) -> Result<String, String> {
    run(workspace, &["tag", "-d", name])?;
    Ok(format!("deleted tag {name}"))
}

/// `git push origin :refs/tags/<name>` — drop the tag from the remote so a
/// fresh local tag with the same name isn't rejected on the next `push --tags`.
#[allow(dead_code)]
pub fn delete_remote(workspace: &Path, name: &str) -> Result<String, String> {
    run(
        workspace,
        &["push", "origin", &format!(":refs/tags/{name}")],
    )
}

/// `git push --tags` — push every local tag to `origin`. No `--force`; an
/// existing-but-different remote tag will refuse and the user can drop to a
/// pty if they really need to overwrite.
pub fn push_all(workspace: &Path) -> Result<String, String> {
    run(workspace, &["push", "--tags"])
}

/// `git tag --list` — every local tag (newest-creation first by `creatordate`).
pub fn list(workspace: &Path) -> Vec<String> {
    let out = match Command::new("git")
        .args(["tag", "--list", "--sort=-creatordate"])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
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
            .args(["commit", "-qm", "init"])
            .current_dir(d)
            .output();
    }

    #[test]
    fn create_and_list_lightweight_tag() {
        let dir = tempfile::tempdir().unwrap();
        init_repo(dir.path());
        let r = create_lightweight(dir.path(), "v1.0", None);
        assert!(r.is_ok(), "create: {:?}", r);
        let tags = list(dir.path());
        assert!(tags.iter().any(|t| t == "v1.0"));
    }

    #[test]
    fn create_annotated_and_delete() {
        let dir = tempfile::tempdir().unwrap();
        init_repo(dir.path());
        assert!(create_annotated(dir.path(), "v2.0", "release 2.0", None).is_ok());
        assert!(list(dir.path()).iter().any(|t| t == "v2.0"));
        assert!(delete_local(dir.path(), "v2.0").is_ok());
        assert!(!list(dir.path()).iter().any(|t| t == "v2.0"));
    }

    #[test]
    fn create_tag_on_specific_commit() {
        let dir = tempfile::tempdir().unwrap();
        init_repo(dir.path());
        let sha_out = Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        let sha = String::from_utf8_lossy(&sha_out.stdout).trim().to_string();
        assert!(create_lightweight(dir.path(), "v3.0", Some(&sha)).is_ok());
        assert!(list(dir.path()).iter().any(|t| t == "v3.0"));
    }
}
