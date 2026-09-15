# mnml-jira — Jira tickets in a pane

An official mnml integration, on `mnml-sdk`. Configurable tabs (JQL, and
auto-resolved release `fixVersion`s), an epic → story → sub-task tree,
a detail pane with the description, the comments and the linked pull
requests, and the actions you need without leaving the editor.

```
JIRA  1 Mine 5  2 Release 12                                    r ⟳  ? help
 KEY            STATUS         ASSIGNEE             SUMMARY          │ ENG-2  Card form validates on blur
▼ ENG-1         In Progress    Ada Lovelace         Checkout rewrite │
  ▼ ENG-2       In Review      Ada Lovelace         Card form vali…  │       type  Story
      ENG-4     Done           Sam Beckett          Wire the blur h… │     status  In Review
      MERGED  checkout #2023  feat/blur → main (2✓)                  │   priority  Medium
    ENG-3       To Do          —                    Apple Pay button │   assignee  Ada Lovelace
  ENG-5         To Do          Ada Lovelace         Basket total wr… │   reporter  Sam Beckett
                                                                     │    version  13.16.0
                                                                     │       epic  ENG-1
                                                                     │
                                                                     │ ── description ──
                                                                     │ Validate the card number when the
                                                                     │ field loses focus.
                                                                     │
                                                                     │ ── pull requests ──
                                                                     │ MERGED  checkout #2023
Mine · 5 tickets                                              2 hidden · H
```

## Install

From mnml: open the INTEGRATIONS section (`ctrl+shift+x`), find **Jira**
on the **Dev** tab, press `i`. That builds it if it needs building, runs
`mnml-jira --install`, links the binary into `<data root>/bin/` and
rescans.

By hand:

```sh
cd integrations/jira && zig build      # → zig-out/bin/mnml-jira
./zig-out/bin/mnml-jira --install      # writes <data root>/integrations/jira.zon
./zig-out/bin/mnml-jira --write-config # writes an example config.zon
./zig-out/bin/mnml-jira --check        # what it read, no network
```

Then `jira.open` in mnml (`ctrl+k j`), or the chip on the palette bar.

## Where the config lives

First hit wins:

1. `--config PATH`
2. `$MNML_JIRA_CONFIG`
3. `<workspace>/.mnml/integrations/jira/config.zon` — per project
4. `<data root>/integrations/jira/config.zon` — usually
   `~/.config/mnml/integrations/jira/config.zon`

(4) is the **private-source** path: the config never has to live in this
repo, which matters because it names your site, your email and possibly
the file holding your token. `--write-config` writes to whichever of
those the lookup settles on.

A missing config is not an error — the pane paints the path to write and
the command that writes it.

## `config.zon`

ZON, not TOML: mnml reads ZON everywhere.

```zig
.{
    .jira = .{
        .url = "https://acme.atlassian.net",
        .email = "you@acme.com",
        .token_env = "JIRA_API_TOKEN",
        // .token_file = "~/.config/mnml/integrations/jira/token",
        .api = .v3,
        // .team_field_id = "customfield_10056",
        // .team_field_name = "Team",
        .projects = .{"ENG"},
        .rate = .{ .per_sec = 0.33, .burst = 60, .cooldown_secs = 45, .max_block_secs = 120 },
    },
    .mnml = .{
        .refresh_interval_secs = 60,
        .detail_width_pct = 40,
        .detail_open = true,
        .expand_indicator = .chevron,
        .max_comments = 10,
        .max_prs = 3,
        // .open_command = "firefox --new-tab",
    },
    .tabs = .{
        .{ .name = "Mine", .kind = .work_assigned },
        .{ .name = "Recent", .kind = .work_recent },
        .{
            .name = "Release",
            .kind = .fix_version,
            .project = "ENG",
            .mode = .current_release,
            .version_name_contains = "13.",
            .group_by = .status,
            .status_order = .{ "In Progress", "In Review", "Testing", "To Do", "Done" },
            .columns = .{ .key, .status, .assignee, .fix_version, .summary },
        },
        .{ .name = "Team board", .kind = .custom, .jql = "project = ENG AND sprint in openSprints() ORDER BY rank", .team = "Apollo" },
        .{ .name = "Saved", .kind = .filter, .filter_id = 10412 },
    },
}
```

