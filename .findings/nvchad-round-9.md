# nvchad-user round 9 findings

Session date: 2026-07-11. Binary: `~/Projects/mnml/target/release/mnml --input vim`.
Workspace: `/tmp/mnml-nvchad-r9/` (+ ephemeral `/tmp/mnml-nvchad-r9-dirty` for a minimal repro).

## Executive summary

- **SEV-1**: 1 (dirty-flag desync after `:e! <other-path>` — subsequent `:w` can
  silently write "phantom-modified" content, cf. §1)
- **SEV-2**: 8 (all ex-command / motion gaps — see §2..§9)
- **SEV-3**: 3 (special registers gap via `"<x>p` and Ctrl-R, filter operator
  discovery friction, `zR` phantom after `zM`+sort — see §10..§12)

Round 8 landed fixes verified live in this build:
- `/<vim-regex>` search — works cleanly (matches highlight, cursor jumps, `n`/`N`
  correct).
- `:g/pat/{cmd}` and `:v/pat/{cmd}` with `:d` and `:norm dd` — both fire.
- Visual text objects `viw`, `vip`, `vi"`, `vi(`, `vit`, etc. — selection extends.
- Fold nav `zj`/`zk` — cursor lands on next/prev fold start.
- `zM` — closes all `{ ... }` regions in prog.rs (bracket-scan fallback works).
- `:delmarks a` — mark cleared, `'a` no longer jumps.
- `:e! <path>` — switches to `<path>` (see SEV-1 for a follow-on flaw).
- `Ctrl-R %` — inserts current filename in insert mode. `Ctrl-R /` — inserts last
  search string.
- `iW` / `aW` — respects WORD boundaries (`two-three`, `alpha.beta` fully deleted).
- `@@` — replays last macro. `3@@` — replays 3 times.
- `:w !cmd` — pipes buffer to `wc -l`, output shown in cmdline.
- V-BLOCK `I` — single undo (spot-checked; no repro of the regression).

A very vim-competent build overall. The gaps found are all in the "less trodden
corners" the round 9 charter targets — ex-command corner cases, `:sort` flag
matrix, filter operator, jump-list stack depth, special registers, and one
buffer-lifecycle issue that could bite a user.

---

## [SEV-1] `:e! <other-path>` clears the current buffer's dirty flag without discarding its in-memory edits

**Reproduction** (fresh workspace with `a.txt` = "original A" and `b.txt` =
"original B"):
```
{"cmd":"open","path":"a.txt"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"iDIRTY_"}
{"cmd":"key","key":"escape"}
{"cmd":"type","text":":e! b.txt\n"}
{"cmd":"wait_ms","ms":300}
{"cmd":"type","text":":b a.txt\n"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```
Then:
```
{"cmd":"type","text":":w\n"}
```

**Expected**: One of two consistent behaviors —
1. `:e! b.txt` truly discards a.txt's changes: coming back via `:b a.txt` shows
   "original A" and dirty=false. (Vim with `hidden` off, `abandon` semantics.)
2. `:e! b.txt` leaves a.txt hidden-and-dirty: coming back shows "DIRTY_original A"
   AND dirty=true (so `:w` still requires the user to intentionally save).
   (Vim with `hidden` on — the common `.vimrc` default.)

**Actual**: A third, worst-of-both state — a.txt's buffer keeps "DIRTY_original A"
in memory but the dirty flag is cleared to false. `:w` then silently writes the
phantom-modified content to disk. `cat /tmp/mnml-nvchad-r9-dirty/a.txt` after
`:w` shows `DIRTY_original A` even though the tab-strip and status.json both
reported dirty=false.

**Source pointer**: `src/app/ex_commands.rs` — the `:e!` handler. The `!` bang
must be dropping the dirty bit on the *outgoing* buffer instead of on the file it
switched to (or in addition to reloading it). Grep for the `edit`/`e` arm with
`bang=true` in `run_ex_command`.

