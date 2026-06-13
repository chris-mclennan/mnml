//! Git subsystem methods on `App` — diff pane / hunk stage / commit
//! prompt / branch + worktree pickers / blame gutter / git graph /
//! git status pane / WIP textarea / GIT rail / stash / cherry-pick /
//! revert / tag / reflog / sync (fetch/pull/push) / multi-repo cycle.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move.

use super::*;

impl App {
    /// Dispatch a click on one of the `> GIT` rail header chips (Fetch /
    /// Pull / Push / Stage all / Commit / Graph). Routes to palette
    /// commands for most; `StageAll` calls `git_stage_all_rail` directly
    /// since the existing `git_stage_all_active` requires a `Pane::GitStatus`
    /// focus we don't want to force.
    pub fn run_git_rail_header_action(&mut self, action: crate::GitRailHeaderAction) {
        use crate::GitRailHeaderAction::*;
        match action {
            Fetch => {
                let _ = crate::command::run("git.fetch", self);
            }
            Pull => {
                let _ = crate::command::run("git.pull", self);
            }
            Push => {
                let _ = crate::command::run("git.push", self);
            }
            StageAll => self.git_stage_all_rail(),
            Commit => {
                let _ = crate::command::run("git.commit", self);
            }
            Graph => {
                let _ = crate::command::run("git.graph", self);
            }
        }
    }

    /// Stage every change in the active repo without requiring `Pane::GitStatus`
    /// to be focused. Sibling to `git_stage_all_active` (which IS gated on the
    /// status pane); this one is the rail-header / programmatic entry point.
    pub fn git_stage_all_rail(&mut self) {
        match crate::git::stage::stage_all(self.active_repo_path()) {
            Ok(()) => {
                self.toast("staged all changes");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add -A: {e}")),
        }
    }

    /// Right-click on the statusline branch chip — exposes the common
    /// per-branch git ops (checkout / new / fetch / pull / push / stash /
    /// graph / status) as a flat menu so they don't all need keyboard
    /// chords or the palette.
    pub fn open_statusline_branch_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self
            .git
            .snapshot()
            .branch
            .clone()
            .unwrap_or_else(|| "git".into());
        let items = vec![
            MenuItem::new("Commit graph", MenuAction::Command("git.graph")),
            MenuItem::new("Status pane", MenuAction::Command("git.status_pane")),
            MenuItem::new("Checkout branch…", MenuAction::Command("git.checkout")),
            MenuItem::new("New branch…", MenuAction::Command("git.new_branch")),
            MenuItem::new("Fetch", MenuAction::Command("git.fetch")),
            MenuItem::new("Pull", MenuAction::Command("git.pull")),
            MenuItem::new("Push", MenuAction::Command("git.push")),
            MenuItem::new("Stash…", MenuAction::Command("git.stash")),
            MenuItem::new("Stash pop", MenuAction::Command("git.stash_pop")),
            MenuItem::new("Commit…", MenuAction::Command("git.commit")),
            MenuItem::new("AI commit message", MenuAction::Command("git.ai_commit")),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click on a row inside a diff body (standalone or
    /// embedded) — build a context menu with hunk-aware actions:
    /// for commit diffs we add "Open file at this revision" /
    /// "Copy commit hash"; for unstaged/staged diffs we add the
    /// Stage / Unstage / Discard chip equivalents. `hunk_index`
    /// refers to the underlying `hunks` vec of whichever DiffView
    /// the row belongs to.
    /// Right-click on a row in the GitStatus pane → per-file
    /// context menu with stage / discard / ignore / stash / reveal /
    /// copy-path / open / delete entries. `idx` is the flat index
    /// (unstaged-first, then staged).
    pub fn open_git_status_context_menu(
        &mut self,
        pane_id: PaneId,
        idx: usize,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(Pane::GitStatus(g)) = self.panes.get(pane_id) else {
            return;
        };
        let u = g.unstaged.len();
        let (entry, is_staged) = if idx < u {
            (&g.unstaged[idx], false)
        } else if let Some(e) = g.staged.get(idx - u) {
            (e, true)
        } else {
            return;
        };
        let rel = entry.rel.clone();
        let abs = self.active_repo_path().join(&rel);
        let basename = std::path::Path::new(&rel)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| rel.clone());
        let ext = std::path::Path::new(&rel)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_string());
        let mut items: Vec<MenuItem> = Vec::new();
        if is_staged {
            items.push(MenuItem::new(
                "Unstage",
                MenuAction::GitUnstageFile(std::path::PathBuf::from(rel.clone())),
            ));
        } else {
            items.push(MenuItem::new(
                "Stage",
                MenuAction::GitStageFile(std::path::PathBuf::from(rel.clone())),
            ));
            items.push(MenuItem::new(
                "Discard changes…",
                MenuAction::GitDiscardFile(std::path::PathBuf::from(rel.clone())),
            ));
        }
        items.push(MenuItem::new(
            "Stash this file",
            MenuAction::GitStashFile(std::path::PathBuf::from(rel.clone())),
        ));
        items.push(MenuItem::new(
            format!("Ignore {basename}"),
            MenuAction::GitIgnoreFile(std::path::PathBuf::from(rel.clone())),
        ));
        if let Some(ext) = ext {
            items.push(MenuItem::new(
                format!("Ignore all *.{ext}"),
                MenuAction::GitIgnoreExtension(ext),
            ));
        }
        items.push(MenuItem::new(
            "Edit file",
            MenuAction::OpenPath(abs.clone()),
        ));
        items.push(MenuItem::new(
            "Reveal in Finder",
            MenuAction::RevealInFinder(abs.clone()),
        ));
        items.push(MenuItem::new("Copy path", MenuAction::CopyPath(rel)));
        items.push(MenuItem::new("Delete file…", MenuAction::Delete(abs)));
        self.context_menu = Some(ContextMenu::new(Some(basename), anchor, items));
    }

    pub fn open_diff_context_menu(
        &mut self,
        pane_id: PaneId,
        hunk_index: usize,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let scope = match self.panes.get(pane_id) {
            Some(Pane::Diff(d)) => Some(d.scope.clone()),
            Some(Pane::GitGraph(g)) => g.embedded_diff.as_ref().map(|d| d.scope.clone()),
            _ => None,
        };
        let Some(scope) = scope else {
            return;
        };
        let mut items: Vec<MenuItem> = Vec::new();
        match scope {
            crate::pane::DiffScope::CommitFile { hash, rel_path } => {
                items.push(MenuItem::new(
                    "Open file at this revision",
                    MenuAction::DiffOpenAtRevision {
                        hash: hash.clone(),
                        rel: rel_path,
                    },
                ));
                items.push(MenuItem::new(
                    format!(
                        "Copy commit hash ({})",
                        hash.chars().take(7).collect::<String>()
                    ),
                    MenuAction::CopyText(hash),
                ));
            }
            crate::pane::DiffScope::Commit(hash) => {
                items.push(MenuItem::new(
                    format!(
                        "Copy commit hash ({})",
                        hash.chars().take(7).collect::<String>()
                    ),
                    MenuAction::CopyText(hash),
                ));
            }
            crate::pane::DiffScope::Unstaged(_) | crate::pane::DiffScope::AllVsHead => {
                items.push(MenuItem::new(
                    "Stage hunk",
                    MenuAction::DiffHunkAction {
                        pane_id,
                        hunk_index,
                        action: crate::DiffHunkAction::Stage,
                    },
                ));
                items.push(MenuItem::new(
                    "Discard hunk",
                    MenuAction::DiffHunkAction {
                        pane_id,
                        hunk_index,
                        action: crate::DiffHunkAction::Discard,
                    },
                ));
            }
            crate::pane::DiffScope::Staged | crate::pane::DiffScope::StagedFile(_) => {
                items.push(MenuItem::new(
                    "Unstage hunk",
                    MenuAction::DiffHunkAction {
                        pane_id,
                        hunk_index,
                        action: crate::DiffHunkAction::Unstage,
                    },
                ));
            }
            crate::pane::DiffScope::BufferVsDisk(_) => {}
        }
        if items.is_empty() {
            return;
        }
        self.context_menu = Some(ContextMenu::new(None, anchor, items));
    }

    /// Set / clear the active GitGraph pane's branch filter. `None` ⇒ all
    /// commits (the default `--all` listing); `Some("foo")` ⇒ only commits
    /// reachable from branch `foo`. No-op when no GitGraph pane is open.
    /// Re-runs `git log` against the new filter + refreshes selection.
    pub fn apply_git_graph_branch_filter(&mut self, branch: Option<String>) {
        let Some(cur) = self.active else {
            self.toast("no active GitGraph pane");
            return;
        };
        let Some(Pane::GitGraph(g)) = self.panes.get_mut(cur) else {
            self.toast("no active GitGraph pane");
            return;
        };
        let label = branch.clone().unwrap_or_else(|| "all".into());
        g.filter.branch = branch;
        g.selected = 0;
        g.scroll = 0;
        g.refresh();
        self.toast(format!("graph filter: branch={label}"));
    }

    /// Apply a date-range filter to the active GitGraph pane. Accepts the
    /// `<since>..<until>` shorthand (either side may be empty),
    /// `--since=<s>` / `--until=<u>` flag form, or a bare expression
    /// treated as `since`. Empty input clears both endpoints. Git's date
    /// parsing accepts any of `1 week ago` / `2026-01-01` / `last Monday`.
    pub fn apply_git_graph_date_filter(&mut self, raw: &str) {
        let Some(cur) = self.active else {
            self.toast("no active GitGraph pane");
            return;
        };
        let Some(Pane::GitGraph(g)) = self.panes.get_mut(cur) else {
            self.toast("no active GitGraph pane");
            return;
        };
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            g.filter.since = None;
            g.filter.until = None;
            g.selected = 0;
            g.scroll = 0;
            g.refresh();
            self.toast("graph filter: cleared date range");
            return;
        }
        // Parse three accepted shapes.
        let (since, until) = if let Some(rest) = trimmed.strip_prefix("--since=") {
            (Some(rest.trim().to_string()), None)
        } else if let Some(rest) = trimmed.strip_prefix("--until=") {
            (None, Some(rest.trim().to_string()))
        } else if let Some((a, b)) = trimmed.split_once("..") {
            let a = a.trim();
            let b = b.trim();
            (
                (!a.is_empty()).then(|| a.to_string()),
                (!b.is_empty()).then(|| b.to_string()),
            )
        } else {
            (Some(trimmed.to_string()), None)
        };
        g.filter.since = since.clone();
        g.filter.until = until.clone();
        g.selected = 0;
        g.scroll = 0;
        g.refresh();
        let label = match (since, until) {
            (Some(s), Some(u)) => format!("since={s} until={u}"),
            (Some(s), None) => format!("since={s}"),
            (None, Some(u)) => format!("until={u}"),
            (None, None) => "all".into(),
        };
        self.toast(format!("graph filter: {label}"));
    }

    /// Apply an author filter. Empty input clears.
    pub fn apply_git_graph_author_filter(&mut self, raw: &str) {
        let Some(cur) = self.active else {
            self.toast("no active GitGraph pane");
            return;
        };
        let Some(Pane::GitGraph(g)) = self.panes.get_mut(cur) else {
            self.toast("no active GitGraph pane");
            return;
        };
        let val = raw.trim();
        g.filter.author = (!val.is_empty()).then(|| val.to_string());
        g.selected = 0;
        g.scroll = 0;
        g.refresh();
        self.toast(if val.is_empty() {
            "graph filter: author cleared".to_string()
        } else {
            format!("graph filter: author={val}")
        });
    }

