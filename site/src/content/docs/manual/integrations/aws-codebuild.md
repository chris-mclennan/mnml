---
title: AWS CodeBuild viewer
description: mnml-aws-codebuild — a terminal viewer for AWS CodeBuild project runs + CloudWatch Logs live tail. Shells out to the `aws` CLI; no SDK dependency. Runs standalone or hosted as an mnml pane.
---

[`mnml-aws-codebuild`](https://github.com/chris-mclennan/mnml-aws-codebuild) is a terminal viewer for AWS CodeBuild project runs and CloudWatch Logs live tail. Runs **standalone in any terminal**. It defers entirely to the **AWS CLI** for credentials — there is no AWS SDK dependency, no token file, no `--profile` flag. See [Building integrations](/manual/integrations/building/) for the model.

This is the sibling that picked up the CodeBuild + CloudWatch panes that used to live in mnml core's `aws-codebuild` Cargo feature (removed 2026-06).

```
┌─ aws ────────────────────────────────────────────────────────────┐
│ ▸1.api builds (30)  2.api logs · tailing                         │
└──────────────────────────────────────────────────────────────────┘
┌─ api builds ─────────────────────────────────────────────────────┐
│ #       │ STATUS       │ STARTED          │ DUR │ INITIATOR      │
│ #38788  │ ✓ succeeded  │ 2026-06-05 14:01 │ 96s │ codepipeline…  │
│ #38787  │ ✗ failed     │ 2026-06-05 13:42 │ 29s │ chris@mnml     │
│ …                                                                 │
└──────────────────────────────────────────────────────────────────┘
  1-9 tab · ↑↓/jk move · Enter/o open · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-aws-codebuild mnml-aws-codebuild
```

You'll also need the [AWS CLI](https://aws.amazon.com/cli/) on your `$PATH` with credentials configured (`aws configure` or any of the usual environment variables / shared-credentials files).

## Setup

1. **Verify your AWS CLI works.** Whatever you'd run from your shell — `aws sts get-caller-identity`, `aws codebuild list-projects` — needs to succeed before this viewer can. It shells out via subprocess; there's no separate credential chain.

2. **Run once** to scaffold the config template:

   ```sh
   mnml-aws-codebuild
   ```

   Writes `~/.config/mnml-aws-codebuild.toml` and exits. Edit the `[[tabs]]` list with your CodeBuild project name(s) and (optionally) a CloudWatch log group for a live-tail tab.

3. **Re-run** — the TUI launches with your configured tabs.

4. **Verify** the resolved config without launching the TUI:

   ```sh
   mnml-aws-codebuild --check
   ```

## Auth shape

There is none — at least, not on this viewer's side. Every AWS API call is a subprocess invocation of the `aws` CLI (`aws codebuild …`, `aws logs tail …`). The CLI's own credential chain (env vars → shared credentials → SSO → instance role) is what authenticates the call. That means:

- `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` set in your shell flow through.
- `aws sso login` sessions just work — the viewer doesn't manage tokens.
- Multi-account setups: switch profiles before launching the viewer; the active profile is the one queried.

If you need to point the viewer at a specific region without changing your CLI default, set `region = "us-east-1"` at the top of the config — that gets passed to every subprocess as `--region <region>`.

## Config

```toml
# region is optional — defers to the `aws` CLI's resolution when unset
# region = "us-east-1"
refresh_interval_secs = 60

[[tabs]]
name    = "api builds"
project = "my-app"            # CodeBuild project name

[[tabs]]
name      = "api logs"
kind      = "logs"            # live `aws logs tail --follow`
log_group = "/aws/codebuild/my-app"
# log_stream = "abc123"       # optional — narrows to one stream
```

`refresh_interval_secs` defaults to `60`; set to `0` to disable auto-refresh on Builds tabs (Logs tabs stream live regardless).

## Tab kinds

Each `[[tabs]]` entry has a `kind` field (defaults to `builds`) that decides what it shows:

| `kind` | What it shows | Required fields |
|---|---|---|
| `builds` (default) | Most-recent CodeBuild runs — #, status, started, duration, initiator, source ref | `project` |
| `logs` | Live `aws logs tail --follow` with per-line severity coloring (`ERROR` / `WARN` / `INFO` / `DEBUG`) | `log_group` (optional `log_stream` narrower) |

```toml
# Builds tab — full project history, newest first
[[tabs]]
name    = "api builds"
project = "my-app"

# Logs tab — live tail of the project's log group
[[tabs]]
name      = "api logs"
kind      = "logs"
log_group = "/aws/codebuild/my-app"

# Logs tab — narrowed to one stream (e.g. a long-running build)
[[tabs]]
name       = "build-7f2a logs"
kind       = "logs"
log_group  = "/aws/codebuild/my-app"
log_stream = "7f2abc12-3456-7890-abcd-ef1234567890"
```

### Builds tabs

The Builds tab calls `aws codebuild list-builds-for-project` to get the build IDs, then batches a `aws codebuild batch-get-builds` to fill in status / timing / initiator. Severity in the `STATUS` column is derived from CodeBuild's build phase + result:

| Chip | When |
|---|---|
| `✓ succeeded` | `SUCCEEDED` |
| `✗ failed` | `FAILED` |
| `… in_progress` | not yet complete |
| `✗ fault` | `FAULT` (CodeBuild internal error) |
| `✗ timed_out` | `TIMED_OUT` |
| `⊘ stopped` | manually stopped via the console |

`Enter` / `o` opens the focused build's CodeBuild console page in your browser (`https://<region>.console.aws.amazon.com/codesuite/codebuild/projects/<project>/build/<build-id>/`).

### Logs tabs

Logs tabs spawn `aws logs tail --follow` on first activation and keep the child running until the tab is closed (or the binary exits — the child is killed on `Drop`). Lines stream into a scrollback buffer; auto-scroll follows the tail by default. `↑` / `PgUp` scrolling pauses auto-scroll until you `G` to jump back to bottom.

Each line gets severity-classified via the same `LineSeverity::classify` machinery mnml uses internally — `ERROR` / `WARN` / `INFO` / `DEBUG` keywords (case-insensitive) get colored chips at the left margin; everything else renders plain.

## Keys

| Chord | Action |
|---|---|
| `1`-`9` | Switch to that tab |
| `Tab` / `BackTab` | Cycle tabs forward / back |
| `↑` / `k`, `↓` / `j` | Move selection (builds tab) / scroll log (logs tab) |
| `PgUp` / `PgDn` | Jump 10 rows / one page |
| `g` / `G` | Top / bottom |
| `Enter` / `o` | Open focused build in browser (CodeBuild console page) |
| `y` | Yank focused build's CodeBuild console URL to the OS clipboard |
| `L` | Open ephemeral Logs tab tailing the focused build's CloudWatch stream (or switch to an existing one) |
| `r` | Refresh active tab (builds: re-list; logs: no-op — already live) |
| `q` / `Esc` / `Ctrl+C` | Quit |

`L` drills from the Builds list into a per-build Logs tab — the
log group + stream come from CodeBuild's `batch-get-builds`
response (`logs.groupName` + `logs.streamName`). The new Logs
tab is named `<short-build-id> logs`; switching back to the same
build re-uses the existing tab.

## Two run modes

### Standalone

Just run `mnml-aws-codebuild` in any terminal. The TUI takes over until you `q`.

### Hosted as a mnml Pty pane

```vim
:term mnml-aws-codebuild
```

mnml spawns it in a Pty pane — splittable, focusable, key-routed like any other pane.

## Wire it into mnml's left rail

`mnml-aws-codebuild` ships as a default chip in mnml's rail under **INTEGRATIONS** — no config needed if you've kept the built-in defaults. To customise the icon, drop this into your `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "codebuild"
glyph    = "\U000F0E5C"            # nf-md-cogs (TOML 8-digit form)
fallback = "C"
command  = ":term mnml-aws-codebuild"
color    = "orange"
tooltip  = "Open AWS CodeBuild + log tail"
```

Setting `[[ui.integration_icon]]` **replaces** the built-in defaults, so copy the defaults from `src/config.rs` into your config first if you want to extend rather than replace. See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference.

## Status

**v0.1 (this release)** — Builds + Logs tabs. No build-detail panel yet (`Enter` opens the CodeBuild console page in the browser). No `fetch artifact → Tests pane` cross-nav. Both queued for v0.2.

The pre-split equivalents in mnml core (`Pane::CodeBuilds`, `Pane::LogTail`, the `aws-codebuild` Cargo feature) were removed on 2026-06-05; any existing `[aws-codebuild]` config in your `~/.config/mnml/config.toml` is silently ignored.

## Source

The viewer lives in its own sibling repo: [github.com/chris-mclennan/mnml-aws-codebuild](https://github.com/chris-mclennan/mnml-aws-codebuild). MIT-licensed. See [Building integrations](/manual/integrations/building/) for the anatomy of an integration, or [Community integrations](/manual/integrations/community/) for the directory of siblings.
