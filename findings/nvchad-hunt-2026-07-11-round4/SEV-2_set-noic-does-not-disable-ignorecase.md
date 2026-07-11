# [SEV-2] `:set noic` toast confirms the change but search stays case-insensitive

## Reproduction

sample.txt contains 10 lines starting with capital `Line`:
```
Line 01 alpha
Line 02 beta
...
```

Set noic then search lowercase:
```jsonl
{"cmd":"type","text":":set noic"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"/line"}
{"cmd":"key","key":"enter"}
```

Statusline: `match 1/10` — all 10 capital `Line` rows matched.

## Expected

After `:set noic`, `/line` (lowercase) should match zero rows because
the file has no lowercase `line`.

## Actual

`:set noic` toast writes `number: off`-style confirmation but the
search path still uses the case-insensitive branch. The 10 uppercase
`Line` hits confirm the switch never propagated.

## Related — `:set smartcase` never engages case-sensitivity either

```jsonl
{"cmd":"type","text":":set smartcase"}
{"cmd":"key","key":"enter"}
{"cmd":"type","text":"/LINE"}
{"cmd":"key","key":"enter"}
```

Statusline: `match 1/10` again — smartcase should have made `/LINE`
(uppercase) case-sensitive (0 matches), but ignored case as if
`ic` were still on.

## Source pointer

- Ex-command `:set noic` handler — grep `noic` in `src/app/ex_commands.rs`
  or wherever `:set` toggles land (`src/app/cmdline_methods.rs` /
  `src/config/` boundary).
- Search implementation — likely `src/find.rs` / `find_all_case_sensitive` /
  `find_all_ci_ascii`. Whichever picks between them is not reading
  the toggled setting.

## Notes

Search & substitute share this issue. Vim users type `:set noic` or
`:set case` all the time to force literal matching for punctuation-
heavy patterns. Also `\C` inline (`/foo\C`) and `\c` for per-search
override — worth testing after the config wire is fixed.
