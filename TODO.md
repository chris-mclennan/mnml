# mnml TODO

Living list of work that's been considered but deliberately deferred.
Not a wishlist — only items where the scope/shape is already understood
and the only thing missing is a session to do it in.

## HTTP

### gRPC support
**Status:** tabled 2026-06-19. Multi-day work.

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
**Status:** tabled 2026-06-19. Multi-day work.

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
