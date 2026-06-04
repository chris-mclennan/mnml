---
title: Building integrations
description: How to build your own mnml integration — a standalone CLI that opt-in becomes a native mnml pane via the blit-host protocol.
---

mnml integrations are **standalone ratatui CLIs** that follow a few conventions and optionally speak [`tmnl-protocol`](https://crates.io/crates/tmnl-protocol) over a Unix domain socket so they can be hosted as a native mnml pane.

They are not plugins, extensions, or scripts. There is no mnml runtime, no plugin loader, no manifest, no registration step. Each integration is a regular Rust binary that:

1. Works **standalone** in any terminal (Terminal.app, iTerm2, tmux, ssh — anywhere).
2. Works **inside mnml as a pty pane** automatically (same as Claude Code, Codex, shell).
3. Optionally works **inside mnml as a native blit pane** via the `--blit <socket>` flag, which gives it mnml's theme palette and click events.

The "opt-in to native hosting" piece is small — ~485 lines of `blit.rs` you copy from a reference repo. Everything else is just your viewer.

## Three deployment modes

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
│  (open a terminal pane in mnml, run the binary)                     │
│  → runs as a regular pty — same as any CLI tool                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  Mode 3: Native BlitHost pane inside mnml                           │
│                                                                     │
│  :host.launch mnml-db-postgres                                      │
│  → mnml spawns it with --blit <socket>, renders its cell grid       │
│    natively, forwards keys + clicks. Theme palette piped in.        │
└─────────────────────────────────────────────────────────────────────┘
```

Modes 1 and 2 require nothing from your code beyond being a normal TUI binary. Mode 3 requires the `--blit` flag and a copy of `blit.rs`.

## Anatomy of an integration

Look at [`mnml-db-postgres`](https://github.com/chris-mclennan/mnml-db-postgres):

```
mnml-db-postgres/
├── Cargo.toml                 # deps + binary metadata
├── README.md
└── src/
    ├── main.rs                # CLI parsing + picks TUI vs --blit vs --check
    ├── app.rs                 # all app state — connections, query buffer, results
    ├── config.rs              # reads ~/.config/mnml-db-postgres.toml
    ├── postgres.rs            # the only file unique to this integration
    ├── keys.rs                # action enum + key → action mapping
    ├── ui.rs                  # ratatui draw + event loop
    └── blit.rs                # tmnl-protocol over UDS — copied verbatim
```

~1,500 lines of Rust total. The only file you really write from scratch is the one that talks to your backend (`postgres.rs` here; `jira.rs` for the Jira viewer; `redis_client.rs` for Redis; etc.).

Everything else is the family scaffold.

## The conventions

These aren't enforced by any tool, but following them makes your integration feel at home next to the others:

### Naming

`mnml-<class>-<name>` — e.g.:

- `mnml-db-postgres`, `mnml-db-mysql`, `mnml-db-sqlite`, `mnml-db-clickhouse`
- `mnml-tickets-jira`, `mnml-tickets-github`, `mnml-tickets-shortcut`
- `mnml-logs-cloudwatch`, `mnml-logs-loki`, `mnml-logs-datadog`

Whatever class makes sense. The `mnml-` prefix is the only "rule" — it's how `cargo search mnml-` discovers them.

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
mnml-<thing> --blit <socket>   # blit-host mode (mode 3); no terminal takeover
```

`--check` should show: where the config came from, which connections / tabs are configured, whether auth succeeds. This is the "is my setup right?" command.

## Opting into blit-host mode

If you want your integration to be hostable as a native mnml pane (`:host.launch <binary>`), do these three things:

1. **Add the `tmnl-protocol` dependency:**

   ```toml
   tmnl-protocol = "0.0.3"
   ```

2. **Copy `blit.rs` verbatim** from any of the reference repos — e.g. [`mnml-db-postgres/src/blit.rs`](https://github.com/chris-mclennan/mnml-db-postgres/blob/main/src/blit.rs). It's a pure wire-format adapter; you shouldn't need to modify it.

3. **Wire `--blit <socket>` in `main.rs`:**

   ```rust
   if let Some(socket_path) = args.blit {
       return blit::run(socket_path, app).await;
   }
   ```

   In standalone mode, the same `app` is driven by `crossterm` events; in blit mode, it's driven by tmnl-protocol messages over the UDS. Same App, different transport.

That's it. mnml hosts you via `:host.launch <your-binary>` and renders your cell grid as a regular `Pane::BlitHost` pane.

## Wiring a launcher chip

Once your integration is installed, users can add a one-click chip to mnml's left rail by adding to their `~/.config/mnml/config.toml`:

```toml
[[ui.integration_icon]]
id       = "your-thing"
glyph    = "\U000F0411"          # any Nerd Font glyph
fallback = "Y"
command  = ":host.launch mnml-your-thing"
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
| [mnml-tickets-jira](https://github.com/chris-mclennan/mnml-tickets-jira) | Tab-list shape — configurable JQL tabs, open-in-browser, periodic refresh |
| [mnml-tickets-github](https://github.com/chris-mclennan/mnml-tickets-github) | Same shape as Jira but talks GitHub Issues / Pulls |

## License + ownership

You own your repo. Use whatever license you want (the references are MIT). The mnml maintainers don't require copyright assignment, won't push to your repo, and won't take it over. The "family" framing is purely about discoverability and shared UX conventions — there's no legal or operational coupling.
