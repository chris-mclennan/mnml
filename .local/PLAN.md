# mnml — a NvChad-style terminal IDE (greenfield)

## Context

`/Users/chrismclennan/Projects/mnml1` was a first cut: Rust + ratatui TUI editor — NvChad onedark
reskin, tree-sitter highlighting, file tree, buffer tabs, embedded pty panes (shell / Claude Code /
Codex), hand-rolled vim modal editing. It briefly had *dual* editing modes (vim + standard) but that
got messy and commit `530a4bf` ripped it back to vim-only. mnml1's editor bones were themselves
carved out of `/Users/chrismclennan/Projects/rqst` — a ratatui "Postman in the terminal": curl/.http
parsing, request chains, assertions, `{{var}}` templating, OpenAPI→stub discovery, AI debug chat
(Claude/OpenAI API + Claude Code subprocess with tool use), file-IPC scripting surface
(`.rqst/ipc/command` ↔ `screen.txt`/`status.json`/`events.jsonl`), CDP browser-request capture, and
embedded pty panes.

We're starting fresh in the empty `/Users/chrismclennan/Projects/mnml`. The intent is **one IDE that
absorbs all of it** — a real editor *and* the rqst capabilities *and* a scriptable/testable surface —
built so the pieces compose instead of fighting each other. mnml1 and rqst are **reference
implementations** to port logic from, not dependencies and not copied verbatim.

Stack: ratatui + crossterm (TUI), portable-pty + vt100 (pty), tree-sitter (highlight),
reqwest + serde_json (HTTP), tungstenite (CDP), lsp-types + per-server subprocess (LSP). Single
binary. No Lua, no Neovim.

## What's in scope (confirmed with the user)

**Core (designed together up front):** editor with a pluggable input layer (VSCode-style **and** vim
keymaps, both fully remappable); `Pane` abstraction + a split-layout tree (side-by-side editors);
unified `Command` registry → command palette + which-key + keybinding resolution + plugin commands;
file-IPC channel + headless mode (virtual screen) + `screen.txt`/`status.json`/`events.jsonl`; TOML
config (theme / input style / keybindings / LSP server table / AI provider); mouse everywhere;
generic fuzzy picker overlay; NvChad onedark theme, devicons, tree-sitter highlight.

