# compare-keys — per-step diff (120x40)

`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). `text`: body rows (2..37) still differing once the tree's cursor cell (column 4), the last column (the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. `cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter (neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. `class`: an automatic first guess — the research doc holds the reviewed one.

| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |
|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|
| 0 | `{"cmd":"key","key":"esc"}` | 21 | 19 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 1 | `{"cmd":"key","key":"esc"}` | 21 | 19 | 0:0 | 0:0 | ?+35 | ?+35 | none | highlight/other |
| 2 | `{"cmd":"open","path":"src/large.rs"}` | 37 | 9 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap, gutter |
| 3 | `{"cmd":"wait_ms","ms":800}` | 37 | 6 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 4 | `{"cmd":"key","key":"pagedown"}` | 37 | 10 | 36:1 | 36:1 | 8 | 8 | NORMAL | wrap, gutter |
| 5 | `{"cmd":"wait_ms","ms":150}` | 37 | 9 | 36:1 | 36:1 | 8 | 8 | NORMAL | wrap |
| 6 | `{"cmd":"key","key":"pagedown"}` | 37 | 14 | 71:1 | 71:1 | 39 | 39 | NORMAL | wrap, gutter |
| 7 | `{"cmd":"wait_ms","ms":150}` | 37 | 13 | 71:1 | 71:1 | 39 | 39 | NORMAL | wrap |
| 8 | `{"cmd":"key","key":"pagedown"}` | 38 | 13 | 106:1 | 106:1 | 77 | 77 | NORMAL | wrap, gutter |
| 9 | `{"cmd":"wait_ms","ms":150}` | 38 | 12 | 106:1 | 106:1 | 77 | 77 | NORMAL | wrap |
| 10 | `{"cmd":"key","key":"pagedown"}` | 38 | 31 | 141:1 | 141:1 | 112 | 112+1 | NORMAL | wrap |
| 11 | `{"cmd":"wait_ms","ms":150}` | 38 | 31 | 141:1 | 141:1 | 112 | 112+1 | NORMAL | wrap |
| 12 | `{"cmd":"key","key":"pagedown"}` | 38 | 24 | 176:1 | 176:1 | 149 | 149+1 | NORMAL | wrap |
| 13 | `{"cmd":"wait_ms","ms":150}` | 38 | 24 | 176:1 | 176:1 | 149 | 149+1 | NORMAL | wrap |
| 14 | `{"cmd":"key","key":"ctrl+d"}` | 38 | 22 | 193:1 | 193:1 | 165 | 165+1 | NORMAL | wrap |
| 15 | `{"cmd":"wait_ms","ms":150}` | 38 | 21 | 193:1 | 193:1 | 165 | 165+1 | NORMAL | wrap |
| 16 | `{"cmd":"key","key":"ctrl+d"}` | 38 | 35 | 210:1 | 210:1 | 182 | 183+1 | NORMAL | scroll offset, wrap |
| 17 | `{"cmd":"wait_ms","ms":150}` | 38 | 35 | 210:1 | 210:1 | 182 | 183+1 | NORMAL | scroll offset, wrap |
| 18 | `{"cmd":"key","key":"ctrl+d"}` | 38 | 30 | 227:1 | 227:1 | 200 | 201 | NORMAL | scroll offset, wrap |
| 19 | `{"cmd":"wait_ms","ms":150}` | 38 | 30 | 227:1 | 227:1 | 200 | 201 | NORMAL | scroll offset, wrap |
| 20 | `{"cmd":"key","key":"G"}` | 38 | 34 | 6000:1 | 6000:1 | 5973 | 5974+1 | NORMAL | scroll offset, wrap |
| 21 | `{"cmd":"wait_ms","ms":150}` | 38 | 34 | 6000:1 | 6000:1 | 5973 | 5974+1 | NORMAL | scroll offset, wrap |
| 22 | `{"cmd":"key","key":"gg"}` | 38 | 10 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap, gutter |
| 23 | `{"cmd":"wait_ms","ms":150}` | 38 | 9 | 1:1 | 1:1 | 1 | 1 | NORMAL | wrap |
| 24 | `{"cmd":"key","key":"50%"}` | 38 | 33 | 3000:1 | 3000:1 | 2969 | 2968+1 | NORMAL | scroll offset, wrap |
| 25 | `{"cmd":"wait_ms","ms":150}` | 38 | 33 | 3000:1 | 3000:1 | 2969 | 2968+1 | NORMAL | scroll offset, wrap |
| 26 | `{"cmd":"type","text":"/needle\n"}` | 38 | 21 | 3016:17 | 3016:17 | 2987 | 2986+1 | NORMAL | scroll offset, wrap, gutter |
| 27 | `{"cmd":"wait_ms","ms":300}` | 37 | 18 | 3016:17 | 3016:17 | 2987 | 2986+1 | NORMAL | scroll offset, wrap |
| 28 | `{"cmd":"key","key":"n"}` | 37 | 35 | 3017:44 | 3017:44 | 2988 | 2987+1 | NORMAL | scroll offset, wrap |
| 29 | `{"cmd":"wait_ms","ms":150}` | 37 | 35 | 3017:44 | 3017:44 | 2988 | 2987+1 | NORMAL | scroll offset, wrap |
| 30 | `{"cmd":"key","key":"n"}` | 37 | 28 | 3038:12 | 3038:12 | 3007 | 3008 | NORMAL | scroll offset, wrap |
| 31 | `{"cmd":"wait_ms","ms":150}` | 37 | 28 | 3038:12 | 3038:12 | 3007 | 3008 | NORMAL | scroll offset, wrap |
| 32 | `{"cmd":"key","key":"n"}` | 37 | 34 | 3050:47 | 3050:47 | 3018 | 3018+1 | NORMAL | wrap |
| 33 | `{"cmd":"wait_ms","ms":150}` | 37 | 34 | 3050:47 | 3050:47 | 3018 | 3018+1 | NORMAL | wrap |
| 34 | `{"cmd":"key","key":"w"}` | 37 | 34 | 3050:53 | 3050:53 | 3018 | 3018+1 | NORMAL | wrap |
| 35 | `{"cmd":"wait_ms","ms":100}` | 37 | 34 | 3050:53 | 3050:53 | 3018 | 3018+1 | NORMAL | wrap |
| 36 | `{"cmd":"key","key":"w"}` | 37 | 34 | 3050:55 | 3050:55 | 3018 | 3018+1 | NORMAL | wrap |
| 37 | `{"cmd":"wait_ms","ms":100}` | 37 | 34 | 3050:55 | 3050:55 | 3018 | 3018+1 | NORMAL | wrap |
| 38 | `{"cmd":"key","key":"w"}` | 37 | 34 | 3050:61 | 3050:61 | 3018 | 3018+1 | NORMAL | wrap |
| 39 | `{"cmd":"wait_ms","ms":100}` | 37 | 34 | 3050:61 | 3050:61 | 3018 | 3018+1 | NORMAL | wrap |
| 40 | `{"cmd":"key","key":"w"}` | 37 | 34 | 3050:66 | 3050:66 | 3018 | 3018+1 | NORMAL | wrap |
| 41 | `{"cmd":"wait_ms","ms":100}` | 38 | 34 | 3050:66 | 3050:66 | 3018 | 3018+1 | NORMAL | wrap |
| 42 | `{"cmd":"key","key":"w"}` | 38 | 34 | 3050:71 | 3050:71 | 3018 | 3018+1 | NORMAL | wrap |
| 43 | `{"cmd":"wait_ms","ms":100}` | 37 | 34 | 3050:71 | 3050:71 | 3018 | 3018+1 | NORMAL | wrap |
| 44 | `{"cmd":"key","key":"w"}` | 37 | 34 | 3050:74 | 3050:74 | 3018 | 3018+1 | NORMAL | wrap |
| 45 | `{"cmd":"wait_ms","ms":100}` | 37 | 34 | 3050:74 | 3050:74 | 3018 | 3018+1 | NORMAL | wrap |
| 46 | `{"cmd":"key","key":"w"}` | 37 | 34 | 3050:79 | 3050:79 | 3018 | 3018+1 | NORMAL | wrap |
| 47 | `{"cmd":"wait_ms","ms":100}` | 37 | 34 | 3050:79 | 3050:79 | 3018 | 3018+1 | NORMAL | wrap |
| 48 | `{"cmd":"key","key":"w"}` | 37 | 18 | 3050:81 | 3050:81 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 49 | `{"cmd":"wait_ms","ms":100}` | 37 | 19 | 3050:81 | 3050:81 | 3018 | 3019+1 | NORMAL | scroll offset, wrap |
| 50 | `{"cmd":"key","key":"w"}` | 37 | 18 | 3050:86 | 3050:86 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 51 | `{"cmd":"wait_ms","ms":100}` | 37 | 17 | 3050:86 | 3050:86 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 52 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:94 | 3050:94 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 53 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:94 | 3050:94 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 54 | `{"cmd":"key","key":"w"}` | 37 | 18 | 3050:95 | 3050:95 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 55 | `{"cmd":"wait_ms","ms":100}` | 37 | 17 | 3050:95 | 3050:95 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 56 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:100 | 3050:100 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 57 | `{"cmd":"wait_ms","ms":100}` | 37 | 17 | 3050:100 | 3050:100 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 58 | `{"cmd":"key","key":"w"}` | 38 | 17 | 3050:102 | 3050:102 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 59 | `{"cmd":"wait_ms","ms":100}` | 38 | 17 | 3050:102 | 3050:102 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 60 | `{"cmd":"key","key":"w"}` | 38 | 20 | 3050:103 | 3050:103 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 61 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:103 | 3050:103 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 62 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:108 | 3050:108 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 63 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:108 | 3050:108 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 64 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:110 | 3050:110 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 65 | `{"cmd":"wait_ms","ms":100}` | 37 | 17 | 3050:110 | 3050:110 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 66 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:112 | 3050:112 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 67 | `{"cmd":"wait_ms","ms":100}` | 37 | 17 | 3050:112 | 3050:112 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 68 | `{"cmd":"key","key":"w"}` | 37 | 18 | 3050:114 | 3050:114 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 69 | `{"cmd":"wait_ms","ms":100}` | 37 | 17 | 3050:114 | 3050:114 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 70 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:117 | 3050:117 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 71 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:117 | 3050:117 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 72 | `{"cmd":"key","key":"w"}` | 37 | 20 | 3050:121 | 3050:121 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 73 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:121 | 3050:121 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 74 | `{"cmd":"key","key":"b"}` | 37 | 17 | 3050:117 | 3050:117 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 75 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:117 | 3050:117 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 76 | `{"cmd":"key","key":"b"}` | 37 | 17 | 3050:114 | 3050:114 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 77 | `{"cmd":"wait_ms","ms":100}` | 38 | 17 | 3050:114 | 3050:114 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 78 | `{"cmd":"key","key":"b"}` | 38 | 18 | 3050:112 | 3050:112 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 79 | `{"cmd":"wait_ms","ms":100}` | 37 | 18 | 3050:112 | 3050:112 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 80 | `{"cmd":"key","key":"b"}` | 37 | 20 | 3050:110 | 3050:110 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 81 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:110 | 3050:110 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 82 | `{"cmd":"key","key":"b"}` | 37 | 17 | 3050:108 | 3050:108 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 83 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3050:108 | 3050:108 | 3018 | 3019+1 | NORMAL | scroll offset, wrap, gutter |
| 84 | `{"cmd":"key","key":"}"}` | 37 | 18 | 3073:1 | 3073:1 | 3044 | 3044+1 | NORMAL | wrap, gutter |
| 85 | `{"cmd":"wait_ms","ms":150}` | 37 | 18 | 3073:1 | 3073:1 | 3044 | 3044+1 | NORMAL | wrap, gutter |
| 86 | `{"cmd":"key","key":"}"}` | 38 | 23 | 3086:1 | 3086:1 | 3059 | 3059+1 | NORMAL | wrap |
| 87 | `{"cmd":"wait_ms","ms":150}` | 38 | 23 | 3086:1 | 3086:1 | 3059 | 3059+1 | NORMAL | wrap |
| 88 | `{"cmd":"key","key":"}"}` | 38 | 22 | 3089:1 | 3089:1 | 3062 | 3062+1 | NORMAL | wrap |
| 89 | `{"cmd":"wait_ms","ms":150}` | 38 | 22 | 3089:1 | 3089:1 | 3062 | 3062+1 | NORMAL | wrap |
| 90 | `{"cmd":"key","key":"}"}` | 38 | 26 | 3097:1 | 3097:1 | 3070 | 3070+1 | NORMAL | wrap |
| 91 | `{"cmd":"wait_ms","ms":150}` | 38 | 26 | 3097:1 | 3097:1 | 3070 | 3070+1 | NORMAL | wrap |
| 92 | `{"cmd":"key","key":"}"}` | 37 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 93 | `{"cmd":"wait_ms","ms":150}` | 37 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 94 | `{"cmd":"key","key":"$"}` | 38 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 95 | `{"cmd":"wait_ms","ms":150}` | 38 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 96 | `{"cmd":"key","key":"0"}` | 37 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 97 | `{"cmd":"wait_ms","ms":150}` | 37 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 98 | `{"cmd":"key","key":"zz"}` | 37 | 18 | 3120:1 | 3120:1 | 3103+1 | 3103+1 | NORMAL | wrap |
| 99 | `{"cmd":"wait_ms","ms":150}` | 37 | 18 | 3120:1 | 3120:1 | 3103+1 | 3103+1 | NORMAL | wrap |
| 100 | `{"cmd":"key","key":"zt"}` | 37 | 11 | 3120:1 | 3120:1 | 3120+1 | 3120 | NORMAL | wrap |
| 101 | `{"cmd":"wait_ms","ms":150}` | 37 | 11 | 3120:1 | 3120:1 | 3120+1 | 3120 | NORMAL | wrap |
| 102 | `{"cmd":"key","key":"zb"}` | 37 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 103 | `{"cmd":"wait_ms","ms":150}` | 37 | 23 | 3120:1 | 3120:1 | 3092 | 3093+1 | NORMAL | scroll offset, wrap |
| 104 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 22 | 3120:1 | 3120:1 | 3093 | 3094+1 | NORMAL | scroll offset, wrap |
| 105 | `{"cmd":"wait_ms","ms":100}` | 37 | 22 | 3120:1 | 3120:1 | 3093 | 3094+1 | NORMAL | scroll offset, wrap |
| 106 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 35 | 3120:1 | 3120:1 | 3094 | 3095+1 | NORMAL | scroll offset, wrap |
| 107 | `{"cmd":"wait_ms","ms":100}` | 37 | 35 | 3120:1 | 3120:1 | 3094 | 3095+1 | NORMAL | scroll offset, wrap |
| 108 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 20 | 3120:1 | 3120:1 | 3095 | 3096+1 | NORMAL | scroll offset, wrap |
| 109 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3120:1 | 3120:1 | 3095 | 3096+1 | NORMAL | scroll offset, wrap |
| 110 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 20 | 3120:1 | 3120:1 | 3096 | 3097 | NORMAL | scroll offset, wrap |
| 111 | `{"cmd":"wait_ms","ms":100}` | 38 | 20 | 3120:1 | 3120:1 | 3096 | 3097 | NORMAL | scroll offset, wrap |
| 112 | `{"cmd":"key","key":"ctrl+e"}` | 38 | 20 | 3120:1 | 3120:1 | 3097 | 3098 | NORMAL | scroll offset, wrap |
| 113 | `{"cmd":"wait_ms","ms":100}` | 38 | 20 | 3120:1 | 3120:1 | 3097 | 3098 | NORMAL | scroll offset, wrap |
| 114 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 20 | 3120:1 | 3120:1 | 3098 | 3099 | NORMAL | scroll offset, wrap |
| 115 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3120:1 | 3120:1 | 3098 | 3099 | NORMAL | scroll offset, wrap |
| 116 | `{"cmd":"key","key":"ctrl+e"}` | 36 | 19 | 3120:1 | 3120:1 | 3099 | 3100+1 | NORMAL | scroll offset, wrap |
| 117 | `{"cmd":"wait_ms","ms":100}` | 36 | 19 | 3120:1 | 3120:1 | 3099 | 3100+1 | NORMAL | scroll offset, wrap |
| 118 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 35 | 3120:1 | 3120:1 | 3100+1 | 3101+1 | NORMAL | scroll offset, wrap |
| 119 | `{"cmd":"wait_ms","ms":100}` | 37 | 35 | 3120:1 | 3120:1 | 3100+1 | 3101+1 | NORMAL | scroll offset, wrap |
| 120 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 35 | 3120:1 | 3120:1 | 3101+1 | 3102+1 | NORMAL | scroll offset, wrap |
| 121 | `{"cmd":"wait_ms","ms":100}` | 37 | 35 | 3120:1 | 3120:1 | 3101+1 | 3102+1 | NORMAL | scroll offset, wrap |
| 122 | `{"cmd":"key","key":"ctrl+e"}` | 37 | 35 | 3120:1 | 3120:1 | 3102+1 | 3103+1 | NORMAL | scroll offset, wrap |
| 123 | `{"cmd":"wait_ms","ms":100}` | 37 | 35 | 3120:1 | 3120:1 | 3102+1 | 3103+1 | NORMAL | scroll offset, wrap |
| 124 | `{"cmd":"key","key":"ctrl+y"}` | 37 | 35 | 3120:1 | 3120:1 | 3101+1 | 3102+1 | NORMAL | scroll offset, wrap |
| 125 | `{"cmd":"wait_ms","ms":100}` | 37 | 35 | 3120:1 | 3120:1 | 3101+1 | 3102+1 | NORMAL | scroll offset, wrap |
| 126 | `{"cmd":"key","key":"ctrl+y"}` | 37 | 35 | 3120:1 | 3120:1 | 3100+1 | 3101+1 | NORMAL | scroll offset, wrap |
| 127 | `{"cmd":"wait_ms","ms":100}` | 37 | 35 | 3120:1 | 3120:1 | 3100+1 | 3101+1 | NORMAL | scroll offset, wrap |
| 128 | `{"cmd":"key","key":"ctrl+y"}` | 36 | 19 | 3120:1 | 3120:1 | 3099 | 3100+1 | NORMAL | scroll offset, wrap |
| 129 | `{"cmd":"wait_ms","ms":100}` | 36 | 19 | 3120:1 | 3120:1 | 3099 | 3100+1 | NORMAL | scroll offset, wrap |
| 130 | `{"cmd":"key","key":"ctrl+y"}` | 38 | 20 | 3120:1 | 3120:1 | 3098 | 3099 | NORMAL | scroll offset, wrap |
| 131 | `{"cmd":"wait_ms","ms":100}` | 38 | 20 | 3120:1 | 3120:1 | 3098 | 3099 | NORMAL | scroll offset, wrap |
| 132 | `{"cmd":"key","key":"ctrl+y"}` | 37 | 20 | 3120:1 | 3120:1 | 3097 | 3098 | NORMAL | scroll offset, wrap |
| 133 | `{"cmd":"wait_ms","ms":100}` | 37 | 20 | 3120:1 | 3120:1 | 3097 | 3098 | NORMAL | scroll offset, wrap |

## Worst three steps by `text` (excerpts)

### step 16 — `{"cmd":"key","key":"ctrl+d"}` — 35 text rows (scroll offset, wrap)

```
row  3 rust:   │  182     while selection.find(|registry| merge(scroll(), line, offset as usize)) {
row  3 zig:    │  179 pub fn draw_registry10<F: Fn(usize) -> bool>(gutter: bool, cursor: impl Iterator<It
row  4 rust: ? │  183     }
row  4 zig:  ? │  184 }                                                                                 █
row  5 rust:   │  184 }
row  5 zig:    │  185                                                                                   █
row  6 rust: ? │  185
row  6 zig:  ? │  186 /// needle: the search harness looks for this word.                               █
row  7 rust:   │  186 /// needle: the search harness looks for this word.
row  7 zig:    │  187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char,    █
row  8 rust:   │  187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char, h
row  8 zig:    │      height: u16) -> String {                                                          █
… 29 more rows
```

### step 17 — `{"cmd":"wait_ms","ms":150}` — 35 text rows (scroll offset, wrap)

```
row  3 rust:   │  182     while selection.find(|registry| merge(scroll(), line, offset as usize)) {
row  3 zig:    │  179 pub fn draw_registry10<F: Fn(usize) -> bool>(gutter: bool, cursor: impl Iterator<It
row  4 rust: ? │  183     }
row  4 zig:  ? │  184 }                                                                                 █
row  5 rust:   │  184 }
row  5 zig:    │  185                                                                                   █
row  6 rust: ? │  185
row  6 zig:  ? │  186 /// needle: the search harness looks for this word.                               █
row  7 rust:   │  186 /// needle: the search harness looks for this word.
row  7 zig:    │  187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char,    █
row  8 rust:   │  187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char, h
row  8 zig:    │      height: u16) -> String {                                                          █
… 29 more rows
```

### step 28 — `{"cmd":"key","key":"n"}` — 35 text rows (scroll offset, wrap)

```
row  3 rust:   │ 2988     viewport = 2994;
row  3 zig:    │ 2983 pub fn advance_style148<T: Clone + 'static>() -> i32 {
row  4 rust: ? │ 2989     debug_assert!(paint(), "\n\t\\ escapes");
row  4 zig:  ? │      self.selection && layout;                                                         █
row  5 rust:   │ 2990     collect(self.style);
row  5 zig:    │ 2988     viewport = 2994;                                                              █
row  6 rust: ? │ 2991     let span: Option<usize> = tokenize(tokenize(registry as usize) / 2189 * Some
row  6 zig:  ? │ 2989     debug_assert!(paint(), "\n\t\\ escapes");                                     █
row  7 rust:   │    ↪ (token_haystack));
row  7 zig:    │ 2990     collect(self.style);                                                          █
row  8 rust:   │ 2992 }
row  8 zig:    │ 2991     let span: Option<usize> = tokenize(tokenize(registry as usize) / 2189 *       █
… 29 more rows
```

