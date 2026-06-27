# mnml TODO

Living list of work that's been considered but deliberately deferred.
Not a wishlist — only items where the scope/shape is already understood
and the only thing missing is a session to do it in.

## HTTP

### gRPC support
**Status:** v1 (external `grpcurl` shell-out) **shipped** — see
commit log for `:grpc.send`. Active .grpc JSON file shape:
`{ server, method, plaintext?, headers?, message }`. Output lands
in `[grpc-response]` scratch.

Native client (`tonic` + `prost` + `prost-reflect` for runtime
descriptor parsing) genuinely tabled. Adds ~50 deps including
build-time codegen tooling, and dynamic gRPC requires server-side
reflection support which not all environments expose. Honest
read: the shell-out covers what 90% of users want (they already
have `grpcurl` on PATH for one-off gRPC calls); the native
client doesn't add product value commensurate with the
implementation complexity for an editor.

Pick up if/when a real workflow needs sub-100ms gRPC dispatch
(e.g. inline assertions during a bench run) or there's reason
to ship mnml to environments without grpcurl.

Why deferred: needs protocol-design discussion before writing code.
gRPC is HTTP/2 + protobuf wire format. The natural mnml integration
shape is one of three:

1. **External `grpcurl` shell-out** — least invasive. `.grpc` files
   describe a call (`service.Method` + JSON message body), `:http.send`
   on a `.grpc` file shells out to `grpcurl`. Trades: dead-simple,
   reuses existing pane, but requires `grpcurl` on PATH and inherits
   its auth/cert handling.
2. **Native `tonic` client** — true Rust client. Mnml would parse
   `.proto` files (or accept FileDescriptorSet from reflection),
   surface services/methods in a picker, encode user-provided JSON
   into protobuf binary. Trades: full control, but bumps Cargo.toml
   significantly (tonic + prost + protobuf-codegen) and shifts the
   `http::send` chokepoint to a dual-protocol design.
3. **reqwest-only HTTP/2 mode** — fire raw HTTP/2 + protobuf-typed
   body. Trades: doesn't really exist for protobuf — gRPC has its own
   framing layer (Length-Prefixed Messages, trailers, status codes)
   that reqwest doesn't speak.

Pick #1 to ship something, #2 if mnml's value-add justifies the dep
churn. Discuss before coding.

### WebSocket support
**Status:** v1 (external `websocat` shell-out, one-shot
fire-and-receive) **shipped** as `:ws.send`. Active .ws JSON
file shape: `{ url, message, timeout_ms?, headers? }`. Output
lands in `[ws-response]` scratch.

**v2 (native persistent connection) also shipped**: `:ws.connect`
prompts for a wss:// URL, spawns a worker thread on `tungstenite`
(already in tree for CDP). Incoming messages stream into a
`[ws-<host>]` scratch buffer with `← text` per line; outgoing
appear with `→ text`. `:ws.send_message` prompts for a message
to push over the live connection; `:ws.disconnect` closes.

Single connection per App for v1 (multi-connection would need a
proper `Pane::Websocket` variant + the ~10 match-arm updates;
queued). Subprotocol selection + ping-interval tuning + auto-
reconnect also queued for v2.

Why deferred: needs protocol-design discussion before writing code.
Possible shapes:

1. **`Pane::Websocket`** — new pane variant with a connection state
   machine (connecting → open → closing → closed), a live message
   log (one row per frame in/out), and a typed-message input at the
   bottom. Reuses ratatui-style scrollback similar to Pty panes.
2. **`:ws.send` palette command + transient log** — minimal:
   `:ws.send wss://… text/binary` opens a connection, sends one frame,
   prints the response, closes. No persistent pane state.
3. **Hybrid:** start with #2 (one-shot), graduate to #1 if users
   want to keep connections open across commands.

The cookie jar from f3f4c53 would extend naturally to WebSocket if
the same domain is involved (WS reuses HTTP cookies on the
upgrade handshake). Auth presets would also apply directly.

Pick #2 for v1 if/when this lands. Discuss before coding.

## Other (uncategorized)

### Multi-pane siblings (Mount or Pty)
**Status:** deferred 2026-06-26 — captured before it gets baked in.

Today: each Mount manifest = one Mount pane (one UDS, one render
loop). Each Pty profile = one Pty pane. A sibling that wants
multiple visual surfaces (main view + detail panel, dashboard +
log tail, …) has to either render both inside one pane (manual
internal split) or use the `OpenPty` tier-2 IPC to spawn a second
Pty as a side effect.

That's fine for today's single-pane siblings but won't scale to
richer integrations. Bake the multi-pane assumption into the
protocol now so we don't have to retrofit.

