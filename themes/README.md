# Bundled colour schemes

These `*.toml` files are NvChad's [base46](https://github.com/NvChad/base46)
colour schemes, converted from their original Lua form into TOML — the values are
unchanged. Each has a `[base_30]` table (UI-chrome colours, NvChad's naming) and
a `[base_16]` table (`base00`..`base0F`, the syntax palette), plus `name` /
`type` (`dark` | `light`).

`build.rs` enumerates this directory and `src/ui/theme.rs` parses each file into
a `Theme` at first use. To add a theme, drop a `.toml` here in the same shape —
missing colours fall back sensibly, so a partial file still works.

base46 is MIT-licensed (see `LICENSE`); the individual colour schemes credit
their original authors in each file's comment header.
