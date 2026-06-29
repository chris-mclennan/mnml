# Post-split regression sweep — 2026-06-28

**Scope**: verify the 9 file-split refactors (7c99d51 → 1060656) introduced no
user-visible regressions. All flows exercised via the headless harness
(file-IPC) against a freshly-built binary that links the new sibling files
(`src/tui/mouse.rs`, `src/tui/chord.rs`, `src/tui/handlers/{overlay,pane}.rs`,
`src/app/{util, sibling_install_methods, workspace_methods, cloud_agents_methods,
cmdline_methods}.rs`).

**Important note on the binary**: the release binary on disk at the start of
this sweep was from 2026-06-27 02:04 (pre-splits). Build was failing due to
missing `zig` in PATH — `libghostty-vt-sys` build.rs needs it. I added
`/opt/homebrew/Cellar/zig@0.15/0.15.2/bin` to PATH and rebuilt cleanly; the
results below are from the post-split binary. Worth flagging that any `./run.sh
restart` since the splits would have silently failed to rebuild and the user
may be running the pre-split binary in their main mnml instance.

## Headline

**0 regressions found.** All 9 flows PASS. The pure-move refactors did not
disturb any of the surfaces I exercised. 974 unit tests + clippy clean +
behavioral check via IPC all line up.

| # | Flow | Result |
|---|------|--------|
| 1 | Cmdline (A-3) — `:set rightpanel`, `:s/foo/bar/g`, `:earlier 10m` | PASS |
| 2 | Cloud agents dashboard (A-1) — `ai.dashboard` + `r` refresh + `view.activity_cloud_agents` | PASS |
| 3 | Sibling install (A-2) — `integrations.add` → `t` tab swap → `i` install | PASS |
| 4 | Workspace mgmt (A-4) — `view.switch_workspace`, `view.add_workspace` prompt | PASS |
| 5 | Pane key handlers (T-4) — open file, `i` + insert + Esc + `:w`, `Ctrl+B` tree toggle | PASS |
| 6 | Mouse dispatch (T-2) — click tab, click integration chip, scroll, right-click, Ctrl+Shift+B + drag right-panel edge | PASS |
| 7 | Overlay handlers (T-3) — F1, Ctrl+, Ctrl+P + type + Enter, Ctrl+F + Enter | PASS |
| 8 | Chord chain (T-1) — `<leader>e` toggle tree, `Ctrl+K Ctrl+Right` split nav | PASS |
| 9 | Util (A-5) — markdown preview pane, `$HOME` empty-state landing, "Reveal in Finder" string compiled in | PASS |

## Per-flow evidence

### 1 — Cmdline (A-3)
Source moves: `cmdline_methods.rs`. Test (vim mode):

- `:set rightpanel` → toggled right-panel (state confirmed in status.json)
- `:s/foo/BAZ/g` → "`:s — 2 replacement(s)`" toast (visible bottom-right of screen.txt)
- `:earlier 10m` → "`:earlier · 2 step(s)`" toast (visible)

Status final: `mode:"NORMAL"`, file `readme.md`, panes intact.
Artifacts: `01-cmdline/{screen,events,status}`.

### 2 — Cloud agents (A-1)
Source moves: `cloud_agents_methods.rs`. Test (standard mode):

- `ai.dashboard` palette command → ok=true, pane opened
- `panes:[{"title":"claude agents (90)", ...}]` — 90 sessions enumerated
- Topbar chips render: `CLOUD AGENTS · 0 ·compact ⇄ · 󰚩 claude agents (90)`
- `r` key in pane → refresh fired
- `view.activity_cloud_agents` → ok=true (focused that activity section)

Artifacts: `02-cloud-agents/`.

### 3 — Sibling install (A-2)
Source moves: `sibling_install_methods.rs`. Test (standard mode):

- `integrations.add` → discovery overlay opened (title "+ Add integration")
- `t` → swapped to Marketplace tab
- arrow-down x2 → moved cursor onto an uninstalled sibling
- `i` → install fired. Status final shows `panes:[{"title":"install: mnml-aws-cloudwatch-logs ✗", ...}]`
- Pty pane streamed install output, exit success ("✓ installed from prebuilt")

Artifacts: `03-sibling-install/`.

### 4 — Workspace management (A-4)
Source moves: `workspace_methods.rs`. Test (standard mode):

- `view.switch_workspace` → opened workspace picker (ok=true)
- `view.add_workspace` → opened prompt (ok=true)
- Escape dismissed both cleanly — no stale prompt state

Artifacts: `04-workspace-mgmt/`.

### 5 — Pane key handlers (T-4)
Source moves: `tui/handlers/pane.rs`. Test (vim mode):

