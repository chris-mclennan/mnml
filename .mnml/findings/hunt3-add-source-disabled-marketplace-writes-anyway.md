---
severity: SEV-3
status: open
---
# With `marketplace.enabled = false`, adding a source reports "disabled" as a failure but has already written the source to config.zon

**Command id / surface:** `marketplace.add_source`.

**Reproduction** (fresh launch; home `config.zon` is `.{ .marketplace = .{ .enabled = false } }`; workspace has `acme/one/{build.zig,manifest.zon}`):
```
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"acme"}
{"cmd":"key","key":"enter"}
```
then the same three lines again.

**Expected:** either refuse before writing ("the Marketplace is disabled"), or add it and say it was added (and that the tab is off).

**Actual:** the only message is the error toast `marketplace: disabled in config (marketplace.enabled)`, yet `config.zon` now reads
```
.marketplace = .{ .enabled = false, .sources = .{
    .{ .local_folder = .{ .id = "acme", .path = "…/acme" } },
} },
```
and the retry says `… /acme is already the source acme` — the user was told it failed.

**Why:** `addSource` writes the file and grows `cfg.marketplace.sources` first, then calls `refresh`, which fails on `!enabled` (`src/app/marketplace.zig:489`) and that error becomes the command's result.

**Reproduced:** 3/3 fresh launches.
