---
title: Bridge & Mount
description: How sibling tools (mnml-aws-*, mnml-db-*, mnml-forge-*, …) integrate with mnml — from env-var-only handoffs all the way up to a hosted UI pane that renders inside the editor.
---

mnml's **family** is a constellation of small sibling binaries
(`mnml-aws-cloudwatch-logs`, `mnml-db-postgres`, `mnml-forge-github`,
`mnml-fs-s3`, …) — each one a focused TUI for a specific service.
The **Bridge** is the protocol that lets those siblings *talk to*
mnml; **Mount** is the highest tier where a sibling takes over a
pane and renders directly into mnml's editor body. Both ship as
`mnml-bridge` — one crate, two integration depths.

This page is the field guide for using and building bridged
siblings.

## The four tiers

Bridge is layered. Each tier is purely additive — siblings opt in
to whatever depth makes sense for them.

| Tier | What | Sibling code |
|---|---|---|
| 1. Env vars | `MNML_WORKSPACE`, `MNML_THEME`, `MNML_IPC_DIR` set on every Pty mnml spawns. | Read on startup; zero protocol. |
| 2. JSONL host calls | Sibling appends JSONL commands to `$MNML_IPC_DIR/command`. | One file write per call. |
| 3. `mnml-bridge` SDK | Typed Rust wrapper around tiers 1 + 2. | `use mnml_bridge::*` |
| 4. Mount | Sibling owns an activity-bar icon + renders frames into a pane via Unix socket. | Connect, ratatui-render, ship `Frame`s. |

**Bridge** is the system as a whole. **Mount** is the specific tier
where the sibling takes over UI space.

## Tier 1 — env vars

Every Pty mnml spawns (`:term <binary>`, the activity-bar
shortcuts, the `mount.open` palette, etc.) is launched with these
in its environment:

```
MNML_WORKSPACE=/Users/you/Projects/your-repo
MNML_THEME=cyberdream
MNML_IPC_DIR=/Users/you/Projects/your-repo/.mnml/ipc
```

Siblings read these on startup. A theme-aware sibling can match
mnml's accent colours; a workspace-aware sibling can scope to the
active project; the IPC dir is where tier 2 talks back.

If you run a sibling **outside** mnml the env vars are absent; the
sibling should fall back to its standalone defaults.

## Tier 2 — JSONL host calls

The sibling writes one JSON object per line to
`$MNML_IPC_DIR/command`. mnml ingests the file each tick. These
commands are recognised:

| Command | Payload | Effect |
|---|---|---|
| `toast` | `{"text": "…"}` | Show a toast in mnml's chrome. |
| `open` | `{"path": "/abs/path"}` | Open the file in mnml's editor. |
| `open-pty` | `{"command": ["echo","hi"], "cwd": "/path"}` | Spawn a new Pty pane. |
| `set-activity-badge` | `{"section": "agents", "count": 3}` | Drive a notification chip on an activity-bar icon. |

Example — a sibling surfacing a result:

```sh
echo '{"cmd":"toast","text":"S3 sync complete · 47 files"}' \
  >> "$MNML_IPC_DIR/command"
```

Or programmatically from Rust:

```rust
use std::io::Write;

fn toast(message: &str) {
    let Some(dir) = std::env::var_os("MNML_IPC_DIR") else { return };
    let path = std::path::PathBuf::from(dir).join("command");
    let line = serde_json::json!({"cmd": "toast", "text": message});
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).create(true).open(&path) {
        let _ = writeln!(f, "{line}");
    }
}
```

That's tier 2 in 9 lines. Most siblings can stop here.

### Activity-bar badges

`set-activity-badge` is how a sibling drives the small
notification chip (`(3)`) on an activity-bar icon. The `section`
field is one of:

| Builtin section | Key |
|---|---|
| Explorer | `explorer` |
| Search | `search` |
| Source control | `git` |
| Run and debug | `debug` |
| Integrations | `integrations` |
| Sessions | `sessions` |
| Agents (local Claude/Codex) | `agents` |
| Cloud agents (Tattle QWE) | `cloud_agents` |

For a manifest-registered Mount sibling, the section key is the
manifest `id`.

`count = 0` clears the badge. The chip renders as `•` for `1`,
the digit for `2-9`, `+` otherwise.

## Tier 3 — `mnml-bridge` SDK

For Rust siblings, `mnml-bridge` is the typed wrapper. Add it as
a dep:

```toml
[dependencies]
mnml-bridge = "0.1"
```

The bare crate exposes only the wire types — small dep tree. To
get the **Mount client** (tier 4) you opt in:

```toml
mnml-bridge = { version = "0.1", features = ["client"] }
```

Most siblings won't need `client` — tier 2 covers everything
short of taking over a pane.

## Tier 4 — Mount

This is the deep integration. A Mount sibling:

- Registers an icon in the activity bar via a manifest file.
- When clicked, mnml spawns the sibling with
  `MNML_MOUNT_SOCKET=/path/to/socket.sock` set.
