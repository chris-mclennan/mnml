# nvchad-round-16 — vim-mode hunt, 2026-07-16

## Executive summary

Ran a ~45-minute headless vim-mode session against a freshly-rebuilt
`~/Projects/mnml/target/release/mnml --input vim`. Same footgun as round-15:
the on-disk binary was built Jul 15 00:24 — 29 minutes older than the round-15
fix commit `7bfc540f fix(mouse): systematic stale-rect clear on activity
switch + 2× vim regressions` (Jul 15 00:53). First-pass verifications reported
`d3gg` still broken until I noticed the timestamp and ran `cargo build
--release`. Memory note `verify findings via headless` earned another badge.

**Round-15 priority verification results (post-rebuild)**:

- `d3G` / `y3G` — count restored. **Ships.**
- `d3gg` / `y3gg` — count restored. **Ships.**
- `Ctrl+B` in Normal → PageUp (36 lines on 40-row screen). **Ships.**
- `Ctrl+B` in Insert → falls through to `view.toggle_tree`. **Ships.**
- `3dd` / `5x` / `3J` + `u` → 1 press restores in each case. **Ships.**
- `S` clears whole line + Insert mode. **Ships.**
- `<count>yy` yanks N lines; `3yy` + `Gp` appends 3 lines. **Ships.**
- `dib` / `dab` / `diB` / `daB` — bracket shorthands work. **Ships.**
- `:%s/foo/X/` (no `/g`) — first per line only. **Ships.**
- `:w!` / `:wa!` / `:wqa!` — force-save works. **Ships.**
- `:map` — no longer silently switches to standard mode (now shows
  "unknown command" toast). **Ships** (see F14 for the gap it opens).

**Fresh hunt on top of the round-15 verifications** — five new count-drop
sites and a Visual-mode Ctrl-key blackhole:

- `<count>gu<motion>` / `<count>gU<motion>` / `<count>g~<motion>` — count
  silently dropped, only the first `<motion>` is transformed. (F1.)
- `<count>gcc` — comment operator drops the count; only cursor line is
  commented. (F2.)
- `<count>gp` / `<count>gP` — paste drops count (`3gp` after `yy` pastes
  once). (F3.)
- `<count>cc` / `<count>S` — line-change operators drop count; only
  cursor line is changed. (F4.)
- `<count>>>` / `<count><<` — count is applied to indent DEPTH instead
  of LINE COUNT (`3>>` indents cursor line 3 levels, doesn't touch
  siblings). (F5.)
- `<count>diw` / `<count>daw` — inner-word text-object drops count
  (`3diw` deletes 1 inner word). (F6.)
- Ctrl+B/F/D/U/E/Y in **Visual** — dead across the board (F7).
  Concretely from line 100 of a 100-line buffer, V-line mode:
  - Ctrl+B moves cursor to line 99 (acts as bare `b` = MoveWordLeft).
  - Ctrl+F silent no-op.
  - Ctrl+D falls to global `editor.add_cursor_at_next_word`, drops
    Visual back to Normal.
  - Ctrl+U silent + drops Visual (via global `editor.delete_to_line_start`
    behavior).
  - Ctrl+E in Visual — silent, viewport doesn't scroll.

- `3.` after `dd` correctly deletes 3 lines but the atomic-undo
  wrapper doesn't cover the dot-repeat: `u` restores only ONE of the
  three lines. (F8.)

**Still broken since round-12 / 13 / 14 / 15** (re-verified this round):

- SEV-2: `dd` / `yy` / `cc` on a closed fold operates only on the
  header line, not the folded body (`zM` + `dd` on `fn main() {` deletes
  only the `fn main() {` line, leaves the 3 body lines + `}` behind).
- SEV-2: V-line case change — `VjU` from line 1 uppercases only line 1
  (line 2 stays lowercase).
- SEV-2: Block-visual insert (`Ctrl+v jjj I X <esc>`) + `u` leaves
  `Xaaaa` on line 1 — `u` restored rows 2, 3, 4 only.
