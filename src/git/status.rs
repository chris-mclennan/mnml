//! Lightweight `git status --porcelain` reader — no libgit2, shells out to `git`.
//! Always succeeds: if `git` is missing or this isn't a repo, the branch is `None`
//! and all counts are zero. Cached with a short TTL so it's cheap to poll every tick.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const TTL: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileState {
    Modified,
    Staged,
    Untracked,
    Conflicted,
}

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub branch: Option<String>,
    /// Commits the local branch is ahead / behind its upstream (0 if no upstream).
    pub ahead: usize,
    pub behind: usize,
    pub modified: usize,
    pub staged: usize,
    pub untracked: usize,
    pub conflicts: usize,
    /// NvChad-style semantic file-status counts — collapse the
    /// staged/unstaged distinction in favor of "what changed".
    /// `added` = files newly added (A in either column) or untracked;
    /// `changed` = files modified; `removed` = files deleted (D in
    /// either column). Used by the statusline's
    /// `+N ●N -N` chips.
    pub added: usize,
    pub changed: usize,
    pub removed: usize,
    /// Path → state, for the tree tint. Keys are absolute (workspace-joined).
    pub files: HashMap<PathBuf, FileState>,
    /// Path → gutter line-signs (added/modified/removed), from `git diff HEAD`.
    /// Keys are absolute. Sorted by line within each entry.
    pub line_changes: super::diff::LineSigns,
    /// Nerd-font icon for the git provider (GitHub / GitLab / Bitbucket /
    /// Azure DevOps / generic) — resolved from `remote.origin.url`. `None`
    /// when the workspace has no `origin` remote or isn't a git repo.
    pub provider_icon: Option<&'static str>,
}

impl Snapshot {
    pub fn change_count(&self) -> usize {
        self.modified + self.staged + self.untracked + self.conflicts
    }
}

#[derive(Debug)]
pub struct GitStatus {
    workspace: PathBuf,
    snapshot: Snapshot,
    probed_at: Option<Instant>,
}

impl GitStatus {
    pub fn new(workspace: &Path) -> Self {
        let mut g = GitStatus {
            workspace: workspace.to_path_buf(),
            snapshot: Snapshot::default(),
            probed_at: None,
        };
        g.refresh();
        g
    }

    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }

    /// Re-probe if the cache is stale; cheap to call every event-loop tick.
    pub fn tick(&mut self) {
        let stale = self.probed_at.map(|t| t.elapsed() >= TTL).unwrap_or(true);
        if stale {
            self.refresh();
        }
    }

    pub fn refresh(&mut self) {
        self.snapshot = probe(&self.workspace);
        self.probed_at = Some(Instant::now());
    }

    /// Re-point the cached workspace at a different repo root and force an
    /// immediate refresh. Used when `App::switch_active_repo` flips to a
    /// different repo so the rail + statusline + gutter line-signs follow.
    pub fn retarget(&mut self, workspace: &Path) {
        self.workspace = workspace.to_path_buf();
        self.refresh();
    }
}

