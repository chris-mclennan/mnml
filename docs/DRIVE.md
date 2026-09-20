# Driving the real terminal — `mnml-drive`

`mnml-drive` opens its own ghostty window, runs mnml in it, and drives
that window the way a person would: real key events, real clicks, real
pixels read back off the screen.

It is a **development tool**. It is not in `run.sh install`, not in
`scripts/package.sh`, not in `release`, and it is not even part of the
build graph unless you ask for it:

```
zig build -Ddrive          # builds zig-out/bin/mnml-drive
zig build drive            # the same, on its own
```

`-Ddrive` on anything but macOS fails the build on purpose. It is macOS
+ ghostty only and always will be — one terminal, deliberately, so the
harness can know exactly what it is looking at.

## Why it exists

mnml already has two ways to be watched, and both of them watch the same
thing: the cell grid mnml *computed*.

| | what it shows | what it cannot show |
|---|---|---|
| `--headless` | the virtual screen, dumped to `screen.txt` | anything a terminal does with it |
| `ipc.write_screen` in the real loop | the same dump, live | the same |
| **`mnml-drive`** | **the window's pixels** | — |

A glyph that fell back to a box, a Nerd Font icon that is not in the
font, a theme colour after ghostty blended it, the cursor shape the
terminal actually drew, a row that the terminal wrapped — `screen.txt`
says everything is fine for all of them, because as far as mnml is
concerned everything *is* fine. The difference between the two is the
whole point of this tool, and the reason a finding from it is worth
more than a finding from the harness that agrees with the code.

## Safety — read this part

The person running this has their own ghostty windows open, with their
own work in them. Every rule below exists so the harness cannot touch
one.

* `launch` starts **its own** ghostty process and records the child pid.
* Every other verb re-reads the window list and **refuses** unless the
  recorded window id is still on screen *and* still owned by that pid.
  Not "a ghostty window". Not "the frontmost window". That one. Window
  ids get recycled, so both halves are checked every time.
* Events are posted with `CGEventPostToPid` — **to a process**, never to
  the screen. The usual `CGEventPost(.cghidEventTap, …)` that every
  automation script on the internet uses (`scripts/macclick.swift` in
  the Rust repo included) delivers to whatever is frontmost, which on a
  developer's machine is their editor with unsaved work in it.
* Nothing is ever raised. The one Accessibility call in the tool moves
  **our own** window onto the main display, and it takes the pid rather
  than a window id so it cannot be aimed at a stranger's window.
* `quit` presses `ctrl+q` and, only if that does not take, signals the
  recorded pid. Never a search for "a ghostty".
* The pointer is warped to the cell before a click (a terminal decides
  hover from where the cursor *is*) and warped back afterwards.

A verb that cannot satisfy all of that exits **3** and does nothing.

## The two permissions

Both are checked before anything is posted, with a call that does not
prompt — a system dialog appearing in the middle of a corpus run would
be worse than a refusal.

```
mnml-drive doctor
```

| | what it is for | where |
|---|---|---|
| Accessibility | posting keys and clicks; moving our window | System Settings → Privacy & Security → **Accessibility** |
| Screen Recording | `shot`, `pixel`, and reading window *titles* | System Settings → Privacy & Security → **Screen & System Audio Recording** |

Grant them to **the program that runs `mnml-drive`** — your terminal
app — not to `mnml-drive` itself. A command-line binary inherits its
parent's grants and cannot hold its own. Add the app with `+`, toggle it
**on**, and **restart it**: a grant does not reach a process that was
already running.

If either is missing, stop and grant it. There is no workaround, and
anything that looks like one is posting events somewhere it should not.

## Using it

```
mnml-drive launch --workspace DIR --data-root DIR [--size small|corpus|full]
                  [--cols N --rows M] [--exe PATH] [--font-size PT]
mnml-drive key ctrl+p            --data-root DIR
mnml-drive key "space f f"       --data-root DIR
mnml-drive type "hello"          --data-root DIR
mnml-drive click 10 3            --data-root DIR
mnml-drive rightclick|doubleclick|hover X Y
mnml-drive drag FX FY TX TY
mnml-drive scroll X Y up|down [--notches N]
mnml-drive shot out.png
mnml-drive pixel X Y [--expect '#61afef'] [--tolerance 8]
mnml-drive screen | status | rects
mnml-drive wait-frame [--timeout MS]
mnml-drive info
mnml-drive quit
```

`--data-root` can be `$MNML_DRIVE_DATA_ROOT` instead. Coordinates are
**cells**, not pixels — the same coordinates a `.test` script's `click`
step uses, so a flow can be written once and run either way.

### What `launch` writes

Into the data root:

* `config.zon` — mnml's own, with `ipc.write_screen = true` (or there is
  nothing to read the app back from) and `ui.first_launch_complete =
  true` (or the setup wizard opens over the whole screen; the `.test`
  runner never meets it because it does not run the startup hook, and
  the very first harness window anyone saw was that wizard).
  Written to **both** `<root>` and `<root>-dev`, because the harness
  launches `--profile dev` and the dev profile is the stable answer with
  `-dev` on the end (`src/config/data_root.zig`).

  It also carries **two keys copied from your own `~/.config/mnml/config.zon`**
  — `ui.tree_width` and `ui.tab_indicator` — so a hunter is looking at
  the layout you look at rather than the defaults. Those two and nothing
  else. Nothing that names a token, a path, a host or an integration
  goes near the harness: a script runs under this config, and a
  credential in a config a script can read is a credential in a
  screenshot.
