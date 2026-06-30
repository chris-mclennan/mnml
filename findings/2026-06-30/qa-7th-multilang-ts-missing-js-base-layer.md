---
agent: multilang-dev-user
severity: SEV-2
language: typescript
repro: e2e
---

# `.ts`/`.tsx` highlighting missing JavaScript base layer

## Summary

`tree_sitter_typescript::HIGHLIGHTS_QUERY` is a 35-line TypeScript extension
query that only covers TypeScript-specific patterns (type identifiers, type
arguments punctuation, variable parameters, TS-specific keywords). It is
designed to be **layered on top** of the JavaScript grammar's query — but
mnml uses it standalone. JavaScript base patterns in `.ts`/`.tsx` files
receive no color:

- `import`, `const`, `let`, `var`, `function`, `return`, `async`, `if`,
  `for` — all render as plain text
- String literals — no color
- Number literals — no color
- Comments (`// ...`) — no color
- Boolean literals — no color

## Repro

Test file (8 lines) that produces only 8 spans when the JS base layer is absent:

```
write src/util.ts "import { readFile } from 'fs';\n\nconst MAX_SIZE = 1024;\n\n// Read bytes from path\nexport async function readBytes(path: string): Promise<Buffer> {\n  return readFile(path);\n}\n"
open src/util.ts
expect highlights at_least 15   ← FAILS, got 8
```

The 8 spans are TypeScript-extension-only hits: `MAX_SIZE` (capitalized id
→ @type), `string`/`Promise`/`Buffer` (predefined/type), `export` keyword,
`path` (variable.parameter), type_argument `<`/`>` punctuation.

Confirmed failing e2e test at `/private/tmp/claude-501/.../highlight_ts_js_base.test`.

## Root cause

`src/highlight.rs` lines 1042-1051:

```rust
"ts" | "cts" | "mts" => (
    tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
    tree_sitter_typescript::HIGHLIGHTS_QUERY,  // ← 35-line extension only
    "",
),
"tsx" => (
    tree_sitter_typescript::LANGUAGE_TSX.into(),
    tree_sitter_typescript::HIGHLIGHTS_QUERY,  // ← same, no JS base
    "",
),
```

`tree_sitter_javascript::HIGHLIGHT_QUERY` (204 lines, covers all JS base
patterns) is never combined with the TypeScript extension.

## Fix direction

For `.ts`: concatenate `tree_sitter_javascript::HIGHLIGHT_QUERY` +
`tree_sitter_typescript::HIGHLIGHTS_QUERY` as the query source, using
`LANGUAGE_TYPESCRIPT` to parse. The `build_config` return type needs to
support an owned `String` (or Box<str>) for the query, since concat is
not const-available at compile time. The `LangConfig` cache already leaks
its contents, so a leaked `String` would work.

For `.tsx`: additionally include `tree_sitter_javascript::JSX_HIGHLIGHT_QUERY`.

## Existing test gap

`highlight_tsx.test` checks `expect highlights at_least 6` — achieved solely
via TypeScript-extension patterns, masking the total absence of JS base
highlighting and JSX tag coloring. The threshold should be raised to ≥20
for a well-highlighted tsx file.
