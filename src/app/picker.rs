//! Picker + prompt accept dispatchers + picker openers.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move.

use super::*;

impl App {
    pub fn open_picker(&mut self, picker: Picker) {
        self.whichkey = None;
        // #1229 (user report) — dismiss an open MENU too.
        //
        // "if i have file menu open and then ctrl ; to type a command i
        // see the command panel but cant type as focus still on the file
        // menu i had open." The menu owns keys while it is open, so the
        // palette appeared and then swallowed nothing: every keystroke
        // went to the File menu behind it.
        //
        // Fixed here rather than in `open_command_palette` because this is
        // the single chokepoint every picker goes through (72 callers), so
        // the file picker, bookmarks, reflog and the rest all inherit it.
        // `open_command_palette` already dismissed `prompt` for exactly
        // this reason (R9 vscode-keyboard SEV-3) — the menu was the same
        // bug with a different overlay, missed because the fix was applied
        // one caller deep instead of at the chokepoint.
        self.menu_open = None;
        // 2026-06-20 — themes picker captures the pre-preview theme
        // so Esc restores it. set when the kind is Themes; cleared on
        // accept or restored on close.
        if matches!(picker.kind, crate::picker::PickerKind::Themes) {
            self.theme_preview_restore = Some(crate::ui::theme::cur().name.to_string());
        }
        self.picker = Some(picker);
    }

    /// Picker Up/Down hook — used for kind-specific previews. For
    /// the Themes picker, applies the highlighted theme live so
    /// the user can see it before committing.
    pub fn on_picker_moved(&mut self) {
        let Some(p) = self.picker.as_ref() else {
            return;
        };
        if !matches!(p.kind, crate::picker::PickerKind::Themes) {
            return;
        }
        let name = match p.selected_item() {
            Some(it) => it.id.clone(),
            None => return,
        };
        let _ = self.set_theme_silent(&name);
    }

