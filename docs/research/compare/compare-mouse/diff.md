# compare-mouse — per-step diff (120x40)

`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). `text`: body rows (2..37) still differing once the tree's cursor cell (column 4), the last column (the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. `cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter (neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. `class`: an automatic first guess — the research doc holds the reviewed one.

| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |
|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|
| 0 | `{"cmd":"key","key":"esc"}` | 4 | 1 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 1 | `{"cmd":"key","key":"esc"}` | 4 | 1 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 38 | 12 | 1:1 | 1:1 | 1 | 1 | none | wrap, gutter |
| 3 | `{"cmd":"wait_ms","ms":800}` | 38 | 6 | 1:1 | 1:1 | 1 | 1 | none | wrap |
| 4 | `{"cmd":"click","col":50,"row":10}` | 38 | 7 | 8:14 | 8:14 | 1 | 1 | none | wrap, gutter |
| 5 | `{"cmd":"wait_ms","ms":150}` | 38 | 9 | 8:14 | 8:14 | 1 | 1 | none | wrap, gutter |
| 6 | `{"cmd":"click","col":32,"row":20}` | 38 | 9 | 19:1 | 18:2 | 1 | 1 | none | cursor placement, wrap, gutter |
| 7 | `{"cmd":"wait_ms","ms":150}` | 38 | 6 | 19:1 | 18:2 | 1 | 1 | none | cursor placement, wrap |
| 8 | `{"cmd":"click","col":15,"row":5}` | 7 | 4 | 1:1 | 1:1 | 1 | 1 | none | gutter |
| 9 | `{"cmd":"wait_ms","ms":400}` | 12 | 9 | 1:1 | 1:1 | 1 | 1 | none | gutter |
| 10 | `{"cmd":"click","col":33,"row":1}` | 37 | 13 | 19:1 | 18:2 | 1 | 1 | none | cursor placement, wrap, gutter |
| 11 | `{"cmd":"wait_ms","ms":300}` | 37 | 13 | 19:1 | 18:2 | 1 | 1 | none | cursor placement, wrap, gutter |
| 12 | `{"cmd":"scroll","col":60,"row":15,"dy":-1}` | 37 | 15 | 19:1 | 18:2 | 4 | 4 | none | cursor placement, wrap, gutter |
| 13 | `{"cmd":"wait_ms","ms":200}` | 37 | 15 | 19:1 | 18:2 | 4 | 4 | none | cursor placement, wrap, gutter |
| 14 | `{"cmd":"scroll","col":60,"row":15,"dy":-3}` | 37 | 35 | 19:1 | 18:2 | 22+1 | 13+1 | none | scroll offset, cursor placement, wrap |
| 15 | `{"cmd":"wait_ms","ms":200}` | 37 | 35 | 19:1 | 18:2 | 22+1 | 13+1 | none | scroll offset, cursor placement, wrap |
| 16 | `{"cmd":"scroll","col":60,"row":15,"dy":-10}` | 37 | 35 | 19:1 | 18:2 | 91+1 | 43+1 | none | scroll offset, cursor placement, wrap, gutter |
| 17 | `{"cmd":"wait_ms","ms":200}` | 37 | 35 | 19:1 | 18:2 | 91+1 | 43+1 | none | scroll offset, cursor placement, wrap, gutter |
| 18 | `{"cmd":"scroll","col":60,"row":15,"dy":-30}` | 37 | 35 | 19:1 | 18:2 | 310+1 | 133+1 | none | scroll offset, cursor placement, wrap |
| 19 | `{"cmd":"wait_ms","ms":200}` | 37 | 35 | 19:1 | 18:2 | 310+1 | 133+1 | none | scroll offset, cursor placement, wrap |
| 20 | `{"cmd":"scroll","col":60,"row":15,"dy":1}` | 37 | 35 | 19:1 | 18:2 | 307+1 | 130+1 | none | scroll offset, cursor placement, wrap |
| 21 | `{"cmd":"wait_ms","ms":200}` | 37 | 35 | 19:1 | 18:2 | 307+1 | 130+1 | none | scroll offset, cursor placement, wrap |
| 22 | `{"cmd":"scroll","col":60,"row":15,"dy":3}` | 37 | 35 | 19:1 | 18:2 | 289+1 | 121+1 | none | scroll offset, cursor placement, wrap |
| 23 | `{"cmd":"wait_ms","ms":200}` | 37 | 35 | 19:1 | 18:2 | 289+1 | 121+1 | none | scroll offset, cursor placement, wrap |
| 24 | `{"cmd":"scroll","col":60,"row":15,"dy":10}` | 37 | 35 | 19:1 | 18:2 | 220+1 | 91 | none | scroll offset, cursor placement, wrap |
| 25 | `{"cmd":"wait_ms","ms":200}` | 37 | 35 | 19:1 | 18:2 | 220+1 | 91 | none | scroll offset, cursor placement, wrap |
| 26 | `{"cmd":"scroll","col":60,"row":15,"dy":30}` | 37 | 12 | 19:1 | 18:2 | 1 | 1 | none | cursor placement, wrap, gutter |
| 27 | `{"cmd":"wait_ms","ms":200}` | 37 | 12 | 19:1 | 18:2 | 1 | 1 | none | cursor placement, wrap, gutter |
| 28 | `{"cmd":"drag","from_col":40,"from_row":6,"col…` | 36 | 12 | 6:17 | 6:17 | 1 | 1 | none | wrap, gutter |
| 29 | `{"cmd":"wait_ms","ms":150}` | 36 | 6 | 6:17 | 6:17 | 1 | 1 | none | wrap |
| 30 | `{"cmd":"click","col":45,"row":12}` | 37 | 7 | 10:9 | 10:11 | 1 | 1 | none | cursor placement, wrap, gutter |
| 31 | `{"cmd":"click","col":45,"row":12}` | 36 | 7 | 10:12 | 10:12 | 1 | 1 | none | wrap, gutter |
| 32 | `{"cmd":"wait_ms","ms":300}` | 36 | 6 | 10:12 | 10:12 | 1 | 1 | none | wrap |

## Worst three steps by `text` (excerpts)

### step 14 — `{"cmd":"scroll","col":60,"row":15,"dy":-3}` — 35 text rows (scroll offset, cursor placement, wrap)

```
row  3 rust:   │pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  3 zig:    │   11 pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  4 rust: ? │   23 pub fn apply_viewport2<K, V>() -> u16 {
row  4 zig:  ? │   14     if span.all(|span_layout| line as usize) { drain(event); }                    █
row  5 rust:   │   24     let mut rect_line: u64 = registry_command.find(|scope| cell_scope?.drain());
row  5 zig:    │   15     return wrap(glyph_scope.len());                                               █
row  6 rust: ? │   25     while collect(palette_theme?.paint() << Some(needle), viewport.any(|offset_e
row  6 zig:  ? │   16     width_pane = 128;                                                             █
row  7 rust:   │    ↪ vent| 3566) == registry_fold as usize / None, tokenize("中 文 文 本  wide cells", buf
row  7 zig:    │   17     highlight(span_scope?.flush(), frame?.restore(), cursor.len());               █
row  8 rust:   │    ↪  as usize) << true == 1) {
row  8 zig:    │   18     let frame: i32 = snapshot(snapshot(true % None, merge(glyph.len())),          █
… 29 more rows
```

### step 15 — `{"cmd":"wait_ms","ms":200}` — 35 text rows (scroll offset, cursor placement, wrap)

```
row  3 rust:   │pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  3 zig:    │   11 pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  4 rust: ? │   23 pub fn apply_viewport2<K, V>() -> u16 {
row  4 zig:  ? │   14     if span.all(|span_layout| line as usize) { drain(event); }                    █
row  5 rust:   │   24     let mut rect_line: u64 = registry_command.find(|scope| cell_scope?.drain());
row  5 zig:    │   15     return wrap(glyph_scope.len());                                               █
row  6 rust: ? │   25     while collect(palette_theme?.paint() << Some(needle), viewport.any(|offset_e
row  6 zig:  ? │   16     width_pane = 128;                                                             █
row  7 rust:   │    ↪ vent| 3566) == registry_fold as usize / None, tokenize("中 文 文 本  wide cells", buf
row  7 zig:    │   17     highlight(span_scope?.flush(), frame?.restore(), cursor.len());               █
row  8 rust:   │    ↪  as usize) << true == 1) {
row  8 zig:    │   18     let frame: i32 = snapshot(snapshot(true % None, merge(glyph.len())),          █
… 29 more rows
```

### step 16 — `{"cmd":"scroll","col":60,"row":15,"dy":-10}` — 35 text rows (scroll offset, cursor placement, wrap, gutter)

```
row  3 rust:   │pub fn clamp_palette1() -> Arc<Mutex<State>> {
row  3 zig:    │   40 pub struct Registry39 {
row  4 rust: ? │   92 pub enum Merge91 {
row  4 zig:  ? │   44     pub command_viewport: u16,                                                    █
row  5 rust:   │   93     Glyph(usize),
row  5 zig:    │   45     pub cursor: String,                                                           █
row  6 rust: ? │   94     Theme{ line: usize, col: usize },
row  6 zig:  ? │   46 }                                                                                 █
row  7 rust:   │   95     Cell,
row  7 zig:    │   47                                                                                   █
row  8 rust:   │   96     Event(String, Vec<u8>),
row  8 zig:    │   48 /// Tabs are rendered at the configured stop, never stored expanded.              █
… 29 more rows
```