Shape (draft — discuss before coding):
  - Manifest gains `[[panes]]` array — each entry has its own
    `id`, `name`, `icon`, `color`, and an optional `mode`
    selector that mnml passes to the sibling on spawn
    (`--mode list`, `--mode detail`, etc.). Each entry registers
    its own activity-bar icon.
  - Clicking icon N spawns the sibling with `--mode <n.mode>` —
    or, if it's already running and the sibling registered itself
    for multiplexing, sends an "open pane" message over the
    existing UDS.
  - On the Pty side: a sibling can send a tier-2
    `OpenAdditionalPty { label, cmd, args, alongside? }` IPC to
    open companion panes that mnml tracks as related (e.g. closes
    them together if the user closes the parent).

Open questions: how does mnml know two panes are "the same
sibling" for status / cleanup purposes? Is it parent-PID, manifest
id, or a sibling-asserted group token? Keep cleanup safe under
crashes (sibling main pane dies, side panel becomes orphan).

### Pre-built sibling binaries (no bundling)
**Status:** deferred 2026-06-26. User explicitly chose NOT to
bundle siblings into mnml core ("the name is minimal — if the
ecosystem grows, mnml shouldn't gatekeep which integrations are
core enough to ship"). Compile time on first install (~30-60s)
remains the main UX cost; auto-retry (commit 9460403) covers the
"forgot to re-click" half of the pain.

Next step when ready: GitHub Releases with pre-built signed
binaries per sibling, served via `cargo-binstall` (or a mnml
built-in downloader). Reuse the same standard-tier runner set
mnml itself uses (audit 2026-06-26 — all five are free on public
repos):
  - macos-14 (Apple Silicon) — `aarch64-apple-darwin`
  - macos-15-intel — `x86_64-apple-darwin`
  - windows-2022 — `x86_64-pc-windows-msvc`
  - ubuntu-22.04-arm — `aarch64-unknown-linux-gnu`
  - ubuntu-22.04 — `x86_64-unknown-linux-gnu`

DON'T switch to `*-xlarge` or `*-large` runners — those are
paid even on public repos.

The existing `scripts/notarize-dmg.sh` cert plumbing
(`APPLE_DEVELOPER_ID_CERT_BASE64` env) can be reused per sibling
repo's CI workflow. ~15 min per repo to set up; 32 repos → ~8
hours mechanical work; ~$0/year ongoing.

Trigger: push-to-main publishes to a `main-latest` GitHub
release. `cargo-binstall` picks up the latest binary; no manual
tagging required, no forgotten-fix risk.

### Audit + re-tag siblings post-tmnl-protocol removal
**Status:** caught 2026-06-26 when a user `:install`-ed
`mnml-aws-cloudwatch-logs` and the build broke on a missing
`tmnl-protocol` workspace member. Pinned `cloudwatch_logs` to
`"main"` as a stopgap (see family_catalog.rs).

Background: 2026-06-22 we ripped tmnl-protocol out of every
sibling repo (mnml became terminal-agnostic — see commit
ce99b59 / memory). Most sibling repos still have tagged
releases (v0.1.0, v0.2.0, …) that predate the removal and
reference `tmnl-protocol` as a path/workspace dep. `cargo
install` on those tags fails immediately.

Required work (per sibling, ~30 to audit):
  1. In each `mnml-*` repo's main branch, verify the workspace
     Cargo.toml no longer lists `tmnl-protocol`
  2. If it still does, remove it + bump the version
  3. Tag a new release (v0.1.1 / v0.2.1 / etc.)
  4. Bump that sibling's `pinned_version` in
     family_catalog.rs back from `"main"` to the new tag

Easier in parallel — agent-able. Each sibling repo is small;
the fix per repo is mechanical.

Why deferred: cross-repo coordination + ~30 small PRs. The
stopgap (pin → main) works for users who hit it one-off.

### In-app icon designer for siblings + integrations
**Status:** deferred 2026-06-26 — user asked for it.

Today: each `family_catalog::FamilySibling` (35+ entries) carries
a hand-picked Nerd Font glyph as its activity-bar / rail icon.
Picking generic Nerd Font glyphs for real-company products
(AWS Lambda → rocket, Datadog → dog, Stripe → card…) looks
random and slightly off-brand. We already shipped one-off
custom icons for Claude Code + Codex that the user actually
liked. Want to generalize.

Shape: user drops an image (PNG/SVG) on the rail/integrations
overlay or runs `:icon.create <integration-id>`. We:
  1. Open a designer pane that lets the user crop, threshold,
     and scale the image into a 16×16 / 24×24 monochrome grid
     (one cell per terminal cell).
  2. Either embed it directly as a Sixel/Kitty graphics fragment
     in the rail row (when the terminal supports it — we already
     have this code path for image preview) OR encode it as a
     custom-glyph entry in `~/.config/mnml/icons/` that the rail
     renderer prefers over the Nerd Font fallback.

Why deferred: needs decisions on (a) image → glyph algorithm
(otsu threshold? edge-detect? user-painted?), (b) rendering
substrate (Sixel vs. Kitty vs. precomputed font slots), and
(c) how the user-stored icon overrides the catalog default.
Don't build until shape is settled — a half-done image flow
is worse than just keeping the Nerd Font icons.

Pick up when the user has a few hours and an integration whose
current glyph annoys them enough to drive the design.