    /// Apply a subject (message) grep filter. Empty input clears.
    pub fn apply_git_graph_grep_filter(&mut self, raw: &str) {
        let Some(cur) = self.active else {
            self.toast("no active GitGraph pane");
            return;
        };
        let Some(Pane::GitGraph(g)) = self.panes.get_mut(cur) else {
            self.toast("no active GitGraph pane");
            return;
        };
        let val = raw.trim();
        g.filter.grep = (!val.is_empty()).then(|| val.to_string());
        g.selected = 0;
        g.scroll = 0;
        g.refresh();
        self.toast(if val.is_empty() {
            "graph filter: subject cleared".to_string()
        } else {
            format!("graph filter: subject~{val}")
        });
    }

    /// Open a prompt to set the GitGraph date-range filter.
    pub fn open_git_graph_date_filter_prompt(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitGraph(_))) {
            self.toast("open the commit graph first (git.graph)");
            return;
        }
        let seed = if let Some(Pane::GitGraph(g)) = self.active_pane() {
            match (&g.filter.since, &g.filter.until) {
                (Some(s), Some(u)) => format!("{s}..{u}"),
                (Some(s), None) => s.clone(),
                (None, Some(u)) => format!("..{u}"),
                (None, None) => String::new(),
            }
        } else {
            String::new()
        };
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::GitGraphDateFilter,
            "Date range (since[..until], empty clears)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    /// Open a prompt to set the GitGraph author filter.
    pub fn open_git_graph_author_filter_prompt(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitGraph(_))) {
            self.toast("open the commit graph first (git.graph)");
            return;
        }
        let seed = if let Some(Pane::GitGraph(g)) = self.active_pane() {
            g.filter.author.clone().unwrap_or_default()
        } else {
            String::new()
        };
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::GitGraphAuthorFilter,
            "Author (regex; empty clears)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    /// Open a prompt to set the GitGraph subject-grep filter.
    pub fn open_git_graph_grep_filter_prompt(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitGraph(_))) {
            self.toast("open the commit graph first (git.graph)");
            return;
        }
        let seed = if let Some(Pane::GitGraph(g)) = self.active_pane() {
            g.filter.grep.clone().unwrap_or_default()
        } else {
            String::new()
        };
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::GitGraphGrepFilter,
            "Subject contains (empty clears)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    /// Open the branch-picker variant that, on accept, narrows the active
    /// GitGraph pane's commit listing to that branch (rather than the
    /// standard `git checkout` action).
    pub fn open_git_graph_branch_filter_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        if !matches!(self.active_pane(), Some(Pane::GitGraph(_))) {
            self.toast("open the commit graph first (git.graph)");
            return;
        }
        let cur_filter = if let Some(Pane::GitGraph(g)) = self.active_pane() {
            g.filter.branch.clone()
        } else {
            None
        };
        let mut items: Vec<PickerItem> = Vec::new();
        // Always offer the reset row first so it's quick to clear.
        let all_label = if cur_filter.is_none() {
            "● --all (no filter)".to_string()
        } else {
            "  --all (no filter)".to_string()
        };
        items.push(PickerItem::new("--all", all_label, "every ref"));
        let locals = crate::git::branch::local_branches(self.active_repo_path());
        for b in &locals {
            let marker = if cur_filter.as_deref() == Some(b.as_str()) {
                "● "
            } else {
                "  "
            };
            items.push(PickerItem::new(b, format!("{marker}{b}"), "local"));
        }
        for b in crate::git::branch::remote_branches(self.active_repo_path()) {
            let marker = if cur_filter.as_deref() == Some(b.as_str()) {
                "● "
            } else {
                "  "
            };
            items.push(PickerItem::new(&b, format!("{marker}{b}"), "remote"));
        }
        self.open_picker(Picker::new(
            PickerKind::GitGraphBranchFilter,
            "Filter graph by branch",
            items,
        ));
    }

    /// Switch which repo the git rail (branches, worktrees, pulls) is
    /// scoped to. No-op when `idx` is out of range or already active.
    pub fn switch_active_repo(&mut self, idx: usize) {
        if idx >= self.repos.len() {
            return;
        }
        if idx == self.active_repo {
            return;
        }
        let name = self.repos[idx].name.clone();
        self.active_repo = idx;
        let root = self.active_repo_path().to_path_buf();
        self.git.retarget(&root);
        self.git_rail.refresh(&root);
        self.refresh_rail_pulls();
        // Retarget every open GitStatus / GitGraph pane so they follow the
        // new active repo. Other panes (BB / GH / GL / AZ pipelines etc.)
        // aren't repo-scoped so they don't need to move.
        for pane in &mut self.panes {
            match pane {
                Pane::GitStatus(g) => g.retarget(&root),
                Pane::GitGraph(g) => g.retarget(&root),
                _ => {}
            }
        }
        self.toast(format!("active repo → {name}"));
    }

    /// Walk forward / backward through `self.repos`, wrapping at the
    /// ends. No-op when there's only one repo. Drives both the
    /// `git.next_repo` / `git.prev_repo` palette commands and the
    /// mouse-wheel handler on the GIT rail header.
    pub fn cycle_active_repo(&mut self, forward: bool) {
        let n = self.repos.len();
        if n <= 1 {
            return;
        }
        let next = if forward {
            (self.active_repo + 1) % n
        } else {
            (self.active_repo + n - 1) % n
        };
        self.switch_active_repo(next);
    }

    /// Relative path of `p` against the active git repo (vs. the workspace
    /// root, which can differ when multiple repos coexist under one
    /// workspace). Used to feed `git`'s positional args — `git blame
    /// src/foo.rs` only works if cwd is the repo containing `src/foo.rs`.
    fn rel_to_active_repo(&self, p: &Path) -> String {
        rel_path(self.active_repo_path(), p)
    }

    /// Toggle the editor's blame-gutter mode for the active buffer (computing
    /// `git blame` when turning it on).
    pub fn toggle_blame(&mut self) {
        let Some(cur) = self.active else { return };
        let already_on = matches!(self.panes.get(cur), Some(Pane::Editor(b)) if b.blame.is_some());
        if already_on {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
                b.blame = None;
            }
            self.toast("blame: off");
            return;
        }
        let repo = self.active_repo_path().to_path_buf();
        let (rel, path) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => match &b.path {
                Some(p) => (rel_path(&repo, p), p.clone()),
                None => {
                    self.toast("blame needs a saved file");
                    return;
                }
            },
            _ => {
                self.toast("blame: not an editor");
                return;
            }
        };
        // Phase async: `git blame` on a huge file can take 10+s.
        // Send it to the loader; `drain_git_results` matches the
        // Blamed result back to the pane by absolute path on the
        // next tick. untouched-surfaces-hunt-2026-06-08 SEV-2 #9.
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::Blame { repo, rel, path });
        self.toast("computing blame…");
    }

    /// If a buffer with blame mode on was just saved, recompute its blame.
    /// Async via the git loader — the saved buffer keeps its prior
    /// blame visible until the recomputed one lands, which avoids a
    /// blank gutter flash on every save.
    pub(super) fn refresh_blame_for(&mut self, path: &Path) {
        let repo = self.active_repo_path().to_path_buf();
        let rel = rel_path(&repo, path);
        // Only queue if there's an editor pane with blame on for this
        // path — avoids spinning the loader for buffers that never
        // had blame requested.
        let needs = self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.blame.is_some() && b.is_at(path)));
        if !needs {
            return;
        }
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::Blame {
                repo,
                rel,
                path: path.to_path_buf(),
            });
    }

    /// Apply a `GitResult::Blamed` to whatever editor pane is open
    /// on the given path. No-ops when the pane was closed between
    /// the request and the result.
    pub(super) fn apply_blame_result(
        &mut self,
        path: &Path,
        lines: Vec<crate::git::blame::BlameLine>,
    ) {
        if lines.is_empty() {
            // Untracked file or other "no output" case. Don't clear
            // the existing blame — preserve any prior result so a
            // mid-edit save doesn't blank the gutter.
            self.toast("git blame returned nothing (untracked file?)");
            return;
        }
        let mut applied = false;
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.is_at(path)
            {
                b.blame = Some(lines.clone());
                applied = true;
            }
        }
        if applied {
            self.toast("blame: on");
        }
    }

    pub(super) fn fetch_diff(&self, scope: &crate::pane::DiffScope) -> Vec<crate::git::diff::Hunk> {
        use crate::pane::DiffScope;
        let repo = self.active_repo_path();
        match scope {
            DiffScope::Unstaged(Some(p)) => {
                crate::git::diff::diff_file(repo, &self.rel_to_active_repo(p))
            }
            DiffScope::Unstaged(None) => crate::git::diff::diff_worktree(repo),
            DiffScope::Staged => crate::git::diff::diff_staged(repo),
            DiffScope::StagedFile(p) => {
                crate::git::diff::diff_staged_file(repo, &self.rel_to_active_repo(p))
            }
            DiffScope::Commit(h) => crate::git::diff::show_commit(repo, h),
            DiffScope::CommitFile { hash, rel_path } => {
                crate::git::diff::show_commit_file(repo, hash, &rel_path.to_string_lossy())
            }
            DiffScope::BufferVsDisk(path) => self.diff_buffer_vs_disk(path),
            DiffScope::AllVsHead => crate::git::diff::diff_vs_head(repo),
        }
    }

    /// Same as [`Self::fetch_diff`] but asks git for full-file
    /// context (`-U99999`). Used by the split (side-by-side) diff
    /// renderer so untouched lines surround the changes — the
    /// "whole file" view.
    pub fn fetch_diff_full(&self, scope: &crate::pane::DiffScope) -> Vec<crate::git::diff::Hunk> {
        use crate::pane::DiffScope;
        let repo = self.active_repo_path();
        match scope {
            DiffScope::Unstaged(Some(p)) => {
                crate::git::diff::diff_file_full(repo, &self.rel_to_active_repo(p))
            }
            DiffScope::Unstaged(None) => crate::git::diff::diff_worktree_full(repo),
            DiffScope::Staged => crate::git::diff::diff_staged_full(repo),
            DiffScope::StagedFile(p) => {
                crate::git::diff::diff_staged_file_full(repo, &self.rel_to_active_repo(p))
            }
            DiffScope::Commit(h) => crate::git::diff::show_commit_full(repo, h),
            DiffScope::CommitFile { hash, rel_path } => {
                crate::git::diff::show_commit_file_full(repo, hash, &rel_path.to_string_lossy())
            }
            DiffScope::BufferVsDisk(path) => self.diff_buffer_vs_disk(path),
            DiffScope::AllVsHead => crate::git::diff::diff_vs_head_full(repo),
        }
    }

    /// Compute the diff between the in-memory buffer for `path` and its
    /// on-disk version. Shell out to `git diff --no-index` (uses the same
    /// parser the regular diff pane needs); fall back to empty if it
    /// can't be run. Writes the buffer text to a tempfile in
    /// `.mnml/tmp/` so the `--no-index` invocation has two real paths.
    fn diff_buffer_vs_disk(&self, path: &Path) -> Vec<crate::git::diff::Hunk> {
        let mem_text = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.path.as_deref() == Some(path) => {
                    Some(b.editor.text().to_string())
                }
                _ => None,
            })
            .unwrap_or_default();
        let tmp_dir = self.workspace.join(".mnml").join("tmp");
        if std::fs::create_dir_all(&tmp_dir).is_err() {
            return Vec::new();
        }
        let stem = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "buffer".to_string());
        let tmp = tmp_dir.join(format!("{stem}.diffview"));
        if std::fs::write(&tmp, &mem_text).is_err() {
            return Vec::new();
        }
        let repo = self.active_repo_path();
        let out = std::process::Command::new("git")
            .args(["diff", "--no-index", "--no-color", "--"])
            .arg(path)
            .arg(&tmp)
            .current_dir(repo)
            .output();
        let stdout = match out {
            Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
            Err(_) => String::new(),
        };
        // `git diff --no-index` exits non-zero when files differ — that's
        // expected, so we don't check `.status.success()`.
        let _ = std::fs::remove_file(&tmp);
        crate::git::diff::parse_hunks(&stdout, repo)
    }

    /// Open a `git diff` view of the active editor's file, in a split to the right.
    pub fn open_diff_file(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.path.clone(),
            Some(Pane::Diff(d)) => match &d.scope {
                crate::pane::DiffScope::Unstaged(p) => p.clone(),
                crate::pane::DiffScope::Staged
                | crate::pane::DiffScope::Commit(_)
                | crate::pane::DiffScope::CommitFile { .. }
                | crate::pane::DiffScope::AllVsHead => None,
                crate::pane::DiffScope::StagedFile(p) => Some(p.clone()),
                crate::pane::DiffScope::BufferVsDisk(p) => Some(p.clone()),
            },
            _ => None,
        };
        let Some(path) = path else {
            self.toast("git diff needs a saved file");
            return;
        };
        let scope = crate::pane::DiffScope::Unstaged(Some(path));
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unstaged changes in that file");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(self.make_diff_view(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// `git.peek_change` (`<leader>g p`) — show the hunk under the cursor as
    /// a floating popup (uses the same hover widget as LSP). Toasts if the
    /// cursor isn't on a changed line.
    pub fn peek_git_change_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("git peek needs a saved file");
            return;
        };
        let (line_0, _) = b.editor.row_col();
        let repo = self.active_repo_path().to_path_buf();
        let rel = match path.strip_prefix(&repo) {
            Ok(r) => r.to_string_lossy().to_string(),
            Err(_) => {
                self.toast("file is outside the active git repo");
                return;
            }
        };
        let Some(hunk) = crate::git::diff::peek_hunk_at(&repo, &rel, line_0) else {
            self.toast("no change at cursor");
            return;
        };
        // Format as: header line, then the hunk's lines with their `+`/`-`/` ` prefix.
        let mut out: Vec<String> = Vec::with_capacity(hunk.lines.len() + 1);
        out.push(hunk.header.clone());
        for hl in &hunk.lines {
            use crate::git::diff::HunkLine;
            match hl {
                HunkLine::Context(t) => out.push(format!(" {t}")),
                HunkLine::Added(t) => out.push(format!("+{t}")),
                HunkLine::Removed(t) => out.push(format!("-{t}")),
                HunkLine::NoNewline => out.push("\\ No newline at end of file".to_string()),
            }
        }
        match crate::hover::HoverPopup::from_lines(out) {
            Some(h) => self.hover = Some(h),
            None => self.toast("peek: (empty)"),
        }
    }

    /// `:Diffsplit <other>` — diff the active buffer's text against
    /// `<other>` on disk. Always opens a fresh diff pane; doesn't try
    /// to reuse the buffer-vs-disk scope (the buffer's own path may
    /// be unrelated to `<other>`). Read-only.
    pub fn open_diff_buffer_vs_file(&mut self, other: PathBuf) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let mem_text = match self.active_editor() {
            Some(b) => b.editor.text().to_string(),
            None => {
                self.toast(":Diffsplit needs an editor pane");
                return;
            }
        };
        // Write the buffer text to a tempfile and shell out the diff.
        let tmp_dir = self.workspace.join(".mnml").join("tmp");
        if let Err(e) = std::fs::create_dir_all(&tmp_dir) {
            self.toast(format!(":Diffsplit: tmp dir: {e}"));
            return;
        }
        let stem = "buffer";
        let tmp = tmp_dir.join(format!("{stem}.diffwith"));
        if let Err(e) = std::fs::write(&tmp, &mem_text) {
            self.toast(format!(":Diffsplit: write tmp: {e}"));
            return;
        }
        let repo = self.active_repo_path().to_path_buf();
        let out = std::process::Command::new("git")
            .args(["diff", "--no-index", "--no-color", "--"])
            .arg(&other)
            .arg(&tmp)
            .current_dir(&repo)
            .output();
        let stdout = match out {
            Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
            Err(e) => {
                self.toast(format!(":Diffsplit failed: {e}"));
                return;
            }
        };
        let _ = std::fs::remove_file(&tmp);
        let hunks = crate::git::diff::parse_hunks(&stdout, &repo);
        if hunks.is_empty() {
            self.toast("no differences");
            return;
        }
        let scope = crate::pane::DiffScope::BufferVsDisk(other);
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(self.make_diff_view(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// `git.diff_orig` (`:DiffOrig`) — open a diff pane comparing the
    /// active buffer's in-memory text against its on-disk version. Vim
    /// canonical for "what have I changed since I last saved". Read-only
    /// (the diff pane's stage/unstage doesn't apply to this scope).
    pub fn open_diff_buffer_vs_disk(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
            self.toast(":DiffOrig needs a saved file");
            return;
        };
        let scope = crate::pane::DiffScope::BufferVsDisk(path);
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unsaved changes");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(self.make_diff_view(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Open one file's contribution to a commit as a `Pane::Diff`
    /// (`git show <hash> -- <rel_path>`). Used by the commit-detail
    /// panel's "Diff view" button.
    pub fn open_commit_file_diff(&mut self, hash: &str, rel_path: &std::path::Path) {
        let scope = crate::pane::DiffScope::CommitFile {
            hash: hash.to_string(),
            rel_path: rel_path.to_path_buf(),
        };
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast(format!(
                "{} — no diff for {}",
                &hash.chars().take(9).collect::<String>(),
                rel_path.display()
            ));
            return;
        }
        self.panes
            .push(Pane::Diff(self.make_diff_view(scope, hunks)));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
    }

    /// Click handler for a changed-file row in the GitGraph
    /// commit-detail panel. Opens the file's diff as an embedded
    /// diff INSIDE the GitGraph pane (replacing the commit list)
    /// so the right detail panel stays visible alongside.
    pub fn click_commit_file_row(&mut self, pane_id: crate::layout::PaneId, file_idx: usize) {
        let Some(Pane::GitGraph(g)) = self.panes.get(pane_id) else {
            return;
        };
        let Some(detail) = g.detail.as_ref() else {
            return;
        };
        let Some((_, rel)) = detail.files.get(file_idx) else {
            return;
        };
        let hash = detail.hash.clone();
        let rel_path = std::path::PathBuf::from(rel);
        // Ensure the GitGraph is the active pane so the embedded-diff
        // helper finds it (the click handler in tui.rs may have
        // already done this, but be defensive).
        self.active = Some(pane_id);
        let scope = crate::pane::DiffScope::CommitFile {
            hash: hash.clone(),
            rel_path: rel_path.clone(),
        };
        let empty_label = format!(
            "{} — no diff for {}",
            hash.chars().take(9).collect::<String>(),
            rel_path.display()
        );
        self.open_embedded_diff_in_active_graph(scope, empty_label);
    }

    /// Build a `DiffView` with the user's remembered view-mode +
    /// wrap preference applied. Use this in place of
    /// `DiffView::new(...)` everywhere a diff pane is created.
    pub fn make_diff_view(
        &self,
        scope: crate::pane::DiffScope,
        hunks: Vec<crate::git::diff::Hunk>,
    ) -> crate::pane::DiffView {
        let mut dv = crate::pane::DiffView::new(scope, hunks);
        dv.view_mode = self.diff_view_mode_pref;
        dv.wrap = self.diff_wrap_pref;
        dv
    }

    /// Open an embedded diff in the active GitGraph pane (replaces
    /// the commit-list area). If the active pane isn't a GitGraph,
    /// falls back to opening a regular `Pane::Diff` so the user
    /// can still see the diff.
    pub(super) fn open_embedded_diff_in_active_graph(
        &mut self,
        scope: crate::pane::DiffScope,
        empty_toast: String,
    ) {
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast(empty_toast);
            return;
        }
        let active_is_graph = matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::GitGraph(_))
        );
        let dv = self.make_diff_view(scope, hunks);
        if active_is_graph
            && let Some(id) = self.active
            && let Some(Pane::GitGraph(g)) = self.panes.get_mut(id)
        {
            g.embedded_diff = Some(dv);
            return;
        }
        // Fallback: no GitGraph active → open as a regular Diff pane.
        self.panes.push(Pane::Diff(dv));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
    }

    /// Open a diff pane for `hash` (one commit). Helper for the file-history
    /// picker accept path.
    pub fn open_commit_diff(&mut self, hash: &str) {
        let scope = crate::pane::DiffScope::Commit(hash.to_string());
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast(format!(
                "{} — empty diff",
                &hash.chars().take(9).collect::<String>()
            ));
            return;
        }
        self.panes
            .push(Pane::Diff(self.make_diff_view(scope, hunks)));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
    }

    /// Open a `git diff` view of the whole worktree, in the focused leaf.
    pub fn open_diff_worktree(&mut self) {
        let scope = crate::pane::DiffScope::Unstaged(None);
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unstaged changes");
            return;
        }
        self.panes
            .push(Pane::Diff(self.make_diff_view(scope, hunks)));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
    }

    /// Open a single diff pane showing every change vs HEAD — both staged
    /// and unstaged combined. Diffview-style "everything I've touched"
    /// browser. Use `]f` / `[f` inside the pane to jump file-by-file.
    pub fn open_diff_all(&mut self) {
        let scope = crate::pane::DiffScope::AllVsHead;
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no changes vs HEAD");
            return;
        }
        let file_count = {
            let mut files: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
            for h in &hunks {
                files.insert(&h.file_rel);
            }
            files.len()
        };
        self.panes
            .push(Pane::Diff(self.make_diff_view(scope, hunks)));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
        self.toast(format!("diff: {file_count} file(s) vs HEAD"));
    }

    /// Diff-pane file jump: move the cursor hunk to the first hunk of the
    /// next file (`forward = true`) or the previous file's first hunk
    /// (`forward = false`). Wraps. No-op when only one file is in the diff.
    ///
    /// For the embedded diff inside `Pane::GitGraph` (which carries
    /// a `DiffScope::CommitFile { hash, rel_path }` — only one file
    /// per view), reopens the embedded diff against the *next* /
    /// *prev* file in the selected commit's changed-files list.
    /// Falls through to the standalone behavior otherwise.
    pub fn diff_jump_file(&mut self, forward: bool) {
        let Some(cur) = self.active else { return };
        // Embedded-diff branch: walk the active commit's file list.
        if let Some(Pane::GitGraph(g)) = self.panes.get(cur)
            && let Some(d) = g.embedded_diff.as_ref()
            && let crate::pane::DiffScope::CommitFile { hash, rel_path } = &d.scope
        {
            let hash = hash.clone();
            let rel = rel_path.clone();
            let Some(detail) = g.detail.as_ref() else {
                return;
            };
            let files: Vec<std::path::PathBuf> = detail
                .files
                .iter()
                .map(|(_, p)| std::path::PathBuf::from(p))
                .collect();
            if files.len() <= 1 {
                return;
            }
            let cur_idx = files.iter().position(|p| *p == rel).unwrap_or(0);
            let next = if forward {
                (cur_idx + 1) % files.len()
            } else {
                (cur_idx + files.len() - 1) % files.len()
            };
            let next_path = files[next].clone();
            // Re-open the embedded diff against the new file.
            let scope = crate::pane::DiffScope::CommitFile {
                hash,
                rel_path: next_path,
            };
            self.open_embedded_diff_in_active_graph(scope, "no diff for file".to_string());
            return;
        }
        let Some(Pane::Diff(d)) = self.panes.get_mut(cur) else {
            return;
        };
        if d.hunks.is_empty() {
            return;
        }
        let cur_file = d.hunks[d.cursor].file_rel.clone();
        let n = d.hunks.len();
        // Collect each file's first hunk index (in encounter order — the
        // existing hunk vector is already file-grouped by `git diff`).
        let mut firsts: Vec<usize> = Vec::new();
        let mut seen: Option<&str> = None;
        for (i, h) in d.hunks.iter().enumerate() {
            if seen != Some(h.file_rel.as_str()) {
                firsts.push(i);
                seen = Some(h.file_rel.as_str());
            }
        }
        if firsts.len() <= 1 {
            return;
        }
        // Find the file the cursor is in.
        let cur_file_idx = firsts
            .iter()
            .rposition(|&i| d.hunks[i].file_rel == cur_file)
            .unwrap_or(0);
        let next = if forward {
            (cur_file_idx + 1) % firsts.len()
        } else {
            (cur_file_idx + firsts.len() - 1) % firsts.len()
        };
        d.cursor = firsts[next].min(n - 1);
    }

    /// Dispatch a per-hunk chip click on the diff pane `pid` (or the
    /// embedded diff inside a `Pane::GitGraph(pid)`). The chip's
    /// `hunk_index` indexes into the diff's `hunks` vec. Stage /
    /// Unstage route through `git apply --cached [--reverse]`;
    /// Discard route through `git apply --reverse` against the
    /// working tree (no `--cached`).
    pub fn apply_hunk_action(
        &mut self,
        pid: PaneId,
        hunk_index: usize,
        action: crate::DiffHunkAction,
    ) {
        let (hunk, scope) = match self.panes.get(pid) {
            Some(Pane::Diff(d)) => (d.hunks.get(hunk_index).cloned(), Some(d.scope.clone())),
            Some(Pane::GitGraph(g)) => g.embedded_diff.as_ref().map_or((None, None), |d| {
                (d.hunks.get(hunk_index).cloned(), Some(d.scope.clone()))
            }),
            _ => (None, None),
        };
        let Some(hunk) = hunk else { return };
        if matches!(scope, Some(crate::pane::DiffScope::Commit(_)))
            || matches!(scope, Some(crate::pane::DiffScope::CommitFile { .. }))
        {
            self.toast("that's a committed change — nothing to stage / discard");
            return;
        }
        // Discard is destructive — route through a "type 'discard' to
        // confirm" prompt instead of firing immediately.
        if matches!(action, crate::DiffHunkAction::Discard) {
            self.pending_discard_hunk = Some((pid, hunk_index));
            let title = format!(
                "Discard hunk in {} — type 'discard' to confirm",
                hunk.file_rel
            );
            self.prompt = Some(crate::prompt::Prompt::new(
                crate::prompt::PromptKind::DiffDiscardHunk,
                title,
            ));
            return;
        }
        let workspace = self.active_repo_path().to_path_buf();
        let res = match action {
            crate::DiffHunkAction::Stage => crate::git::diff::apply_hunk(&workspace, &hunk, false),
            crate::DiffHunkAction::Unstage => crate::git::diff::apply_hunk(&workspace, &hunk, true),
            crate::DiffHunkAction::Discard => unreachable!(),
        };
        match res {
            Ok(()) => {
                self.toast(match action {
                    crate::DiffHunkAction::Stage => "staged hunk",
                    crate::DiffHunkAction::Unstage => "unstaged hunk",
                    crate::DiffHunkAction::Discard => "discarded hunk",
                });
                self.after_git_change();
                self.refresh_active_diff();
            }
            Err(e) => self.toast(format!("git apply failed: {e}")),
        }
    }

    /// Accept handler for the `DiffDiscardHunk` confirmation prompt.
    /// Requires the typed text to equal the literal `discard`; on
    /// match, reverse-applies the hunk against the working tree.
    pub fn accept_discard_hunk(&mut self, typed: &str) {
        let Some((pid, hi)) = self.pending_discard_hunk.take() else {
            return;
        };
        if typed.trim() != "discard" {
            self.toast("discard cancelled");
            return;
        }
        let hunk = match self.panes.get(pid) {
            Some(Pane::Diff(d)) => d.hunks.get(hi).cloned(),
            Some(Pane::GitGraph(g)) => g
                .embedded_diff
                .as_ref()
                .and_then(|d| d.hunks.get(hi).cloned()),
            _ => None,
        };
        let Some(hunk) = hunk else { return };
        let workspace = self.active_repo_path().to_path_buf();
        match crate::git::diff::discard_hunk(&workspace, &hunk) {
            Ok(()) => {
                self.toast("discarded hunk");
                self.after_git_change();
                self.refresh_active_diff();
            }
            Err(e) => self.toast(format!("git apply failed: {e}")),
        }
    }

    /// Stage (`reverse == false`) / unstage the cursor hunk of the active diff pane.
    pub fn apply_cursor_hunk(&mut self, reverse: bool) {
        let Some(cur) = self.active else { return };
        let hunk = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => d.hunks.get(d.cursor).cloned(),
            _ => return,
        };
        let Some(hunk) = hunk else { return };
        if matches!(
            self.panes.get(cur),
            Some(Pane::Diff(d)) if matches!(d.scope, crate::pane::DiffScope::Commit(_))
        ) {
            self.toast("that's a committed change — nothing to stage");
            return;
        }
        match crate::git::diff::apply_hunk(self.active_repo_path(), &hunk, reverse) {
            Ok(()) => {
                self.toast(if reverse {
                    "unstaged hunk"
                } else {
                    "staged hunk"
                });
                self.after_git_change();
                self.refresh_active_diff();
            }
            Err(e) => self.toast(format!("git apply failed: {e}")),
        }
    }

    /// Jump the source editor to the cursor hunk's first new-file line (if that
    /// file is open). Used by Enter in the diff pane.
    pub fn jump_to_cursor_hunk(&mut self) {
        let Some(cur) = self.active else { return };
        let (path, line) = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => match d.hunks.get(d.cursor) {
                Some(h) => (h.file.clone(), h.new_start.saturating_sub(1)),
                None => return,
            },
            _ => return,
        };
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
                b.editor.place_cursor(line, 0);
            }
            self.active = Some(id);
            self.focus = Focus::Pane;
        } else {
            self.open_path(&path);
            if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                b.editor.place_cursor(line, 0);
            }
        }
    }

    /// `git.stash` — open a prompt for the (optional) message. Accept with an
    /// empty input ⇒ untitled stash. Accept with text ⇒ `git stash push -u
    /// -m <text>`. Esc ⇒ no stash. The `-u` (include untracked) flag is on
    /// by default so new files don't get left behind.
    pub fn open_stash_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GitStashMessage,
            "Stash message (Enter for none)",
        ));
    }

    /// Run the stash push directly (called from the prompt's accept arm or
    /// from a future "stash without message" chord).
    pub fn run_git_stash_push(&mut self, message: Option<&str>) {
        // untouched-surfaces-hunt-2026-06-08 SEV-2 #7: refuse rather
        // than warn. `git stash push` shells `git diff` against the
        // working tree on disk — in-memory unsaved edits aren't
        // captured, so a later `stash pop` + save would silently
        // overwrite them with the disk version. Symmetric with the
        // pull-with-dirty refusal in `run_git_pull`.
        let dirty_open = self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.dirty));
        if dirty_open {
            self.toast("git stash: refuse — unsaved edits in open buffers");
            return;
        }
        match crate::git::stash::push(self.active_repo_path(), message) {
            Ok(summary) => {
                self.after_git_change();
                self.tree.refresh();
                self.toast(summary);
            }
            Err(e) => self.toast(format!("git stash: {e}")),
        }
    }

    /// `git.stash_pop` — apply + drop the most recent stash.
    pub fn run_git_stash_pop(&mut self) {
        match crate::git::stash::pop(self.active_repo_path()) {
            Ok(summary) => {
                self.after_git_change();
                self.tree.refresh();
                self.toast(format!("popped: {summary}"));
            }
            Err(e) => self.toast(format!("git stash pop: {e}")),
        }
    }

    /// `git.fetch` — `git fetch --all --prune`. Refreshes every tracked
    /// remote's refs + drops gone-upstream tracking marks. Always safe
    /// (read-only). Refreshes the status snapshot so the statusline's
    /// ahead/behind counts update right away.
    pub fn run_git_fetch(&mut self) {
        let repo = self.active_repo_path().to_path_buf();
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::Fetch { repo });
        self.toast("fetching…");
    }

    /// `git.pull` — `git pull --ff-only`. Refuses on divergent histories
    /// so the user falls back to manual merge instead of getting a
    /// surprise merge commit. Refuses with a warning when unsaved
    /// buffers exist (pull rewrites tracked files; in-mnml edits would
    /// silently conflict).
    pub fn run_git_pull(&mut self) {
        let dirty_open = self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.dirty));
        if dirty_open {
            self.toast("git pull: refuse — unsaved edits in open buffers");
            return;
        }
        let repo = self.active_repo_path().to_path_buf();
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::Pull { repo });
        self.toast("pulling…");
    }

    /// `git.push` — `git push`. Falls back to `--set-upstream origin
    /// <current>` when the current branch has no tracked upstream (the
    /// common "first push of a new branch" case). No `--force`.
    pub fn run_git_push(&mut self) {
        let repo = self.active_repo_path().to_path_buf();
        let current_branch = self.git_rail.current_branch.clone();
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::Push {
                repo,
                current_branch,
            });
        self.toast("pushing…");
    }

    /// `git.cherry_pick` — apply the selected `Pane::GitGraph` commit on
    /// top of HEAD. Conflicts land in the toast with git's message
    /// (`git cherry-pick --continue` from a pty when ready).
    pub fn run_git_cherry_pick(&mut self) {
        let Some(hash) = self.selected_graph_commit_hash() else {
            self.toast("git cherry-pick: no commit selected");
            return;
        };
        let repo = self.active_repo_path().to_path_buf();
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::CherryPick {
                repo,
                hash: hash.clone(),
            });
        self.toast(format!("cherry-picking {}…", &hash[..8.min(hash.len())]));
    }

    /// Drain the git-loader result channel. Called from `App::tick`
    /// before rendering so completions surface promptly. Each branch
    /// fires `after_git_change` + a final toast matching the legacy
    /// sync behaviour.
    pub fn drain_git_results(&mut self) {
        use crate::app::git_async::{GitResult, PushKind};
        loop {
            match self.git_loader_rx.try_recv() {
                Ok(GitResult::Fetched(Ok(summary))) => {
                    self.after_git_change();
                    self.toast(format!("fetched: {summary}"));
                }
                Ok(GitResult::Fetched(Err(e))) => self.toast(format!("git fetch: {e}")),
                Ok(GitResult::Pulled(Ok(summary))) => {
                    self.after_git_change();
                    self.tree.refresh();
                    self.toast(format!("pulled: {summary}"));
                }
                Ok(GitResult::Pulled(Err(e))) => self.toast(format!("git pull: {e}")),
                Ok(GitResult::Pushed {
                    kind: PushKind::Normal,
                    result: Ok(summary),
                }) => {
                    self.after_git_change();
                    self.toast(format!("pushed: {summary}"));
                }
                Ok(GitResult::Pushed {
                    kind: PushKind::SetUpstream,
                    result: Ok(summary),
                }) => {
                    self.after_git_change();
                    self.toast(format!("pushed (first time): {summary}"));
                }
                Ok(GitResult::Pushed {
                    kind: PushKind::Normal,
                    result: Err(e),
                }) => self.toast(format!("git push: {e}")),
                Ok(GitResult::Pushed {
                    kind: PushKind::SetUpstream,
                    result: Err(e),
                }) => self.toast(format!("git push --set-upstream: {e}")),
                Ok(GitResult::CherryPicked {
                    hash,
                    result: Ok(summary),
                }) => {
                    self.after_git_change();
                    self.tree.refresh();
                    self.toast(format!(
                        "cherry-picked {}: {summary}",
                        &hash[..8.min(hash.len())]
                    ));
                }
                Ok(GitResult::CherryPicked { result: Err(e), .. }) => {
                    self.toast(format!("git cherry-pick: {e}"))
                }
                Ok(GitResult::Blamed { path, lines }) => {
                    self.apply_blame_result(&path, lines);
                }
                Ok(GitResult::CheckedOut {
                    kind,
                    from_branch,
                    result,
                }) => {
                    self.apply_checkout_result(kind, from_branch, result);
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    self.toast("git loader thread died");
                    break;
                }
            }
        }
    }

    /// `git.revert` — create a new commit that undoes the selected
    /// `Pane::GitGraph` commit. Uses `--no-edit` (default `Revert "..."`
    /// message); conflicts land in the toast.
    pub fn run_git_revert(&mut self) {
        let Some(hash) = self.selected_graph_commit_hash() else {
            self.toast("git revert: no commit selected");
            return;
        };
        match crate::git::commit::revert(self.active_repo_path(), &hash) {
            Ok(summary) => {
                self.after_git_change();
                self.tree.refresh();
                self.toast(format!(
                    "reverted {}: {summary}",
                    &hash[..8.min(hash.len())]
                ));
            }
            Err(e) => self.toast(format!("git revert: {e}")),
        }
    }

    /// The selected commit's hash from the active `Pane::GitGraph`, if any.
    pub(super) fn selected_graph_commit_hash(&self) -> Option<String> {
        self.active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                Pane::GitGraph(g) => g.selected_commit().map(|c| c.hash.clone()),
                _ => None,
            })
    }

    /// `git.tag` — open a single-line prompt for the tag name. The same input
    /// is used as both name and annotation message; for finer control the
    /// user can drop to a pty. Targets the selected `Pane::GitGraph` commit
    /// if the graph is focused, otherwise HEAD.
    pub fn open_git_tag_prompt(&mut self) {
        let title = match self.selected_graph_commit_hash() {
            Some(h) => format!("Tag name (on {})", &h[..h.len().min(9)]),
            None => "Tag name (on HEAD)".to_string(),
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GitTag,
            title,
        ));
    }

    /// `git.stash_list` — fuzzy picker over `git stash list`. Accept ⇒
    /// `git stash apply <ref>` (keeps the stash; sibling `git.stash_drop`
    /// drops without applying).
    pub fn open_git_stash_list(&mut self) {
        let stashes = crate::git::stash::list(self.active_repo_path());
        if stashes.is_empty() {
            self.toast("git stash: empty");
            return;
        }
        let items: Vec<crate::picker::PickerItem> = stashes
            .iter()
            .map(|s| {
                let label = format!("{}  {}", s.stash_ref, s.subject);
                let detail = if s.branch.is_empty() {
                    "apply".to_string()
                } else {
                    format!("on {}", s.branch)
                };
                crate::picker::PickerItem::new(&s.stash_ref, label, detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::StashesApply,
            format!("Apply stash ({})", stashes.len()),
            items,
        ));
    }

    /// `git.stash_drop` — picker over stashes, accept = drop. Sibling of
    /// `git.stash_list`. No "are you sure" prompt — stashes are listed
    /// before drop, so the user can re-create one by hand if they hit
    /// the wrong row (git records `git stash drop` in the reflog).
    pub fn open_git_stash_drop(&mut self) {
        let stashes = crate::git::stash::list(self.active_repo_path());
        if stashes.is_empty() {
            self.toast("git stash: empty");
            return;
        }
        let items: Vec<crate::picker::PickerItem> = stashes
            .iter()
            .map(|s| {
                let label = format!("{}  {}", s.stash_ref, s.subject);
                let detail = if s.branch.is_empty() {
                    "drop".to_string()
                } else {
                    format!("drop · {}", s.branch)
                };
                crate::picker::PickerItem::new(&s.stash_ref, label, detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::StashesDrop,
            format!("Drop stash ({})", stashes.len()),
            items,
        ));
    }

    /// `git.reflog` — fuzzy picker over recent reflog entries. Accept ⇒
    /// open that entry's commit as a diff pane. The selector
    /// (`HEAD@{N}`) is shown as the dim detail so the user can copy it
    /// for a manual `git reset --hard HEAD@{N}` from a pty.
    pub fn open_git_reflog(&mut self) {
        let entries = crate::git::reflog::list(self.active_repo_path(), 200);
        if entries.is_empty() {
            self.toast("git reflog: empty");
            return;
        }
        let items: Vec<crate::picker::PickerItem> = entries
            .iter()
            .map(|e| {
                let label = format!(
                    "{}  {}: {}",
                    e.short_hash,
                    e.op,
                    if e.subject.is_empty() {
                        "(no subject)"
                    } else {
                        &e.subject
                    }
                );
                let detail = format!("{} · {}", e.selector, e.relative_time);
                crate::picker::PickerItem::new(&e.full_hash, label, detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Reflog,
            format!("Reflog ({} entries)", entries.len()),
            items,
        ));
    }

    /// Open the commit-message prompt. Commits whatever is staged when accepted;
    /// if nothing's staged, `git commit` says so.
    pub fn open_commit_prompt(&mut self) {
        let staged = self.git.snapshot().staged;
        let title = if staged > 0 {
            format!("Commit message ({staged} staged)")
        } else {
            "Commit message (nothing staged — stage hunks first)".to_string()
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GitCommit,
            title,
        ));
    }

    /// vim `[c` / `]c` — jump cursor to the previous / next changed line
    /// in the active buffer (per the cached `git diff` line-signs). Wraps
    /// around. No-op when no change marks are recorded.
    pub fn git_jump_to_change(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("no path");
            return;
        };
        let Some(changes) = self.git.snapshot().line_changes.get(&path) else {
            self.toast("no change marks");
            return;
        };
        if changes.is_empty() {
            self.toast("no change marks");
            return;
        }
        let cur_row = b.editor.row_col().0;
        // Group consecutive change lines into "hunks" — pick the start of
        // the next/prev one.
        let mut hunks: Vec<usize> = Vec::new();
        let mut prev_line: Option<usize> = None;
        for (line, _) in changes.iter() {
            if prev_line.is_none_or(|p| *line > p + 1) {
                hunks.push(*line);
            }
            prev_line = Some(*line);
        }
        let target = if forward {
            hunks
                .iter()
                .copied()
                .find(|&l| l > cur_row)
                .or_else(|| hunks.first().copied())
        } else {
            hunks
                .iter()
                .copied()
                .rev()
                .find(|&l| l < cur_row)
                .or_else(|| hunks.last().copied())
        };
        let Some(row) = target else { return };
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(row, 0);
            self.toast(format!(
                "{} hunk → line {}",
                if forward { "next" } else { "prev" },
                row + 1
            ));
        }
    }

    /// Open the commit-DAG browser, taking over the full editor area
    /// (the file-tree rail stays). Replaces the active tab's layout
    /// with a single `Layout::Leaf` pointing at the graph pane —
    /// other open panes survive as background buffers in the
    /// bufferline. If a graph pane is already open in this tab, just
    /// focus it instead of opening a duplicate.
    pub fn open_git_graph(&mut self) {
        if let Some(id) = (0..self.panes.len()).find(|&i| {
            matches!(self.panes.get(i), Some(Pane::GitGraph(_))) && self.layout().contains(i)
        }) {
            self.reveal_pane(id);
            // Reveal can leave the leaf as a split member — force a
            // single-leaf layout so the graph fills the editor area.
            *self.layout_mut() = Layout::Leaf(id);
            self.active = Some(id);
            self.focus = Focus::Pane;
            return;
        }
        let pane = Pane::GitGraph(crate::git::graph::GitGraphPane::open(
            self.active_repo_path(),
        ));
        self.panes.push(pane);
        let id = self.panes.len() - 1;
        *self.layout_mut() = Layout::Leaf(id);
        self.active = Some(id);
        self.focus = Focus::Pane;
    }

    /// Re-run `git log` for the active git-graph pane (after a commit / fetch).
    pub fn refresh_active_git_graph(&mut self) {
        if let Some(Pane::GitGraph(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.refresh();
        }
    }

    pub(super) fn refresh_git_graph_panes(&mut self) {
        for pane in &mut self.panes {
            if let Pane::GitGraph(g) = pane {
                g.refresh();
            }
        }
    }

    /// Open the selected commit's diff (`git show <hash>`) as a `Pane::Diff` in a
    /// split to the right of the graph pane.
    pub fn open_selected_commit_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let hash = match self.panes.get(cur) {
            Some(Pane::GitGraph(g)) => g.selected_commit().map(|c| c.hash.clone()),
            _ => None,
        };
        let Some(hash) = hash else { return };
        let scope = crate::pane::DiffScope::Commit(hash.clone());
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast(format!(
                "commit {} has no file changes (merge?)",
                hash.chars().take(9).collect::<String>()
            ));
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(self.make_diff_view(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Copy the selected commit's full hash to the clipboard.
    pub fn copy_selected_commit_hash(&mut self) {
        let Some(cur) = self.active else { return };
        let hash = match self.panes.get(cur) {
            Some(Pane::GitGraph(g)) => g.selected_commit().map(|c| c.hash.clone()),
            _ => None,
        };
        let Some(hash) = hash else { return };
        self.clipboard.set(hash.clone(), false);
        self.toast(format!(
            "copied {}",
            hash.chars().take(12).collect::<String>()
        ));
    }

    /// Open the staging view as a split to the right of the focused leaf.
    pub fn open_git_status(&mut self) {
        let pane = Pane::GitStatus(crate::git::stage::GitStatusPane::open(
            self.active_repo_path(),
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    fn refresh_git_status_panes(&mut self) {
        for pane in &mut self.panes {
            if let Pane::GitStatus(g) = pane {
                g.refresh();
            }
        }
    }

    /// After any staging/commit change: refresh the cached status + all git
    /// panes + the rail's `GIT` section (the current branch may have moved /
    /// a branch may have been created).
    pub(super) fn after_git_change(&mut self) {
        self.git.refresh();
        let root = self.active_repo_path().to_path_buf();
        self.git_rail.refresh(&root);
        self.refresh_rail_pulls();
        self.refresh_git_status_panes();
        self.refresh_git_graph_panes();
    }

    /// Project the cross-host PR cache into `git_rail.pulls` —
    /// matches each cached PR's `remote_url_https` / `remote_url_ssh`
    /// against the active repo's `remote.origin.url`. Empty when no
    /// remote, no cache, or no matching PRs.
    ///
    /// Cache is populated by `pr.picker` / `pr.refresh` — see
    /// [`App::open_pr_picker`]. This method is a pure projection: it
    /// never spawns a sibling itself. To get fresh data, the user
    /// runs `pr.picker` or `pr.refresh`.
    pub fn refresh_rail_pulls(&mut self) {
        use crate::git::rail::PullRow;
        let mut out: Vec<PullRow> = Vec::new();
        let repo_path = self.active_repo_path().to_path_buf();
        let remote = crate::git::browse::git_config(&repo_path, "remote.origin.url");
        let current_branch = self.git_rail.current_branch.clone();
        if let Some(cache) = self.scm_pr_cache.as_ref()
            && let Some(remote) = remote.as_deref()
        {
            for pr in cache.prs.iter() {
                if !crate::scm::pr_matches_remote(pr, remote) {
                    continue;
                }
                let is_current_branch =
                    match (pr.source_branch.as_deref(), current_branch.as_deref()) {
                        (Some(src), Some(cur)) => !src.is_empty() && src == cur,
                        _ => false,
                    };
                let host_tag = match pr.host.as_str() {
                    "bitbucket" => "BB",
                    "github" => "GH",
                    "gitlab" => "GL",
                    "azdevops" => "AZ",
                    _ => "??",
                };
                let number_prefix = match pr.host.as_str() {
                    "gitlab" => "!",
                    _ => "#",
                };
                out.push(PullRow {
                    host_tag,
                    number_label: format!("{number_prefix}{}", pr.id),
                    title: pr.title.clone(),
                    source_branch: pr.source_branch.clone(),
                    is_current_branch,
                    web_url: pr.url.clone(),
                });
            }
        }
        // Sort: current-branch PR(s) first, then everything else in
        // insertion order (which is recency-from-aggregate_all).
        out.sort_by_key(|p| !p.is_current_branch);
        self.git_rail.pulls = out;
        // Clamp cursor in case the row count shrank.
        let max = self.git_rail.row_count().saturating_sub(1);
        if self.git_rail.cursor > max {
            self.git_rail.cursor = max;
        }
    }

    /// `(rel, is_staged)` for the highlighted file in the active git-status pane.
    fn git_status_selection(&self) -> Option<(String, bool)> {
        match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::GitStatus(g)) => g.selected_entry().map(|(e, st)| (e.rel.clone(), st)),
            _ => None,
        }
    }

    pub fn git_stage_selected(&mut self) {
        let Some((rel, staged)) = self.git_status_selection() else {
            return;
        };
        if staged {
            self.toast("already staged — `u` to unstage");
            return;
        }
        match crate::git::stage::stage(self.active_repo_path(), &rel) {
            Ok(()) => {
                self.toast(format!("staged {rel}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add: {e}")),
        }
    }

    pub fn git_unstage_selected(&mut self) {
        let Some((rel, staged)) = self.git_status_selection() else {
            return;
        };
        if !staged {
            self.toast("not staged — `s` to stage");
            return;
        }
        match crate::git::stage::unstage(self.active_repo_path(), &rel) {
            Ok(()) => {
                self.toast(format!("unstaged {rel}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore --staged: {e}")),
        }
    }

    /// Space in the status pane — stage if unstaged, unstage if staged.
    pub fn git_toggle_selected(&mut self) {
        match self.git_status_selection() {
            Some((_, false)) => self.git_stage_selected(),
            Some((_, true)) => self.git_unstage_selected(),
            None => {}
        }
    }

    pub fn git_stage_all_active(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitStatus(_))) {
            return;
        }
        match crate::git::stage::stage_all(self.active_repo_path()) {
            Ok(()) => {
                self.toast("staged all changes");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add -A: {e}")),
        }
    }

    pub fn git_unstage_all_active(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitStatus(_))) {
            return;
        }
        match crate::git::stage::unstage_all(self.active_repo_path()) {
            Ok(()) => {
                self.toast("unstaged everything");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore --staged: {e}")),
        }
    }

    /// Enter in the status pane — open the highlighted file's diff in a split.
    pub fn git_status_open_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let sel = match self.panes.get(cur) {
            Some(Pane::GitStatus(g)) => g.selected_entry().map(|(e, st)| (e.abs.clone(), st)),
            _ => None,
        };
        let Some((abs, staged)) = sel else { return };
        let scope = if staged {
            crate::pane::DiffScope::Staged
        } else {
            crate::pane::DiffScope::Unstaged(Some(abs))
        };
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no diff for that file (untracked? — stage it to see it)");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(self.make_diff_view(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Click on the WIP detail's `Commit` button — commit using the
    /// Git activity-bar section: focus the inline commit textarea so
    /// the next keystrokes append to the buffer. Also switches the
    /// active section to Git + makes the rail visible.
    pub fn git_section_commit_focus(&mut self) {
        if !self.tree_visible {
            self.tree_visible = true;
        }
        self.active_section = crate::app::ActivitySection::Git;
        self.git_section_commit_focused = true;
    }

    pub fn git_section_commit_blur(&mut self) {
        self.git_section_commit_focused = false;
    }

    pub fn git_section_commit_insert_char(&mut self, c: char) {
        self.git_section_commit_buffer.push(c);
    }

    pub fn git_section_commit_backspace(&mut self) {
        self.git_section_commit_buffer.pop();
    }

    /// Submit the inline commit buffer via `git commit -m`. Refuses
    /// when the buffer is empty (toasts an explanation); clears the
    /// buffer + blurs on success.
    pub fn git_section_commit_submit(&mut self) {
        let msg = self.git_section_commit_buffer.trim().to_string();
        if msg.is_empty() {
            self.toast("commit: message is empty");
            return;
        }
        let repo = self.active_repo_path().to_path_buf();
        match crate::git::commit::commit(&repo, &msg) {
            Ok(summary) => {
                self.git_section_commit_buffer.clear();
                self.git_section_commit_focused = false;
                self.toast(summary);
                self.note_commit_for_undo();
                self.after_git_change();
                self.refresh_active_git_graph();
                self.refresh_active_diff();
            }
            Err(e) => self.toast(format!("git commit: {e}")),
        }
    }

    /// inline textarea's content. When the active pane isn't a
    /// GitGraph with a populated textarea, falls through to opening
    /// the modal commit prompt (the legacy flow).
    pub fn commit_from_active_wip_textarea_or_prompt(&mut self) {
        let active_id = self.active;
        if let Some(id) = active_id
            && let Some(Pane::GitGraph(g)) = self.panes.get_mut(id)
            && g.is_wip_selected()
        {
            if g.wip_commit.ai_streaming {
                self.toast("AI message still streaming — wait for it to finish");
                return;
            }
            let msg = g.wip_commit.text.trim().to_string();
            if msg.is_empty() {
                // Nothing typed — fall back to modal prompt for
                // muscle-memory users who expect `c` to open one.
                self.open_commit_prompt();
                return;
            }
            let repo = self.active_repo_path().to_path_buf();
            match crate::git::commit::commit(&repo, &msg) {
                Ok(summary) => {
                    if let Some(Pane::GitGraph(g)) = self.panes.get_mut(id) {
                        g.wip_commit.clear();
                    }
                    self.toast(summary);
                    self.note_commit_for_undo();
                    self.after_git_change();
                    self.refresh_active_git_graph();
                    self.refresh_active_diff();
                }
                Err(e) => self.toast(format!("git commit: {e}")),
            }
            return;
        }
        self.open_commit_prompt();
    }

    /// Focus the WIP commit textarea on the given GitGraph pane.
    /// Called when the user clicks inside the textarea rect.
    pub fn focus_wip_commit_textarea(&mut self, pane_id: crate::layout::PaneId) {
        if let Some(Pane::GitGraph(g)) = self.panes.get_mut(pane_id) {
            g.wip_commit.focused = true;
        }
    }

    /// Blur the WIP commit textarea on the active GitGraph pane (if
    /// any). Used by Esc + click-elsewhere paths.
    pub fn blur_active_wip_commit_textarea(&mut self) {
        if let Some(id) = self.active
            && let Some(Pane::GitGraph(g)) = self.panes.get_mut(id)
        {
            g.wip_commit.focused = false;
        }
    }

    /// Returns true when the active pane is a GitGraph whose WIP
    /// commit textarea is focused. Lets `tui::dispatch_key` route
    /// printable / Backspace / arrow / Enter keys to the textarea
    /// before the GitGraph chord table sees them.
    pub fn active_wip_commit_textarea_focused(&self) -> bool {
        self.active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| {
                if let Pane::GitGraph(g) = p {
                    Some(g)
                } else {
                    None
                }
            })
            .map(|g| g.wip_commit.focused)
            .unwrap_or(false)
    }

    /// Mutable handle to the active GitGraph pane's commit textarea
    /// state. `None` when the active pane isn't a GitGraph.
    pub fn active_wip_commit_textarea_mut(
        &mut self,
    ) -> Option<&mut crate::git::graph::WipCommitInput> {
        self.active.and_then(move |i| {
            self.panes.get_mut(i).and_then(|p| {
                if let Pane::GitGraph(g) = p {
                    Some(&mut g.wip_commit)
                } else {
                    None
                }
            })
        })
    }

    /// Open a fuzzy picker over local + remote branches; accept ⇒ checkout.
    pub fn open_branch_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::git::branch::current(self.active_repo_path());
        let mut items: Vec<PickerItem> = Vec::new();
        // Surface the current branch first + marked with a `●` glyph; rest in
        // for-each-ref order. The picker's fuzzy match still narrows from any
        // position, so the ordering is just a visual default.
        let locals = crate::git::branch::local_branches(self.active_repo_path());
        if let Some(c) = cur.as_ref()
            && locals.iter().any(|b| b == c)
        {
            items.push(PickerItem::new(
                format!("local:{c}"),
                format!("● {c}"),
                "current",
            ));
        }
        for b in locals {
            if Some(&b) == cur.as_ref() {
                continue;
            }
            items.push(PickerItem::new(
                format!("local:{b}"),
                format!("  {b}"),
                "local",
            ));
        }
        for b in crate::git::branch::remote_branches(self.active_repo_path()) {
            items.push(PickerItem::new(
                format!("remote:{b}"),
                format!("  {b}"),
                "remote",
            ));
        }
        if items.is_empty() {
            self.toast("no branches (not a git repo?)");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Branches, "Checkout branch", items));
    }

    /// Checkout the branch a `PickerKind::Branches` item id encodes.
    pub fn checkout_branch(&mut self, id: &str) {
        let repo = self.active_repo_path().to_path_buf();
        let from_branch = crate::git::branch::current(&repo);
        // Resolve the prefix to a CheckoutKind on the main thread —
        // the loader doesn't need to know about the `local:` /
        // `remote:` wire format. untouched-surfaces-hunt-2026-06-08
        // SEV-2 #9.
        let (kind, target) = if let Some(name) = id.strip_prefix("local:") {
            (crate::app::git_async::CheckoutKind::Local, name.to_string())
        } else if let Some(remote) = id.strip_prefix("remote:") {
            (
                crate::app::git_async::CheckoutKind::RemoteTrack,
                remote.to_string(),
            )
        } else {
            (crate::app::git_async::CheckoutKind::Local, id.to_string())
        };
        let _ = self
            .git_loader_tx
            .send(crate::app::git_async::GitJob::Checkout {
                repo,
                kind,
                target: target.clone(),
                from_branch,
            });
        self.toast(format!("checking out {target}…"));
    }

    /// Apply a `GitResult::CheckedOut` — register the undo (local
    /// checkouts only) + run the standard after-checkout side
    /// effects. RemoteTrack creates a new local branch as a side
    /// effect; redo semantics get fuzzy, so it skips the undo step.
    pub(super) fn apply_checkout_result(
        &mut self,
        kind: crate::app::git_async::CheckoutKind,
        from_branch: Option<String>,
        result: Result<String, String>,
    ) {
        match result {
            Ok(name) => {
                if matches!(kind, crate::app::git_async::CheckoutKind::Local)
                    && let Some(from) = &from_branch
                {
                    self.note_checkout_for_undo(from, &name);
                }
                self.after_checkout(&name);
            }
            Err(e) => self.toast(format!("git checkout: {e}")),
        }
    }

    /// Open the "new branch name" prompt; accept ⇒ `git checkout -b <name>`.
    pub fn open_new_branch_prompt(&mut self) {
        // Bare `git.new_branch` — no source, off HEAD.
        self.pending_branch_source = None;
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewBranch,
            "New branch name (off current HEAD)",
        ));
    }

    pub fn create_branch(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            self.toast("branch creation cancelled (empty name)");
            self.pending_branch_source = None;
            return;
        }
        let source = self.pending_branch_source.take();
        let result = match &source {
            Some(s) => crate::git::branch::create_from(self.active_repo_path(), name, s),
            None => crate::git::branch::create(self.active_repo_path(), name),
        };
        match result {
            Ok(()) => {
                if let Some(s) = source {
                    self.toast(format!("created {name} off {s}"));
                }
                self.after_checkout(name);
            }
            Err(e) => self.toast(format!("git checkout -b: {e}")),
        }
    }

    /// Open a picker over `git worktree list`; accept ⇒ a shell pane in that dir.
    pub fn open_worktree_picker(&mut self) {
        use crate::picker::PickerItem;
        let wts = crate::git::branch::worktrees(self.active_repo_path());
        if wts.is_empty() {
            self.toast("no worktrees (not a git repo?)");
            return;
        }
        let items: Vec<PickerItem> = wts
            .into_iter()
            .map(|w| {
                let detail = if w.is_current {
                    format!("{} · current", w.label)
                } else {
                    w.label.clone()
                };
                PickerItem::new(
                    w.path.display().to_string(),
                    w.path.display().to_string(),
                    detail,
                )
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::Worktrees,
            "Worktree → shell",
            items,
        ));
    }

    /// Open a shell pane in `path` (a worktree directory).
    pub fn open_worktree_shell(&mut self, path: &str) {
        self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(PathBuf::from(
            path,
        ))));
    }

    /// Common tail of a checkout / new-branch: refresh git + tree, warn that open
    /// editors may now be stale (their file on disk could differ).
    fn after_checkout(&mut self, label: &str) {
        self.after_git_change();
        self.tree.refresh();
        let dirty_open = self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.dirty));
        if dirty_open {
            self.toast(format!(
                "switched to {label} — heads up: you have unsaved edits open"
            ));
        } else {
            self.toast(format!(
                "switched to {label} — reopen files if their content changed"
            ));
        }
    }

    /// If `(x, y)` is on a GitGraph detail-divider rect, start a
    /// detail-width drag. Returns true if so.
    pub fn begin_git_graph_detail_drag(&mut self, x: u16, y: u16) -> bool {
        if let Some(&(r, pid)) = self
            .rects
            .git_graph_detail_dividers
            .iter()
            .find(|(r, _)| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
        {
            // Capture the pane's left + right edge so we can clamp
            // the resulting detail width across the live drag.
            let (left, right) = self
                .rects
                .editor_panes
                .iter()
                .find(|(_, id)| *id == pid)
                .map(|(rect, _)| (rect.x, rect.x + rect.width))
                .unwrap_or((r.x.saturating_sub(20), r.x + 20));
            self.dragging_git_graph_detail = Some((pid, left, right));
            let _ = r; // suppress unused-binding if optimised away
            return true;
        }
        false
    }

    /// Continue a GitGraph detail-divider drag: set the detail-width
    /// to (pane_right - x), clamped to a usable range.
    pub fn drag_git_graph_detail_to(&mut self, x: u16) {
        let Some((_, left, right)) = self.dragging_git_graph_detail else {
            return;
        };
        // Compute new detail width in cells. The divider sits at
        // `pane_right - detail_w - 1`; solve for detail_w.
        let x = x.clamp(left + 20, right.saturating_sub(2));
        let new_detail_w = right.saturating_sub(x).saturating_sub(1).max(20);
        // Clamp to a workable range — minimum 20, maximum is the
        // pane width minus 40 (so the list always stays usable).
        let max = (right - left).saturating_sub(40).max(20);
        let clamped = new_detail_w.min(max);
        self.git_graph_detail_col_override = Some(clamped);
    }

    pub fn end_git_graph_detail_drag(&mut self) {
        self.dragging_git_graph_detail = None;
    }

    /// Toggle the `> GIT` section in the rail (sibling of the workspace
    /// section). Clicking the header expands/collapses it and parks the rail
    /// keyboard on the git section.
    pub fn toggle_git_section_expanded(&mut self) {
        self.git_section_expanded = !self.git_section_expanded;
        if self.git_section_expanded {
            self.focus = Focus::Tree;
            self.rail_section = RailSection::Git;
        }
    }

    /// Move the git rail's cursor. Crosses back into the workspace section
    /// when the user goes up off the top of the git list.
    pub fn git_rail_move_up(&mut self) {
        if self.git_rail.cursor == 0 {
            // At top of the git section already → flip back to workspace.
            self.rail_section = RailSection::Workspace;
        } else {
            self.git_rail.move_up();
        }
    }

    pub fn git_rail_move_down(&mut self) {
        self.git_rail.move_down();
    }

    /// Enter on the cursor row: checkout the branch, or open a shell in the
    /// worktree. (Both are also reachable via right-click context menu.)
    pub fn git_rail_activate(&mut self) {
        let Some(hit) = self.git_rail.selected() else {
            return;
        };
        self.run_git_rail_hit(hit);
    }

    /// Click handler — focus the git section, set the cursor, run the row's
    /// default action.
    pub fn click_git_rail(&mut self, hit: crate::git::rail::GitRailHit) {
        // The `+ N more` / `show less` toggle row doesn't focus a
        // selectable entry — it flips a render flag. Handle it before
        // the normal focus + hit flow.
        if matches!(hit, crate::git::rail::GitRailHit::ToggleBranches) {
            self.git_branches_expanded = !self.git_branches_expanded;
            return;
        }
        self.focus_tree();
        self.rail_section = RailSection::Git;
        self.git_rail.focus(hit);
        self.run_git_rail_hit(hit);
    }

    /// Right-click on a git-rail row: open the appropriate context menu.
    pub fn open_git_rail_context_menu(
        &mut self,
        hit: crate::git::rail::GitRailHit,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        self.focus_tree();
        self.rail_section = RailSection::Git;
        self.git_rail.focus(hit);
        let menu = match hit {
            crate::git::rail::GitRailHit::Branch(i) => {
                let Some(b) = self.git_rail.branches.get(i) else {
                    return;
                };
                let name = b.name.clone();
                let title = if b.is_current {
                    Some(format!("● {name}"))
                } else {
                    Some(name.clone())
                };
                let items = if b.is_current {
                    vec![MenuItem::new(
                        "New branch from here…",
                        MenuAction::GitNewBranchFrom(name),
                    )]
                } else {
                    vec![
                        MenuItem::new(
                            format!("Checkout {name}"),
                            MenuAction::GitCheckoutBranch(name.clone()),
                        ),
                        MenuItem::new(
                            "New branch from here…",
                            MenuAction::GitNewBranchFrom(name.clone()),
                        ),
                        MenuItem::new(format!("Delete {name}…"), MenuAction::GitDeleteBranch(name)),
                    ]
                };
                ContextMenu::new(title, anchor, items)
            }
            crate::git::rail::GitRailHit::Worktree(i) => {
                let Some(w) = self.git_rail.worktrees.get(i) else {
                    return;
                };
                let path = w.path.clone();
                let label = w.label.clone();
                let is_cur = w.is_current;
                let title = Some(format!("{label}  {}", path.display()));
                let mut items = vec![
                    MenuItem::new(
                        "Open shell here",
                        MenuAction::GitWorktreeShell(path.clone()),
                    ),
                    MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                    MenuItem::new(
                        "Copy path",
                        MenuAction::CopyPath(path.to_string_lossy().into_owned()),
                    ),
                ];
                if !is_cur {
                    items.push(MenuItem::new(
                        "Remove worktree…",
                        MenuAction::GitWorktreeRemove(path),
                    ));
                }
                ContextMenu::new(title, anchor, items)
            }
            crate::git::rail::GitRailHit::Pull(i) => {
                let Some(p) = self.git_rail.pulls.get(i) else {
                    return;
                };
                let url = p.web_url.clone();
                let title = Some(format!("{} {} — {}", p.host_tag, p.number_label, p.title));
                let items = vec![
                    MenuItem::new("Open in browser", MenuAction::OpenUrl(url.clone())),
                    MenuItem::new("Copy URL", MenuAction::CopyText(url)),
                ];
                ContextMenu::new(title, anchor, items)
            }
            // Right-clicking the `+ N more` toggle has no useful menu —
            // bail.
            crate::git::rail::GitRailHit::ToggleBranches => return,
        };
        self.context_menu = Some(menu);
    }

    /// Common tail of click + Enter — run the action attached to `hit`.
    fn run_git_rail_hit(&mut self, hit: crate::git::rail::GitRailHit) {
        match hit {
            crate::git::rail::GitRailHit::Branch(i) => {
                let Some(b) = self.git_rail.branches.get(i) else {
                    return;
                };
                if b.is_current {
                    self.toast(format!("● {} (already checked out)", b.name));
                } else {
                    let name = b.name.clone();
                    self.git_checkout_named(&name);
                }
            }
            crate::git::rail::GitRailHit::Worktree(i) => {
                let Some(w) = self.git_rail.worktrees.get(i) else {
                    return;
                };
                let path = w.path.clone();
                self.open_worktree_shell(&path.to_string_lossy());
            }
            crate::git::rail::GitRailHit::Pull(i) => {
                let Some(p) = self.git_rail.pulls.get(i) else {
                    return;
                };
                let url = p.web_url.clone();
                open_url_external(&url);
                self.toast(format!("opened {} in browser", p.number_label));
            }
            crate::git::rail::GitRailHit::ToggleBranches => {
                // Keyboard Enter on the toggle row — same behavior as
                // mouse click; `click_git_rail` intercepts mouse hits
                // before reaching here, so this branch fires only for
                // keyboard activation.
                self.git_branches_expanded = !self.git_branches_expanded;
            }
        }
    }

    /// Right-click context-menu action: checkout an existing local branch.
    pub fn git_checkout_named(&mut self, name: &str) {
        let from = crate::git::branch::current(self.active_repo_path());
        match crate::git::branch::checkout(self.active_repo_path(), name) {
            Ok(()) => {
                if let Some(from) = from {
                    self.note_checkout_for_undo(&from, name);
                }
                self.after_checkout(name);
            }
            Err(e) => self.toast(format!("checkout: {e}")),
        }
    }

    /// Right-click context-menu action: prompt for a new branch name (off the
    /// named branch's tip) and create+checkout. The existing
    /// [`Self::open_new_branch_prompt`] already does this off `HEAD`; here we
    /// just stash the source branch and reuse that prompt — the user can
    /// switch first if they want a different base.
    pub fn git_new_branch_from(&mut self, source: String) {
        self.pending_branch_source = Some(source.clone());
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewBranch,
            format!("New branch name (off {source})"),
        ));
    }

    /// Right-click context-menu action: prompt to confirm, then `git branch -D`.
    pub fn git_delete_branch_prompt(&mut self, name: String) {
        use crate::prompt::{Prompt, PromptKind};
        self.prompt = Some(Prompt::seeded(
            PromptKind::GitDeleteBranch,
            format!("Type {name:?} to delete this branch"),
            "",
        ));
        self.pending_delete_branch = Some(name);
    }

    /// Accept handler for the `PromptKind::GitDeleteBranch` confirm prompt.
    pub fn confirm_delete_branch(&mut self, typed: String) {
        let Some(name) = self.pending_delete_branch.take() else {
            return;
        };
        if typed.trim() != name {
            self.toast("branch delete cancelled (name didn't match)");
            return;
        }
        match crate::git::branch::delete_branch(self.active_repo_path(), &name) {
            Ok(()) => {
                self.toast(format!("deleted branch {name}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("branch delete: {e}")),
        }
    }

    /// Accept handler for `PromptKind::GitStashDrop` — require the
    /// literal word "drop" to commit a `git stash drop <ref>`.
    /// untouched-surfaces-hunt-2026-06-08 SEV-2 #8.
    pub fn confirm_stash_drop(&mut self, typed: String) {
        let Some((stash_ref, label)) = self.pending_stash_drop.take() else {
            return;
        };
        if typed.trim() != "drop" {
            self.toast("stash drop cancelled (type 'drop' to confirm)");
            return;
        }
        match crate::git::stash::drop_stash(self.active_repo_path(), &stash_ref) {
            Ok(summary) => self.toast(format!("dropped {label}: {summary}")),
            Err(e) => self.toast(format!("git stash drop: {e}")),
        }
    }

    /// Right-click context-menu action: confirm + `git worktree remove`.
    pub fn git_worktree_remove_prompt(&mut self, path: PathBuf) {
        use crate::prompt::{Prompt, PromptKind};
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();
        self.prompt = Some(Prompt::seeded(
            PromptKind::GitWorktreeRemove,
            format!("Type {name:?} to remove this worktree"),
            "",
        ));
        self.pending_worktree_remove = Some((path, name));
    }

    /// Accept handler for `PromptKind::GitWorktreeRemove`.
    pub fn confirm_worktree_remove(&mut self, typed: String) {
        let Some((path, name)) = self.pending_worktree_remove.take() else {
            return;
        };
        if typed.trim() != name {
            self.toast("worktree remove cancelled (name didn't match)");
            return;
        }
        match crate::git::branch::worktree_remove(self.active_repo_path(), &path) {
            Ok(()) => {
                self.toast(format!("removed worktree {name}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("worktree remove: {e}")),
        }
    }
}

#[cfg(test)]
mod git_tests {
    use super::*;
    use std::fs;

    fn app_with_files() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        fs::write(d.path().join("b.txt"), "beta").unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    #[test]
    fn git_rail_section_toggles_focus_rail() {
        let (_d, mut app) = app_with_files();
        // Both sections start expanded; collapse + re-expand each and
        // verify the rail keyboard parks on the section just expanded.
        assert!(app.tree_root_expanded);
        assert!(app.git_section_expanded);
        app.toggle_tree_root_expanded(); // collapse
        assert!(!app.tree_root_expanded);
        app.toggle_git_section_expanded(); // collapse
        assert!(!app.git_section_expanded);
        app.toggle_git_section_expanded(); // expand
        assert!(app.git_section_expanded);
        assert_eq!(app.rail_section, RailSection::Git);
        assert_eq!(app.focus, Focus::Tree);
        app.toggle_tree_root_expanded(); // expand
        assert_eq!(app.rail_section, RailSection::Workspace);
    }

    #[test]
    fn click_git_rail_branch_routes_to_checkout() {
        // No `git` available in the sandbox is fine — we just seed the rail
        // directly + verify the click handler routes to the checkout call.
        let (_d, mut app) = app_with_files();
        app.git_rail.branches = vec![
            crate::git::rail::BranchRow {
                name: "main".into(),
                is_current: true,
            },
            crate::git::rail::BranchRow {
                name: "feature/x".into(),
                is_current: false,
            },
        ];
        app.git_rail.current_branch = Some("main".into());

        // Click the current branch → toasts "already checked out", no crash.
        app.click_git_rail(crate::git::rail::GitRailHit::Branch(0));
        assert_eq!(app.rail_section, RailSection::Git);
        assert!(app.git_rail.selected() == Some(crate::git::rail::GitRailHit::Branch(0)));

        // Click the other branch → would shell out to `git checkout`; the
        // workspace isn't a repo so we just verify the cursor moved.
        app.click_git_rail(crate::git::rail::GitRailHit::Branch(1));
        assert_eq!(
            app.git_rail.selected(),
            Some(crate::git::rail::GitRailHit::Branch(1))
        );
    }

    #[test]
    fn right_click_git_rail_branch_opens_menu_with_actions() {
        use crate::context_menu::MenuAction;
        let (_d, mut app) = app_with_files();
        app.git_rail.branches = vec![
            crate::git::rail::BranchRow {
                name: "main".into(),
                is_current: true,
            },
            crate::git::rail::BranchRow {
                name: "topic".into(),
                is_current: false,
            },
        ];
        app.git_rail.current_branch = Some("main".into());

        // Right-click the *current* branch ⇒ only "New branch from here…".
        app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Branch(0), (0, 0));
        let m = app.context_menu.as_ref().unwrap();
        assert_eq!(m.items.len(), 1);
        assert!(matches!(m.items[0].action, MenuAction::GitNewBranchFrom(_)));

        // Right-click a non-current branch ⇒ Checkout / New / Delete.
        app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Branch(1), (0, 0));
        let m = app.context_menu.as_ref().unwrap();
        assert_eq!(m.items.len(), 3);
        assert!(matches!(
            m.items[0].action,
            MenuAction::GitCheckoutBranch(ref n) if n == "topic"
        ));
        assert!(matches!(m.items[2].action, MenuAction::GitDeleteBranch(_)));
    }

    #[test]
    fn session_round_trips_git_section_expanded() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app.git_section_expanded);
        app.git_section_expanded = false;
        app.save_session_on_quit();
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Pre-restore: runtime default is true.
        assert!(app2.git_section_expanded);
        app2.try_restore_session();
        assert!(!app2.git_section_expanded);
    }

    #[test]
    fn switching_active_repo_retargets_open_git_panes() {
        // Two sibling sub-repos; open both a GitStatus and a GitGraph pane
        // while on proj-a, then switch to proj-b. Each pane should follow
        // the switch (verified via the pane's `workspace` field).
        let d = tempfile::tempdir().unwrap();
        for name in ["proj-a", "proj-b"] {
            let p = d.path().join(name);
            std::fs::create_dir(&p).unwrap();
            std::fs::create_dir(p.join(".git")).unwrap();
        }
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let proj_a = app.repos[0].path.clone();
        let proj_b = app.repos[1].path.clone();

        // Open status + graph panes while proj-a is active.
        let status = Pane::GitStatus(crate::git::stage::GitStatusPane::open(&proj_a));
        let graph = Pane::GitGraph(crate::git::graph::GitGraphPane::open(&proj_a));
        app.panes.push(status);
        app.panes.push(graph);

        // Sanity: both currently point at proj-a.
        for pane in &app.panes {
            match pane {
                Pane::GitStatus(g) => assert_eq!(g.workspace, proj_a),
                Pane::GitGraph(g) => assert_eq!(g.workspace, proj_a),
                _ => {}
            }
        }

        app.switch_active_repo(1);
        // Both panes should now point at proj-b.
        for pane in &app.panes {
            match pane {
                Pane::GitStatus(g) => assert_eq!(g.workspace, proj_b),
                Pane::GitGraph(g) => assert_eq!(g.workspace, proj_b),
                _ => {}
            }
        }
    }

    #[test]
    fn diff_jump_file_walks_files() {
        use crate::git::diff::{Hunk, HunkLine};
        use crate::pane::{DiffScope, DiffView};
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Synthetic 4-hunk diff spanning 3 files (A, B, B, C).
        let mk = |file: &str| Hunk {
            file: PathBuf::from(file),
            file_rel: file.to_string(),
            header: "@@ -1 +1 @@".into(),
            new_start: 1,
            lines: vec![HunkLine::Context("x".into())],
            body: "@@ -1 +1 @@\n x\n".into(),
        };
        let hunks = vec![mk("a.txt"), mk("b.txt"), mk("b.txt"), mk("c.txt")];
        app.panes
            .push(Pane::Diff(DiffView::new(DiffScope::AllVsHead, hunks)));
        let id = app.panes.len() - 1;
        app.active = Some(id);
        if let Some(Pane::Diff(d)) = app.panes.get_mut(id) {
            d.cursor = 0;
        }
        // ]f from a.txt → b.txt (index 1).
        app.diff_jump_file(true);
        let cur = match app.panes.get(id) {
            Some(Pane::Diff(d)) => d.cursor,
            _ => unreachable!(),
        };
        assert_eq!(cur, 1);
        // ]f from b.txt's first hunk → c.txt (index 3).
        app.diff_jump_file(true);
        let cur = match app.panes.get(id) {
            Some(Pane::Diff(d)) => d.cursor,
            _ => unreachable!(),
        };
        assert_eq!(cur, 3);
        // ]f wraps → a.txt (index 0).
        app.diff_jump_file(true);
        let cur = match app.panes.get(id) {
            Some(Pane::Diff(d)) => d.cursor,
            _ => unreachable!(),
        };
        assert_eq!(cur, 0);
        // [f from a.txt wraps backwards to c.txt (index 3).
        app.diff_jump_file(false);
        let cur = match app.panes.get(id) {
            Some(Pane::Diff(d)) => d.cursor,
            _ => unreachable!(),
        };
        assert_eq!(cur, 3);
    }
}
