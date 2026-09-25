# Looking at the real screen — the agent recipe

The headless harness (`--headless`, the `.test` corpus, `tools/zig-spec.sh`)
shows what mnml **computed**: the cell grid, the attributes, `status.json`.
It cannot show what a person **sees**: a glyph that fell back to a box or a
`?`, an icon drawn at the wrong size, a colour that reads as faded, a blank
row the terminal's own reflow left above a prompt. Every UI bug the user
found in the week before this recipe existed lived in that gap.

So a hunter or fixer agent works in two gears on the **same workspace**:

1. **Headless, for speed.** Drive the workspace through the file channel,
   read `screen.txt` / `status.json`, iterate on the fix.
2. **The real window, to look.** Launch mnml-zig in its own ghostty window
   on that workspace, send the same channel lines, take a PNG, `Read` it.

```
tools/look.sh launch <ws> [--exe zig-out/bin/mnml-zig] [--cols 120 --rows 40]
tools/look.sh run view.activity_git          # a command id
tools/look.sh key ctrl+shift+p               # a key spec, as the channel reads it
tools/look.sh type "git"                     # literal text (\n is Enter)
tools/look.sh click 32 1 [right]             # cells, 0-based
tools/look.sh hover 36 3
tools/look.sh send '{"cmd":"scroll","col":40,"row":10,"dy":-3}'   # any channel line
tools/look.sh shot palette                   # prints .verify/look/<ws>/shots/palette.png
tools/look.sh pixel 0 38 [FX FY]             # prints #rrggbb; FX/FY 0..1 within the cell
tools/look.sh screen                         # the live screen.txt
tools/look.sh status                         # the live status.json
tools/look.sh quit
```

`look.sh` is a thin front on `tools/tour/` (stdlib Python) and
`zig-out/bin/mnml-drive` (`zig build -Ddrive`, macOS + ghostty only; see
`docs/DRIVE.md`). Every verb after `launch` acts on the window `launch`
recorded (`.verify/look/current`).

## The rules

* **Never `mnml-drive focus`, and never `mnml-drive key` / `type`.** Those
  need the harness to be the active application, which takes the keyboard
  from the person at the machine until they click back. Keys go through
  the channel instead: `look.sh launch` starts the app with
  `ipc.allow_input` on (`mnml-drive launch --allow-input`), and every
  `key` / `type` / `click` is a JSONL line appended to
  `<ws>/.mnml/ipc-zig/command`, acknowledged in `events.jsonl`. An
  `unsupported` ack means the switch is off — relaunch, do not reach for
  `focus`.
* **The pointer is not an input.** The window's own mouse reporting is
  off (`mnml-drive launch --no-mouse`), so the person's pointer passing
  over it cannot move the hover help into your shot; `click` / `hover`
  go through the channel like everything else.
* **One window per agent. Quit when done.** `look.sh launch` refuses while
  its window is up. A window left open is a window on somebody's desktop.
* **Own data root, under the worktree.** Everything the window writes —
  its data root, its private `HOME`, its ghostty config, its shots — is
  under `<worktree>/.verify/look/<ws>/`. Nothing lands in `~/.config/mnml`,
  `~/.claude` or the real `HOME`: the app is `env -i`-launched with a
  private `HOME` (ghostty starts commands through `login(1)`, which resets
  `HOME` to the real one — the wrapper puts it back), a clean `PATH`, and a
  proxy that refuses, so nothing reaches the network.
* **The window is the agent's; the user's mnml is never touched.** Not
  driven, not stopped, not restarted, not screenshot. `look.sh` and
  `mnml-drive` only ever act on the pid and window id `launch` recorded;
  never `pkill`, never "the frontmost ghostty".
* **One workspace, one live mnml.** The channel directory is the
  workspace's (`<ws>/.mnml/ipc-zig`): quit the headless instance before
  launching the window on the same workspace, and the other way round.
* **Launching borrows the foreground for a moment.** ghostty activates as
  it opens; `mnml-drive launch` hands the keyboard straight back to
  whichever app had it. Launch once and drive many steps, not one launch
  per step.

## Reading what you see

`look.sh shot NAME` prints a PNG path; `Read` it. Beside it is
`NAME.txt`, the `screen.txt` of the same frame, so a finding can quote
the cells. What to look for is in `tools/tour-review.md`; the short form:
faded rails or text, `?` / tofu / boxes where an icon belongs, glyphs at
the wrong size, blank rows above prompts, chrome drawn over chrome,
truncated labels, the focus cue on the wrong pane, and anything that
differs from the Rust screens in `docs/ui-spec/`.

A colour question is `look.sh pixel`, not your eyes. The pixel is the
display's, not the theme's (`docs/DRIVE.md`, *A pixel is not a theme
hex*): compare two cells of the same frame, or compare against a value
you measured on this machine, never against a hex from the theme file
with a tight tolerance. A half-block glyph — the pane rail's `▌` — fills
only the left half of its cell; sample it at `FX 0.25`.

## Where this sits

| | what it drives | when |
|---|---|---|
| `mnml-zig test` (the corpus) | the App, headless | every change |
| `tools/look.sh` | one real window, by hand | while fixing anything visual |
| `tools/tour.sh` | the curated tour, 29 states, baselines + pixel asserts | after every green chain |
| `tools/tour.sh sweep` | every `.test` through the real window | overnight |

`docs/TESTING-hermetic.md` → *The real-screen layer* says when each runs.
