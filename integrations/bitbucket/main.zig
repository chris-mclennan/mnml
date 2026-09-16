//! Placeholder while the pane is rebuilt: keeps `zig build test` running
//! every module's tests. Replaced by the real entry point below.

const std = @import("std");

pub fn main() !void {}

test {
    _ = @import("src/dates.zig");
    _ = @import("src/json.zig");
    _ = @import("src/os.zig");
    _ = @import("src/ratelimit.zig");
    _ = @import("src/config.zig");
    _ = @import("src/auth.zig");
    _ = @import("src/model.zig");
    _ = @import("src/api.zig");
    _ = @import("src/tabs.zig");
    _ = @import("src/keymap.zig");
    _ = @import("src/hit.zig");
    _ = @import("src/theme.zig");
    _ = @import("src/fetch.zig");
    _ = @import("src/app.zig");
    _ = @import("src/view.zig");
    _ = @import("src/screen.zig");
}
