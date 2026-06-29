---
agent: nvchad-user
severity: SEV-2
---

## SEV-2 `de` / `ye` / `ce` / `cw` are off-by-one — operator excludes the last char of the word

**Reproduction**:
```
{"cmd":"open","path":"sample.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"w"}                // → col 5 (q of "quick")
{"cmd":"key","key":"w"}                // → col 11 (b of "brown")
{"cmd":"key","key":"y"}
{"cmd":"key","key":"e"}                // yank to end of "brown"
{"cmd":"type","text":":reg \"\n"}
// Toast shows: ""  brow      ← only 4 chars; should be "brown" (5)
```

Direct `e` motion from same position lands the cursor at col 15 ('n' of brown) — that's correct. The bug is in how the operator combines with the motion:

```
{"cmd":"key","key":"e"}                // bare motion: cursor 11 → 15 ✓
```

But `de`, `ce`, `ye`, `cw` (which is `ce` semantics in vim) all stop ONE char early:

```
gg w w c w SLOW <Esc>     →  "The quick BIGfox jumps..."   // mnml; "BIG" inserted but the trailing space + 'n' are gone — wait, that's a different drift. Let me re-anchor:

gg w w c e BIG <Esc>      →  "The quick BIGn fox..."       // mnml — should be "The quick BIG fox..."
gg w w d e               →  "The quick n fox..."          // mnml — should be "The quick  fox..." (with double space, 'brown' gone)
gg w w y e               →  unnamed register has "brow"   // mnml — should be "brown"
```

The `n` is always left behind. Confirmed by `:reg "` showing "brow" after `ye`.

**Expected**: vim canonical — `e` motion is INCLUSIVE for operators. From start of word, `de` / `ce` / `ye` operate on the whole word including its last character. (Vim's `:help inclusive`: "Operators which act on a forward motion of one of these inclusive motions act ON the character of the motion's destination.") `cw` is documented as equivalent to `ce` (`:help cw`).

**Actual**: Mnml treats the motion as EXCLUSIVE — the operator stops one char short. Tested on multiple words; consistent.

**Source pointer**: somewhere in `src/input/vim.rs` operator-pending dispatch or the `EditOp::DeleteForward`/`MoveEndWord` interaction. Search for how `e` motion is combined with `d`/`c`/`y` — likely a missing `+1` (or the equivalent inclusive flag).

**Notes**: This is the kind of subtle vim violation that makes the editor feel "not quite right" for muscle memory. `dw` (which uses `w`, exclusive in vim, so the trailing space IS included) and `D`/`C` (the line-end shortcuts) work correctly. The bug is specific to operator + word-end motions. See the sibling finding for `d$`/`c$`/`y$` which has a related symptom — those keep the LAST char of the line; same off-by-one in the other operator-motion pairing.
