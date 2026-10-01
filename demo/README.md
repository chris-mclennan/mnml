# demo/ — mnml in the browser (local trial)

A real `mnml --demo`, running in a Linux container, shown in the browser
through ttyd (its websocket, driven by xterm.js in the demo's own page). Until the visitor touches it,
an **attract mode** plays the site's tour flows inside the live app with
a banner — *Guided tour playing — press any key or click to take over*.
The first key or click stops the tour where it is and the visitor has
the real app in that state. Idle for three minutes and the tour resumes;
after ten minutes the session ends with *Start again*.

Everything lives in this folder. The site's "Try it" button is **not**
added; nothing on the site links here.

## Run the trial

```bash
demo/run-local.sh            # builds mnml-demo:local the first time, starts ONE container
open http://localhost:7681
demo/run-local.sh stop       # stop every container this script started
```

Options: `--port N` (several side by side), `--cap SECONDS` (default
600), `--idle SECONDS` (default 180), `--rebuild` (after changing the
app or this folder; `demo/build.sh` alone rebuilds the image), `--dev`
(this checkout's runner, flows and page mounted over the image's).

Each `run-local.sh` is a **new container**: a fresh `mnml --demo`
sandbox, nothing shared with any other run. Reloading the page (or
*Start again*) inside one container starts a new `mnml --demo` there —
its sandbox is new too, but the container is reused; the per-visitor
container is the broker's job (`broker/README.md`).

## What's in here

| path | what |
| --- | --- |
| `Dockerfile` | three stages: build mnml + the two fakes + the two integrations + MnmlSymbols with Zig 0.16 (ReleaseSafe, any arch); fetch the web fonts; a Debian runtime with git, zsh, bash, vim-tiny, ttyd, python3, a non-root `demo` user |
| `build.sh` | builds the image from the repo's tracked files (the checkout's `zig-pkg/` rides along when present); `--cross` compiles the Linux binaries on the host instead |
| `run-local.sh` | the trial: one fresh container, `--network none`, plus a relay |
| `attract/attract.py` | the one process in the container: starts ttyd, serves the page + fonts + xterm.js + `/api/*`, proxies ttyd's websocket (the newest page wins), plays the flows, watches for the visitor |
| `attract/session.sh` | what ttyd runs per connection: `mnml --demo --config kiosk.zon`, then the "session over" screen |
| `attract/kiosk.zon` | the config layer that opens mnml's file channel to the runner |
| `attract/relay.py` | publishes the port for a container that has no network |
| `flows/` | the site recorder's flows (`tools/site-record/flows/`), minus recording-only steps |
| `web/index.html` | the page: the site's Ghostty-style window frame, the terminal (xterm.js speaking ttyd's protocol, the web fonts), the banner, Replay / the flow picker, the end screen |
| `broker/README.md` | the interface a per-visitor broker needs |
| `cloudflare/` | the broker, built: the hosted demo on Cloudflare Containers |

## How attract mode works

- **Playing.** A flow is the recorder's format (`run`, `key`,
  `slowtype`, `until`, …). Each step becomes a line appended to mnml's
  IPC `command` file (`MNML_IPC_DIR`), exactly as the recorder drives
  it; `until` reads `screen.txt`. `kiosk.zon` turns on
  `ipc.allow_input` (the channel may type and click) and
  `ipc.write_screen`.
- **Taking over.** mnml did not log terminal input, so this work added
  `ipc.report_input` to the app (`src/tui/loop.zig`): with it on, a key,
  click, wheel or paste **at the terminal** appends
  `{"event":"input","kind":"key|mouse|paste"}` to `events.jsonl` (one a
  second per kind; never what was typed; pointer motion is not input).
  Input the runner sends through the channel never produces one, so the
  runner cannot mistake its own keys for a visitor. The runner tails
  `events.jsonl` every 50 ms; the player checks its stop flag before
  every line and during every wait, so the tour stops mid-step. Clicking
  the page's banner also takes over (`POST /api/stop`).
- **The banner** is the page's pill over the terminal plus a statusline
  segment inside mnml (`statusline-set-segment`) naming the flow.
- **Replay** restarts the whole tour; the picker plays one flow and then
  leaves the app live. Idle `MNML_DEMO_IDLE_S` → the tour resumes from
  the start. `MNML_DEMO_CAP_S` after the session started, the runner
  sends `quit` (mnml removes its sandbox) and `session.sh` paints the
  end screen; the page shows *Start again*.

## Fidelity: real vs stand-in

