# [SEV-2] `:next` / `:prev` / `:args {glob}` — vim's arglist not implemented; `:next` fires find.next

## Reproduction

Workspace has `sample.txt`, `tags.html`, `hello.rs`. Only `sample.txt`
and `tags.html` are open buffers.

```jsonl
{"cmd":"type","text":":args *.rs"}
{"cmd":"key","key":"enter"}
```
Toast: `:Args — sample.txt · tags.html`

`hello.rs` is NOT loaded. The glob was ignored — the toast just echoes
the currently-open buffer list.

```jsonl
{"cmd":"type","text":":next"}
{"cmd":"key","key":"enter"}
```
Toast: `no active find — press Ctrl+F`

`:next` fired **find.next**, not vim's `:next` (advance in the
arglist). `:prev` did switch to a different buffer (looked more like
buffer-prev than arglist-prev), but neither maps to arglist semantics.

## Expected

Vim:
- `:args foo/*.rs` sets the arglist to the glob's matches, loads the
  first entry.
- `:next` advances to the next arglist entry.
- `:prev` moves back.
- `:args` alone shows the arglist, `[current]` bracketed.

NvChad users rely on `:n` / `:N` after `:args src/**/*.rs` for
methodical file-by-file work.

## Actual

- `:args` alias shows open buffers (looks like a buffer picker, not
  an arglist).
- `:next` misroutes into the `find.next` command — a big
  ex-command → registered-command lookup collision.
- `:prev` switches to the previous buffer (guess: `:bp`).

Concrete impact: a user typing `:next` mid-edit expecting to advance
arglist gets a confusing "no active find" toast, and their arglist
mental model isn't reflected anywhere in the app.

## Source pointer

Unknown — grep `"next"` in the command registry / ex-command
dispatcher (`src/command.rs`, `src/app/ex_commands.rs`).
Likely `find.next` was registered with a raw `next` alias that
shadows the vim ex-command.

## Notes

Minimal fix: implement a real arglist (`Vec<PathBuf>` on App or per-
tab-page), `:args`/`:next`/`:prev`/`:first`/`:last`/`:argdo`. If out
of scope, at minimum route `:next` to arglist-next (empty when no
arglist, silent no-op) instead of `find.next`, so the vim ex-command
namespace isn't polluted by application commands.