- SEV-3: `Ctrl+[` from Insert mode doesn't escape to Normal (mode
  stays INSERT).

**Not broken (verified this round)**:

- Marks `ma` → `'a` round-trip.
- `Ctrl+o` from Insert (one-shot Normal command, then back to Insert).
- `Ctrl+r "` in Insert pastes the yank register.
- `.` dot-repeat with same count (no count override — mnml reuses the
  original count, matches vim's canonical `.`).
- `3~` toggles case of 3 chars.
- `3 Ctrl+a` / `3 Ctrl+x` — increment / decrement by 3.
- `3gg` (no operator) — jumps to line 3.
- `d3w` — 3-word deletion works.
- `qa 3dd q` then `@a` — macro replay of `3dd` is atomic-undo-able.
- Macro `@a` respects atomic wrap on the count-op inside.
- `:%s/foo/XX/gc` confirm loop — y/n/a/q all reachable.
- `:q` refuses on dirty; `:q!` forces; `:bd!` on dirty y.txt closes
  cleanly.
- `:tabnew b.txt` opens as second pane.
- `ci)` / `ci}` — closing-bracket forms.

**Verdict** — Round-15 shipped both announced fixes correctly, and every
priority verification lands. But there are five FURTHER count-preservation
sites in the same shape as the F1 fix that just landed (all inside
`Prefix::G` re-entry, plus the doubled-line `<count>cc` / `<count>S` /
`<count>>>` / `<count><<` operator arms). Visual mode is separately
underweight: Ctrl+B/F/D/U/E all miss the vim-canonical PageUp / PageDown
/ Half / Scroll interception that Normal mode has. Net feel: works for a
Normal-mode drive-by but leaks the muscle memory the moment I pop into
Visual to select first.

**Count by severity**: **SEV-1: 0 · SEV-2: 12 fresh + 3 carried · SEV-3:
5 fresh + 1 carried** = 21 findings.

---

## [SEV-2] F1 — `<count>gu<motion>` / `<count>gU<motion>` / `<count>g~<motion>` silently drop the count

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"3"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"u"}
{"cmd":"key","key":"w"}
```

Setup: `HELLO WORLD FOO BAR BAZ\n`.

**Expected** (vim): lowercase 3 words → `hello world foo BAR BAZ`.
**Actual**: `hello WORLD FOO BAR BAZ` — only the first word was lowercased.

Same shape for `3gUw` (result `HELLO world foo bar baz`) and `3g~w`
(result `AbC dEf gHi jKl mNo` — only "aBc" toggled). `gu3w` /
`gU3w` / `g~3w` (count AFTER operator) work correctly.

**Source pointer**: `src/input/vim.rs:1262-1275` — the `Prefix::G`
handler's arms for `KeyCode::Char('u' | 'U' | '~')` set
`self.op = Some(PendingOp::…)` but never restore `self.count` after
the top-of-fn `reset_pending()` at :1140. Mirror the round-15 F1 fix at
:2260-2263 (set `self.count = Some(n)` when `count_was_explicit`).

---

## [SEV-2] F2 — `<count>gcc` drops count

**Reproduction**:
```
{"cmd":"open","path":"x.py"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"3gcc"}
```

Setup: `line1\nline2\nline3\nline4\nline5\n` in `x.py`.

**Expected** (nvchad Comment.nvim / vim-commentary): comment 3 lines.
**Actual**: only line 1 gets `# line1`. Same root cause as F1.

**Source pointer**: `src/input/vim.rs:1201-1204` sets
`self.prefix = Prefix::Gc` and DOES restore count (`self.count = if
n > 1 { Some(n) } else { None }`), but `Prefix::Gc` at :1406-1408
starts with `self.reset_pending()` — clearing that restored count
before the `KeyCode::Char('c')` arm at :1407 fires
`ToggleLineComment`, which is a single-op not a
`Self::repeated(…, n)`. Either preserve count through `Prefix::Gc`
or use the `n` captured pre-reset when emitting the ops vector.

