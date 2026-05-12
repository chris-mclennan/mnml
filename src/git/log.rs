//! `git log --all` reader + a lane layout for an ASCII commit DAG (the data
//! behind [`crate::git::graph::GitGraphPane`]). Shells out to `git`; degrades to
//! an empty graph when `git` is missing or this isn't a repo.
//!
//! The layout is single-row-per-commit: each commit sits in one lane (column),
//! pass-through lanes draw `│`, the commit's node is `●`. Branch/merge points use
//! corner glyphs (`╮ ╭ ╯ ╰`) toward the commit's lane — approximate (no diagonal
//! crossings), but readable; fancier connectors are a follow-up.

use std::path::Path;
use std::process::Command;

/// What kind of ref points at a commit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefKind {
    /// `HEAD` (the symbolic ref itself — drawn on whatever commit is checked out).
    Head,
    LocalBranch,
    RemoteBranch,
    Tag,
}

#[derive(Debug, Clone)]
pub struct RefLabel {
    pub kind: RefKind,
    /// Short name — `main`, `origin/main`, `v1.2.0`, `HEAD`.
    pub name: String,
}

/// One graph cell — a character to draw plus a lane-colour index (`0..N`, cycled
/// through a small palette by the renderer).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GraphCell {
    pub ch: char,
    pub color: u8,
}

impl GraphCell {
    const BLANK: GraphCell = GraphCell { ch: ' ', color: 0 };
}

#[derive(Debug, Clone)]
pub struct Commit {
    pub hash: String,
    /// First 9 chars of `hash` (what's shown).
    pub short: String,
    pub parents: Vec<String>,
    pub author: String,
    /// Author time, unix seconds.
    pub time: i64,
    pub subject: String,
    pub refs: Vec<RefLabel>,
    /// The rendered graph columns for this row (left → right).
    pub graph: Vec<GraphCell>,
    /// The lane this commit's node sits in (index into `graph`).
    pub lane: usize,
}

/// Load up to `limit` commits across all refs, with a lane layout computed.
pub fn load(workspace: &Path, limit: usize) -> Vec<Commit> {
    let refs = load_refs(workspace);
    let head = head_hash(workspace);

    // `%x1f` (unit separator) between fields — safe inside commit subjects.
    let fmt = "%H%x1f%P%x1f%an%x1f%at%x1f%s";
    let out = match Command::new("git")
        .args([
            "log",
            "--all",
            "--date-order",
            &format!("-n{limit}"),
            &format!("--pretty=format:{fmt}"),
        ])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };

    let mut commits: Vec<Commit> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut f = line.split('\u{1f}');
            let hash = f.next()?.to_string();
            let parents: Vec<String> = f.next()?.split_whitespace().map(str::to_string).collect();
            let author = f.next().unwrap_or("").to_string();
            let time = f.next().unwrap_or("0").parse().unwrap_or(0);
            let subject = f.next().unwrap_or("").to_string();
            let short: String = hash.chars().take(9).collect();
            let mut refs: Vec<RefLabel> = refs
                .iter()
                .filter(|(h, _)| *h == hash)
                .map(|(_, r)| r.clone())
                .collect();
            if head.as_deref() == Some(hash.as_str()) {
                refs.insert(
                    0,
                    RefLabel {
                        kind: RefKind::Head,
                        name: "HEAD".to_string(),
                    },
                );
            }
            Some(Commit {
                hash,
                short,
                parents,
                author,
                time,
                subject,
                refs,
                graph: Vec::new(),
                lane: 0,
            })
        })
        .collect();

    layout(&mut commits);
    commits
}

