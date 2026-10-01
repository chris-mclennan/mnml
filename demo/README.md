# demo/ — mnml in the browser (local trial)

A real `mnml --demo`, running in a Linux container, shown in the browser
through ttyd (xterm.js over a websocket). Until the visitor touches it,
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
app or this folder; `demo/build.sh` alone rebuilds the image).

Each `run-local.sh` is a **new container**: a fresh `mnml --demo`
sandbox, nothing shared with any other run. Reloading the page (or
*Start again*) inside one container starts a new `mnml --demo` there —
its sandbox is new too, but the container is reused; the per-visitor
container is the broker's job (`broker/README.md`).

## What's in here

| path | what |
| --- | --- |
| `Dockerfile` | three stages: build mnml + the two fakes + the two integrations + MnmlSymbols with Zig 0.16 (ReleaseSafe, any arch); fetch the web fonts; a Debian runtime with git, zsh, bash, vim-tiny, ttyd, python3, a non-root `demo` user |
| `build.sh` | builds the image from the repo's tracked files (the checkout's `zig-pkg/` rides along when present) |
| `run-local.sh` | the trial: one fresh container, `--network none`, plus a relay |
| `attract/attract.py` | the one process in the container: starts ttyd, serves the page + fonts + `/api/*`, proxies ttyd, plays the flows, watches for the visitor |
| `attract/session.sh` | what ttyd runs per connection: `mnml --demo --config kiosk.zon`, then the "session over" screen |
| `attract/kiosk.zon` | the config layer that opens mnml's file channel to the runner |
| `attract/relay.py` | publishes the port for a container that has no network |
| `flows/` | the site recorder's flows (`tools/site-record/flows/`), minus recording-only steps |
| `web/index.html` | the page: the site's Ghostty-style window frame, the banner, Replay / the flow picker, the end screen |
| `web/term-head.html` | put into ttyd's own page: the `@font-face`s, and the cell size reported to the frame |
| `broker/README.md` | the interface a per-visitor broker needs (not built) |

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

See the numbers in the commit that measured them: `docker image ls
mnml-demo:local`.

## Rollback

Delete `demo/` (and, if it was ever added, the site's "Try it" button),
plus the images and containers: `demo/run-local.sh stop; docker rmi
mnml-demo:local`. The one app change (`ipc.report_input`, off by default)
can stay or be reverted on its own.

## Hosting next (not decided)

- **Cloudflare Containers**: a Worker in front routes each visitor to a
  container instance (Durable Object per session = the broker); needs
  the image in Cloudflare's registry (linux/amd64), websocket
  passthrough from the Worker, instance sleep/teardown after `ended`, and
  egress blocked (the image needs none). Pay per running instance.
- **Fly.io**: Fly Machines API as the broker — create a machine per
  visitor from the image, route with `fly-replay` or a small proxy app,
  destroy on `ended`/disconnect; `auto_stop` for idle. Egress: Fly has
  no per-machine egress switch — keep machines in a private network
  with no public egress or accept outbound and rely on there being
  nothing to reach out with.
- Both: build for linux/amd64 (`docker build --platform linux/amd64`;
  the Dockerfile is arch-agnostic), set `MNML_DEMO_PORT`, keep
  `MNML_DEMO_LISTEN` unset (TCP), and put the broker of
  `broker/README.md` in front.
