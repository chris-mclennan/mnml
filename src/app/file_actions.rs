//! Local filesystem actions on `App` — the New / Rename / Delete /
//! Cut / Copy / Paste / Duplicate / Move-to file operations, the
//! confirm/discard prompt handlers that gate destructive ops, and the
//! at-revision open (git blame → open the historical file). Matches
//! the Finder / VS Code file-clipboard convention (see local file
//! actions pack, 2026-07-07).
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// Open the "type the filename to confirm" prompt for the
    /// "Discard changes" menu entry. Stashes `rel` in
    /// `pending_discard_file`; the prompt accept calls
    /// `accept_discard_file`.
    pub fn open_discard_file_prompt(&mut self, rel: std::path::PathBuf) {
        let basename = rel
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| rel.to_string_lossy().into_owned());
        self.pending_discard_file = Some(rel);
        let title = format!("Discard uncommitted changes to `{basename}`?");
        let mut p = crate::prompt::Prompt::new(crate::prompt::PromptKind::GitDiscardFile, title);
        p.cursor = 1;
        self.prompt = Some(p);
    }

    /// Accept handler for [`PromptKind::GitDiscardFile`]. Requires the
    /// typed text to equal the file's basename; on match, runs
    /// `git restore -- <rel>`.
    pub fn accept_discard_file(&mut self, typed: &str) {
        let Some(rel) = self.pending_discard_file.take() else {
            return;
        };
        let basename = rel
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if typed.trim() != basename {
            self.toast("discard cancelled");
            return;
        }
        let rel_str = rel.to_string_lossy().into_owned();
        match crate::git::stage::discard_file(self.active_repo_path(), &rel_str) {
            Ok(()) => {
                self.toast(format!("discarded {basename}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore: {e}")),
        }
    }

    /// `git show <hash>:<rel>` into a scratch buffer titled
    /// `<rel> @ <short>`. Useful from the diff context menu when
    /// the user wants to read the file's full contents at the
    /// chosen revision (rather than just the changed lines).
    pub fn open_file_at_revision(&mut self, hash: &str, rel: &std::path::Path) {
        use std::process::Command;
        let spec = format!("{}:{}", hash, rel.to_string_lossy());
        let out = Command::new("git")
            .args(["show", &spec])
            .current_dir(self.active_repo_path())
            .output();
        let text = match out {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
            Ok(o) => {
                self.toast(format!(
                    "git show: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                ));
                return;
            }
            Err(e) => {
                self.toast(format!("git show: {e}"));
                return;
            }
        };
        let short = hash.chars().take(7).collect::<String>();
        let title = format!("{} @ {}", rel.to_string_lossy(), short);
        self.open_scratch_with_text(title, text);
    }

    // A-3: open_ex_command_prompt + no_pane_cmdline_* methods moved
    // to src/app/cmdline_methods.rs.

    pub fn open_new_file_prompt(&mut self, parent: PathBuf) {
        self.pending_fs_action = Some(FsAction::NewFile {
            parent: parent.clone(),
        });
        let title = format!("New file in {}/", rel_path(&self.workspace, &parent));
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewFile,
            title,
        ));
    }

    /// Open the "New folder…" prompt — captures `parent`.
    pub fn open_new_folder_prompt(&mut self, parent: PathBuf) {
        self.pending_fs_action = Some(FsAction::NewFolder {
            parent: parent.clone(),
        });
        let title = format!("New folder in {}/", rel_path(&self.workspace, &parent));
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewFolder,
            title,
        ));
    }

    /// Open the FS rename prompt — captures `path`, seeds with its filename.
    pub fn open_fs_rename_prompt(&mut self, path: PathBuf) {
        let seed = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        self.pending_fs_action = Some(FsAction::Rename { path: path.clone() });
        let title = format!("Rename {}", rel_path(&self.workspace, &path));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::Rename,
            title,
            seed,
        ));
    }

    /// Create an empty file at `parent / name` and open it. `name` may include
    /// `/` separators — any missing intermediate dirs are created. Empty name
    /// is a no-op; an existing target toasts and bails.
    pub fn create_new_file(&mut self, parent: &Path, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let target = parent.join(name);
        if target.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &target)
            ));
            return;
        }
        if let Some(p) = target.parent()
            && let Err(e) = std::fs::create_dir_all(p)
        {
            self.toast(format!("cannot create dirs for {}: {e}", p.display()));
            return;
        }
        if let Err(e) = std::fs::write(&target, "") {
            self.toast(format!("create failed: {e}"));
            return;
        }
        self.tree.refresh();
        self.toast(format!("created {}", rel_path(&self.workspace, &target)));
        self.open_path(&target);
    }

    /// `mkdir -p parent/name` (then refresh the tree).
    pub fn create_new_folder(&mut self, parent: &Path, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let target = parent.join(name);
        if target.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &target)
            ));
            return;
        }
        if let Err(e) = std::fs::create_dir_all(&target) {
            self.toast(format!("mkdir failed: {e}"));
            return;
        }
        self.tree.refresh();
        self.toast(format!("created {}/", rel_path(&self.workspace, &target)));
    }

    /// Open the FS delete prompt — captures `path`. Renders as a
    /// two-button `[ Delete ] [ Cancel ]` confirm dialog (Cancel is
    /// the default focus for safety). Was: text-input asking the
    /// user to type the filename verbatim; user feedback 2026-07-06
    /// flagged the pattern as goofy compared to the quit dialog.
    pub fn open_fs_delete_prompt(&mut self, path: PathBuf) {
        self.pending_fs_action = Some(FsAction::Delete { path: path.clone() });
        // #20 v4 — surface the recursive-delete case explicitly.
        // Also count how many entries would be removed so the user
        // sees the blast radius before confirming.
        let is_dir = path.is_dir();
        let rel = rel_path(&self.workspace, &path);
        let title = if is_dir {
            let count = walk_entry_count(&path, 0, 500);
            let count_hint = if count >= 500 {
                "500+ entries".to_string()
            } else {
                format!("{count} entr{}", if count == 1 { "y" } else { "ies" })
            };
            format!("Delete {rel} recursively? ({count_hint})")
        } else {
            format!("Delete {rel}?")
        };
        let mut prompt =
            crate::prompt::Prompt::new(crate::prompt::PromptKind::DeleteConfirm, title);
        // Focus Cancel by default (index 1) — safety first for a
        // destructive action.
        prompt.cursor = 1;
        self.prompt = Some(prompt);
    }

    /// Stage `path` on `file_clipboard`. `cut = true` marks paste as
    /// move; `cut = false` marks paste as copy. Multi-select support
    /// slots in here (push multiple; for now v1 is single-path).
    pub fn file_stage_clipboard(&mut self, path: PathBuf, cut: bool) {
        self.file_clipboard = vec![path.clone()];
        self.file_clipboard_cut = cut;
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        self.toast(format!("{} {}", if cut { "cut" } else { "copied" }, name));
    }

    /// Paste the clipboard into `target`. If `target` is a file, its
    /// parent dir is used. Cut = rename() the source; Copy = fs::copy
    /// (recursive for dirs). Refresh the tree; clear the clipboard on
    /// cut, keep it on copy so the same set can paste elsewhere.
    pub fn file_paste_into(&mut self, target: PathBuf) {
        if self.file_clipboard.is_empty() {
            self.toast("clipboard empty");
            return;
        }
        let target_dir = if target.is_dir() {
            target.clone()
        } else {
            target
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| self.workspace.clone())
        };
        if !target_dir.is_dir() {
            self.toast(format!("not a directory: {}", target_dir.display()));
            return;
        }
        let sources = self.file_clipboard.clone();
        let cut = self.file_clipboard_cut;
        let mut ok = 0usize;
        for src in &sources {
            let Some(name) = src.file_name() else {
                self.toast(format!("skip (no filename): {}", src.display()));
                continue;
            };
            let mut dest = target_dir.join(name);
            // Same-dir copy: bump the filename so we don't clobber
            // the source. Cut into the same dir is a no-op (toast).
            if dest == *src {
                if cut {
                    continue;
                }
                dest = collision_free_copy_name(&dest);
            } else if dest.exists() {
                self.toast(format!(
                    "already exists: {}",
                    rel_path(&self.workspace, &dest)
                ));
                continue;
            }
            let result = if cut {
                std::fs::rename(src, &dest).map_err(|e| e.to_string())
            } else {
                copy_recursively(src, &dest)
            };
            if let Err(e) = result {
                self.toast(format!(
                    "{} failed for {}: {e}",
                    if cut { "move" } else { "copy" },
                    rel_path(&self.workspace, src)
                ));
                continue;
            }
            ok += 1;
        }
        if cut {
            self.file_clipboard.clear();
            self.file_clipboard_cut = false;
        }
        self.tree.refresh();
        if ok > 0 {
            self.toast(format!(
                "{} {ok} item{} into {}",
                if cut { "moved" } else { "copied" },
                if ok == 1 { "" } else { "s" },
                rel_path(&self.workspace, &target_dir)
            ));
        }
    }

    /// Duplicate `path` in place with a `-copy` suffix; falls back to
    /// `-copy-2`, `-copy-3`, ... on collision.
    pub fn file_duplicate(&mut self, path: PathBuf) {
        let dest = collision_free_copy_name(&path);
        match copy_recursively(&path, &dest) {
            Ok(()) => {
                self.tree.refresh();
                self.toast(format!(
                    "duplicated {} \u{2192} {}",
                    rel_path(&self.workspace, &path),
                    rel_path(&self.workspace, &dest)
                ));
            }
            Err(e) => self.toast(format!("duplicate failed: {e}")),
        }
    }

    /// Open the "Move to..." prompt — the user types a destination
    /// directory (workspace-relative or absolute). Path suggestions
    /// come from the standard `is_path_kind` autocomplete path.
    pub fn file_open_move_to_picker(&mut self, path: PathBuf) {
        self.pending_fs_action = Some(FsAction::MoveTo {
            source: path.clone(),
        });
        let title = format!("Move {} to…", rel_path(&self.workspace, &path));
        let seed = path
            .parent()
            .map(|p| rel_path(&self.workspace, p))
            .unwrap_or_default();
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::FileMoveTo,
            title,
            seed,
        ));
    }

    /// Resolve the "Move to..." prompt — moves the pending source
    /// into the typed destination directory.
    pub fn file_finish_move_to(&mut self, dest_text: &str) {
        let Some(FsAction::MoveTo { source }) = self.pending_fs_action.take() else {
            return;
        };
        let dest_dir_raw = dest_text.trim();
        if dest_dir_raw.is_empty() {
            self.toast("move: empty destination");
            return;
        }
        let dest_dir = expand_tilde_and_resolve(&self.workspace, dest_dir_raw);
        if let Err(e) = std::fs::create_dir_all(&dest_dir) {
            self.toast(format!("mkdir failed: {e}"));
            return;
        }
        let Some(name) = source.file_name() else {
            self.toast(format!("no filename in {}", source.display()));
            return;
        };
        let dest = dest_dir.join(name);
        if dest == source {
            self.toast("move: source and destination are the same");
            return;
        }
        if dest.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &dest)
            ));
            return;
        }
        match std::fs::rename(&source, &dest) {
            Ok(()) => {
                self.tree.refresh();
                self.toast(format!(
                    "moved {} \u{2192} {}",
                    rel_path(&self.workspace, &source),
                    rel_path(&self.workspace, &dest)
                ));
            }
            Err(e) => self.toast(format!("move failed: {e}")),
        }
    }

    /// Dispatch handler for the generic destructive confirm-button
    /// dialogs (git delete branch / stash drop / worktree remove /
    /// tag delete / hunk discard / claude kill / merge / rebase).
    ///
    /// Rather than have N specialized `run_*_button` methods, this
    /// synthesizes the "magic string" each kind's accept handler
    /// expected (dynamic for `<name>`-style, static for `"drop"` /
    /// `"kill"` / etc.), writes it into `Prompt.input`, then calls
    /// the shared `accept_prompt` path. On cancel it writes an empty
    /// string so the else-branch fires and each kind's cancel logic
    /// runs unchanged.
    pub fn run_confirm_button(&mut self, primary: bool) {
        use crate::prompt::PromptKind::*;
        let Some(kind) = self.prompt.as_ref().map(|p| p.kind) else {
            return;
        };
        // Kinds where the accept handler doesn't check `Prompt.input`
        // at all (pure yes/no dispatch) get a direct routing rather
        // than a synthesized-input pass through `prompt_accept`.
        match kind {
            TreeMoveConfirm => {
                self.prompt = None;
                if primary {
                    self.accept_tree_move();
                } else {
                    self.pending_tree_move = None;
                    self.toast("move cancelled");
                }
                return;
            }
            AiToolConfirm => {
                self.prompt = None;
                self.resolve_tool_confirm(primary);
                return;
            }
            _ => {}
        }
        let synth = if primary {
            match kind {
                GitDeleteBranchConfirm => "delete".into(),
                WorktreeRemoveConfirm => "remove".into(),
                GitStashDrop => "drop".into(),
                GitTagDelete => self.pending_tag_delete.clone().unwrap_or_default(),
                DiffDiscardHunk => "discard".into(),
                GitDiscardFile => self
                    .pending_discard_file
                    .as_ref()
                    .and_then(|p| p.file_name())
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                ClaudeKillConfirm => "kill".into(),
                GitMergeConfirm => "merge".into(),
                GitRebaseConfirm => "rebase".into(),
                // Both install-confirm handlers just check `input.starts_with('y')`.
                ToolInstallConfirm | MarketplaceInstallConfirm => "y".into(),
                IntegrationRemoveConfirm => "uninstall".into(),
                ResetToDefaultsConfirm => "reset".into(),
                WorkspaceTrustConfirm => "trust".into(),
                // Both options are valid — primary=portable, cancel=normal.
                // The accept handler discriminates on the input string.
                PortableChoicePrompt => {
                    if primary {
                        "portable".into()
                    } else {
                        "normal".into()
                    }
                }
                _ => return,
            }
        } else {
            String::new()
        };
        if let Some(p) = self.prompt.as_mut() {
            p.input = synth;
        }
        self.prompt_accept();
    }

    /// Dispatch handler for the DeleteConfirm button dialog. Delete
    /// = execute, Cancel = drop the pending FsAction.
    pub fn run_delete_button(&mut self, code: u8) {
        match code {
            crate::ui::prompt::CONFIRM_BTN_PRIMARY => {
                if let Some(FsAction::Delete { path }) = self.pending_fs_action.take() {
                    self.execute_delete_fs_entry(&path);
                }
            }
            crate::ui::prompt::CONFIRM_BTN_CANCEL => {
                self.pending_fs_action = None;
                self.toast("delete cancelled");
            }
            _ => {}
        }
    }

    /// Execute the delete unconditionally — the caller (button
    /// dialog / test) is responsible for the confirmation gate.
    /// Removes any open editor buffer for the file; for a directory,
    /// removes every editor buffer under it. `rm` for a file,
    /// `rm -rf` for a dir.
    /// Refresh the primary file tree PLUS every extra workspace whose
    /// root is an ancestor of `path`. Use this after any filesystem
    /// mutation (delete / rename / paste / duplicate) so a change
    /// inside an extra workspace refreshes THAT extra's tree, not
    /// just the primary one. 2026-07-12 fix for stale row after
    /// delete-in-extra-workspace.
    pub fn refresh_trees_for_path(&mut self, path: &Path) {
        self.tree.refresh();
        for extra in self.extra_workspaces.iter_mut() {
            if path.starts_with(&extra.root) {
                extra.tree.refresh();
            }
        }
    }

    pub fn execute_delete_fs_entry(&mut self, path: &Path) {
        let is_dir = path.is_dir();
        let res = if is_dir {
            std::fs::remove_dir_all(path)
        } else {
            std::fs::remove_file(path)
        };
        if let Err(e) = res {
            self.toast(format!("delete failed: {e}"));
            return;
        }
        // Force-close any editor buffer for the deleted file (or dir contents).
        let affected: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| match p {
                Pane::Editor(b) => b.path.as_deref().and_then(|bp| {
                    if bp == path || (is_dir && bp.starts_with(path)) {
                        Some(i)
                    } else {
                        None
                    }
                }),
                _ => None,
            })
            .collect();
        for i in affected.into_iter().rev() {
            self.force_close_pane(i);
        }
        self.lsp.did_close(path);
        // Trim out of recent_files.
        self.recent_files
            .retain(|p| p != path && !(is_dir && p.starts_with(path)));
        // 2026-07-12 — refresh the extra workspace's tree too if
        // the deleted path lived inside one; previously only the
        // primary tree rescanned, so extra-workspace rows for the
        // deleted file hung around until a manual refresh.
        self.refresh_trees_for_path(path);
        // Bug 2026-07-06: right-click Delete on an HTTP-sidebar file
        // row was refreshing the file tree but NOT the HTTP panel's
        // own cache — the row stayed visible until the user closed +
        // reopened the section. Refresh the HTTP cache whenever a
        // path the panel might display gets deleted. Cheap to run
        // unconditionally (walks `.http` / `.curl` / `.rest` in the
        // workspace + `.mnml/` subdirs).
        self.http_panel_refresh();
        self.toast(format!(
            "deleted {}{}",
            rel_path(&self.workspace, path),
            if is_dir { "/" } else { "" }
        ));
    }

    /// Rename `from` → `<from.parent()>/new_name`. If `from` is open as an
    /// editor buffer, the buffer is repointed at the new path (LSP gets a
    /// close/open pair). Refuses an existing target.
    pub fn rename_fs_entry(&mut self, from: &Path, new_name: &str) {
        let new_name = new_name.trim();
        if new_name.is_empty() {
            return;
        }
        let Some(parent) = from.parent() else {
            self.toast("can't rename — no parent dir");
            return;
        };
        let to = parent.join(new_name);
        if to == from {
            return;
        }
        if to.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &to)
            ));
            return;
        }
        if let Err(e) = std::fs::rename(from, &to) {
            self.toast(format!("rename failed: {e}"));
            return;
        }
        // Repoint any open buffer for `from` at `to`.
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.path.as_deref() == Some(from)
            {
                b.path = Some(to.clone());
            }
        }
        self.lsp.did_close(from);
        // If still open as an editor, notify the LSP about the new path.
        let new_text = self.panes.iter().find_map(|p| match p {
            Pane::Editor(b) if b.is_at(&to) => Some(b.editor.text().to_string()),
            _ => None,
        });
        if let Some(t) = new_text {
            self.lsp.did_open(&to, &t);
        }
        // Update recent_files too.
        for p in &mut self.recent_files {
            if p == from {
                *p = to.clone();
            }
        }
        // 2026-07-12 — refresh whichever tree owns the source /
        // destination path so an extra-workspace rename doesn't leave
        // a stale row. `from` and `to` share a parent, so refreshing
        // either root is enough — refresh from `from` to cover the
        // "source moves out" case.
        self.refresh_trees_for_path(from);
        self.toast(format!(
            "renamed {} → {}",
            rel_path(&self.workspace, from),
            rel_path(&self.workspace, &to),
        ));
    }
}
