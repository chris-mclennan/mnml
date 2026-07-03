---
title: Google Calendar browse + create
description: mnml-msg-gcal — a terminal Google Calendar client. Today / Week / Upcoming meeting panes with keyboard-driven navigation. Uses Google Calendar API v3 with per-user OAuth loopback.
---

[`mnml-msg-gcal`](https://github.com/chris-mclennan/mnml-msg-gcal) is a terminal Google Calendar client. Today's meetings, the week ahead, upcoming events — keyboard-driven navigation, respects the calendar list you've subscribed to. Quick-create dialogs. Runs **standalone in any terminal**.

## Status — v0.1 skeleton

**Working:** CLI + config, `--install` / `--uninstall`, Calendar API v3 client (`list_events`), OAuth token cache format.

**Not yet implemented:** OAuth interactive loopback flow, TUI event loop, quick-create popup. See [the sibling repo](https://github.com/chris-mclennan/mnml-msg-gcal) for v0.2 milestones.

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-msg-gcal mnml-msg-gcal
mnml-msg-gcal --install
```

## Setup (per-user GCP project)

Google Calendar API requires a per-user OAuth client — same shape as `gcloud auth login`.

1. Open <https://console.cloud.google.com>, create a new project (or reuse one).
2. Enable **Calendar API v3** under *APIs & Services → Library*.
3. **OAuth consent screen** — External + add your email as a *Test user*.
4. **Credentials → Create Credentials → OAuth Client ID → Desktop app.** Copy client_id + client_secret.
5. Drop them into `~/.config/mnml-msg-gcal/client.toml`:

   ```toml
   client_id     = "<your-client-id>.apps.googleusercontent.com"
   client_secret = "<your-client-secret>"
   ```

6. Verify with `mnml-msg-gcal --check`.

Once v0.2 lands, first launch triggers the OAuth loopback flow — browser opens, you grant Calendar scope, token lands at `~/.config/mnml-msg-gcal/token.json`.

## Config

`~/.config/mnml-msg-gcal.toml` (scaffolded first run):

```toml
calendar_id   = "primary"          # or an email-shaped calendar id
timezone      = "America/New_York" # defaults to $TZ then UTC
refresh_secs  = 60
upcoming_days = 14
```

## Keys (planned for v0.2)

| Key | Action |
|---|---|
| `1` / `2` / `3` | Switch to Today / Week / Upcoming |
| `j` / `↓`, `k` / `↑` | Move selection |
| `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` | Open event details |
| `n` | Quick-create event |
| `r` | Refresh |
| `y` | Yank event link (`htmlLink`) |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-msg-gcal
```

### Hosted as a mnml Pty pane

```vim
:term mnml-msg-gcal
```

Or `<leader>iC` after `mnml-msg-gcal --install`.

## Source

[github.com/chris-mclennan/mnml-msg-gcal](https://github.com/chris-mclennan/mnml-msg-gcal). MIT.
