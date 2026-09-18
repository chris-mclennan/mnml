# mnml-jira — Jira Work, Jira Fix Versions and Jira Boards

An official mnml integration, on `mnml-sdk`: the reference tracker's
three chips over one binary, each a family of tabs — the status-grouped
ticket tree with linked pull requests and their post-merge pipelines
(Work, Fix Versions) and the sprint kanban (Boards) — with the detail
pane, the detail modal, the pickers, bulk actions, the filter, the JQL
editor, watching, the dispatch queue, auto-refresh and a statusline
count. The spec is `docs/ui-spec/jira/README.md`: every screen of the
reference, captured from the running tracker, and the inventory the
port was built against.

```
▌JIRA WORK (3)                                                                                                      ?
▌1 Assigned   2 Recently Done
▌ basic   jql   󰍉 / filter   space: —   assignee: All   type: —   status: All
▌ KEY               STATUS        ASSIGNEE            UPDATED     SUMMARY
▌ In PR Review (1)
▌    ENG-2         In PR Review  Ada Lovelace        2026-09-15  Card form validates on blur                [ Review ]
▌        MERGED                                                  Validate the card form on blur               [ Open ]
▌         OPEN                                                   Follow-up: trim the whitespace  [ Open ] [ Review ] [ Merge ]
▌ In Progress (1)
▌     ENG-1         In Progress   Ada Lovelace        2026-09-15  Checkout rewrite
▌ To Do (1)
▌     ENG-5         To Do         Ada Lovelace        2026-09-15  Basket total wrong with a voucher  [ Triage ] [ Fix ]
 ENG-5: 0 linked PR(s)  t transition · a assignee · S select · f fix version · d detail · . actions · / filter · ? keys
```

Column 0 is the app-colour gutter the pane toolkit paints — Work blue,
Fix Versions green, Boards magenta, off each chip's manifest colour —
and the cursor's row lights it up. Every other colour on the screen is a
role out of the host theme's `hello.palette`, so the pane wears the
theme mnml is wearing.

## Install

From mnml: open the INTEGRATIONS section, find **Jira Work** on the
**Dev** tab, press `i`. That builds it if it needs building, runs
`mnml-jira --install` — which registers all three chips — links the
binary into `<data root>/bin/` and rescans.

By hand:

```sh
cd integrations/jira && zig build      # → zig-out/bin/mnml-jira, mnml-fake-jira
./zig-out/bin/mnml-jira --install      # writes jira_work.zon, jira_fix_versions.zon, jira_boards.zon
./zig-out/bin/mnml-jira --write-config # drops an example config.zon and prints its path
./zig-out/bin/mnml-jira --check        # the resolved config and where the token is, no network
./zig-out/bin/mnml-jira --diag         # the same plus a live /myself probe
```

The chips are `jira_work.open` (`space i j w`), `jira_fix_versions.open`
(`space i j v`) and `jira_boards.open` (`space i j b`); each opens the
pane with `--only <family>` and shows that family's tabs.

## The config

`config.zon`, looked for in this order: `--config PATH`,
`$MNML_JIRA_CONFIG`, `<workspace>/.mnml/integrations/jira/config.zon`,
`<data root>/integrations/jira/config.zon`. The keys are the reference
tracker's TOML keys, by name, in ZON; `--write-config` writes an
example.

