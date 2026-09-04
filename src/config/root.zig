//! ZON config — barrel. See `docs/DESIGN.md` E1 and `docs/CONFIG.md`.

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
}