### `.jira` — the site and how to reach it

| key | type | default | what it does |
|---|---|---|---|
| `url` | string | *(required)* | Your Atlassian site. A trailing `/` is stripped on load. |
| `email` | string | *(required)* | The Atlassian account email — the user-name half of HTTP Basic. |
| `api` | `.v3` \| `.v2` | `.v3` | `.v3` is Cloud: ADF bodies, `POST /rest/api/3/search/jql`. `.v2` is Server / Data Center: wiki-markup bodies, `GET /rest/api/2/search`. A Cloud site answers the old v3 `/search` with `410`; the error says to try `.v2` if you are on Server. |
| `token_env` | string | `"JIRA_API_TOKEN"` | The environment variable holding the API token. |
| `token_file` | string | `""` | A file holding the token. `~` expands. Empty means the default file (below). |
| `team_field_id` | string | `""` | A Jira custom field holding the team (`customfield_10056`). Added to every search's field list, and read into `Issue.team`. |
| `team_field_name` | string | `""` | Its display name. Preferred over the id when a tab's `team` clause is built, because it reads better in the JQL. |
| `projects` | list of string | `.{}` | Project keys the `--values` count is scoped to. Sanitised to `[A-Z0-9]{1,10}`; anything else is dropped silently. |
| `rate.per_sec` | float | `0.33` | Permits per second — about 20 requests a minute, Atlassian's comfortable rate. `0` turns the limiter off. |
| `rate.burst` | int | `60` | How many permits may be spent at once after an idle spell. |
| `rate.cooldown_secs` | int | `45` | The pause after a `429` or a `5xx`. Doubles per consecutive failure. |
| `rate.max_block_secs` | int | `120` | The ceiling on one wait. |

### `.mnml` — how the pane behaves

| key | type | default | what it does |
|---|---|---|---|
| `refresh_interval_secs` | int | `60` | Reload the active tab when the pane regains focus, if the last load was this long ago. `0` disables it. Bridge v2 has no timer message, so focus is the tick: come back to the pane and it reloads before you read it. |
| `detail_width_pct` | int | `40` | The detail pane's share of the width. Clamped to 20–70. |
| `detail_open` | bool | `true` | Whether the detail pane starts open. `d` toggles it. |
| `expand_indicator` | `.chevron` \| `.triangle` | `.chevron` | `▼`/`▶` or `▾`/`▸`, matching mnml's own `$MNML_EXPAND_INDICATOR`. |
| `max_comments` | int | `10` | How many comments the detail pane shows, newest first. |
| `max_prs` | int | `3` | How many linked PRs a ticket shows before `… show all N more`. `P` lifts the cap. |
| `open_command` | string | `""` | What `o` runs on a URL. Empty picks the platform's own opener (`open` / `xdg-open` / `start`). |

### `.tabs` — one entry per tab

| key | type | default | what it does |
|---|---|---|---|
| `name` | string | *(required)* | The tab's label. |
| `kind` | enum | `.custom` | See the table below. |
| `jql` | string | `""` | An explicit JQL. **Wins over `kind`** — a `kind` with a `jql` runs the `jql`. |
| `project` | string | `""` | Required by `.fix_version` (unless `jql` is set). Also seeds the create form and the assignee picker. |
| `component` | string | `""` | Narrows a `.fix_version` tab to one component. |
| `mode` | `.current_release` \| `.next_release` | `.current_release` | Which unreleased version a `.fix_version` tab means. |
| `version_name_contains` | string | `""` | Case-insensitive substring a version's name must contain — for a project with parallel release tracks (`Mobile - 1.6.X` beside `13.15.0`). |
| `filter_id` | int | `0` | Required by `.filter`. |
| `team` | string | `""` | Adds a server-side team clause (below). |
| `columns` | list of enum | `.{ .key, .status, .assignee, .updated, .summary, .actions }` | Which columns, in order. |
| `group_by` | `.hierarchy` \| `.status` | `.hierarchy` | Epic → story → sub-task, or one bucket per workflow status. |
| `status_order` | list of string | `.{ "In Progress", "In Review", "Testing", "To Do", "Open", "Done" }` | The bucket order when `group_by = .status`. Anything not named follows, alphabetically. |

