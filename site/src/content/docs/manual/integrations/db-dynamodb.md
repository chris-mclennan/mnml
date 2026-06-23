---
title: DynamoDB browser
description: mnml-db-dynamodb — a terminal browser for Amazon DynamoDB tables and items. Scan-based table browsing with focused-item JSON detail panel. First mnml-db-* sibling that uses the AWS CLI for auth instead of a vendor driver.
---

[`mnml-db-dynamodb`](https://github.com/chris-mclennan/mnml-db-dynamodb) is a terminal browser for Amazon DynamoDB — scan tables, inspect item JSON, yank entries. Runs **standalone in any terminal**.

Sibling to the existing `mnml-db-*` databases ([`mnml-db-postgres`](https://github.com/chris-mclennan/mnml-db-postgres), `-mariadb`, `-redshift`, `-clickhouse`, `-redis`, `-docdb`), but the first one that uses the `aws` CLI for auth instead of a vendor driver — same chain as the other AWS siblings.

```
┌─ dynamodb ───────────────────────────────────────────────────────┐
│ ▸1.Sessions (47)  2.Orders (50)  3.Events                        │
└──────────────────────────────────────────────────────────────────┘
┌─ Sessions · pk: userId / ts ─┐ ┌─ focused item ────────────────┐ │
│ ▸ user-abc · 1717685623      │ │ {                              │ │
│   user-abc · 1717685420      │ │   "userId": { "S": "abc" },    │ │
│   user-xyz · 1717684901      │ │   "ts": { "N": "1717685623" }, │ │
│   user-xyz · 1717684500      │ │   "device": { "S": "iOS" },    │ │
│   …                          │ │   "appVer": { "S": "4.2.1" }   │ │
│                              │ │ }                              │ │
└──────────────────────────────┘ └────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank JSON · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-db-dynamodb mnml-db-dynamodb
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured.

## Setup

1. **Verify the AWS CLI works.** `aws dynamodb list-tables` must succeed.
2. **Run once** to scaffold the config: `mnml-db-dynamodb`.
3. **Edit `~/.config/mnml-db-dynamodb.toml`** — add your tables.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings. This is the first `mnml-db-*` viewer that doesn't use a vendor driver; for AWS-native NoSQL the AWS CLI's credential resolution is the right path (env vars → shared credentials → SSO → IAM role).

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

[[tabs]]
name = "Sessions"
table = "user-sessions"
scan_limit = 50

[[tabs]]
name = "Orders"
table = "orders"
scan_limit = 100
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Tab strip label |
| `table` | yes | DynamoDB table name |
| `scan_limit` | no | Max items per scan (1..=1000, default 50) |
| `region` | no | Per-tab region override |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab item count badge
- **Items table (left, 45%):** `PRIMARY` column showing partition key (+ sort key if present), `FIELDS` column with a compact summary of the remaining attributes
- **Detail panel (right, 55%):** focused item's full JSON, pretty-printed
- **Status:** active table, scan count, key hints

The `PRIMARY` column is smart — on first scan, the sibling runs `describe-table` alongside `scan` to find the table's HASH + RANGE key fields, then renders those values in the PRIMARY column. No config required per table.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `o` | Open DynamoDB console for the active table |
| `y` | Yank focused item's pretty-printed JSON to clipboard |
| `r` | Refresh active tab (re-scan) |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-db-dynamodb
```

### Hosted as a mnml Pty pane

```vim
:term mnml-db-dynamodb
```

## Wire it into mnml's left rail

`mnml-db-dynamodb` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i d` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_dynamodb`.

## Status

**v0.1** — scan-based table browsing, focused-item JSON detail panel, console open, item JSON yank.

Held back for v0.2+:
- `query` instead of `scan` (partition-key-anchored lookups)
- Filter expression input (`FilterExpression`)
- Pagination — currently first `scan_limit` items only
- Item editing
- GSI / LSI browsing
- Stream tail (DynamoDB Streams → live item changes)

## Source

[github.com/chris-mclennan/mnml-db-dynamodb](https://github.com/chris-mclennan/mnml-db-dynamodb). MIT.
