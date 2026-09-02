//! One glyph per menu row — the `MenuAction → glyph` table.
//!
//! User ask: "all rows on all dropdowns and right click menus and such
//! should have glyphs for each one like we did for menubar."
//!
//! A shared visual-constant module rather than a `match` buried in the
//! renderer, for the same reason `search_glyph` / `refresh_glyph` /
//! `action_button` are: two call sites already paint menu rows (the menu
//! and its submenu), and any future one must agree with them.
//!
//! **Grouped by meaning, not by variant.** Actions that do the same kind
//! of thing share a glyph — every delete is `` , every copy is `` —
//! so the menu reads as a small vocabulary the user learns once, instead
//! of 132 individually-chosen icons they have to learn separately.
//!
//! Returning `""` is a legitimate answer, not a gap: a row whose glyph
//! would be arbitrary is better left blank than given a misleading one.
//! `is_empty()` callers pad the column so blank rows still align.

use crate::context_menu::MenuAction;

/// Nerd Font glyph for a menu row, or `""` when none fits.
///
/// ASCII mode is the caller's decision — it passes the result through
/// [`for_action_ascii`] instead, which returns `""` for everything so an
/// `ascii_icons` user's menus look exactly as they did before.
pub fn for_action(a: &MenuAction) -> &'static str {
    use MenuAction as M;
    match a {
        // ── Open / reveal / navigate ──
        M::OpenPath(..)
        | M::OpenPathAsText(..)
        | M::OpenFilesPane(..)
        | M::OpenCloudAgentRunDetail(..)
        | M::OpenCloudWatchPane { .. }
        | M::OpenS3Pane { .. }
        | M::DiffOpenAtRevision { .. }
        | M::JumpToEnvVar(..) => "\u{f07c}", // folder-open
        M::OpenInSplit(..) | M::SplitTabInto(..) | M::HostInBottomPanel(..) => "\u{f0db}", // columns
        M::RevealInFinder(..) => "\u{f002}",                                               // search
        M::OpenExternally(..) | M::OpenUrl(..) => "\u{f08e}", // external-link
        M::OpenBookmarks(..) => "\u{f02e}",                   // bookmark
        M::OpenTerminal(..) | M::GitWorktreeShell(..) => "\u{f120}", // terminal
        M::PreviewMarkdown(..) => "\u{f06e}",                 // eye — matches the Preview chip

        // ── Clipboard ──
        M::CopyPath(..)
        | M::CopyText(..)
        | M::CopyIntegrationId(..)
        | M::FileCopy(..)
        | M::FilesCopyMarked(..)
        | M::FileDuplicate(..) => "\u{f0c5}", // copy
        M::FileCut(..) | M::FilesCutMarked(..) => "\u{f0c4}", // scissors
        M::FilePaste(..) => "\u{f0ea}",                       // paste
        M::FileMoveTo(..) => "\u{f0b2}",                      // arrows

        // ── Create ──
        M::NewFile(..) => "\u{f15b}",   // file
        M::NewFolder(..) => "\u{f07b}", // folder
        M::NewAiLaunchProfile(..) | M::GitNewBranchFrom(..) => "\u{f067}", // plus

        // ── Edit / configure ──
        M::Rename(..)
        | M::RenameSession(..)
        | M::SessionRename(..)
        | M::WorkspaceEditName(..)
        | M::WorkspaceEditPath(..)
        | M::WorkspaceEditGroup(..)
        | M::EditIntegration(..)
        | M::SetEnvVarValue(..)
        | M::ConfigureIntegration(..)
        | M::SetIntegrationLauncher(..) => "\u{f044}", // pencil

        // ── Destructive ──
        M::Delete(..)
        | M::RemoveIntegration(..)
        | M::RemoveAiLaunchProfile(..)
        | M::RemovePrimaryWorkspace
        | M::WorkspaceDelete(..)
        | M::GitDeleteBranch(..)
        | M::GitTagDelete(..)
        | M::GitStashDrop(..)
        | M::GitWorktreeRemove(..)
        | M::RemoveIntegrationFromActivityBar(..) => "\u{f1f8}", // trash
        M::CloseTab(..)
        | M::CloseOtherTabs(..)
        | M::CloseAllTabs
        | M::CloseOtherRightPanelTabs(..)
        | M::CloseAllRightPanelTabs
        | M::SessionClose(..)
        | M::StopManagedSession(..) => "\u{f00d}", // times

        // ── Pin / hide ──
        M::PinTab(..) | M::PlusMenuPin(..) | M::PlusMenuUnpin(..) | M::SessionTogglePin(..) => {
            "\u{f08d}" // thumbtack
        }
        M::PlusMenuHide(..) => "\u{f070}", // eye-slash

        // ── Git ──
        M::GitSwitchRepo(..) | M::GitReopenRepo(..) => "\u{f1d3}", // git
        M::GitCheckoutBranch(..)
        | M::GitRemoteCheckout(..)
        | M::GitMergeBranchInto(..)
        | M::GitRebaseCurrentOnto(..) => "\u{f126}", // code-fork
        M::GitStageFile(..) => "\u{f067}",                         // plus
        M::GitUnstageFile(..) => "\u{f068}",                       // minus
        M::GitDiscardFile(..) => "\u{f0e2}",                       // undo
        M::GitIgnoreFile(..) | M::GitIgnoreExtension(..) => "\u{f070}", // eye-slash
        M::GitStashFile(..) | M::GitStashPop(..) | M::GitStashApply(..) => "\u{f187}", // archive

        // ── Ordering ──
        M::SessionMoveUp(..)
        | M::WorkspaceMoveUp(..)
        | M::ExtraWorkspaceMoveUp(..)
        | M::MoveIntegrationUp(..)
        | M::MovePinnedIntegrationUp(..) => "\u{f062}", // arrow-up
        M::SessionMoveDown(..)
        | M::WorkspaceMoveDown(..)
        | M::ExtraWorkspaceMoveDown(..)
        | M::MoveIntegrationDown(..)
        | M::MovePinnedIntegrationDown(..) => "\u{f063}", // arrow-down
        M::SessionMoveToTop(..)
        | M::MoveIntegrationToTop(..)
        | M::MovePinnedIntegrationToTop(..) => "\u{f102}", // angle-double-up
        M::SessionMoveToBottom(..)
        | M::MoveIntegrationToBottom(..)
        | M::MovePinnedIntegrationToBottom(..) => "\u{f103}", // angle-double-down
        M::SessionSortAuto | M::ReorderStatuslineSegment(..) => "\u{f0dc}", // sort

        // ── Toggles ──
        M::ToggleIntegrationEnabled(..)
        | M::ToggleIntegrationPaletteBar(..)
        | M::ToggleLauncherEnabled(..)
        | M::SetIntegrationAutoUpdate(..)
        | M::FilesToggleMark(..) => "\u{f205}", // toggle-on

        // ── Workspace ──
        M::SetAsWorkspace(..)
        | M::SetDefaultWorkspace
        | M::SetDefaultWorkspaceAt(..)
        | M::WorkspaceSetDefault(..)
        | M::SwitchToExtraWorkspace(..) => "\u{f0c9}", // bars

        // ── Tree ──
        M::TreeExpandRecursive(..) => "\u{f0fe}", // plus-square
        M::TreeCollapseRecursive(..) => "\u{f146}", // minus-square

        // ── Terminal / process ──
        M::TogglePanelAutoRefresh(..) => "\u{f021}", // refresh
        M::MarkMessagesSeen => "\u{f00c}",           // check
        M::CopyLastMessage | M::CopyAllMessages => "\u{f0c5}", // copy
        M::SetPanelSort(..) => "\u{f0dc}",           // sort
        M::PtyRestart(..) => "\u{f021}",             // refresh
        M::PtyInterrupt(..) => "\u{f04d}",           // stop
        M::PtyClear(..) => "\u{f12d}",               // eraser

        // ── Run ──
        // `Command` is a generic wrapper used by dozens of rows, so one
        // glyph here rendered whole menus as a single repeated icon
        // (user: "i see too much repetition... its like we quit trying"
        // — the pty menu was twelve identical play triangles). Derive
        // it from the command id instead.
        M::Command(id) => command_glyph(id),
        M::RunCmd(..) => "\u{f04b}", // play
        // Agents / skills / slash-commands offered on a TODO row.
        M::TodoAction { .. } => "\u{F06A9}",     // robot
        M::RunIntegrationDiag(..) => "\u{f0f1}", // stethoscope

        // ── Info ──
        M::ShowIntegrationDetails(..) | M::ShowIntegrationManifest(..) => "\u{f05a}", // info-circle
        M::ShowIntegrationInMarketplace(..) => "\u{f07a}", // shopping-cart
        M::UpdateIntegration(..) => "\u{f019}",            // download

        // ── Appearance ──
        M::SetTheme(..) | M::SessionSetColor(..) => "\u{f043}", // tint
        M::OpenGlyphBuilderForCp(..) | M::RebakeGlyphForCp(..) => "\u{f031}", // font

        // ── Save ──
        M::SavePane(..) => "\u{f0c7}", // save

        // ── AI ──
        M::OpenAiSessionWithProfile(..) | M::SetAiDefaultProfile(..) => "\u{f0e7}", // bolt

        M::AddIntegrationToActivityBar(..) | M::LaunchPinnedIntegration(..) => "\u{f0fe}",

        // A submenu already carries its `▸` affordance on the right; a
        // glyph on the left as well would double-mark the same fact.
        M::Submenu => "",

        // Deliberately blank — a positional/contextual action whose glyph
        // would be invented rather than meaningful.
        M::SetRightPanelTab(..) | M::SetTopBarClusterMode(..) | M::DiffHunkAction { .. } => "",
    }
}

