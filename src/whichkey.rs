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

/// 2026-06-21 multilang SEV-3 runners-npm-priority-no-disambiguation:
/// walk the leader trie and emit `(chord_path, command_id)` for
/// every leaf. The cheatsheet uses this to surface leader-chord
/// bindings so they don't show up as `(unbound)`. Leader prefix
/// is `<leader>` so a `<leader>Lct` binding for `cargo.test`
/// emits `("<leader>L c t", "cargo.test")`.
pub fn enumerate_leaves() -> Vec<(String, &'static str)> {
    let mut out = Vec::new();
    walk(root(), String::from("<leader>"), &mut out);
    out
}

fn walk(node: &'static Leader, path: String, out: &mut Vec<(String, &'static str)>) {
    match node {
        Leader::Cmd { id, .. } => out.push((path, id)),
        Leader::Group { children, .. } => {
            for (ch, child) in children.iter() {
                let next_path = if path == "<leader>" {
                    format!("<leader>{ch}")
                } else {
                    format!("{path}{ch}")
                };
                walk(child, next_path, out);
            }
        }
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
                            // NvChad parity: `<leader>fg` = workspace
                            // grep. Bug-hunt seed #272 from 2026-06-07
                            // nvchad-user hunt — chord was missing.
                            ('g', cmd("find.grep", "grep")),
                            // nvchad-parity #1142 (2026-08-22) —
                            // `<leader>fm` = format buffer. NvChad
                            // binds this to conform.format;
                            // mnml routes to lsp.format.
                            ('m', cmd("lsp.format", "format buffer")),
                        ],
                    ),
                ),
                // nvchad-parity #1142 (2026-08-22) — `<leader>/`
                // toggles line comment. NvChad's canonical shortcut
                // — mnml had `Ctrl+/` and `gcc` but the leader chord
                // was missing.
                ('/', cmd("editor.toggle_line_comment", "toggle comment")),
                // nvchad-parity #1142 (2026-08-22) — `<leader>n`
                // toggles the line-number gutter. Not a group at
                // root (single leaf), so muscle-memory `<leader>n`
                // doesn't wait for a second key.
                ('n', cmd("view.toggle_line_numbers", "line numbers")),
                // nvchad-parity SEV-3 f/u (2026-08-22) — `<leader>ch`
                // opens the cheatsheet, matching NvChad's canonical
                // chord (`<leader>?` also works but muscle memory is
                // `ch`). Group scaffolds a `+nvchad` slot for other
                // NvChad-ish chords to slot in later.
                (
                    'c',
                    group(
                        "+nvchad",
                        vec![('h', cmd("view.cheatsheet", "cheatsheet (all chords)"))],
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
                            ('r', cmd("buffer.reopen", "reopen closed")),
                        ],
                    ),
                ),
                (
                    't',
                    group(
                        "+toggle",
                        vec![
                            ('e', cmd("view.toggle_tree", "explorer")),
                            ('r', cmd("view.toggle_right_panel", "right panel")),
                            (']', cmd("view.right_panel_next_tab", "right panel: next")),
                            ('[', cmd("view.right_panel_prev_tab", "right panel: prev")),
                            // design-critic + claude-agents-power-user
                            // 2026-06-28: "evict" was unique vocabulary
                            // — every other surface (palette title,
                            // context menu, × tooltip) said "close".
                            // Aligned for whichkey/palette searchability.
                            (
                                'x',
                                cmd("view.right_panel_close_tab", "right panel: close tab"),
                            ),
                            ('k', cmd("editor.toggle_keymap", "vim ⇄ standard")),
                            ('t', cmd("theme.pick", "theme…")),
                            ('h', cmd("view.toggle_hidden", "hidden files (focused)")),
                            ('H', cmd("view.toggle_hidden_all", "hidden files (all)")),
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
                            ('A', cmd("git.diff_all", "diff all vs HEAD (multi-file)")),
                            ('p', cmd("git.peek_change", "peek change at cursor")),
                            ('b', cmd("git.blame_toggle", "blame toggle")),
                            ('c', cmd("git.commit", "commit")),
                            ('l', cmd("git.graph", "commit graph")),
                            ('s', cmd("git.status_pane", "status / staging")),
                            ('m', cmd("git.ai_commit", "ai (Claude) commit message")),
                            ('M', cmd("git.ai_recompose", "ai rewrite HEAD msg")),
                            ('x', cmd("git.codex_commit", "codex commit message")),
                            ('o', cmd("git.checkout", "checkout branch")),
                            ('n', cmd("git.new_branch", "new branch")),
                            ('w', cmd("git.worktrees", "worktrees → shell")),
                            ('S', cmd("git.stash", "stash (with optional msg)")),
                            ('P', cmd("git.stash_pop", "stash pop")),
                        ],
                    ),
                ),
                (
                    'h',
                    group(
                        "+http",
                        vec![
                            ('s', cmd("http.send", "send request")),
                            ('y', cmd("http.copy_curl", "copy as curl")),
                            ('d', cmd("http.ai_debug", "ask Claude (debug)")),
                            (']', cmd("http.next_block", "next ### block")),
                            ('[', cmd("http.prev_block", "previous ### block")),
                        ],
                    ),
                ),
                (
                    'T',
                    group(
                        "+test",
                        vec![
                            ('a', cmd("test.run_all", "run all")),
                            ('f', cmd("test.run_file", "run this file")),
                            ('t', cmd("test.run_at_cursor", "run test at cursor")),
                            ('l', cmd("test.rerun_failed", "re-run last-failed")),
                            ('h', cmd("test.heal", "heal failing test (Claude)")),
                            ('w', cmd("flaky.show", "flaky/wobbly dashboard")),
                        ],
                    ),
                ),
                // 2026-06-21 multilang SEV-3 runners-no-whichkey-group:
                // language-specific runner family. Two-level prefix
                // — `<leader>Lc` for cargo, `<leader>Ln` for npm,
                // `<leader>Lp` for pytest, `<leader>Lg` for go. The
                // generic `<leader>T` group (above) handles
                // framework-agnostic test commands. `L` chosen to
                // avoid the prior `<leader>r` accident — see comment
                // below — and `R` (which read as redo). `L` reads
                // as "language" + has no vim-canonical at root.
                (
                    'L',
                    group(
                        "+lang/run",
                        vec![
                            (
                                'c',
                                group(
                                    "+cargo",
                                    vec![
                                        ('t', cmd("cargo.test", "cargo test")),
                                        ('b', cmd("cargo.build", "cargo build")),
                                        ('r', cmd("cargo.run", "cargo run")),
                                        ('c', cmd("cargo.check", "cargo check")),
                                        ('l', cmd("cargo.clippy", "cargo clippy")),
                                        ('f', cmd("cargo.fmt", "cargo fmt")),
                                    ],
                                ),
                            ),
                            (
                                'n',
                                group(
                                    "+npm",
                                    vec![
                                        ('t', cmd("npm.test", "npm test")),
                                        ('b', cmd("npm.build", "npm run build")),
                                        ('r', cmd("npm.run", "npm run dev")),
                                        ('s', cmd("npm.start", "npm start")),
                                        ('i', cmd("npm.install", "npm install")),
                                        ('l', cmd("npm.lint", "npm run lint")),
                                        ('x', cmd("npm.run_script", "run an npm script (prompt)")),
                                    ],
                                ),
                            ),
                            (
                                'p',
                                group(
                                    "+pytest",
                                    vec![
                                        ('t', cmd("pytest.run", "pytest")),
                                        ('l', cmd("pytest.failed", "pytest --lf")),
                                    ],
                                ),
                            ),
                            (
                                'g',
                                group(
                                    "+go",
                                    vec![
                                        ('t', cmd("go.test", "go test ./...")),
                                        ('b', cmd("go.build", "go build")),
                                        ('r', cmd("go.run", "go run .")),
                                        ('v', cmd("go.vet", "go vet ./...")),
                                        ('p', cmd("go.run_path", "go run <path> (prompt)")),
                                    ],
                                ),
                            ),
                        ],
                    ),
                ),
                (
                    'P',
                    group(
                        "+pr",
                        vec![
                            (
                                'p',
                                cmd(
                                    "pr.picker",
                                    "PRs: cross-host picker (Enter URL / Tab pipeline)",
                                ),
                            ),
                            (
                                'r',
                                cmd("pr.refresh", "PRs: refresh cross-host cache (background)"),
                            ),
                        ],
                    ),
                ),
                (
                    'i',
                    group(
                        "+integrations",
                        vec![
                            (
                                'd',
                                cmd(
                                    "integrations.show_details",
                                    "detail pane (description / buttons / links)",
                                ),
                            ),
                            // 2026-08-03 — the ~20 forge.open_* chord bindings
                            // that lived here (bitbucket / github / gitlab /
                            // azdevops / codebuild / s3 / azure_blob /
                            // cloudwatch_logs / amplify / dynamodb / lambda /
                            // eventbridge / rds / ecs / ecr / cognito / sqs /
                            // sns) were dropped alongside the corresponding
                            // hardcoded palette commands in command.rs — the
                            // integration binaries they pointed at are all retired
                            // (ecosystem consolidated to mnml + mnml-integrations
                            // + mnml-tattle-tests). Anything a user installs
                            // through the marketplace now registers its OWN
                            // command via IntegrationManifest.commands + can
                            // bind its own chords via [keys.global] in user
                            // config or [[commands]].keys in the manifest.
                            //
                            // Also unwedges the previous 'd'/'C'/'E' collisions
                            // (integrations.show_details vs forge.open_dynamodb;
                            // tools.btop vs forge.open_ecs; integrations.toggle_enabled
                            // vs forge.open_ecr — each pair silently shadowed one
                            // side).
                            ('h', cmd("tools.htop", "htop — interactive process viewer")),
                            (
                                'I',
                                cmd("tools.iftop", "iftop — interactive bandwidth monitor"),
                            ),
                            ('r', cmd("tools.btop", "btop — resource monitor")),
                            (
                                'p',
                                cmd("integrations.icon_picker", "browse Nerd Font glyphs"),
                            ),
                            (
                                'E',
                                cmd("integrations.toggle_enabled", "enable/disable a chip"),
                            ),
                            // 2026-08-03 — same removal as the block above.
                            // The datadog/buttondown/slack/teams/mandrill/
                            // docker/gmail/gcal/jira/cloudflare bindings all
                            // pointed at now-retired forge.open_* palette
                            // commands. Users install these via marketplace
                            // now (chord binding comes from manifest).
                        ],
                    ),
                ),
                (
                    'a',
                    group(
                        "+ai/term",
                        vec![
                            ('a', cmd("ai.ask", "ask claude…")),
                            ('b', cmd("ai.toggle_backend", "toggle backend (cli ↔ api)")),
                            ('d', cmd("ai.dashboard", "agents dashboard")),
                            ('e', cmd("ai.explain", "explain selection")),
                            ('f', cmd("ai.fix", "fix bugs")),
                            ('r', cmd("ai.refactor", "refactor")),
                            ('w', cmd("ai.write_tests", "write tests")),
                            ('m', cmd("ai.session_view", "mirror session")),
                            ('t', cmd("term.shell", "shell")),
                            ('c', cmd("ai.claude_code", "claude code")),
                            ('n', cmd("ai.claude_code_new", "new claude session")),
                            ('C', cmd("ai.chat", "claude chat (context)")),
                            ('x', cmd("ai.codex", "codex")),
                            ('X', cmd("ai.codex_new", "new codex session")),
                            ('M', cmd("mixr.show", "mixr DJ")),
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
                            ('o', cmd("view.close_others", "close others")),
                        ],
                    ),
                ),
                (
                    'l',
                    group(
                        "+lsp",
                        vec![
                            ('a', cmd("lsp.code_action", "code actions")),
                            ('c', cmd("lsp.completion", "complete at cursor")),
                            ('s', cmd("lsp.symbols", "symbols in this file")),
                            ('S', cmd("lsp.workspace_symbols", "workspace symbols…")),
                            ('o', cmd("outline.show", "outline pane")),
                            ('d', cmd("lsp.goto_definition", "go to definition")),
                            ('h', cmd("lsp.hover", "hover docs")),
                            ('r', cmd("lsp.references", "find references")),
                            ('R', cmd("lsp.rename", "rename symbol")),
                            ('e', cmd("lsp.diagnostics", "diagnostics list")),
                            ('n', cmd("lsp.next_diagnostic", "next diagnostic")),
                            ('p', cmd("lsp.prev_diagnostic", "prev diagnostic")),
                        ],
                    ),
                ),
                (
                    'I',
                    group(
                        "+insert",
                        vec![
                            ('s', cmd("snippet.pick", "snippet…")),
                            ('x', cmd("snippet.expand", "expand snippet at cursor")),
                        ],
                    ),
                ),
                // `+C` (CI) and `+P` (PR) chord groups removed after
                // the 2026-06 SCM split — all four hosts ship as
                // mnml-forge-* integrations, launched via the integration
                // icons in the rail.
                (
                    'H',
                    group(
                        "+harpoon",
                        vec![
                            ('a', cmd("harpoon.add", "pin active file")),
                            ('m', cmd("harpoon.menu", "menu / picker")),
                        ],
                    ),
                ),
                ('1', cmd("harpoon.goto_1", "harpoon 1")),
                ('2', cmd("harpoon.goto_2", "harpoon 2")),
                ('3', cmd("harpoon.goto_3", "harpoon 3")),
                ('4', cmd("harpoon.goto_4", "harpoon 4")),
                ('5', cmd("harpoon.goto_5", "harpoon 5")),
                ('6', cmd("harpoon.goto_6", "harpoon 6")),
                ('7', cmd("harpoon.goto_7", "harpoon 7")),
                ('8', cmd("harpoon.goto_8", "harpoon 8")),
                ('9', cmd("harpoon.goto_9", "harpoon 9")),
                ('?', cmd("view.cheatsheet", "cheatsheet (all chords)")),
                ('w', cmd("file.save", "write/save")),
                ('B', cmd("browser.open", "open browser (Chrome/CDP)")),
                ('q', cmd("buffer.close", "close buffer")),
                ('e', cmd("view.toggle_tree", "explorer")),
                ('m', cmd("markdown.preview", "markdown preview")),
                ('p', cmd("palette", "command palette")),
                ('o', cmd("task.run", "run task…")),
                // 2026-06-13 nvchad-user SEV-1 follow-up: `<leader>r`
                // used to fire `app.restart`, but `r` reads as
                // redo/rename in any vim-flavoured leader chord and
                // a reflexive `<leader>r` was wiping the running app
                // mid-edit. Removed; `:rebuild` ex-command + the
                // command palette (`<leader>p`) still expose restart
                // for the rare time anyone actually wants it.
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
    fn integrations_group_is_reachable() {
        // Regression: 'i' was double-registered with both `+integrations`
        // and `+insert`; BTreeMap dedup made `+integrations` unreachable.
        // `+insert` now lives under 'I'.
        match lookup("i") {
            Some(Leader::Group { label, .. }) => assert_eq!(*label, "+integrations"),
            other => panic!("expected +integrations group at 'i', got {other:?}"),
        }
        // 2026-08-03 — The `ib`/`iw`/`ie` bindings that used to test
        // `forge.open_bitbucket`/`forge.open_cloudwatch_logs`/
        // `forge.open_eventbridge` are gone; the palette + chord chain
        // stopped hosting hardcoded integration launchers now that the
        // ecosystem consolidated into the marketplace catalog. Just
        // assert the surviving invariants — `E` still reaches the
        // toggle-enabled picker (the 2026-06-28 SEV-1 fix for the
        // BTreeMap last-wins collision on 'e' isn't reintroduced by
        // this cleanup — 'e' is now free but nothing binds it here).
        assert!(matches!(
            lookup("iE"),
            Some(Leader::Cmd {
                id: "integrations.toggle_enabled",
                ..
            })
        ));
        assert!(matches!(
            lookup("Is"),
            Some(Leader::Cmd {
                id: "snippet.pick",
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