| TOML (`~/.config/mnml-tracker-jira.toml`) | ZON (`config.zon`) | notes |
|---|---|---|
| `jira_url = "…"` | `.jira_url = "…"` | no trailing slash |
| `email = "…"` | `.email = "…"` | the account the token belongs to |
| `refresh_interval_secs = 60` | `.refresh_interval_secs = 60` | `0` turns the auto-refresh off |
| `release_cut = false` | `.release_cut = false` | turns the tabs' `bumps.release_cut` rules on |
| `team_field_id = "customfield_10056"` | `.team_field_id = "…"` | the team select's id, read on every issue |
| `team_field_name = "Team"` | `.team_field_name = "…"` | the JQL name of that field |
| `dispatch_workspace = "/path"` | `.dispatch_workspace = "/path"` | where `queue.jsonl` and the `term` line go |
| `projects = ["TE"]` | `.projects = .{ "TE" }` | scopes `--values` and the default JQLs |
| `[detail_modal] fields = [...]` | `.detail_modal = .{ .fields = .{ .{ .id = "type" }, .{ .id = "customfield_1", .label = "Severity" } } }` | a bare TOML string becomes `.{ .id = … }` |
| `[detail_modal.field_alias] Severity = "customfield_1"` | `.detail_modal = .{ .field_alias = .{ .{ .name = "Severity", .id = "customfield_1" } } }` | |
| `[[tabs]] name` | `.tabs = .{ .{ .name = "…", … } }` | |
| `kind = "work_assigned"` | `.kind = .work_assigned` | `work_assigned` · `work_recently_done` · `work_recent` · `work_unified` · `filter` · `fix_version_tree` · `board_active_sprint` · `board_backlog` |
| `mode = "current_release"` | `.mode = .current_release` | or `.next_release`; needs `.project` |
| `jql = "…"` | `.jql = "…"` | a custom query |
| `project`, `component` | `.project`, `.component` | |
| `columns = ["key", …]` | `.columns = .{ .key, .status, .assignee, .updated, .summary }` | `key` · `status` · `assignee` · `reporter` · `priority` · `type` · `updated` · `fix_version` · `actions` · `summary` |
| `status_order = [...]` | `.status_order = .{ "Testing", … }` | default: Testing, In PR Review, Code Review, In Progress, To Do, Open, Done |
| `[tabs.bumps] pr_approved = "Testing"` | `.bumps = .{ .pr_approved = "Testing" }` | |
| `[tabs.bumps] no_open_prs = "Testing"` | `.bumps = .{ .no_open_prs = "Testing" }` | |
| `[tabs.bumps.release_cut] Done = "top"` | `.bumps = .{ .release_cut = .{ .{ .status = "Done", .target = "top" } } }` | `top` is the group above every other |
| `version_name_contains`, `team`, `issue_type`, `label` | the same names | |
| `board_id = 200` | `.board_id = 200` | the Agile board a kanban tab reads |
| `filter_id = 10` | `.filter_id = 10` | a saved filter for `.kind = .filter` |
| — | `.token_file = "~/…"` | port only: a file holding the token |
| — | `.token_env = "JIRA_API_TOKEN"` | port only: the variable (this is the default) |
| — | `.api = .v3` | port only: `.v2` for a site that answers `410` |
| — | `.rate = .{ .per_sec = 0.33, .burst = 60, .cooldown_secs = 45, .max_block_secs = 120 }` | port only: the shared bucket's numbers (the reference's). The bucket is one file — `<root>/jira-ratelimit.json` — so every pane, the statusline poller and the Rust tracker take turns on one allowance and one 429 parks them all |
| — | `.bitbucket_api_url`, `.bitbucket_token_env` | port only: the forge for post-merge pipelines (`BITBUCKET_ACCESS_TOKEN`) |
| — | `.open_command = "open"` | port only: the browser command |

The token is never in the config. It comes, in order, from
`.token_file`, `$JIRA_API_TOKEN` (or `.token_env`),
`<data root>/integrations/jira/token`, and last the reference tracker's
own file `~/.config/mnml-tracker-jira/token` — so a token already on
the box works without copying it.

## The screens

**Jira Work / Jira Fix Versions — the tree.** The caps header with the
count (`JIRA WORK (3)`, `(1 of 3)` under a filter), the tab strip with
the marker on the active tab, the toolbar as mode chips (`basic`,
`jql`, the search pill, `space: TE`, `assignee: Me`, `type: —`,
`status: All`, and on a release tab `fixVersion: 13.16.0` with its `ⓧ`)
that wrap to a second row instead of clipping, the column header, then
one group per status in the tab's `status_order`, each ticket under it
with its columns, unresolved tickets auto-expanded with their linked PRs
(`MERGED` / `OPEN` / `DECLINED`, the title, `[ Open ] [ Review ] [ Merge ]`
on an open one, `[ Open ]` on the rest), a merged PR expandable to its
post-merge pipelines, three PRs per ticket then a `Show all N PRs ↴`
row. A ticket a bump rule promoted carries `★` after its key and sits in
the target group with its real status in the STATUS column. The last
row is the status text and a hint row generated from the bindings.

**Jira Boards — the kanban.** `board: <name>`, `sprint: <name>`, the
search pill, the avatar cluster (initials, lit when active, `[?]` for
the full list), `version`, `epic`, `type`, `label`, `quick filters`,
`unassigned`, `settings`; four bordered columns (To Do, In Progress,
Testing, Done) of cards — `▶ <type> KEY`, the summary wrapped,
`· assignee`, the action buttons; `>` expands a card to its `#label`
chips and the hint; a card click opens the modal, its `▶` expands it,
the wheel scrolls the column under the pointer.

**The detail pane** (`d`): the key and summary, the field table, the
watcher line, the description, the comments. **The comment box** (`c`
with the pane open): `Ctrl+S` sends. **The detail modal** (`D`, or a
card click): 80 % × 80 %, the field table (`detail_modal.fields`) left,
the description right, `×` closes.

