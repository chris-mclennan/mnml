# mnml bug-hunt — 2026-06-07

Headless exploration run by an LLM agent against v0.1.4 (~30 min).
The agent's tool layer blocked writing this file directly, so the
findings were returned in-band and saved here post-hoc. See the
session transcript at
`/private/tmp/claude-501/.../tasks/a924e5a4ccc222fea.output` for
the full agent run.

## Executive summary

**9 findings: 0 SEV-1, 2 SEV-2, 7 SEV-3.** Stability is high — no
panics, no hangs, no data loss across stress tests (100
splits/closes, 100 file-open cycles, 5 MB file open + edit).
Surprises worth flagging:

- `Ctrl+Alt+Shift+X` (and friends) silently cut the current line —
  standard-mode handler only checks `CONTROL`; other modifiers leak
  (SEV-2).
- `:e <newfile>` doesn't create a new buffer like vim does (SEV-2).
- `--ascii` flag is honored unevenly — bufferline still emits
  nerd-font close glyphs.

**Explored**: workspace+startup (incl. `--no-workspace`), palette +
commands, editor mutations, splits/panes/tabs, PTY shell, HTTP
send, git status/diff/commit, settings overlay, AI prompt,
image-view, blit-host launch of missing siblings, IPC fuzzing
(huge paste, weird keys, malformed paths).

