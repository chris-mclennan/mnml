---
title: Slack browse + post
description: mnml-msg-slack — a terminal Slack client for browsing channels + DMs, previewing recent messages, running search.messages, posting messages, replying in threads, and reacting with quick-pick emojis. The first messaging sibling in the mnml family.
---

[`mnml-msg-slack`](https://github.com/chris-mclennan/mnml-msg-slack) is a terminal browse + post client for Slack. List your channels + DMs, peek the latest 30 messages in any channel, run interactive search, post messages, reply in threads, react with a quick-pick of common emojis, and copy permalinks to the clipboard. Runs **standalone in any terminal**.

```
┌─ slack — Acme ───────────────────────────────────────────────────────────┐
│ ▸1.channels (37)  2.dms (12)  3.search (0)  4.threads                    │
└──────────────────────────────────────────────────────────────────────────┘
┌─ channels (37) ───────────────┐ ┌─ #general ──────────────────────────┐
│ ▸ #general                    │ │ 09:14:22 chrism        morning team │
│   #announcements              │ │ 09:18:01 alice         heads up...  │
│   #eng-platform               │ │ 09:24:33 bob           ↳3 thread    │
│   #random                     │ │ 09:42:11 carol         shipped 1.2  │
└───────────────────────────────┘ └─────────────────────────────────────┘
 1-9 tab · Enter open · / search · p post · R react · T thread · y permalink · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-msg-slack mnml-msg-slack
mnml-msg-slack --install
```

## Setup

Slack tokens live behind app creation. Five steps:

1. Visit **<https://api.slack.com/apps>** → **Create New App → From scratch**. Pick a workspace.
2. **OAuth & Permissions** → **Scopes → User Token Scopes**. Add:

   `channels:read` · `channels:history` · `groups:read` · `groups:history` · `im:read` · `im:history` · `mpim:read` · `mpim:history` · `search:read` · `chat:write` · `reactions:read` · `reactions:write` · `users:read`

3. **OAuth Tokens for Your Workspace → Install to Workspace**. Approve.
4. Copy the **User OAuth Token** (starts with `xoxp-…`).
5. Export + verify:

   ```sh
   export SLACK_USER_TOKEN=xoxp-...
   mnml-msg-slack --check
   ```

`SLACK_BOT_TOKEN` (xoxb-…) is a fallback but `search.messages` requires the user token.

## Config

`~/.config/mnml-msg-slack/config.toml` (scaffolded on first run):

```toml
refresh_interval_secs = 60
post_multiline = false

[[tabs]]
name = "channels"
kind = "channels"

[[tabs]]
name = "dms"
kind = "dms"

[[tabs]]
name = "search"
kind = "search"
```

### Tab kinds

| `kind` | What it shows |
|---|---|
| `channels` | Public + private channels you're a member of |
| `dms` | 1:1 DMs + multi-person group DMs |
| `search` | Interactive `search.messages` query (`/` to enter) |
| `threads` | v0.2 stub — will surface unread thread replies |

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn`, `g` / `G` | Jump 10 rows / top / bottom |
| `Enter` | Open channel / thread |
| `/` | Search input (Enter = submit, Esc = cancel) |
| `p` | Post — type + Enter sends `chat.postMessage` |
| `R` | Reaction picker (12 quick emojis; `←→` pick, Enter react) |
| `T` | Thread reply — same as `p` with `thread_ts` set |
| `y` | Yank permalink for the focused message |
| `r` | Force-refresh (bypasses the 5-min conversation-list cache) |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-msg-slack
```

### Hosted as a mnml Pty pane

```vim
:term mnml-msg-slack
```

Or `<leader>iS` after `mnml-msg-slack --install`.

## Caching + rate limits

- `conversations.list` cached in-memory for 5 minutes; `r` forces refresh.
- User-id → name lookups cached per session (lazy on first sight).
- On HTTP 429, status bar shows `slack: rate-limited, retry in Ns` (from `Retry-After`). v0.1 does not auto-retry.

## Security

The user token (`xoxp-…`) has broad access — treat it like a password. Store in a keychain, not a dotfile. Revoke unused tokens at api.slack.com → your app → **OAuth & Permissions → Revoke Tokens**.

## Source

[github.com/chris-mclennan/mnml-msg-slack](https://github.com/chris-mclennan/mnml-msg-slack). MIT.
