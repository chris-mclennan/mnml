---
title: AWS ECR viewer
description: mnml-aws-ecr — a terminal browser for AWS ECR repositories and image tags. List repositories or images-per-repository with size, push date, digest. Pairs with mnml-aws-ecs. Runs standalone or as an mnml-hosted pane. Same `aws` CLI auth chain as the other AWS siblings.
---

[`mnml-aws-ecr`](https://github.com/chris-mclennan/mnml-aws-ecr) is a terminal browser for AWS Elastic Container Registry — list every repository in a region, drill into image tags with size + push date + digest, yank the `docker pull` URI in one keystroke. Pairs naturally with [`mnml-aws-ecs`](/manual/integrations/aws-ecs/) for the full container deploy workflow (where the image lives + where the container runs). Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol.

```
┌─ ecr ─────────────────────────────────────────────────────────────────┐
│ ▸1.Repositories (6)  2.api images (24)                                │
└───────────────────────────────────────────────────────────────────────┘
┌─ images · api (24) ───────────┐ ┌─ detail ────────────────────────────┐
│ ▸ v1.2.3       48.0 MB · …    │ │ Repository    api                   │
│   v1.2.2       48.1 MB · …    │ │ Tags          v1.2.3, latest        │
│   v1.2.1       47.9 MB · …    │ │ Digest        abc123def456…         │
│   abc123def…   48.0 MB · …    │ │ Size          48.0 MB               │
│   …                           │ │ Pushed        2026-06-06 18:30      │
│                               │ │  Full digest                        │
│                               │ │  sha256:abc1234567890def…           │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · o console · y yank ARN/pull URI · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-ecr --tag v0.1.0 mnml-aws-ecr
```

## Setup

1. **Verify the AWS CLI works.** `aws ecr describe-repositories` must succeed.
2. **Run once** to scaffold the config: `mnml-aws-ecr`.
3. **Edit `~/.config/mnml-aws-ecr.toml`** — add your tabs.
4. **Re-run**.

## Auth shape

Pure shell-out to the `aws` CLI — same chain as the other AWS siblings.

## Config

```toml
# Optional top-level region:
# region = "us-east-1"

refresh_interval_secs = 60

[[tabs]]
name = "Repositories"
kind = "repositories"

[[tabs]]
name = "api images"
kind = "images"
repository = "api"
```

### Tab kinds

| `kind` | What it shows | Required fields |
|---|---|---|
| `repositories` (default) | Every ECR repo in the region — tag mutability, scan-on-push status | none |
| `images` | Image tags within `repository`, newest first | `repository` |

## Layout

- **Tab strip:** one tab per `[[tabs]]` entry, with per-tab count badge
- **Items table (left, 45%):**
  - For repositories: `<name>  <mutability> · <scan-mode>`
  - For images: `<tag or short-digest>  <size> · <pushed> [· +N tag(s)]`
- **Detail panel (right, 55%):** focused item's full detail
  - **Repository:** name, URI, registry ID, tag mutability, scan-on-push flag, created, ARN
  - **Image:** repository, tags (comma-separated, or `(untagged)`), short digest, size, pushed-at (no seconds), manifest media type, full digest

Images are sorted by `pushed_at` descending so the newest is always at the top — matches the `docker images` view a deploy engineer would expect.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open ECR console for the focused item |
| `y` | Yank — repository ARN for repos, `<repo>:<tag>` (or `<repo>@<digest>` if untagged) for images |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

### `y`-on-image — the `docker pull` payload

The yank on an image row gives you what you'd paste into `docker pull <copied>` or into your task definition's `image:` field. Tagged images get `<repo>:<tag>`; untagged images fall back to `<repo>@<digest>`. Pairs with `mnml-aws-ecs` for the natural workflow: find the image here, look up which services use it there.

## Two run modes

### Standalone

```sh
mnml-aws-ecr
```

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-aws-ecr
```

## Wire it into mnml's left rail

`mnml-aws-ecr` ships as a default chip in mnml's rail under **INTEGRATIONS**. Bound to `<leader>i E` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_ecr`.

## Status

**v0.1** — repositories list + images-per-repository list (both paginated), focused-item detail panel, console open, repository-ARN yank + image-pull-URI yank.

Held back for v0.2+:
- Image scan findings (high/medium/low/critical counts in the list)
- Cross-sibling handoff to `mnml-aws-ecs`: pick an image, see all services running it
- Multi-arch manifest expansion
- Delete-image action with confirm prompt
- Filter by tag pattern
- Public ECR Gallery support (`public.ecr.aws`)

## Source

[github.com/chris-mclennan/mnml-aws-ecr](https://github.com/chris-mclennan/mnml-aws-ecr). MIT.
