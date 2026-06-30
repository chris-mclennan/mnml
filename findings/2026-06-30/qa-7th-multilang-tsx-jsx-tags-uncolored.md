---
agent: multilang-dev-user
severity: SEV-2
language: typescript
repro: e2e
---

# JSX tags (`<div>`, `<h1>`, etc.) are not highlighted in `.tsx`/`.jsx` files

## Summary

`tree_sitter_javascript::JSX_HIGHLIGHT_QUERY` (8 lines, provides `@tag` and
`@attribute` captures for JSX elements) is exported by the JS crate but is
never used by mnml for any extension. JSX element names and attributes
render as plain text in `.tsx` files even though the TSX grammar parses them
correctly.

## Repro

```
write src/Component.tsx "import React from 'react';\n\nexport function Hero({ title }: { title: string }) {\n  return (\n    <section className=\"hero\">\n      <h1>{title}</h1>\n      <p>Welcome</p>\n    </section>\n  );\n}\n"
open src/Component.tsx
expect screen contains "<section"
expect screen contains "<h1>"
expect highlights at_least 12   ← FAILS, got 4
```

A 10-line tsx file with JSX `<section>`, `<h1>`, `<p>`, `className` attribute
only produces 4 spans. All JSX markup is plain text.

Confirmed failing e2e test at `/private/tmp/claude-501/.../highlight_tsx_jsx_tags.test`.

## Root cause

`tree_sitter_javascript` 0.25.0 exports two constants:
- `HIGHLIGHT_QUERY` — JS base patterns (no JSX)
- `JSX_HIGHLIGHT_QUERY` — JSX-specific `@tag` + `@attribute` captures

mnml uses only `HIGHLIGHT_QUERY` for `.js`/`.jsx`, and uses
`tree_sitter_typescript::HIGHLIGHTS_QUERY` (which has no JSX queries at all)
for `.tsx`. The `JSX_HIGHLIGHT_QUERY` is never referenced anywhere in mnml.

The JSX captures that would fire if the query were included:
```scheme
(jsx_opening_element (identifier) @tag (#match? @tag "^[a-z][^.]*$"))
(jsx_closing_element (identifier) @tag (#match? @tag "^[a-z][^.]*$"))
(jsx_attribute (property_identifier) @attribute)
```

## Affected extensions

- `.tsx` — JSX tags uncolored (compounded by the missing JS base layer)
- `.jsx` — JSX tags uncolored (JS base layer is present, but JSX query absent)

## Fix direction

Add `tree_sitter_javascript::JSX_HIGHLIGHT_QUERY` to the query string for
`.jsx` and `.tsx`. Requires the same owned-query refactor as the JS-base-layer
fix (the query source can't be a `&'static str` after concatenation; leak a
Box<str> from the build cache).

## Why the existing test doesn't catch it

`highlight_tsx.test` expects `at_least 6`. The App.tsx fixture has enough
TypeScript-specific patterns (`interface`, capitalized identifiers, `FC<>`)
to produce 6+ spans without any JSX `@tag` captures ever firing.
