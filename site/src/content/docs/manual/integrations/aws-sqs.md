---
title: AWS SQS viewer
description: mnml-aws-sqs — a terminal browser for AWS SQS queues with approximate message counts, retention, visibility timeout, redrive policy. Lazy per-queue attribute fetch keeps it fast on accounts with hundreds of queues. Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-sqs`](https://github.com/chris-mclennan/mnml-aws-sqs) is a terminal browser for AWS SQS — list every queue in a region, watch approximate message counts at a glance, drill into the focused queue's full attributes (visibility timeout, retention period, redrive policy / DLQ wiring, etc.), yank the queue URL or ARN in one keystroke. Pairs naturally with [`mnml-aws-eventbridge`](/manual/integrations/aws-eventbridge/) — events fan out to SQS queues, you'll find yourself flipping between the two. Runs **standalone in any terminal**.

```
┌─ sqs ─────────────────────────────────────────────────────────────────┐
│ ▸1.All queues (12)  2.ingest queues (4)                               │
└───────────────────────────────────────────────────────────────────────┘
┌─ queues (12) ─────────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ events             42 msg…  │ │ Name                  events       │
│   events.fifo  0 msg · FIFO   │ │ Type                  Standard     │
│   ingest-emails  3 msg · DLQ  │ │                                    │
│   ingest-jobs       1.2k msg…⚠│ │  Backlog                           │
│   …                           │ │  ApproxNumMessages     42          │
│                               │ │  ApproxNotVisible      3           │
│                               │ │                                    │
│                               │ │  Config                            │
│                               │ │  VisibilityTimeout    30s          │
│                               │ │  MessageRetention     14d          │
│                               │ │  ReceiveWait          20s          │
│                               │ │                                    │
│                               │ │  ARN                               │
│                               │ │  arn:aws:sqs:us-east-1:…           │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank URL · Y yank ARN · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-sqs --tag v0.1.0 mnml-aws-sqs
```

## Setup

1. **Verify the AWS CLI works.** `aws sqs list-queues --max-results 10` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-sqs`.
3. **Edit `~/.config/mnml-aws-sqs.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "All queues"
kind = "all"

[[tabs]]
name = "ingest queues"
kind = "prefix"
prefix = "ingest-"
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `all` (default) | Every queue in the region | none |
| `prefix` | Queues whose name starts with `prefix` — useful for scoping to one app's queues in a shared account | `prefix` |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):** `<queue name>  <visible> msg · <in-flight> in-flight [· N delayed][· FIFO][· DLQ]`. Color cues:
  - Loading attributes → dim gray
  - Normal traffic → gray
  - **Backlog warning** (>1000 visible OR >100 in-flight) → yellow, surfaces queues falling behind at a glance
- **Detail panel (right, 55%):** focused queue's full detail, lazy-loaded on cursor move:
  - **Backlog:** ApproxNumMessages / ApproxNotVisible / ApproxDelayed (only shown when nonzero)
  - **Config:** VisibilityTimeout, MessageRetention, DelaySeconds, ReceiveWait, MaxMessageSize, Created, LastModified — all durations humanised (`60s` → `1m`, `1209600` → `14d`)
  - **Redrive policy (DLQ):** raw JSON when present — shows what DLQ + max-receive-count are configured
  - **ARN:** at the bottom for copy reference

Attributes are fetched lazily — only the focused queue pays the per-queue `get-queue-attributes` cost. An account with hundreds of queues opens fast.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection — also triggers attribute fetch for the new focus |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open SQS v3 console for the focused queue |
| `y` | Yank queue URL — the input to `aws sqs send-message --queue-url $(pbpaste)` |
| `Y` | Yank queue ARN (only after attributes have loaded) |
| `r` | Refresh active tab (re-runs `list-queues` + refreshes focused attributes) |
| `q` / `Esc` / `Ctrl+C` | Quit |

The URL yank is what you'll use most — it's the input shape for the `aws sqs send-message` / `receive-message` / `purge-queue` commands.

## Two run modes

### Standalone

```sh
mnml-aws-sqs
```

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-sqs
```

## Wire it into mnml's left rail

`mnml-aws-sqs` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i q` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_sqs`.

## Status

**v0.1** — queue list (paginated, `all` and `prefix` tab kinds), lazy per-queue attribute fetch, full detail panel with backlog / config / redrive-policy / ARN, console open, URL yank, ARN yank, backlog-warning color cue.

Held back for v0.2+:
- DLQ correlation — mark queues that are *referenced* as the DLQ for another queue (currently we only mark queues that *have* a DLQ via RedrivePolicy)
- Message peek (`receive-message` with VisibilityTimeout=0) for the focused queue
- Purge queue action with confirm prompt
- Cross-sibling handoff from `mnml-aws-eventbridge` — pick a target SQS queue, jump straight here
- Send-test-message action

## Source

[github.com/chris-mclennan/mnml-aws-sqs](https://github.com/chris-mclennan/mnml-aws-sqs). MIT.
