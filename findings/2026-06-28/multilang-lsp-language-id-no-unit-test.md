---
agent: multilang-dev-user
severity: SEV-2
language: ts
repro: e2e
---

# derive_lsp_language_id has no unit test — SEV-2 regression surface

## What's missing

The `4ed8c9e` commit introduced `derive_lsp_language_id` in `src/lsp/mod.rs` to fix
the tsx/jsx languageId mapping (tsx→typescriptreact, jsx→javascriptreact,
js→javascript, ts→typescript). The function is correct from code inspection but has
**zero unit tests**.

The existing `lsp/mod.rs` test suite covers:
- `byte_at_resolves_positions`
- `uri_round_trips`
- `ext_lookup_hits_builtins` (tests `server_for_ext`, NOT `server_for_file`)
- `config_overrides_builtin`
- `parse_diagnostic_basic`

None of these exercise the path `server_for_file → ensure_client →
derive_lsp_language_id`. A single-line accidental change to the match arms (e.g.
reverting `"tsx" => "typescriptreact"` to `"tsx" => "typescript"`) would silently
break JSX parsing with no test failure.

## Why e2e can't catch it

The headless harness cannot observe LSP wire messages — there's no
`expect lsp sent languageId "typescriptreact"` assertion type. The
`lsp_unavailable_toast.test` only exercises a `.ts` file.

## Suggested test (unit, src/lsp/mod.rs)

```rust
#[test]
fn language_id_derived_per_extension() {
    let cfg = Config::default();
    let m = LspManager::new(Path::new("/tmp/ts-project"), &cfg);
    // Simulate what ensure_client would derive (testing the pure fn directly):
    assert_eq!(derive_lsp_language_id(Path::new("x.ts"), "typescript"), "typescript");
    assert_eq!(derive_lsp_language_id(Path::new("x.tsx"), "typescript"), "typescriptreact");
    assert_eq!(derive_lsp_language_id(Path::new("x.js"), "typescript"), "javascript");
    assert_eq!(derive_lsp_language_id(Path::new("x.jsx"), "typescript"), "javascriptreact");
    assert_eq!(derive_lsp_language_id(Path::new("x.py"), "python"), "python");
    assert_eq!(derive_lsp_language_id(Path::new("x.rs"), "rust"), "rust");
}
```

Note: `derive_lsp_language_id` is currently `fn` (private). Make it `pub(crate)` or
move the test inside the `mod tests` block.
