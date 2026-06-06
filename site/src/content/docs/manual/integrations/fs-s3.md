---
title: Amazon S3 browser
description: mnml-fs-s3 — a terminal browser for Amazon S3 buckets + prefixes + objects. Bucket tabs, breadcrumb navigation, download to local cache, URI yank, presigned URLs. Shells out to the `aws` CLI; no SDK dep. The first of the `mnml-fs-*` cloud-filesystem sibling class.
---

[`mnml-fs-s3`](https://github.com/chris-mclennan/mnml-fs-s3) is a terminal browser for Amazon S3 — list buckets, navigate prefixes, download objects, yank URIs, generate presigned URLs. Runs **standalone in any terminal** or as a **native mnml pane** via the blit-host protocol. It defers entirely to the **AWS CLI** for credentials — there is no AWS SDK dependency, same auth chain as [`mnml-aws-codebuild`](/manual/integrations/aws-codebuild/).

This is the **first of the family's `mnml-fs-*` siblings** — opens up `mnml-fs-gcs` (Google Cloud Storage), `mnml-fs-azureblob`, and other cloud-filesystem viewers with the same TUI shape. See [Building integrations](/manual/integrations/building/) for the model.

```
┌─ s3 ─────────────────────────────────────────────────────────────┐
│ ▸1.logs  2.exports  3.configs                                     │
└──────────────────────────────────────────────────────────────────┘
┌─ logs ───────────────────────────────────────────────────────────┐
│ 📁 my-app-logs / 2026 / 06                                        │
└──────────────────────────────────────────────────────────────────┘
┌─ 12 entries ─────────────────────────────────────────────────────┐
│ ▸ 📁 errors/                                                      │
│   📁 access/                                                      │
│   📄 build-log.txt              1.2 MB    2026-06-06              │
│   📄 application.log            45 KB     2026-06-06              │
│   …                                                               │
└──────────────────────────────────────────────────────────────────┘
  ↑↓/jk · Enter open · BS up · y URI · Y presign · o console · d del · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-fs-s3 mnml-fs-s3
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured (`aws configure` or any of the usual environment variables / shared-credentials files).

## Setup

1. **Verify the AWS CLI works.** Whatever you'd run from your shell — `aws s3 ls`, `aws sts get-caller-identity` — needs to succeed before this viewer can. There's no separate credential chain.

2. **Run once** to scaffold the config template:

   ```sh
   mnml-fs-s3
   ```

   Writes `~/.config/mnml-fs-s3.toml` and exits. Edit the `[[buckets]]` list — one entry per bucket you want as a tab.

3. **Re-run** — the TUI launches with your configured tabs.

4. **Verify** the resolved config + AWS CLI state without launching the TUI:

   ```sh
   mnml-fs-s3 --check
   ```

## Auth shape

There is none — at least, not on this viewer's side. Every S3 API call is a subprocess invocation of the `aws` CLI (`aws s3 …`, `aws s3api …`, `aws s3 presign`). The CLI's own credential chain (env vars → shared credentials → SSO → instance role) is what authenticates the call. That means:

- `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` set in your shell flow through.
- `aws sso login` sessions just work — the viewer doesn't manage tokens.
- Multi-account setups: switch profiles before launching the viewer; the active profile is the one queried.

Same shape as [`mnml-aws-codebuild`](/manual/integrations/aws-codebuild/) — if one works, the other will.

## Config

```toml
# Optional global:
#   refresh_interval_secs — default 0 (no auto-refresh).
#   S3 listings don't churn, so the default is no-poll;
#   press `r` in the TUI to refresh.

refresh_interval_secs = 0

# ── Buckets ──────────────────────────────────────────────────────
# Each [[buckets]] entry is one tab. Switch with 1-9 in the TUI.

[[buckets]]
name = "logs"
bucket = "my-app-logs"
prefix = "2026/"            # optional starting prefix
# region = "us-east-1"      # optional; defaults to AWS CLI's region

[[buckets]]
name = "exports"
bucket = "my-data-exports"

[[buckets]]
name = "configs"
bucket = "my-app-configs"
prefix = "prod/"
```

`bucket` is the bare name (`my-app-logs`, not `s3://my-app-logs/`). `prefix` jumps you straight into a subtree (must end in `/` — the viewer normalizes if you forget). `region` defers to the AWS CLI by default; override per-bucket for multi-region setups.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that bucket tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection |
| `PgUp` / `PgDn` | Jump 10 rows |
| `g` / `G` | Top / bottom |
| `Enter` | On a prefix → drill in. On a file → download to `~/.cache/mnml-fs-s3/<bucket>/<key>` (status shows the local path) |
| `Backspace` / `h` | Up one prefix level |
| `y` | Yank `s3://bucket/key` URI to OS clipboard |
| `Y` | Yank presigned URL (5-minute TTL, via `aws s3 presign`) to clipboard |
| `o` | Open S3 console URL in browser (anchored at current bucket / prefix) |
| `d` | Delete focused object — asks for `y` to confirm |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## File-open handoff

This is the interesting integration point. There are three levels; v0.1 ships the simple one and notes the rest.

**v0.1 (this release):** Press `Enter` on a file → sibling downloads to `~/.cache/mnml-fs-s3/<bucket>/<key>` → status shows the local path. User copies the path manually (or `y`-yanks the `s3://` URI for later) and opens it however they like. Simple, works today, no protocol changes.

**v0.2 (planned):** When running as a hosted pane (`:host.launch mnml-fs-s3`), the sibling emits a `tmnl-protocol::Message::OpenFile { path }` event after download. mnml-as-host picks it up and opens the file in its editor pane. The S3 browser stays focused; you `Tab` between the editor + S3 browser. Same protocol change benefits future siblings.

**v0.3 (later):** Save-back. Remember the (bucket, key) → local path mapping. Add a save-hook in mnml core that calls the sibling when a file from `~/.cache/mnml-fs-s3/` is saved. Sibling does `aws s3 cp` upload. Now you can actually edit configs in S3 from mnml.

## Why not just NFS-mount the bucket?

[Mountpoint for S3](https://github.com/awslabs/mountpoint-s3) (AWS-official, GA since August 2023) lets you mount a bucket as a real filesystem; once mounted, mnml's regular file browser works against the mount with no integration code. That's the right path **on Linux** or **inside AWS compute** (EC2 / EKS / etc. — and Amazon S3 Files since April 2026 makes it even cleaner there).

The catch is **macOS laptops**: Mountpoint needs FUSE, which on macOS means macFUSE — a kernel extension that requires manual user approval in System Settings and a reboot. mnml can't automate that. So `mnml-fs-s3` exists for the laptop-without-FUSE workflow: install one binary, point at your buckets, browse. No kernel extension. No mount. No reboot.

For users on EC2/EKS/Linux, the mount-then-browse path is equally valid — either workflow works.

## Two run modes

### Standalone

Just run `mnml-fs-s3` in any terminal. The TUI takes over until you `q`.

### Blit-host (hosted by mnml)

```vim
:host.launch mnml-fs-s3
```

mnml spawns it with `--blit <socket>` and renders the streamed cells into a native `Pane::BlitHost`. The pane becomes a normal mnml pane — splittable, focusable, key-routed. `Ctrl+E` releases focus back to the layout tree. See [Building integrations](/manual/integrations/building/) for the protocol mechanism.

## Wire it into mnml's left rail

`mnml-fs-s3` ships as a default chip in mnml's rail under **INTEGRATIONS** — no config needed if you've kept the built-in defaults. Bound to `<leader>i s` in the whichkey leader menu (vim mode), or palette-runnable as `forge.open_s3`.

To customise the icon, drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "s3"
glyph    = "\U000F0EBC"            # nf-md-aws (TOML 8-digit form)
fallback = "S3"
command  = ":host.launch mnml-fs-s3"
color    = "orange"
tooltip  = "Open S3 browser"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults, so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference.

## Status

**v0.1 (this release)** — Bucket tabs, prefix navigation, download-to-cache, URI / presigned-URL yank, S3 console open, delete-with-confirmation. Standalone TUI + blit-host mode.

Held back for v0.2+:
- Upload prompt UI (the `aws s3 cp` call is implemented; the prompt scaffold is what's deferred)
- `tmnl-protocol::Message::OpenFile` for the in-place file-open handoff
- Glacier / IA tier visibility
- Versioning support (latest only in v0.1)
- Encryption metadata
- Multi-select for batch ops

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-fs-s3](https://github.com/chris-mclennan/mnml-fs-s3). MIT-licensed. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
