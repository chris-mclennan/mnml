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
▌ basic   jql   󰍉 / filter   assignee: All   type: —   status: All
▌ KEY               STATUS        ASSIGNEE            UPDATED     SUMMARY
▌ In PR Review (1)
▌    ENG-2         In PR Review  Ada Lovelace        2026-09-15  Card form validates on blur                [ Review ]
▌        MERGED                                                  Validate the card form on blur               [ Open ]
▌         OPEN                                                   Follow-up: trim the whitespace  [ Open ] [ Review ] [ Merge ]
▌ In Progress (1)
▌     ENG-1         In Progress   Ada Lovelace        2026-09-15  Checkout rewrite
▌ To Do (1)
▌     ENG-5         To Do         Ada Lovelace        2026-09-15  Basket total wrong with a voucher  [ Triage ] [ Fix ]
 ENG-5: 0 linked PR(s)  t transition · a assignee · S select · f fix version · d detail · . actions · / filter · r refresh · ? keys
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
| — | `.poll_max_secs = 120` | no TOML twin: the adaptive poller's cap — the interval doubles from `refresh_interval_secs` while nothing changes (see Polling below) |
| — | `.feed = .{ .file = "", .stale_secs = 300, .sweep_secs = 600 }` | no TOML twin: an event file that names changed tickets; empty is off |
| — | `.budget = .{ .shared_bucket = "" }` | no TOML twin: a machine-wide token bucket file; empty is none |
| `release_cut = false` | `.release_cut = false` | turns the tabs' `bumps.release_cut` rules on |
| `team_field_id = "customfield_10056"` | `.team_field_id = "…"` | the team select's id, read on every issue |
| `team_field_name = "Team"` | `.team_field_name = "…"` | the JQL name of that field |
| `dispatch_workspace = "/path"` | `.dispatch_workspace = "/path"` | where `queue.jsonl` and the `term` line go |
| `projects = ["ENG"]` | `.projects = .{ "ENG" }` | scopes `--values` (both counts); the pane's tabs are not narrowed |
| `[detail_modal] fields = [...]` | `.detail_modal = .{ .fields = .{ .{ .id = "type" }, .{ .id = "customfield_1", .label = "Severity" } } }` | a bare TOML string becomes `.{ .id = … }` |
| `[detail_modal.field_alias] Severity = "customfield_1"` | `.detail_modal = .{ .field_alias = .{ .{ .name = "Severity", .id = "customfield_1" } } }` | |
| `[[tabs]] name` | `.tabs = .{ .{ .name = "…", … } }` | |
| `kind = "work_assigned"` | `.kind = .work_assigned` | `work_open` · `work_reported` · `work_assigned` · `work_recently_done` · `work_recent` · `work_unified` · `jql_editable` · `filter` · `fix_version_tree` · `board_active_sprint` · `board_backlog` |
| — | `.vars = .{ .{ .name = "project", .value = "ENG" }, .{ .name = "versions", .values = .{ "1.2.0" } } }` | a `jql_editable` tab's `{name}` holes. ZON has no string-keyed map, so this is a list of small structs — the shape `bumps.release_cut` and `field_alias` already use. `J` on the tab edits these and writes them back here |
| `mode = "current_release"` | `.mode = .current_release` | or `.next_release`; needs `.project` |
| `jql = "…"` | `.jql = "…"` | a custom query |
| `project`, `component` | `.project`, `.component` | |
| `columns = ["key", …]` | `.columns = .{ .key, .status, .assignee, .updated, .summary }` | `key` · `status` · `assignee` · `reporter` · `priority` · `type` · `updated` · `fix_version` · `actions` · `summary` |
| `status_order = [...]` | `.status_order = .{ "Testing", … }` | default: Testing, In PR Review, Code Review, In Progress, To Do, Open, Done |
| `[tabs.bumps] pr_approved = "Testing"` | `.bumps = .{ .pr_approved = "Testing" }` | |
| `[tabs.bumps] no_open_prs = "Testing"` | `.bumps = .{ .no_open_prs = "Testing" }` | |
| `reported_window_days = 14` | `.reported_window_days = 14` | `work_reported` only: how far back the tab looks when it opens. `0` opens it on everything you ever filed |
| `[tabs.bumps.release_cut] Done = "top"` | `.bumps = .{ .release_cut = .{ .{ .status = "Done", .target = "top" } } }` | `top` is the group above every other |
| `version_name_contains`, `team`, `issue_type`, `label` | the same names | |
| `board_id = 200` | `.board_id = 200` | the Agile board a kanban tab reads |
| `filter_id = 10` | `.filter_id = 10` | a saved filter for `.kind = .filter` |
| — | `.token_file = "~/…"` | port only: a file holding the token |
| — | `.token_env = "JIRA_API_TOKEN"` | port only: the variable (empty, the default, means `JIRA_API_TOKEN`) |
| — | `.api = .v3` | port only: `.v2` for a site that answers `410` |
| — | `.rate = .{ .per_sec = 0.33, .burst = 60, .cooldown_secs = 45, .max_block_secs = 120 }` | port only: the shared bucket's numbers (the reference's). The bucket is one file — `$JIRA_RATELIMIT_STATE` when it is set; else `jira-ratelimit.json` under `$MNML_SHARED_STATE_DIR`; else `<MNML_DATA_ROOT>/ratelimit/jira.json` (`~/.config/mnml/ratelimit/jira.json` with no data root) — and the rate broker's socket is `jira-broker.sock` beside it (`$JIRA_BROKER_SOCKET` names it outright; a derived path too long for a Unix socket becomes `/tmp/mnml-broker-jira-<12 hex>.sock`; `sdk/mnml-sdk/src/ratelimit.zig` `statePath`, `broker.zig` `socketPath`) — so every pane, the statusline poller and any other tool on the machine that agrees to the file format take turns on one allowance and one 429 parks them all — for the `Retry-After` the site sent, or a backoff from `cooldown_secs` doubling to `max_block_secs` when it sent none (the SDK's `budget`, the Bitbucket pane's too: a read asks again after a pause of up to 30 s, a write never) |
| — | `.dry_run = false` | no TOML twin: start in a dry run — nothing is sent, the rows on screen stay, and the request log gets the line it would have been (`"dry":true`). `Shift+N` flips it for the session; the budget chip says `DRY` |
| — | `.intervals = .{ .listing_secs = 300, .builds_secs = 90, .readiness_secs = 0 }` | port only: how often each kind of thing is kept fresh (`sdk.warm.Intervals`, the defaults shown); `readiness_secs = 0` is on demand only |
| — | `.bitbucket_api_url`, `.bitbucket_token_env` | port only: the forge for post-merge pipelines (`https://api.bitbucket.org/2.0`, `BITBUCKET_ACCESS_TOKEN`) |
| — | `.required_approvals = 1` | port only: approvals a linked pull request needs before its `[ Merge ]` stops being dim |
| — | `.open_command = "open"` | port only: the browser command; empty (the default) picks the platform's — `open`, `xdg-open`, or `rundll32 url.dll,FileProtocolHandler` on Windows |

