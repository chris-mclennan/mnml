---
title: Buttondown newsletter
description: mnml-msg-buttondown — a terminal browser for the Buttondown newsletter platform. List drafts, browse sent issues with open/click stats, peek the scheduled queue, and manage subscribers.
---

[`mnml-msg-buttondown`](https://github.com/chris-mclennan/mnml-msg-buttondown) is a terminal browser for [Buttondown](https://buttondown.email/). List drafts, browse sent newsletters with per-issue open + click stats, peek the scheduled queue, and manage subscribers. Runs **standalone in any terminal**.

```
┌─ buttondown ──────────────────────────────────────────────────────────┐
│ ▸1.drafts (3)  2.sent (47)  3.scheduled (1)  4.subscribers (1248+)    │
└───────────────────────────────────────────────────────────────────────┘
┌─ drafts (3) ──────────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ Issue #48 — half-baked      │ │ Subject     Issue #48 — half-baked  │
│   Reply to last week          │ │ Status      draft                   │
│   Untitled scratch            │ │ Created     2026-06-05T00:00:00Z    │
│                               │ │ Word count  812                     │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · Enter open · y ID · p publish · X unsubscribe · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-msg-buttondown mnml-msg-buttondown
mnml-msg-buttondown --install
```

## Setup

Buttondown uses a single API key.

```sh
export BUTTONDOWN_API_KEY=...   # Settings → Programming
mnml-msg-buttondown --check     # verify env + config
```

The API key grants full newsletter access — read, schedule, delete subscribers. Treat like a password. The TUI never logs the key; `--check` shows length + last 4 chars only.

## Config

`~/.config/mnml-msg-buttondown/config.toml` (scaffolded first run):

```toml
refresh_interval_secs = 60

[[tabs]]
name = "drafts"
kind = "drafts"

[[tabs]]
name = "sent"
kind = "sent"

[[tabs]]
name = "scheduled"
kind = "scheduled"

[[tabs]]
name = "subscribers"
kind = "subscribers"
```

### Tab kinds

| `kind` | What it shows |
|---|---|
| `drafts` | Unsent drafts. `p` schedules the focused draft 5 min from now (v0.2 will add a picker). |
| `sent` | Already-shipped emails with open / click counts when reported. |
| `scheduled` | Emails queued for a future send. |
| `subscribers` | Every subscriber, color-coded by type. `X` unsubscribes the focused one. |

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` / `o` | Open in Buttondown web UI |
| `y` | Yank the focused item's id |
| `p` | **Publish draft** (drafts tab). `PATCH /emails/{id}` → `status=scheduled`, `publish_date=+5m`. Confirms `[y/n]`. |
| `X` | **Unsubscribe** (subscribers tab). `DELETE /subscribers/{id}`. Confirms `[y/n]`. |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-msg-buttondown
```

### Hosted as a mnml Pty pane

```vim
:term mnml-msg-buttondown
```

Or `<leader>iB` after `mnml-msg-buttondown --install`.

## Errors + rate limits

- 4xx surfaces as `buttondown: <detail>` verbatim from Buttondown's error body.
- Buttondown allows ~600 req/min; TUI never auto-retries `429` — refresh manually with `r`.

## Pagination

v0.1 fetches page 1 only (Buttondown default is 100 per page). When more results exist, the tab badge shows `(N+)`. Real pagination is v0.2.

## Source

[github.com/chris-mclennan/mnml-msg-buttondown](https://github.com/chris-mclennan/mnml-msg-buttondown). MIT.
