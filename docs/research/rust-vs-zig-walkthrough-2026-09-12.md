# Rust vs Zig — the walkthrough (2026-09-12)

The Rust IDE (`mnml` 0.2.21, `target/release/mnml` at `7e95aea0c-dirty`) and
the Zig successor (`mnml-zig` 0.3.0-dev at `c4675a7`) were driven headless
over the file-IPC on the **same real workspace** — a private copy of
`~/Projects/work-workspace` (its `.git` kept) — with **private copies
of the user's real data root** (`~/.config/mnml`: Rust reads its
`config.toml`, Zig its `config.zon`, both list the same workspaces, themes,
integrations, bookmarks and HTTP history), a private `HOME` whose `.claude`
mirrors the real one read-only, and a `claude` shim on `PATH` (never the real
CLI). 51 surface runs (45 distinct after the re-runs and probes), 343 snapshot pairs, 3 sizes, both profiles. Every pair
of screens, `status.json` and `rects.json` was kept and diffed; the raw
per-snapshot diffs are summarised in the per-surface table at the end.

The user's worry — "we are leaving so much of the Rust one out of Zig; there
are probably hundreds of other gotchas" — is half right. Outside the accepted
divergences (`docs/ui-spec/README.md`: the rail, the statusline chips, the
list-panel idiom, the branches panel, the debugger, the sessions table) the
two apps agree on the frame — menu bar, tree, tabs, breadcrumb, gutter,
editor text for all ten languages, the palette, the picker, the which-key
leader, the context-menu shape, the git graph's columns — cell for cell.
What diverges is **behaviour behind the same door**: 12 findings below are
SEV-1, a same-step-different-place or a feature that is silently empty, and
a quarter of them are Rust's bugs, not Zig's. The two known items (the
SESSIONS card content/grouping; the AI pane 2×2 grid) are recorded in §3 and
were not re-investigated.

## 1. Method

- **Workspace.** `rsync` of `~/Projects/work-workspace` (excluding
  `node_modules`, `target`, `zig-out`, the stale `.mnml/ipc*`, and the 12 MB
  `.mnml/chrome-profile`) into `/private/tmp/walk/pristine/ws`. The workspace
  has no `.ts/.go/.rs/.lua/.zon/.toml/.yml` files, so a `walk-samples/` dir of
  ten small sample files (one per language, plus `sample.png` copied from the
  workspace's scratchpad) and `requests/demo.http` (the chrome-fixture's) were
  added — they show up as untracked `?` rows in every git view. The workspace
  carries a Rust-era `.mnml/config.toml` (`[git_graph] lane_spacing = 1`) and
  a `.mnml/session.json` from August; both were kept, and both matter (finding
  1.10).
- **Data roots.** `cp -R ~/.config/mnml` twice (minus its 48 MB `backups/`):
  `rs-data` for Rust, `zig-data` for Zig. Neither app was pointed at the real
  directory. The private workspace path is not in either trust list, so Rust
  shows `󰌾 RESTRICTED` and Zig treats the workspace config as untrusted — the
  same thing the user sees on a workspace he has not trusted yet.
- **HOME.** `/private/tmp/walk/home`: `.claude/*` symlinked to the real
  entries except `projects/`, which is a real directory holding a symlink to
  the real `-Users-chrismclennan-Projects-acmeco-claude-workspace` transcript
  dir under the copy's own encoded name (`-private-tmp-walk-slotN-ws`), so
  both apps see the user's real Claude Code sessions for this workspace
  (4.9 GB of transcripts). `~/Projects` is symlinked so the `~`-relative
  workspace roots in the real config resolve (git discovery finds the same
  twelve repos on both sides). `bin/claude` and `bin/codex` are shims that
  print a banner and idle; `ANTHROPIC_API_KEY` / `GITHUB_TOKEN` are unset.
- **Harness.** `docs/ui-spec/walk/walk-drive.py` is `tools/compare-drive.py`'s
  mechanics with one change: a screen / `status.json` / `rects.json` is kept
  at every `{"cmd":"snapshot"}` line (a `# label` comment names it), after
  the ack and the next frame. `run.sh` resets a slot from the pristine copies
  before each side, so Rust and Zig never see each other's session files;
  four slots ran in parallel. `walk-report.py` counts as `tools/ui-diff.sh`
  does (rows whose columns 4+ differ; the rail is accepted) and additionally
  drops the statusline row and the Zig config toast (finding 1.10, on every
  Zig screen) so the numbers measure the rest. Rust's first frame took a
  median 1.3 s on this workspace (max 3.6 s — it scans the transcripts at
  start); Zig's 10 ms.
- **Steps.** 38 steps files under `docs/ui-spec/walk/`, one per surface:
  every activity section, every pane kind reachable from the workspace, the
  overlays, the menus, right-clicks on eight targets, the statusline in each
  state, both profiles, 120×40 / 80×24 / 200×60. Classification of each
  differing row-group was done by reading every pair; four reader agents
  wrote one findings file per surface (`/private/tmp/walk/findings/`, not
  committed — the report is the digest) and I re-verified every SEV-1 against
  the raw screens, `status.json` and the source before ranking it.
- **Three steps were wrong on the first pass and were re-run** (`*2`
  files): the statusline and context-menu clicks were one row low (row 39 is
  the ex-command row, the statusline is 38); the vim leader was sent as
  `type " "` instead of `key space`. The corrected runs are the ones cited.

## 2. Ranked findings

Severity: **SEV-1** — structural or behavioural, hit on the first try of a
surface; **SEV-2** — structural/behavioural on a second step or a less common
path; **SEV-3** — cosmetic. Excerpts are trimmed (columns 0–3 dropped where
noted). "Owner" is the file I believe owns it on the side that is wrong or
missing; the other side is named for reference.

### SEV-1

