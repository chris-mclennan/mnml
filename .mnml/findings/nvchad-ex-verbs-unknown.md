---
severity: SEV-3
status: open
---
# Everyday ex verbs not covered by PARITY's "missing" list are "unknown command"

**Command ids:** the `:` line (`src/app/ex.zig` verb table).

**Reproduction** — each line typed on its own, toast read from screen.txt:
```
{"cmd":"type","text":":t.\n"}          → │ :t. — unknown command │
{"cmd":"type","text":":m0\n"}          → │ :m0 — unknown command │
{"cmd":"type","text":":only\n"}        → unknown (also :on)
{"cmd":"type","text":":new\n"}         → unknown (also :vnew)
{"cmd":"type","text":":update\n"}      → unknown (also :up)
{"cmd":"type","text":":sav x\n"}       → unknown
{"cmd":"type","text":":bfirst\n"}      → unknown (also :blast)
{"cmd":"type","text":":cq\n"}          → unknown
{"cmd":"type","text":":set number?\n"} → │ :set — unknown option "number?" │   (`:set wrap?` works, `:set number` works)
```

**Expected**: `:t` / `:m` (copy/move lines), `:only`, `:new`/`:vnew`, `:update`, `:saveas`, `:bfirst`/`:blast` are core vim and none is listed as cut or Remaining in `docs/PARITY.md`; `:set number?` should print the value like `:set wrap?` does.

**Actual**: unknown-command toasts. (For contrast, `:g`, `:v`, `:norm`, `:!`, `:r`, `:>`, `:s///c` — all "missing" per PARITY — actually work; the ledger is stale in the other direction.)
