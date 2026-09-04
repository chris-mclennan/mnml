//! Settings, app side: where a value is written back, and the one
//! `persist` every settings surface (the overlay, the theme picker, the
//! first-launch wizard) goes through.
//!
//! Two files can take a write. The home config is the user's own
//! preferences; the workspace config is the per-project file checked in
//! beside the code. A row says which it belongs to (`Scope`), and the
//! write is `persistScalar`'s AST splice — comments and order survive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const config = @import("../config/root.zig");

pub const Scope = enum { home, workspace };

/// The file a scope writes to, or null when there is no home at all
/// (no `$HOME`, no data root — nothing to write into).
pub fn configPath(app: *App, scope: Scope) Allocator.Error!?[]const u8 {
    const arena = app.frame.allocator();
    return switch (scope) {
        .workspace => try std.fs.path.join(arena, &.{ app.workspace, ".mnml", config.data_root.config_file }),
        .home => blk: {
            if (app.loaded) |l| if (l.home_path) |p| break :blk p;
            if (app.data_root.len != 0) break :blk try std.fs.path.join(arena, &.{ app.data_root, config.data_root.config_file });
            break :blk null;
        },
    };
}

/// Write `value` at `key_path` in `scope`'s file. A failure is toasted,
/// never fatal — a read-only home must not stop the setting from
/// applying in memory. Returns whether the file changed.
pub fn persist(app: *App, scope: Scope, key_path: []const []const u8, value: anytype) Allocator.Error!bool {
    const path = (try configPath(app, scope)) orelse {
        app.toast("nowhere to save settings (no home directory)", .{});
        return false;
    };
    const literal = try config.persist.serializeLiteral(app.frame.allocator(), value);
    const outcome = config.persist.persistScalar(app.gpa, app.io, path, key_path, literal) catch |err| {
        app.toast("could not write {s}: {s}", .{ path, @errorName(err) });
        return false;
    };
    return outcome == .written;
}
