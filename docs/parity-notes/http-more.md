# Parity notes — branch `http-more` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| HTTP activity-bar panel (seven sections + the `/` filter) — L | remaining | done | `src/app/http_panel.zig` (unit tests: filter across sections, collapse, activate, headless paint); `tests/e2e-zig/http_panel.test` |
| Side-by-side request edit split (`http.toggle_edit_split` is a stub) — M | remaining | done | `src/app/request_pane.zig` test "split: toggling picks a second tab…"; `src/ui/request_view.zig` test "draw: the edit split paints both halves…"; `tests/e2e-zig/http_edit_split.test` |
| Inline `{{VAR}}` highlighting, click-to-definition line, hover, the quick-fix menu — M | remaining | done | `src/app/http.zig` tests "vars: tokens classify against the env…" and "vars: the editor hook…"; `src/ui/request_view.zig` split/var test; `tests/e2e-zig/http_vars_inline.test` |
| True SSE streaming (the parser exists; the send path reads to the end) — M | remaining | done | `src/app/http.zig` tests "stream: an event-stream lands event by event…" and "stream: http.cancel stops a stream…" (commit 3e85b6a) |
| Pre / post-request scripts (`@set-*`, `@assert`, `@capture`) — M | remaining | done | `src/http/script.zig` tests; `src/app/http.zig` test "directives: @set-* reach the wire…" (commits 330ec81, 1c4d5e1) |
| Browser inspectors' type-to-narrow filters; live DOM highlight — S | remaining | done | commit c97ea59 (`src/app/browser_pane.zig`, `src/ui/browser_view.zig`) |

## `## HTTP request client` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Pre / post-request scripts | missing | done | `src/http/script.zig`, `cmd_http.runScript` | `@set-*` before the send, `@assert` / `@capture` after, per chain step |
| Side-by-side edit split | missing | done | `RequestPane.split*`, `request_view.drawTabContent` | pane state; divider drags; `⇔` chip; `http.toggle_split_orientation` cycles auto / vertical / horizontal |
| `{{VAR}}` inline highlight | missing | done | `request_view.paintVarsOnField / paintVarsOnLine`, `editor_view` hook | `syntax.variable` when resolved, `error_fg` when not |
| `{{VAR}}` click → definition | partial | done | `http.jumpToVarDef` | lands on the `KEY=` line (`env.lineOfKey`); at the end with a toast when undefined |
| `{{VAR}}` right-click quick-fix | partial | done | `http.openQuickFixMenu`, `http.quick_fix` | Define in env… / Jump to definition / Pick env… / Inline value / Copy variable name |
| `{{VAR}}` hover | missing | done | `request_view.drawVarTip`, `http.drawEditorVarTip` | masked (`••••••••`) for `# @secret` names and credential-shaped names |
| HTTP activity-bar panel (7 sections) | missing | done | `src/app/http_panel.zig`, `PanelId.http` | COLLECTIONS / ENVS / CHAINS / MOCKS / COOKIES / RECENT / CAPTURED |
| HTTP panel `/` filter | missing | done | `http_panel.rebuild` | one filter across every section; honest header counts |
| SSE streaming | partial | done | `http.handleStream`, `client.zig` streaming | live chunks; `http.cancel` stops one |

Rows that stay as they are: the green `+` chip in the INTEGRATIONS rail
(the panel's row menus and `http.new_request` cover it), the per-field
title on the request right-click menu.

## Counts

`## HTTP request client` in the summary table moves from
31 done / 4 partial / 1 cut / 7 remaining to 40 done / 0 partial / 1 cut /
2 remaining (the `+` chip and the per-field menu title). Command ids:
830 (four `{{VAR}}` commands, three panel commands), every one with a
runner; `docs/commands.md` regenerated.

## Checks run

- `zig build test` (Debug and `-Doptimize=ReleaseSafe`): 747 pass, 1 skipped.
- `mnml-zig test` (the whole corpus): 231/232 — the one failure is
  `settings_persist_to_workspace.test`, which asserts TOML by design.
- `mnml-zig test tests/e2e/http`: 32/32.
- `mnml-zig test --gate`: 47/47; `--gate --sizes 80x24,120x40,200x60`: 141/141.
- Break-checks: the panel filter's "drop an emptied section" line
  commented out → `http_panel` filter test fails; the secret mask in
  `http.varTokens` replaced by the raw value → the `http.zig` vars test
  fails. Both confirmed in the file (`grep BREAK`) before the run and
  restored from a scratch copy after.
