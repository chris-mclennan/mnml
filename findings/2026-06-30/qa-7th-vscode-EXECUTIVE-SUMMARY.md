---
agent: vscode-user
severity: summary
---

# QA round 7 — standard-mode VS Code user pass

## Severity counts

- SEV-1: 0
- SEV-2: 3
- SEV-3: 4

## How VS-Code-compatible does mnml feel after 45 minutes?

Strong on the visible chrome — file picker, command palette, settings
overlay, right-panel toggles, statusline chip menus, mixr tooltip + menu,
session restore, F1 help, Ctrl+G goto-line, Ctrl+B sidebar toggle, and the
new `[Save]` / `[Cancel]` chips all behaved cleanly. The 4 new
`statusline.*_menu` palette commands all wire up to their respective
context menus. Spend report opens and shows data. Right-panel routing of
`outline.show` + `lsp.diagnostics` from the empty-state command rows works
via mouse click.

Where it bites: keystrokes from the VS Code muscle-memory shelf that
either route into vim's chord chain (Ctrl+W stalls 1000ms before closing
because it's a vim window-prefix in the standard keymap) or implement the
vim semantic of an op that shares a name (Ctrl+L = SelectLine acts like
vim `V`, selecting `line_start..cursor` instead of the whole line). The
bufferline overflow chevrons are decorative — the render-time auto-clamp
to keep the active tab visible immediately undoes any click on `‹` / `›`.
And the settings overlay's chips advertise a save/cancel model that
doesn't match the per-keystroke disk persist underneath.

The minor stuff: Cmd-prefixed shortcuts don't fall back to Ctrl on macOS,
so a Cmd+W / Cmd+P user feels nothing happen; right-panel headers show the
file name instead of the documented `OUTLINE` / `DIAGNOSTICS` literal; and
the statusline context menus need two Esc presses to fully release before
the palette will reopen.

Net feel: about an 80% match for VS Code muscle memory. The visible UI is
right; the few-but-load-bearing chords (Ctrl+W, Ctrl+L, chevrons) still
sit just-a-bit on the vim side. None of the misses are crashes or data
loss, and all five SEV-2/3 keystroke issues are fixable as bindings tweaks
rather than re-architectures.

## Findings

- SEV-2 `qa-7th-vscode-bufferline-chevron-stuck.md`
- SEV-2 `qa-7th-vscode-ctrl-w-chord-delay.md`
- SEV-2 `qa-7th-vscode-ctrl-l-vim-not-vscode.md`
- SEV-3 `qa-7th-vscode-cmd-shortcuts-unbound.md`
- SEV-3 `qa-7th-vscode-settings-persist-on-keypress.md`
- SEV-3 `qa-7th-vscode-right-panel-header-not-OUTLINE.md`
- SEV-3 `qa-7th-vscode-context-menu-blocks-palette.md`

## Verified-working (not bugs)

- `Ctrl+P` file picker — fuzzy match, Enter opens file
- `Ctrl+Shift+P` command palette
- `Ctrl+G` Go to Line (correct in-editor binding restored)
- `F1` help overlay (correct in-editor binding restored)
- `Ctrl+B` tree toggle, `Ctrl+Shift+B` right-panel toggle, `Ctrl+Alt+W`
  close right-panel pane
- Settings overlay: chips clickable, Esc / Enter / `r` reset / `R` reset-all
  hint render, modified-flag `*` appears + clears
- 4 new statusline.*_menu palette commands (mode, branch, workspace, clock)
- Mixr chip hover tooltip + right-click "Open mixr" menu
- Spend report (`ai.spend`) opens, background thread populates rows
- Session restore: open[] panes correctly recreated on relaunch; empty
  layout persists when all panes closed via Ctrl+W before quit
- Middle-click tab close
- File picker fuzzy ordering still surfaces workspace files first
