## [SEV-3] Preview-tab pin marker `◳` is inconsistent — appears on some previews but not others

**Reproduction**:

```jsonc
{"cmd":"key","key":"ctrl+p"}
{"cmd":"type","text":"src"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"ctrl+p"}
{"cmd":"type","text":"app"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"ctrl+p"}
{"cmd":"type","text":"read"}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"ctrl+p"}
{"cmd":"type","text":"deep"}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
```

The bufferline visible in `screen.txt`:

```
  src.py       app.js     󰂺  readme.md ◳     󰈙  deep.txt 󰅖
```

**Expected**: Preview indicator (`◳`) either appears on ALL preview-mode tabs or none. VS Code shows italic titles for preview tabs consistently.

**Actual**: Only `readme.md` gets `◳`. `src.py`, `app.js`, `deep.txt` do NOT — even though all four were opened the same way and should all be in preview mode until the user edits one. The status `panes` array confirms only `readme.md ◳` carries the suffix in its title.

Additionally: single-click on a file in the tree DOES replace-preview (correct semantic), but the newly opened tab also doesn't show `◳`.

**Source pointer**: Wherever pane titles are computed for the bufferline — likely `src/app/mod.rs` or `src/ui/bufferline.rs`. The `◳` is being written by only one of the two "open path" code paths (the `open` IPC vs `open_path` internal vs whatever routes single-click).

**Notes**: Adjacent to preview-mode UX. VS Code parity would render preview tabs in italic AND make the "◳" state visually consistent across every code path that opens a preview.