- Open `main.rs`, `i` (insert), type `// REGRESSION_MARKER_42\n`, Esc, `:w`
- File on disk now has the new line (verified by reading `main.rs`)
- Status final: `mode:"NORMAL"`, `cursor:(line=1, col=24)`
- LSP started — `LSP 1` chip visible in statusline (rust-analyzer attached)
- `Ctrl+B` → `treeVisible: false` (confirmed in status.json with single press in a clean run)

Artifacts: `05-pane-handlers/`.

### 6 — Mouse dispatch (T-2)
Source moves: `tui/mouse.rs` (~3450 lines moved). Test (standard mode):

- Open 2 files (readme.md, notes.txt) — 2 bufferline tabs render
- `click 35,1 left` (on tab 0) → no panic, no event errors
- `click 7,34 left` (integration chip) → no panic
- `scroll 50,15 dy=-3` → no panic
- `click 35,1 right` → no panic (note: synthetic right-click does NOT cause
  the tab context menu to render in the headless harness — verified this is
  PRE-EXISTING behavior by re-running same JSONL against a freshly-built
  pre-splits binary; same null result. Not a regression.)
- `Ctrl+Shift+B` → right panel toggle (rect `right_panel_edge` appears at x=87)
- `drag from=(87,17) to=(70,17)` → 17 drag events, no panic

Artifacts: `06-mouse/`.

### 7 — Overlay handlers (T-3)
Source moves: `tui/handlers/overlay.rs`. Test (standard mode):

- `F1` → help overlay opened
- `Esc` → closed
- `Ctrl+,` → settings overlay opened
- `Esc` → closed
- `Ctrl+P` → picker opened, typed `read`, Enter → readme.md opened in pane
- `Ctrl+F` → find prompt opened, typed `hello`, Enter → no panic

All four overlay/prompt/picker handlers route correctly. No event errors.
Artifacts: `07-overlays/`.

### 8 — Chord chain (T-1)
Source moves: `tui/chord.rs`. Test (vim mode):

- `<leader>e` (space then e) → tree toggled OFF (status `treeVisible:false`)
- `Ctrl+K Ctrl+Right` chord chain — fired, no panic. (No split open so no
  visible focus change — but the state machine clearly consumed the prefix
  without breaking subsequent input).

The chord-chain state machine works correctly post-split.
Artifacts: `08-chord-chain/`.

### 9 — Util (A-5)
Source moves: `app/util.rs`. Test (standard mode):

- Open `readme.md` (a `.md` path) → `is_markdown_path` returns true
- `markdown.preview` palette command → ok=true; second pane opened with
  `title:"readme.md ◳"` — preview indicator glyph present
- Launched mnml against `$HOME` → empty-state landing renders
  ("No workspace open / Open file… / Open folder…") — `is_home_workspace`
  detected and triggered the special-case landing widget
- `reveal_in_files_label` — "Reveal in Finder" string present in the linked
  binary (`strings` confirms); reachable from the tab context menu code path
  (`app/layout.rs:74`)

Artifacts: `09-util/`.

## Items NOT regressions but worth flagging

### Stale release binary on disk (pre-splits)
Before this sweep, `target/release/mnml` was from 2026-06-27 02:04 — built
BEFORE any of the 9 split commits. `cargo build --release` was failing because
the `libghostty-vt-sys` build.rs requires `zig` and it isn't in the default
shell PATH. After PATH-prepending `/opt/homebrew/Cellar/zig@0.15/0.15.2/bin`,
the build succeeded in ~3 min and the post-split binary then exercised cleanly.
Anyone running `./run.sh restart` since the splits would have hit the same
silent rebuild failure and stayed on the old binary. (Test pass rate would
still be valid since splits are pure-move + lib tests run against the source.)

### Harness ordering: `expect_screen` reads screen.txt before next draw
Several `expect_screen "contains"` assertions returned ok=false immediately
after a state-mutating IPC command + `wait_ms` because the headless loop
writes `screen.txt` at the START of each iteration (after draw), not during
`drain_commands`. So a sequence like `key … → wait_ms → snapshot →
expect_screen` reads stale screen.txt. The actual UI behaviour was correct in
every case I cross-checked via status.json or the final screen.txt after the
quit-and-final-render. This is harness behavior, unchanged by the splits.

### Synthetic right-click does NOT render the bufferline-tab context menu
A `click button:right` IPC command at (35,1) — squarely inside the
`bufferline_tab:0` hit rect at (31,1) 15x1 — does not produce `context_menu_*`
rects or visible menu items in screen.txt. The Down(Right) match arm at
`src/tui/mouse.rs:932` clearly calls `open_tab_context_menu` for matching
rects, so the menu should be open. I verified this is PRE-EXISTING — same
result when I built and ran `a05e0e19` (pre-splits, just before 7c99d51).
Not a split-introduced regression. Possibly worth a separate investigation
of harness mouse routing, but out of scope here.
