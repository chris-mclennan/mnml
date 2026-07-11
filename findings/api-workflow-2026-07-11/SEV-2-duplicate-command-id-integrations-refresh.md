---
finding: duplicate-command-id-integrations-refresh
severity: SEV-2
surface: cli-mode
---

**Repro**: numbered steps (headless `.test` harness, `cargo run -- test <file>`):

1. `grep -oE 'id: "[a-zA-Z0-9_.]+"' src/command.rs | sort | uniq -c | sort -rn`
   shows `id: "integrations.refresh"` registered **twice**, at
   `src/command.rs:1679` and `src/command.rs:4696`, with two DIFFERENT `run`
   handlers:
   - Line 1679: `crate::integration_detect::clear_cache(); app.toast("integration detection refreshed");`
     (title: "Integrations: refresh installed-binary detection")
   - Line 4696: `app.refresh_integration_manifests()`
     (title: "Integrations: re-scan manifests in .mnml/integrations/ + ~/.config/mnml/integrations/")
2. In a `.test` script: `open anchor.txt` then `command integrations.refresh`
   (this is the same dispatch path used by the palette-by-id, the
   `:integrations.refresh` ex-command, IPC `{"cmd":"run-command","id":"integrations.refresh"}`,
   and any `[keys.*]` config binding to this id).
3. `expect screen contains "integration detection refreshed"`.

**Expected**: either both distinct behaviors are reachable under distinct
ids, or (if intentionally consolidated) only one `Command` entry exists.

**Actual**: the toast that appears is `"integrations: 37 manifest(s)
loaded"` (the line-4696 handler) — never `"integration detection
refreshed"`. `Registry::build()` (`src/command.rs:66-73`) builds `by_id` via
`.collect::<HashMap<_,_>>()` over `(c.id, i)` pairs; for a duplicate key the
later entry in iteration order silently wins. `Registry::get(id)` — used by
every id-based dispatch path (IPC `run-command`, `:ex <id>`, keybinding
resolution) — can therefore **never** reach the line-1679
`integration_detect::clear_cache()` handler. It's dead code: still present
in `Registry::all()` (so it may render as an extra, confusingly-duplicate
row in the palette, since the palette lists `all()` by index, not `by_id`),
but its actual "refresh installed-binary detection" behavior
(`integration_detect::clear_cache()`) is permanently unreachable by id,
keybinding, or `:ex` — only a palette click on that specific row instance
would still fire it (palette invokes the picked `Command` struct's `run`
directly, not via `get(id)`).

**IPC trace** (`.test` runner's toast-line output on the repro above):
```
integrations: 37 manifest(s) loaded
```
(instead of the expected `integration detection refreshed` for the
binary-detection-cache-clear command.)

**Notes** (offending file:line): `src/command.rs:1679-1687` (first,
now-unreachable-by-id registration) vs `src/command.rs:4693-4699` (second,
winning registration). Root cause in the registry itself:
`src/command.rs:66-73`, `Registry::build()`'s `by_id` construction has no
duplicate-key detection (a `debug_assert!` or panic on collision at
registry-build time would have caught this at compile/test time instead of
silently shadowing a builtin).

Also noted in passing, lower severity, same root cause: `id:
"view.close_others"` is ALSO registered twice (`src/command.rs:550` and
`src/command.rs:1288`) — but both entries call the identical
`app.close_other_panes()` handler, so behavior isn't affected, just a
redundant/confusing palette row. Not filed as its own SEV-3 since it's
inert; flagging here so triage can clean up both duplicates together.