The token is never in the config. It comes, in order, from
`.token_file`, `$JIRA_API_TOKEN` (or `.token_env`),
`<data root>/integrations/jira/token`, and last the reference tracker's
own file `~/.config/mnml-tracker-jira/token` — so a token already on
the box works without copying it.

One key can be overridden from the environment: `$JIRA_BASE_URL` wins
over `.jira_url`, either literally or as `@<path>` naming a file that
holds the URL. It is there for the test double — `mnml-fake-jira
--port 0 --url-file jira.url` writes the port it was actually given, so
a script never picks a number and two runs never collide. Bitbucket's
`$BITBUCKET_BASE_URL` is the same shape, and wins over
`.bitbucket_api_url` (where a ticket's linked pull requests are asked
about). An `@<path>` whose file is still missing after 5 s is the
setup screen ("The base URL override points nowhere.") and `--check`
exits 1 naming it: the fake did not start, and no server — not the
config's site — is asked instead.

## The screens

**Jira Work / Jira Fix Versions — the tree.** The caps header with the
count (`JIRA WORK (3)`, `(1 of 3)` under a filter), the tab strip with
the marker on the active tab, the toolbar as mode chips (`basic`,
`jql`, the search pill, `assignee: All` (a board tab opens on `Me`), `type: —`,
`status: All`, and on a release tab `fixVersion: 2.4.0` with its `ⓧ`)
that wrap to a second row instead of clipping, the column header, then
one group per status in the tab's `status_order`, each ticket under it
with its columns, unresolved tickets auto-expanded with their linked PRs
(`MERGED` / `OPEN` / `DECLINED`, the title, `[ Open ] [ Review ] [ Merge ]`
on an open one, `[ Open ]` on the rest), a merged PR expandable to its
post-merge pipelines, three PRs per ticket then a `⋯  Show more (N)`
row. A ticket a bump rule promoted carries `★` after its key and sits in
the target group; its STATUS cell reads that group too. The last
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
with the pane open): `Enter` is a newline, and `Enter` on an empty last
line sends — as does `Ctrl+S`, which a mounted pane cannot count on
seeing, since it is the host's save chord. **The detail modal** (`D`, or a
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
**JQL editor** (`J`) is a box at the bottom with the tab's resolved
query, every text-field affordance (arrows, Home/End, `Ctrl+A/E`,
`Alt+←/→`, `Ctrl+W/U/K`, paste, a click places the caret), `Enter`
runs it. The **key sheet** (`?`) is the family's one component
(`sdk.pane.chrome.Painter.keySheet`, the Bitbucket pane's too) —
`▾ ── name ── (n)` headers, the chords in the accent, a long label
wrapped, `Esc` closes — from the bindings that apply, so it cannot
drift.

**Setup screens.** No config, a config that does not parse, one that
cannot work, a scope with no tabs, no token: each names the file and
the next step and waits for `r`.

## Keys

| context | key | action |
|---|---|---|
| any | `q`, `Ctrl+C` | quit |
| any | `Esc` | clear the selection → clear the filter → close the detail pane → quit |
| any | `r` | refresh (the cursor stays on its ticket) — after the first whole listing, a window onto what moved since, plus one search for which rows on screen moved OUT of the query (closed, reassigned away), which are dropped |
| any | `R` | full refresh: the whole listing again |
| any | `↑` `k` / `↓` `j`, PageUp / PageDown, `g` / `G`, Home / End | move |
| detail open | `Ctrl+U` / `Ctrl+D` | scroll the detail pane |
| tree | `Enter`, `Space` | fold a group · expand a ticket · open a PR · uncap a show-all row |
| tree | `→` `l` / `←` `h` | expand / collapse (every PR row expands to its builds) |
| tree | `E` / `C` | expand / collapse every group — the integration tree convention, the same pair the Bitbucket pane binds |
| tree | `S` | select for a bulk action |
| kanban | `Space` | select for a bulk action |
| kanban | `>` | expand the card |
| any | `o` | open in the browser |
| any | `Tab` / `Shift+Tab`, `1`–`9` | switch tab |
| any | `t` · `a` · `w` · `.` | transition · assignee · watch / unwatch · actions |
| Work, Boards | `f` · `V` · `T` | fix version on the ticket · tab-view fix version · team |
| Fix Versions | `f` · `F` | switch the release · fix version on the ticket |
| Fix Versions | `I` `X` `T` `V` `M` | dispatch implement / fix / triage / review · merge the PR through Claude Code (`V` / `M` on a PR row) |
| detail open | `c` | comment |
| any | `d` / `D` | detail pane / detail modal |
| any | `/` · `J` · `?` | filter · JQL editor (the vars editor on a `jql_editable` tab) · keys |
| any | `Ctrl+X` · `N` | stop waiting out a rate-limit pause · dry run on / off |

The header's **budget chip**, beside refresh, is the Bitbucket pane's
same chip (`sdk.pane.chrome.budgetChip`): `812/1000` off Jira Cloud's
`X-RateLimit-Remaining` / `-Limit`, `37/h` (calls this hour) when the
site sends none, `DRY`, or `paused until 14:03:22` after a 429 — in the
host usage meter's colours (yellow from 60 % spent or on
`X-RateLimit-NearLimit`, red from 85 % and while paused). Its hover adds
the reset time, the hit ratio (a ticket whose linked PRs the store
already holds, against a read that carried a body) and calls today ·
yesterday · last 7 days, from `<data root>/budget/jira.tally`, which
every process on the data root adds to. A click on it stops a pause;
so do `Ctrl+X` and the host's `integrations.cancel_wait`.

