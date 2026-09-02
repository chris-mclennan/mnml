# mnml — Features

The complete, organised feature inventory. For the front-door overview see
[README.md](README.md); for design rationale see [`CLAUDE.md`](CLAUDE.md).

---

## Editing & input

- **Pluggable input layer** — a modal **vim** keymap and a modeless **standard**
  (VS Code-style) keymap, both first-class and both fully remappable. Switch at
  runtime (`:set input=vim` / `editor.toggle_keymap`). Input handlers translate
  keys into a closed set of edit operations; the editor, buffer, and render
  layers never branch on which handler is active.
- **Vim modal editing** — Normal / Insert / Visual / Visual-Block / Replace
  modes; operators + motions + text objects (`iw`, `ip`, `i(`, `if`/`ic`/`ia`
  tree-sitter objects, indent objects); registers (named, numbered delete-ring,
  yank); macros (named, persisted); marks (buffer-local + global, persisted);
  the `.` repeat; jumplist & change-list; `f`/`t` find-char; vim-surround;
  multi-cursor; flash-motion jumps; abbreviations.
- **Ex-command line** — `:w`/`:q`/`:e`, `:%s/old/new/flags` with ranges and
  marks, `:g/`/`:v/` global commands, `:norm`, `:sort`, `:!cmd`, `:r`, line-range
  ops, user-defined `:command`s, history with completion — a deep `:` surface.
- **Standard keymap** — modeless VS Code-style editing with multi-cursor
  (`Ctrl-D` add-next-occurrence, `Ctrl-Alt-↑/↓` column cursors), familiar
  chords, and the same config-driven rebinding.
- **Editor essentials** — undo/redo (persisted per file), system clipboard,
  word-wrap, auto-indent, auto-pairs, bracket-match highlight, code folding
  (manual + LSP-suggested), `.editorconfig` support, snippets with tab-stops,
  trailing-whitespace tools.

## Panes, splits & tab pages

- **Recursive split tree** — editors, terminals, diffs, and every tool view are
  `Pane`s laid out in a binary split tree. Split side-by-side or stacked.
- **Window management** — vim `Ctrl-W` chords (focus, move, resize, rotate,
  equalize, maximize), mouse click-to-focus and drag-to-resize dividers.
- **Tab pages** — vim-style `:tab*` pages, each with an independent split tree;
  a bufferline tab strip; session-persisted across launches.
- **Buffer management** — a tabline of open buffers, MRU buffer switching,
  reopen-closed-buffer, recent-files picker, alternate-file jump.

## File manager

- **Files pane** — a directory listing as a first-class `Pane`
  (`files.open`), so a browser is just another thing you can split, tab,
  and arrange; `files.open_split` opens a second one beside it for a
  Commander-style dual layout. Navigation, three sort orders
  (dirs-first-name / size / modified), a hidden-file toggle, a clickable
  breadcrumb with a destinations picker (Home / Downloads / volumes /
  workspaces / recents), per-row git status badges, `p` to preview a file
  without leaving the listing, and a `/`-filter. The same `file.*`
  operations that work from tree focus (below) also act from a focused
  Files pane. `src/file_browser.rs` + `src/ui/file_browser_view.rs` +
  `src/app/file_actions.rs`.
- **Multi-select** — `Space` marks the row under the cursor, `a` marks
  all, `Esc` clears; every file operation acts on the marked set.
  Ctrl/Cmd-click toggles one row, Shift-click extends a range; the
  right-click menu acts on the marks rather than the row under the
  cursor. Marks are keyed by path (not index), so they survive a
  re-sort, a reload, a hidden-file toggle, or navigating away and back.
- **Background transfers** — copy and move run on a worker thread
  (`src/transfer.rs`) instead of the render thread, so a large directory
  no longer freezes the editor. A statusline chip shows progress and
  speed while a transfer is running (hidden when idle);
  `transfer.cancel_all` cancels every in-flight transfer from the
  palette; `:qa` refuses to quit mid-transfer.
- **Undoable delete / workspace trash** — a delete moves the entry to
  `<workspace>/.mnml/trash` instead of removing it outright; the confirm
  modal also offers "Delete permanently" to skip the trash. `files.trash`
  opens the trash as a Files pane; `files.restore_from_trash` puts the
  selected entry back where it came from. Bounded: entries older than 7
  days are pruned, the trash is capped at 512 MB total (oldest evicted
  first above that), and anything at least 256 MB skips the trash and is
  deleted directly rather than trashing something the size cap would
  immediately evict.
- **Editor breadcrumb** — a directory-path row above the buffer; each
  path segment is clickable and opens a Files pane at that directory
  (parity with the Files pane's own breadcrumb, which was already
  clickable).

## Navigation & search

