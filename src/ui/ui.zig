//! src/ui — the render layer (D6): geometry and painting primitives on a
//! tty-free `vaxis.Screen`, the frame hit map, the theme, and every
//! component the app paints with. Components take a `Ui`, never `*App`.
//!
//! This barrel is the ui test root: `main.zig`'s `test {}` imports it, so
//! every module's tests run under `zig build test` on
//! `std.testing.allocator` (leak = failure).

pub const Rect = @import("rect.zig");
pub const color = @import("color.zig");
pub const Canvas = @import("canvas.zig");
pub const clip = @import("clip.zig");
pub const text = @import("text.zig");
pub const border = @import("border.zig");

pub const Theme = @import("theme.zig");
pub const brand = @import("brand.zig");
pub const hit = @import("hit.zig");
pub const HitMap = hit.HitMap;
pub const HitTarget = hit.HitTarget;
pub const ChipKind = hit.ChipKind;
pub const Ui = @import("context.zig");

pub const editor_view = @import("editor_view.zig");
pub const statusline = @import("statusline.zig");
pub const bufferline = @import("bufferline.zig");
pub const stepper = @import("stepper.zig");

pub const chip = @import("chip.zig");
pub const icons = @import("icons.zig");
pub const tree_view = @import("tree_view.zig");
pub const info_view = @import("info_view.zig");
pub const text_field = @import("text_field.zig");
pub const Caret = text_field.Caret;
pub const scrollbar = @import("scrollbar.zig");
pub const empty_state = @import("empty_state.zig");
pub const welcome = @import("welcome.zig");
pub const header = @import("header.zig");
pub const filter_input = @import("filter_input.zig");
pub const expander = @import("expander.zig");
pub const list_panel = @import("list_panel.zig");
pub const ListPanel = list_panel.ListPanel;

pub const fuzzy = @import("fuzzy.zig");
pub const overlay = @import("overlay.zig");
pub const prompt = @import("prompt.zig");
pub const Prompt = prompt;
pub const confirm = @import("confirm.zig");
pub const Confirm = confirm;
pub const which_key = @import("which_key.zig");
pub const cmdline_popup = @import("cmdline_popup.zig");
pub const whichkey_glyph = @import("whichkey_glyph.zig");
pub const find_bar = @import("find_bar.zig");
pub const FindBar = find_bar;
pub const picker = @import("picker.zig");
pub const Picker = picker;
pub const toast = @import("toast.zig");
pub const settings = @import("settings.zig");
pub const wizard = @import("wizard.zig");
pub const Toast = toast.Toast;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test_fixture.zig");
    // Not re-exported (the app's render reaches it directly), so its
    // tests are named here or they never run.
    _ = @import("grep_view.zig");
}
