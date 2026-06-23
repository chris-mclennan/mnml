---
title: AWS CloudWatch Logs viewer
description: mnml-aws-cloudwatch-logs — a terminal viewer for AWS CloudWatch log groups. Tabbed groups, live tail with severity coloring, filter patterns, console link. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-cloudwatch-logs`](https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs) is a terminal viewer for AWS CloudWatch Logs — tabbed log groups, per-line severity coloring, filter pattern support, and a one-key jump to the AWS Console. Runs **standalone in any terminal**.

This generalizes the Logs tabs that used to live inside [`mnml-aws-codebuild`](/manual/integrations/aws-codebuild/) — instead of CodeBuild-specific log groups, this viewer handles any CloudWatch log group (Lambda, API Gateway, ECS, EKS, your own service logs).

```
┌─ cloudwatch logs ────────────────────────────────────────────────┐
│ ▸1.lambda errors · tailing  2.api gateway · tailing  3.ecs       │
└──────────────────────────────────────────────────────────────────┘
┌─ lambda errors · /aws/lambda/my-function ────────────────────────┐
│ 2026-06-06T15:43:01.234Z START RequestId: abc-123                 │
│ 2026-06-06T15:43:01.456Z [ERROR] DynamoDB throttled: …            │
│ 2026-06-06T15:43:01.789Z END RequestId: abc-123                   │
│ 2026-06-06T15:43:02.012Z REPORT Duration: 245.67 ms               │
│ …                                                                 │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk scroll · y yank line · o console · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs --tag v0.2.0 mnml-aws-cloudwatch-logs
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured (`aws configure` or any of the usual environment variables / shared-credentials files).

## Setup

1. **Verify the AWS CLI works.** `aws logs describe-log-groups` must succeed before this viewer can.
2. **Run once** to scaffold the config template:
   ```sh
   mnml-aws-cloudwatch-logs
   ```
   Writes `~/.config/mnml-aws-cloudwatch-logs.toml` and exits.
3. **Edit the config** — add your log groups as `[[tabs]]` entries.
4. **Re-run** — the TUI launches with your configured tabs.
5. **Verify** the resolved config without launching the TUI:
   ```sh
   mnml-aws-cloudwatch-logs --check
   ```

## Auth shape

There is none on this viewer's side. Every operation is a subprocess call to `aws logs tail --follow`. The CLI's credential chain (env vars → shared credentials → SSO → instance role) is what authenticates. Same shape as every other `mnml-aws-*` sibling — if one works, the others will.

## Config

```toml
# Optional top-level region (defers to AWS CLI when unset):
# region = "us-east-1"

refresh_interval_secs = 0

[[tabs]]
name = "lambda errors"
log_group = "/aws/lambda/my-function"
# Optional: narrow to one stream
# log_stream = "2026/06/06/[$LATEST]abc123"
# Optional: filter pattern (substring or CloudWatch Logs syntax)
filter = "ERROR"

[[tabs]]
name = "api gateway"
log_group = "/aws/apigateway/my-api"

[[tabs]]
name = "ecs service"
log_group = "/ecs/my-service"
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Tab strip label |
| `log_group` | yes | CloudWatch log group name (`/aws/lambda/my-func`) |
| `log_stream` | no | Narrow to one stream — useful when a long-running build has its own stream |
| `region` | no | Per-tab region override; defers to AWS CLI by default |
| `filter` | no | CloudWatch Logs filter pattern — passed to `--filter-pattern` |

Filter pattern syntax: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html>. Examples:

- `filter = "ERROR"` — substring match
- `filter = '{ $.level = "error" }'` — JSON field match
- `filter = "[level=ERROR, ...]"` — space-delimited match

## One-off tab via CLI flags

v0.2 adds a set of CLI flags that let another program (or you, from a
shell prompt) launch the viewer scoped to **one specific log group**
without touching the user's regular `~/.config/mnml-aws-cloudwatch-logs.toml`.

```sh
mnml-aws-cloudwatch-logs --log-group /aws/lambda/api-handler
```

That opens a single-tab session tailing `/aws/lambda/api-handler` and
exits cleanly with `q`. The on-disk config is not read or modified.

| Flag | Purpose |
|---|---|
| `--log-group <GROUP>` | The CloudWatch log group to tail. Triggers one-off mode — the config file is bypassed. |
| `--log-group-name <NAME>` | Tab label. Defaults to the last path segment of `--log-group` (e.g. `api-handler` for `/aws/lambda/api-handler`). |
| `--filter <PATTERN>` | Filter pattern, same syntax as the `filter` config field. |
| `--region <REGION>` | AWS region override for this one-off tab. |

Internally, a `Config::one_off_tab()` constructor synthesises a single-tab
`Config` on the fly. Everything downstream — the tail loop, severity
colouring, console open, yank — behaves exactly as it would for a
config-defined tab.

### Cross-sibling handoff

This is what powers the **`l` chord in `mnml-aws-lambda`**: pressing `l`
on a focused Lambda function spawns

```sh
mnml-aws-cloudwatch-logs \
  --log-group /aws/lambda/<focused-fn> \
  --log-group-name <focused-fn> \
  [--region <r>]
