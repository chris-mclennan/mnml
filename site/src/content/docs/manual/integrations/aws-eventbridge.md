---
title: AWS EventBridge viewer
description: mnml-aws-eventbridge — a terminal browser for AWS EventBridge buses and rules. List + focused-item detail (event pattern JSON, schedule expression, ARN). Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-eventbridge`](https://github.com/chris-mclennan/mnml-aws-eventbridge) is a terminal browser for AWS EventBridge — list event buses or rules-per-bus, inspect event patterns / schedules / state / targets, jump to the console. Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol.

```
┌─ eventbridge ─────────────────────────────────────────────────────────┐
│ ▸1.Buses (3)  2.Default rules (14)  3.Orders bus (4)                  │
└───────────────────────────────────────────────────────────────────────┘
┌─ rules · default (14) ────┐ ┌─ detail ────────────────────────────────┐
│ ▸ daily-cleanup           │ │ Name          daily-cleanup             │
│   ENABLED · rate(1 day)   │ │ State         ENABLED                   │
│   order-created           │ │ Bus           default                   │
│   ENABLED                 │ │ Schedule      rate(1 day)               │
│   payment-completed       │ │                                         │
│   ENABLED                 │ │  ARN                                    │
│   …                       │ │  arn:aws:events:us-east-1:…             │
│                           │ │  Description                            │
│                           │ │  Nightly cleanup job                    │
└───────────────────────────┘ └─────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank ARN · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-eventbridge mnml-aws-eventbridge
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured.

## Setup

1. **Verify the AWS CLI works.** `aws events list-event-buses` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-eventbridge`.
3. **Edit `~/.config/mnml-aws-eventbridge.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "Buses"
kind = "buses"

[[tabs]]
name = "Default rules"
kind = "rules"
event_bus_name = "default"

[[tabs]]
name = "Orders bus"
kind = "rules"
event_bus_name = "orders-events"
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `buses` (default) | Every event bus in the region | none |
| `rules` | Rules on `event_bus_name`. Use `"default"` for the account-wide default bus | `event_bus_name` |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):** name + state / schedule (rules) or "event bus" (buses)
- **Detail panel (right, 55%):** focused item's full detail
  - **Bus:** name, created, last-modified, ARN, optional resource policy JSON
  - **Rule:** name, state, bus, schedule expression, role, managed-by, ARN, description, event pattern JSON
- **Status:** active count, key hints

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open EventBridge console for the focused item |
| `y` | Yank focused item's ARN to clipboard |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-aws-eventbridge
```

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-aws-eventbridge
```

## Wire it into mnml's left rail

`mnml-aws-eventbridge` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i e` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_eventbridge`.

## Status

**v0.1** — buses list, rules-per-bus list (paginated), focused-item detail panel, console open, ARN yank.

Held back for v0.2+:
- Targets list per rule (`list-targets-by-rule` per focused rule)
- Schedules tab (EventBridge Scheduler — separate service)
- Archives + replays tab
- Test event sender (`put-events`)
- Rule enable/disable toggle
- Rule state filter (ENABLED-only / DISABLED-only / managed-by-aws)

## Source

[github.com/chris-mclennan/mnml-aws-eventbridge](https://github.com/chris-mclennan/mnml-aws-eventbridge). MIT.