**The pickers**: `t` transitions (`1. Name → Target`, `1-9` jump), `a`
assignee (`— Unassign —` then the assignable users), `f` fix version
(`— Clear fixVersion —` then the project's versions, unreleased first),
`.` actions (the ticket's dispatch buttons), `T` team, `V` / the
`version` chip the tab-view fix version, the `assignee` chip / `[?]`
the multi-select assignee filter, `epic`, `type`, `label`,
`quick filters`, `board`, `sprint`. Type to filter, `↑` `↓`, `Enter`,
`Esc`, `Space` toggles a multi-select row; a click on a row commits it,
outside cancels. A bulk selection (`S` on a tree tab, `Space` on the
kanban) carries into `t`, `a` and `f`: the transition matches by name
on every selected ticket and reports the ones skipped.

**The filter** (`/`) narrows the tree and the kanban as it is typed; the
**JQL editor** (`E`) is a box at the bottom with the tab's resolved
query, every text-field affordance (arrows, Home/End, `Ctrl+A/E`,
`Alt+←/→`, `Ctrl+W/U/K`, paste, a click places the caret), `Enter`
runs it. The **key sheet** (`?`) is the built-in sections' —
`▾ ── name ── (n)` headers, the chords in the accent — from the
bindings that apply, so it cannot drift.

**Setup screens.** No config, a config that does not parse, one that
cannot work, a scope with no tabs, no token: each names the file and
the next step and waits for `r`.

## Keys

| context | key | action |
|---|---|---|
| any | `q`, `Ctrl+C` | quit |
| any | `Esc` | clear the selection → clear the filter → close the detail pane → quit |
| any | `r` | refresh (the cursor stays on its ticket) |
| any | `↑` `k` / `↓` `j`, PageUp / PageDown, `g` / `G`, Home / End | move |
| detail open | `Ctrl+U` / `Ctrl+D` | scroll the detail pane |
| tree | `Enter`, `Space` | fold a group · expand a ticket · open a PR · uncap a show-all row |
| tree | `→` `l` / `←` `h` | expand / collapse (a merged PR row expands to its pipelines) |
| tree | `S` | select for a bulk action |
| kanban | `Space` | select for a bulk action |
| kanban | `>` | expand the card |
| any | `o` | open in the browser |
| any | `Tab` / `Shift+Tab`, `1`–`9` | switch tab |
| any | `t` · `a` · `w` · `.` | transition · assignee · watch / unwatch · actions |
| Work, Boards | `f` · `V` · `T` | fix version on the ticket · tab-view fix version · team |
| Fix Versions | `f` · `F` | switch the release · fix version on the ticket |
| Fix Versions | `I` `X` `T` `V` | dispatch implement / fix / triage / review (`V` on a PR row) |
| detail open | `c` | comment |
| any | `d` / `D` | detail pane / detail modal |
| any | `/` · `E` · `?` | filter · JQL editor · keys |

Every row, chip, tab, picker entry and button is a click target sized
to what it paints (`src/hit.zig`); a right click on a ticket row
toggles its selection.

## The statusline

The Work chip's manifest declares **two** segments, because they are
two numbers about two different things.

**`jira_work.assigned`** — `󰌃 N`: open items assigned to you, the
Assigned tab's count. A click runs `jira_work.open`.

**`jira_work.qa_actionable`** — ` K`: the tab you have set up as **QA
Actionable Now**. There is no tab *kind* for it yet (that is its own
track), so the tab is found by name — "QA Actionable Now",
"qa_actionable", "QA actionable" all count — and its own `jql` is what
runs. With no such tab the key is `null` and the chip is not published
at all, which is not the same as a zero.

Each chip's hover is its breakdown by status —
`Jira · 7 open items assigned to me — 3 In Progress · 2 In Review ·
2 To Do` — so a number that moved says what moved.

The pane publishes the first over mnml's Tier-2 IPC after every
refresh. `mnml-jira --values --workspace <ws>` publishes both from
outside the pane and prints `{"assigned_open":N,"qa_actionable":K}` for
a poller; mnml's own poller runs exactly that line on the manifest's
interval, so the chips move with no pane open.

## The dispatch queue

`.` + Enter, `I` / `X` / `T` / `V` on a Fix Versions tab, or a card's
action button write one JSON line — `{kind, issue_key, issue_type,
summary, jira_url, pr_url?, queued_at}` — to
`<dispatch_workspace>/.claude/queue.jsonl` and one `term` line
(`claude <<'MNML_EOF' /agents:developer KEY … MNML_EOF`) to
`<dispatch_workspace>/.mnml/ipc/command`, each channel only when its
directory exists; the status says which fired.

## Tests

```sh
cd integrations/jira && zig build test         # the unit suite: every module, the fake server
zig build && ./zig-out/bin/mnml-zig test tests/e2e/integrations_jira_*.test   # the corpus scripts
tools/jira-diff.sh [work|fix-versions|boards]  # the reference vs the port, by content
```

`tools/fake_jira/` is a deterministic Jira on the loopback (project
ENG, twelve issues, a scrum board with sprints and quick filters,
versions, users, the dev-status panel, a forge corner for pipelines);
every test runs against it, no network. `mnml-jira --dump --steps FILE`
plays a step script at the pane with no mnml and prints every `snap`.
