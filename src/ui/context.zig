//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The per-frame draw context every component receives instead of `*App`.

const std = @import("std");
const Canvas = @import("canvas.zig");
const hit = @import("hit.zig");
const theme = @import("theme.zig");
const ids = @import("../core/ids.zig");

pub const Ui = struct {
    canvas: Canvas,
    hits: *hit.HitMap,
    theme: *const theme.Theme,
    /// Frame arena — everything a draw allocates.
    arena: std.mem.Allocator,
    focus: ids.FocusId,
    hover: ?struct { x: u16, y: u16 } = null,
    ascii: bool = false,
    nerd_font: bool = true,
};
