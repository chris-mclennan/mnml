//! The which-key leader menu (NvChad-style). After a leader key — `<space>` in
//! vim Normal mode, `Ctrl+K` in the standard keymap — a popup lists the available
//! key continuations; each subsequent key descends a small trie; a leaf runs its
//! command. Esc (or a key with no continuation) closes it.
//!
//! The leader map is a built-in default for now; a `[keys.leader]` config overlay
//! and which-key popups for the vim *operator* prefixes (`g…`, `d…`) are later
//! refinements — for P3b this is leader-only, and a binding is strictly a leaf
//! *or* a group, never both, which keeps the state machine a one-liner.

use std::collections::BTreeMap;
use std::sync::OnceLock;

#[derive(Debug)]
pub enum Leader {
    /// A leaf: running `id` closes the menu. `label` is shown in the popup.
    Cmd {
        id: &'static str,
        label: &'static str,
    },
    /// A submenu. `label` (e.g. `"+find"`) heads it in the popup.
    Group {
        label: &'static str,
        children: BTreeMap<char, Leader>,
    },
}

impl Leader {
    pub fn label(&self) -> &'static str {
        match self {
            Leader::Cmd { label, .. } => label,
            Leader::Group { label, .. } => label,
        }
    }
    pub fn is_group(&self) -> bool {
        matches!(self, Leader::Group { .. })
    }
}

fn cmd(id: &'static str, label: &'static str) -> Leader {
    Leader::Cmd { id, label }
}
fn group(label: &'static str, kids: Vec<(char, Leader)>) -> Leader {
    Leader::Group {
        label,
        children: kids.into_iter().collect(),
    }
}

/// The root of the leader trie (built once).
pub fn root() -> &'static Leader {
    static ROOT: OnceLock<Leader> = OnceLock::new();
    ROOT.get_or_init(|| {
        group(
            "<leader>",
            vec![
                (
                    'f',
                    group(
                        "+find",
                        vec![
                            ('f', cmd("picker.files", "files")),
                            ('b', cmd("picker.buffers", "buffers")),
                        ],
                    ),
                ),
                (
                    'b',
                    group(
                        "+buffer",
                        vec![
                            ('n', cmd("buffer.next", "next")),
                            ('p', cmd("buffer.prev", "previous")),
                            ('d', cmd("buffer.close", "delete")),
                        ],
                    ),
                ),
                (
                    't',
                    group(
                        "+toggle",
                        vec![
                            ('e', cmd("view.toggle_tree", "explorer")),
                            ('k', cmd("editor.toggle_keymap", "vim ⇄ standard")),
                            ('t', cmd("theme.pick", "theme…")),
                        ],
                    ),
                ),
                (
                    'g',
                    group(
                        "+git",
                        vec![
                            ('d', cmd("git.diff_file", "diff file")),
                            ('D', cmd("git.diff", "diff worktree")),
                            ('b', cmd("git.blame_toggle", "blame toggle")),
                            ('c', cmd("git.commit", "commit")),
                        ],
                    ),
                ),
                (
                    'h',
                    group(
                        "+http",
                        vec![
                            ('s', cmd("rqst.send", "send request")),
                            ('y', cmd("rqst.copy_curl", "copy as curl")),
                        ],
                    ),
                ),
                (
                    's',
                    group(
                        "+split",
                        vec![
                            ('v', cmd("view.split_right", "split right")),
                            ('s', cmd("view.split_down", "split down")),
                            ('h', cmd("view.focus_left", "focus left")),
                            ('j', cmd("view.focus_down", "focus down")),
                            ('k', cmd("view.focus_up", "focus up")),
                            ('l', cmd("view.focus_right", "focus right")),
                            ('w', cmd("view.focus_next_split", "focus next")),
                            ('c', cmd("view.close_split", "close split")),
                        ],
                    ),
                ),
                ('w', cmd("file.save", "write/save")),
                ('q', cmd("buffer.close", "close buffer")),
                ('e', cmd("view.toggle_tree", "explorer")),
                ('m', cmd("markdown.preview", "markdown preview")),
                ('p', cmd("palette", "command palette")),
                ('r', cmd("app.restart", "restart mnml")),
            ],
        )
    })
}

/// Walk the trie following `prefix` from the root. `""` ⇒ the root group itself.
pub fn lookup(prefix: &str) -> Option<&'static Leader> {
    let mut node = root();
    for ch in prefix.chars() {
        match node {
            Leader::Group { children, .. } => node = children.get(&ch)?,
            Leader::Cmd { .. } => return None,
        }
    }
    Some(node)
}

/// One continuation row for the popup: `(key, label, is_group)`.
pub type Entry = (char, &'static str, bool);

/// The continuations available at `prefix`, for rendering. Empty if `prefix`
/// isn't a group.
pub fn continuations(prefix: &str) -> Vec<Entry> {
    match lookup(prefix) {
        Some(Leader::Group { children, .. }) => children
            .iter()
            .map(|(&k, v)| (k, v.label(), v.is_group()))
            .collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_has_groups_and_leaves() {
        assert!(matches!(lookup(""), Some(Leader::Group { .. })));
        assert!(matches!(lookup("f"), Some(Leader::Group { .. })));
        assert!(matches!(
            lookup("ff"),
            Some(Leader::Cmd {
                id: "picker.files",
                ..
            })
        ));
        assert!(matches!(
            lookup("w"),
            Some(Leader::Cmd {
                id: "file.save",
                ..
            })
        ));
    }

    #[test]
    fn dead_ends_are_none() {
        assert!(lookup("z").is_none());
        assert!(lookup("fz").is_none());
        // descending past a leaf is a dead end
        assert!(lookup("wx").is_none());
    }

    #[test]
    fn continuations_lists_children() {
        let c = continuations("f");
        assert!(c.iter().any(|&(k, l, g)| k == 'f' && l == "files" && !g));
        assert!(c.iter().any(|&(k, _, _)| k == 'b'));
        assert!(continuations("ff").is_empty()); // a leaf has none
        assert!(continuations("z").is_empty()); // a dead end has none
    }
}