---

## [SEV-2] F3 — `<count>gp` / `<count>gP` drop count

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"yy"}
{"cmd":"type","text":"3gp"}
```

Setup: `x\n`.

**Expected**: paste 3 copies (result: 4 lines of `x`).
**Actual**: 2 lines — paste happened once.

For comparison `3p` (no `g`) DOES paste 3 lines (verified same repro
with `3p` substituted).

**Source pointer**: `src/input/vim.rs:1285-1286` — `KeyCode::Char('p' |
'P')` in `Prefix::G` emit `vec![PasteAfterEnd]` / `vec![PasteBeforeEnd]`
without `Self::repeated(…, n)`. The captured `n` is in scope
(:1135) but ignored.

---

## [SEV-2] F4 — `<count>cc` / `<count>S` drop count

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"3cc"}
{"cmd":"type","text":"NEW"}
{"cmd":"key","key":"esc"}
```

Setup: `line1\n…\nline5\n`.

**Expected**: change 3 lines → `NEW\nline4\nline5\n`.
**Actual**: only line 1 changed → `NEW\nline2\nline3\nline4\nline5\n`.

Same shape for `3S` — `S` is documented as the singleton form of `cc`
(round-13 F1). Both drop count.

**Source pointer**: `src/input/vim.rs:2134-2145` (doubled-op path for
`cc` inside `PendingOp::Change`) emits `vec![SelectLine, MoveLineEnd,
ReplaceSelection(String::new())]` and enters Insert mode without
extending the selection to `n` lines. Compare with the `Delete` arm at
:2126 which does `Self::repeated(DeleteLine, n)`.

---

## [SEV-2] F5 — `<count>>>` / `<count><<` apply count to indent depth, not line count

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"3"}
{"cmd":"key","key":">"}
{"cmd":"key","key":">"}
```

Setup: `line1\n…\nline5\n`.

**Expected** (vim): indent 3 lines by one shiftwidth →
```
    line1
    line2
    line3
line4
line5
```
**Actual**:
```
            line1
line2
line3
line4
line5
```
Only line 1 is affected, but it gets indented 3 shiftwidths (`\t\t\t`
equivalent — 12 spaces on a 4-col shiftwidth).

Same shape for `3<<` — the pre-indented input `    a\n…\n    e\n` gives
`a\n    b\n    c\n    d\n    e\n` (only line 1 outdented).

**Source pointer**: `src/input/vim.rs:2147-2148` (doubled-op path for
`PendingOp::Indent` / `PendingOp::Outdent`) —
`InputResult::Ops(Self::repeated(Indent, n))` — repeats Indent N
times, but Indent is a per-cursor-line op, so N repeats stack the
levels on the same line instead of moving the cursor down after each.
Emit a linewise op equivalent to `IndentLines { start, end }` covering
`cur..=cur+n-1`, or interleave `MoveDown` between each Indent.

---

## [SEV-2] F6 — `<count>diw` / `<count>daw` etc. drop count on text-object

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"0"}
{"cmd":"type","text":"3diw"}
```

Setup: `one two three four five\n`.

**Expected** (vim `:help count-and-object`): delete 3 inner words →
`four five` (with leading whitespace nuances).
**Actual**: only the first inner word "one" is removed → ` two three
four five`.

Same shape for `d3iw` (post-operator count) and `3daw` — all drop the
count multiplier on the text-object range.

**Source pointer**: `src/input/vim.rs:2237` and `:2242` — the
`TextObjectInner` / `TextObjectAround` prefix transitions preserve
`self.op` but don't preserve `self.count`. The dispatcher at
`:1595-1791` builds one text-object range and applies the op once,
ignoring any repeated invocation.

---

