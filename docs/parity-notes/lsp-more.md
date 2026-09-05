# Parity notes — branch `lsp-more` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| Inlay hints (the toggle is a stub), code lens, semantic tokens, document colors, document links, on-type formatting, `willSaveWaitUntil`, range formatting — S each; semantic tokens M | remaining | done | `src/app/lsp_decor.zig` test "through the fake server: hints and swatches paint…"; `src/app/lsp_semantic.zig` test "through the fake server: a full reply's tokens layer…"; `src/app/lsp_format.zig` test "through the fake server: on-type formatting…"; `src/ui/editor_view.zig` tests "virtual text paints before its grapheme…" and "a virtual line paints above its line…"; `src/highlight/engine.zig` test "layerSpans…"; `src/lsp/semantic.zig` (legend, decode, delta); `src/lsp/types.zig` readers test |
| Rename preview / cross-file confirmation pane — S | remaining | done | `src/app/lsp_rename.zig` test "through the fake server: a rename over two files opens the preview…" |
| External linters and formatters (`Config.linters` / `formatters` are parsed and never read) — M | remaining | done | `src/lsp/tools.zig` tests (builtin table, `{file}`, the five parsers + the `pattern` template); `src/app/lsp_format.zig` tests "an external formatter runs stdin → stdout or in place…" and "an external linter runs on a worker…"; `src/app/lsp.zig` test "diagnostics from a server and a linter merge sorted…"; `tests/e2e-zig/format_external_zig_fmt.test` |

## `## Language intelligence (LSP)` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| External linters | missing | done | `src/lsp/tools.zig`, `lsp_format.lintOnHook / lintPath / lintWorker` | on open and on save, a worker per run; findings land beside the server's through the `.lsp` lane as server id 0 |
| Rename — inline preview + confirmation pane | missing | done | `src/app/lsp_rename.zig` | the confirmation box with per-file toggles, hunk rows `Lnn  before → after`; a single-file rename still applies at once. Not done, by design: the Rust overlay that repaints every occurrence while the prompt is open — the box's hunk rows carry the before/after instead |
| Inlay hints | missing | done | `lsp_decor.onFrame / requestHints / virtualTextFor`, `editor_view.Doc.virtual_text` | visible window ±1 screen, idle-debounced (250 ms), stale sets not painted; `lsp.inlay_hints_toggle` live; `editor.inlay_hints` |
| Semantic tokens | missing | done | `src/lsp/semantic.zig`, `src/app/lsp_semantic.zig`, `engine.layerSpans` | full + `full/delta` (+ `range` when that is all a server offers); legend decoded to theme roles; laid OVER the tree-sitter spans; `editor.semantic_tokens` |
| Document colors | missing | done | `lsp_decor.virtualTextFor` | a `■ ` swatch cell before the literal, in its colour (`# ` under `--ascii`) |
| Code lens | missing | done | `lsp_decor.virtualLinesFor / runLens`, `editor_view.Doc.virtual_lines` | a row above the target; click, `lsp.code_lens_run`, or Enter in vim Normal runs it; `codeLens/resolve` for a lens without a command; `editor.code_lens` |
| Document links | missing | done | `lsp_decor.linkUnderlinesFor / linkAtCursor` | single underline in the accent colour (a diagnostic's squiggle wins an overlap); `gx` (`editor.open_url_at_cursor`) opens the server's target, else a `scheme://` token under the cursor |
| On-type formatting | missing | done | `lsp_format.onTyped` | the server's trigger characters, behind `editor.format_on_type` |
| `willSaveWaitUntil` | missing | done | `lsp_format.onSavePre / handleResponse` | behind `editor.will_save_wait_until`; the reply's edits are applied and the buffer written again (the hook cannot hold the write — D3) |
| External formatters | missing | done | `src/lsp/tools.zig`, `lsp_format.formatExternalPane` | stdin → stdout, or `in_place` on `{file}`; `lsp.format` / `editor.format` prefer the server and fall back to the tool; `editor.format_external` always the tool; format-on-save uses the tool when no server formats |
| Formatting — LSP | done | done | `lsp_format.formatSelection` | gains range formatting: `lsp.format_selection` on a visual selection |

## Counts

`## Language intelligence (LSP)` in the summary table moves from
23 done / 0 partial / 0 cut / 10 remaining to 33 done / 0 partial / 0 cut /
0 remaining. Command ids: 883 (`lsp.format_selection`, `lsp.code_lens_run`
added on top of main's 881; `editor.format_external`, `editor.lint_external` and
`editor.open_url_at_cursor` had no runner and now do); `docs/commands.md`
regenerated.

## Checks run

- `zig fmt --check` clean; `zig build test` (which now carries the
  Phase-0 gate) in Debug and `-Doptimize=ReleaseSafe`: 864 pass,
  1 skipped, gate 47/47 — on main after the `panels` merge (b17e594),
  which this branch was rebased onto last.
- `mnml-zig test` (the whole corpus): 241/242 — main's count plus the
  two scripts below; the one failure is
  `settings_persist_to_workspace.test`, which asserts TOML by design
  (`zig build check` skips it by name).
- `mnml-zig test --gate`: 47/47; `--gate --sizes 80x24,120x40,200x60`: 141/141.
- `tests/e2e-zig/lsp_more_no_server.test`, `tests/e2e-zig/format_external_zig_fmt.test`.
- Break-checks (`tools/break-check.sh`): the delta sort in
  `semantic.applyDelta` flipped to ascending → "a delta splices from the
  highest start down" fails; the too-short-line refusal in
  `lsp_rename.writeClosed` flipped (`<` → `>`) → "a rename over two files
  opens the preview" fails at the `multiShort` step. Both confirmed
  changed in the scratch copy by the tool (exit 2 otherwise).
  Both first reported "still passes" — `-Dtest-filter` only sees a
  file's tests when a `test {}` block references the file, and the
  six new modules were file-scope imports only (the full suite ran
  them regardless; a planted failing canary proved both halves). The
  `test {}` block at the end of `src/app/lsp.zig` is what makes them
  filterable; after it, both break-checks fail as they should.