/// Glyph for a `MenuAction::Command(id)` row, keyed off the command id.
///
/// ACTION FIRST, then domain. A command id is `namespace.action`, and
/// the action is what the row DOES — so `editor.undo` is an undo, not
/// an edit, and `git.push` is a push, not a generic git operation.
///
/// The first version matched substrings against the WHOLE id in one
/// ordered pass, which let a namespace swallow everything under it:
/// `("git", …)` claimed all fifty git commands, `("edit", …)` claimed
/// every `editor.*`, and 339 of 789 commands (43%) fell through to a
/// play triangle. The result was menus that were a column of one icon
/// — the exact complaint the table was added to fix, relocated.
fn command_glyph(id: &str) -> &'static str {
    // Matched against the LAST dotted segment.
    const ACTION: &[(&str, &str)] = &[
        ("undo", "\u{f0e2}"),
        ("redo", "\u{f01e}"),
        ("paste", "\u{f0ea}"),
        ("copy", "\u{f0c5}"),
        ("yank", "\u{f0c5}"),
        ("cut", "\u{f0c4}"),
        ("clear", "\u{f12d}"),
        ("restart", "\u{f021}"),
        ("refresh", "\u{f021}"),
        ("reload", "\u{f021}"),
        ("reset", "\u{f0e2}"),
        ("close", "\u{f00d}"),
        ("quit", "\u{f00d}"),
        ("kill", "\u{f00d}"),
        ("stop", "\u{f04d}"),
        ("delete", "\u{f1f8}"),
        ("remove", "\u{f1f8}"),
        ("trash", "\u{f1f8}"),
        ("save", "\u{f0c7}"),
        ("write", "\u{f0c7}"),
        ("definition", "\u{eab5}"),
        ("references", "\u{f0c1}"),
        ("hover", "\u{f05a}"),
        ("symbol", "\u{f1b3}"),
        ("rename", "\u{f044}"),
        ("format", "\u{f036}"),
        ("comment", "\u{f075}"),
        ("indent", "\u{f03c}"),
        ("fold", "\u{f0d7}"),
        ("select", "\u{f0c9}"),
        ("goto", "\u{eab5}"),
        ("jump", "\u{eab5}"),
        ("commit", "\u{f1d3}"),
        ("push", "\u{f062}"),
        ("pull", "\u{f063}"),
        ("fetch", "\u{f063}"),
        ("stash", "\u{f187}"),
        ("branch", "\u{f126}"),
        ("merge", "\u{f126}"),
        ("rebase", "\u{f126}"),
        ("diff", "\u{f0db}"),
        ("stage", "\u{f067}"),
        ("unstage", "\u{f068}"),
        ("new", "\u{f067}"),
        ("open", "\u{f07c}"),
        ("reveal", "\u{f002}"),
        ("find", "\u{f002}"),
        ("search", "\u{f002}"),
        ("grep", "\u{f002}"),
        ("theme", "\u{f043}"),
        ("toggle", "\u{f205}"),
        ("dock", "\u{f0db}"),
        ("split", "\u{f0db}"),
        ("equalize", "\u{f0db}"),
        ("maximize", "\u{f065}"),
        ("zoom", "\u{f065}"),
        ("settings", "\u{f013}"),
        ("config", "\u{f013}"),
        ("help", "\u{f059}"),
        ("about", "\u{f05a}"),
        ("pin", "\u{f08d}"),
        ("hide", "\u{f070}"),
        ("show", "\u{f06e}"),
        ("run", "\u{f04b}"),
        ("test", "\u{f0c3}"),
        ("build", "\u{f0ad}"),
        ("install", "\u{f019}"),
        ("update", "\u{f019}"),
        ("next", "\u{f061}"),
        ("prev", "\u{f060}"),
    ];
    // Matched against the FIRST dotted segment, only when the action
    // says nothing. A domain icon is a weaker answer than an action
    // one, so it must never outrank it.
    const DOMAIN: &[(&str, &str)] = &[
        ("git", "\u{f1d3}"),
        ("ai", "\u{F06A9}"),
        ("browser", "\u{f0ac}"),
        ("http", "\u{f1d8}"),
        ("term", "\u{f120}"),
        ("pty", "\u{f120}"),
        ("tools", "\u{f120}"),
        ("lsp", "\u{f085}"),
        ("dap", "\u{f188}"),
        ("debug", "\u{f188}"),
        ("files", "\u{f07b}"),
        ("tree", "\u{f07b}"),
        ("buffer", "\u{f15b}"),
        ("tab", "\u{f15b}"),
        ("editor", "\u{f044}"),
        ("view", "\u{f06e}"),
        ("window", "\u{f0db}"),
        ("picker", "\u{f002}"),
        ("notes", "\u{f249}"),
        ("todos", "\u{f046}"),
        ("findings", "\u{F1623}"),
        ("integrations", "\u{f12e}"),
        ("cloud", "\u{f0c2}"),
        ("mixr", "\u{f001}"),
    ];

    let lower = id.to_ascii_lowercase();
    let (ns, action) = match lower.split_once('.') {
        Some((a, b)) => (a, b.rsplit('.').next().unwrap_or(b)),
        None => ("", lower.as_str()),
    };
    for (needle, glyph) in ACTION {
        if action.contains(needle) {
            return glyph;
        }
    }
    for (needle, glyph) in DOMAIN {
        if ns == *needle {
            return glyph;
        }
    }
    "\u{f04b}"
}

