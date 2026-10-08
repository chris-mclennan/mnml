# mnml-sdk — write an integration in Zig

An integration is a program mnml opens in a pane. It draws into a cell
grid, gets keys and clicks, and can ask mnml to run commands, toast, or
put things on the statusline. `sdk/mnml-sdk` is the package; the wire it
speaks is `docs/BRIDGE.md`. `integrations/sample` is the official
sample — a counter pane on the SDK, ~270 lines, what mnml's own tests
install and mount; `sdk/examples/hello` is the smaller list that the
host's mount test spawns.

## Your first integration — the sample, end to end

The official Zig integrations live in this repo under
`integrations/<id>/`, each a package of its own on the SDK by path.
`integrations/sample` is the shape to copy:

```
integrations/sample/
  build.zig       an exe on the SDK (`b.dependency("mnml_sdk", …)`)
  build.zig.zon   `.mnml_sdk = .{ .path = "../../sdk/mnml-sdk" }`
  manifest.zon    the manifest — id, label, chip, commands, settings…
  main.zig        `--install` / `--uninstall` / `--version`, then the pane
```

1. **Copy the folder** to `integrations/<id>/`, change `.name` and the
   fingerprint in `build.zig.zon` (`zig build` prints the value to use).
2. **Write `manifest.zon`** — one definition, two readers. `main.zig`
   does `pub const spec: sdk.Manifest = @import("manifest.zon");` and
   `--install` writes exactly that; mnml's INTEGRATIONS section reads
   the same file from the folder on its Dev tab before anything is
   built. The sample declares a chip (a Nerd Font glyph with an ASCII
   twin and a theme colour), two commands — `sample.open`, first, is
   what the chip, Enter and the statusline segment run; `sample.hello`
   is an `ex` line that toasts — a `statusline` segment, a
   pair of `context_menu` rows (*Menu contributions*), and a `settings` row that reaches the binary as
   `MNML_SETTING_MOOD`.
3. **Paint** in `main.zig`: connect (`Mount.connectEnv`), size a
   `Frame` to `mount.geometry`, `setTitle`, paint, `send`; then the
   loop — `resize` resizes the frame, `input` is a key spec / a click /
   a wheel notch, `focus` says whether the keys are yours, `goodbye`
   (or `null` from `next`) ends the loop. The sample keeps a counter,
   the theme name mnml sent in `hello`, and a row that counts on a
   click; `h` toasts through the mount, `q` says `bye`.
4. **Run it from mnml.** Open the INTEGRATIONS section
   (`view.activity_integrations`, `ctrl+shift+x`); the **Dev** tab lists
   every folder under `integrations.dev_roots` — and this repo's
   `integrations/` by itself, since the workspace holds `sdk/mnml-sdk`.
   `b` (or the row menu's *Build*) runs `zig build` in the folder as a
   task pane; `i` (*Install*) builds when nothing is built yet, runs
   `zig-out/bin/<binary> --install` in the task pane, links the binary
   into `<data root>/bin/` and rescans; `B` (*Rebuild + reinstall*)
   always builds first. The **Installed** tab then lists it (`Sample`
   over `sample.open`), the chip is on the palette bar, the segment on
   the statusline, `sample.open` in the palette and on `ctrl+k s`,
   *Mood* in Settings → Integrations. The same folder stays on the Dev
   tab, marked *installed from here* — a folder is a folder, and
   Rebuild + reinstall is the edit loop.
5. **Uninstall** is `x` on the Installed row (or the detail pane's
   *Uninstall*): the manifest goes, and with it the commands, the
   bindings, the chip and the segment. The binary stays.

The corpus does all of this without building: `zig build` installs
`zig-out/bin/mnml-sample`, `mnml test` exports it as
`$MNML_SAMPLE_INTEGRATION`, and a manifest whose `binary` is `$VAR`
resolves through the environment — see
`tests/e2e/integrations_sample_dev_install.test` and
`integrations_sample_marketplace_local.test` (the private-folder path).

A private or external integration is the same folder outside this
repo: point `integrations.dev_roots` at its parent to develop it, or
list its parent as a `local_folder` marketplace source to install it
from the Marketplace tab (`docs/CONFIG.md`). Two entry points add that
source without editing config.zon, through one code path
(`marketplace.addSource`): `marketplace.add_source` — the palette, the
Marketplace tab's `+ source` chip and the INTEGRATIONS tab strip's
right-click menu — and the first-launch setup's Private integrations
row. Either takes the folder (`~` expanded, relative to the workspace)
— a folder of integrations, or one integration's own folder, which is
listed and built as that one integration — or a GitHub monorepo as
`owner/repo[:apps_dir]`. A pasted GitHub URL is read as that repo —
`https://github.com/owner/repo`, the same without a scheme, with a
trailing `.git` or `/`, `…/tree/<branch>/<dir>` (the `<dir>` becomes the
apps dir; the branch is dropped, the default branch is cloned), or
`git@github.com:owner/repo.git`; any other URL is refused. It refuses a folder with nothing to install, and a source
already there by another spelling (a repo in other letter case; a folder
by a symlink, or in other case on a case-folding volume), and appends
the entry to the home config.zon — nothing is written while the
Marketplace is disabled. A folder's rows show at once; the other sources
re-list behind it.

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

The SDK has no package dependencies beyond `std`; it links libc (for
`kill` / `getpid`), and importers inherit that. Zig 0.16.0.

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
            .focus, .hello, .session_state, .focus_item => {},
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

`key.spec` is mnml's grammar: `a`, `shift+a` (an uppercase letter
always arrives as `shift+` and the lowercase), `enter`, `esc`, `up`,
`ctrl+p`, `shift+f5`, `alt+left`, `space`. Click / scroll / hover coordinates are
pane-relative cells; row 0 is your first row (the tab strip is not
yours). The host folds a wheel burst into one `scroll` with `dy` the
notch count (positive = up).

## The pane toolkit — mnml's chrome

`sdk.pane` is what every official integration paints out of, so two
panes cannot drift into two design languages. It owns the caps header
and its right-to-left chip ladder, the tab strip, the filter pill, the
app-colour left gutter, the row ground (one row, or two for a row with
a sub-line), the `Show more (N)` fold row, a detail panel with its `×`
and a scrollbar, and a hint row where every `key label` is a click
target. The full list is the table below. It also owns the two elements a pull-request row hangs off: the
build lines under it and the action button on it, below. The hit map is generic over your own target union, so you keep
your vocabulary and share the bookkeeping.

```zig
const Target = union(enum) { row: u32, filter, quit };
var hits: sdk.pane.HitMap(Target) = .{};

var p: sdk.pane.Painter(Target) = .{
    .f = &frame, .gpa = gpa, .arena = arena, .hits = &hits,
    // The theme the host sent, with your manifest chip colour as the brand.
    .th = sdk.pane.Theme.fromHelloBranded(mount.hello.palette, "teal"),
    .ui = .{ .nerd = mount.hello.capabilities.nerd_font, .ascii = mount.hello.capabilities.ascii },
};
p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = frame.rows - 1 }, cursor_y);
_ = p.capsTitle(1, 0, "SAMPLE", "  (5)");
try p.filterPill(.{ .x = 1, .y = 1, .w = frame.cols - 2, .h = 1 }, query, caret, editing, .filter);
try p.rowGround(.{ .x = 0, .y = y, .w = frame.cols, .h = 1 }, y == cursor_y, .{ .row = i });
try p.hintRow(frame.rows - 1, status, &.{.{ .key = "q", .title = "quit", .target = .quit }});
```

Two rules:

* **Never an ANSI index.** `.{ .index = 6 }` paints whatever the
  terminal calls colour 6, which is how a pane ends up teal in a theme
  that has no teal in it. Every colour comes off `sdk.pane.Theme`, which
  reads the host's `hello.palette` (see `Hello.palette` in
  `docs/BRIDGE.md`) and falls back to the 16-colour palette when a host
  sends none. State colours live there too: `prState`, `pipelineState`,
  `ticketStatus`.
* **Register the rectangle in the same statement as the paint.** Every
  chrome call takes its target for that reason; dispatch is then one
  `switch` on `hits.at(col, row)` and there is no second table to keep
  in step. `hits.at` scans back to front, so an overlay painted after
  the body wins the click.

`sdk/mnml-sdk/src/pane/consistency_test.zig` paints every shared element
from two different target vocabularies and compares the frames cell for
cell — the test that notices when a change moves one pane and not the
other.

### A table's column widths

`sdk.pane.columns.fit(out, specs, width, gap)` lays a table's columns
into a width — the one rule every table in the family follows. Each
`Spec` has a preferred width `w`, a floor `min`, a drop rank, at most
one `rest` column, and two fields for a wide pane:

```zig
const specs = [_]sdk.pane.columns.Spec{
    .{ .w = 14, .min = 8, .need = longest_item + 1 },          // ITEM
    .{ .w = 13, .min = 8, .drop = 3, .need = longest_runner + 1 }, // RUNNER
    .{ .w = 12, .fixed = true },                                 // EXPIRES
};
sdk.pane.columns.fit(&widths, &specs, avail, 1);
```

- **Narrower than the preferred widths**: the shrinkable columns give up
  cells together down to their floors, then the lowest-ranked droppable
  column goes whole, and only then does the `rest` column shrink.
  `need` and `fixed` change nothing here.
- **Wider**: the spare goes first to the columns being cut — `need`, the
  longest visible cell (with any air the row leaves after it), past `w`
  — in proportion to what each is short of, and never past its need. A
  `fixed` column (a number, a date) never grows. What is left is the
  `rest` column's, or blank at the right.

Measure `need` from the rows on screen, every frame. A pane that leaves
it 0 keeps today's widths: its cut names end in `…` while the right of
the pane sits empty.

### A table's column header, and a fill meter

Two pieces a private pane used to have to draw itself are the toolkit's:

