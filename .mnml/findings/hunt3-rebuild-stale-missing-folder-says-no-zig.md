---
severity: SEV-3
status: fixed
---
# `integrations.rebuild_stale` on a stale row whose source folder is gone fails with "zig build: cannot run zig: FileNotFound" instead of naming the row as not rebuildable

**Command id / surface:** `integrations.rebuild_stale` (and `integrations.rebuild_focused`, same `localSource` path); the Installed tab's `rebuild` chip.

**Reproduction** (fresh launch; `MNML_MARKETPLACE_LOCAL=<fx>/gone`, a copy of a local app integration whose `--install` writes a manifest stamped `.sdk = "0.0.1"`):
```
{"cmd":"run-command","id":"integrations.show_marketplace"}
{"cmd":"key","key":"i"}
# wait for data-root/integrations/slow.zon, then: rm -rf <fx>/gone
{"cmd":"run-command","id":"integrations.show_installed"}
{"cmd":"run-command","id":"integrations.rebuild_stale"}
```

**Expected:** per the command's own contract, "a stale row with no folder behind it is named and left" — the warn toast `integrations: slow is built on an older SDK but not from a folder here — reinstall from the Marketplace` (or "its folder <path> is gone").

**Actual:** the row wears `Slow  0.1.0     rebuild`; the command toasts `rebuilding slow against SDK 0.1.0…` and then `marketplace: slow: zig build: cannot run zig: FileNotFound` — blaming the `zig` binary, which is on PATH; it is the build folder (the child's cwd) that is missing.

**Why:** `localSource` (`src/app/integrations.zig` ~2950) returns the `built-from` note's path (and a cached marketplace entry's url) without checking the folder exists; the spawn's cwd failure surfaces as `FileNotFound` against argv[0] in `run` (`src/app/marketplace.zig`).

**Reproduced:** 3/3 fresh launches.
