//! The file-tree rail. Scans the workspace once (gitignore-aware, hidden files
//! off by default), keeps an expand/collapse set, and flattens to "visible rows"
//! on demand. Mirrors mnml1's tree but rebuilt from scratch.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

const MAX_ENTRIES: usize = 50_000;

#[derive(Debug, Clone)]
struct Entry {
    path: PathBuf,
    is_dir: bool,
    /// Depth relative to the workspace root: root's direct children are depth 0.
    depth: usize,
}

/// One rendered row of the tree.
#[derive(Debug, Clone)]
pub struct VisibleRow {
    pub path: PathBuf,
    pub is_dir: bool,
    pub is_expanded: bool,
    pub depth: usize,
    pub name: String,
}

#[derive(Debug)]
pub struct Tree {
    root: PathBuf,
    /// All discovered nodes, already in display order (DFS, dirs-first, alpha).
    entries: Vec<Entry>,
    expanded: BTreeSet<PathBuf>,
    /// Cursor index into `visible_rows()`.
    cursor: usize,
    /// First visible row to render (set by the view to keep the cursor on screen).
    pub scroll: usize,
    pub show_hidden: bool,
    /// Optional fuzzy filter — when non-empty, [`Self::visible_rows`] returns
    /// only entries whose `file_name` fuzzy-matches, plus every ancestor dir
    /// on their path (so the hierarchy stays readable). Empty ⇒ no filter.
    pub filter: String,
    /// `true` while the tree is in type-to-filter mode (UI captures keystrokes
    /// into `filter` instead of navigating). Driven by `tui.rs`.
    pub filter_mode: bool,
}