## [SEV-2] F7 — Ctrl+B / Ctrl+F / Ctrl+D / Ctrl+U / Ctrl+E don't fire canonical scroll in Visual mode

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}         # 100-line seed
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"G"}                # cursor line 100
{"cmd":"key","key":"V"}                # V-LINE
{"cmd":"key","key":"ctrl+b"}
```

**Expected** (vim): cursor jumps up by page height (~36 lines with a
40-row screen), Visual selection extends.
**Actual**: cursor moves from line 100 to line 99 — that's `b`
(MoveWordLeft), NOT PageUp. Modifier silently dropped.

Same repro pattern for the other four:

| Chord     | Expected                     | Actual                               |
|-----------|------------------------------|--------------------------------------|
| `Ctrl+B`  | PageUp                        | acts as `b` (MoveWordLeft, 1 line up) |
| `Ctrl+F`  | PageDown                      | silent no-op                          |
| `Ctrl+D`  | HalfPageDown                  | drops Visual + fires global `editor.add_cursor_at_next_word` |
| `Ctrl+U`  | HalfPageUp                    | drops Visual + `DeleteToLineStart` (leaves empty buffer) |
| `Ctrl+E`  | Scroll viewport down 1 line   | silent no-op                          |

**Source pointer**: `src/input/vim.rs:3083 handle_visual` — no
`Ctrl+B/F/D/U/E/Y` handling. The Normal-mode `KeyCode::Char('b') if
ctrl` arm at :2850 doesn't exist in the Visual handler. The bypass in
`src/tui/mod.rs:2131-2144` (round-15 F2) does cover Visual (`vim_normal_or_visual
= matches!(EditingMode::Visual | VisualLine | VisualBlock)`), so
chord_chain is skipped and the key reaches the vim handler — but the
handler's `Self::motion(key.code)` at :3262 matches `Char('b')` as
MoveWordLeft before any ctrl-check runs. Add explicit
`KeyCode::Char('b' | 'f' | 'd' | 'u' | 'e' | 'y') if ctrl` arms that
short-circuit to PageUp/PageDown/HalfPageUp/HalfPageDown/ScrollUp/
ScrollDown while keeping selection live.

---

## [SEV-2] F8 — `<count>.` after `<op>` deletes correctly but breaks atomic-undo

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"dd"}       # delete line 1
{"cmd":"type","text":"3."}        # replay with count 3 → deletes 3 lines
{"cmd":"key","key":"u"}           # single undo
```

Setup: 20-line file, cursor at start.

After `dd`: lines 2..20 remain.
After `3.`: lines 5..20 remain (3 more lines deleted, count applied).
After `u`: lines 4..20 remain — only ONE line was restored.

**Expected** (vim `:help .`): `<count>.` runs the last change as if it
had been typed with count N. `u` restores ALL N. mnml did the right
thing on the DELETE (3 lines removed) but the undo unit is 1 line, so
`u` walks it back one step at a time.

**Source pointer**: `src/input/vim.rs` (dot-repeat implementation
around the `Repeat(count, inner)` op emission). The atomic wrapper
introduced in round-14 for `<count><op>` (see F13 in round-15 notes)
covers the initial typing but not the dot-replay. Likely the replay
emits N separate copies of the inner op (each atomic) instead of one
atomic `Repeat(N, …)`.

---

## [SEV-2] F9 — `dd` / `yy` / `cc` on closed fold header only touches header

**Reproduction**:
```
{"cmd":"open","path":"x.rs"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"zM"}     # fold all
{"cmd":"type","text":"dd"}
```

Seed:
```rs
fn main() {
    let x = 1;
    let y = 2;
    let z = 3;
}
fn other() {
    let a = 1;
    let b = 2;
}
```

After `zM`:
```
▶  1 fn main() {    ⋯ 4 hidden
▶  6 fn other() {    ⋯ 3 hidden
```

**Expected**: `dd` on the folded `fn main()` header removes the whole
5-line block, leaving only `fn other() { ⋯ }`.
**Actual**:
```
   1     let x = 1;
   2     let y = 2;
   3     let z = 3;
   4 }
▶  5 fn other() {    ⋯ 3 hidden
```
The header line was deleted but the fold body was left behind, and
the fold is now broken.

