//! Identifiers shared by the app core and the UI layer. Kept apart from
//! both so a component can name a pane or a focus target without
//! importing `App`, and `App` can route a hit without importing a widget.

const panel = @import("panel.zig");

/// Index into the pane store. Stable for the pane's lifetime.
pub const PaneId = u32;

/// What owns the keyboard.
pub const FocusId = union(enum) {
    tree,
    pane: PaneId,
    panel: panel.PanelId,
    /// An overlay (prompt, picker, which-key, confirm) is up; the
    /// app routes keys to it before anything else.
    overlay,
    /// // changed (welcome): the start surface — the editor area while
    /// the layout is empty (`app/welcome.zig`). Its lists walk on
    /// j / k, Tab steps between them, Enter acts.
    welcome,
    /// The sidebar's info view (`app/info_view.zig`, `help.focus`):
    /// Tab walks its shortcut and link rows, Enter runs one, Esc gives
    /// the keys back to where they came from.
    info_view,
};
