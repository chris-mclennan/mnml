# compare-keys-30000l — per-step diff (120x40)

`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). `text`: body rows (2..37) still differing once the tree's cursor cell (column 4), the last column (the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. `cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter (neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. `class`: an automatic first guess — the research doc holds the reviewed one.

| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |
|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|
| 0 | `{"cmd":"key","key":"esc"}` | 22 | 19 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 1 | `{"cmd":"key","key":"esc"}` | 22 | 19 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 38 | 13 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 3 | `{"cmd":"wait_ms","ms":800}` | 38 | 13 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 4 | `{"cmd":"key","key":"pagedown"}` | 38 | 26 | 36:1 | 36:1 | 9 | 8 | NORMAL | scroll offset, wrap, gutter |
| 5 | `{"cmd":"wait_ms","ms":150}` | 38 | 25 | 36:1 | 36:1 | 9 | 8 | NORMAL | scroll offset, wrap |
| 6 | `{"cmd":"key","key":"pagedown"}` | 38 | 13 | 71:1 | 71:1 | 39 | 39 | NORMAL | wrap, gutter |
| 7 | `{"cmd":"wait_ms","ms":150}` | 38 | 12 | 71:1 | 71:1 | 39 | 39 | NORMAL | wrap, gutter |
| 8 | `{"cmd":"key","key":"pagedown"}` | 38 | 14 | 106:1 | 106:1 | 77 | 77 | NORMAL | wrap, gutter |
| 9 | `{"cmd":"wait_ms","ms":150}` | 38 | 17 | 106:1 | 106:1 | 77 | 77 | NORMAL | wrap |
| 10 | `{"cmd":"key","key":"pagedown"}` | 38 | 16 | 141:1 | 141:1 | 112 | 112+1 | NORMAL | wrap |
| 11 | `{"cmd":"wait_ms","ms":150}` | 38 | 16 | 141:1 | 141:1 | 112 | 112+1 | NORMAL | wrap |
| 12 | `{"cmd":"key","key":"pagedown"}` | 38 | 24 | 176:1 | 176:1 | 149 | 149+1 | NORMAL | wrap, gutter |
| 13 | `{"cmd":"wait_ms","ms":150}` | 38 | 24 | 176:1 | 176:1 | 149 | 149+1 | NORMAL | wrap, gutter |
| 14 | `{"cmd":"key","key":"ctrl+d"}` | 38 | 35 | 193:1 | 193:1 | 166 | 165+1 | NORMAL | scroll offset, wrap |
| 15 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 193:1 | 193:1 | 166 | 165+1 | NORMAL | scroll offset, wrap |
| 16 | `{"cmd":"key","key":"ctrl+d"}` | 38 | 35 | 210:1 | 210:1 | 182 | 183+1 | NORMAL | scroll offset, wrap |
| 17 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 210:1 | 210:1 | 182 | 183+1 | NORMAL | scroll offset, wrap |
| 18 | `{"cmd":"key","key":"ctrl+d"}` | 38 | 30 | 227:1 | 227:1 | 200 | 201 | NORMAL | scroll offset, wrap |
| 19 | `{"cmd":"wait_ms","ms":150}` | 38 | 30 | 227:1 | 227:1 | 200 | 201 | NORMAL | scroll offset, wrap |
| 20 | `{"cmd":"key","key":"G"}` | 38 | 35 | 30000:1 | 30000:1 | 29973 | 29973+1 | NORMAL | wrap |
| 21 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 30000:1 | 30000:1 | 29973 | 29973+1 | NORMAL | wrap |
| 22 | `{"cmd":"key","key":"gg"}` | 38 | 13 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 23 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 24 | `{"cmd":"key","key":"50%"}` | 38 | 23 | 15000:1 | 15000:1 | 14974 | 14974+1 | NORMAL | wrap |
| 25 | `{"cmd":"wait_ms","ms":150}` | 38 | 23 | 15000:1 | 15000:1 | 14974 | 14974+1 | NORMAL | wrap |
| 26 | `{"cmd":"type","text":"/needle\n"}` | 38 | 18 | 15006:8 | 15006:8 | 14979 | 14979+1 | NORMAL | wrap, gutter |
| 27 | `{"cmd":"wait_ms","ms":300}` | 38 | 14 | 15006:8 | 15006:8 | 14979 | 14979+1 | NORMAL | wrap |
| 28 | `{"cmd":"key","key":"n"}` | 38 | 11 | 15008:8 | 15008:8 | 14980 | 14980+1 | NORMAL | wrap |
| 29 | `{"cmd":"wait_ms","ms":150}` | 38 | 11 | 15008:8 | 15008:8 | 14980 | 14980+1 | NORMAL | wrap |
| 30 | `{"cmd":"key","key":"n"}` | 38 | 14 | 15015:5 | 15015:5 | 14988 | 14988 | NORMAL | wrap, gutter |
| 31 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 15015:5 | 15015:5 | 14988 | 14988 | NORMAL | wrap |
| 32 | `{"cmd":"key","key":"n"}` | 38 | 14 | 15015:22 | 15015:22 | 14988 | 14988 | NORMAL | wrap, gutter |
| 33 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 15015:22 | 15015:22 | 14988 | 14988 | NORMAL | wrap |
| 34 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15015:29 | 15015:29 | 14988 | 14988 | NORMAL | wrap, gutter |
| 35 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15015:29 | 15015:29 | 14988 | 14988 | NORMAL | wrap |
| 36 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15015:32 | 15015:32 | 14988 | 14988 | NORMAL | wrap, gutter |
| 37 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15015:32 | 15015:32 | 14988 | 14988 | NORMAL | wrap |
| 38 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15015:34 | 15015:34 | 14988 | 14988 | NORMAL | wrap, gutter |
| 39 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15015:34 | 15015:34 | 14988 | 14988 | NORMAL | wrap, gutter |
| 40 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15015:42 | 15015:42 | 14988 | 14988 | NORMAL | wrap, gutter |
| 41 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15015:42 | 15015:42 | 14988 | 14988 | NORMAL | wrap, gutter |
| 42 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15016:1 | 15016:1 | 14989 | 14989+1 | NORMAL | wrap, gutter |
| 43 | `{"cmd":"wait_ms","ms":100}` | 38 | 12 | 15016:1 | 15016:1 | 14989 | 14989+1 | NORMAL | wrap |
| 44 | `{"cmd":"key","key":"w"}` | 37 | 14 | 15018:1 | 15018:1 | 14990 | 14990+1 | NORMAL | wrap, gutter |
| 45 | `{"cmd":"wait_ms","ms":100}` | 37 | 14 | 15018:1 | 15018:1 | 14990 | 14990+1 | NORMAL | wrap, gutter |
| 46 | `{"cmd":"key","key":"w"}` | 37 | 12 | 15018:5 | 15018:5 | 14990 | 14990+1 | NORMAL | wrap |
| 47 | `{"cmd":"wait_ms","ms":100}` | 37 | 12 | 15018:5 | 15018:5 | 14990 | 14990+1 | NORMAL | wrap |
| 48 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15018:10 | 15018:10 | 14990 | 14990+1 | NORMAL | wrap |
| 49 | `{"cmd":"wait_ms","ms":100}` | 38 | 12 | 15018:10 | 15018:10 | 14990 | 14990+1 | NORMAL | wrap |
| 50 | `{"cmd":"key","key":"w"}` | 37 | 14 | 15018:23 | 15018:23 | 14990 | 14990+1 | NORMAL | wrap, gutter |
| 51 | `{"cmd":"wait_ms","ms":100}` | 37 | 14 | 15018:23 | 15018:23 | 14990 | 14990+1 | NORMAL | wrap, gutter |
| 52 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15019:5 | 15019:5 | 14991 | 14991+1 | NORMAL | wrap, gutter |
| 53 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15019:5 | 15019:5 | 14991 | 14991+1 | NORMAL | wrap, gutter |
| 54 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15019:11 | 15019:11 | 14991 | 14991+1 | NORMAL | wrap, gutter |
| 55 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15019:11 | 15019:11 | 14991 | 14991+1 | NORMAL | wrap, gutter |
| 56 | `{"cmd":"key","key":"w"}` | 38 | 12 | 15019:12 | 15019:12 | 14991 | 14991+1 | NORMAL | wrap |
| 57 | `{"cmd":"wait_ms","ms":100}` | 38 | 12 | 15019:12 | 15019:12 | 14991 | 14991+1 | NORMAL | wrap |
| 58 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15019:17 | 15019:17 | 14991 | 14991+1 | NORMAL | wrap, gutter |
| 59 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15019:17 | 15019:17 | 14991 | 14991+1 | NORMAL | wrap, gutter |
| 60 | `{"cmd":"key","key":"w"}` | 38 | 11 | 15020:5 | 15020:5 | 14992 | 14992+1 | NORMAL | wrap |
| 61 | `{"cmd":"wait_ms","ms":100}` | 38 | 11 | 15020:5 | 15020:5 | 14992 | 14992+1 | NORMAL | wrap |
| 62 | `{"cmd":"key","key":"w"}` | 38 | 13 | 15020:11 | 15020:11 | 14992 | 14992+1 | NORMAL | wrap, gutter |
| 63 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15020:11 | 15020:11 | 14992 | 14992+1 | NORMAL | wrap, gutter |
| 64 | `{"cmd":"key","key":"w"}` | 38 | 11 | 15020:12 | 15020:12 | 14992 | 14992+1 | NORMAL | wrap |
| 65 | `{"cmd":"wait_ms","ms":100}` | 38 | 11 | 15020:12 | 15020:12 | 14992 | 14992+1 | NORMAL | wrap |
| 66 | `{"cmd":"key","key":"w"}` | 38 | 13 | 15020:17 | 15020:17 | 14992 | 14992+1 | NORMAL | wrap, gutter |
| 67 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15020:17 | 15020:17 | 14992 | 14992+1 | NORMAL | wrap, gutter |
| 68 | `{"cmd":"key","key":"w"}` | 38 | 14 | 15021:1 | 15021:1 | 14993 | 14993+1 | NORMAL | wrap, gutter |
| 69 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15021:1 | 15021:1 | 14993 | 14993+1 | NORMAL | wrap |
| 70 | `{"cmd":"key","key":"w"}` | 38 | 10 | 15023:1 | 15023:1 | 14994 | 14994+1 | NORMAL | wrap |
| 71 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15023:1 | 15023:1 | 14994 | 14994+1 | NORMAL | wrap |
| 72 | `{"cmd":"key","key":"w"}` | 38 | 13 | 15023:5 | 15023:5 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 73 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15023:5 | 15023:5 | 14994 | 14994+1 | NORMAL | wrap |
| 74 | `{"cmd":"key","key":"b"}` | 38 | 13 | 15023:1 | 15023:1 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 75 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15023:1 | 15023:1 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 76 | `{"cmd":"key","key":"b"}` | 38 | 10 | 15021:1 | 15021:1 | 14994 | 14994+1 | NORMAL | wrap |
| 77 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15021:1 | 15021:1 | 14994 | 14994+1 | NORMAL | wrap |
| 78 | `{"cmd":"key","key":"b"}` | 38 | 10 | 15020:17 | 15020:17 | 14994 | 14994+1 | NORMAL | wrap |
| 79 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15020:17 | 15020:17 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 80 | `{"cmd":"key","key":"b"}` | 38 | 10 | 15020:12 | 15020:12 | 14994 | 14994+1 | NORMAL | wrap |
| 81 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15020:12 | 15020:12 | 14994 | 14994+1 | NORMAL | wrap |
| 82 | `{"cmd":"key","key":"b"}` | 38 | 13 | 15020:11 | 15020:11 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 83 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15020:11 | 15020:11 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 84 | `{"cmd":"key","key":"}"}` | 38 | 13 | 15022:1 | 15022:1 | 14994 | 14994+1 | NORMAL | wrap, gutter |
| 85 | `{"cmd":"wait_ms","ms":150}` | 38 | 10 | 15022:1 | 15022:1 | 14994 | 14994+1 | NORMAL | wrap |
| 86 | `{"cmd":"key","key":"}"}` | 38 | 20 | 15044:1 | 15044:1 | 15015 | 15015+1 | NORMAL | wrap, gutter |
| 87 | `{"cmd":"wait_ms","ms":150}` | 38 | 20 | 15044:1 | 15044:1 | 15015 | 15015+1 | NORMAL | wrap, gutter |
| 88 | `{"cmd":"key","key":"}"}` | 37 | 31 | 15068:1 | 15068:1 | 15042 | 15043+1 | NORMAL | scroll offset, wrap |
| 89 | `{"cmd":"wait_ms","ms":150}` | 37 | 31 | 15068:1 | 15068:1 | 15042 | 15043+1 | NORMAL | scroll offset, wrap |
| 90 | `{"cmd":"key","key":"}"}` | 37 | 35 | 15087:1 | 15087:1 | 15062 | 15062+1 | NORMAL | wrap |
| 91 | `{"cmd":"wait_ms","ms":150}` | 37 | 35 | 15087:1 | 15087:1 | 15062 | 15062+1 | NORMAL | wrap |
| 92 | `{"cmd":"key","key":"}"}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 93 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 94 | `{"cmd":"key","key":"$"}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 95 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 96 | `{"cmd":"key","key":"0"}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 97 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 98 | `{"cmd":"key","key":"zz"}` | 38 | 9 | 15097:1 | 15097:1 | 15080 | 15080+1 | NORMAL | wrap |
| 99 | `{"cmd":"wait_ms","ms":150}` | 38 | 9 | 15097:1 | 15097:1 | 15080 | 15080+1 | NORMAL | wrap |
| 100 | `{"cmd":"key","key":"zt"}` | 38 | 15 | 15097:1 | 15097:1 | 15097+1 | 15097 | NORMAL | wrap |
| 101 | `{"cmd":"wait_ms","ms":150}` | 38 | 15 | 15097:1 | 15097:1 | 15097+1 | 15097 | NORMAL | wrap |
| 102 | `{"cmd":"key","key":"zb"}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 103 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 15097:1 | 15097:1 | 15070 | 15070 | NORMAL | wrap |
| 104 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 13 | 15097:1 | 15097:1 | 15071 | 15071+1 | NORMAL | wrap |
| 105 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15097:1 | 15097:1 | 15071 | 15071+1 | NORMAL | wrap |
| 106 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 14 | 15097:1 | 15097:1 | 15072 | 15070 | NORMAL | scroll offset, wrap |
| 107 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15097:1 | 15097:1 | 15072 | 15070 | NORMAL | scroll offset, wrap |
| 108 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 13 | 15097:1 | 15097:1 | 15073 | 15073+1 | NORMAL | wrap |
| 109 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15097:1 | 15097:1 | 15073 | 15073+1 | NORMAL | wrap |
| 110 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 13 | 15097:1 | 15097:1 | 15074 | 15074+1 | NORMAL | wrap |
| 111 | `{"cmd":"wait_ms","ms":100}` | 38 | 13 | 15097:1 | 15097:1 | 15074 | 15074+1 | NORMAL | wrap |
| 112 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 14 | 15097:1 | 15097:1 | 15075 | 15075+1 | NORMAL | wrap |
| 113 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15097:1 | 15097:1 | 15075 | 15075+1 | NORMAL | wrap |
| 114 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 15 | 15097:1 | 15097:1 | 15076 | 15076+1 | NORMAL | wrap |
| 115 | `{"cmd":"wait_ms","ms":100}` | 38 | 15 | 15097:1 | 15097:1 | 15076 | 15076+1 | NORMAL | wrap |
| 116 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 14 | 15097:1 | 15097:1 | 15077 | 15077+1 | NORMAL | wrap |
| 117 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15097:1 | 15097:1 | 15077 | 15077+1 | NORMAL | wrap |
| 118 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 12 | 15097:1 | 15097:1 | 15078 | 15078+1 | NORMAL | wrap |
| 119 | `{"cmd":"wait_ms","ms":100}` | 38 | 12 | 15097:1 | 15097:1 | 15078 | 15078+1 | NORMAL | wrap |
| 120 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 10 | 15097:1 | 15097:1 | 15079 | 15079+1 | NORMAL | wrap |
| 121 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15097:1 | 15097:1 | 15079 | 15079+1 | NORMAL | wrap |
| 122 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 9 | 15097:1 | 15097:1 | 15080 | 15080+1 | NORMAL | wrap |
| 123 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 15097:1 | 15097:1 | 15080 | 15080+1 | NORMAL | wrap |
| 124 | `{"cmd":"key","key":"ctrl+y"}` | 38 | 10 | 15097:1 | 15097:1 | 15079 | 15079+1 | NORMAL | wrap |
| 125 | `{"cmd":"wait_ms","ms":100}` | 38 | 10 | 15097:1 | 15097:1 | 15079 | 15079+1 | NORMAL | wrap |
| 126 | `{"cmd":"key","key":"ctrl+y"}` | 38 | 12 | 15097:1 | 15097:1 | 15078 | 15078+1 | NORMAL | wrap |
| 127 | `{"cmd":"wait_ms","ms":100}` | 38 | 12 | 15097:1 | 15097:1 | 15078 | 15078+1 | NORMAL | wrap |
| 128 | `{"cmd":"key","key":"ctrl+y"}` | 38 | 14 | 15097:1 | 15097:1 | 15077 | 15077+1 | NORMAL | wrap |
| 129 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15097:1 | 15097:1 | 15077 | 15077+1 | NORMAL | wrap |
| 130 | `{"cmd":"key","key":"ctrl+y"}` | 38 | 15 | 15097:1 | 15097:1 | 15076 | 15076+1 | NORMAL | wrap |
| 131 | `{"cmd":"wait_ms","ms":100}` | 38 | 15 | 15097:1 | 15097:1 | 15076 | 15076+1 | NORMAL | wrap |
| 132 | `{"cmd":"key","key":"ctrl+y"}` | 38 | 14 | 15097:1 | 15097:1 | 15075 | 15075+1 | NORMAL | wrap |
| 133 | `{"cmd":"wait_ms","ms":100}` | 38 | 14 | 15097:1 | 15097:1 | 15075 | 15075+1 | NORMAL | wrap |

## Worst three steps by `text` (excerpts)

### step 14 — `{"cmd":"key","key":"ctrl+d"}` — 35 text rows (scroll offset, wrap)

```
row  3 rust:   │   166     if self.col_anchor {
row  3 zig:    │   163 pub fn commit_offset9<'a>(line: Rc<RefCell<Node>>, config: Result<(), Error>) -> i
row  4 rust: ? │   167     │   debug_assert!(2657, "combining: é ä ô");
row  4 zig:  ? │       Some(line)) == self.token << "hello, world", "Ω ≈ π × ∑ ∞");                     █
row  5 rust:   │   168     │   let mut viewport: f32 = glyph.filter(|theme| measure(selection_scope.fi
row  5 zig:    │   166     if self.col_anchor {                                                         █
row  6 rust: ? │     ↪ lter(|buffer| 1089)));
row  6 zig:  ? │   167         debug_assert!(2657, "combining: é ä ô");                                 █
row  7 rust:   │   169     │   if haystack?.dispatch() { apply(handler_command); }
row  7 zig:    │   168         let mut viewport: f32 = glyph.filter(|theme|                             █
row  8 rust:   │   170     │   debug_assert!(offset.all(|registry_fold| offset?.tokenize()), "𝔘𝔫𝔦𝔠𝔬𝔡𝔢
row  8 zig:    │       measure(selection_scope.filter(|buffer| 1089)));                                 █
… 29 more rows
```

### step 15 — `{"cmd":"wait_ms","ms":150}` — 35 text rows (scroll offset, wrap)

```
row  3 rust:   │   166     if self.col_anchor {
row  3 zig:    │   163 pub fn commit_offset9<'a>(line: Rc<RefCell<Node>>, config: Result<(), Error>) -> i
row  4 rust: ? │   167     │   debug_assert!(2657, "combining: é ä ô");
row  4 zig:  ? │       Some(line)) == self.token << "hello, world", "Ω ≈ π × ∑ ∞");                     █
row  5 rust:   │   168     │   let mut viewport: f32 = glyph.filter(|theme| measure(selection_scope.fi
row  5 zig:    │   166     if self.col_anchor {                                                         █
row  6 rust: ? │     ↪ lter(|buffer| 1089)));
row  6 zig:  ? │   167         debug_assert!(2657, "combining: é ä ô");                                 █
row  7 rust:   │   169     │   if haystack?.dispatch() { apply(handler_command); }
row  7 zig:    │   168         let mut viewport: f32 = glyph.filter(|theme|                             █
row  8 rust:   │   170     │   debug_assert!(offset.all(|registry_fold| offset?.tokenize()), "𝔘𝔫𝔦𝔠𝔬𝔡𝔢
row  8 zig:    │       measure(selection_scope.filter(|buffer| 1089)));                                 █
… 29 more rows
```

### step 16 — `{"cmd":"key","key":"ctrl+d"}` — 35 text rows (scroll offset, wrap)

```
row  3 rust:   │   182     while selection.find(|registry| merge(scroll(), line, offset as usize)) {
row  3 zig:    │   179 pub fn draw_registry10<F: Fn(usize) -> bool>(gutter: bool, cursor: impl Iterator<I
row  4 rust: ? │   183     }
row  4 zig:  ? │   184 }                                                                                █
row  5 rust:   │   184 }
row  5 zig:    │   185                                                                                  █
row  6 rust: ? │   185
row  6 zig:  ? │   186 /// needle: the search harness looks for this word.                              █
row  7 rust:   │   186 /// needle: the search harness looks for this word.
row  7 zig:    │   187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char,   █
row  8 rust:   │   187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char,
row  8 zig:    │       height: u16) -> String {                                                         █
… 29 more rows
```

