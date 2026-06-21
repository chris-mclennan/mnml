---
finding: runners-npm-priority-no-disambiguation
severity: SEV-3
agent: power-user-lsp-cheat-test
repro: code-review
---

# Test runner palette commands don't disambiguate across polyglot workspaces

## Surface

`src/app/playwright.rs::run_npm_subcommand / run_cargo_subcommand /
run_pytest / run_go_subcommand` + `command.rs:3944-4060`
(commit `c5b459c`).

## What happens

Each runner family checks ONLY its own manifest:

- `:cargo.test` → `Cargo.toml` at workspace root
- `:npm.test` → `package.json` at workspace root
- `:pytest.run` → `pyproject.toml`/`setup.py`/`tests/` at workspace root
- `:go.test` → `go.mod` at workspace root

…and palette commands for them are ALL registered unconditionally —
nothing is gated on actual presence. Consequences:

1. **Polyglot workspaces are surprising**. mnml's own repo has both
   `Cargo.toml` AND `package.json` (the Astro site at `site/`).
   Wait, no — `package.json` is inside `site/`. But a TYPESCRIPT
   SDK + Rust core repo (a common shape) has both at the root.
   `:npm.test` would just run, and `:cargo.test` would also run,
   and there's no signal that one is the "primary" path.

2. **Command palette discoverability**. The "(unbound)" section of
   the cheatsheet (commit `1346dba` adds this view) shows every
   `cargo.*` / `npm.*` / `pytest.*` / `go.*` command regardless of
   whether the workspace can use them. The pytest user sees 5 cargo
   commands and 4 go commands they can't run. With ~20 new commands
   added in `c5b459c`, the palette feels noisy in non-polyglot
   workspaces.

## Why it matters

It's not a correctness bug; it's discoverability rot. The palette
is the entry point for unbound commands, and the cheatsheet's
`(unbound)` section was added explicitly as a discoverability
surface (`src/cheatsheet.rs:71-72` comment). If 4 of 20 commands
shown can't actually fire, that signal is corrupted.

## Repro

Code-review finding. Run `:view.cheatsheet` in any workspace and
scroll to `(unbound)` — every runner command is listed regardless
of detect state.

## Suggested fix

Two cheap moves:

1. At cheatsheet build time, *gate* the `(unbound)` entries that
   correspond to runner commands by manifest presence: `npm.*`
   commands hidden when no `package.json`; etc.
2. In `run_*_subcommand`, hint at the *real* path when toasting
   ("no Cargo.toml at /abs/path — try `:set workspace /repo/root`").

The first is a small `Command` registry change (or a build-time
filter in the cheatsheet); the second is a 2-line toast tweak.

## Severity

SEV-3 — discoverability rot, not a bug. But the `(unbound)` section
specifically exists to be the discoverable "everything you can do"
view; filtering it on actual usability would meaningfully sharpen
the signal.
