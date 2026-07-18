# nvchad-round-14 — vim-mode hunt, 2026-07-14

## Executive summary

Ran a ~60-minute headless vim-mode session against the freshly-rebuilt
`~/Projects/mnml/target/release/mnml --input vim`. **Rebuild note**: the
initial binary at `target/release/mnml` was 8min older than the round-13
fix commit `55c737c4 polish(vim): 3× nvchad-round-13 SEV-2 — S · <count>yy
· dG/dgg`. First-pass tests reported all three round-13 findings still
live; after `cargo build --release` (2m 51s) and re-verification, all
three shipped correctly for the `<motion>` case they were tested against.

Same footgun as round-13 rebuild — memory item "verify findings via
headless" applies: **check the binary mtime against the newest
polish(vim) commit before drawing conclusions.**

**Priority verifications, post-rebuild** — all three round-13 fixes
ship for the direct case, but a **count-on-G/gg** gap remains:

- `S` from mid-line now clears the entire line before entering Insert.
  `Sfoo<esc>` on `line3` at col 3 → line3 = `foo` (was `linfoo` prior).
- `2yy` yanks 2 lines linewise; `G p` pastes both. Round-13 F2 ✓.
- `dG` from line 3 of a 10-line buffer leaves 2 lines (linewise, top-2).
  Round-13 F3 primary case ✓.
- `dgg` from line 8 of a 10-line buffer leaves 2 lines (linewise). ✓ (the
  round-13 priority note "leaves 3 lines" appears to be a typo — vim
  behavior would also leave 2 for `dgg` from line 8 in a 10-line file).
- **BUT** `d3G` / `y3G` / `d3gg` / `y3gg` — the **count** variant — ignores
  the count and behaves as `dG` / `yG` / `dgg` / `ygg`. So `y3G` from
  line 1 in a 5-line file yanks ALL 5 lines (should yank 3). Same for
  `d3G` — deletes the entire buffer. This is the fresh SEV-2 below.

**Verdict** — the round-13 shipped fixes hold for the direct cases they
targeted, `guu` (round-13 SEV-3) is now working, but the count-on-G/gg
gap is the next linewise op-motion mistake. Beyond that, `Ctrl+b` is
still trapped as a sidebar toggle (not page-up), and the whole class of
`<count><op>` doesn't produce a single undo group.

**Count by severity**: **SEV-1: 0 · SEV-2: 4 fresh + 5 carried · SEV-3:
2 fresh + 4 carried** = 15 findings.

**Verified fixed since round-13** (all shipped by 55c737c4):

- `S` = `cc` (clears full line before Insert).
- `<count>yy` / `<count>Y` yanks N lines linewise.
- `dG` / `dgg` (direct-form, no count) linewise.
- `guu` (round-13 SEV-3 F4) — `guu` on `ALPHA BETA` now yields `alpha
  beta`. Round-13 said no-op; this round it works. Not sure which
  commit shipped it — grep points to vim.rs:2160 `SelectLine +
  MoveLineEnd + TransformSelectionCase(Lower)` which was already in
  place from an earlier fix. Marking as verified-shipped.

**Still broken since round-12 / 13** (re-verified this round):

- SEV-2: `dd` / `yy` / `cc` / `>>` / `<<` on a closed fold only operate
  on the header line, not the fold body.
- SEV-2: `:sp <file>` / `Ctrl+w n` still produces 3 panes.
- SEV-2: Visual-line `V ~` / `V U` / `V u` / `V gU` / `V gu` / `V g~` no-op.
- SEV-2: Visual-block edit + `u` requires two undos (only reverts rows
  2..N; row 1 needs a second `u`).
- SEV-3: `Ctrl+[` doesn't fire Escape from Insert.
- SEV-3: Visual `r<char>` no-op (only block-visual works).
- SEV-3: `:ab` abbreviation eats trigger whitespace (`:ab teh the` →
  typing `teh dog` produces `thedog`).
