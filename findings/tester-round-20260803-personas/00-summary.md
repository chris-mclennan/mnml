# Tester round 20260803 (personas) — summary

## Scope
Drove the mnml headless harness against HEAD~5..HEAD (5 commits landed 2026-08-03):
- `cb82bfb8` — `layout.merge_to_tabs` + `layout.spread_to_splits`
- `d586d97e` — docs
- `1940917a` — Rebake glyph now + `purge_sibling_glyph_state` meta cleanup
- `2a357614` — persist_ui_string_array helper (refactor; not user-visible)
- `ae63b6b7` — Marketplace Provenance chip + sort

Release binary was stale (pre-cb82bfb8); rebuilt with zig 0.16 in PATH before testing.

## Findings by severity

| SEV | # | Item |
|-----|---|------|
| 1 (crash / data loss / modal corrupt) | 0 | — |
| 2 (chord fires wrong action / silent drop / broken command) | 1 | Silent tab-chip clipping after merge |
| 3 (UX wart / doc drift) | 2 | Rebake dead-end on default chip; test-brief crates.io wording |

## Top 3 for immediate fix

1. **SEV-2 — `layout.merge_to_tabs` silently clips overflow tabs.** Merging 10 splits back into one leaf produces 5 visible chips (of 10 tabs) with no `+N more` indicator. `hidden_tab_count` is only computed for the HTTP filter case; the strip-paint loop just `break`s on overflow. Same shape hits `spread_to_splits` on 9-10 tabs (last leaf's multi-tab strip also clips). See finding 01.

2. **SEV-3 — "Rebake glyph now" is a dead-end on the default `browser` chip.** New menu item under "Bake / tune glyph…" is unconditionally added to every integration chip's context menu, but only chips with a `glyph_meta.toml` entry OR a `BUILTIN_GLYPHS` catalog entry actually rebake. `browser` (U+EB01) is a Nerd Font codicon with neither — so the sole enabled-by-default chip hits an error toast on first use. See finding 02.

3. **SEV-3 — Marketplace test-brief calls `crates.io` "3rd-party" but the code classifies it Official.** `default_sources()` includes both `crates.io` (keyword search) AND `chris-mclennan/mnml-integrations` — anything from either renders `✓ Official`. Community only appears for user-added `[[marketplace.source]]` ids. Shipping behavior is correct end-to-end; the round's test brief just needs a wording fix. See finding 03.

## What passed (worth calling out)

- `layout.spread_to_splits` shapes were **all correct**: 2-tab → H-split; 3 → left + right V-stack; 5 → 3×2 (5 leaves, 6th slot missing); 8 → 4×2; 10 → 4×2 with last leaf holding tabs `[7,8,9]`. All 10 panes preserved, focus preserved across every tested spread + merge + spread + focus-in-tail round-trip; dirty-buffer flags preserved.
- `layout.merge_to_tabs` correctly reports "nothing to merge" on Empty and "already a single leaf" on single-leaf layouts.
- `layout.spread_to_splits` correctly reports "already has splits; merge to tabs first" and "nothing to spread" on single-tab leaves.
- Both commands surface under the `view` group in Ctrl+Shift+P palette + `:layout.` ex-command completion; no leader chord binding (no collision).
- Rebake correctly toasts `no stored meta or builtin` on chips without a bakeable glyph; does NOT open the visual glyph-builder overlay (verified — no overlay appeared post-click, just a toast). Unit test `purge_sibling_glyph_state_drops_matching_glyph_meta_entry` (src/app/sibling_glyphs.rs:474) covers the meta-cleanup path end-to-end.
- Marketplace `✓ Official` (green) / `~ Community` (dim) chips render; sort is Official-first + case-insensitive alphabetical within each group; sort survives cache reload (verified by seeding a Community entry and restarting).