/// Assign lanes + build each row's `graph` cells. `commits` is newest-first.
fn layout(commits: &mut [Commit]) {
    // `lanes[i]` = the hash that lane `i` is "waiting for" (its next commit going
    // older), or `None` if free. A stable colour is `lane_index` cycled.
    let mut lanes: Vec<Option<String>> = Vec::new();

    for c in commits.iter_mut() {
        // Which lane is this commit's? (the first lane already waiting for it).
        let my_lane = match lanes
            .iter()
            .position(|l| l.as_deref() == Some(c.hash.as_str()))
        {
            Some(i) => i,
            None => {
                lanes.push(None);
                lanes.len() - 1
            }
        };
        // Other lanes also waiting for this commit ⇒ branches merging in here.
        let merging: Vec<usize> = lanes
            .iter()
            .enumerate()
            .filter(|(i, l)| *i != my_lane && l.as_deref() == Some(c.hash.as_str()))
            .map(|(i, _)| i)
            .collect();

        // Reserve lanes for extra parents (the first parent stays in `my_lane`).
        let mut branch_to: Vec<usize> = Vec::new();
        for p in c.parents.iter().skip(1) {
            if lanes.iter().any(|l| l.as_deref() == Some(p.as_str())) {
                continue; // a lane already heads there — it'll merge later
            }
            let free = lanes
                .iter()
                .enumerate()
                .find(|(i, l)| *i != my_lane && l.is_none())
                .map(|(i, _)| i);
            let slot = match free {
                Some(free) => free,
                None => {
                    lanes.push(None);
                    lanes.len() - 1
                }
            };
            lanes[slot] = Some(p.clone());
            branch_to.push(slot);
        }

        // Build this row's cells.
        let width = lanes.len();
        let mut cells = vec![GraphCell::BLANK; width];
        for (i, l) in lanes.iter().enumerate() {
            let color = (i % LANE_COLORS) as u8;
            if i == my_lane {
                cells[i] = GraphCell { ch: '●', color };
            } else if merging.contains(&i) {
                cells[i] = GraphCell {
                    ch: if i < my_lane { '╰' } else { '╯' },
                    color,
                };
            } else if branch_to.contains(&i) {
                cells[i] = GraphCell {
                    ch: if i < my_lane { '╭' } else { '╮' },
                    color,
                };
            } else if l.is_some() {
                cells[i] = GraphCell { ch: '│', color };
            }
        }
        // A horizontal stretch across the gap between `my_lane` and the furthest
        // merge/branch lane, so the corners actually connect.
        let mut endpoints: Vec<usize> = merging.iter().chain(branch_to.iter()).copied().collect();
        if let (Some(&lo), Some(&hi)) = (
            endpoints.iter().chain(std::iter::once(&my_lane)).min(),
            endpoints.iter().chain(std::iter::once(&my_lane)).max(),
        ) {
            for cell in cells.iter_mut().take(hi).skip(lo + 1) {
                if cell.ch == ' ' {
                    *cell = GraphCell {
                        ch: '─',
                        color: (my_lane % LANE_COLORS) as u8,
                    };
                } else if cell.ch == '│' {
                    *cell = GraphCell {
                        ch: '┼',
                        color: cell.color,
                    };
                }
            }
        }
        endpoints.clear();

        c.graph = cells;
        c.lane = my_lane;

        // Advance lanes for the next (older) row: `my_lane` now waits for the
        // first parent (or frees up); merged-in lanes are absorbed (freed).
        for i in &merging {
            lanes[*i] = None;
        }
        lanes[my_lane] = c.parents.first().cloned();
        // Trim trailing free lanes so the graph doesn't drift wide forever.
        while matches!(lanes.last(), Some(None)) {
            lanes.pop();
        }
    }
}

/// How many colours the lane palette cycles through (the renderer maps `0..N`).
pub const LANE_COLORS: usize = 6;

fn head_hash(workspace: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(workspace)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let h = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!h.is_empty()).then_some(h)
}

