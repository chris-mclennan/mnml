---
severity: SEV-3
status: fixed
---
# A rebuild toasts "rebuilt against SDK <current>" whatever the rebuilt binary stamped; the row keeps its `rebuild` chip with no word why

**Command id / surface:** `integrations.rebuild_stale` / `integrations.rebuild_focused`; the Installed tab's `rebuild` chip.

**Reproduction** (fresh launch; `MNML_MARKETPLACE_LOCAL=<fx>/slowsrc`, a local app integration whose `--install` writes its manifest with `.sdk = "0.0.1"` — what an integration whose `build.zig.zon` still pins an older `mnml-sdk` does):
```
{"cmd":"run-command","id":"integrations.show_marketplace"}
{"cmd":"key","key":"i"}
# wait for data-root/integrations/slow.zon
{"cmd":"run-command","id":"integrations.show_installed"}
{"cmd":"run-command","id":"integrations.rebuild_stale"}
```

**Expected:** the toast reports the SDK the fresh manifest carries; when it is still behind, it says so (e.g. "slow: rebuilt, still on SDK 0.0.1 — its mnml-sdk dependency is older than 0.1.0").

**Actual:** toast `slow: rebuilt against SDK 0.1.0`, while `integrations/slow.zon` reads `.sdk = "0.0.1"` and the row still reads `Slow  0.1.0     rebuild`. Running the command again repeats the same claim; the chip never goes.

**Why:** `installInner` returns `"rebuilt against SDK {sdk_version}"` with the host's own `mnml_sdk.version` (`src/app/marketplace.zig` ~1372) instead of reading back the stamp `--install` wrote.

**Reproduced:** 3/3 fresh launches.
