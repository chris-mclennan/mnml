---
severity: SEV-3
status: open
---
# `mnml-zig --headless --ascii <ws>` ignores `--ascii`: the virtual screen is full of Nerd Font glyphs and powerline chevrons

**Command id / surface:** the `--headless` entry point (`mnml-zig --headless [--ascii] WORKSPACE`), which the usage line lists `--ascii` for; what a host driving the file-IPC channel sees in `screen.txt`.

**Reproduction** (fresh launch):
```
MNML_DATA_ROOT=<fresh> MNML_COLS=80 MNML_ROWS=24 mnml-zig --headless --ascii <ws>
```
then read `screen.txt`.

**Expected:** the same screen `--ascii` gives in the terminal and under the `.test` runner's `# ascii` directive — e.g. the statusline `START  [no file]  B >   !  01:39  <ws>` with ASCII separators.

**Actual:** 24 private-use-area cells on the first frame; the statusline row is
```
 START  [no file]                 F 58% ▼0.6  󱼀 󰐎    01:39  ws-102   —
```
with U+E0B0/U+E0B2 chevrons and the `󱼀 󰐎 ` glyphs, and the top bar's `󰍉 󰐕 󰅖` icons — exactly the non-ASCII screen.

**Why:** `headlessSubcommand` calls `loadConfig(gpa, io, env, ws_abs, argv, false)` (`src/main.zig:1014`) with the `ascii` argument hard-coded `false`; the terminal path parses `--ascii` (`src/main.zig:323`) but the headless one never does.

**Reproduced:** 4/4 fresh launches.
