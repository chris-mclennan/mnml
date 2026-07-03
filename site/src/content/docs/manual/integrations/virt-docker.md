---
title: Docker container browser
description: mnml-virt-docker — a terminal browser for Docker. Containers, images, volumes, networks, and per-project compose services. Tail logs, exec a shell, start / stop / remove, cross-sibling handoff to mnml-aws-ecr for ECR-hosted images. Shells out to `docker`; no SDK dep.
---

[`mnml-virt-docker`](https://github.com/chris-mclennan/mnml-virt-docker) is a terminal browser for Docker. Containers, images, volumes, networks, per-project compose services — tail logs, exec a shell, start / stop / remove, cross-sibling handoff to `mnml-aws-ecr` for ECR-hosted images. Runs **standalone in any terminal**. Shells out to `docker`; no SDK dep, no API tokens — Docker's socket is the auth boundary.

**First sibling in the `mnml-virt-*` family** (planned: `mnml-virt-k8s`, `mnml-virt-podman`, `mnml-virt-colima`).

```
┌─ docker ──────────────────────────────────────────────────────────────┐
│ ▸1.containers (8)  2.images (47)  3.volumes (12)  4.networks (5)      │
└───────────────────────────────────────────────────────────────────────┘
┌─ containers (8) ──────────────┐ ┌─ inspect ───────────────────────────┐
│ ▸ ● redis              redis:7│ │ State          running              │
│   ● postgres-pg        pg:16  │ │ Status         Up 2 hours           │
│   ○ example-api        acme…  │ │ Ports          6379/tcp             │
│   ↺ web-1              myorg/…│ │                                     │
└───────────────────────────────┘ └─────────────────────────────────────┘
  1-9 tab · l logs · e exec · s/S stop/start · R rm · L → ECR · r · q
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-virt-docker mnml-virt-docker
mnml-virt-docker --install
```

## Pre-requisite

Docker installed + running — [Docker Desktop](https://www.docker.com/get-started/) or any other Engine build. TUI shells out to `docker`, never opens the daemon socket directly. Whichever context `docker` is configured for is what this sees. v0.1 supports the default context only.

If the daemon isn't running, the body shows a "Docker daemon not running" notice. Start it, press `r`, reconnect.

## Setup

```sh
docker version               # verify CLI reaches daemon
mnml-virt-docker             # first-run scaffolds config
```

## Config

`~/.config/mnml-virt-docker/config.toml`:

```toml
refresh_interval_secs = 60

[[tabs]]
name = "containers"
kind = "containers"

[[tabs]]
name = "images"
kind = "images"

[[tabs]]
name = "volumes"
kind = "volumes"

[[tabs]]
name = "networks"
kind = "networks"

# Per-project compose (opt-in — no default since project dir is per-user)
# [[tabs]]
# name = "myapp"
# kind = "compose"
# project_path = "/Users/me/Projects/myapp"
```

### Tab kinds

| `kind` | What it shows | Required |
|---|---|---|
| `containers` | Every container in the local engine | — |
| `images` | Every image | — |
| `volumes` | Every volume | — |
| `networks` | Every network | — |
| `compose` | Services in a compose project (`compose.yaml` / `compose.yml` / `docker-compose.yml`) | `project_path` |

Container-state glyph: `●` green running · `○` gray exited / red dead · `↺` yellow restarting · `‖` yellow paused · `·` gray created.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate (each move re-runs inspect for the new focus, lazy) |
| `o` | Open Docker Desktop (macOS only; toast on other OSes) |
| `y` | Yank focused item's full ID / name |
| `l` | Tail logs for the focused container |
| `e` | Exec a shell (`/bin/bash` if available, else `/bin/sh`) |
| `s` / `S` | Stop / start the focused container |
| `R` | **Remove** focused item (`y` confirms) |
| `L` | **Cross-sibling jump** — if focused image is an ECR URL (`<acct>.dkr.ecr.<region>.amazonaws.com/…`), spawn `mnml-aws-ecr --region <region>` |
| `r` | Refresh + re-probe daemon if offline |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-virt-docker
```

### Hosted as a mnml Pty pane

```vim
:term mnml-virt-docker
```

Or `<leader>iK` after `mnml-virt-docker --install`.

## Source

[github.com/chris-mclennan/mnml-virt-docker](https://github.com/chris-mclennan/mnml-virt-docker). MIT.
