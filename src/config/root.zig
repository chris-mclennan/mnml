//! ZON config — barrel. See `docs/DESIGN.md` E1 and `docs/CONFIG.md`.
//!
//! `App.cfg` is this `Config` (`src/app.zig`); the loader's `Loaded`
//! travels with it and is freed last, since every string in the merged
//! config borrows the loader's arena. The one enum the input layer keeps
//! for itself (`input.Style`) is reconciled by `App.styleOf`.

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
pub const trusted = @import("trusted.zig");
pub const TrustPrompt = load.TrustPrompt;
pub const data_root = @import("data_root.zig");
pub const profile = @import("profile.zig");
pub const seed = @import("seed.zig");
pub const sandbox = @import("sandbox.zig");
pub const demo = @import("demo.zig");
pub const Profile = profile.Profile;
pub const persist = @import("persist.zig");
pub const zon_tree = @import("zon_tree.zig");
pub const zon_schema = @import("zon_schema.zig");

test {
    _ = @import("Config.zig");
    _ = @import("Dynamic.zig");
    _ = @import("map.zig");
    _ = @import("patch.zig");
    _ = @import("diag.zig");
    _ = @import("decode.zig");
    _ = @import("load.zig");
    _ = @import("trust.zig");
    _ = @import("trusted.zig");
    _ = @import("demo.zig");
    _ = @import("data_root.zig");
    _ = @import("profile.zig");
    _ = @import("seed.zig");
    _ = @import("sandbox.zig");
    _ = @import("persist.zig");
    _ = @import("zon_tree.zig");
    _ = @import("zon_schema.zig");
}
