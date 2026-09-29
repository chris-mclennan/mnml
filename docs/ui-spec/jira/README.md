# The Jira spec — every screen of the reference tracker

The reference is `mnml-tracker-jira` **v0.2.24** (the current source of
`mnml-integrations/apps/mnml-tracker-jira`). This file is the inventory
it was read into: every screen, the surfaces on each, the columns and
their content, the keys and the clicks that reach them. The rows below
name each screen by the capture it is read from.

Screens are cut from the offline server only — `tools/jira-diff.sh` runs
the reference and `mnml-jira` against `mnml-fake-jira` (project ENG,
invented people) through the same scripted session and leaves both
sides' dumps in its output folder. No capture of a real site belongs in
this repository: a live run is for the eyes of whoever runs it, in a
scratch folder, and only ever with GET requests.

The inventory is the spec for **what is there**, not for the exact
bytes: `mnml-jira` renders the same content in mnml-zig's own chrome.

## The three families

The app ships as three rail chips over one binary
(`~/.config/mnml/integrations/jira_work.toml`, `jira_fix_versions.toml`,
`jira_boards.toml`): each is `:term mnml-tracker-jira --only <family>`,
which keeps only that family's tabs and hides the tab strip. Inside a
family the tabs still exist — `1`–`9`, `Tab` / `Shift+Tab` switch them
— but nothing on the screen says which is active (the status line's
last message is the only clue: `Recently Done · 12 issues`).