Same shape for `yy` (yanks header only; `Gp` pastes back `fn main() {`
instead of the 5-line block) and (untested but symmetric) `cc`.

**Source pointer**: unknown — `DeleteLine` / `YankLine` don't consult
the fold table. Search for `folds` in `src/app/mod.rs` and interpose a
`resolve_folded_range_starting_at(row)` helper.

**Notes**: same finding as round-15's carried SEV-2. Not fixed.

---

## [SEV-2] F10 — V-line case-change only touches the first line of the selection

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"j"}       # selection now spans lines 1-2
{"cmd":"key","key":"U"}
```

Setup: `hello\nworld\nfoo\n`.

**Expected**: both selected lines uppercased → `HELLO\nWORLD\nfoo\n`.
**Actual**: `HELLO\nworld\nfoo\n` — only line 1 changed.

**Source pointer**: `src/input/vim.rs:3369-3374` — `KeyCode::Char('U')`
in Visual emits `TransformSelectionCase(Upper)` + `SelectClear`. The
TransformSelectionCase implementation (elsewhere) is probably a per-
range char-transform that doesn't traverse across the newline
boundary of a V-line selection. Confirm by mapping the linewise
selection to `[line_start(anchor_row), line_end(cursor_row)]` before
transform.

**Notes**: same finding as round-15 carried. Not fixed.

---

## [SEV-2] F11 — Block-visual insert + one undo leaves one row un-restored

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}       # block covers rows 1-4
{"cmd":"key","key":"I"}
{"cmd":"type","text":"X"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"u"}
```

Setup: `aaaa\nbbbb\ncccc\ndddd\n`.

After block-I-X: `Xaaaa\nXbbbb\nXcccc\nXdddd\n`.
After `u`: `Xaaaa\nbbbb\ncccc\ndddd\n` — only rows 2-4 restored.

**Expected**: one undo restores all 4 rows.
**Source pointer**: `handle_visual_block` at `src/input/vim.rs:3417`.
The block-insert replays typed keys per-row after Esc; the atomic-undo
wrapper is missing for the fan-out. Same shape as F8 dot-repeat.

**Notes**: same finding as round-15 carried. Not fixed.

---

## [SEV-2] F12 — `:s/pat/rep/gc` reports "match 1/2" but `:noh` doesn't dismiss the indicator

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"/foo\n"}
{"cmd":"type","text":":noh\n"}
```

Setup: `foo bar foo baz\n`.

**Expected**: the "match 1/2" chip in the bottom-right disappears.
**Actual**: still visible after `:noh`.

**Source pointer**: `src/app/find.rs` (or wherever the FindState +
match-count chip live) — `:noh` clears highlight but keeps the
overlay chip.

**Notes**: minor but a NvChad user reaches for `:noh` specifically
to hide this UI, so it reads as "the ex command doesn't work". Borderline
SEV-2 / SEV-3 — filed SEV-2 because a canonical vim command is a no-op.

---

## [SEV-3] F13 — `Ctrl+[` from Insert doesn't return to Normal

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"i"}      # mode INSERT
{"cmd":"key","key":"ctrl+["}  # expect NORMAL
```

**Expected**: `Ctrl+[` is vim canonical `<Esc>`; returns to Normal.
**Actual**: mode stays INSERT.

`Ctrl+C` from Insert DOES return to Normal — so an emergency-exit
exists — but `Ctrl+[` specifically is a Nerd-keyboard reflex (users
on ergonomic layouts remap `Caps Lock → Ctrl` and hit `Ctrl+[`
several times per minute). Silent no-op means finger keeps typing
into the buffer.

**Source pointer**: unknown — likely at the mode-transition in
`handle_insert`. Match `KeyCode::Char('[')` + `KeyModifiers::CONTROL`
alongside the existing `KeyCode::Esc` arm.

**Notes**: same finding as round-15 carried. Not fixed.

---

## [SEV-3] F14 — `<count>oNEW<esc>` inserts N lines but `u` leaves stray empty line

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"3"}
{"cmd":"key","key":"o"}
{"cmd":"type","text":"NEW"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"u"}
```

Setup: `line1\n…\nline5\n`.

After `3oNEW<esc>`: `line1\nNEW\nNEW\nNEW\nline2\n…\nline5\n`. ✓
After single `u`:
```
line1
<empty>
line2
line3
line4
line5
```
So `u` removed 2 of the 3 NEWs and blanked the 3rd (leaves an
empty-line ghost). Round-15 flagged this as "needs 3 presses" —
observed behavior is worse: N-1 presses to clean up + a phantom empty
line. Full recovery from single `u` never happens.

**Source pointer**: same as F8 — atomic-undo wrap doesn't cover the
`o<text><esc>` fan-out cleanly; the Insert-mode text ops slip out of
the wrap while the row-creation stays inside.

**Notes**: round-15 explicitly deferred this as backlog. Restating
here so the phantom-empty-line + N-1-presses shape is on record — the
"just 3 presses" summary undersells the recovery cost.

---

## [SEV-3] F15 — `Ctrl+B` in Cmdline types literal `b`, doesn't act as canonical vim BOL

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":"}
{"cmd":"key","key":"ctrl+b"}
```

