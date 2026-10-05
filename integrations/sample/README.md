# mnml-sample — a pane in mnml's chrome

The sample integration: a live screen on `mnml-sdk` that answers keys,
clicks and the wheel. It is the thing to copy when you start a new
integration, and it is what mnml's own corpus mounts to prove the host
end of the bridge.

```sh
zig build sample-integration     # → zig-out/bin/mnml-sample
./zig-out/bin/mnml-sample --install
./zig-out/bin/mnml-sample --uninstall
./zig-out/bin/mnml-sample --version
```

`--install` writes `manifest.zon` to `<data root>/integrations/sample.zon`;
mnml picks it up at startup or on `integrations.refresh`. Running the
binary with no socket tells you so rather than painting into a pipe.

## A pane in mnml's chrome, in ten lines

`sdk.pane` is the toolkit every official integration paints out of, so
two panes cannot drift into two design languages. It owns the caps
header and its chip ladder, the tab strip, the filter pill, the
app-colour left gutter, the row ground, the `Show more (N)` fold row, a
detail panel with its `×` and scrollbar, and a hint row where every
`key label` is a click target.

```zig
const Target = union(enum) { row: u32, filter, quit };   // your vocabulary
var hits: sdk.pane.HitMap(Target) = .{};

var p: sdk.pane.Painter(Target) = .{
    .f = &frame, .gpa = gpa, .arena = arena, .hits = &hits,
    // The theme the host sent, with your manifest chip colour as the brand.
    .th = sdk.pane.Theme.fromHelloBranded(hello.palette, "teal"),
    .ui = .{ .nerd = hello.capabilities.nerd_font, .ascii = hello.capabilities.ascii },
};
p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = frame.rows - 1 }, cursor_y);
_ = p.capsTitle(1, 0, "SAMPLE", "  (5)");
try p.filterPill(.{ .x = 1, .y = 1, .w = frame.cols - 2, .h = 1 }, query, caret, editing, .filter);
try p.rowGround(.{ .x = 0, .y = y, .w = frame.cols, .h = 1 }, y == cursor_y, .{ .row = i });
try p.hintRow(frame.rows - 1, status, &.{.{ .key = "q", .title = "quit", .target = .quit }});
```

Two rules the toolkit expects and mnml's audits enforce:

* **Never an ANSI index.** `.{ .index = 6 }` paints whatever the
  terminal calls colour 6, which is how a pane ends up teal in a theme
  that has no teal in it. Every colour comes off `sdk.pane.Theme`,
  which reads the host's `hello.palette`.
* **Register the rectangle in the same statement as the paint.** Every
  chrome call above takes its target for that reason; dispatch is then
  one `switch` on `hits.at(col, row)` and there is no second table to
  keep in step.

## The screen

Row 0 is the caps header — the label, then the theme mnml said hello
with, the `mood` setting and the geometry. `counter_row` (2) is the
counter and the event tally; a right-click there resets it. `click_row`
(4) is the row a left click bumps, painted on the toolkit's row ground.
The last row is the hint row: `r reset · h toast · q quit`, each one a
hit that does what its key does.

| key | what it does |
|---|---|
| `↑` `k` `+` `Space` `Enter` | count up |
| `↓` `j` `-` | count down |
| `r` | reset |
| `h` | a toast through the host |
| `q` | bye |

The wheel counts too, and a click anywhere reports its cell in the hint
row's status — handy when you are checking that your own hit rectangles
land where you think they do.

## The design-language suite

`main.zig`'s last test is one line — `try sdk.testing.conformance(Probe);`
— and it is the one to copy. `Probe` mounts the pane on a fixture and
says where its title, gutter, ladder, list and segments are; the SDK
paints it at 120×40 and 80×24, with and without `--ascii`, and holds it
to every rule the family checks (title ink, header ladder, gutter full
height, list scrollbar, statusline figure, the ascii twins, no hit off
the screen). Every integration, in this repo or outside it, should call
it; a rule the SDK adds later then reaches your pane at its next
`zig build test`. The sample has no ladder, no scrolling list and no
live figure, so it leaves those three fields null.

## The manifest

`manifest.zon` beside `main.zig`, `@import`ed by the binary so the
program and the Dev tab read one definition: the chip (a flask, `S` without a Nerd Font, teal), the
`sample.open` command on `ctrl+k s`, a `sample.hello` ex line, a
statusline segment, two menu contributions (`ticket`, `pr`) and one discrete
setting (`mood`), which reaches the binary as `MNML_SETTING_MOOD`.
