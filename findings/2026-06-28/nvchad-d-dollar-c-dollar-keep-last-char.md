---
agent: nvchad-user
severity: SEV-2
---

## SEV-2 `d$` / `c$` / `y$` leave the last character of the line behind; `D` / `C` work correctly

**Reproduction**:
```
{"cmd":"open","path":"sample.txt"}     // line 1: "The quick brown fox jumps over the lazy dog."
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"w"}
{"cmd":"key","key":"w"}                // cursor on 'b' of "brown" (col 11)
{"cmd":"key","key":"d"}
{"cmd":"key","key":"$"}
{"cmd":"snapshot"}
// Result: "The quick ."   ← period at end is preserved (off-by-one)
// Expected: "The quick"   ← whole rest of line gone, including trailing period
```

`c$ REST` → `"The quick REST."`  (period preserved) — wrong.
`C REST`  → `"The quick REST"`   (period gone) — correct.

Same pattern: `D` works, `d$` is broken; `C` works, `c$` is broken. (Verified `y$` keeps the trailing period in the yank too — `:reg "` shows the truncation.)

**Expected**: vim canonical — `d$` is documented as equivalent to `D` (`:help d$`, `:help D`). Both delete from cursor to end-of-line INCLUDING the last character. `c$` ≡ `C`. `y$` yanks from cursor to end of line inclusive.

**Actual**: The single-char shortcuts (`D`, `C`, `Y`) take a different code path that's correct; the explicit `d$` / `c$` / `y$` motion-based path drops the last char.

**Source pointer**: `src/input/vim.rs` — the `$` motion handling combined with an operator. Likely the same root cause as the sibling finding on `de`/`ce`/`ye` being off-by-one (one bug producing two surfaces). Compare the codepath for `KeyCode::Char('D')` (works) vs `Prefix::Operator + KeyCode::Char('$')` (broken).

**Notes**: Discovered while exercising operator + motion combinations as a vim user would (`d$` is reflexively typed for "clear to end-of-line"; only some users default to `D`). Combined with the `e`-motion off-by-one in the sibling finding, mnml has at least TWO operator + motion combos that don't match vim. Worth a one-shot audit: enumerate every operator × motion pair, fixture-test each.