/// ASCII mode gets no glyphs at all.
///
/// The alternative — an ASCII stand-in per family — would need a legend
/// to be readable, and `ascii_icons` exists for terminals that cannot
/// render these codepoints, not for users who want a denser menu.
pub fn for_action_ascii(_a: &MenuAction) -> &'static str {
    ""
}

/// Width of the glyph column, in cells: glyph + a 2-cell gap, matching
/// `menu_bar`'s `icon_col_w` — the spacing the user singled out as the
/// one that reads correctly.
pub const COLUMN_W: usize = 3;

/// The glyph column a menu row paints, honouring `ascii_icons`.
///
/// ALWAYS [`COLUMN_W`] cells in nerd mode, even for a row with no
/// glyph. A variable-width column was the bug behind rows looking
/// randomly indented: a label already carrying its own `✓ ` prefix
/// ended up a gutter deeper than its neighbours.
/// The glyph column, preferring an EXPLICIT icon over the action
/// table. `MenuItem::with_icon` sets one for rows the table cannot
/// identify — submenu parents and integration rows.
pub fn column_for(icon: Option<&str>, a: &MenuAction, ascii: bool) -> String {
    if ascii {
        return String::new();
    }
    match icon {
        Some(g) if !g.is_empty() => format!("{g}{}", " ".repeat(COLUMN_W - 1)),
        _ => column(a, ascii),
    }
}

