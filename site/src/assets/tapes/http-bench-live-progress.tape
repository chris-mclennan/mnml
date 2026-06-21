# http-bench-live-progress — live (done/total · Ns) ticking in the
# cmdline bar while `:http.bench` is in flight, then the histogram
# block opens as a `[bench-trace]` scratch when it finishes.
#
# The earlier `:http.bench` tape (http-bench-output.tape) shows the
# headline toast + the captured histogram, but doesn't capture the
# *live* progress chip on the cmdline bar — the surface added in
# `src/ui/cmdline_bar.rs` (search for `http_bench_progress`):
#
#     ⟳ bench (12/100 · 5s) running…
#
# The counter is an `AtomicU32` shared between the bench worker thread
# (incremented per completed request in
# `src/http/bench.rs::run_with_progress`) and the render path; the
# cmdline-bar refresh polls it every tick. When the worker finishes,
# `App::drain_http_bench_result` opens `[bench-trace]` with the full
# p50/p95/p99/max histogram + status-class breakdown.
#
# Flow recorded:
# 1. Pre-seed `get.curl` pointed at httpbin.org/get (a real upstream
#    so the live counter actually progresses — a dead port would
#    pin all workers on connect-fail and not exercise the ticker).
# 2. Open the .curl via Ctrl+P.
# 3. `:http.bench` — fires 10× across 4 workers (the hardcoded
#    arguments in `:http.bench`'s palette entry).
# 4. The cmdline bar at the bottom shows `⟳ bench (N/10 · Ns) running…`
#    ticking up.
# 5. On completion: `[bench-trace]` scratch opens; the toast lands
#    with the `bench summary` headline.
# 6. The trace body contains the latency histogram (min · p50 · p95
#    · p99 · max · mean) + status-class counts.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-bench-live-progress.tape

Output site/src/assets/tapes/http-bench-live-progress.gif

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

# ── open get.curl ───────────────────────────────────────────────────────
Ctrl+P
Sleep 800ms
Type "get"
Sleep 500ms
Enter
Sleep 1.5s

# ── fire :http.bench ────────────────────────────────────────────────────
# `:http.bench` is hardcoded to 10 fires across 4 workers (see
# `command.rs` ~L2838: `app.http_bench_active(10, 4)`).
Type ":http.bench"
Sleep 500ms
Enter

# ── linger so the live `(N/10 · Ns)` chip is visible on the cmdline
#    bar at the bottom of the viewport while the worker thread fires
#    the 10 requests against httpbin.org/get. ─────────────────────────
Sleep 8s

# ── on completion: `[bench-trace]` scratch opens automatically with
#    the full p50/p95/p99/max trace; the toast lands with the
#    bench summary headline (`bench summary — 10 samples in N ms`). ──
Sleep 4s

# Final frame: the histogram block — `latency ms — min M · p50 M ·
# p95 M · p99 M · max M · mean M` + `status: 2xx=10 …` — should fill
# the body of the `[bench-trace]` scratch.
Sleep 2.5s
