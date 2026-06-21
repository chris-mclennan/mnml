---
finding: npm-run-hardcoded-dev-script
severity: SEV-3
agent: multilang-dev-user
language: ts
repro: workspace-fixture
---

# `npm.run` is hardcoded to `npm run dev` — no way to invoke other scripts

## Summary

The `npm.run` command always runs `npm run dev`. Its title says "npm: run `npm
run dev` in a pty pane". There is no way to run arbitrary `package.json` scripts
(e.g. `npm run watch`, `npm run preview`, `npm run serve`, `npm run storybook`)
without opening a pty shell and typing manually.

Most TS/JS projects have 5–10 scripts in `package.json`. The hardcoded `dev`
convention covers Vite/Next/CRA/Remix, but common dev stacks like:
- Nx monorepos (`npm run app:serve`)
- Storybook (`npm run storybook`)
- Turborepo tasks (`npm run build --workspace=packages/ui`)

…all have different script names.

## Comparison with cargo.*

`cargo.*` doesn't have this problem because Cargo's commands are universal
(`test`, `build`, `check`, `clippy`) — no project-specific naming. npm scripts
are per-project.

## Suggested fix

1. **Short-term**: Add a `npm.run_script` command that prompts for a script name
   (like `task.run` does), reading `package.json`'s `scripts` field to populate
   a picker.
2. **Longer-term**: `npm.run` could open a picker over `package.json` scripts
   instead of hardcoding `dev`.

## Affected code

`/Users/chrismclennan/Projects/mnml/src/command.rs`, line 3986–3991:
```rust
id: "npm.run",
title: "npm: run `npm run dev` in a pty pane",
run: |app| app.run_npm_subcommand("run dev"),
```

`/Users/chrismclennan/Projects/mnml/src/app/playwright.rs`, line 140–142:
```rust
pub fn run_npm_subcommand(&mut self, subcmd: &str) {
    self.run_manifest_command("package.json", "npm", subcmd);
}
```
