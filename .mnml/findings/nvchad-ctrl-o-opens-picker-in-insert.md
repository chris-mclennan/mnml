---
severity: SEV-2
status: open
---
# `Ctrl-O` is bound to `picker.files` in the vim profile — insert-mode one-shot normal is gone and the picker swallows the next keys

**Command id:** `picker.files` — `docs/commands.md` line 568: chords `ctrl+p`, `ctrl+o`, `space f f` in **both** columns.

**Reproduction**:
```
{"cmd":"open","path":"hunt/b.zig"}
{"cmd":"type","text":":12\n"}
{"cmd":"key","key":"A"}
{"cmd":"key","key":"ctrl+o"}
{"cmd":"snapshot"}
{"cmd":"key","key":"0"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
**status.json** after each step: `"mode":"INSERT","cursor":{"line":12,"col":25}` → after `0` still INSERT col 25 (the `0` went into the picker filter) → after first `esc` still `"mode":"INSERT"` (it closed the picker) → after second `esc` `"mode":"NORMAL"`.

In a longer session this is how a user ends up typing ex commands into the buffer: `A`, `Ctrl-O`, `0`, `ZZ`, `Esc`, then `:e!⏎ :w …⏎` all landed as literal text on lines 12–36 of b.zig (screen excerpt):
```
12|  12     const x = add(1, 2);:e!
13|  13 :w hunt/copy.zig
14|  14 :tabnew
```

**Expected**: in INSERT, `Ctrl-O` executes one normal-mode command and returns to insert (`Ctrl-O 0` moves to column 1). In NORMAL, `Ctrl-O` is the jumplist (known missing per PARITY — fine to toast, but the chord should not be taken by the file picker).

**Actual**: the file picker opens over insert mode; the next keys are typed into its filter; the first `Esc` only dismisses the picker.

**Source pointer**: `src/commands/specs.zig` `picker.files` keys (`ctrl+o` not moved to `standard`); `docs/KEYMAP_PROFILES.md` rule 1 list lacks `ctrl+o`.