    pub fn close_picker(&mut self) {
        // 2026-06-19 — api-workflow-user agent flagged that Esc
        // on a lookup-stage picker left `lookup_fire_rx` armed;
        // when the response landed, `App::tick`'s drain popped a
        // ghost LookupItem picker over whatever the user was now
        // doing. Drop the receiver here so the worker's send is
        // silently discarded.
        if matches!(
            self.picker.as_ref().map(|p| p.kind),
            Some(crate::picker::PickerKind::LookupFile)
                | Some(crate::picker::PickerKind::LookupItem)
        ) {
            self.lookup_fire_rx = None;
            self.pending_lookup_items.clear();
            self.pending_lookup_picked_id = None;
        }
        // 2026-06-21 — api-workflow SEV-1: `pending_history_rows`
        // is shared between :http.history (workspace) and
        // :http.history_global (cross-workspace). Esc on one and
        // opening the other left stale rows in the shared Vec,
        // so picker-index resolution at accept time pointed into
        // the wrong snapshot — either silently returning the
        // wrong workspace's curl or hitting `None` for high
        // indexes. Clear it on close so the next opener owns it.
        if matches!(
            self.picker.as_ref().map(|p| p.kind),
            Some(crate::picker::PickerKind::HistoryRows)
        ) {
            self.pending_history_rows.clear();
        }
        // Themes picker: if Esc-closed (no accept), restore the
        // pre-preview theme. Clear the snapshot either way.
        if matches!(
            self.picker.as_ref().map(|p| p.kind),
            Some(crate::picker::PickerKind::Themes)
        ) && let Some(orig) = self.theme_preview_restore.take()
        {
            let _ = self.set_theme_silent(&orig);
        }
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
        // vscode-user SEV-3 — VS Code's Ctrl+P excludes .git, node_modules,
        // target by default via files.exclude. Mirror that so the picker
        // doesn't surface .git/HEAD, build artifacts, etc.
        let is_noise = |path: &std::path::Path| -> bool {
            for component in path.components() {
                if let std::path::Component::Normal(name) = component {
                    let s = name.to_string_lossy();
                    // R9 vscode-keyboard SEV-3 — `.mnml/` is mnml's own
                    // per-workspace state dir (session.json, undo/,
                    // findings/, ipc/, cookies.json). Never useful in
                    // Ctrl+P; drowns real files when a session's
                    // accumulated hundreds of undo snapshots.
                    if matches!(
                        s.as_ref(),
                        ".git" | ".mnml" | "node_modules" | "target" | ".next" | "dist" | "build"
                    ) {
                        return true;
                    }
                }
            }
            false
        };
        let make_item = |p: &Path| -> PickerItem {
            // In-workspace: label is the workspace-relative path
            // (no leading slash), detail is the relative parent dir.
            // Outside-workspace (recent file from another workspace):
            // label is the file_name only, detail is the absolute
            // parent dir so the user can still see WHERE it lives.
            // vscode-user-keyboard SEV-3 — was showing the full
            // absolute path as label, leading to visual doubling
            // when the renderer also appended `detail`.
            match p.strip_prefix(&root) {
                Ok(rel) => {
                    let label = rel.to_string_lossy().to_string();
                    let dir = rel
                        .parent()
                        .map(|d| d.to_string_lossy().to_string())
                        .unwrap_or_default();
                    PickerItem::new(p.to_string_lossy().to_string(), label, dir)
                }
                Err(_) => {
                    let label = p
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| p.to_string_lossy().to_string());
                    let dir = p
                        .parent()
                        .map(|d| d.to_string_lossy().to_string())
                        .unwrap_or_default();
                    PickerItem::new(p.to_string_lossy().to_string(), label, dir)
                }
            }
        };
        // vscode-user 2026-06-28 SEV-3 / 3rd 2026-06-29 SEV-2:
        // Ctrl+P workspace affinity. The original fix only ordered
        // the source list — the fuzzy scorer then re-ranked items
        // by score, and shorter cross-workspace labels (`lib.rs`)
        // beat longer local labels (`src/lib.rs`). Now we tag
        // items with `priority`: 2 = current-workspace, 1 = cross-
        // workspace recent, 0 = extra-workspace tree. `refilter`
        // sorts (priority desc, score desc, index asc) so the
        // higher priority always wins.
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut items: Vec<PickerItem> = Vec::new();
        let workspace = self.workspace.clone();
        for p in &self.recent_files {
            if p.starts_with(&workspace) && seen.insert(p.clone()) && p.exists() && !is_noise(p) {
                items.push(make_item(p).with_priority(2));
            }
        }
        for p in self.tree.all_files() {
            if !is_noise(&p) && seen.insert(p.clone()) {
                items.push(make_item(&p).with_priority(2));
            }
        }
        for p in &self.recent_files {
            if seen.insert(p.clone()) && p.exists() && !is_noise(p) {
                items.push(make_item(p).with_priority(1));
            }
        }
        // #polish 2026-07-07 (vscode-user SEV-2 #2) — do NOT scan the
        // extra_workspaces. Was: files from every registered
        // `[[workspaces]]` entry showed up in Ctrl+P, drowning the
        // active workspace's 6 files under thousands of unrelated
        // hits (tester saw `3373 of 22783 matching`). VS Code's
        // Ctrl+P is scoped to the current workspace root; mirror
        // that. `picker.workspaces` remains the way to jump to
        // another workspace root.
        self.open_picker(Picker::new(PickerKind::Files, "Open file", items));
    }

    /// Fuzzy picker over `.svg` files reachable from mnml — the
    /// active workspace tree PLUS every extra workspace, common
    /// mnml source-tree locations under `~/Projects/mnml*/` (so a
    /// user driving from a integration workspace can still pick the
    /// shipped SVGs), plus `~/Downloads` and `~/Desktop` for
    /// ad-hoc imports. 2026-07-19 — first version was scoped to
    /// just `self.workspace` and turned up 0 matches when the
    /// user was in a workspace whose tree had no SVGs.
    pub fn open_glyph_builder_svg_picker(&mut self) {
        use crate::picker::{PickerItem, PickerKind};
        use std::collections::HashSet;
        let is_svg = |p: &Path| -> bool {
            p.extension()
                .and_then(|s| s.to_str())
                .is_some_and(|s| s.eq_ignore_ascii_case("svg"))
        };
        let is_noise = |path: &Path| -> bool {
            for component in path.components() {
                if let std::path::Component::Normal(name) = component {
                    let s = name.to_string_lossy();
                    if matches!(
                        s.as_ref(),
                        ".git" | "node_modules" | "target" | ".next" | "dist" | "build" | ".cache"
                    ) {
                        return true;
                    }
                }
            }
            false
        };
        // Bounded recursive walker — cap at MAX_DEPTH so we don't
        // wander into massive `~/Projects/somebody/node_modules`
        // trees. Depth 6 is enough to reach anything a user would
        // reasonably want.
        const MAX_DEPTH: usize = 6;
        fn walk(root: &Path, max_depth: usize, sink: &mut Vec<PathBuf>) {
            fn rec(
                dir: &Path,
                depth_left: usize,
                sink: &mut Vec<PathBuf>,
                is_noise: &dyn Fn(&Path) -> bool,
            ) {
                if depth_left == 0 {
                    return;
                }
                let Ok(rd) = std::fs::read_dir(dir) else {
                    return;
                };
                for entry in rd.flatten() {
                    let path = entry.path();
                    if is_noise(&path) {
                        continue;
                    }
                    if path.is_dir() {
                        rec(&path, depth_left - 1, sink, is_noise);
                    } else {
                        sink.push(path);
                    }
                }
            }
            rec(root, max_depth, sink, &|p| {
                for component in p.components() {
                    if let std::path::Component::Normal(name) = component {
                        let s = name.to_string_lossy();
                        if matches!(
                            s.as_ref(),
                            ".git"
                                | "node_modules"
                                | "target"
                                | ".next"
                                | "dist"
                                | "build"
                                | ".cache"
                        ) {
                            return true;
                        }
                    }
                }
                false
            });
        }
        let workspace = self.workspace.clone();
        let make_item = |p: &Path| -> PickerItem {
            let (label, detail) = match p.strip_prefix(&workspace) {
                Ok(rel) => (
                    rel.to_string_lossy().to_string(),
                    rel.parent()
                        .map(|d| d.to_string_lossy().to_string())
                        .unwrap_or_default(),
                ),
                Err(_) => (
                    p.file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| p.to_string_lossy().to_string()),
                    p.parent()
                        .map(|d| d.to_string_lossy().to_string())
                        .unwrap_or_default(),
                ),
            };
            PickerItem::new(p.to_string_lossy().to_string(), label, detail)
        };
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut items: Vec<PickerItem> = Vec::new();
        let add = |p: PathBuf, items: &mut Vec<PickerItem>, seen: &mut HashSet<PathBuf>| {
            if is_svg(&p) && !is_noise(&p) && seen.insert(p.clone()) && p.exists() {
                items.push(make_item(&p));
            }
        };
        // 1. Active workspace tree (fast — already indexed).
        for p in self.tree.all_files() {
            add(p, &mut items, &mut seen);
        }
        // 2. Extra workspace roots — walk each fresh.
        for ws in &self.extra_workspaces {
            let mut buf = Vec::new();
            walk(&ws.root, MAX_DEPTH, &mut buf);
            for p in buf {
                add(p, &mut items, &mut seen);
            }
        }
        // 3. Common mnml source-tree locations. Catches SVGs shipped
        //    with mnml or in a integration worktree when the user's
        //    active workspace is unrelated.
        if let Some(home) = std::env::var_os("HOME") {
            let projects = PathBuf::from(home).join("Projects");
            if let Ok(rd) = std::fs::read_dir(&projects) {
                for entry in rd.flatten() {
                    let name = entry.file_name();
                    let name_str = name.to_string_lossy();
                    if !name_str.starts_with("mnml") {
                        continue;
                    }
                    let root = entry.path();
                    for sub in &["assets/glyphs", "scripts/glyphs"] {
                        let dir = root.join(sub);
                        if dir.exists() {
                            let mut buf = Vec::new();
                            walk(&dir, 4, &mut buf);
                            for p in buf {
                                add(p, &mut items, &mut seen);
                            }
                        }
                    }
                }
            }
            // 4. Downloads / Desktop for ad-hoc imports.
            let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            for sub in &["Downloads", "Desktop"] {
                let dir = home.join(sub);
                let mut buf = Vec::new();
                walk(&dir, 2, &mut buf);
                for p in buf {
                    add(p, &mut items, &mut seen);
                }
            }
        }
        let count = items.len();
        self.open_picker(crate::picker::Picker::new(
            PickerKind::GlyphBuilderSvg,
            format!("Pick an SVG file ({count} found)").as_str(),
            items,
        ));
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
        // Exclude the currently focused editor's file from the
        // recent-files picker. Selecting "the file I'm already
        // looking at" is a no-op and just steals the top row from
        // the file the user probably wants next.
        // vscode-mouse-2026-06-10 SEV-3 #8.
        let active_path: Option<std::path::PathBuf> = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                crate::pane::Pane::Editor(b) => b.path.clone(),
                _ => None,
            });
        let items: Vec<PickerItem> = self
            .recent_files
            .iter()
            .filter(|p| p.exists())
            .filter(|p| active_path.as_deref() != Some(p.as_path()))
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
        // R9 vscode-keyboard SEV-3 — the palette used to stack on
        // top of an already-open prompt, and the user's Ctrl+Shift+P
        // keystrokes then leaked into the underneath prompt when
        // Esc was pressed. Dismiss any prompt as step 1 so the
        // palette is always the ONLY input target after open.
        self.prompt = None;
        // 2026-06-19 — keyboard hunt SEV-2: include the command
        // id in the label so a user typing the dotted id (VS Code
        // muscle memory) finds the command directly. The id renders
        // visually as a faint suffix; the fuzzy matcher (with its
        // _-stripping fix) treats `http.send_streaming` ≈ `httpsendstreaming`
        // ≈ both the id and the title text.
        let mut items: Vec<PickerItem> = crate::command::registry()
            .all()
            .iter()
            .filter(|c| c.id != "palette")
            .map(|c| {
                PickerItem::new(
                    c.id,
                    format!("{}  ·  {}  ·  {}", c.group, c.title, c.id),
                    c.key_hint(),
                )
            })
            .collect();
        for dc in &self.dynamic_commands {
            items.push(PickerItem::new(
                dc.id.clone(),
                format!("{}  ·  {}", dc.group, dc.title),
                dc.keys.join(" / "),
            ));
        }
        // keyboard-round-8 SEV-3 2026-07-12 — bubble the last
        // few power-actions to the top so an empty-query palette
        // matches VS Code's "recents at top" convention. The user
        // can still find every command via fuzzy — recents just
        // save the fresh-open Enter.
        //
        // mouse-round-11 SEV-3 2026-07-12 — mark recents with a
        // leading `★` glyph on the label so users see WHY those
        // rows are at the top; without the marker the reorder
        // looked like the palette had shuffled at random.
        if !self.recent_commands.is_empty() {
            let order: std::collections::HashMap<String, usize> = self
                .recent_commands
                .iter()
                .enumerate()
                .map(|(i, id)| (id.clone(), i))
                .collect();
            for item in items.iter_mut() {
                if order.contains_key(&item.id) {
                    item.label = format!("★ {}", item.label);
                    // #1154 reviewer follow-up 2026-08-23 —
                    // when the pane-scoped boost switched from
                    // `priority` to `score_bonus` (+20), a
                    // non-namespaced recent (score 0) started
                    // losing to a pane-scoped non-recent (score
                    // 20). Bump recents to +50 so they still
                    // beat pane-scope. Preserves the documented
                    // "recents > pane-scoped > everything-else"
                    // order at empty query AND on non-empty
                    // queries (a strong bull's-eye elsewhere,
                    // typical fuzzy scores 200-500, can still
                    // beat a weakly-matching recent).
                    item.score_bonus = item.score_bonus.max(50);
                }
            }
            items.sort_by(|a, b| {
                let ai = order.get(&a.id).copied();
                let bi = order.get(&b.id).copied();
                match (ai, bi) {
                    (Some(x), Some(y)) => x.cmp(&y),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                }
            });
        }
        // #1113 (2026-08-20) — pane-scoped boost. Bump commands whose
        // id starts with the active pane's namespace to `priority = 1`
        // so they surface above the generic pool when the query is
        // empty AND rank higher on ties for a non-empty query (the
        // picker's sort is priority desc → score desc → index asc).
        // Recents-on-top from the block above still win because their
        // items already got sorted into positions 0..N and the picker
        // sort uses index-asc as the final tiebreaker at equal
        // priority + score. So the effective order for empty query
        // becomes: recents > pane-scoped > everything-else.
        let namespaces: &[&str] = match self.active.and_then(|i| self.panes.get(i)) {
            Some(crate::pane::Pane::Pty(_)) => &["term.", "pty.", "session."],
            Some(crate::pane::Pane::Editor(_)) => &["editor.", "buffer.", "lsp.", "vim."],
            Some(crate::pane::Pane::Request(_)) => &["http.", "chain."],
            Some(crate::pane::Pane::Diff(_)) => &["diff.", "git."],
            Some(crate::pane::Pane::MdPreview(_)) => &["md.", "editor."],
            _ => &[],
        };
        if !namespaces.is_empty() {
            // R11 vscode-keyboard SEV-2 (2026-08-23) — was
            // `item.priority = item.priority.max(1)`, which is a
            // hard tier that ALWAYS beats fuzzy score. Effect:
            // typing `save file` in an Editor pane picked
            // `lsp.diagnostics_severity_filter_cycle` (an
            // `lsp.*` id with a low-but-positive score) over
            // `file.save` (a 341-score bull's-eye). Switch to
            // a `+20` score bump so pane-scoped commands still
            // surface first at empty-query and still win on
            // ties, but a genuinely-better match elsewhere in
            // the tree can beat them. Fuzzy scores range ~30-
            // ~500; 20 is enough to break same-family ties
            // without derailing cross-family queries.
            for item in items.iter_mut() {
                if namespaces.iter().any(|ns| item.id.starts_with(ns)) {
                    item.score_bonus = item.score_bonus.max(20);
                }
            }
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

    /// Tab on a picker — picker-kind-specific "secondary accept".
    /// `OpenPullRequests`: cross-nav from a PR to its pipeline/build
    /// via the matching `mnml-forge-*` integration's
    /// `--find-pipeline-for-pr --json` headless mode.
    /// #toast-history — a searchable view of every toast this session.
    ///
    /// User: "make way of seeing latest toasts". `:messages` already
    /// existed but crammed the last EIGHT into a single toast joined by
    /// `↵` — unreadable, and it expired like any other toast, so the way
    /// to review a message you missed was itself a message you would
    /// miss. `:Messages!` dumped the lot into a scratch buffer, which is
    /// better but is vim-only and unsearchable.
    ///
    /// A picker gives filtering and scrolling for free, and is reachable
    /// from the palette, so standard-mode users can find it at all.
    pub fn open_messages_picker(&mut self) {
        // Reading the history is what clears the notification badge.
        self.mark_messages_seen();
        if self.message_log.is_empty() {
            self.toast("no messages yet");
            return;
        }
        let items: Vec<crate::picker::PickerItem> = self
            .message_log
            .iter()
            .enumerate()
            .rev() // newest first — the one you missed is the recent one
            .map(|(i, m)| {
                let icon = match m.level {
                    crate::app::ToastLevel::Error => "\u{f071}",
                    crate::app::ToastLevel::Warn => "\u{f071}",
                    crate::app::ToastLevel::Info => "\u{f05a}",
                };
                let icon = if self.config.ui.ascii_icons {
                    match m.level {
                        crate::app::ToastLevel::Error => "!",
                        crate::app::ToastLevel::Warn => "*",
                        crate::app::ToastLevel::Info => "-",
                    }
                } else {
                    icon
                };
                let detail = format!("{icon}  {}", crate::app::hhmm_local(m.at));
                crate::picker::PickerItem::new(i.to_string(), m.text.clone(), detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Messages,
            format!("Messages ({})", items.len()),
            items,
        ));
    }

    /// #files item 3 — destinations for the Files pane's `▾`.
    pub fn open_files_destinations_picker(&mut self) {
        let workspaces: Vec<(String, std::path::PathBuf)> = self
            .config
            .workspaces
            .iter()
            .map(|w| (w.name.clone(), w.path.clone()))
            .collect();
        let recents: Vec<std::path::PathBuf> = self
            .recent_files
            .iter()
            .filter_map(|p| p.parent().map(|q| q.to_path_buf()))
            .collect();
        let places = crate::places::all(&workspaces, &recents);
        if places.is_empty() {
            self.toast("no destinations found");
            return;
        }
        let ascii = self.config.ui.ascii_icons;
        let items: Vec<crate::picker::PickerItem> = places
            .iter()
            .map(|p| {
                let group = match p.group {
                    crate::places::Group::Standard => "",
                    crate::places::Group::Volume => "volume",
                    crate::places::Group::Workspace => "workspace",
                    crate::places::Group::Recent => "recent",
                };
                // Group name in the DETAIL column rather than as section
                // headers: the picker filters as you type, and headers
                // that survive filtering while their rows vanish read as
                // noise.
                let label = if ascii {
                    p.label.clone()
                } else {
                    format!("{}  {}", p.glyph, p.label)
                };
                let detail = if group.is_empty() {
                    p.path.display().to_string()
                } else {
                    format!("{group}  ·  {}", p.path.display())
                };
                crate::picker::PickerItem::new(p.path.display().to_string(), label, detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::FilesDestinations,
            format!("Go to ({} destinations)", items.len()),
            items,
        ));
    }

    /// #1229 — open a bookmarks picker, optionally scoped to one env.
    ///
    /// A picker rather than a nested context menu because the context
    /// menu is flat (no submenu support) and the user expects this list to
    /// grow — "probably more coming". A picker also brings fuzzy search,
    /// which a twelve-row submenu would not.
    pub fn open_bookmarks_picker(&mut self, env: Option<&str>) {
        let all = crate::bookmarks::load(&self.workspace);
        if all.is_empty() {
            let p = crate::bookmarks::paths(&self.workspace)
                .first()
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            // Name the file: an empty picker with no explanation is a
            // dead end, and this feature is useless until the user
            // writes that file.
            self.toast(format!("no bookmarks yet — define them in {p}"));
            return;
        }
        let picked: Vec<&crate::bookmarks::Bookmark> = match env {
            Some(e) => crate::bookmarks::in_env(&all, e),
            None => all.iter().collect(),
        };
        if picked.is_empty() {
            self.toast(format!("no bookmarks in env `{}`", env.unwrap_or("")));
            return;
        }
        let items: Vec<crate::picker::PickerItem> = picked
            .iter()
            .map(|b| {
                // Label carries the env when showing all of them, so the
                // three same-named rows of a 3-env site stay tellable
                // apart.
                let label = if env.is_some() {
                    b.label.clone()
                } else {
                    format!("{}  ·  {}", b.env, b.label)
                };
                crate::picker::PickerItem::new(&b.url, label, b.url.clone())
            })
            .collect();
        let title = match env {
            Some(e) => format!("Bookmarks · {e} ({})", items.len()),
            None => format!("Bookmarks ({})", items.len()),
        };
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Bookmarks,
            title,
            items,
        ));
    }

    pub fn picker_accept_secondary(&mut self) {
        let Some(picker) = self.picker.as_ref() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match picker.kind {
            PickerKind::OpenPullRequests => {
                // Take the picker so we close the overlay before the
                // (potentially-1s) integration shellout — keeps the UI
                // responsive while we look up the pipeline URL.
                self.picker = None;
                self.accept_pr_picker_secondary(&item.id);
            }
            PickerKind::Reflog => {
                // #1229 — Tab recovers, Enter inspects. Enter stays the
                // primary because you want to CONFIRM the commit is the
                // one you lost before acting on it; recovery is the
                // deliberate second gesture.
                let hash = item.id.clone();
                self.picker = None;
                self.recover_reflog_entry(&hash);
            }
            _ => self.toast("Tab → no secondary action for this picker"),
        }
    }

    pub fn picker_accept(&mut self) {
        let Some(picker) = self.picker.take() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            // No match. For a file picker, the query may be a PATH the
            // user pasted — one outside the workspace, so it was never a
            // candidate to match against. Enter did nothing at all
            // before, with no feedback either (user report: pasted an
            // absolute path, pressed Enter, "nothing happens").
            if matches!(picker.kind, PickerKind::Files | PickerKind::Recent) {
                let q = picker.query.trim();
                if !q.is_empty() {
                    // Resolves `~`, and a relative path against the
                    // workspace — the same rule the rest of the file
                    // operations use.
                    let expanded = crate::app::util::expand_tilde_and_resolve(&self.workspace, q);
                    if expanded.is_file() {
                        self.open_path(&expanded);
                        return;
                    }
                    if expanded.is_dir() {
                        // A directory is a reasonable thing to paste too.
                        self.open_files_pane(Some(expanded));
                        return;
                    }
                    self.toast(format!("no such file: {q}"));
                    return;
                }
            }
            return;
        };
        match picker.kind {
            PickerKind::Files | PickerKind::Recent => self.open_path(Path::new(&item.id)),
            PickerKind::SonosRooms => self.sonos_select_room(&item.id),
            PickerKind::SonosFavorites => self.sonos_play_favorite(&item.id),
            PickerKind::SonosAirPlayTargets => self.sonos_send_music_to(&item.id),
            PickerKind::GlyphBuilderSvg => {
                // Route the picked path into the glyph builder's
                // svg_path field. Preserves the current focused_field
                // so the user lands back on `path` with the value
                // populated (they can Tab away or hit Enter to bake).
                if let Some(s) = self.glyph_builder.as_mut() {
                    s.svg_path = item.id.clone();
                    s.svg_path_cursor = s.svg_path.len();
                    s.focused_field = crate::glyph_builder::BuilderField::Path;
                }
            }
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
                // vscode-user-keyboard S1-1: prefixed ids from the
                // integration chip picker dispatch to the per-chip
                // toggle / edit / remove handlers. Anything else is
                // a plain command id (Cmd+Shift+P palette default).
                if let Some(id) = item.id.strip_prefix("toggle:") {
                    // #852 — route through the shared helper so
                    // this picker path uses write_override_toml
                    // like the right-click menu + detail-pane
                    // button. Previously wrote to config.toml
                    // where the 2026-08-01 flip drops it for any
                    // non-builtin id.
                    self.toggle_integration_enabled_by_id(id);
                } else if let Some(id) = item.id.strip_prefix("edit:") {
                    self.open_integration_edit_by_id(id);
                } else if let Some(id) = item.id.strip_prefix("remove:") {
                    self.open_integration_remove_confirm(id.to_string());
                } else if let Some(id) = item.id.strip_prefix("copy_id:") {
                    // vscode-user-keyboard SEV-2 fix 2026-07-10 —
                    // Copy id palette-reachable (was mouse-only via
                    // the chip's right-click context menu).
                    let mut clip = crate::clipboard::Clipboard::new();
                    clip.set(id.to_string(), false);
                    self.toast(format!("copied `{id}` to clipboard"));
                } else if let Some(id) = item.id.strip_prefix("show_manifest:") {
                    // vscode-user-keyboard SEV-2 fix — Show manifest…
                    // via palette. Reuses the context-menu handler's
                    // path-resolution logic.
                    let ws_path = self
                        .workspace
                        .join(".mnml")
                        .join("integrations")
                        .join(format!("{id}.toml"));
                    let home = std::env::var_os("HOME")
                        .map(std::path::PathBuf::from)
                        .unwrap_or_else(|| std::path::PathBuf::from("."));
                    let user_path = home
                        .join(".config")
                        .join("mnml")
                        .join("integrations")
                        .join(format!("{id}.toml"));
                    if ws_path.exists() {
                        self.open_path(&ws_path);
                    } else if user_path.exists() {
                        self.open_path(&user_path);
                    } else {
                        self.toast(format!(
                            "no manifest file for `{id}` — it's a built-in default"
                        ));
                    }
                } else {
                    crate::command::run(&item.id, self);
                }
            }
            PickerKind::Themes => {
                self.theme_preview_restore = None;
                self.set_theme(&item.id);
            }
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
            PickerKind::BrowserNetworkThrottle => {
                self.browser_set_network_throttle(&item.id);
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
                // Restored 2026-06-06 after the SCM split: dispatched
                // by `pr.picker` — Enter opens the chosen PR's URL.
                // The picker's secondary-accept (Tab) is handled
                // separately by `accept_pr_picker_secondary` invoked
                // from the picker keymap.
                self.accept_pr_picker_primary(&item.id);
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
            PickerKind::GitReopenRepo => {
                let path = std::path::PathBuf::from(&item.id);
                if self.git_closed_repos.remove(&path) {
                    self.open_git_graph();
                    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("repo");
                    self.toast(format!("reopened {name}"));
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
                // Phase-in confirm prompt instead of acting
                // immediately. Reflog-recoverable only until next
                // `git gc` (~30 days); a hard typed confirm matches
                // the branch-delete floor.
                // untouched-surfaces-hunt-2026-06-08 SEV-2 #8.
                let stash_ref = item.id;
                let label = item.label.clone();
                self.prompt = Some(crate::prompt::Prompt::seeded(
                    crate::prompt::PromptKind::GitStashDrop,
                    format!("Type 'drop' to delete {label}"),
                    "",
                ));
                self.pending_stash_drop = Some((stash_ref, label));
            }
            PickerKind::Messages => {
                // Copy, because a log entry is text you usually want to
                // paste into an issue or a search.
                self.clipboard.set(item.label.clone(), false);
                self.toast("message copied");
            }
            PickerKind::FilesDestinations => {
                let dir = std::path::PathBuf::from(&item.id);
                // Navigate the pane the picker was opened FROM, which is
                // still `active` — the picker does not move focus.
                if let Some(i) = self.active
                    && let Some(crate::pane::Pane::Files(f)) = self.panes.get_mut(i)
                {
                    f.navigate_to(&dir);
                } else {
                    // No Files pane focused any more (the user switched
                    // panes with the picker open) — open one rather than
                    // silently doing nothing.
                    self.open_files_pane(Some(dir));
                }
            }
            PickerKind::Bookmarks => {
                // `id` is the URL — hand it to the OS browser.
                crate::app::open_url_external(&item.id);
                self.toast(format!("opened {}", item.label));
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
            PickerKind::IntegrationConfigure => {
                let id = item.id.clone();
                self.accept_integration_configure(&id);
            }
            PickerKind::IntegrationDiag => {
                let id = item.id.clone();
                self.accept_integration_diag(&id);
            }
            PickerKind::CapturedRows => {
                if let Ok(idx) = item.id.parse::<usize>()
                    && let Some(row) = self.pending_captured_rows.get(idx).cloned()
                {
                    self.open_curl_scratch(&row.to_curl(), &row.method, &row.url);
                }
                self.pending_captured_rows.clear();
            }
            PickerKind::HistoryRows => {
                if let Ok(idx) = item.id.parse::<usize>()
                    && let Some(v) = self.pending_history_rows.get(idx).cloned()
                {
                    let (curl, method, url) = crate::http::history::entry_to_curl(&v);
                    self.open_curl_scratch(&curl, &method, &url);
                }
                self.pending_history_rows.clear();
            }
            PickerKind::LookupFile => {
                let path = std::path::PathBuf::from(item.id.clone());
                self.accept_lookup_file(&path);
            }
            PickerKind::LookupItem => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.accept_lookup_item(idx);
                }
            }
            PickerKind::EnvVars => {
                let id = item.id.clone();
                self.accept_env_vars(&id);
            }
            PickerKind::HttpHeader => {
                let name = item.id.clone();
                self.accept_http_header(&name);
            }
            PickerKind::HttpGenerateCode => {
                let id = item.id.clone();
                self.accept_http_generate_code(&id);
            }
            PickerKind::HttpResponseFormat => {
                let id = item.id.clone();
                self.accept_http_response_format(&id);
            }
            PickerKind::HttpEnv => {
                let name = item.id.clone();
                self.accept_http_env(&name);
            }
            PickerKind::AuthPresets => {
                let name = item.id.clone();
                self.accept_auth_preset(&name);
            }
            PickerKind::HttpChains => {
                let path = std::path::PathBuf::from(item.id.clone());
                self.http_chain_run_path(path);
            }
            PickerKind::HttpImport => {
                let id = item.id.clone();
                self.accept_http_import(&id);
            }
            PickerKind::GitDeleteBranch => {
                self.git_delete_branch_confirm(item.id.clone());
            }
            PickerKind::GitMergeInto => {
                // 2026-06-21 vscode-user SEV-2: was running merge
                // unconditionally on accept, so a single mouse
                // click fast-forwarded the current branch onto
                // whatever was clicked — no confirm gate while
                // integration pickers (delete_branch, worktree_remove)
                // do gate. Now mirrors those: stash the branch
                // name + open a confirm prompt typed-`merge`.
                self.pending_merge_source = Some(item.id.clone());
                let mut p = crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::GitMergeConfirm,
                    format!("Merge `{}` into current?", item.id),
                );
                p.cursor = 1;
                self.prompt = Some(p);
            }
            PickerKind::GitRebaseOnto => {
                self.pending_rebase_onto = Some(item.id.clone());
                let mut p = crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::GitRebaseConfirm,
                    format!("Rebase current onto `{}`?", item.id),
                );
                p.cursor = 1;
                self.prompt = Some(p);
            }
            PickerKind::GitWorktreeOpen => {
                self.git_open_worktree(std::path::PathBuf::from(item.id.clone()));
            }
            PickerKind::GitWorktreeRemove => {
                let path = std::path::PathBuf::from(item.id.clone());
                self.pending_worktree_path = Some(path.clone());
                let mut p = crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::WorktreeRemoveConfirm,
                    format!("Remove worktree {}?", path.display()),
                );
                p.cursor = 1;
                self.prompt = Some(p);
            }
            PickerKind::GoRunCmd => {
                let app = item.id.clone();
                self.run_manifest_command("go.mod", "go", "run", &format!("run ./cmd/{app}"));
            }
            PickerKind::WsHistory => {
                let url = item.id.clone();
                self.ws_history_open(url);
            }
            PickerKind::CookiesDelete => {
                if let Some((host, name)) = item.id.split_once('\t') {
                    let removed = {
                        let Ok(mut jar) = self.cookie_jar.lock() else {
                            self.toast("cookies: jar lock poisoned");
                            return;
                        };
                        jar.remove(host, name)
                    };
                    if removed {
                        let Ok(jar) = self.cookie_jar.lock() else {
                            return;
                        };
                        let _ = jar.save(&self.workspace);
                        drop(jar);
                        self.toast(format!("cookies: removed {host} · {name}"));
                    } else {
                        self.toast("cookies: not found");
                    }
                }
            }
            PickerKind::Cookies => {
                // id shape: `<host>\t<name>`.
                let lookup = item.id.split_once('\t').and_then(|(host, name)| {
                    let jar = self.cookie_jar.lock().ok()?;
                    let val = jar.iter().find_map(|(h, n, v)| {
                        if h == host && n == name {
                            Some(v.to_string())
                        } else {
                            None
                        }
                    });
                    val.map(|v| (name.to_string(), v))
                });
                if let Some((name, v)) = lookup {
                    let pair = format!("{name}={v}");
                    self.clipboard.set(pair.clone(), false);
                    self.toast(format!("cookies: copied {pair}"));
                }
            }
            PickerKind::IconGlyphs => {
                // Special "+ Create custom glyph…" row — opens the
                // glyph builder in edit-panel context; commit routes
                // the resulting codepoint back to the still-open edit
                // panel. Only surfaces when integration_edit is Some
                // (see the row-add block in `open_icon_picker`), but
                // guard here too in case that invariant changes.
                if item.id == "new" && self.integration_edit.is_some() {
                    self.open_glyph_builder_from_edit();
                    return;
                }
                // id = uppercase hex codepoint. Build the glyph.
                if let Ok(cp) = u32::from_str_radix(&item.id, 16)
                    && let Some(ch) = char::from_u32(cp)
                {
                    // Route straight into the edit panel's Glyph
                    // field when the panel is open — the user
                    // triggered the picker from Ctrl+G there.
                    if let Some(panel) = self.integration_edit.as_mut() {
                        panel.focused_field = crate::app::discovery::IntegrationEditField::Glyph;
                        panel.glyph.clear();
                        panel.glyph.push(ch);
                        // crash-investigator SEV-1 2026-07-11: reset
                        // glyph_cursor to match the new buffer length.
                        // Nerd Font icons vary in UTF-8 width (3 bytes
                        // for BMP private-use vs 4 bytes for MDI).
                        // A stale cursor from the previous glyph could
                        // land mid-codepoint, and the next backspace /
                        // move_left / type_char would panic on the
                        // byte-slice.
                        panel.glyph_cursor = panel.glyph.len();
                        self.toast(format!("glyph: {ch}"));
                    } else {
                        // Bare palette-triggered picker still
                        // copies to clipboard (both literal +
                        // \u{...} escape).
                        let line = format!("{ch}  \\u{{{}}}  ({})", item.id, item.label);
                        self.clipboard.set(line, false);
                        self.toast(format!("icon copied — paste: {ch} or \\u{{{}}}", item.id));
                    }
                }
            }
            PickerKind::GlyphAction => {
                // 3-option Enter-on-Glyph chooser. Dispatch by id.
                let id = item.id.clone();
                self.glyph_action_dispatch(&id);
            }
        }
    }

    /// Build a Picker of every configured integration chip — used
    /// by the toggle / edit / remove palette commands. `accept_kind`
    /// determines what `id` shape we return so the accept-handler
    /// routes correctly.
    fn open_integration_chip_picker(&mut self, title: &str, action_prefix: &str) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let items: Vec<PickerItem> = self
            .config
            .ui
            .integration_icons
            .iter()
            .map(|ic| {
                let state = if ic.enabled { "on" } else { "off" };
                let label = ic.label.clone().unwrap_or_default();
                PickerItem {
                    id: format!("{action_prefix}:{}", ic.id),
                    label: format!("{} ({state}) — {}", ic.id, label),
                    detail: ic.command.clone(),
                    priority: 0,
                    score_bonus: 0,
                }
            })
            .collect();
        let p = Picker::new(PickerKind::Commands, title.to_string(), items);
        self.open_picker(p);
    }

    pub fn open_integration_copy_id_picker(&mut self) {
        self.open_integration_chip_picker("Integrations: copy id", "copy_id");
    }

    pub fn open_integration_show_manifest_picker(&mut self) {
        self.open_integration_chip_picker("Integrations: show manifest…", "show_manifest");
    }

    pub fn open_integration_toggle_picker(&mut self) {
        self.open_integration_chip_picker("Integrations: toggle enabled", "toggle");
    }
    pub fn open_integration_edit_picker(&mut self) {
        self.open_integration_chip_picker("Integrations: edit", "edit");
    }
    pub fn open_integration_remove_picker(&mut self) {
        self.open_integration_chip_picker("Integrations: remove", "remove");
    }

    /// Open the integrations icon picker — a searchable list of
    /// every Nerd Font glyph. Hand-curated entries (with real names +
    /// categories) rank first (priority 1) so a search for "aws" or
    /// "git" hits them; the rest of the PUA ranges are appended so
    /// users can browse the full catalog. Accept in the picker feeds
    /// the char back into the integration-edit panel's Glyph field
    /// (see `PickerKind::IconGlyphs` in `picker.rs::accept`).
    pub fn open_icon_picker(&mut self) {
        let mut items: Vec<crate::picker::PickerItem> = Vec::with_capacity(2048);
        let mut seen = std::collections::HashSet::<u32>::new();

        // "+ Create custom glyph…" pseudo-row — pinned at the very top
        // via priority=2. Special id "new" is handled by the accept
        // path in this file: opens the glyph builder in edit-panel
        // context so the resulting codepoint flows straight back into
        // the still-open integration edit panel's Glyph field.
        // Only surface this affordance when the picker was launched
        // from an integration edit context (otherwise the resulting
        // glyph has nowhere to flow back to).
        if self.integration_edit.is_some() {
            items.push(crate::picker::PickerItem {
                id: "new".to_string(),
                label: "+ Create custom glyph (SVG → font)".to_string(),
                detail: "opens glyph builder".to_string(),
                priority: 2,
                score_bonus: 0,
            });
        }

        // Hand-curated section — pinned first via priority=1 so
        // typing a search matches these before generic entries.
        for e in crate::icon_catalog::ICON_CATALOG {
            let Some(cp) = u32::from_str_radix(e.codepoint, 16).ok() else {
                continue;
            };
            let Some(ch) = char::from_u32(cp) else {
                continue;
            };
            seen.insert(cp);
            items.push(crate::picker::PickerItem {
                id: format!("{cp:04X}"),
                label: format!("{ch}  {}  [{}]", e.name, e.category),
                detail: format!("\\u{{{cp:04X}}}"),
                priority: 1,
                score_bonus: 0,
            });
        }

        // Full Nerd Fonts catalog (~11k glyphs) from bundled
        // glyphnames.json v3.5.1. Each row carries name + category
        // so search matches "repo pull" and "cod-repo_pull" the way
        // nerdfonts.com's own search does — was previously typing
        // hex codepoints only, since the fallback path only labeled
        // rows as `U+XXXX`.
        for meta in crate::nerd_glyphs::catalog().values() {
            if seen.contains(&meta.codepoint) {
                continue;
            }
            let Some(ch) = char::from_u32(meta.codepoint) else {
                continue;
            };
            let cp_hex = format!("{:04X}", meta.codepoint);
            // Label carries: glyph, human name, category chip, hex.
            // The picker's fuzzy matcher runs against the whole label,
            // so `pull` finds every `*_pull` glyph, `md` narrows to
            // Material Design, and `eb40` still lands on repo_pull.
            let category_chip = if meta.category.is_empty() {
                String::new()
            } else {
                format!("  [{}]", meta.category)
            };
            // 2026-08-25 — surface ghostty's codepoint-map routing
            // so users can see WHICH font would render this glyph
            // per their config. `?` for unmapped codepoints (which
            // fall back to the terminal's primary font).
            let routed = crate::ghostty_config::resolve_family(meta.codepoint)
                .map(|f| format!("  → {f}"))
                .unwrap_or_default();
            items.push(crate::picker::PickerItem {
                id: cp_hex.clone(),
                label: format!(
                    "{ch}  {name}{category_chip}  U+{cp_hex}",
                    name = meta.human_name,
                ),
                detail: format!("nf-{}  \\u{{{cp_hex}}}{routed}", meta.full_name,),
                priority: 0,
                score_bonus: 0,
            });
        }
        let title = format!("Pick glyph · {} shown", items.len());
        let picker =
            crate::picker::Picker::new(crate::picker::PickerKind::IconGlyphs, title, items);
        self.open_picker(picker);
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
        self.pending_branch_source = None;
        self.pending_branch_delete = None;
        self.pending_worktree_path = None;
        // render-reviewer #9 — pending_tool_install stash followed
        // the same pattern; cleared here for consistency even though
        // the realistic data-loss path is narrow.
        self.pending_tool_install = None;
        self.rename_preview_state = None;
        // 2026-06-21 — power-user-ws-git SEV-1: Esc on the
        // `:git.worktree_add` path prompt left
        // `pending_worktree_path = Some(empty)` stuck, so the very
        // next `view.add_workspace` (which reuses the AddWorkspace
        // PromptKind) silently hijacked the typed path into the
        // worktree-add flow. Clear it alongside the other path
        // stashes.
        self.pending_worktree_path = None;
        self.pending_branch_delete = None;
        self.pending_merge_source = None;
        self.pending_rebase_onto = None;
        self.pending_kill_pid = None;
        self.pending_kill_batch.clear();
        // 2026-06-19 — api-workflow-user SEV-3: Esc on a lookup
        // var-name / env edit prompt left these stashes set, so the
        // next picker accept of the same type could fire against
        // stale state.
        self.pending_lookup_picked_id = None;
        self.pending_env_edit_key = None;
        self.pending_claude_account_rename = None;
        if was_find {
            self.restore_find_preview_snapshot();
            self.find_pending_range = None;
        }
    }

    pub fn prompt_accept(&mut self) {
        let Some(mut p) = self.prompt.take() else {
            return;
        };
        match p.kind {
            crate::prompt::PromptKind::AddWorkspace => {
                // If the user picked a row from the live directory
                // listing (↑↓ then Enter), that path wins over the
                // typed input — the row's `take_selected_input`
                // returns the full path with tilde already expanded.
                let from_selected = p.take_selected_input();
                let raw = from_selected.unwrap_or_else(|| p.input.trim().to_string());
                let input = raw.trim();
                if input.is_empty() {
                    return;
                }
                let path = if let Some(rest) = input.strip_prefix("~/") {
                    if let Some(home) = std::env::var_os("HOME") {
                        PathBuf::from(home).join(rest)
                    } else {
                        PathBuf::from(input)
                    }
                } else {
                    PathBuf::from(input)
                };
                // Sentinel: `:git.worktree_add` set
                // pending_worktree_path to an empty path before
                // opening this prompt. Reroute the path to the
                // worktree-add flow instead of opening a workspace.
                if self
                    .pending_worktree_path
                    .as_ref()
                    .is_some_and(|p| p.as_os_str().is_empty())
                {
                    self.git_worktree_add_path_chosen(path);
                    return;
                }
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
            crate::prompt::PromptKind::LinkClaudeToken => {
                self.accept_link_claude_token(p.input.clone())
            }
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
                let chain_to_replace = p.chain_to_replace;
                // Live-preview is the new find state already; commit it.
                self.find_preview_snapshot = None;
                self.accept_find(q.clone());
                // vscode-user-keyboard SEV-2 2026-07-11: when the Find
                // prompt was opened via Ctrl+H (chain flag), Enter's
                // accept-find should immediately open Replace if the
                // query produced matches. Matches VS Code's one-chord
                // find+replace flow. If NO matches, keep the Find
                // prompt up so the user can refine without hitting
                // Ctrl+F again — vscode-user-keyboard SEV-3 follow-up
                // 2026-07-11.
                if chain_to_replace {
                    let has_matches = self
                        .active
                        .and_then(|cur| self.panes.get(cur))
                        .and_then(|pane| {
                            if let Pane::Editor(b) = pane {
                                b.find.as_ref().map(|f| !f.matches.is_empty())
                            } else {
                                None
                            }
                        })
                        .unwrap_or(false);
                    if has_matches {
                        self.open_replace_prompt();
                    } else {
                        // No matches — re-open the Find prompt with the
                        // typed query preserved so the user can adjust.
                        let mut fresh = crate::prompt::Prompt::seeded(
                            crate::prompt::PromptKind::Find,
                            "Find (Enter → Replace)",
                            q,
                        );
                        fresh.chain_to_replace = true;
                        self.prompt = Some(fresh);
                    }
                }
            }
            crate::prompt::PromptKind::Replace => {
                let r = p.input.clone();
                self.accept_replace(r);
            }
            crate::prompt::PromptKind::Grep => {
                let q = p.input.clone();
                // #polish 2026-07-06 — remember for next launch.
                self.last_grep_query = q.clone();
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
            crate::prompt::PromptKind::PatchNerdFontSvg => {
                let svg = p.input.trim().to_string();
                self.run_patch_nerd_font_svg(&svg);
            }
            crate::prompt::PromptKind::LookupVarName => {
                let var = p.input.trim().to_string();
                self.accept_lookup_var_name(&var);
            }
            crate::prompt::PromptKind::EnvEditValue => {
                let v = p.input.clone();
                self.accept_env_edit_value(&v);
            }
            crate::prompt::PromptKind::EnvAddKey => {
                let v = p.input.clone();
                self.accept_env_add_key(&v);
            }
            crate::prompt::PromptKind::HttpParamAdd => {
                let v = p.input.clone();
                self.accept_http_param_add(&v);
            }
            crate::prompt::PromptKind::AuthSavePreset => {
                let v = p.input.clone();
                self.accept_auth_save_preset(&v);
            }
            crate::prompt::PromptKind::AiAskAboutRequest => {
                let q = p.input.clone();
                self.ai_ask_about_request_with_question(&q);
            }
            crate::prompt::PromptKind::HttpSaveResponse => {
                let path = p.input.clone();
                self.http_save_response_to(&path);
            }
            crate::prompt::PromptKind::HttpSaveRequestAs => {
                let path = p.input.clone();
                self.http_save_request_as(&path);
            }
            crate::prompt::PromptKind::HttpNewEnv => {
                let name = p.input.clone();
                self.http_new_env_create(&name);
            }
            crate::prompt::PromptKind::HttpNewChain => {
                let name = p.input.clone();
                self.http_new_chain_create(&name);
            }
            crate::prompt::PromptKind::HttpNewCollection => {
                let name = p.input.clone();
                self.http_new_collection_create(&name);
            }
            crate::prompt::PromptKind::HttpAuthBearer => {
                let tok = p.input.clone();
                self.http_auth_set("Authorization", &format!("Bearer {tok}"));
            }
            crate::prompt::PromptKind::HttpAuthBasic => {
                use base64::prelude::*;
                let creds = p.input.clone();
                let encoded = BASE64_STANDARD.encode(creds.as_bytes());
                self.http_auth_set("Authorization", &format!("Basic {encoded}"));
            }
            crate::prompt::PromptKind::HttpAuthApiKey => {
                let key = p.input.clone();
                self.http_auth_set("X-Api-Key", &key);
            }
            crate::prompt::PromptKind::WsConnect => {
                let url = p.input.clone();
                self.ws_connect_to(&url);
            }
            crate::prompt::PromptKind::WsSendMessage => {
                let msg = p.input.clone();
                self.ws_send_on_active(&msg);
            }
            crate::prompt::PromptKind::HttpAiBuild => {
                let description = p.input.clone();
                self.http_ai_build_accept(description);
            }
            crate::prompt::PromptKind::ClaudeSessionSearch => {
                let q = p.input.clone();
                self.ai_session_search_run(q);
            }
            crate::prompt::PromptKind::AiBranchNameDescription => {
                let description = p.input.clone();
                self.ai_write_branch_name_accept(description);
            }
            crate::prompt::PromptKind::BranchName => {
                let name = p.input.trim().to_string();
                if name.is_empty() {
                    self.toast("branch name empty");
                    return;
                }
                match crate::git::branch::create(self.active_repo_path(), &name) {
                    Ok(()) => self.toast(format!("created + checked out {name}")),
                    Err(e) => self.toast(format!("branch {name}: {e}")),
                }
            }
            crate::prompt::PromptKind::WorktreeBranchName => {
                let branch = p.input.clone();
                self.git_worktree_add_apply(branch);
            }
            crate::prompt::PromptKind::NpmRunScript => {
                let script = p.input.clone();
                self.npm_run_script_accept(script);
            }
            crate::prompt::PromptKind::GoRunPath => {
                let path = p.input.clone();
                self.go_run_path_accept(path);
            }
            crate::prompt::PromptKind::GitMergeConfirm => {
                if p.input.trim().eq_ignore_ascii_case("merge") {
                    if let Some(branch) = self.pending_merge_source.take() {
                        self.git_merge_branch(branch);
                    }
                } else {
                    self.pending_merge_source = None;
                    self.toast("merge cancelled");
                }
            }
            crate::prompt::PromptKind::GitRebaseConfirm => {
                if p.input.trim().eq_ignore_ascii_case("rebase") {
                    if let Some(target) = self.pending_rebase_onto.take() {
                        self.git_rebase_onto(target);
                    }
                } else {
                    self.pending_rebase_onto = None;
                    self.toast("rebase cancelled");
                }
            }
            crate::prompt::PromptKind::WorktreeRemoveConfirm => {
                if p.input.trim().eq_ignore_ascii_case("remove") {
                    self.git_worktree_remove_apply();
                } else {
                    self.pending_worktree_path = None;
                    self.toast("worktree remove cancelled");
                }
            }
            crate::prompt::PromptKind::ToolInstallConfirm => {
                self.accept_tool_install(p.input);
            }
            crate::prompt::PromptKind::GitDeleteBranchConfirm => {
                if p.input.trim().eq_ignore_ascii_case("delete") {
                    self.git_delete_branch_apply();
                } else {
                    self.pending_branch_delete = None;
                    self.toast("branch delete cancelled");
                }
            }
            crate::prompt::PromptKind::ClaudeKillConfirm => {
                if p.input.trim().eq_ignore_ascii_case("kill") {
                    self.claude_agents_kill_confirmed();
                } else {
                    self.pending_kill_pid = None;
                    self.pending_kill_batch.clear();
                    self.toast("kill cancelled");
                }
            }
            crate::prompt::PromptKind::IntegrationRemoveConfirm => {
                // 2026-08-06 — 2-button dialog accepts on either
                // "remove" (legacy — kept so existing dispatcher
                // paths still fire) or the new "Uninstall" label
                // that the confirm_labels arm emits.
                let accept = {
                    let t = p.input.trim();
                    t.eq_ignore_ascii_case("remove") || t.eq_ignore_ascii_case("uninstall")
                };
                if accept {
                    let id = self.pending_integration_remove_id.take();
                    let bin = self.pending_integration_remove_binary.take();
                    if let Some(id) = id {
                        self.remove_integration_by_id(&id);
                        // 2026-08-08 — spawn `cargo uninstall` in a
                        // visible Pty pane (matches the Install flow's
                        // shape) so the user sees the output instead
                        // of a silent background process. Post-run,
                        // fire integrations.refresh via the IPC file
                        // so any cached view catches up.
                        if let Some(bin) = bin {
                            let ipc_cmd = self.workspace.join(".mnml").join("ipc").join("command");
                            self.run_ex_command(&format!(
                                "term cargo uninstall {bin} && echo '{{\"cmd\":\"run-command\",\"id\":\"integrations.refresh\"}}' >> {ipc} && echo '✓ {bin} uninstalled'",
                                ipc = ipc_cmd.display(),
                            ));
                        }
                    }
                } else {
                    self.pending_integration_remove_id = None;
                    self.pending_integration_remove_binary = None;
                    self.toast("integration uninstall cancelled");
                }
            }
            crate::prompt::PromptKind::ResetToDefaultsConfirm => {
                // 2-button dialog uses `confirm_labels` +
                // generic_confirm; the accept text is the primary
                // button label ("  Reset  "). Cancel path is a
                // dropped prompt with no dispatch.
                if p.input.trim().eq_ignore_ascii_case("reset") {
                    self.perform_reset_to_defaults();
                } else {
                    self.toast("reset cancelled");
                }
            }
            crate::prompt::PromptKind::WorkspaceTrustConfirm => {
                if p.input.trim().eq_ignore_ascii_case("trust") {
                    self.grant_workspace_trust();
                } else {
                    // Staying restricted needs no action — the exec
                    // keys were never applied. Just say so, since the
                    // consequence (no repo LSP/formatter) is otherwise
                    // invisible until something quietly doesn't run.
                    self.toast(
                        "Workspace left untrusted — its language servers, formatters, \
                         and startup commands stay off. `workspace.review_trust` to revisit.",
                    );
                }
            }
            crate::prompt::PromptKind::WorkspaceTrustReview => {
                // Both options are real; "keep" is the primary so a
                // reflexive Enter can't drop a standing decision.
                if p.input.trim().eq_ignore_ascii_case("revoke") {
                    self.revoke_workspace_trust();
                } else {
                    self.toast("Workspace stays trusted.");
                }
            }
            crate::prompt::PromptKind::PortableChoicePrompt => {
                // #867 — both options are valid choices, not
                // primary/cancel. The synth in run_confirm_button
                // maps primary → "portable", cancel → "normal".
                let choice = p.input.trim().to_ascii_lowercase();
                self.dispatch_portable_choice(&choice);
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
                // No-op: DeleteConfirm now routes through the button
                // handler (`run_delete_button`) in the prompt-key
                // dispatcher. Kept as an arm so future accidental
                // Enter routing lands here silently rather than
                // crashing.
            }
            crate::prompt::PromptKind::GitStashDrop => {
                self.confirm_stash_drop(p.input.clone());
            }
            crate::prompt::PromptKind::GitTagDelete => {
                self.confirm_tag_delete(p.input.clone());
            }
            crate::prompt::PromptKind::WorkspaceRename => {
                let typed = p.input.clone();
                self.commit_workspace_rename(&typed);
            }
            crate::prompt::PromptKind::WorkspacePathEdit => {
                let typed = p.input.clone();
                self.commit_workspace_path_edit(&typed);
            }
            crate::prompt::PromptKind::WorkspaceGroupEdit => {
                let typed = p.input.clone();
                self.commit_workspace_group_edit(&typed);
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
            crate::prompt::PromptKind::FilterLinesShellCmd => {
                let cmd = p.input.clone();
                self.accept_filter_lines_shell_cmd(cmd);
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
            crate::prompt::PromptKind::DockWidgetRename => {
                let typed = p.input.clone();
                self.rename_dock_widget(&typed);
            }
            crate::prompt::PromptKind::MountBinary => {
                let typed = p.input.clone();
                self.open_mount(&typed);
            }
            crate::prompt::PromptKind::CloudRunTicket => {
                let typed = p.input.clone();
                self.fire_cloud_run(&typed);
            }
            crate::prompt::PromptKind::MarketplaceInstallConfirm => {
                let typed = p.input.clone();
                self.marketplace_install_confirm_resolve(&typed);
            }
            crate::prompt::PromptKind::FileMoveTo => {
                let from_selected = p.take_selected_input();
                let raw = from_selected.unwrap_or_else(|| p.input.trim().to_string());
                self.file_finish_move_to(&raw);
            }
            crate::prompt::PromptKind::IntegrationLauncher => {
                let input = p.input.clone();
                self.accept_integration_launcher(input);
            }
            crate::prompt::PromptKind::LaunchProfileName => {
                let input = p.input.clone();
                self.accept_launch_profile_name(input);
            }
            crate::prompt::PromptKind::LaunchProfileCommand => {
                let input = p.input.clone();
                self.accept_launch_profile_command(input);
            }
            crate::prompt::PromptKind::ClaudeAccountRename => {
                let typed = p.input.clone();
                if let Some(old) = self.pending_claude_account_rename.take() {
                    self.rename_claude_account(&old, typed);
                }
            }
        }
    }
}

#[cfg(test)]
mod picker_tests {
    use super::*;

    // Cross-host PR picker removed after the 2026-06 SCM split —
    // per-host happy-path tests live in each forge integration's own repo.

    #[test]
    fn open_repo_picker_no_op_when_single() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join(".git")).unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_repo_picker();
        // Only one repo ⇒ no picker.
        assert!(app.picker.is_none());
    }
}

