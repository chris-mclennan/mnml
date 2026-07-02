# http-history-global — `:http.history_global` cross-workspace picker
#
# Every `:http.send` mirrors a JSONL row into
# `~/.config/mnml/history-global.jsonl` (or wherever
# `$MNML_HISTORY_GLOBAL_PATH` points — used by tests + this tape so
# we don't pollute the real user log). The mirror carries a
# `workspace` label so the picker can show which project the request
# came from. Recovery scenario: "I remember firing that request, but
# which project was I in?"
#
# Wiring:
# - `:http.history_global` → `App::open_http_history_global`
#   (`src/app/http.rs` ~L1597) calls
#   `crate::http::history::tail_global(100)` then opens a
#   `PickerKind::HistoryRows` picker. Each item: title is
#   `<METHOD> <short-url>`; detail is `<workspace> · <status> · <ms>`
#   (or `… · FAILED · <ms>` on transport error). Empty file toasts +
#   bails.
# - `tail_global` (`src/http/history.rs` ~L126) is a tail-truncated
#   read of the global log, most-recent-last.
# - `global_history_path` (~L116) honours `$MNML_HISTORY_GLOBAL_PATH`
#   before falling back to `~/.config/mnml/history-global.jsonl`.
#
# Flow recorded:
# 1. Pre-seed a tempfile with several JSONL rows across multiple
#    workspaces (mnml, acme-api, mixr) — varied methods, statuses,
#    durations — to make the cross-workspace surface obvious.
# 2. Export `MNML_HISTORY_GLOBAL_PATH` to point mnml at that file.
# 3. Launch mnml on a tempdir.
# 4. `:http.history_global` opens the picker; title reads
#    "HTTP history · all workspaces". Each row shows
#    `<METHOD> <host/path>` + detail `<workspace> · <status> · <ms>`.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-history-global.tape

Output site/src/assets/tapes/http-history-global.gif

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
Type "echo '# history-global demo workspace' > README.md"
Enter
Sleep 200ms

# Point mnml at a sandboxed global-history file so the demo doesn't
# pollute the real `~/.config/mnml/history-global.jsonl`.
Type "export MNML_HISTORY_GLOBAL_PATH=$MNML_DEMO/history-global.jsonl"
Enter
Sleep 200ms

# Seed the file with rows from 4 different workspaces. Shape matches
# what `crate::http::history::append_global` writes (ts / workspace /
# workspace_path / method / url / status / duration_ms / body_bytes /
# error). 7 entries — 6 successes + 1 transport failure.
Type `printf '%s\n' '{"ts":1718900001000,"workspace":"mnml","workspace_path":"/Users/me/Projects/mnml","method":"GET","url":"https://api.github.com/repos/chris-mclennan/mnml","status":200,"duration_ms":182,"body_bytes":4821,"error":null}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 150ms
Type `printf '%s\n' '{"ts":1718900002000,"workspace":"acme-api","workspace_path":"/Users/me/Projects/acme-api","method":"POST","url":"https://api.example.dev/v1/auth/login","status":200,"duration_ms":341,"body_bytes":612,"error":null}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 150ms
Type `printf '%s\n' '{"ts":1718900003000,"workspace":"acme-api","workspace_path":"/Users/me/Projects/acme-api","method":"GET","url":"https://api.example.dev/v1/merchants?limit=20","status":200,"duration_ms":97,"body_bytes":9821,"error":null}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 150ms
Type `printf '%s\n' '{"ts":1718900004000,"workspace":"mixr","workspace_path":"/Users/me/Projects/mixr","method":"GET","url":"https://api.beatport.com/v4/catalog/tracks?per_page=10","status":401,"duration_ms":221,"body_bytes":58,"error":null}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 150ms
Type `printf '%s\n' '{"ts":1718900005000,"workspace":"mnml","workspace_path":"/Users/me/Projects/mnml","method":"POST","url":"https://httpbin.org/post","status":200,"duration_ms":418,"body_bytes":312,"error":null}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 150ms
Type `printf '%s\n' '{"ts":1718900006000,"workspace":"docs","workspace_path":"/Users/me/Projects/docs","method":"GET","url":"https://api.openai.com/v1/models","status":null,"duration_ms":3001,"body_bytes":null,"error":"connect timeout"}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 150ms
Type `printf '%s\n' '{"ts":1718900007000,"workspace":"acme-api","workspace_path":"/Users/me/Projects/acme-api","method":"DELETE","url":"https://api.example.dev/v1/sessions/abc123","status":204,"duration_ms":151,"body_bytes":0,"error":null}' >> $MNML_HISTORY_GLOBAL_PATH`
Enter
Sleep 200ms

Type "clear"
Enter
Sleep 400ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
# Inherits MNML_HISTORY_GLOBAL_PATH from the parent shell — mnml's
# `global_history_path` honours it before falling back to
# `~/.config/mnml/history-global.jsonl`.
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

# ── Stage 1: :http.history_global opens the picker ─────────────────────
# Title: "HTTP history · all workspaces". Rows show
# `<METHOD> <host/path>` + detail `<workspace> · <status> · <ms>`.
# Most-recent first (the picker reverses tail order so the
# DELETE-on-acme-api entry lands at the top).
Type ":http.history_global"
Sleep 500ms
Enter
Sleep 2s

# ── Stage 2: scroll through the entries to show the workspace mix ──────
# `j` walks down through the rows — each detail line surfaces a
# different workspace (acme-api, mixr, mnml, docs…) so the
# cross-workspace nature of the surface is clear.
Down
Sleep 600ms
Down
Sleep 600ms
Down
Sleep 600ms
Down
Sleep 600ms

# ── Stage 3: settle on the full picker view ────────────────────────────
Sleep 3s
