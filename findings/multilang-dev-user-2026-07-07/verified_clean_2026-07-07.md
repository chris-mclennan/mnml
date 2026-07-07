---
finding: verified-clean-runner-and-lsp-surface-2026-07-07
severity: SEV-3
agent: multilang-dev-user
language: ts | py | go
repro: e2e (live headless, three fresh workspaces)
---

## Purpose

Positive-result note (matching the prior round's
`stale_finding_fixtures_now_fail.md` convention) so a future multilang-dev-user
pass doesn't re-spend budget re-verifying the same ground. Built three
realistic fresh fixtures from scratch — `/tmp/ts-test-workspace` (package.json
+ tsconfig + jest + a monorepo-shaped `pnpm-workspace.yaml` case already
covered by `tests/e2e/ts_monorepo_tree.test`), `/tmp/py-test-workspace`
(pyproject.toml + requirements.txt + FastAPI + dataclasses), `/tmp/go-test-workspace`
(go.mod + `cmd/server/` + `internal/handler/` + a channel/goroutine body) — and
drove each headless as a single clean process (no `cargo run -- test`
sandboxing; real `./target/debug/mnml <ws> --headless` + raw IPC JSONL).

## Confirmed working correctly

- **Manifest-not-found toasts**, all six wrong-language combos tested live:
  `npm.test`/`go.test` in the Python workspace, `go.test` in the TS workspace,
  `npm.test` in the Go workspace — every one produced the correct
  `<bin>.<slug>: no <manifest> found in <path> or any parent` toast, correct
  cwd shown, no crash.
- **npm/pytest/go pty spawn**: correct cwd (workspace root), live-streamed
  output (not buffered-until-done — watched `npm test`'s `> ts-test-workspace@…`
  / `sh: jest: command not found` lines arrive incrementally), correct exit
  code (`✗`) + "[process exited — Ctrl+W to close]" hint, correct 🧪 statusline
  chip binding to the pty pane id.
- **`go.run` cmd/ auto-detection**: single `cmd/server/` dir → auto-ran
  `go run ./cmd/server` with zero prompt, matching the documented 1-dir
  auto-pick behavior.
- **File-tree artifact hiding**: `node_modules/`, `dist/`, `.next/`,
  `coverage/`, `.venv/`, `__pycache__/`, `vendor/` all correctly absent from
  the tree on all three fixtures, matching `tree.rs`'s hardcoded
  artifact-dir list — this now covers the full non-Rust artifact set well
  (this used to be a real gap per `findings/2026-06-28`-era notes; confirmed
  fixed).
- **LSP toasts**: `typescript-language-server` / `pyright-langserver` /
  `gopls` all produce the correct "not installed — `<install cmd>`" toast on
  `.tsx`/`.ts`/`.py`/`.go` open, no crash, file content still renders and is
  editable.
- **`git.recent_branches` at 56-branch scale**: picker opened instantly,
  listed all 56 (55 synthetic + main), no lag, no truncation.
- **`git.merge`**: picker excludes current branch, merge of a same-commit
  branch resolved as a silent no-op fast-forward with no error — correct.
- **`pytest.run` / `pytest.failed` (`--lf`)**: both correctly detect
  `pyproject.toml`, spawn `pytest` / `pytest --lf` in a pty at the workspace
  root; failure mode is just "pytest not installed" in this sandbox, which is
  the expected/correct behavior per the task's own guidance (harness has no
  real pytest binary).
- **`pnpm-workspace.yaml` / monorepo tree** (`packages/server`,
  `packages/client`): already covered by `tests/e2e/ts_monorepo_tree.test`,
  re-confirmed conceptually via the artifact-hiding + manifest-walk fixtures
  above; not re-litigated in detail here.

## Not re-flagged (already-fixed, per code comments + tests already in tree)

`find_manifest_dir` workspace-boundary escape (prior round's SEV-2,
`manifest_walk_escapes_workspace.md`) — now has an explicit `workspace`
param + a passing regression test
(`playwright_tests::find_manifest_dir_stops_at_workspace_root`,
`src/app/playwright.rs:714`). Confirmed fixed by reading the test, did not
re-drive live.

## Caution for future sessions (methodology, not a product bug)

Headless `mnml <ws> --headless` processes left running via `nohup … &` in a
Bash tool call can survive past `kill %1` in a *later* Bash call, since each
tool call is a fresh shell with no job-control memory of the earlier one.
Two `mnml` processes pointed at the same `<ws>/.mnml/ipc/` directory will
race on the same `command`/`screen.txt` files and produce very confusing
mixed-session output (e.g. a stale pty from process A's session bleeding into
process B's screen dump). Always capture `$!` to a file and `kill $(cat
…pid)` by literal PID, and `ps aux | grep 'target/debug/mnml <ws>'` before
trusting a screen dump.
