---
title: AWS SNS viewer
description: mnml-aws-sns — a terminal browser for AWS SNS topics and per-topic subscription detail. Pairs with mnml-aws-sqs for the SNS → SQS fan-out pattern. Lazy per-topic attribute fetch keeps it fast on accounts with hundreds of topics. Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-sns`](https://github.com/chris-mclennan/mnml-aws-sns) is a terminal browser for AWS SNS — list every topic in a region, watch confirmed / pending subscription counts, drill into per-topic subscription detail (protocol, endpoint, status). Pairs naturally with [`mnml-aws-sqs`](/manual/integrations/aws-sqs/) for the canonical **SNS → SQS fan-out pattern**. Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol.

```
┌─ sns ─────────────────────────────────────────────────────────────────┐
│ ▸1.Topics (8)  2.orders subs (5)                                      │
└───────────────────────────────────────────────────────────────────────┘
┌─ topics (8) ──────────────────┐ ┌─ detail ────────────────────────────┐
│ ▸ orders-created  3 sub       │ │ Name                orders-created  │
│   orders-failed   2 sub · 1…⚠ │ │ Type                Standard        │
│   ses-bounces     4 sub       │ │ Display name        Orders Created  │
│   …                           │ │ Owner               111111111111    │
│                               │ │ Confirmed subs      3               │
│                               │ │ KMS key             alias/aws/sns   │
│                               │ │                                     │
│                               │ │  ARN                                │
│                               │ │  arn:aws:sns:us-east-1:…            │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank ARN · Y yank endpoint · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-sns --tag v0.1.0 mnml-aws-sns
```

## Setup

1. **Verify the AWS CLI works.** `aws sns list-topics --max-items 10` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-sns`.
3. **Edit `~/.config/mnml-aws-sns.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "Topics"
kind = "topics"

# Scope by name prefix —
[[tabs]]
name = "billing topics"
kind = "topics"
prefix = "billing-"

# Subscriptions to one specific topic —
[[tabs]]
name = "orders subs"
kind = "subscriptions"
topic_arn = "arn:aws:sns:us-east-1:111111111111:orders-created"
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `topics` (default) | Every SNS topic in the region (filterable by short-name `prefix`) | none |
| `subscriptions` | Subscriptions to `topic_arn` — protocol, endpoint, status | `topic_arn` |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):**
  - **Topics:** `<name>  <N confirmed> sub [· N pending][· FIFO]`. Color cues: loading → dim, topics with pending confirmations → yellow, normal → gray.
  - **Subscriptions:** `<protocol>  <endpoint>[  ⚠ pending confirmation]`. Endpoint ARNs (Lambda, SQS) trim to their tail segment for readability. Pending subs are yellow.
- **Detail panel (right, 55%):** focused item's full detail
  - **Topic:** name, type (FIFO/Standard), display name, owner, subscription counts (confirmed / pending / deleted — pending and deleted shown only when nonzero), KMS master key, signature version, delivery policy JSON, full ARN
  - **Subscription:** protocol, endpoint, confirmation status, owner, topic name, topic ARN, subscription ARN (only for confirmed subs)

Topic attributes are fetched lazily — only the focused topic pays the per-topic `get-topic-attributes` cost.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection — also triggers attribute fetch for the new focus |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open SNS v3 console for the focused topic (or the subscription's parent topic) |
| `y` | Yank — topic ARN for topics, subscription ARN for confirmed subs (pending subs report "no ARN yet") |
| `Y` | Yank endpoint — topic ARN for topics, subscription's endpoint (Lambda ARN, SQS ARN, email, URL) for subs |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

The `Y` (capital) yank on a subscription is the **destination** — paste straight into a config / IaC declaration.

## Two run modes

### Standalone

```sh
mnml-aws-sns
```

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-aws-sns
```

## Wire it into mnml's left rail

`mnml-aws-sns` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i N` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_sns`.

## Status

**v0.1** — topic list (paginated, with client-side name-prefix filter), lazy per-topic attribute fetch, per-topic subscription list, full detail panel for both kinds, console open, ARN yank, endpoint yank, pending-confirmation warning.

Held back for v0.2+:
- Publish-test-message action
- Cross-sibling handoff to `mnml-aws-sqs` for subscriptions with SQS endpoints — pick the subscribed queue, jump straight there
- Cross-sibling handoff to `mnml-aws-lambda` for subscriptions with Lambda endpoints
- Delete subscription action with confirm prompt
- Topic policy (resource-based access policy) pretty-printer

## Source

[github.com/chris-mclennan/mnml-aws-sns](https://github.com/chris-mclennan/mnml-aws-sns). MIT.
