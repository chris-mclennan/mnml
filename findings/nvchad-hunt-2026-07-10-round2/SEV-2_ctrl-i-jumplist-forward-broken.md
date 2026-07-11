# [SEV-2] Ctrl+I (jumplist forward) is a no-op after Ctrl+O

## Reproduction

Workspace: /tmp/mnml-nvhunt2/scen1 with hello.txt (6 non-empty lines).

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":"G"}
{"cmd":"key","key":"ctrl+o"}
{"cmd":"wait_ms","ms":100}
{"cmd":"key","key":"ctrl+i"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```

## Expected

Vim: `G` jumps to end (line 6, pushed on jumplist). `Ctrl+O` returns to prior
position (line 1) and pushes line 6 onto forward-stack. `Ctrl+I` restores
line 6. Final cursor: line 6, col 1.

## Actual

Final cursor: line 1, col 1. Toast "nothing to go forward to" (visible in
screen buffer bottom line: `nothing to go forward to`).

## Source pointer

`src/tui/mod.rs:2014-2029` — the post-dispatch big-jump recorder fires on
every `dispatch_key` where cursor moved >= 3 rows OR file switched. When
Ctrl+O jumps from line 6 back to line 1, that's a 5-row move so the
recorder calls `record_within_file_jump(before)` — and
`record_within_file_jump` (`src/app/mod.rs:6569-6572`) unconditionally
clears `self.nav_forward`, wiping out the line 6 entry that `nav_back_jump`
just pushed.

Direct evidence: `run-command nav.forward` immediately after Ctrl+O also
toasts "nothing to go forward to" — confirms the stack is empty, not that
Ctrl+I fails to dispatch.

## Notes

Effectively means `Ctrl+I` never works in-buffer. The only way to
round-trip is when the jumps span < 3 rows (short jumps skip the recorder).
The comment in `record_within_file_jump` says "matches vim's behavior of
'any new jump wipes the redo lane'" but that rule is only supposed to
apply to _user-initiated_ new jumps, not to the internal target-jump that
`Ctrl+O` itself performs. Guard `record_within_file_jump` with a "am I
inside nav_back_jump / nav_forward_jump right now?" flag.
