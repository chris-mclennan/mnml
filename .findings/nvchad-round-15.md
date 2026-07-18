# nvchad-round-15 — vim-mode hunt, 2026-07-15

## Executive summary

Ran a ~50-minute headless vim-mode session against a freshly-rebuilt
`~/Projects/mnml/target/release/mnml --input vim` (rebuild required — the
existing binary was 17 minutes older than the round-14 fix commit
`2398eebf polish(vim): 3× nvchad-round-14 SEV-2 — d3G count · Ctrl+B PageUp
· count-op undo group`, so the first pass reported false negatives — same
"verify findings via headless" footgun that has bit every round).

**Round-14 priority verification results (post-rebuild)**:

- `d3G` from line 1 in a 10-line buffer → 7 lines remain (deleted 1..3). **Ships.**
- `y5G` + `G` + `p` → pastes 5 lines. **Ships.**
- `d3gg` from line 8 → **DOES NOT SHIP** — deletes 8 lines (1..8), same
  as bare `dgg`; count silently dropped. (New SEV-2 below.)
- `y3gg` — same drop. Yanks all lines from cursor to line 1, ignores N.
- Ctrl+B in Normal → **DOES NOT SHIP** — still toggles the tree sidebar.
  The vim.rs Normal-mode branch is dead code because
  `dispatch_chord_chain` resolves Ctrl+B against the global keymap
  (`view.toggle_tree`) and consumes it before the input handler runs.
  (SEV-2 F2 below.)
- `3dd` + `u` → 1 press restores 3 lines. **Ships.**
- `5x` + `u` → 1 press restores 5 chars. **Ships.**
- `3J` + `u` → 1 press. **Ships.**
- `3oNEW<esc>` + `u` → **NEEDS 3 presses** — atomic-undo wrapper covers
  the `o` ops but not the trailing Insert-mode typing on each repeat.
  Task spec said this should be 1 press. (SEV-3 F3.)
- Motion-only `3w` / `5j` no spurious undo entry. **Ships.**

**Fresh hunt on top of the round-14 verifications**:

- `.` after `3dd` correctly re-executes `3dd` (deletes 3 more lines). Ships.
- Macro `qa 3dd q` then `@a` correctly replays `3dd`; `u` after replay
  restores all 3 in ONE press — macro plays as an atomic-undo unit. Ships.
- `c3G` — count silently dropped: from line 5 in 100-line buffer,
  `c3G` deleted 96 lines (behaved as `cG`), left 5 lines + Insert.
  Doesn't crash but no-op-with-count is worse than a crash for muscle
  memory. (SEV-2 F4 below.)
- `c3gg` — c operator silently dropped: no change happens, only
  cursor moves to line 1 (like bare `gg`). SEV-2 F5 below.
- `Ctrl+B` in Insert / Visual / Cmdline modes — all fall through to
  the global keymap and toggle the tree, as the round-14 commit
  described. Note in cmdline mode this breaks vim's canonical
  Ctrl+B = go-to-BOL. (SEV-3 F6.)

**Still broken since round-12 / 13 / 14** (re-verified this round):

- SEV-2: `dd` / `yy` / `cc` on a closed fold operates only on the
  header line, not the fold body.
- SEV-2: `:sp <file>` / `:new` create an extra duplicate pane in the
  new split (`:sp big.txt` → 4 panes, `:new` → +2 panes).
- SEV-2: Visual-block insert (`Ctrl+v jj I XXX <esc>`) + `u` requires
  two undos; first `u` reverts rows 2 & 3, second reverts row 1.
- SEV-3: `Ctrl+[` from Insert mode doesn't escape to Normal.

**Not broken (verified this round)**:

- `%` bracket jump (line-1 col-11 `{` → line-7 col-1 `}`).
- `Ctrl+o` / `Ctrl+i` jumplist back/forward.
- `:%s/pattern/replacement/g` with regex (`\d\+`).
- `:%s/foo/bar/gc` confirmation flow (`y` / `n` step through).
- `/search` + `n` + `:noh`.