**Did not drive**: real LSP completion, DAP, mouse forwarding (IPC
had no mouse channel during the run — see #239), tmnl-native
promotion, sixel rendering, in-app updater path (gated to
non-headless), `mnml run`/`mnml test` subcommands.

---

## [SEV-2] Ctrl+X-style chords trigger regardless of extra modifiers in standard mode

**Reproduction**:
```json
{"cmd":"open","path":"test.txt"}
{"cmd":"key","key":"escape"}
{"cmd":"run-command","id":"focus.cycle"}
{"cmd":"key","key":"ctrl+alt+shift+x"}
{"cmd":"snapshot"}
{"cmd":"quit"}
```
With `test.txt` = `alpha\nbeta\ngamma\n`.

**Expected**: `ctrl+alt+shift+x` is unbound; buffer unchanged.

**Actual**: Current line is cut (yank + delete). Same pattern
reproduces for `ctrl+alt+a` (Select All), `ctrl+shift+alt+s`
(Save), almost certainly `ctrl+alt+v`, `ctrl+alt+z`, `ctrl+alt+c`,
`ctrl+alt+/`, etc.

**Source pointer**: `src/input/standard.rs:59` —
`KeyCode::Char(c) if ctrl => match c.to_ascii_lowercase() { ... }`.
The match gates only on `ctrl`; `alt` and `shift` bits are ignored
for everything except the few arms that explicitly check them
(`'z' if shift => Redo`, `'d' if shift => DuplicateLine`). Fix:
require `!alt && extra modifiers empty` at the top of the match,
or use guards on each arm.

**Notes**: macOS keyboards often emit Ctrl+Alt+* combos for
OS-level shortcuts. If those leak into a focused mnml pane, the
user's current line gets silently cut. Real risk + invisible
failure mode.

---

## [SEV-2] `:e <new-file>` does not create a new buffer; you must use `file.new` instead

**Reproduction**:
```json
{"cmd":"open","path":"does-not-exist-yet.txt"}
{"cmd":"key","key":"escape"}
{"cmd":"run-command","id":"focus.cycle"}
{"cmd":"type","text":"NEW CONTENT"}
{"cmd":"run-command","id":"file.save"}
{"cmd":"quit"}
```

**Expected**: A new empty buffer for `does-not-exist-yet.txt`;
typing then saving creates the file (vim semantics: `:e
newfile.txt`).

**Actual**: Toast: `cannot open <path>: No such file or directory`.
`panes: []` — no buffer created. `file.save` then toasts `no
active editor`. File never created.

**Source pointer**: `src/app/layout.rs:246-332` (`open_path_inner`
→ `Buffer::open` Err arm toasts but doesn't create a scratch
buffer) + `src/app/ex_commands.rs:3042` (`ex_edit` delegates to
`open_path`). On ENOENT, should create an in-memory buffer with
`path: Some(p)` and `dirty: true`; save creates the file on first
write.

**Notes**: `file.new` (Ctrl+N) works and prompts for a filename —
but vim users will type `:e newfile.txt` reflexively and hit the
confusing toast.

---

## [SEV-3] `--ascii` doesn't strip bufferline close glyphs

**Reproduction**:
```bash
mnml --headless --ascii /tmp/ws
# then via IPC: open test.txt + snapshot
# inspect screen.txt for `\u{F0156}` glyphs in tab close badges
```

**Expected**: Every nerd-font glyph in chrome has an ASCII fallback
rendered.

**Actual**: Bufferline still uses `\u{F0156}` (`nf-md-close`) for
the close badge on every tab AND for the per-tabpage chip close
button. Status / tree / activity-bar respect the flag; bufferline
doesn't.

**Source pointer**: `src/ui/bufferline.rs:269` — `let badge = if
pane.is_dirty() { "●" } else { "\u{F0156}" };` (hardcoded, no
`nerd` check). Same pattern at line 517 for the active tabpage
chip's close button. File header reads `let nerd =
!app.config.ui.ascii_icons;` but `nerd` is never consulted at
these two sites.

---

## [SEV-3] Settings-overlay rows that exceed the overlay width are silently truncated mid-word

**Reproduction**:
```json
{"cmd":"open","path":"test.txt"}
{"cmd":"key","key":"escape"}
{"cmd":"run-command","id":"view.settings"}
{"cmd":"snapshot"}
{"cmd":"quit"}
```
At default 120 × 50 size.

**Expected**: Long descriptions wrap or get `…`-truncated.

**Actual**: Rows like `Scrolloff (rows of context above/below
cursor)  [ 0 ]  (0–20 · step` and `Theme  [ "onedark" ]  (text ·
default "oned` cut mid-word at the right border with no
indicator. Reads as broken layout.

**Source pointer**: `src/ui/settings_overlay.rs` (per-row
Paragraph render). Either wrap or truncate with `…`.

---

## [SEV-3] Statusline left section pushes all right-side chips off-screen for long file paths

**Reproduction**:
```bash
echo x > "/tmp/ws/a-very-long-filename-that-tests-bufferline-and-statusline-width-rendering.txt"
# open via IPC, snapshot
```

**Expected**: Right chips (mixr, file size, line/col, clock,
workspace, ext) preserved; filename gets `…`-truncated.

**Actual**: Right side disappears entirely. Only ` TREE  󰈙
<full-long-filename>  ♪` remains; clock + position + ws name + ext
all gone.

**Source pointer**: `src/ui/statusline.rs` — left section rendered
without max-width clamp before the right cluster.

---

## [SEV-3] Mnml auto-creates `.mnml/` in any opened workspace but never adds it to `.gitignore`

**Reproduction**:
```bash
cd /tmp && mkdir new-repo && cd new-repo && git init -q && \
  echo hi > a.txt && git add . && \
  git -c user.email=t@t -c user.name=t commit -qm init
mnml --headless . &
sleep 1
echo '{"cmd":"quit"}' >> .mnml/ipc/command
wait
git status -s
# shows .mnml/ipc/* + .mnml/session.json as untracked
```

**Expected**: `.mnml/` auto-appended to `.gitignore` so user's
clean git state stays clean.

**Actual**: `.mnml/ipc/{command,events.jsonl,screen.txt,status.json}`
+ `.mnml/session.json` show as untracked. Worse: opening
`git.status_pane` or `git.diff` inside mnml then diffs its own
IPC files (recursive self-noise).

**Source pointer**: `src/app/session.rs:232` is the
directory-creation site; no companion call to write `.gitignore`.
Mnml's own repo gitignores `.mnml/` but doesn't propagate the
rule. Fix: on first creation of `<workspace>/.mnml/`, append
`.mnml/` to `<workspace>/.gitignore` (create if absent), gated on
the workspace being a git repo.

**Notes**: Mild but every new-repo user hits it immediately.

---

## [SEV-3] `Ln 1/4` for a 3-line file — trailing newline counted as an extra line

**Reproduction**:
```bash
echo -e "a\nb\nc" > /tmp/ws/test.txt   # 6 bytes, 3 lines (wc -l = 3)
# open in mnml, check statusline
```

**Expected**: `Ln 1/3` (matches `wc -l` and every other editor).

**Actual**: `Ln 1/4`. Every trailing-newline file (the
Unix-correct form) is over-counted by 1.

**Source pointer**: `src/editor/mod.rs:1235` —
```rust
pub fn line_count(&self) -> usize {
    self.text.bytes().filter(|&b| b == b'\n').count() + 1
}
```
Fix: subtract 1 when the buffer is non-empty and ends in `\n`.

**Notes**: Pure display issue (cursor positioning isn't affected
— uses `current_line()`), but every line-count chip is
off-by-one.

---

## [SEV-3] First-time IPC drive races: `Ipc::init` truncates the command channel after launch

**Reproduction**:
```bash
mkdir -p /tmp/ws/.mnml/ipc
cat > /tmp/ws/.mnml/ipc/command <<EOF
{"cmd":"snapshot"}
{"cmd":"quit"}
EOF
mnml --headless /tmp/ws   # hangs forever — pre-queued commands were truncated
```

**Expected**: Either documented (it kind of is) OR an event
"truncated N bytes on init" so a host can spot the race.

**Actual**: Silently swallows pre-queued commands. The only safe
pattern is "launch first, sleep, then append, then poll".

**Source pointer**: `src/ipc/mod.rs:90-93` — `Ipc::init` does
`std::fs::write(&cmd_path, b"")?;` unconditionally.

---

## [SEV-3] `forge.open_lambda` (and siblings) returns `ok:true` even when the sibling binary is missing

**Reproduction**:
```bash
which mnml-aws-lambda     # confirm: not found
# IPC: run-command forge.open_lambda, snapshot 1-2s later
```

**Expected**: ok=false reported, OR the palette/whichkey command
list suppresses sibling-launch commands when the binary isn't
detected (the `+ Add integration` overlay already detects this —
gate command exposure on the same signal).

**Actual**: `events.jsonl` records `command_run
id=forge.open_lambda ok=true` even though `host_launch` toasted
`host.launch: pane_host: spawn mnml-aws-lambda: No such file or
directory (os error 2)` and no pane was created.

**Source pointer**: `src/command.rs:85` (`pub fn run` treats
"handler returned without panicking" as success) +
`src/app/blit_host.rs:16-45` (`host_launch` returns `()`, toasts
on failure but signals nothing upward). Consider routing
`Result<(), String>` back, or gating palette/whichkey exposure on
`integration_detect`.

**Notes**: Interactive users see the toast (4s TTL). Headless
callers + plugin authors don't.

---

## Notes worth recording (not findings)

- 5 MB / 50 000-line file opens in <1 s, navigates with `ctrl+end`,
  edits at the head with no perceptible lag.
- 100 file opens + 60 `view.close_split` calls left `panes: []`
  cleanly — no leak.
- 100 splits-then-close cycle: no leak, no crash.
- HTTP `http.send` to unreachable address returns `connection
  failed: error sending request` cleanly — no hang.
- Binary file (urandom bytes, no extension) refused with graceful
  UTF-8 error.
- Garbage IPC (unknown cmds, malformed JSON, bad command ids) all
  logged as `unknown` / `ok=false`, no panic.
- CJK input (日本語) round-trips correctly through save/reload.
- DAP commands (`dap.run`, `dap.terminate`) on no-session
  workspaces are no-ops, no crash.
- `host.launch <missing-binary>` toasts cleanly within 4s TTL
  (the only issue is the false-positive ok=true above).

## Driver / artifacts

- Helper: `/tmp/mnml-hunt/drive.sh` (launches mnml --headless,
  appends commands to `<ws>/.mnml/ipc/command`, polls for exit,
  dumps status + events + screen).
- Test workspaces under `/tmp/mnml-hunt/ws-*` — each one's
  `.mnml/ipc/screen.txt` + `events.jsonl` is the artifact.
- Binary: `target/release/mnml` (v0.1.4).

## Worst-3 highlights

1. **Modifier leak: Ctrl+Alt+Shift+X silently cuts the current
   line** (and Ctrl+Alt+A, Ctrl+Alt+S, etc. fire too) — standard
   handler only checks CONTROL, ignores ALT/SHIFT.
2. **`:e newfile.txt` doesn't create a new buffer** — toasts
   "cannot open" instead of giving vim users the buffer they
   reflexively expect.
3. **`--ascii` bypassed by bufferline close glyphs** — hardcoded
   `\u{F0156}` renders as tofu on non-nerd-font terminals.
