---
name: drive-mnml
description: See and control the REAL running mnml (its ghostty window) — screenshot the live pixels and post synthetic mouse events. Use to visually verify a change in the actual app (CoreText glyphs/icons/color that screen.txt can't show), or to drive a flow by clicking. macOS + ghostty only.
allowed-tools: Bash(./run.sh shot:*), Bash(scripts/shot.sh:*), Bash(scripts/click.sh:*), Bash(osascript:*), Read
---

# Drive mnml — the third way to observe it

mnml can be observed three ways. The first two are **text** (the cell grid);
this skill is the third — **pixels**.

1. **headless** — `--headless` renders to a ratatui `TestBackend`; the cell grid
   is dumped to `.mnml/ipc/screen.txt`.
2. **screen.txt** — the real terminal loop *also* dumps `screen.txt` every frame
   (`src/tui.rs`). Same text form as headless.
3. **this skill** — a real screenshot of ghostty's window + synthetic mouse
   input. The only way to see what `screen.txt` fundamentally can't: the
   CoreText-rendered glyphs, Nerd Font icons, true colors, cursor shape — the
   rendering quality mnml went terminal-agnostic for.

Requires: macOS, mnml running in **ghostty** (`./run.sh` started it). Permissions
(one-time macOS grants, prompted on first use): **Screen Recording**
(screencapture) and **Accessibility** (System Events window geometry / keystrokes).

## ⚠️ Before driving input: is the window yours?

Posting mouse/keyboard events drives whatever real ghostty window matches
`mnml — <workspace>`. If **another session/person is actively using that mnml
window**, your clicks land in their lap. Before any `click`/`keystroke`:
- `shot` first and look at the current state.
- If unsure who's at the keyboard, **only screenshot — do not drive input.**
Screenshotting is always safe; input is not.

## View — screenshot the live window

```
./run.sh shot                 # or: scripts/shot.sh [OUT.png]
```

Prints the PNG path (stdout only). Then `Read` that path to see it. It also
writes a `<OUT>.json` geometry sidecar used for clicking. The window is found by
its OSC title `mnml — <workspace>` (set in `src/tui.rs`), preferring the one
matching the `run.sh` marker's workspace.

## Control — post mouse events

```
scripts/click.sh <move|click|rclick|dblclick|scroll> X Y [DELTA]
```

`X Y` are **display points** (top-left origin), the same space the shot geometry
uses. Source: `scripts/macclick.swift` (CGEvent; compiled+cached under `target/`).

### Pixel-in-PNG → click point

The PNG is retina (usually 2× the points). Read `<OUT>.json`
(`{origin_x,origin_y,scale,…}`) and convert a pixel `(px,py)` you spotted in the
shot to a screen point:

```
point_x = origin_x + px / scale
point_y = origin_y + py / scale
```

So: `shot` → `Read` PNG → find the target pixel → convert with the sidecar →
`scripts/click.sh click <point_x> <point_y>` → `shot` again to confirm.

## Control — type keys

Keystrokes go through System Events (no custom binary needed). Make ghostty
frontmost first, then send to the process:

```
osascript -e 'tell application "ghostty" to activate' \
          -e 'tell application "System Events" to keystroke "i"'          # a char
osascript -e 'tell application "System Events" to key code 53'            # Esc
osascript -e 'tell application "System Events" to keystroke "p" using {command down, shift down}'  # ⌘⇧P
```

Common `key code`s: Esc 53 · Return 36 · Tab 48 · ↑126 ↓125 ←123 →124.

## The verify loop

`shot` → `Read` → decide → `click`/`keystroke` → `shot` → `Read`. Capture a couple
of frames around an action; the statusline clock confirms a shot is fresh.
