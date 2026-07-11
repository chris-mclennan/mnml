# [SEV-3] Normal-mode `U` (undo all changes on current line) is a no-op

## Reproduction

hello.txt with `one\ntwo\nthree\n`:

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"iAAA"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"aBBB"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"U"}
{"cmd":"snapshot"}
```

## Expected

Vim's `U` in NORMAL mode reverts every edit on the current line since
the cursor first landed on it. After `iAAA<esc>` and `aBBB<esc>`, line 1
= `AAABBBone`; `U` should restore `one`.

## Actual

Line 1 stays `AAABBBone` — `U` is inert. `u` (single-step undo) works
normally; only the vim-`U` variant is missing.

## Source pointer

`src/input/vim.rs` — greps for `KeyCode::Char('U')` find:
- Line 1148: `gU` operator (uppercase-motion)
- Line 1901: `PendingOp::Upper` guard for `gUU` composite
- Line 2824: Visual-mode `U` (transform selection to uppercase)

No NORMAL-mode top-level `U` arm ⇒ the key falls through the operator
prefix path and gets absorbed silently.

## Notes

Vim `:h U` — "Undo all latest changes on one line, the line where the
latest change was made". Nvchad users don't rely on it every day, but
when they need it and it does nothing, the feedback is silence — which
reads as "editor doesn't know what `U` is."
