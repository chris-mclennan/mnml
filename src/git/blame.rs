//! `git blame --porcelain` → one [`BlameLine`] per file line, for the editor's
//! blame-gutter mode. Lines not yet committed get a sha of all zeros and the
//! author `"Not Committed Yet"`.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Default)]
pub struct BlameLine {
    /// Short commit hash (`0000000` for an uncommitted line).
    pub sha: String,
    pub author: String,
    pub summary: String,
    /// Commit time, Unix seconds (`0` if unknown).
    pub time: i64,
}

impl BlameLine {
    pub fn is_uncommitted(&self) -> bool {
        self.sha.chars().all(|c| c == '0')
    }
    /// `"abc1234 Author · summary"` truncated to `width` chars (gutter display).
    pub fn label(&self, width: usize) -> String {
        if self.is_uncommitted() {
            return trunc("• not committed yet", width);
        }
        let short = &self.sha[..7.min(self.sha.len())];
        trunc(&format!("{short} {}", self.author), width)
    }
}

fn trunc(s: &str, width: usize) -> String {
    let n = s.chars().count();
    if n <= width {
        format!("{s:width$}")
    } else if width == 0 {
        String::new()
    } else {
        let keep: String = s.chars().take(width.saturating_sub(1)).collect();
        format!("{keep}…")
    }
}

/// Blame `rel` (workspace-relative). One entry per file line, in order. Empty on
/// error / not-a-repo.
pub fn blame(workspace: &Path, rel: &str) -> Vec<BlameLine> {
    let Ok(out) = Command::new("git")
        .args(["blame", "--porcelain", "--", rel])
        .current_dir(workspace)
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    parse(&String::from_utf8_lossy(&out.stdout))
}

fn parse(porcelain: &str) -> Vec<BlameLine> {
    // sha → (author, time, summary), filled the first time each commit appears.
    let mut meta: HashMap<String, (String, i64, String)> = HashMap::new();
    // (sha, final_line_1based) for the line currently being described.
    let mut cur: Option<(String, usize)> = None;
    let mut author = String::new();
    let mut time = 0i64;
    let mut summary = String::new();
    let mut out: Vec<(usize, String)> = Vec::new(); // (final_line, sha)

    for line in porcelain.lines() {
        if line.starts_with('\t') {
            // The blamed source line — close out this line's record.
            if let Some((sha, fl)) = cur.take() {
                if !author.is_empty() {
                    meta.entry(sha.clone())
                        .or_insert((author.clone(), time, summary.clone()));
                }
                out.push((fl, sha));
            }
        } else if let Some(rest) = line.strip_prefix("author ") {
            author = rest.to_string();
        } else if let Some(rest) = line.strip_prefix("author-time ") {
            time = rest.trim().parse().unwrap_or(0);
        } else if let Some(rest) = line.strip_prefix("summary ") {
            summary = rest.to_string();
        } else {
            // Either "<sha> <orig> <final> [<count>]" (start of a line block) or a
            // header field we don't care about — the hex guard filters the latter.
            let mut parts = line.split_whitespace();
            if let (Some(sha), Some(_orig), Some(final_)) =
                (parts.next(), parts.next(), parts.next())
                && sha.len() >= 7
                && sha.bytes().all(|b| b.is_ascii_hexdigit())
                && let Ok(fl) = final_.parse::<usize>()
            {
                cur = Some((sha.to_string(), fl));
                author.clear();
                summary.clear();
                time = 0;
            }
        }
    }

    if out.is_empty() {
        return Vec::new();
    }
    let max_line = out.iter().map(|&(l, _)| l).max().unwrap_or(0);
    let mut lines = vec![BlameLine::default(); max_line];
    for (fl, sha) in out {
        if fl == 0 || fl > lines.len() {
            continue;
        }
        let (a, t, s) = meta.get(&sha).cloned().unwrap_or_default();
        lines[fl - 1] = BlameLine {
            sha,
            author: a,
            summary: s,
            time: t,
        };
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_porcelain() {
        let p = "\
abc1234def5678abc1234def5678abc1234def56 1 1 2
author Alice
author-mail <alice@x>
author-time 1700000000
author-tz +0000
committer Alice
committer-mail <alice@x>
committer-time 1700000000
committer-tz +0000
summary first commit
filename a.txt
\tline one
abc1234def5678abc1234def5678abc1234def56 2 2
\tline two
0000000000000000000000000000000000000000 3 3 1
author Not Committed Yet
author-time 0
summary Version of a.txt from a.txt
filename a.txt
\tline three (new)
";
        let v = parse(p);
        assert_eq!(v.len(), 3);
        assert_eq!(&v[0].sha[..7], "abc1234");
        assert_eq!(v[0].author, "Alice");
        assert_eq!(v[0].summary, "first commit");
        assert_eq!(v[1].sha, v[0].sha); // line 2 is the same commit
        assert_eq!(v[1].author, "Alice"); // metadata reused from the first occurrence
        assert!(v[2].is_uncommitted());
    }

    #[test]
    fn label_truncates() {
        let bl = BlameLine {
            sha: "abcdef1234".into(),
            author: "Somebody Long".into(),
            summary: "x".into(),
            time: 0,
        };
        assert_eq!(bl.label(20).chars().count(), 20);
        assert!(bl.label(20).starts_with("abcdef1 Somebody"));
        assert!(bl.label(8).ends_with('…'));
    }
}
