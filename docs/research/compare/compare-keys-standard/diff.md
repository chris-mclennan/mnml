# compare-keys-standard — per-step diff (120x40)

`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). `text`: body rows (2..37) still differing once the tree's cursor cell (column 4), the last column (the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. `cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter (neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. `class`: an automatic first guess — the research doc holds the reviewed one.

| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |
|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|
| 0 | `{"cmd":"key","key":"esc"}` | 4 | 1 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 1 | `{"cmd":"key","key":"esc"}` | 4 | 1 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 38 | 9 | 1:1 | 1:1 | 1 | 1 | none | wrap, gutter |
| 3 | `{"cmd":"wait_ms","ms":800}` | 38 | 6 | 1:1 | 1:1 | 1 | 1 | none | wrap |
| 4 | `{"cmd":"key","key":"pagedown"}` | 38 | 10 | 36:1 | 36:1 | 8 | 8 | none | wrap, gutter |
| 5 | `{"cmd":"wait_ms","ms":150}` | 38 | 9 | 36:1 | 36:1 | 8 | 8 | none | wrap |
| 6 | `{"cmd":"key","key":"pagedown"}` | 38 | 14 | 71:1 | 71:1 | 39 | 39 | none | wrap, gutter |
| 7 | `{"cmd":"wait_ms","ms":150}` | 38 | 13 | 71:1 | 71:1 | 39 | 39 | none | wrap |
| 8 | `{"cmd":"key","key":"pagedown"}` | 38 | 13 | 106:1 | 106:1 | 77 | 77 | none | wrap, gutter |
| 9 | `{"cmd":"wait_ms","ms":150}` | 38 | 12 | 106:1 | 106:1 | 77 | 77 | none | wrap |
| 10 | `{"cmd":"key","key":"pagedown"}` | 38 | 31 | 141:1 | 141:1 | 112 | 112+1 | none | wrap |
| 11 | `{"cmd":"wait_ms","ms":150}` | 38 | 31 | 141:1 | 141:1 | 112 | 112+1 | none | wrap |
| 12 | `{"cmd":"key","key":"pagedown"}` | 38 | 24 | 176:1 | 176:1 | 149 | 149+1 | none | wrap |
| 13 | `{"cmd":"wait_ms","ms":150}` | 38 | 24 | 176:1 | 176:1 | 149 | 149+1 | none | wrap |
| 14 | `{"cmd":"key","key":"pageup"}` | 38 | 23 | 141:1 | 141:1 | 141 | 141 | none | wrap, gutter |
| 15 | `{"cmd":"wait_ms","ms":150}` | 38 | 21 | 141:1 | 141:1 | 141 | 141 | none | wrap |
| 16 | `{"cmd":"key","key":"pageup"}` | 38 | 27 | 106:1 | 106:1 | 106 | 106 | none | wrap |
| 17 | `{"cmd":"wait_ms","ms":150}` | 38 | 27 | 106:1 | 106:1 | 106 | 106 | none | wrap |
| 18 | `{"cmd":"key","key":"ctrl+end"}` | 38 | 34 | 6000:21 | 6000:21 | 5973 | 5974 | none | scroll offset, wrap |
| 19 | `{"cmd":"wait_ms","ms":150}` | 38 | 34 | 6000:21 | 6000:21 | 5973 | 5974 | none | scroll offset, wrap |
| 20 | `{"cmd":"key","key":"ctrl+home"}` | 38 | 10 | 1:1 | 1:1 | 1 | 1 | none | wrap, gutter |
| 21 | `{"cmd":"wait_ms","ms":150}` | 38 | 9 | 1:1 | 1:1 | 1 | 1 | none | wrap |
| 22 | `{"cmd":"key","key":"down"}` | 38 | 10 | 2:1 | 2:1 | 1 | 1 | none | wrap, gutter |
| 23 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 2:1 | 2:1 | 1 | 1 | none | wrap |
| 24 | `{"cmd":"key","key":"down"}` | 38 | 10 | 3:1 | 3:1 | 1 | 1 | none | wrap, gutter |
| 25 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 3:1 | 3:1 | 1 | 1 | none | wrap |
| 26 | `{"cmd":"key","key":"down"}` | 38 | 10 | 4:1 | 4:1 | 1 | 1 | none | wrap, gutter |
| 27 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 4:1 | 4:1 | 1 | 1 | none | wrap |
| 28 | `{"cmd":"key","key":"down"}` | 38 | 9 | 5:1 | 5:1 | 1 | 1 | none | wrap, gutter |
| 29 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 5:1 | 5:1 | 1 | 1 | none | wrap |
| 30 | `{"cmd":"key","key":"down"}` | 38 | 6 | 6:1 | 6:1 | 1 | 1 | none | wrap |
| 31 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 6:1 | 6:1 | 1 | 1 | none | wrap |
| 32 | `{"cmd":"key","key":"down"}` | 38 | 6 | 7:1 | 7:1 | 1 | 1 | none | wrap |
| 33 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 7:1 | 7:1 | 1 | 1 | none | wrap |
| 34 | `{"cmd":"key","key":"down"}` | 38 | 6 | 8:1 | 8:1 | 1 | 1 | none | wrap |
| 35 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 8:1 | 8:1 | 1 | 1 | none | wrap |
| 36 | `{"cmd":"key","key":"down"}` | 38 | 9 | 9:1 | 9:1 | 1 | 1 | none | wrap, gutter |
| 37 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 9:1 | 9:1 | 1 | 1 | none | wrap, gutter |
| 38 | `{"cmd":"key","key":"down"}` | 38 | 7 | 10:1 | 10:1 | 1 | 1 | none | wrap, gutter |
| 39 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 10:1 | 10:1 | 1 | 1 | none | wrap |
| 40 | `{"cmd":"key","key":"down"}` | 38 | 9 | 11:1 | 11:1 | 1 | 1 | none | wrap, gutter |
| 41 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 11:1 | 11:1 | 1 | 1 | none | wrap |
| 42 | `{"cmd":"key","key":"down"}` | 38 | 9 | 12:1 | 12:1 | 1 | 1 | none | wrap, gutter |
| 43 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 12:1 | 12:1 | 1 | 1 | none | wrap |
| 44 | `{"cmd":"key","key":"down"}` | 38 | 6 | 13:1 | 13:1 | 1 | 1 | none | wrap |
| 45 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 13:1 | 13:1 | 1 | 1 | none | wrap |
| 46 | `{"cmd":"key","key":"down"}` | 38 | 6 | 14:1 | 14:1 | 1 | 1 | none | wrap |
| 47 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 14:1 | 14:1 | 1 | 1 | none | wrap |
| 48 | `{"cmd":"key","key":"down"}` | 38 | 6 | 15:1 | 15:1 | 1 | 1 | none | wrap |
| 49 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 15:1 | 15:1 | 1 | 1 | none | wrap |
| 50 | `{"cmd":"key","key":"down"}` | 38 | 6 | 16:1 | 16:1 | 1 | 1 | none | wrap |
| 51 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 16:1 | 16:1 | 1 | 1 | none | wrap |
| 52 | `{"cmd":"key","key":"down"}` | 38 | 6 | 17:1 | 17:1 | 1 | 1 | none | wrap |
| 53 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 17:1 | 17:1 | 1 | 1 | none | wrap |
| 54 | `{"cmd":"key","key":"down"}` | 38 | 6 | 18:1 | 18:1 | 1 | 1 | none | wrap |
| 55 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 18:1 | 18:1 | 1 | 1 | none | wrap |
| 56 | `{"cmd":"key","key":"down"}` | 38 | 6 | 19:1 | 19:1 | 1 | 1 | none | wrap |
| 57 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 19:1 | 19:1 | 1 | 1 | none | wrap |
| 58 | `{"cmd":"key","key":"down"}` | 38 | 7 | 20:1 | 20:1 | 1 | 1 | none | wrap, gutter |
| 59 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 20:1 | 20:1 | 1 | 1 | none | wrap |
| 60 | `{"cmd":"key","key":"down"}` | 38 | 6 | 21:1 | 21:1 | 1 | 1 | none | wrap |
| 61 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 21:1 | 21:1 | 1 | 1 | none | wrap |
| 62 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:1 | 22:1 | 1 | 1 | none | wrap |
| 63 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:1 | 22:1 | 1 | 1 | none | wrap |
| 64 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:2 | 22:2 | 1 | 1 | none | wrap |
| 65 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:2 | 22:2 | 1 | 1 | none | wrap |
| 66 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:3 | 22:3 | 1 | 1 | none | wrap |
| 67 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:3 | 22:3 | 1 | 1 | none | wrap |
| 68 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:4 | 22:4 | 1 | 1 | none | wrap |
| 69 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:4 | 22:4 | 1 | 1 | none | wrap |
| 70 | `{"cmd":"key","key":"right"}` | 38 | 9 | 22:5 | 22:5 | 1 | 1 | none | wrap, gutter |
| 71 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:5 | 22:5 | 1 | 1 | none | wrap |
| 72 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:6 | 22:6 | 1 | 1 | none | wrap |
| 73 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:6 | 22:6 | 1 | 1 | none | wrap |
| 74 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:7 | 22:7 | 1 | 1 | none | wrap |
| 75 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:7 | 22:7 | 1 | 1 | none | wrap |
| 76 | `{"cmd":"key","key":"right"}` | 38 | 9 | 22:8 | 22:8 | 1 | 1 | none | wrap, gutter |
| 77 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 22:8 | 22:8 | 1 | 1 | none | wrap, gutter |
| 78 | `{"cmd":"key","key":"right"}` | 37 | 7 | 22:9 | 22:9 | 1 | 1 | none | wrap, gutter |
| 79 | `{"cmd":"wait_ms","ms":100}` | 37 | 6 | 22:9 | 22:9 | 1 | 1 | none | wrap |
| 80 | `{"cmd":"key","key":"right"}` | 37 | 6 | 22:10 | 22:10 | 1 | 1 | none | wrap |
| 81 | `{"cmd":"wait_ms","ms":100}` | 37 | 6 | 22:10 | 22:10 | 1 | 1 | none | wrap |
| 82 | `{"cmd":"key","key":"right"}` | 37 | 6 | 22:11 | 22:11 | 1 | 1 | none | wrap |
| 83 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:11 | 22:11 | 1 | 1 | none | wrap |
| 84 | `{"cmd":"key","key":"right"}` | 38 | 9 | 22:12 | 22:12 | 1 | 1 | none | wrap, gutter |
| 85 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 22:12 | 22:12 | 1 | 1 | none | wrap, gutter |
| 86 | `{"cmd":"key","key":"right"}` | 38 | 7 | 22:13 | 22:13 | 1 | 1 | none | wrap, gutter |
| 87 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:13 | 22:13 | 1 | 1 | none | wrap |
| 88 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:14 | 22:14 | 1 | 1 | none | wrap |
| 89 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:14 | 22:14 | 1 | 1 | none | wrap |
| 90 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:15 | 22:15 | 1 | 1 | none | wrap |
| 91 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:15 | 22:15 | 1 | 1 | none | wrap |
| 92 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:16 | 22:16 | 1 | 1 | none | wrap |
| 93 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:16 | 22:16 | 1 | 1 | none | wrap |
| 94 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:17 | 22:17 | 1 | 1 | none | wrap |
| 95 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:17 | 22:17 | 1 | 1 | none | wrap |
| 96 | `{"cmd":"key","key":"right"}` | 38 | 6 | 22:18 | 22:18 | 1 | 1 | none | wrap |
| 97 | `{"cmd":"wait_ms","ms":100}` | 37 | 6 | 22:18 | 22:18 | 1 | 1 | none | wrap |
| 98 | `{"cmd":"key","key":"right"}` | 37 | 9 | 22:19 | 22:19 | 1 | 1 | none | wrap, gutter |
| 99 | `{"cmd":"wait_ms","ms":100}` | 37 | 9 | 22:19 | 22:19 | 1 | 1 | none | wrap, gutter |
| 100 | `{"cmd":"key","key":"right"}` | 37 | 7 | 22:20 | 22:20 | 1 | 1 | none | wrap, gutter |
| 101 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:20 | 22:20 | 1 | 1 | none | wrap |
| 102 | `{"cmd":"key","key":"end"}` | 38 | 9 | 22:58 | 22:58 | 1 | 1 | none | wrap, gutter |
| 103 | `{"cmd":"wait_ms","ms":150}` | 38 | 6 | 22:58 | 22:58 | 1 | 1 | none | wrap |
| 104 | `{"cmd":"key","key":"home"}` | 38 | 6 | 22:1 | 22:1 | 1 | 1 | none | wrap |
| 105 | `{"cmd":"wait_ms","ms":150}` | 38 | 6 | 22:1 | 22:1 | 1 | 1 | none | wrap |
| 106 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 9 | 22:5 | 22:5 | 1 | 1 | none | wrap, gutter |
| 107 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:5 | 22:5 | 1 | 1 | none | wrap |
| 108 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 7 | 22:9 | 22:9 | 1 | 1 | none | wrap, gutter |
| 109 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:9 | 22:9 | 1 | 1 | none | wrap |
| 110 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 7 | 22:13 | 22:13 | 1 | 1 | none | wrap, gutter |
| 111 | `{"cmd":"wait_ms","ms":100}` | 38 | 7 | 22:13 | 22:13 | 1 | 1 | none | wrap, gutter |
| 112 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 7 | 22:20 | 22:20 | 1 | 1 | none | wrap, gutter |
| 113 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:20 | 22:20 | 1 | 1 | none | wrap |
| 114 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 7 | 22:26 | 22:26 | 1 | 1 | none | wrap, gutter |
| 115 | `{"cmd":"wait_ms","ms":100}` | 37 | 6 | 22:26 | 22:26 | 1 | 1 | none | wrap |
| 116 | `{"cmd":"key","key":"ctrl+right"}` | 37 | 7 | 22:33 | 22:33 | 1 | 1 | none | wrap, gutter |
| 117 | `{"cmd":"wait_ms","ms":100}` | 37 | 7 | 22:33 | 22:33 | 1 | 1 | none | wrap, gutter |
| 118 | `{"cmd":"key","key":"ctrl+right"}` | 37 | 7 | 22:42 | 22:42 | 1 | 1 | none | wrap, gutter |
| 119 | `{"cmd":"wait_ms","ms":100}` | 37 | 6 | 22:42 | 22:42 | 1 | 1 | none | wrap |
| 120 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 7 | 22:46 | 22:46 | 1 | 1 | none | wrap, gutter |
| 121 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:46 | 22:46 | 1 | 1 | none | wrap |
| 122 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 7 | 22:53 | 22:53 | 1 | 1 | none | wrap, gutter |
| 123 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:53 | 22:53 | 1 | 1 | none | wrap |
| 124 | `{"cmd":"key","key":"ctrl+right"}` | 38 | 9 | 22:57 | 22:57 | 1 | 1 | none | wrap, gutter |
| 125 | `{"cmd":"wait_ms","ms":100}` | 38 | 9 | 22:57 | 22:57 | 1 | 1 | none | wrap, gutter |
| 126 | `{"cmd":"key","key":"ctrl+left"}` | 38 | 6 | 22:53 | 22:53 | 1 | 1 | none | wrap |
| 127 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:53 | 22:53 | 1 | 1 | none | wrap |
| 128 | `{"cmd":"key","key":"ctrl+left"}` | 38 | 7 | 22:46 | 22:46 | 1 | 1 | none | wrap, gutter |
| 129 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:46 | 22:46 | 1 | 1 | none | wrap |
| 130 | `{"cmd":"key","key":"ctrl+left"}` | 38 | 7 | 22:42 | 22:42 | 1 | 1 | none | wrap, gutter |
| 131 | `{"cmd":"wait_ms","ms":100}` | 38 | 7 | 22:42 | 22:42 | 1 | 1 | none | wrap, gutter |
| 132 | `{"cmd":"key","key":"ctrl+left"}` | 38 | 7 | 22:33 | 22:33 | 1 | 1 | none | wrap, gutter |
| 133 | `{"cmd":"wait_ms","ms":100}` | 38 | 7 | 22:33 | 22:33 | 1 | 1 | none | wrap, gutter |
| 134 | `{"cmd":"key","key":"ctrl+left"}` | 38 | 7 | 22:26 | 22:26 | 1 | 1 | none | wrap, gutter |
| 135 | `{"cmd":"wait_ms","ms":100}` | 38 | 6 | 22:26 | 22:26 | 1 | 1 | none | wrap |
| 136 | `{"cmd":"key","key":"ctrl+f"}` | 38 | 11 | 22:26 | 22:26 | 1 | 1 | none | wrap |
| 137 | `{"cmd":"wait_ms","ms":300}` | 38 | 11 | 22:26 | 22:26 | 1 | 1 | none | wrap |
| 138 | `{"cmd":"type","text":"needle\n"}` | 38 | 8 | 25:50 | 25:50 | 1 | 1 | none | wrap, gutter |
| 139 | `{"cmd":"wait_ms","ms":300}` | 38 | 7 | 25:50 | 25:50 | 1 | 1 | none | wrap |
| 140 | `{"cmd":"key","key":"enter"}` | 38 | 35 | 26:5 | 50:12 | 1 | 21 | none | scroll offset, cursor placement, wrap |
| 141 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 26:5 | 50:12 | 1 | 21 | none | scroll offset, cursor placement, wrap |
| 142 | `{"cmd":"key","key":"enter"}` | 38 | 35 | 27:5 | 67:24 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 143 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 27:5 | 67:24 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 144 | `{"cmd":"key","key":"enter"}` | 38 | 35 | 28:5 | 67:41 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 145 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 28:5 | 67:41 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 146 | `{"cmd":"key","key":"esc"}` | 38 | 35 | 28:5 | 67:41 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 147 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 28:5 | 67:41 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 148 | `{"cmd":"key","key":"ctrl+g"}` | 38 | 33 | 28:5 | 67:41 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 149 | `{"cmd":"wait_ms","ms":300}` | 38 | 33 | 28:5 | 67:41 | 1 | 36+1 | none | scroll offset, cursor placement, wrap |
| 150 | `{"cmd":"type","text":"3000\n"}` | 38 | 35 | 3000:1 | 3000:1 | 2969 | 2968+1 | none | scroll offset, wrap, gutter |
| 151 | `{"cmd":"wait_ms","ms":300}` | 38 | 35 | 3000:1 | 3000:1 | 2969 | 2968+1 | none | scroll offset, wrap, gutter |
| 152 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3001:1 | 3001:1 | 2970 | 2969+1 | none | scroll offset, wrap, gutter |
| 153 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3001:1 | 3001:1 | 2970 | 2969+1 | none | scroll offset, wrap, gutter |
| 154 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3002:1 | 3002:1 | 2971 | 2970 | none | scroll offset, wrap, gutter |
| 155 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3002:1 | 3002:1 | 2971 | 2970 | none | scroll offset, wrap, gutter |
| 156 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3003:1 | 3003:1 | 2972 | 2971 | none | scroll offset, wrap |
| 157 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3003:1 | 3003:1 | 2972 | 2971 | none | scroll offset, wrap |
| 158 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3004:1 | 3004:1 | 2973 | 2972 | none | scroll offset, wrap |
| 159 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3004:1 | 3004:1 | 2973 | 2972 | none | scroll offset, wrap |
| 160 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3005:1 | 3005:1 | 2974 | 2973 | none | scroll offset, wrap |
| 161 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3005:1 | 3005:1 | 2974 | 2973 | none | scroll offset, wrap |
| 162 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3006:1 | 3006:1 | 2975 | 2974 | none | scroll offset, wrap |
| 163 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3006:1 | 3006:1 | 2975 | 2974 | none | scroll offset, wrap |
| 164 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3007:1 | 3007:1 | 2976 | 2975+1 | none | scroll offset, wrap |
| 165 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3007:1 | 3007:1 | 2976 | 2975+1 | none | scroll offset, wrap |
| 166 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3008:1 | 3008:1 | 2977 | 2976+1 | none | scroll offset, wrap, gutter |
| 167 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3008:1 | 3008:1 | 2977 | 2976+1 | none | scroll offset, wrap, gutter |
| 168 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3009:1 | 3009:1 | 2978 | 2977+1 | none | scroll offset, wrap |
| 169 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3009:1 | 3009:1 | 2978 | 2977+1 | none | scroll offset, wrap |
| 170 | `{"cmd":"key","key":"ctrl+down"}` | 38 | 35 | 3010:1 | 3010:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 171 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3010:1 | 3010:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 172 | `{"cmd":"key","key":"ctrl+up"}` | 38 | 35 | 3009:1 | 3009:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 173 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3009:1 | 3009:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 174 | `{"cmd":"key","key":"ctrl+up"}` | 38 | 35 | 3008:1 | 3008:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 175 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3008:1 | 3008:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 176 | `{"cmd":"key","key":"ctrl+up"}` | 38 | 35 | 3007:1 | 3007:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 177 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3007:1 | 3007:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 178 | `{"cmd":"key","key":"ctrl+up"}` | 38 | 35 | 3006:1 | 3006:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 179 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3006:1 | 3006:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 180 | `{"cmd":"key","key":"ctrl+up"}` | 38 | 35 | 3005:1 | 3005:1 | 2979 | 2978+1 | none | scroll offset, wrap |
| 181 | `{"cmd":"wait_ms","ms":100}` | 38 | 35 | 3005:1 | 3005:1 | 2979 | 2978+1 | none | scroll offset, wrap |

## Worst three steps by `text` (excerpts)

### step 140 — `{"cmd":"key","key":"enter"}` — 35 text rows (scroll offset, cursor placement, wrap)

```
row  3 rust:   │    1 //! A large, deterministic fixture for the navigation harness.
row  3 zig:    │   21                                                                                   █
row  4 rust: ● │    2 //! Generated by tools/gen-large-fixture.py — do not edit by hand.
row  4 zig:  ? │   22 /// See the design notes before touching the layout tree.                         █
row  5 rust:   │    3 #![allow(dead_code, unused_variables, unused_mut, clippy::all)]
row  5 zig:    │   23 pub fn apply_viewport2<K, V>() -> u16 {                                           █
row  6 rust: ? │    4
row  6 zig:  ? │   24     let mut rect_line: u64 = registry_command.find(|scope| cell_scope?.drain());  █
row  7 rust:   │    5 use std::collections::HashMap;
row  7 zig:    │   25     while collect(palette_theme?.paint() << Some(needle),                         █
row  8 rust:   │    6 use std::rc::Rc;
row  8 zig:    │      viewport.any(|offset_event| 3566) == registry_fold as usize / None,               █
… 29 more rows
```

### step 141 — `{"cmd":"wait_ms","ms":150}` — 35 text rows (scroll offset, cursor placement, wrap)

```
row  3 rust:   │    1 //! A large, deterministic fixture for the navigation harness.
row  3 zig:    │   21                                                                                   █
row  4 rust: ● │    2 //! Generated by tools/gen-large-fixture.py — do not edit by hand.
row  4 zig:  ? │   22 /// See the design notes before touching the layout tree.                         █
row  5 rust:   │    3 #![allow(dead_code, unused_variables, unused_mut, clippy::all)]
row  5 zig:    │   23 pub fn apply_viewport2<K, V>() -> u16 {                                           █
row  6 rust: ? │    4
row  6 zig:  ? │   24     let mut rect_line: u64 = registry_command.find(|scope| cell_scope?.drain());  █
row  7 rust:   │    5 use std::collections::HashMap;
row  7 zig:    │   25     while collect(palette_theme?.paint() << Some(needle),                         █
row  8 rust:   │    6 use std::rc::Rc;
row  8 zig:    │      viewport.any(|offset_event| 3566) == registry_fold as usize / None,               █
… 29 more rows
```

### step 142 — `{"cmd":"key","key":"enter"}` — 35 text rows (scroll offset, cursor placement, wrap)

```
row  3 rust:   │    1 //! A large, deterministic fixture for the navigation harness.
row  3 zig:    │   23 pub fn apply_viewport2<K, V>() -> u16 {
row  4 rust: ● │    2 //! Generated by tools/gen-large-fixture.py — do not edit by hand.
row  4 zig:  ? │   37                                                                                   █
row  5 rust:   │    3 #![allow(dead_code, unused_variables, unused_mut, clippy::all)]
row  5 zig:    │   38 /// Every mutation goes through apply(); no direct buffer writes.                 █
row  6 rust: ? │    4
row  6 zig:  ? │   39 #[derive(Debug, Clone, PartialEq)]                                                █
row  7 rust:   │    5 use std::collections::HashMap;
row  7 zig:    │   40 pub struct Registry39 {                                                           █
row  8 rust:   │    6 use std::rc::Rc;
row  8 zig:    │   41     pub cursor: char,                                                             █
… 29 more rows
```

