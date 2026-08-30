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
                // Cancel side ("Keep trusted") synthesizes "" and the
                // accept handler treats anything but "revoke" as keep,
                // so Esc — which routes here with primary=false — is
                // inert. That's why Revoke is the primary label.
                WorkspaceTrustReview => "revoke".into(),
                // NB: this arm only ever runs with `primary == true` —
                // the whole `match` is inside `if primary`. It used to
                // carry an `else { "normal" }` branch that could never
                // execute; the cancel side lands on `String::new()`
                // below, which `dispatch_portable_choice` maps to
                // normal via its `_` arm. Same outcome, but the dead
                // branch read as if the cancel verb were wired up.
                PortableChoicePrompt => "portable".into(),
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

impl App {
    /// The path the user means RIGHT NOW, for a file operation.
    ///
    /// #files — every `file.*` command used to read
    /// `app.tree.selected_file()` directly, so a `Pane::Files` was
    /// read-only: no cut, copy, paste, rename, delete or right-click,
    /// however many rows it showed. The underlying methods already take
    /// paths, so the whole gap was this resolver not existing.
    ///
    /// Precedence is FOCUS, not pane existence: a Files pane only wins
    /// while it has focus. Otherwise having one open anywhere would
    /// silently retarget the tree's own Ctrl+X, and a delete aimed at the
    /// wrong file is the worst outcome in this whole area.
    pub fn target_path(&self) -> Option<std::path::PathBuf> {
        if self.focus == crate::focus::Focus::Pane
            && let Some(i) = self.active
            && let Some(crate::pane::Pane::Files(f)) = self.panes.get(i)
        {
            return f.selected_entry().map(|e| e.path.clone());
        }
        self.tree.selected_file()
    }

    /// Every path an operation should act on.
    ///
    /// #files item 2 — the marked set when a focused Files pane has one,
    /// otherwise whatever [`Self::target_path`] resolves to. This is what
    /// makes marking mean anything: without it `Space` would decorate rows
    /// and Ctrl+C would still copy one file.
    pub fn target_paths(&self) -> Vec<std::path::PathBuf> {
        if self.focus == crate::focus::Focus::Pane
            && let Some(i) = self.active
            && let Some(crate::pane::Pane::Files(f)) = self.panes.get(i)
        {
            return f.action_paths();
        }
        self.target_path().into_iter().collect()
    }

    /// Stage several paths on the file clipboard.
    ///
    /// `file_clipboard` was always a `Vec` — `file_stage_clipboard` simply
    /// only ever put one path in it, so paste already handles a set.
    pub fn file_stage_clipboard_many(&mut self, paths: Vec<std::path::PathBuf>, cut: bool) {
        if paths.is_empty() {
            return;
        }
        if paths.len() == 1 {
            let p = paths.into_iter().next().unwrap();
            self.file_stage_clipboard(p, cut);
            return;
        }
        let n = paths.len();
        self.file_clipboard = paths;
        self.file_clipboard_cut = cut;
        self.toast(format!("{} {n} items", if cut { "cut" } else { "copied" }));
    }

    /// The DIRECTORY a new file / paste should land in.
    ///
    /// Distinct from [`Self::target_path`] because "paste here" means the
    /// current directory when a file is selected, not a sibling of it.
    pub fn target_dir(&self) -> Option<std::path::PathBuf> {
        if self.focus == crate::focus::Focus::Pane
            && let Some(i) = self.active
            && let Some(crate::pane::Pane::Files(f)) = self.panes.get(i)
        {
            return Some(f.cwd.clone());
        }
        self.tree.selected_file().map(|p| {
            if p.is_dir() {
                p
            } else {
                p.parent().map(|q| q.to_path_buf()).unwrap_or(p)
            }
        })
    }

    /// Re-read every Files pane showing `dir`, after an operation changed
    /// its contents. Without this a copy or delete appears not to have
    /// happened until the user presses `r`.
    pub fn refresh_files_panes_for(&mut self, dir: &std::path::Path) {
        for p in self.panes.iter_mut() {
            if let crate::pane::Pane::Files(f) = p
                && f.cwd == dir
            {
                f.reload();
            }
        }
    }