- **Fuzzy pickers** — file finder, command palette, buffer switcher, symbol
  picker, marks/clipboard/recent-commands pickers — all over one fuzzy core.
- **Which-key leader popup** — a discoverable trie of leader-key chords.
  Root groups: `f` find, `b` buffer, `t` toggle (explorer, right panel,
  hidden files, vim⇄standard, theme picker), `g` git, `h` http, `T` test,
  `L` lang-run (`c` cargo / `n` npm / `p` pytest / `g` go, each its own
  subgroup), `P` PR (cross-host picker + refresh), `i` integrations
  (detail pane, `htop`/`iftop`/`btop` launchers, icon picker,
  enable/disable), `a` AI/term, `s` split, `l` LSP, `I` snippet insert, `H`
  harpoon (plus `1`–`9` direct jumps), `c` cheatsheet. Root-level leaves
  (no second key): `/` toggle comment, `n` line-number gutter, `?`
  cheatsheet, `w` save, `B` open browser, `q` close buffer, `e` explorer,
  `m` markdown preview, `p` command palette, `o` run task. The per-forge
  chords that used to live under `i` (one letter per Bitbucket / GitHub /
  S3 / Lambda / … sibling) were dropped 2026-08-03 — each marketplace
  integration now registers its own command and chord via its manifest
  instead of a hardcoded binding here.
- **Find & replace** — in-buffer find (literal + regex, smart-case,
  incremental), replace, find history.
- **Workspace grep** — ripgrep-backed project search into a results pane, with
  cross-file replace and a per-hit toggle.
- **Quickfix & location lists** — vim-style `:cnext`/`:cprev` navigation.
- **Multi-root workspaces** — several workspace roots and multiple git repos in
  one session, with a repo switcher. The "Open folder…" (`AddWorkspace`) prompt
  shows a live-filtered directory listing (up to 12 suggestions): `↑↓` navigate,
  `Tab` autocomplete from focused row, `Enter` accept. Tilde expansion; dotfiles
  hidden unless the typed prefix asks for them. Other prompt kinds are unaffected.

## Language intelligence (LSP)

- **Completion** — as-you-type popup with documentation, lazy
  `completionItem/resolve`, snippet-format items.
- **Navigation** — go-to definition / declaration / type-definition /
  implementation, find references, document & workspace symbols, an Outline pane.
- **Diagnostics** — inline gutter signs, a Problems pane, `]d`/`[d` navigation,
  external-linter integration (eslint, ruff, shellcheck, …).
- **Code actions** — quick-fix, refactors, organize-imports, with a picker.
- **Rename** — with an inline preview and a cross-file confirmation pane.
- **Hover, signature help, inlay hints, semantic tokens, document colors,
  code lens, document links** — the standard LSP surface.
- **Hierarchies** — call hierarchy (incoming/outgoing) and type hierarchy
  (super/sub-types).
- **Formatting** — LSP formatting, format-on-save, on-type formatting,
  `willSaveWaitUntil`, plus external formatters (rustfmt, prettier, gofmt, …).
- **Tools picker** — a Mason-style installer view listing every LSP / formatter
  / linter mnml looks for, with install hints.

## Git

- **Gutter & statusline** — per-line add/modify/remove signs, a branch chip with
  ahead/behind and file-status counts, a clickable provider badge.
- **Diff pane** — Hunk / Inline / Split views, per-hunk stage / unstage /
  discard, intraline highlighting, a `/`-filter, change-density minimap.
- **Staging view** — `git status` unstaged/staged lists, stage/unstage whole
  files or dive into hunks, commit from inside the IDE.
- **Commit graph** — a coloured-lane commit DAG with a
  right-side detail panel, sortable columns, branch/date/author/subject filters,
  hash-jump, and a working-tree (WIP) row with interactive staging buttons.
- **Branch rail** — a collapsible rail of branches / worktrees / open PRs;
  checkout, create, delete, and worktree management.
- **Sync** — fetch / pull (ff-only) / push, cherry-pick, revert, tags, stash
  list & reflog pickers, an operation-level undo/redo stack.
- **Blame** — a per-line `<sha> <author>` gutter.
- **AI commit messages** — summarise the staged diff into a conventional-commit
  message, recompose `HEAD`'s message, via the `claude` CLI or Codex.
- **Browse** — open the current file / commit on the remote (GitHub, GitLab,
  Bitbucket, Azure DevOps).
- **Cross-host PR picker** — `pr.picker` fans out to whichever
  `mnml-forge-*` integration siblings (Bitbucket / GitHub / GitLab /
  Azure DevOps) are installed, merges their open PRs into one picker
  (Enter opens the PR URL, Tab jumps to its pipeline run), backed by a
  background-refreshed cache (`pr.refresh`). Per-host Pipelines/builds
  dashboards, PR reviewer/approval detail, and CI log viewers live in
  those standalone `mnml-forge-*` binaries, not in mnml core — the SCM
  hosts were split out of core in June 2026 (`src/scm.rs`).