#[cfg(test)]
mod picker_path_fallback_tests {
    use crate::app::App;
    use crate::config::Config;

    /// User report — pasted an absolute path into "Open file", pressed
    /// Enter, "nothing happens". The picker matches against WORKSPACE
    /// files, so a path outside it was never a candidate; with no
    /// selection, accept returned early and did not even toast.
    #[test]
    fn accepting_a_pasted_absolute_path_opens_it() {
        let d = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let f = outside.path().join("elsewhere.txt");
        std::fs::write(&f, "hello\n").unwrap();

        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_file_picker();
        for c in f.to_string_lossy().chars() {
            if let Some(p) = app.picker.as_mut() {
                p.type_char(c);
            }
        }
        assert!(
            app.picker.as_ref().unwrap().selected_item().is_none(),
            "setup: the path should match nothing in this workspace"
        );

        app.picker_accept();
        assert!(
            app.panes.iter().any(|p| matches!(
                p,
                crate::pane::Pane::Editor(b)
                    if b.path.as_deref().is_some_and(|q| q.ends_with("elsewhere.txt"))
            )),
            "the pasted path did not open"
        );
    }

    /// A pasted DIRECTORY is a reasonable thing to want too — it opens
    /// as a Files pane rather than failing.
    #[test]
    fn accepting_a_pasted_directory_opens_a_files_pane() {
        let d = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("a.txt"), "x").unwrap();

        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_file_picker();
        for c in outside.path().to_string_lossy().chars() {
            if let Some(p) = app.picker.as_mut() {
                p.type_char(c);
            }
        }
        app.picker_accept();
        assert!(
            app.panes
                .iter()
                .any(|p| matches!(p, crate::pane::Pane::Files(_))),
            "a pasted directory did not open a Files pane"
        );
    }

    /// A path that does not exist must SAY so. Silence is what made the
    /// original report read as the app being broken.
    #[test]
    fn a_pasted_path_that_does_not_exist_says_so() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_file_picker();
        for c in "/nope/does/not/exist.txt".chars() {
            if let Some(p) = app.picker.as_mut() {
                p.type_char(c);
            }
        }
        app.picker_accept();
        let toast = app
            .toast
            .as_ref()
            .map(|(t, _)| t.clone())
            .unwrap_or_default();
        assert!(
            toast.contains("no such file"),
            "silent on a bad path; toast was {toast:?}"
        );
    }
}