/// `(commit-hash, label)` for every branch / remote-branch / tag tip.
fn load_refs(workspace: &Path) -> Vec<(String, RefLabel)> {
    let out = match Command::new("git")
        .args([
            "for-each-ref",
            "--format=%(objectname) %(refname)",
            "refs/heads",
            "refs/remotes",
            "refs/tags",
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
            let (hash, refname) = line.split_once(' ')?;
            let (kind, name) = if let Some(n) = refname.strip_prefix("refs/heads/") {
                (RefKind::LocalBranch, n.to_string())
            } else if let Some(n) = refname.strip_prefix("refs/remotes/") {
                if n.ends_with("/HEAD") {
                    return None; // the `origin/HEAD -> origin/main` alias — skip
                }
                (RefKind::RemoteBranch, n.to_string())
            } else if let Some(n) = refname.strip_prefix("refs/tags/") {
                (RefKind::Tag, n.to_string())
            } else {
                return None;
            };
            Some((hash.to_string(), RefLabel { kind, name }))
        })
        .collect()
}

/// `git show -s --format=%B <hash>` — the full commit message body.
pub fn full_message(workspace: &Path, hash: &str) -> String {
    Command::new("git")
        .args(["show", "-s", "--format=%B", hash])
        .current_dir(workspace)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end().to_string())
        .unwrap_or_default()
}

/// `git show --name-status --format= <hash>` — `(status, path)` per changed file.
/// `status` is the porcelain letter (`M`/`A`/`D`/`R…`/`C…`).
pub fn changed_files(workspace: &Path, hash: &str) -> Vec<(String, String)> {
    let out = match Command::new("git")
        .args(["show", "--name-status", "--format=", hash])
        .current_dir(workspace)
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| {
            let mut it = l.split('\t');
            let status = it.next()?.to_string();
            // For renames/copies the line is `R100\told\tnew` — take the new path.
            let path = it.next_back()?.to_string();
            Some((status, path))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_on_non_repo() {
        let d = tempfile::tempdir().unwrap();
        assert!(load(d.path(), 100).is_empty());
    }

    #[test]
    fn lays_out_a_linear_history() {
        // C <- B <- A (newest first), all in lane 0.
        let mut commits = vec![
            Commit {
                hash: "c".into(),
                short: "c".into(),
                parents: vec!["b".into()],
                author: "x".into(),
                time: 3,
                subject: "third".into(),
                refs: vec![],
                graph: vec![],
                lane: 9,
            },
            Commit {
                hash: "b".into(),
                short: "b".into(),
                parents: vec!["a".into()],
                author: "x".into(),
                time: 2,
                subject: "second".into(),
                refs: vec![],
                graph: vec![],
                lane: 9,
            },
            Commit {
                hash: "a".into(),
                short: "a".into(),
                parents: vec![],
                author: "x".into(),
                time: 1,
                subject: "first".into(),
                refs: vec![],
                graph: vec![],
                lane: 9,
            },
        ];
        layout(&mut commits);
        for c in &commits {
            assert_eq!(c.lane, 0);
            assert_eq!(c.graph.len(), 1);
            assert_eq!(c.graph[0].ch, '●');
        }
    }

    #[test]
    fn merge_uses_two_lanes() {
        // M (parents P1, P2) <- P1 <- (root), P2 <- (root). Newest first: M, P1, P2.
        let mut commits = vec![
            Commit {
                hash: "m".into(),
                short: "m".into(),
                parents: vec!["p1".into(), "p2".into()],
                author: "x".into(),
                time: 4,
                subject: "merge".into(),
                refs: vec![],
                graph: vec![],
                lane: 9,
            },
            Commit {
                hash: "p1".into(),
                short: "p1".into(),
                parents: vec![],
                author: "x".into(),
                time: 3,
                subject: "p1".into(),
                refs: vec![],
                graph: vec![],
                lane: 9,
            },
            Commit {
                hash: "p2".into(),
                short: "p2".into(),
                parents: vec![],
                author: "x".into(),
                time: 2,
                subject: "p2".into(),
                refs: vec![],
                graph: vec![],
                lane: 9,
            },
        ];
        layout(&mut commits);
        assert_eq!(commits[0].lane, 0);
        // The merge row spans two lanes (a branch-out corner in lane 1).
        assert!(commits[0].graph.len() >= 2);
        assert_eq!(commits[1].lane, 0); // p1 stays in lane 0
        assert_eq!(commits[2].lane, 1); // p2 in the second lane
    }
}
