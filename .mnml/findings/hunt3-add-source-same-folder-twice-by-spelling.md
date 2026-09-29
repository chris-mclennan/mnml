---
severity: SEV-3
status: open
---
# The same folder can be added as several sources by spelling it differently (letter case on macOS, a symlink) — every integration in it is then listed once per spelling

**Command id / surface:** `marketplace.add_source` (all entry points).

**Reproduction** (fresh launch on macOS's default case-insensitive volume; workspace `acme/one/{build.zig,manifest.zon}` and `ln -s acme link`):
```
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"acme"}
{"cmd":"key","key":"enter"}
```
repeated with `ACME`, `Acme` and `link`.

**Expected:** the second and later adds are refused as `… is already the source acme` — the same refusal `./acme/`, `empty/../acme` and the absolute path already get.

**Actual:** every one is accepted — `added ACME: 1 integration found`, `added Acme: 1 integration found`, `added link: 1 integration found` — and `config.zon` gains `.id = "ACME", .path = "…/ACME"` and `.id = "Acme", .path = "…/Acme"` beside `acme`. The Marketplace tab then reads `Mkt (6)` with
```
[app] One  Private  (ac…
[app] One  Private  (AC…
[app] One  Private  (Ac…
```

**Why:** the duplicate check compares the lexically resolved path strings (`std.mem.eql(u8, spec.path, f.abs)`, `src/app/marketplace.zig` ~992), never the folder's real path.

**Reproduced:** 2/2 fresh launches.
