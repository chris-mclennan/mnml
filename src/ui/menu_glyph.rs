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
        M::PtyRestart(..) => "\u{f021}",   // refresh
        M::PtyInterrupt(..) => "\u{f04d}", // stop
        M::PtyClear(..) => "\u{f12d}",     // eraser

        // ── Run ──
        M::RunCmd(..) | M::Command(..) | M::TodoAction { .. } => "\u{f04b}", // play
        M::RunIntegrationDiag(..) => "\u{f0f1}",                             // stethoscope

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

/// ASCII mode gets no glyphs at all.
///
/// The alternative — an ASCII stand-in per family — would need a legend
/// to be readable, and `ascii_icons` exists for terminals that cannot
/// render these codepoints, not for users who want a denser menu.
pub fn for_action_ascii(_a: &MenuAction) -> &'static str {
    ""
}

/// The glyph column a menu row should paint, honouring `ascii_icons`.
///
/// Always two cells wide when non-empty (glyph + separating space) so
/// rows with no glyph still align with rows that have one.
pub fn column(a: &MenuAction, ascii: bool) -> String {
    let g = if ascii {
        for_action_ascii(a)
    } else {
        for_action(a)
    };
    if g.is_empty() {
        String::new()
    } else {
        format!("{g} ")
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

    /// ASCII mode must be untouched — `ascii_icons` exists for terminals
    /// that cannot render these codepoints.
    #[test]
    fn ascii_mode_emits_no_glyph_column() {
        let a = M::CopyText("x".into());
        assert_eq!(column(&a, true), "", "ascii mode painted a glyph");
        assert!(!column(&a, false).is_empty(), "nerd mode painted nothing");
    }

    /// A blank glyph must produce a BLANK COLUMN, not a stray space that
    /// shifts that row's label out of line with its neighbours.
    #[test]
    fn a_blank_glyph_produces_a_blank_column_not_a_stray_space() {
        assert_eq!(for_action(&M::Submenu), "", "setup: expected a blank row");
        assert_eq!(
            column(&M::Submenu, false),
            "",
            "a glyph-less row emitted padding, misaligning it against its \
             neighbours"
        );
    }

    /// The non-empty column is glyph + one space, so labels line up.
    #[test]
    fn the_glyph_column_is_glyph_plus_one_space() {
        let c = column(&M::SavePane(0), false);
        assert!(c.ends_with(' '), "no separator after the glyph: {c:?}");
        assert_eq!(c.chars().count(), 2, "unexpected column width: {c:?}");
    }
}
