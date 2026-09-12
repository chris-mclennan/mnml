# compare-mouse — per-step diff (120x40)

`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). `text`: body rows (2..37) still differing once the tree's cursor cell (column 4), the last column (the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. `cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter (neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. `class`: an automatic first guess — the research doc holds the reviewed one.

| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |
|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|
| 0 | `{"cmd":"key","key":"esc"}` | 3 | 1 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 1 | `{"cmd":"key","key":"esc"}` | 3 | 1 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 11 | 9 | 1:1 | 1:1 | 1 | 1 | none | wrap, gutter |
| 3 | `{"cmd":"wait_ms","ms":800}` | 9 | 6 | 1:1 | 1:1 | 1 | 1 | none | wrap |
| 4 | `{"cmd":"click","col":50,"row":10}` | 10 | 7 | 8:14 | 8:14 | 1 | 1 | none | wrap, gutter |
| 5 | `{"cmd":"wait_ms","ms":150}` | 12 | 9 | 8:14 | 8:14 | 1 | 1 | none | wrap, gutter |
| 6 | `{"cmd":"click","col":32,"row":20}` | 12 | 9 | 19:1 | 18:1 | 1 | 1 | none | cursor placement, wrap, gutter |
| 7 | `{"cmd":"wait_ms","ms":150}` | 9 | 6 | 19:1 | 18:1 | 1 | 1 | none | cursor placement, wrap |
| 8 | `{"cmd":"click","col":15,"row":5}` | 7 | 4 | 1:1 | 1:1 | 1 | 1 | none | gutter |
| 9 | `{"cmd":"wait_ms","ms":400}` | 12 | 9 | 1:1 | 1:1 | 1 | 1 | none | gutter |
| 10 | `{"cmd":"click","col":33,"row":1}` | 15 | 12 | 19:1 | 18:1 | 1 | 1 | none | cursor placement, wrap, gutter |
| 11 | `{"cmd":"wait_ms","ms":300}` | 15 | 12 | 19:1 | 18:1 | 1 | 1 | none | cursor placement, wrap, gutter |
| 12 | `{"cmd":"scroll","col":60,"row":15,"dy":-1}` | 17 | 14 | 19:1 | 18:1 | 4 | 4 | none | cursor placement, wrap, gutter |
| 13 | `{"cmd":"wait_ms","ms":200}` | 18 | 15 | 19:1 | 18:1 | 4 | 4 | none | cursor placement, wrap, gutter |
| 14 | `{"cmd":"scroll","col":60,"row":15,"dy":-3}` | 22 | 18 | 19:1 | 18:1 | 22+1 | 22 | none | cursor placement, wrap, gutter |
| 15 | `{"cmd":"wait_ms","ms":200}` | 22 | 18 | 19:1 | 18:1 | 22+1 | 22 | none | cursor placement, wrap, gutter |
| 16 | `{"cmd":"scroll","col":60,"row":15,"dy":-10}` | 24 | 21 | 19:1 | 18:1 | 91+1 | 91 | none | cursor placement, wrap, gutter |
| 17 | `{"cmd":"wait_ms","ms":200}` | 24 | 21 | 19:1 | 18:1 | 91+1 | 91 | none | cursor placement, wrap, gutter |
| 18 | `{"cmd":"scroll","col":60,"row":15,"dy":-30}` | 15 | 12 | 19:1 | 18:1 | 310+1 | 310 | none | cursor placement, wrap, gutter |
| 19 | `{"cmd":"wait_ms","ms":200}` | 15 | 12 | 19:1 | 18:1 | 310+1 | 310 | none | cursor placement, wrap, gutter |
| 20 | `{"cmd":"scroll","col":60,"row":15,"dy":1}` | 16 | 12 | 19:1 | 18:1 | 307+1 | 307+1 | none | cursor placement, wrap, gutter |
| 21 | `{"cmd":"wait_ms","ms":200}` | 16 | 12 | 19:1 | 18:1 | 307+1 | 307+1 | none | cursor placement, wrap, gutter |
| 22 | `{"cmd":"scroll","col":60,"row":15,"dy":3}` | 28 | 25 | 19:1 | 18:1 | 289+1 | 289+2 | none | cursor placement, wrap |
| 23 | `{"cmd":"wait_ms","ms":200}` | 28 | 25 | 19:1 | 18:1 | 289+1 | 289+2 | none | cursor placement, wrap |
| 24 | `{"cmd":"scroll","col":60,"row":15,"dy":10}` | 31 | 29 | 19:1 | 18:1 | 220+1 | 220+1 | none | cursor placement, wrap, gutter |
| 25 | `{"cmd":"wait_ms","ms":200}` | 31 | 29 | 19:1 | 18:1 | 220+1 | 220+1 | none | cursor placement, wrap, gutter |
| 26 | `{"cmd":"scroll","col":60,"row":15,"dy":30}` | 16 | 13 | 19:1 | 18:1 | 1 | 1 | none | cursor placement, wrap, gutter |
| 27 | `{"cmd":"wait_ms","ms":200}` | 16 | 13 | 19:1 | 18:1 | 1 | 1 | none | cursor placement, wrap, gutter |
| 28 | `{"cmd":"drag","from_col":40,"from_row":6,"col…` | 14 | 12 | 6:17 | 6:17 | 1 | 1 | none | wrap, gutter |
| 29 | `{"cmd":"wait_ms","ms":150}` | 8 | 6 | 6:17 | 6:17 | 1 | 1 | none | wrap |
| 30 | `{"cmd":"click","col":45,"row":12}` | 10 | 7 | 10:9 | 10:9 | 1 | 1 | none | wrap, gutter |
| 31 | `{"cmd":"click","col":45,"row":12}` | 10 | 7 | 10:12 | 10:12 | 1 | 1 | none | wrap, gutter |
| 32 | `{"cmd":"wait_ms","ms":300}` | 9 | 6 | 10:12 | 10:12 | 1 | 1 | none | wrap |

## Worst three steps by `text` (excerpts)

### step 24 — `{"cmd":"scroll","col":60,"row":15,"dy":10}` — 29 text rows (cursor placement, wrap, gutter)

```
row  3 rust:   │pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  3 zig:    │  215 pub fn render_config13(handler: u32, height_line: String, command: HashMap<String,
row  4 rust: ? │    ↪ t.len()) >= None && width_layout);
row  4 zig:  ? │      style_layout.len()) >= None && width_layout);
row  5 rust:   │  221     │   if 41 { collect(span_gutter); }
row  5 zig:    │  221         if 41 { collect(span_gutter); }
row  6 rust: ? │  222     │   let command: &str = snapshot(viewport?.snapshot(), wrap()) << span / Som
row  6 zig:  ? │  222         let command: &str = snapshot(viewport?.snapshot(), wrap()) << span /
row  7 rust:   │    ↪ e(byte) / editor?.render();
row  7 zig:    │      Some(byte) / editor?.render();
row  8 rust:   │  223     │   rect = None;
row  8 zig:    │  223         rect = None;
… 23 more rows
```

### step 25 — `{"cmd":"wait_ms","ms":200}` — 29 text rows (cursor placement, wrap, gutter)

```
row  3 rust:   │pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  3 zig:    │  215 pub fn render_config13(handler: u32, height_line: String, command: HashMap<String,
row  4 rust: ? │    ↪ t.len()) >= None && width_layout);
row  4 zig:  ? │      style_layout.len()) >= None && width_layout);
row  5 rust:   │  221     │   if 41 { collect(span_gutter); }
row  5 zig:    │  221         if 41 { collect(span_gutter); }
row  6 rust: ? │  222     │   let command: &str = snapshot(viewport?.snapshot(), wrap()) << span / Som
row  6 zig:  ? │  222         let command: &str = snapshot(viewport?.snapshot(), wrap()) << span /
row  7 rust:   │    ↪ e(byte) / editor?.render();
row  7 zig:    │      Some(byte) / editor?.render();
row  8 rust:   │  223     │   rect = None;
row  8 zig:    │  223         rect = None;
… 23 more rows
```

### step 22 — `{"cmd":"scroll","col":60,"row":15,"dy":3}` — 25 text rows (cursor placement, wrap)

```
row  3 rust:   │pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  3 zig:    │  229 pub fn clamp_registry14<F: Fn(usize) -> bool>() -> f64 {
row  4 rust: ? │  290     }
row  4 zig:  ? │  269 pub fn dispatch_span16<T>(registry: String, palette: Arc<Mutex<State>>, gutter: Arc
row 10 rust:   │  296     let mut handler_registry: f64 = "𝔘𝔫𝔦𝔠𝔬𝔡𝔢 math letters" << editor.all(|cursor
row 10 zig:    │  296     let mut handler_registry: f64 = "𝔘𝔫𝔦𝔠𝔬𝔡𝔢 math letters" << editor.all(|cursor|
row 11 rust:   │    ↪ | height?.flush());
row 11 zig:    │      height?.flush());
row 15 rust:   │  300     debug_assert!(anchor?.apply() << highlight(true % Some(span), "zero-widthjo
row 15 zig:    │  300     debug_assert!(anchor?.apply() << highlight(true % Some(span),
row 16 rust:   │    ↪ iner" - 241), "zero-widthjoiner");
row 16 zig:    │      "zero-widthjoiner" - 241), "zero-widthjoiner");
… 19 more rows
```