    /// Enter the selected directory, or open the selected file.
    ///
    /// The two are one gesture (`Enter` / `l` / double-click) because that
    /// is how every file manager behaves — the user is saying "go to this
    /// thing", and whether that means descend or open is the pane's
    /// problem, not theirs.
    pub fn files_pane_activate(&mut self, pane_idx: usize) {
        let Some(crate::pane::Pane::Files(f)) = self.panes.get_mut(pane_idx) else {
            return;
        };
        if f.enter_selected() {
            return;
        }
        // Not a directory — open it. `open_path` already routes by
        // extension (Request panes for .http, image panes for images,
        // editor otherwise), so a Files pane inherits all of that.
        let Some(path) = f.selected_entry().map(|e| e.path.clone()) else {
            return;
        };
        self.open_path(&path);
    }

    /// Two Files panes side by side — the commander layout.
    ///
    /// #files — the first version ran `open_files_pane` then
    /// `view.split_right` then `open_files_pane`, and `split_active`
    /// creates a PLACEHOLDER pane for the new side (a scratch buffer)
    /// when it has nothing to move there. The second Files pane then
    /// landed as a TAB beside that placeholder, so the right leaf opened
    /// showing `[scratch]` next to the browser. User report, with a
    /// screenshot: "whenever i open the dual browser the right side one
    /// gets a scratch tab, why?"
    ///
    /// `split_leaf_with` takes the pane to put on the new side, so the
    /// second browser IS the new side and no placeholder is ever created.
    pub fn open_dual_files_panes(&mut self) {
        let dir = self.workspace.clone();
        self.open_files_pane(Some(dir.clone()));
        let Some(left) = self.active else { return };
        let right = crate::pane::Pane::Files(crate::file_browser::FileBrowserPane::open(&dir));
        let id = self.split_leaf_with(left, crate::layout::SplitDir::Horizontal, right);
        self.active = Some(id);
        self.focus = crate::focus::Focus::Pane;
    }

    /// Preview the selected file WITHOUT leaving the Files pane.
    ///
    /// #files item 4. The flow this exists for is "arrow down a listing
    /// glancing at each file", so two things matter: the preview must
    /// REPLACE the previous one rather than stacking tabs, and focus must
    /// stay in the browser so the next arrow keeps working.
    ///
    /// Reuses `open_path_preview`, whose docstring said only the
    /// tree-click handler should call it — that comment is now updated,
    /// because this IS the same gesture: "show me this, I am still
    /// browsing". Everything it routes by extension comes free (images to
    /// the image pane, markdown to MdPreview, the rest to an editor).
    ///
    /// A directory previews as nothing. Descending is what Enter is for,
    /// and opening a directory in an editor pane is not a preview.
    pub fn files_pane_preview(&mut self, pane_idx: usize) {
        let Some(crate::pane::Pane::Files(f)) = self.panes.get(pane_idx) else {
            return;
        };
        let Some(e) = f.selected_entry() else { return };
        if e.is_dir {
            return;
        }
        let path = e.path.clone();
        let prev = f.preview_pane;
        // Point `active` at the previous preview so `open_path_preview`
        // replaces it. Only when it is still a live preview editor — the
        // user may have closed it, edited it (which promotes it out of
        // preview), or replaced the layout since.
        let reusable = prev.filter(|&id| {
            self.layout().contains(id)
                && matches!(self.panes.get(id), Some(crate::pane::Pane::Editor(b)) if b.is_preview)
        });
        if let Some(id) = reusable {
            self.active = Some(id);
        }
        self.open_path_preview(&path);
        let opened = self.active;
        if let Some(crate::pane::Pane::Files(f)) = self.panes.get_mut(pane_idx) {
            f.preview_pane = opened;
        }
        // Hand focus BACK. `open_path_preview` focuses what it opened,
        // which is right for a tree click and wrong here: it would move
        // the cursor out of the listing after every preview, so the next
        // `j` would scroll the previewed file instead of the browser.
        self.active = Some(pane_idx);
        self.focus = crate::focus::Focus::Pane;
    }

    /// Open a Files pane at `dir` (defaults to the workspace root).
    pub fn open_files_pane(&mut self, dir: Option<std::path::PathBuf>) {
        let dir = dir.unwrap_or_else(|| self.workspace.clone());
        let pane = crate::pane::Pane::Files(crate::file_browser::FileBrowserPane::open(&dir));
        self.panes.push(pane);
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
        self.focus = crate::focus::Focus::Pane;
    }
}

#[cfg(test)]
mod target_path_tests {
    use crate::app::App;
    use crate::config::Config;
    use crate::focus::Focus;

