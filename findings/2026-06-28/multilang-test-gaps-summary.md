---
agent: multilang-dev-user
severity: SEV-2
language: ts/py/go
repro: e2e
---

# Test coverage gaps for 2026-06-28 multilang fixes

Eight new e2e tests were added to cover features that shipped with no
harness verification. All 8 pass.

## New test files added

| File | Feature verified | Fix commit |
|------|-----------------|------------|
| `pytest_runner_requirements_txt.test` | pytest detects `requirements.txt` as project marker | `5d4c4f0` |
| `npm_run_script_validation.test` | `npm.run`/`npm.lint` toast when script not in package.json | `ac96648` |
| `npm_monorepo_nearest_pkg.test` | npm walks up from active editor dir in monorepo | `5d4c4f0` |
| `highlight_tsx.test` | `.tsx` uses `LANGUAGE_TSX` grammar (not typescript) | pre-existing |
| `fold_chord.test` | `Ctrl+Shift+[` fires `editor.toggle_fold`, `Ctrl+Shift+]` fires `editor.unfold_all` | `53c95a4` |
| `tree_refresh_auto_expand.test` | `tree.refresh` auto-expands newly-appeared top-level dirs | `ac96648` |
| `outline_go_receiver.test` | Go outline shows `Router.Handle` (Receiver.Method) | `ac96648` |
| `outline_react_fc.test` | `React.FC<Props>` components appear in TypeScript outline | `ac96648` |

## Pre-existing gaps that remain

- `derive_lsp_language_id` has no unit test (cannot be e2e-verified — LSP
  wire messages aren't observable in headless mode). See separate finding.

- `lsp_unavailable_toast.test` only tests `.ts` files, not `.tsx`. The
  `highlight_tsx.test` above covers the grammar path; the LSP languageId
  path is covered by the unit-test gap finding.
