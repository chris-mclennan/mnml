---
finding: utf8-truncation-panic
severity: SEV-2
agent: power-user-ai
repro: code-review
---

# `:ai.explain_diff` and `:ai.write_pr_description` panic on multi-byte UTF-8 in large diffs

`src/app/ai.rs:2033-2034` (explain_diff) and `src/app/ai.rs:2112-2113`
(write_pr_description) use **byte slicing** to cap the diff at 32k chars:

```rust
let diff = if diff.len() > 32_000 {
    format!("{}\n…(diff truncated)…", &diff[..32_000])
} else {
    diff
};
```

`&diff[..32_000]` is a byte-range slice. Rust panics
(`byte index 32000 is not a char boundary`) when byte 32_000 lands
mid-UTF-8-character. Real-world triggers:

- Any file under git with non-ASCII content (CJK source, emoji in strings,
  even smart-quotes in markdown). A diff that crosses byte 32_000 right
  inside a 2/3/4-byte char crashes.
- `String::from_utf8_lossy` is used upstream when reading `git diff`
  output, which can produce U+FFFD (3 bytes UTF-8) for bad bytes —
  another way to land mid-char on the boundary.

Reproduced minimal case:
```
let mut s = String::with_capacity(33_000);
for _ in 0..31_999 { s.push('a'); }
s.push('💥');               // 4 bytes starting at byte 31_999
for _ in 0..1000 { s.push('b'); }
let _ = &s[..32_000];        // PANIC
```

Worker-thread panic from `request_ai_explain_diff` /
`request_ai_pr_description` would unwind through the main thread and
abort mnml entirely. Cmd is invoked from a synchronous palette path —
this code runs on the UI thread, not a worker.

`request_ai_commit_message` (line 1853) and `request_codex_commit_message`
(line 2147) and `request_ai_recompose_message` (line 2202) all use the
same buggy pattern with `24_000` — same SEV-2 there. (Pre-existing on
those three; new in this session on the two flagged above.)

**Fix shape**: use `floor_char_boundary(32_000)` (stable since 1.80) or
walk back to the previous `is_char_boundary()` byte before slicing.
Apply to all 5 truncation sites.