```zig
// The header row over a table: names in `Theme.label()`, clipped to
// their widths, one cell of air between. `cols` is your own column
// type after `sdk.pane.columns.fit` — anything with `name` and `w`.
_ = p.columnHeader(x0, y, max_w, cols, 1); // or sdk.pane.columns.header(f, …, th)

// A bucket / quota / budget meter: full cells in the budget chip's tier
// ink (`budgetStyle`'s tiers — good, warn, bad), the rest a dim track;
// `█`/`░`, and `#`/`-` under `--ascii`.
const tier = sdk.pane.meter.tierOfFraction(used_fraction);
_ = p.meter(x, y, 20, remaining_fraction, tier);
```

`sdk.pane.expect.columnHeader(&frame, theme, x0, y, &.{ "KEY", "STATUS" })`
asserts a header row: every name in label ink, and never run into the
next (`STATUSASSIGNEE`). The Bitbucket pane's tables wear this header;
its suite proves it cell for cell what the pane painted before.

### The design language, in full

The toolkit is the list. A pane that paints all of it belongs beside
the ones that shipped before it; one that paints most of it is the one
the next backfill has to come back for.

| element | the toolkit's |
|---|---|
| Host palette roles, never ANSI indices | `Theme.fromHelloBranded` |
| The app-colour left gutter, full height — under a board-shaped body too | `Painter.gutter` + `expect.gutterFullHeight` |
| The caps header — title, count, `as of …`, and the ladder, laid against each other: narrower, the age goes whole, then every chip with an `icon` drops to it, then the count goes whole — never clipped mid-word | `Painter.capsHeader`, `Chip.icon` |
| Its pieces, if you need them apart | `Painter.capsTitle`, `Painter.rightChips`, `Painter.asOf`, `Painter.refreshChipText`, `chrome.help_chip_text` |
| What a fetch is doing while it is out — `⣾ fetching… 2/13 repos`, `queued behind 3 requests`, `waiting for the API budget`, `fetch failed: …` — and the refresh chip turning the host's spinner ring meanwhile | `chrome.Fetch` / `chrome.fetchText`, `Painter.fetchSub`, `Painter.refreshOrBusyChipText`, `chrome.spinnerFrame` (the host's `list_panel` ring, pinned equal); the request's live phase comes off `ratelimit.Notice.live()` |
| A toolbar of ` key: value ` filter chips under the strip, wrapping whole chips | `Painter.toolbarRow`, `Painter.modeChipText` |
| The tab strip and its indicator | `Painter.tabStrip` |
| The filter pill — glyph, placeholder, caret | `Painter.filterPill` |
| A row's ground, its stripe and its hit, in one statement | `Painter.rowGround` |
| The cursor row's band | `Theme.cursorLine` |
| The list's scrollbar when the rows outrun the body | `Painter.scrollbar` + `pane.scrollAt` |
| `⋯  Show more (N)`, one phrase, the words bright | `Painter.showMoreRow` |
| The detail panel's `×` and its own scrollbar | `Painter.detailPanel`, `Painter.scrollbar` |
| A build line under a pull request, and the line where one would be | `Painter.buildRow`, `Painter.buildNote` |
| The door a build line opens — the whole line, in a free row or a table cell | `pane.buildHit` + `pane.build.pageUrl` |
| A row's run of action buttons, always present — `[󰏌 Open]` with room, `󰏌` without | `Painter.actionChips`, `pane.action.formFor` |
| One of them, painted alone: the word in its role colour, the brackets muted | `Painter.actionChip`, `pane.action.chipOf` |
| What a press left on a button — spinner, `⏸`, `[ view ]`, `✗` | `pane.action.caption` |
| Whether a pull request may merge, and why not | `pane.merge` |
| A named confirm | `Painter.confirmBox` |
| The hint row, every `key label` a hit | `Painter.hintRow` |
| The `?` key sheet — ` Keys ` box on the overlay ground, `▾ ── name ── (n)` headers, chords padded to the widest, a long label wrapped under itself, `j/k scroll · Esc close`; Esc / `?` / `q` close it and a stray key is ignored; a row runs its key | `Painter.keySheet`, `pane.keysheet.key` / `scroll` |
| A chord spelled the family's one way — `Enter`, `Space`, `PgDn`, `Home`, `Shift+Tab`, `Ctrl+D`, `Alt+↑`, `D` for `shift+d` — on the sheet, the hint row and a mode's help line | `pane.keysheet.chord` / `chords` |
| A count's noun — `1 PR`, `3 PRs` | `pane.text.noun` |
| The tree keys: `→`/`←` expand / collapse, `Enter`/`Space` toggle, `E`/`C` every node open / shut | (the convention; both first-party panes bind it) |
| State colours | `Theme.prState` / `pipelineState` / `ticketStatus` |
| A chevron that folds under the mouse | `Painter.chevron` |
| One statusline chip per integration: one figure, a bracketed subset only when the pane has one, further counts each named by a glyph after a ` · ` | `pane.figure` |

The gutter runs the WHOLE height of the pane, whatever shape the body
is. A pane with a column-shaped body (a board of boxed columns) starts
its columns one cell in rather than painting over it: the stripe is
the only column that says which application this is, and a pane that
loses it halfway down reads as two panes stacked. The bad-scope error
screen wears it too — a pane that cannot show anything is still this
pane.

Keys and chrome that are not the toolkit's but ARE the family's: `r`
refreshes and `R` refreshes past every cache; `?` opens the key sheet;
the tab wears the manifest's chip glyph.

#### What a statusline segment may say

**One chip per integration.** An integration shows ONE statusline
chip by default; the chip's hover gives the breakdown in words, one
line per number; a click opens the pane. Three chips that all hover as
the same app read as one thing said three times — that is what the
owner saw when Bitbucket PRs published three.

On the chip: **one named figure, a bracketed subset only when the pane
genuinely has one, and every further count named by its own glyph
after a ` · ` — a count of zero left off.**

```
󰂨 12(11)              twelve of my pull requests open, eleven of them unapproved
󰂨 3(2) ·  1 ·  2    …and one review thread on them, two waiting on my review
󰌃 43                  forty-three items assigned to me — and no invented subset
󰌃 10 ·  14           …and fourteen in my QA Actionable Now tab
```

The bracket is a SUBSET of the figure beside it, never a second count
about something else. A second count says what it counts with its
glyph — never as a bare number, because a reader looking at `󰂨 12 3`
has no way to learn which number is which — and the hover says it in
words:

```
3 open pull requests of yours (2 still unapproved)
1 unresolved review thread on them
2 waiting on your review
```

A pane with no subset says one figure and stops. That is not the
poorer half of the standard — `43(2)` invented so the tracker's chip
matches the forge's shape is a number nobody can believe, which is
worse than a chip that says less.

`sdk.pane.figure` is the helper, and it makes the rule true by
construction: one `n`, one optional `subset`, named `parts`.

```zig
var buf: [96]u8 = undefined;
const text = sdk.pane.figure.text(&buf, .{
    .glyph = glyph,
    .n = open_mine,
    .subset = unapproved_mine,
    .parts = &.{ .{ .glyph = "\u{f075}", .n = threads }, .{ .glyph = "\u{f06e}", .n = waiting } },
});
try ipc.statuslineSetSegment(.{ .id = "…", .text = text, .tooltip = breakdown });
```

A part's glyph has an `--ascii` twin like any other (`RT`, `RV`, `QA`).
Give the manifest's segment a short `label` (below): it is how the
statusline's *Segments ▸* menu names the chip.

`sdk.pane.expect.statuslineFigure` is the assertion both integration
suites call on their own published text; `sdk.pane.figure.check`
refuses a second bare figure, a tail after the figure, a ` · ` part with
no glyph or no count, empty brackets, and a "subset" larger than the
figure it claims to be a subset of.

The hover is where the breakdown goes, and it is not rationed: the
figure is what the reader sees from across the room, and the sentence
under the pointer is what explains it.

#### Every glyph ships with its `--ascii` twin

A Nerd Font glyph on a terminal without the font is a hollow box, and
the reader loses the chip, not just the icon. So **every glyph an
integration paints has a twin beside it, and every paint site picks
between them.** The naming is the codebase's: `<x>_glyph` (or
`<x>_nerd`) with an `<x>_ascii` sibling in the same file, or a
`.fallback = "…"` on a manifest entry.

Keep the twin the same WIDTH as the glyph where the layout depends on
it — `󰂨 12(11)` and `BB 12(11)` put the figure in the same column, and
the reader gets the number either way.

A pane reads which one to paint off its `hello`, through
`sdk.pane.Ui`:

```zig
const ui: sdk.pane.Ui = .{ .ascii = mount.hello.capabilities.ascii, .nerd = mount.hello.capabilities.nerd_font };
const g = ui.glyph(chip_glyph, chip_ascii); // ascii OR no font → the twin
```

A run with **no pane** — `--values` under mnml's statusline poller —
has no `hello` to read, so the host puts the same answer in the
environment. `sdk.pane.asciiFromEnv(env)` reads `$MNML_ASCII`; unset
means "the terminal has the font", which is what a child run by hand
from a shell should assume.

```zig
try publishSegments(&ipc, arena, values, bucket, sdk.pane.asciiFromEnv(env));
```

`zig build glyph-audit` is the guard. It walks `src/`, `sdk/` **and
`integrations/`**, names every private-use codepoint against the Nerd
Font catalogue, prints the twin it found beside each, and `--strict`
exits 1 on a site that has none or a codepoint the catalogue does not
know. A glyph literal inside a `test "…" { … }` block is a fixture,
not a painted site, and is listed as such. The tool's own unit test
walks the same three trees, so a new glyph without its twin fails
`zig build unit` as well as the audit.

### Proving your pane CALLS the toolkit

`consistency_test.zig` proves the toolkit is consistent with itself. It
cannot prove your pane uses it — and that is the drift that actually
happens. Point `sdk.pane.expect` at your own painted frame from your
own tests:

```zig
try sdk.pane.expect.capsTitleInk(&frame, theme, 1, 0, "SAMPLE");
try sdk.pane.expect.headerLadderTail(&frame, theme, 0, nerd, ascii);
try sdk.pane.expect.listScrollbar(&frame, frame.cols - 1, 0, frame.rows);
try sdk.pane.expect.foldRow(&frame, theme, fold_y, ascii);
try sdk.pane.expect.statuslineFigure(my_segment_text);
try sdk.pane.expect.buildLineHit(Target, &hits, y, x0, x1, .{ .build_line = i });
try sdk.pane.expect.gutterFullHeight(&frame, theme, 0, 0, frame.rows - 1, ascii);
try sdk.pane.expect.actionRun(Target, &frame, &hits, y, &targets, form);
try sdk.pane.expect.columnHeader(&frame, theme, x0, y, &.{ "KEY", "SUMMARY" });
```

Both official integrations call these, which is the point: one
expectation, checked from two packages, rather than two suites each
checking whatever they happened to be written against. The 2026-09-19
audit (`docs/research/pane-drift-audit-2026-09-19.md`) found seven
elements that had come apart precisely where no shared assertion
existed.

### The conformance suite — one call, every rule

Every integration — the official three and every external one — should
also make this call from its own tests:

```zig
const Probe = struct {
    pub const Target = MyTarget;
    // … the pane mounted on its own fixture …
    pub fn init(gpa: Allocator, size: sdk.testing.Size) !Probe { … }
    pub fn deinit(p: *Probe) void { … }
    pub fn paint(p: *Probe, arena: Allocator) !sdk.testing.Painted(MyTarget) {
        try paintMyPane(arena, &p.frame, &p.app, p.ascii); // `init` kept `size.ascii`
        return .{ .frame = &p.frame, .hits = &p.hits, .theme = p.theme,
            .title = .{ .text = "MY PANE" }, .ladder_y = 0,
            .gutter = .{ .h = p.frame.rows - 1 },
            .list = .{ .bar_x = p.frame.cols - 1, .y0 = 1, .h = p.frame.rows - 2 },
            .statusline = &.{my_segment_text} };
    }
};
test "the design language" { try sdk.testing.conformance(Probe); }
```

`sdk.testing.conformance` mounts the pane at 120×40 and 80×24, each with
and without `--ascii`, and asserts: the caps title is painted in
`label()`; the header ladder ends in refresh then `?` on the chip
ground; the gutter runs its full height in its ink (`|` under
`--ascii`); a list whose bar column shows any bar shows a thumb over a
track, and a declared list outruns its body at one size at least (so the
fixture really exercises the bar — `ListNeverOutruns` otherwise); every
statusline segment obeys the figure rule; under `--ascii` no cell holds a
Private Use Area codepoint; and no hit lies off the frame. A failure
prints the rule and the size (`conformance: GutterBroken at 120x40
--ascii`). A field left null (no ladder, no list, no segments) is a rule
the pane says does not apply; the title and the gutter apply to all.

Rules are added in `sdk/mnml-sdk/src/conformance.zig`, and a rule added
there reaches every pane that calls the suite at its next test run. Jira,
Bitbucket and the sample call it from their `main.zig`.

### Build lines under a pull-request row

`sdk.pane.build` is the one line both official panes paint for a
pipeline run, so a reader who learns one reads the other:

```
✓ SUCCESSFUL · main · 4h · #412
```

State first (it is what the eye is after), then the branch it ran on,
then how long ago — an age rather than a date, because "did this run
since I pushed" is the question — then the run's number.

```zig
try p.buildRow(.{ .x = 0, .y = y, .w = cols, .h = 1 }, indent, .{
    .state = run.stateLabel(), .branch = run.branch,
    .created_on = run.created_on, .number = run.build_number,
}, now_secs, .{ .build = i });
p.buildNote(.{ .x = 0, .y = y, .w = cols, .h = 1 }, indent, "no build ran on abc1234", false);
```

`buildRow` registers the hit with the paint, so clicking the line
opens that run (`sdk.pane.build.pageUrl`). The door is
`sdk.pane.buildHit` — the WHOLE line, indent and trailing air
included, clipped at the first column the pane does not own:

```zig
const door = sdk.pane.buildHit(.{ .x = list_x, .y = y, .w = text_w, .h = 1 }, list_x + text_w);
try hits.add(gpa, door, .{ .build_line = i });
```

A pane whose build line is a table CELL rather than a free row calls
`buildHit` itself, after its table has painted — the map's
last-painted-wins rule then puts the door over the row. That is the
forge pane: both panes paint the same line, both know the page, and on
neither did a click go there until the door was one function.
`sdk.pane.expect.buildLineHit` is the assertion both suites call.

`buildNote` is the line where
a build line would be — fetching, none, or why not — dim, or in the bad
colour when `bad`. `sdk.pane.build.parseEpoch` reads an ISO-8601 stamp
with its offset, which is all the age needs.

### Action buttons, and the session behind one

A row can carry a button — `[ Triage ]`, `[ Review ]`, `[ Merge ]` —
that dispatches a Claude Code session. `sdk.pane.action` is the button:

```zig
var actions = sdk.pane.ActionStore.init(gpa);       // keyed by ROW KEY, not row index
defer actions.deinit();

// The whole run, in one call. `formFor` is asked BEFORE the row paints
// its words, because the buttons take their cells off the text column.
const specs = [_]sdk.pane.action.Spec{
    .{ .word = "Open" },
    .{ .word = "Merge", .state = actions.state(pr_key, "merge") },
};
const form = sdk.pane.action.formFor(&specs, text_w, sdk.pane.action.text_floor, spin, ascii);
const run_w = sdk.pane.action.runWidth(&specs, form, spin, ascii);
_ = try p.actionChips(x, y, form, spin, &.{
    .{ .word = "Open", .target = .{ .pr_button = .{ .row = i, .which = .open } } },
    .{ .word = "Merge", .state = specs[1].state, .chip = sdk.pane.merge.chipOf(th, readiness),
      .target = if (sdk.pane.merge.isPressable(readiness)) .{ .pr_button = … } else .{ .merge_blocked = i } },
});
```

#### The two forms, and why the buttons never go away

**A row's buttons are always there. The width decides how much of
themselves they show, never whether they exist.**

```
 icon+label   [󰏌 Open] [󰘭 Merge]     the glyph, the word, muted brackets
 icon         󰏌 󰘭                     one cell each, the same role colour
```

`action.formFor` picks the widest form that still leaves
`action.text_floor` cells of the text column for the row's own words;
below that the run reduces to its glyphs, and it never reduces past
them. That is one rule for both families and it replaced two: the
forge pane dropped its buttons whole below about 135 columns — on the
CURSOR's row, the one row that can act, so at 80 and 120 the action
was reachable only by key — and the tracker pane clipped forty
summaries to show forty copies of a word.

A button that disappears teaches nothing. A button reduced to its
glyph is still there, still coloured by what pressing it costs, still
pressable, and the hover names it (`action.hoverText`, empty at
icon+label where the word is already on screen).

One glyph per KIND, not one per word, so the whole set is four and
both families wear the same four — each with an `--ascii` twin:

| kind | glyph | ascii |
|---|---|---|
| `navigation` | `󰏌` `md-open_in_new` | `>` |
| `review` | `` `fa-eye` | `?` |
| `dispatch` | `` `fa-rocket` | `*` |
| `final` | `󰘭` `md-source_merge` | `&` |

`[󰏌 Open]` is exactly as wide as the `[ Open ]` it replaces, so no row
got narrower for growing a glyph. A state past `idle` outranks the
kind at both widths: a spinner is a spinner in one cell, and `[ ⠙ ]`
where the word would be.

`sdk.pane.expect.actionRun` is the assertion both suites call — the
buttons are there, the form is the one the row can afford, and every
hit is exactly the cells its button painted.

`actionChip` paints the brackets and the word separately: the
punctuation stays muted and the **word carries the colour of what
pressing it does**, so a row of three buttons is three different
answers rather than three identical grey chips. Neither style names a
ground, so a button on the cursor's row keeps that row's fill.

Four families, by the word (`sdk.pane.action.kindOf`):

| kind | words | colour |
|---|---|---|
| `navigation` | `Open`, `view` | `muted` — it goes somewhere and changes nothing |
| `review` | `Review`, `Test` | `blue` — it starts a session that READS |
| `dispatch` | `Implement`, `Fix`, `Triage`, anything unclassified | the pane's brand, stepped to `purple`/`orange`/`cyan` when the brand is already `blue` or `green` |
| `final` | `Merge`, `Decline` | `green` when ready, muted + dim when blocked (`sdk.pane.merge.chipOf`) |

A state past `idle` is the host's word about a session and outranks
the family — a spinner is a spinner whichever button started it.

Five states, and the last four are the **host's word**, not a guess:

| state | paints | means |
|---|---|---|
| `idle` | `[ Merge ]` | nothing pressed |
| `running` | `[ ⠙ ]`, turning | its session is working |
| `waiting` | `[ ⏸ ]`, warning colour | its session is asking the user something |
| `view` | `[ view ]` | its session ended |
| `failed` | `[ ✗ ]`, bad colour | the dispatch itself failed, or the session did |

A press writes the dispatch, sets `running`, and sends one
`watch_session` naming the button:

```zig
var kbuf: [320]u8 = undefined;
const key = sdk.pane.actionWatchKey(&kbuf, pr_key, "merge");
try mount.watchSession(key, .{ .cwd = workspace, .prompt_line = first_line_of_prompt });
```

Every `session_state` line that comes back goes straight in:

```zig
.session_state => |ss| _ = try actions.applyState(
    ss.key, sdk.pane.actionStateOf(ss.state), ss.session_id, ss.detail),
