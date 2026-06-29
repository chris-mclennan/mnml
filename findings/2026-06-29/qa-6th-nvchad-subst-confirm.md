---
agent: nvchad-user
severity: SEV-2
---

# `:%s/foo/bar/gc` silently no-ops — no confirm UI, no substitutions

## Reproduction
```jsonl
{"cmd":"open","path":"main.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"%s/line/X/gc\n"}
{"cmd":"wait_ms","ms":250}
{"cmd":"snapshot"}
```

File `main.txt` contents (5 lines, each begins `line`):
```
line one
line two
line three
line four
line five
```

## Expected
mnml prompts `replace with X? (y/n/a/q/l)` per match — or, failing that, falls back to `/g` behavior (apply all). Either is acceptable; silently dropping the command is not.

## Actual
- No confirm prompt anywhere on screen.
- Buffer unchanged.
- `mode` stays NORMAL.
- Status bar shows no error message.

Sanity check: `:%s/line/LINE/g` on the same buffer DOES work — all 5 occurrences are replaced. The `/c` flag specifically is silently dropped.

## Source pointer
Likely `src/app/cmdline_methods.rs` `:%s` handler — needs a grep for the substitute parse to confirm the `/c` flag is recognized.

## Notes
This is one of the most-used vim flows ("preview each change"). A user testing a non-trivial regex will hit this immediately. Either implement the prompt or, at minimum, toast `:%s/.../c not supported — use /g for now` so the user knows to drop the flag.