pub fn column(a: &MenuAction, ascii: bool) -> String {
    if ascii {
        return String::new();
    }
    let g = for_action(a);
    if g.is_empty() {
        " ".repeat(COLUMN_W)
    } else {
        format!("{g}{}", " ".repeat(COLUMN_W - 1))
    }
}

/// Write the menu-glyph audit document and return its path.
///
/// A REAL function, not a `#[ignore]`d test: the user asked for "an
/// easier way to do the audit list in future, shouldn't be that hard".
/// `menu.glyph_audit` in the palette calls this and opens the result.
///
/// Enumerates EVERY registered command, not a hand-picked sample.
///
/// The first version sampled 26 of 132 `MenuAction` variants and 10
/// command ids while its own header claimed it was "generated from the
/// live table so it cannot drift" — so it reported a healthy
/// vocabulary while the git chip menu was ten identical logos and the
/// LSP menu was seven play triangles. A sampling audit that claims
/// completeness is worse than no audit: it answers the question
/// wrongly and confidently.
pub fn write_audit(dir: &std::path::Path) -> std::io::Result<std::path::PathBuf> {
    use std::collections::BTreeMap;

    // Every registered command id, resolved through the real table.
    let mut by_glyph: BTreeMap<&'static str, Vec<(&'static str, &'static str)>> = BTreeMap::new();
    for c in crate::command::registry().all() {
        by_glyph
            .entry(command_glyph(c.id))
            .or_default()
            .push((c.id, c.title));
    }
    let total: usize = by_glyph.values().map(|v| v.len()).sum();

    // Worst offenders first — a menu is unreadable when many of its
    // rows share one icon, so size of group is the thing to look at.
    let mut groups: Vec<(&'static str, usize)> =
        by_glyph.iter().map(|(g, v)| (*g, v.len())).collect();
    groups.sort_by_key(|(_, n)| std::cmp::Reverse(*n));

    let mut out = format!(
        "# Menu glyph audit\n\n\
         Regenerate with the `menu.glyph_audit` palette command.\n\n\
         {total} registered commands resolved through `command_glyph`, \
         grouped by the glyph they land on. EVERY command is listed — \
         this is not a sample.\n\n\
         A large group is the thing to look for: it means that many menu \
         rows draw the same icon, which is what makes a menu read as a \
         column of one symbol.\n\n\
         ## Group sizes\n\n"
    );
    for (g, n) in &groups {
        let shown = if g.is_empty() {
            "(none)".to_string()
        } else {
            format!("`{g}` {g}")
        };
        out.push_str(&format!("- {shown} — **{n}**\n"));
    }

    out.push_str("\n## Every command, by glyph\n");
    for (g, n) in &groups {
        let shown = if g.is_empty() {
            "(none)".to_string()
        } else {
            format!("`{g}`  {g}")
        };
        out.push_str(&format!("\n### {shown} — {n} command(s)\n\n"));
        let mut rows = by_glyph[g].clone();
        rows.sort();
        for (id, title) in rows {
            out.push_str(&format!(
                "- `{}{}` — `{id}`\n",
                column_for(None, &crate::context_menu::MenuAction::Command(id), false),
                title
            ));
        }
    }

    std::fs::create_dir_all(dir)?;
    let path = dir.join("menu-glyph-audit.md");
    std::fs::write(&path, out)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context_menu::MenuAction as M;

    /// The point of the table: same KIND of action, same glyph. If these
    /// drift apart the menu stops being a small learnable vocabulary and
    /// becomes 132 unrelated icons.
    #[test]
    fn actions_of_the_same_kind_share_a_glyph() {
        assert_eq!(
            for_action(&M::CopyPath("/a".to_string())),
            for_action(&M::CopyText("x".into())),
            "two copy actions disagree on their glyph"
        );
        assert_eq!(
            for_action(&M::CloseAllTabs),
            for_action(&M::CloseOtherTabs(0)),
            "two close actions disagree on their glyph"
        );
    }

    /// Different kinds must NOT collide, or the glyph column carries no
    /// information — a test that only checked "every row has a glyph"
    /// would pass on a table that returned one icon for everything.
    #[test]
    fn different_kinds_do_not_share_a_glyph() {
        let copy = for_action(&M::CopyText("x".into()));
        let del = for_action(&M::Delete(std::path::PathBuf::from("/a")));
        let save = for_action(&M::SavePane(0));
        assert_ne!(copy, del, "copy and delete share a glyph");
        assert_ne!(copy, save, "copy and save share a glyph");
        assert_ne!(del, save, "delete and save share a glyph");
    }

    /// The ACTION must beat the NAMESPACE.
    ///
    /// Matching the whole id in one pass let a namespace swallow
    /// everything under it: `editor.undo` resolved to a pencil because
    /// "edit" matched, and all fifty git commands drew one logo.
    #[test]
    fn the_action_outranks_the_namespace() {
        assert_ne!(
            command_glyph("editor.undo"),
            command_glyph("editor.indent_line"),
            "every editor.* command still collapses to one namespace icon"
        );
        assert_ne!(
            command_glyph("git.push"),
            command_glyph("git.pull"),
            "push and pull share an icon — the git namespace is winning"
        );
        assert_ne!(
            command_glyph("editor.undo"),
            command_glyph("editor.redo"),
            "undo and redo share an icon, and they are opposites"
        );
    }

    /// No single glyph may claim a large share of the command surface.
    ///
    /// This is the measurable form of "a menu should not be a column of
    /// one repeated icon". Before the action/domain split, the play
    /// triangle held 339 of 789 commands — 43% — and menus built from
    /// those ids rendered as exactly that.
    #[test]
    fn no_glyph_claims_a_large_share_of_all_commands() {
        use std::collections::BTreeMap;
        let mut by: BTreeMap<&str, usize> = BTreeMap::new();
        let mut total = 0usize;
        for c in crate::command::registry().all() {
            *by.entry(command_glyph(c.id)).or_default() += 1;
            total += 1;
        }
        let (worst, n) = by.iter().max_by_key(|(_, n)| **n).unwrap();
        let share = (*n as f64) / (total as f64);
        assert!(
            share < 0.20,
            "{worst:?} covers {n}/{total} commands ({:.0}%) — menus built \
             from these ids will read as a column of one icon",
            share * 100.0
        );
    }

    /// A go-to-definition row must draw the same glyph wherever it
    /// appears. The menu bar hand-picks `\u{eab5}`; the table used to
    /// give the editor's own menu a play triangle for the same action.
    #[test]
    fn goto_definition_matches_the_menu_bars_hand_picked_glyph() {
        assert_eq!(
            command_glyph("lsp.goto_definition"),
            "\u{eab5}",
            "the same action draws two different glyphs depending on \
             which menu you opened it from"
        );
    }

    /// An EXPLICIT icon must win over the action table.
    ///
    /// Without this, a submenu parent rendered blank (its action is
    /// `Submenu`, which identifies nothing) and every integration row
    /// rendered the same play triangle (all generic `RunCmd`) — fifteen
    /// identical icons in one menu.
    #[test]
    fn an_explicit_icon_overrides_the_action_table() {
        let a = M::Submenu;
        assert_eq!(for_action(&a), "", "setup: Submenu has no table glyph");
        let col = column_for(Some("\u{f12e}"), &a, false);
        assert!(
            col.starts_with('\u{f12e}'),
            "the explicit icon was ignored: {col:?}"
        );
        assert_eq!(
            col.chars().count(),
            COLUMN_W,
            "an explicit icon broke the column width: {col:?}"
        );
    }

    /// Distinct integration glyphs must stay distinct — that is the
    /// entire complaint being fixed.
    #[test]
    fn distinct_explicit_icons_do_not_collapse() {
        let a = M::RunCmd("x".into());
        let one = column_for(Some("\u{f09b}"), &a, false);
        let two = column_for(Some("\u{f1d3}"), &a, false);
        assert_ne!(one, two, "two integrations rendered the same icon");
    }

    /// No explicit icon falls through to the table, so rows that never
    /// set one are unaffected.
    #[test]
    fn no_explicit_icon_falls_through_to_the_table() {
        let a = M::SavePane(0);
        assert_eq!(column_for(None, &a, false), column(&a, false));
        assert_eq!(column_for(Some(""), &a, false), column(&a, false));
    }

    /// ASCII mode still paints nothing, explicit icon or not.
    #[test]
    fn an_explicit_icon_is_still_suppressed_in_ascii_mode() {
        assert_eq!(column_for(Some("\u{f12e}"), &M::Submenu, true), "");
    }

    /// ASCII mode must be untouched — `ascii_icons` exists for terminals
    /// that cannot render these codepoints.
    #[test]
    fn ascii_mode_emits_no_glyph_column() {
        let a = M::CopyText("x".into());
        assert_eq!(column(&a, true), "", "ascii mode painted a glyph");
        assert!(!column(&a, false).is_empty(), "nerd mode painted nothing");
    }

    /// EVERY row's column is the same width, glyph or not.
    ///
    /// This test previously asserted the opposite — that a glyph-less
    /// row emitted NOTHING — which is precisely the bug the user saw:
    /// rows whose label already carried a `✓ ` prefix sat a gutter
    /// deeper than their neighbours, so the menu looked randomly
    /// indented. A variable-width column cannot align.
    #[test]
    fn every_row_reserves_the_same_glyph_column_width() {
        assert_eq!(for_action(&M::Submenu), "", "setup: expected a blank row");
        let blank = column(&M::Submenu, false);
        let full = column(&M::SavePane(0), false);
        assert_eq!(
            blank.chars().count(),
            COLUMN_W,
            "a glyph-less row did not reserve the column: {blank:?}"
        );
        assert_eq!(
            full.chars().count(),
            COLUMN_W,
            "a glyph row did not reserve the column: {full:?}"
        );
        assert!(
            blank.trim().is_empty(),
            "the blank column painted something: {blank:?}"
        );
        assert!(
            full.ends_with("  "),
            "no 2-cell gap after the glyph: {full:?}"
        );
    }

    /// `MenuAction::Command` is a generic wrapper behind dozens of rows.
    /// One glyph for all of them turned whole menus into a column of the
    /// same repeated icon ("i see too much repetition... its like we
    /// quit trying"), so ids must resolve to DIFFERENT glyphs.
    #[test]
    fn command_rows_do_not_all_collapse_to_one_glyph() {
        let ids = [
            "pty.clear",
            "pty.restart",
            "pane.close",
            "window.dock_left",
            "window.maximize_width",
            "edit.paste",
        ];
        let glyphs: std::collections::HashSet<&str> =
            ids.iter().map(|i| command_glyph(i)).collect();
        assert!(
            glyphs.len() >= 5,
            "{} ids collapsed to {} glyph(s) — the pty menu was twelve \
             identical play triangles for exactly this reason",
            ids.len(),
            glyphs.len()
        );
    }

    /// An id the table does not know still gets an honest fallback
    /// rather than a blank or a wrong-but-specific icon.
    #[test]
    fn an_unmapped_command_falls_back_rather_than_blank() {
        let g = command_glyph("something.entirely.unmapped");
        assert!(!g.is_empty(), "unmapped command produced no glyph");
    }
}