**Verdict** — round-14's `d<n>G` count fix ships correctly, but the
sibling `d<n>gg` / `y<n>gg` / `c<n>G` / `c<n>gg` cases were missed. The
Ctrl+B → PageUp change is a code-added-but-unshipped situation — the
vim.rs branch is unreachable because the global keymap wins first. The
count-op atomic-undo group works for pure-buffer ops but not for the
`<count>o<text><esc>` case where each repeat spawns an Insert-mode
session that isn't wrapped in the group.

**Count by severity**: **SEV-1: 0 · SEV-2: 5 fresh + 3 carried · SEV-3:
3 fresh + 1 carried** = 12 findings.

---

## [SEV-2] F1 — `d<n>gg` / `y<n>gg` silently drop the count (deletes/yanks to line 1)

Round-14's fix landed for `d<n>G` (via the `KeyCode::Char('G')` arm at
`src/input/vim.rs:2272-2294`, which reads the pre-reset `n`), but the
sibling `<op><n>gg` path was missed. It goes through a different code
route: the op-pending `g` handler at :2250-2253 sets `self.op = Some(op);
self.prefix = Prefix::G;` — but `self.reset_pending()` at :2120 already
ran, so `self.count` is `None` by the time the second `g` hits the
`Prefix::G` handler at :1134. Result: `count_was_explicit` at :1136
resolves to `false`, and the LinewiseTo arm at :1164 picks
`target = Some(0)` (buffer start) instead of `Some(n)`.

**Reproduction** (10-line `ten.txt`, `line01..line10`, cursor on line 8):
```jsonc
{"cmd":"open","path":"ten.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"8 G"}
{"cmd":"key","key":"d 3 g g"}
{"cmd":"snapshot"}
```

**Expected** (vim): delete lines 3..8 = 6 lines. Leaves 4 lines
(`line01`, `line02`, `line09`, `line10`).
**Actual**: deletes lines 1..8 = 8 lines. Leaves 2 lines (`line09`,
`line10`).

Same pattern for `y3gg` from line 5 in a 100-line buffer: yanks 5 lines
(1..5) instead of 3 (3..5), so `G p` produces 105 lines instead of 103.

**Source pointer**: `src/input/vim.rs:2250-2253` (op-pending g-prefix
enter — needs to stash `n` alongside `op` before `reset_pending`
clobbers it), and the fetch site at `src/input/vim.rs:1134-1170` (needs
to consult the stashed n instead of `self.count`).

**Notes**: Suggested fix mirrors the round-14 F1 approach — after the
:2250 arm, capture the count into a new `PendingOp`-adjacent field
(e.g. `self.pending_op_count: Option<u32>`) so the second-`g` handler
can read it after the reset clears `self.count`. Or: don't call
`reset_pending` until AFTER the op+g transition decides not to enter
Prefix::G. The G-arm handles it correctly because it doesn't need a
second key press — the count is still in the captured `n` local from
:2119. gg needs two key presses, so state has to survive the
intervening reset.

---

## [SEV-2] F2 — Ctrl+B in vim Normal mode still toggles the tree (round-14 F2 fix unshipped)

The vim.rs `KeyCode::Char('b') if ctrl` arm at :2839 exists and would
emit `PageUp`, but it never runs. `dispatch_key` in `src/tui/mod.rs`
calls `dispatch_chord_chain` at :2129 BEFORE handing off to
`handle_pane_key`. The chord chain sees Ctrl+B, resolves it against the
global keymap (`view.toggle_tree`, `src/command.rs:255`), fires the
command, returns `true`, and `dispatch_key` returns without reaching the
input handler.

**Reproduction** (fresh workspace, cursor at line 100 in a 100-line file,
tree visible):
```jsonc
{"cmd":"open","path":"big.txt"}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"G"}
{"cmd":"key","key":"ctrl+b"}
{"cmd":"snapshot"}
```