Real: mnml itself (the same ReleaseSafe build as a release, Linux), its
editor, splits, palette, git (a real repository made at start), the
shell (zsh), `vi`, the Lua runtime, the Jira and Bitbucket
integrations, the terminal emulation inside mnml (libghostty).

Stand-in: Jira and Bitbucket answer from `mnml-fake-jira` /
`mnml-fake-bitbucket` inside the container; `claude` and `codex` are the
demo's shims (a canned exchange, no model). The outer terminal is
xterm.js, not Ghostty: no kitty graphics, so image previews do not
show; fonts are JetBrains Mono + Symbols Nerd Font Mono + MnmlSymbols as
web fonts rather than the visitor's own. The Marketplace flow is left
out: it needs the network.

## Network

The container runs with `--network none`: only loopback. Docker drops
published ports on such a container, so `run-local.sh` adds a second
container from the same image (`attract/relay.py`) on the default
bridge that accepts TCP on `127.0.0.1:PORT` and splices it to the demo's
unix socket in a shared volume. The relay runs nothing else. Network is
used only by `docker build` (apt, Zig, fonts, Zig packages).

## Image

`mnml-demo:local` measured on this Mac (linux/arm64): **483 MB on disk,
107 MB compressed** — Debian trixie-slim, git/zsh/python3/vim-tiny,
the stripped ReleaseSafe `mnml` (72 MB), the integrations and fakes
(7 MB), ttyd's static binary, 2 MB of web fonts. A cold build is about
25 minutes here (the app's ReleaseSafe compile dominates); a rebuild
that only touches `demo/` reuses the build stage when docker's cache
holds. `demo/build.sh` reuses a local image with Zig 0.16 in it
(`mnml-zig-linux-gate`) when there is one: ziglang.org served the
tarball at ~70 KB/s during this work. `demo/build.sh --cross` builds the
Linux binaries with the host's Zig (about 5 minutes on this Mac) and the
image only copies them — no compile space on docker's disk, which was
full here.

## Notes from the trial

- The terminal is 200x60 cells, the recordings' grid. The page runs its
  own xterm.js and speaks ttyd's websocket protocol: ttyd's client fits
  the terminal to its page on every resize, which fought the page's
  sizing (a resize loop until the fonts settled, then a grid clipped by
  the font swap). Now the fonts load first, the terminal is created at
  200x60, the font size is chosen from the measured cell so the grid fits
  the window's width and height, the frame wraps the grid exactly, and
  the pty is told 200x60 once. A window resize changes only the font size.
- The font is one family by unicode-range (JetBrains Mono, Symbols Nerd
  Font Mono, MnmlSymbols) plus the symbol files as fallback families.
  Two Chrome traps cost glyphs: a `font-weight: 100 900` range on the
  symbol faces (never matched), and the ranged face for the Nerd Font's
  supplementary-plane icons in the canvas renderer (boxes; the fallback
  family draws them).
- One terminal per container, and the newest page wins: a reload or a
  second tab ends the older websocket; each session has its own IPC
  directory, so an older mnml's exit never ends the newer session. A page
  whose connection is gone says so and offers a new session.
- The terminal answers mnml's startup queries (a cursor-position report
  can read as F3), so input in a session's first 4 s does not stop the
  tour.
- **An app bug the tour found:** opening the git status pane while a
  second tab page exists panics this build (`App.showPane`, reached
  unreachable code, from `git.status_pane`). The demo's `splits.flow` ends
  with `tab.only` to stay clear of it; a visitor can still hit it.

## Rollback

Delete `demo/` (and, if it was ever added, the site's "Try it" button),
plus the images and containers: `demo/run-local.sh stop; docker rmi
mnml-demo:local`. The one app change (`ipc.report_input`, off by default)
can stay or be reverted on its own.

## Hosted: Cloudflare Containers

`cloudflare/` is the hosted form, at **mnml.sh/demo**: a Worker on the
zone's `/demo` route, a Durable Object per visitor session (`?s=<id>`)
that starts one container from this image built for linux/amd64
(`cloudflare/build-image.sh`), no egress, and a control mode
(`DEMO_CONTROL`: view / ask / open) the Worker enforces. How to run it
under `wrangler dev`, deploy it, what it costs and how to roll it back:
`cloudflare/README.md`. The page and runner here serve both: the page
uses relative URLs and carries `?s=` when it has one; the runner listens
on `MNML_DEMO_LISTEN=unix:/path` (the local trial) or `tcp:HOST:PORT`
(hosted).
