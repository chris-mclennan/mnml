# Two monitors — one mnml, two frames

*2026-10-02 · a research spike; nothing here is built. Every mnml claim was
read in this tree (main, `6bee26c1`). The user's brief: mnml on both
monitors, each possibly full screen, "the full mnml experience" on both —
and "we dont want to gimp or slowdown things we already worked so hard to
speed up".*

## 1. The problem in one paragraph

Eight-plus Claude Code / Codex sessions in pty panes, plus the code they
touch, do not fit one screen. Two separate mnml windows can be opened today,
but they are two apps: each has its own buffers, sessions, language servers
and scans, and the sessions started in one cannot be focused in the other.
The ask is **one mnml, two frames**: one process owning the buffers, panes,
ptys and sessions, painting into two terminal windows on two monitors, each
window independently sized (and possibly full screen), each with its own
focus.

"The full mnml experience on both" means, per window:

- **Keymaps**: both profiles, the leader and chord chain, vim operators
  pending. A half-typed chord in window 1 must not finish in window 2.
- **Chrome**: rail, activity bar, statusline, tab strip, overlays (picker,
  palette, menus) — opened in the window you are typing in.
- **Sessions mode** on either window (the obvious layout is code on the left
  monitor, four session columns on the right).
- **Tour / IPC**: `screen.txt`, `status.json`, `rects.json` and the
  `mnml-drive` tools keep working, and can address either window.
- **The web demo** keeps working; a second viewer is a bonus, not a must.

## 2. How mnml is built today, as it bears on this

**One loop, one wait** (`src/tui/loop.zig`). `run` creates one `Term`, one
`App`, and an `Io.Group` of three bridge tasks (terminal input →
`AppEvent`, the IPC tail, the signal pipe). Each iteration: wait on the
event queue → drain → `app.tick` → if `needs_render`,
`app.renderInto(term.screen())` and `term.render()`. Terminal output is
paced: while a pty has a backlog, frames come at most every 16 ms
(`flood_frame_ms`), immediately for input.