**Expected**: cursor moves up ~one screen (vim's canonical PageUp).
**Actual**: `treeVisible` toggles from `true` → `false`, cursor
unchanged at line 100. The vim handler never sees the key.

**Source pointer**: The unreachable code is at `src/input/vim.rs:2839-2842`.
Fix requires either: (a) a Normal-mode Ctrl+B intercept in `dispatch_key`
above `dispatch_chord_chain` (similar to the existing Ctrl+; and Ctrl+]
carve-outs at :2043 / :2061); or (b) teaching `dispatch_chord_chain` /
the keymap to skip commands the active input handler wants to own —
which is the deeper "input handler should be able to shadow keymap"
question. NvChad users hit this in the first minute.

**Notes**: Commit message for `2398eebf` claims "Now vim-owned in Normal
mode; sidebar toggle still works from standard mode + from Insert/Visual/
Cmdline". Insert/Visual/Cmdline is still-toggles-tree confirmed; but so
is Normal — the fix simply doesn't fire.

---

## [SEV-2] F3 — `c<n>G` silently drops the count (deletes to buffer end, enters Insert)

Same class as F1 but the C-operator path is even more misbehaved
because the round-14 F1 fix only special-cased Delete/Yank (:2273
gates on `matches!(op, PendingOp::Delete | PendingOp::Yank)` — Change
was explicitly deferred per the comment at :2311-2316). So `c<n>G`
falls through to the generic G motion path with count already reset,
and the App layer receives `target = None` — which resolves to
`line_count.saturating_sub(1)` (buffer end) in
`vim_operator_linewise_to`.

**Reproduction** (100-line `big.txt`, cursor at line 5):
```jsonc
{"cmd":"open","path":"big.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"5 G"}
{"cmd":"key","key":"c 3 G"}
{"cmd":"snapshot"}
```

**Expected** (vim): delete lines 3..5 = 3 lines, enter Insert on the
new line 3. 97 lines remain.
**Actual**: deletes lines 5..100 = 96 lines (behaves as `cG`),
enters Insert, 5 lines remain.

**Source pointer**: `src/input/vim.rs:2272-2294` (only handles
Delete/Yank); `src/app/mod.rs:10310-10316` (Change arm is `_ => {}`).

