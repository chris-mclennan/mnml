# compare-mouse — timing (120x40)

| side | binary | start event | first frame | peak RSS | rss samples | exit |
|------|--------|------------:|------------:|---------:|------------:|------|
| rust | `~/Projects/mnml/target/release/mnml` | 1986.1 ms | 1993.7 ms | 112.3 MB | 211 | 0 |
| zig | `~/Projects/mnml-zig-worktrees/mouse-fixes/zig-out/bin/mnml-zig` | 167.4 ms | 187.7 ms | 55.5 MB | 183 | 0 |

Per step, ms from the command's append: `ack` = the ack line in events.jsonl (applied), `dump` = the next screen.txt write after the ack (painted). A `wait_ms` step's ack includes its own sleep.

| # | step | rust ack | rust dump | zig ack | zig dump |
|---|------|---------:|----------:|--------:|---------:|
| 0 | `{"cmd":"key","key":"esc"}` | 25.3 | 71.8 | 4.6 | 54.2 |
| 1 | `{"cmd":"key","key":"esc"}` | 21.1 | 69.8 | 9.7 | 10.9 |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 104.4 | 108.8 | 24.7 | 362.3 |
| 3 | `{"cmd":"wait_ms","ms":800}` | 818.9 | 820.4 | 834.4 | 1030.0 |
| 4 | `{"cmd":"click","col":50,"row":10}` | 12.4 | 61.3 | 25.5 | 30.1 |
| 5 | `{"cmd":"wait_ms","ms":150}` | 168.9 | 220.1 | 173.0 | 177.6 |
| 6 | `{"cmd":"click","col":32,"row":20}` | 11.1 | 12.6 | 57.8 | 62.4 |
| 7 | `{"cmd":"wait_ms","ms":150}` | 160.4 | 161.9 | 177.8 | 182.3 |
| 8 | `{"cmd":"click","col":15,"row":5}` | 1.6 | 51.4 | 25.6 | 68.1 |
| 9 | `{"cmd":"wait_ms","ms":400}` | 419.6 | 465.4 | 416.6 | 418.0 |
| 10 | `{"cmd":"click","col":33,"row":1}` | 43.7 | 91.3 | 12.8 | 17.4 |
| 11 | `{"cmd":"wait_ms","ms":300}` | 326.3 | 373.9 | 328.7 | 331.8 |
| 12 | `{"cmd":"scroll","col":60,"row":15,"dy":-1}` | 9.6 | 57.6 | 25.2 | 29.8 |
| 13 | `{"cmd":"wait_ms","ms":200}` | 212.4 | 259.4 | 227.4 | 230.5 |
| 14 | `{"cmd":"scroll","col":60,"row":15,"dy":-3}` | 9.4 | 10.9 | 21.6 | 26.1 |
| 15 | `{"cmd":"wait_ms","ms":200}` | 208.6 | 210.2 | 228.3 | 232.8 |
| 16 | `{"cmd":"scroll","col":60,"row":15,"dy":-10}` | 9.3 | 50.7 | 22.4 | 25.5 |
| 17 | `{"cmd":"wait_ms","ms":200}` | 215.8 | 217.4 | 238.1 | 241.2 |
| 18 | `{"cmd":"scroll","col":60,"row":15,"dy":-30}` | 48.2 | 97.5 | 18.4 | 23.5 |
| 19 | `{"cmd":"wait_ms","ms":200}` | 218.5 | 220.0 | 217.0 | 221.5 |
| 20 | `{"cmd":"scroll","col":60,"row":15,"dy":1}` | 19.5 | 68.6 | 14.4 | 19.0 |
| 21 | `{"cmd":"wait_ms","ms":200}` | 207.9 | 209.4 | 233.5 | 238.1 |
| 22 | `{"cmd":"scroll","col":60,"row":15,"dy":3}` | 6.5 | 57.7 | 23.1 | 27.7 |
| 23 | `{"cmd":"wait_ms","ms":200}` | 207.0 | 255.2 | 235.9 | 240.4 |
| 24 | `{"cmd":"scroll","col":60,"row":15,"dy":10}` | 1.6 | 3.1 | 23.5 | 28.1 |
| 25 | `{"cmd":"wait_ms","ms":200}` | 213.2 | 260.0 | 218.0 | 222.6 |
| 26 | `{"cmd":"scroll","col":60,"row":15,"dy":30}` | 1.6 | 51.4 | 19.3 | 23.9 |
| 27 | `{"cmd":"wait_ms","ms":200}` | 222.2 | 223.8 | 220.3 | 223.3 |
| 28 | `{"cmd":"drag","from_col":40,"from_row":6,"col…` | 10.5 | 12.0 | 100.8 | 105.4 |
| 29 | `{"cmd":"wait_ms","ms":150}` | 162.4 | 211.6 | 167.4 | 172.0 |
| 30 | `{"cmd":"click","col":45,"row":12}` | 17.2 | 18.7 | 20.6 | 23.7 |
| 31 | `{"cmd":"click","col":45,"row":12}` | 3.1 | 4.7 | 26.4 | 29.4 |
| 32 | `{"cmd":"wait_ms","ms":300}` | 306.7 | 347.7 | 331.1 | 335.7 |

Over the 18 non-wait steps — mean dump latency: rust 50.0 ms, zig 53.8 ms; slowest: rust 109 ms (step 2), zig 362 ms (step 2).
