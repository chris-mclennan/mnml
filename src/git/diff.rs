//! Parsing `git diff` output. Right now: per-file *line signs* (added /
//! modified / removed) for the editor gutter, computed from
//! `git diff HEAD --unified=0`. (The diff-*pane* with hunk staging will reuse
//! the fuller hunk parser added later.)

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The kind of change a gutter sign marks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignKind {
    Added,
    Modified,
    Removed,
}

/// Per-file gutter signs, keyed by absolute path. Each `Vec` is sorted by line
/// (0-based). `Added`/`Modified` get one entry per affected line; `Removed` gets
/// one entry on the line just above where lines were deleted.
pub type LineSigns = HashMap<PathBuf, Vec<(usize, SignKind)>>;

/// Compute gutter signs for everything that differs from `HEAD`. Empty (never
/// errors) if `git` is missing, this isn't a repo, or there's no `HEAD` yet.
pub fn line_signs(workspace: &Path) -> LineSigns {
    let Ok(out) = Command::new("git")
        .args(["diff", "HEAD", "--unified=0", "--no-color", "--", "."])
        .current_dir(workspace)
        .output()
    else {
        return LineSigns::new();
    };
    if !out.status.success() {
        return LineSigns::new();
    }
    parse(&String::from_utf8_lossy(&out.stdout), workspace)
}

fn flush(signs: &mut LineSigns, path: &mut Option<PathBuf>, cur: &mut Vec<(usize, SignKind)>) {
    if let Some(p) = path.take() {
        let mut v = std::mem::take(cur);
        v.sort_unstable_by_key(|&(l, _)| l);
        v.dedup();
        if !v.is_empty() {
            signs.insert(p, v);
        }
    } else {
        cur.clear();
    }
}

fn parse(diff: &str, workspace: &Path) -> LineSigns {
    let mut signs: LineSigns = HashMap::new();
    let mut cur: Vec<(usize, SignKind)> = Vec::new();
    let mut cur_path: Option<PathBuf> = None;

    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("+++ ") {
            // "+++ b/path/to/file" — or "/dev/null" for a deleted file.
            flush(&mut signs, &mut cur_path, &mut cur);
            cur_path = if rest == "/dev/null" {
                None
            } else {
                Some(workspace.join(rest.strip_prefix("b/").unwrap_or(rest)))
            };
        } else if cur_path.is_some()
            && let Some(rest) = line.strip_prefix("@@ ")
        {
            // "@@ -A[,B] +C[,D] @@ …"
            let Some(((_old_start, old_count), (new_start, new_count))) = parse_hunk_header(rest)
            else {
                continue;
            };
            if new_count == 0 {
                // pure deletion: mark the line just above (0-based), clamped.
                let l = new_start.saturating_sub(1).max(1) - 1;
                cur.push((l, SignKind::Removed));
            } else {
                let kind = if old_count == 0 {
                    SignKind::Added
                } else {
                    SignKind::Modified
                };
                for n in 0..new_count {
                    cur.push((new_start.saturating_sub(1) + n, kind));
                }
            }
        }
    }
    flush(&mut signs, &mut cur_path, &mut cur);
    signs
}

/// `"-A[,B] +C[,D] @@ …"` → `((A, B), (C, D))` (counts default to 1).
fn parse_hunk_header(s: &str) -> Option<((usize, usize), (usize, usize))> {
    let mut parts = s.split_whitespace();
    let minus = parts.next()?.strip_prefix('-')?;
    let plus = parts.next()?.strip_prefix('+')?;
    let pair = |t: &str| -> Option<(usize, usize)> {
        match t.split_once(',') {
            Some((a, b)) => Some((a.parse().ok()?, b.parse().ok()?)),
            None => Some((t.parse().ok()?, 1)),
        }
    };
    Some((pair(minus)?, pair(plus)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_added_modified_removed() {
        let ws = Path::new("/repo");
        let diff = "\
diff --git a/foo.rs b/foo.rs
index e69de29..1234567 100644
--- a/foo.rs
+++ b/foo.rs
@@ -0,0 +1,2 @@
+line one
+line two
@@ -10 +12,1 @@
-old
+new
@@ -20,2 +22,0 @@
-gone a
-gone b
";
        let s = parse(diff, ws);
        let v = s.get(&ws.join("foo.rs")).unwrap();
        // added: new lines 1,2 (1-based) → 0-based 0,1
        assert!(v.contains(&(0, SignKind::Added)));
        assert!(v.contains(&(1, SignKind::Added)));
        // modified: new line 12 (1-based) → 0-based 11
        assert!(v.contains(&(11, SignKind::Modified)));
        // removed: deletion at new line 22 (1-based) → marker around 0-based 20
        assert!(v.iter().any(|&(_, k)| k == SignKind::Removed));
        // sorted
        assert!(v.windows(2).all(|w| w[0].0 <= w[1].0));
    }

    #[test]
    fn dev_null_target_skipped() {
        let ws = Path::new("/repo");
        let diff = "\
diff --git a/del.txt b/del.txt
--- a/del.txt
+++ /dev/null
@@ -1,3 +0,0 @@
-a
-b
-c
";
        let s = parse(diff, ws);
        assert!(s.is_empty());
    }
}