**1.1 — The INTEGRATIONS section is empty on Zig: the user's 19 installed
integrations do not exist for it.** `integrations/00-installed`. Rust reads
`Inst (15) Mkt (3)  (8)` and lists Amplify Deployments, Bitbucket
Pipelines, Bitbucket PRs, Browser, btop, Claude Code, CodeBuild Builds, …;
Zig reads `Inst (0) Mkt (0)  (0)` on every snapshot and shows `Nothing
installed yet — …`. Both data roots hold the same `integrations/*.toml`
manifests (19 of them); Zig loads `<data root>/integrations/<id>.zon` only
(`docs/CONFIG.md`) and says nothing about the `.toml` files it skipped. Every
later step (`enter` on a row, `integrations.show_details`, `show_in_dev`) is
therefore a no-op on Zig. This is the same shape as the config-file gotcha
(1.10): a Rust user's data root migrates silently to "nothing".
```
R|  │ Inst (15) Mkt (3)  (8)  │          Z|  │ Inst (0) Mkt (0)  (0)   │
R|  │  󱰎 Amplify Deployments  █│          Z|   │  Nothing installed yet —…│
R|  │     amplify.open         │
R|  │  󰫯 Bitbucket Pipelines   █│
```
Owner: `mnml-zig/src/app/integrations.zig` (the manifest loader; a `.toml`
beside the missing `.zon` deserves the same pointer-at-the-converter the
config loader gives).

**1.2 — SEARCH is a sidebar section on Rust and a grep pane on Zig, and they
search different things.** `search/02-results`. Rust: `view.activity_search`
replaces the sidebar with `SEARCH  Aa \b .*`, a query box (`/ toggle█`), and
`16 hits (git grep)` grouped by file; the pane area stays on the welcome
screen. Zig: the sidebar stays the tree; a `󰍉 Search` tab opens in the pane
area — `SEARCH · walk: "toggle" · 437 matches in 38 files`, hint row
`⏎ open · n/N step · space toggle · R replace · r rerun · / filter · h/l fold
· esc back`. Rust's is `git grep` (tracked files only); Zig's walks the
workspace including `scratchpad/` and a 60 KB single-line JSON, so the counts
are 16 vs 437. Then (`04-enter-hit`) Enter on a hit opens `manifest/loops.json`
at 424:35 on Zig; on Rust nothing changes (`panes=[]`, `activeFile=""`) even
though Rust's own hint says "Enter jumps to the match". Rust's click-rect
count is flat at 48 through all six snapshots — the hit list registers no
targets.
```
R| │ SEARCH           Aa \b .*│ 󰐕                       Z| │  /pri…             █│ 󰍉 Search 󰅖   󰐕
R| │ / toggle█                │                          Z| │▌    .claude           █│ SEARCH · walk: "toggle" · 437 matches in 38 files
R| │ 16 hits (git grep)       │                          Z| │       commands        █│  ⏎ open · n/N step · space toggle · R replace …
R| │ docs/command-reference.ht│                          Z| │     󱼄  queue.jsonl   ? █│ manifest/loops.json (4)
R| │   537:23  secHead.classLi│                          Z| │     󱼄  settings.json M █│   424:21  "MINE MODE. toggle_prompt/toggle_flag …
```
Owner: `mnml-zig/src/app/grep.zig` + `src/ui/grep_view.zig` (the pane; the
walk's scope) vs Rust `src/app/grep.rs` / `src/ui/mod.rs` (the section; the
dead Enter is Rust's, `src/tui/mod.rs` key dispatch for `ActivitySection::Search`).

**1.3 — The git graph's DATE / TIME column is eleven U+FFFD on every commit
row at 120×40 (and 80×24).** `git/00-branches` … `05-graph`. Rust paints
`09/12 03:47`; Zig paints `�����������` — real replacement characters in
`screen.txt`, not a dump artefact — exactly `cols.age` wide. At 200×60, where
the column is wide enough to carry the header un-clipped and an AUTHOR
column appears, Zig paints the dates correctly (`git-200x60/05-graph`); at
120×40 the header reads `…E / TIME` (the column is narrower than the spec's
13 cells) and the truncation path is the one that breaks.
```
R|▌    ●─╮           │ Merged in f… │   09/12 03:47 │ 8ea702cda  │
Z|▌▌    ●─╮           │ Merged in fe… │ ����������� │ 8ea702cda  │
R|▌    ●─┼─╮         │ Merged in f… │   09/12 03:46 │ 803386537  │
Z|▌▌    ●─┼─╮         │ Merged in fi… │ ����������� │ 803386537  │
```
Owner: `mnml-zig/src/ui/git_graph_view.zig:861-864` — `commitDateTime(&buf, …)`
formats into a per-row stack `buf: [16]u8` and the result goes through
`rightAlign(arena, …, cols.age, …)`; on the narrow path the painted slice is
not the formatted text. (The `▌▌` double gutter on Zig's graph rows — the repo
accent painted twice, and on the toolbar row — is a separate SEV-3.)

**1.4 — `git.graph` on Zig swaps the workspace's graph for another repo's.**
`git/05-graph`, at all three sizes. Both apps open one graph tab per
discovered repo (12 on this config: `ws, mixr, acmeco-claude-workspace, …,
tttl.co-customer-web-app`). On Rust `git.graph` from there is a no-op on
screen (`status.json`: focus `pane→tree`, panes unchanged). On Zig the pane
list loses `ws` and gains `mnml` at the end, `activePane=12`: the graph on
screen is `~/Projects/mnml`'s (`fix(find): standard-profile Enter steps t…`,
`Chris McLennan`, `09/10 09:09`), the tab strip scrolls to `… 󰊢 mnml 󰅖`, while
the sidebar pill still says `ws 󰅀`. `06-graph-enter` then opens a
`commit 25e1bc3` detail pane for that foreign repo (Zig-only `git.graph_detail`).
```
R row1| GIT       │ 󰊢 ws 󰅖 󰐕  󰅁  󰅂  󱸀  󱰔       │  git status 󰐕
Z row1| GIT       │ 󰊢 tttl.co-customer-… 󰅖   󰊢 mnml 󰅖   󰐕     󰅁  󰅂
R row5|▌▶   ●─┼─╮   │ Merged in fix…  │  Unstaged changes (16)
Z row5|▌▌    ●   │ fix(vim): Ctrl+F / C… │   09/10 09:09 │ 25e1bc342
status Z 04: panes=[13] title="git status"   05: panes=[12] title="mixr" (list ends …, "mnml")
```
Owner: `mnml-zig/src/app/cmd_git.zig` (the `git.graph` handler's repo pick
when a graph is already open) / `src/app/git.zig`.

