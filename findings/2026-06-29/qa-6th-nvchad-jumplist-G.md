---
agent: nvchad-user
severity: SEV-3
---

# `Ctrl-o` doesn't unwind in-buffer jumps (G / gg / `'a`)

## Reproduction
```jsonl
{"cmd":"open","path":"main.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"m"}
{"cmd":"key","key":"a"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"ctrl+o"}
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}
```

## Expected
After `gg` → `G` (cursor lands at line 5), `Ctrl+o` returns the cursor to line 1 — the position before `G`. This is standard vim jump-history behavior. `Ctrl+i` would then go forward again.

## Actual
`status.json` reports `cursor.line = 5` both before and after `Ctrl+o` — cursor doesn't move. (Cross-buffer history is wired: opening file A → file B → `Ctrl+o` returns to A. The miss is the in-buffer jump-list — `G`, `gg`, `/`, `?`, `n`, `N`, `*`, `#` don't register as jumps.)

`'a` (jump to mark) does work, so the position-restore primitive exists; only the jump-list population is incomplete.

## Source pointer
Search for jumplist push sites — likely a missing call before `G` / `gg` execute in `src/input/vim/`.

## Notes
A NvChad user hits this constantly: `gg` to top, scan-read, `Ctrl+o` to "where was I" — staying parked at line 1 is jarring. Low-severity (workaround: `''` for last position) but feels distinctly un-vim.
