# mnml-sdk — write an integration in Zig

An integration is a program mnml opens in a pane. It draws into a cell
grid, gets keys and clicks, and can ask mnml to run commands, toast, or
put things on the statusline. `sdk/mnml-sdk` is the package; the wire it
speaks is `docs/BRIDGE.md`. `integrations/sample` is the official
sample — a counter pane on the SDK, ~200 lines, what mnml's own tests
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
   `context_menu` row, and a `settings` row that reaches the binary as
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
`zig-out/bin/mnml-sample`, `mnml-zig test` exports it as
`$MNML_SAMPLE_INTEGRATION`, and a manifest whose `binary` is `$VAR`
resolves through the environment — see
`tests/e2e/integrations_sample_dev_install.test` and
`integrations_sample_marketplace_local.test` (the private-folder path).

A private or external integration is the same folder outside this
repo: point `integrations.dev_roots` at its parent to develop it, or
list its parent as a `local_folder` marketplace source to install it
from the Marketplace tab (`docs/CONFIG.md`).

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
| What a fetch is doing while it is out — `⠋ fetching… 2/13 repos`, `queued behind 3 requests`, `waiting for the API budget`, `fetch failed: …` — and the refresh chip turning the host's spinner ring meanwhile | `chrome.Fetch` / `chrome.fetchText`, `Painter.fetchSub`, `Painter.refreshOrBusyChipText`, `chrome.spinnerFrame` (the host's `list_panel` ring, pinned equal); the request's live phase comes off `ratelimit.Notice.live()` |
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

The gutter runs the WHOLE height of the pane, whatever shape the body
is. A pane with a column-shaped body (a board of boxed columns) starts
its columns one cell in rather than painting over it: the stripe is
the only column that says which application this is, and a pane that
loses it halfway down reads as two panes stacked. The bad-scope error
screen wears it too — a pane that cannot show anything is still this
pane.
| One figure on a statusline segment, and a bracketed subset only when the pane has one | `pane.figure` |

Keys and chrome that are not the toolkit's but ARE the family's: `r`
refreshes and `R` refreshes past every cache; `?` opens the key sheet;
the tab wears the manifest's chip glyph.

#### What a statusline segment may say

**One named figure per segment, plus a bracketed subset only when the
pane genuinely has one.**

```
󰂨 12(11)    twelve of my pull requests open, eleven of them unapproved
󰌃 43        forty-three items assigned to me — and no second number
```

The bracket is a SUBSET of the figure beside it, never a second count
about something else. A pane with two things to say publishes two
segments, each named for its own figure, because a reader looking at
`󰂨 12 3` has no way to learn which number is which.

A pane with no subset says one figure and stops. That is not the
poorer half of the standard — `43(2)` invented so the tracker's chip
matches the forge's shape is a number nobody can believe, which is
worse than a chip that says less.

`sdk.pane.figure` is the helper, and it makes the rule true by
construction: one `n`, one optional `subset`.

```zig
var buf: [32]u8 = undefined;
const text = sdk.pane.figure.text(&buf, .{ .glyph = glyph, .n = open_mine, .subset = unapproved_mine });
try ipc.statuslineSetSegment(.{ .id = "…", .text = text, .tooltip = breakdown });
```

`sdk.pane.expect.statuslineFigure` is the assertion both integration
suites call on their own published text; `sdk.pane.figure.check`
refuses a second bare figure, a tail after the figure, empty brackets,
and a "subset" larger than the figure it claims to be a subset of.

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
```

Both official integrations call these, which is the point: one
expectation, checked from two packages, rather than two suites each
checking whatever they happened to be written against. The 2026-09-19
audit (`docs/research/pane-drift-audit-2026-09-19.md`) found seven
elements that had come apart precisely where no shared assertion
existed.

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
| `chip` | a button on the palette bar: `glyph` (Nerd Font) — or `glyph_codepoint` (`F1D00`, painted verbatim when `glyph` is empty, for a mark in mnml's own font block), `fallback` (plain, always), `color` (a theme name — `red orange yellow green blue cyan teal purple pink comment fg` — or `#rrggbb`), `tooltip`, `enabled`, `in_palette_bar`. Right-click → enable / disable / show or hide on the bar / add to the activity bar / manifest / remove |
| `commands[]` | each is a palette command with `keys`; it opens the binary (with `args`) unless `run` (or `ex`, the same field) names an ex line to run instead — `term mnml-hello --pty`, `:term code --goto {{current_file_abs}}:{{cursor_line}}:{{cursor_col}}`; mnml expands `{{workspace}}` `{{workspace_name}}` `{{current_file}}` `{{current_file_abs}}` `{{current_file_dir}}` `{{cursor_line}}` `{{cursor_col}}` `{{selection}}` when it fires and leaves an unknown token as written (`launchers/README.md`). The first one is what the chip, Enter and a pinned activity-bar icon do |
| `settings[]` | a row in mnml's settings overlay under *Integrations* (discrete choices); the chosen value reaches the binary as `MNML_SETTING_<KEY>` |
| `statusline[]` | a segment on the statusline while the integration is enabled and its binary resolves — `text`, `side`, `color`, `priority`, and `click_command` (a command id) — keyed `<id>.<segment id>`; it goes with the manifest. The live run replaces it over Tier 2, where it may also carry `items` (below) |
| `requires[]` | environment variables the integration needs (shown in the detail pane) |
| `context_menu[]`, `menu_bar[]`, `auth[]`, `values_sources[]` | parsed and shown in the detail pane; wiring into mnml's menus / auth store is a later slice |

