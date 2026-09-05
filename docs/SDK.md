# mnml-sdk — write an integration in Zig

An integration is a program mnml opens in a pane. It draws into a cell
grid, gets keys and clicks, and can ask mnml to run commands, toast, or
put things on the statusline. `sdk/mnml-sdk` is the package; the wire it
speaks is `docs/BRIDGE.md`. The sample, `sdk/examples/hello`, is ~160
lines and is what mnml's own integration test spawns.

## Set up

`build.zig.zon`:

```zig
.dependencies = .{
    .mnml_sdk = .{ .path = "../mnml-zig/sdk/mnml-sdk" },   // or a .url + .hash once tagged
},
```

`build.zig`:

```zig
const sdk = b.dependency("mnml_sdk", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mnml_sdk", sdk.module("mnml_sdk"));
```

The SDK has no dependencies beyond `std`; Zig 0.16.0.

## The loop

```zig
const sdk = @import("mnml_sdk");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    // `--install` writes the manifest and exits (below).
    // Otherwise we were spawned by mnml: connect and read `hello`.
    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |err| switch (err) {
        error.NoSocket => return usage(),       // not launched by mnml
        else => return err,
    };
    defer mount.destroy();

    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    try mount.setTitle("hello");
    paint(&frame);
    try mount.send(&frame);                       // the first send is a full frame

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const msg = (try mount.next(arena.allocator())) orelse break;   // null: goodbye or EOF
        switch (msg) {
            .resize => |r| try frame.resize(r.geometry.cols, r.geometry.rows),
            .input => |in| switch (in.event) {
                .key => |k| if (std.mem.eql(u8, k.spec, "q")) { mount.bye(); break; },
                .click => |c| select(c.row),
                .scroll, .hover, .paste => {},
            },
            .focus, .hello => {},
            .goodbye => break,
        }
        paint(&frame);
        try mount.send(&frame);                   // dirty rows only, or nothing
    }
    return 0;
}
```

* `Mount.connectEnv` reads `MNML_MOUNT_SOCKET`, connects, and parses the
  host's `hello` (`mount.hello`, `mount.geometry`). A host on another
  protocol is `error.UnsupportedProtocol`.
* `mount.next(arena)` blocks for one `HostMessage`; the strings it
  returns live on `arena`. A `resize` updates `mount.geometry` before
  you see it. `null` means mnml said goodbye or the socket ended —
  leave the loop.
* `Frame` is your screen: `put(x, y, symbol, style)`, `text(x, y, max_w,
  s, style)` (returns cells used; CJK / emoji take two), `fill(x, y, w,
  h, style)`, `clear(style)`, `resize(cols, rows)`. It remembers which
  rows changed, so `mount.send(&frame)` ships a whole screen the first
  time and after a resize, the dirty rows otherwise, nothing when
  nothing moved.
* `Style{ fg, bg, mods }` — `Color = .{ .index = n }` or `.{ .rgb = .{r,g,b} }`;
  `Mods` is a packed set (`.{ .bold = true }`). `Style.bold` / `.dim` /
  `.reverse` / `.none` are ready-made.
* `mount.setTitle`, `mount.setCursor(?{x,y})`, `mount.toast(level, text)`,
  `mount.command(id)` (run an mnml command by id), `mount.bye()`.
* `mount.sendMessage(SiblingMessage)` for anything else.

Sends are serialised by a mutex, so a worker thread may `toast` while
the main loop paints.

## Keys and clicks

`key.spec` is mnml's grammar: `a`, `A`, `enter`, `esc`, `up`, `ctrl+p`,
`shift+f5`, `alt+left`, `space`. Click / scroll / hover coordinates are
pane-relative cells; row 0 is your first row (the tab strip is not
yours). The host folds a wheel burst into one `scroll` with `dy` the
notch count (positive = up).

## `--install` — the manifest

mnml learns about an integration from
`~/.config/mnml/integrations/<id>.zon` (or `$MNML_DATA_ROOT/integrations/`,
or `<workspace>/.mnml/integrations/` for a per-project one). Your binary
writes it:

