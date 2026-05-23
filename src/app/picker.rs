//! Picker + prompt accept dispatchers + picker openers.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//! (`.local/PLAN.md` Phase E.1). Pure non-destructive move.

use super::*;

impl App {
    pub fn open_picker(&mut self, picker: Picker) {
        self.whichkey = None;
        self.picker = Some(picker);
    }

    pub fn close_picker(&mut self) {
        self.picker = None;
    }

    /// Open the fuzzy file finder over every file in the workspace. Recent
    /// files (from `App::recent_files`) are prepended in recency order so
    /// "Ctrl+P, Enter" jumps straight back to the last file — fuzzy
    /// `refilter` keeps original order on tie scores, and the empty-query
    /// score is constant, so the prepended order survives until the user
    /// types something.
    pub fn open_file_picker(&mut self) {
        use crate::picker::PickerItem;
        use std::collections::HashSet;
        let root = self.workspace.clone();
        let make_item = |p: &Path| -> PickerItem {
            let rel = p.strip_prefix(&root).unwrap_or(p).to_path_buf();
            let label = rel.to_string_lossy().to_string();
            let dir = rel
                .parent()
                .map(|d| d.to_string_lossy().to_string())
                .unwrap_or_default();
            PickerItem::new(p.to_string_lossy().to_string(), label, dir)
        };
        // Recents first (newest first; absolute paths only — non-workspace
        // entries silently come along, which is fine, they still open).
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut items: Vec<PickerItem> = Vec::new();
        for p in &self.recent_files {
            if seen.insert(p.clone()) && p.exists() {
                items.push(make_item(p));
            }
        }
        // Then the rest of the primary workspace, skipping anything already in.
        for p in self.tree.all_files() {
            if seen.insert(p.clone()) {
                items.push(make_item(&p));
            }
        }
        // Multi-root: extra workspaces' files too, after the primary's. They
        // keep their natural tree order but appear below the launched
        // workspace so the picker doesn't shuffle the user's mental model
        // of "this is the workspace I opened".
        for ws in &self.extra_workspaces {
            for p in ws.tree.all_files() {
                if seen.insert(p.clone()) {
                    items.push(make_item(&p));
                }
            }
        }
        self.open_picker(Picker::new(PickerKind::Files, "Open file", items));
    }

