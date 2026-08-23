---
title: Running mnml over SSH
description: What works verbatim, what degrades, and the one behavior that's silently wrong — when you SSH into a Linux server and run mnml there.
---

Running mnml on a remote box over SSH is a supported scenario — the release train ships Linux `x86_64` and `aarch64` binaries, and the crossterm + ratatui core makes no assumption that its stdout is a local terminal. This page is the short list of what actually changes when you SSH in.

## The scenario

`ssh you@server` → `mnml ~/some-repo`. Your keys, mouse, and screen updates travel over the SSH tunnel; mnml itself, your files, the LSP servers, `claude` binary, and every Pty pane's child process all live on the remote box.

The alternate scenario — mnml running locally on your laptop, opening `ssh you@server` inside a Pty pane — is not what this page covers. That case works today because Pty panes are just `libghostty-vt` buffers over any child process (`:term ssh user@server` opens one), and the SSH client's traffic never leaves your Mac.

## What works verbatim

- **Editing, panes, splits, layout, palette, chord chains, ex-commands.** Everything the render loop touches goes through crossterm (protocol traffic to your local terminal) and ratatui (pure Rust byte-buffer render). SSH is transparent.
- **Mouse.** SGR 1006 mouse mode negotiates through the SSH pty. Chip clicks, drag-resize splits, right-click menus all work the way they do locally.
- **LSP, git, tests, HTTP client.** All local to the box mnml runs on, which is what you probably wanted — that's why you SSH'd in.
- **Pty panes.** Claude Code, Codex, `htop`, integration launchers — all are child processes of mnml on the remote box; their output crosses the SSH tunnel the same way mnml's does.
- **Ghost-text via `claude -p` sub.** Runs on the remote box, needs the `claude` binary on the remote's PATH. Same authoring UX as local mnml.
- **Statusline OSC 9 / OSC 777 notifications.** Emitted to stdout, so they hit your local terminal — iTerm2's badge, xterm's bell, etc. all fire.
- **Image protocols** (sixel, kitty, iTerm2 inline). Auto-detected from `TERM` / `KITTY_WINDOW_ID` / `WEZTERM_EXECUTABLE`, which SSH forwards. Your local terminal has to speak the protocol.

## What degrades gracefully

- **System clipboard.** mnml uses [`arboard`](https://crates.io/crates/arboard), which needs a display server. On a remote Linux box with no X11 / Wayland forwarding, arboard init returns `None` — yank/paste **inside** mnml still work through the internal register + vim named registers, but the `"+ / "*` system-clipboard bridge is inert. Workaround: `ssh -X` (X11 forwarding) if your local system has an X server, or copy through the terminal's own selection.
- **Anthropic Keychain resync** (macOS's `security` binary shellout at `src/ai_usage.rs`). Not present on Linux, so the "Fetch from Keychain" button on the Claude Usage pane no-ops. Paste the OAuth token into `~/.config/mnml/ai_token` by hand — the rest of the auth surface works.
- **Sonos + AirPlay chip.** `#[cfg(target_os = "macos")]`-gated (CoreAudio + AppleScript). Not present on non-macOS builds; the chip doesn't render. Not a regression, just a platform gate.
- **`osascript`-driven now-playing detection.** Same story — the mixr / Spotify / Music watchers are macOS-only; the file-based mixr watcher works everywhere.

## What's silently wrong (one item)

**"Open in browser" opens on the wrong machine.** `gx`, the right-click "Open in browser" menu items, and integration links (Bitbucket, Jira, GitHub) all shell out to `xdg-open` when mnml is compiled for Linux. Running on a remote Linux server, that fires `xdg-open` **on the server** — best case it silently fails (no display), worst case it paints an unwanted window on whatever remote display the server has.

Until this is fixed properly (via OSC 8 hyperlinks or a copy-to-clipboard toast when `SSH_TTY` is set — see `docs/design/mnml-over-ssh.md`), the practical workaround is:

- Right-click the URL in your local terminal (most modern terminals turn URLs into clickable text — iTerm2, Ghostty, kitty, wezterm, WT all do).
- Or copy the URL out of the toast / hover-help panel and paste into your local browser.

## SSH config tips

Two small things in `~/.ssh/config` make the remote experience match local:

```
Host myserver
    SendEnv COLORTERM
    SetEnv TERM=xterm-256color
```

- `COLORTERM` — mnml's true-color rendering falls back to 256-color without this.
- `TERM=xterm-kitty` (instead of `xterm-256color`) if both your local terminal AND the remote's terminfo know kitty — enables the kitty image protocol.

Nerd Font: your **local** terminal has to have a Nerd Font configured. The remote box's fonts don't matter; the remote just emits codepoints.