- The sibling connects to that socket, negotiates a `Hello`
  (geometry + theme), then streams `Frame` messages back. Each
  Frame is a 2D array of `Cell`s.
- mnml decodes the cells and stamps them into its own
  `ratatui::Frame` — the host terminal does the actual rendering,
  so font quality is always whatever the user's terminal renders
  (no GPU/font involvement in mnml itself).
- Input flows the other way: key + mouse events the user does in
  the pane area are forwarded to the sibling as `InputEvent`s.

### Registering an activity-bar icon

A Mount sibling drops a manifest in either of two dirs (workspace
beats user on id collision):

```
<workspace>/.mnml/mounts/<id>.toml
~/.config/mnml/mounts/<id>.toml
```

Manifest fields:

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Stable unique id. Also the badge key. |
| `name` | yes | Display label / pane title. |
| `binary` | yes | PATH name or absolute path. |
| `icon` | yes | Single Nerd Font glyph. |
| `color` | no | Named theme color — `red`/`orange`/`yellow`/`green`/`blue`/`cyan`/`teal`/`purple`/`pink`/`comment`. Defaults to cyan. |
| `tooltip` | no | Hover text. Falls back to `name`. |

Example — registering the Tattle test-executions browser:

```toml
id = "tattle-tests"
name = "Tattle tests"
binary = "mnml-tattle-tests"
icon = ""
color = "green"
```

mnml scans both manifest dirs at startup. To re-scan without a
restart, run the `mounts.refresh` palette command.

### Writing a Mount sibling

The minimum Mount sibling is ~30 lines using the `client`
feature. Connect, render a `ratatui::Buffer` into a `TestBackend`
each tick, ship it.

```rust
use mnml_bridge::{InputEvent, Mount};
use ratatui::{Terminal, backend::TestBackend};
use std::time::Duration;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut mount = Mount::connect_env()?;
    let g = mount.geometry();
    let mut terminal = Terminal::new(TestBackend::new(g.cols, g.rows))?;

    while !mount.is_done() {
        for ev in mount.drain_inputs() {
            // Handle key + mouse events here.
            if let InputEvent::Key { spec } = ev
                && spec == "ctrl+q"
            {
                return Ok(());
            }
        }

        // Resize follow-up: rebuild terminal if geometry changed.
        let g = mount.geometry();
        if terminal.size()?.width != g.cols {
            terminal = Terminal::new(TestBackend::new(g.cols, g.rows))?;
        }

        terminal.draw(|f| {
            f.render_widget(
                ratatui::widgets::Paragraph::new("Hello from a Mount sibling!"),
                f.area(),
            );
        })?;

        let buf = terminal.backend().buffer().clone();
        let _ = mount.send_frame_from_buffer(&buf);
        tokio::time::sleep(Duration::from_millis(33)).await;
    }
    mount.send_bye();
    Ok(())
}
```

That's it. `Mount::connect_env()` reads `MNML_MOUNT_SOCKET`,
performs the handshake, spawns a reader thread. The sibling owns
its tick cadence; ~30 fps is fine for most UI.

### Lifecycle

| Event | What happens |
|---|---|
| Activity-bar icon clicked | mnml binds a Unix socket, spawns the sibling with `MNML_MOUNT_SOCKET` set. |
| Sibling connects | mnml sends `HostMessage::Hello { geometry, theme }`. |
| Pane resized | mnml sends `Resize { geometry }`. |
| User keys/clicks in pane | mnml sends `Input { event }`. |
| Sibling renders | Ships `SiblingMessage::Frame { cells }`. mnml stamps into ratatui buffer. |
| Sibling exits cleanly | Sends `Bye`; mnml shows "sibling disconnected" placeholder. |
| Pane closed | mnml sends `Goodbye`, SIGKILLs the sibling, removes the socket. |

## Picking a tier

|If your sibling needs…| Use |
|---|---|
| Just visual consistency (theme colors) | Tier 1 (read `MNML_THEME`) |
| To surface progress / errors | Tier 2 (`toast`) |
| To open files in mnml's editor | Tier 2 (`open`) |
| To dispatch a follow-on operation as a pane | Tier 2 (`open-pty`) |
| To drive notification counts | Tier 2 (`set-activity-badge`) |
| A rich, custom panel that owns rail + body | Tier 4 (Mount) |

Most siblings are happy with tiers 1 + 2. Tier 4 is for tools
where Pty rendering doesn't fit the shape of the UI (the
`mnml-tattle-tests` 3-env-column dashboard is the canonical
example).

## See also

- [`/manual/activity-bar/`](/manual/activity-bar/) — where mount icons appear.
- [`/manual/family/`](/manual/family/) — the catalog of sibling tools.
- [`mnml-bridge` source](https://github.com/chris-mclennan/mnml/tree/main/crates/mnml-bridge) — the crate.