```

`sdk.pane.action.pressOf(state)` says what a second press means —
`dispatch` only from `idle`, `focus_session` while it is running,
waiting or finished (so a button can never fork a duplicate session),
`retry` after a failure. Keep `Entry.detail` for the hint row: it holds
the question while `waiting` and the reason after a `failed`. The
spinner needs a counter of your own, bumped once per pass while
`actions.anyRunning()`, so every button on screen turns together.

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
| `id`, `label`, `description`, `version`, `category` | the INTEGRATIONS section's row (`label` over the first command's id) and the detail pane |
| `binary`, `args`, `mode` | what a command opens: `mode = .mount` (default) hosts it over the socket; `.pty` opens it as a terminal pane. Leave `binary` out and the manifest is a **launcher** — no program of its own; every command then needs a `run` line (`validate` refuses one without) |
| `chip` | a button on the palette bar: `glyph` (Nerd Font) — or `glyph_codepoint` (`F1D00`, painted verbatim when `glyph` is empty, for a mark in mnml's own font block), `fallback` (plain, always), `color` (a theme name — `red orange yellow green blue cyan teal purple pink magenta comment grey fg white`, `magenta` the same colour as `pink` and `white` as `fg` — or `#rrggbb`; anything else paints in the accent), `tooltip`, `enabled`, `in_palette_bar`. Right-click → enable / disable / show or hide on the bar / add to the activity bar / manifest / remove |
| `commands[]` | each is a palette command with `keys`; it opens the binary (with `args`) unless `run` (or `ex`, the same field) names an ex line to run instead — `term mnml-hello --pty`, `:term code --goto {{current_file_abs}}:{{cursor_line}}:{{cursor_col}}`; mnml expands `{{workspace}}` `{{workspace_name}}` `{{current_file}}` `{{current_file_abs}}` `{{current_file_dir}}` `{{cursor_line}}` `{{cursor_col}}` `{{selection}}` when it fires and leaves an unknown token as written (`launchers/README.md`). The first one is what the chip, Enter and a pinned activity-bar icon do |
| `settings[]` | a row in mnml's settings overlay under *Integrations* (discrete choices); the chosen value reaches the binary as `MNML_SETTING_<KEY>` |
| `statusline[]` | a segment on the statusline while the integration is enabled and its binary resolves — `text`, `side`, `color`, `priority`, `click_command` (a command id), `tooltip`, and an optional short `label` (what the chip counts, in a few words: the statusline's *Segments ▸* menu shows `<integration label>: <label>`, and the raw `<id>.<segment id>` without one) — keyed `<id>.<segment id>`; it goes with the manifest. One per integration (*What a statusline segment may say*). The live run replaces it over Tier 2, where it may also carry `items` (below); a published value stays until the run publishes again or the integration goes, a rescan included. A segment a newer manifest no longer declares is cleared on the rescan its install triggers |
| `requires[]` | environment variables the integration needs (shown in the detail pane) |
| `values_sources[]` | the statusline poller (`src/app/integration_poll.zig`): each entry's `command` runs as `<binary> --values --workspace <ws>` every `poll_interval_secs` (300 by default), one worker per source, staggered, backed off on a failure, and quiet while a pane of the integration is open; `prefetch = true` also runs the whole-pane warm |
| `links[]` | text shapes the integration links — a ticket key and the address it opens — wherever mnml shows text it did not write: a SESSIONS card's name and output, the sessions table's summary, a terminal pane, an editor, the Markdown preview, a commit's message in the git graph, a toast, an HTTP response body. See *Links* below |
| `context_menu[]` | rows this integration adds to menus mnml builds for other panes' rows and for links — see *Menu contributions* below |
| `menu_bar[]`, `auth[]` | parsed and shown in the detail pane; wiring into mnml's menu bar / auth store is a later slice |

**One mark per chip.** A chip, its statusline segment and its pane wear
one glyph, spelled once — the manifest's `chip.glyph`. A segment's
resting `text` writes `{chip}` for it (`.text = "{chip} …"`), and the
binary wraps its manifest in `sdk.manifest.withChipMark`
(`pub const spec = sdk.manifest.withChipMark(@import("manifest.zon"));`),
so what `--install` writes holds the glyph; mnml fills in a `{chip}` it
still meets. A live figure takes the host's mark from `$MNML_CHIP_GLYPH`
(`sdk.pane.chipGlyphFromEnv(env, <the manifest's glyph>)`), never a
codepoint of the binary's own. A further count on the chip
(Bitbucket's review threads, Jira's QA count) wears its own glyph after
the ` · ` when it publishes, and never leads a resting text: at install mnml
names any segment whose resting text starts on a private-use glyph that
is not its chip's, in a warning toast with the integration, the segment
and both glyphs. Jira and Bitbucket each carry a test that the chip's
glyph, the resting text's first glyph and the published figure agree.

`binary` may be `$NAME` (or `$NAME/rest`): the variable's value is the
path. `<data root>/bin/<binary>` is tried before PATH — that is where an
install from the Dev tab or the marketplace links the built binary.

`sdk.manifest.validate(m, &why)` is the rule both readers apply — the
id is a file name; a manifest without a `binary` has a command, and
every such command a `run` line — so `--install` and mnml's scan refuse
the same files. mnml's own launchers live in the repo's `launchers/`.

`sdk.manifest.write` picks the data root the way mnml does
(`MNML_DATA_ROOT`, `XDG_CONFIG_HOME/mnml`, `HOME/.config/mnml`, with
`USERPROFILE` standing in for an unset `HOME`) and
returns the path it wrote. `sdk.manifest.remove(gpa, io, env, id)` is
uninstall. mnml re-scans on `integrations.refresh` and at startup; an
`id` must be a file name (`[A-Za-z0-9_.-]`).

## Links — the text your integration knows

mnml links a plain `http://` / `https://` URL wherever it shows text it
did not write — a session card's name and output, the sessions table's
summary, a terminal pane, an editor, the Markdown preview, a commit's
message, a toast, an HTTP response body: the words underline (dotted at
rest, the accent under the pointer), a click opens them (Ctrl/Cmd+click
in a terminal or an editor, where a plain press is the pane's own; `gx`
in an editor), a right-click offers *Copy link* / *Open link*, and a
card's menu (Shift+F10 on the focused card) lists them as `Open …`
rows. Everything that is not a URL — a ticket key, a
build number — links only because an installed integration says what
it looks like and where it goes. mnml itself knows no project key,
company or product.

```zig
.links = &.{
    .{ .pattern = "[A-Z][A-Z0-9]+-\\d+", .url = "{site_url}/browse/{0}" },
},
```

* **`pattern`** is a Perl-style regex, matched case-sensitively. A match
  must stand alone as a word — no letter, digit or `_` either side — so
  `XENG-1` does not yield `ENG-1`. A match inside a URL mnml already
  linked stays part of the URL.
* **`url`** is a template: `{0}` or `{match}` is the matched text, `{1}`
  … `{9}` the pattern's groups (each percent-encoded where a URL needs
  it), and `{<key>}` a value the integration was configured with. What
  it expands to must start `http://` or `https://`; mnml refuses
  anything else and toasts why.
* **A `{<key>}` is bound once, never per match.** Your `--install` can
  bind it from what only it knows — `sdk.manifest.bindLinks(arena, spec,
  "site_url", url)` before `write`; the Jira integration writes its
  config's `.jira_url` in that way. Whatever is still unbound when mnml
  reads the manifest, mnml binds from the manifest's own `settings[]`
  value of that key, else from the environment variable the `auth[]`
  field of that key names as its `env_fallback` (Jira's `site_url` falls
  back to `$JIRA_URL`). A link with a value still missing is not in
  force — nothing breaks; the key just does not link until the
  integration is set up and installed (or refreshed) again.
* **The first declaration wins.** mnml builds one rule set when it reads
  the manifests — startup, an install, `integrations.refresh` — never per
  frame. URLs come first; then the integrations in the order the
  INTEGRATIONS section lists them (by label), each manifest's `links[]`
  in its own order. Where two integrations' patterns both match the same
  words, the first one listed opens. A disabled integration (its chip
  off) declares nothing.

A capture group carries a part of the match into the address. The
Bitbucket PRs chip links a pull request written `<repo>#<number>`:

```zig
.links = &.{
    .{ .pattern = "(?<![/\\w.-])([A-Za-z0-9_.-]+)#(\\d+)", .url = "https://bitbucket.org/{workspace}/{1}/pull-requests/{2}" },
},
```

`widget#42` opens `https://bitbucket.org/<workspace>/widget/pull-requests/42`.
The lookbehind keeps a path's `src/foo#3` and another forge's
`owner/repo#5` from linking, and a bare `#42` has no repo to match.
`{workspace}` is bound like any `{<key>}`: Bitbucket's `--install` writes
its config's workspace in — and, when the config lists `repos`, narrows
`([A-Za-z0-9_.-]+)` to `(widget|api)` and adds
`<workspace>/<repo>#<number>` — else mnml takes it from the `workspace`
auth field's `$BITBUCKET_WORKSPACE`.

### A bare number — the range table

`Pull request 5505`, `PR #5505` and `pipeline 10554` name no repo, and
every repo numbers its pull requests and pipelines from 1. What tells
them apart is that each repo is at its own height: one is in the 5000s,
another in the 7000s. A link may say so with `resolve = .range`:

```zig
.links = &.{
    .{ .pattern = "(?i)\\bpull request #?(\\d+)", .url = "https://bitbucket.org/{repo}/pull-requests/{1}", .resolve = .range, .ranges = "pr" },
    .{ .pattern = "(?i)\\bpipeline #?(\\d+)", .url = "https://bitbucket.org/{repo}/pipelines/results/{1}", .resolve = .range, .ranges = "pipeline" },
},
```

* **The integration publishes the table.** Over the same IPC channel as
  its statusline (`sdk.Ipc`), after each poll:
  `ipc.linkRanges(manifest_id, rows)`, one row per repo and kind —
  `{ .repo = "acme/widget", .kind = "pr", .low = 5490, .high = 7130 }`.
  It is the whole table every time; the last one replaces the one before
  (an empty table clears it). The wire line is
  `{"cmd":"link-ranges","id":"<manifest id>","ranges":[{"repo","kind","low","high"}…]}`;
  a row with a field missing, `low` above `high`, or a repo with a byte
  other than letters, digits, `_ . - /` is dropped.
* **mnml resolves each match.** Group 1 is the number (the whole match
  when there is no group). The rows of the manifest's own table whose
  `kind` is the link's `ranges` and whose `low`..`high` hold the number
  are the candidates; failing any, the rows the number is at most 50
  past the `high` of (a pull request opened since the poll). `{repo}` is
  filled with the candidate's `repo` as written; every other `{<key>}`
  is bound the usual way.
* **When a link shows.** One candidate: a link to that repo. Several: a
  link to the first — the repo the workspace's git remote names, if it is
  one of them, then the table's order — and its right-click menu lists
  `Open in <repo>` for each, in place of *Open link*. None, or no table
  published yet: the words stay plain. `repo#123` is explicit and never
  goes through the table.
* **Where the numbers come from is the integration's call.** Bitbucket's
  `--values` poll widens each repo's `pr` row with every pull request its
  listing returns and asks for each repo's newest pipelines once an hour;
  it keeps the low and high watermarks in `<config dir>/cache/link-ranges.json`,
  so a restart does not forget a low the open listing no longer shows.

The in-repo integrations: Jira's Work chip declares the issue key
above, Bitbucket's PRs chip the pull request. The sample's
`manifest.zon` declares one, live: `SAMPLE-12` links to
`https://example.com/sample/SAMPLE-12`.

## Menu contributions — rows on other integrations' menus

An integration can add rows to menus it does not own: a Jira ticket's
row, a Bitbucket pull request, a ticket key linked in a terminal. The
owner of the menu never learns who added what — mnml merges them.

```zig
.context_menu = .{
    .{ .target = .{ .kind = "ticket" }, .label = "Triage with Claude", .command = "loops.triage" },
    .{ .target = .{ .kind = "pane:bitbucket:pr" }, .label = "Watch", .command = "loops.watch", .when = "state=OPEN", .hover = "Follows the PR until it merges" },
},
```

