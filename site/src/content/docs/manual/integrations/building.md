---
title: Building integrations
description: How to build your own mnml integration — a standalone TUI that opt-in becomes an mnml Pty pane via the `:term <binary>` palette command.
---

mnml integrations are **standalone ratatui CLIs** that follow a few conventions. mnml hosts them as Pty panes via `:term <binary>` — no protocol to implement, no manifest to register.

They are not plugins, extensions, or scripts. There is no mnml runtime, no plugin loader, no manifest, no registration step. Each integration is a regular Rust binary that:

1. Works **standalone** in any terminal (Terminal.app, iTerm2, tmux, ssh — anywhere).
2. Works **inside mnml as a Pty pane** automatically — same as Claude Code, Codex, shell.

## Two deployment modes

```
┌─────────────────────────────────────────────────────────────────────┐
│  Mode 1: Standalone                                                 │
│                                                                     │
│  $ mnml-db-postgres                                                 │
│  → ratatui TUI in your current terminal                             │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  Mode 2: Pty pane inside mnml                                       │
│                                                                     │
│  :term mnml-db-postgres                                             │
│  → mnml spawns the binary as a Pty pane — splittable, focusable,    │
│    key-routed like any other pane                                   │
└─────────────────────────────────────────────────────────────────────┘
```

Both modes require nothing from your code beyond being a normal ratatui TUI binary.

## Anatomy of an integration

