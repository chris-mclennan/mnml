---
title: Datadog observability
description: mnml-obs-datadog — a terminal browser for Datadog. Monitors color-coded by alert state, dashboards, live-tail logs, open incidents. Cross-sibling handoff to mnml-aws-cloudwatch-logs for AWS-log-group monitors.
---

[`mnml-obs-datadog`](https://github.com/chris-mclennan/mnml-obs-datadog) is a terminal browser for [Datadog](https://www.datadoghq.com/). Monitors color-coded by alert state, dashboards, live-tail logs against a custom query, open incidents. Cross-sibling handoff to `mnml-aws-cloudwatch-logs` when a monitor query references an AWS log group. Runs **standalone in any terminal**.

```
┌─ datadog ─────────────────────────────────────────────────────────────┐
│ ▸1.Monitors (37)  2.Dashboards (84)  3.API errors (12)  4.Incidents (2)│
└───────────────────────────────────────────────────────────────────────┘
┌─ monitors (37) ───────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ api 5xx rate                │ │ Name             api 5xx rate       │
│   db connection saturation    │ │ State            Alert              │
│   queue backlog               │ │ Query            avg(last_5m):sum:…│
│   high cpu — i-aabbccdd       │ │                                     │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · Enter/o console · y URL · L → cloudwatch-logs · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-obs-datadog mnml-obs-datadog
mnml-obs-datadog --install
```

## Setup

Datadog uses two keys: an API key (org-scope) + an application key (user-scope).

```sh
export DD_API_KEY=...            # Org Settings → API Keys
export DD_APP_KEY=...            # Org Settings → Application Keys
export DD_SITE=datadoghq.com     # default; override for EU / US3 / US5 / AP1 / Gov
mnml-obs-datadog --check
```

**Auth shape:** plain HTTP — `DD-API-KEY` + `DD-APPLICATION-KEY` headers to `https://api.{DD_SITE}/api/{v1,v2}/…`. No SDK dep.

## Config

`~/.config/mnml-obs-datadog/config.toml` (scaffolded first run):

```toml
refresh_interval_secs = 60

[[tabs]]
name = "Monitors"
kind = "monitors"

# Scope monitors by tag
[[tabs]]
name = "api alerts"
kind = "monitors"
query = "tag:service:api"

[[tabs]]
name = "Dashboards"
kind = "dashboards"

# Title-prefix filter
[[tabs]]
name = "API dashboards"
kind = "dashboards"
query = "API"

# Live-tail logs (Datadog log search syntax; polls every tail_interval_secs)
[[tabs]]
name = "API errors"
kind = "logs"
query = "service:api status:error"
from = "now-15m"
tail_interval_secs = 5

[[tabs]]
name = "Incidents"
kind = "incidents"
```

### Tab kinds

| `kind` | What it shows | Required |
|---|---|---|
| `monitors` | Every monitor sorted Alert → Warn → No Data → OK. `query` = tag scope. | — |
| `dashboards` | Every dashboard. `query` = title-prefix filter. | — |
| `logs` | Live-tail matching Datadog log search syntax. | `query` |
| `incidents` | Open (state=active) incidents. | — |

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` / `o` | Open in Datadog web UI (monitor / dashboard / incident / Logs Explorer pre-scoped) |
| `y` | Yank web URL, or log message body for log events |
| `L` | **Cross-sibling jump** — on a monitor whose query references an AWS log group (`aws_log_group:` tag or `/aws/…` path), launches `mnml-aws-cloudwatch-logs --log-group <group>` |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-obs-datadog
```

### Hosted as a mnml Pty pane

```vim
:term mnml-obs-datadog
```

Or `<leader>iD` after `mnml-obs-datadog --install`.

## Pagination

v0.1 caps lists at **500 items**. When capped, tab badge shows `(N+)`. Real cursor pagination is v0.2.

## Source

[github.com/chris-mclennan/mnml-obs-datadog](https://github.com/chris-mclennan/mnml-obs-datadog). MIT.