* `ghostty.conf` — see below.
* `drive.json` — pid, window id, bounds, grid, paths. Every other verb
  checks itself against this.

### The harness renders with *your* ghostty font setup

`ghostty.conf` is **your own `~/.config/ghostty/config`, verbatim**, with
a short list of keys the harness has to own appended after it
(decoration off, zero padding, the window size in cells, position,
title, no saved state, no close confirmation).

That is deliberate. mnml's glyphs come from a Nerd-Font primary plus a
`font-codepoint-map` onto `MnmlSymbols`; a harness that invented its own
font setup would photograph a screen you have never seen, and every
glyph finding out of it would be about the harness. **What the hunter
sees is what you see.**

Your `font-size` is kept too. The only time the harness overrides it is
when the grid you asked for will not fit on the display at that size —
then it measures a cell, works out the size that *would* fit, and says
so on stderr. The grid never shrinks; only the type does.

## Sizes

A size-only bug is the commonest kind mnml has, so the harness takes the
same size vocabulary the headless runner does.

```
--size small     80x24     the floor
--size corpus  120x40      where the corpus was written
--size full    measured    the default
```

`full` is measured on the machine: the largest ghostty window **you**
have open — the size you actually work at — and, if you have none, the
main display less the menu bar. Your window is only ever measured; it is
never raised, moved, focused or driven.

Every launch sets the size fresh (`window-save-state = never`, and the
grid written into the config every time), so a window you zoomed by hand
last run never carries over into the next one.

`--cols N --rows M` beats all of it, which is what a script's own
`# width:` / `# height:` header turns into: a file that declares a size
gets that size and no other.

### The ladder

`mnml-zig test --sizes ladder` (and the harness's own sweep) runs a
script at every width where mnml's chrome is known to change shape.
Sweeping only 80 and 200 walks straight past all of these:

| rung | why it is on the list |
|---|---|
| 80x24 | the smallest terminal anyone runs. Dock labels gone, menu bar down to `»`, sidebar at its floor. |
| 100x30 | between the two: the menu bar has begun to overflow, the dock still has room for its counts. |
| 120x40 | the corpus size. Every `.test` content assertion was written here, so a difference at this rung is a regression, not a reflow. |
| 135x42 | the Bitbucket PR row swaps icons for labelled buttons around here, and the settings strip leaves its initials form. |
| 160x48 | wide enough for the full menu word list and the right panel at once — where two-column layouts first fit. |
| 200x60 | the widest the gate sweeps. Nothing should be clipped; anything still clipped is a layout bug, not a space problem. |

The list lives in `src/e2e/runner.zig` (`ladder`), with the same reasons
in its doc comment — that is where the next person adding a rung will
look.

## A notch is not an event

Ghostty multiplies a wheel detent by its own scroll multiplier, so one
`mnml-drive scroll … up` is one detent to you and *several* events to
mnml. The Rust repo hit this too (`ghostty triples discrete scroll`).
Do not tune scroll behaviour from what the harness reports without
checking the terminal's multiplier first.

## The `shot` step

`.test` scripts take a `shot <name>` step. Every driver understands it
and none of them fails on it:

* headless — nothing happens, and the step passes. That is the point: a
  script sprinkled with `shot` has to run unchanged under the driver
  that has no pixels, or nobody will sprinkle it.
* ghostty — a PNG lands under the run directory.

The name is a bare name, never a path.

## Reading the pixel/headless difference

The value of this tool is the **disagreement**. A finding is worth
recording when the two drivers say different things about the same
script:

* headless passes, ghostty fails → the terminal is doing something mnml
  did not account for: a glyph that is not in the font, a width mnml
  measured differently from CoreText, a colour the terminal blended.
* ghostty passes, headless fails → the headless screen is missing
  something the real one has. Rare, and worth a hard look at the
  fixture.
* both fail, differently → usually two bugs.

`expect color X Y fg|bg #RRGGBB` is the place this bites hardest. A
**background** colour samples cleanly: the cell centre is background
almost everywhere. A **foreground** colour does not — the cell centre
may be ink or may be the gap inside a glyph, and antialiasing means even
the ink is not exactly the theme's value. Sample foreground with a
tolerance and treat a near-miss as "the right colour, drawn", not as an
exact match; that approximation is documented here rather than hidden,
because a test that pretends otherwise will flake on a font change.

## `scripts/shot.sh --drive`

`scripts/shot.sh` photographs the mnml the user is running. With
`--drive` it photographs the **harness** window instead, found through
`drive.json` — never the user's.

## What it cannot do

* **It needs the keyboard.** macOS routes synthetic key events to the
  active application; a harness window that is not frontmost gets the
  events and drops them. The harness will not steal focus on its own —
  it refuses and says so — which means a run that presses keys owns the
  machine while it runs. Clicks and pixel reads do not have this
  problem.
* One window. Not tabs, not splits at the terminal level.
* macOS, ghostty. Both on purpose.