`kind`:

| `kind` | JQL it builds |
|---|---|
| `.work_assigned` | `assignee = currentUser() AND resolution = Unresolved AND status not in ("Done", "Closed", "Resolved") ORDER BY updated DESC` |
| `.work_recently_done` | `assignee = currentUser() AND status in (Done, Closed, Resolved) AND resolved >= -30d ORDER BY resolved DESC` |
| `.work_recent` | `(assignee was currentUser() OR reporter = currentUser() OR worklogAuthor = currentUser() OR commentedBy = currentUser()) AND updated >= -30d ORDER BY updated DESC` |
| `.work_unified` | `assignee = currentUser() AND (resolution is EMPTY OR resolved >= -30d) ORDER BY resolved DESC, updated DESC` |
| `.filter` | `filter = {filter_id} ORDER BY updated DESC` |
| `.fix_version` | resolved at refresh — see below |
| `.custom` | none; `jql` is required |

`columns`: `.key` (14) · `.status` (14) · `.assignee` (20) · `.reporter`
(20) · `.priority` (10) · `.type` (10) · `.updated` (10) ·
`.fix_version` (14) · `.actions` (11) · `.summary` (takes what is left).
When the pane is too narrow to leave the summary a usable width, fixed
columns are dropped **from the right** — never `key`, never `summary` —
because a row of metadata with the sentence cut off is the wrong trade.

### How a release tab picks its version

At the first refresh of a `.fix_version` tab:

1. `GET /rest/api/{2,3}/project/{project}/versions`
2. drop everything `released`
3. drop everything whose name does not contain `version_name_contains`
   (case-insensitive), when that key is set
4. sort by `startDate` ascending with the undated last, and **by name
   descending** between two undated ones — most projects never set a
   start date, and `13.16.0` is the one being worked on, not `13.1.0`
5. `.current_release` takes the first, `.next_release` the second (or the
   first when there is only one)
6. build `project = {project} AND fixVersion = "{name}" [AND component =
   "{component}"] ORDER BY rank`, with the name escaped for JQL

Nothing matching is not a failure: the tab runs `issuekey = ''` — empty,
present, with a line saying why.

### The team clause

`team = "Apollo"` on a tab rewrites its JQL as

```
(<where>) AND ("Team" = "Apollo" OR component = "Apollo" OR labels = "Apollo") <ORDER BY …>
```

Three ways because sites disagree about where a team lives, and
server-side rather than client-side because filtering after the fact
drops matches past the row cap. The `ORDER BY` has to come off first —
Jira rejects `(<where> ORDER BY x) AND <extra>`.

## The token

Never in `config.zon`. Looked for in this order:

1. the file `jira.token_file` names (if that key is set) — and **only**
   there, so a typo does not silently fall through to a stale variable
2. `$<jira.token_env>` (default `JIRA_API_TOKEN`)
3. `<data root>/integrations/jira/token`

Surrounding quotes are stripped. This matters: Atlassian's copy button
hands out `"ATATT3x…"`, and a quoted token authenticates as a *corrupted*
token, which Jira answers with `200` and zero results rather than `401`.

The token value is never printed. `--check` reports its length and where
it came from, and nothing else.

`/myself` is **not** used as a preflight. A scoped API token routinely
lacks `read:me` while being perfectly able to search, so a `/myself`
failure costs one feature (`m`, assign-to-me) and never the pane.

## Keys

