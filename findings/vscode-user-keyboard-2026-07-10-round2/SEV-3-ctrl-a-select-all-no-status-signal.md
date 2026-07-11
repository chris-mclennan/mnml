# SEV-3 — Ctrl+A select-all leaves no user-visible signal that a selection exists

## What I did

Placed cursor mid-file, pressed `Ctrl+A`. Cursor jumped to end of
file (line 10, col 1) — indication that `SelectAll` ran per
`src/editor/mod.rs:2197-2200` (`anchor = Some(0); cursor =
self.text.len();`).

But:

- The statusline shows `Ln 10/9 Col 1`, no `Sel N` chip.
- The tab shows no highlight change.
- No highlight of the selected region visible in the pane body
  (though this could be a headless-render quirk; hard to tell from
  `screen.txt`).
- `status.json` from the IPC channel emits neither `selRange` nor
  `selectionCharCount` — status_json in `src/ipc/mod.rs:1577` has no
  selection fields.

The statusline DOES render a `Sel N` chip when a range is selected
via arrow-with-shift (verified in a separate test — same file,
Home + Shift+End showed `Sel 36`). So Ctrl+A alone doesn't trip the
same code path.

## Why it matters

A user hits Ctrl+A intending to copy the file. Since no visible
indicator says "you have selected everything", they can't be sure
whether Ctrl+C will copy the whole file or nothing. VS Code shows the
selection count in the statusline (`36 selected` etc.) as immediate
feedback. Ctrl+C did in fact work (a subsequent paste replayed the
whole file), so the selection IS being set — it just isn't shown.

## Suggested fix (not applied)

- Ensure the `Sel N` chip / count reflects the SelectAll anchor+cursor
  pair.
- Add `selRange` and `selectionCharCount` to `status_json` so
  headless E2E tests can assert selection state deterministically.

## Severity

SEV-3 — chord works, the visible confirmation just doesn't fire.