| field | |
|---|---|
| `target.kind` | `ticket`, `pr`, `pipeline` — a row or link of that kind anywhere; `link` — every link; `pane:<integration id>:<row kind>` — that integration's pane rows of that kind only. Anything else is refused at load with the reason |
| `label` | the row's text (`title` is the older spelling, still read) |
| `command` | one of this integration's own `commands[]` ids |
| `when` | optional: `field=value` or `field!=value` over `kind` `id` `key` `repo` `n` `state`, the value compared ignoring case |
| `hover` | optional: the info view's copy for the row; the label when left out |

When the row is picked, mnml runs `command` with the clicked thing's
values in its `run` line or its `args`: `{id}` (a ticket's key, a PR's
number), `{key}` (the key, or the matched text), `{repo}`
(`workspace/repo`), `{n}` (a PR's or pipeline's number) and `{url}` (a
link's address). An unknown `{…}` stays as written, and a `{{token}}`
is still the launcher's (`.ex = "echo Triage {key}"`).

The values come from whatever was clicked — a link is whatever a
terminal printed — so the host treats them as untrusted. In `args`
each value lands inside its one argv element as it is. In a `run`
line, which can reach `sh -c`, each value is quoted as one literal word
for the quoting context it sits in (bare, `'…'` or `"…"`), so it can
never close a quote or start a command; on Windows, where `cmd /d /c`
has no such quoting, a value is filled only from letters, digits,
spaces and `/\._-+:@,#=~`. A value holding a NUL or a line break —
or, on Windows, any other character — is refused and the command does
not run.

**Where they appear.** Every installed, enabled integration's matching
rows follow the menu's own, each integration's under a separator and a
muted header with its `label`, integrations by label and rows in
manifest order:

- **A link's menu** — a terminal pane, a session card, a preview: the
  link's kind comes from the `links[]` entry that made it — a range
  link's `ranges`, a literal one's `.kind` (`ticket`, `pr`, `pipeline`;
  left out, only `link` rows join). Jira's issue key declares `ticket`,
  Bitbucket's `<repo>#<n>` forms `pr`.
- **A mounted pane's row** — a pane names the row under the pointer
  with its hover: `help.row = .{ .kind = "ticket", .key = "ACME-123",
  .state = "In Progress" }` (`wire.RowRef`) on the `Help` it passes
  to `mount.hoverHelp`, beside the `command` that names its Key line. A right-click
  there, when some integration contributes to that kind (or to
  `pane:<this pane's id>:<kind>`), opens the host's menu titled with the
  row's key instead of reaching the pane; with no contribution the click
  is the pane's, as before. The Jira pane names its ticket rows and
  cards.

The older shape — `.target = "tree.file"`, `.title = …` — still loads
and shows in the detail pane; those host-surface targets (`tree.file`
`tree.dir` `tab` `pane`) are not wired into a menu.

The sample is the reference: `Echo ticket key` on every `ticket` and
`Echo pull request` on every `pr` (`when = "state!=DECLINED"`), each an
`ex` line that toasts what it was given.

## Publishing an integration — the catalogue entry

`--install` is what a user runs once they HAVE your binary. The
Marketplace tab is how they find it. Its default source is the **mnml
catalogue** — one ZON file listing the integrations mnml itself ships
(`data/marketplace.zon` in the repo, `share/mnml/marketplace.zon`
beside a packaged binary). One entry per BINARY, not per manifest:
`mnml-jira --install` writes three manifests, so Jira is one row and
three chips.

```zig
.{
    .entries = .{
        .{
            .id = "jira",                  // a file name; the row's id, not a manifest id
            .label = "Jira",
            .description = "Jira: work, boards and fix versions — three chips on one binary",
            .category = "tracker",
            .version = "0.2.0",            // what the manifests will say
            .binary = "mnml-jira",         // a bare name, or $VAR / an absolute path
            .docs = "https://github.com/…/integrations/jira",
            .chip = .{ .glyph = "\u{f0303}", .fallback = "J", .color = "blue" },
        },
    },
}
```

Install from such a row is deliberately small: the binary already
exists, so mnml links `<data root>/bin/<name>` at it and runs
`<binary> --install`. The link is the indirection that lets your
manifest keep a bare `binary` name — `resolveBinary` prefers the link
over PATH — so a rebuild in a checkout never moves the binary out from
under a running stable copy, and `run.sh install` relinks the same file
when it moves one to `PREFIX/bin`. `integrations.update` relinks it on
demand; uninstall deletes the manifest and, when no other manifest
names the binary, the link.

A row's state is read off what is installed, matching on the binary's
file name: `installed`, `update available` (the catalogue's `version`
is ahead of an installed manifest's), or `not installed`.

**To publish your own**, you have two shapes today and neither needs
mnml to ship your code:

* a **`github_monorepo_apps`** source — your repo, a directory per
  integration, each with a `build.zig` and a `manifest.zon`. mnml
  shallow-clones, `zig build`s into the data root, links the binary and
  runs `--install`. Users add it with

  ```zig
  .marketplace = .{ .sources = .{ .{ .github_monorepo_apps = .{ .id = "acme", .repo = "acme/mnml-apps", .apps_dir = "apps" } } } },
  ```

* a **`github_launcher_folder`** source — a folder of bare `*.zon`
  manifests for programs already on the machine (launchers). Install is
  the file being copied into the data root.

A `local_folder` source is the same two shapes on a disk you can
reach — a company share, a private checkout — and lists with the
`Private` badge. Add one from the UI with `marketplace.add_source` (or
the tab's `+ source` chip, or the first-launch setup's Private
integrations row) rather than by hand.

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

### Hover help — `Mount.hover` and `sdk.pane.help`

mnml's info view explains whatever the pointer rests on. A mounted pane
paints every cell itself, so only the pane knows that the cell under
the pointer is an `assignee:` chip rather than a row: on every pointer
move (`input` → `hover`), look the cell up in your hit map and call
`mount.hover(title, body)`. The SDK sends it only to a host that shows
it (`hello.capabilities.hover_help`) and only when it changed, so
calling it on every move is free; `""` clears it. The toolkit's own
chrome has one entry each in `sdk.pane.help.common` — the refresh and
`?` chips, a tab, the filter pill, a tree or list row, a chevron, a
build line, the PR row's Open / Review / Merge, the detail panel, the
scrollbar, a picker row, the key sheet — and `help.key` spells a
hint-row entry, so the same element reads the same in every pane; your
own chips and pages get your own words. Both first-party integrations
do this (`App.helpAt`).

When the element's click runs a command, say which: give the entry its
id with `Help.runs("<integration>.<verb>")` (or set `.command`) and send
it with `mount.hoverHelp(help)`. The host then ends your words with a
`Key: <chord>` line, the same line its own controls carry: a command
your manifest published reads its first `keys` entry, a host id reads
the chord under the user's profile, and nothing is printed when the
command has no chord or the id is unknown. The pane never spells a
chord itself, so it cannot disagree with the user's keymap. The field
is optional both ways: an older host ignores it, and an entry without
it is title and body as before. The sample's header is the reference
(`integrations/sample/main.zig`, `helpAt`).

### A figure's hover lists what it counts

**The design-language rule: a statusline figure's hover lists what the
figure counts.** A chip that says `12(11)` and nothing else sends the
reader into a pane to find out WHICH twelve. `tooltip` says what the
number is; `items` says what it is made of.

```zig
try ipc.statuslineSetSegment(.{
    .id = "bitbucket_prs.prs_mine",
    .text = "12(11)",
    .click_command = "bitbucket_prs.open_mine",
    .tooltip = "Bitbucket · 12 open pull requests you authored — 11 still unapproved",
    .items = &.{
        .{ .text = "Fix the login redirect", .sub = "acme/api · unapproved", .command = "bitbucket_prs.open_mine", .args = &.{ "--focus", "api#1234" } },
        .{ .text = "Redesign the empty state", .sub = "acme/web · approved", .command = "bitbucket_prs.open_mine", .args = &.{ "--focus", "web#820" } },
    },
});
```

| field | what it is |
|---|---|
| `text` | the thing itself — a pull request title, a ticket key and summary, a pipeline and its stage. Painted in the foreground. Required; a row without one is dropped |
| `sub` | where it lives, how old it is, what state it is in. Painted muted, right-aligned, and it outlives the tail of a long `text` |
| `command` | the command id a left click on the row runs. Omit it and the row is a label |
| `args` | appended to that command's argv when the command mounts a binary — `.{ "--focus", "acme/api#1198" }`, so a row opens the thing it names rather than only the pane that holds it. An integration opts in by accepting the flag; one that does not should send no `args` |

### `--focus <key>`: a row that opens the thing, not the pane

A row's `args` name ONE of the things the pane lists. The host knows
exactly one shape — `--focus <key>` — and treats it as an argument to
a listing rather than a different listing:

* **the pane is not open**: it is started with the flag on its argv;
* **the pane is already open**: the key goes down the mount as
  `focus_item` (`docs/BRIDGE.md`) and no second pane is started. A
  pane is known by its argv WITHOUT the deep link, so the second row
  of the same hover reaches the pane the first one opened.

So a pane that wants its rows to land takes `--focus <key>` on the
argv AND answers `focus_item` on the socket, with the same code behind
both. The flag is read before anything has loaded, so remember the key
rather than applying it, and try it again at every listing that
arrives. What landing means is the pane's own: both official
integrations open the section that was folded shut, drop the `/` query
that was hiding the row, switch to the tab that holds it, put the
cursor on it and open its detail. A key in no listing is answered
(`not in this listing: <key>`) and forgotten, rather than left waiting
for a listing that is not coming; a narrowing the reader turned on by
hand is the one thing `--focus` does not undo, because undoing it
would empty the listing they asked for.

```
mnml-bitbucket --only prs --focus api#1198
mnml-jira --only work --focus ENG-2
```

Build the rows **from the cache the run already has**. The hover is
worth nothing if it costs a request: `--values` must not fetch more
than it did before it carried `items`, and both official integrations
have a test on the fake's `--log-file` that says so.

**Every publish of a segment carries its rows, not just the poll's.**
A `statusline-set-segment` REPLACES the chip, so an open pane that
republishes its own figure without `items` takes the hover's list away
until the next poll — a list that disappears the moment the reader
opens the pane is worse than one that was never there. Give a pane ONE
publish function, fed from whichever listing is at hand, so the chip a
pane sends for itself is the chip a `--values` run would have sent for
the same things.

The host keeps at most 24 rows off the wire and paints at most
`statusline.hover_items` (8 by default, `docs/CONFIG.md`), with
`… and N more` under them. Send no `items` and the chip keeps the
one-line hover — nothing about an older integration changes.

Each call appends one JSON line to `$MNML_IPC_DIR/command`; the shapes
are in `docs/BRIDGE.md`. Over a mount, prefer `mount.toast` and
`mount.command` — they need no file.

### A toast with something to do about it

A message that reports something and then vanishes leaves the reader
holding the consequence. Since protocol 3 a mounted pane's toast can
carry an offer, and mnml paints it as the button in the box:

```zig
try mount.toastWithAction(.info, "merged #1234",
    .{ .label = "Open PR", .url = pr_url });
try mount.toastWithAction(.@"error", "refresh failed: 503",
    .{ .label = "Retry", .command = "integrations.retry_refresh" });
```

`label` is what the button says, and **exactly one** of `command` and
`url` is set — a row with neither or both is sent as a plain toast
instead, because a button that does nothing is worse than no button.
`command` is an id the host already knows (one of mnml's, or one this
integration registered), run with the pane that offered it focused;
`url` is a page, and mnml applies its own http(s) rule to it. A
sibling cannot name a shell line here.

Use it where the message is the LAST place a thing is named: a merge
that lands takes its own row off the open list, and a refresh that
fails leaves a stale one with nothing on it saying so.
`integrations.retry_refresh` is the host command for the second — it
sends `r`, the refresh key every pane in the family binds, to the
focused integration pane.

`ipc.focusSession(.{ .id = e.session, .cwd = ws, .prompt_line = e.prompt_line })`
brings a session mnml is running to the front — what a `[ view ]` press
asks for. It names the session the same way `watch_session` does, on
purpose: a button that can watch a session must be able to open the
same one.

## A second one, with a network behind it

`integrations/bitbucket` is the other official integration: Bitbucket
Cloud pull requests and pipelines, on the same SDK, as two chips from
one binary (`--install` writes two manifests), with an HTTP client, a
private `config.zon` beside the manifests, a shared cross-process rate
bucket, a worker thread for the fetches, and a deterministic fake
server of its own (`integrations/bitbucket/tools/fake_bitbucket/`). Four
things it ran into are worth knowing before you write one:

* **A key arrives as the host spells it, not as you say it.** mnml folds
  an uppercase letter into `shift+<lower>` and reports a back-tab as
  `backtab` (`src/core/key.zig`'s `Chord.of`). Spell the table that
  way (`keymap.zig`) rather than doubling twenty comparisons.
* **`Mount.next` blocks, so a fetch cannot share its thread.** The pane
  runs a reader thread that turns host messages into events on an
  `Io.Queue`, a worker thread that runs the fetches and posts results
  on the same queue, and a ticker for the auto-refresh; the main loop
  takes one event at a time. A pane that fetches inline freezes for as
  long as the network takes — minutes, under a shared rate bucket.
* **There is no host→sibling command.** `HostMessage` is hello / resize /
  input / focus / session_state / focus_item / goodbye: mnml can start
  your binary for a command, but it cannot send one into a mount that
  is already running. A command that has to act on a *live* pane needs
  a key (`integrations.retry_refresh` sends `r`), or a second headless
  invocation that writes to the Tier-2 channel. `session_state` (only
  about a session the pane asked it to watch) and `focus_item` (a key
  the pane already lists, see `--focus` above) are the two things the
  host volunteers.
* **A `pty` child does not inherit `MNML_IPC_DIR`.** A mount child does
  (`src/bridge/host.zig`'s `envFor`); a `:term` one gets the app's own
  environment. If a headless `run` line has to publish a segment or a
  badge, pass mnml's workspace through the ex line
  (`--workspace {{workspace}}`) and find the channel under it.

`hello.palette` carries the host theme's roles (`theme.zig` there
turns them into the styles the pane paints with, falling back to
palette indices on a host that sends none).

## What every request cost — the request log

A pane that is slow gives the user one word, `loading…`, and no way to
tell a throttled bucket from a wedged socket from a tab that simply
asks for forty things. `mnml_sdk.request_log` is the answer to that:
one JSON line per request, appended to
`<data root>/requests/<service>.jsonl`.

```zig
var log = try sdk.RequestLog.open(gpa, io, env, "jira", "mnml-jira");
defer log.deinit();
client.log = &log;
```

One file per service, because the rate bucket is per service too: two
integrations on one API read back as one story. It rotates at 4 MB and
keeps one older generation (`<service>.1.jsonl`). The host's
`integrations.request_log` block reaches it as two environment
variables on every integration mnml starts — `MNML_REQUEST_LOG`
(`0` / `off` / `false` / `no` turns it off) and
`MNML_REQUEST_LOG_MAX_MB`. An integration run by hand with neither set
gets the log: the point of it is to be there when the slow morning
happens, not to be switched on afterwards.

Every call site passes a **reason** — `pane_open`, `refresh`, `poll`,
`prefetch`, `detail`, `builds`, `readiness`, `dispatch`, `user`,
`warm`, `delta`, `revalidate`, `cache_hit` — because a line that
cannot be read back to a cause is only a route.

The last four are the warmer's. `warm` is filling a cache for a tab
nobody is looking at; `delta` is a window since the last successful
sync; `revalidate` is a conditional GET that came back `304`; and
`cache_hit` is **not a request at all** — a local cache answered, and
`Log.noteCacheHit` writes the line anyway so the pane shows the whole
story. A `cache_hit` line carries `status: null`, `wait_ms: 0` and
`tokens_after: 0`, which is what lets a reader keep counting requests
by counting lines with a status.

Nothing that could carry a credential has a field to arrive in.
`Entry` names what it holds; the only header shape it takes is
`RateLimit`, four numbers about the budget; no body is ever written;
and the query — which IS kept, since `?jql=…` is most of what makes a
Jira line worth reading — has the value of any credential-shaped
parameter replaced with `***`, the parameter left in place so the line
still says it was sent. `splitUrl` also drops a `user:password@`
authority outright.

mnml's own REQUESTS pane (`integrations.requests`) reads these files.

Every line also carries `route` — the path with its ids elided
(`/pullrequests/{n}`, `/issue/{key}`, `{sha}`, `{uuid}`), so one
endpoint reads as one — and a dry run's line carries `"dry":true` and
no status. `RateLimit` reads `X-RateLimit-Limit` / `-Remaining` /
`-Reset` (epoch seconds, or the ISO 8601 stamp Jira Cloud sends) /
`-NearLimit` and `Retry-After`.

## The API budget — `mnml_sdk.budget`

One `sdk.Budget` per pane process: the client writes it on every
request, the paint loop reads it for the header's budget chip. Both
first-party integrations hold one and paint it with
`Painter.budgetChip` and `help.budget`, so the chip is the same in the
same place on every pane.

```zig
app.budget.configure(io, .{
    .label = "Jira", .service = "jira", .data_root = root,
    .hourly_budget = @intFromFloat(rate_per_sec * 3600),
    .dry_run = config.dry_run,
    .backoff = .{ .base_secs = 45, .cap_secs = 120 },
});
client.budget = &app.budget;
```

- **`record(.{ .now_secs, .on_wire, .rate_limit, .cache })`** after
  every request: the latest headers, the calls in the last hour, cache
  hits (a local answer, a 304 with the body held) against misses (a
  read that carried its body), and the day's tally —
  `<data root>/budget/<service>.tally`, `YYYY-MM-DD N` per line, read,
  bumped and written under one exclusive lock so every process on the
  data root adds to one count, rolled over at local midnight.
  `noteHit` records a read a pane's own store answered.
- **A 429**: `throttled(attempt, retry_after)` pauses for `Retry-After`
  (else `Backoff`: `base_secs` doubling per attempt, jittered ±20 %,
  capped at `cap_secs`) and says how long; `backoff.retries(attempt,
  is_read)` only ever says yes for a read. `waitOut()` goes at the top
  of every attempt: a pause of up to `wait_in_request_secs` (30) is
  waited in tenths of a second — `cancelWait()` ends it at once — and a
  longer one is `.paused`, answered without sending anything. Keep the
  bucket's `Limiter.penalize` beside it: the pause is this pane's, the
  bucket every process's. A call made on the paint loop's own thread
  must not wait at all (the loop could not paint `paused until`).
- **Dry run**: `isDry()` / `toggleDry()`. The client writes the line it
  would have sent (`Entry.dry`) and answers from what it holds.
- **`snapshot(now)`**: what the chip and its hover read —
  `chipWords` (`812/1000`, `37/h`, `DRY`, `paused until 14:03:22`),
  `tier()` on the host usage meter's 60 / 85 thresholds, `helpBody`.
  With a feed seam set (`setFeed`, below) the words gain what the poller
  is doing: `812/1000 · feed` while an event file is live, `37/h · 20s`
  while polling. The hover says the interval and how it moves, why a
  feed degraded, and — with a shared bucket — its tokens, its cooldown
  and how many requests were skipped waiting on it.
- **A shared bucket file** (`.shared_bucket`, below): `waitOut` takes a
  token from it after the pause check. An empty bucket is
  `.bucket_empty`, a cooling one `.bucket_cooldown` — the request is
  not sent, and the caller answers `Budget.refusalText(gate)`
  (`isBucketRefusal` tells a pane's skipped round from a failure, so the
  first is a quiet status line and never a toast). `throttled` writes a
  429 into the file as a cooldown.

`ratelimit.Retry` and `parseRetryAfter` are still there for a client
that has no budget; both first-party integrations answer a 429 through
the budget.

## When to ask — adaptive polling and the event feed (`mnml_sdk.feed`)

A pane that lists things from an API has to learn when one of them
moved. Asking is the default, and asking a quiet listing every few
seconds is most of what a pane spends in a day. `mnml_sdk.feed` is one
seam with two sources behind it, so a pane asks one question —
"what changed since my last look?" — whichever answers.

**The poller backs off.** `Schedule` holds the interval. A poll whose
answer is the same as the last one (a `304`, the same `ETag`, the same
content hash — the Bitbucket pane folds every GET's answer into one
digest, the Jira pane asks for a window and counts what came back)
doubles it, from the base up to a cap; a poll that found a change, a
key, a click, the wheel, a paste, the pane taking focus, or `r` puts it
back to the base. The first load is the pane's own, never the poller's.
Both panes read the same two keys:

```zig
.refresh_interval_secs = 5,   // the base; 0 turns polling off
.poll_max_secs = 120,         // the cap: 5 → 10 → 20 → 40 → 80 → 120
```

A cap at or below the base keeps the interval fixed.

**The event file.** `feed.file` names a JSONL file any process on the
machine may append to — a webhook relay, a gateway reader, a script
tailing a queue. The pane tails it by byte offset (complete lines only,
the way the host's IPC reader does), coalesces what it read by key,
and fetches **only those items**, through the same client and budget as
everything else. While the file is live the poller does not stop: it
drops to a safety sweep every `sweep_secs`, because a feed that lost one
line must not leave a row wrong forever. When the file is missing, or
nothing has been written to it for `stale_secs` — no event and no
heartbeat — the pane goes back to adaptive polling from the base, and
the budget chip's hover says which.

```zig
.feed = .{ .file = "~/feeds/bitbucket.jsonl", .stale_secs = 300, .sweep_secs = 600 },
```

A relative `file` is taken against the config file's directory; `~/`
is the home directory. Empty (the default) is off.

### The event line — a public contract

One JSON object per line, UTF-8, `\n`-terminated. Append whole lines
(`O_APPEND`, one `write` per line); a line with no newline yet is left
for the next look.

```json
{"kind":"pr","key":"api#1234","at":1790000000,"source":"relay"}
{"kind":"issue","key":"ENG-12","at":1790000003.5,"source":"relay"}
{"kind":"heartbeat","at":1790000060,"source":"relay"}
```

| key | type | meaning |
| --- | --- | --- |
| `kind` | string | `pr` (a pull request), `issue` (a tracker issue), `heartbeat` (nothing changed; the writer is alive). Required. |
| `key` | string | Which item, keyed the way the pane keys its rows: `<repo>#<id>` for a pull request (`<workspace>/<repo>#<id>` also works; the workspace defaults to the tab's, else the config's), the issue key for an issue (`ENG-12`). Required for `pr` and `issue`; at most 200 bytes, no control characters. |
| `at` | number | When it changed, epoch seconds (fractions allowed). Kept for the record; ordering is the file's. |
| `source` | string | Who wrote it — the hover names the last one. Optional. |

The rules a reader follows, so a writer knows what it can rely on:

- A pane opening on an existing file starts at its end: what was there
  before is history its own first load already covers.
- Any well-formed line — an event of any kind, a heartbeat, a `kind`
  this reader does not know — proves the writer is alive. A line that
  is not a JSON object with a string `kind` does not, and is skipped.
  A writer with nothing to say should write a heartbeat at least every
  `stale_secs` (default 300 s) or the pane will stop trusting it.
- Keys are coalesced: twenty lines about `api#1234` between two looks
  are one fetch. A key whose fetch is still out is not asked for again.
- A pull request that no longer belongs to the listing on screen (merged
  out of an open list), or is not in it yet, costs one conditional GET
  of the listing instead of the item.
- The file may be truncated or replaced at any time (rotation). The
  reader starts over from the first byte when the file at the path is
  another file (its inode — Windows' file index — changed: moved aside
  and a new one written, whatever its size), when it is smaller than
  the reader's offset (truncated in place), or when its modification
  time went backwards. A file that disappears and comes back is read
  from its first byte.
- Kinds other than the ones a pane wants are ignored by that pane. The
  Bitbucket pane reads `pr`; the Jira pane reads `issue`. Both may share
  one file.

```zig
var w: sdk.feed.Watcher = .init(io, .pr, cfg.refresh_interval_secs, cfg.poll_max_secs, cfg.feed, resolved_path);
// every tick, while the listing is not already loading:
const look = try w.look(arena, now_ms);
if (look.sweep) { refreshListing(); w.started(now_ms); }
else for (look.changed) |c| fetchOne(c.key);
budget.setFeed(w.state(now_ms));
// when a listing lands: w.settled(changed); on a key or a click: w.touch();
```

`Feed` is the interface both sources sit behind (`PollFeed.feed()`,
`FileFeed.feed()`); `Watcher` is the rule between them.

## The recent-items cache — `mnml_sdk.cache`

What your integration polls anyway, shared: the host labels a link
to `ACME-123` with the ticket's summary, and any pane — in any language
— can read the same file. One small typed record per item, never a body:

| kind | id | record |
|------|----|--------|
| `.ticket` | `ACME-123` | `sdk.cache.Ticket` — summary, status, status_category, assignee, priority, type, fix_versions, updated |
| `.pr` | `acme/widget#45` | `sdk.cache.Pr` — title, source_branch, dest_branch, author, state, draft, updated |
| `.pipeline` | `acme/widget!1234` | `sdk.cache.Pipeline` — state, result, ref_name, created, updated |
| `.release` | `ACME/2026.10` | `sdk.cache.Release` — name, project, state, release_date, role (`current`/`next`/empty), keys |

People appear by display name only — never an account id or an email.

```zig
// Where a poll already has the records in hand (a worker, not paint):
_ = sdk.cache.put(gpa, io, env, .{
    .source = "jira",
    .kind = .ticket,
    .listing = "assigned_open", // which poll this was
    .complete = true,           // the listing came back whole
    .stale_after_secs = 120,    // the poll interval, doubled
}, tickets);                    // []const sdk.cache.Ticket
_ = sdk.cache.failed(gpa, io, env, "jira", .ticket); // the poll failed: error_at only

const t = sdk.cache.get(.ticket, arena, io, env, "ACME-123"); // ?Found(Ticket)
const open = sdk.cache.query(.pr, arena, io, env, .{ .repo = "acme/widget", .state = "OPEN", .since_secs = 7 * 86400, .limit = 50 });
```

`put` upserts by id and sets `seen_at`; it never deletes on absence.
With `.complete = true`, a record that named this listing before and is
missing now loses the listing and turns `stale` (it moved or closed);
seeing it again clears that. `putAt` / `failedAt` / `getAt` / `queryAt`
take the `recent/` directory instead of the environment — what a worker
thread holding no `env` calls (`sdk.cache.rootDir` once, up front). A
`Found` carries `source`, `seen_at` and a computed `stale`. Every write
is best effort and returns an `Outcome`, never an error.

### The file — a public contract

`recent/<source>/<kind>.json`, `recent/` being the first of
`$MNML_SHARED_STATE_DIR/recent/`, `<MNML_DATA_ROOT>/recent/`,
`~/.config/mnml/recent/`:

```json
{"version":1,"source":"jira","kind":"ticket","fresh_at":1791100000,"error_at":0,"stale_after_secs":1800,"records":[
 {"id":"ACME-123","seen_at":1791100000,"stale":false,"listings":["assigned_open"],"summary":"Fix the login redirect","status":"In Review","status_category":"indeterminate","assignee":"Pat Example","priority":"High","type":"Bug","fix_versions":["2026.10"],"updated":"2026-10-01T09:12:00.000+0000"}
]}
```

- `fresh_at` is the last good poll, `error_at` the last failed one,
  `seen_at` when the record last came back. A record reads as stale
  when its `stale` is true, when `error_at` is newer than `fresh_at`,
  or when `fresh_at` is more than `stale_after_secs` ago. A stale
  record is still shown — an old title beats none.
- Fields a reader does not know are kept on rewrite, so a newer
  writer's survive an older one's.
- **Writers** take `<kind>.lock` exclusively (a writer that cannot in
  2 s skips the write), merge, evict, write `<kind>.json.tmp.<pid>`
  mode 0600 and rename it over the file — three tries 50 ms apart,
  then give up until the next poll. The directory is 0700.
  **Readers** never lock and refuse a file over 4 MiB.
- Eviction, oldest `seen_at` first: tickets 1000 / 30 days, PRs 500 /
  30 days, pipelines 20 per repo / 14 days, releases 20 plus every
  `current`/`next` / 180 days. A file stays under 2 MiB.
- `$MNML_RECENT_ITEMS=0` turns every write off; mnml sets it for what
  it starts when the user sets `recent_items.enabled = false`.
- The files hold real company data: they live on the user's machine
  only — never under a workspace's `.mnml/`, never in a repo or a bug
  report. Tests point `MNML_SHARED_STATE_DIR` at a scratch directory.

### Who writes what

| file | listings | complete |
|------|----------|----------|
| `jira/ticket.json` | `assigned_open`, `qa_actionable` (`--values`), `tab:<name>` | yes, unless a delta window or an event feed's keys |
| `jira/release.json` | `versions:<PROJECT>` — whenever the pane fetches a project's versions (a release tab resolving its version, the Fix Version picker) | yes |
| `bitbucket/pr.json` | `authored`, `reviewing` (`--values`), `tab:<name>` | when every repo answered |
| `bitbucket/pipeline.json` | `probe` (`--values`' hourly per-repo probe), `tab:<name>` | never: a run that left the newest page aged out, it did not change |

A release's `role`: `current` is the project's nearest unreleased
version by `release_date`, the undated after every dated one (then by
name); `next` is the unreleased one after it. mnml's
`recent_items.current_release` reaches the integrations it starts as
`$MNML_RECENT_CURRENT_RELEASE=ACME/2026.10` and names `current`
outright; `next` is then the one after that. A release's `keys` are
the issues a release tab last listed for it, carried across the next
versions fetch. Pinned through eviction: every record with a role.

### Reading it from a shell

```
mnml cache get <kind> <id>                     # the record as JSON; exit 1 when absent
mnml cache ls <kind> [--source S] [--limit N]  # id, title, status, source[, stale] — tab-separated, newest first
mnml cache clear [kind] [--yes]                # remove that kind's files, or every source's; asks unless --yes
```

In mnml, `picker.recent_items` lists the cached tickets and pull
requests, newest first, and Enter opens one where its link would.

## The shared bucket file — a public contract

`budget.shared_bucket` names a file holding one token bucket that every
caller on the machine draws from — mnml's panes, and anything else that
agrees to the format (a script, another tool's poller). It is
separate from `ratelimit`'s per-service state file, whose six keys are
the older contract below; this one is opt-in, per config, and names its
own path.

```json
{"rate_per_sec":0.25,"burst":40,"tokens":12.5,"updated_at":1790000000.25,"cooldown_until":null,"last_429_at":null}
```

| key | type | meaning |
| --- | --- | --- |
| `rate_per_sec` | number | Tokens added per second. `≥ 0`. |
| `burst` | integer | The most the bucket holds. |
| `tokens` | number | What was left at `updated_at`. |
| `updated_at` | number | Epoch seconds, fractional — when `tokens` was last written. |
| `cooldown_until` | number or `null` | While in the future, every caller is refused. |
| `last_429_at` | number or `null` | When a caller last met a 429. |

Every access is **one read-modify-write under an exclusive advisory
lock** on the file (`flock` on Unix, `LockFileEx` on Windows; a reader
that only looks takes a shared one):

1. Refill: `tokens = min(burst, tokens + (now − updated_at) × rate_per_sec)`,
   `updated_at = now` (a clock behind `updated_at` refills nothing).
2. If `cooldown_until` is in the future: refused — skip this round.
3. Else if `tokens ≥ 1`: take one (`tokens −= 1`) and send.
4. Else: refused — skip this round. Nothing is sent and nothing waits
   inside the request; the pane says `waiting on the shared rate-limit
   bucket` and asks again on its next round.
5. On a 429: `cooldown_until = max(cooldown_until, now + Retry-After)`
   (else the budget's own backoff), `last_429_at = now`, `tokens = 0`.
6. Write the document back whole, **keeping every key you do not know**.

One token per request that would reach the wire — a retry is a request;
a cache answer and a dry run are not. **This code never creates the
file**, and a missing file, a file that is not a JSON object, or one
missing any of the four numeric keys is **no bucket**: the request goes
as if none were configured. A bad file can slow a pane; it can never
take its API away.

```zig
.budget = .{ .shared_bucket = "~/buckets/bitbucket.json" },
```

**The file this machine may already share.** `ratelimit`'s
`<service>-ratelimit.json` — the one the Rust crate `mnml-ratelimit`
and any other tool on the machine that agrees to the file format read
and write — is the same bucket under older names, and `shared_bucket`
reads it too:

| `ratelimit`'s key | is read as |
| --- | --- |
| `ts` | `updated_at` |
| `rate` | `rate_per_sec` |
| `tokens` | `tokens` |
| `cooldown_until` (`0` = none) | `cooldown_until` |
| `last_429` (`0` = none) | `last_429_at` |
| `throttles` | kept; a 429 adds one |

That file carries no burst, so it stands for the service's own
capacity (`ratelimit.Config`: 40 for Bitbucket, 60 for Jira). A file is
written back in the names it was read in, so the processes already on
it keep reading it. **On a machine that already shares one, pointing
`budget.shared_bucket` at it is the expected setup** — every pane, the
statusline poller and any other tool on the machine that agrees to the
file format then draw on one allowance under one lock, rather than on
two buckets that each think they are the whole budget.

**Where `ratelimit`'s state file is** (`ratelimit.statePath`), the
first of:

1. `<SERVICE>_RATELIMIT_STATE` — the file, named outright;
2. `$MNML_SHARED_STATE_DIR/<service>-ratelimit.json` — the directory
   holding state every process on the machine shares; point any other
   tool that agrees to the file format at the same directory;
3. `$MNML_DATA_ROOT/ratelimit/<service>.json`;
4. `~/.config/mnml/ratelimit/<service>.json`.

An empty variable counts as unset, and nothing under the home directory
is probed for: with neither variable set the bucket is mnml's own. The
file name `<service>-ratelimit.json` and its six keys are the contract;
the broker's socket, the election lock and `<service>-draws.jsonl` sit
beside whichever file this resolves.

### A bucket per token — part of the contract

Bitbucket Cloud counts its rate limit **per token, not per IP**
(measured 2026-10-07: a second token from the same machine got 200s
while the first sat in a 429). So a service that counts per token keeps
one bucket per credential, beside the shared one
(`ratelimit.statePathFor`, `Limiter.forToken`):

```
<dir of the shared file>/<service>-ratelimit-<id>.json
```

**`<id>`** is the first 12 lowercase hex characters of a sha256 over the
bare credential, as UTF-8:

- strip a leading `Bearer ` and hash what is left;
- for a `Basic ` header, strip it and **base64-decode first**, then hash
  the decoded `user:secret`;
- for Basic auth held as a `(user, secret)` pair, hash `user:secret` —
  one colon, no newline — so the pair and the header it builds name the
  same bucket.

Two vectors pin the rule; any implementation must agree:

| hashed | `<id>` |
| --- | --- |
| `abc` | `ba7816bf8f01` |
| `me@x:pw` (also `Basic bWVAeDpwdw==`) | `0032469eec6d` |

Same six keys, same lock, same arithmetic as the shared file. **No
credential — or a client that predates this — means the shared file,
unchanged**, and so does `<SERVICE>_RATELIMIT_STATE`, which names the
file outright. It is opt-in per service (`ratelimit.per_token_services`):
Bitbucket is in; Jira is not, its limits never having been measured.
The broker hands out the shared bucket, so a per-token limiter does not
ask it.

The draws file stays **one per service** (`<service>-draws.jsonl`,
beside both buckets); a draw from a per-token bucket carries an eighth
key, `token_id`, the same 12 hex (see the draws file below).

## The shared HTTP response cache — a public contract

`mnml_sdk.http_cache`: Bitbucket and Jira GET responses held on disk,
one file per URL, so a second process asking the same question within
minutes does not spend another request. mnml and any other tool on the
machine that agrees to the format read and write the same files: each
works alone, and on a machine with both they share entries by pointing
at one directory. `sdk/mnml-sdk/src/testdata/http_cache_vectors.json` is
the shared case file — canonical URLs with their file names, item keys,
decisions, and the Bitbucket URLs that are never held — vendored
verbatim from the other implementation. Every case runs as a unit test
here, and a section the test does not know fails it by name, so a
re-vendor cannot pass by being skipped.

**A cache is a hint.** Any read, parse or write failure costs a
request, never a wrong answer and never an error.

```zig
const d = (try sdk.http_cache.Dir.fromEnv(gpa, env, "bitbucket")) orelse return; // off, or no home
defer d.deinit(gpa);
const url = try sdk.http_cache.canonical(a, raw_url, &.{});
const key = try sdk.http_cache.itemKey(a, url);       // acme/widget#45, or ""
const entry = d.load(a, io, url);                     // ?Entry
switch (sdk.http_cache.decide(entry, now, d.changedAt(a, io, key), listing_stamp)) {
    .fresh => {},      // answer from entry.?.body — no request
    .revalidate => {}, // If-None-Match: entry.?.etag; a 304 → d.confirm(a, io, entry.?, sent_at)
    .miss => {},       // a plain GET; a 200 → d.store(a, io, .{ .url = url, .body = …, .etag = …, .key = key, .now = sent_at })
}
_ = d.markChanged(a, io, key, sdk.http_cache.changedNow(io)); // after a write this process made
```

### Where

`<root>/http-cache/<service>/`, `<root>` being the first of
`$MNML_SHARED_STATE_DIR`, `$MNML_DATA_ROOT`, `~/.config/mnml` (the
recent-items cache's rule, `cache.sharedDir`). `<service>` is
`bitbucket` or `jira`.

| file | what |
| --- | --- |
| `<sha256 hex of the canonical URL>.json` | one response |
| `changed/<sha256 hex of the item key>.json` | one item's change stamp |
| `<target>.<pid>.tmp` | a write in progress — never an entry |
| `<root>/http-cache/.gc-at` | when the last sweep ran (its modification time) |

`$MNML_HTTP_CACHE=0` (or `off` / `false` / `no`) turns the cache off for
a process. `$MNML_RECENT_ITEMS` does not touch it.

### The canonical URL

The cache key, so two writers that build the same request reach the
same file:

1. Scheme and host lower-cased; the default port dropped; the fragment
   dropped; a `user:password@` authority dropped.
2. The path kept byte for byte.
3. The query: every `name=value` pair, blank values kept, decoded (`+`
   is a space), sorted by name then value (code-point order of the
   decoded text), then each part percent-encoded as UTF-8 with only
   `A-Z a-z 0-9 - . _ ~` left bare (space is `%20`, `,` is `%2C`),
   joined with `&`. No `?` when there are none. A list parameter is one
   pair per element; a number is the caller's text (`50`, not `50.0`).

Credentials never appear in a URL, so they never reach a key. Because
every token on the machine shares the files, a writer holds only
responses that are the same whichever credential asks: Bitbucket reads
under `/2.0/repositories/` — never `/2.0/user`, a workspace probe, or
anything with a `role=` parameter, even under `/2.0/repositories/`
(`?role=member` lists what the caller can see). A `role` inside another
parameter's value, such as an encoded `q=` search, is still held.
`sdk.http_cache.bitbucketShareable(canonical_url)` is that rule.

Query bytes that do not decode as UTF-8 become U+FFFD, one per broken
sequence: `?q=%FF%FEa` canonicalises to `?q=%EF%BF%BD%EF%BF%BDa`.

### A response file

```json
{"version":1,"url":"<canonical URL>","key":"acme/widget#45","status":200,
 "etag":"\"abc\"","stamp":"2026-10-06T12:00:00Z","fetched_at":1790000000,
 "valid_until":0,"content_type":"application/json","body":"<response body, verbatim>"}
```

| field | meaning |
| --- | --- |
| `version` | `1`. Any other value reads as a miss. |
| `url` | the canonical URL. A file naming another URL is a miss. |
| `key` | the item the response is about: `<workspace>/<repo>#<pr id>` for a pull request and everything under it, `<workspace>/<repo>!<build number>` for a pipeline run, the issue key for a Jira issue; workspace and repo lower-cased. Empty for a listing and anything else. |
| `status` | `200` — only 200s are stored. |
| `etag` | the `ETag` header, or empty: an expired entry revalidates with `If-None-Match`, and a `304` keeps the body. |
| `stamp` | the server's own last-changed value for `key` (`updated_on`, `updated`), when the writer knows it. A reader holding the same stamp from a cheap listing uses the entry with no request. |
| `fetched_at` | when the body was last confirmed current (a 200, or a 304), epoch seconds — the time the request was **sent**, so a change stamped while it was in flight still makes the entry stale. |
| `valid_until` | answer with no request until then; `0` means always ask first. |
| `content_type` | optional: the response's `Content-Type`, written when known. Empty and absent both mean unknown. |
| `body` | the response text. A writer skips bodies over 8 MB. |

A reader ignores fields it does not know; a writer rewriting an entry
after a `304` may keep them or drop them (mnml drops them).

Times may be integers or decimals; a reader compares them as numbers.
mnml writes integers: `fetched_at` rounded down, `changed_at` rounded
up, so neither ever claims to be later than it was.

### A change stamp

```json
{"version":1,"key":"acme/widget#45","changed_at":1790000100}
```

Written when anything learns the item changed: a write this process
made itself, or a webhook. An entry with this `key` and `fetched_at <
changed_at` is stale whatever its `valid_until` says. A writer only ever
moves `changed_at` forward.

### Deciding

Given an entry, the time, the item's `changed_at` (if a change stamp
exists) and a `stamp` from the caller (if it has one), in order:

1. No entry, unreadable, or `version` is not 1: **miss**.
2. `changed_at` is after `fetched_at`: **revalidate** if there is an
   `etag`, else **miss**.
3. The caller's `stamp` and the entry's are both non-empty: equal is
   **fresh**, different is **revalidate** if there is an `etag`, else
   **miss**.
4. `now < valid_until`: **fresh**.
5. An `etag`: **revalidate**. Otherwise **miss**.

**fresh**: answer from `body`, no request. **revalidate**: GET with
`If-None-Match: <etag>`; a 304 answers from `body` and rewrites the
entry with a new `fetched_at` / `valid_until`; a 200 replaces it.
**miss**: a plain GET; a 200 is stored. A revalidation takes a
rate-limit token like any other request.

In the request log a fresh answer is a `cache_hit` line (no status, no
request) and a 304 is a `revalidate` line with `cache: hit` — the
REQUESTS pane's meanings, unchanged.

### Writing

The whole file goes to `<target>.<pid>.tmp` in the same directory, then
a rename over the target (`rename(2)`; on Windows `Io.Dir.rename`, which
replaces an existing target — `MoveFileEx`'s replace). No lock: one file
is one entry, a rename is atomic, and the last writer wins with a whole
entry. Every store is written at once, not at exit, so other processes
see it. A reader never sees a partial file.

### What mnml writes

- **Bitbucket.** Every GET under `/2.0/repositories/` goes through the
  cache. A listing is stored with `valid_until: 0` — mnml always asks
  first, conditionally — and an entry another writer stored with its
  own TTL is honoured. A pull request's own detail carries its
  `updated_on` as the stamp; its comments carry the listing's
  `updated_on` when the caller had one (the readiness look and the
  statusline's review-thread count pass it), so an unmoved pull request
  costs no request at all. `R` (full refresh) asks outright and stores
  what comes back. Dry run answers from whatever is held.
- **Jira.** A ticket's linked-PR (dev-status) answer, under the issue
  key with the ticket's `updated` as the stamp and `valid_until: 0`.
  The search that carries `updated` is what makes it free on the next
  open. A 404 ("no dev info") paints as an empty list and is not
  stored — it is not a 200.
- **Change stamps.** After every write mnml itself makes — a Bitbucket
  approval or its withdrawal, a Jira transition, comment, assignee,
  fix-version or watch change — the item's `changed_at` moves to now.
  mnml does not merge or decline pull requests itself (a merge is a
  Claude Code session's, `sdk.pane.merge`), so those stamps are the
  merging tool's to write.

### Collecting

Entries, change stamps and abandoned temp files older than seven days by
modification time may be deleted by anyone. mnml does it at most once a
day, from the first store after `<root>/http-cache/.gc-at` is a day old
(`http_cache.maybeGc`; `gc(max_age)` sweeps on demand).

**Upgrading.** The single-file stores this replaced —
`<data root>/cache/bitbucket/etags.json` and
`<data root>/cache/jira/dev-status.json` — are no longer read, and not
deleted. The first open after an upgrade costs one unconditional GET per
URL. Jira's `cache/jira/sync.json` (the delta windows' marks, not a
response store) is still read and written.

## The warmer — pacing, one warmer per service, windows

`mnml_sdk.warm` is the part `ratelimit` and `http_cache` do not own: **when**
a request may go, **who** may make the speculative ones, and **how
little** of a listing has to be asked for. It lives in the SDK because
two integrations drawing on one bucket have to agree about it.

```zig
var gate: sdk.warm.Gate = .forConfig(sdk.ratelimit.configFor("bitbucket"));
client.gate = &gate;
```

**Pacing.** `Gate` spaces a service's requests at one per
`1/rate + margin` and hands out send times rather than blocking.
`Gate.hold(priority, now_ms)` gives a background caller the wait and an
interactive caller **zero** — a person is watching, the bucket already
bounds how fast they can spend, and holding them saves no tokens. Their
reservation still moves the slot, so background work steps behind them.

**Priority** comes off the reason every request already carries.
`warm.priorityOf` sorts `Reason` into the two that matter: somebody is
waiting (`pane_open`, `refresh`, `detail`, `user`, `readiness`,
`dispatch`) or nobody is (`poll`, `prefetch`, `builds`, `warm`,
`delta`, `revalidate`, `cache_hit`).

**One warmer per service.** Speculative work is worth doing once on a
machine, not once per pane. `warm.Lock` is a file beside the ratelimit
state naming the process doing it; everyone else reads the cache.

```zig
var lock = try sdk.warm.Lock.forService(gpa, io, env, "bitbucket", sdk.warm.selfPid(), "mnml-bitbucket");
defer lock.deinit();
if (lock.acquire(now_secs)) { … warm the tabs nobody is looking at … }
```

The lock **heartbeats** rather than recording a start time: a paced
sweep is slow on purpose, so the holder rewrites `ts` as it works and a
lock nobody has touched for `Lock.stale_secs` is taken whatever its pid
says — which is what covers a reused pid and a platform with no
liveness probe.

**Windows.** `warm.windowStart(last_sync, now)` reaches back
`overlap_secs` further than the gap, because two clocks are never the
same clock; `sinceText` renders it as Jira's `-15m` and `isoStamp` as
Bitbucket's `2026-09-19T08:30:00+00:00`. `SyncMarks` keeps the mark in
an ordinary `Store` — the entry's own `fetched_at` IS the mark, so
nothing new goes on disk.

**Intervals and the floor.** `warm.Intervals` states the three
cadences an integration's config carries — listings 300 s, in-progress
builds 90 s, readiness 0 (on demand only) — and `warm.underBudget`
answers whether the shared bucket has too little left for speculative
work (under `budget_floor`, a quarter, or parked by a 429). A poller
that gives way says `warm.skipped_budget` — `poll_skipped_budget` — so
a chip that stopped moving is explained rather than mysterious.

**The freshness both families wear.** `warm.asOfText` and the pane
toolkit's `Painter.asOf` put `as of 4m ago` after the caps subtitle in
the same muted ink, so two panes say it the same way.

## The broker — who gets the next token

The shared bucket says how much of an API's budget is left and makes
every process draw from one number. What it cannot say is **who goes
next**: the file bucket is first-come, so the pane a person is looking
at queues behind whatever batch script asked a millisecond earlier. On
a machine running a dozen Claude sessions, mnml and a handful of loops,
that is most of the time.

`mnml_sdk.broker` is a queue in front of that bucket — one Unix socket
per service, four classes:

| class | who |
| --- | --- |
| `interactive` | the pane on screen: `pane_open`, `detail`, `user`, `dispatch`, `readiness` |
| `refresh` | wanted soon, nobody watching: `refresh`, `poll`, `builds`, `revalidate` |
| `warm` | speculative: `warm`, `delta`, `prefetch` (and `cache_hit`, which never asks) |
| `batch` | a shell script, a capture tool — nothing a pane does reaches it |

**The rule, written down.** Waiters are served by *effective class*,
ties by arrival. A waiter's effective class is its declared class
promoted one step for every full `broker.age_step_ms` (10 s) it has
been queued, capped at `interactive`. So strict priority never becomes
starvation: a `batch` waiter reaches the front after three steps
however busy it is above, and `warm.classOf` is the one mapping from a
reason to a class, so two integrations on one bucket agree.

**It is a queue, not a second bucket.** The broker holds a
`ratelimit.Limiter` on the SAME state file, under the same exclusive
lock the Python `bb_ratelimit.py` takes, so a Python process that
predates it keeps working and "tokens left" is one number wherever it
is read. It writes no draw line of its own: the client writes it once
the reply lands, so `<service>-draws.jsonl` keeps naming whoever
actually spent the budget.

**Using it is one call.** `Limiter.forService` resolves the socket at
startup and `acquireVia` tries it per request, falling back to the file
bucket when there is none:

```zig
var limiter = try sdk.ratelimit.Limiter.forService(gpa, io, env, "jira");
limiter.reason = @tagName(reason);
const got = limiter.acquireVia(sdk.warm.classOf(reason));   // got.via: .broker | .file
```

A missing, refused or wrong-service socket is a `.file` acquire and a
two-second quiet period, so a machine with no broker pays one failed
connect every two seconds rather than one per request. A brokered
`ok:false` is the same fail-open the file bucket gives — send anyway —
and never a reason to take a second token. `Acquired.via` reaches the
request log as a reason-agnostic `via` field, so "was the broker up" is
a question the log answers for a `poll` exactly as for a `pane_open`.

**Who hosts it.** mnml does, while it runs (`integrations.broker`, on
by default), one per service, elected by a lock file beside the socket
with the same pid-and-heartbeat rules as `warm.Lock` — so a second mnml
window becomes a client of the first rather than a second queue. Its
REQUESTS header shows the result: `broker — jira on · queue 3 · 42%
budget`. `mnml broker serve --service jira` holds one on a machine
with no mnml. **Absent is a supported state**, not a degraded one.

**The wire** is one line of JSON each way, deliberately trivial to
speak from Python's stdlib — whitespace after the colons and all:

```
→ {"v":1,"op":"acquire","service":"bitbucket","class":"interactive","client":"mnml-jira:1234","reason":"pane_open","timeout_ms":5000}
← {"ok":true,"wait_ms":0,"remaining":12.4}
← {"ok":false,"wait_ms":5000,"why":"timeout"}
```

`why` is one of `timeout` (the caller's own budget ran out),
`closed` (the broker is going down, or its bucket failed open),
`bad_request` or `wrong_service` — the last two meaning "not your
broker", which sends the caller to the file bucket. `{"v":1,
"op":"status","service":"…"}` answers with the budget, the queue depth
by class, and what the broker has served. One request, one reply, then
the connection closes.

Where the socket is, in the order the state file resolves:
`<SERVICE>_BROKER_SOCKET`, else `<service>-broker.sock` beside the
state file, else — when that DERIVED path is longer than
`broker.max_path_len` (100 bytes, the same number on every platform so
both ends pick the same branch) — `/tmp/mnml-broker-<service>-<hash>.sock`
(`%TEMP%\mnml-broker-<service>-<hash>.sock` on Windows),
where `<hash>` is the first six bytes of the SHA-256 of the long path in
hex, so both ends derive the same name and two buckets in two
directories never share a broker (`broker.fallbackPath`).
`MNML_BROKER=0` turns the whole thing off for a child.

**The limit, and what happens at it.** A `sockaddr_un`'s `sun_path`
holds 104 bytes on macOS and 108 on Linux, NUL included — so the
longest usable path is `broker.os_max_path_len`, one fewer. That is the
hard ceiling: nothing past it can be bound *or* connected to, by
anybody, on that machine. (`Io.net.UnixAddress.max_len` says 108
everywhere it is not Windows, which on macOS is four bytes past the end
of the struct, and `listen` asserts rather than erroring — so the SDK's
own number is what decides, not the runtime's.)

**The `/tmp` fallback is the derived path's only.** An explicit
`<SERVICE>_BROKER_SOCKET` is used exactly as it was set: a broker
listening somewhere other than the place you named is worse than no
broker, because everything that reads the same variable would go on
looking at the path you gave. So an override past the limit is
*refused*, by length, with the same sentence in all four places that
can hit it:

```
bitbucket: socket path is 131 bytes; the OS allows 103 — set BITBUCKET_BROKER_SOCKET shorter or unset it for the default
```

`mnml broker serve` prints it and exits 1 before it takes a lock or
touches a bucket; mnml's own election prints it as a warning toast and
a `:messages` line, once per service, and leaves every client on the
file bucket exactly as an absent broker does; `mnml broker status`
prints it instead of the indistinguishable `no broker at <path>`; and
the Python client raises `BrokerPathTooLong` (which `try_broker` /
`broker_status` catch, warn about once on stderr, and fall through on —
a misconfigured broker must still not be a dependency).

Every other bind failure names its errno rather than flattening to one
`BindFailed`, because the fix differs: `address in use` — with `a stale
socket from pid N?` appended when the election lock still named one —
`permission denied`, `no such directory`.

**From a shell**, so a capture tool queues behind the panes rather than
taking a token out from under one:

```sh
mnml broker acquire --service bitbucket --class batch --reason capture && curl …
mnml broker status
```

Exit 0 is a token; exit 1 is none inside the timeout, and the caller
decides whether to send anyway.

**From Python**, `sdk/clients/ratelimit_broker.py` — stdlib only, one
connect, one line each way, and a clean `False` on anything at all so
the caller falls through to its existing file-bucket loop. Its
docstring shows the two-line change `bb_ratelimit.py` would make.
Unix sockets are the whole transport (`broker.supported`, which is
`Io.net.has_unix_sockets`: true on Windows 10 1803 and later too, where
the long-path fallback above lands in `%TEMP%` rather than `/tmp`);
where they are missing every client is on the file bucket, which is a
path rather than a hole.

## Who is spending the budget — the draws file

The rate bucket (`mnml_sdk.ratelimit`) says how much of an API's
per-minute allowance is left; it never said who took it. On a machine
where a dozen things draw on the same `<service>-ratelimit.json` —
mnml's panes, the statusline poller, the Rust crate `mnml-ratelimit`,
the Python `bb_ratelimit.py` — that is the half of the answer that
does not help.

So every `acquire` also appends one line to `<service>-draws.jsonl`,
**beside the state file**, in the same interop directory every one of
those shares:

```json
{"ts":1789526218.411,"pid":48123,"program":"mnml-jira","service":"jira","reason":"pane_open","wait_ms":3030,"tokens_after":0.24}
```

**This line is a contract.** Seven keys, exactly these spellings:

| key | type | meaning |
| --- | --- | --- |
| `ts` | number | wall clock, seconds since the epoch, milliseconds kept |
| `pid` | integer | the process that drew; `0` where there is no pid to name |
| `program` | string | `argv[0]`'s basename — `mnml-jira`, `bb.py` |
| `service` | string | which bucket — `jira`, `bitbucket` |
| `reason` | string | why, in the requesting side's own words |
| `wait_ms` | integer | how long `acquire` held the request before it went out |
| `tokens_after` | number | tokens left in the shared bucket afterwards |
| `token_id` | string, optional | present only when the draw came out of a per-token bucket: that bucket's 12-hex `<id>` ("A bucket per token"); `tokens_after` is then that bucket's |

```json
{"ts":1789526218.411,"pid":48123,"program":"mnml-bitbucket","service":"bitbucket","reason":"pane_open","wait_ms":0,"tokens_after":39.0,"token_id":"ba7816bf8f01"}
```

The file stays one per service whichever bucket a draw came out of; a
reader that does not know `token_id` ignores it.

Anything else on the machine that spends from one of these buckets can
append the same line and be counted; nothing has to be taught to read
it. The file rotates at 4 MB and keeps one older generation
(`<service>-draws.jsonl.1`).

The state file itself is **never** given a field for this. The Rust and
Python writers rewrite its six keys wholesale, and a seventh there
would be dropped by one of them or choke the other.

```zig
var limiter = try sdk.ratelimit.Limiter.forService(gpa, io, env, "jira");
try limiter.identify("jira", "mnml-jira", pid);
limiter.reason = "pane_open";   // set per request
```

A limiter nobody identified writes no draw lines: a line that cannot
say who drew is worth nothing. `ratelimit.recentDraws` reads the file
back for a window, which is what a statusline chip's hover uses to say
`spent by bb.py 30 of 83 draws in 10m`.

## Results outlive the job — take the arena, or dupe

A pane's slow work runs off the loop and comes back as a **result that
carries its own arena**: the HTTP body, the parsed JSON, and every
string the payload points into all live on it. The consumer on the loop
then has exactly two options, and no third:

- **take the arena** into a field that lives as long as the thing you
  are keeping, or
- **dupe** what you keep onto an allocator the holder owns.

Letting the arena go while keeping a slice out of the payload is the
one mistake this shape invites, and it has now shipped four times. It
is not loud: an arena hands its pages back through `rawFree`, which
poisons nothing, so the rows go on reading correctly until something
else claims the page — minutes later, on someone's screen.

The idiom is a `keep_arena` flag and a field beside the value:

```zig
/// The last statusline values, for the chip.
values: ?fetch.ValuesResult = null,
/// The arena those values live on — the result's own, taken off it
/// rather than let go at the end of `commit`. This figure is not a
/// number: it carries the tooltip's breakdown and the hover's rows,
/// and the pane republishes all of it every time it opens one of
/// those rows. It has to still be there minutes after it landed.
values_arena: ?std.heap.ArenaAllocator = null,

pub fn commit(app: *App, res: *fetch.Result) !void {
    var keep_arena = false;
    defer if (!keep_arena) res.arena.deinit();
    switch (res.payload) {
        .values => |v| {
            if (app.values_arena) |*old| old.deinit();
            app.values_arena = res.arena;   // the strings come with it
            keep_arena = true;
            app.values = v;
        },
        .whoami => |w| {
            // The other answer: a copy the app owns.
            app.gpa.free(app.me_account_id);
            app.me_account_id = try app.gpa.dupe(u8, w.account_id);
        },
    }
}
```

`app.deinit` frees `values_arena` like any other owned thing. Only
scalars — counts, flags, timestamps — may be stored out of a payload
without one of the two.

Two rules that fall out of the same reasoning:

- **An `ArenaAllocator`'s `allocator()` binds to the address it was
  taken from.** Put the arena in the field FIRST, then take the handle
  off the field. A handle taken from a stack local and copied into
  state points at a frame that has returned — harmless for plain
  slices, not for a `std.json.Value`, whose arrays are
  `std.array_list.Managed` and carry the handle inside them.
- **A `FixedBufferAllocator` over a local buffer is an arena too.**
  `std.json`'s default `.alloc_if_needed` puts an escaped string on it
  and hands you the slice; return that and you have returned a piece of
  your own frame. Copy into a caller-supplied buffer instead.

`zig build arena-audit` enforces the first rule mechanically over
`integrations/` and `sdk/`: a prong of a result switch that stores the
payload without taking the arena or duping is a finding, and a unit
test walks both roots under `zig build unit`.

## Opening a URL — `MNML_OPEN_URL`

An integration that opens a page in the browser (a pull request, a
pipeline run) asks `sdk.platform` for the opener — `openUrlArgv` — and,
before it starts one, `sdk.platform.divertOpenUrl(io, env.get(sdk.platform.open_url_env), url)`.
The variable is one contract for the host and every integration:

| `MNML_OPEN_URL` | what happens |
| --- | --- |
| unset, or empty | the URL opens in the browser, as normal |
| `none` | nothing: no process, no file |
| anything else | a file path: one line `<epoch seconds>\t<url>\n` is appended to it (created if missing), and no process starts |

Only `.spawn` lets the opener run; `.log_failed` is a reason to say so,
never a reason to open the browser after all. `sdk.platform.openUrlRoute`
is the decision alone, for a caller that wants to branch on it. The
`.test` runner sets the variable for every file (`opened-urls.log` in
the file's workspace, so a script can `expect file opened-urls.log
contains https://…`), `--headless` defaults it to `none`, and the
real-window harness points it at a file beside its run — no automated
run ever puts a page in front of a person.

## Testing an integration

The socket is plain: a test can `UnixAddress.listen`, spawn the binary
with `MNML_MOUNT_SOCKET`, send a `hello` with `sdk.wire.send`, and read
frames back with `sdk.wire.receive(sdk.SiblingMessage, …)`. mnml's own
test does exactly this against the sample
(`src/app/mount_pane.zig`, "a mounted sample integration paints…").

### Pointing an integration at a fake — `sdk.base_url`

A test points an integration at its fake server with
`$<SERVICE>_BASE_URL`: a URL, or `@<path>` naming the file the fake
writes once it listens (`--port 0 --url-file <path>`), so no script
ever picks a port. Read it with
`sdk.base_url.fromEnv(gpa, io, env, "JIRA_BASE_URL", .{})`: `.unset`
leaves the config's URL standing, `.url` is the override, and
`.unreadable` — an `@<path>` whose file is still missing or empty
after the wait (5 s) — is a sentence for the setup screen. On
`.unreadable` the integration builds **no client and asks no server**:
the fake did not start, and neither the config's URL nor the
service's production API is a fallback for it. Both first-party
integrations read their overrides here (Jira reads
`$JIRA_BASE_URL` and, for a ticket's linked pull requests,
`$BITBUCKET_BASE_URL`).

### Proving a result outlives its job — `sdk.testing.Scribble`

A test for the rule above passes whatever the code does unless the
allocator underneath poisons what it frees. `Allocator.free`'s own
poison is `undefined`, which a release build may skip; an arena gives
its pages back through `rawFree`, which never poisons. `Scribble`
writes `0xAA` over everything it frees, in every build mode, and hands
the call on to a child — so `std.testing.allocator` underneath still
reports leaks as it always did.

Put it under the rig's **fetch** side — the client, the worker, and
every arena a job or a result makes:

```zig
var scribble: sdk.testing.Scribble = .{ .child = std.testing.allocator };
const r = try Rig.initOn(cfg, .{}, scribble.allocator());
defer r.deinit();
// The listing is over. Anything the chip kept a slice of is 0xAA now.
try t.expectEqualStrings("Fix the login redirect", r.app.values.?.open_items[0].text);
```

Both shipped integrations expose that door — bitbucket's
`Rig.initOn(config, opts, gpa)` and jira's
`Harness.startOn(config, family, gpa)` — and a third should, for the
same reason.

## Keeping an external integration current

An integration that lives outside this repository — a private one
installed from a `local_folder` marketplace source, or anyone's —
depends on the SDK by path and draws through its components. A change
to the SDK's look reaches it only when it is BUILT again. Four pieces
keep that from going quiet:

* **The stamp.** `--install` (`sdk.manifest.write` / `render`) records
  the SDK the binary was compiled against as the manifest's `.sdk`
  (`sdk.version`, which mnml's release test holds to
  `sdk/mnml-sdk/build.zig.zon`). You never write it; a launcher (no
  binary) is never stamped.
* **The `rebuild` chip and commands.** mnml reads the stamp. An
  Installed row built on an SDK behind the one mnml carries — or with no
  stamp at all, i.e. installed before the stamp existed — wears a
  `rebuild` chip at its right edge; its hover says "built against SDK
  0.1.0, current 0.2.0". `integrations.rebuild_stale` rebuilds every such
  row that came from a folder on this machine (the install leaves
  `<data root>/integrations/<id>/built-from` naming it) with the same
  in-place `zig build` the install ran, then `--install` again, a toast
  per row, naming the SDK the fresh manifest is stamped with — a build
  still behind (its `build.zig.zon` pins an older `mnml-sdk`) says so. A
  stale row with no folder behind it, or whose folder has been deleted,
  is named, not built, and its chip reads `old SDK` instead of `rebuild`.
  The row menu's *Rebuild* (`integrations.rebuild_focused`) does one.
* **The conformance call.** `try sdk.testing.conformance(Probe);` in the
  integration's own tests (above) holds its pane to every design-language
  rule the SDK knows, including the ones added after it was written.
* **The extra-roots check.** `tools/check-integration-roots.sh` builds
  and tests every integration under the folders named in
  `MNML_EXTRA_INTEGRATION_ROOTS` (a `:`-separated list — `;` on Windows — of
  `integrations/`-shaped folders — each subfolder with a `build.zig` and
  a `manifest.zon`), one line each, `ok|FAIL <root>/<id> (<n> tests)`,
  exiting non-zero on any failure; unset means no extra roots and exit 0.
  Put it in a verification chain so an SDK change that breaks a private
  integration fails there, before the author finds out at their next
  build.

**The rule: a component a private pane needs and the SDK lacks is added
to the SDK first.** A pane that draws its own meter or its own table
header today misses every polish pass the family gets tomorrow, and two
panes drawing one thing two ways is exactly the drift the toolkit exists
to stop. Add it to `sdk.pane` (with its `--ascii` twin, a test and, when
the family asserts it, an `expect` helper), move the in-repo panes that
draw the same thing onto it, and only then use it from the private pane.
`sdk.pane.meter` and `sdk.pane.columns.header` came in exactly that way.

## Layout of the package

```
sdk/mnml-sdk/src/
  root.zig       the module: Mount, Frame, Style, Ipc, Manifest, wire
  wire.zig       the protocol — types, framing, encode/decode, tests
  client.zig     Mount: connect, next, send, the small senders
  frame.zig      Frame: the cell grid + dirty-row tracking
  ipc.zig        Ipc: the tier-2 lines
  manifest.zig   Manifest + write/remove + the data-root rule
  broker.zig     the local broker: one queue per service, four classes
  ratelimit.zig  one cross-process token bucket per service
  request_log.zig  one JSON line per request, with its reason
  budget.zig     the API budget a pane shows and obeys: headers, a
                 429's pause, hit ratio, the daily tally, dry run, the
                 shared bucket file
  feed.zig       when to ask: the adaptive poll schedule, the JSONL
                 event file, and the Watcher that picks between them
  store.zig      small keyed records kept between runs (Jira's sync marks)
  http_cache.zig the shared HTTP response cache: one file per GET, the
                 public contract, fresh / revalidate / miss
  testdata/http_cache_vectors.json  the contract's shared cases, verbatim
  zon_edit.zig   saving a hand-written ZON file in place, comments kept —
                 the splice the host's settings write through too
  warm.zig       the warmer: pacing with priority, one warmer per
                 service, delta windows, intervals, the budget floor
  base_url.zig   the `$<SERVICE>_BASE_URL` override — a URL or `@<file>`;
                 a file that never arrives is an error, never a fallback
  platform.zig   the platform's URL opener — `open`, `xdg-open`, or
                 `rundll32 url.dll,FileProtocolHandler` (never `cmd`) —
                 and `MNML_OPEN_URL`, which diverts it to a file or nowhere
  testing.zig    test allocators a suite borrows — Scribble, which
                 poisons what it frees so a slice into a let-go arena
                 reads as 0xAA rather than as luck
  pane.zig       the pane toolkit's barrel (Theme, Painter, HitMap)
  pane/theme.zig   the host theme's roles, the brand colour, state colours
  pane/chrome.zig  Painter: header, tabs, pill, gutter, rows, detail, hints
  pane/hit.zig     Rect + Map(Target), generic over your own union
  pane/text.zig    widths and fitting, counted the way Frame paints
  pane/action.zig  a row's action button and what a press leaves behind
  pane/build.zig   the build lines under a pull-request row
  pane/merge.zig   whether a pull request may merge, and the button's state
  pane/figure.zig  what a statusline segment is allowed to say
  pane/work.zig    a pane's slow work off its event loop
  pane/expect.zig  the assertions your own tests make about the chrome
  pane/consistency_test.zig  the toolkit painted from both panes' vocabularies, cell for cell
  pane/columns.zig how a table gives way when narrow: shrink to floors,
                   then drop whole by rank; the key column never clips;
                   when wide, a cut column grows to its measured need
  pane/help.zig    hover help: the toolkit chrome's one entry each, `key`
  pane/keysheet.zig  the `?` key sheet's keys and the family's chord spelling
sdk/clients/ratelimit_broker.py   the broker's Python client, stdlib only
sdk/examples/hello/   the small list the host's mount test spawns (`zig build sdk-example`)
integrations/sample/  the official sample (`zig build sample-integration`, or its own build.zig)
```