**Expected** (vim `:help c_CTRL-B`): cursor jumps to the beginning of
the cmdline.
**Actual**: cmdline shows `:b▏` — a literal 'b' was inserted (control
modifier was stripped in the cmdline handler).

**Source pointer**: `src/input/vim.rs:571 handle_cmdline` — the arm
that maps `KeyCode::Char(c)` to `insert into cmdline` doesn't check
`ctrl` and admits every `Char(_)`. Add a `if ctrl { … }` short-circuit
above the insert.

**Notes**: standalone this is SEV-3, but combined with F7 (Visual-mode
Ctrl+B) it shows the same class of "the round-15 Ctrl+B bypass only
covers Normal, other modes still eat the modifier".

---

## [SEV-3] F16 — `:map` reports "unknown command" — the round-15 fix suppresses the standard-mode switch but leaves no way to list mappings

**Reproduction**:
```
{"cmd":"open","path":"x.txt"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":map\n"}
```

**Expected**: pop up a mapping list (vim canonical) OR a
mnml-native `:commands` fallback.
**Actual**: toast `:map — unknown command`.

Round-15's fix was to stop `:map` from silently switching to standard
mode (which was the surprising behavior). The current state is
correct-but-incomplete: the vim user still gets no way to inspect
their bindings. Route `:map` to `commands.show` or a which-key mapping
peek so muscle memory has SOMETHING.

**Source pointer**: `src/app/ex_commands.rs` — add an alias / handler.

---

## [SEV-3] F17 — `:sp` / `:new` produce extra duplicate panes (carried from round-15)

Not re-verified this round — round-15's F11 catch. Same shape:
`:vsplit y.txt` after opening x.txt yields three panes
`[x.txt, x.txt, y.txt]` in status.json (should be 2). Filed here for
continuity; keeping severity SEV-3 as it's cosmetic-ish (the extra
pane is a phantom in the pane list, not a visible split).

---

## Reproduction environment

- Binary: `~/Projects/mnml/target/release/mnml` (rebuilt 2026-07-16
  16:54 after the round-15 fix commit).
- Launch: `mnml --headless --input vim <ws>`.
- IPC substrate: `<ws>/.mnml/ipc/{command, screen.txt, status.json,
  events.jsonl}`.
- Each finding was validated in a fresh workspace (`/tmp/mnml-nvchad-r16-*`)
  so state doesn't leak across scenarios. Every workspace was killed
  (`kill $(cat $WS/.mnml/mnml.pid)`) between runs.