Look at [`mnml-db-postgres`](https://github.com/chris-mclennan/mnml-db-postgres):

```
mnml-db-postgres/
├── Cargo.toml                 # deps + binary metadata
├── README.md
└── src/
    ├── main.rs                # CLI parsing + picks TUI vs --check
    ├── app.rs                 # all app state — connections, query buffer, results
    ├── config.rs              # reads ~/.config/mnml-db-postgres.toml
    ├── postgres.rs            # the only file unique to this integration
    ├── keys.rs                # action enum + key → action mapping
    └── ui.rs                  # ratatui draw + event loop
```

~1,500 lines of Rust total. The only file you really write from scratch is the one that talks to your backend (`postgres.rs` here; `jira.rs` for the Jira viewer; `redis_client.rs` for Redis; etc.).

Everything else is the family scaffold.

## The conventions

These aren't enforced by any tool, but following them makes your integration feel at home next to the others:

### Naming

`mnml-<class>-<name>` — e.g.:

- `mnml-db-postgres`, `mnml-db-mysql`, `mnml-db-sqlite`, `mnml-db-clickhouse`, `mnml-db-dynamodb`
- `mnml-tracker-jira`, `mnml-tracker-linear`, `mnml-tracker-shortcut`
- `mnml-forge-bitbucket`, `mnml-forge-github`, `mnml-forge-gitlab`, `mnml-forge-azdevops`
- `mnml-aws-codebuild`, `mnml-aws-cloudwatch-logs`, `mnml-aws-amplify`
- `mnml-fs-s3`, `mnml-fs-gcs`, `mnml-fs-azureblob`
- `mnml-test-playwright`, `mnml-test-cypress`

Whatever class makes sense. The `mnml-` prefix is the only "rule" — it's how `cargo search mnml-` discovers them. The first-party class names today are `db` (databases), `tracker` (issue trackers), `forge` (code-hosting forges), `aws` (AWS service viewers), `fs` (cloud filesystems), and `test` (test result viewers); coin a new class when nothing fits.

### Config location

```
~/.config/mnml-<class>-<name>.toml
```

Secrets in a separate `~/.config/mnml-<class>-<name>/token` file with `chmod 600`. The viewer should `chmod 600` it for the user when it's created.

First-run UX: when the config doesn't exist, scaffold a template and exit with instructions. Don't blow up.

### Key chords

The family idiom:

| Chord | Action |
|---|---|
| `1`-`9` / `Alt+1`-`Alt+9` | Switch tab / connection |
| `Tab` / `BackTab` | Cycle tabs |
| `Enter` / `Ctrl+Enter` / `F5` | Run / open |
| `↑↓` / `j k` | Move selection |
| `g` / `G` | Top / bottom |
| `r` | Refresh active view |
| `Ctrl+U` | Clear input buffer |
| `q` / `Esc` / `Ctrl+C` | Quit |

### CLI flags

```sh
mnml-<thing>                   # launch the TUI
mnml-<thing> --check           # print resolved config + auth state, exit 0/1
```

`--check` should show: where the config came from, which connections / tabs are configured, whether auth succeeds. This is the "is my setup right?" command.

## Shelling out to vendor CLIs (the AWS pattern)

Seven first-party siblings now follow a "no SDK; shell out to the vendor CLI" model: [`mnml-aws-codebuild`](/manual/integrations/aws-codebuild/), [`mnml-aws-cloudwatch-logs`](/manual/integrations/aws-cloudwatch-logs/), [`mnml-aws-amplify`](/manual/integrations/aws-amplify/), [`mnml-aws-lambda`](/manual/integrations/aws-lambda/), [`mnml-aws-eventbridge`](/manual/integrations/aws-eventbridge/), [`mnml-fs-s3`](/manual/integrations/fs-s3/), and [`mnml-db-dynamodb`](/manual/integrations/db-dynamodb/). The pattern is worth lifting up because it removes a lot of integration code that would otherwise be on you.

The deal: every backend call is a `std::process::Command::new("aws").args([...])` subprocess. The CLI's own credential chain — env vars (`AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) → shared credentials → SSO → instance role — is what authenticates the call. The viewer's auth code is "did the subprocess exit 0?"

What you get for free:

- **No SDK dep.** No `aws-sdk-rust`, no token refresh logic, no region resolution code.
- **`aws sso login` just works** — the viewer doesn't manage tokens; the CLI does.
- **Multi-account / multi-profile** — switch `AWS_PROFILE` before launching; the active profile is the one queried. No config knob needed.
- **Forward compatibility** — when AWS adds a new service flag, the CLI gets it and you inherit it.

What it costs:

- **Subprocess latency.** A cold `aws codebuild list-builds-for-project` is ~300-800ms; subsequent calls are warmer but never free. Fine for human-paced TUI use; not great for tight polling loops.
- **JSON parsing on every call.** All `aws` invocations use `--output json`; you `serde_json::from_slice` the stdout. Schema drift between CLI versions is a real (but rare) hazard.
- **You have to have the CLI installed.** First-run `--check` should verify it (`which aws` or `aws --version`).

If you're building an integration against an AWS, GCP, Azure, or other "the vendor ships a first-class CLI" backend, this is the recommended pattern — clone `mnml-aws-codebuild` or `mnml-fs-s3`, swap the subprocess calls for your service's commands, and you've skipped the auth code entirely. Don't reach for an SDK unless you genuinely need streaming responses, long-lived connections, or sub-100ms latency.

### Cross-sibling handoffs

When one sibling's data points at another sibling's surface — a Lambda function's logs live in CloudWatch, an S3 bucket's events feed an EventBridge rule, a CodeBuild run's artifacts land in S3 — the natural move is a single-key handoff to the relevant sibling. The first instance: [`mnml-aws-lambda`](/manual/integrations/aws-lambda/)'s `l` chord launches [`mnml-aws-cloudwatch-logs`](/manual/integrations/aws-cloudwatch-logs/) on the focused function. The mechanism is a plain `std::process::Command::new("mnml-aws-cloudwatch-logs").spawn()` — no IPC, no shared state, just the sibling binary path on `$PATH`. If you're routing through a context (a focused function, an open bucket), pass it as a CLI flag (`--log-group /aws/lambda/<fn>` is the planned v0.2 of that chord). Treat the sibling like any other vendor CLI — if it's installed it'll resolve; if it isn't, toast that it's missing and move on.

## Wiring a launcher chip

Once your integration is installed, users can add a one-click chip to mnml's left rail by adding to their `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "your-thing"
glyph    = "\U000F0411"          # any Nerd Font glyph
fallback = "Y"
command  = ":term mnml-your-thing"
color    = "blue"
tooltip  = "Open your thing"
```

See [the launcher-icon strips](/manual/settings/#the-launcher-icon-strips) for the field reference.

## Get listed

Once your integration is published, send a PR to mnml adding it to [Community integrations](/manual/integrations/community/). The list page is a single Markdown file — one line per entry. The bar is low: it should build, run, and not be malware. We won't audit your code or gate on quality.

## Reference repos

The fastest path is: clone the closest reference repo, replace the backend file, rename in `Cargo.toml`, and ship.

| Reference | What it shows |
|---|---|
| [mnml-db-postgres](https://github.com/chris-mclennan/mnml-db-postgres) | SQL-shaped viewer with tabbed connections + query buffer + results table |
| [mnml-db-redis](https://github.com/chris-mclennan/mnml-db-redis) | Same shape but with a command playground + type-aware response rendering |
| [mnml-db-docdb](https://github.com/chris-mclennan/mnml-db-docdb) | NoSQL shape — find filter as JSON, results render as `_id` + document |
| [mnml-db-clickhouse](https://github.com/chris-mclennan/mnml-db-clickhouse) | HTTP-based backend instead of a binary driver — uses `reqwest` + `FORMAT JSON` |
| [mnml-db-dynamodb](https://github.com/chris-mclennan/mnml-db-dynamodb) | NoSQL shape with vendor-CLI auth — `aws dynamodb scan` + describe-table for the partition-key column |
| [mnml-tracker-jira](https://github.com/chris-mclennan/mnml-tracker-jira) | Tab-list shape — configurable JQL tabs, open-in-browser, periodic refresh |
| [mnml-aws-codebuild](https://github.com/chris-mclennan/mnml-aws-codebuild) | Vendor-CLI shell-out reference — Builds + Logs tabs over `aws` subprocesses |
| [mnml-fs-s3](https://github.com/chris-mclennan/mnml-fs-s3) | Object-store / tree shape — bucket tabs, prefix breadcrumb, download-to-cache |

## License + ownership

You own your repo. Use whatever license you want (the references are MIT). The mnml maintainers don't require copyright assignment, won't push to your repo, and won't take it over. The "family" framing is purely about discoverability and shared UX conventions — there's no legal or operational coupling.
