# Parity notes — branch `misc` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| `ai.apply` as a reviewed diff (today it splices the first code block) — S | remaining | done | `src/app/ai_apply.zig` tests "the line diff…", "result assembles accepted hunks…", "ai.apply opens the review pane; skipping a hunk applies the rest as one undo step"; `src/ui/ai_apply_view.zig` paint test |
| AI launch profiles (`[[launch_profile]]`, chip right-click, the `wrapper` shim) — M | remaining | done | `src/app/launch_profiles.zig` tests "shim text…", "writeShim lands an executable file…", "launch: the built-in is the bare binary…", "setDefault persists…"; `Config.LaunchProfile` |
| Pty session strip, `$` suffix and close button on pty tabs, `:bn` / `:bp` skipping ptys, `term.rename`, `term.scratch_toggle` — S | remaining | done | `tests/e2e-zig/pty_tabs.test`; `src/ui/bufferline.zig`, `src/app/cmd_term.zig`, `src/app/cmd_buffer.zig` tests (commit 1235483) |
| Playwright runner, grouped results, trace viewer, flaky dashboard — L | remaining | done | `src/app/tests_pane.zig` (parser fixture, rows, `handle`), `src/app/flaky.zig` (history, ZON, `flaky.show`), `src/ui/{tests_view,flaky_view}.zig`; `tests/e2e-zig/{playwright_pane,flaky_dashboard}.test` |
| The `.test` corpus under `zig build test` (today `mnml-zig test`; `zig build check` runs the gate) — S | remaining | done | `build.zig` `── e2e ──` blocks: `zig build e2e`, the gate under `test`, the full corpus under `check`, `-Dtest-filter` → `--filter`; `src/e2e/runner.zig` test "runPath: --filter keeps…" |
| IPC tier-2 app effects: `statusline-set-segment` / `-clear-segment`, `open-pty`, `set-activity-badge`, `notify` fidelity — S–M | remaining | done | `src/ipc/effects.zig` tests; `src/ipc/golden/tier2.{commands,events}.jsonl` + `src/headless.zig` test "tier-2 golden…"; `src/ui/statusline.zig` test "host segments…" |
| Glyph baking / audit tooling (not the SVG preview, which is cut) — M | remaining | done | `tools/glyph_audit.zig` (`zig build glyph-audit`), `data/nerd-glyphnames.json`; its three tests, one walking the real `src/` |
| `--startup-picker` flag and the `mnml.app` bundle — S | remaining | done | `src/main.zig` test "--startup-picker is MNML_STARTUP_PICKER=1…"; `dist/macos/{Info.plist,launcher.sh,build-app.sh}`; `scripts/package.sh --macos-app` |

## `## AI` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Apply as a reviewed diff | partial (splices the first block) | done | `Pane.ai_apply`, `ai_apply.zig` | per-hunk accept / skip; one `App.splice`, so undo is one step |
| Launch profiles | missing | done | `launch_profiles.zig`, `Config.Ai.launch_profiles` / `default_profile` | the chip menu's *New session:* / *Default:* lanes; the `mnml-ai-<name>` shim |

## `## Terminal` table

| Row | Was | Now | Where |
| --- | --- | --- | --- |
| Pty session strip / `$` tabs / close `×` | missing | done | `bufferline.zig` (`Tab.kind`, `HitTarget.tab_close`) |
| `:bn` / `:bp` skip terminals (`!` walks all) | missing | done | `cmd_buffer.cycleAny` |
| `term.rename`, `:rename` | missing | done | `cmd_term.zig` |
| `term.scratch_toggle` | missing | done | `cmd_term.zig`, `App.scratch_pty`, `Kind.scratch` |

## `## Testing & quality` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Playwright runner | missing | done | `tests_pane.zig` (`test.run_playwright*`) | Zig-only ids; the generic `test.run_*` stay the project runners |
| Grouped results pane | missing | done | `ui/tests_view.zig` | file headers, `s` for slowest-first |
| Jump-to-source | missing | done | `tests_pane.jumpTo` | Enter, or a second click |
| Trace timeline viewer | missing | done (launcher) | `tests_pane.openTrace` | `npx playwright show-trace` in a pane below; the *open trace* row / `t` |
| Flaky dashboard | missing | done | `flaky.zig`, `ui/flaky_view.zig` | `<ws>/.mnml/flaky.zon`, most flips first |
| Runs under the unit-test harness | partial | done | `build.zig` | `zig build test` runs the gate; `zig build check` the full corpus (minus the TOML-by-design file); `zig build e2e` |

## `## Headless, IPC & extensibility` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Tier-2 toasts / sticky / progress / notify | done (notify degraded) | done | `ipc/effects.zig` | `notify`: toast + `osascript` / `notify-send` / PowerShell in the terminal loop; `error` pins under `source` |
| Tier-2 statusline segment / open-pty / activity badge | partial | done | `ipc/effects.zig`, `statusline.Info.dyn_*` | every field; priority pack; `click_command`; badges for every Rust section |
| Glyph baking / audit tooling | missing | done | `tools/glyph_audit.zig` | `zig build glyph-audit`; the SVG preview stays cut |
| `--startup-picker` flag | missing | done | `main.zig` | sets `MNML_STARTUP_PICKER=1` for the process |
| `mnml.app` launcher default | missing | done | `dist/macos/` | ghostty first, Terminal.app else; the picker on |

## Counts

Command ids: 836 (six Playwright commands), every one with a runner
(`test.heal` gained its runner); `docs/commands.md` regenerated.

## Checks run

- `zig build test` (Debug, now including the gate 47/47) and
  `-Doptimize=ReleaseSafe`: 780 tests, 779 pass, 1 skipped.
- `mnml-zig test` (the whole corpus): 234/235 — the base 231/232
  plus `pty_tabs`, `playwright_pane`, `flaky_dashboard`; the one
  failure is `settings_persist_to_workspace.test`, which asserts
  TOML by design.
- `mnml-zig test --gate --sizes 80x24,120x40,200x60`: 141/141.
- `zig build glyph-audit`: 8 sites, 18 assertion lines, 0 without a
  fallback, 0 unknown.
- Break-checks (`tools/break-check.sh`, which refuses a break that
  did not land, nor one that does not compile): the pack's
  `min_width` drop loosened from `< need + 2` to `< need` → "pack:
  priority…" fails; `wobbly()`'s `and` made `or` → "history:
  records…" fails. Both files restored by the script.
- Finding, not fixed (outside the touch list): the pty reader is a
  detached thread sharing a refcount with its session; a
  leak-checked test that closes a pty whose child already exited can
  race the reader's `Shared.release` (seen once in ReleaseSafe with
  `open-pty ls -la`). The golden runs `sleep 30`, as `pty_tabs.test`
  does.