## TODOs, notes & findings

Three activity-bar list panels sharing one design (`src/ui/{todos,notes,
findings}_panel.rs`, `src/ui/list_sort.rs`).

- **TODOS panel** — scans `TODO`/`FIXME`/`XXX`/`HACK`/`REVIEW` markers from
  source-code comments AND markdown list items (a bare `- TODO: …` line
  counts) across the workspace, plus Playwright/Jest `.fixme(`/`.fail(`/
  `.skip(` call sites. Rescans on filesystem changes, throttled to one
  scan per 2 seconds. `+ New todo` (`todos.new`) appends a line under a
  `## Inbox` heading in the workspace's `TODO.md` (creating both if
  absent). Right-click a hit for an action menu that hands it to
  whatever agents/commands/skills the workspace's own `.claude/`
  directory declares, or falls back to "Fix with Claude Code" / "Fix
  with Codex".
- **NOTES / FINDINGS panels** — the same list shape over `.mnml/notes/`
  and `.mnml/findings/`. `+ New note` (`notes.new`) / `+ New finding`
  (`findings.new`) open a NewFile prompt pre-seeded with the next
  auto-numbered filename (`note-N.md` / `finding-N.md`), so Enter is
  fast and typing over it is still possible.
- **Shared panel chrome** — a caps header with a live count (`(N)`, or
  `(M of N)` while filtered), a `/`-focus filter row, a focused-row
  accent bar, a scrollbar, and keyboard/wheel/drag scrolling. Right-click
  the `⟳` chip (shared with the Git / Agents / Cloud Agents / HTTP
  panels) for "Refresh now", "Auto-refresh: on/off" (persisted per panel
  via `[ui] auto_refresh_off`), and — TODOS/NOTES/FINDINGS only — a sort
  toggle between Newest-first and Name A–Z (persisted as `[ui]
  todos_sort` / `notes_sort` / `findings_sort`).

## AI

> mnml *integrates with* AI tooling — it does not bundle a model. These
> features describe what mnml does; you bring your own CLI / API key.

- **AI panes** — run the `claude` CLI or Codex as embedded panes; tail their
  session transcripts; promote a one-shot answer into an interactive session.
  `ai.claude_code_focus` focuses the running Claude Code session (starting one
  if none is open) rather than always spawning a new one.
- **On-selection actions** — explain / fix / refactor / write-tests on a
  selection; a free-text "ask"; results stream into a pane and a fix/refactor can
  be applied as a reviewed diff.
- **Two backends** — drive the `claude` CLI in print mode, or talk to the
  Anthropic Messages API directly (with an agentic read-only tool loop). The
  backend, model name, system prompt, and token cap are all config knobs.
- **Inline suggestions** — opt-in Copilot-style ghost text: an API backend, or a
  fully local, in-process FIM model via the bundled `mnml-fim-engine` crate (no API
  key, offline after a one-time download). Off until you turn it on — via the
  first-launch wizard, `ai.setup_suggestions`, or Settings → AI. The remote
  backends send buffer context around the cursor, so files whose names look
  secret-bearing (`.env`, `id_rsa`, `*.pem`, `*credentials*`, …) are never sent
  regardless of the setting; the local backend is exempt since nothing leaves
  the machine.
- **Context-aware chat** — a claude-chat.nvim-style wrapper that seeds a prompt
  with the active file and selection.
- **Launch profiles** — multiple named launch commands per Claude/Codex chip
  (`[[launch_profile]]` + `default_profile` in the integration manifest,
  user-global or workspace-scoped). Right-click the chip to fire a one-off
  session with any profile or to persist a new default; the legacy
  "Set launcher script…" single override still works as the `wrapper` profile.

## Terminal & process panes

- **Pty panes** — a shell, the `claude` CLI, Codex, or any task as live terminal
  panes, with a multi-session tab strip and `:rename`.
- **Pty tabs in bufferline** — terminal and Claude Code sessions get bufferline
  tabs with a `$` suffix and a close button. `:bn` / `:bp` skip Pty tabs so vim
  users don't get trapped cycling through terminal sessions.
- **Scratch terminal** — a quick docked terminal strip.
- **External tool launchers** — `tools.htop`, `tools.iftop`, `tools.btop` (also
  `term.htop` / `term.iftop` / `term.btop` aliases) probe `$PATH`, open the tool
  in a Pty pane if found, or fire a platform-aware install hint toast (Homebrew on
  macOS, apt on Linux, winget on Windows) if not.
- **Tasks** — `[tasks.*]` config + a task launcher; startup tasks.

## Dock widgets

