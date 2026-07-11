# VS Code mouse tester — 2026-07-10 session hunt

Driven headless via `.mnml/ipc/command`. Fresh workspace under
`/private/tmp/.../scratchpad/dataloss` at 120x40.

## Findings

### 1. Bitbucket palette-bar chip missing despite manifest — **SEV-2**

Claim 9 ("Bitbucket integration shows on the activity bar now,
`in_palette_bar = true`") does not manifest.

Manifest at `~/.config/mnml/integrations/bitbucket.toml` has
`enabled = true` + `in_palette_bar = true`. Built-in defaults have
both `false`. After merger the icon *should* pick up both.

Rects at row 0 after fresh launch:
```
integration:46  (84, 0) w=3   ← Browser (only chip)
```

Hover on (85, 0) tooltips as "Browser (CDP Chrome-for-testing;
can be captured in mnml)". No Bitbucket chip in the row 55-109
gap. `:integrations.refresh` on the cmdline does not repopulate.

Right-clicking the Bitbucket **panel** row shows "Disable (hide
chip)" as the first item — consistent with `enabled=true` in the
merged config, so `enabled` is being read. Filter that gates the
palette-bar row must be dropping it silently.

Src: `src/ui/mod.rs:2056-2071` (`enabled_integrations` filter). The
`sibling_binary_for_command` clause returns `None` for
`"bitbucket.open"`, so that leg passes. Something else is
short-circuiting.

### 2. Split-strip hit-rects overlap across narrow neighbouring panes — **SEV-2**

Reproduced with 3 vertical splits until leaves reach w=5 and w=10.
Rects dump:
```
split_strip:3:Vertical         (105, 1) w=3   ← pane 3 (w=10)
split_strip_term:4             (105, 1) w=3   ← pane 4 (w=5)
split_strip:4:Vertical         (111, 1) w=3   ← pane 4
split_strip_term:5             (111, 1) w=3   ← pane 5 (w=5)
```

Clicking (105, 1) or (111, 1) fires whichever handler wins the
hit-test — pane 3 vert-split vs pane 4 term is ambiguous. Claim 3
covers AI-chip dropout for narrow leaves but the *core* cluster
still lays down chips that leak into neighbouring pane strips.

Visible glyphs at row 1 cols 95–118 read `⊞│ $⊟ $⊟ $⊟⊞` — the
term/horiz/vert triple repeats across bordering leaves regardless
of leaf width.

### 3. Missing IPC rects for new chrome — **SEV-3**

- `add_integration_button` (`+ Add integration` at row 37 of the
  Integrations panel) has no entry in `rects.json`. Clicking (10,
  37) opens the install picker, so the chip *works*; headless
  hunters just can't discover the target.
- `todos_panel_rescan_button` similarly absent — Todos empty
  state shows `⟳ Rescan` chip with no rect.
- Prior report's `split_strip_ai_buttons` entry is now emitted
  as split-per-kind (`split_strip_ai_claude` +
  `split_strip_ai_codex`), which is *fine* — flagging so the
  previous finding can be closed.

### 4. Sibling install picker column packing — **SEV-3**

Trailing name segments collide with `INSTALLED` status when the
overlay narrows: `mnml-aws-lamINSTALLED · Pty · …`,
`mnml-aws-ecsINSTALLED · Pty · …`. Add a min-1 space padding, or
truncate the name to fit.

### 5. Stale comment in request_view.rs — **SEV-3**

`src/ui/request_view.rs` still reads
`// styled orange to draw the eye` above the AI-chip render, but
the actual code sets `.fg(t.cyan)` (per claim 7's design-critic
fix). Just a doc-drift.

## Verified clean

- **Filter absorb** across Todos → Notes → Todos (claim 1). Typing
  in Notes filter after switching from a focused Todos filter no
  longer leaks into Todos.
- **AI launcher menu** has exactly 5 items — Toggle + 4 half
  placements. No dupe placement (claim 2).
- **"No matches — Esc clears"** in Notes fits (claim 4).
- **Confirm title** reads `` Remove integration `bitbucket`? `` with
  `Remove` + `Cancel` button row (claim 5).
- **Integrations right-click menu** — `Copy id` + `Show manifest…`
  land above `Remove` (claim 6). Show manifest opens the toml file
  as a pane.
- **⚡ AI chip** styled `t.cyan` in `request_view.rs` (claim 7).
- **Cursor row highlight** implemented — `row_bg = if is_focused_row
  { t.bg2 } else { bg }` in `todos_panel.rs` + `notes_panel.rs`;
  sessions accent stripe respects cyan cursor via `s.accent_color`
  fallback (claim 8).

## Files
`/private/tmp/claude-501/.../scratchpad/dataloss/.mnml/ipc/{screen.txt,rects.json,events.jsonl}`