```zig
const spec: sdk.Manifest = .{
    .id = "hello",
    .label = "Hello",
    .description = "The mnml-sdk sample",
    .version = "0.1.0",
    .binary = "mnml-hello",                 // on PATH, or absolute
    .category = "sample",
    .chip = .{ .glyph = "\u{f0e7}", .fallback = "H", .color = "cyan", .tooltip = "Hello" },
    .commands = &.{
        .{ .id = "hello.open", .title = "Hello: open", .keys = &.{"ctrl+k h"} },
        .{ .id = "hello.shell", .title = "Hello: as a terminal", .ex = "term mnml-hello --pty" },
    },
    .settings = &.{ .{ .key = "greeting", .label = "Greeting", .options = &.{ "HELLO", "HOWDY" }, .default = "HELLO" } },
    .requires = &.{"HELLO_TOKEN"},
};

if (isInstall) {
    const path = try sdk.manifest.write(gpa, io, env, spec);
    defer gpa.free(path);
    // print it and exit 0
}
```

What mnml does with each field:

| field | effect |
|---|---|
| `id`, `label`, `description`, `version`, `category` | the INTEGRATIONS pane row and its detail block |
| `binary`, `args`, `mode` | what a command opens: `mode = .mount` (default) hosts it over the socket; `.pty` opens it as a terminal pane |
| `chip` | a button on the palette bar: `glyph` (Nerd Font), `fallback` (plain), `color` (a theme name — `red orange yellow green blue cyan teal purple pink comment fg` — or `#rrggbb`), `tooltip`, `enabled`, `in_palette_bar`. Right-click → enable / disable / manifest / remove |
| `commands[]` | each is a palette command with `keys`; it opens the binary (with `args`) unless `ex` names an ex line to run instead. The first one is what the chip and Enter do |
| `settings[]` | a row in mnml's settings overlay under *Integrations* (discrete choices); the chosen value reaches the binary as `MNML_SETTING_<KEY>` |
| `requires[]` | environment variables the integration needs (shown in the detail block) |
| `context_menu[]`, `menu_bar[]`, `statusline[]`, `auth[]`, `values_sources[]` | parsed and shown; wiring into mnml's menus / auth store is a later slice |

`sdk.manifest.write` picks the data root the way mnml does
(`MNML_DATA_ROOT`, `XDG_CONFIG_HOME/mnml`, `HOME/.config/mnml`) and
returns the path it wrote. `sdk.manifest.remove(gpa, io, env, id)` is
uninstall. mnml re-scans on `integrations.refresh` and at startup; an
`id` must be a file name (`[A-Za-z0-9_.-]`).

## Tier 2 — toasts, progress, statusline, badges, commands

Anything mnml spawned can write to the file-IPC channel, socket or not:

```zig
if (try sdk.Ipc.fromEnv(gpa, io, env)) |ipc_const| {
    var ipc = ipc_const;
    defer ipc.deinit();
    try ipc.registerCommand("hello.pick", "Hello: pick", "integrations", &.{"ctrl+k p"});
    try ipc.toast(.info, "ready");
    try ipc.progressStart("sync", "Syncing");
    try ipc.progressUpdate("sync", null, 40);
    try ipc.progressEnd("sync", .success);
    try ipc.statuslineSetSegment(.{ .id = "hello", .text = "H·3", .click_command = "hello.open" });
    try ipc.setActivityBadge("integrations", 3);
    try ipc.notify("Hello", "something happened", .info, false);
}
```

Each call appends one JSON line to `$MNML_IPC_DIR/command`; the shapes
are in `docs/BRIDGE.md`. Over a mount, prefer `mount.toast` and
`mount.command` — they need no file.

## Testing an integration

The socket is plain: a test can `UnixAddress.listen`, spawn the binary
with `MNML_MOUNT_SOCKET`, send a `hello` with `sdk.wire.send`, and read
frames back with `sdk.wire.receive(sdk.SiblingMessage, …)`. mnml's own
test does exactly this against the sample
(`src/app/mount_pane.zig`, "a mounted sample integration paints…").

## Layout of the package

```
sdk/mnml-sdk/src/
  root.zig       the module: Mount, Frame, Style, Ipc, Manifest, wire
  wire.zig       the protocol — types, framing, encode/decode, tests
  client.zig     Mount: connect, next, send, the small senders
  frame.zig      Frame: the cell grid + dirty-row tracking
  ipc.zig        Ipc: the tier-2 lines
  manifest.zig   Manifest + write/remove + the data-root rule
sdk/examples/hello/   the sample (`zig build sdk-example` in mnml-zig, or its own build.zig)
```
