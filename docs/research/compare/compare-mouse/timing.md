# compare-mouse — timing (120x40)

| side | binary | start event | first frame | peak RSS | rss samples | exit |
|------|--------|------------:|------------:|---------:|------------:|------|
| rust | `/Users/chrismclennan/Projects/mnml/target/release/mnml` | 2175.7 ms | 2185.0 ms | 111.2 MB | 219 | 0 |
| zig | `/Users/chrismclennan/Projects/mnml-zig-worktrees/scroll/zig-out/bin/mnml-zig` | 12.8 ms | 15.7 ms | 39.6 MB | 175 | 0 |

Per step, ms from the command's append: `ack` = the ack line in events.jsonl (applied), `dump` = the next screen.txt write after the ack (painted). A `wait_ms` step's ack includes its own sleep.

| # | step | rust ack | rust dump | zig ack | zig dump |
|---|------|---------:|----------:|--------:|---------:|
| 0 | `{"cmd":"key","key":"esc"}` | 32.3 | 75.9 | 34.8 | 81.0 |
| 1 | `{"cmd":"key","key":"esc"}` | 4.2 | 50.8 | 40.4 | 44.6 |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 145.0 | 148.9 | 5.4 | 82.9 |
| 3 | `{"cmd":"wait_ms","ms":800}` | 809.9 | 851.2 | 823.6 | 868.8 |
| 4 | `{"cmd":"click","col":50,"row":10}` | 4.0 | 45.8 | 1.4 | 2.8 |
| 5 | `{"cmd":"wait_ms","ms":150}` | 157.8 | 203.5 | 197.3 | 240.7 |
| 6 | `{"cmd":"click","col":32,"row":20}` | 3.9 | 5.2 | 2.6 | 48.3 |
| 7 | `{"cmd":"wait_ms","ms":150}` | 159.7 | 206.1 | 160.2 | 161.5 |
| 8 | `{"cmd":"click","col":15,"row":5}` | 5.2 | 49.4 | 44.1 | 55.5 |
| 9 | `{"cmd":"wait_ms","ms":400}` | 405.1 | 449.2 | 405.6 | 451.0 |
| 10 | `{"cmd":"click","col":33,"row":1}` | 41.5 | 42.7 | 37.3 | 38.6 |
| 11 | `{"cmd":"wait_ms","ms":300}` | 304.5 | 305.8 | 311.1 | 312.3 |
| 12 | `{"cmd":"scroll","col":60,"row":15,"dy":-1}` | 2.7 | 48.7 | 3.9 | 5.2 |
| 13 | `{"cmd":"wait_ms","ms":200}` | 214.4 | 215.7 | 209.7 | 211.0 |
| 14 | `{"cmd":"scroll","col":60,"row":15,"dy":-3}` | 45.4 | 47.2 | 5.2 | 50.7 |
| 15 | `{"cmd":"wait_ms","ms":200}` | 249.8 | 294.7 | 204.8 | 251.7 |
| 16 | `{"cmd":"scroll","col":60,"row":15,"dy":-10}` | 3.9 | 50.0 | 42.8 | 44.0 |
| 17 | `{"cmd":"wait_ms","ms":200}` | 208.3 | 254.4 | 206.7 | 208.0 |
| 18 | `{"cmd":"scroll","col":60,"row":15,"dy":-30}` | 44.6 | 87.8 | 5.0 | 48.4 |
| 19 | `{"cmd":"wait_ms","ms":200}` | 208.7 | 253.1 | 209.9 | 254.9 |
| 20 | `{"cmd":"scroll","col":60,"row":15,"dy":1}` | 43.9 | 45.1 | 6.5 | 7.8 |
| 21 | `{"cmd":"wait_ms","ms":200}` | 208.8 | 252.8 | 208.3 | 209.6 |
| 22 | `{"cmd":"scroll","col":60,"row":15,"dy":3}` | 4.1 | 46.8 | 9.1 | 53.6 |
| 23 | `{"cmd":"wait_ms","ms":200}` | 211.2 | 212.5 | 209.3 | 210.6 |
| 24 | `{"cmd":"scroll","col":60,"row":15,"dy":10}` | 6.4 | 7.7 | 4.0 | 5.3 |
| 25 | `{"cmd":"wait_ms","ms":200}` | 244.7 | 246.0 | 206.9 | 208.3 |
| 26 | `{"cmd":"scroll","col":60,"row":15,"dy":30}` | 44.2 | 87.2 | 4.1 | 48.8 |
| 27 | `{"cmd":"wait_ms","ms":200}` | 204.6 | 246.9 | 210.4 | 256.8 |
| 28 | `{"cmd":"drag","from_col":40,"from_row":6,"col…` | 2.8 | 4.1 | 18.6 | 60.6 |
| 29 | `{"cmd":"wait_ms","ms":150}` | 158.3 | 158.3 | 161.4 | 162.7 |
| 30 | `{"cmd":"click","col":45,"row":12}` | 2.8 | 3.9 | 5.2 | 6.5 |
| 31 | `{"cmd":"click","col":45,"row":12}` | 1.3 | 47.4 | 2.7 | 4.0 |
| 32 | `{"cmd":"wait_ms","ms":300}` | 308.4 | 354.0 | 310.1 | 311.4 |

Over the 18 non-wait steps — mean dump latency: rust 49.7 ms, zig 38.3 ms; slowest: rust 149 ms (step 2), zig 83 ms (step 2).