- **Three-tier UI** — full panes (split-tree) / dock widgets (corner-pinned
  mini-panels in the editor body) / status chrome. The middle tier is for
  things you want visible next to the buffer rather than instead of it.
- **Four corners** — `BottomLeft` / `BottomRight` / `TopLeft` / `TopRight`.
  Widgets sharing a corner stack inward (bottom corners upward, top corners
  downward); per-corner stack capped at 50 % of the editor height.
- **Content variants** — `Text` (static, via `dock.new_text*`) and `LogTail`
  (per-frame re-read of a file's last N lines, via `dock.new_log_tail`;
  default path `<workspace>/.mnml/run.log`). The title bar shows a `▼N`
  chip when the file has more lines than fit.
- **Size presets** — Small (0.25 × 0.15) / Medium (0.5 × 0.25, default) /
  Large (0.5 × 0.4) / Wide (0.9 × 0.25) / Tall (0.5 × 0.5). Fractions clamped
  to `0.15..=0.9`.
- **Layout modes** — `Overlay` (default; paints on top of the editor) and
  `Inline` (claims a strip at the top/bottom edge; editor reflows around it).
  Multiple inline widgets at the same edge tile horizontally; combined strip
  heights capped at 50 % of editor height.
- **Opacity modes** — `Solid` (default; full bg) and `Translucent` (skips body
  bg so editor text shows through; title + border keep their bg).
- **Kebab menu** — `⋮` glyph at the right end of the title bar (also right-click
  the widget body). Sections: Resize / Move to / Layout / Opacity / Rename… /
  Close. Current values get a `●` marker; the highlight pre-positions on the
  row that matches the widget's current state. Drops up when it would clip
  into the statusline.
- **Drag-to-move** — click + hold the title bar; a cyan ghost chip `⇲ <title>`
  follows the cursor, and a translucent `░` overlay paints on the actual
  landing rect (with a `⤴ Top-left` / `⤵ Top-right` label) so the drop target
  is unambiguous. Magnetic snap within 8 cells of another widget's body
  center: the dragged widget inherits the target's corner and reorders in
  the vec to sit adjacent (above if cursor was above the target's center,
  below otherwise).
- **New dock note lives in the `+` menu.** An earlier faint ` + dock `
  chip painted over the bottom-right of the editor body — on top of
  whatever pane's last row was there, so clicking a file in a Files pane
  could spawn a sticky note. Removed 2026-08; "New dock note" is a row
  in the shared `+` menu instead, which covers nothing and is always in
  the same place.
- **Session persistence** — the widget vec (positions, sizes, corners,
  content, layout, opacity) round-trips through `.mnml/session.json`. Older
  session files without the layout / opacity fields default to `Overlay` /
  `Solid` cleanly via serde.

## HTTP request client

- **Request files** — send `.http` / `.rest` / `.curl` files, with multi-block
  files, `{{variable}}` templating, environments, and pre/post-request scripts
  (`@set-*`, `@assert`, `@capture`).
- **Request pane** — an editable, form-style pane (method / URL / headers /
  body), re-send, copy-as-curl, and write-back to the source file. The Edit
  view is **tabbed** — Body / Headers / Params / Vars / Source — with
  `Ctrl+]` / `Ctrl+[` cycling and `Ctrl+1..5` for direct jumps.
- **Side-by-side edit split** — the `[⇔]` chip on the Request block's border
  row opens a two-pane view of the edit area. Left = current primary tab,
  right = a secondary tab you pick (any of Body / Params / Headers / Auth /
  Vars / Source). Both sides operate on the same underlying request, so
  edits in one are visible in the other. Right side has its own clickable
  tab strip so any combination works (Body|Vars, Params|Body, Auth|Headers).
  Click the 1-cell divider to cycle the ratio 30 / 50 / 70. Palette command
  `http.toggle_edit_split`.
- **`{{VAR}}` highlighting + click-to-def + hover** — variable tokens across
  the URL, Body (JSON + plain), Params values, and Headers values render
  cyan-bold when resolved, red-bold when the active env is missing them.
  Left-click a token jumps to its definition line in
  `.mnml/env/<active>.env` (falls back to `.rqst/env/<active>.env`; opens
  at end-of-file when undefined so you can append). Right-click opens a
  quick-fix menu: "Set value…" seeds the env-edit prompt (accept upserts
  into the active env file), "Jump to definition", "Copy variable name".
  Hover shows the resolved value or "not defined in active env" so you can
  scan a request for missing envs at a glance. Dynamic vars like
  `{{$uuid}}` / `{{$timestamp}}` render as resolved but skip the Set-value
  menu since they're built-ins.