    /// Open a fuzzy picker over `App::recent_files` (most-recent first). The
    /// items keep that order — fuzzy filtering still works on the labels but
    /// the unfiltered list is recency-sorted (the picker doesn't auto-sort
    /// alphabetically), so just opening the picker + Enter goes "back" to the
    /// last file.
    pub fn open_recent_files_picker(&mut self) {
        use crate::picker::PickerItem;
        // Multi-root: build a list of candidate workspace roots (primary +
        // each extra) so a file from any of them gets the right relative
        // label rather than its full absolute path.
        let primary = self.workspace.clone();
        let extra_roots: Vec<std::path::PathBuf> = self
            .extra_workspaces
            .iter()
            .map(|w| w.root.clone())
            .collect();
        let items: Vec<PickerItem> = self
            .recent_files
            .iter()
            .filter(|p| p.exists())
            .map(|p| {
                // Pick the workspace this file belongs to (longest matching
                // prefix), then build the relative label. Files outside any
                // configured workspace use their absolute path.
                let rel = std::iter::once(&primary)
                    .chain(extra_roots.iter())
                    .filter_map(|root| p.strip_prefix(root).ok())
                    .next()
                    .unwrap_or(p.as_path())
                    .to_path_buf();
                let label = rel.to_string_lossy().to_string();
                let dir = rel
                    .parent()
                    .map(|d| d.to_string_lossy().to_string())
                    .unwrap_or_default();
                PickerItem::new(p.to_string_lossy().to_string(), label, dir)
            })
            .collect();
        if items.is_empty() {
            self.toast("no recent files yet");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Recent, "Recent files", items));
    }

    /// Open a fuzzy picker over every open PR / MR across the configured
    /// SCM hosts (Bitbucket, GitHub, GitLab, Azure DevOps). Reads from the
    /// per-host caches the SCM workers populate — no fresh API calls; the
    /// list is as recent as the last poll cycle. Items are sorted by
    /// most-recent activity (updated_at ⇒ created_at fallback). Accept
    /// opens the chosen PR's web URL in the OS browser.
    pub fn open_pr_picker(&mut self) {
        use crate::picker::PickerItem;
        // Unified row shape — collected from all 4 hosts, sorted, then
        // projected to PickerItem.
        struct Row {
            host_tag: &'static str,
            repo_label: String,
            number: String,
            title: String,
            state_label: &'static str,
            author: Option<String>,
            source: Option<String>,
            dest: Option<String>,
            reviewers: u32,
            approved: u32,
            changes: u32,
            comments: u32,
            ts_ms: i64,
            web_url: String,
        }
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let mut rows: Vec<Row> = Vec::new();
        // Bitbucket — keyed by (workspace, slug).
        for ((ws, slug), prs) in &self.bitbucket_pull_requests {
            for pr in prs {
                rows.push(Row {
                    host_tag: "BB",
                    repo_label: format!("{ws}/{slug}"),
                    number: format!("#{}", pr.id),
                    title: pr.title.clone(),
                    state_label: pr.state.label(),
                    author: pr.author.clone(),
                    source: pr.source_branch.clone(),
                    dest: pr.dest_branch.clone(),
                    reviewers: pr.reviewer_count,
                    approved: pr.approved_count,
                    changes: pr.changes_count,
                    comments: pr.comment_count,
                    ts_ms: pr.updated_on_ms.or(pr.created_on_ms).unwrap_or(0),
                    web_url: pr.web_url.clone(),
                });
            }
        }
        // GitHub — keyed by (owner, repo). Comments + review comments
        // combined for the unified `comments` count.
        for ((owner, repo), prs) in &self.github_pull_requests {
            for pr in prs {
                rows.push(Row {
                    host_tag: "GH",
                    repo_label: format!("{owner}/{repo}"),
                    number: format!("#{}", pr.number),
                    title: pr.title.clone(),
                    state_label: pr.state.label(),
                    author: pr.author.clone(),
                    source: pr.source_branch.clone(),
                    dest: pr.dest_branch.clone(),
                    reviewers: pr.reviewer_count,
                    approved: pr.approved_count,
                    changes: pr.changes_count,
                    comments: pr.comment_count + pr.review_comment_count,
                    ts_ms: pr.updated_at_ms.or(pr.created_at_ms).unwrap_or(0),
                    web_url: pr.web_url.clone(),
                });
            }
        }
        // GitLab — keyed by project label (numeric ID or "group/path").
        // `!iid` is the URL-segment shape ("!17"), not "#17".
        for (project, mrs) in &self.gitlab_merge_requests {
            for mr in mrs {
                rows.push(Row {
                    host_tag: "GL",
                    repo_label: project.clone(),
                    number: format!("!{}", mr.iid),
                    title: mr.title.clone(),
                    state_label: mr.state.label(),
                    author: mr.author.clone(),
                    source: mr.source_branch.clone(),
                    dest: mr.dest_branch.clone(),
                    reviewers: mr.reviewer_count,
                    approved: mr.approved_count,
                    changes: mr.changes_count,
                    comments: mr.comment_count,
                    ts_ms: mr.updated_at_ms.or(mr.created_at_ms).unwrap_or(0),
                    web_url: mr.web_url.clone(),
                });
            }
        }
        // Azure DevOps — label already shaped "org/project/repo".
        for (label, prs) in &self.azdevops_pull_requests {
            for pr in prs {
                rows.push(Row {
                    host_tag: "AZ",
                    repo_label: label.clone(),
                    number: format!("#{}", pr.id),
                    title: pr.title.clone(),
                    state_label: pr.state.label(),
                    author: pr.author.clone(),
                    source: pr.source_branch.clone(),
                    dest: pr.dest_branch.clone(),
                    reviewers: pr.reviewer_count,
                    approved: pr.approved_count,
                    changes: pr.changes_count,
                    comments: pr.comment_count,
                    ts_ms: pr.created_at_ms.unwrap_or(0),
                    web_url: pr.web_url.clone(),
                });
            }
        }
        if rows.is_empty() {
            self.toast(
                "no open PRs in cache yet — configure [[bitbucket.repos]] / [[github.repos]] / [[gitlab.projects]] / [[azdevops.projects]] and wait one poll cycle",
            );
            return;
        }
        // Most recent activity first; ties keep insertion order.
        rows.sort_by_key(|r| std::cmp::Reverse(r.ts_ms));
        let items: Vec<PickerItem> = rows
            .into_iter()
            .map(|r| {
                // Label is the fuzzy-match target — pack everything a user
                // might type: host, repo, number, title, state.
                let label = format!(
                    "[{}] {} {} {} — {}",
                    r.host_tag, r.repo_label, r.state_label, r.number, r.title
                );
                // Item id encodes the full cross-nav payload so the
                // secondary accept (Ctrl+Enter → jump-to-pipeline) has
                // everything it needs without an App-side stash. Fields
                // separated by `\x1F` (unit separator), which doesn't
                // appear in URLs / branch names / repo labels.
                let id = format!(
                    "{}\x1F{}\x1F{}\x1F{}",
                    r.web_url,
                    r.host_tag,
                    r.repo_label,
                    r.source.clone().unwrap_or_default(),
                );
                let branches = match (r.source.as_deref(), r.dest.as_deref()) {
                    (Some(s), Some(d)) => format!("{s}→{d}"),
                    (Some(s), None) => s.to_string(),
                    (None, Some(d)) => format!("→{d}"),
                    (None, None) => String::new(),
                };
                let counts = format!(
                    "👀{} ✓{} ✗{} 💬{}",
                    r.reviewers, r.approved, r.changes, r.comments
                );
                let age = if r.ts_ms > 0 {
                    crate::ui::git_graph_view::humanize_age(now_ms.saturating_sub(r.ts_ms) / 1000)
                } else {
                    String::new()
                };
                let mut detail_parts: Vec<String> = Vec::new();
                if let Some(a) = r.author.as_deref()
                    && !a.is_empty()
                {
                    detail_parts.push(a.to_string());
                }
                if !branches.is_empty() {
                    detail_parts.push(branches);
                }
                detail_parts.push(counts);
                if !age.is_empty() {
                    detail_parts.push(age);
                }
                PickerItem::new(id, label, detail_parts.join(" · "))
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::OpenPullRequests,
            "Pull requests · all hosts",
            items,
        ));
    }

    /// Open the buffer switcher over the currently-open panes.
    pub fn open_buffer_picker(&mut self) {
        use crate::picker::PickerItem;
        // Order: MRU first, then anything left over (panes opened but never
        // focused — shouldn't happen normally but the fallback keeps the list
        // complete). The active pane is dropped from the top so the picker
        // starts on the second-most-recent (vim's "alternate buffer" pattern
        // — pressing Enter on the picker swaps quickly).
        let mut ordered: Vec<usize> = Vec::with_capacity(self.panes.len());
        let active = self.active;
        for &id in self.pane_mru.iter() {
            if id < self.panes.len() && Some(id) != active && !ordered.contains(&id) {
                ordered.push(id);
            }
        }
        for i in 0..self.panes.len() {
            if Some(i) != active && !ordered.contains(&i) {
                ordered.push(i);
            }
        }
        // Active last (so it's still in the list, but at the bottom).
        if let Some(a) = active
            && a < self.panes.len()
        {
            ordered.push(a);
        }
        let items: Vec<PickerItem> = ordered
            .into_iter()
            .map(|i| {
                let p = &self.panes[i];
                PickerItem::new(
                    i.to_string(),
                    p.title(),
                    if p.is_dirty() { "●" } else { "" },
                )
            })
            .collect();
        if items.is_empty() {
            self.toast("no open buffers");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Buffers, "Switch buffer", items));
    }

    /// `tab.picker` — fuzzy picker over the tab pages. Each row labels
    /// the tab number, the active pane's display name (or `(empty)`),
    /// and a `●` chip when any pane in the tab has unsaved changes.
    /// The active tab sorts last so the picker opens cursored on the
    /// second-most-recent (mirrors `open_buffer_picker`).
    pub fn open_tab_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.layouts.len() <= 1 {
            self.toast("only one tab");
            return;
        }
        let active = self.active_layout;
        let mut order: Vec<usize> = (0..self.layouts.len()).filter(|&i| i != active).collect();
        order.push(active);
        let items: Vec<PickerItem> = order
            .into_iter()
            .map(|i| {
                // Tab's "headline" — last-focused pane's title.
                let head_title = self
                    .tab_actives
                    .get(i)
                    .copied()
                    .unwrap_or(None)
                    .or_else(|| self.layouts.get(i)?.first_leaf())
                    .and_then(|id| self.panes.get(id))
                    .map(|p| p.title())
                    .unwrap_or_else(|| "(empty)".to_string());
                // Dirty if any editor pane in the tab is dirty.
                let dirty = self
                    .layouts
                    .get(i)
                    .map(|l| l.leaves())
                    .unwrap_or_default()
                    .into_iter()
                    .any(|id| matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.dirty));
                let mark = if i == active { "●" } else { "" };
                PickerItem::new(
                    i.to_string(),
                    format!("{} {} {}", i + 1, mark, head_title)
                        .trim()
                        .to_string(),
                    if dirty { "● dirty" } else { "" }.to_string(),
                )
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Tabs, "Switch tab page", items));
    }

    /// `picker.marks` (`<leader>m m`) — fuzzy picker over every set mark.
    /// Buffer-local (lowercase) marks first, then global (uppercase) ones.
    /// Each row labels the letter, the file (relative), the line/col, and a
    /// short slice of the line text as a preview.
    pub fn open_marks_picker(&mut self) {
        use crate::picker::PickerItem;
        let mut items: Vec<PickerItem> = Vec::new();
        // Local marks for the active buffer.
        if let Some(b) = self.active_editor() {
            let mut local: Vec<(char, (usize, usize))> =
                b.marks.iter().map(|(&c, &v)| (c, v)).collect();
            local.sort_by_key(|(c, _)| *c);
            let text = b.editor.text();
            let path = b
                .path
                .as_ref()
                .map(|p| rel_path(&self.workspace, p))
                .unwrap_or_else(|| b.display_name().to_string());
            for (c, (row, col)) in local {
                let line = text.lines().nth(row).unwrap_or("").trim();
                let preview: String = line.chars().take(40).collect();
                items.push(PickerItem::new(
                    format!("local:{c}"),
                    format!("'{c}  {path}:{}:{}  {preview}", row + 1, col + 1),
                    "local".to_string(),
                ));
            }
        }
        // Global marks across the workspace.
        let mut global: Vec<(char, (PathBuf, usize, usize))> = self
            .global_marks
            .iter()
            .map(|(&c, v)| (c, v.clone()))
            .collect();
        global.sort_by_key(|(c, _)| *c);
        for (c, (path, row, col)) in global {
            let rel = rel_path(&self.workspace, &path);
            // Try to read a preview line from disk (fast, single line).
            let preview = std::fs::read_to_string(&path)
                .ok()
                .and_then(|text| text.lines().nth(row).map(|s| s.trim().to_string()))
                .unwrap_or_default();
            let preview: String = preview.chars().take(40).collect();
            items.push(PickerItem::new(
                format!("global:{}", c.to_ascii_lowercase()),
                format!("'{c}  {rel}:{}:{}  {preview}", row + 1, col + 1),
                "global".to_string(),
            ));
        }
        if items.is_empty() {
            self.toast("no marks set");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Marks, "Marks", items));
    }

    /// Open the command palette over the registered commands (builtins + any
    /// plugin-registered ones).
    pub fn open_command_palette(&mut self) {
        use crate::picker::PickerItem;
        let mut items: Vec<PickerItem> = crate::command::registry()
            .all()
            .iter()
            .filter(|c| c.id != "palette")
            .map(|c| PickerItem::new(c.id, format!("{}  ·  {}", c.group, c.title), c.key_hint()))
            .collect();
        for dc in &self.dynamic_commands {
            items.push(PickerItem::new(
                dc.id.clone(),
                format!("{}  ·  {}", dc.group, dc.title),
                dc.keys.join(" / "),
            ));
        }
        self.open_picker(Picker::new(PickerKind::Commands, "Command palette", items));
    }

    /// Open the theme picker over the built-in themes. Each row's detail
    /// column flags the currently-active theme and the configured default
    /// (`[ui] theme` from config.toml) so the user can tell at a glance
    /// which is which — useful when they've live-switched away.
    pub fn open_theme_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::ui::theme::cur().name;
        let default_name = self.config.ui.theme.clone();
        let toggle_name = self.config.ui.theme_toggle.clone();
        let items: Vec<PickerItem> = crate::ui::theme::names()
            .into_iter()
            .map(|n| {
                let mut tags: Vec<&str> = Vec::new();
                if n == cur {
                    tags.push("current");
                }
                if n.eq_ignore_ascii_case(&default_name) {
                    tags.push("default");
                }
                if let Some(alt) = toggle_name.as_deref()
                    && n.eq_ignore_ascii_case(alt)
                {
                    tags.push("toggle");
                }
                PickerItem::new(n, n, tags.join(" · "))
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Themes, "Theme", items));
    }

    /// Act on the picker's current selection, then close it.
    /// Tab on a picker — picker-kind-specific "secondary accept".
    /// For `PickerKind::OpenPullRequests`, jumps to the PR's matching
    /// pipeline/build (instead of opening the URL). For other kinds,
    /// no-op + a short hint toast.
    pub fn picker_accept_secondary(&mut self) {
        let Some(picker) = &self.picker else {
            return;
        };
        let kind = picker.kind;
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match kind {
            PickerKind::OpenPullRequests => {
                self.picker = None;
                let mut parts = item.id.split('\x1F');
                let _url = parts.next().unwrap_or("");
                let host_tag = parts.next().unwrap_or("");
                let repo_label = parts.next().unwrap_or("");
                let branch = parts.next().unwrap_or("");
                if branch.is_empty() {
                    self.toast("no source branch on this PR — can't cross-nav");
                    return;
                }
                self.cross_nav_pr_to_pipeline(host_tag, repo_label, branch);
            }
            _ => {
                // No secondary action; let the user know Tab did something.
                self.toast("Tab → no secondary action for this picker");
            }
        }
    }

    pub fn picker_accept(&mut self) {
        let Some(picker) = self.picker.take() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match picker.kind {
            PickerKind::Files | PickerKind::Recent => self.open_path(Path::new(&item.id)),
            PickerKind::Harpoon => {
                if let Ok(slot1) = item.id.parse::<usize>() {
                    self.harpoon_goto(slot1);
                }
            }
            PickerKind::Buffers => {
                if let Ok(i) = item.id.parse::<usize>()
                    && i < self.panes.len()
                {
                    self.reveal_pane(i);
                }
            }
            PickerKind::Tabs => {
                if let Ok(i) = item.id.parse::<usize>()
                    && i < self.layouts.len()
                {
                    self.switch_tab(i);
                }
            }
            PickerKind::Commands => {
                crate::command::run(&item.id, self);
            }
            PickerKind::Themes => self.set_theme(&item.id),
            PickerKind::Tasks => {
                self.run_task(&item.id);
            }
            PickerKind::Branches => self.checkout_branch(&item.id),
            PickerKind::Worktrees => self.open_worktree_shell(&item.id),
            PickerKind::Locations => {
                let mut parts = item.id.split('\t');
                if let (Some(p), Some(l), Some(c)) = (parts.next(), parts.next(), parts.next()) {
                    let path = std::path::PathBuf::from(p);
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    self.open_path(&path);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
            PickerKind::CodeActions => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.apply_code_action(idx);
                }
            }
            PickerKind::RenamePreview => {
                let edits = self.pending_rename_preview.take();
                if item.id == "apply"
                    && let Some(edits) = edits
                {
                    self.apply_rename_edits(edits);
                } else {
                    self.toast("rename: cancelled");
                }
            }
            PickerKind::Symbols => {
                let mut parts = item.id.split('\t');
                if let (Some(l), Some(c)) = (parts.next(), parts.next()) {
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
            PickerKind::BrowserTargets => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_browser_target(idx);
                }
            }
            PickerKind::BrowserHistory => self.browser_navigate_to(&item.id),
            PickerKind::BrowserDevices => {
                if item.id == "reset" {
                    self.browser_clear_device();
                } else if let Ok(idx) = item.id.parse::<usize>() {
                    self.browser_set_device(idx);
                }
            }
            PickerKind::Snippets => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.snippet_insert_at_cursor(idx);
                }
            }
            PickerKind::Marks => {
                let mut parts = item.id.splitn(2, ':');
                if let (Some(scope), Some(letter_str)) = (parts.next(), parts.next())
                    && let Some(c) = letter_str.chars().next()
                {
                    match scope {
                        "local" => self.jump_to_mark(c, true),
                        "global" => self.jump_to_mark(c.to_ascii_uppercase(), true),
                        _ => {}
                    }
                }
            }
            PickerKind::FileHistory => self.open_commit_diff(&item.id),
            PickerKind::AiSessions => self.open_ai_session_mirror(&item.id),
            PickerKind::Clipboard => self.paste_register(&item.id),
            PickerKind::OpenPullRequests => {
                // First field of the `\x1F`-delimited id is the web URL.
                let url = item.id.split('\x1F').next().unwrap_or(&item.id);
                open_url_external(url);
            }
            PickerKind::Repos => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_active_repo(idx);
                }
            }
            PickerKind::Workspaces => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_workspace(idx);
                }
            }
            PickerKind::RemoveWorkspace => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.remove_workspace_runtime(idx);
                }
            }
            #[cfg(feature = "private")]
            PickerKind::the private integrationEnv => {
                self.run_private_tests_with_overrides(Some(item.id), None);
            }
            #[cfg(not(feature = "private"))]
            PickerKind::the private integrationEnv => {}
            #[cfg(feature = "private")]
            PickerKind::the private integrationBranch => {
                self.run_private_tests_with_overrides(None, Some(item.id));
            }
            #[cfg(not(feature = "private"))]
            PickerKind::the private integrationBranch => {}
            PickerKind::Tools => {
                // `id` is a `KNOWN_TOOLS[i].name`. Find the entry and
                // copy its install command to the clipboard.
                if let Some(tool) = crate::tools::KNOWN_TOOLS.iter().find(|t| t.name == item.id) {
                    self.clipboard.set(tool.install, false);
                    self.toast(format!("copied install: {}", tool.install));
                }
            }
            PickerKind::DapWatchRemove => {
                // `id` is the watch expression itself.
                let expr = item.id;
                self.dap_watches.retain(|w| w != &expr);
                self.dap_watch_results.remove(&expr);
                self.toast(format!("watch: − {expr}"));
            }
            PickerKind::DapAttach => {
                if let Ok(pid) = item.id.parse::<i64>() {
                    self.dap_attach_to_pid(pid);
                }
            }
            PickerKind::DapThread => {
                if let Ok(tid) = item.id.parse::<i64>() {
                    self.dap_switch_thread(tid);
                }
            }
            PickerKind::DapException => {
                self.dap_toggle_exception_filter(&item.id);
            }
            PickerKind::CallHierarchyItems => {
                // id = "<idx>\t<in|out>" — pull the picked item out of
                // the stash + fire the chosen-direction follow-up.
                let mut parts = item.id.splitn(2, '\t');
                let idx: usize = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                let dir = parts.next().unwrap_or("in");
                if let Some(picked) = self.pending_call_hierarchy_items.get(idx).cloned() {
                    match dir {
                        "out" => self.lsp.call_hierarchy_outgoing(&picked),
                        _ => self.lsp.call_hierarchy_incoming(&picked),
                    }
                    // Replace the stash with just the picked item so a
                    // future opposite-direction re-fire skips prepare.
                    self.pending_call_hierarchy_items = vec![picked];
                }
            }
            PickerKind::GitTags => {
                let name = item.id;
                match crate::git::tag::delete_local(self.active_repo_path(), &name) {
                    Ok(summary) => {
                        self.after_git_change();
                        self.refresh_active_git_graph();
                        self.toast(summary);
                    }
                    Err(e) => self.toast(format!("git tag -d: {e}")),
                }
            }
            PickerKind::StashesApply => {
                let stash_ref = item.id;
                match crate::git::stash::apply(self.active_repo_path(), &stash_ref) {
                    Ok(summary) => {
                        self.after_git_change();
                        self.tree.refresh();
                        self.toast(summary);
                    }
                    Err(e) => self.toast(format!("git stash apply: {e}")),
                }
            }
            PickerKind::StashesDrop => {
                let stash_ref = item.id;
                match crate::git::stash::drop_stash(self.active_repo_path(), &stash_ref) {
                    Ok(summary) => self.toast(summary),
                    Err(e) => self.toast(format!("git stash drop: {e}")),
                }
            }
            PickerKind::Reflog => {
                // `id` is the full hash — open it as a commit-diff pane.
                self.open_commit_diff(&item.id);
            }
            PickerKind::GitGraphBranchFilter => {
                self.apply_git_graph_branch_filter(if item.id == "--all" {
                    None
                } else {
                    Some(item.id.clone())
                });
            }
            PickerKind::SuggestBackend => {
                let id = item.id.clone();
                self.accept_suggest_backend(&id);
            }
        }
    }

    /// Open a fuzzy picker over the repos discovered in the workspace.
    /// Accept ⇒ [`Self::switch_active_repo`]. No-op when there's only one
    /// repo or none.
    pub fn open_repo_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.repos.len() <= 1 {
            self.toast("only one repo in this workspace");
            return;
        }
        let items: Vec<PickerItem> = self
            .repos
            .iter()
            .enumerate()
            .map(|(i, r)| {
                let active_marker = if i == self.active_repo { "● " } else { "  " };
                let label = format!("{active_marker}{}", r.name);
                let detail = r
                    .path
                    .strip_prefix(&self.workspace)
                    .ok()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_else(|| r.path.to_string_lossy().into_owned());
                PickerItem::new(i.to_string(), label, detail)
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Repos, "Switch repo", items));
    }

    /// Picker over the primary + every configured extra workspace. Accept ⇒
    /// `switch_workspace(idx)` — for the primary that just refocuses the
    /// rail; for an extra it expands that section + collapses others. No-op
    /// when no extras are configured.
    pub fn open_workspace_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.extra_workspaces.is_empty() {
            self.toast("no extra workspaces — add `[[workspaces]]` to config.toml");
            return;
        }
        let primary_name = self
            .workspace
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("workspace")
            .to_string();
        let mut items: Vec<PickerItem> = Vec::with_capacity(self.extra_workspaces.len() + 1);
        items.push(PickerItem::new(
            "0".to_string(),
            format!("● {primary_name}"),
            self.workspace.to_string_lossy().into_owned(),
        ));
        for (i, w) in self.extra_workspaces.iter().enumerate() {
            let marker = if w.expanded { "● " } else { "  " };
            items.push(PickerItem::new(
                (i + 1).to_string(),
                format!("{marker}{}", w.name),
                w.root.to_string_lossy().into_owned(),
            ));
        }
        self.open_picker(Picker::new(
            PickerKind::Workspaces,
            "Switch workspace",
            items,
        ));
    }

    /// Picker over removable (extra) workspaces. Accept ⇒
    /// [`Self::remove_workspace_runtime`].
    pub fn open_remove_workspace_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.extra_workspaces.is_empty() {
            self.toast("no extra workspaces to remove");
            return;
        }
        let items: Vec<PickerItem> = self
            .extra_workspaces
            .iter()
            .enumerate()
            .map(|(i, w)| {
                PickerItem::new(
                    (i + 1).to_string(),
                    w.name.clone(),
                    w.root.to_string_lossy().into_owned(),
                )
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::RemoveWorkspace,
            "Remove workspace",
            items,
        ));
    }

    /// `task.run` — open a picker over `[tasks.<name>]` config entries.
    pub fn open_task_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.config.tasks.is_empty() {
            self.toast("no [tasks.*] defined in config".to_string());
            return;
        }
        let items: Vec<PickerItem> = self
            .config
            .tasks
            .iter()
            .map(|(name, t)| PickerItem::new(name.clone(), name.clone(), t.cmd.clone()))
            .collect();
        self.open_picker(Picker::new(PickerKind::Tasks, "Run task", items));
    }

    /// `picker.recent_commands` — fuzzy picker over the most-recently-
    /// run commands (newest first). Distinct from `palette` (alphabetical
    /// over all builtins + dynamic).
    pub fn open_recent_commands_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.recent_commands.is_empty() {
            self.toast("no recent commands yet");
            return;
        }
        let items: Vec<PickerItem> = self
            .recent_commands
            .iter()
            .filter_map(|id| {
                crate::command::registry().get(id).map(|cmd| {
                    PickerItem::new(
                        cmd.id,
                        format!("{}  ·  {}", cmd.group, cmd.title),
                        cmd.key_hint(),
                    )
                })
            })
            .collect();
        if items.is_empty() {
            self.toast("no recent commands resolvable");
            return;
        }
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Commands,
            "Recent commands",
            items,
        ));
    }

    /// `picker.clipboard` — pick from the named-register history
    /// (`"a`-`"z`, `"0` last yank, `"1`-`"9` delete history) and paste
    /// the chosen entry at the cursor. Useful for "pull back something I
    /// deleted three operations ago" without remembering its register.
    pub fn open_clipboard_picker(&mut self) {
        let registers = self.clipboard.named_registers();
        if registers.is_empty() {
            self.toast("clipboard: no register history");
            return;
        }
        let mut entries: Vec<(char, String, bool)> = registers
            .iter()
            .map(|(c, (t, lw))| (*c, t.clone(), *lw))
            .filter(|(_, t, _)| !t.is_empty())
            .collect();
        // Show numeric registers in ascending order (0..=9), then a..z.
        entries.sort_by(|a, b| {
            let key = |c: char| match c {
                '0'..='9' => (0u8, c),
                _ => (1, c),
            };
            key(a.0).cmp(&key(b.0))
        });
        let items: Vec<crate::picker::PickerItem> = entries
            .into_iter()
            .map(|(reg, text, linewise)| {
                let mut preview: String = text.replace('\n', "↵");
                let n_chars = preview.chars().count();
                if n_chars > 80 {
                    preview = preview.chars().take(80).collect::<String>() + "…";
                }
                let detail = if linewise { "linewise" } else { "" };
                crate::picker::PickerItem::new(
                    reg.to_string(),
                    format!("\"{reg}  {preview}"),
                    detail.to_string(),
                )
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Clipboard,
            "Clipboard / registers",
            items,
        ));
    }

    /// `git.file_history` — fuzzy picker over commits that touched the active
    /// file (`git log --follow`, capped at 200). Accept opens a diff pane for
    /// the chosen commit.
    pub fn open_file_history_picker(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("file history needs a saved file");
            return;
        };
        let repo = self.active_repo_path().to_path_buf();
        let rel = match path.strip_prefix(&repo) {
            Ok(r) => r.to_string_lossy().to_string(),
            Err(_) => {
                self.toast("file is outside the active git repo");
                return;
            }
        };
        let commits = crate::git::log::commits_for_file(&repo, &rel);
        if commits.is_empty() {
            self.toast("no commits touched this file");
            return;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let items: Vec<crate::picker::PickerItem> = commits
            .into_iter()
            .map(|c| {
                let age = crate::ui::git_graph_view::humanize_age(now.saturating_sub(c.time));
                crate::picker::PickerItem::new(
                    c.hash,
                    format!("{}  {}", c.short, c.subject),
                    format!("{age} · {}", c.author),
                )
            })
            .collect();
        let title = format!("File history — {rel}");
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::FileHistory,
            title,
            items,
        ));
    }

    /// `git.tag_delete` — open a picker over every local tag (newest-creation
    /// first). Accept ⇒ `git tag -d <name>`. No confirmation step — tags are
    /// cheap to re-create.
    pub fn open_git_tag_delete_picker(&mut self) {
        let tags = crate::git::tag::list(self.active_repo_path());
        if tags.is_empty() {
            self.toast("git tag: no local tags");
            return;
        }
        let items: Vec<crate::picker::PickerItem> = tags
            .iter()
            .map(|name| crate::picker::PickerItem::new(name, name, "delete"))
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::GitTags,
            format!("Delete tag ({} local)", tags.len()),
            items,
        ));
    }

    pub fn prompt_cancel(&mut self) {
        // Esc-cancel on a Find prompt restores the editor's prior find state
        // (incremental preview is dropped).
        let kind = self.prompt.as_ref().map(|p| p.kind);
        let was_find = matches!(kind, Some(crate::prompt::PromptKind::Find));
        // Esc on a tool-confirm prompt means "deny" — the blocked agent
        // worker is waiting for an answer.
        if matches!(kind, Some(crate::prompt::PromptKind::AiToolConfirm)) {
            self.resolve_tool_confirm(false);
        }
        self.prompt = None;
        self.pending_rename = None;
        self.pending_fs_action = None;
        self.pending_delete_branch = None;
        self.pending_worktree_remove = None;
        self.pending_branch_source = None;
        self.rename_preview_state = None;
        if was_find {
            self.restore_find_preview_snapshot();
            self.find_pending_range = None;
        }
    }

    pub fn prompt_accept(&mut self) {
        let Some(p) = self.prompt.take() else { return };
        match p.kind {
            crate::prompt::PromptKind::AddWorkspace => {
                let input = p.input.trim();
                if input.is_empty() {
                    return;
                }
                // Tilde-expand `~/...`.
                let path = if let Some(rest) = input.strip_prefix("~/") {
                    if let Some(home) = std::env::var_os("HOME") {
                        PathBuf::from(home).join(rest)
                    } else {
                        PathBuf::from(input)
                    }
                } else {
                    PathBuf::from(input)
                };
                self.add_workspace_runtime(path, None);
            }
            crate::prompt::PromptKind::GitCommit => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("commit cancelled (empty message)");
                    return;
                }
                match crate::git::commit::commit(self.active_repo_path(), msg) {
                    Ok(summary) => {
                        self.toast(summary);
                        self.note_commit_for_undo();
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit: {e}")),
                }
            }
            crate::prompt::PromptKind::GitCommitAmend => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("amend cancelled (empty message)");
                    return;
                }
                match crate::git::commit::amend(self.active_repo_path(), msg) {
                    Ok(summary) => {
                        self.toast(format!("amended: {summary}"));
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit --amend: {e}")),
                }
            }
            crate::prompt::PromptKind::GitStashMessage => {
                let msg = p.input.trim();
                let msg_opt = if msg.is_empty() { None } else { Some(msg) };
                self.run_git_stash_push(msg_opt);
            }
            crate::prompt::PromptKind::GitTag => {
                let name = p.input.trim().to_string();
                if name.is_empty() {
                    self.toast("tag cancelled (empty name)");
                    return;
                }
                let target = self.selected_graph_commit_hash();
                match crate::git::tag::create_annotated(
                    self.active_repo_path(),
                    &name,
                    &name,
                    target.as_deref(),
                ) {
                    Ok(summary) => {
                        self.after_git_change();
                        self.refresh_active_git_graph();
                        self.toast(summary);
                    }
                    Err(e) => self.toast(format!("git tag: {e}")),
                }
            }
            crate::prompt::PromptKind::DapAddWatch => {
                let expr = p.input.trim().to_string();
                if expr.is_empty() {
                    return;
                }
                if !self.dap_watches.iter().any(|w| w == &expr) {
                    self.dap_watches.push(expr.clone());
                }
                // Fire an immediate `evaluate` if we're stopped at a
                // breakpoint so the row populates without waiting for
                // the next stop. No-op when no session is active.
                let frame_id = self
                    .dap
                    .as_ref()
                    .and_then(|m| m.stack_frames.first().map(|f| f.id));
                if let (Some(mgr), Some(fid)) = (self.dap.as_mut(), frame_id) {
                    let _ = mgr.client.evaluate(&expr, Some(fid), "watch");
                }
                self.toast(format!("watch: + {expr}"));
            }
            crate::prompt::PromptKind::DapBreakpointCondition => {
                let cond = p.input.trim().to_string();
                let pending = self.dap_pending_bp_condition.take();
                let Some((line0, path)) = pending else {
                    return;
                };
                self.set_breakpoint_condition(&path, line0, cond);
            }
            crate::prompt::PromptKind::DapBreakpointHitCount => {
                let hit = p.input.trim().to_string();
                let pending = self.dap_pending_bp_condition.take();
                let Some((line0, path)) = pending else {
                    return;
                };
                self.set_breakpoint_hit_condition(&path, line0, hit);
            }
            crate::prompt::PromptKind::DapSetVariable => {
                let new_value = p.input.clone();
                let Some((parent_ref, name)) = self.dap_pending_set_variable.take() else {
                    return;
                };
                let Some(mgr) = self.dap.as_mut() else {
                    self.toast("dap: no session");
                    return;
                };
                if let Err(e) = mgr.client.set_variable(parent_ref, &name, &new_value) {
                    self.toast(format!("dap setVariable: {e}"));
                }
            }
            crate::prompt::PromptKind::AiAsk => {
                let q = p.input.trim();
                if q.is_empty() {
                    return;
                }
                let short: String = q.chars().take(24).collect();
                let ellip = if q.chars().count() > 24 { "…" } else { "" };
                self.ask_ai(format!("AI: {short}{ellip}"), q.to_string());
            }
            crate::prompt::PromptKind::NewBranch => {
                let name = p.input.clone();
                self.create_branch(&name);
            }
            crate::prompt::PromptKind::LspRename => {
                let new_name = p.input.trim().to_string();
                // Clear the preview before either path returns — keeps the
                // overlay from leaking past the accept moment.
                self.rename_preview_state = None;
                let Some((path, line, ch)) = self.pending_rename.take() else {
                    return;
                };
                if new_name.is_empty() {
                    self.toast("rename cancelled (empty name)");
                    return;
                }
                // Sync the buffer's current text so the server's positions line up.
                let text = self.panes.iter().find_map(|p| match p {
                    Pane::Editor(b) if b.is_at(&path) => Some(b.editor.text().to_string()),
                    _ => None,
                });
                if let Some(t) = text {
                    self.lsp.did_change(&path, &t);
                }
                if !self.lsp.rename(&path, line, ch, &new_name) {
                    self.toast("no language server for this file (rename)");
                }
            }
            crate::prompt::PromptKind::BrowserUrl => self.open_browser(p.input.trim()),
            crate::prompt::PromptKind::BrowserNavigate => {
                let url = p.input.clone();
                if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    b.navigate(&url);
                }
            }
            crate::prompt::PromptKind::BrowserCookieEdit => {
                self.accept_cookie_edit(p.input.clone())
            }
            crate::prompt::PromptKind::BrowserCookieAdd => self.accept_cookie_add(p.input.clone()),
            crate::prompt::PromptKind::BrowserStorageEdit => {
                self.accept_storage_edit(p.input.clone())
            }
            crate::prompt::PromptKind::BrowserStorageAdd => {
                self.accept_storage_add(p.input.clone())
            }
            crate::prompt::PromptKind::BrowserEval => {
                let expr = p.input.clone();
                if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    b.eval(&expr);
                }
            }
            crate::prompt::PromptKind::Find => {
                let q = p.input.clone();
                // Live-preview is the new find state already; commit it.
                self.find_preview_snapshot = None;
                self.accept_find(q);
            }
            crate::prompt::PromptKind::Replace => {
                let r = p.input.clone();
                self.accept_replace(r);
            }
            crate::prompt::PromptKind::Grep => {
                let q = p.input.clone();
                self.run_workspace_grep(q);
            }
            crate::prompt::PromptKind::GrepReplace => {
                let r = p.input.clone();
                self.run_grep_replace(r);
            }
            crate::prompt::PromptKind::GotoLine => {
                let s = p.input.trim().to_string();
                self.goto_line_str(&s);
            }
            crate::prompt::PromptKind::NewFile => {
                let name = p.input.clone();
                if let Some(FsAction::NewFile { parent }) = self.pending_fs_action.take() {
                    self.create_new_file(&parent, &name);
                }
            }
            crate::prompt::PromptKind::NewFolder => {
                let name = p.input.clone();
                if let Some(FsAction::NewFolder { parent }) = self.pending_fs_action.take() {
                    self.create_new_folder(&parent, &name);
                }
            }
            crate::prompt::PromptKind::Rename => {
                let name = p.input.clone();
                if let Some(FsAction::Rename { path }) = self.pending_fs_action.take() {
                    self.rename_fs_entry(&path, &name);
                }
            }
            crate::prompt::PromptKind::DeleteConfirm => {
                let typed = p.input.clone();
                if let Some(FsAction::Delete { path }) = self.pending_fs_action.take() {
                    self.confirm_delete_fs_entry(&path, &typed);
                }
            }
            crate::prompt::PromptKind::GitDeleteBranch => {
                self.confirm_delete_branch(p.input.clone());
            }
            crate::prompt::PromptKind::GitWorktreeRemove => {
                self.confirm_worktree_remove(p.input.clone());
            }
            crate::prompt::PromptKind::LspWorkspaceSymbol => {
                let q = p.input.clone();
                self.run_workspace_symbol_query(&q);
            }
            crate::prompt::PromptKind::DiffDiscardHunk => {
                let typed = p.input.clone();
                self.accept_discard_hunk(&typed);
            }
            crate::prompt::PromptKind::GitDiscardFile => {
                let typed = p.input.clone();
                self.accept_discard_file(&typed);
            }
            crate::prompt::PromptKind::GitGraphDateFilter => {
                let typed = p.input.clone();
                self.apply_git_graph_date_filter(&typed);
            }
            crate::prompt::PromptKind::GitGraphAuthorFilter => {
                let typed = p.input.clone();
                self.apply_git_graph_author_filter(&typed);
            }
            crate::prompt::PromptKind::GitGraphGrepFilter => {
                let typed = p.input.clone();
                self.apply_git_graph_grep_filter(&typed);
            }
            crate::prompt::PromptKind::TreeMoveConfirm => {
                self.accept_tree_move();
            }
            crate::prompt::PromptKind::QuitConfirm => {
                self.accept_quit();
            }
            crate::prompt::PromptKind::AiToolConfirm => {
                self.resolve_tool_confirm(true);
            }
            crate::prompt::PromptKind::AiChat => {
                let typed = p.input.clone();
                self.dispatch_ai_chat(&typed);
            }
            crate::prompt::PromptKind::PtySessionName => {
                let typed = p.input.clone();
                self.rename_active_pty(&typed);
            }
        }
    }
}

