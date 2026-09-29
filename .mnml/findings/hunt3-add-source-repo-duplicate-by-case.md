---
severity: SEV-3
status: open
---
# `owner/repo` sources are de-duplicated case-sensitively: `someone/tools`, `Someone/Tools` and `SOMEONE/TOOLS` are added as three sources

**Command id / surface:** `marketplace.add_source`.

**Reproduction** (fresh launch; `MNML_MARKETPLACE_API=http://127.0.0.1:9` so nothing leaves the machine):
```
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"someone/tools"}
{"cmd":"key","key":"enter"}
```
repeated with `Someone/Tools` and `SOMEONE/TOOLS`.

**Expected:** GitHub owner and repo names are case-insensitive — the second and third are "already the source tools" (the exact repeat `someone/tools` is refused that way).

**Actual:** home `config.zon` gains three entries for one repo, with ids that differ only by case:
```
.{ .github_monorepo_apps = .{ .id = "tools", .repo = "someone/tools", .apps_dir = "apps", } },
.{ .github_monorepo_apps = .{ .id = "Tools", .repo = "Someone/Tools", .apps_dir = "apps", } },
.{ .github_monorepo_apps = .{ .id = "TOOLS", .repo = "SOMEONE/TOOLS", .apps_dir = "apps", } },
```
Every refresh then fetches the same repo three times and lists each integration three times.

**Why:** the repo branch of `addSource` compares with `std.mem.eql` (`src/app/marketplace.zig` ~1016), and `uniqueId` is case-sensitive too.

**Reproduced:** 2/2 fresh launches.
