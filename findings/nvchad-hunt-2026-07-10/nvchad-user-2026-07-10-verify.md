# nvchad verify + adjacent hunt — 2026-07-10

Binary rebuilt at 22:08 (commit 6b1c96c had shipped at 22:03 but the
existing `target/release/mnml` was from 20:14 — verification against a
stale binary initially showed the `:` still typed literally; after
`cargo build --release` the fix behaves as designed).

## Summary

- Counts: 1 SEV-3 confirmed. No new SEV-1/2 in the fix's blast radius.
- SEV-1 fix (`:` on Request URL/Method → ex-cmd prompt) verified end-
  to-end: prompt opens, URL is not mangled, `:bn` <Enter> actually
  switches buffers (activePane 1 → 0, mode NORMAL on lib.rs).
- Method field also routes `:` to the ex-cmd prompt (matches fix's
  `EditField::Url | EditField::Method`).
- Body accepts `:` literally (JSON `{"a":1}` types cleanly).
- Esc from URL closes any ex-cmd prompt without corruption.
- Session persistence: URL edits don't persist until `:w`; on `:w` an
  `.http` file is rewritten as a `curl '...'` line (pre-existing
  behavior, may surprise a vim user but unchanged by this fix).

## [SEV-1] `:` on Request URL — VERIFIED FIXED

**Reproduction:**
```jsonl
{"cmd":"key","key":"esc"}
{"cmd":"open","path":"lib.rs"}
{"cmd":"open","path":"req.http"}
{"cmd":"wait_ms","ms":400}
{"cmd":"type","text":":"}
{"cmd":"snapshot"}
{"cmd":"type","text":"bn"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":300}
```
Before fix: URL becomes `https://httpbin.org/get:bn`, Enter fires a
real HTTP request against the mangled URL.
After fix: bottom row shows `:▏` prompt, URL stays clean at
`https://httpbin.org/get`, Enter runs `:bn` and status.json flips
`activePane` from 1 to 0 with `mode:"NORMAL"`.
Source: `src/tui/handlers/pane.rs:2467-2491`

## [SEV-3] `u` / `Ctrl+Z` on Request URL do not undo

**Reproduction:**
```jsonl
{"cmd":"open","path":"req.http"}
{"cmd":"type","text":"XYZ"}
{"cmd":"key","key":"ctrl+z"}
```
Expected (vim user): `u` in normal-mode-ish text field or `Ctrl+Z` in
standard mode reverts the last URL edit.
Actual: `u` types literally into URL, `Ctrl+Z` no-op. The Request
pane has no per-field edit-history stack — every keystroke is
durable-until-saved with no undo path.
Notes: Since `:` already routes to ex-cmd in vim mode, `u` is a
narrower miss than the SEV-1 was — but a vim user expects some way
to unwind an accidental character. Currently the only fix is
Backspace one char at a time.
Source pointer: `src/request_pane.rs` has no undo stack.

## Adjacent tests — no findings (recorded for completeness)

- `/` on Request URL types literally (URL slashes are meaningful —
  intentionally NOT routed to ex-cmd; parity with what a REST client
  needs).
- `i`, `a`, `o` on Request URL type literally (correct — URL is a
  text field, these are just characters).
- `Esc` from URL after garbage does not corrupt state; ex-cmd prompt
  dismisses cleanly.
- Body accepts `:` (JSON typing works).
- Headers/Params/Vars/Auth same story per the fix's scope note.
- MdPreview: `:`, `/`, `i` still all inert (unchanged since prior
  hunt — was SEV-2 then, remains SEV-2 but explicitly outside this
  fix's scope).
- `markdown.edit_raw` still palette-only (no `<leader>me` chord)
  — same as prior hunt.
- Session persistence clean: quit + relaunch reloads req.http as
  the on-disk `GET https://…` form (no state leak).
- `h`/`j`/`k`/`l` on URL field type literally (correct — the field
  is text input, not a vim buffer).