impl Tree {
    pub fn open(root: &Path) -> Self {
        let mut t = Tree {
            root: root.to_path_buf(),
            entries: Vec::new(),
            expanded: BTreeSet::new(),
            cursor: 0,
            scroll: 0,
            show_hidden: true,
            filter: String::new(),
            filter_mode: false,
        };
        t.rescan();
        // Auto-expand the first level so the tree isn't a wall of collapsed dirs.
        let first_level: Vec<PathBuf> = t
            .entries
            .iter()
            .filter(|e| e.is_dir && e.depth == 0)
            .map(|e| e.path.clone())
            .collect();
        for p in first_level {
            t.expanded.insert(p);
        }
        t
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Snapshot of the currently-expanded directories — for session persistence.
    /// Returns absolute paths; the caller can store them as strings.
    pub fn expanded_dirs(&self) -> Vec<PathBuf> {
        self.expanded.iter().cloned().collect()
    }

    /// Collapse every directory in the tree. Cursor + scroll snap back
    /// to the top so the user doesn't end up looking at an empty row.
    pub fn collapse_all(&mut self) {
        self.expanded.clear();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Expand every directory under the workspace root — drives the
    /// "expand all" half of the collapse/expand toggle. Cursor + scroll
    /// snap back to the top so the user can drill down from row 0.
    pub fn expand_all_dirs(&mut self) {
        self.expanded = self
            .entries
            .iter()
            .filter(|e| e.is_dir)
            .map(|e| e.path.clone())
            .collect();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// True when no directory in the tree is expanded — used by the
    /// rail's collapse/expand toggle chip to flip its glyph + behavior.
    pub fn is_fully_collapsed(&self) -> bool {
        self.expanded.is_empty()
    }

    /// Replace the auto-expansion set with exactly `paths` (validated against
    /// existing dirs — unknown paths drop silently). Useful when the caller
    /// has a specific notion of what should be open on first launch, e.g.
    /// the multi-repo workspace case where only the *active* repo dir should
    /// start expanded — non-active repo dirs render as collapsed headers
    /// the user can drill into.
    pub fn expand_only<I: IntoIterator<Item = PathBuf>>(&mut self, paths: I) {
        let present: BTreeSet<PathBuf> = self
            .entries
            .iter()
            .filter(|e| e.is_dir)
            .map(|e| e.path.clone())
            .collect();
        self.expanded = paths
            .into_iter()
            .filter(|p| present.contains(p))
            .collect::<BTreeSet<_>>();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Replace the expansion set with `dirs` (paths previously returned by
    /// [`Self::expanded_dirs`]). Paths that no longer point at directories are
    /// silently dropped. Resets the cursor + scroll to the top.
    pub fn set_expanded_dirs<I: IntoIterator<Item = PathBuf>>(&mut self, dirs: I) {
        let present: BTreeSet<PathBuf> = self
            .entries
            .iter()
            .filter(|e| e.is_dir)
            .map(|e| e.path.clone())
            .collect();
        self.expanded = dirs
            .into_iter()
            .filter(|p| present.contains(p))
            .collect::<BTreeSet<_>>();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Every (non-directory) file under the workspace, in display order — for the file picker.
    pub fn all_files(&self) -> Vec<PathBuf> {
        self.entries
            .iter()
            .filter(|e| !e.is_dir)
            .map(|e| e.path.clone())
            .collect()
    }

    /// Re-scan the workspace, preserving expansion state (dropping stale entries).
    pub fn refresh(&mut self) {
        self.rescan();
        let present: BTreeSet<PathBuf> = self.entries.iter().map(|e| e.path.clone()).collect();
        self.expanded.retain(|p| present.contains(p));
        // multilang-redo 2026-06-28 F3: auto-expand newly-appeared
        // top-level directories so a user who cloned/scaffolded
        // into the workspace post-startup doesn't have to manually
        // press `l` on every fresh top-level entry. Matches the
        // expansion logic in `open()`.
        for entry in &self.entries {
            if entry.is_dir && entry.depth == 0 {
                self.expanded.insert(entry.path.clone());
            }
        }
        let max = self.visible_rows().len().saturating_sub(1);
        self.cursor = self.cursor.min(max);
    }

    fn rescan(&mut self) {
        let mut raw: Vec<Entry> = Vec::new();
        let walker = ignore::WalkBuilder::new(&self.root)
            .hidden(!self.show_hidden)
            .git_ignore(true)
            .git_global(true)
            .git_exclude(true)
            .parents(true)
            // Honor .gitignore even when the workspace isn't (yet) a git repo.
            .require_git(false)
            .max_depth(None)
            .build();
        for dent in walker.flatten() {
            if raw.len() >= MAX_ENTRIES {
                break;
            }
            let path = dent.path();
            if path == self.root {
                continue;
            }
            // multilang 3rd 2026-06-28 F3: hide artifact dirs even
            // when there's no .gitignore. The file picker hardcodes
            // the same exclusions (src/app/picker.rs:98); the tree
            // was the lone surface showing node_modules /
            // __pycache__ / target / .next / dist / build / vendor
            // by default. Aligned the two surfaces. Users who want
            // to see these can `:set hidden` (shows dot-files which
            // is the show_hidden toggle).
            if let Some(name) = path.file_name().and_then(|n| n.to_str())
                && matches!(
                    name,
                    "node_modules"
                        | "__pycache__"
                        | ".next"
                        | "dist"
                        | "build"
                        | "target"
                        | "vendor"
                        | ".venv"
                        | "venv"
                )
            {
                // Skip the directory entirely — `ignore::Walk` would
                // descend into it without a per-file filter hook.
                // We can't tell Walk to prune at this point so we
                // simply omit it; its children still get yielded
                // and would push noise. Skip both the dir and any
                // path UNDER it.
                continue;
            }
            // Also skip files whose ANY ancestor matches one of the
            // artifact names — handles the children of dirs already
            // emitted by Walk.
            let mut artifact_ancestor = false;
            let mut p = path.parent();
            while let Some(pp) = p {
                if pp == self.root {
                    break;
                }
                if let Some(name) = pp.file_name().and_then(|n| n.to_str())
                    && matches!(
                        name,
                        "node_modules"
                            | "__pycache__"
                            | ".next"
                            | "dist"
                            | "build"
                            | "target"
                            | "vendor"
                            | ".venv"
                            | "venv"
                    )
                {
                    artifact_ancestor = true;
                    break;
                }
                p = pp.parent();
            }
            if artifact_ancestor {
                continue;
            }
            let depth = dent.depth().saturating_sub(1);
            let is_dir = dent.file_type().map(|ft| ft.is_dir()).unwrap_or(false);
            raw.push(Entry {
                path: path.to_path_buf(),
                is_dir,
                depth,
            });
        }
        self.entries = order_dfs(&self.root, raw);
    }

    fn ancestors_all_expanded(&self, path: &Path) -> bool {
        let mut cur = path.parent();
        while let Some(p) = cur {
            if p == self.root {
                return true;
            }
            if !self.expanded.contains(p) {
                return false;
            }
            cur = p.parent();
        }
        true
    }

    /// The currently-visible rows, top to bottom.
    pub fn visible_rows(&self) -> Vec<VisibleRow> {
        // When filtering, expand everything along matched paths so the
        // ancestor dirs of a match are visible regardless of the user's
        // expansion state. Otherwise the standard expansion-gate runs.
        if !self.filter.is_empty() {
            let keep = self.filter_visible_set();
            return self
                .entries
                .iter()
                .filter(|e| keep.contains(&e.path))
                .map(|e| VisibleRow {
                    path: e.path.clone(),
                    is_dir: e.is_dir,
                    // While filtering, render all kept dirs as "expanded"
                    // (their matching descendants render below them).
                    is_expanded: e.is_dir,
                    depth: e.depth,
                    name: e
                        .path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("?")
                        .to_string(),
                })
                .collect();
        }
        self.entries
            .iter()
            .filter(|e| self.ancestors_all_expanded(&e.path))
            .map(|e| VisibleRow {
                path: e.path.clone(),
                is_dir: e.is_dir,
                is_expanded: e.is_dir && self.expanded.contains(&e.path),
                depth: e.depth,
                name: e
                    .path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("?")
                    .to_string(),
            })
            .collect()
    }

    /// Set of entry paths that pass the current filter — entries whose
    /// file name fuzzy-matches `self.filter`, plus every ancestor of a
    /// match so the hierarchy is readable.
    fn filter_visible_set(&self) -> BTreeSet<PathBuf> {
        use crate::fuzzy::fuzzy_match;
        let mut keep: BTreeSet<PathBuf> = BTreeSet::new();
        for e in &self.entries {
            let Some(name) = e.path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if fuzzy_match(&self.filter, name).is_some() {
                keep.insert(e.path.clone());
                let mut anc = e.path.parent().map(Path::to_path_buf);
                while let Some(p) = anc {
                    if p == self.root || !p.starts_with(&self.root) {
                        break;
                    }
                    keep.insert(p.clone());
                    anc = p.parent().map(Path::to_path_buf);
                }
            }
        }
        keep
    }

    /// Append `c` to the filter, snap the cursor back to the top.
    pub fn filter_push(&mut self, c: char) {
        self.filter.push(c);
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Pop one char off the filter.
    pub fn filter_pop(&mut self) {
        self.filter.pop();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Clear the filter + exit filter mode.
    pub fn filter_clear_and_exit(&mut self) {
        self.filter.clear();
        self.filter_mode = false;
        self.cursor = 0;
        self.scroll = 0;
    }

    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn selected_row(&self) -> Option<VisibleRow> {
        self.visible_rows().into_iter().nth(self.cursor)
    }

    /// The file path under the cursor (None when the cursor is on a directory).
    pub fn selected_file(&self) -> Option<PathBuf> {
        self.selected_row().filter(|r| !r.is_dir).map(|r| r.path)
    }

    pub fn move_up(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
    }
    pub fn move_down(&mut self) {
        let max = self.visible_rows().len().saturating_sub(1);
        self.cursor = (self.cursor + 1).min(max);
    }
    pub fn set_cursor(&mut self, idx: usize) {
        let max = self.visible_rows().len().saturating_sub(1);
        self.cursor = idx.min(max);
    }

    /// Toggle expand/collapse on the row under the cursor (no-op on files).
    pub fn toggle_current(&mut self) {
        if let Some(row) = self.selected_row()
            && row.is_dir
        {
            if self.expanded.contains(&row.path) {
                self.expanded.remove(&row.path);
            } else {
                self.expanded.insert(row.path);
            }
            let max = self.visible_rows().len().saturating_sub(1);
            self.cursor = self.cursor.min(max);
        }
    }

    /// `→`-style: expand a collapsed dir, or move into the first child of an open one.
    pub fn expand_or_descend(&mut self) {
        if let Some(row) = self.selected_row()
            && row.is_dir
        {
            if !self.expanded.contains(&row.path) {
                self.expanded.insert(row.path);
            } else {
                self.move_down(); // first child is the next visible row
            }
        }
    }

    /// `←`-style: collapse an open dir, or hop up to the parent dir.
    pub fn collapse_or_ascend(&mut self) {
        if let Some(row) = self.selected_row() {
            if row.is_dir && self.expanded.contains(&row.path) {
                self.expanded.remove(&row.path);
                return;
            }
            if let Some(parent) = row.path.parent()
                && parent != self.root
                && let Some(idx) = self.visible_rows().iter().position(|r| r.path == parent)
            {
                self.cursor = idx;
            }
        }
    }
}

/// Reorder a flat, walk-order list into DFS display order: within each directory,
/// directories come first, then files, each group alphabetical (case-insensitive).
fn order_dfs(root: &Path, raw: Vec<Entry>) -> Vec<Entry> {
    let by_path: HashMap<PathBuf, Entry> =
        raw.iter().cloned().map(|e| (e.path.clone(), e)).collect();
    let mut children: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
    for e in &raw {
        let parent = e
            .path
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| root.to_path_buf());
        children.entry(parent).or_default().push(e.path.clone());
    }
    for kids in children.values_mut() {
        kids.sort_by(|a, b| {
            let ad = by_path.get(a).map(|e| e.is_dir).unwrap_or(false);
            let bd = by_path.get(b).map(|e| e.is_dir).unwrap_or(false);
            bd.cmp(&ad) // dirs (true) first
                .then_with(|| {
                    let an = a
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    let bn = b
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    an.cmp(&bn)
                })
        });
    }
    let mut out = Vec::with_capacity(raw.len());
    let mut stack: Vec<PathBuf> = children
        .get(root)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .rev()
        .collect();
    while let Some(p) = stack.pop() {
        if let Some(e) = by_path.get(&p) {
            let is_dir = e.is_dir;
            out.push(e.clone());
            if is_dir && let Some(kids) = children.get(&p) {
                for k in kids.iter().rev() {
                    stack.push(k.clone());
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn workspace() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        fs::create_dir(d.path().join("src")).unwrap();
        fs::write(d.path().join("src").join("main.rs"), "fn main() {}").unwrap();
        fs::write(d.path().join("src").join("lib.rs"), "").unwrap();
        fs::create_dir(d.path().join("src").join("ui")).unwrap();
        fs::write(d.path().join("src").join("ui").join("mod.rs"), "").unwrap();
        fs::write(d.path().join("Cargo.toml"), "[package]").unwrap();
        fs::write(d.path().join(".gitignore"), "target\n").unwrap();
        fs::create_dir(d.path().join("target")).unwrap();
        fs::write(d.path().join("target").join("junk"), "x").unwrap();
        d
    }

    #[test]
    fn first_level_auto_expanded_and_gitignore_honored() {
        let d = workspace();
        let t = Tree::open(d.path());
        let rows = t.visible_rows();
        let names: Vec<&str> = rows.iter().map(|r| r.name.as_str()).collect();
        // `src` is a dir at depth 0 → auto-expanded → its children show; `target` is gitignored.
        assert!(names.contains(&"src"));
        assert!(names.contains(&"main.rs"));
        assert!(names.contains(&"Cargo.toml"));
        assert!(!names.iter().any(|n| *n == "target" || *n == "junk"));
        // dirs before files within `src`
        let src_pos = rows.iter().position(|r| r.name == "src").unwrap();
        let ui_pos = rows.iter().position(|r| r.name == "ui").unwrap();
        let main_pos = rows.iter().position(|r| r.name == "main.rs").unwrap();
        assert!(src_pos < ui_pos && ui_pos < main_pos);
    }

    #[test]
    fn collapse_hides_children() {
        let d = workspace();
        let mut t = Tree::open(d.path());
        // cursor on `src` (first row)
        assert_eq!(t.selected_row().unwrap().name, "src");
        t.toggle_current(); // collapse src
        let names: Vec<String> = t.visible_rows().iter().map(|r| r.name.clone()).collect();
        assert!(names.contains(&"src".to_string()));
        assert!(!names.contains(&"main.rs".to_string()));
    }

    #[test]
    fn selected_file_is_none_on_dir() {
        let d = workspace();
        let t = Tree::open(d.path());
        assert!(t.selected_file().is_none()); // on `src` (a dir)
    }

    #[test]
    fn expand_only_replaces_default_expansion() {
        let d = workspace();
        let mut t = Tree::open(d.path());
        // Default: `src` is expanded → `main.rs` visible.
        assert!(t.visible_rows().iter().any(|r| r.name == "main.rs"));
        // Restrict the expansion to just the workspace root (i.e. nothing
        // at depth 0 stays expanded) — `src/`'s children disappear.
        t.expand_only::<Vec<PathBuf>>(Vec::new());
        let names: Vec<String> = t.visible_rows().iter().map(|r| r.name.clone()).collect();
        assert!(names.contains(&"src".to_string()));
        assert!(!names.contains(&"main.rs".to_string()));
    }

    #[test]
    fn artifact_dirs_hidden_without_gitignore() {
        // multilang 3rd 2026-06-28 F3 — node_modules / __pycache__ /
        // target / .next / dist / build / vendor / .venv / venv are
        // hidden by default regardless of .gitignore. Picker already
        // does this; the tree was the lone surface showing them.
        let d = tempfile::tempdir().unwrap();
        for art in [
            "node_modules",
            "__pycache__",
            "target",
            ".next",
            "dist",
            "build",
            "vendor",
            ".venv",
        ] {
            fs::create_dir_all(d.path().join(art)).unwrap();
            fs::write(d.path().join(art).join("foo"), "x").unwrap();
        }
        fs::create_dir_all(d.path().join("src")).unwrap();
        fs::write(d.path().join("src").join("index.ts"), "console.log('hi')").unwrap();
        let t = Tree::open(d.path());
        let names: Vec<String> = t.visible_rows().iter().map(|r| r.name.clone()).collect();
        for art in [
            "node_modules",
            "__pycache__",
            "target",
            ".next",
            "dist",
            "build",
            "vendor",
            ".venv",
        ] {
            assert!(
                !names.contains(&art.to_string()),
                "{art} should be hidden by default; got: {names:?}"
            );
        }
        assert!(names.contains(&"src".to_string()));
    }

    #[test]
    fn filter_narrows_and_keeps_ancestors() {
        let d = workspace();
        let mut t = Tree::open(d.path());
        // Filter for "main" — should match `main.rs` and keep `src/`.
        t.filter_push('m');
        t.filter_push('a');
        t.filter_push('i');
        t.filter_push('n');
        let names: Vec<String> = t.visible_rows().iter().map(|r| r.name.clone()).collect();
        assert!(names.contains(&"src".to_string()));
        assert!(names.contains(&"main.rs".to_string()));
        assert!(!names.contains(&"lib.rs".to_string()));
        assert!(!names.contains(&"Cargo.toml".to_string()));
        // Clear → everything visible again.
        t.filter_clear_and_exit();
        let names: Vec<String> = t.visible_rows().iter().map(|r| r.name.clone()).collect();
        assert!(names.contains(&"lib.rs".to_string()));
        assert!(names.contains(&"Cargo.toml".to_string()));
    }
}
