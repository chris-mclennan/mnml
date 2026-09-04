# mnml-zig conventions

Short rules, one example each. The design rationale lives in
`docs/DESIGN.md` (D1–D10); this file is what you check a diff against.

## Allocation — three tiers (D1, `src/core/alloc.zig`)

Every allocation belongs to exactly one tier. Name the tier in your head
before you write `alloc`.

| tier | get it from | lifetime | freed by |
|---|---|---|---|
| **gpa** | `app.gpa` (passed to `App.init(gpa, io)`) | process | the owner's `deinit` |
| **snapshot** | `sub.snapshot.allocator()` — one `SnapshotArena` per replace-wholesale dataset | until the next dataset lands | `SnapshotArena.replace` / `reset` |
| **frame** | `app.frame.allocator()` | one loop iteration (dispatch → tick → render) | nobody — `FrameArena.begin` at the top of the next iteration |

```zig
// gpa: lives as long as the buffer
buf.path = try gpa.dupe(u8, path);           // freed in Buffer.deinit

// snapshot: the whole TODO list is replaced at once
const items = try scan.arena.allocator().alloc(Item, n);

// frame: a label that only needs to survive this render
const label = try std.fmt.allocPrint(ui.arena, "({d})", .{count});
```

Rules:
- `page_allocator` only for pty ring buffers. Never in a `test`.
- Every `test` block uses `std.testing.allocator`. Leak = failure.
- No per-buffer arenas: buffer allocations have independent lifetimes, so
  `Editor`/`Buffer` hold gpa-owned `ArrayList`s and free them in `deinit`.
- Nothing allocated from `app.frame` may be stored in `App` or any
  subsystem `State`. If you need it next iteration, `gpa.dupe` it.

## String ownership is spelled by the type

- `[]u8` field ⇒ **owned**. The holder allocated it on the gpa and frees
  it in `deinit`.
- `[]const u8` field ⇒ **borrowed**. A literal, or a slice into a snapshot
  or frame arena. The holder never frees it. To keep it past the current
  iteration, `gpa.dupe` at the boundary and store the result as `[]u8`.

```zig
pub const Item = struct {
    path: []const u8,   // borrowed from the scan's snapshot arena
    title: []const u8,  // borrowed from the same arena
};
pub const DynCommand = struct {
    id: []u8,           // owned: registered at runtime, freed on unregister
};
```

## Event payloads (D3, `src/core/event.zig`)

A payload on `AppEvent` is **owned by the event**. The handler either
adopts it (moves it into subsystem state) or frees it before returning.
There is no third option, and no handler may stash the raw pointer to
"deal with later".

```zig
.todos => |result| app.todos.handle(app, result), // adopts result.arena, frees the box
```

- Workers build the payload on their own arena / gpa allocations and post
  it. A failed `post` calls `freeEvent` so a closed queue cannot leak.
- Workers never toast. Failures travel as `.err = .{ .source, .msg }`,
  with `msg` gpa-owned and freed by the handler after toasting.

## Errors (D2, `src/core/command.zig`)

- Commands are `fn (*App) CommandError!void`. A user-facing reason goes in
  `app.diag.fail(...)` (frame arena) right before `return error.Failed`.
- `errdefer` after every acquire. Multi-field mutations snapshot the old
  values and `errdefer`-restore them.
- No `catch unreachable` outside comptime and tests.
- Render functions return `Allocator.Error!void`; OOM skips the frame.

## Components (D6, `src/ui/`)

- A component is `State` (persistent transient: scroll, hover, filter
  buffer — owned by its subsystem) plus `draw(state, ui, area, props)`.
- Register the hit in the **same statement** as the paint:
  `ui.hits.add(row_rect, .{ .row = .{ .panel = .todos, .idx = i } })`.
  A painted-but-unregistered rect is a bug by construction.
- Components take `Ui`, never `*App`. Only commands and event handlers
  see `*App`.
- Layout is the parent's job (`Rect.split*`); a component paints inside
  the rect it is given and clips to it.

## Commands (D5)

- Ids are `<namespace>.<snake_verb>`; `group` must equal the namespace
  prefix — checked at comptime.
- Runners live in `src/<sub>.zig` as `pub const table = .{ .@"todos.refresh" = &refresh, … }`
  and are merged into `command.runners` at comptime.
- Keys are declared per profile in `commands/specs.zig` (`Keys{ vim, standard, both }`).
  Chord collisions are a compile error per profile.

## Tests

- `std.testing.allocator` only.
- Every behaviour test ships with a break-check: revert the fix, watch
  the test fail, grep that the break really landed.
- Test the shipped default, not values around it.