| family | `--only` | tabs (author's config) | renderer |
|---|---|---|---|
| Jira Work | `work` | Assigned (`work_assigned`), Recently Done (`work_recently_done`) | status-grouped tree |
| Jira Fix Versions | `fix-versions` | Current Release (`fix_version_tree`, `project = ENG`, `mode = current_release`, `status_order`, `bumps`) | status-grouped tree |
| Jira Boards | `boards` | Sprint (`board_active_sprint`, `board_id = 200`), Backlog (`board_backlog`) | kanban |

## Screen by screen

Every file is `rust-<family>-<screen>-120x40.txt`. None of them is in
this repository: they were read off the reference's own screens when this
inventory was written and are kept by nobody (see the rule above), so a
name below is a label for the screen, not a path. The offline equivalents
are what `tools/jira-diff.sh` cuts — `<out>/rust-<family>/<snap>.txt` for
the reference, `<out>/zig-<family>.txt` for the port, the snap names in
`tools/jira-diff/rust-*.steps`. The `steps-*.txt` and `rust-cli-*.txt`
files named further down are labels in the same way. "Keys" are what
reaches the screen from the family's list view; the status line's last
segment is the hint strip the app paints for that mode.

### Jira Work — the tree

| file | reached by | what it shows |
|---|---|---|
| `rust-work-assigned` | `--only work` | Row 0: the filter toolbar — `[ Basic ] [ JQL ] [ 🔍 Search ] [ Space ▾ ] [ Assignee: Me ▾ ] [ Type ▾ ] [ Status: All ▾ ]` left, `⟳ Refresh` right. Row 1: the header `KEY STATUS ASSIGNEE UPDATED SUMMARY` (18 / 14 / 20 / 12 / rest). Then one status group per row `▼ Testing (1)` in the tab's `status_order` (default: Testing, In PR Review, Code Review, In Progress, To Do, Open, Done; unknown statuses alphabetical at the end), each ticket under it as `▼ KEY  status  assignee  yyyy-mm-dd  summary`, unresolved tickets auto-expanded with their linked PRs as `▶ MERGED / OPEN / DECLINED` rows (status in the KEY column, the PR title in SUMMARY, `[ Review ] [ Merge ]` on an open PR and `[ Open ]` on every PR after the title), capped at 3 per ticket with a `⋯  Show all N PRs ↴` row. Last row: the status line (`ENG-14997: 0 linked PR(s)`) then the hint `1-9 · ↑↓ · / filter · Space pick · t move · a assignee · f version · w watch · d details · q`. |
| `rust-work-group-collapsed` | `h` / `←` on a group header, or click | The group folded to `▶ Testing (1)`; `l` / `→` / Enter / Space / click reopens it. |
| `rust-work-cursor-pr-row` | `j` `k` `↑` `↓` | The cursor visits every row: headers, tickets, PR rows, the show-all row. The selected row is reverse-video; a bulk-selected ticket is magenta. |
| `rust-work-pr-pipeline` | `l` on a **merged** PR row | The PR opens (`▼ MERGED`) over its post-merge pipeline rows — `→ no pipeline ran on merge commit`, or one `✓ SUCCESSFUL  repo  #build  on branch  date  duration` row each, or `→ pipeline lookup failed: BITBUCKET_ACCESS_TOKEN not set — needed to fetch post-merge pipelines`. Open / declined PRs have no chevron and do not expand. |
| `rust-work-show-all-prs` | click `Show all N PRs ↴`, or Enter / Space on it | The ticket's PR list uncapped in one click (the row is gone). |
| `rust-work-row-click` | click a ticket row | Selects it **and** toggles its expansion (click = Enter). |
| `rust-work-end` / `g` | `G` / `End`, `g` / `Home` | Cursor to the last / first row; the table scrolls to keep it in view. |
| `rust-work-wheel-down` | wheel | Moves the cursor three rows per notch (the list scrolls with it). |
| `rust-work-chip-refresh` | click `⟳ Refresh`, or `r` | Re-fetches the tab (auto-expands unresolved tickets again). Also runs every 60 s (`refresh_interval_secs`), with the UI frozen for the fetch. |
| `rust-work-recently-done` | `2` (`Tab` cycles) | The second tab: one `▼ Done (12)` group, tickets collapsed (`▶`) because resolved tickets are not auto-expanded. |
| `rust-work-tab-cycle` | `Tab` | Back on Assigned; nothing on screen names the tab. |

### Jira Work — the detail pane and the modal

| file | reached by | what it shows |
|---|---|---|
| `rust-work-detail` | `d` | The body splits 60 / 40: the tree keeps the left (its columns squeezed, the toolbar clipped to what fits), the right is `┌ detail ┐`: `KEY  summary`, blank, `type / status / priority / assignee / reporter / fixVersion` right-aligned labels, `watcher: ★ watching (2 total)` (or `☆ no watchers` / `☆ N watcher(s)`), then `── description` with the ADF flattened, then `── comments (N)` newest first, `author  yyyy-mm-dd` and the body indented. `Ctrl+D` / `Ctrl+U` scroll it (`rust-work-detail-scrolled`); moving the cursor re-fetches for the new ticket. Hint: `d close · c comment · a assignee · f version · t move · w watch · Space pick · / filter · q`. |
| `rust-work-comment-editor` / `-typed` | `c` with the pane open | An 8-row `┌ comment on KEY ┐` box docked under the detail: the text with a `│` caret, `Enter` newline, hint `type a comment · Esc cancel` then `Ctrl+S send · Esc cancel · Enter newline`; an error line inside the box if the post fails, the text kept. |
| `rust-work-detail-modal` / `-scrolled` | `D` (or a kanban card click) | An 80 % × 80 % centred box titled ` KEY `, a ` × ` close chip top-right, header row `KEY · summary  [status]`, left 40 %: `Type / Priority / Assignee / Reporter / Labels / Components / Fix version / Sprint / Parent` (`[detail_modal] fields` order, `field_alias` labels, custom fields by id), right 60 %: `Description` (+ `Environment`) flattened, scrolled by `j` / `k` (2), PageUp / PageDown (10), wheel (3). `Esc` / `q` / click `×` / click outside closes. Every other key is swallowed. |

### Jira Work — the pickers

All pickers are a 60 × 18 (transition: 60 × 14) centred box on a black
ground: a `/` filter line with a caret, the rows, a hint row. Type to
filter, `↑` `↓` move, `Enter` commits, `Esc` cancels; a click on a row
commits it, a click outside cancels. The title carries the target: `set
assignee`, `set assignee × 3` with a bulk selection.

| file | reached by | what it shows |
|---|---|---|
| `rust-work-transition-picker` | `t` | `┌ transition KEY ┐`: the issue's own transitions as `▸ 1. Name  → Target status`, `1`–`9` jump, `j` `k` move, hint `1-9 jump · ↑↓/jk move · Enter commit · Esc cancel`; `loading…` first; an error or `(no transitions available — terminal state or no permission)` inside the box. |
| `rust-work-assignee-picker` / `-filtered` | `a` | `┌ set assignee ┐`: `— Unassign —` then every assignable user of the ticket's project (up to 50), filtered live by typing. |
| `rust-work-fixversion-picker` | `f` (Work / Boards) · `F` (Fix Versions) | `┌ assign fixVersion on KEY ┐`: `— Clear fixVersion —` then the project's versions, unreleased first, `(released)` suffixed. |
| `rust-work-action-picker` | `.` | `┌ actions ┐`: the ticket's dispatch buttons by type + status — `[ Implement ] [ Triage ]` (Story / Task in To Do / Open / In Progress), `[ Fix ] [ Triage ]` (Bug), `[ Test ]` (Testing), `[ Review ]` (PR Review), `[ Triage ]` (Bug Reopened); nothing → a status-line hint instead of an empty picker. Enter dispatches (see the queue below). |
| `rust-work-chip-assignee-picker` | click `[ Assignee ▾ ]` (Boards: the `+N` / `[?]` chips) | `┌ filter by assignees (Space toggles) ┐`, multi-select `[x] / [ ]` rows: `— Me (Current User) —`, `— Unassigned —`, then every assignee seen on the tab with its count; hint `… Space toggle · Enter apply …`. |
| `rust-work-chip-type-picker` | click `[ Type ▾ ]` | `┌ set type ┐`: `— Clear type —` then the issue types seen on the tab; the chip then reads `Type ▪ Bug ▾`. |

### Jira Work — bulk selection, the filter, the JQL editor, the chips

| file | reached by | what it shows |
|---|---|---|
| `rust-work-bulk-selected` | `Space` on ticket rows | Selected tickets in bold magenta; hint `↑↓ · Space pick · t move · a assignee · f version · Esc clear · / filter · q`. `Esc` clears the set. (On a tree tab `Space` is bound to tree-activate, so the selection is toggled by the second `Space` of the pair — see the notes.) |
| `rust-work-bulk-transition` | `t` with a selection | `┌ transition × N ticket(s) ┐` (the list is the **focused** ticket's transitions; the commit matches each selected ticket's transitions by name, skips the ones without it, and reports `N ticket(s) → Status · skipped …`). The dump shows the single-ticket title `transition ENG-15426` because on a tree tab `Space` never selected anything (note 7). |
| `rust-work-bulk-assignee` | `a` with a selection | `┌ set assignee × N ┐`; likewise `f`. Same caveat: the dump shows the single-ticket title. |
| `rust-work-filter-editing` / `-committed` | `/` (or click `[ 🔍 Search ]`) | The hint changes to `type to filter · Enter commit · Esc cancel` and the Search chip reads `[ 🔍 qr ]` once committed with ` · 28 tickets` after the chips — **but no filter strip is painted and the tree is not filtered** (see the notes). `Esc` clears. |
| `rust-work-jql-editor` / `-typed` | `E`, or click `[ JQL ]` | A full-width box near the bottom: `┌  JQL — type to edit · Enter=run · Esc=cancel ┐` with the tab's resolved JQL hard-wrapped, a `│` caret, grows to 8 rows. Keys: `←` `→`, Home / End / `Ctrl+A` / `Ctrl+E`, `Alt+←` / `Alt+→` words, Backspace / Delete, `Ctrl+W` / `Alt+Backspace` word back, `Ctrl+U` kill to start, `Ctrl+K` kill to end, paste, a click places the caret. `Enter` replaces the tab's JQL (in memory) and re-fetches; `Esc` keeps the old one. |
| `rust-work-chip-jql` / `-mode` | click `[ JQL ]` | Opens the editor and flips the mode chip: `[ JQL ]` active, `[ Basic ]` dim, until `[ Basic ]` is clicked. |
| `rust-work-chip-space` | click `[ Space ▾ ]` (also `More filters`, `Save filter`) | Not wired: the status line says `filter not wired yet (round-1 visual)`. The chip reads `Space: ENG ▾` on a tab with a `project`. |
| `rust-work-chip-status-unresolved` / `-resolved` | click `[ Status: All ▾ ]` | Cycles All → Unresolved → Resolved → All: a client-side scope over the tree (empty groups dropped, counts rewritten). **Resolved on the Assigned tab empties it and the app paints `(no issues)` with the toolbar gone** — nothing brings it back but `q`. |

### Jira Fix Versions

Same renderer, chips and pickers as Work; these are the differences.

| file | reached by | what it shows |
|---|---|---|
| `rust-fixv-current` | `--only fix-versions` | `[ Space: ENG ▾ ]` in the toolbar; the release's tickets grouped by the tab's `status_order` (Testing, In PR Review, In Progress, To Do, Done); a ticket promoted by a bump carries ` ★` after its key and sits in the target group with its real status in the STATUS column (`ENG-14806 ★  PR Review` under `▼ Testing (11)`, from `pr_approved = "Testing"` / `no_open_prs = "Testing"`; `release_cut = { Done = "top" }` when the global `release_cut` flag is on). The resolved version name is **not** on screen: the `[ Fix versions = 13.19.0 ▾ ] [ⓧ]` pill and the ` · N tickets` count are dropped when the seven fixed chips fill the row, which they do at 120 columns. |
| `rust-fixv-tab-version-picker` / `-filtered` | `f`, or click the pill | `┌ switch tab view to fixVersion ┐`: every version of the project, unreleased first; committing rewrites the tab's JQL to `project = ENG AND fixVersion = "X" ORDER BY rank` and re-fetches. |
| `rust-fixv-ticket-version-picker` | `F` | The per-ticket picker (Work's `f`). |
| `rust-fixv-review-on-ticket-row` | `V` on a ticket row | `no PR under cursor` on the status line; on a PR row `V` dispatches a Review for that PR. `I` / `X` / `T` dispatch Implement / Fix / Triage for the focused ticket (Fix Versions only; on Boards `T` is the team picker and `V` the tab-version picker). |
| `rust-fixv-detail`, `-detail-modal`, `-transition-picker`, `-assignee-picker`, `-action-picker`, `-bulk-selected`, `-bulk-transition`, `-filter-*`, `-jql-editor`, `-end`, `-wheel-down`, `-chip-status-*` | as on Work | The same surfaces on the release tab. |

### Jira Boards — the kanban

| file | reached by | what it shows |
|---|---|---|
| `rust-boards-sprint` | `--only boards` | Row 0: the kanban toolbar — `[ Board: Apollo ▾ ] [ Sprint: <active sprint> ▾ ] [ 🔍 Search ]`, the avatar cluster (up to five ` XX ` initials chips, each in a colour hashed from the account id, filled when active; ` [?] ` the Unassigned toggle; ` +N ` overflow), `[ Version ▾ ] [ Epic ▾ ] [ Type ▾ ] [ Label ▾ ] [ ⚡ Quick filters ▾ ] [ ⚙ Settings ]`. Below: four bordered columns of equal width, ` To Do (n) `, ` In Progress (n) `, ` Testing (n) `, ` Done (n) ` (statuses bucketed by name: To Do / Backlog / Open / Reopened / Selected for Development → To Do; Testing / In PR Review / In Review / QA / Ready for QA / Code Review → Testing; Done / Closed / Resolved / Released → Done; everything else In Progress), the column holding the cursor with a cyan border. Each card: `▶ <type glyph> KEY` (bug / story / task / epic / sub-task / spike glyphs), the summary word-wrapped and indented, `· assignee` italic, the action buttons `[ Implement ] [ Triage ]` etc., a blank row. A column with more cards than rows ends in `↓ more · j/k scroll`. Hint: `↑↓ · / filter · Space pick · . actions · t move · a assignee · T team · w watch · d details · q`. |
| `rust-boards-cursor` | `j` `k` | The cursor moves through the tab's issue list in fetch order (rank), so it hops between columns; the focused card's key is reverse-video. |
| `rust-boards-card-expanded` | `>` on the focused card, or click its `▶` | The card grows: `#label` chips (up to four, `+N`), `(click card for full details)`. |
| `rust-boards-detail-modal` | `D`, or click a card body | The detail modal (above). |
| `rust-boards-detail-pane` | `d` | The kanban squeezed to 60 % with the detail pane beside it. |
| `rust-boards-team-picker` | `T` | `┌ filter kanban by team ┐`: `— Clear team —` then every component, label and `team_field_id` value on the tab; committing adds a server-side `("Team" = X OR component = X OR labels = X)` clause and re-fetches. |
| `rust-boards-board-picker` | click `[ Board ▾ ]` | `┌ switch board ┐`: `— Board default —` then every board of the project tagged `[scrum]` / `[kanban]`; committing re-fetches from that board. |
| `rust-boards-sprint-picker` | click `[ Sprint ▾ ]` | `┌ switch sprint ┐`: `— Board default (active sprint) —`, then the active, future and last five closed sprints tagged `[active]` / `[future]` / `[closed]`, the current one pre-selected. Hidden on kanban boards. |
| `rust-boards-version-picker` | click `[ Version ▾ ]`, or `V` | The tab-view fixVersion picker; the chip then reads `Version: 13.20.0 ▾`. |
| `rust-boards-epic-picker` / `-toggled` | click `[ Epic ▾ ]` | `┌ filter by epic (Space toggles) ┐`: multi-select over the distinct parent epics (`KEY  summary`) of the tab's issues; a client-side filter; the chip reads `Epic: KEY ▾` / `Epic: N selected ▾`. Toasts `Epic filter: no epics found on current issues` when there are none. |
| `rust-boards-type-picker`, `-label-picker` | click `[ Type ▾ ]`, `[ Label ▾ ]` | `— Clear type —` / `— Clear label —` then the values seen; client-side filters; the chips read `Type: Bug ▾`, `Label: x ▾`. |
| `rust-boards-quickfilter-picker` / `-toggled` | click `[ ⚡ Quick filters ▾ ]` | `┌ toggle quick filters (Space) ┐`: the board's saved quick filters, multi-select; committing ANDs each one's JQL into the fetch; the chip reads `⚡ Quick filters (2) ▾`. `quick filters: this board defines none` when empty. |
| `rust-boards-unassigned-toggle`, `-avatar-toggled` | click ` [?] `, click an avatar | Toggles that account in the assignee filter (client-side); the chip fills. |
| `rust-boards-avatar-overflow-picker` | click ` +N ` | The assignee multi-select picker (as on Work's Assignee chip). |
| `rust-boards-*-200x60` | `--only boards` at 200 columns | The toolbar whole: `[ Version ▾ ] [ Epic ▾ ] [ Type ▾ ] [ Label ▾ ] [ ⚡ Quick filters ▾ ] [ ⚙ Settings ]` after the avatar cluster (at 120 columns everything after `[ Version ▾ ]` is clipped off the row and unreachable by mouse), and the Type / Label / Quick-filter pickers opened from those chips. |
| (not captured) card click → modal, ` × ` click, `▶` click, `/` filter, the JQL editor, bulk selection, the wheel, `End`, the Backlog tab | click a card, click ` × `, click a card's `▶`, `/`, `E`, `Space`, wheel, `G`, `2` | From `ui.rs` / `keys.rs`: a card click opens the modal and ` × ` closes it; the `▶` is a one-cell target that wins over the card body; on the kanban the `/` filter **does** narrow the cards, the wheel scrolls the column under the pointer (three rows), `j` / `k` move the cursor through the issue list in rank order; the Backlog tab is `sprint is EMPTY AND status != Done` for the project — up to the 500-issue cap, each unresolved ticket auto-expanded with a linked-PR fetch. Two runs were cut for these (`steps-boards-c.txt`, `steps-boards-d.txt`): the first never finished its cold load, the second died at the ` +N ` overflow chip, which the author's board never shows (five assignees fit), and the `Esc` after the miss quit the app (note 4). |

`[ ⚙ Settings ]` opens the board's configuration page in the browser
(`…/jira/software/c/projects/ENG/boards/200?config=filter`); `o` and
`Enter` on a flat row open the ticket, Enter on a PR row opens the PR.
Neither was clicked.

### The dispatch queue

`.` + Enter, `I` / `X` / `T` on a Fix Versions ticket, `V` on a PR row,
or a kanban card's `[ Implement ]`-style button (they paint; the click
routing for them was never added) write one JSON line —
`{kind, issue_key, issue_type, summary, jira_url, pr_url?, queued_at}` —
to `<dispatch_workspace>/.claude/queue.jsonl` **and** ask the running
mnml to open a terminal pane: `{"cmd":"term","args":["sh","-c","claude
<<'MNML_EOF'\n/agents:developer KEY\n\n<!-- context -->\nkind: …\nticket:
KEY (Type) — summary\nurl: …\nMNML_EOF"]}` appended to
`<dispatch_workspace>/.mnml/ipc/command` (each channel only when its
directory exists; the status line reports `implement → queue + pane`, or
which failed, or `nothing to dispatch to …`, naming both channels it
looked for). The slash command is
`/agents:developer` for implement / fix / triage, `/agents:reviewer
<pr_url or key>` for review, `/agents:tester KEY mode=ticket` for test.
Not captured live — it writes into the author's agent workspace.

### The statusline segment, the badge and what mnml paints

| file | what it shows |
|---|---|
| `rust-statusline-120x40` | The Rust mnml's statusline with the author's manifests (headless twin of the running instance, same binary and data root): the Jira segment is ` 󰌃 28 ` on the right side — U+F0303 (nf-md-jira) in `#1B5DCF` followed by `{assigned_open}` from `mnml-tracker-jira --values` (`{"assigned_open":28}`, the Assigned tab's JQL, scoped to `projects` when set), polled every 300 s by mnml's `values_sources` worker (a hard floor of 30 s, ceiling 3600 s); `?` for a missing key; the chip dims with `…` while the first poll is out and `!` when the command fails. Clicking it runs `jira_work.open`. The tracker never writes `statusline-set-segment` / `set-activity-badge` lines itself — the running mnml's `command` file is empty — and declares no activity badge: the segment is entirely the manifest's `[[values_sources]]` + `[[statusline_segments]]` rendered by mnml core. |
| `rust-mnml-integrations-120x40` | The INTEGRATIONS section (Installed tab, filter `jira`): three rows — `󰌃 Jira Boards  0.2.22` / `jira_boards.open`, `󰌃 Jira Fix Versions  0…` / `jira_fix_versions.open`, `󰌃 Jira Work  0.2.22` / `jira_work.open` — and the rail's three pinned `󰌃` icons (`in_palette_bar = false`, so no palette-bar chips). |
| `rust-mnml-jira-work-pane-120x40` | `jira_work.open` from inside mnml: a terminal pane titled `󰌃 Jira Work 󰅖` on the bufferline hosting the Work screen, the section's info box `Jira Work ⋮ / Terminal pane — Ctrl+Alt+H to detach, Ctrl+Alt+K to kill.`, the statusline reading `VIEW` with the segment. |

### The CLI

| file | what it shows |
|---|---|
| `rust-cli-help.txt` | `--config`, `--check`, `--install` / `--uninstall`, `--diag`, `--only`, `--values`, `--prefetch`. |
| `rust-cli-check.txt` | `--check`: the config path, site, email, refresh, the tabs with their resolve (`CurrentRelease project=ENG` / `jql = `), the token path and whether it is present. No network. |
| `rust-cli-diag.txt` | `--diag`: a tree — Auth (token source, length, email, site, a live `/myself` probe), Config (path, site, projects allowlist, the tabs with their kinds), Runtime (version, os/arch). |
| `rust-cli-values.txt` | `--values`: `{"assigned_open":28}`. |
| `rust-cli-prefetch-shape.txt` | `--prefetch --only <family>`: `{"generated_at": secs, "tabs": [{"name", "jql", "issues": [Issue…]}]}` on stdout for mnml's prefetch worker (`[[prefetch]]` in the manifests, every 600 s; the pane hydrates from `$MNML_PREFETCH_CACHE_FILE` and skips its cold fetch). It has a 10 s ceiling of its own, and on this site it **timed out** — as the author's cache shows: `jira_boards` and `jira_fix_versions` caches hold zero issues since 2026-08-28. |

## Keys, complete

From `keys.rs`; the greedy modals win in this order: detail modal,
comment editor, field picker, transition picker, filter, JQL editor.

| context | key | action |
|---|---|---|
| list | `q`, `Ctrl+C` | quit |
| list | `Esc` | the cascade: clear the selection → clear the filter → close the detail pane → **quit** |
| list | `r` | refresh the tab (and the focused detail) |
| list | `↑` `k` / `↓` `j`, PageUp / PageDown (10), `g` Home / `G` End | move |
| list | `Ctrl+U` / `Ctrl+D` | scroll the detail pane by 4 |
| tree tab | `Enter`, `Space` | activate the row: fold a group, expand a ticket (fetches its PRs), open a PR's URL, uncap a show-all row |
| tree tab | `→` `l` / `←` `h` | expand / collapse (a PR row expands to its pipelines; on a child row `←` folds the parent) |
| flat tab | `Enter`, `o` | open the ticket in the browser |
| flat tab | `Space` | toggle the bulk selection |
| any | `Tab` / `Shift+Tab`, `1`–`9` | switch tab |
| any | `/` | the filter |
| any | `t` | transition picker |
| any | `E` | JQL editor |
| any | `w` | watch / unwatch (needs `/myself`) |
| detail open | `c` | comment editor |
| any | `a` | assignee picker (bulk-aware) |
| Work, Boards | `f` | fixVersion picker for the ticket (bulk-aware) |
| Fix Versions | `f` / `F` | tab-view fixVersion picker / the per-ticket one |
| Fix Versions | `I` `X` `T` `V` | dispatch implement / fix / triage / review (`V` on a PR row) |
| Boards, Work | `T` | team picker |
| Boards, Work | `V` | tab-view fixVersion picker |
| any | `.` | action picker |
| any | `d` / `D` | detail pane / detail modal |
| Boards | `>` | expand the focused card |
| modal | `Esc` `q` close, `j` `k` (2), PageUp / PageDown (10) | |
| comment | printable, `Enter` newline, Backspace, `Ctrl+S` send, `Esc` cancel | |
| picker | type, Backspace, `↑` `↓`, `Enter`, `Esc`, `Space` toggles in a multi-select | |
| transition | `1`–`9`, `↑` `k` / `↓` `j`, `Enter`, `Esc` | |
| JQL editor | see above | |

Mouse: left click on a toolbar chip fires it; on a tree row selects and
activates; on a kanban card opens the modal, on its `▶` expands, on an
avatar / `[?]` toggles; on a picker row commits, outside the picker
cancels; on the modal's `×` closes; in the JQL editor places the caret.
Wheel: three rows on a list, a column on the kanban, the modal's text.

## What the reference gets wrong (and the port does not copy)

Observed while cutting the screens; each is something the user named
as awful or that the dumps show plainly.

1. **The `/` filter is inert on the tree tabs.** `draw_tree_table` never
   paints the filter strip and `tree_rows` never reads
   `visible_indices`, so on Work and Fix Versions typing is invisible
   and nothing is filtered — only the Search chip's label and the
   ` · N tickets` count change. The same goes for the Assignee chip's
   client-side filter: `Assignee: Me ▾` reads active on Current Release
   while every assignee's ticket is on screen. (The kanban honours both.)
2. **The toolbar vanishes on an empty scope.** `rows.is_empty()`
   returns before the toolbar paints, so `Status: Resolved` on Assigned
   leaves `(no issues)` and no chip to click back.
3. **The chips clip.** At 120 columns the Fix Versions pill and the
   ticket count are dropped whole; the resolved version is then nowhere
   on the screen.
4. **`Esc` quits.** The fourth `Esc` of the cascade ends the app; every
   run of the capture that pressed one Esc too many died here.
5. **Nothing names the active tab** under `--only`.
6. **The first frame waits on the whole fetch.** Every unresolved
   ticket's linked PRs are fetched serially before the first paint
   (and again on every 60 s auto-refresh, with the UI frozen): Work takes
   ~1½ min on this site, Current Release ~5, the Apollo sprint over 10 —
   and `--prefetch`, meant to hide exactly this, gives up after 10 s.
7. **`Space` on a tree tab activates the row** instead of toggling the
   selection the hint strip promises (`Space pick`); the selection only
   takes on flat tabs.
8. **The hint strip is hand-written per mode**, six literal strings
   that already disagree with the bindings (`Space pick` above; `T team`
   is not mentioned for Work where it works; `E`, `D`, `>`, `V`, `.` on
   Fix Versions are absent).
9. **Kanban action buttons paint but do not click**; `Space ▾`, `More
   filters ▾`, `Save filter` are painted placeholders.
10. **Click targets are rows, not the things on them**: a tree row's
    click toggles the whole ticket (there is no chevron target), the
    `[ Review ] [ Merge ] [ Open ]` chips on PR rows are text, and the
    show-all row is registered at a fixed offset that drifts once a
    filter or the detail pane changes the table's origin.
