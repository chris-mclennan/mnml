# [SEV-3] `:bd` on a dirty buffer opens confirm overlay silently — no vim-canonical error text

## Reproduction

hello.txt with `alpha\n`:

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"iEDIT"}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":bd"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```

## Expected (vim)

Cmdline echoes `E89: No write since last change for buffer 1 (add ! to
override)`. `:bd!` force-discards. `:q` on dirty gets the same message.

## Actual (mnml)

An "Unsaved changes" overlay pops up with `[ Save ]` `[ Discard ]`
`[ Cancel ]` buttons. Functionally correct — the user can Discard to get
vim's `:bd!` behavior — but there's no cmdline text explaining WHY the
overlay opened, and (more importantly for a vim user) `:bd!` typed
directly is not the escape hatch it would be in vim. A user who reflexes
`:bd!` (skipping the overlay) then hits `!` after the overlay is already
open just gets `!` echoed into the message area.

## Source pointer

`src/tui/handlers/overlay.rs` (close-prompt overlay) + the ex-command
dispatcher for `:bd`. `:bd!` handling likely needs to add a "force"
flag that skips the overlay and goes straight to Discard.

## Notes

- The Save/Discard/Cancel button dialog IS a nice touch for new-to-vim
  users — this isn't a "remove the overlay" ask.
- The gap: `:bd!` should bypass the overlay (immediate discard), and the
  cmdline should echo a short `no write since last change — :bd! to
  discard` line when the overlay opens, so vim reflexes still land you
  somewhere sensible.
- Same story for `:q` / `:q!` on dirty buffers.