| key | what it does |
|---|---|
| `j` `k` · `↓` `↑` | move |
| `g` `G` | first / last row |
| `l` `h` · `→` `←` | expand / collapse — `←` on a leaf climbs to the parent |
| `Enter` `Space` | toggle the row |
| `E` `C` | expand / collapse everything |
| `x` `H` | hide the branch / unhide all |
| `P` | show every linked PR on this ticket |
| `Tab` `1`–`9` | switch tab |
| `r` | refresh this tab |
| `/` | filter (live; `Esc` clears) |
| `d` | detail pane |
| `ctrl+d` `ctrl+u` | scroll the detail pane |
| `o` | open in the browser (the PR's URL on a PR row) |
| `y` `Y` | copy the key / the URL |
| `t` | transition — a picker, then a confirm |
| `a` `m` | assign / assign to me |
| `f` | set the fix version |
| `c` | comment (`ctrl+s` sends, `Enter` is a newline) |
| `n` | new ticket (`Tab` walks the fields, `ctrl+s` creates) |
| `?` | the key sheet |
| `q` | close the pane |

`Esc` is a cascade: clear the filter, else close the detail pane, else
leave.

The mouse: a click on the tab strip switches tab; a click on a row
selects it; a click on its chevron — or a right-click anywhere on it —
folds it; the wheel moves three rows a notch.

## Commands, the chip and the statusline

`--install` writes a manifest declaring:

| what | value |
|---|---|
| id / label | `jira` / `Jira` |
| chip | `\u{f0303}` (nf-md-jira), fallback `JI`, blue |
| `jira.open` | the pane — `ctrl+k j`, the chip, the statusline segment |
| `jira.refresh` | the pane with every tab reloaded (`--refresh-all`) |
| `jira.search` | the pane with the filter box already up — `ctrl+k /` |
| statusline | `JIRA` on the right, clicking runs `jira.open` |
| settings | *Detail pane* (shown / hidden), *Ticket tree* (hierarchy / status) |
| auth | `site_url`, `email`, `api_token` (with `JIRA_API_TOKEN` as its env fallback) |

While the pane is running it pushes a live segment and an activity badge
over Tier-2 IPC: `JIRA <n>`, where `n` is the count in the first
`work_assigned` / `work_unified` tab.

`mnml-jira --values` prints `{"assigned_open": N}` for a poller.

## Testing it

Everything runs offline against `tools/fake_jira/` — a deterministic Jira
on the loopback with one epic, two stories, a sub-task, a bug, three fix
versions, two users and a four-state workflow.

```sh
cd integrations/jira && zig build test      # unit + the fake server's own tests
zig build                                   # → mnml-jira, mnml-fake-jira
./zig-out/bin/mnml-fake-jira --port 18719   # a Jira to point a real config at
```

`Store.handle` is the whole fake server as a pure function (method,
target, auth header, body in; status and body out), so most of its tests
touch no socket at all; `src/jira.zig`'s last two tests drive the client
against it through a real TCP connection, which is what proves the URLs,
the headers and the bodies.

The corpus scripts are `tests/e2e/integrations_jira_pane.test` (install
from the Dev tab, mount, tree, filter, help, hide/unhide, the transition
picker) and `integrations_jira_blocked.test` (no config, no token, a
config that does not parse).

## Layout

```
integrations/jira/
  build.zig            an exe on the SDK, plus the fake server
  build.zig.zon        `.mnml_sdk = .{ .path = "../../sdk/mnml-sdk" }`
  manifest.zon         the manifest — one definition, two readers
  main.zig             the CLI and the mount loop
  src/
    app.zig            the state and every action
    auth.zig           where the token comes from, and the refusals
    config.zig         the `config.zon` schema and where it lives
    jira.zig           the REST client and the JQL surgery
    json.zig           reading Jira's JSON without a schema for it
    keys.zig           keys → actions, one table
    model.zig          `Issue` / `Detail` out of the JSON
    os.zig             the clipboard and the browser
    ratelimit.zig      the token bucket in front of every call
    text.zig           fitting, wrapping, ages, percent-encoding
    theme.zig          colours by role
    tree.zig           the row model and the fold state
    ui.zig             painting
  tools/fake_jira/     the offline Jira
```

`docs/PARITY.md` has the feature-by-feature ledger against the Rust
`mnml-tracker-jira`, including what was deliberately left out.
