---
title: Zig SDK (bridge v2)
description: The integration surface for mnml 0.3.0 — the bridge v2 wire, the mnml-sdk Zig package, and where the 0.2.x Rust integrations stand.
---

mnml 0.3.0 does not run the 0.2.x integrations. The `mnml-bridge` crate they link against speaks bridge v1, and the Zig host speaks v2 — a fresh encoding, not a compatibility layer. Integrations are being rewritten in Zig against a Zig-native SDK, jira and bitbucket first, as a phase after the 0.3.0 cutover. If a Rust integration is part of your day, [pin 0.2.x](/manual/upgrading-to-0-3/#pin-02x) until its Zig version lands.

This page is a stub for that work. What exists today is the wire and the SDK package, both documented in the mnml-zig repo; the rest of this page says what they are so you can decide whether to build against them now.

## What 0.3.0 has

- **`:term <binary>`** opens any installed program as a pty pane — the same escape hatch 0.2.x had. A pure-launcher integration that only ever shelled out to a CLI needs nothing more than this.
- **Bridge v2** — the mount wire. mnml binds a Unix socket (`<ipc dir>/mounts/<pid>-<n>.sock`; Unix sockets on Windows too, 10 1803+), spawns the integration with `MNML_MOUNT_SOCKET`, `MNML_PROTOCOL=2`, `MNML_WORKSPACE`, `MNML_THEME`, `MNML_IPC_DIR` and one `MNML_SETTING_<KEY>` per manifest setting, and the two sides exchange 4-byte little-endian length-prefixed JSON frames. Every union is externally tagged (`{"<tag>": payload}`); a colour is `{"index":4}` or `{"rgb":[r,g,b]}` and nothing else. Host → integration: `hello`, `resize`, `input`, `focus`, `goodbye`. Integration → host: `frame` (whole screen or dirty rows), `title`, `cursor`, `toast`, `command`, `bye`. The contract is [`docs/BRIDGE.md`](https://github.com/chris-mclennan/mnml-zig/blob/main/docs/BRIDGE.md).
- **`mnml-sdk`** — the Zig package (`sdk/mnml-sdk` in the repo; Zig 0.16.0, no dependencies beyond `std`). `Mount.connectEnv` connects and reads `hello`; `mount.next(arena)` blocks for one host message; `Frame` is the cell grid with dirty-row tracking, so `mount.send(&frame)` ships the whole screen once and only changed rows after; `mount.setTitle`, `setCursor`, `toast`, `command(id)` and `bye` cover the small senders. `--install` writes the manifest — a ZON file at `~/.config/mnml/integrations/<id>.zon` — with `sdk.manifest.write`. The sample, `sdk/examples/hello`, is about 160 lines and is what mnml's own integration test spawns. The walkthrough is [`docs/SDK.md`](https://github.com/chris-mclennan/mnml-zig/blob/main/docs/SDK.md).
- **Tier 2** — anything mnml spawned, socket or not, can append JSON lines to `$MNML_IPC_DIR/command`: register a command, toast, progress, a statusline segment, an activity badge, a notification. `sdk.Ipc.fromEnv` wraps them.

## What it does not have yet

- The Zig rewrites of the 0.2.x integrations. None ship with 0.3.0.
- Manifest fields beyond the core set — `context_menu[]`, `menu_bar[]`, `statusline[]`, `auth[]`, `values_sources[]` are parsed and shown, but wiring them into mnml's menus and auth store is a later slice.
- A published package. Until the SDK is tagged, depend on it by path (`.mnml_sdk = .{ .path = "../mnml-zig/sdk/mnml-sdk" }` in `build.zig.zon`).
- A page here that goes deeper than this one. The 0.2.x [Building integrations](/manual/integrations/building/) page describes the launcher-TOML and Rust-sibling shapes; on 0.3.0 the manifest is ZON and the sibling is Zig.

## Next

- [Upgrading to 0.3](/manual/upgrading-to-0-3/) — what changed, what was cut, how to pin
- [Integrations overview](/manual/integrations/overview/) — the 0.2.x model
- [Building integrations](/manual/integrations/building/) — the 0.2.x authoring guide
