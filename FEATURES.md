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

## Navigation & search

- **Fuzzy pickers** — file finder, command palette, buffer switcher, symbol
  picker, marks/clipboard/recent-commands pickers — all over one fuzzy core.
- **Which-key leader popup** — a discoverable trie of leader-key chords.
  Root groups: `f` find, `g` git, `b` buffer, `p` picker, `P` PR, `i`
  integrations, `a` AI/term, `s` split, `l` LSP, `I` insert, `t` tab, `w`
  workspace, `u` UI, `h` http, `d` diff/debug. `<leader>i` opens `+integrations`
  with chords for every forge/AWS/DB sibling: `b` Bitbucket, `g` GitHub, `l`
  GitLab, `z` Azure DevOps, `c` CodeBuild, `s` S3, `w` CloudWatch Logs, `a`
  Amplify, `d` DynamoDB, `L` Lambda, `e` EventBridge, `+` add integration, `p`
  icon picker, `e` enable/disable. `<leader>t` includes `r` (toggle right panel).
  `<leader>...b` maps to `tools.btop`.
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

## SCM & CI dashboards

- **Pipelines / builds** — recent runs for Bitbucket Pipelines, GitHub Actions,
  GitLab CI, and Azure DevOps, grouped by repo with per-branch and "mine" views.
- **Pull requests** — open PRs / MRs across all four hosts, with reviewer and
  approval counts, a cross-host PR picker, and PR ↔ pipeline cross-navigation.
- **Log viewers** — fetch and tail per-job CI logs with severity colouring.

## AI

> mnml *integrates with* AI tooling — it does not bundle a model. These
> features describe what mnml does; you bring your own CLI / API key.

- **AI panes** — run the `claude` CLI or Codex as embedded panes; tail their
  session transcripts; promote a one-shot answer into an interactive session.
- **On-selection actions** — explain / fix / refactor / write-tests on a
  selection; a free-text "ask"; results stream into a pane and a fix/refactor can
  be applied as a reviewed diff.
- **Two backends** — drive the `claude` CLI in print mode, or talk to the
  Anthropic Messages API directly (with an agentic read-only tool loop). The
  backend, model name, system prompt, and token cap are all config knobs.
- **Inline suggestions** — opt-in Copilot-style ghost text: an API backend, or a
  fully local, in-process FIM model via the sibling `fim-engine` crate (no API
  key, offline after a one-time download).
- **Context-aware chat** — a claude-chat.nvim-style wrapper that seeds a prompt
  with the active file and selection.

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
- **Empty-state chip** — a faint ` + dock ` chip at the bottom-right of the
  editor body when no widgets exist. Click to spawn a default Note 1.
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
- **`..` tree up-navigation** — a `..` row at the top of the tree (hidden at
  filesystem root) climbs the workspace root up one level via
  `set_workspace_to`, so tree / repos / git / integrations / palette-bar
  workspace chip all follow. Palette command `view.workspace_up`.
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
- **94 themes** — the full NvChad base46 set (onedark, gruvbox, catppuccin,
  kanagawa, tokyonight, nord, dracula, …); switch at runtime.
- **Discoverability** — an F1 click-discovery overlay, hover tooltips on every
  chip (hover any chip for a description; right-click for a context menu with
  actions), right-click context menus throughout, a first-launch welcome, About &
  Settings overlays.
- **Markdown** — a live preview pane with inline image embedding, and optional
  inline-rendered markdown in the editor.
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
- **Zen mode**, **stacked notifications**, a clickable statusline.

## Headless, IPC & extensibility

- **Headless mode** — `mnml --headless` renders to a virtual screen, driven over
  a file-IPC channel (`command` in, `screen.txt` / `status.json` /
  `events.jsonl` out) — the same `App` and draw path as the terminal UI.
- **Plugins** — out-of-process helpers over the IPC channel can register
  commands that appear in the palette and resolve as keybindings.
- **Sibling tool integrations** — `:term <binary>` spawns a sibling tool
  (`mnml-tickets-jira`, `mnml-aws-cloudwatch-logs`, `mnml-aws-amplify`,
  `mnml-db-dynamodb`, `mnml-aws-lambda`, `mnml-aws-eventbridge`, and ~15
  more in `family_catalog`) as a Pty pane. The integration-icon rail
  ships default entries for all of them; palette commands
  `forge.open_cloudwatch_logs`, `forge.open_amplify`, `forge.open_dynamodb`,
  `forge.open_lambda`, and `forge.open_eventbridge` are also registered.
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
  TOML or the `+` overlay — no code changes to mnml required.
- **`+` "Add integration" discovery overlay** — the `+` chip on the sidebar's
  INTEGRATIONS header (palette: `integrations.add`) opens a centered overlay
  listing the full family catalog (15 hardcoded siblings grouped by category:
  AWS, Databases, Forges, Trackers, Filesystems, Test runners) plus any
  `mnml-<class>-<name>` binaries auto-discovered on `$PATH` or well-known
  dirs. Per-row status: ✓ in rail / ✓ installed / ✗ not installed.
  Keys: `↑↓`/`jk` move, `Enter` add to rail, `i` spawn `cargo install` Pty
  pane live, `y` yank install command, `Esc` close. `integrations.refresh`
  clears the detection cache outside the overlay. `Enter` to add also
  writes the full `[[ui.integration_icon]]` list back to
  `~/.config/mnml/config.toml` (line-based strip-and-rewrite; other sections
  and comments preserved). Auto-discovered rows render with a
  `· auto-discovered` chip; `i`/`y` are no-ops for them (repo URL unknown).
- **Integration `enabled` opt-in** — each integration chip in the palette bar
  carries an `enabled` flag (default `false`; `browser` is enabled by default).
  Right-click a chip → Enable / Disable toggles the flag and persists the change
  to TOML. Palette command: `integrations.toggle_enabled`. Which-key chord:
  `<leader>ie`. Disabled chips are rendered visually dim and do not launch on
  click; they can still be edited or removed via the kebab menu
  (`integrations.edit` / `integrations.remove`). Which-key chords `<leader>i+`
  (add) and `<leader>ip` (icon picker) round out the integrations group.
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
