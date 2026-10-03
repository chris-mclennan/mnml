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
2. **The real window, to look.** Launch mnml in its own ghostty window
   on that workspace, send the same channel lines, take a PNG, `Read` it.

```
tools/look.sh launch <ws> [--exe zig-out/bin/mnml-zig] [--cols 120 --rows 40] [--sandbox] [--env KEY=VALUE]…
tools/look.sh run view.activity_git          # a command id
tools/look.sh key ctrl+shift+p               # a key spec, as the channel reads it
tools/look.sh type "git"                     # literal text (\n is Enter)
tools/look.sh click 32 1 [right]             # cells, 0-based
tools/look.sh hover 36 3
tools/look.sh send '{"cmd":"scroll","col":40,"row":10,"dy":-3}'   # any channel line: 3 notches DOWN
tools/look.sh shot palette                   # prints .verify/look/<ws>/shots/palette.png
tools/look.sh pixel 0 38 [FX FY]             # prints #rrggbb; FX/FY 0..1 within the cell
tools/look.sh screen                         # the live screen.txt
tools/look.sh status                         # the live status.json
tools/look.sh quit
```

The channel's `scroll` sign is the wheel's: `dy >= 0` scrolls up and a
negative `dy` scrolls down, one notch per unit (`src/ipc/effects.zig`).

`look.sh` is a thin front on `tools/tour/` (stdlib Python) and
`zig-out/bin/mnml-drive` (`zig build -Ddrive`, macOS + ghostty only; see
`docs/DRIVE.md`). `launch` rebuilds a driver older than its sources
first (`mnml-drive version` against `tools/tour/stamp.py`;
`MNML_DRIVE_NO_REBUILD=1` stops instead), and warns — only warns — when
no `--exe` is given and `zig-out/bin/mnml-zig` is older than `src/`. Every verb after `launch` acts on the window `launch`
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

`launch --sandbox` starts the app with `--sandbox` (docs/CONFIG.md,
*Sandbox*): it re-executes into a fresh `mnml-sandbox-*` under the
window's own `TMPDIR` (`<root>/tmp`, inside the worktree), so the
statusline shows the ` sandbox ` chip and the data root starts empty.
The driver's `config.zon` rides along as the explicit `--config` layer,
so the channel still works; the app removes the directory when `quit`
ends it. It is an extra, not a replacement for the private `HOME`: the
wrapper's `env -i`, clean `PATH` and refusing proxy still apply.

`launch --env KEY=VALUE` (repeatable) adds to the app's environment —
a stand-in `claude` ahead of the clean `PATH`, a fake manifest's
`ACME_SITE`. A value may name the window's own variables, so
`--env 'PATH=/abs/stand-ins:$PATH'` prepends a directory (quote it so
your shell leaves `$PATH` alone). It adds, never loosens: `HOME`,
`TMPDIR`, `MNML_DATA_ROOT`, `MNML_IPC_DIR`, `MNML_PROFILE`, the
artifacts and sessions homes and the proxies stay the window's own, and
an `--env` naming one is refused. The pairs are kept in the root's
`look.json`.

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
| `mnml test` (the corpus) | the App, headless | every change |
| `tools/look.sh` | one real window, by hand | while fixing anything visual |
| `tools/tour.sh` | the curated tour, 29 states, baselines + pixel asserts | after every green chain |
| `tools/tour.sh sweep` | every `.test` through the real window | overnight |

`tools/tour.sh` leads with one line — `N ok, M changed, K asserts ok` —
before the per-shot lines, and exits 1 only on a CHANGED shot or a failed
assert; a stale app binary, a missing baseline or a lingering toast is a
note. Two things keep a shot about its state and nothing else:

* **The workspace is always `.verify/tour-ws/ws`**, whatever `--out` says.
  The sidebar header paints the workspace path abbreviated (`/Use…`), so a
  workspace under `--out /private/tmp/…` painted `/pr…` and flagged every
  shot with the tree open. `masks.zon` masks that cell too. One tour at a
  time: a second refuses while the first holds `.verify/tour-ws.lock`.
* **No toast in a shot.** Before each shot the tour waits (up to 6 s) for
  `status.json` `toasts` to reach zero — a toast rides its own four-second
  clock into whatever comes next. The note names the toast it waited out
  (`waited 1796 ms for 1 toast(s) to go (`info panel: pinned — Sidebar`)`),
  or `toast lingered: …` when one outlives the wait.

`docs/TESTING-hermetic.md` → *The real-screen layer* says when each runs.
