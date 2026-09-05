---
severity: SEV-1
status: open
---

# `lsp.references` and `lsp.symbols` silently do nothing for TypeScript (list-shaped LSP results never render)

## Summary

With `typescript-language-server` genuinely attached (confirmed via working
`lsp.hover` and `lsp.goto_definition`), invoking `lsp.references` ("find
references", the vim `g r` / `shift+f12` command) or `lsp.symbols` ("symbols
in this file → picker") on a TypeScript symbol produces **zero visible
effect**: no picker opens, no toast fires, `rightPanelVisible` stays
`false`, and the pane list is unchanged. The command ack in `events.jsonl`
reports `"ok":"true"`, so the command dispatch succeeds — the LSP
request/response/render pipeline for *list-shaped* results appears to be
broken, while single-location results (hover, goto-definition) and the
graceful-empty-state path (`lsp.completion` → `"no completions"` toast) all
work correctly.

This is a core, documented, "done"-status LSP feature
(`docs/PARITY.md` doesn't list find-references/symbols as partial or
missing) that is completely non-functional, with no error signal to tell
the user anything went wrong — worse than the graceful failure other LSP
commands show.

## Repro (verified twice from fresh launches)

Workspace: `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt-py/ts-app`
(`package.json` + `tsconfig.json` present; `typescript-language-server` on
PATH).

```
MNML_DATA_ROOT=<scratch>/hunt-py-data MNML_COLS=120 MNML_ROWS=40 \
  /Users/chrismclennan/Projects/mnml-zig/zig-out/bin/mnml-zig \
  --headless --input standard \
  /Users/chrismclennan/Projects/mnml-zig-worktrees/hunt-py/ts-app
```

`src/util.ts` line 3: `export function formatUser(u: User): string {` —
`formatUser` is imported and called from `src/index.ts` (confirmed via a
successful `lsp.goto_definition` in the same session, landing exactly on
this declaration).

IPC command sequence (via `<ws>/.mnml/ipc-zig/command`):

```json
{"cmd":"open","path":"src/util.ts"}
{"cmd":"wait_ms","ms":1500}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"down"}
{"cmd":"key","key":"right"}   // x17, lands cursor at line 3, col 18 — inside "formatUser"
{"cmd":"run-command","id":"lsp.references"}
{"cmd":"wait_ms","ms":1000}
{"cmd":"snapshot"}
```

`status.json` after the sequence:

```json
{"focus":"pane","activePane":0,"activeFile":".../src/util.ts","cursor":{"line":3,"col":18},"mode":"none","rightPanelVisible":false,"rightPanelPanes":[],"panes":[{"title":"util.ts","dirty":false}],"quit":false}
```

`screen.txt` is unchanged before/after — no picker, no toast:

```
 ≡                                            search files · run commands                                         ✳  ▤
 ● ts-app                     │ util.ts   +                                                               src › util.ts
  packages                   │   1 import type { User, Role } from "./types";
    api                      │   2
    web                      │   3 export function formatUser(u: User): string {
  src                        │   4   return `${u.name} <${u.email ?? "no-email"}>`;
    components               │   5 }
     index.ts                 │   6
```

Same exact symptom for `lsp.symbols` run immediately after in the same
session (also `ok:"true"`, zero visible change).

## Contrast — what DOES work in the same session

- `lsp.hover` on `formatUser`/`ExternalWidget` → correct popup with type
  signature (`(alias) function formatUser(u: User): string`).
- `lsp.goto_definition` on a cross-file (`index.ts` → `util.ts`) and
  cross-`.d.ts` (`index.ts` → `vendor.d.ts`) reference → lands the cursor
  exactly on the target symbol both times.
- `lsp.completion` in a spot with no valid completions → correctly shows a
  `no completions` toast (graceful empty state, unlike references/symbols'
  total silence).
- `lsp.diagnostics` → correctly opens a `DIAGNOSTICS (4)` panel listing real
  `tsc` errors.

So the LSP connection, position-based requests, and even one other
list-shaped feature (diagnostics) work. Only `lsp.references` and
`lsp.symbols` — both of which return LSP *array* results that should open a
picker — are silent no-ops. This points at something specific to how those
two commands' array responses are parsed or handed to the picker overlay,
not a general LSP-attach problem.

## Expected vs actual

- Expected: `lsp.references` opens a references picker/list (or, with zero
  results, a "no references found" toast). `lsp.symbols` opens a file
  symbols picker.
- Actual: both commands ack `ok:"true"` and do nothing observable at all.

## Command ids

`lsp.references`, `lsp.symbols`
