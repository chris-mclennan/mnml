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

_Nothing here yet — add items only after the shape is understood,
not at the speculation stage._
