# http-schema-validate — sidecar .schema.json validation footer
#
# Drop a sibling `<request>.schema.json` next to a `.curl` / `.http` /
# `.rest` file and mnml validates every response body against it
# after `:http.send`. The result lands as a footer on the response
# view:
#
#     ✓ Schema valid (users.schema.json)
#
# …or:
#
#     ✗ Schema: 2 errors (users.schema.json) — :http.show_schema_errors
#
# The footer renderer lives in `src/ui/request_view.rs` (search for
# `schema_footer_line`). The validation itself runs in
# `src/http/schema.rs::validate_for`, which resolves the sidecar
# (filename stem + `.schema.json`) and runs the body through a JSON
# Schema validator. `:http.show_schema_errors` opens the full list in
# a `[schema-errors]` scratch buffer; `:http.revalidate_schema`
# re-runs the validation without re-firing the request (useful after
# editing the sidecar).
#
# Flow recorded:
# 1. Pre-seed `users.curl` + sibling `users.schema.json` requiring
#    `name` to be a string, plus a `.mock.json` returning a body
#    where `name: 42` (invalid — number, not string).
# 2. Open `users.curl` via Ctrl+P.
# 3. `:http.send` fires the request (fails fast against a dead port).
# 4. `:http.replay_mock` injects the pre-seeded mock response so the
#    pane has a Done body to validate against — works offline + is
#    the same pattern `tests/e2e/http/http-schema-validate.test`
#    uses to drive this flow deterministically.
# 5. `:http.revalidate_schema` re-runs validation — the response
#    footer flips to `✗ Schema: 1 error (users.schema.json)`.
# 6. `:http.show_schema_errors` opens `[schema-errors]` with the
#    full validator output (path / message / expected type).
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-schema-validate.tape

Output site/src/assets/tapes/http-schema-validate.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1280
Set Height      760
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ───────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Sleep 200ms

# A curl pointing at a dead local port — :http.send fails fast, then
# :http.replay_mock injects the canned response below. Same trick the
# http-mock-round-trip e2e test uses.
Type `echo "curl 'http://127.0.0.1:19876/users'" > users.curl`
Enter
Sleep 200ms

# Mock response — body is intentionally invalid against the schema
# (name should be a string per the .schema.json below; we return 42).
Type `printf '%s' '{"status":200,"status_text":"OK","headers":[["content-type","application/json"]],"body":"{\"name\":42}","ts":1}' > users.curl.mock.json`
Enter
Sleep 200ms

# JSON Schema — requires `name` as a string + an `email` field.
Type `printf '%s' '{"type":"object","required":["name","email"],"properties":{"name":{"type":"string"},"email":{"type":"string","format":"email"}}}' > users.schema.json`
Enter
Sleep 200ms

Type "clear"
Enter
Sleep 400ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml . --input vim"
Sleep 400ms
Enter
Sleep 3s

Escape
Sleep 600ms

# ── open users.curl ─────────────────────────────────────────────────────
Ctrl+P
Sleep 800ms
Type "users.curl"
Sleep 500ms
Enter
Sleep 1.5s

# ── Stage 1: :http.send — fires (fails fast against dead port) ─────────
# Connection failure spawns a Request pane in Failed state; focus
# stays on the editor pane underneath. We Escape between every
# cmdline transition to drop any auto-opened popup / picker so the
# `:` next opens a clean cmdline (the Response view's `a` chord
# would otherwise consume the `a` in `replay_mock`).
Escape
Sleep 200ms
Type ":http.send"
Sleep 500ms
Enter
Sleep 3s

# ── Stage 2: :http.replay_mock — inject the canned response ────────────
# The pane now holds a Done response with body `{"name":42}` + the
# `content-type: application/json` header. The schema sidecar gets
# resolved at this point and the footer shows the validation result
# (`✗ Schema: N errors` — name isn't a string, email is missing).
Escape
Sleep 200ms
Escape
Sleep 200ms
Type ":http.replay_mock"
Sleep 500ms
Enter
Sleep 3s

# ── Stage 3: :http.revalidate_schema — re-run validation explicitly ─────
# The initial send path doesn't validate against the mock body —
# replay_mock writes the response with `schema_result: None`. The
# revalidate call is what actually runs the JSON-Schema validator
# against the mock'd body, populates the footer, and toasts the
# `✗ schema re-validated: N error(s)` headline.
Escape
Sleep 200ms
Escape
Sleep 200ms
Type ":http.revalidate_schema"
Sleep 500ms
Enter
Sleep 3s

# Linger on the response view so the `✗ Schema: N errors …` footer is
# readable.
Sleep 1.5s

# ── Stage 4: :http.show_schema_errors — open the full error list ───────
Escape
Sleep 200ms
Escape
Sleep 200ms
Type ":http.show_schema_errors"
Sleep 500ms
Enter
Sleep 4s

# Final frame: `[schema-errors]` scratch open with the numbered list
# of validator errors (`✗ Schema validation failed (users.schema.json)`
# header + the per-error path / message).
Sleep 2s
