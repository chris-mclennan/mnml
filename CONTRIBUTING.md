# Contributing to mnml

Thanks for your interest in mnml. This guide covers the workflow, conventions,
and the bits of architecture worth knowing before you change code.

## Getting started

```bash
git clone https://github.com/chris-mclennan/mnml-rs
cd mnml-rs
cargo build
cargo test
```

mnml builds on stable Rust — MSRV **1.87**, edition 2024. A
[Nerd Font](https://www.nerdfonts.com/) helps when running the UI, but isn't
needed to build or test.

## The verification gate

Every change must pass, in order:

```bash
cargo fmt                    # format
cargo build                  # compile clean
cargo clippy --all-targets   # warning-free — the project keeps it clean
cargo test                   # unit + e2e + ipc suites green
```

`cargo clippy --all-targets` being **warning-free** is a hard requirement, not a
nice-to-have. If you're working in mnml itself, the `/verify` skill in
`.claude/skills/` runs the whole gate.

## Architecture spine

A few load-bearing pieces — read [`CLAUDE.md`](CLAUDE.md) for the full design:

- **Pluggable input layer** (`src/input/`) — `Box<dyn InputHandler>` translates
  key events into a closed set of `EditOp`s (interpreted by the single chokepoint
  `Editor::apply`) or escalates to an `AppCommand` / a registered `Command`. The
  editor, buffer, and render layers **never** branch on which handler is active.
- **`Pane` + `Layout` + the `Command` registry** are the rest of the spine.
  `Pane` is the open-thing enum, `Layout` is the split tree, and `Command` is
  what the palette / which-key / keybindings / plugins all hang off.
- **Adding a feature is additive** — register a `Command`, add an `EditOp` or
  `Pane` variant. It should not require special-casing across layers. If you find
  yourself adding `if vim { … }` outside the statusline or cursor-shape code,
  step back: the design exists specifically to avoid that.
- **Headless mode** (`src/headless.rs`) and the **file-IPC channel**
  (`src/ipc/`) share `App` + `ui::draw` with the terminal loop, so headless
  behaviour matches the real UI — that's the substrate for `.test` E2E coverage.
- **No giant files.** `App` state is render-free and lives across
  `src/app/mod.rs` + per-subsystem siblings (`src/app/{bitbucket,github,git,
  lsp,ai,dap,cdp,…}.rs` — 25 files, each owning one cohesive surface).
  `src/tui.rs` is only the crossterm event loop; chrome lives in `src/ui/`;
  other subsystems get their own top-level dirs.
- **Cargo features.** The default build has no optional features. `aws-codebuild`
  adds `Pane::CodeBuilds` + `Pane::LogTail` (AWS CodeBuild + CloudWatch log
  tail, both shelling out to the `aws` CLI; no new crate deps). Gate org-specific
  code in private blit-host binaries rather than adding new features here.
- **Blit-host integrations** (`src/pane_host.rs`, `src/app/blit_host.rs`).
  Out-of-process binaries render into a `Pane::BlitHost` over a Unix socket using
  the `tmnl-protocol` wire format. Opened via `:host.launch <binary>`. Adding a
  new integration requires no changes to mnml — wire up a binary and add a
  `[[ui.launcher_icon]]` config entry.

## Conventions

- Run `cargo fmt` and keep `cargo clippy --all-targets` warning-free before every
  commit.
- Add tests for new behaviour. Pure logic gets unit tests; UI flows get a
  `.test` file under `tests/e2e/`.
- Keep commits small and focused. End commit messages with a
  `Co-Authored-By:` trailer when a change is co-authored.
- Match the style of the surrounding code — comment density, naming, idioms.

## Tests

- **Unit tests** — `cargo test --lib`.
- **End-to-end** — `.test` files under `tests/e2e/` run via `cargo test` and
  `mnml test`. The format is a line-based DSL (`open`, `key`, `type`, `command`,
  `click`, `expect screen …`) driving the real `App` against a virtual backend.
- **IPC** — `tests/ipc.rs` exercises the file-IPC wire format.

## Pull requests

1. Branch from `main`.
2. Make your change with tests; run the verification gate.
3. Open a PR describing the change and how you verified it.
4. CI runs `fmt` + `clippy -D warnings` + `test` — keep it green.

## Reporting bugs & requesting features

Use the [issue tracker](https://github.com/chris-mclennan/mnml-rs/issues). For bugs,
include your OS, terminal, and steps to reproduce — a `.test` file that fails is
the gold standard.

## License

By contributing, you agree that your contributions will be dual licensed under
the MIT and Apache-2.0 licenses, as described in [README.md](README.md#license),
without any additional terms or conditions.