```

so the user lands in a logs viewer already pointed at the right group.
The same pattern is the planned hook for any future sibling that needs
to drill into the logs of a specific resource. See the
[Lambda viewer](/manual/integrations/aws-lambda/) for the call site.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k` | Scroll up (pauses auto-scroll until you `G` back to bottom) |
| `↓` / `j` | Scroll down (jumps to live-tail at bottom) |
| `PgUp` / `PgDn` | Page up / down |
| `g` / `G` | Top / bottom |
| `o` | Open CloudWatch console URL for the active tab in browser |
| `y` | Yank focused log line to OS clipboard |
| `r` | No-op (the tail is already live; reserved for future re-spawn) |
| `q` / `Esc` / `Ctrl+C` | Quit |

Each tab maintains a 5000-line scrollback buffer. Lines are
classified into 4 severities (`ERROR` red / `WARN` yellow / `INFO`
cyan / `DEBUG` dim) so scrolling through a long run is much
easier to scan than uniform output.

## Why this is a sibling, not built into mnml-aws-codebuild

The CodeBuild sibling has Logs tabs because CodeBuild builds emit their own log streams under `/aws/codebuild/<project>`. Those tabs only know about CodeBuild-shaped log groups. The CloudWatch sibling generalizes the same `aws logs tail` machinery to any log group, with per-tab filter patterns and a wider feature set (yank, console jump). If you only care about CodeBuild log groups, the CodeBuild sibling's Logs tabs are fine; for everything else, run this one.

## Two run modes

### Standalone

```sh
mnml-aws-cloudwatch-logs
```

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-cloudwatch-logs
```

mnml spawns the binary in a Pty pane — splittable, focusable, key-routed like any other pane.

## Wire it into mnml's left rail

`mnml-aws-cloudwatch-logs` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i w` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_cloudwatch_logs`.

## Status

**v0.2** — adds one-off-tab CLI flags (`--log-group`, `--log-group-name`,
`--filter`, `--region`) so other siblings can spawn the viewer scoped to
a single log group. New `Config::one_off_tab()` constructor synthesises
a single-tab config on the fly, bypassing `~/.config/mnml-aws-cloudwatch-logs.toml`
entirely. Powers the `l` cross-sibling handoff from `mnml-aws-lambda`.

**v0.1** — tabbed log groups, live tail with severity coloring, filter patterns, console open, line yank, 5K-line scrollback per tab.

Held back for v0.3+:
- Multi-stream selection within a tab
- CloudWatch Logs Insights query mode
- Saved searches
- Log-group picker overlay (config-only today)

## Source

[github.com/chris-mclennan/mnml-aws-cloudwatch-logs](https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs). MIT.
