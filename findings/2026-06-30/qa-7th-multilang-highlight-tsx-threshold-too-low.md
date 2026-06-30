---
agent: multilang-dev-user
severity: SEV-3
language: typescript
repro: e2e
---

# `highlight_tsx.test` threshold masks broken TypeScript/JSX highlighting

## Summary

`tests/e2e/highlight_tsx.test` checks `expect highlights at_least 6`.
This threshold is achievable from TypeScript-extension-only tokens
(capitalized identifiers as @type, `interface`/`export` keywords,
`<>`  type argument punctuation) WITHOUT the JavaScript base layer or any
JSX tag highlights. The two SEV-2 bugs — missing JS base layer and uncolored
JSX tags — are completely invisible to this test.

## What the threshold should be

A `.tsx` file with a proper combined JS+TS+JSX query on content like:

```tsx
import React from 'react';

interface Props { title: string; }

const App: React.FC<Props> = ({ title }) => (
  <div className="app">
    <h1>{title}</h1>
  </div>
);
export default App;
```

should produce at least 20 spans covering: `import`/`from`/`const`/`export`
keywords, string `'react'`, interface keyword, predefined types, type
argument punctuation, React/FC/Props/App as identifiers/types, `<div>`/`<h1>`
@tag, `className` @attribute, `{title}` variable reference.

## Recommended fix

After fixing the JS base layer + JSX queries, raise the test threshold to
`at_least 20`. Until then, the test gives a false sense of confidence in
TypeScript/TSX highlighting.

## Related

- `tests/e2e/highlight_typescript.test` has the same issue: `at_least 6`
  for a `.ts` file that gets 8 TypeScript-only spans while `import`, `const`,
  string literals, and number literals are plain text.
