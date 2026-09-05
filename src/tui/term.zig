//! The terminal session for this target. `term_posix.zig` is termios +
//! `/dev/tty` + a SIGWINCH self-pipe; `term_windows.zig` is the console
//! modes + `CONIN$` + the window-buffer-size record. Both are the same
//! struct to their callers — `init` / `deinit`, `screen`, `render`,
//! `next`, `Panic` — so the loop and the demos import `Term` from here
//! and never name a platform.

const builtin = @import("builtin");

pub const Term = if (builtin.os.tag == .windows) @import("term_windows.zig") else @import("term_posix.zig");

/// The environment's verdicts, shared by both backends.
pub const caps = @import("caps.zig");
pub const Capabilities = caps.Capabilities;
pub const Options = caps.Options;