**Notes**: The App-layer note at :10311-10315 says "`c` (change-to-G)
needs an insert-mode transition; the App layer doesn't own the vim
handler's mode. Left unsupported for now". That's fine as a decision,
but the current fallthrough is worse-than-unsupported — it silently
runs the delete portion of change and then leaves the user in Insert
mode with an unintended amount deleted. Better to no-op (toast "c<n>G
not yet supported") than to run a destructive silent variant.

---

## [SEV-2] F4 — `c<n>gg` silently drops the c operator entirely (behaves as `gg`)

Same code path as F1 but with the c-doesn't-match-Delete/Yank gate at
`src/input/vim.rs:1157` — the Prefix::G handler only routes to
LinewiseTo for d/y. For c, it falls through to :1170's plain
`MoveBufferStart` / `MoveToLine`, so no change happens.

**Reproduction** (100-line `big.txt`, cursor at line 5):
```jsonc
{"cmd":"key","key":"5 G"}
{"cmd":"key","key":"c 3 g g"}
{"cmd":"snapshot"}
```

**Expected** (vim): delete lines 3..5 = 3 lines, enter Insert on new
line 3.
**Actual**: no lines deleted, cursor moves to line 1, mode stays
NORMAL. The `c` was silently dropped; `c3gg` = `gg`.

**Source pointer**: `src/input/vim.rs:1156-1174`. The `if let Some(op)
= pending_op && matches!(op, Delete | Yank)` at :1156-1158 gates out
Change and the fallthrough discards the operator without a toast or
op-pending recovery.

**Notes**: Should either route Change through the linewise path (paired
with an insert-mode transition on the App side, same as `cc`) or toast
"`c<n>gg` not yet supported" and stay in Normal.

---

## [SEV-2] F5 — `:sp <file>` and `:new` create an extra duplicate pane in the new split

Carried over from round-14 (which classified this as SEV-2) — the
behavior is unchanged.

**Reproduction** (starting with `ten.txt` and `fold.rs` open, focus on
ten.txt):
```jsonc
{"cmd":"key","key":":"}
{"cmd":"type","text":"sp big.txt\n"}
```

**Expected** (vim): horizontal split; top window shows ten.txt, bottom
window shows big.txt. Pane count +1.
**Actual**: 4 panes total — original ten.txt + fold.rs on top, plus a
DUPLICATE ten.txt + big.txt as tabs in the bottom split. Pane count +2.

Same pattern for `:new` (which should create one empty scratch pane):
adds a duplicate of the current buffer + a `[scratch]` pane = +2.

**Source pointer**: `src/app/ex_commands.rs` sp/vsp/new implementation.
Presumed root cause: `sp <file>` = `sp` (duplicates current) + `e <file>`
(opens file in new leaf), and the "duplicate current" step is what
adds the extra pane.

**Notes**: This is user-visible clutter in `:ls` / `:bn` cycles — the
duplicate ten.txt shows up as a background tab in the new split.

---

## [SEV-3] F6 — `3o<text><esc>` needs one undo per repeat, not one for the whole group

Round-14 F3 fixed `3dd` / `5x` / `3J` (all pure-buffer ops) to coalesce
into a single undo entry via `Repeat`'s atomic-undo wrapper. But
`3oNEW<esc>` — where each `o` repeat opens a line AND then re-runs the
Insert-mode typing captured during the first repeat — has 3 separate
undo entries per the checkpoint the InsertSessionEnd emits. Task spec
listed this as one of the priority F3 verifications ("3oNEW<esc> + u =
one press").

**Reproduction** (10-line `ten.txt`, cursor on line 1):
```jsonc
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"3 o"}
{"cmd":"type","text":"NEW"}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"u"}
{"cmd":"snapshot"}
```

**Expected** (vim + task spec): one `u` press restores the file to 10
lines.
**Actual**: after one `u`, the file has 11 lines (2 NEW rows remain);
needs 3 total `u` presses.

**Source pointer**: `src/edit_op.rs` — the `Repeat` variant's atomic
wrapper doesn't extend to nested Insert-mode sessions triggered by `o`.

---

## [SEV-3] F7 — `Ctrl+B` in ex-cmdline should move cursor to BOL, not toggle tree

Vim's canonical `:` cmdline binds `Ctrl+B` to "move cursor to beginning
of line" (`:help cmdline-editing`). mnml's cmdline lets Ctrl+B fall
through to the global keymap and toggles the tree.

**Reproduction**:
```jsonc
{"cmd":"key","key":":"}
{"cmd":"type","text":"help"}
{"cmd":"key","key":"ctrl+b"}
{"cmd":"snapshot"}
```

**Expected**: cursor moves to before the `h` of "help" in the cmdline
buffer.
**Actual**: tree visibility toggles; cmdline cursor unchanged.

**Source pointer**: same as F2 — Cmdline mode falls through
`dispatch_chord_chain` for Ctrl+B.

---

## [SEV-3] F8 — cursor position "Ln 8/7 Col 1" after `:%s`

Minor polish: after a substitute that shrinks the buffer, the
statusline reports cursor at "Ln N/M" where N > M (off-end). Vim clamps
cursor to the last line automatically.

Not blocking; noted for the polish pile.

**Source pointer**: statusline render around `Ln %d/%d Col %d` — needs
`min(cursor.line, line_count)` when displaying.

---

## Carried-over rollovers (re-verified as still-broken)

### [SEV-2] `dd` / `yy` / `cc` on closed fold only operates on header line

Same as rounds 11-14. Standing:

**Reproduction** (fold.rs with `fn medium()` folded via `zc` on line 5):
```jsonc
{"cmd":"key","key":"d d"}
```

**Expected**: entire fold (lines 5-9 including body) deleted as one op.
**Actual**: only line 5 (`fn medium() {`) deleted; body remains.

### [SEV-2] Visual-block insert + `u` needs two undos

Same as round-12/13/14. `Ctrl+v jj I XXX <esc>` on 3 rows + `u`:
first `u` reverts rows 2 & 3 (XXX removed), second `u` reverts row 1.
Two presses to fully undo one visual operation.

### [SEV-3] `Ctrl+[` from Insert mode doesn't escape to Normal

Same as round-14. Mode stays INSERT after Ctrl+[.