#[cfg(test)]
mod picker_tests {
    use super::*;

    #[test]
    fn open_pr_picker_aggregates_all_hosts_sorted_by_updated() {
        // Seed one PR per host in `App`'s per-host caches, fire the picker,
        // and check it lists all 4 + sorts the most-recently-updated first.
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // BB — oldest update.
        app.bitbucket_pull_requests.insert(
            ("exampleorg".into(), "example-api".into()),
            vec![crate::bitbucket::PullRequestRecord {
                workspace: "exampleorg".into(),
                slug: "example-api".into(),
                id: 42,
                title: "BB fix thing".into(),
                state: crate::bitbucket::PullRequestState::Open,
                author: Some("alice".into()),
                source_branch: Some("feature/bb".into()),
                dest_branch: Some("main".into()),
                reviewer_count: 2,
                approved_count: 1,
                changes_count: 0,
                comment_count: 3,
                task_count: 0,
                created_on_ms: Some(1_000),
                updated_on_ms: Some(1_000),
                web_url: "https://bitbucket.org/exampleorg/example-api/pull-requests/42".into(),
            }],
        );
        // GH — middle update.
        app.github_pull_requests.insert(
            ("private-org".into(), "repo".into()),
            vec![crate::github::PullRequestRecord {
                owner: "private-org".into(),
                repo: "repo".into(),
                number: 7,
                title: "GH refactor".into(),
                state: crate::github::PullRequestState::Open,
                author: Some("bob".into()),
                source_branch: Some("feature/gh".into()),
                dest_branch: Some("main".into()),
                reviewer_count: 1,
                approved_count: 0,
                changes_count: 1,
                comment_count: 2,
                review_comment_count: 4,
                created_at_ms: Some(2_000),
                updated_at_ms: Some(2_000),
                web_url: "https://github.com/private-org/repo/pull/7".into(),
            }],
        );
        // GL — newest update.
        app.gitlab_merge_requests.insert(
            "group/project".into(),
            vec![crate::gitlab::MergeRequestRecord {
                project: "group/project".into(),
                iid: 17,
                title: "GL feature".into(),
                state: crate::gitlab::MergeRequestState::Opened,
                author: Some("carol".into()),
                source_branch: Some("feature/gl".into()),
                dest_branch: Some("main".into()),
                reviewer_count: 3,
                approved_count: 2,
                changes_count: 0,
                comment_count: 0,
                created_at_ms: Some(3_000),
                updated_at_ms: Some(4_000),
                web_url: "https://gitlab.com/group/project/-/merge_requests/17".into(),
            }],
        );
        // AZ — second-newest (created-only).
        app.azdevops_pull_requests.insert(
            "org/project/repo".into(),
            vec![crate::azdevops::PullRequestRecord {
                label: "org/project/repo".into(),
                id: 99,
                title: "AZ chore".into(),
                state: crate::azdevops::PullRequestState::Active,
                author: Some("dave".into()),
                source_branch: Some("feature/az".into()),
                dest_branch: Some("main".into()),
                reviewer_count: 1,
                approved_count: 0,
                changes_count: 0,
                comment_count: 0,
                created_at_ms: Some(3_500),
                web_url: "https://dev.azure.com/org/project/_git/repo/pullrequest/99".into(),
            }],
        );
        app.open_pr_picker();
        let picker = app.picker.as_ref().expect("picker should have opened");
        assert_eq!(picker.kind, crate::picker::PickerKind::OpenPullRequests);
        let labels: Vec<String> = picker.items_view().map(|it| it.label.clone()).collect();
        assert_eq!(labels.len(), 4, "all four hosts represented");
        // Most-recently-updated first: GL (4000) > AZ (3500) > GH (2000) > BB (1000).
        assert!(labels[0].contains("[GL]"), "GL first, got {:?}", labels[0]);
        assert!(labels[1].contains("[AZ]"), "AZ second, got {:?}", labels[1]);
        assert!(labels[2].contains("[GH]"), "GH third, got {:?}", labels[2]);
        assert!(labels[3].contains("[BB]"), "BB fourth, got {:?}", labels[3]);
        // The id encodes URL + cross-nav payload (delimited by `\x1F`).
        // First field is the URL.
        let ids: Vec<String> = picker.items_view().map(|it| it.id.clone()).collect();
        let first_url = ids[0].split('\x1F').next().unwrap_or("");
        assert!(first_url.starts_with("https://gitlab.com/"));
        // Subsequent fields encode host_tag, repo_label, source_branch
        // for Tab → cross-nav-to-pipeline.
        let parts: Vec<&str> = ids[0].split('\x1F').collect();
        assert_eq!(parts.len(), 4, "id should have 4 \\x1F-delimited fields");
        assert_eq!(parts[1], "GL");
        assert_eq!(parts[2], "group/project");
        assert_eq!(parts[3], "feature/gl");
        // Fuzzy match shrinks to one host (label contains "private-org" and "refactor").
        let mut picker = app.picker.take().unwrap();
        for c in "refactor".chars() {
            picker.type_char(c);
        }
        assert_eq!(picker.len(), 1, "fuzzy 'refactor' narrows to GH only");
    }