- SEV-3: `Ctrl+g` doesn't toast file info as vim canonically does (it
  binds via `editor.file_info` but appears to fall through to the `g`
  prefix popup in interactive tests — flaky under my repro, marking as
  needs-second-look).

**Note on `:sp <file>`** — since round-13, I re-classified as SEV-2 (not
SEV-3) because it clutters `:bn` / `:bp` cycles + `:ls` output with
phantom duplicates. Each `:sp file` on 16-buffer test session produced
the same 3-pane pattern.

---

## [SEV-2] `d<count>G` / `y<count>G` / `d<count>gg` / `y<count>gg` ignore the count — always delete/yank through buffer edge

**Reproduction** (workspace with `aaa\nbbb\nccc\nddd\neee\n`):

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"y3G"}
{"cmd":"type","text":"G"}
{"cmd":"type","text":"p"}
{"cmd":"snapshot"}
```

Buffer after: 10 lines (`aaa..eee` + `aaa..eee`). The yank captured 5
lines, not 3. `d3G` from the same start position produces a 0-byte
buffer. `d3gg` and `y3gg` (from any row above line 3) do the same to
top.

**Verify** `3G` alone (without operator) correctly moves to line 3:

```jsonl
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"3G"}
{"cmd":"snapshot"}
```

Cursor position after `3G` = `{"line":3,"col":1}` ✓.

But under an operator, the count is dropped and `G` acts as
`MoveBufferEnd` (`gg` as `MoveBufferStart`), so the delete/yank range
extends all the way to the edge.

**Expected**: vim `y3G` from line 1 = yank lines 1..3 linewise (3 lines).
`d3G` from line 1 = delete lines 1..3 (leaves lines 4, 5). Symmetric for
`d3gg` / `y3gg`.

**Actual**: count is ignored. `y3G` yanks 5 lines (whole file from line
1), `d3G` deletes 5 lines. Same for `gg` direction.

**Source pointer**: `src/input/vim.rs` — the doubled-op linewise arm
handles `dd`/`yy` correctly, and the round-13 fix at
`src/input/vim.rs:2126-2133` (see `git show 55c737c4`) added linewise
capture for `dG`/`dgg` motion. Missing piece: when count `N` is present
on the motion side of `d<N>G` / `y<N>G`, the parser hands the whole
`3G` motion to `MoveBufferEnd` without honoring N. Fix likely in the
operator+motion arm that resolves `G` — needs to compute `line = N` and
route to a bounded linewise delete/yank up to that line.

**Notes**: `d3G` / `y3G` are the natural "delete/yank the next 3 lines
including the current one to line 3" gesture. Round-13's Priority
description literally called out `y3G` from line 1 yanks lines 1–3
linewise (p pastes them as new lines below) — this round shows the
count variant still miscounts. Confirmed count-motion works elsewhere:
`y2j` correctly yanks 3 lines (current + 2 down); `yj` yanks 2 lines.
Only `<count>G` / `<count>gg` under an operator drops the count.

---

## [SEV-2] `Ctrl+b` doesn't page-up in vim mode — bound globally to `view.toggle_tree`

**Reproduction** (fresh workspace with a 50-line file):

```jsonl
{"cmd":"open","path":"long.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"G"}
{"cmd":"key","key":"ctrl+b"}
{"cmd":"snapshot"}
```

Cursor after `Ctrl+b` = `{"line":50,"col":1}` (unchanged). `Ctrl+f`
(page-down) from line 1 correctly jumps to line 18 (page). `Ctrl+d`
(half-down) and `Ctrl+u` (half-up) also work. Only `Ctrl+b` is a no-op
for cursor motion.

**Expected**: canonical vim page-up = `Ctrl+B`. From line 50 in a 17-row
viewport it should move cursor to line ~34, mirroring `Ctrl+F`.

**Actual**: `Ctrl+b` is intercepted by the global keymap and routed to
`view.toggle_tree` (sidebar toggle). The tree flickers or stays hidden
(depending on state); cursor doesn't move.

**Source pointer**: `src/input/vim.rs:2807-2817` has an explicit comment:

```rust
// vim full-page scroll: Ctrl+F (forward) / Ctrl+B (back).
// nvchad-round-10 SEV-2 follow-up 2026-07-12 — Ctrl+F is
// now vim-owned in Normal mode (was falling to find.find);
// this restores the canonical page-down. Ctrl+B stays
// bound globally (sidebar) so page-up via Ctrl+B skips
// this arm — use the PageUp key or `Ctrl+U` (half-page)
// in vim mode.
KeyCode::Char('f') if ctrl => { … PageDown }
```

The `Char('b')` arm is deliberately absent. Global binding is at
`src/command.rs:255` (`keys: &["ctrl+b"], id: "view.toggle_tree"`).

**Notes**: this is a documented design choice — the comment says "use
PageUp or Ctrl+U". But **every serious vim user's finger memory has
Ctrl-B for page-up since 1976 vi**. Ctrl-U is HALF-page (different
semantic), and PageUp isn't a chord — it's a dedicated key many
keyboards don't surface. For an NvChad-style editor that prides itself
on vim-mode fidelity, this is a real footgun. Recommendation: in vim
mode, hoist `Ctrl+B` to the vim handler as `PageUp` (motion), and route
tree-toggle to `<leader>e` (which is already the NvChad convention).
`Ctrl+B` on the sidebar is a VSCode reflex — not a vim one.

---

## [SEV-2] `<count><op>` doesn't group into one undo unit — `u` reverts one repetition at a time

**Reproduction A** — `3dd` needs 3 undos:

```jsonl
{"cmd":"open","path":"a.txt"}   // 5-line buffer: a b c d e
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"3dd"}     // buffer → d e (2 lines)
{"cmd":"type","text":"u"}       // buffer → c d e (3 lines) — restored only 1 line
```

Two more `u` presses needed to fully restore the 5-line buffer.

**Reproduction B** — `3J` needs 2 undos:

```jsonl
// 4-line buffer aaa bbb ccc ddd
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"3J"}      // buffer → "aaa bbb ccc" + "ddd" (2 lines)
{"cmd":"type","text":"u"}       // buffer → "aaa bbb" + "ccc" + "ddd" (3 lines)
{"cmd":"type","text":"u"}       // buffer → 4 lines (full revert)
```

**Reproduction C** — `5x` needs 5 undos (`abcdefghij` → `fghij` via
`5x`; each `u` restores one char). `3o NEW <esc>` also produces 3 lines
that need 3 undos to fully remove.

**Expected**: vim treats a count+op as ONE atomic undo unit. `3dd` = 1
undo. `3J` = 1 undo. `5x` = 1 undo. `3oNEW<esc>` = 1 undo.

**Actual**: mnml treats each iteration as a separate undo entry. `<n><op>`
requires `<n>` undos.

**Source pointer**: `src/input/vim.rs:2126` — `PendingOp::Delete =>
InputResult::Ops(Self::repeated(DeleteLine, n))`. `Self::repeated` at
vim.rs:? probably clones the op N times and pushes each into `ops`
independently. The editor's `apply` loop treats each op as a distinct
undo snapshot. Grouping fix: wrap the multi-op vector in an
`UndoGroupBegin` / `UndoGroupEnd` pair, or extend `DeleteLine` /
`Indent` / `Outdent` etc. to accept a count directly (like `YankLinesCount(n)`
was fixed for `<count>yy`).

**Notes**: this is a real user-facing paper cut — press `5J` to fold a
snippet, realize you didn't want it, hit `u`, and now you have to hit
`u` four more times. Compounds on the count-o / count-i / count-a
findings below. `dw` with count (`3dw`) DOES group correctly as one
undo — so the fix pattern exists in the codebase, just not applied
universally.

---

## [SEV-2] `dd` / `yy` / `cc` / `>>` on a closed fold operate only on the header line — round-12 / round-13 unresolved

**Reproduction** (Rust file with a 12-line fold):

```rust
fn main() {
    let a = 1;
    …
    let i = 9;
    println!("done");
}
```

```jsonl
{"cmd":"open","path":"long.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"zc"}   // close outer fold — shows "fn main() {  ⋯ 11 hidden"
{"cmd":"type","text":"cc"}   // change closed fold
{"cmd":"type","text":"NEW"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"zo"}   // re-open to inspect
```

After `zo`: line 1 = `NEW`, lines 2-12 = the original fold body (`let a
= 1;` etc.). Only the header was changed; 11 hidden lines survived.

Same class defect for `dd` (only header removed), `yy` (only header
yanked), `>>` / `<<` (only header indented/outdented).

**Expected**: vim's fold-aware line ops act on the ENTIRE fold when
the cursor sits on a closed fold header. `dd` = 12 lines deleted. `yy`
+ `p` = 12 lines pasted. `>>` = all 12 lines indented.

**Actual**: fold body untouched. Cursor navigation `j` / `k` skips over
the folded region (fold-aware), but line operators don't.

**Source pointer**: same as round-13 F4 — `src/input/vim.rs`
doubled-op linewise arm at 2124-2160 doesn't consult the fold table
before dispatching `DeleteLine` / `YankLinesCount` / etc.

**Notes**: fold + `dd` to nuke a function block is one of vim's most
useful pairings. Still-broken since round-12.

---

## [SEV-2] `:sp <file>` / `:vsp <file>` / `:new` / `:vnew` / `Ctrl+w n` produce 3 panes (round-13 F#7 unresolved — bumping to SEV-2)

**Reproduction**:

```jsonl
{"cmd":"open","path":"a.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":sp b.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

Status.json panes after: `[{"a.txt"},{"a.txt"},{"b.txt"}]` — one
duplicate a.txt.

Same for `:vsp b.txt`, `:new`, `:vnew`, `Ctrl+w n`. Bumping from round-13
SEV-3 to SEV-2 because a 16-buffer test session's `:bn` cycle now
includes multiple phantom duplicates and `:ls` output is misleading.

**Source pointer**: `src/app/ex_commands.rs` `sp` / `vsp` / `new` /
`vnew` arms — the split-then-open sequence carries the source leaf's
active file into the new leaf's tabs list before adding the requested
file on top.

---

## [SEV-2] Visual-line `V` case-change no-op (round-12 F#7 unresolved)

Verified `V ~` / `V U` / `V u` / `V gU` / `V gu` / `V g~` all leave the
buffer unchanged. `gu$` / `gU$` etc. work — only the visual-line-mode
`~` / `U` / `u` / `g~` / `gU` / `gu` chords no-op.

**Source pointer**: `src/input/vim.rs::handle_visual` — missing
case-transform arms when the visual selection is `VimSelection::Line`.

---

## [SEV-3] `<count>i<text><esc>` / `<count>a<text><esc>` / `<count>A<text><esc>` doesn't multiply the insertion

**Reproduction**:

```jsonl
// buffer: START
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"3i"}
{"cmd":"type","text":"X"}
{"cmd":"key","key":"esc"}
```

Buffer after: `XSTART`.

Same for `3aX <esc>` → `SXTART` (one X), and `3AX <esc>` → `startX`
(one X at end).

**Expected**: vim `3iX <esc>` inserts `XXX` at cursor. `3aX <esc>`
appends `XXX`. `3AX <esc>` appends `XXX` at end of line.

**Actual**: count is ignored; only one insertion.

**Source pointer**: `src/input/vim.rs` `i` / `a` / `A` arms — the count
is captured (via `count1()`) but not fed to the Insert-mode
end-of-session multiplication logic (vim wraps the inserted text +
motion in a repeatable macro that's replayed count-1 times on `<esc>`).

**Notes**: `3i<c-a><esc>` is a canonical "add 3 of that" gesture (e.g.
`i - <esc>` after `10i-` for a `----------` divider). This is a
frequently-missed vim behavior — mnml joins the club.

---

## [SEV-3] `.` (dot repeat) after visual-mode edit doesn't replay at cursor

**Reproduction**:

```jsonl
// buffer: abcdefghij (line 1) + abcdefghij (line 2)
{"cmd":"type","text":"gg"}
{"cmd":"type","text":"vlld"}   // delete chars 0..2 on line 1 → cdefghij
{"cmd":"type","text":"j0"}
{"cmd":"type","text":"."}
{"cmd":"snapshot"}
```

Line 2 unchanged. Dot-repeat after visual-delete doesn't re-apply.

**Expected**: vim `.` after visual `vlld` re-runs the delete with the
same-shape selection at cursor — deletes the next 3 chars.

**Actual**: `.` after visual op is a no-op.

**Source pointer**: `src/input/vim.rs` — the visual-op path may not be
setting the dot-repeat register (`self.last_change`), or the replayed
op isn't reconstructing the visual selection at the current cursor.

**Notes**: paired with dot-repeat working for normal ops (verified `dw
.`, `dib .`, `cc .`, `>> .`, `dd .`, `S .`) — the visual-mode path is
the odd one out. Common vim workflow: "edit a small piece under
visual", then `.` on subsequent similar-shape targets. Missing here.

---

## Round-12 / 13 still-broken (re-verified quickly)

- SEV-2: **Visual-line `V ~` / `V U` / `V u` / `V gU` / `V gu` / `V g~`**
  — still no-op.
- SEV-2: **Block-visual edit undo needs two undos** — `gg <c-v> 3j A "
  X!" <esc>` then `u` — restores rows 2..4 but leaves row 1 with the
  edit. Second `u` completes.
- SEV-2: **`dd`/`cc`/`>>`/`<<`/`yy` on a closed fold** — header-only.
- SEV-2: **`:sp <file>` / `Ctrl+w n` produces 3 panes** — bumped from
  SEV-3.
- SEV-3: **`Ctrl+[` doesn't exit Insert mode** — `Ctrl+c` and `Esc`
  both work; `Ctrl+[` stays INSERT.
- SEV-3: **`:ab teh the`** — typing `teh dog` produces `thedog`
  (trigger whitespace eaten).
- SEV-3: **Visual `r<char>`** — `v ll r z` on `abcdefghij` leaves line
  unchanged. Only block-visual `r` works.

---

## Priority-verification detail (post-rebuild)

- **`S` clears the entire line before Insert**: verified from a mid-line
  position (col 3 of `line3`) → `S NEW <esc>` produces `NEW`. ✓
- **`2yy` yanks 2 lines linewise**: verified on a 5-line file — `gg 2yy
  G p` produces a 7-line buffer with `line1\nline2` appended. ✓
- **`dG` from line 3 in a 10-line buffer leaves 2 lines**: verified —
  cursor `jj` from `gg` = line 3, `dG` produces `line1\nline2\n`. ✓
- **`dgg` from line 8 in a 10-line buffer leaves 2 lines** (not 3 — the
  round-13 priority description had a typo). ✓
- **`y3G` from line 1 yanks lines 1–3** — **FAILS**. `y3G` yanks all 5
  lines. See SEV-2 above.

---

## Macros (verified working)

- `qa … q` records a macro into register `a` including `dib` and `S`
  and `A YUM <esc>`.
- `@a` replays. `3@a` replays 3× correctly (macro count works).
- `qb <find-brackets> dib q` → `@b` on line 2 → `@b` on line 3 —
  correctly deletes inner brackets on each line.

---

## Fixed since round-13 (verified)

- **`guu`** (lowercase current line) now works — `guu` on `ALPHA BETA`
  produces `alpha beta`. Round-13 said no-op. Not sure which commit
  landed the fix; the vim.rs:2160-2168 code path looks correct.

---