    fn fixture() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join("sub")).unwrap();
        std::fs::write(d.path().join("sub").join("inner.txt"), "x").unwrap();
        std::fs::write(d.path().join("root.txt"), "y").unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    /// #files — the resolver is why a Files pane can do anything at all.
    /// Every `file.*` command read `tree.selected_file()` directly, so the
    /// pane was read-only however many rows it showed.
    #[test]
    fn a_focused_files_pane_owns_the_target() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, mut app) = fixture();
        app.open_files_pane(Some(d.path().join("sub")));
        assert_eq!(app.focus, Focus::Pane, "open_files_pane should focus it");

        let got = app.target_path().expect("no target");
        assert_eq!(
            got.file_name().unwrap(),
            "inner.txt",
            "target should be the Files pane's selection, got {got:?}"
        );
    }

    /// Precedence is FOCUS, not existence. An open-but-unfocused Files
    /// pane must not retarget the tree's own Ctrl+X — a delete aimed at
    /// the wrong file is the worst outcome in this area.
    #[test]
    fn an_unfocused_files_pane_does_not_steal_the_target() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, mut app) = fixture();
        app.open_files_pane(Some(d.path().join("sub")));
        // User moves focus back to the tree.
        app.focus = Focus::Tree;

        let got = app.target_path();
        assert!(
            got.is_none_or(|p| p.file_name().unwrap() != "inner.txt"),
            "an unfocused Files pane hijacked the tree's target"
        );
    }

    /// "Paste here" means the current directory, not a sibling of the
    /// selected file.
    #[test]
    fn target_dir_is_the_panes_cwd_not_the_selections_parent() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, mut app) = fixture();
        app.open_files_pane(Some(d.path().join("sub")));
        let got = app.target_dir().expect("no target dir");
        assert_eq!(got.file_name().unwrap(), "sub", "got {got:?}");
    }

    /// An operation that changes a directory must be reflected without the
    /// user pressing `r`.
    #[test]
    fn refresh_reloads_only_the_panes_showing_that_directory() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, mut app) = fixture();
        app.open_files_pane(Some(d.path().join("sub")));
        let pid = app.active.unwrap();
        let before = match app.panes.get(pid) {
            Some(crate::pane::Pane::Files(f)) => f.entries.len(),
            _ => panic!(),
        };

        std::fs::write(d.path().join("sub").join("added.txt"), "z").unwrap();
        // A refresh for an UNRELATED directory must not pick it up...
        app.refresh_files_panes_for(d.path());
        let mid = match app.panes.get(pid) {
            Some(crate::pane::Pane::Files(f)) => f.entries.len(),
            _ => panic!(),
        };
        assert_eq!(mid, before, "refreshed a pane showing a different dir");

        // ...but a refresh for its own directory must.
        let sub = d.path().join("sub");
        app.refresh_files_panes_for(&sub);
        let after = match app.panes.get(pid) {
            Some(crate::pane::Pane::Files(f)) => f.entries.len(),
            _ => panic!(),
        };
        assert_eq!(after, before + 1, "the pane did not re-read its directory");
    }
}

#[cfg(test)]
mod open_split_tests {
    use crate::app::App;
    use crate::config::Config;

    /// `files.open_split` is the commander shape. Never tested when it
    /// shipped — verify it really produces TWO Files panes side by side
    /// rather than two tabs of one leaf.
    #[test]
    fn open_split_yields_exactly_two_panes_and_nothing_else() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();

        crate::command::run("files.open_split", &mut app);

        let ids = app.layout().all_panes();
        let files = ids
            .iter()
            .filter(|&&i| matches!(app.panes.get(i), Some(crate::pane::Pane::Files(_))))
            .count();
        assert_eq!(files, 2, "expected two Files panes, got {files}");

        // THE ASSERTION THAT WAS MISSING. The first version of this test
        // checked only "two Files panes exist in a split" and passed while
        // the right leaf also carried a `[scratch]` placeholder tab —
        // `split_active` creates one when it has nothing to move to the new
        // side. Counting Files panes could never see it; counting EVERY
        // pane in the layout can.
        assert_eq!(
            ids.len(),
            2,
            "the layout holds {} panes, not 2 — something extra came along: {:?}",
            ids.len(),
            ids.iter()
                .map(|&i| app.panes.get(i).map(|p| p.title()))
                .collect::<Vec<_>>()
        );

        // Every leaf must hold exactly ONE tab, or a browser is hidden
        // behind a tab strip instead of being visible side by side.
        for &id in &ids {
            let tabs = app
                .layout()
                .leaf_containing(id)
                .map(|t| t.len())
                .unwrap_or(0);
            assert_eq!(
                tabs, 1,
                "leaf containing pane {id} has {tabs} tabs; the second pane \
                 is a tab rather than a split side"
            );
        }

