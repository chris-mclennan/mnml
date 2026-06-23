---
title: AWS Cognito viewer
description: mnml-aws-cognito — a terminal browser for AWS Cognito User Pools and recent users. List pools or users-in-pool with status, email, attributes, Lambda triggers. Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-cognito`](https://github.com/chris-mclennan/mnml-aws-cognito) is a terminal browser for AWS Cognito User Pools — list every pool in a region, drill into recent users with status / email / created-at / Lambda triggers, yank a user's `sub` (the OIDC subject claim) or a pool's ID in one keystroke. Useful for the support workflow: "user X reports a sign-in problem — find them, check their status." Runs **standalone in any terminal**.

```
┌─ cognito ─────────────────────────────────────────────────────────────┐
│ ▸1.Pools (2)  2.prod users (60)                                       │
└───────────────────────────────────────────────────────────────────────┘
┌─ users · us-east-1_abc (60) ──┐ ┌─ detail ────────────────────────────┐
│ ▸ ada@example.com CONFIRMED   │ │ Username       ada@example.com      │
│   bob@example.com CONFIRMED   │ │ Status         CONFIRMED            │
│   eve@example.com UNCONFIRMED │ │ Enabled        true                 │
│   …                           │ │ Created        2026-06-06 18:30     │
│                               │ │ Modified       2026-06-06 18:42     │
│                               │ │  Attributes (6)                     │
│                               │ │  sub                  f4a1b2c3-…    │
│                               │ │  email                ada@…         │
│                               │ │  email_verified       true          │
│                               │ │  custom:role          admin         │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank pool ID / user sub · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-cognito --tag v0.1.0 mnml-aws-cognito
```

## Setup

1. **Verify the AWS CLI works.** `aws cognito-idp list-user-pools --max-results 10` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-cognito`.
3. **Edit `~/.config/mnml-aws-cognito.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "Pools"
kind = "pools"

[[tabs]]
name = "prod users"
kind = "users"
user_pool_id = "us-east-1_abc123"
user_limit = 60
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `pools` (default) | Every Cognito User Pool in the region | none |
| `users` | Recent users in `user_pool_id`, newest first, up to `user_limit` (default 60, max 600) | `user_pool_id` |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):**
  - For pools: `<name>  <status> · <id>`
  - For users: `<email or username>  <status>[ · DISABLED]` with color-coded status:
    - `CONFIRMED` gray
    - `FORCE_CHANGE_PASSWORD` / `RESET_REQUIRED` / `UNCONFIRMED` yellow (action needed)
    - `enabled: false` dim
- **Detail panel (right, 55%):** focused item's full detail
  - **Pool:** name, ID, status, created, last-modified, Lambda triggers — every configured trigger (`PreSignUp`, `PostAuthentication`, `PreTokenGeneration`, etc.) with the function name extracted from the ARN tail
  - **User:** username, status, enabled flag, created, modified, all attributes (sub, email, email_verified, given_name, family_name, plus `custom:*` claims) — up to 15 rows

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open Cognito console for the focused item |
| `y` | Yank pool ID (for pools) or user `sub` (for users — falls back to username) |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

The user `sub` yank is the **OIDC subject claim** — paste it into a database query or a CloudWatch Logs query to find that user's records / requests.

## Two run modes

### Standalone

```sh
mnml-aws-cognito
```

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-cognito
```

## Wire it into mnml's left rail

`mnml-aws-cognito` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i o` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_cognito`.

## Status

**v0.1** — User pools list, users-in-pool list (newest first, cap at 600), focused-item detail panel with pool Lambda triggers + user attributes, console open, ID/sub yank.

Held back for v0.2+:
- Search/filter users by email or `sub`
- Filter by user status (CONFIRMED / UNCONFIRMED / RESET_REQUIRED)
- Disable/enable user action with confirm prompt
- Cross-sibling handoff to `mnml-aws-lambda` for the focused pool's trigger functions
- App Clients tab
- Federated identity pools (`cognito-identity`)

## Source

[github.com/chris-mclennan/mnml-aws-cognito](https://github.com/chris-mclennan/mnml-aws-cognito). MIT.
