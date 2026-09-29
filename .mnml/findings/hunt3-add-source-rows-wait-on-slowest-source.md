---
severity: SEV-3
status: open
---
# A folder just added as a source is not listed until every other source's fetch finishes, while the toast already says "N integrations found"

**Command id / surface:** `marketplace.add_source` → the Marketplace tab.

**Reproduction** (fresh launch; a local HTTP server on 127.0.0.1 that answers `release_index` requests after a 6 s delay; home `config.zon`:
`.{ .marketplace = .{ .use_defaults = false, .sources = .{ .{ .release_index = .{ .id = "ri", .url = "http://127.0.0.1:18778/index.json" } }, .{ .local_folder = .{ .id = "acme", .path = "<ws>/acme" } } } } }`,
workspace folders `acme/one/` and `beta/two/` each a build.zig + manifest.zon integration):
```
{"cmd":"run-command","id":"integrations.show_marketplace"}
# wait for the first listing (Mkt (1))
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"beta"}
{"cmd":"key","key":"enter"}
```

**Expected:** the tab lists the new folder at once (what `marketplace_add_source_folder.test` and the add-source docs promise) — the folder was already listed once, to count it.

**Actual:** toast `added beta: 1 integration found`, but the tab stays `Mkt (1)` showing only `[app] One  Private  (acme)` for the full 6 s, and becomes `Mkt (2)` only when the slow source answers. From a first launch where that source had not answered yet the tab read `Mkt (0)` for the whole delay (12 s server). With GitHub sources on a slow network the new rows lag by however long GitHub takes, or never appear if it times out.

**Why:** `addSource` lists the folder (`listLocal`) only to count it, then calls `refresh`, which cancels and restarts one worker that fetches every source and posts a single `.listing` (`src/app/marketplace.zig` `refresh` / `fetchWorker`); nothing is shown until the whole batch lands.

**Reproduced:** 2/2 fresh launches.
