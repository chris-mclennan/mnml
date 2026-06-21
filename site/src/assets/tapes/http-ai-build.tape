# http-ai-build — `:http.ai_build` natural-language → curl
#
# `:http.ai_build` takes a one-line description of the HTTP request you
# want ("get the top 5 users from prod with bearer auth") and asks
# Claude to convert it into an exact curl command. The reply lands as a
# freshly-minted Request pane parked on the **Source** tab so the user
# can audit the curl before firing it.
#
# Wiring:
# - `:http.ai_build` → `App::http_ai_build_prompt` opens a Prompt
#   (`PromptKind::HttpAiBuild`, `src/app/http.rs` ~L450). Requires
#   `$ANTHROPIC_API_KEY`; toasts and bails otherwise.
# - Prompt-accept → `App::http_ai_build_accept` (~L467) spawns a worker
#   thread calling `crate::ai::api_client::nl_to_curl`
#   (`src/ai/api_client.rs` ~L271) — a non-streaming Anthropic Messages
#   call with a fixed system prompt steering the model toward a single
#   line of `curl` (no fences, no `$` prompt, explicit `-X <METHOD>` +
#   `-H` headers).
# - `App::drain_http_ai_build` (~L492) parses the reply via
#   `crate::http::parse`, opens a new Request pane, fills in url /
#   headers / body / `source_buffer` from the parsed shape and
#   `rp.edit_tab = EditTab::Source` so the curl is what the user sees
#   first.
#
# Flow recorded (vim input mode — `:` ex-cmdline is the driver):
# 1. Launch mnml on a tempdir with a seed README so `Ctrl+P` has
#    something to land focus on (an editor pane is needed for `:`
#    cmdline to be reachable).
# 2. `:http.ai_build` opens the prompt
#    ("Describe the request (NL → curl):").
# 3. Type the natural-language description.
# 4. Enter accepts; worker thread fires the Anthropic call. Toast
#    "http.ai_build: calling Claude…" lands.
# 5. Reply arrives within a few seconds; `drain_http_ai_build` opens a
#    new Request pane parked on the Source tab. The generated curl is
#    visible in the Source buffer; the toast updates to
#    "http.ai_build: ✓ ready (Source tab)".
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-ai-build.tape
#
# Precondition: `$ANTHROPIC_API_KEY` must be set in the shell that
# runs VHS — the worker is a real Anthropic Messages call.

Output site/src/assets/tapes/http-ai-build.gif

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
Type "echo '# ai-build demo workspace' > README.md"
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

# ── Stage 1: :http.ai_build opens the NL prompt ────────────────────────
# Prompt label reads: "Describe the request (NL → curl):"
Type ":http.ai_build"
Sleep 500ms
Enter
Sleep 1.5s

# ── Stage 2: type the natural-language description ─────────────────────
Type "get the top 5 users from prod with bearer auth"
Sleep 1.5s

# ── Stage 3: Enter sends the description to Claude ─────────────────────
# Toast lands: "http.ai_build: calling Claude…" — the prompt closes,
# focus returns to the editor pane while the worker thread runs.
Enter
Sleep 500ms

# ── Stage 4: wait for the Anthropic reply ──────────────────────────────
# `nl_to_curl` is a single non-streaming Messages call with a 30s
# client timeout; in practice the reply is back in 3-6s. Linger so the
# pane has time to appear once `drain_http_ai_build` parses the reply.
Sleep 8s

# ── Stage 5: settle on the new Request pane ────────────────────────────
# The new pane lands in Edit/Source view — the Source tab is selected
# and its buffer holds the curl Claude produced (single line, explicit
# -X / -H / --data, https://, {{TOKEN}} placeholder where auth was
# implied). Toast updates to "http.ai_build: ✓ ready (Source tab)".
Sleep 4s