**Tracks (each self-contained, slot in when most useful):**
- **Vim handler** — modal Normal/Insert/Visual + `:` ex-commands (high priority, but a track because the standard handler is the core baseline).
- **LSP** — client subsystem; completion, go-to-def, hover, diagnostics, rename; config-driven server table.
- **Git (rich)** — status chip (early) → diff pane, stage/unstage hunks, blame gutter, commit from inside the IDE.
- **Search** — ripgrep-backed project search + search/replace, results into the picker.
- **Pty / AI-CLI panes** (the AI track) — shell, `claude` CLI, `codex`, as `Pane::Pty`; tail Claude Code's session JSONL (and Codex's if it has one) so a CLI pane and the in-IDE AI view share a conversation. **AI-on-selection actions** (explain / refactor / fix / write tests → a diff you accept) and **request-debug** (`Ctrl+.` on a failing request) are *one-shot `claude -p` subprocesses* (the CLI in print/non-interactive mode — does tool use, returns text, reuses the user's auth), not a raw-API client. **Decision:** the CLIs already do tool use / file edits / agentic loops / MCP and the vendors keep them current — re-implementing that as an API client (provider abstraction, tool registry, diff-approval UI, SSE streaming, rate-limit handling, key management) is a large surface for something that exists. So the AI track is pty + `claude -p`, no embedded API client.
- ~~**AI (API-based)**~~ — *deferred / probably skipped.* A raw Claude/OpenAI client (`ai/provider.rs`) would only earn its keep for fully headless/scripted AI in the `.test` harness with no subprocess, or for users who want OpenAI without the CLIs. Not gating anything; revisit behind `[ai]` config only if there's real demand.
- **HTTP** — request capability baked into mnml (its own `src/http/` modules — *port* rqst's logic, not a `rqst` crate dep): paste-a-curl, `.http`/`.rest`/`.curl` files into a `Pane::Request`, request chains, `@assert`/`@capture`, `{{var}}`/`{{$uuid}}` templating, OpenAPI→stub discovery, history; headless `mnml run file.curl` / `mnml chain run x.chain.json`.
- **CDP / web** — launch Chrome with remote debugging, JSON-RPC over WebSocket, capture network → curl, drive a page (navigate/click/eval); feeds the request pane *and* the E2E web tests.
- **E2E test format** — a declarative `.test` format (steps + expectations) run against the headless+IPC harness (and CDP for web flows); mnml's own UI test suite is written in it; reusable for testing other TUIs.
- **Plugin hooks** — external scripts connect over the IPC channel: register palette commands, subscribe to events (`events.jsonl`), send commands. Documented protocol.

**Later, not gated:** snippets, multi-cursor, code folding, session/workspace state restore, multiple themes, a startup dashboard/greeter.

## Guiding principles

- **One direction of dependency:** `keys → InputHandler → EditOp → Editor` for text; `keys → keymap → Command id → Command registry → App` for everything else; `App + ui::draw` are render-backend-agnostic so the *same* render path serves the real terminal and the headless virtual screen.
- **`Pane` and `Layout` exist from day one** (even when only one editor leaf is ever shown) so splits / pty / request / diff / ai panes are *additive*, never refactors.
- **The `Command` registry is the spine.** Every non-text-editing action is a named `Command` (id, title, default binding, handler, optional which-key group). Both keymaps resolve non-editing keys to command ids; the palette fuzzy-searches commands; which-key shows pending continuations; plugins register commands the same way. Adding a feature = registering commands + (maybe) a pane kind.
- **Mode coupling is fenced:** only the statusline (mode chip) and cursor-shape code read a 4-variant `EditingMode`; nothing can ask "is this the vim handler."
- **Subprocesses use the thread+channel model** (pty already does): LSP servers, ripgrep, git, Chrome/CDP each run on a thread (or a small thread pool), feeding the event loop via channels. No global async runtime unless LSP forces it — default to threads; revisit only if it gets unwieldy.
- **`String` + byte-cursor buffer** to start; all mutation behind `EditOp`/`Editor::apply` so `ropey` can slide in later without touching call sites.
- **No giant files** (mnml1's `tui.rs` ≈ 56k chars, rqst's `app.rs` ≈ 468k chars both rotted). `app.rs` is render-free; `tui.rs` is *only* the terminal event loop; chrome lives in `ui/`, subsystems in their own dirs.
- Every phase ends green: `cargo build && cargo clippy --all-targets && cargo test`.

## Module layout

(Phase-1 core modules are unmarked; later-track modules are listed with their track and stubbed until then.)

```
src/
  main.rs            Binary entry: subcommand dispatch — default = TUI (workspace dir, --input vim|standard, --ascii,
                     --config PATH); `mnml run FILE` / `mnml chain run FILE` (HTTP headless); `mnml test GLOB` (E2E runner);
                     `mnml ipc ...` (one-shot IPC command for scripts).
  lib.rs             Re-export modules for tests + a future `mnml` lib consumer.

  app.rs             Pure state: workspace path, panes: SlotMap<PaneId, Pane>, layout: Layout, focus: Focus, Tree,
                     toast, quit flag, pane_rects, command registry handle, config. NO rendering, NO event loop.
                     + the ex-command interpreter (delegates most to the Command registry).
  pane.rs            enum Pane { Editor(Buffer), Pty(PtySession), Request(RequestPane), Diff(DiffView), Ai(AiPanel) }.
                     ui::draw + the event router dispatch by pane kind; adding a kind is additive.
  layout.rs          enum Layout { Leaf(PaneId), HSplit(Box<Layout>,Box<Layout>,ratio), VSplit(...) } + the tree rail
                     + statusline are outside the split tree. Recursive render; Ctrl+W navigation; resize; rect calc.
  focus.rs           enum Focus { Tree, Pane(PaneId), Picker, Palette, Prompt } + cycle logic; which keys are pane-agnostic.
  config.rs          Load/merge TOML: ~/.config/mnml/config.toml + .mnml/config.toml + --config. Sections: [editor]
                     (input_style, tab_width, ...), [ui] (theme, ascii_icons, tree_width), [keys.vim]/[keys.standard]
                     (id → key, fully remappable), [lsp.<lang>] (cmd, args, root_markers), [ai] (provider, model, api_key_env),
                     [tools] (allow/deny for AI tool use). Hot-reload on save (later nicety).

  command.rs         Command { id: &'static str, title, group, default_keys: KeySpec, run: fn(&mut App, &CommandCtx) }.
                     Registry: id→Command map + a key→id resolver built from config (per keymap). Palette + which-key
                     read it; plugins register dynamic commands into it via IPC.

  editor.rs          TextStore (String + byte cursor) + motions + undo/redo (insert coalescing) + selection anchor.
                     Exposes only the methods EditOp maps to. No key handling, no command knowledge.
  edit_op.rs         enum EditOp { ... } + Editor::apply(EditOp, viewport_rows, &mut Clipboard) -> EditOutcome.
                     Single chokepoint: undo-grouping + dirty + clipboard policy live here.
  clipboard.rs       Thin arboard wrapper + internal register-string fallback (preserves vim line-yank vs char-yank).
  buffer.rs          Pane::Editor payload: path, Editor, scroll/h_scroll, dirty + saved_text, language_ext,
                     diagnostics: Vec<Diagnostic> (LSP), input: Box<dyn InputHandler>. feed_key(), editing_mode().

  input/mod.rs       trait InputHandler + EditingMode + CursorShape + InputResult + AppCommand + EditCtx + make_handler().
  input/standard.rs  StandardInputHandler — modeless, VSCode keymap baseline (arrows/Home/End/PgUp/PgDn, Shift-select,
                     Ctrl+C/X/V/Z/Y/A, Ctrl+←/→, Ctrl+Backspace/Del, Ctrl+D add-selection (later multi-cursor),
                     Ctrl+/, Ctrl+], Ctrl+[, Alt+↑/↓ move line, ...). Bindings come from config; this file is the
                     translation logic, not a hardcoded table.
  input/vim.rs       VimInputHandler — VimMode { Normal, Insert, Visual, VisualLine }; private pending/count/operator/cmdline.
                     ALL vim state private here. Bindings (the leader-key map, motions) configurable via [keys.vim].
  input/keymap.rs    KeyEvent → semantic key classification; KeySpec parsing ("ctrl+shift+p", "<leader>ff"); the
                     config-driven key→{EditOp | Command id} resolver shared by both handlers for non-text keys.

  picker.rs          Generic fuzzy-picker overlay (telescope-ish): source = Vec<Item> or a streaming channel; live
                     fuzzy filter; preview pane; used for file-open, command palette, buffer switch, project-search
                     results, git files, LSP symbols/refs, AI tool picks. Mouse + keyboard driven.
  palette.rs         Command palette = picker over the Command registry (titles + bindings shown). Ctrl+Shift+P.
  whichkey.rs        After a prefix/leader, a popup of the available continuations (NvChad-style). Reads the registry.

  tree.rs            File tree: lazy dir read, .gitignore-aware, expand/collapse, visible-rows flatten, selection,
                     "open under cursor" → PathBuf (app.open_path picks the Pane kind from the extension).
  git/mod.rs         Git subsystem. status.rs (porcelain parse, ~3s cache, branch + counts — early). diff.rs (parse
                     `git diff` into hunks; DiffView for Pane::Diff; stage/unstage via `git apply --cached`). blame.rs
                     (`git blame --porcelain` → per-line author/sha for a gutter mode). commit.rs (commit message prompt
                     → `git commit`). All shell out to `git`; degrade gracefully when absent.

  search.rs          Project search: spawn `rg --json` (or the `grep`/`ignore` crates), stream matches into the picker;
                     "replace in files" applies edits across buffers/files with a confirm step.

  lsp/mod.rs         (LSP track) LspManager: one LspClient per (root, language) keyed off [lsp.<lang>] config. Each client
                     = a subprocess + JSON-RPC over stdio on a thread, channel to the event loop. lsp/client.rs (lifecycle,
                     request/notification plumbing, lsp-types). lsp/handlers.rs (publishDiagnostics → buffer.diagnostics;
                     completion → picker/popup; hover → popup; definition/references → jump or picker; rename → workspace edit).
                     editor_view renders diagnostic squiggles + a gutter sign; statusline shows the worst severity.

  pty_pane.rs        (Pty track) portable-pty + vt100; BinaryProfile { shell | claude_code | codex } (claude/codex inject
                     .mnml project context like mnml1). Threaded read pump → channel. Pane::Pty. ai/claude_code.rs tails
                     the session JSONL these write so the in-IDE AI view stays in sync.

  ai/mod.rs          (AI track — pty + `claude -p`, NOT a raw-API client) ai/claude_code.rs (tail the Claude Code /
                     Codex session JSONL so the in-IDE view mirrors the CLI pane's conversation; emit into the same view).
                     ai/oneshot.rs (run `claude -p "<prompt>"` as a subprocess on a thread → capture stdout). ai/actions.rs
                     (on-selection commands: explain / refactor / fix / write-tests → feed the selection to `claude -p` →
                     show the answer, or parse a proposed patch → DiffView with accept/reject). ai/debug.rs (request-debug:
                     `Ctrl+.` on a failing request → `claude -p` with the request+response). Surface as Commands; Pane::Ai is
                     the conversation view (shared with the JSONL tail). [ai/provider.rs — a raw Claude/OpenAI client — is
                     deferred; only worth it for headless `.test` AI with no subprocess. Don't build unless asked.]

  http/mod.rs        (HTTP track) Request { method, url, headers, body }; send via reqwest (blocking); Response capture.
  http/curl.rs       Parse a pasted curl → Request. (Port rqst/src/curl.rs.)
  http/file.rs       Parse .http / .rest (REST Client format) and .curl files; auto-detect. (Port rqst/src/http_file.rs.)
  http/template.rs   {{VAR}} resolution: env files → dynamic {{$uuid}}/{{$firstName}}/... → process env; track unresolved. (Port rqst.)
  http/script.rs     @assert / @capture / @set-env / @set-header directives. (Port rqst/src/script.rs.)
  http/chain.rs      .chain.json sequences with JSONPath extraction. (Port rqst/src/chain.rs.)
  http/discover.rs   OpenAPI/swagger JSON → generated .curl stubs (the `discover` command). (Port rqst/src/discover.rs.)
  http/env.rs        .mnml/env/<name>.env loading; .mnml/history.jsonl append; .mnml/snippets, .mnml/requests, .mnml/lookups.
  request_pane.rs    (HTTP track) Pane::Request: Postman-ish field tabs (URL / Headers / Body / Params / Vars / Source),
                     response view (status, timing, formatted JSON, assertion/capture results). Editable fields delegate
                     to StandardInputHandler. Ctrl+R send · Ctrl+Y copy-as-curl · Ctrl+. AI-debug. ui/request_view.rs renders it.

  cdp/mod.rs         (CDP track) Launch Chrome with --remote-debugging-port; CdpSession over WebSocket (tungstenite),
                     JSON-RPC. cdp/launch.rs (find/launch Chrome, temp profile). cdp/fetch.rs (Network.* events → captured
                     requests). cdp/page.rs (Page.navigate, Runtime.evaluate, Input.dispatch* for click/type — drives a
                     page for web E2E tests). captured.rs (view captured requests; "copy as curl" / "open in request pane").

  ipc/mod.rs         File-IPC channel (port rqst's): watch .mnml/ipc/command (JSONL of commands), execute against App,
                     write .mnml/ipc/{screen.txt (rendered virtual screen), status.json (focus, panes, cursor, mode, diagnostics
                     counts, ...), events.jsonl (append-only log: keypresses, command runs, pane opens, http sends, ...)}.
                     Commands cover: open/close/save, key, run-command <id>, type <text>, palette <query>, http send/chain,
                     cdp <subcmd>, snapshot, wait-for <predicate>. Plugins and the E2E runner both speak this.

  headless.rs        Run loop without a real terminal: render via ratatui TestBackend into a virtual screen buffer; drive
                     entirely from the IPC channel; tick subsystems. Shares app.rs + ui::draw with tui.rs verbatim.

  ui/mod.rs          draw(frame, &mut App): layout (tree rail | recursive split tree of panes | statusline) + overlays
                     (picker / palette / whichkey / hover popup / completion popup / prompt line); fills app.pane_rects;
                     dispatches to sub-renderers by pane kind. Backend-agnostic (works over the real terminal and TestBackend).
  ui/theme.rs        NvChad onedark RGB palette: base16 slots BASE16_00..0F + named UI colors. (Multiple themes later.)
  ui/icons.rs        Nerd-Font devicon glyphs by ext/filename (default — Nerd Font is installed) + ASCII fallback (--ascii / [ui]).
  ui/tree_view.rs    File-tree rail: devicons, indent, expand chevrons, git-status tint, selection bar.
  ui/bufferline.rs   Top "tabufline" (NvChad-style): global strip of all open buffers (icon + name + ● dirty + × hitbox,
                     active highlight) on the left + tabpage indicators / theme-toggle on the right. The active split's
                     buffer is the highlighted one; clicking a buffer focuses it (in the active split).
  ui/editor_view.rs  Buffer body: gutter (line numbers, git-change marks, LSP severity signs, blame mode), indent guides,
                     syntax spans, selection highlight, diagnostic underlines/virtual-text, cursor placement; scroll-to-cursor.
  ui/popup.rs        Floating popups: LSP completion menu (kind icon + label + kind name, à la NvChad's cmp menu) with a
                     side documentation/signature box; hover docs; signature help; diagnostic float. Mouse-selectable.
  ui/statusline.rs   Bottom bar — segmented & plugin-extensible: mode chip (ONLY place reading EditingMode), file name +
                     icon, git branch + dirty/staged counts, diagnostics counts, Ln:Col, language/LSP-client name,
                     AI/HTTP activity spinner, plugin segments (e.g. a pomodoro). No mode chip when EditingMode::None.
  ui/request_view.rs (HTTP track) renders Pane::Request.   ui/diff_view.rs (Git/AI tracks) renders Pane::Diff with hunk staging.
  ui/ai_view.rs      (AI track) renders Pane::Ai (conversation, streaming text, tool-call cards, accept/reject for diffs).
  ui/welcome.rs      Splash when no pane is open (later: dashboard/greeter with recents + shortcuts).

  highlight.rs       tree-sitter: ext → HighlightConfiguration cache → per-line ColoredSpan vec (rs/ts/tsx/js/jsx/py/cs/
                     json/md/html/css/go to start; .http syntax registered by the HTTP track). Per-grammar quirks isolated here.
  git_status alias   (folded into git/status.rs)

  tui.rs             The ONLY crossterm event loop + raw-mode/altscreen/mouse setup. poll → route (global chords →
                     focus/pane dispatch → fallthrough) → tick subsystems (drain pty/lsp/search/ai/cdp channels, git cache)
                     → draw. Nothing else. Mirrors headless.rs's loop minus the terminal I/O.
```

## The pluggable input layer (the "vim way + standard way without conditionals everywhere" ask)

### Decision: `Box<dyn InputHandler>`, not an enum
Open/closed (a third style is a new file, zero edits to `Buffer`/`App`/`tui`); vim's chord/count/operator/cmdline
state lives as *private fields* on `VimInputHandler` instead of leaking into `App`; one virtual call per keystroke is
free at TUI scale. Mirrors how Helix (mode-as-data + composable keymap layers), Kakoune (mode = data), Zed vim mode
(operator-pending state machine) and CodeMirror keymaps (key→command maps composed at runtime) structure the same
problem. Bonus: live vim↔standard toggle is just `buffer.input = make_handler(other, &config)`.

### Types (`input/mod.rs`)
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditingMode { None, Normal, Insert, Visual }     // the ONLY handler-derived info render may read
impl EditingMode {
    pub fn cursor_shape(self) -> CursorShape { match self { Insert|None => Bar, _ => Block } }
    pub fn label(self) -> Option<&'static str> { /* None ⇒ render no chip; else NORMAL/INSERT/VISUAL */ }
}
pub enum InputResult {
    Ops(Vec<EditOp>),    // apply to the active buffer's editor, in order
    Consumed,            // consumed, no edit (half a chord, typing into the `:` line) — still redraw
    Ignored,             // not wanted — tui.rs tries the keymap→Command resolver, then global chords, then fallthrough
    App(AppCommand),     // small closed set the editor can't express
}
#[derive(Debug, Clone)]
pub enum AppCommand { Save, SaveAll, Quit, ForceQuit, CloseBuffer, NextBuffer, PrevBuffer, GotoLine(usize),
                      ExCommand(String), RunCommand(&'static str) }   // RunCommand bridges into the Command registry
pub trait InputHandler: Send {
    fn handle_key(&mut self, key: KeyEvent, ctx: &EditCtx) -> InputResult;
    fn mode(&self) -> EditingMode;                       // the single sanctioned coupling point
    fn pending_display(&self) -> Option<String> { None } // `:`-line or "d…" hint for the statusline
    fn name(&self) -> &'static str;                      // "vim" | "standard"
    fn on_blur(&mut self) {}                             // focus left this buffer — vim drops to Normal, clears chords
}
pub struct EditCtx { pub cursor: usize, pub line_len: usize, pub line_idx: usize, pub line_count: usize,
                     pub at_line_start: bool, pub at_line_end: bool, pub has_selection: bool }   // tiny on purpose
```

### `EditOp` vocabulary (`edit_op.rs`)
```rust
#[derive(Debug, Clone, PartialEq)]
pub enum EditOp {
    // motion (moves the selection head too if a selection is active)
    MoveLeft, MoveRight, MoveUp, MoveDown, MoveWordLeft, MoveWordRight, MoveWordEnd,
    MoveLineStart, MoveLineFirstNonWs, MoveLineEnd, MoveBufferStart, MoveBufferEnd, MoveToLine(usize), PageUp, PageDown,
    // selection
    SelectStart, SelectClear, SelectLine, SelectAll, SelectWord, AddCursorBelow, AddCursorAbove,   // last two: later multi-cursor
    // text mutation
    InsertChar(char), InsertStr(String), InsertNewline, InsertNewlineBelow, InsertNewlineAbove,
    Backspace, DeleteForward, DeleteWordLeft, DeleteWordRight, DeleteToLineStart, DeleteToLineEnd,
    DeleteLine, DeleteSelection, ReplaceSelection(String), Indent, Outdent, ToggleLineComment, MoveLineUp, MoveLineDown,
    // clipboard / registers
    YankLine, YankSelection, CutSelection, PasteAfter, PasteBefore, Paste,
    // history
    Undo, Redo,
    // vim counts stay out of the editor — vim emits Repeat(3, MoveWordRight); apply loops; standard never emits it
    Repeat(u32, Box<EditOp>),
}
pub struct EditOutcome { pub buffer_changed: bool, pub cursor_moved: bool, pub clipboard_set: Option<String>, pub wants_clipboard: bool }
impl Editor { pub fn apply(&mut self, op: EditOp, viewport_rows: usize, clip: &mut Clipboard) -> EditOutcome { /* owns undo-grouping + clipboard policy */ } }
```
`Buffer::feed_key` builds `EditCtx`, calls `input.handle_key`; on `Ops` runs each through `editor.apply`, recomputes
dirty, pushes incremental changes to the LSP client (if attached). On `Ignored` it bubbles to `tui.rs` which tries the
keymap→Command resolver. On `App(RunCommand id)` it dispatches into the Command registry.

### The mode-coupling fence
Allowed to read `EditingMode`/`pending_display()`: **only** `ui/statusline.rs` (mode chip + `:`/pending hint) and
`tui.rs`/`headless.rs` cursor placement (`SetCursorStyle` from `cursor_shape()`). `EditingMode` is a 4-variant `Copy`
enum with no back-reference to the handler type — you cannot ask "is this vim"; vim-specific UI needs a new variant
(visible, reviewable). `Buffer`/`Editor`/`tree`/`ui/editor_view`/`ui/tree_view` never call `.mode()`. Handlers may not
reach into `App` — facts in via `EditCtx`, intent out via `InputResult`/the closed `AppCommand`; a vim `:` line becomes
`AppCommand::ExCommand(String)` whose interpreter lives in `app.rs` (so `:vsplit` is an app change, not a handler change).
Vim chord state is private to `vim.rs`; `on_blur()` resets it. CI grep later: `grep -rn 'EditingMode' src/ui` hits only `statusline.rs`.

## Focus & key routing (`tui.rs` / `headless.rs`, per key event)
1. **Global chords** (any focus, configurable): `Ctrl+Q` quit · `Ctrl+B` toggle tree · `Ctrl+E` cycle focus · `Ctrl+S` save · `Ctrl+P` file picker · `Ctrl+Shift+P` command palette · `Ctrl+Shift+F` project search · `Ctrl+\` split · `Ctrl+W h/j/k/l` focus split · `Ctrl+T` shell pane · `Ctrl+Shift+A`/`Ctrl+Shift+X` Claude Code / Codex pane · `Ctrl+Shift+I` AI chat pane. Matched ⇒ run the Command, redraw, next event.
2. **Dispatch by focus:**
   - `Picker`/`Palette`/`Prompt` overlay active → it eats keys until closed.
   - `Tree` → `tree.handle_key` (↑/↓ sel · →/Enter expand-or-open — open picks `Pane` kind by extension: `.http/.rest/.curl`→`Request`, `.diff`→`Diff`, else `Editor` — then focuses that pane · ← collapse/ascend · `/` filter).
   - `Pane(id)` by kind: `Editor`→`buffer.feed_key` (`Ops`/`Consumed`⇒redraw · `App`⇒app handles · `Ignored`⇒step 3); `Pty`→forward raw bytes, `Esc` releases; `Request`→its field/response key handling (editable fields delegate to `StandardInputHandler`); `Diff`→hunk navigation + `s`/`u` stage/unstage; `Ai`→input box + scroll + accept/reject diffs.
3. **Fallthrough:** the keymap→Command resolver (the key wasn't text-editing but maps to a registered command, e.g. `gd` in vim normal → `lsp.goto_definition`, `F2` → `lsp.rename`, `Ctrl+/` → `editor.toggle_comment`). Resolver tables are built from `[keys.vim]`/`[keys.standard]`. No match ⇒ drop.

**Mouse everywhere:** `ui::draw` fills `app.pane_rects` (incl. tree rows, tab × hitboxes, split borders, scrollbars, overlay items, request-pane fields, diff hunks, statusline chips). Click ⇒ hit-test ⇒ set focus + the obvious action (place cursor at row/col, switch tab, select tree row, drag split border to resize, click a palette/picker item, stage a diff hunk). Wheel scrolls whatever's under the pointer. Drag in a buffer = selection. The E2E harness exercises mouse events through the same path (IPC `mouse <x> <y> <button>`).

## Build order

Editor core lands first (P0–P3) because everything else plugs into the `Pane`/`Command` spine. After that the tracks
are independent — do whichever is most useful next. Suggested early order once core is solid: Vim → Git(status→diff) →
HTTP → Pty/AI-CLI (the AI track — pty panes + `claude -p` one-shots) → LSP → CDP → E2E format → Plugins →
polish/laters. (A raw AI-API client is deferred — see the AI track note.) **The IPC + headless harness is built
inside P0–P1, not as a track** — it's load-bearing for testing everything after.

**P0 — skeleton compiles, opens a workspace, renders chrome, headless+IPC stub works.**
Cargo project; `main.rs` subcommand skeleton; `app.rs` (state, no editing); `pane.rs` (`enum Pane`, only `Editor`);
`layout.rs` (single leaf + tree rail + statusline; recursive renderer that today has nothing to recurse); `focus.rs`;
`config.rs` (parse TOML, defaults); `command.rs` (registry + a handful of commands: quit, toggle-tree, open-file,
save); `tree.rs`; `git/status.rs`; `ui/` (`theme.rs`, `mod.rs`, `tree_view.rs`, `bufferline.rs`, `statusline.rs`,
`welcome.rs`); `tui.rs` (raw mode, altscreen, mouse capture, event loop; global chords; Enter opens a *read-only*
`Pane::Editor`); `headless.rs` + `ipc/mod.rs` (watch `command`, run a tiny command set, write `screen.txt`/`status.json`/
`events.jsonl`); `edit_op.rs` + `editor.rs` skeleton (TextStore + motions + undo, **unit-tested now**, no key path);
`input/mod.rs` + a stub `StandardInputHandler` (`Ignored` everything).
*Done when:* `mnml ~/proj` shows a NvChad-ish tree + statusline, arrow-navigate the tree, Enter shows file contents,
mouse-click a tree row works, `Ctrl+Q` exits cleanly; **and** `mnml --headless` + writing `{"cmd":"open","path":"..."}`
to `.mnml/ipc/command` makes `screen.txt`/`status.json` reflect it.

**P1 — text editing via the VSCode-style `StandardInputHandler`.**
`editor.rs::apply` (full interpreter, undo-grouping, selection); `clipboard.rs`; `input/standard.rs` + `input/keymap.rs`
(config-driven bindings: typing, arrows, Shift-select, Home/End/PgUp/PgDn, Ctrl+C/X/V/Z/Y/A, Ctrl+←/→, Ctrl+Backspace/Del,
Tab/Shift-Tab, Alt+↑/↓ move line, Ctrl+/ toggle comment, Ctrl+S save); `buffer.rs::feed_key`; `ui/editor_view.rs` (gutter,
scroll-to-cursor, selection highlight, bar cursor); `tui.rs` wires `Pane::Editor`→`feed_key` + mouse click→`MoveToLine`+col,
drag→selection; IPC gains `type`/`key`/`save` so e2e can edit.
*Done when:* type/select/cut/paste/undo/redo (incl. UTF-8 boundaries), `Ctrl+S` writes to disk, `●` dirty marker; same
behaviors reproducible headlessly via IPC.

**P2 — palette + picker + which-key + highlight + theme polish + icons.**
`picker.rs` (generic fuzzy overlay), `palette.rs` (Ctrl+Shift+P over the registry), `whichkey.rs`; `highlight.rs`
(tree-sitter); `ui/editor_view.rs` overlays syntax spans + indent guides; `ui/icons.rs` (Nerd-Font default, `--ascii`
fallback); statusline gains `Ln:Col` + language. File-open uses the picker (`Ctrl+P`).
*Done when:* `Ctrl+P` fuzzy-opens files, `Ctrl+Shift+P` runs commands, which-key popup shows after a prefix, source files
are colored to onedark with indent guides + icons.

**P3 — `VimInputHandler` + editor splits.**
`input/vim.rs` (Normal `hjkl w b e 0 ^ $ gg G NG x dd yy p P dw d$ d0 i a I A o O u Ctrl-R v V Z(ZZ→Save+Quit, ZQ→ForceQuit)
gd/gD→LSP `<leader>`-map via which-key`; Insert printable→`InsertChar`, Esc→Normal; Visual motions extend, `y`/`d`/`x`;
cmdline `:` → `AppCommand::ExCommand`); `[keys.vim]`/`[keys.standard]` honored; runtime `:set input=…` toggle.
`layout.rs` grows real split nodes + `Ctrl+\`/`Ctrl+W hjkl`/mouse-drag-border; `ui/mod.rs` recursive render; per-split
focus + tabs. **Zero changes to `editor.rs`/`app.rs` render/`ui/*` except `statusline.rs` (already handles it) for the vim part.**
*Done when:* `--input vim` gives full Normal/Insert/Visual + `:wq` + leader-which-key; `--input standard` unchanged with no
mode chip; `Ctrl+\` splits the editor, edit two files side by side, `Ctrl+W l` moves focus.

**Track — Git (rich).** status chip lands in P0; then `git/diff.rs` + `ui/diff_view.rs` (`Pane::Diff`, hunk nav,
`s`/`u` stage/unstage via `git apply --cached`), `git/blame.rs` (gutter blame mode), `git/commit.rs` (message prompt →
`git commit`); gutter change-marks in `editor_view`; commands: `git.status_pane`, `git.diff_file`, `git.stage_hunk`,
`git.blame_toggle`, `git.commit`. *Done when:* open a dirty repo → see change marks, open the diff pane, stage a hunk,
write a commit, all from inside mnml.

**Track — HTTP (baked-in request capability).** `src/http/*` ported from `rqst/src/*` (curl/file/template/script/chain/
discover/env); `request_pane.rs` + `ui/request_view.rs` (`Pane::Request`); `.http`/`.rest`/`.curl` open into it; `.mnml/`
holds `config`/`env/*.env`/`requests/`/`snippets/`/`lookups/`/`history.jsonl`; commands `rqst.send`/`rqst.copy_curl`/
`rqst.discover`/`rqst.chain_run`; `highlight.rs` registers `.http` syntax; headless `mnml run FILE` / `mnml chain run FILE`
(non-zero exit on a failed `@assert`). *Done when:* open a `.curl` from the tree → loads into a request pane → `{{VAR}}`s
resolve from `.mnml/env/dev.env` → `Ctrl+R` sends → response + assertions render; `mnml run file.curl` works headlessly.

**Track — Pty / AI-CLI panes.** `pty_pane.rs` (portable-pty + vt100; profiles shell/`claude`/`codex`, `.mnml` context
injection; threaded read pump → channel); `Pane::Pty` live; renderer for the vt100 grid; `tui.rs` forwards raw bytes when
focused, `Esc` releases; `ai/claude_code.rs` tails the session JSONL Claude Code writes (and Codex's if it has one — TBD,
user will test with their account). Commands: `term.shell`, `ai.claude_code`, `ai.codex`. *Done when:* spawn a shell pane,
spawn Claude Code in another, `Esc` back to the editor, resize doesn't corrupt; the AI chat view (next track) shows the
CLI conversation.

**Track — AI (folded into the Pty/AI-CLI track — `claude -p` one-shots, not a raw-API client).** Beyond the CLI panes:
`ai/oneshot.rs` (spawn `claude -p "<prompt>"` on a thread, capture stdout via the same channel pattern as the pty pump);
`ai/actions.rs` (on-selection commands `ai.explain`/`ai.refactor`/`ai.fix`/`ai.write_tests` → feed the selection + a task
prompt to `claude -p` → show the answer, or — when the prompt asks for a patch — parse it to a `Pane::Diff` with
accept/reject); `ai/debug.rs` (`Ctrl+.` on a failing request → `claude -p` with the request+response → suggested fix);
`Pane::Ai` + `ui/ai_view.rs` is the conversation view, kept in sync with the CLI pane via the JSONL tail. *Why no API
client:* the CLIs already do tool use / file edits / agentic loops / MCP and the vendors keep them current; an embedded
client (provider abstraction, tool registry, diff-approval UI, SSE streaming, rate-limit handling, key management) is a
large surface for a capability that exists. `ai/provider.rs` stays deferred — revisit only for headless `.test` AI with no
subprocess, behind `[ai]` config. *Done when:* ask the AI panel to
"add a test for this function", it reads the file via a tool call, proposes a diff, you accept it; select a block → "explain"
streams an answer; a failing request → `Ctrl+.` → AI proposes a fix.

**Track — CDP / web.** `cdp/launch.rs` (find/launch Chrome with `--remote-debugging-port`, temp profile), `cdp/mod.rs` +
`cdp/fetch.rs` (WebSocket JSON-RPC, `Network.*` → captured requests), `cdp/page.rs` (`Page.navigate`, `Runtime.evaluate`,
`Input.dispatch*`), `captured.rs` (view captures; "copy as curl"/"send in request pane"); commands `cdp.launch`/
`cdp.capture_toggle`. *Done when:* `cdp.launch` opens Chrome, browse, see captured requests in mnml, "copy as curl" into a
request pane and replay.

**Track — E2E test format.** A `.test` (TOML or a tiny DSL) of `steps` (`open FILE`, `type "..."`, `key ctrl+p`,
`mouse X Y left`, `palette "rename"`, `wait status.lsp == "idle"`, `cdp navigate URL`, `cdp click "selector"`) and
`expect`s (`screen contains "..."`, `status.activePane == "editor"`, `cursor == 3:12`, `cdp request matching "..." seen`)
run against `headless.rs` + `ipc/` (and `cdp/` for web steps). Runner: `mnml test 'tests/e2e/**/*.test'` (also wired into
`cargo test`). mnml's own UI suite is written in `.test` files. *Done when:* `cargo test` runs the `.test` suite headlessly
and a web `.test` drives Chrome via CDP and asserts on captured traffic.

**Track — Plugin hooks.** Document the IPC plugin protocol: a plugin process connects to `.mnml/ipc/`, on handshake can
`register-command {id,title,group,keys}` (appears in the palette/which-key; invoking it writes an event the plugin reads),
`subscribe events`, and send any IPC command. Ship 1–2 example plugins (e.g. a "open in GitHub" command, a custom linter
that pushes diagnostics). *Done when:* a standalone script registers a palette command that, when run, does its thing.

**Laters (no fixed order):** snippets, multi-cursor (the `AddCursor*` ops are stubbed in already), code folding, session/
workspace state restore (reopen files + cursors + layout, recent-workspaces picker), multiple themes, dashboard/greeter.

## Cargo.toml (starting point — pin exact patch versions from `cargo update` once it builds; `Cargo.lock` from mnml1 is a good reference for a known-good tree-sitter combo)
```toml
[package]
name = "mnml"; version = "0.1.0"; edition = "2024"
description = "NvChad-style TUI IDE: pluggable vim/standard editing, splits, LSP, git, fuzzy finder, command palette, embedded terminal + Claude Code/Codex, baked-in HTTP request client, CDP capture, file-IPC + headless E2E harness."
license = "MIT"
[lib] name = "mnml"; path = "src/lib.rs"
[[bin]] name = "mnml"; path = "src/main.rs"

[dependencies]
ratatui = "0.28"            # incl. its `backend-crossterm` + `TestBackend` (headless render)
crossterm = "0.28"
arboard = "3"               # system clipboard; register fallback when unavailable
ignore = "0.4"              # .gitignore-aware tree walking / file enumeration
toml = "0.8"; serde = { version = "1", features = ["derive"] }; serde_json = "1"
nucleo = "0.5"              # fuzzy matcher for the picker/palette (or `fuzzy-matcher`)
notify = "6"                # watch .mnml/ipc/command (or just poll — keep it simple if notify is fussy)
# Pty / AI-CLI panes
portable-pty = "0.8"; vt100 = "0.15"
# HTTP track (baked in — not a rqst-crate dep)
reqwest = { version = "0.12", default-features = false, features = ["blocking", "rustls-tls", "gzip", "brotli", "deflate"] }
# CDP track
tungstenite = "0.24"
# LSP track
lsp-types = "0.97"          # types only; we manage the subprocess + JSON-RPC ourselves on a thread
# AI track: no extra deps — it shells out to `claude` / `codex` (pty panes + `claude -p` one-shots) and tails session JSONL (serde_json). (A raw Claude/OpenAI client is deferred; if ever built it reuses reqwest + serde_json.)
# tree-sitter (P2) — grammars bump independently; isolate quirks in highlight.rs::build_config
tree-sitter = "0.26"; tree-sitter-highlight = "0.26"
tree-sitter-rust = "0.24"; tree-sitter-javascript = "0.25"; tree-sitter-typescript = "0.23"; tree-sitter-python = "0.25"
tree-sitter-c-sharp = "0.23"; tree-sitter-json = "0.24"; tree-sitter-md = "0.5"; tree-sitter-html = "0.23"
tree-sitter-css = "0.25"; tree-sitter-go = "0.25"
# unicode-width — add in P2 if CJK column math in editor_view needs it
# tokio — ONLY if the LSP thread model proves unworkable; default is threads + channels, no global runtime

[dev-dependencies]
tempfile = "3"
[profile.release]
lto = true; codegen-units = 1; strip = true
```

## Verification
```
cargo build && cargo clippy --all-targets && cargo test
cargo run -- ~/some/project                 # P0+
cargo run -- --input standard FILE          # P1
cargo run -- --input vim ~/proj             # P3
cargo run -- --headless ~/proj &            # then drive via .mnml/ipc/command
cargo run -- run requests/foo.curl          # HTTP headless
cargo run -- test 'tests/e2e/**/*.test'     # E2E suite (also runs under `cargo test`)
```
Manual / harness checklist per phase/track:
- **P0:** tree renders w/ onedark; ↑/↓ navigate; mouse-click a row; Enter shows file body; `Ctrl+Q` exits with the terminal fully restored; resize reflows; **headless:** IPC `open` → `screen.txt`/`status.json` reflect it.
- **P1:** type/select/cut/paste/undo/redo incl. UTF-8 (emoji, accents — cursor stays on char boundaries); Shift+arrows select; OS-clipboard round-trip; `Ctrl+Z` coalesces a typing burst; `Ctrl+S` writes, `●` clears; same via IPC `type`/`key`/`save`.
- **P2:** `Ctrl+P` fuzzy-opens; `Ctrl+Shift+P` runs a command; which-key popup after a prefix; `.rs`/`.ts`/`.py`/`.json`/`.md` colored per onedark; indent guides line up; icons render; `--ascii` degrades cleanly; statusline shows `Ln:Col` + language.
- **P3:** vim Normal motions (`hjkl w b 0 $ gg G 5G`), `i a o O`/`Esc`, `x dd yy p u Ctrl-R`, `v`/`V` + motion + `y`/`d`, `:w :q :wq :q!`, `ZZ`/`ZQ`, `<leader>` which-key; block cursor Normal / bar Insert; `--input standard` identical to P1, no mode chip; remap a key via `[keys.*]` and see it take effect; `Ctrl+\` splits, edit two files side by side, `Ctrl+W l` moves focus, drag the border to resize.
- **Git track:** dirty repo → gutter change marks; diff pane; stage a hunk; commit; blame mode shows authors.
- **HTTP track:** Enter on `.curl`/`.http` → request pane; `{{VAR}}` from `.mnml/env/dev.env`; `Ctrl+R` sends, status/timing/`@assert`/`@capture` render; `Ctrl+Y` copies as curl; `mnml run file.curl` exits non-zero on a failed assertion; `mnml chain run x.chain.json` threads vars.
- **Pty/AI-CLI track:** `Ctrl+T` shell pane works; `Ctrl+Shift+A` Claude Code pane; `Esc` releases; resize doesn't corrupt; the in-IDE AI view mirrors the CLI conversation (JSONL tail); select a block → "explain" → `claude -p` answer; "write tests" → proposed patch → `Pane::Diff` accept applies it; failing request → `Ctrl+.` → `claude -p` suggests a fix.
- **CDP track:** `cdp.launch` opens Chrome; browse; captured requests appear; "copy as curl" → request pane → replay; a web `.test` drives a page and asserts on captured traffic.
- **E2E track:** `cargo test` runs the `.test` suite headlessly; a `.test` failure points at the failing step/expect; mouse steps exercise the same hit-test path as a real click.
- **Plugin track:** a standalone script registers a palette command that appears in `Ctrl+Shift+P` and runs.

Unit tests (the cheap, high-value ones):
- `editor.rs`/`edit_op.rs` — insert/backspace/delete, `insert_str`, UTF-8 boundary safety; word motions L/R/end over whitespace+punctuation; line start/first-non-ws/end; buffer start/end; `MoveToLine` clamping; up/down preserve target column; undo/redo round-trip; typing coalesces, a motion breaks the group, a new edit clears redo, `replace_all` resets history; selection grows with motion after `SelectStart`; `DeleteSelection`/`ReplaceSelection` exactness; `DeleteLine` on first/middle/last; `YankLine`/`PasteAfter` via a fake `Clipboard`; `Repeat(3, MoveWordRight)` == three moves; `ToggleLineComment`/`MoveLineUp/Down`.
- `input/standard.rs` — key→`InputResult` table for the default config: `'a'`→`InsertChar`, `Enter`→`InsertNewline`, `Left`→clear-sel+`MoveLeft`, `Shift+Left`→`SelectStart?`+`MoveLeft`, `Ctrl+C/X/V`→`Yank/Cut/Paste`, `Ctrl+Z/Y`→`Undo/Redo`, `Ctrl+A`→`SelectAll`, `Ctrl+Left`→`MoveWordLeft`, `Ctrl+Backspace`→`DeleteWordLeft`, `Ctrl+/`→`App(RunCommand "editor.toggle_comment")`, `Ctrl+S`→`App(Save)`; `mode()` always `None`; a remapped binding from a test config resolves.
- `input/vim.rs` — `Normal` start; `i`→`Insert`, `Esc`→`Normal`; `o`→`InsertNewlineBelow`+Insert; `hjkl`→moves; `5`+`w`→`Repeat(5, MoveWordRight)`; `d`+`w`→`DeleteWordRight`; `d`+`d`→`DeleteLine`; `y`+`y`→`YankLine`; `x`→`DeleteForward`; `p`→`PasteAfter`; `u`→`Undo`; `Ctrl-R`→`Redo`; `g`+`g`→`MoveBufferStart`; lone `g`→`Consumed` + `pending_display()=="g"`; `v`→`Visual`, `l`→sel-extend, `y`→`YankSelection`+`Normal`; `:`→`Consumed`+`pending_display()` starts `:`; `w q` Enter→`App(ExCommand("wq"))`; `Esc` cancels; `gd`→`App(RunCommand "lsp.goto_definition")`; `on_blur()` resets.
- `command.rs` — registry id lookup; key→id resolver built from a config snippet (both keymaps); duplicate-id rejection; plugin-registered command appears.
- `app.rs` — `open_path` dedups & refocuses and picks the right `Pane` kind by extension; `close` clears active when empty; ex-interpreter `"q"`→`Quit`, `"wq"`→save+quit, `"5"`→`GotoLine(5)`, `"vsplit"`→split command.
- `layout.rs` — split/unsplit changes the tree; focus-direction picks the right neighbor; rect calc sums to the frame; close-leaf collapses the parent.
- `tree.rs` — gitignore filtering excludes ignored entries; expand/collapse changes the flatten; "open under cursor" returns the right path.
- `http/*` (HTTP track) — port rqst's corpus: `curl.rs` parses quoted/continued curls; `http_file.rs` round-trips `.http`; `template.rs` resolves `{{VAR}}`+`{{$uuid}}` and marks unknowns; `script.rs` evaluates `@assert status == 200` / `@capture id = json $.id`; `chain.rs` threads extracted vars step→step.
- `ipc/mod.rs` — a command line in → the expected app mutation + the expected `events.jsonl` line out; `status.json` shape is stable; `wait-for` predicate evaluation.
- `headless.rs` — render a known buffer into `TestBackend` and assert the screen text (this is the substrate the `.test` runner stands on).

## Risks & tradeoffs
- **Scope.** This is a full IDE plus an HTTP client plus a browser-automation harness. The mitigation is the `Pane`/`Command`/IPC spine + strict layering: each track is genuinely additive, and the core (P0–P3) is independently useful. Resist letting a track reach across — if a track needs something from the core, add a `Command`/`EditOp`/`Pane` variant, don't special-case.
- **Async vs threads.** Defaulting to thread+channel per subprocess (pty's proven model) avoids a global runtime infecting everything. The one place it might not hold is LSP (many concurrent in-flight requests across several servers). Plan B: introduce `tokio` and move LSP (and then reqwest/AI) onto it — but only if the thread model actually hurts. Decide at the LSP track, not now.
- **Trait-object input layer.** Slight extra ceremony (`InputResult`/`EditCtx`/`AppCommand`); the payoff is the no-conditionals property *and* live keymap switching *and* config-driven remap. Worth it.
- **Headless fidelity.** Real value only if `headless.rs` shares `app.rs` + `ui::draw` byte-for-byte with `tui.rs` — the only difference is the backend (`TestBackend` vs `CrosstermBackend`) and the input source (IPC vs crossterm events). Enforce that the two run loops are near-identical; don't fork render logic.
- **String vs rope.** Fine for typical source files; keep mutation behind `EditOp`/`apply` so `ropey` is a one-module swap later. Not now.
- **tree-sitter / Chrome / git version churn.** tree-sitter grammar crates change `HighlightConfiguration::new` arity between versions (mnml1 already has per-grammar quirks) — pin exact versions, isolate quirks in `highlight.rs::build_config`. Chrome's CDP is stable for `Network`/`Page`/`Runtime`/`Input` (rqst already relies on it). `git` shell-outs degrade to "not a repo" — never panic.
- **`EditCtx`/`AppCommand` scope creep.** Keep `EditCtx` to the listed handful (need bracket-match for vim `%`? add an `EditOp`, don't fatten `EditCtx`); keep `AppCommand` to save/quit/close/switch/goto/ex/run-command — bigger things become `Command`s.
- **Giant-file relapse.** mnml1's `tui.rs` and rqst's `app.rs` both rotted. The `ui/` + `git/` + `http/` + `lsp/` + `ai/` + `cdp/` + `ipc/` directories, render-free `app.rs`, and event-loop-only `tui.rs` are the structural guard. Hold the line.

## Critical files to create (the load-bearing ones)
- `src/command.rs` — the `Command` registry: the spine every non-text feature, the palette, which-key, keybindings, and plugins hang off of.
- `src/pane.rs` + `src/layout.rs` — the open-thing abstraction + the split tree; every later track plugs in here.
- `src/input/mod.rs` — `InputHandler` trait, `EditingMode`, `InputResult`, `AppCommand`, `EditCtx`; the "vim + standard, no conditionals everywhere" mechanism.
- `src/edit_op.rs` + `src/editor.rs` — the `EditOp` vocabulary + the `apply` interpreter (undo-grouping + clipboard policy).
- `src/ipc/mod.rs` + `src/headless.rs` — the file-IPC channel + the virtual-screen run loop; load-bearing for the whole E2E story; must share `app.rs` + `ui::draw` with `tui.rs`.
- `src/tui.rs` — the only crossterm event loop; routing (global chords → focus/pane dispatch → keymap→Command fallthrough), subsystem tick, draw.
- `src/input/vim.rs` — the modal handler; proves the "no conditionals outside here" property. Reference Helix (mode-as-data + keymap layers), Kakoune (mode = data), Zed vim mode (operator-pending state machine), CodeMirror keymaps.

Reference implementations (mirror the structure, port the logic, but this is mnml's own code — not crate deps):
`/Users/chrismclennan/Projects/mnml1/src/{editor,app,buffer,highlight,pty_pane,tree,theme,icons,git_status}.rs` (editor + IDE bones);
`/Users/chrismclennan/Projects/rqst/src/{curl,http_file,template,script,chain,discover,history,config,ipc,ipc_files,proxy,cookies,jwt,picker,lookup,snippets,mock}.rs` and `rqst/src/cdp/*` and `rqst/src/ai/*` and `rqst/src/{claude,openai}/*` (the HTTP / IPC / CDP / AI stacks to port into `src/http/`, `src/ipc/`, `src/cdp/`, `src/ai/`), and `rqst/src/app.rs` for the request-pane field-tabs + response-view layout (port the shape, not the monolith).
