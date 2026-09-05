---
severity: SEV-2
status: open
---
# `p` over a Visual selection with an empty unnamed register deletes the selection (Vim refuses with E353)

**Command ids:** V-LINE / VISUAL `p` (`src/input/vim.zig` visual put → replace-selection path).

Workspace `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt`, launched `MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input vim <ws>`; `nvchad-scratch/a.txt` is a copy of `hunt/a.txt` (9 NATO lines), `nvchad-scratch/b.zig` of `hunt/b.zig`, `nvchad-scratch/long.zig` of `hunt/long.zig` (every `pub fn` is 8 lines). Each repro is a fresh launch, reproduced twice.

**Reproduction**:
```
{"cmd":"open","path":"nvchad-scratch/a.txt"}
{"cmd":"type","text":":1\n"}
{"cmd":"type","text":"Vjjp"}
{"cmd":"snapshot"}
{"cmd":"type","text":"u"}
{"cmd":"type","text":"p"}
{"cmd":"snapshot"}
```
**screen.txt / status.json**:
```
after V j j p (nothing ever yanked this session):  Ln 1/6 — lines 1-3 are gone
  1 juliet kilo lima
  2 mike november oscar
after u then Normal-mode p:  Ln 1/9, unchanged (correct)
```

**Expected**: with nothing in the register `v_p` fails (`E353: Nothing in register "`) and the text stays; Normal-mode `p` already behaves that way here.

**Actual**: the selection is replaced by nothing — three lines vanish with no message. Undoable, but a fresh-session `Vp` reflex silently deletes text. Two launches.

**Source pointer**: `src/input/vim.zig` Visual `'p'` — deletes the selection before checking the register has content.
