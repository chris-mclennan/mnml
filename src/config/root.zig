//! ZON config — barrel. See `docs/DESIGN.md` E1 and `docs/CONFIG.md`.

pub const Config = @import("Config.zig");
pub const Dynamic = @import("Dynamic.zig").Dynamic;
pub const Map = @import("map.zig").Map;

test {
    _ = @import("Config.zig");
    _ = @import("Dynamic.zig");
    _ = @import("map.zig");
}
