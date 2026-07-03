---
title: Cloudflare CDN
description: mnml-cdn-cloudflare — a terminal browser for Cloudflare. List zones color-coded by status, browse DNS records per zone, Workers scripts, Pages projects, and security/firewall events. Cache purge + dev-mode toggle actions.
---

[`mnml-cdn-cloudflare`](https://github.com/chris-mclennan/mnml-cdn-cloudflare) is a terminal browser for [Cloudflare](https://www.cloudflare.com/). Zones, DNS records, Workers, Pages, security events — cache purge + dev-mode toggle actions. Talks to Cloudflare API v4 directly (no SDK dep). Runs **standalone in any terminal**.

```
┌─ cloudflare ─────────────────────────────────────────────────────────────┐
│ ▸1.Zones (12)  2.Workers (4)  3.Pages (3)  4.example.com DNS (28)        │
└──────────────────────────────────────────────────────────────────────────┘
┌─ zones (12) ───────────────────┐ ┌─ detail ──────────────────────────────┐
│ ▸ example.com                  │ │ Name             example.com          │
│   marketing.example.com        │ │ Status           active               │
│   docs.example.com             │ │ Plan             Pro                  │
│   api.example.com              │ │ Dev mode         off                  │
└────────────────────────────────┘ └───────────────────────────────────────┘
  1-9 tab · Enter/o dashboard · y ID · X purge · D dev-mode · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-cdn-cloudflare mnml-cdn-cloudflare
mnml-cdn-cloudflare --install
```

## Setup

Create an API token at dash.cloudflare.com → **My Profile → API Tokens → Create Token**. Start from the **"Edit zone DNS"** template + add:

- **Account:** `Workers Scripts: Read`, `Pages: Read` (for Workers / Pages tabs)
- **Zone:** `Zone: Read`, `DNS: Read` (Write for v0.2 edits), `Cache Purge: Edit`, `Zone Settings: Edit` (for dev-mode toggle)
- **Optional:** `User: User Details: Read` (lets `--check` print token owner email)

```sh
export CLOUDFLARE_API_TOKEN=...      # scoped token
export CLOUDFLARE_ACCOUNT_ID=...     # dash sidebar → Account ID (Workers/Pages tabs only)
mnml-cdn-cloudflare --check          # hits /user/tokens/verify
```

Use a **scoped token** — not the Global API Key (all-or-nothing).

## Config

`~/.config/mnml-cdn-cloudflare/config.toml` (scaffolded first run):

```toml
refresh_interval_secs = 60

[[tabs]]
name = "Zones"
kind = "zones"

# Per-zone DNS — set zone_id (yank via `y` on the Zones tab).
[[tabs]]
name = "example.com DNS"
kind = "dns"
zone_id = "abc123..."

[[tabs]]
name = "Workers"
kind = "workers"

[[tabs]]
name = "Pages"
kind = "pages"

[[tabs]]
name = "example.com WAF"
kind = "security_events"
zone_id = "abc123..."
```

### Tab kinds

| `kind` | What it shows | Required |
|---|---|---|
| `zones` | Every zone. Status: active green, pending yellow, suspended red. Plan + paused chips. | — |
| `dns` | DNS records for one zone. A/AAAA cyan, CNAME blue, MX yellow, TXT gray. Proxied=orange chip. | `zone_id` |
| `workers` | Worker scripts (name, last modified, usage model in detail). | `CLOUDFLARE_ACCOUNT_ID` |
| `pages` | Pages projects (primary domain, production branch, last deploy status). | `CLOUDFLARE_ACCOUNT_ID` |
| `security_events` | Recent firewall events (timestamp, client IP, action, source, rule). | `zone_id` |

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` / `o` | Open in Cloudflare dashboard |
| `y` | Yank focused item's ID (zone / record / script / project / ray) |
| `X` | **Purge cache** for the focused zone. `POST /zones/{id}/purge_cache` with `purge_everything: true`. Confirms `[y/n]`. |
| `D` | **Toggle dev mode.** `PATCH /zones/{id}/settings/development_mode`. |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-cdn-cloudflare
```

### Hosted as a mnml Pty pane

```vim
:term mnml-cdn-cloudflare
```

Or `<leader>iF` after `mnml-cdn-cloudflare --install`.

## Rate limits + pagination

Cloudflare's global REST limit: **1200 requests / 5 min** per token. TUI polls at `refresh_interval_secs` (60s default) per focused tab — well under.

v0.1 caps lists at 500 items; `(N+)` shown when truncated. Security events capped server-side at 100. Real cursor pagination is v0.2.

## Auth shape + error handling

Plain HTTP — `Authorization: Bearer <token>` to `https://api.cloudflare.com/client/v4/…`. Every response wrapped in `{"success": bool, "errors": [{code, message}], "result": ...}`. TUI unwraps `result` on success, surfaces first `errors[].message` on failure. 403s get an extra "token missing required scope" hint.

## Source

[github.com/chris-mclennan/mnml-cdn-cloudflare](https://github.com/chris-mclennan/mnml-cdn-cloudflare). MIT.
