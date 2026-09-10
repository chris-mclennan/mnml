# compare-mouse — timing (120x40)

| side | binary | start event | first frame | peak RSS | rss samples | exit |
|------|--------|------------:|------------:|---------:|------------:|------|
| rust | `/Users/chrismclennan/Projects/mnml/target/release/mnml` | 2259.4 ms | 2269.3 ms | 111.9 MB | 210 | 0 |
| zig | `/Users/chrismclennan/Projects/mnml-zig-worktrees/scroll/zig-out/bin/mnml-zig` | 139.5 ms | 152.3 ms | 55.0 MB | 182 | 0 |

Per step, ms from the command's append: `ack` = the ack line in events.jsonl (applied), `dump` = the next screen.txt write after the ack (painted). A `wait_ms` step's ack includes its own sleep.

| # | step | rust ack | rust dump | zig ack | zig dump |
|---|------|---------:|----------:|--------:|---------:|
| 0 | `{"cmd":"key","key":"esc"}` | 61.9 | 111.0 | 27.2 | 28.8 |
| 1 | `{"cmd":"key","key":"esc"}` | 9.4 | 58.7 | 18.6 | 67.5 |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 115.6 | 118.7 | 22.5 | 361.3 |
| 3 | `{"cmd":"wait_ms","ms":800}` | 812.0 | 813.6 | 841.7 | 1036.1 |
| 4 | `{"cmd":"click","col":50,"row":10}` | 7.9 | 57.1 | 26.1 | 30.4 |
| 5 | `{"cmd":"wait_ms","ms":150}` | 160.1 | 161.6 | 168.7 | 171.6 |
| 6 | `{"cmd":"click","col":32,"row":20}` | 19.0 | 19.0 | 15.8 | 20.4 |
| 7 | `{"cmd":"wait_ms","ms":150}` | 163.3 | 164.5 | 169.4 | 172.5 |
| 8 | `{"cmd":"click","col":15,"row":5}` | 18.8 | 66.4 | 29.6 | 73.2 |
| 9 | `{"cmd":"wait_ms","ms":400}` | 413.1 | 459.4 | 414.5 | 415.9 |
| 10 | `{"cmd":"click","col":33,"row":1}` | 11.1 | 12.7 | 13.9 | 18.3 |
| 11 | `{"cmd":"wait_ms","ms":300}` | 314.0 | 315.6 | 324.6 | 328.8 |
| 12 | `{"cmd":"scroll","col":60,"row":15,"dy":-1}` | 1.6 | 3.2 | 20.6 | 25.3 |
| 13 | `{"cmd":"wait_ms","ms":200}` | 210.0 | 211.6 | 235.6 | 238.7 |
| 14 | `{"cmd":"scroll","col":60,"row":15,"dy":-3}` | 17.9 | 19.5 | 22.0 | 25.1 |
| 15 | `{"cmd":"wait_ms","ms":200}` | 226.5 | 228.1 | 225.0 | 229.6 |
| 16 | `{"cmd":"scroll","col":60,"row":15,"dy":-10}` | 20.2 | 21.7 | 26.8 | 29.9 |
| 17 | `{"cmd":"wait_ms","ms":200}` | 217.9 | 266.5 | 225.8 | 230.3 |
| 18 | `{"cmd":"scroll","col":60,"row":15,"dy":-30}` | 17.8 | 66.4 | 17.1 | 21.7 |
| 19 | `{"cmd":"wait_ms","ms":200}` | 219.8 | 269.1 | 223.9 | 228.5 |
| 20 | `{"cmd":"scroll","col":60,"row":15,"dy":1}` | 9.5 | 11.0 | 20.6 | 25.2 |
| 21 | `{"cmd":"wait_ms","ms":200}` | 258.2 | 259.8 | 234.6 | 239.2 |
| 22 | `{"cmd":"scroll","col":60,"row":15,"dy":3}` | 3.7 | 5.1 | 22.8 | 27.4 |
| 23 | `{"cmd":"wait_ms","ms":200}` | 217.5 | 217.5 | 235.6 | 240.2 |
| 24 | `{"cmd":"scroll","col":60,"row":15,"dy":10}` | 10.5 | 12.0 | 28.0 | 32.1 |
| 25 | `{"cmd":"wait_ms","ms":200}` | 212.8 | 214.3 | 221.9 | 225.5 |
| 26 | `{"cmd":"scroll","col":60,"row":15,"dy":30}` | 18.2 | 67.4 | 32.7 | 36.8 |
| 27 | `{"cmd":"wait_ms","ms":200}` | 203.3 | 245.7 | 227.1 | 230.2 |
| 28 | `{"cmd":"drag","from_col":40,"from_row":6,"col…` | 19.0 | 63.4 | 90.6 | 95.2 |
| 29 | `{"cmd":"wait_ms","ms":150}` | 163.2 | 209.4 | 176.4 | 179.5 |
| 30 | `{"cmd":"click","col":45,"row":12}` | 13.9 | 62.3 | 19.0 | 23.3 |
| 31 | `{"cmd":"click","col":45,"row":12}` | 13.6 | 61.8 | 28.3 | 31.4 |
| 32 | `{"cmd":"wait_ms","ms":300}` | 319.0 | 368.6 | 325.7 | 331.9 |

Over the 18 non-wait steps — mean dump latency: rust 46.5 ms, zig 54.1 ms; slowest: rust 119 ms (step 2), zig 361 ms (step 2).
