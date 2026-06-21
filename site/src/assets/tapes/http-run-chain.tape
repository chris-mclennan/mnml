# http-run-chain — `:http.run_chain` picker → `[chain-trace]` scratch
#
# A chain is a sequence of `.curl` / `.http` requests where each step
# can capture values out of its response into variables the later
# steps `{{…}}`-template into their URL / headers / body. Chain files
# live in `<workspace>/.mnml/chains/*.chain.json`; the format is a
# JSON array of `{ "request": "<path>", "extract": { "VAR": "$.path" } }`
# (see `src/http/chain.rs` for the parser + the runner).
#
# Wiring:
# - `:http.run_chain` → `App::open_http_chain_picker` (~L343 in
#   `src/app/http.rs`) reads `.mnml/chains/*.chain.json`, builds a
#   PickerItem per file labelled `<name> · <N> step(s)`. Empty dir
#   toasts and bails. Detail line shows step count.
# - Picker accept → `App::http_chain_run_path` (~L392) spawns a worker
#   thread calling `crate::http::chain::run`, which interprets each
#   step in order, extracts variables, and writes a step-by-step
#   trace into a `&mut String`.
# - `App::drain_http_chain` (~L424) opens the trace as a
#   `[chain-trace]` scratch buffer with a `────` rule and a summary
#   line at the bottom (`✓ chain completed successfully` or
#   `✗ chain failed: …`).
#
# Flow recorded:
# 1. Pre-seed `.mnml/chains/example.chain.json` with a 2-step chain
#    pointing at two sibling `.curl` files (login.curl extracts a
#    `TOKEN` from `$.access_token`, then me.curl `{{TOKEN}}`s it
#    into its Authorization header). The chain's first step fires
#    against `http://127.0.0.1:19876/login` — a dead local port —
#    so `crate::http::send` returns a transport error and the chain
#    halts after step 1. The trace shows the step boundary +
#    failure message + summary line.
# 2. Launch mnml on the workspace with a README so an editor pane
#    has focus before `:` is reachable.
# 3. `:http.run_chain` opens the picker; the chain row shows
#    `example · 2 step(s)`.
# 4. Enter accepts; toast lands "chain: running example.chain.json…".
# 5. Worker fires the first step; transport error halts the run.
# 6. `[chain-trace]` scratch opens with:
#       ──── step 1/2 — POST http://127.0.0.1:19876/login
#       ────
#       ✗ chain failed: step 1: send: …
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-run-chain.tape

Output site/src/assets/tapes/http-run-chain.gif

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
Type "echo '# chain demo workspace' > README.md"
Enter
Sleep 200ms
Type "mkdir -p .mnml/chains"
Enter
Sleep 200ms

# Step 1 — login.curl. POST against a dead local port so the chain
# halts on step 1 with a transport error. We extract a TOKEN field
# from the (never-arriving) response just to show the extract shape.
Type `printf '%s' "curl -X POST 'http://127.0.0.1:19876/login' -H 'Content-Type: application/json' --data '{\"username\":\"demo\",\"password\":\"demo\"}'" > login.curl`
Enter
Sleep 200ms

# Step 2 — me.curl. The Authorization header templates the captured
# TOKEN. Never actually fires (chain halts at step 1).
Type `printf '%s' "curl 'http://127.0.0.1:19876/me' -H 'Authorization: Bearer {{TOKEN}}'" > me.curl`
Enter
Sleep 200ms

# The chain — login → extract TOKEN → me with {{TOKEN}} header.
Type `printf '%s' '[{"request":"login.curl","extract":{"TOKEN":"$.access_token"}},{"request":"me.curl"}]' > .mnml/chains/example.chain.json`
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

# ── focus an editor pane so `:` ex-cmdline is reachable ─────────────────
Ctrl+P
Sleep 800ms
Type "readme"
Sleep 500ms
Enter
Sleep 1.2s

# ── Stage 1: :http.run_chain opens the chain picker ────────────────────
# Picker title: "HTTP chains". Single row: `example · 2 step(s)`.
Type ":http.run_chain"
Sleep 500ms
Enter
Sleep 2.5s

# ── Stage 2: Enter accepts the focused row ─────────────────────────────
# Toast lands: "chain: running example.chain.json…". Worker thread
# fires step 1 against the dead local port; `crate::http::send`
# returns a connection error within ~1s and the chain halts.
Enter
Sleep 4s

# ── Stage 3: settle on the [chain-trace] scratch ───────────────────────
# Scratch body:
#   ──── step 1/2 — POST http://127.0.0.1:19876/login
#   ────
#   ✗ chain failed: step 1: send: …
# Toast updates with the failure summary at the same time.
Sleep 3s
