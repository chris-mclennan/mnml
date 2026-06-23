# Family theming — one mnml-sourced palette

mnml, mixr, and the `mnml-*` integration siblings all follow **one
palette, sourced from mnml's active theme.** Change mnml's theme and the whole
family retints — within a tick for apps that live-reload.

This is the family convention (CLAUDE.md "Option A — no shared crate"): there is
**no shared theming crate.** Each app carries its own small `theme.rs` (~120
lines) that reads the same file and projects it onto that app's own colour roles.

## Single source of truth

mnml writes its **resolved active theme** to:

```
~/.config/mnml/current-theme.toml      ($XDG_CONFIG_HOME/mnml/… if set)
```

- Written by `theme::write_current()` (`src/ui/theme.rs`) at **startup** and on
  **every theme switch** (`set_theme_silent`, which the picker + toggle funnel
  through). It is always present and always current — even on the built-in
  default — so consumers never have to special-case "no theme configured."
- Format is the same `[base_30]` + `[base_16]` TOML mnml's own `parse_theme`
  reads (round-trip-tested), so it is a normal mnml theme file.
- Do not hand-edit; it's regenerated on launch.

## The role contract (`[base_30]`)

Consumers map the keys they need. The load-bearing ones:

| key                | role                                  |
|--------------------|---------------------------------------|
| `white`            | primary text (fg)                     |
| `black`            | editor/body background                |
| `darker_black`     | darkest chrome (rails, overlays)      |
| `one_bg`/`one_bg2` | panel bg / selected-row bg            |
| `light_grey`       | **dim / secondary text** (the comment role) |
| `grey` / `grey_fg` | borders, inactive                     |
| `red` `green` `yellow` `blue` `cyan` `orange` `purple` `teal` | semantic accents |

`light_grey` (also emitted as `grey_fg2`) is the dim role — the one that was
"too dark" before; bumping mnml's `comment` lifts it everywhere at once.

`[base_16]` (`base00`..`base0F`) carries the syntax palette for apps that need it.

## How a consumer follows it

Pattern (mirror what mixr does in `mixr/src/theme.rs`):

1. On startup, read `~/.config/mnml/current-theme.toml`, parse `[base_30]`, and
   build a local `Palette` of `ratatui::Color::Rgb` values (one field per role
   the app actually uses). Store behind `OnceLock<RwLock<Palette>>`.
2. **Live reload:** once per tick, `stat()` the file; on mtime change, re-parse
   and swap the palette (cheap — full parse only when it actually changes).

Crossterm rendering: replace literal `Color::DarkGray`/etc. sites with
`palette().dim`/etc. Mechanical; do the dim sites first (highest value).