**Notes**: Data-loss potential is real — a user who does `:e! other` believing
they discarded changes to the current file, then later ends up back on that
buffer, will get no dirty-marker warning before `:w`. Even the "hidden" behavior
(keep the modifications, keep the marker) would be safer than clearing the
marker while retaining the content.

---

## [SEV-2] `:<range>sort` silently ignores the range

**Reproduction**:
```
{"cmd":"open","path":"rs2.txt"}   // zebra / yak / X / Y / apple / banana
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":":1,4sort\n"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

**Expected**: Lines 1-4 sorted (`X`, `Y`, `yak`, `zebra`); lines 5-6 untouched.
**Actual**: Buffer unchanged. No error toast. Silent drop.

**Source pointer**: `src/app/ex_commands.rs:824-881`. The range-prefixed match
handles only `d`, `y`, `j`, `<`, `>`, `s`. `sort` falls through the
`_ => { /* fall through to normal dispatcher */ }` arm; the fall-through then
tries to run the whole `2,5sort` line as a single command name, which nothing
matches. Same shape blocks `:2,5normal A_x`, which I also reproduced (see §3).

`:sort` with no range still works. `:%sort` — I did not confirm; it falls
through to the main `"sort"` arm which sorts the whole buffer, matching intent.

---

## [SEV-2] `:<range>normal <keys>` also silently dropped

**Reproduction**:
```
{"cmd":"open","path":"rs2.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":":2,4normal A_x\n"}   // append _x to lines 2..4
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

**Expected**: Only lines 2-4 get `_x` appended.
**Actual**: Buffer unchanged. `:%norm A_x` DOES fire (all lines get `_x`), so
the `norm`/`normal` handler exists — it's the numeric-range prefix path that
drops it, same as `:sort` (§2).

**Source pointer**: `src/app/ex_commands.rs:824-881` (range-prefix match table)
vs `src/app/ex_commands.rs:2568` (`"norm" | "normal" => self.run_norm(rest, false)`
in the main dispatcher).

---

## [SEV-2] `:sort n` (numeric) and `:sort r` (reverse) flags silently ignored

