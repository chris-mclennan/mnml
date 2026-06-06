---
title: AWS Lambda viewer
description: mnml-aws-lambda — a terminal browser for AWS Lambda functions. List + focused-function detail panel (runtime, memory, timeout, handler, ARN). Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-lambda`](https://github.com/chris-mclennan/mnml-aws-lambda) is a terminal browser for AWS Lambda — list every function in a region (or watch a hand-picked set), inspect runtime / memory / timeout / handler, open the console, yank an ARN. Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol.

```
┌─ lambda ──────────────────────────────────────────────────────────────┐
│ ▸1.All (42)  2.Watched (5)                                            │
└───────────────────────────────────────────────────────────────────────┘
┌─ functions (42) ──────────┐ ┌─ detail ────────────────────────────────┐
│ ▸ api-handler   nodejs20.x│ │ Name          api-handler               │
│   ingest-worker python3.12│ │ Runtime       nodejs20.x                │
│   ses-bouncer   python3.11│ │ Handler       index.handler             │
│   thumb-gen     go1.x     │ │ Memory        512 MB                    │
│   …                       │ │ Timeout       30s                       │
│                           │ │ Code size     1.2 MB                    │
│                           │ │ Arch          arm64                     │
│                           │ │ Package       Zip                       │
│                           │ │ Modified      2026-06-02T12:34:56+0000  │
│                           │ │ Role          lambda-role               │
└───────────────────────────┘ └─────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · l tail logs · o console · y yank ARN · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-lambda mnml-aws-lambda
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured.

## Setup

1. **Verify the AWS CLI works.** `aws lambda list-functions` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-lambda`.
3. **Edit `~/.config/mnml-aws-lambda.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings (env vars → shared credentials → SSO → IAM role).

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "All"
kind = "all"

[[tabs]]
name = "Watched"
kind = "watched"
watched = [
  "api-handler",
  "ingest-worker",
]
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Tab strip label |
| `kind` | no | `"all"` (default) or `"watched"` |
| `watched` | when `kind = "watched"` | Explicit list of function names |
| `region` | no | Per-tab region override |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab function-count badge
- **Functions table (left, 45%):** name + runtime
- **Detail panel (right, 55%):** focused function's full config (name / runtime / handler / memory / timeout / code size / arch / package / last-modified / role / ARN / description)
- **Status:** active count, key hints

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open Lambda console for the focused function |
| `y` | Yank focused function's ARN to clipboard |
| `l` | Launch `mnml-aws-cloudwatch-logs` |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

### `l` — the cross-sibling log handoff

A Lambda function's logs live in CloudWatch under `/aws/lambda/<function-name>`. Pressing `l` on a focused function launches the [`mnml-aws-cloudwatch-logs`](/manual/integrations/aws-cloudwatch-logs/) sibling so you can drill into the logs without leaving the terminal.

v0.1 launches the sibling without scoping it — you'll need to switch tabs in the launched view to the function's log group. v0.2 will pass a `--log-group` flag through so it auto-scopes to `/aws/lambda/<focused-fn>`. This is the first cross-sibling handoff in the family — Lambda's data model points at CloudWatch's, so they compose.

## Two run modes

### Standalone

```sh
mnml-aws-lambda
```

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-aws-lambda
```

## Wire it into mnml's left rail

`mnml-aws-lambda` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i L` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_lambda`.

## Status

**v0.1** — list (paginated) + watched filter, focused-function detail panel, console open, ARN yank, log-tail launch.

Held back for v0.2+:
- `l` auto-scopes to `/aws/lambda/<fn>` log group (needs sibling CLI flag in `mnml-aws-cloudwatch-logs`)
- Invoke with test payload picker (`i` chord)
- Errors-24h tab kind (CloudWatch Metrics integration)
- Per-function env-var count + concurrent-execution stats
- Recent invocation list

## Source

[github.com/chris-mclennan/mnml-aws-lambda](https://github.com/chris-mclennan/mnml-aws-lambda). MIT.