- **HTTP activity-bar panel with `/` filter** — the seven-section HTTP
  sidebar (COLLECTIONS / FILES / ENVS / CHAINS / MOCKS / RECENT / CAPTURED)
  gains a `/`-focus filter row at the top, matching the Agents / Cloud
  Agents idiom. Typing narrows across every section; for COLLECTIONS a
  matching request-name keeps its collection visible and force-expands the
  chevron so hits show without an extra click.
- **Blank request scratch** — `:http.new` (or the green `+` chip in the
  INTEGRATIONS rail) opens an empty Request pane in Edit mode, no file
  backing. Postman-style entry point.
- **Paste curl** — `:http.paste_curl` (also `Ctrl+Shift+V` in Edit view, or
  right-click a field → "Paste curl from clipboard") reads the clipboard,
  parses it as curl / `.http` / `.rest`, and overwrites the active pane's
  Method / URL / Headers / Body. Opens a blank pane first if none active.
- **Field-aware right-click menu** — Send / Paste curl / Copy as curl /
  Switch to Response, with per-field title (`Request · URL` / `· Method` /
  etc) and an extra "Cycle method" entry on the Method row. Same menu
  fires from every tab's content area.
- **Cycle method** — `:http.cycle_method` (also Space when Method field is
  focused) walks through GET → POST → PUT → PATCH → DELETE → HEAD → OPTIONS.
- **SSE streaming** — `:http.send_streaming` opens the request over an SSE
  reader (per-event newline buffering, no overall timeout for SSE servers
  that hold the socket).
- **Cookies normalizer** — `:cookies.normalize_clipboard` collapses any of
  the three DevTools cookie-paste shapes (`name=val` per line,
  `name: val` per line, or canonical `name=val; name=val`) into the
  on-the-wire `name=v; name=v` form, written back to clipboard.
- **Env files** — `.mnml/env/<name>.env` (preferred) and `.rqst/env/<name>.env`
  (legacy, ported from rqst). `.mnml/` overrides on the same key; resolution
  chain is `--env` → `$MNML_ENV` → `.rqst/config`'s `default_env`.
- **Chains** — run a `.chain.json` of dependent requests, extracting values
  between steps.
- **Discover** — turn an OpenAPI / Swagger spec into one `.curl` stub per
  operation.
- **Sources sync** — `.mnml/sources.json` (or `.rqst/sources.json`) lists
  swagger sources; `:http.sync` regenerates every `.curl` stub from upstream
  on a background thread.
- **Bench** — `:http.bench` fires the active request 10× concurrent on a
  background thread, full p50/p95/p99/max trace to the clipboard, summary
  headline toasts.
- **Mocks** — `:http.save_mock` writes the active Done response to a sibling
  `<source>.curl.mock.json`; `:http.replay_mock` serves it back as if it were
  a live send (no network call).
- **History** — every send (Ok or Err) appends to `.rqst/history.jsonl`;
  `:http.history` opens a picker over the last 100 entries, Enter scratches a
  re-fire-ready `.curl` buffer.
- **Captured browser traffic** — when a Browser pane is open, every network
  request auto-appends to `.rqst/captured/log.jsonl` (default on; toggle with
  `[browser] autocapture_to_log` or `:browser.autocapture_toggle`).
  `:http.view_captured` opens a picker, Enter scratches a `.curl` for re-fire.
  `:http.capture_now` also dumps the pane's current NetEntry list on demand.
- **Lookup picker** — `:http.lookup` walks a multi-stage UI: pick a `.curl`
  under `.rqst/lookups/` → fire it → pick an item from the response list →
  type a var name → writes `<var>=<id>` to the active env file.
- **Env editor** — `:http.edit_env` opens a structured picker over every
  `KEY=VALUE` row in the active env file plus a `+ Add new variable…` row.
  Reads both `.mnml/env/` and `.rqst/env/` files (with `.mnml/` precedence);
  writes back to whichever file the key currently lives in.
- **Helpers** — `:jwt.decode` (clipboard JWT → claims + EXPIRED flag);
  `:auth.extract_bearer` (clipboard text → bare token);
  `:sse.parse_active_response` (parse Done body as SSE events + summarize).
- **CLI mode** — `mnml run FILE`, `mnml chain run FILE`, `mnml discover SPEC`,
  `mnml sync [--workspace DIR]`, `mnml proxy --url URL [--seconds N]`
  (headless Chrome CDP capture into `.rqst/captured/log.jsonl`).

## Browser & CDP capture

- **Browser pane** — launch Chrome over the DevTools Protocol; a live console,
  filtered network log, and navigation log.
- **Inspectors** — network requests (copy-as-curl, re-send as a request pane),
  a DOM tree with live highlight, cookies, web storage, and a performance panel
  — all with type-to-narrow filters.
- **Capture** — full-page and per-node screenshots, print-to-PDF, snapshot
  diffs, device emulation, multi-target and headless support.

## Debugging (DAP)

