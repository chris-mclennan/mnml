# [SEV-2] `:{range}s/…/…/` with anything other than `%` fails — "unknown command"

## Reproduction

sample.txt (13 lines):
```
Line 01 alpha
Line 02 beta
...
foo qux
```

```jsonl
{"cmd":"type","text":":e! sample.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"3"}
{"cmd":"key","key":"j"}
{"cmd":"type","text":":.,+3s/Line/LN/"}
{"cmd":"key","key":"enter"}
```

Toast: `:.,+3s/Line/LN/ — unknown command`

Also fails: `:5,10s/Line/LN/`, `:.,$s/foo/BAR/`, `:'a,'bs/x/y/`. Only
`:%s/…/…/` (whole-buffer with `%`) is understood.

## Expected

Vim treats `:5,10s/foo/bar/g`, `:.,+3s/…/…/`, `:'a,'bs/…/…/`,
`:.,$s/…/…/` all as ranged substitutes running the substitution only
inside the range. This is a bread-and-butter vim idiom for scoped
find-and-replace.

## Actual

`parse_line_range` in `src/app/cmdline_methods.rs:216` correctly
returns `(start, end, "s/Line/LN/")` for `.,+3s/…/…/`, but the
dispatcher in `src/app/ex_commands.rs:508-530` only whitelists
`d/y/j/>/<` as post-range commands. Anything else falls through and
the raw line hits the "unknown command" arm at `ex_commands.rs:2523`
because `parse_substitute` only strips `%s/` and `s/` prefixes (it
sees `.,+3s/…` and returns `None`).

## Source pointer

- `src/app/ex_commands.rs:508-530` — the post-range command match
  (missing `s`/`substitute` arm).
- `src/app/cmdline_methods.rs:291-336` — `parse_substitute` only
  handles `%s/` and bare `s/`.

## Notes

Fix shape: add `s | substitute | su` to the range dispatcher, calling
`parse_substitute` on the remainder with a bounded row window
(`[start..=end]`) instead of `[0..line_count)`. Also route
`:{range}g/…/cmd` and `:{range}!<shell>` through here if you want
full compat.
