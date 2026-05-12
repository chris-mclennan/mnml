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

// ── full hunk parsing (for the diff pane + hunk staging) ───────────────

/// One line inside a hunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HunkLine {
    Context(String),
    Added(String),
    Removed(String),
    /// `\ No newline at end of file`.
    NoNewline,
}

/// One `@@ … @@` hunk plus everything `git apply --cached` needs to stage it on
/// its own: the minimal patch is `--- a/{file_rel}\n+++ b/{file_rel}\n{body}`.
#[derive(Debug, Clone)]
pub struct Hunk {
    /// Absolute path of the file this hunk touches.
    pub file: PathBuf,
    /// The diff path (e.g. `src/foo.rs`) — used to rebuild the patch header.
    pub file_rel: String,
    /// The `@@ -a,b +c,d @@ …` line, verbatim (trailing `\n` trimmed) — for display.
    pub header: String,
    /// 1-based start line in the new file (where the editor should jump to).
    pub new_start: usize,
    /// The `+`/`-`/context lines, parsed for display.
    pub lines: Vec<HunkLine>,
    /// The raw hunk text — the `@@ … @@\n` line plus its `+`/`-`/space lines,
    /// verbatim from `git diff` (so `git apply` sees exactly what it expects).
    pub body: String,
}

impl Hunk {
    /// The minimal patch that stages (or, reversed, unstages) just this hunk.
    pub fn patch(&self) -> String {
        format!("--- a/{0}\n+++ b/{0}\n{1}", self.file_rel, self.body)
    }
}

/// `git diff` for a single path (worktree vs index — i.e. unstaged changes).
pub fn diff_file(workspace: &Path, rel: &str) -> Vec<Hunk> {
    run_diff(workspace, &["diff", "--no-color", "--", rel])
}
/// `git diff` for the whole worktree (unstaged changes).
pub fn diff_worktree(workspace: &Path) -> Vec<Hunk> {
    run_diff(workspace, &["diff", "--no-color"])
}
/// `git diff --cached` — the staged changes (index vs HEAD).
pub fn diff_staged(workspace: &Path) -> Vec<Hunk> {
    run_diff(workspace, &["diff", "--no-color", "--cached"])
}

fn run_diff(workspace: &Path, args: &[&str]) -> Vec<Hunk> {
    let Ok(out) = Command::new("git")
        .args(args)
        .current_dir(workspace)
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    parse_hunks(&String::from_utf8_lossy(&out.stdout), workspace)
}

/// Stage (`reverse == false`) or unstage (`reverse == true`) a single hunk.
pub fn apply_hunk(workspace: &Path, hunk: &Hunk, reverse: bool) -> Result<(), String> {
    use std::io::Write;
    let mut args = vec!["apply", "--cached", "--unidiff-zero"];
    if reverse {
        args.push("--reverse");
    }
    args.push("-");
    let mut child = Command::new("git")
        .args(&args)
        .current_dir(workspace)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn git apply: {e}"))?;
    child
        .stdin
        .take()
        .ok_or("no stdin")?
        .write_all(hunk.patch().as_bytes())
        .map_err(|e| format!("write patch: {e}"))?;
    let out = child
        .wait_with_output()
        .map_err(|e| format!("git apply: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// Parse a full unified `git diff` into hunks. Robust to missing files
/// (`/dev/null`), which it just skips.
pub fn parse_hunks(diff: &str, workspace: &Path) -> Vec<Hunk> {
    // Index byte offsets of every line start so raw slices stay verbatim.
    let mut starts = vec![0usize];
    for (i, b) in diff.bytes().enumerate() {
        if b == b'\n' {
            starts.push(i + 1);
        }
    }
    let line_at = |k: usize| -> &str {
        let a = starts[k];
        let b = starts.get(k + 1).copied().unwrap_or(diff.len());
        &diff[a..b]
    };
    let n = starts.len();

    let mut hunks: Vec<Hunk> = Vec::new();
    let mut file_rel: Option<String> = None;
    // Open hunk being accumulated: (file_rel, header_line, new_start, start_line_index, parsed lines).
    let mut open: Option<(String, String, usize, usize, Vec<HunkLine>)> = None;

    let flush = |hunks: &mut Vec<Hunk>,
                 open: &mut Option<(String, String, usize, usize, Vec<HunkLine>)>,
                 end_line: usize| {
        if let Some((rel, header, new_start, start_k, lines)) = open.take() {
            let body = diff[starts[start_k]..starts.get(end_line).copied().unwrap_or(diff.len())]
                .to_string();
            hunks.push(Hunk {
                file: workspace.join(&rel),
                file_rel: rel,
                header,
                new_start,
                lines,
                body,
            });
        }
    };

    for k in 0..n {
        let line = line_at(k).trim_end_matches(['\n', '\r']);
        if line.starts_with("diff --git ") {
            flush(&mut hunks, &mut open, k);
            file_rel = None;
        } else if let Some(rest) = line.strip_prefix("+++ ") {
            if rest != "/dev/null" {
                file_rel = Some(rest.strip_prefix("b/").unwrap_or(rest).to_string());
            }
        } else if line.starts_with("@@ ") {
            flush(&mut hunks, &mut open, k);
            if let (Some(rel), Some(after)) = (file_rel.clone(), line.strip_prefix("@@ ")) {
                let new_start = parse_hunk_header(after)
                    .map(|(_, (c, _))| c)
                    .unwrap_or(1)
                    .max(1);
                open = Some((rel, line.to_string(), new_start, k, Vec::new()));
            }
        } else if let Some((_, _, _, _, lines)) = open.as_mut() {
            // a hunk line: ' ' context, '+' added, '-' removed, '\' no-newline
            match line.as_bytes().first() {
                Some(b' ') => lines.push(HunkLine::Context(line[1..].to_string())),
                Some(b'+') => lines.push(HunkLine::Added(line[1..].to_string())),
                Some(b'-') => lines.push(HunkLine::Removed(line[1..].to_string())),
                Some(b'\\') => lines.push(HunkLine::NoNewline),
                _ => {} // blank line within a zero-context diff, or stray — ignore
            }
        }
    }
    flush(&mut hunks, &mut open, n);
    hunks
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

    #[test]
    fn parse_hunks_splits_files_and_hunks() {
        let ws = Path::new("/repo");
        let diff = "\
diff --git a/src/a.rs b/src/a.rs
index 111..222 100644
--- a/src/a.rs
+++ b/src/a.rs
@@ -1,3 +1,4 @@
 fn main() {
-    old();
+    new();
+    extra();
 }
diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -5 +5 @@
-x
+y
";
        let hs = parse_hunks(diff, ws);
        assert_eq!(hs.len(), 2);
        assert_eq!(hs[0].file, ws.join("src/a.rs"));
        assert_eq!(hs[0].file_rel, "src/a.rs");
        assert_eq!(hs[0].new_start, 1);
        assert!(hs[0].header.starts_with("@@ -1,3 +1,4 @@"));
        assert!(matches!(hs[0].lines[0], HunkLine::Context(_)));
        assert!(matches!(hs[0].lines[1], HunkLine::Removed(_)));
        assert!(matches!(hs[0].lines[2], HunkLine::Added(_)));
        // the patch we'd hand to `git apply` reconstructs the file header.
        let patch = hs[0].patch();
        assert!(patch.starts_with("--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,3 +1,4 @@"));
        assert!(patch.contains("+    new();\n"));
        assert_eq!(hs[1].file_rel, "b.txt");
        assert_eq!(hs[1].new_start, 5);
    }
}