### Polling, the event feed and the shared bucket

**The poller backs off while nothing changes.** `refresh_interval_secs`
is the base; every auto-refresh that comes back the same as the last
one (a window that found nothing moved, or the same tickets at the same `updated` stamps) doubles the interval, up to `poll_max_secs` (120; at or
below the base the interval stays fixed): `5 s → 10 → 20 → 40 → 80 →
120`. A change, a key, a click, the wheel, a paste, the pane taking
focus, or `r` puts it straight back to the base. The budget chip adds
the interval in force (`37/h · 40s`); its hover says the base, the cap
and how many quiet polls in a row got it there.

**An event feed**, when something on the machine knows what changed:

```zig
.feed = .{ .file = "~/feeds/jira.jsonl", .stale_secs = 300, .sweep_secs = 600 },
```

Anything may append one JSON line per change —
`{"kind":"issue","key":"ENG-12","at":1790000000,"source":"relay"}` — and the pane fetches only those tickets (one search, `key in (…)` inside the tab's own query, so a ticket that has left the query drops off the tab), once however many lines
name it, through the same budget as everything else. While the file is
live the chip says `· feed` and the listing is only swept every
`sweep_secs`, in case a line was lost. If the file goes missing, or has
had no line (an event or a `{"kind":"heartbeat",…}`) for `stale_secs`,
the pane goes back to adaptive polling and the hover says why. A
relative path is taken against this config's directory. The format is
a public contract: `docs/SDK.md` → "The event line".

**A shared bucket file**, when several tools on the machine must share
one allowance:

```zig
.budget = .{ .shared_bucket = "~/buckets/jira.json" },
```

Every request takes one token from it under an exclusive file lock; an
empty bucket skips the round (nothing is sent, the hint line says
`waiting on the shared rate-limit bucket`) and a 429 is written into it
as a cooldown every other reader honours. A missing or unparsable file
is no bucket — it can slow the pane, never take its API away. The
chip's hover shows its tokens and any cooldown. The format:
`docs/SDK.md` → "The shared bucket file".

Every row, chip, tab, picker entry and button is a click target sized
to what it paints (`src/hit.zig`); a right click on a ticket row
toggles its selection.

### The three Work tabs the scaffold ships

`--write-config` writes seven tabs: four Work tabs — the three below,
because these are the three questions a working day asks, plus **Recently
Done** — a Fix Versions tab (**Current Release**) and two board tabs
(**Sprint**, **Backlog**):

| tab | kind | what it answers |
| --- | --- | --- |
| **My open work items** | `work_open` | what is on my plate — the count the `󰌃` chip carries |
| **Reported by me** | `work_reported` | what I filed, newest first, for the last two weeks (`reporter = currentUser() AND created >= -14d ORDER BY created DESC`) — Jira's own filter, windowed |
| **QA Actionable now** | `jql_editable` | your own JQL, with the parts that change per release pulled out into `.vars` |

**Reported by me** is Jira's own filter — newest *filed* first, every
resolution — with a created-date window on the front, because without
one it is every ticket the account ever filed and the tab takes its
time. It opens on two weeks (`reported_window_days`, `0` for none) and
carries a trailing row below the last group:

```
⋯  Show older (2 weeks → 30 days)
```

`Enter` or a click widens one step — 14 days → 30 → 90 → all time — and the
row's words move on to name the next step. Each press is one ordinary
refetch at the wider window, through the same broker and the same token
bucket as `r`: no count query, and nothing extra to be rate-limited for.
At all time there is nowhere left to go and the row is gone. The window
is the session's, not the file's: a restart opens the tab back on
`reported_window_days`.

An editable tab wears its vars as header chips (`project: ENG`,
`versions: 1.2.0 +1`). **`J`**, or a click on any of them, opens a small
editor: `↑↓` move, `Enter` types into the focused value, `a` adds one, `d`
removes one, `s` (or `Ctrl+S`) saves, `Esc` cancels. `s` as well as
`Ctrl+S` because `Ctrl+S` is the host's own save chord and a mounted
pane cannot count on seeing it. A save splices each var back into
`config.zon` one span at a time, so every comment and every key the edit
did not name is left exactly where it was — and the tab re-runs its
query without a reload. The JQL itself is not editable here on purpose:
a release list changes every few weeks, the query around it almost
never.

## The statusline

The Work chip's manifest declares **one** segment, `jira_work.assigned`,
with up to two numbers on it:

```
󰌃 10 ·  14
```

- **`󰌃 10`** — open work items assigned to you: the count of the
  `work_open` (or `work_assigned`) tab.
- **` 14`** (a clipboard, `QA` with `--ascii`) — the tab you have set
  up as **QA Actionable Now**: the first `.kind = .jql_editable` tab,
  whatever it is called. A config written before that kind existed still
  works: failing a kinded tab, one is found by name ("QA Actionable
  Now", "qa_actionable", "QA actionable" all count). Its own `jql` —
  holes filled from `.vars` — is what runs. With no such tab, or none in
  it, the part is left off.

The hover says each number in words, one line apiece, with its
breakdown by status —

```
10 work items assigned to you — 6 In Progress · 4 To Do
14 in your QA Actionable Now tab — 14 Ready for QA
```

— then the shared rate-limit bucket's line, and lists the tickets:
the assigned ones, then the QA tab's not already among them. A press on
a row opens the pane with the cursor on that ticket; a click on the
chip opens the pane. The statusline's *Segments ▸* menu lists it as
*Jira Work: assigned, QA actionable*, and its own right-click menu has
*Hide*.

The pane republishes the chip over mnml's Tier-2 IPC after every
refresh — once its QA tab has loaded, so an open pane never drops the
QA count a poll put there. `mnml-jira --values --workspace <ws>`
publishes it from outside the pane and prints
`{"assigned_open":N,"qa_actionable":K}` for a poller; mnml's own poller
runs exactly that line on the manifest's interval, so the chip moves
with no pane open.

Until 0.2.4 the QA count was a second chip, `jira_work.qa_actionable`.
Installing 0.2.4 takes it off the row; its name left in
`statusline.hidden` shows in *Segments ▸* by its raw id and can be
unticked from there.

## Builds under a pull request

Every PR row under a ticket folds out (its chevron, `l`, or the row's
`[ Open ]` chip) to the pipeline runs on the commit it is about — a
merged one to the runs on its merge commit, an open one to the runs on
its **source head**, which are the builds a reviewer wants before
merging. One row per run, in the toolkit's line so it reads the same as
the Bitbucket pane's:

```
▾ #2044  OPEN   Follow-up: trim the whitespace                  [ Open ] [ Review ] [ Merge ]
        ⏵ IN_PROGRESS · feat/trim · 1h · #414
        ✗ FAILED · feat/trim · 5h · #413
```

`Enter` on a build row opens that run's page; `Enter` on the PR row
still opens the pull request itself. It costs one Bitbucket request per
pull request when nothing has changed — the PR detail carries
`updated_on`, and the pipelines list is skipped whenever it has not
moved.

## Merging a PR — and why the button is usually dim

`[ Merge ]` on a PR row is **dim and not a click target** until the
pull request can actually merge. Five conditions, in the order a reader
thinks about them: the required approvals (`required_approvals`,
default 1) with nobody asking for changes, every task resolved, no
conflicts, the newest run on the **source** commit green, and every
comment resolved or replied to. Hovering a dim one — or clicking it —
says which condition fails and its number, `Merge: 1 of 2 approvals`.
A pull request nobody has looked at says `not checked yet` rather than
inventing a blocker.

The look costs one cached round per pull request against its own
`updated_on`, taken when the button is pressed or the row is hovered,
and reuses the row's builds for the pipeline half when they are already
folded out.

A ready button opens a confirm that **names** the pull request, its
branches and the strategy (`←→` cycles). Confirming writes the same
kind of `term` line every other action here writes: a **Claude Code
session** that merges through the Bitbucket API with
`$BITBUCKET_ACCESS_TOKEN` and reports the outcome on its last line.
This pane never calls the merge API itself. The button then follows
that session — spinner, `⏸`, `[ view ]`, red `✗` — and a merge that
ends while the pane does not have the keyboard sends a notification.

## The dispatch queue

`.` + Enter, `I` / `X` / `T` / `V` on a Fix Versions tab, or a card's
action button write one JSON line — `{kind, issue_key, issue_type,
summary, jira_url, pr_url?, queued_at}` — to
`<dispatch_workspace>/.claude/queue.jsonl` and one `term` line
(`claude <<'MNML_EOF' /agents:developer KEY … MNML_EOF`) to
`$MNML_IPC_DIR/command` (else `<dispatch_workspace>/.mnml/ipc-zig/command`), each channel only when its
directory exists; the status says which fired.

The button then **follows the session it started**. mnml tells the pane
what that session is doing (`watch_session` / `session_state`, see
`docs/BRIDGE.md`), so `[ Triage ]` turns a spinner while it runs, shows
`⏸` in the warning colour when it stops to ask you something — with the
question on the hint row — becomes `[ view ]` when it ends, and wears a
red `✗` with the reason when it fails. Pressing it again brings that
session to the front rather than starting a second one.

## Tests

```sh
(cd integrations/jira && zig build test)       # the unit suite: every module, the fake server
# the next two from the repo root
zig build && ./zig-out/bin/mnml-zig test tests/e2e/integrations_jira_*.test   # the corpus scripts
tools/jira-diff.sh [work|fix-versions|boards]  # the reference vs the port, by content
```

`tools/fake_jira/` is a deterministic Jira on the loopback (project
ENG, twelve issues, a scrum board with sprints and quick filters,
versions, users, the dev-status panel, a forge corner for pipelines);
every test runs against it, no network. `--rate-limit-first N`
(`--retry-after N`) answers the next N Jira requests 429;
`--rate-limit-limit N` / `--rate-limit-remaining N` /
`--rate-limit-reset ISO` send Jira Cloud's `X-RateLimit-*` on every Jira
answer — what the budget chip's tests drive. It takes `--port 0` and writes
where it landed — the bare number to `--port-file`, the whole
`http://127.0.0.1:NNNNN` to `--url-file` — which is what the corpus
reads back through `JIRA_BASE_URL=@<path>`. `mnml-jira --dump --steps FILE`
plays a step script at the pane with no mnml and prints every `snap`.
