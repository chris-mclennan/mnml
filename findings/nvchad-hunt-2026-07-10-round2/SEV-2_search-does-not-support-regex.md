# [SEV-2] `/pattern` and `?pattern` use literal-string matching — no regex

## Reproduction

hello.txt:
```
line 1
line 2
line 3
```

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"/^line \\d+"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

Bottom of screen: `no matches for "^line \\d+"`.

## Expected

Vim: `/^line \d+` (or classic vim `\v^line \d+`) matches every line
that starts with `line ` followed by a digit run — all three lines here.
Cursor jumps to first match.

## Actual

Literal-string match — `^`, `\d`, `+` are treated as literals. Cursor
stays put. Companion to the `:s` regex gap (separate finding
`SEV-2_substitute-does-not-support-regex.md`).

## Source pointer

Unknown exact call path, but the "no matches for X" toast preserves the
raw pattern verbatim (backslashes included) which is the tell — a regex
implementation would either error on the pattern (`invalid regex`) or
succeed at compiling and then run.

Search internally likely reuses the same `find_all_case_sensitive` /
`find_all_ci_ascii` helper from `src/buffer.rs` that `:s` uses.

## Notes

Interacts with the `:s` gap — a vim user who fails to `/foo\|bar` and
then tries to `:s/foo\|bar/qux/g` runs into the SAME miss twice. The
fix should update both search and substitute in one pass — same helper.

Casts a wide net: `*`/`#` (word-under-cursor search) already work because
they generate literal find strings; but the moment a user types `/`
with any regex, the search is silently useless.
