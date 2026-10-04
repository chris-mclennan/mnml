# tools/gate — merge and gate main

The scripts that land branches on `main` and decide whether `main` may be
pushed. They act on the checkout they live in (the repo root is two levels
above this directory) and expect branch worktrees at `<repo>-worktrees/<branch>`.

**The one rule: never push around them.** `main` reaches origin only through
`merge-batch.sh` or `fix-main.sh`, after a green chain. A red chain is fixed on
`main` and re-gated with `fix-main.sh`; it is never pushed "just this once".

## Order

1. Write `msgs/merge-msg-<branch>.txt` for each branch (the merge commit's
   message; `msgs/` is git-ignored).
2. `tools/gate/merge-batch.sh <branch>...` — merges the branches in order, then
   runs the full chain once and pushes on green.
3. If it stops red, fix `main`, then `tools/gate/fix-main.sh LABEL` to re-gate
   it (LABEL names the logs), and requeue the branches that did not land.

Logs land in `logs/` (git-ignored) and the chain's own scratch in `$CHAIN_TMP`.
Only one batch runs at a time (`/tmp/mnml-batch.lock.d`).

## The scripts

| Script | What it does |
| --- | --- |
| `merge-batch.sh BRANCH...` | Per branch: rebase its worktree on `main` (conflicts through `resolve-loop.sh`), merge `--no-ff` with its message file, remove the worktree, regenerate `docs/commands.md`, then a quick gate (build + ReleaseSafe unit) that stops the queue on red. After the last branch: the full chain, a bundle to `~/Backups/mnml-zig/`, a refusal when origin is ahead of local `main`, the push, and the real-screen tour. Clears a `.zig-cache` over 40 GB first when nothing is building. |
| `fix-main.sh LABEL` | The tail of `merge-batch.sh` alone: full chain, bundle, origin-ahead refusal, push, tour. |
| `chain-scrub.sh` | The full chain: work-data and gate-path audits, fmt, arena audit, `-Dpartial=false`, the heavy phase, glyph audit, the drive build, the size sweep, the sharded corpus, the PTY mouse check, extra integration roots, the bitbucket and jira suites, `run-sh-check`, docs. |
| `heavy-phase.sh` | ReleaseSafe unit, Debug unit and the five cross-target gate builds, in parallel (2+2 wide). |
| `corpus-sharded.sh BIN N OUTLOG` | The e2e corpus as N parallel shards, merged into one `X/Y passed` line. |
| `resolve-loop.sh` | Called by `merge-batch.sh` mid-rebase: keep-both for `docs/` and `CHANGELOG.md`, keep-both plus the pin re-sum for `specs.zig` / `command.zig`, the notch sum for `settings_wheel.test`; anything else stops the queue. |
| `keepboth.py`, `fixpins.sh`, `fixwheel.py` | The three resolvers `resolve-loop.sh` uses. |
| `check.sh` | Fails if any script here still names a scratch directory or a home path. `chain-scrub.sh` runs it beside `work-data-audit.sh`. |

Extra integration roots for the chain (a private integrations repo on this
machine) are read from `extra-roots.local` here (git-ignored) or from
`$MNML_EXTRA_INTEGRATION_ROOTS`; with neither, that step is skipped.
