//! `Pane::GitGraph` — a graphical-Git-GUI-style commit-DAG view: the lane graph + commit
//! list on the left, the selected commit's details (full message + changed
//! files) below it. Built on [`super::log`]. Read-only for now; "stage & commit
//! (with Claude / Codex)" and worktree management are follow-ups (see
//! `.local/PLAN.md` — "Git GUI").

use std::path::{Path, PathBuf};

use super::log::{self, Commit};

/// Details for the currently-selected commit (loaded lazily as the selection moves).
#[derive(Debug, Clone)]
pub struct CommitDetail {
    pub hash: String,
    /// Full commit message body (`git show -s --format=%B`).
    pub message: String,
    /// `(status-letter, path)` for each file the commit touched.
    pub files: Vec<(String, String)>,
}

pub struct GitGraphPane {
    pub workspace: PathBuf,
    pub commits: Vec<Commit>,
    /// Index into the *virtual* list (WIP row + commits). When
    /// `has_wip` is true, `0 = WIP, 1..=commits.len() = commits[i-1]`;
    /// otherwise `0..commits.len() = commits[i]`.
    pub selected: usize,
    /// Top visible row in the virtual list (the renderer keeps
    /// `selected` on screen).
    pub scroll: usize,
    pub detail: Option<CommitDetail>,
    /// `/` filter — accumulating hash prefix to fuzzy-jump to a commit.
    /// Empty when inactive. The renderer shows a chip in the header row when
    /// non-empty; `tui.rs` routes printable keys / Backspace / Enter / Esc.
    pub hash_filter: String,
    /// True while the filter is actively accepting keystrokes (the `/` chord
    /// was pressed and we haven't pressed Enter/Esc yet).
    pub hash_filter_mode: bool,
    /// True when the working tree has uncommitted changes — drives the
    /// "WIP" virtual row rendered above commits[0]. Recomputed on
    /// `open` / `refresh` / `retarget` from `git status --porcelain`.
    pub has_wip: bool,
    /// When set, the GitGraph's commit-list area is replaced by an
    /// embedded diff view (the user clicked a file in the right
    /// detail panel). Esc closes it; the commit list returns. The
    /// right detail panel keeps showing whatever it was showing
    /// (WIP detail or commit detail).
    pub embedded_diff: Option<crate::pane::DiffView>,
    /// Inline commit-message editor in the WIP detail panel (sticky at
    /// the bottom). Click the textarea to focus it, type a message,
    /// then click the `Commit` button — or click `AI Message` to have
    /// `claude -p` fill it from `git diff --cached`.
    pub wip_commit: WipCommitInput,
    /// Active commit-list filter — branch name + optional date range.
    /// `default()` ⇒ `git log --all` (no narrowing). A non-empty branch
    /// scopes to commits reachable from that branch; `since` / `until`
    /// accept any spec git understands ("1 week ago", "2026-01-01", …).
    pub filter: crate::git::log::LogFilter,
    /// Active commit-list sort. `None` ⇒ git's native `--date-order`
    /// (parent-relative); `Some(col, asc)` re-sorts the loaded commits
    /// in-place by the chosen column. Click a column header to cycle.
    pub sort: Option<(SortColumn, bool)>,
}

/// Which column the user wants the commit list sorted by — wired to
/// header clicks in the GitGraph pane. `None` on `GitGraphPane.sort`
/// keeps git's native parent-relative ordering.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortColumn {
    /// Commit author timestamp (default direction = descending = newest first).
    Date,
    /// Author name (alphabetical).
    Author,
    /// Short SHA (alphabetical).
    Sha,
}

/// Multi-line text-area state for the WIP detail panel's commit
/// section. Bytes-only — UTF-8 boundaries are respected by the
/// cursor-moving helpers but we don't track display width.
#[derive(Debug, Clone, Default)]
pub struct WipCommitInput {
    /// Current commit-message text (multi-line — `\n` separates).
    pub text: String,
    /// Byte offset of the caret within `text` (always on a char
    /// boundary).
    pub cursor: usize,
    /// True when the textarea has keyboard focus — set on click,
    /// cleared on Esc or click elsewhere in the pane.
    pub focused: bool,
    /// Top visible row when the message wraps past the box height.
    /// Render-side concern only; keyboard input always keeps the
    /// caret in view.
    pub scroll: usize,
    /// True while an AI commit-message job is in flight whose result
    /// will land in this textarea. Drives the "AI is writing…"
    /// placeholder hint so the user knows to wait.
    pub ai_streaming: bool,
}

/// How many commits to load (across all refs). Plenty for browsing; bump later
/// if "load more" becomes a thing.
const LIMIT: usize = 800;

