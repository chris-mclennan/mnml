---
title: Microsoft Teams browse + post
description: mnml-msg-teams — a terminal browser + composer for Microsoft Teams. List joined teams and their channels, walk your chats, search messages, and post / reply / react. Uses Microsoft Graph with device-code OAuth (the same flow `az login` uses).
---

[`mnml-msg-teams`](https://github.com/chris-mclennan/mnml-msg-teams) is a terminal browser + composer for Microsoft Teams. List joined teams + channels, walk chats, search messages across Teams, and post / reply / react without leaving the keyboard. Runs **standalone in any terminal**.

```
┌─ teams ───────────────────────────────────────────────────────────────┐
│ ▸1.teams (4)  2.chats (12)  3.search (0)  4.threads (0)               │
└───────────────────────────────────────────────────────────────────────┘
┌─ teams (4) ────────────────────┐ ┌─ channel ──────────────────────────┐
│ ▸ ▾ Engineering                │ │  06-07 10:14 · Alice               │
│     ▸ General                  │ │     ship it                        │
│     ▸ Frontend                 │ │  06-07 10:16 · Bob                 │
│   ▸ Design                     │ │     LGTM                           │
│   ▸ Operations                 │ │     [👍 3] [❤ 1]                   │
└────────────────────────────────┘ └────────────────────────────────────┘
  1-9 tab · Enter open · / search · p post · R react · T thread · y permalink · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-msg-teams mnml-msg-teams
mnml-msg-teams --install
```

## Auth

Microsoft Graph requires OAuth 2.0 — no "paste an API key" path. Uses the **device-code flow** (same as `az login`).

```sh
mnml-msg-teams auth
```

Prints a verification URL + one-time code, opens your browser, polls until you authenticate.

**How Microsoft trusts us:** ships with the public Azure CLI client ID (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) — same one `az` uses. Consent screen reads "Microsoft Azure CLI" (honest cost of not registering our own multi-tenant app).

**Scopes requested:** `User.Read`, `ChatMessage.Read/Send`, `ChannelMessage.Read.All/Send`, `Channel.ReadBasic.All`, `Team.ReadBasic.All`, `Chat.Read/ReadWrite`, `offline_access`.

**Token storage:** `~/.config/mnml-msg-teams/token.json` (mode 0600). Access-token (~1h TTL) + refresh-token (~90d) + expiry. Proactive refresh on impending expiry; `401` triggers one-shot retry.

Revoke locally: `mnml-msg-teams auth --logout`.

## Config

`~/.config/mnml-msg-teams/config.toml` (scaffolded on first run):

```toml
refresh_interval_secs = 60

[[tabs]]
name = "teams"
kind = "teams"

[[tabs]]
name = "chats"
kind = "chats"

[[tabs]]
name = "search"
kind = "search"
```

### Tab kinds

| `kind` | What it shows |
|---|---|
| `teams` | Joined teams (`/me/joinedTeams`). Enter expands channels (lazy). |
| `chats` | 1:1 + group chats, newest first. |
| `search` | `/` to enter a query; runs `POST /search/query` over `chatMessage`. |
| `threads` | v0.2 stub — focused-thread view. |

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` | Expand team channels · focus channel/chat · open search hit's permalink |
| `/` | Search input (search tab only) |
| `p` | Post — `Ctrl+S` sends, `Esc` cancels |
| `T` | Threaded reply to the top-of-scrollback message |
| `R` | React 👍 (v0.1 direct; picker in v0.2) |
| `y` | Yank permalink / URL / `team:<id>` / `chat:<id>` |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-msg-teams
```

### Hosted as a mnml Pty pane

```vim
:term mnml-msg-teams
```

Or `<leader>iT` after `mnml-msg-teams --install`.

## Error handling

- Graph errors surface as `graph: {code}: {msg}`.
- `429` shows `Retry-After` when present; no auto-retry.
- `401 InvalidAuthenticationToken` triggers one-shot refresh + retry.

## Security

The persisted token grants whatever Graph access you consented to. Treat `~/.config/mnml-msg-teams/token.json` like a password. Mode 0600 by default. `auth --logout` deletes it.

## Source

[github.com/chris-mclennan/mnml-msg-teams](https://github.com/chris-mclennan/mnml-msg-teams). MIT.
