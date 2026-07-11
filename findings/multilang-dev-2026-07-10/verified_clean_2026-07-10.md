---
finding: verified-clean-runner-git-http-surface-2026-07-10
severity: SEV-3
agent: multilang-dev-user
language: ts | py | go
repro: e2e (live headless, three fresh workspaces + real live git ops)
---

## Purpose

Positive-result note (matching the `verified_clean_2026-07-07.md` /
`stale_fixtures` convention) so a future multilang-dev-user pass doesn't
re-spend budget on ground already re-confirmed. Built fresh fixtures —
`/tmp/ts-test-workspace2` (package.json + tsconfig + pnpm-workspace.yaml
monorepo with `packages/server` + `packages/client`, each own
package.json/script), `/tmp/py-test-workspace2` (pyproject.toml +
requirements.txt + dataclasses/f-strings), `/tmp/go-test-workspace2`
(go.mod + `cmd/server/` + `internal/handler/` with generics + channel) —
and drove each as a standalone `./target/debug/mnml <ws> --headless` +
raw file-IPC JSONL (current uncommitted working tree, not a clean
checkout — see caution note below).

## Confirmed working correctly (all newly re-driven, not just read from code)

- **`go.test` manifest-not-found toast** fires correctly from the TS
  workspace root: `go.test: no go.mod found in /private/tmp/ts-test-workspace2
  or any parent`.
- **`npm.test` monorepo context**: with no active editor, ran at the
  workspace root (`npm test` → root package.json's `jest` script, `sh:
  jest: command not found`, correct cwd). After opening
  `packages/server/src/index.ts`, a follow-up `npm.test` correctly
  re-resolved to `packages/server/package.json`'s `vitest run` script
  instead of the root — monorepo-context walking still works.
- **`pytest.run` / `pytest.failed`**: both correctly found
  `pyproject.toml` at the Python workspace root and spawned `pytest` /
  `pytest --lf` respectively (confirmed the `--lf` flag literally on the
  pty's title bar: `pytest --lf ✗`).
- **`go.vet`**: ran `go vet ./...` at the workspace root.
- **`go.run` cmd/ auto-detection**: single `cmd/server/` dir → silently
  ran `go run ./cmd/server`, zero prompt — matches documented 1-dir
  auto-pick behavior.
- **File-tree artifact hiding**: `node_modules/`, `dist/`, `.next/`,
  `__pycache__/`, `.venv/`, `vendor/` all absent from their respective
  trees, confirmed by grepping fresh `screen.txt` dumps (not reused from
  a prior round).
- **`git.merge`**: picker correctly excludes current branch and lists
  the real candidate; the merge (via the new button-dialog confirm —
  `[ Merge ] [ Cancel ]`, default focus on Cancel, matching the
  established "destructive-action safety idiom" documented at
  `src/app/mod.rs:13436`) actually performs `git merge` on disk when the
  Merge button is selected (`Left`+`Enter`) — verified against real
  `git log` on the fixture repo, not just the toast. Plain `Enter`
  correctly no-ops into Cancel by design; this is consistent with the
  rest of the confirm-dialog family, not multilang-specific, not flagged
  as a bug.
- **`git.rebase`**: picker title correctly reflects the *live* current
  branch (`Rebase topic onto…`) even after the branch was changed
  entirely outside mnml via raw `git checkout` — confirms mnml's branch
  cache refreshes off a live check rather than a stale snapshot from
  session start. Candidate list correctly includes all non-current local
  branches (main, feature-a, feature-b).
- **`git.worktree_add` path autocomplete**: typing `~/Projects/mnml`
  live-populated a dropdown of sibling repos under `~/Projects/`
  (`mnml`, `mnml-aws-amplify`, `mnml-aws-cloudwatch-logs`,
  `mnml-aws-codebuild`, …) — `~` expansion + prefix match both work from
  a non-Rust workspace's prompt.
- **`.curl` file in a TS workspace root**: opened cleanly as a Request
  pane with the expected "not sent yet · press `r` to fire" state — no
  workspace-relative path resolution issue.
- **`lsp.inlay_hints_toggle`**: fires and toasts `inlay hints: off` from
  a TS workspace with no LSP attached (config-level toggle, independent
  of LSP availability) — behaves the same as on a Rust workspace.

## Not re-driven live (known-cut or requires live network/binaries)

- Actual LSP hover/completion/goto-def content (typescript-language-server
  / pyright / gopls not installed in this sandbox — the "not installed"
  toast is the correct and only testable behavior per the task's own
  known-cuts list).
- `ai.write_commit_message` / `ai.write_branch_name` / `ai.recompose_branch`
  — these shell out to `claude -p` and need real network + auth; not
  fired to avoid burning API budget on a purely presentational check.
  Prior round already flagged one real bug here
  (`multilang-dev-user-2026-07-07/ai_commit_message_agentic_preamble_leak.md`)
  — check whether that's landed before re-testing.
- `http.history_global` cross-workspace visibility — no entries existed
  to check because firing an actual HTTP request needs a live server;
  opening the picker with zero history is not a meaningful test.
- Syntax-highlighting token *colors* (tsx JSX tags, Python f-string
  interpolation braces, Go generics `[T any]`) — `screen.txt` is a plain
  text dump with no style info; would need `./run.sh shot` (real ghostty
  pixels) to verify, out of scope for this pass's time budget.

## Caution for future sessions

This pass ran against the **current uncommitted working tree**
(`git status` showed `src/app/git.rs`, `src/app/mod.rs`,
`src/app/picker.rs`, `src/command.rs`, `src/tui/handlers/overlay.rs`,
`src/tui/mouse/mod.rs`, `src/ui/prompt.rs` all modified — mid-flight
"confirm dialogs become button dialogs" work per recent commit
messages), not a clean `main` checkout. The git.merge confirm-dialog
default-focus behavior documented above is a product of that WIP; if a
later session sees it land differently (e.g. Enter directly merging
again), that's expected churn, not a regression to chase.
