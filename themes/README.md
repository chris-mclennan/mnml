# Bundled colour schemes

These `*.lua` files are NvChad's [base46](https://github.com/NvChad/base46) theme
definitions, vendored verbatim. mnml's `build.rs` enumerates this directory and
`src/ui/theme.rs` parses each file's `M.base_30` (UI chrome) and `M.base_16`
(syntax) tables into a `Theme` at startup. To add a theme, drop a file here in
the same format.

base46 is MIT-licensed (see `LICENSE`); the individual colour schemes credit
their original authors in each file's header comment.