**`Term` is already decoupled from stdin/stdout's identity**
(`src/tui/term_posix.zig`). vaxis owns the cell store and the diff, but mnml
drives it "on `*std.Io.Writer` rather than through its Tty/Loop". Keys come
from stdin or `/dev/tty`; frames go to stdout's writer. The only
"one terminal per process" assumption is the panic hook's `var active:
?*Term` (both `term_posix.zig:55` and `term_windows.zig:66`). The Windows
console session sets `ENABLE_VIRTUAL_TERMINAL_INPUT`, so on Windows too the
input is a VT byte stream parsed by the same reader.

**The App is one view.** `App` (`src/app.zig`, ~335 fields) holds the
state of *the* screen: `cols`/`rows`, `screen`, `hits`, `focus`, `active`,
`overlay`, `chord`, `hover`, `zen`, `image_paints`, `frame` (the frame
arena), and `layouts.active` (the shown tab page). They are read
everywhere: `app.overlay` 1891 references in 111 files, `app.active` 735,
`app.focus` 558, `app.screen` 327, `app.hits` 276,
`layouts.active`/`current()` 238. Threading a `*Frame` parameter through
all of that is a rewrite; this shapes the recommendation.

**The frame arena is reset inside `render`** (`src/app/render.zig:607`,
`app.frame.begin()`), and the hit map registered by a frame must survive
until the next mouse event (DESIGN.md, 2026-09-04). Two renders per
iteration on one arena would free frame 1's hits under it — the exact
"frame-arena strings outlive the frame" bug class. A second frame needs
its own arena.

**Tab pages and the layout invariant** (`src/app/layout.zig:867`).
`LayoutState` is a list of pages with one `active`. The invariant
(`holders`, checked after every command in Debug) is that a pane lives in
one leaf of one page. So if each window shows a *different* page, no pty is
ever drawn in two places at two sizes. `PtyPane.fit(cols, rows)`
(`pty_pane.zig:343`) resizes the child to the leaf rect; it is the only
size a child has.

**pty output is not tied to the screen.** The reader thread fills a 256 KiB
SPSC ring (`src/pty/ring.zig`); `pty_pane.tickAll` pumps every pty pane
into its ghostty-vt terminal on every tick, *whether or not its page is
shown*. Rendering only reads the grid. So a second window does not add vt
parsing — only painting of what it shows.

**Sessions mode and git mode own "the page"** (`src/app/sessions_mode.zig`):
entering lifts sessions off other pages into `ai.session_columns` columns
and keeps the old trees in `State.others`. In a two-frame world that lift
must not pull a session out of the page the other window is showing.

**The IPC channel** (`src/ipc/`). `command` is tailed every 200 ms;
`screen.txt` / `status.json` / `rects.json` are rewritten per frame when
`ipc.write_screen` is on. Init is destructive: a second instance on the
same workspace truncates the first one's files. `screen.txt` is plain
text, no colour — a test oracle, not a viewer. The running-instance marker
(`src/tui/marker.zig`) is one file per user; a second instance overwrites
it, and `run.sh restart` then reaches whichever wrote last.

**Headless** (`src/headless.zig`) is the same `App` rendering into its own
`vaxis.Screen` (`App.render`), driven by the channel. Any frame abstraction
has to keep this path byte-identical, or the 1142 `.test` files under `tests/` move.

**The web demo is a byte pipe, not a protocol** (`demo/README.md`,
`demo/attract/`). ttyd runs `mnml --demo` on a pty and streams the
terminal's bytes over a websocket to xterm.js. mnml does not know a browser
exists. One terminal per container, "the newest page wins". It is the
proof that *escape bytes are a perfectly good wire* — but it mirrors one
screen at one size.

**The Bridge is the in-repo precedent for drawing from another process**
(`docs/BRIDGE.md`, `src/bridge/host.zig`). An integration paints its pane
over a Unix socket: 4-byte length + JSON, `frame` (whole grid) or
`frame_dirty` (changed rows), every cell an object
(`{"symbol":"a","fg":{"index":4},...}`). BRIDGE.md puts a 200×60 full frame
at ~300 KB. Frames never queue: the reader paints into one grid under a lock
and posts one `.frame` event, so a fast sender is coalesced. Input goes the
other way as `{"input":{"event":{"key":{"spec":"ctrl+k"}}}}`. Unix sockets
are used on Windows too (10 1803+). It is right for a pane that changes a
few times a second; a JSON cell per glyph is far too heavy for a whole
mnml frame at pty-flood rates — and it is the expensive half of what a
"remote UI" protocol would cost.

**The speed work that must not regress.** `docs/research/bench-2026-09-21.md`
(big-file open/edit/search/RSS, headless, via the out-of-tree `bench.py`);
`tools/compare.sh compare-keys` (per-step ms from command to screen dump,
`docs/research/compare/compare-keys*/timing.md`); the in-app stress meter
(`src/app/stress.zig`: p50/p95/max of the render alone, `perf.copy_stress`);
and the pty flood behaviour above (`flood_frame_ms`, bounded pumps).

## 3. Options

### a. Client/server split (tmux / zellij)

A daemon owns everything — App, panes, ptys, LSPs. Every window is a
client that attaches over a socket; the daemon renders per client and the
client writes to its tty. Sessions survive closing every window.

- **Buys**: detach/reattach (close both windows, the agents keep running);
  remote attach over ssh; N windows.
- **Breaks**: the first window is now a client too, so *every* keystroke and
  frame pays a socket hop, single-window included, unless the daemon also
  owns the first terminal (which is option f). `run.sh`'s exit-75 restart
  loop, the marker, `scripts/shot.sh` and the tour all assume the process in
  the window *is* mnml. Crash handling doubles (daemon dies → every window;
  client dies → orphaned state). Windows needs a named-pipe/AF_UNIX relay.
- **Hot paths**: +1 copy and context switch per frame and per key
  (tens of µs; tmux lives with it). pty throughput unchanged (vt parse stays
  in the daemon).
- **Single window**: not zero-overhead in the pure form.
- **Effort**: 15–25 agent-days, mostly lifecycle, not drawing.

### b. Emacs frames — mnml opens the second window itself

mnml spawns a second terminal window running a thin viewer and mirrors a
tab page into it over a channel; the viewer relays input back.

- **Buys**: one command ("open frame on the other monitor"); the user never
  types an attach command.
- **Breaks**: the window-spawn is per terminal and per OS (below, option e);
  placement on the *other* monitor is mostly not ours to choose.
- **Wire choice decides the cost.** If the viewer speaks a cell protocol
  (Bridge-style), mnml serializes every frame: at ~300 KB JSON per 200×60
  frame and 60 frames/s during a flood, that is real CPU on the UI thread.
  If the viewer is a byte pipe (mnml renders escape sequences, the viewer
  copies them to its tty), this collapses into option f with a spawn step.
- **Effort**: 8–12 agent-days with a cell protocol; the spawn step alone is
  1–2 on top of f.

### c. Neovim `--remote-ui` — a UI protocol

mnml exposes a semantic UI protocol (Neovim's is `grid_line` events with
highlight ids and a `flush`); any number of UIs attach, including
non-terminal ones.

- **How it differs from a**: the client renders. That buys GUI front-ends,
  a browser viewer without ttyd, and per-UI fonts — not more monitors.
- **What exists already**: `screen.txt` is uncoloured text written to disk
  per frame — an oracle, not a UI. The demo's relay is a byte stream of one
  terminal. The Bridge is a cell protocol in the *other* direction.
- **Neovim's lesson**: with several UIs attached, the active capabilities
  are "the intersection of those requested", and one global grid has to
  pick one size; per-window independence needed `ext_multigrid`. That is a
  large surface to design and keep stable.
- **Hot paths**: a serialize per frame for every attached UI; the
  single-window path can skip it, but the protocol becomes a contract every
  chrome change must honour.
- **Effort**: 20–30 agent-days to something usable. Wrong tool for "two
  monitors".

### d. Two instances + shared state (close to today)

Run a second mnml on the same workspace and add an "adopt / move session"
command.

- **Buys**: zero engineering on the hot path; works today, roughly.
- **Breaks, today, measured in code**: the second instance's channel init
  truncates the first's IPC files (needs `MNML_IPC_DIR` per instance);
  `.mnml/session.zon` is last-writer-wins; the marker names whichever
  started last, so `run.sh restart` hits one of them; every LSP, scan worker
  and parse runs twice (RSS ×2 on the big-file bench); the same file open in
  both is two buffers that will conflict on save. The sessions *scan* is
  shared (both read the transcript directories), so instance B lists A's
  sessions as `EXTERNAL`.
- **The honest problem — a pty cannot move between processes, mostly.**
  What exists: session restore already relaunches an AI pane with
  `--resume <id>` (`app/session.zig`, `pty_pane.resumeArgv`). So "move"
  can be *end in A, resume in B*: the conversation moves, the in-flight turn
  and the live process do not, and a plain shell cannot move at all.
  A true move: on POSIX the pty master fd *can* be sent to another process
  (`SCM_RIGHTS`), and on Windows a ConPTY handle can be duplicated — but the
  ghostty-vt terminal, its scrollback and the ring live in A's memory, so B
  starts with a blank screen until the child repaints (a TUI does on
  `SIGWINCH`; a shell's history is lost). A detachable layer that keeps the
  state (dtach/abduco-style holder per pty) puts a process hop on every pty
  byte — exactly the throughput the pump work bought.
- **Effort**: per-instance IPC dir + session file 1–2 days; end-and-resume
  move 2–3; true fd move 5–8 with the blank-screen caveat.

### e. Terminal-native

No terminal shows one program's surface in two OS windows; a pty has one
reader. What they offer is *spawning* a window, which helps b/f:

| terminal | open a window | place it / full screen |
|---|---|---|
| Ghostty, macOS | AppleScript `new window` (1.3+); `open -na Ghostty.app --args -e …` | AppleScript has no bounds/screen verb; config `window-position-x/-y` (macOS only, relative to the visible screen) and `fullscreen` |
| Ghostty, Linux | `ghostty +new-window` (native IPC to the running instance) | `fullscreen`; GTK ignores position |
| kitty | `kitten @ launch --type=os-window` (remote control on) | WM's choice |
| WezTerm | `wezterm connect <domain>` opens a second window; a second connect mirrors the first | WM's choice |
| Windows Terminal | `wt -w new …` | `--pos`, `--fullscreen` flags |

WezTerm's mux is the nearest thing to the ask, but it multiplexes
*terminal tabs*, so mnml would run twice inside it. Placement is the
platform's: Wayland forbids a client from positioning its toplevel at all;
X11 and Windows allow it; macOS allows it per app. Realistically the user
drags window 2 to monitor 2 once and full-screens it.

### f. Second frame in the same process — `mnml attach` hands over its terminal (better)

The interactive mnml stays exactly what it is. In another terminal window,
`mnml attach` connects to the running instance's socket and **hands over
its terminal**: on POSIX it sends its tty fd (`SCM_RIGHTS`) and then just
waits; mnml opens a second `Term` on that fd — raw mode, its own vaxis
screen and diff, its own input worker posting into the same event queue
tagged with frame 2. This is how tmux itself works: the client passes its
fd and the server writes everything to it. On Windows, where a process has
one console, `mnml attach` is a byte relay (console VT input → socket,
socket → console), which is the fallback tmux uses on Cygwin. Both
directions are already escape bytes, so the relay is a copy loop, no
protocol.

Inside mnml, **a frame is a view swap, not a parameter**. A `View` struct
holds the per-window fields (`cols`/`rows`, `screen`, `hits`, `frame`
arena, `focus`, `active`, `overlay`, `chord`, `hover`, `zen`,
`image_paints`, `layouts.active`, the sessions/git mode slot). The App's
fields *are* view 1. When an event arrives tagged frame 2, or frame 2 needs
a paint, the loop swaps view 2's fields in, handles/renders, and swaps
them out — Emacs's "selected frame". None of the ~4000 call sites change.

- **Buys**: one process, shared buffers/sessions/LSPs, independent focus,
  overlay, page, sessions mode per window; full screen is just the
  terminal's own; the web demo gains a second viewer for free (ttyd running
  `mnml attach`).
- **Breaks**: closing window 1 (the owning terminal) ends mnml — no detach
  (option a's one real advantage). IPC needs a frame field (below). The
  panic hook must restore every terminal. Both terminals' capabilities may
  differ (kitty graphics in one, not the other) — capabilities become per
  view, which `Term.caps` already is.
- **Hot paths**: frame 1's bytes still go straight to stdout; frame 2's
  go straight to its fd (POSIX) — no serialize, no extra hop. Input from
  frame 2 is one more reader task on the same queue. Render: a frame whose
  page did not change does not need repainting; first cut repaints every
  attached frame on `needs_render` (the flood pacing caps it at 60/s), then
  per-frame dirty bits if the stress meter says so. pty throughput:
  unchanged — pumping is already per pane, shown or not.
- **Single window**: no `View` swap ever happens; the loop pays one
  `frames.len > 1` branch per iteration; the attach socket listener is one
  idle task. Measured, not asserted — see §5.
- **Effort**: 10–15 agent-days to parity (phases in §5).

### Comparison

| | one process | own focus / page per window | single-window overhead | render cost per extra window | pty throughput | survives closing all windows | Windows | effort (agent-days) |
|---|---|---|---|---|---|---|---|---|
| a. daemon + clients | yes | yes | +1 hop per key and frame | escape bytes over socket | unchanged | **yes** | relay needed | 15–25 |
| b. mnml spawns viewer (cell wire) | yes | yes | none | serialize every frame | unchanged | no | relay needed | 8–12 |
| c. UI protocol | yes | yes (with multigrid) | none if unattached | serialize per UI | unchanged | no | any | 20–30 |
| d. two instances | **no** | yes | none | none | unchanged | no | works | 1–8 |
| e. terminal-native | — | — | — | — | — | — | — | helper only |
| **f. attach hands over tty** | **yes** | **yes** | **one branch** | **a render + vaxis diff** | **unchanged** | no | byte relay | **10–15** |

## 4. Prior art (read)

- **tmux**: one server, clients over a socket in `/tmp`. Several clients
  on one window negotiate size: `window-size` is `largest`, `smallest`,
  `manual` or `latest`; `aggressive-resize` sizes per current client. The
  server writes to the fd the client passed in; on Cygwin, where fds cannot
  be passed, it relays through a pty instead.
  [man tmux](https://man7.org/linux/man-pages/man1/tmux.1.html),
  [tmux#4054](https://github.com/tmux/tmux/pull/4054)
- **zellij**: multiple clients each "focused on different tabs" — it
  names the two-monitor case directly. Since 0.45 a tab is sized only by the
  clients viewing it, so windows on different tabs no longer constrain each
  other. [multiplayer sessions](https://zellij.dev/news/multiplayer-sessions/),
  [options](https://zellij.dev/documentation/options.html),
  [discussion #5066](https://github.com/zellij-org/zellij/discussions/5066)
- **Neovim**: `nvim_ui_attach` + `grid_line` / `flush`; capabilities of
  several UIs are intersected; `ext_multigrid` lets a UI size grids
  independently of the global layout.
  [api-ui-events](https://neovim.io/doc/user/api-ui-events/)
- **Emacs**: one process, many frames, on several displays or ttys
  (`make-frame-on-display`, `emacsclient -t` opens a tty frame in the
  calling terminal). Frames on different terminals get separate input
  streams, each with its own selected frame — option f's per-view chord
  chain and `View` swap are this shape. `make-frame-on-monitor` covers one
  display with several monitors.
  [Multiple Displays](https://www.gnu.org/software/emacs/manual/html_node/emacs/Multiple-Displays.html)
- **Kakoune**: a server per session; `kak -c` attaches another client
  in another terminal, sharing buffers, registers and undo.
  [why Kakoune](https://kakoune.org/why-kakoune/why-kakoune.html)
- **Helix**: users ask for a window per monitor sharing state; no
  maintainer answer; an experimental fork splits `Editor` for multiple
  clients. [discussion #12951](https://github.com/helix-editor/helix/discussions/12951),
  [issue #312](https://github.com/helix-editor/helix/issues/312)
- **VS Code / Zed**: VS Code is one main process, a renderer and an
  extension host per window; since 2026-08 agent sessions live in a
  separate Agent Host so "multiple windows can connect to one host" — the
  detachable-session idea, for agents specifically. Zed opens one window
  per project and refuses two windows on one project.
  [Agent Host](https://code.visualstudio.com/blogs/2026/08/26/agent-host-architecture),
  [sandboxing](https://code.visualstudio.com/blogs/2022/11/28/vscode-sandbox),
  [Zed windows](https://zed.dev/docs/windows-and-projects),
  [zed#12074](https://github.com/zed-industries/zed/discussions/12074)
- **Terminals**: [Ghostty AppleScript](https://ghostty.org/docs/features/applescript),
  [Ghostty config](https://ghostty.org/docs/config/reference),
  [ghostty +new-window](https://man.archlinux.org/man/ghostty.1),
  [kitty remote control](https://sw.kovidgoyal.net/kitty/remote-control/),
  [WezTerm multiplexing](https://wezterm.org/multiplexing.html),
  [wt command line](https://learn.microsoft.com/en-us/windows/terminal/command-line-arguments),
  [Wayland placement](https://wiki.libsdl.org/SDL3/README-wayland).

## 5. Recommendation

**Option f**, built so that option a stays reachable later: the `View`
split is the prerequisite for any multi-window design, so none of it is
thrown away if detach is wanted one day.

**Rule for pages**: a tab page is shown by at most one window. Asking
window 2 for the page window 1 shows swaps the two (xmonad's greedy view).
That keeps the layout invariant meaning "one pty, one size" and avoids
tmux's `window-size` question entirely. Sessions mode gets a per-view slot
and only lifts sessions from pages no other window shows.

| phase | what | agent-days |
|---|---|---|
| 0 — prove it | `mnml attach` (POSIX fd handoff); a second `Term` on that fd; `View` with the fields in §3f and its own frame arena; the loop swaps views per event and per paint; window 2 shows page 2. macOS + Linux. | 2–3 |
| 1 — parity | chord chain and pending operators per view; overlays/menus open in the window you clicked; statusline, rail, tab strip per window; sessions mode per window; `frame.next` / `frame.close` commands; IPC: `status.json` gains `frames[]`, input lines take an optional `"frame":2`, `screen.txt` stays frame 1 and frame 2 writes `screen-2.txt`; panic hook restores every terminal; window title `mnml — ws · 2` so the tour finds it | 5–7 |
| 2 — reach | Windows byte relay; `frame.open_window` that spawns the terminal and runs `mnml attach` (Ghostty AppleScript / `ghostty +new-window` / `wt -w new --fullscreen`); per-frame dirty bits if Phase 0's numbers ask for them | 3–5 |
| later, if asked | detach (option a): move the owning terminal into an attached view and keep the process when it closes | 5–10 |

**The smallest first step that proves it**: Phase 0 behind a build flag —
two Ghostty windows, the left editing a file, the right running
`mnml attach` showing a page of four Claude stand-in panes flooding
output, typing in each with the other one live.

**What shows the single-window hot paths unchanged** — run each on main and
on the branch, single window, same machine, back to back:

1. `tools/compare.sh compare-keys` and `compare-keys 200x60` — the per-step
   ms in `timing.md` must sit inside the run-to-run noise
   (`docs/research/compare/`).
2. The big-file rows of `docs/research/bench-2026-09-21.md` (10 MB and
   100 MB `.rs` / `.log`, the out-of-tree `bench.py`) — open, edits,
   search, RSS.
3. The stress meter in the real terminal loop: a scripted session, then
   `perf.copy_stress` — p50/p95 of the render.
4. A pty flood in the real loop (the `tools/pty-lifecycle.py` way of
   spawning on a pty): a pane catting a few hundred MB, wall time to
   finish and key-echo latency during it.

Then the same four with a second window attached, to say what the second
window costs — that number is the user's to accept, the single-window
number must not move.

## 6. Open questions for the user

- Should a window be able to show the same page as the other (a mirror), or one page per window?
- Is it acceptable that closing the first window quits mnml, or must agents survive all windows closing?
- Should mnml open and place the second terminal window itself, or will you type `mnml attach` in a window you placed?
- macOS + Linux first and Windows in phase 2, or all three on day one?
- Should the second window open straight into sessions mode?
- Is attaching from another machine (over ssh) ever wanted?