**1.5 — `git.commit` does nothing on Zig; the typed message lands in the
editor's void.** `git/08-commit-box`, `09-commit-typed`. Rust opens
`┌ Commit message (nothing staged — stage hunks first) ─┐` and `walk: test`
appears inside it. Zig: no box, no toast, the `settings.json` editor
unchanged line for line, `Ln 1/116 Col 1` before and after the typing.
Probably because the preceding `esc` closed Zig's diff tab outright (Rust's
stays behind the modal — see 1.6), leaving no git context for the command.
```
R|  │ ▾ LOCAL        17 █│▌    ┌ Commit message (nothing staged — stage hunks first) ─────┐
R|  │  ▾ chore  (8)     █│▌    │ walk: test                                               │
R|  │     ○ coverage-con█│▌    │  enter to submit · esc to cancel                         │
Z|  │ [F12] Definition · │  26             "type": "command",
Z| EDIT   main  󰐙 14  󰛕 1   settings.json       󱼀 󰐎  LSP?  WRAP  3.4K  Ln 1/116 Col 1
```
Owner: `mnml-zig/src/app/cmd_git.zig:446` (`fn commit`).

**1.6 — `git.status_pane` and `git.diff` split the view on Rust and replace
it on Zig.** `git/03-status-pane`, `07-diff`. Rust adds a pane to the right of
the graph (`panes` 13 → 14 → 16; the graph's `GRAPH │ COMMIT MESSAGE │ SHA`
columns stay, the status/diff block appears beside them). Zig swaps the
current pane's content (`panes` stays 13, title flips to `git status`; the
diff arrives as a tab). Same command, a different number of panes — and it
is why 1.5 then fails. Also `04-status-enter` (Enter on the untracked `? $O`
row): Rust opens nothing; Zig toasts `no diff for that file (untracked? —
stage it to see it)`.
Owner: `mnml-zig/src/app/cmd_git.zig` (`status_pane` / `diff` open path) vs
Rust `src/app/git.rs`.