**Reproduction** (numeric):
```
{"cmd":"open","path":"numeric.txt"}   // 10 / 2 / 100 / 5 / 20 / 1
{"cmd":"type","text":":sort n\n"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
**Expected**: `1, 2, 5, 10, 20, 100` (numeric order).
**Actual**: `1, 10, 100, 2, 20, 5` (lexicographic — `n` flag ignored).

**Reproduction** (reverse):
```
{"cmd":"type","text":"u"}
{"cmd":"type","text":":sort r\n"}
```
**Expected**: `100, 20, 10, 5, 2, 1` (descending).
**Actual**: `1, 10, 100, 2, 20, 5` (ascending — `r` ignored, same output as
plain `:sort`).

**Note**: `:sort!` (reverse via bang) DOES work — confirms the reversal logic
exists in `run_sort_lines_opts`, just isn't reachable via the `r` flag.

**Source pointer**: `src/app/ex_commands.rs:1343`:
```
"sort" => self.run_sort_lines_opts(rest.contains('u'), false, rest.contains('i')),
"sort!" => self.run_sort_lines_opts(rest.contains('u'), true, rest.contains('i')),
```
Only `u` and `i` flags are parsed. `n` and `r` are read but ignored. `x` (hex),
`b` (binary), `o` (octal), `f` (float) unsupported — probably out of scope for
now, but at minimum `n` and `r` (the standard ones) should land.

---

## [SEV-2] `:sort` on files with a trailing newline sorts a phantom empty line to the top

**Reproduction**:
```
{"cmd":"open","path":"nums.txt"}   // 9 words, file ends with \n
{"cmd":"type","text":":sort\n"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
**Expected**: 9 sorted lines.
**Actual**: 10 lines — line 1 is empty, then the 9 sorted words.

Confirmed the trailing-`\n` connection with `printf "cherry\napple\nbanana"`
(no trailing newline) — `:sort` there produces 3 lines, no phantom empty.

**Source pointer**: `src/app/ex_commands.rs:341-373`. `end_byte = text.len()`
then `text[start_byte..end_byte].split('\n').collect()`. When `text` ends with
`\n`, the split produces a trailing `""`. The sort then puts that empty at the
top (empty < everything).

Fix shape: detect a trailing newline before the split, strip it, sort, re-attach.

**Notes**: Ships identical behavior across `:sort u` and `:sort i`. `:%!sort`
(shell-filter path) does NOT have the phantom — that path preserves the trailing
newline correctly.

---

## [SEV-2] `!<motion>` / `!!` filter operator not implemented in normal mode

**Reproduction**:
```
{"cmd":"open","path":"filter.txt"}   // 20 / 5 / 100 / 1 / 2 / 10
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"!G"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```
**Expected**: Cmdline shows `:.,$!` prompt awaiting a shell command; user then
types `sort -n\n` and the buffer is piped through.
**Actual**: `!G` just moves the cursor to line 6 (the `G` fires as a motion) —
no cmdline appears. `!!` (double-bang, filter current line): also nothing —
mode stays NORMAL, no prompt.

**Source pointer**: `src/input/vim.rs` — grep the operator-pending prefix table
around 850..950. There is no `KeyCode::Char('!')` arm setting a `PendingOp::Bang`
/ `Filter`. `:%!cmd` (ex-command shell filter) works fine, so the plumbing to
run a shell filter exists — just no normal-mode operator entry.

**Notes**: `!` operator is one of the standard motion-operator pairs
(cf. `:h !`). Users lean on it for one-shot sorts (`!ipsort`), formatters
(`!apjson_pp`), etc.

---

## [SEV-2] Ctrl-O jump list toggles between the last two positions instead of walking back

**Reproduction**:
```
{"cmd":"open","path":"prog.rs"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"3G"}        // jump 1→3
{"cmd":"type","text":"7G"}        // jump 3→7
{"cmd":"type","text":"12G"}       // jump 7→12
{"cmd":"key","key":"ctrl+o"}      // expect 7
{"cmd":"key","key":"ctrl+o"}      // expect 3
{"cmd":"key","key":"ctrl+o"}      // expect 1
```
**Expected**: cursor path 12 → 7 → 3 → 1.
**Actual**: 12 → 7 → 12 → 7 (toggle).

**Source pointer**: `src/app/mod.rs:6728` `nav_back_jump`. The jump itself calls
`jump_to_nav_point` → `place_cursor` → the `dispatch_key` post-hook
(`record_within_file_jump`) then pushes the *destination* row back onto
`nav_back`. So after Ctrl+O, back-stack is again `[1, 3, 7, 12]` (with 12
re-appended), and the next Ctrl+O pops 12 → jumps to 12.

The `nav_jump_in_progress` flag (`src/app/mod.rs:6703-6708`) prevents the forward
stack from being cleared but does NOT prevent the back-stack push. That last
guard is missing:

```rust
pub fn record_within_file_jump(&mut self, np: NavPoint) {
    if self.nav_jump_in_progress { return; }   // <— missing
    self.push_nav_back(np);
    if !self.nav_jump_in_progress {
        self.nav_forward.clear();
    }
}
```

Effect: a jump-list of any depth degenerates to a 2-slot toggle.

---

## [SEV-2] Visual mode text objects `vif`/`vaf`/`vic`/`vac`/`via`/`vaa` don't select

**Reproduction**:
```
{"cmd":"open","path":"prog.rs"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"5G"}         // land on `fn multiply(…) { … }`
{"cmd":"type","text":"vaf"}
{"cmd":"type","text":"y"}          // yank the (empty) selection
{"cmd":"type","text":"G"}
{"cmd":"type","text":"o"}
{"cmd":"key","key":"escape"}
{"cmd":"type","text":"p"}
```
**Expected**: yanked function definition pastes at end of file.
**Actual**: pastes nothing — `vaf` did not extend the selection past the anchor.
Same shape for `vif`, `vic`, `vac`, `via`, `vaa`.

`daf`/`dif`/`dic`/`dac`/`dia`/`daa` (operator + text object) all work — the
issue is specifically the visual-mode text-object dispatcher.

**Source pointer**: `src/input/vim.rs:2925-2988` — the visual `TextObjectInner|
TextObjectAround` match table. Compare vs the operator-pending table at
`src/input/vim.rs:1530-1650`:

| Text object | Op-pending path (§1530) | Visual path (§2925) |
|-------------|-------------------------|---------------------|
| `w`, `W`    | ✓                       | ✓                   |
| `"`/`'`/`` ` ``, `q` | ✓              | ✓                   |
| `p` (paragraph) | ✓                   | ✓                   |
| `t` (tag)   | ✓                       | ✓                   |
| `i`/`I` (indent) | ✓                  | ✓                   |
| `(`/`[`/`{`/`<` | ✓                   | ✓                   |
| **`f` (function)** | ✓                | ✗ (missing)         |
| **`c` (class)**    | ✓                | ✗ (missing)         |
| **`a` (arg)**      | ✓                | ✗ (missing)         |

The three tree-sitter text objects only exist in the operator-pending arm. Add
the `KeyCode::Char('f'|'c'|'a')` arms mirroring §1579-1598 to the visual arm and
they light up.

---

## [SEV-2] `i,`/`a,` argument text object not recognized

**Reproduction**:
```
{"cmd":"open","path":"prog.rs"}
{"cmd":"type","text":"12G"}         // let a = add(1, 2);
{"cmd":"type","text":"f1"}          // land on `1`
{"cmd":"type","text":"di,"}
```
**Expected**: `1` deleted (targitpad delimits argument by `,`) or `1, ` (around).
**Actual**: nothing changes. Only `ia` / `aa` (mnml's chosen keys) do argument
selection.

**Source pointer**: `src/input/vim.rs:1593-1598`:
```rust
KeyCode::Char('a') => {
    if around { SelectAroundArgument } else { SelectInnerArgument }
}
```

**Notes**: SEV-2 not because vim upstream defines `i,` — it doesn't; the classic
`targits.vim` plugin's `i,` chord is what most NvChad users have wired in via
`nvim-treesitter-textobjects` or `wellle/targets.vim`. But mnml's rebinding to
`ia`/`aa` conflicts with `ai`/`ii` (indent-block) in the operator-pending
table — `daa` and `dai` are one keystroke apart and semantically different
(delete-arg vs delete-around-indent-block). Consider also accepting `i,`/`a,`
as an alias.

---

## [SEV-3] Special registers `":`, `".`, `"%`, `"/` don't work via `"<x>p` selector; `Ctrl-R` covers `%`/`/` only

**Reproduction** (via `"` register selector):
```
{"cmd":"type","text":":set ai\n"}   // populate the last-cmdline register
{"cmd":"type","text":"o\":"}         // literal `":` text
{"cmd":"key","key":"escape"}
{"cmd":"type","text":"\":p"}         // paste from `:` register (last cmdline)
```
**Expected**: pastes `set ai` next to the literal `":` prefix.
**Actual**: pastes whatever is in the unnamed / small-delete register (in my
session, `gamma` from a way-earlier `dw`).

Same for `"%p` (current filename), `".p` (last inserted text), `"/p` (last
search). All fall back to the unnamed register.

**Ctrl-R** in insert mode does cover *some* of these:
- `Ctrl-R %` → `regs.txt` (filename) ✓
- `Ctrl-R /` → `alpha` (last search) ✓ — but only if the search was fresh
  enough in the session (see §11)
- `Ctrl-R :` → empty ✗
- `Ctrl-R .` → empty ✗

**Source pointer**: `src/input/vim.rs` — the register-selector `"` prefix arm.
Grep for `Prefix::Register` / `pending_register`. The parse currently only
matches `a..z` / `A..Z` / `0..9` / `-` for register names.

**Notes**: SEV-3 rather than SEV-2 because most vim users memorize
`Ctrl-R %` and `Ctrl-R /` for the common cases and never touch the `"<x>p`
form of `:`, `.`, or `%`. But the gap is real and shows up when someone runs a
plugin or macro that assumes it.

---

## [SEV-3] `Ctrl-R /` reads stale-or-empty between search runs (not reliably the last search)

**Reproduction**:
```
{"cmd":"open","path":"prog.rs"}
{"cmd":"type","text":"/alpha\n"}        // set the / register to "alpha"
{"cmd":"wait_ms","ms":100}
{"cmd":"type","text":"G"}
{"cmd":"type","text":"o"}
{"cmd":"type","text":"search="}
{"cmd":"key","key":"ctrl+r"}
{"cmd":"type","text":"/"}
```
**Expected**: inserts `alpha`.
**Actual**: in my session, sometimes empty and sometimes `alpha` — I got
`search=` (empty) on the first attempt and `search2=alpha` (correct) when I
re-ran the same sequence a few commands later. Both times were in the same
mnml process, both after the same `/alpha\n` call.

**Source pointer**: `src/input/vim.rs` / `src/app/*.rs` — grep the last-search
storage. My guess is the register is populated only when the search overlay
commits, and the first commit path in the session was going through a
different code path (welcome overlay dismissal?). Hard to pin without
instrumentation.

**Notes**: Might just be my session state; could not reproduce a clean
minimal every-time repro. Filing as SEV-3 with a note to keep an eye on.

---

## [SEV-3] `zR` after `zM` and a subsequent `:sort` leaves the phantom empty line at the top

Follow-on cosmetic issue tied to §5 — the sort-phantom empty line survives
`zR`, `zM`, `zR` cycles. Once the phantom is there, it stays until the user
manually `gg dd`s it. Not a distinct issue from §5 in the underlying cause; only
noted because it visibly persists across fold cycles and is one more surprise
in a session that already has "hidden" trailing-newline handling elsewhere.

---

## Deep-dig items I couldn't confirm inside this session

- **LSP `K` hover popup** — the workspace was a plain `/tmp` dir with a
  standalone `.rs` file, so rust-analyzer never attached. `K` did nothing
  (silent, no toast, no popup). Recommend re-running this scenario against the
  actual mnml Cargo workspace to sanity-check the `K` → popup → `Esc` dismiss
  path with a live LSP.
- **`Ctrl-N` completion popup interaction with vim ops** — in the `/tmp`
  workspace with no LSP, `Ctrl-N` in insert mode just inserted a newline. Same
  need for a real LSP-attached workspace to test the "completion popup steals
  Esc" question.
- **`:autocmd`** — dispatcher returns `unknown command`. Consistent with mnml
  not having autocmds. Not counted as a finding since it's an explicit
  scope gap, but confirming the `run cmd on save` hook question: there is none
  reachable via `:` today.
- **Deep `.` after `ysiw)`** — works. `.` on the next word wraps `beta` too.
  Confirmed on the surround.txt fixture.

## Files exercised

Fixtures in `/tmp/mnml-nvchad-r9/`: `hello.txt`, `nums.txt`, `numeric.txt`,
`filter.txt`, `para.txt`, `prog.rs`, `tags.html`, `repeat.txt`, `quotes.txt`,
`indent.txt`, `surround.txt`, `word.txt`, `macro.txt`, `rangesort.txt`, `rs2.txt`,
`vg.txt`, `regs.txt`, `nonewline.txt`. Second workspace at
`/tmp/mnml-nvchad-r9-dirty/` for the SEV-1 minimal repro (`a.txt` + `b.txt`).

No panics observed. `stderr.log` empty. `events.jsonl` shows only expected
`ok:true` / no `key_unparsed` misses beyond the first learning-curve one at
session start.