impl GitGraphPane {
    pub fn open(workspace: &Path) -> Self {
        let commits = log::load(workspace, LIMIT);
        let has_wip = working_tree_has_changes(workspace);
        let mut p = GitGraphPane {
            workspace: workspace.to_path_buf(),
            commits,
            // Start at row 0 — that's the WIP row when changes exist,
            // otherwise the newest commit. Either way, the user opens
            // the graph to see what's been happening lately.
            selected: 0,
            scroll: 0,
            detail: None,
            hash_filter: String::new(),
            hash_filter_mode: false,
            has_wip,
            embedded_diff: None,
            wip_commit: WipCommitInput::default(),
            filter: crate::git::log::LogFilter::default(),
            sort: None,
        };
        p.reload_detail();
        p
    }

    /// Cycle the sort state for `col`: `Some(col, asc)` ⇒ `Some(col,
    /// !asc)` ⇒ `None` (back to git's native order). Re-sorts the
    /// loaded commits in place — no extra `git log` invocation needed.
    pub fn cycle_sort(&mut self, col: SortColumn) {
        self.sort = match self.sort {
            Some((c, true)) if c == col => Some((col, false)),
            Some((c, false)) if c == col => None,
            _ => Some((col, false)),
        };
        self.apply_sort();
        self.selected = 0;
        self.scroll = 0;
    }

    /// Apply the current sort to `self.commits` in place. No-op when
    /// `sort` is `None`. Re-stable so equal keys preserve git order.
    pub fn apply_sort(&mut self) {
        let Some((col, asc)) = self.sort else {
            return;
        };
        match col {
            SortColumn::Date => self
                .commits
                .sort_by(|a, b| if asc { a.time.cmp(&b.time) } else { b.time.cmp(&a.time) }),
            SortColumn::Author => self.commits.sort_by(|a, b| {
                if asc {
                    a.author.cmp(&b.author)
                } else {
                    b.author.cmp(&a.author)
                }
            }),
            SortColumn::Sha => self.commits.sort_by(|a, b| {
                if asc {
                    a.short.cmp(&b.short)
                } else {
                    b.short.cmp(&a.short)
                }
            }),
        }
    }

    /// Total virtual rows = commits + maybe a WIP row at the top.
    pub fn total_rows(&self) -> usize {
        self.commits.len() + usize::from(self.has_wip)
    }

    /// True when the WIP virtual row sits at `selected`.
    pub fn is_wip_selected(&self) -> bool {
        self.has_wip && self.selected == 0
    }

    /// Returns the index into `self.commits` for the current selection,
    /// or `None` when the WIP row is selected. Use this to translate
    /// virtual-list selection back to a real commit.
    pub fn commit_index(&self) -> Option<usize> {
        if self.is_wip_selected() {
            return None;
        }
        let offset = usize::from(self.has_wip);
        let idx = self.selected.checked_sub(offset)?;
        if idx < self.commits.len() {
            Some(idx)
        } else {
            None
        }
    }

    /// Find the first commit whose short hash (or full hash, ASCII case-
    /// insensitive) begins with `prefix`. Empty prefix ⇒ None. Returns
    /// the **commit-list** index (not the virtual row), so callers using
    /// `jump_to` need to add `has_wip as usize` to land on the right row.
    pub fn find_by_hash_prefix(&self, prefix: &str) -> Option<usize> {
        if prefix.is_empty() {
            return None;
        }
        let needle = prefix.to_ascii_lowercase();
        self.commits
            .iter()
            .position(|c| c.hash.to_ascii_lowercase().starts_with(&needle))
    }

    /// Set the selection to the virtual-row index `idx` (0 = WIP if
    /// present, then commits). Returns true on change.
    pub fn jump_to(&mut self, idx: usize) -> bool {
        let total = self.total_rows();
        if total == 0 {
            return false;
        }
        let clamped = idx.min(total - 1);
        if clamped == self.selected {
            return false;
        }
        self.selected = clamped;
        self.reload_detail();
        true
    }

    /// Jump to a commit by its index in `self.commits`. Adjusts for the
    /// WIP row offset.
    pub fn jump_to_commit(&mut self, commit_idx: usize) -> bool {
        self.jump_to(commit_idx + usize::from(self.has_wip))
    }

    pub fn tab_title(&self) -> String {
        "git graph".to_string()
    }

    /// Re-run `git log` (after a commit, fetch, etc.), keeping the selection in range.
    pub fn refresh(&mut self) {
        self.commits = log::load_filtered(&self.workspace, LIMIT, &self.filter);
        self.apply_sort();
        self.has_wip = working_tree_has_changes(&self.workspace);
        let total = self.total_rows();
        if total == 0 {
            self.selected = 0;
        } else if self.selected >= total {
            self.selected = total - 1;
        }
        self.reload_detail();
    }

    /// Re-point the cached workspace at a different repo root + reload.
    /// Used when `App::switch_active_repo` flips repos so the graph follows.
    /// Resets selection + scroll since the new repo's commit history is
    /// entirely different.
    pub fn retarget(&mut self, workspace: &Path) {
        self.workspace = workspace.to_path_buf();
        self.selected = 0;
        self.scroll = 0;
        // Repo switch invalidates the previous repo's branch filter.
        self.filter = crate::git::log::LogFilter::default();
        self.commits = log::load_filtered(&self.workspace, LIMIT, &self.filter);
        self.has_wip = working_tree_has_changes(&self.workspace);
        self.reload_detail();
    }