`binary` may be `$NAME` (or `$NAME/rest`): the variable's value is the
path. `<data root>/bin/<binary>` is tried before PATH — that is where an
install from the Dev tab or the marketplace links the built binary.

`sdk.manifest.validate(m, &why)` is the rule both readers apply — the
id is a file name; a manifest without a `binary` has a command, and
every such command a `run` line — so `--install` and mnml's scan refuse
the same files. mnml's own launchers live in the repo's `launchers/`.

`sdk.manifest.write` picks the data root the way mnml does
(`MNML_DATA_ROOT`, `XDG_CONFIG_HOME/mnml`, `HOME/.config/mnml`) and
returns the path it wrote. `sdk.manifest.remove(gpa, io, env, id)` is
uninstall. mnml re-scans on `integrations.refresh` and at startup; an
`id` must be a file name (`[A-Za-z0-9_.-]`).

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
`Private` badge.

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
  input / focus / session_state / goodbye: mnml can start your binary
  for a command, but it cannot send one into a mount that is already
  running. A command that has to act on a *live* pane needs a key, or a
  second headless invocation that writes to the Tier-2 channel.
  `session_state` is the one thing the host volunteers, and only about
  a session the pane asked it to watch.
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

### A 429 — `ratelimit.Retry`

Read `Retry-After` with `ratelimit.parseRetryAfter`, park the shared
bucket with `Limiter.penalize(retry_after)` (the service's default
cooldown when the server sent none), and ask `Retry.next(attempt,
retry_after)` how long to wait before the next try — null means give
up now: out of attempts, or a park longer than `max_backoff_secs`,
which is not slept through inside a request. Both first-party
integrations answer a 429 through it.

## The warmer — pacing, one warmer per service, windows

`mnml_sdk.warm` is the part `ratelimit` and `store` do not own: **when**
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
| `warm` | speculative: `warm`, `delta`, `prefetch` |
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
budget`. `mnml-zig broker serve --service jira` holds one on a machine
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
both ends pick the same branch) — `/tmp/mnml-broker-<service>-<hash>.sock`,
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

`mnml-zig broker serve` prints it and exits 1 before it takes a lock or
touches a bucket; mnml's own election prints it as a warning toast and
a `:messages` line, once per service, and leaves every client on the
file bucket exactly as an absent broker does; `mnml-zig broker status`
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
mnml-zig broker acquire --service bitbucket --class batch --reason capture && curl …
mnml-zig broker status
```

Exit 0 is a token; exit 1 is none inside the timeout, and the caller
decides whether to send anyway.

**From Python**, `sdk/clients/ratelimit_broker.py` — stdlib only, one
connect, one line each way, and a clean `False` on anything at all so
the caller falls through to its existing file-bucket loop. Its
docstring shows the two-line change `bb_ratelimit.py` would make.
Unix sockets are the whole transport, so Windows has no broker and
every client is on the file bucket there, which is a path rather than
a hole.

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
  store.zig      bodies kept between runs, keyed by the server's stamp
  zon_edit.zig   saving a hand-written ZON file in place, comments kept —
                 the splice the host's settings write through too
  warm.zig       the warmer: pacing with priority, one warmer per
                 service, delta windows, intervals, the budget floor
  base_url.zig   the `$<SERVICE>_BASE_URL` override — a URL or `@<file>`;
                 a file that never arrives is an error, never a fallback
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
                   then drop whole by rank; the key column never clips
sdk/clients/ratelimit_broker.py   the broker's twenty-line Python client
sdk/examples/hello/   the small list the host's mount test spawns (`zig build sdk-example`)
integrations/sample/  the official sample (`zig build sample-integration`, or its own build.zig)
```
