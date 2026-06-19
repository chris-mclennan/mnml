# http-bench-output — `:http.bench` against httpbin.org/get
#
# 1. Launch mnml in a tempdir pre-seeded with a get.curl pointed at
#    https://httpbin.org/get, plus a sample-trace.txt file capturing
#    the shape of what :http.bench writes to the system clipboard.
# 2. Open get.curl via Ctrl+P.
# 3. `:http.bench` fires the request 10× concurrent across 4 workers.
#    The headline toast lands: "bench summary — 10 samples in N ms".
# 4. Open sample-trace.txt to show the p50/p95/p99/max histogram the
#    real clipboard payload would hold.
#
# Why not paste the real clipboard? VHS's recording environment has
# no system clipboard the host process can read back. The trace shape
# is fixed (defined in `App::http_bench_active`), so showing a
# representative trace from a captured real run is faithful.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-bench-output.tape

Output site/src/assets/tapes/http-bench-output.gif

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
Type `echo "curl 'https://httpbin.org/get' -H 'Accept: application/json'" > get.curl`
Enter
Sleep 200ms
# Seed a representative trace file — the shape `App::http_bench_active`
# writes to the system clipboard. Numbers below are from a real run
# captured while writing this tape (`vhs <flow>.tape` then read the
# trailing toast).
Type `printf 'bench  GET https://httpbin.org/get\n  10 requests . 4 concurrent\n\nbench summary - 10 samples in 6279 ms (rate: 1.6 req/s)\n  latency ms - min 412 . p50 661 . p95 1842 . p99 1842 . max 1842 . mean 778\n  status: 2xx=10 3xx=0 4xx=0 5xx=0\n' > sample-trace.txt`
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

# ── open the .curl file ─────────────────────────────────────────────────
Ctrl+P
Sleep 800ms
Type "get"
Sleep 500ms
Enter
Sleep 1.5s

# ── fire the bench ──────────────────────────────────────────────────────
Type ":http.bench"
Sleep 500ms
Enter

# Wait for 10 fires (4-concurrent) against httpbin.org to complete.
# Toast lands with `bench summary — N samples in M ms`.
Sleep 7s

# ── open the trace file to show the full p50/p95/p99/max breakdown ──────
Type ":e sample-trace.txt"
Sleep 400ms
Enter
Sleep 2s

# ── settle on the histogram ─────────────────────────────────────────────
Sleep 3s
