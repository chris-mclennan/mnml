---
title: AWS RDS viewer
description: mnml-aws-rds — a terminal browser for AWS RDS DB instances and Aurora clusters. List + focused-item detail (engine, status, endpoint, storage). Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-rds`](https://github.com/chris-mclennan/mnml-aws-rds) is a terminal browser for AWS RDS — list every DB instance or Aurora cluster in a region, inspect engine / status / endpoint / storage detail, yank the endpoint for a `psql` invocation in one keystroke. Runs **standalone in any terminal**.

```
┌─ rds ─────────────────────────────────────────────────────────────────┐
│ ▸1.Instances (8)  2.Clusters (3)                                      │
└───────────────────────────────────────────────────────────────────────┘
┌─ db instances (8) ────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ prod-postgres  postgres · ⬤│ │ Identifier   prod-postgres          │
│   prod-readonly  postgres · ⬤│ │ Engine       postgres 16.4          │
│   stage-postgres postgres · ⬤│ │ Class        db.r6g.xlarge          │
│   thumb-cache    mysql · ⬤   │ │ Status       available              │
│   …                           │ │ Endpoint     prod.…:5432            │
│                               │ │ Storage      200 GB · gp3           │
│                               │ │ Multi-AZ     true                   │
│                               │ │ Master user  admin                  │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank ARN · E yank endpoint · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-rds --tag v0.1.0 mnml-aws-rds
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured.

## Setup

1. **Verify the AWS CLI works.** `aws rds describe-db-instances` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-rds`.
3. **Edit `~/.config/mnml-aws-rds.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "Instances"
kind = "instances"

[[tabs]]
name = "Clusters"
kind = "clusters"
```

### Tab kinds

| `kind` | What it shows |
|---|---|
| `instances` (default) | Every RDS DB instance in the region (Postgres / MySQL / MariaDB / Oracle / SQL Server) |
| `clusters` | Every Aurora cluster (DB Cluster identifier) — Postgres or MySQL |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):** identifier + `engine · status`. Status color cues: `available` gray, anything `*ing` (creating/modifying) yellow, `stopped`/`inaccessible` red.
- **Detail panel (right, 55%):** focused item's full detail
  - **Instance:** identifier, engine + version, instance class, status, endpoint host:port, storage size + type, multi-AZ, AZ, public/private flag, master username, cluster membership, created, ARN
  - **Cluster:** identifier, engine + version, mode (provisioned/serverless), status, writer/reader endpoints, database name, multi-AZ, master username, allocated storage, created, ARN

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open RDS console for the focused item |
| `y` | Yank focused item's ARN to clipboard |
| `E` | Yank focused item's endpoint (host:port) — drops into `psql` / `mysql` / `redis-cli` invocations |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

### `E` — the endpoint yank

Pressing `E` on a focused DB copies `<host>:<port>` to your clipboard. Pipes naturally into shell tooling:

```sh
psql -h $(pbpaste | cut -d: -f1) -p $(pbpaste | cut -d: -f2) -U admin -d mydb
```

Or just paste the host into your secrets manager / IaC config and move on. Less convenient than the eventual `mnml-db-postgres` cross-sibling handoff (planned for v0.2 — `E`+Enter spawns a psql session in a pty) but enough to skip an AWS Console tab.

## Two run modes

### Standalone

```sh
mnml-aws-rds
```

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-rds
```

## Wire it into mnml's left rail

`mnml-aws-rds` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i R` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_rds`.

## Status

**v0.1** — list (paginated) DB instances + Aurora clusters, focused-item detail panel, console open, ARN yank, endpoint yank.

Held back for v0.2+:
- Snapshot list per instance/cluster (`describe-db-snapshots`)
- Tag display in detail panel
- Cross-sibling handoff: `mnml-aws-cloudwatch-logs --log-group /aws/rds/instance/<id>/postgresql` (Postgres) / `/aws/rds/instance/<id>/error` (MySQL)
- Cross-sibling handoff: `mnml-db-postgres` / `mnml-db-mysql` session against the focused endpoint
- Failover button for Aurora clusters
- Parameter group + option group browsing

## Source

[github.com/chris-mclennan/mnml-aws-rds](https://github.com/chris-mclennan/mnml-aws-rds). MIT.
