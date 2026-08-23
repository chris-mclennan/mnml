# mnml over SSH — what works, what degrades, what breaks

Task #1163. Ground truth as of 2026-08-23 (commit ~`a8eb98ea`).

## TL;DR

The core editor (crossterm + ratatui) runs unmodified over SSH. Every
feature that reaches OUTSIDE the terminal to the host — open a browser,
read the Keychain, control the Mac's audio output, notify the desktop
— quietly no-ops or acts on the *remote* box, not your laptop. There
are no crashes; there is one silently-wrong behavior worth
documenting (the URL-open shellouts).

## Verdict per surface

### Works verbatim over SSH

- **Editing, panes, splits, layout, palette, chords, ex-commands.**
  All keyboard + rendering routes through `crossterm` (which speaks
  the ANSI/xterm protocol crossterm ↔ your local terminal) and
  `ratatui` (renders to a byte buffer). Nothing platform-native in
  the render loop.
- **Mouse.** SGR 1006 mouse mode is negotiated over the SSH pty. All
  chip-click / drag-resize / right-click flows work.
- **File I/O, LSP, git, HTTP client, tests.** All happen on the box
  mnml is running on — the SSH scenario ("mnml on a Linux server")
  is the natural fit.
- **Pty panes** (Claude Code, Codex, htop, integrations spawned as
  `:term …`). These are just child processes on the box mnml runs
  on; the SSH client sees their output the same way it sees mnml's.
- **Ghost text via `claude -p` sub** (`src/ai/api_client.rs::nl_to_curl`
  and friends) — runs on the remote box, needs `claude` on PATH there.
- **Bufferline notifications via OSC 9 / OSC 777** (`src/tui/mod.rs:53-58`).
  Emitted to stdout, so they cross the SSH tunnel and land in whatever
  the LOCAL terminal does with them (iTerm2 badge, xterm bell, etc.).
- **Sixel / kitty / iTerm2 image protocols** (`src/image/mod.rs`) —
  auto-detected via `TERM`/`KITTY_WINDOW_ID`/`WEZTERM_EXECUTABLE`.
  Works over SSH as long as the SSH-client terminal on your end
  advertises the protocol AND your ssh config passes through the
  needed env (usually `TERM` alone is enough).
- **Clipboard via `arboard`** (`src/clipboard.rs:55`) — arboard tries
  native APIs first (OSC 52 is not one of them). On a Linux server
  arboard needs `X11`/`wayland` up; over a plain SSH session there's
  usually no display server, so arboard init returns `None` and the
  clipboard falls back to mnml's internal register (`self.sys` is
  `None`). Yank/paste inside mnml still works; system-clipboard
  bridge doesn't.

### Silently wrong

- **`gx` / right-click "Open in browser" / integration "open URL"**
  (`src/app/mod.rs::open_url_external` line 1357, plus three
  `Command::new("open" | "xdg-open" | "cmd /C start")` sites in
  `src/ui/integration_detail_view.rs:1000-1011`,
  `src/app/context_menus.rs:1974`, `src/app/mod.rs:9219`). These
  detect platform via `cfg!(target_os = …)` — a *compile-time*
  check. When mnml is compiled for Linux and running on a Linux
  server, `xdg-open` fires — which opens the URL in a browser **on
  that server**, not on your Mac. Best case: no display server,
  process errors and dies silently. Worst case: some remote-desktop
  session paints an unwanted window on the server. Either way the
  user's expectation ("show me this Bitbucket PR in my browser") is
  not met, with no error surfaced. **Recommended fix**: detect SSH
  session (env `SSH_TTY` or `SSH_CONNECTION` set) and emit OSC 8
  (hyperlinked text — modern terminals turn it into a clickable
  link the local terminal opens) OR toast the URL for manual copy
  instead of shelling out.

### Broken by environment, not by mnml

- **Anthropic Keychain resync**
  (`src/ai_usage.rs:216,366,412` — `security find-generic-password`).
  macOS-only shellout. On a Linux server the shellout fails; the
  function returns `None`; the token file path (`~/.config/mnml/ai_token`)
  is the only ingest point, so users on a remote server paste the
  Claude Code OAuth token there manually. No mnml-side bug — the
  code path already handles the `security` binary being missing.
- **Sonos statusline chip + AirPlay**
  (`src/sonos/coreaudio.rs`, `src/sonos/airplay.rs`, gated
  `#[cfg(target_os = "macos")]` at `src/sonos/mod.rs:27-29` and
  `src/sonos/stream.rs:93,101`). Non-macOS builds compile the
  Sonos surface out — the chip renders as inactive, transport
  actions are no-ops. Not a regression; a documented platform gate.
- **`osascript` shellouts** (music now-playing at
  `src/now_playing/macos.rs`, CDP window bounds at
  `src/app/cdp.rs:455,478,520,571`, terminal detection at
  `src/tui/mod.rs:3080`). All gated on macOS at either the module
  or the call site; degrade to safe defaults elsewhere.
- **Nerd Font glyphs.** The chrome uses Nerd Font codepoints (chips,
  file-tree icons, git glyphs). Your LOCAL SSH-client terminal has
  to have a Nerd Font configured — the remote box's fonts don't
  matter, since the remote just emits codepoints. Same story as
  running mnml locally, moved one hop.

## Case B — mnml running LOCALLY, opening remote SSH sessions in Pty panes

Different scenario, not the one this doc covers. `:term ssh
user@host` opens a Pty pane that runs SSH inside — the child
process talks to the remote box, mnml renders the child's output
into a pane. Works today because Pty panes are just `libghostty-vt`
buffers over any child process; no code change needed.

## Recommended patches (not applied here)

1. **`src/app/mod.rs::open_url_external`** — add SSH detection
   (`std::env::var("SSH_TTY").is_ok()`) and switch strategy:
   - Emit OSC 8 hyperlink into the buffer for one frame + a toast
     ("URL copied to clipboard — Cmd+Click your terminal to open"),
     OR
   - Copy to clipboard + toast the URL. Better than the current
     silent-`xdg-open`-on-the-wrong-box.
2. **Sweep the four call sites** that duplicate the same pattern
   (`integration_detail_view.rs:1000`, `context_menus.rs:1974`,
   `app/mod.rs:9219`, the `open_url_external` in `app/mod.rs:1357`)
   through `open_url_external` so the SSH fix lands in one place.
3. **Doc `~/.ssh/config` guidance**: `SendEnv COLORTERM` + `SetEnv
   TERM=xterm-256color` (or `xterm-kitty` for kitty image support)
   are the two most common gotchas — surface these in the manual
   page.

None of these are urgent. Point 1 is the only one that changes
user-visible behavior; the rest are hygiene / discoverability.
