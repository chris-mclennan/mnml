# [SEV-3] "Rebake glyph now" menu item is a dead-end on the only chip enabled by default

**Reproduction** (fresh workspace, headless):
```
{"cmd":"key","key":"esc"}
{"cmd":"click","col":85,"row":0,"button":"right"}          // right-click the browser integration chip
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
// context menu shows "Rebake glyph now" as a normal enabled row
{"cmd":"click","col":70,"row":9,"button":"left"}           // click "Rebake glyph now"
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

**Expected**: Either
1. The menu item is hidden / disabled on chips whose codepoint has neither a `glyph_meta.toml` entry nor a `BUILTIN_GLYPHS` catalog entry (i.e., every Nerd Font codicon-backed chip mnml ships), or
2. The toast points at what to do next ("rebake only fires for mnml-owned SVG glyphs — this chip uses a Nerd Font codicon"; or "run `integrations.bake_ai_glyphs` first").

**Actual**: Menu item is shown on every integration chip. Clicking it on the default `browser` chip (U+EB01, a Nerd Font codicon) fires the toast `rebake U+EB01: no stored meta or builtin` and does nothing else. `browser` is the ONLY integration `enabled: true` + `in_palette_bar: true` by default (`src/config.rs:1145-1163`), so the very first user-facing surface for this feature is a dead end.

**Source pointer**:
- Menu item is unconditionally pushed in `src/app/context_menus.rs:568-578` (immediately below "Bake / tune glyph…") whenever the chip has any codepoint at all.
- Handler in `src/app/glyph_builder.rs:441-527` (`rebake_glyph_for_cp`) does the meta/builtin lookup and toasts `"no stored meta or builtin"` on miss (`src/app/glyph_builder.rs:472`).
- `BUILTIN_GLYPHS` covers only F1B07 (AWS), F1E00/F1E01 (AI), F2000-F2002 (dev tools) — see `src/glyph_builder.rs:622-694`. Every other chip glyph (browser, all launchers, all messaging siblings) hits the miss path.

**Notes**:
- Fix is one condition on the item-push: check `builtin_for_codepoint(cp).is_some() || load_meta().glyphs.iter().any(|g| g.codepoint == format!("{cp:04X}"))` before adding the item.
- Alternative: keep the item but grey it out (context_menu already supports disabled items in the same file for other cases).
- Cosmetic bonus: the accompanying "Bake / tune glyph…" item DOES work for these chips (opens the visual builder at a fresh PUA codepoint), so the pair reads as "one works, the sibling right below it just errors" — extra confusing.
