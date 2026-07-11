# [SEV-2] `:b <N>` (numeric buffer switch) errors as "no match"

## Reproduction

Three buffers open (hello.txt, world.txt, third.txt):

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"hello.txt"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"esc"}
{"cmd":"type","text":":e world.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":":e third.txt"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":":b 1"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

## Expected

Vim: `:b 1` switches to buffer number 1 (hello.txt — the first one opened).
Cursor + active pane move to hello.txt.

## Actual

Bottom of screen shows `:b — no match for "1"` and active pane stays on
third.txt. `:b hello` DOES work (name matching), so mnml's `:b`
implementation ignores the vim-canonical numeric case entirely.

## Source pointer

Unknown exact file:line — `grep -n '"b" =>' src/app/*.rs` didn't surface a
buffer-switch arm; likely lives in the ex-command dispatcher. Behavior
suggests `:b <arg>` runs a substring/name match without first checking
whether the arg parses as an integer.

## Notes

Also affects `:buffer 1`, `:sb 1`, `:sbuffer 1` — every buffer-selection
command with a numeric arg. Vim users use `:b<num>` more often than
`:b<name>` because `:ls` shows numbers. NvChad users also — since NvChad's
tab-line displays 1-based indices.
