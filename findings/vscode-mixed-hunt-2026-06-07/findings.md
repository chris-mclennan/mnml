# VS Code-user bug hunt — mnml `--input standard` (2026-06-07)

## Executive summary

- SEV-1: 0
- SEV-2: 8
- SEV-3: 6
- Total: 14

**How VS Code-compatible does mnml feel after 45 min?** Promising foundation, lots of rough edges. The basics work — Ctrl+P, Ctrl+Shift+P, Ctrl+S, Ctrl+Z/Shift+Z, Ctrl+C/X/V, Ctrl+/, Alt+↑/↓, Ctrl+B, Ctrl+W, Ctrl+Tab, middle-click close tab, drag-to-reorder, right-click context menus, Alt+click multi-cursor. Where it slips: a cluster of "VS Code muscle memory hits a wall" moments — Ctrl+H, Ctrl+D next-occurrence, Shift+Alt+Down, Ctrl+\, Ctrl+,, Ctrl+S in palette/find, preview-tab invisibility, .git/ pollution in picker — that come up in the first 10 minutes and break flow.

## Top 3 worst

1. **SEV-2** — Ctrl+, opens raw `~/.config/mnml/config.toml` as a buffer; leaked DocumentDB credentials onto the agent's screen. mnml has a proper settings overlay (`view.settings`) — the chord should route there. (`src/app/mod.rs:7279`)
2. **SEV-2** — Ctrl+H (replace) bails with "find first (Ctrl+F)" toast if no find session exists. Should open the replace prompt directly. (`src/app/find.rs:487-503`)
3. **SEV-2** — Ctrl+D only selects current word; doesn't add cursor at next occurrence on subsequent presses. One of the most-burned-in VS Code reflexes. (`src/input/standard.rs:78`)

## SEV-2

### Ctrl+H requires Ctrl+F first
`src/app/find.rs:487-503` `open_replace_prompt` bails with toast when buffer has no `find` state.

### Ctrl+S silently no-ops while palette / find bar has focus
Palette + prompt input loops in `src/tui.rs` consume keys before global handler.

### Esc after committed find jumps focus editor → tree
`src/input/standard.rs:126-132` — Esc returns Ignored when no selection, falls through to tree-focus handler.

### Ctrl+D doesn't extend to next occurrence
`src/input/standard.rs:78` — `'d' => SelectWord` with no "if already selected, extend" branch.

### Ctrl+\ opens scratch terminal instead of split
`src/command.rs:2778-2782` — `term.scratch_toggle` binds both Ctrl+backtick AND Ctrl+\. Drop the backslash or rebind to split.

### Ctrl+, opens raw config.toml (and leaked credentials)
**Worst finding.** Agent's screen showed `mongodb://claude_dev_ro:LKCT...@integration-engine-dev...` (DocumentDB readonly creds). Source: `src/app/mod.rs:7279-7287` `file.open_settings` opens raw toml. Fix: repoint chord to `view.settings`.

### File picker shows .git/ internals
Picker first lists 23+ `.git/hooks/`, `.git/refs/`, `.git/logs/` entries before user files. mnml correctly auto-gitignores `.mnml/` — same logic should hide `.git/`.

### Settings overlay accepts NO mouse input
`src/ui/settings_overlay.rs` registers no per-row hit rects; `src/tui.rs` has no settings-row click arm.

## SEV-3

### Shift+Alt+Down doesn't duplicate the line
`src/input/standard.rs:77` — needs `KeyCode::Down if alt && shift => DuplicateLine`.

### Preview-tab behavior exists but has no visual indicator
Tab replacement works; no italics or visual distinction. VS Code uses italics.

### Hover tooltips never appear
Welcome overlay promises "hover any clickable chip ~500ms for tooltip." Agent waited 700-1500ms across 6 chips — no tooltip ever painted. May be headless-only (idle ticks not firing tooltip render) or related to the mnml mouse hunt's `HoverChip` missing-variants finding.

### Ctrl+P fuzzy matcher rejects transpositions
Type `uitl` → "(no matches)" even though `src/util.rs` exists. VS Code tolerates 1-2 char transpositions.

### Statusline `Ln N/M` overflow (N > M)
`Ctrl+A`, `Ctrl+C`, `Ctrl+End`, Enter, `Ctrl+V` → reads `Ln 12/11 Col 5`. Related to but distinct from the line_count off-by-one I fixed earlier today (66f26e7).

### Per-character undo (no token grouping)
Type `// hi` + Enter → 6 Ctrl+Z presses needed. VS Code groups consecutive char bursts within ~500ms.

## Test setup notes

- Workspace: `/tmp/mnml-vscode-hunt/ws1` (git init + 5 seed files)
- Binary required rebuild before testing — on-disk binary at session start was older than `wait_ms`/`expect_screen`/`drag` IPC commands. Pre-rebuild events logged `wait_ms` as `unknown`.
- All findings driven through file-IPC at `<ws>/.mnml/ipc/`.
