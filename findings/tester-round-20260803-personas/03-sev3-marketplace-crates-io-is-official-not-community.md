# [SEV-3] `crates.io` marketplace results render `✓ Official`, not `~ Community` — spec drift

**Reproduction**:
```
{"cmd":"key","key":"esc"}
{"cmd":"click","col":1,"row":10,"button":"left"}          // open Integrations activity panel
{"cmd":"wait_ms","ms":200}
{"cmd":"click","col":22,"row":2,"button":"left"}          // switch to Marketplace tab
{"cmd":"run-command","id":"marketplace.refresh"}
{"cmd":"wait_ms","ms":5000}
{"cmd":"snapshot"}
```

**Expected** (per this round's test brief): `chris-mclennan/mnml-integrations` entries render `✓ Official`; any crates.io result renders `~ Community`. Test wording implies crates.io is a "3rd-party" source.

**Actual**: Both `chris-mclennan/mnml-integrations` AND `crates.io` (keyword `mnml-integration`) are entries of `default_sources()` (`src/marketplace.rs:194-206`). `provenance_for(source_id)` matches ANY id in `default_sources()` and returns `Provenance::Official` (`src/marketplace.rs:132-138`). So a crates.io result — if the ecosystem search ever returns one — will render `✓ Official`, not `~ Community`. `~ Community` currently only appears for entries whose `source_id` is a user-added `[[marketplace.source]]` id (verified by seeding a fake entry with `source_id="user-source-x"` in `~/.cache/mnml/marketplace.json` and restarting — that entry rendered correctly as `~ Community` and sorted after all Official entries, alphabetical within group).

**Source pointer**: `src/marketplace.rs:194-206` (default sources include both crates.io AND the GH integrations catalog); `src/marketplace.rs:132-138` (`provenance_for` = "is your id in the default list?").

**Notes**:
- The **shipping behavior** (Official-first sort, alphabetical within group, ✓ Official green chip, ~ Community dim chip, sort persists across cache reload) is all correct — verified via seeded cache.
- Just the **test brief's wording** is off: "crates.io" is not a 3rd-party source in the shipped default catalog. A cleaner test spec would seed a `[[marketplace.source]]` block with a distinct id (e.g. `"my-team/integrations"`) and assert Community rendering + sort on that.
- No user-facing fix needed — just documentation / test-brief cleanup.
