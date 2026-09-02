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
/// Ordered most-specific-first, and matched as a substring, so
/// `"pane.close"` resolves on "close" rather than on "pane". Falls back
/// to a play triangle, which is honest — the row runs *some* command —
/// rather than pretending to know more.
fn command_glyph(id: &str) -> &'static str {
    const TABLE: &[(&str, &str)] = &[
        ("paste", "\u{f0ea}"),
        ("copy", "\u{f0c5}"),
        ("cut", "\u{f0c4}"),
        ("clear", "\u{f12d}"),
        ("restart", "\u{f021}"),
        ("refresh", "\u{f021}"),
        ("reload", "\u{f021}"),
        ("close", "\u{f00d}"),
        ("quit", "\u{f00d}"),
        ("delete", "\u{f1f8}"),
        ("remove", "\u{f1f8}"),
        ("trash", "\u{f1f8}"),
        ("save", "\u{f0c7}"),
        ("equalize", "\u{f0db}"),
        ("dock", "\u{f0db}"),
        ("split", "\u{f0db}"),
        ("maximize", "\u{f065}"),
        ("full", "\u{f065}"),
        ("zoom", "\u{f065}"),
        ("new", "\u{f067}"),
        ("reveal", "\u{f002}"),
        ("find", "\u{f002}"),
        ("search", "\u{f002}"),
        ("grep", "\u{f002}"),
        ("open", "\u{f07c}"),
        ("theme", "\u{f043}"),
        ("toggle", "\u{f205}"),
        ("git", "\u{f1d3}"),
        ("term", "\u{f120}"),
        ("pty", "\u{f120}"),
        ("shell", "\u{f120}"),
        ("rename", "\u{f044}"),
        ("edit", "\u{f044}"),
        ("settings", "\u{f013}"),
        ("config", "\u{f013}"),
        ("help", "\u{f059}"),
        ("pin", "\u{f08d}"),
        ("hide", "\u{f070}"),
        ("agent", "\u{F06A9}"),
        ("ai", "\u{F06A9}"),
    ];
    let lower = id.to_ascii_lowercase();
    for (needle, glyph) in TABLE {
        if lower.contains(needle) {
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

/// Dump every menu row's glyph as markdown, grouped by glyph, for a
/// human to audit ("is this icon appropriate, and is it spaced right").
///
/// Generated FROM THE LIVE TABLE rather than hand-written, so the audit
/// document cannot drift from what the menus actually paint. Run with:
///
/// ```text
/// cargo test --lib menu_glyph::audit -- --ignored --nocapture
/// ```
///
/// Writes `.mnml/menu-glyph-audit.md`, which opens in mnml itself —
/// where the Nerd Font is present and the glyphs actually render.
#[cfg(test)]
#[test]
#[ignore = "generates a review document; not a correctness check"]
fn audit_dump() {
    use crate::context_menu::MenuAction as M;
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    let p = |s: &str| PathBuf::from(s);
    // One representative per variant. Labels are the human-facing names
    // the menus actually use, so the audit reads like the menus do.
    let rows: Vec<(&str, MenuAction)> = vec![
        ("Open", M::OpenPath(p("/a"))),
        ("Open as text", M::OpenPathAsText(p("/a"))),
        ("Open in split", M::OpenInSplit(p("/a"))),
        ("Reveal in Finder", M::RevealInFinder(p("/a"))),
        ("Open externally", M::OpenExternally("u".into())),
        ("Open terminal here", M::OpenTerminal(p("/a"))),
        ("Preview markdown", M::PreviewMarkdown(p("/a"))),
        ("Copy path", M::CopyPath("/a".into())),
        ("Copy text", M::CopyText("x".into())),
        ("Cut", M::FileCut(p("/a"))),
        ("Paste", M::FilePaste(p("/a"))),
        ("Duplicate", M::FileDuplicate(p("/a"))),
        ("Move to…", M::FileMoveTo(p("/a"))),
        ("New file", M::NewFile(p("/a"))),
        ("New folder", M::NewFolder(p("/a"))),
        ("Rename…", M::Rename(p("/a"))),
        ("Delete", M::Delete(p("/a"))),
        ("Close tab", M::CloseTab(0)),
        ("Close all tabs", M::CloseAllTabs),
        ("Pin tab", M::PinTab(0)),
        ("Save", M::SavePane(0)),
        ("Expand recursively", M::TreeExpandRecursive(p("/a"))),
        ("Collapse recursively", M::TreeCollapseRecursive(p("/a"))),
        ("Submenu parent", M::Submenu),
    ];

    let mut by_glyph: BTreeMap<&'static str, Vec<&str>> = BTreeMap::new();
    for (label, a) in &rows {
        by_glyph.entry(for_action(a)).or_default().push(label);
    }

    let mut out = String::from(
        "# Menu glyph audit\n\n\
         Generated by `cargo test --lib menu_glyph::audit -- --ignored`.\n\
         Grouped by glyph: every row under one heading shares that icon.\n\
         Read it in mnml, where the Nerd Font renders.\n\n\
         Ask of each group: does one icon honestly cover all of these?\n\n",
    );
    for (glyph, labels) in &by_glyph {
        let shown = if glyph.is_empty() {
            "(none)".to_string()
        } else {
            format!("`{glyph}`  {glyph}")
        };
        out.push_str(&format!("## {shown} — {} row(s)\n\n", labels.len()));
        for l in labels {
            let col = column(
                rows.iter().find(|(n, _)| n == l).map(|(_, a)| a).unwrap(),
                false,
            );
            out.push_str(&format!("- `{col}{l}`\n"));
        }
        out.push('\n');
    }

    // `MenuAction::Command` rows resolve through the id table, which is
    // where the worst repetition lived — audit it separately.
    out.push_str("## `Command(id)` — resolved by id keyword\n\n");
    for id in [
        "pty.clear",
        "pty.restart",
        "pane.close",
        "window.dock_left",
        "window.equalize",
        "view.toggle_theme",
        "files.new",
        "git.stage",
        "edit.paste",
        "something.unmapped",
    ] {
        out.push_str(&format!("- `{}` → `{}`\n", id, command_glyph(id)));
    }

    let dir = std::path::Path::new(".mnml");
    std::fs::create_dir_all(dir).unwrap();
    let path = dir.join("menu-glyph-audit.md");
    std::fs::write(&path, out).unwrap();
    eprintln!("wrote {}", path.display());
}
