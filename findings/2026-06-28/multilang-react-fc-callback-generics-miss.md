---
agent: multilang-dev-user
severity: SEV-3
language: ts
repro: workspace-fixture
---

# React.FC outline misses components with callback types in generics

## Pattern that fails

The `ac96648` regex for React.FC components:

```
^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*[^=]+=\s*(?:async\s+)?\([^)]*\)\s*=>
```

The `[^=]+` segment stops at the **first `=`** in the type annotation. When the
generic contains a callback type that includes `=>`, the `=` inside `=>` terminates
the match prematurely:

```ts
// WORKS — no = inside the generic
const App: React.FC<Props> = ({ title }) => <h1>{title}</h1>;

// FAILS — React.FC<{ onClick: () => void }> contains = (from =>)
const Input: React.FC<{ onClick: () => void }> = (props) => <input />;
```

Confirmed via Python regex:

```python
pattern = r"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*[^=]+=\s*(?:async\s+)?\([^)]*\)\s*=>"
re.match(pattern, "const Input: React.FC<{ onClick: () => void }> = (props) => <input />")
# → None (no match)
```

## Impact

Components whose Props interface contains callback types (extremely common in React:
`onChange: (e: Event) => void`, `onSubmit: () => Promise<void>`, etc.) will be absent
from the regex outline. As a fallback, the LSP's document symbol provider covers these
cases when typescript-language-server is attached — so this only affects the no-LSP
outline.

## Suggested fix

Replace `[^=]+` with a pattern that allows `=` inside angle brackets, or use a
two-pass approach: find the assignment `=` that's followed by `(` rather than `>`.

A simpler targeted fix: match the pattern `= (` or `= async (` (where `=` is
surrounded by spaces) to locate the assignment boundary, rather than stopping at the
first `=`:

```
\s*=\s*(?:async\s+)?\([^)]*\)\s*=>
```

But this requires capturing everything before the assignment, which conflicts with
`[^=]+` greediness. A viable approach: use a positive lookahead for `= (` or match
`=(?![>])` (equals not followed by `>`).