        assert!(
            matches!(app.layout(), crate::layout::Layout::Split { .. }),
            "the two panes are not in a split"
        );
    }
}

#[cfg(test)]
mod entry_point_tests {
    use crate::app::App;
    use crate::config::Config;

    /// #files — every advertised route must actually resolve to a
    /// registered command. mnml has shipped menu rows pointing at
    /// non-existent command ids twice (#1226 View/Go menus, and the
    /// palette-bar `+` chip), and both times the label promised something
    /// the wiring could not deliver.
    #[test]
    fn every_files_entry_point_names_a_registered_command() {
        for id in ["files.open", "files.open_split"] {
            assert!(
                crate::command::registry().all().iter().any(|c| c.id == id),
                "`{id}` is advertised in a menu but is not registered"
            );
        }
    }

    /// The View menu rows specifically — a menu label is a promise.
    #[test]
    fn the_view_menu_offers_both_file_pane_rows() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let menus = crate::menu_bar::bar(&app);
        let view = menus
            .iter()
            .find(|m| m.label == "View")
            .expect("no View menu");
        let ids: Vec<&str> = view
            .items
            .iter()
            .filter_map(|i| match i {
                crate::menu_bar::MenuItem::Action { command_id, .. } => Some(command_id.as_str()),
                _ => None,
            })
            .collect();
        assert!(
            ids.contains(&"files.open"),
            "View menu has no file-browser row: {ids:?}"
        );
        assert!(
            ids.contains(&"files.open_split"),
            "View menu has no dual-pane row: {ids:?}"
        );
    }

    /// A folder's right-click must offer to open it AS a browser, at that
    /// folder — not at the workspace root, which would make the user
    /// navigate back down to where they already were.
    #[test]
    fn a_folder_right_click_opens_the_browser_at_that_folder() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join("deep")).unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let dir = d.path().join("deep");
        app.open_tree_context_menu(dir.clone(), true, (2, 2));
        let menu = app.context_menu.take().expect("no menu");
        let action = menu
            .items
            .iter()
            .find(|i| i.label.contains("file browser"))
            .map(|i| i.action.clone())
            .expect("no 'Open in file browser' row on a folder");
        // The action must CARRY the right-clicked directory. Asserted on
        // the payload rather than by firing it, because opening at the
        // workspace root instead would still produce a Files pane — the
        // failure this guards against is a pane at the WRONG place.
        match action {
            crate::context_menu::MenuAction::OpenFilesPane(p) => assert_eq!(
                p.canonicalize().unwrap(),
                dir.canonicalize().unwrap(),
                "the row carries the wrong directory"
            ),
            other => panic!("wrong action on the row: {other:?}"),
        }
    }
}

#[cfg(test)]
mod multi_select_tests {
    use crate::app::App;
    use crate::config::Config;

    fn fixture() -> (tempfile::TempDir, App, usize) {
        let d = tempfile::tempdir().unwrap();
        for n in ["one.txt", "two.txt", "three.txt"] {
            std::fs::write(d.path().join(n), n).unwrap();
        }
        std::fs::create_dir(d.path().join("dest")).unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_files_pane(None);
        let pid = app.active.unwrap();
        (d, app, pid)
    }