- **Debug Adapter Protocol** — launch or attach a debug adapter; breakpoints
  (incl. conditional & hit-count), step controls, an exception-breakpoints
  picker.
- **Inspection** — a call-stack pane, a variables tree with set-variable, watch
  expressions, and a REPL pane with lazy-expand. Reverse-debugging where the
  adapter supports it.

## Testing & quality

- **Playwright runner** — run tests, a grouped results pane, jump-to-source, a
  trace timeline viewer, a flaky-test dashboard with run history.
- **`.test` E2E format** — a line-based DSL (`open`, `key`, `type`, `command`,
  `click`, `expect screen …`) that drives the real `App` against a virtual
  backend. Runs via `mnml test` and under `cargo test`.

## UI & theming

- **NvChad-style chrome** — file-tree rail, bufferline, powerline statusline,
  cmdline bar, which-key, indent guides, sticky scope context.
- **Local file actions** — `file.cut` / `file.copy` / `file.paste` /
  `file.duplicate` / `file.move_to` cover the standard file-manager surface
  from tree focus (Ctrl+X / C / V / D chords, plus the right-click menu).
  Cut+Paste renames (move, clipboard clears); Copy+Paste duplicates (recursive
  for directories, symlinks preserved on Unix; clipboard sticks so the same
  set can paste elsewhere); same-dir Copy bumps to `-copy` / `-copy-N` instead
  of clobbering. Move-to opens a path prompt with autocomplete and `~`
  expansion. Tree drag-and-drop works too — plain drag prompts "Move to X?"
  before renaming, and `Alt`-drag copies immediately without a confirmation
  (Finder / VS Code convention).
- **Optional right side panel** — a collapsible panel on the right edge; toggle
  with `Ctrl+Shift+B` or click the EC00 icon in the palette bar, or `:set
  rightpanel` (idempotent enable) / `:set rightpanel!` (toggle) / `:set
  norightpanel` (disable). Drag the left-edge grip to resize. State (visible +
  width) persists to `session.json`; defaults configurable via `[ui]
  right_panel_visible` and `[ui] right_panel_width`. Palette command:
  `view.toggle_right_panel`. Which-key chord: `<leader>tr`.
  When visible, `outline.show` and `lsp.diagnostics` host their pane inside
  the panel instead of splitting the editor body — the editor keeps full
  width and the panel header switches between OUTLINE / DIAGNOSTICS. A `×`
  on the header evicts the hosted pane (panel stays open, returns to the
  empty-state copy that teaches the two commands).
- **Keyboard right-click** — `Shift+F10` opens the context menu for the
  focused element. Routes Focus::Tree → tree-row menu, Focus::Pane →
  bufferline tab menu, and falls back to the cursor's most-recent hovered
  chip (integration / launcher / activity-bar gear). Palette command:
  `view.context_menu_at_focus`. Mirrors VS Code + macOS convention.
- **Palette bar redesign** — sidebar toggle (EC02 codicon) + right-panel toggle
  (EC00 codicon) + flat-rendered integration chips between the workspace chip and
  the right cluster + add-integration `+` (EA7C codicon). At narrow widths the
  right cluster drops TABS rather than vanishing entirely.
- **Menu glyphs** — every context-menu row draws an icon by default
  (`src/ui/menu_glyph.rs`); `[ui] ascii_icons = true` blanks them all so
  the menu is pure text. `menu.glyph_audit` writes and opens a
  spacing/icon audit covering every menu in the app.
- **Context-menu submenus + a curated `+` menu** — a context-menu row can
  open a nested submenu. The `+` chip's "new thing" menu is organised
  into five sections rather than ~15 flat rows; each row carries a kebab
  to pin, hide, or copy its command id, and the layout persists
  (`[ui] plus_menu_pinned` / `plus_menu_hidden`).
- **External browser override** — `[ui] external_browser = "Google
  Chrome"` opens external links (git remote browse, etc.) in a named
  application instead of the OS default; an untrusted workspace cannot
  set this key for you.
- **94 themes** — the full NvChad base46 set (onedark, gruvbox, catppuccin,
  kanagawa, tokyonight, nord, dracula, …); switch at runtime.
- **Discoverability** — an F1 click-discovery overlay, hover tooltips on every
  chip (hover any chip for a description; right-click for a context menu with
  actions), right-click context menus throughout, a first-launch welcome, About &
  Settings overlays.
- **Markdown** — a live preview pane with inline image embedding, and
  optional inline-rendered markdown in the editor (`render_markdown`,
  off by default; `view.toggle_render_markdown`). `[ui]
  markdown_opens_rendered` (default on) opens `.md` files straight into
  the rendered preview pane rather than the raw editor.
