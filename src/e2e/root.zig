//! The `.test` end-to-end harness: the script grammar, the runner, and the
//! `Driver` seam an application implements to be driven by it.

pub const parser = @import("parser.zig");
pub const driver = @import("driver.zig");
pub const runner = @import("runner.zig");

pub const Driver = driver.Driver;
pub const Factory = driver.Factory;
pub const Options = runner.Options;
pub const Size = runner.Size;

test {
    _ = parser;
    _ = driver;
    _ = runner;
    _ = @import("cancel_probe.zig");
}
