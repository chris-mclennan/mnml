# compare-mouse — timing (120x40)

| side | binary | start event | first frame | peak RSS | rss samples | exit |
|------|--------|------------:|------------:|---------:|------------:|------|
| rust | `/Users/chrismclennan/Projects/mnml/target/release/mnml` | 2032.7 ms | 2039.4 ms | 111.7 MB | 187 | 0 |
| zig | `/Users/chrismclennan/Projects/mnml-zig-worktrees/compare/zig-out/bin/mnml-zig` | 339.7 ms | 409.4 ms | 46.9 MB | 215 | 0 |

Per step, ms from the command's append: `ack` = the ack line in events.jsonl (applied), `dump` = the next screen.txt write after the ack (painted). A `wait_ms` step's ack includes its own sleep.

| # | step | rust ack | rust dump | zig ack | zig dump |
|---|------|---------:|----------:|--------:|---------:|
| 0 | `{"cmd":"key","key":"esc"}` | 16.7 | 17.8 | 81.4 | 81.7 |
| 1 | `{"cmd":"key","key":"esc"}` | 15.8 | 109.8 | 10.8 | 63.2 |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 122.9 | 126.0 | 37.7 | 2487.2 |
| 3 | `{"cmd":"wait_ms","ms":800}` | 814.2 | 815.9 | 848.9 | 866.5 |
| 4 | `{"cmd":"click","col":50,"row":10}` | 10.8 | 12.4 | 1814.9 | 1822.2 |
| 5 | `{"cmd":"wait_ms","ms":150}` | 167.2 | 168.6 | 245.7 | 251.4 |
| 6 | `{"cmd":"click","col":32,"row":20}` | 12.9 | 14.3 | 64.1 | 67.2 |
| 7 | `{"cmd":"wait_ms","ms":150}` | 166.6 | 168.2 | 170.9 | 181.8 |
| 8 | `{"cmd":"click","col":15,"row":5}` | 9.6 | 11.1 | 25.1 | 140.2 |
| 9 | `{"cmd":"wait_ms","ms":400}` | 458.0 | 459.8 | 419.8 | 463.7 |
| 10 | `{"cmd":"click","col":33,"row":1}` | 225.9 | 227.4 | 12.5 | 18.5 |
| 11 | `{"cmd":"wait_ms","ms":300}` | 323.0 | 324.2 | 325.8 | 330.4 |
| 12 | `{"cmd":"scroll","col":60,"row":15,"dy":-1}` | 17.1 | 65.9 | 26.3 | 29.3 |
| 13 | `{"cmd":"wait_ms","ms":200}` | 212.7 | 214.3 | 223.3 | 227.8 |
| 14 | `{"cmd":"scroll","col":60,"row":15,"dy":-3}` | 10.4 | 11.6 | 27.3 | 31.8 |
| 15 | `{"cmd":"wait_ms","ms":200}` | 215.4 | 218.6 | 225.9 | 231.6 |
| 16 | `{"cmd":"scroll","col":60,"row":15,"dy":-10}` | 23.7 | 71.0 | 26.6 | 31.2 |
| 17 | `{"cmd":"wait_ms","ms":200}` | 227.2 | 228.8 | 224.5 | 229.1 |
| 18 | `{"cmd":"scroll","col":60,"row":15,"dy":-30}` | 12.3 | 14.1 | 22.6 | 27.1 |
| 19 | `{"cmd":"wait_ms","ms":200}` | 216.8 | 218.1 | 225.7 | 230.3 |
| 20 | `{"cmd":"scroll","col":60,"row":15,"dy":1}` | 16.6 | 64.4 | 17.1 | 21.6 |
| 21 | `{"cmd":"wait_ms","ms":200}` | 222.8 | 418.5 | 227.4 | 230.5 |
| 22 | `{"cmd":"scroll","col":60,"row":15,"dy":3}` | 49.1 | 101.1 | 20.3 | 24.9 |
| 23 | `{"cmd":"wait_ms","ms":200}` | 212.3 | 213.8 | 231.5 | 234.6 |
| 24 | `{"cmd":"scroll","col":60,"row":15,"dy":10}` | 15.7 | 58.6 | 24.4 | 29.0 |
| 25 | `{"cmd":"wait_ms","ms":200}` | 209.4 | 258.0 | 221.9 | 226.5 |
| 26 | `{"cmd":"scroll","col":60,"row":15,"dy":30}` | 15.9 | 59.6 | 24.7 | 29.2 |
| 27 | `{"cmd":"wait_ms","ms":200}` | 208.7 | 211.6 | 219.2 | 223.7 |
| 28 | `{"cmd":"drag","from_col":40,"from_row":6,"col…` | 12.6 | 14.4 | 88.4 | 93.0 |
| 29 | `{"cmd":"wait_ms","ms":150}` | 170.0 | 171.5 | 174.7 | 179.7 |
| 30 | `{"cmd":"click","col":45,"row":12}` | 13.5 | 59.6 | 19.1 | 23.3 |
| 31 | `{"cmd":"click","col":45,"row":12}` | 3.9 | 5.4 | 26.9 | 30.0 |
| 32 | `{"cmd":"wait_ms","ms":300}` | 315.3 | 316.9 | 318.5 | 322.6 |

Over the 18 non-wait steps — mean dump latency: rust 58.0 ms, zig 280.6 ms; slowest: rust 227 ms (step 10), zig 2487 ms (step 2).
