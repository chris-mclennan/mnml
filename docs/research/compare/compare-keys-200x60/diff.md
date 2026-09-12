# compare-keys-200x60 — per-step diff (200x60)

`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). `text`: body rows (2..57) still differing once the tree's cursor cell (column 4), the last column (the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. `cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter (neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. `class`: an automatic first guess — the research doc holds the reviewed one.

| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |
|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|
| 0 | `{"cmd":"key","key":"esc"}` | 22 | 19 | 0:0 | 0:0 | ?+55 | ?+55 | none | highlight/other |
| 1 | `{"cmd":"key","key":"esc"}` | 22 | 19 | 0:0 | 0:0 | ?+55 | ?+55 | none | highlight/other |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 58 | 12 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap, gutter |
| 3 | `{"cmd":"wait_ms","ms":800}` | 58 | 7 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 4 | `{"cmd":"key","key":"pagedown"}` | 58 | 9 | 56:1 | 56:1 | 4 | 4 | NORMAL | wrap, gutter |
| 5 | `{"cmd":"wait_ms","ms":150}` | 58 | 8 | 56:1 | 56:1 | 4 | 4 | NORMAL | wrap |
| 6 | `{"cmd":"key","key":"pagedown"}` | 58 | 18 | 111:1 | 111:1 | 59 | 59+1 | NORMAL | wrap, gutter |
| 7 | `{"cmd":"wait_ms","ms":150}` | 58 | 17 | 111:1 | 111:1 | 59 | 59+1 | NORMAL | wrap |
| 8 | `{"cmd":"key","key":"pagedown"}` | 58 | 9 | 166:1 | 166:1 | 112 | 112+1 | NORMAL | highlight/other |
| 9 | `{"cmd":"wait_ms","ms":150}` | 58 | 9 | 166:1 | 166:1 | 112 | 112+1 | NORMAL | highlight/other |
| 10 | `{"cmd":"key","key":"pagedown"}` | 58 | 26 | 221:1 | 221:1 | 167 | 167+1 | NORMAL | gutter |
| 11 | `{"cmd":"wait_ms","ms":150}` | 58 | 25 | 221:1 | 221:1 | 167 | 167+1 | NORMAL | highlight/other |
| 12 | `{"cmd":"key","key":"pagedown"}` | 58 | 36 | 276:1 | 276:1 | 225 | 225+1 | NORMAL | wrap |
| 13 | `{"cmd":"wait_ms","ms":150}` | 58 | 37 | 276:1 | 276:1 | 225 | 225+1 | NORMAL | wrap |
| 14 | `{"cmd":"key","key":"ctrl+d"}` | 58 | 41 | 303:1 | 303:1 | 251 | 251+1 | NORMAL | wrap, gutter |
| 15 | `{"cmd":"wait_ms","ms":150}` | 58 | 40 | 303:1 | 303:1 | 251 | 251+1 | NORMAL | wrap |
| 16 | `{"cmd":"key","key":"ctrl+d"}` | 58 | 25 | 330:1 | 330:1 | 276 | 276+1 | NORMAL | highlight/other |
| 17 | `{"cmd":"wait_ms","ms":150}` | 58 | 25 | 330:1 | 330:1 | 276 | 276+1 | NORMAL | highlight/other |
| 18 | `{"cmd":"key","key":"ctrl+d"}` | 58 | 17 | 357:1 | 357:1 | 303 | 303+1 | NORMAL | highlight/other |
| 19 | `{"cmd":"wait_ms","ms":150}` | 58 | 17 | 357:1 | 357:1 | 303 | 303+1 | NORMAL | highlight/other |
| 20 | `{"cmd":"key","key":"G"}` | 58 | 14 | 6000:1 | 6000:1 | 5947 | 5947+1 | NORMAL | wrap, gutter |
| 21 | `{"cmd":"wait_ms","ms":150}` | 58 | 13 | 6000:1 | 6000:1 | 5947 | 5947+1 | NORMAL | wrap |
| 22 | `{"cmd":"key","key":"gg"}` | 58 | 8 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap, gutter |
| 23 | `{"cmd":"wait_ms","ms":150}` | 58 | 7 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 24 | `{"cmd":"key","key":"50%"}` | 58 | 25 | 3000:1 | 3000:1 | 2946 | 2946 | NORMAL | gutter |
| 25 | `{"cmd":"wait_ms","ms":150}` | 58 | 24 | 3000:1 | 3000:1 | 2946 | 2946 | NORMAL | highlight/other |
| 26 | `{"cmd":"type","text":"/needle\n"}` | 58 | 16 | 3016:17 | 3016:17 | 2962 | 2962+1 | NORMAL | gutter |
| 27 | `{"cmd":"wait_ms","ms":300}` | 58 | 14 | 3016:17 | 3016:17 | 2962 | 2962+1 | NORMAL | highlight/other |
| 28 | `{"cmd":"key","key":"n"}` | 58 | 14 | 3017:44 | 3017:44 | 2963 | 2963+1 | NORMAL | gutter |
| 29 | `{"cmd":"wait_ms","ms":150}` | 58 | 13 | 3017:44 | 3017:44 | 2963 | 2963+1 | NORMAL | highlight/other |
| 30 | `{"cmd":"key","key":"n"}` | 58 | 16 | 3038:12 | 3038:12 | 2984 | 2984+1 | NORMAL | highlight/other |
| 31 | `{"cmd":"wait_ms","ms":150}` | 58 | 16 | 3038:12 | 3038:12 | 2984 | 2984+1 | NORMAL | highlight/other |
| 32 | `{"cmd":"key","key":"n"}` | 58 | 18 | 3050:47 | 3050:47 | 2996 | 2996+1 | NORMAL | gutter |
| 33 | `{"cmd":"wait_ms","ms":150}` | 58 | 17 | 3050:47 | 3050:47 | 2996 | 2996+1 | NORMAL | highlight/other |
| 34 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:53 | 3050:53 | 2996 | 2996+1 | NORMAL | gutter |
| 35 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:53 | 3050:53 | 2996 | 2996+1 | NORMAL | gutter |
| 36 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:55 | 3050:55 | 2996 | 2996+1 | NORMAL | gutter |
| 37 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:55 | 3050:55 | 2996 | 2996+1 | NORMAL | highlight/other |
| 38 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:61 | 3050:61 | 2996 | 2996+1 | NORMAL | gutter |
| 39 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:61 | 3050:61 | 2996 | 2996+1 | NORMAL | gutter |
| 40 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:66 | 3050:66 | 2996 | 2996+1 | NORMAL | gutter |
| 41 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:66 | 3050:66 | 2996 | 2996+1 | NORMAL | highlight/other |
| 42 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:71 | 3050:71 | 2996 | 2996+1 | NORMAL | gutter |
| 43 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:71 | 3050:71 | 2996 | 2996+1 | NORMAL | gutter |
| 44 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:74 | 3050:74 | 2996 | 2996+1 | NORMAL | gutter |
| 45 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:74 | 3050:74 | 2996 | 2996+1 | NORMAL | highlight/other |
| 46 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:79 | 3050:79 | 2996 | 2996+1 | NORMAL | gutter |
| 47 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:79 | 3050:79 | 2996 | 2996+1 | NORMAL | gutter |
| 48 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:81 | 3050:81 | 2996 | 2996+1 | NORMAL | gutter |
| 49 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:81 | 3050:81 | 2996 | 2996+1 | NORMAL | highlight/other |
| 50 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:86 | 3050:86 | 2996 | 2996+1 | NORMAL | gutter |
| 51 | `{"cmd":"wait_ms","ms":100}` | 58 | 21 | 3050:86 | 3050:86 | 2996 | 2996+1 | NORMAL | gutter |
| 52 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:94 | 3050:94 | 2996 | 2996+1 | NORMAL | gutter |
| 53 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:94 | 3050:94 | 2996 | 2996+1 | NORMAL | gutter |
| 54 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:95 | 3050:95 | 2996 | 2996+1 | NORMAL | gutter |
| 55 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:95 | 3050:95 | 2996 | 2996+1 | NORMAL | highlight/other |
| 56 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:100 | 3050:100 | 2996 | 2996+1 | NORMAL | gutter |
| 57 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:100 | 3050:100 | 2996 | 2996+1 | NORMAL | gutter |
| 58 | `{"cmd":"key","key":"w"}` | 58 | 17 | 3050:102 | 3050:102 | 2996 | 2996+1 | NORMAL | highlight/other |
| 59 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:102 | 3050:102 | 2996 | 2996+1 | NORMAL | highlight/other |
| 60 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:103 | 3050:103 | 2996 | 2996+1 | NORMAL | gutter |
| 61 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:103 | 3050:103 | 2996 | 2996+1 | NORMAL | gutter |
| 62 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:108 | 3050:108 | 2996 | 2996+1 | NORMAL | gutter |
| 63 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:108 | 3050:108 | 2996 | 2996+1 | NORMAL | gutter |
| 64 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:110 | 3050:110 | 2996 | 2996+1 | NORMAL | gutter |
| 65 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:110 | 3050:110 | 2996 | 2996+1 | NORMAL | gutter |
| 66 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:112 | 3050:112 | 2996 | 2996+1 | NORMAL | gutter |
| 67 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:112 | 3050:112 | 2996 | 2996+1 | NORMAL | gutter |
| 68 | `{"cmd":"key","key":"w"}` | 58 | 18 | 3050:114 | 3050:114 | 2996 | 2996+1 | NORMAL | gutter |
| 69 | `{"cmd":"wait_ms","ms":100}` | 58 | 18 | 3050:114 | 3050:114 | 2996 | 2996+1 | NORMAL | gutter |
| 70 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:117 | 3050:117 | 2996 | 2996+1 | NORMAL | gutter |
| 71 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:117 | 3050:117 | 2996 | 2996+1 | NORMAL | gutter |
| 72 | `{"cmd":"key","key":"w"}` | 58 | 20 | 3050:121 | 3050:121 | 2996 | 2996+1 | NORMAL | gutter |
| 73 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:121 | 3050:121 | 2996 | 2996+1 | NORMAL | highlight/other |
| 74 | `{"cmd":"key","key":"b"}` | 58 | 17 | 3050:117 | 3050:117 | 2996 | 2996+1 | NORMAL | highlight/other |
| 75 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:117 | 3050:117 | 2996 | 2996+1 | NORMAL | highlight/other |
| 76 | `{"cmd":"key","key":"b"}` | 58 | 17 | 3050:114 | 3050:114 | 2996 | 2996+1 | NORMAL | highlight/other |
| 77 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:114 | 3050:114 | 2996 | 2996+1 | NORMAL | highlight/other |
| 78 | `{"cmd":"key","key":"b"}` | 58 | 18 | 3050:112 | 3050:112 | 2996 | 2996+1 | NORMAL | gutter |
| 79 | `{"cmd":"wait_ms","ms":100}` | 58 | 18 | 3050:112 | 3050:112 | 2996 | 2996+1 | NORMAL | gutter |
| 80 | `{"cmd":"key","key":"b"}` | 58 | 20 | 3050:110 | 3050:110 | 2996 | 2996+1 | NORMAL | gutter |
| 81 | `{"cmd":"wait_ms","ms":100}` | 58 | 17 | 3050:110 | 3050:110 | 2996 | 2996+1 | NORMAL | highlight/other |
| 82 | `{"cmd":"key","key":"b"}` | 58 | 17 | 3050:108 | 3050:108 | 2996 | 2996+1 | NORMAL | highlight/other |
| 83 | `{"cmd":"wait_ms","ms":100}` | 58 | 20 | 3050:108 | 3050:108 | 2996 | 2996+1 | NORMAL | gutter |
| 84 | `{"cmd":"key","key":"}"}` | 58 | 29 | 3073:1 | 3073:1 | 3019 | 3019+1 | NORMAL | gutter |
| 85 | `{"cmd":"wait_ms","ms":150}` | 58 | 26 | 3073:1 | 3073:1 | 3019 | 3019+1 | NORMAL | highlight/other |
| 86 | `{"cmd":"key","key":"}"}` | 58 | 25 | 3086:1 | 3086:1 | 3032 | 3032+1 | NORMAL | highlight/other |
| 87 | `{"cmd":"wait_ms","ms":150}` | 58 | 25 | 3086:1 | 3086:1 | 3032 | 3032+1 | NORMAL | highlight/other |
| 88 | `{"cmd":"key","key":"}"}` | 58 | 26 | 3089:1 | 3089:1 | 3035 | 3035 | NORMAL | highlight/other |
| 89 | `{"cmd":"wait_ms","ms":150}` | 58 | 26 | 3089:1 | 3089:1 | 3035 | 3035 | NORMAL | highlight/other |
| 90 | `{"cmd":"key","key":"}"}` | 58 | 31 | 3097:1 | 3097:1 | 3043 | 3043 | NORMAL | highlight/other |
| 91 | `{"cmd":"wait_ms","ms":150}` | 58 | 31 | 3097:1 | 3097:1 | 3043 | 3043 | NORMAL | highlight/other |
| 92 | `{"cmd":"key","key":"}"}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 93 | `{"cmd":"wait_ms","ms":150}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 94 | `{"cmd":"key","key":"$"}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 95 | `{"cmd":"wait_ms","ms":150}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 96 | `{"cmd":"key","key":"0"}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 97 | `{"cmd":"wait_ms","ms":150}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 98 | `{"cmd":"key","key":"zz"}` | 58 | 13 | 3120:1 | 3120:1 | 3093 | 3093+1 | NORMAL | highlight/other |
| 99 | `{"cmd":"wait_ms","ms":150}` | 58 | 13 | 3120:1 | 3120:1 | 3093 | 3093+1 | NORMAL | highlight/other |
| 100 | `{"cmd":"key","key":"zt"}` | 58 | 14 | 3120:1 | 3120:1 | 3120+1 | 3120 | NORMAL | highlight/other |
| 101 | `{"cmd":"wait_ms","ms":150}` | 58 | 14 | 3120:1 | 3120:1 | 3120+1 | 3120 | NORMAL | highlight/other |
| 102 | `{"cmd":"key","key":"zb"}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 103 | `{"cmd":"wait_ms","ms":150}` | 58 | 26 | 3120:1 | 3120:1 | 3066 | 3066+1 | NORMAL | highlight/other |
| 104 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 26 | 3120:1 | 3120:1 | 3067 | 3067+1 | NORMAL | highlight/other |
| 105 | `{"cmd":"wait_ms","ms":100}` | 58 | 26 | 3120:1 | 3120:1 | 3067 | 3067+1 | NORMAL | highlight/other |
| 106 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 26 | 3120:1 | 3120:1 | 3068 | 3068+1 | NORMAL | highlight/other |
| 107 | `{"cmd":"wait_ms","ms":100}` | 58 | 26 | 3120:1 | 3120:1 | 3068 | 3068+1 | NORMAL | highlight/other |
| 108 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 25 | 3120:1 | 3120:1 | 3069 | 3069+1 | NORMAL | highlight/other |
| 109 | `{"cmd":"wait_ms","ms":100}` | 58 | 25 | 3120:1 | 3120:1 | 3069 | 3069+1 | NORMAL | highlight/other |
| 110 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 25 | 3120:1 | 3120:1 | 3070 | 3070+1 | NORMAL | highlight/other |
| 111 | `{"cmd":"wait_ms","ms":100}` | 58 | 25 | 3120:1 | 3120:1 | 3070 | 3070+1 | NORMAL | highlight/other |
| 112 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 26 | 3120:1 | 3120:1 | 3071 | 3071+1 | NORMAL | highlight/other |
| 113 | `{"cmd":"wait_ms","ms":100}` | 58 | 26 | 3120:1 | 3120:1 | 3071 | 3071+1 | NORMAL | highlight/other |
| 114 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 27 | 3120:1 | 3120:1 | 3072 | 3072+1 | NORMAL | highlight/other |
| 115 | `{"cmd":"wait_ms","ms":100}` | 58 | 27 | 3120:1 | 3120:1 | 3072 | 3072+1 | NORMAL | highlight/other |
| 116 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 27 | 3120:1 | 3120:1 | 3073 | 3073 | NORMAL | highlight/other |
| 117 | `{"cmd":"wait_ms","ms":100}` | 58 | 27 | 3120:1 | 3120:1 | 3073 | 3073 | NORMAL | highlight/other |
| 118 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 28 | 3120:1 | 3120:1 | 3074 | 3074 | NORMAL | highlight/other |
| 119 | `{"cmd":"wait_ms","ms":100}` | 58 | 28 | 3120:1 | 3120:1 | 3074 | 3074 | NORMAL | highlight/other |
| 120 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 28 | 3120:1 | 3120:1 | 3075 | 3075 | NORMAL | highlight/other |
| 121 | `{"cmd":"wait_ms","ms":100}` | 58 | 28 | 3120:1 | 3120:1 | 3075 | 3075 | NORMAL | highlight/other |
| 122 | `{"cmd":"key","key":"ctrl+e"}` | 58 | 28 | 3120:1 | 3120:1 | 3076 | 3076+1 | NORMAL | highlight/other |
| 123 | `{"cmd":"wait_ms","ms":100}` | 58 | 28 | 3120:1 | 3120:1 | 3076 | 3076+1 | NORMAL | highlight/other |
| 124 | `{"cmd":"key","key":"ctrl+y"}` | 58 | 28 | 3120:1 | 3120:1 | 3075 | 3075 | NORMAL | highlight/other |
| 125 | `{"cmd":"wait_ms","ms":100}` | 58 | 28 | 3120:1 | 3120:1 | 3075 | 3075 | NORMAL | highlight/other |
| 126 | `{"cmd":"key","key":"ctrl+y"}` | 58 | 28 | 3120:1 | 3120:1 | 3074 | 3074 | NORMAL | highlight/other |
| 127 | `{"cmd":"wait_ms","ms":100}` | 58 | 28 | 3120:1 | 3120:1 | 3074 | 3074 | NORMAL | highlight/other |
| 128 | `{"cmd":"key","key":"ctrl+y"}` | 58 | 27 | 3120:1 | 3120:1 | 3073 | 3073 | NORMAL | highlight/other |
| 129 | `{"cmd":"wait_ms","ms":100}` | 58 | 27 | 3120:1 | 3120:1 | 3073 | 3073 | NORMAL | highlight/other |
| 130 | `{"cmd":"key","key":"ctrl+y"}` | 58 | 27 | 3120:1 | 3120:1 | 3072 | 3072+1 | NORMAL | highlight/other |
| 131 | `{"cmd":"wait_ms","ms":100}` | 58 | 27 | 3120:1 | 3120:1 | 3072 | 3072+1 | NORMAL | highlight/other |
| 132 | `{"cmd":"key","key":"ctrl+y"}` | 58 | 26 | 3120:1 | 3120:1 | 3071 | 3071+1 | NORMAL | highlight/other |
| 133 | `{"cmd":"wait_ms","ms":100}` | 58 | 26 | 3120:1 | 3120:1 | 3071 | 3071+1 | NORMAL | highlight/other |

## Worst three steps by `text` (excerpts)

### step 14 — `{"cmd":"key","key":"ctrl+d"}` — 41 text rows (wrap, gutter)

```
row  3 rust:   │  251     let config: String = viewport_span?.poll();
row  3 zig:    │  249 pub fn scroll_editor15<'a>(palette_theme: String, editor: impl Iterator<Item = (usize, &'a str)>, registry_span: f32, scope: &'a [T]) -> Option<usize> {
row  4 rust: ? │  252     while config.take_while(|registry_palette| tick / self.viewport_byte) && draw("zero-widthjoiner" || registry as usize, measure(None, None), None * Some(pal
row  4 zig:  ? │  252     while config.take_while(|registry_palette| tick / self.viewport_byte) && draw("zero-widthjoiner" || registry as usize, measure(None, None), None *            █
row  5 rust:   │    ↪ ette)) {
row  5 zig:    │      Some(palette)) {                                                                                                                                                  █
row  6 rust: ? │  253     │   for _ in "日m本e語tの—テtキeスhトg" {
row  6 zig:  ? │  253         for _ in "日 本 語 の テ キ ス ト " {                                                                                                                             █
row  7 rust:   │  254     │   │   let handler: u32 = flush(self.haystack_buffer, fold?.merge(), tick.all(|tick| col));
row  7 zig:    │  254             let handler: u32 = flush(self.haystack_buffer, fold?.merge(), tick.all(|tick| col));                                                                  █
row  8 rust:   │  255     │   │   let handler: u16 = height_buffer.len();
row  8 zig:    │  255             let handler: u16 = height_buffer.len();                                                                                                               █
… 35 more rows
```

### step 15 — `{"cmd":"wait_ms","ms":150}` — 40 text rows (wrap)

```
row  3 rust:   │  251     let config: String = viewport_span?.poll();
row  3 zig:    │  249 pub fn scroll_editor15<'a>(palette_theme: String, editor: impl Iterator<Item = (usize, &'a str)>, registry_span: f32, scope: &'a [T]) -> Option<usize> {
row  4 rust: ? │  252     while config.take_while(|registry_palette| tick / self.viewport_byte) && draw("zero-widthjoiner" || registry as usize, measure(None, None), None * Some(pal
row  4 zig:  ? │  252     while config.take_while(|registry_palette| tick / self.viewport_byte) && draw("zero-widthjoiner" || registry as usize, measure(None, None), None *            █
row  5 rust:   │    ↪ ette)) {
row  5 zig:    │      Some(palette)) {                                                                                                                                                  █
row  6 rust: ? │  253     │   for _ in "日m本e語tの—テtキeスhトg" {
row  6 zig:  ? │  253         for _ in "日 本 語 の テ キ ス ト " {                                                                                                                             █
row  7 rust:   │  254     │   │   let handler: u32 = flush(self.haystack_buffer, fold?.merge(), tick.all(|tick| col));
row  7 zig:    │  254             let handler: u32 = flush(self.haystack_buffer, fold?.merge(), tick.all(|tick| col));                                                                  █
row  8 rust:   │  255     │   │   let handler: u16 = height_buffer.len();
row  8 zig:    │  255             let handler: u16 = height_buffer.len();                                                                                                               █
… 34 more rows
```

### step 13 — `{"cmd":"wait_ms","ms":150}` — 37 text rows (wrap)

```
row  3 rust:   │  225     }
row  3 zig:    │  215 pub fn render_config13(handler: u32, height_line: String, command: HashMap<String, Vec<u32>>) -> &'a [T] {
row  8 rust:   │  230 let mut config: Vec<u8> = resolve(handler as usize, glyph_line?.layout() - style_layout.map(|scope| height), tokenize(render(true), buffer_viewport.find(|line|
row  8 zig:    │  230     let mut config: Vec<u8> = resolve(handler as usize, glyph_line?.layout() - style_layout.map(|scope| height), tokenize(render(true),                           █
row  9 rust:   │    ↪  None), self.palette));
row  9 zig:    │      buffer_viewport.find(|line| None), self.palette));                                                                                                                █
row 10 rust:   │  231 if true {
row 10 zig:    │  231     if true {                                                                                                                                                     █
row 11 rust:   │  232 let tick_event: Vec<u8> = retreat(collect(selection.len()), width_cursor.len());
row 11 zig:    │  232         let tick_event: Vec<u8> = retreat(collect(selection.len()), width_cursor.len());                                                                          █
row 12 rust: … │  233 editor = clamp(handler_scope?.render(), scope_palette);
row 12 zig:  … │  233         editor = clamp(handler_scope?.render(), scope_palette);                                                                                                   █
… 31 more rows
```

