---
title: AWS Amplify viewer
description: mnml-aws-amplify — a terminal viewer for AWS Amplify apps, branches, and deploy jobs. Split view of branches + recent jobs. Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-amplify`](https://github.com/chris-mclennan/mnml-aws-amplify) is a terminal viewer for AWS Amplify — apps, branches, and deploy jobs. The Amplify console is one of the more click-painful AWS surfaces; this pulls the daily-driver views (which branch is on what stage, did the last deploy succeed, what was the commit) into a terminal tab. Runs **standalone in any terminal**.

```
┌─ amplify ────────────────────────────────────────────────────────┐
│ ▸1.All apps (12)  2.Frontend (4 br)  3.Marketing (2 br)          │
└──────────────────────────────────────────────────────────────────┘
┌─ Frontend ───────────────────────────────────────────────────────┐
│ ┌─ branches ──────────┐ ┌─ recent jobs ─────────────────────────┐│
│ │ ▸ main  PRODUCTION  │ │ #421 SUCCEED     a8f3c1d2 feat: …     ││
│ │   beta  BETA        │ │ #420 SUCCEED     b4e2c19a fix: …      ││
│ │   dev   DEVELOPMENT │ │ #419 FAILED      c9a1b3f5 chore: …    ││
│ │                     │ │ …                                     ││
│ └─────────────────────┘ └───────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · Enter/o console · y yank · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-amplify mnml-aws-amplify
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured.

## Setup

1. **Verify the AWS CLI works.** `aws amplify list-apps` must succeed before this viewer can.
2. **Run once** to scaffold the config: `mnml-aws-amplify`.
3. **Edit `~/.config/mnml-aws-amplify.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as [`mnml-aws-codebuild`](/manual/integrations/aws-codebuild/) and [`mnml-aws-cloudwatch-logs`](/manual/integrations/aws-cloudwatch-logs/).

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "All apps"
kind = "apps"

[[tabs]]
name = "Frontend"
kind = "app"
app_id = "d2abc123def456"   # from Amplify console URL or `aws amplify list-apps`
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `apps` (default) | Every Amplify app in the region — id / name / platform / repo | none |
| `app` | Drills into one specific app — branches (left) + recent deploy jobs for the focused branch (right) | `app_id` |

The Amplify app id is the `dXXXXXXXX` segment in the console URL:
`https://us-east-1.console.aws.amazon.com/amplify/apps/d2abc123def456`

You can also run `aws amplify list-apps --query "apps[].{name:name, id:appId}"` to find them.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `Enter` / `o` | Open focused row's console URL in browser |
| `y` | Yank focused row's console URL to clipboard |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

On an **App** tab, moving the branch selection auto-triggers a `list-jobs` for that branch — the right-hand panel updates to show its recent deploy history. The PRODUCTION stage gets a green chip, BETA yellow, DEVELOPMENT cyan.

## Two run modes

### Standalone

```sh
mnml-aws-amplify
```

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-amplify
```

## Wire it into mnml's left rail

`mnml-aws-amplify` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i a` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_amplify`.

## Status

**v0.1** — Apps list, App detail (branches + jobs split view), console open, URL yank.

Held back for v0.2+:
- Trigger a deploy from the terminal (`start-job`)
- Per-job build log tail
- Pull request previews list
- Webhooks list

## Source

[github.com/chris-mclennan/mnml-aws-amplify](https://github.com/chris-mclennan/mnml-aws-amplify). MIT.