    #[test]
    fn picker_accept_secondary_cross_navs_pr_to_pipeline() {
        // Set up: BB repo with a PR + a matching pipeline on the same branch.
        // Open the cross-host PR picker, Tab on the row → pipelines pane
        // opens, selection lands on the matching pipeline.
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.bitbucket.repos = vec![crate::config::BitbucketRepo {
            workspace: "exampleorg".into(),
            slug: "example-api".into(),
            branches: Vec::new(),
        }];
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.bitbucket_pipelines.insert(
            ("exampleorg".into(), "example-api".into()),
            vec![crate::bitbucket::PipelineRecord {
                workspace: "exampleorg".into(),
                slug: "example-api".into(),
                uuid: "uuid-99".into(),
                build_number: 99,
                state: crate::bitbucket::PipelineState::Successful,
                target_ref: Some("feature/cross".into()),
                target_kind: Some("BRANCH".into()),
                commit_hash: None,
                creator: None,
                trigger: None,
                created_on_ms: Some(0),
                completed_on_ms: None,
                duration_secs: None,
                running_step: None,
                web_url: "u".into(),
            }],
        );
        app.bitbucket_pull_requests.insert(
            ("exampleorg".into(), "example-api".into()),
            vec![crate::bitbucket::PullRequestRecord {
                workspace: "exampleorg".into(),
                slug: "example-api".into(),
                id: 1,
                title: "Cross-nav PR".into(),
                state: crate::bitbucket::PullRequestState::Open,
                author: None,
                source_branch: Some("feature/cross".into()),
                dest_branch: Some("main".into()),
                reviewer_count: 0,
                approved_count: 0,
                changes_count: 0,
                comment_count: 0,
                task_count: 0,
                created_on_ms: Some(0),
                updated_on_ms: Some(0),
                web_url: "https://bitbucket.org/...".into(),
            }],
        );
        app.open_pr_picker();
        assert!(app.picker.is_some(), "picker should be open");
        // Picker has only the one PR — selection is already at idx 0.
        app.picker_accept_secondary();
        // Picker should now be closed.
        assert!(app.picker.is_none(), "picker should close after Tab");
        // Active pane should be the BB pipelines pane.
        let active = app.active.expect("active pane");
        assert!(
            matches!(app.panes.get(active), Some(Pane::BitbucketPipelines(_))),
            "active should be BB pipelines pane after cross-nav"
        );
    }

    #[test]
    fn open_repo_picker_no_op_when_single() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join(".git")).unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_repo_picker();
        // Only one repo ⇒ no picker.
        assert!(app.picker.is_none());
    }

    #[test]
    fn open_pr_picker_empty_toasts_and_does_not_open() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_pr_picker();
        assert!(
            app.picker.is_none(),
            "picker should NOT open when every cache is empty"
        );
    }
}
