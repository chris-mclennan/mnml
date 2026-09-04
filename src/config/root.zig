//! ZON config — barrel. See `docs/DESIGN.md` E1 and `docs/CONFIG.md`.
//!
//! TODO(merge): `app.Config` (src/app.zig) is replaced by this `Config`
//! at merge. The fields it carries today map as:
//!   input_style      ← config.editor.input_style   (same enum shape as input.Style)
//!   tab_width        ← config.editor.tab_width
//!   text_width       ← config.editor.text_width
//!   wrap             ← config.ui.wrap
//!   breadcrumb       ← config.editor.breadcrumb
//!   line_numbers     ← config.ui.line_numbers
//!   chord_timeout_ms ← config.editor.chord_timeout_ms
//!   ascii            ← config.ui.ascii_icons
//!   toast_ttl_ms     — no config key; keep the App default
//! Not adapted here: importing app.zig from this leaf would drag the
//! whole App into a self-contained module for a ten-line function.

pub const Config = @import("Config.zig");
pub const Dynamic = @import("Dynamic.zig").Dynamic;
pub const Map = @import("map.zig").Map;
pub const patch = @import("patch.zig");
pub const Patch = patch.Patch;
pub const diag = @import("diag.zig");
pub const Diagnostics = diag.Diagnostics;
pub const decode = @import("decode.zig");
pub const load = @import("load.zig");
pub const Loaded = load.Loaded;
pub const Trust = load.Trust;
pub const trust = @import("trust.zig");
pub const data_root = @import("data_root.zig");
pub const persist = @import("persist.zig");

test {
    _ = @import("Config.zig");
    _ = @import("Dynamic.zig");
    _ = @import("map.zig");
    _ = @import("patch.zig");
    _ = @import("diag.zig");
    _ = @import("decode.zig");
    _ = @import("load.zig");
    _ = @import("trust.zig");
    _ = @import("data_root.zig");
    _ = @import("persist.zig");
}
