---
title: AWS ECS viewer
description: mnml-aws-ecs — a terminal browser for AWS ECS clusters and services. Two-tab kind (clusters / services-per-cluster) with task count + deployment rollout state + recent service events. Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-ecs`](https://github.com/chris-mclennan/mnml-aws-ecs) is a terminal browser for AWS ECS — list every cluster, list services-within-a-cluster, watch running/desired task counts, drill into recent deployment rollout state + the last few service events. Runs **standalone in any terminal**.

```
┌─ ecs ─────────────────────────────────────────────────────────────────┐
│ ▸1.Clusters (3)  2.prod services (8)                                  │
└───────────────────────────────────────────────────────────────────────┘
┌─ services · prod (8) ─────────┐ ┌─ detail ────────────────────────────┐
│ ▸ api          ACTIVE · 3/3   │ │ Name           api                  │
│   ingest      ACTIVE · 2/2    │ │ Status         ACTIVE               │
│   worker      ACTIVE · 5/5    │ │ Tasks          3/3                  │
│                               │ │ Task def       api:42               │
│                               │ │ Launch type    FARGATE              │
│                               │ │                                     │
│                               │ │  Deployments (1)                    │
│                               │ │  PRIMARY    api:42      3/3         │
│                               │ │                                     │
│                               │ │  Recent events                      │
│                               │ │  2026-06-06 18:30:00  steady state. │
│                               │ │  2026-06-06 18:25:11  task ec2-… …  │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank ARN · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-ecs --tag v0.1.0 mnml-aws-ecs
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured.

## Setup

1. **Verify the AWS CLI works.** `aws ecs list-clusters` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-ecs`.
3. **Edit `~/.config/mnml-aws-ecs.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "Clusters"
kind = "clusters"

[[tabs]]
name = "prod services"
kind = "services"
cluster = "prod-cluster"
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `clusters` (default) | Every ECS cluster in the region — services count, running tasks, capacity providers | none |
| `services` | Services within `cluster` — task counts, task def revision, deployments, events | `cluster` |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):** name + `status · counts`. Color cues for fast scanning:
  - **Failed rollout** red — catches deployments whose `rolloutState` is `FAILED`
  - **In-progress rollout** yellow — `IN_PROGRESS` deployments
  - `DRAINING` clusters yellow, `INACTIVE` clusters dim gray
- **Detail panel (right, 55%):** focused item's full detail
  - **Cluster:** name, status, active services, running tasks, pending tasks (when > 0), EC2 instances (when > 0), capacity providers, ARN
  - **Service:** name, status, task counts (running/desired with pending if any), task definition short form (`family:revision`), launch type, platform version, created, **deployments** (top 3, rollout-state colored — green COMPLETED, yellow IN_PROGRESS, red FAILED), **recent events** (last 5, timestamp + truncated message), ARN

The recent-events section is the actionable bit: when a deployment stalls, the events list usually has a `failed task placement` or `target group health check` line explaining why.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open ECS v2 console for the focused item |
| `y` | Yank focused item's ARN to clipboard |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-aws-ecs
```

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-ecs
```

## Wire it into mnml's left rail

`mnml-aws-ecs` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i C` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_ecs`.

## Status

**v0.1** — clusters + services-per-cluster list (both paginated), focused-item detail panel with deployment rollout state + recent events, console open, ARN yank.

Held back for v0.2+:
- Task list per service (`list-tasks` + `describe-tasks`) — current running tasks with their container statuses
- Cross-sibling handoff to `mnml-aws-cloudwatch-logs` for the service's awslogs log group
- ECS Exec command to drop into a running container (`aws ecs execute-command`)
- Task definition pretty-printer + revision diff
- Force new deployment button (`update-service --force-new-deployment`)
- Auto-Scaling target tracking display

## Source

[github.com/chris-mclennan/mnml-aws-ecs](https://github.com/chris-mclennan/mnml-aws-ecs). MIT.