    /// #files item 2 — the whole point: Ctrl+C must stage the MARKED SET,
    /// not one file. Without this, `Space` would just decorate rows.
    #[test]
    fn copy_stages_every_marked_path() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture();
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.selected = 0;
            f.toggle_mark(); // marks + advances
            f.toggle_mark();
        }
        crate::command::run("file.copy", &mut app);
        assert_eq!(
            app.file_clipboard.len(),
            2,
            "clipboard holds {:?}, expected the two marked paths",
            app.file_clipboard
        );
        assert!(!app.file_clipboard_cut, "copy must not be a cut");
    }

    /// And with nothing marked it still stages the cursor row, so every
    /// operation works without ever pressing Space.
    #[test]
    fn copy_without_marks_stages_the_cursor_row() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture();
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.selected = 1;
        }
        crate::command::run("file.copy", &mut app);
        assert_eq!(app.file_clipboard.len(), 1, "{:?}", app.file_clipboard);
    }

    /// A marked set must actually paste — the clipboard being a Vec is not
    /// proof that paste iterates it.
    #[test]
    fn pasting_a_marked_set_copies_every_file() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, mut app, pid) = fixture();
        // Mark the three FILES explicitly.
        //
        // The first version started at index 0 and toggled three times,
        // which silently included `dest` — directories sort first — so it
        // pasted `dest` INTO `dest`. That recursed until the stack ran out
        // and CI aborted with `fatal runtime error: stack overflow`. The
        // crash was a real product bug (now guarded in `copy_recursively`),
        // but this test should be deliberate about what it marks rather
        // than depending on sort order.
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            for name in ["one.txt", "two.txt", "three.txt"] {
                f.selected = f.entries.iter().position(|e| e.name == name).unwrap();
                f.toggle_mark();
            }
            assert!(
                f.marked.iter().all(|p| p.is_file()),
                "a directory got marked: {:?}",
                f.marked
            );
        }
        crate::command::run("file.copy", &mut app);
        assert_eq!(app.file_clipboard.len(), 3, "setup: three staged");

        let dest = d.path().join("dest");
        app.file_paste_into(dest.clone());

        let landed = std::fs::read_dir(&dest).unwrap().count();
        assert_eq!(
            landed, 3,
            "only {landed} of 3 marked files were pasted — paste does not \
             iterate the clipboard"
        );
    }

    /// An unfocused Files pane must not contribute its marks — same
    /// reasoning as `target_path`: a bulk delete aimed at the wrong set is
    /// the worst outcome in this area.
    #[test]
    fn an_unfocused_panes_marks_are_ignored() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture();
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.selected = 0;
            f.toggle_mark();
            f.toggle_mark();
        }
        app.focus = crate::focus::Focus::Tree;
        let paths = app.target_paths();
        assert!(
            paths.len() <= 1,
            "an unfocused pane's marks leaked into the target set: {paths:?}"
        );
    }
}

#[cfg(test)]
mod preview_tests {
    use crate::app::App;
    use crate::config::Config;
    use crate::focus::Focus;

    fn fixture(style: &str) -> (tempfile::TempDir, App, usize) {
        let d = tempfile::tempdir().unwrap();
        for n in ["one.txt", "two.txt", "three.txt"] {
            std::fs::write(d.path().join(n), n).unwrap();
        }
        std::fs::create_dir(d.path().join("adir")).unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = style.to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_files_pane(None);
        let pid = app.active.unwrap();
        // Cursor onto the first FILE. Directories sort first, so index 0
        // is `adir` — an earlier version of these tests previewed a
        // directory and then asserted about panes that were never opened.
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.selected = f.entries.iter().position(|e| !e.is_dir).unwrap();
        }
        (d, app, pid)
    }

    /// #files item 4 — the flow is "arrow down glancing at each file", so
    /// focus must STAY in the browser. `open_path_preview` focuses what it
    /// opens, which is right for a tree click and wrong here.
    #[test]
    fn previewing_keeps_focus_in_the_files_pane() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture("standard");
        app.files_pane_preview(pid);
        assert_eq!(
            app.active,
            Some(pid),
            "preview moved focus out of the listing; the next `j` would \
             scroll the previewed file instead"
        );
        assert_eq!(app.focus, Focus::Pane);
    }

    /// And it must actually open something.
    #[test]
    fn previewing_opens_the_selected_file() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture("standard");
        let before = app.panes.len();
        app.files_pane_preview(pid);
        assert!(app.panes.len() > before, "no pane opened");
    }

    /// Previewing several files in a row must REPLACE, not stack — the
    /// whole point of using the preview-tab mechanism.
    #[test]
    fn previewing_several_files_reuses_one_tab() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture("standard");
        app.files_pane_preview(pid);
        let after_first = app.panes.len();
        for _ in 0..3 {
            if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
                f.move_selection(1);
            }
            app.files_pane_preview(pid);
        }
        assert_eq!(
            app.panes.len(),
            after_first,
            "each preview opened a new pane — arrowing through a directory \
             would bury the browser in tabs"
        );
    }

    /// A directory is not previewable — Enter descends into it, and
    /// opening a folder in an editor pane is not a preview.
    #[test]
    fn previewing_a_directory_does_nothing() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (_d, mut app, pid) = fixture("standard");
        // Back onto the directory (`adir` sorts first).
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.selected = 0;
            assert!(f.selected_entry().unwrap().is_dir, "setup: cursor on a dir");
        }
        let before = app.panes.len();
        app.files_pane_preview(pid);
        assert_eq!(
            app.panes.len(),
            before,
            "a directory was opened as a preview"
        );
    }
}