**1.7 — On Rust, keys and right-clicks in a sidebar section fall through to
the hidden explorer and open a file.** Seen in four surfaces: `notes/01-down2`
(Down ×2: the NOTES cursor stays on `note-1`, but `.claude/queue.jsonl`
opens in a pane — `treeCursor 0→2`, `treeVisible: true` under NOTES),
`debug/01-down2` (same, plus the Debug pane later sits beside the stray
`queue.jsonl`), `sessions-seeded/02-rclick-card` (a right-click on an empty
SESSIONS row with **no registered rect** at that cell opens `queue.jsonl`),
`discovery/01-down2` (arrows move the tree under the overlay). Zig moves the
section's own cursor (`note-1 → note-2`) and opens nothing.
```
R notes 00| │ NOTES  (2)             │ 󰐕                    R 01| │ NOTES  (2)             │  queue.jsonl 󰅖   󰐕
R notes 00|  │ ▌ note-1             6w │                    R 01|  │ ▌ note-1             6w │ .claude › queue.jsonl
status R 01: focus=tree panes=[{"queue.jsonl"}] treeCursor=2 treeSelection=…/.claude/queue.jsonl
status Z 01: focus=tree panes=[] (cursor marker on note-2)
```
Owner: `mnml/src/tui/mod.rs` (`dispatch_key`: no `ActivitySection::{Notes,
Debug,Sessions}` arm before the tree's) and `src/app/layout.rs:2394`
(`treeVisible` stays true under a section). Rust-side.

**1.8 — `ai.claude_code` opens the pane but leaves the sidebar on the tree
(Zig); Rust switches it to SESSIONS.** `ai/00-claude-pane`. Rust
(`src/app/ai.rs:646-653`, gated by `[ai] auto_show_sessions_on_ai_activate`)
flips the rail to SESSIONS (`SESSIONS  (1)` / `▌ Claude Code`) before
spawning; Zig's `claudeCode` (`src/app/ai.zig:1153`) calls `openSession` and
nothing else — the key exists in `Config.zig:280` and is never read.
```
R| │ SESSIONS  (1)          │ 󱸀 Claude Code 󰅖   󰐕        Z| │  /pri…             █│  claude 󰅖   󰐕
R|  │ ▌ Claude Code            │▌                           Z| │▌    .claude           █│▌claude (walk shim)
```
Owner: `mnml-zig/src/app/ai.zig` (`claudeCode` / `claudeCodeNew*`) and the
dead field in `src/config/Config.zig:280`.

**1.9 — `ai.claude_usage` is a different feature on Zig.** `ai/03-usage`.
Rust opens the `Claude usage` pane (`personal … 0% used`, `Current session /
Current week`, `:ai.refresh_usage`). Zig toasts `Claude usage: the quota
endpoint is not in this build — sho…` and opens `AI spend (24h): 0 tokens ·
$0.0000 · 0 sessions`. Self-documented, but it is the same palette entry
landing on different data. The statusline's usage chip (`󱸀 0% 5h 99% 1d`) is
likewise Rust-only. Owner: `mnml-zig/src/app/ai.zig:1530` (`claudeUsage`) vs
Rust `src/ui/claude_usage_view.rs`. Rust-only feature.

**1.10 — A workspace with a Rust-era `.mnml/config.toml` gets an unreadable
toast on every Zig launch; Rust shows `RESTRICTED` instead.** Every Zig
screen, rows 36–38: `│ config: /private/tmp/walk/slot1/ws/.mnml/config.toml:
mnml-… │`. The message (`src/config/load.zig:229`: "mnml-zig reads
config.zon, not TOML — run `mnml export-config-zon` (0.2.22) to convert this
file") is capped at 60 cells by the toast painter, so the path prefix eats
the budget and the instruction never shows — not at 80, 120 or 200 columns
(`smoke-200x60`). The toast also paints **over overlays**: it hides the last
rows of the palette (`palette-80x24/00-open`), of the which-key root menu
(`w` is gone) and its `g` submenu (`w`, `x`), of the help and cheatsheet
boxes. Rust, on the same workspace, reads the file and (the path being
untrusted) shows `󰌾 RESTRICTED` on the statusline and, on a fresh data root,
a `┌ Confirm ─┐ Trust / Don't trust` dialog. Both are first-launch
experiences on an existing workspace; only one is legible.
```
Z 200x60 row57| │ config: /private/tmp/walk/probe/ws/.mnml/config.toml: mnml-… │
Z palette 80x24| ││ view  ·  Picker: toggle po┌────────────────────────────────────────── × ┐
Z              | │└───────────────────────────│ config: /private/tmp/walk/slot1/ws/.mnml/con│
```
Owner: `mnml-zig/src/ui/toast.zig` (the cap; put the file name last) and
`src/app/render.zig` (paint order: toasts before overlays).

**1.11 — `Esc` never dismisses a toast on Zig; they stack.** `picker/04-recent`
… `07-clipboard`: after `picker.recent`, `picker.buffers`, `picker.marks`,
`picker.clipboard` (each with an `esc` before it) Zig shows `no recent
files` / `no marks` / `clipboard empty` boxes stacked three deep over the
editor; Rust shows at most one (its `Esc` handler clears the toast stack,
`src/tui/mod.rs:2411`). Zig has `toast.dismiss_all` (`src/app/cmd_app.zig:36`)
but only the toast's right-click menu reaches it. Owner:
`mnml-zig/src/app/dispatch.zig` (`keyInner`, no toast branch on `esc`).

**1.12 — `picker.recent_commands` is a working picker on Rust and `no :
lines yet` on Zig.** `palette/03-recent-commands`. Same id, same title
("Pick a recently-run command"). Rust: `┌ Recent commands ─┐ … 1 │ ▌integrations
· Integrations: fire auto-updates now`. Zig: nothing opens, a toast `no :
lines yet` — the id is wired to the `:` line's history, not to the commands
that ran. Relatedly the empty-query palette on Rust pins recently-run
commands first (`▌★ integrations · …`); Zig's list is registration order.
Owner: `mnml-zig/src/app/cmd_picker.zig` (or wherever `picker.recent_commands`
resolves) vs Rust `src/app/picker.rs:1712`.

### SEV-2

**2.1 — Diagnostics: a split pane below the editor on Rust, a right-panel
list on Zig.** `diagnostics/00`. Rust `lsp.diagnostics` opens `󰀦 problems ✓`
as a second pane under `sample.ts` and focuses it (`activeFile=""`,
`0 errors · 0 warnings`, `⏎ jump  r refresh  s severity-filter  esc back`);
Zig opens `DIAGNOSTICS (0)` in the right panel, filter pill, `No problems —
the language se…`, the editor stays focused. `view.toggle_bottom_panel`:
Rust toggles it; Zig toasts that there is no bottom panel.
`lsp.diagnostics_filter`: Zig toasts the new filter; Rust shows no feedback.
Owner: `mnml-zig/src/app/lsp.zig:1323` vs Rust `src/ui/diagnostics_view.rs`.

**2.2 — `+` menu → `New ▸` → `→`: Rust ignores the key, Zig opens the
row-curation submenu on the wrong row, and `Enter` pins instead of creating.**
`plusmenu/03-right`, `04-enter`. Both open `Create…` with `New ▸ / Open ▸ /
AI ▸ / Dock ▸ / Integrations ▸`, both hang `Scratch buffer / From clipboard /
HTTP request / Shell / Browser tab / Tab page` off `New`, both move two rows
down. `right`: Rust's child box is unchanged (its `Right` arm reads the
parent menu's selection — `src/app/context_menus.rs:2254`); Zig replaces the
child with `Pin to top / Hide this row / Copy command id` for the row *above*
the cursor. `enter`: Rust opens `GET  new request` (`panes=[1]`); Zig toasts
`pinned scratch.from_clipboard to the top of +` and opens nothing.
```
R 03|│   New          ▸ │┌───────────────────┐   Z 03|│   New          ▸ │┌────────────────────┐
R   |│   Open         ▸ ││   Scratch buffer │   Z   |│   Open         ▸ ││   Pin to top      │
R   |│   Dock         ▸ ││   HTTP request   │   Z   |│   Dock         ▸ ││   Copy command id │
```
Owner: `mnml-zig/src/app/dispatch.zig` (submenu cursor arm-then-move) and
`mnml/src/tui/mod.rs` (`Right | Char('l')` reads `app.context_menu`, not the
open child).

**2.3 — On a fresh data root, Rust's first-launch wizard runs invisibly
under the trust dialog and leaves the workspace untrusted.** `wizard-fresh`.
Rust at rest shows `┌ Confirm ─┐ … Trust / Don't trust` (the workspace's
`.mnml/config.toml` declares an executable integration); `first_launch.show`,
`n`, `down`, `down`, `enter` change nothing on screen (rects flat at 51) —
yet `04-enter` toasts `Setup saved. Reopen anytime via first_launch.show.`
and `05-esc` `Workspace left untrusted — its language servers, formatters…`.
Zig shows `╭ First-launch setup ─╮` section 1 of 7, `n` switches the glyphs
live, `enter` toasts `Setup saved (2 setting(s))`. Rust also records the
"no Nerd Font" answer without applying it (Zig switches the UI live).
Owner: `mnml/src/ui/first_launch_overlay.rs` + `src/tui/mod.rs` (dispatch
order: the wizard takes keys, the confirm takes the paint). Rust-side.

**2.4 — Settings overlays are different products.** `settings/*`. Rust:
a bordered box with a filter field (focused by default), `Save / Cancel`
buttons, rows like `Editor: input style`, footer `r reset row · R reset all`;
pressing `r` types `r` into the filter (`01-reset-row` — the footer's own
promise fails). Zig: no filter, no buttons, the title shows the live config
path, the catalogs are almost disjoint (Zig's are the `config.zon` sections).
Owner: both `src/ui/settings*.{rs,zig}`; the Rust `r` is
`mnml/src/app/settings_overlay.rs` (focus default).

**2.5 — The cheatsheet: alphabetical sections in a bordered box (Rust) vs
declaration order in a borderless pane (Zig); Rust also lists unbound
commands.** `cheatsheet/00`. Rust's first screen is `── ai (14)` (`<leader>aC
AI: Claude chat…`), Zig's is `app (1)` then `view (37)`; Rust's catalog has
an `(unbound)` section Zig drops. Same door, unrecognisable screens.
Owner: `mnml-zig/src/app/cheatsheet.zig:55-93` vs `mnml/src/cheatsheet.rs:49`.

**2.6 — HTTP: `http.new_request` prompts for a path on Zig, opens a scratch
tab on Rust; `Down ×3, Enter` on a fresh request fires on Rust, not Zig.**
`http/06-new-request`, `02-enter`. Zig: `┌ New request path (e.g.
requests/users.http) ─┐`, no pane until submitted (`panes=[2]`); Rust: a
third `GET  new reques…` tab (`panes=[3]`). Zig's `Down` on the URL field
moves focus to the body (`src/app/request_pane.zig:1096`), so `Enter` no
longer sends; Rust's `Down` on the URL is a no-op and `Enter` fires (`✗ bad
request: builder error` in four places). Owner: `mnml-zig/src/app/cmd_http.zig:878`
and `src/app/request_pane.zig:1088-1099`.

**2.7 — Rust appends to the workspace's `.gitignore` on launch; Zig does not
— so every git count differs by one.** Probe on a spare copy: after Rust's
first frame `.gitignore` gains `# Added by mnml — workspace state: IPC,
session, and HTTP history / captured traffic / env values (these carry
secrets)` + `.mnml/` (`mnml/src/git/stage.rs:127 append_gitignore`), and
Rust's status pane lists `M .gitignore` (`16 change(s)`; Zig `15`; the
splash `on main · 2 changed files` vs `1`). A user comparing the two apps on
one repo sees Rust dirty it. Rust-side, by design — but Zig should decide
whether to inherit it; a repo that already ignores `.mnml/` (this one:
`.gitignore:23 .mnml/*`) still gets the line.

**2.8 — The same file's diff has 3 hunks on Rust, 1 on Zig — `git diff` says
2.** `git/07-diff` on `.claude/settings.json`: Rust `Hunk 1/3`, Zig `Hunk 1/1`,
`git diff -U3` on the pristine copy: `@@ -3,7 +3,18 @@` and `@@ -102,4 +113,4 @@`.
Owner: `mnml-zig/src/git/parse.zig` (`parseHunkHeader` / `closeHunk`, ~400/557)
merges; Rust's splitter (`src/git/diff.rs`) splits one further.

**2.9 — Right-clicks open menus with different item sets, not just different
grouping.** `contextmenus2/*`, `tree/04`, `editor/11-12`, `pty/04`:
- tree row: Rust has `Open in terminal`, `Open externally`; Zig has `Paste
  here`, `Refresh tree` and five separators (Rust none).
- tree header: Rust `Set as default workspace` / `Remove workspace`; Zig
  `New file… / New folder… / Paste here / Copy path`.
- rail Explorer: Zig adds `Move to right side`.
- editor tab: different titles and items; and because Zig's tabs are wider,
  the fixed-coordinate click lands on a different tab on each side.
- pty pane: Zig adds `Rename…` and a `Color ▸` submenu; Rust's `Restart`
  carries `(Ctrl+C)`.
- statusline branch chip (`contextmenus2/04`): near parity — `Commit graph /
  Status pane / Checkout branch… / New branch… / Fetch / Pull / Push / Stash…
  / Stash pop / Commit… / AI commit message`; Zig adds `Refresh` and
  separators.
Owner: `mnml-zig/src/app/context_menus.zig:191` (`openTreeMenu`) etc. vs
`mnml/src/app/context_menus.rs:323`.

**2.10 — Clicking the statusline branch chip: Rust opens the GIT section +
graph; Zig opens the status pane.** `statusline2/06-click-branch` (row 38).
Rust: `VIEW`, GIT sidebar with `LOCAL 17`, the graph pane; Zig: the `git
status` pane, tree still in the sidebar. Owner: `mnml-zig/src/ui/statusline.zig`
(the chip's click command) vs `mnml/src/ui/statusline.rs`.

**2.11 — With a file open, Rust's statusline collapses the branch chip to
`mai…` and drops the `󰐙 14 󰛕 2` stat chips; Zig keeps them.**
`statusline/01-file`: `R| EDIT   mai…  sample.rs …` vs `Z| EDIT   main  󰐙 14
󰛕 1   sample.rs …`. Rust-side. Zig shows `LSP?` in EDIT with no server; Rust
shows no chip. Owner: `mnml/src/ui/statusline.rs` (~2281).

**2.12 — The click-discovery overlay is modal on Zig, pass-through on Rust.**
`discovery/01-down2`: Rust's arrows move the tree under the overlay (a file
previews, the `Editor gutter [1]` count updates); Zig swallows every key but
`esc` / `f1` (`src/app/dispatch.zig:1110`). And `debug.toggle_click_inspector`
then a click: Zig toasts the inspected target; Rust shows no result toast.
Owner: `mnml-zig/src/app/dispatch.zig:1110` (or Rust's `show_discovery_overlay`
bool, `src/app/mod.rs:5852`, whichever is wanted).

**2.13 — In the NOTES section, a right-click on a row is an explicit stub on
Zig (`no menu in this build`) and leaves `Enter` dead afterwards.**
`notes/06-rclick-row5`, `08-enter`: Zig shows no menu and the later `Enter`
opens no note; Rust opens the row's menu. FINDINGS (empty on this workspace)
adds two small ones: Zig hides the `(0)` header count Rust always shows, and
Zig's filtered-empty copy stays `No findings yet.` where Rust says `No
findings match /a — 0 in workspace` (`src/findings.zig:751-757`). TODOS: after `todos.new` + `esc` Zig's info box stays on the generic
`Sidebar` copy (`todos/05`); Rust returns to the TODOS copy. Owner:
`mnml-zig/src/app/notes.zig` / `src/ui/info_box.zig`.

**2.14 — The outline goes stale on Rust after an edit; Zig's follows.**
`outline/02-enter`: after the edit the Zig panel's line numbers move with
the text, Rust's do not until a re-open. Owner: `mnml/src/app/lsp.rs`
(outline refresh on buffer change).

**2.15 — Which-key: `ctrl+k` then `i` with no frame between drops the
leader on Rust.** `whichkey/02-i-sub`: Rust shows nothing (the global
3-key chord `ctrl+k i d`, `src/command.rs:5301`, leaves `ctrl+k i` pending
with no fallback — `src/input/keymap.rs:292-302`); Zig shows `<leader> i`.
Also: `<leader> g` maps the same letters to different commands; Zig's `i`
submenu lacks `browse Nerd Font glyphs`; Zig's root leader has both `l →
+lsp` and `r → +lsp` (and `d → +debug`, Zig-only). Owner: `mnml/src/tui/chord.rs:155`;
`mnml-zig/src/commands/specs.zig` (the duplicate `+lsp`).

**2.16 — Menu bar: `view.menu_bar_cycle` blanks the labels on Rust; the View
menu's items differ; `»` opens the overflow list on Zig (documented
Zig-only) and the first hidden menu on Rust.** `menubar/07-chevron`, `09-cycle`.
Owner: `mnml/src/ui/menu_bar.rs` (cycle repaint) / `src/app/menu_bar.zig`.

**2.17 — Editor chrome: Rust paints indent guides, a left-gutter change mark
and a right-edge change strip; Zig paints a change mark after the number
and nothing else; Rust hard-wraps with `↪`, Zig word-wraps unmarked; Rust
renders tabs zero-width.** `editor/*`, `tree/01-down3`. Text, gutter,
breadcrumb, tabs and the info box agree for all ten languages (colours are
invisible here). Rust: `▎  6     │ "mcp__…` (change mark at the gutter's
left, an indent guide `│` at the block's column) and `▎` at column 115 on
changed rows; Zig: `   6▎      "mcp__…`. `editor/02-go`: Rust's tab-indented
Go body has no indentation at all (`7 ID    int`) — the CLAUDE.md-documented
"columns are chars" gap made visible; Zig `7     ID    int`. Wrap:
`R| 2 export interface Todo { id: number; title` / `R|   ↪ : string; done: boolean }`
vs `Z| … title:` / `Z|     string; done: boolean }`; Rust also paints an
inline hint `...data:` after line 7. Owner: `mnml-zig/src/ui/editor_view.zig`
(guides, strip, marker); `mnml/src/editor.rs` (tabs).

**2.18 — Marketplace / details.** `integrations/03-marketplace`: Rust shows
three cached entries under a GitHub rate-limit (`rust.log`: `marketplace:
… HTTP status 404`), Zig zero and logs nothing; `integrations.show_details`
opens a details pane on Rust and nothing on Zig (no row). Follows 1.1.

**2.19 — SESSIONS (recorded; being fixed elsewhere).** On the seeded home
(`sessions-seeded/00`) Zig lists four cards (`▌ run the release build / ▌ you:
run the releas… / ▌ claude: Running it.`), Rust `SESSIONS  (0) / No sessions
yet.` (its section lists pty panes; none resumed here). `sessions.table` is
Zig-only (`SESSIONS (3 of 4)  ended: hidden  ⏸ pause  ? help  sort: state`;
`ws (3 · 1 hidden)`; `✦ ⚠ wait / ● live / ○ idle` rows with id, tokens,
cost, age, dirty); Rust's `ai.dashboard` was not driven. `view.activity_agents`
on Rust is `AGENTS (4)` with `Action needed (1) / Running (1) / Done (2)`,
on Zig an alias of SESSIONS. At 80×24 the Zig SESSIONS info box shows the
debugger's copy (`Arrows walk rows. Enter jumps to the source. F6 cycles
focus.`). Owner: `mnml-zig/src/sessions.zig`; the info copy
`src/app/info_view.zig`.

**2.20 — The AI pane grid (KNOWN, being fixed elsewhere).**
`ai/02-grid-x4-known`: `ai.claude_code_new_x4` lays the four panes unevenly
on Zig. Recorded only.

### SEV-3 (cosmetic)

- **3.1** Tree: when a name clips, Rust drops the git badge (`settings.json.ba█`),
  Zig keeps it and clips the name (`settings.json.?`); Zig's tree scrollbar
  starts on the header row (`/pri…             █│`), Rust's one row lower.
- **3.2** The welcome screen's `Tip   install mnml to PATH …` row is
  Rust-only (clipped hard at 80 cols: `…works anywh`).
- **3.3** Rust's HTTP response tab row overprints at 80 cols: `│  Body
  Headers  Coo ⚡r AIT wrap e copy s — ▼  │` (Zig `Body  Headers  Cookies
  Timeline  Tests`). Rust-side.
- **3.4** Zig's HTTP section lists the requests inside a `.http` file as
  child rows (`demo.http › GET httpbin.org/ · POST httpbin.org/`, `HTTP (6)`);
  Rust lists the file. Zig-only feature (the folder grouping is in the README;
  the children are not).
- **3.5** Sort toasts: Rust `todos: …`, Zig `sort: …`; typing a letter filters
  on Rust, Zig wants `/` first (the documented idiom).
- **3.6** Zig's `New TODO` prompt does not clear the ASCII art behind it.
- **3.7** Palette: Rust `813` commands, Zig `1042`; Rust's filtered `git`
  list has three fewer rows, so two arrow-downs land on different commands.
- **3.8** Picker: buffers picker title/label format differ; empty-state
  wording differs; Rust's file count is one higher (it counts the
  `walk-samples/` dir?). Rust leaks the pane's text past the picker box's
  right border at one row (`palette-80x24/00`: `█│nywh`) — Rust-side.
- **3.9** PTY: pane title `ghostty (zsh)` (Rust) vs `zsh` (Zig); Zig's title
  ignores the child's OSC title and the user's pinned integration glyph.
- **3.10** Image pane: Zig's info is denser (path, dimensions, `i header · r
  reload · Esc tree` hint); Rust's lacks the path and size.
- **3.11** Markdown preview: Rust's inline renderer leaves a GFM table as
  raw pipes (`| col | val |`) where Zig draws a table (`col │ val`);
  `markdown.cycle_engine` only actually tries the external tool on Rust.
  Rust-side (`mnml/src/ui/md_preview.rs`).
- **3.12** Vim `:` line: Rust pops a live command-suggestion list; Zig is a
  bare ex line. All motions/modes/`dd`/`u`/`/`/`zc` matched (`vim2-vim`).
- **3.13** Zig graph gutter `▌▌` (double accent, also on the toolbar row);
  Rust `▌`.
- **3.14** Zig `ai.show_config` toast lists different fields and does not gate
  on the backend; `opened N Claude sessions` capitalisation differs.
- **3.15** The which-key `<leader> i` box on Zig lists `E / I / d / h / r`;
  Rust adds the glyph browser (2.15).

## 3. Per-surface table

`rows` = rows whose columns 4+ differ, per snapshot (the accepted rail
excluded, the statusline and the Zig config toast dropped); nearly every
body row differs on most surfaces because the accepted idioms (branches
panel, list-panel top block, tree badges, editor strips) touch every row.
Classes: **A** accepted residue, **C** cosmetic, **S** structural, **B**
behavioural, **Z** Zig-only feature, **R** Rust-only feature — counts of
distinct row-groups per surface across its snapshots, as classified.

| surface | steps file | snaps | rows beyond rail | A | C | S | B | Z | R | findings |
|---|---|---:|---|--:|--:|--:|--:|--:|--:|---|
| tree | `steps-tree` | 8 | 27–37 | 4 | 3 | 1 | 1 | 0 | 0 | 2.9, 3.1, 2.17 |
| search | `steps-search` | 6 | 34–38 | 2 | 1 | 2 | 2 | 0 | 0 | 1.2 |
| git | `steps-git` | 10 | 38 | 3 | 2 | 3 | 4 | 1 | 0 | 1.3–1.6, 2.7, 2.8 |
| git 80×24 / 200×60 | same | 10 / 10 | 19–22 / 58 | 3 | 1 | 1 | 1 | 0 | 0 | 1.3, 1.4 |
| debug | `steps-debug` | 4 | 32–38 | 1 | 0 | 1 | 2 | 1 | 0 | 1.7 (Rust body unclickable) |
| integrations | `steps-integrations` | 8 | 28–38 | 1 | 0 | 2 | 2 | 0 | 0 | 1.1, 2.18 |
| sessions (real home) | `steps-sessions` | 7 | 29–38 | 3 | 1 | 1 | 2 | 1 | 1 | 2.19, 1.7 |
| sessions (seeded) | `steps-sessions` | 7 + 7 | 30–38 / 20–23 | 3 | 2 | 2 | 2 | 1 | 1 | 2.19, 1.7 |
| http | `steps-http` | 7 | 29–36 | 4 | 1 | 1 | 2 | 1 | 0 | 2.6, 3.4 |
| http 80×24 | same | 7 | 14–19 | 4 | 2 | 0 | 0 | 1 | 0 | 3.3 |
| todos | `steps-todos` | 9 | 29–33 | 5 | 3 | 1 | 1 | 0 | 0 | 2.13, 3.5, 3.6 |
| notes | `steps-notes` | 9 | 28–33 | 5 | 2 | 0 | 2 | 0 | 0 | 1.7, 2.13 |
| findings | `steps-findings` | 9 | 30–33 | 5 | 2 | 0 | 1 | 0 | 0 | as todos/notes (same idiom; `findings.new` prompt on both) |
| scripts | `steps-scripts` | 2 | 37–38 | 1 | 1 | 0 | 0 | 1 | 0 | Zig-only SCRIPTS (Lua) |
| outline | `steps-outline` | 4 | 32–33 | 2 | 1 | 0 | 1 | 0 | 0 | 2.14 |
| diagnostics | `steps-diagnostics` | 3 | 38 | 1 | 1 | 2 | 1 | 0 | 1 | 2.1 |
| editor (10 langs) | `steps-editor` | 14 | 20–32 | 3 | 3 | 2 | 1 | 0 | 0 | 2.17, 2.9 |
| editor 80×24 / 200×60 | same | 14 / 14 | 12–23 / 33–47 | 3 | 3 | 1 | 0 | 0 | 0 | 2.17 |
| mdpreview | `steps-mdpreview` | 4 | 18–27 | 2 | 1 | 0 | 1 | 0 | 0 | 3.11 |
| image | `steps-image` | 2 | 19 | 2 | 2 | 1 | 0 | 0 | 0 | 3.10 |
| pty | `steps-pty` | 5 | 16–27 | 2 | 3 | 1 | 0 | 1 | 0 | 2.9, 3.9 |
| ai | `steps-ai` | 5 | 28–38 | 2 | 3 | 1 | 2 | 0 | 1 | 1.8, 1.9, 2.20 |
| palette | `steps-palette` | 4 | 24–30 | 1 | 2 | 1 | 1 | 0 | 1 | 1.12, 3.7 |
| palette 80×24 | same | 4 | 19–21 | 1 | 2 | 1 | 0 | 0 | 0 | 1.10, 3.8 |
| picker | `steps-picker` | 8 | 8–24 | 1 | 3 | 1 | 1 | 0 | 0 | 1.11, 3.8 |
| settings | `steps-settings` | 6 | 31–32 | 0 | 1 | 2 | 1 | 1 | 0 | 2.4 |
| whichkey | `steps-whichkey` | 3 | 26–33 | 1 | 1 | 1 | 1 | 1 | 1 | 2.15, 1.10 |
| cheatsheet | `steps-cheatsheet` | 4 | 38 | 0 | 2 | 3 | 0 | 0 | 1 | 2.5 |
| help | `steps-help` | 4 | 9–12 | 2 | 2 | 0 | 0 | 0 | 0 | near parity; 1.10 |
| wizard (fresh root) | `steps-wizard` | 6 | 27–39 | 0 | 1 | 1 | 2 | 0 | 0 | 2.3 |
| plusmenu | `steps-plusmenu` | 5 | 27–38 | 1 | 1 | 0 | 2 | 0 | 0 | 2.2 |
| menubar | `steps-menubar` | 10 | 24–30 | 3 | 1 | 1 | 2 | 1 | 0 | 2.16 |
| contextmenus (×2) | `steps-contextmenus2` | 9 | 27–35 | 2 | 2 | 3 | 0 | 1 | 0 | 2.9 |
| statusline (×2) | `steps-statusline2` | 8 | 24–38 | 3 | 1 | 1 | 1 | 0 | 1 | 2.10, 2.11 |
| statusline 80×24 | `steps-statusline` | 8 | 17–19 | 3 | 1 | 0 | 0 | 0 | 0 | accepted overflow |
| discovery | `steps-discovery` | 3 | 13–34 | 1 | 1 | 0 | 2 | 0 | 0 | 2.12 |
| vim (×2) | `steps-vim2` | 13 | 17–28 | 3 | 1 | 1 | 0 | 0 | 1 | 3.12; motions matched |
| vim which-key (×2) | `steps-vim-whichkey2` | 4 | 23–30 | 2 | 1 | 1 | 0 | 1 | 0 | 2.15 (no popup on either side without a file open) |
| tree 80×24 / smoke 200×60 | `steps-tree`, `steps-smoke` | 8 / 1 | 17–23 / 35 | 4 | 2 | 0 | 0 | 0 | 0 | 3.2; rail packs/spaces on both |
| doors | `steps-doors` | 1 | — | — | — | — | — | — | — | §4 |

## 4. Doors

**IPC.** The verb sets are identical on both sides (`open, key, type,
run-command, register-command, click, hover, scroll, drag, mouse_down/move/up,
wait_ms, expect_screen, snapshot, toast, toast-persistent, toast-dismiss,
progress-start/update/end, statusline-set-segment/clear-segment, notify,
open-pty, set-activity-badge, dump-rects, ghost, quit, restart`), and both
write `screen.txt`, `status.json`, `rects.json`, `events.jsonl`. Rust's IPC
dir is fixed at `<ws>/.mnml/ipc`; Zig honours `MNML_IPC_DIR`.

**Command ids** (Rust: every `id: "…"` literal under `src/`, 801; Zig:
`docs/commands.md`, 1042). 792 ids are on both sides — but as §2 shows, a
shared id is not a shared behaviour (`view.activity_search`,
`view.activity_agents`, `ai.claude_usage`, `picker.recent_commands`,
`git.graph`, `http.new_request`, `lsp.diagnostics`, `git.commit`). Verified
live with `steps-doors.jsonl` (94 ids, each run on both sides, the
`command_run` ack read back):

- **Rust ids with no Zig door:** `cloud_agents.toggle_view`,
  `cloud_agents.view_compact`, `cloud_agents.view_standard` (the CLOUD AGENTS
  section's own views). The rest of Rust's cloud-agents / agents family
  (`cloud_agents.new_run*`, `agents.new_from_pr`, `ai.dashboard*`) share ids
  with Zig, where they land on SESSIONS / the sessions table. (`build.1`,
  `job.1`, `plugin.x`, `slack.*`, `crates.io` in the grep are fixture strings,
  not commands — both sides ack them `false`.)
- **Rust surfaces with no Zig door:** the AGENTS and CLOUD AGENTS sections
  (accepted), the bottom panel (`view.toggle_bottom_panel` — Zig toasts),
  the `Claude usage` quota pane, the `:` line's live suggestion list, the
  settings filter/Save/Cancel, the palette's recents pinning, the welcome
  `Tip` row, the ex-command row under the statusline, the indent guides and
  change strip.
- **Zig ids with no Rust door (248, all ack `false` on Rust):** `git.*` 69
  (conflict resolution, rebase plan, stage/unstage lines, reset/squash/fixup,
  worktree_add_from, graph_detail, palette_all, repo_next/prev, command_log…),
  `sessions.*` 31 (table, pin, rename, kill, export, worktree merge/remove,
  cloud_*…), `http.*` 27 (body types, vars, proxy, timeout, redirects,
  rename/duplicate/move request…), `files.*` 18 (the file manager: marks,
  sort, hidden, preview, trash), `dap.*` 16, `view.*` 10
  (`activity_scripts`, `activity_bar_cycle`, `only`, `reset_layout`,
  `focus_top/bottom/previous`, `menu_bar_open`, `move_section_left/right`),
  `grep.*` 8, `todos.*` 7, `dotnet.*` 6, `integrations.*` 6 (dev build/install,
  pin/unpin, toggle palette bar), `test.*` 6 (Playwright), `dock.*` 5,
  `findings.*` 4, `menu.*` 4, `script.*` 4 (Lua), `lsp.*` 3, `notes.*` 3,
  `session.*` 3, `zon.*` 2, `toast.*` 2, `tree.*` 2, `buffer.*` 2, `app.*` 2,
  and one each of `ai.new_session_worktree`, `coverage.toast`,
  `editor.set_tab_width`, `file.copy_path`, `harpoon.clear`, `messages.clear`,
  `perf.copy_stress`, `trusted.forget`.
- **Zig surfaces with no Rust door:** SCRIPTS (Lua), the sessions table, the
  ZON view, the conflict-resolution editor, the branches panel, the FONTS
  block, the file manager, the `»` overflow list, the HTTP file's request
  children, COOKIES.

## 5. Coverage — what this walkthrough could and could not see

It saw **cells**: every glyph codepoint, label, count, box, row order,
focus, cursor, pane list and click rect, after every step, on both sides,
from the same files. It could not see **colour or font** (the theme, the
accent bars' hues, syntax highlighting, the MnmlSymbols glyphs' actual
shapes — every `.rs/.py/.go/…` file "matched" only as text), **motion**
(scroll feel, wheel multipliers, drag, animation, the spinner), **timing**
beyond first-frame and ack (the LSP toast, the marketplace fetch, the
sessions scan are all racy — some snapshots caught them, some did not), or
anything **network-bound** (`http.send` failed identically on both — no
`httpbin` from the sandbox; the marketplace was rate-limited). The
harness also cannot dismiss what a human would (the Zig config toast sat on
every screen), cannot see a hover highlight (colour), and the steps files
are one path through each surface — the tree's expand/collapse, the vim
motions, the menus' rows and the palette were exercised; drag-to-resize,
splits, the `+` dock, the browser/CDP pane, the DAP session itself, the
integrations' own panes, the HTTP chains/mocks/envs, the `.test` format and
the real `claude` were not. Rust's SESSIONS section stayed empty in this
harness on both the real and the seeded home (it lists pty panes it
resumed; none were), so the "SESSIONS card" comparison is Zig-only here and
was left to the fix in flight. Where the two apps agree on a bug (the git
tab strip opening twelve graph tabs at once; the leader not opening while
the tree has focus) it is recorded in the findings files but not ranked —
it is not a divergence.

## 6. Reproducing

```
# the harness and every steps file
ls docs/ui-spec/walk/
# one surface, both binaries, four slots possible in parallel (paths inside
# run.sh / batch.sh are the /private/tmp/walk layout described in §1)
docs/ui-spec/walk/run.sh 1 git 120x40 standard
docs/ui-spec/walk/run.sh 2 wizard 120x40 standard     # FRESH=1 for an empty data root
docs/ui-spec/walk/run-seeded.sh 120x40                # sessions on the seeded home
```
The private directories (`/private/tmp/walk/{pristine,slot1..4,home,
home-seeded,probe,out,findings}`) were deleted after this report was
written; nothing under the real `~/.config/mnml`, `~/.claude` or the real
workspace was touched (the shims, the symlinks and the copies were the only
writes, and Rust's `.gitignore` append landed on the copy).
