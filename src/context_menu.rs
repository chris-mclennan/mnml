//! The right-click context menu — a small floating list of actions, anchored at
//! the click. Opened from the file tree (on a file / dir) or a bufferline tab;
//! steals key + mouse input like the picker until dismissed. `App` owns an
//! `Option<ContextMenu>` and maps the chosen [`MenuAction`] to an effect.

use std::path::PathBuf;

use crate::layout::PaneId;

/// What a menu entry does when chosen.
#[derive(Debug, Clone)]
pub enum MenuAction {
    /// Open the file (in the focused leaf).
    OpenPath(PathBuf),
    /// Open the file in a new split to the right.
    OpenInSplit(PathBuf),
    /// `open -R <path>` (macOS Finder reveal); a no-op elsewhere.
    RevealInFinder(PathBuf),
    /// Hand `path` to the OS's default app — `open` / `xdg-open` / `start`.
    OpenExternally(PathBuf),
    /// Open a shell pty pane with its cwd set to `dir` (the right-clicked
    /// folder, or a right-clicked file's parent folder) — VS Code's
    /// "Open in Integrated Terminal".
    OpenTerminal(PathBuf),
    /// Copy `text` (a workspace-relative path) to the clipboard.
    CopyPath(String),
    /// Promote the right-clicked folder to the primary workspace.
    /// Replaces `App.workspace` + reloads the tree. Surfaced on the
    /// tree's directory-row context menu. User-requested 2026-06-18
    /// for "I opened at ~/Projects, drill into one of these into."
    SetAsWorkspace(PathBuf),
    /// qa-feature 2026-07-01 — recursively expand/collapse a dir + all its
    /// descendants. Surfaced from the tree dir right-click menu; equivalent
    /// to Alt+click on the dir row.
    TreeExpandRecursive(PathBuf),
    TreeCollapseRecursive(PathBuf),
    /// qa-feature 2026-07-01 — remove the currently-primary workspace
    /// (promotes the first extra in position order to primary first, then
    /// drops the demoted old primary). No-op / hidden when there are no
    /// extras, since removing would leave the app with nothing loaded.
    RemovePrimaryWorkspace,
    /// Toggle whether `App.workspace` is the persisted default
    /// (`[startup] default_workspace` in the global config).
    /// #polish 2026-07-06 — written to disk on click.
    SetDefaultWorkspace,
    /// Same as `SetDefaultWorkspace` but for an extra workspace row
    /// — carries the target path so we don't rely on `App.workspace`.
    SetDefaultWorkspaceAt(PathBuf),
    /// Open the integration-edit panel for the integration with the
    /// given id, pre-filled with that entry's glyph/color/tooltip.
    /// Surfaced by the integration-chip right-click menu so users
    /// can tweak a chip without going through the discovery overlay.
    EditIntegration(String),
    /// Drop the integration from the rail (config + persist). Same
    /// effect as clicking the chip's row in the discovery overlay
    /// when it's already InRail. Surfaced by the chip right-click
    /// menu's "Remove from rail" entry.
    RemoveIntegration(String),
    /// Run a registered command by id (e.g. `tree.refresh`).
    Command(&'static str),
    CloseTab(PaneId),
    CloseOtherTabs(PaneId),
    CloseAllTabs,
    /// Right-panel v3 tab right-click "Switch to this tab" — sets
    /// `right_panel_active_idx` directly to the given index instead
    /// of cycling via next_tab. Future-proofs the action when the
    /// 2-tab cap lifts (render-reviewer-4th W-1).
    SetRightPanelTab(usize),
    /// Right-panel v5 polish 2026-06-29: close every panel tab
    /// EXCEPT the one at this idx.
    CloseOtherRightPanelTabs(usize),
    /// Right-panel v5 polish 2026-06-29: close every panel tab.
    CloseAllRightPanelTabs,
    /// Save the specific pane (an editor) without changing focus.
    /// Surfaced from the bufferline tab right-click menu — the
    /// VS-Code-mouse hunt's SEV-2 "no Save button anywhere" finding.
    SavePane(PaneId),
    /// 2026-06-21 — VS Code-style pin / unpin for a specific editor
    /// tab. Pinned tabs sort to the front of the bufferline strip
    /// (📌 glyph) and are immune to Close all / Close others.
    PinTab(PaneId),
    /// Rename a pty session (Claude / Codex / shell) — reveals the
    /// pane, then opens the session-name prompt.
    RenameSession(PaneId),
    /// Prompt for a name and create an empty file in `parent_dir`.
    NewFile(PathBuf),
    /// Prompt for a name and create an empty directory in `parent_dir`.
    NewFolder(PathBuf),
    /// Prompt for a new name and rename `path` (kept in the same dir).
    Rename(PathBuf),
    /// Prompt for the filename as a confirmation; on exact match, delete
    /// `path` (`rm` for a file, `rm -rf` for a directory).
    Delete(PathBuf),
    /// Git rail — checkout an existing local branch.
    GitCheckoutBranch(String),
    /// #polish 2026-07-06 — merge the named branch into the
    /// current branch. Uses the existing GitJob::Merge job.
    GitMergeBranchInto(String),
    /// #polish 2026-07-06 — rebase the current branch onto the
    /// named branch. Uses the existing GitJob::Rebase job.
    GitRebaseCurrentOnto(String),
    /// Git rail — prompt for a new branch name (off the named base; first cut
    /// just branches off `HEAD`).
    GitNewBranchFrom(String),
    /// Git rail — confirm + `git branch -D <name>`.
    GitDeleteBranch(String),
    /// Git rail — open a shell pane rooted in the worktree directory.
    GitWorktreeShell(PathBuf),
    /// Git rail — confirm + `git worktree remove <path>`.
    GitWorktreeRemove(PathBuf),
    /// Git palette stash — `git stash pop <id>` (applies + drops).
    GitStashPop(String),
    /// Git palette stash — `git stash apply <id>` (applies, keeps).
    GitStashApply(String),
    /// Git palette stash — confirm + `git stash drop <id>`.
    GitStashDrop(String),
    /// Git palette tag — confirm + `git tag -d <name>`.
    GitTagDelete(String),
    /// Git palette remote-branch — `git checkout <name>` (creates a
    /// local tracking branch). Wraps `App::checkout_branch` which
    /// already handles the remote-ref form.
    GitRemoteCheckout(String),
    /// Sessions panel — open the rename prompt for the pty pane
    /// at `pane_id`. Reuses `PromptKind::PtySessionName`.
    SessionRename(usize),
    /// Sessions panel — set the per-pane accent color to a
    /// named theme color (Green / Blue / Yellow / Orange / Red /
    /// Purple / Cyan / None).
    SessionSetColor(usize, &'static str),
    /// Sessions panel — close (kill child + drop pane) the pty
    /// at `pane_id`.
    SessionClose(usize),
    /// Workspaces editor — open the rename prompt for the row.
    WorkspaceEditName(usize),
    /// Workspaces editor — open the path-edit prompt.
    WorkspaceEditPath(usize),
    /// Workspaces editor — open the group-edit prompt.
    WorkspaceEditGroup(usize),
    /// Workspaces editor — remove the workspace at this index.
    WorkspaceDelete(usize),
    /// #polish 2026-07-06 — Workspaces editor — toggle whether
    /// this row's path is the persisted `[startup] default_workspace`.
    WorkspaceSetDefault(usize),
    /// Workspaces editor — swap with the row above.
    WorkspaceMoveUp(usize),
    /// Workspaces editor — swap with the row below.
    WorkspaceMoveDown(usize),
    /// #polish 2026-07-06 — rail-level reorder for an extra
    /// workspace. Swaps its rail slot with the adjacent extra
    /// (up if the payload is Up, down if Down) and persists to
    /// `[[workspaces]]`. Accessible from the extra-workspace
    /// header right-click without opening Manage.
    ExtraWorkspaceMoveUp(usize),
    ExtraWorkspaceMoveDown(usize),
    /// Switch to the workspace at the given 1-based index — 0 is
    /// the primary; 1.. map to entries in `[[workspaces]]`. Used
    /// by the "Set as current" right-click on an extra workspace
    /// header.
    SwitchToExtraWorkspace(usize),
    /// Open a rendered-markdown preview for `path` in a split. Surfaced from
    /// the tree (right-click an `.md`/`.markdown`/`.mdx`/`.mkd` file) and
    /// from a bufferline tab right-click on the same.
    PreviewMarkdown(PathBuf),
    /// Open a URL via the OS default browser. Used by the git rail's
    /// `Pull` row context menu.
    OpenUrl(String),
    /// Copy a literal string to the clipboard. Used by the git rail's
    /// `Pull` row context menu ("Copy URL").
    CopyText(String),
    /// Split the leaf containing the tab and put the tab in the
    /// new half. Direction is the DropZone (Left/Right/Top/Bottom).
    /// Used by tab right-click "Split Right / Down / Left / Up".
    SplitTabInto(PaneId, crate::app::tab_drop::DropZone),
    /// Open the CloudAgentRun detail pane for a row at `idx` in
    /// `cloud_agents_rows`. Used by the managed-agent right-click
    /// menu's "View details" entry.
    OpenCloudAgentRunDetail(usize),
    /// `POST /v1/sessions/{id}/stop` on an Anthropic Managed Agents
    /// session — asks the worker to wind down cleanly. Used by
    /// the managed-agent right-click menu's "Stop session" entry.
    StopManagedSession(String),
    /// Toggle an integration chip's `enabled` field by `id`. Hidden
    /// chips reappear in the palette bar; visible chips hide.
    /// Persists to user config TOML.
    ToggleIntegrationEnabled(String),
    /// Move an integration chip one position earlier in the ordered
    /// list. No-op when already first. Persists via
    /// `persist_integration_icons`.
    MoveIntegrationUp(String),
    /// Move an integration chip one position later in the ordered
    /// list. No-op when already last. Persists.
    MoveIntegrationDown(String),
    /// Move an integration chip to position 0. No-op when already
    /// there. Persists.
    MoveIntegrationToTop(String),
    /// Move an integration chip to the last position. No-op when
    /// already there. Persists.
    MoveIntegrationToBottom(String),
    /// Toggle a launcher chip's `enabled` field by `id`.
    ToggleLauncherEnabled(String),
    /// Set `[ui] top_bar_cluster_mode` to one of
    /// `"auto"` / `"expanded"` / `"compact"` and persist to user config.
    SetTopBarClusterMode(&'static str),
    /// Spawn the `mnml-aws-cloudwatch-logs` sibling tool in a Pty
    /// pane, pre-filtered to the given log group + filter pattern.
    /// Used by the Cloud Agents row context menu's "Tail logs in
    /// mnml" entry — handoffs the runId as a filter so the pane
    /// shows only that run's log lines.
    OpenCloudWatchPane {
        log_group: String,
        filter: String,
        label: String,
    },
    /// Spawn the `mnml-fs-s3` sibling in a Pty pane, pre-filtered
    /// to a specific bucket + prefix. Used by the Cloud Agents
    /// row context menu's "Open S3 artifacts in mnml" entry —
    /// drops the user straight into the qwe-run's artifact tree.
    OpenS3Pane {
        bucket: String,
        prefix: String,
        label: String,
    },
    /// Diff pane / embedded diff: open `<rel_path>` at the file's
    /// pre-commit revision (`git show <hash>:<rel>`) as a scratch
    /// buffer. The user can read the file as it existed at that
    /// commit.
    DiffOpenAtRevision {
        hash: String,
        rel: PathBuf,
    },
    /// Diff pane / embedded diff: dispatch a per-hunk action against
    /// `(pane_id, hunk_index)` — same as a chip click.
    DiffHunkAction {
        pane_id: PaneId,
        hunk_index: usize,
        action: crate::DiffHunkAction,
    },
    /// `git add -- <rel>` against the active repo.
    GitStageFile(PathBuf),
    /// `git restore --staged -- <rel>` (fall back to `reset HEAD --`).
    GitUnstageFile(PathBuf),
    /// `git restore -- <rel>` *iff* the user types the filename to
    /// confirm. Destructive — discards working-tree changes back to
    /// HEAD. Captured via the prompt at `pending_discard_file`.
    GitDiscardFile(PathBuf),
    /// Append `<rel>` to `.gitignore` (creating it if missing).
    GitIgnoreFile(PathBuf),
    /// Append `*.<ext>` to `.gitignore` — ignore all files of this
    /// type. The action carries the extension *with* the leading dot
    /// stripped (e.g. `"log"`).
    GitIgnoreExtension(String),
    /// `git stash push -u -- <rel>` — stash just this file's changes.
    GitStashFile(PathBuf),
}

#[derive(Debug, Clone)]
pub struct MenuItem {
    pub label: String,
    pub action: MenuAction,
}

impl MenuItem {
    pub fn new(label: impl Into<String>, action: MenuAction) -> Self {
        MenuItem {
            label: label.into(),
            action,
        }
    }
}

pub struct ContextMenu {
    /// Optional heading shown above the items (e.g. the file name).
    pub title: Option<String>,
    pub items: Vec<MenuItem>,
    /// Where the menu's top-left should sit (the click cell) — clamped on render.
    pub anchor: (u16, u16),
    pub selected: usize,
    /// True once the user has actively moved focus (mouse hover or
    /// arrow keys). When false, the renderer paints no row highlight
    /// — matches macOS/Cursor's right-click menu, where nothing is
    /// pre-selected until you interact. Enter / click still fire the
    /// item at `selected` (0 by default), so the "no highlight"
    /// state isn't actually inert.
    pub interacted: bool,
}

impl ContextMenu {
    pub fn new(title: Option<String>, anchor: (u16, u16), items: Vec<MenuItem>) -> Self {
        ContextMenu {
            title,
            items,
            anchor,
            selected: 0,
            interacted: false,
        }
    }
    pub fn move_up(&mut self) {
        self.interacted = true;
        if self.selected == 0 {
            self.selected = self.items.len().saturating_sub(1);
        } else {
            self.selected -= 1;
        }
    }
    pub fn move_down(&mut self) {
        self.interacted = true;
        if self.items.is_empty() {
            return;
        }
        self.selected = (self.selected + 1) % self.items.len();
    }
    pub fn set_selected(&mut self, i: usize) {
        if i < self.items.len() {
            self.selected = i;
            self.interacted = true;
        }
    }
    /// Inner content width (the longest label + a little padding).
    pub fn content_width(&self) -> usize {
        let longest = self
            .items
            .iter()
            .map(|i| i.label.chars().count())
            .chain(self.title.iter().map(|t| t.chars().count()))
            .max()
            .unwrap_or(8);
        (longest + 2).max(12)
    }
}