- **Preview tabs** — opening a markdown file, an image/GIF, or an
  `.http`/`.curl`/`.rest` request from a single click (tree, Files pane,
  a jump) reuses a *preview* tab that the next glance replaces, instead
  of piling up permanent tabs for things you were only looking at.
  Typing edits the tab permanent; on a rendered markdown preview, typing
  first swaps it to the raw editor and lands the keystroke there — under
  the standard keymap only, vim input does not auto-swap on the first key.
- **Image rendering** — inline images via the Kitty / iTerm2 graphics protocols.
- **Now-playing transport chip** — the statusline's right-side cluster splits
  into `[play/pause]` + `[ffwd]` + `[track]` adjacent segments when any source
  is playing. Source-aware dispatch — mixr uses its `~/.mixr/command` IPC
  (`pause`, `teleport`); Apple Music and Spotify use AppleScript via
  `osascript` (`playpause`, `next track`, `activate`) with a hardcoded source
  whitelist. macOS sources combine `artist - title` in the track text. A 10-s
  stickiness layer papers over mixr's mid-transition empty reads so the chip
  doesn't flicker. Idle collapses to one `♪ <app>` chip — label and click
  destination follow `[ui] preferred_music_app` (`mixr` / `music` / `spotify`,
  default `mixr`).
- **Mixr panel size chips** — the `♪ mixr` panel's header carries three
  right-aligned chips for snapping between size states: `⤢` grow (to
  `Full`), `⤡` shrink (to `BottomStrip`, only from `Full`), `–` minimize.
  Click handlers run before the header's drag detector so the chips don't
  get eaten by a window-drag start. The minimize chip releases focus back
  to the editor; grow and shrink keep focus on the panel.
- **Stress meter** — a small 4-block bar in both the top-right
  bufferline cluster and the bottom-right statusline that fills as
  mnml's p95 frame time climbs (green under 20/100, yellow to 40,
  orange to 70, red above). Hidden when idle. Hover shows exact
  `p50 / p95 / max` in ms plus the sample count; right-click opens
  Reset / Copy summary / Toast the numbers. Backed by a rolling
  120-sample window (`App.frame_times_ms`) populated by the main
  loop after each tick+draw+event-wait cycle.
- **Click-to-dismiss toasts** — click a toast to remove it; right-
  click for a menu with dismiss-this / dismiss-all / copy-text.
  The Undo chip beside the toast stack commits on left-click and
  cancels on right-click.
- **Notification history** — every toast is recorded to `:messages`
  (`messages.show` opens a picker over recent entries; `:Messages!`
  dumps the full log into a scratch buffer) and now persists per
  workspace across restarts. A bell chip sits immediately left of the
  clock in the statusline, always drawn, in three states: quiet/idle
  colours when nothing is unread, yellow with a count for unread
  warnings, red with a count when any unread entry is an error — info
  messages don't light it.
- **Zen mode**, a clickable statusline.

## Workspace trust

- **Repo-supplied config is gated before it can run anything.** A workspace's
  own `.mnml/config.toml` can name programs mnml would execute — language
  servers (`[lsp.*] cmd`), formatters and linters, debug adapters,
  `[ui] md_preview_engine = "custom:…"`, `[[startup.layout]] kind = "pty"` —
  and `.mnml/integrations/*.toml` can register commands, launch profiles, and
  spawn `[env]`. mnml scans for exactly those keys on open and asks before
  honouring any of them, so cloning a repo and opening it can't run code.
- **Quiet by default.** The scan means an ordinary repo — no `.mnml/`, or one
  with only themes and keymaps — never prompts. You see the dialog only when a
  workspace actually declares something executable, which is what keeps it
  worth reading rather than reflexively dismissing.
- **The dialog shows the actual commands**, what each one is, and when it would
  fire ("runs when you open a file", "runs immediately, on open"). "Don't
  trust" is focused by default.
- **Untrusted is restricted, not broken.** Only the exec-bearing keys are
  dropped; the same file's theme, keymaps, and editor settings still apply, and
  your global language servers and formatters keep working. A `RESTRICTED` chip
  in the statusline says why something isn't running.
- **Trust is fingerprinted**, so approving a workspace today doesn't bless
  whatever a later `git pull` adds — if the declared commands change, mnml asks
  again. Cosmetic config edits don't re-prompt. Decisions live in
  `~/.config/mnml/trusted_workspaces.toml`, keyed by canonical path (never in
  the workspace, which the repo itself could write). `workspace.review_trust`
  reviews or revokes.

## Headless, IPC & extensibility

- **Headless mode** — `mnml --headless` renders to a virtual screen, driven over
  a file-IPC channel (`command` in, `screen.txt` / `status.json` /
  `events.jsonl` out) — the same `App` and draw path as the terminal UI.
- **Plugins** — out-of-process helpers over the IPC channel can register
  commands that appear in the palette and resolve as keybindings.
