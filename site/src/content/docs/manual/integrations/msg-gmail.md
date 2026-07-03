---
title: Gmail browse + compose
description: mnml-msg-gmail — a terminal browser + composer for Gmail. List inbox / sent / starred / labels, search with full Gmail query syntax, read message bodies, archive, star, and compose new mail. Uses Gmail API v1 with per-user OAuth loopback (like `gcloud auth login`).
---

[`mnml-msg-gmail`](https://github.com/chris-mclennan/msg-gmail) is a terminal browser + composer for Gmail. List inbox / sent / starred / labels, search with Gmail's full query syntax (`from:alice has:attachment newer_than:7d`), read bodies, archive, star, compose. Runs **standalone in any terminal**.

```
┌─ gmail ───────────────────────────────────────────────────────────────┐
│ ▸1.inbox (24)  2.sent (50)  3.starred (12)  4.labels (37)  5.search   │
└───────────────────────────────────────────────────────────────────────┘
┌─ inbox (24) ──────────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ Alice                       │ │ Subject  Welcome to the team        │
│   Bob                         │ │ From     "Alice" <alice@ex.com>     │
│   GitHub                      │ │ Labels   INBOX, UNREAD              │
│   Stripe                      │ │ Body     Hi! Welcome aboard…        │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · Enter open · / search · c compose · D archive · ! star · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-msg-gmail mnml-msg-gmail
mnml-msg-gmail --install
```

## Auth setup (per-user, ~5 min)

Google **does not allow shared client IDs for Gmail scopes** the way Microsoft does for Azure CLI. Every user creates their own Google Cloud project + OAuth credentials. One-time setup.

1. **Create a project** at <https://console.cloud.google.com/projectcreate>.
2. **Enable Gmail API** at <https://console.cloud.google.com/apis/library/gmail.googleapis.com>.
3. **OAuth consent screen** — User Type: External. Fill in name + support email. **Keep in Testing mode** (see refresh-token note below).
4. **Add yourself as a Test user** (else sign-in fails with `403: access_denied`).
5. **Credentials → Create Credentials → OAuth client ID → Desktop app.** Copy Client ID + secret.
6. Export env vars:

   ```sh
   export GMAIL_CLIENT_ID=123456-abcdefg.apps.googleusercontent.com
   export GMAIL_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxxxxxxxxx
   ```

7. Run the loopback consent flow:

   ```sh
   mnml-msg-gmail auth
   ```

8. Verify:

   ```sh
   mnml-msg-gmail --check
   ```

### Refresh token expiry

Google enforces: **refresh tokens for "Testing" mode OAuth apps expire after 7 days.** Re-run `mnml-msg-gmail auth` weekly (~3 seconds end-to-end). Switching to Production requires Google verification review — weeks of review + privacy policy + demo video. Not worth it for a personal tool.

### Auth flow

Loopback redirect (RFC 8252). Binds `localhost:0`, opens browser to Google consent, catches redirect, exchanges code for access + refresh tokens. Persisted at `~/.config/mnml-msg-gmail/token.json` (mode 0600). Refresh silent on impending expiry + on `401`.

Scopes: `gmail.modify` + `gmail.send`.

## Subcommands

| Command | What it does |
|---|---|
| `mnml-msg-gmail` | Launch the TUI |
| `mnml-msg-gmail auth` | Run consent flow + persist token |
| `mnml-msg-gmail auth --logout` | Delete token cache |
| `mnml-msg-gmail --check` | Print env + token state + `/me/profile` probe |

## Config

`~/.config/mnml-msg-gmail/config.toml`:

```toml
refresh_interval_secs = 120

[[tabs]]
name = "inbox"
kind = "inbox"

[[tabs]]
name = "sent"
kind = "sent"

[[tabs]]
name = "starred"
kind = "starred"

[[tabs]]
name = "labels"
kind = "labels"

[[tabs]]
name = "search"
kind = "search"
```

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` | Open focused message (loads full body) / on `labels` — scope into that label |
| `o` | Open in Gmail web UI |
| `y` | Yank Gmail URL |
| `/` | Jump to search + start editing |
| `c` | Compose overlay (Tab cycles To → Subject → Body; `Ctrl+Enter` sends; Esc cancels) |
| `r` | Refresh |
| `D` | Archive focused (`y/n` confirm) |
| `!` | Toggle STARRED |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-msg-gmail
```

### Hosted as a mnml Pty pane

```vim
:term mnml-msg-gmail
```

Or `<leader>iG` after `mnml-msg-gmail --install`.

## Body rendering

Prefers `text/plain`; falls back to `text/html` with tag-strip + entity-decode (no full HTML parser).

## Source

[github.com/chris-mclennan/mnml-msg-gmail](https://github.com/chris-mclennan/mnml-msg-gmail). MIT.