    /// Move the selection by `delta` rows (clamped), reloading the detail panel.
    pub fn move_selection(&mut self, delta: isize) {
        let total = self.total_rows();
        if total == 0 {
            return;
        }
        let n = total as isize;
        let next = (self.selected as isize + delta).clamp(0, n - 1) as usize;
        if next != self.selected {
            self.selected = next;
            self.reload_detail();
        }
    }

    /// The commit at the current selection — `None` when the WIP row
    /// is selected (or no commits loaded).
    pub fn selected_commit(&self) -> Option<&Commit> {
        let idx = self.commit_index()?;
        self.commits.get(idx)
    }

    pub fn reload_detail(&mut self) {
        let idx = self.commit_index();
        self.detail = idx.and_then(|i| self.commits.get(i)).map(|c| CommitDetail {
            hash: c.hash.clone(),
            message: log::full_message(&self.workspace, &c.hash),
            files: log::changed_files(&self.workspace, &c.hash),
        });
    }
}

impl WipCommitInput {
    /// Replace the entire buffer with `text` and park the cursor at
    /// the end. Used when an AI message-generation job lands.
    pub fn set_text(&mut self, text: String) {
        self.cursor = text.len();
        self.text = text;
        self.scroll = 0;
    }

    /// Insert one char at the cursor + advance past it. Auto-clamps
    /// the cursor to the new buffer length.
    pub fn insert_char(&mut self, ch: char) {
        let mut buf = [0u8; 4];
        let s = ch.encode_utf8(&mut buf);
        self.text.insert_str(self.cursor, s);
        self.cursor += s.len();
    }

    /// Insert a literal string (e.g. paste, or the chunked tail of an
    /// AI stream) at the cursor.
    pub fn insert_str(&mut self, s: &str) {
        self.text.insert_str(self.cursor, s);
        self.cursor += s.len();
    }

    /// Delete the char immediately before the cursor (Backspace).
    pub fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let prev = prev_char_boundary(&self.text, self.cursor);
        self.text.replace_range(prev..self.cursor, "");
        self.cursor = prev;
    }

    /// Delete the char immediately after the cursor (Delete key).
    pub fn delete_forward(&mut self) {
        if self.cursor >= self.text.len() {
            return;
        }
        let next = next_char_boundary(&self.text, self.cursor);
        self.text.replace_range(self.cursor..next, "");
    }

    /// Move the cursor left by one char (UTF-8 boundary-safe).
    pub fn move_left(&mut self) {
        if self.cursor > 0 {
            self.cursor = prev_char_boundary(&self.text, self.cursor);
        }
    }

    /// Move the cursor right by one char.
    pub fn move_right(&mut self) {
        if self.cursor < self.text.len() {
            self.cursor = next_char_boundary(&self.text, self.cursor);
        }
    }

    /// Move the cursor to the start of the current logical line.
    pub fn move_line_start(&mut self) {
        if let Some(nl) = self.text[..self.cursor].rfind('\n') {
            self.cursor = nl + 1;
        } else {
            self.cursor = 0;
        }
    }

    /// Move the cursor to the end of the current logical line.
    pub fn move_line_end(&mut self) {
        if let Some(rel) = self.text[self.cursor..].find('\n') {
            self.cursor += rel;
        } else {
            self.cursor = self.text.len();
        }
    }

    /// Empty the buffer (used after a successful commit).
    pub fn clear(&mut self) {
        self.text.clear();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// True when the buffer has no committable content (whitespace
    /// only or empty). The `Commit` button uses this to decide whether
    /// to toast vs actually commit.
    pub fn is_blank(&self) -> bool {
        self.text.trim().is_empty()
    }
}

fn prev_char_boundary(s: &str, mut at: usize) -> usize {
    if at == 0 {
        return 0;
    }
    at -= 1;
    while at > 0 && !s.is_char_boundary(at) {
        at -= 1;
    }
    at
}

fn next_char_boundary(s: &str, mut at: usize) -> usize {
    let len = s.len();
    if at >= len {
        return len;
    }
    at += 1;
    while at < len && !s.is_char_boundary(at) {
        at += 1;
    }
    at
}

/// True when `git status --porcelain` reports any uncommitted change
/// (untracked / modified / staged / conflict). Cheap — runs once per
/// graph-pane open / refresh. Falls back to `false` when git is missing
/// or this isn't a repo.
fn working_tree_has_changes(workspace: &Path) -> bool {
    use std::process::Command;
    match Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace)
        .output()
    {
        Ok(out) if out.status.success() => !out.stdout.is_empty(),
        _ => false,
    }
}