- **Integration tools** — `:term <binary>` spawns an integration
  (`mnml-tracker-jira`, `mnml-aws-cloudwatch-logs`, `mnml-aws-amplify`,
  `mnml-db`, `mnml-aws-lambda`, `mnml-aws-eventbridge`, and ~25 more in
  the `mnml-integrations` monorepo) as a Pty pane.

  Each integration declares its own palette command in the manifest its
  `--install` writes, so the ids live with the integration, not in mnml
  core: `lambda.open`, `amplify.open`, `cloudwatch_logs.open`,
  `eventbridge.open`, `db.open`. They resolve as dynamic commands once
  that integration is installed, and `integrations.refresh` re-scans
  without a restart.

  Add a custom integration by dropping a `[[ui.integration_icon]]` entry
  in config — no code changes to mnml required.
- **Settings overlay** — `:settings` / `view.settings` opens a keyboard-driven
  overlay (centered, ~60 % × 70 %) for everyday config toggles. Rows are
  `▸ <label>: [active] / other  *`; section headers `── UI ──` etc. Keys:
  `←→` adjust, `↑↓` move, `r` reset row, `R` reset all, `Enter` save, `Esc`
  cancel. Includes rows for right panel visible (default on) and right panel
  width.
- **Config-driven launcher-icon strip** — the bufferline's right cluster is
  driven by `[[ui.launcher_icon]]` TOML entries (`id`, `glyph`, `fallback`,
  `command`, `color`, `tooltip`). The `command` field accepts a registered
  command id or a colon-prefixed ex-cmdline string (`:term binary`).
  Setting the key replaces the built-in Claude Code + Codex defaults.
- **Config-driven integration-icon rail** — the file-tree rail's icon strip is
  driven by `[[ui.integration_icon]]` TOML entries (same fields as
  `[[ui.launcher_icon]]`). Each icon launches its sibling binary on click.
  Default entries ship for all first-party siblings; extras can be added via
  TOML or the Marketplace tab — no code changes to mnml required.
- **`+` "Add integration" chip** — the `+` chip in the palette bar opens the
  Marketplace tab (`integrations.show_marketplace`), which lists published
  apps plus any `mnml-<class>-<name>` binaries auto-discovered on `$PATH`,
  with per-row install / update actions.

  The separate centered "discovery overlay" this chip used to open was
  dropped on 2026-07-03 — the activity-bar side panel (Installed /
  Marketplace tabs, filter, per-row Enable / Edit / Move-up / Remove menu)
  already covered browse + enable + edit + install, so the overlay was a
  redundant second copy.
- **Integration `enabled` opt-in** — each integration chip in the palette bar
  carries an `enabled` flag (default `false`; `browser` is enabled by default).
  Right-click a chip → Enable / Disable toggles the flag and persists the change
  to TOML. Palette command: `integrations.toggle_enabled`. Which-key chord:
  `<leader>iE`. Disabled chips are rendered visually dim and do not launch on
  click; they can still be edited or removed via the kebab menu
  (`integrations.edit` / `integrations.remove`). `<leader>ip` (icon picker) and
  `<leader>id` (detail pane) round out the integrations which-key group.
- **Icon picker** — `integrations.icon_picker` (palette command; `<leader>ip`)
  opens a browsable overlay of ~70 Nerd Font glyphs organized by category.
  Accepting a glyph copies the character and its `\u{XXXX}` escape to the
  clipboard. Used when adding or editing an integration icon.
- **Startup workspace picker** — `--startup-picker` (or `MNML_STARTUP_PICKER=1`)
  shows a chooser overlay on launch: [1] New file, [2] Open file…, [3–9]
  configured `[[workspaces]]` rows. Keys: `↑↓`/`jk` move, `Enter` commit,
  `1`–`9` direct jump, `Esc`/`q` skip. The `mnml.app` launcher enables this by
  default so Finder launches land on the chooser rather than `$HOME`.
- **Update-available check** — on launch, a background thread queries
  `api.github.com/repos/chris-mclennan/mnml/releases/latest` and fires a
  one-shot toast when a newer release tag is found. Opt out with
  `[ui] check_updates = false`. Skipped in headless mode.

## Languages

Tree-sitter syntax highlighting for **39+ languages** — Rust, JavaScript / TSX,
Python, Go, C / C++, Ruby, Java, C#, Lua, HTML / CSS, JSON, YAML, TOML, Markdown,
Bash, Scala, Elixir, Haskell, PHP, Swift, Zig, Nix, OCaml, Dart, SQL, Kotlin,
Dockerfile, HCL / Terraform, Protobuf, Vue, Svelte, Astro, diff, and more — with
**language injection** so fenced code blocks, embedded `<script>` / `<style>`,
and other nested grammars are highlighted too.
