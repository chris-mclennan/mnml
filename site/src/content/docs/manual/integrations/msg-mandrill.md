---
title: Mandrill transactional email
description: mnml-msg-mandrill — a terminal browser for Mandrill (Mailchimp Transactional). List recent sends color-coded by delivery state, browse templates, inspect tag stats with bounce-rate cues, and audit webhooks.
---

[`mnml-msg-mandrill`](https://github.com/chris-mclennan/mnml-msg-mandrill) is a terminal browser for [Mandrill](https://mandrillapp.com/) (Mailchimp Transactional). List recent transactional sends color-coded by delivery state, browse templates by publish state, inspect tag stats with bounce-rate cues, and audit webhooks. Runs **standalone in any terminal**.

```
┌─ mandrill ────────────────────────────────────────────────────────────┐
│ ▸1.messages (87)  2.templates (12)  3.tags (24)  4.webhooks (3)        │
└───────────────────────────────────────────────────────────────────────┘
┌─ messages (87) ───────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ Welcome aboard              │ │ State            delivered          │
│   Password reset              │ │ To               user@example.com   │
│   Order #4421 confirmed       │ │ From             noreply@example.com│
│   You have 3 new reviews      │ │ Opens            2                  │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · Enter/o web · y ID · L event log → $PAGER · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-msg-mandrill mnml-msg-mandrill
mnml-msg-mandrill --install
```

## Setup

Mandrill uses a single API key per app.

```sh
export MANDRILL_API_KEY=...   # Settings → SMTP & API Info → API Keys
mnml-msg-mandrill --check     # hits /users/ping.json
```

Prefer a **read-only key** — every v0.1 endpoint is read-only.

**Auth shape:** plain HTTP `POST` to `https://mandrillapp.com/api/1.0/<resource>/<verb>.json`, key sent in the request body (not a header). No SDK dep.

## Config

`~/.config/mnml-msg-mandrill/config.toml` (scaffolded first run):

```toml
refresh_interval_secs   = 60
messages_lookback_days  = 14

[[tabs]]
name = "messages"
kind = "messages"

[[tabs]]
name = "templates"
kind = "templates"

[[tabs]]
name = "tags"
kind = "tags"

[[tabs]]
name = "webhooks"
kind = "webhooks"
```

### Tab kinds

| `kind` | What it shows |
|---|---|
| `messages` | Recent sends over `messages_lookback_days`, newest first. Color: `delivered` green · `queued`/`scheduled`/`deferred` yellow · `bounced`/`rejected`/`spam` red · `sent` gray. |
| `templates` | Every template + publish state. Published green, draft gray. |
| `tags` | Tag stats + derived bounce rate. Bounce ≥5% red, ≥2% yellow. |
| `webhooks` | Every webhook + subscribed events. Webhooks with `last_error` set are red. |

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` / `o` | Open in Mandrill web UI (message activity · template code · tag stats · webhooks settings) |
| `y` | Yank — message ID · template slug · tag name · webhook URL |
| `L` | (messages) Render full event log (SMTP events, opens, clicks) into `$TMPDIR` + open in `$PAGER` |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-msg-mandrill
```

### Hosted as a mnml Pty pane

```vim
:term mnml-msg-mandrill
```

Or `<leader>iM` after `mnml-msg-mandrill --install`.

## Pagination

v0.1 caps lists at **500 items** (fetching 100/page for messages). When capped, tab badge shows `(N+)`. Real cursor pagination is v0.2.

## Security

The API key has full read access (and, on a non-read-only key, full **send** access) to your transactional email. Protect `MANDRILL_API_KEY` like a password. Prefer a read-only key. Never commit it — this binary only reads it from env.

## Source

[github.com/chris-mclennan/mnml-msg-mandrill](https://github.com/chris-mclennan/mnml-msg-mandrill). MIT.