fn probe(workspace: &Path) -> Snapshot {
    let mut snap = Snapshot {
        provider_icon: super::browse::provider_icon_for(workspace),
        ..Default::default()
    };

    // Branch (gracefully degrade on detached HEAD / not a repo).
    if let Ok(out) = Command::new("git")
        .args(["symbolic-ref", "--short", "-q", "HEAD"])
        .current_dir(workspace)
        .output()
        && out.status.success()
    {
        let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !b.is_empty() {
            snap.branch = Some(b);
        }
    }
    if snap.branch.is_none()
        && let Ok(out) = Command::new("git")
            .args(["rev-parse", "--short", "HEAD"])
            .current_dir(workspace)
            .output()
        && out.status.success()
    {
        let h = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !h.is_empty() {
            snap.branch = Some(format!("@{h}"));
        }
    }

    // Status (`-b` adds the `## branch…remote [ahead N, behind M]` header line).
    if let Ok(out) = Command::new("git")
        .args(["status", "--porcelain", "-b"])
        .current_dir(workspace)
        .output()
        && out.status.success()
    {
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            if let Some(rest) = line.strip_prefix("## ") {
                let num_after = |needle: &str| -> usize {
                    rest.find(needle)
                        .and_then(|i| {
                            rest[i + needle.len()..]
                                .split([',', ']'])
                                .next()?
                                .trim()
                                .parse()
                                .ok()
                        })
                        .unwrap_or(0)
                };
                snap.ahead = num_after("ahead ");
                snap.behind = num_after("behind ");
                continue;
            }
            if line.len() < 3 {
                continue;
            }
            let bytes = line.as_bytes();
            let (x, y) = (bytes[0] as char, bytes[1] as char);
            let path_part = line[3..].trim();
            // handle "old -> new" for renames; take the new path
            let rel_raw = path_part
                .rsplit(" -> ")
                .next()
                .unwrap_or(path_part)
                .trim_matches('"');
            // Without `-z`, `git status --porcelain` octal-escapes
            // non-ASCII / quoteable bytes inside double-quotes:
            // `weird-😀.txt` arrives as `"weird-\360\237\230\200.txt"`.
            // Unescape so the rail / commit pane shows the actual
            // glyphs. untouched-surfaces-hunt-2026-06-08 SEV-3 #13.
            let rel_decoded = decode_git_path(rel_raw);
            let rel = rel_decoded.as_str();
            let abs = workspace.join(rel);
            let state = if x == 'U' || y == 'U' || (x == 'D' && y == 'D') || (x == 'A' && y == 'A')
            {
                snap.conflicts += 1;
                FileState::Conflicted
            } else if x == '?' && y == '?' {
                snap.untracked += 1;
                snap.added += 1;
                FileState::Untracked
            } else {
                if x != ' ' && x != '?' {
                    snap.staged += 1;
                }
                if y != ' ' && y != '?' {
                    snap.modified += 1;
                }
                // Semantic counts (NvChad-style). A file is "added" once
                // even if it was staged-added then modified (D/M counts as
                // added → removed, etc; we pick the most-recent action).
                if x == 'A' || y == 'A' {
                    snap.added += 1;
                } else if x == 'D' || y == 'D' {
                    snap.removed += 1;
                } else if x == 'M' || y == 'M' || x == 'R' || y == 'R' {
                    snap.changed += 1;
                }
                if y != ' ' {
                    FileState::Modified
                } else {
                    FileState::Staged
                }
            };
            snap.files.insert(abs, state);
        }
    }

    snap.line_changes = super::diff::line_signs(workspace);
    snap
}

/// Decode `git status --porcelain` path output. Without `-z`, git
/// quote-wraps + octal-escapes any path with non-printable / non-
/// ASCII bytes: `weird-😀.txt` → `"weird-\360\237\230\200.txt"`.
///
/// Strips the quote wrapping (if present), walks the string
/// interpreting `\<3 octal digits>` as one byte + `\\` / `\"` /
/// `\t` / `\n` / `\r` as their literal C-escape equivalent.
/// Anything else (`\x`, `\u`) is left literal — git only emits the
/// classic C-style octal form.
fn decode_git_path(s: &str) -> String {
    let inner = s
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .unwrap_or(s);
    let bytes = inner.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            let n = bytes[i + 1];
            // Three-octal-digit escape: `\NNN`.
            if (b'0'..=b'7').contains(&n)
                && i + 3 < bytes.len()
                && (b'0'..=b'7').contains(&bytes[i + 2])
                && (b'0'..=b'7').contains(&bytes[i + 3])
            {
                let v =
                    (bytes[i + 1] - b'0') * 64 + (bytes[i + 2] - b'0') * 8 + (bytes[i + 3] - b'0');
                out.push(v);
                i += 4;
                continue;
            }
            // Common C-style escapes git emits.
            let mapped = match n {
                b'\\' => Some(b'\\'),
                b'"' => Some(b'"'),
                b't' => Some(b'\t'),
                b'n' => Some(b'\n'),
                b'r' => Some(b'\r'),
                _ => None,
            };
            if let Some(m) = mapped {
                out.push(m);
                i += 2;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_repo_is_quiet() {
        let d = tempfile::tempdir().unwrap();
        let g = GitStatus::new(d.path());
        assert!(g.snapshot().branch.is_none());
        assert_eq!(g.snapshot().change_count(), 0);
    }

    #[test]
    fn decode_git_path_reverses_octal_escapes() {
        // 😀 = U+1F600 = UTF-8 bytes 0xF0 0x9F 0x98 0x80
        //              = octal       360  237  230  200
        let escaped = r#""weird-\360\237\230\200.txt""#;
        let decoded = decode_git_path(escaped);
        assert_eq!(decoded, "weird-😀.txt");
    }

    #[test]
    fn decode_git_path_passes_ascii_through_unchanged() {
        assert_eq!(decode_git_path("foo/bar.txt"), "foo/bar.txt");
        assert_eq!(decode_git_path("\"quoted/ascii.txt\""), "quoted/ascii.txt");
    }

    #[test]
    fn decode_git_path_handles_c_style_escapes() {
        // git status escapes embedded tab/newline/backslash too.
        assert_eq!(decode_git_path(r#""a\tb""#), "a\tb");
        assert_eq!(decode_git_path(r#""a\\b""#), "a\\b");
        assert_eq!(decode_git_path(r#""a\"b""#), "a\"b");
    }
}
