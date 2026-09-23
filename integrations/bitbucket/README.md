# mnml-bitbucket

Bitbucket Cloud as two mnml chips, on the SDK: **Bitbucket PRs** — the
open and merged pull requests across your workspace, one tree per
repo, a detail with the comments, approve — and **Bitbucket
Pipelines** — each repo's branches with the latest run on each. The
screens are the Rust reference's (`docs/ui-spec/bitbucket/README.md`
is the inventory), painted in mnml-zig's own chrome.

```
▌BITBUCKET PRS  (2 repos · 5 PRs)  as of 4m ago                                                                    ?
▌ 1 Open + Draft (3)   2 Merged (2)
▌ status: Open + Draft   author: all   target: any   show: all
▌󰍉 / filter
▌ REPO / #PR                   STATE      AUTHOR         BRANCH             UPDATED      TITLE
▌  api                        2 PRs      Chris M        chris/fix-login    2026-09-01   #1234 · Fix the login redirect
▌      #1234                   OPEN       Chris M        chris/fix-login    2026-09-01   Fix the login redirect
▌      #1198                   OPEN       Dana R         dana/timeout       2026-08-31   Bump the client timeout to 30s
▌  web                        1 PR       Chris M        chris/empty-state  2026-09-01   #820 · Redesign the empty state
▌                                                                                        ⋯  Show more (1)
 Open + Draft · 2 repos, 5 PRs   ↓ move · ⏎ expand · o open on web · d detail · m open↔merged · r refresh · ? keys · q quit
```

The row under the strip is Bitbucket Cloud's own filter bar — see
"The filter bar" below — and the rows fold with the same chevron the
host's file tree wears (`tools/bitbucket-spec.sh` cuts these screens
into `docs/ui-spec/bitbucket/zig-*.txt`).

Column 0 is the app-colour gutter the pane toolkit paints, off this
chip's manifest colour (PRs blue, Pipelines green); the cursor's row
lights it up. Every colour on the screen is a role out of the host
theme's `hello.palette` — the same toolkit, the same roles and the same
`Show more (N)` row the Jira pane paints.

## Install

From this repo's INTEGRATIONS section (`ctrl+shift+x`), Dev tab: `i`
builds and installs the folder. By hand:

```sh
cd integrations/bitbucket && zig build
./zig-out/bin/mnml-bitbucket --install
```

`--install` writes two manifests — `<data root>/integrations/bitbucket_prs.zon`
and `bitbucket_pipelines.zon` (the chips, the commands, the auth
fields, the statusline segment) — and the config scaffold at
`<data root>/integrations/bitbucket/config.zon`. The manifests are
public; the config is private to this machine and nothing else reads
it. `--uninstall` removes both manifests and leaves the config.

The commands: `bitbucket_prs.open` (`space i b`), `bitbucket_prs.open_mine`
(the chip's click: only the PRs you authored), `bitbucket_prs.refresh`
(headless: recount the chip), `bitbucket_pipelines.open` (`space i l`).

## Config

`config.zon`'s keys are the reference's `mnml-forge-bitbucket.toml` keys
by name, so a TOML converts line for line:

| TOML | config.zon |
|---|---|
| `email = "…"` | `.email = "…"` |
| `workspace = "…"` | `.workspace = "…"` |
| `account_id = "…"` | `.account_id = "…"` (skips `/2.0/user`) |
| `refresh_interval_secs = 60` | `.refresh_interval_secs = 60` |
| `scope = "recent"` | `.scope = .recent` (`.all` / `.explicit`) |
| `recent_window_days = 14` | `.recent_window_days = 14` |
| `explicit_repos = [...]` | `.explicit_repos = .{ … }` |
| `hidden_repos = [...]` | `.hidden_repos = .{ … }` |
| `repo_order = [...]` | `.repo_order = .{ … }` |
| `chip_stale_after_days = 90` | `.chip_stale_after_days = 90` |
| `chip_excluded_branch_patterns = ["^release/", "^hotfix/"]` | `.chip_excluded_branch_patterns = .{ "^release/", "^hotfix/" }` (`^prefix` anchors, else substring) |
| `repos = [...]` | `.repos = .{ … }` |
| `[[tabs]] name / kind / workspace / repo / state / mode / q` | `.tabs = .{ .{ .name = "…", .kind = .workspace_open_prs, .repo = "…", .state = .OPEN, .mode = .mine, .q = "…" } }` |

`kind` is one of `.workspace_open_prs`, `.workspace_merged_prs`,
`.workspace_pipelines`, `.pull_requests`, `.pipelines`, `.branches`;
`state` `.OPEN` / `.MERGED` / `.DECLINED` / `.SUPERSEDED`; `mode`
`.mine` / `.reviewing` on a `pull_requests` tab. Two keys have no TOML
twin: `.base_url` (a test double; `$BITBUCKET_BASE_URL` wins, `@<path>`
reads a file — one still missing after 5 s is the setup screen and a
failing `--check`, never a fall back to `api.bitbucket.org`) and `.rate` (`rate_per_sec`, `capacity`, `max_attempts`,
`default_backoff_secs`, `max_backoff_secs`, `state_path`).

The keys that change the config at runtime — `x` hide, `H` un-hide,
`s` scope, `alt+↑` `alt+↓` order — rewrite the file whole; hand-written
comments do not survive, as in the reference.

## Auth

**`BITBUCKET_ACCESS_TOKEN` when it is set, else `<config dir>/token`.**
One variable to export, one file otherwise, and the same token for the
reads and for the one write the pane has (`a`, approve).

Bitbucket takes two kinds of token and they are **not** interchangeable
on the wire, which is what the one exception to that rule is about:

| token | header | `/2.0/user` |
|---|---|---|
| an account credential — an Atlassian API token (`ATATT…`) or an app password | `Basic base64(email:token)` | answers, with your account |
| an access token (`ATCTT…`) — repository, project or workspace scoped | `Bearer <token>` | 401s: it belongs to no person |

Send either one the other way round and Bitbucket answers **401**, with
nothing to say the token itself was fine. `mnml-bitbucket` reads the
kind off the token and picks the scheme, and `--check` says which it
used and why — you never choose.

The exception: an access token has no account, so the `mine` /
`reviewing` tabs, the chip and `--values` have nothing to filter by.
When an account credential is available too, **reads take it** and
`BITBUCKET_ACCESS_TOKEN` stays the approve token. With only an access
token exported, reads use it and `--check` reports the workspace it
reached instead of a person — set `account_id` in `config.zon` for the
`mine` tabs.

The reference's three variables still resolve, between those two, so a
machine that already exports one keeps working — first hit wins:

| | |
|---|---|
| `BITBUCKET_ACCESS_TOKEN` | the rule's variable; also the approve token |
| `BITBUCKET_API_TOKEN` | an Atlassian scoped API token |
| `BITBUCKET_APP_PASSWORD` | a Bitbucket app password |
| `BITBUCKET_PERSONAL_TOKEN` | either kind; `email:token` is fine — only the half after the colon is used |
| `<config dir>/token` | one line, `chmod 600` |

Scopes: **Pull requests: Read**, **Account: Read** for the mine /
reviewing tabs and the chip, **Pull requests: Write** for approve.

A token is never printed — `--check` names the variable or the file it
came from and how many characters it is, and nothing else:

```sh
mnml-bitbucket --check      # config, token source + length, whoami, the tabs
mnml-bitbucket --diag       # the same as a tree, with the rate bucket
```

```
token source: BITBUCKET_PERSONAL_TOKEN (loaded, 25 chars, not shown)
auth scheme: Basic base64(email:token) — an account credential (an Atlassian API token or an app password) authenticates as a person
approve token: BITBUCKET_ACCESS_TOKEN (192 chars, not shown) · Bearer <token>
```

## Keys

`?` in the pane is the sheet; it and the hint row are generated from
the one table in `src/keymap.zig`, so neither can drift from what a key
does. The keys are the reference's:

| | |
|---|---|
| `j` `k` `↑` `↓` · `⇞` `⇟` · `g` `G` `⇱` `⇲` | move |
| `⏎` `␣` | expand / collapse a repo; fold a pull request out to its builds; open a build's page; lift the `Show more (N)` footer |
| `→` `l` · `←` `h` | expand or step in · collapse or step up |
| `E` `C` (or `e` `c`) | expand / collapse every repo — the integration tree convention, the same pair the Jira pane binds |
| `x` `H` `s` `⌥↑` `⌥↓` | hide this repo · un-hide all · cycle the scope · reorder (all persist) |
| `o` · `y` | open on the web · copy the URL |
| `d` · `^d` `^u` | the pull request's detail · scroll it (PR tabs) |
| `a` | approve / withdraw (a PR tab, with the detail open) |
| `M` · `[ Open ]` `[ Merge ]` | merge this PR through Claude Code (only when it may) · the same two on the cursor's row, when it is wide enough |
| `S` `U` `T` `A` | on a PR tab: the Status picker · the Author picker · the Target-branch picker · show: all → reviewing → awaiting me |
| `U` `B` `P` `S` `T` | on a pipelines tab: Run by · Branch · Pipeline type · Status · Trigger type — each a picker |
| `m` · `⇥` `⇤` · `1`–`9` | open ↔ merged (PR tabs) · next / previous tab · a tab |
| `/` `esc` | filter · clear |
| `r` `?` `q` | refresh · keys · quit |

The pipelines header's `run pipeline`, `schedules` and `caches` open
that page for the repo under the cursor (its header or any of its
branches), and are not offered when no repo is; `usage` asks before
it opens the workspace's pipeline-minutes page in the browser. On a
pipelines tab the PR-only keys (`d`, `a`, `m`, `M`) are unbound and
off the hint row.

Mouse: every row, tab, chip and hint word is a hit target sized to what
it paints — a click on a row selects that row (and toggles a repo
header or a pull request), a right-click opens the row's menu, the
wheel moves the cursor or scrolls the detail under it.

## Builds under a pull request

Every pull request folds out to the pipeline runs on the commit it is
about — a merged one to the runs on its merge commit, an open one to
the runs on its **source head**, which are the builds you actually want
before you merge it. One row per run:

```
▾ #1234    OPEN    Chris M   chris/fix-login   2026-09-18   Fix the login redirect
      ⏵ IN_PROGRESS · chris/fix-login · 1h · #413
      ✓ SUCCESSFUL · chris/fix-login · 5h · #412
```

State first, then the branch it ran on, then how long ago, then the
run's number — the same line the Jira pane paints, out of the same
toolkit code (`sdk.pane.build`). `⏎` on one opens that run's page; `h`
folds the pull request back up.

It costs **one** request per pull request, keyed by the PR's
`updated_on`: Bitbucket moves that whenever anything on the pull
request does, a push included, so folding the same row open twice costs
nothing and one that has been pushed to is re-read without your having
to know to ask.

## Merging — and why the button is usually dim

The row under the cursor carries `[ Open ]` and, on an open pull
request, `[ Merge ]` — only that row, and only when the title column
can give up their cells and still say something (a title clipped to
`Rede` is worse than no button, so below about 140 columns they are
not offered). `M` merges the focused pull request at any width, and the
row's right-click menu carries it too: the inline button is the
convenience, the key is the guarantee.

`[ Merge ]` is **dim and not a click target** until the pull request can
actually merge. Five conditions, in the order a reader thinks about
them:

| | |
|---|---|
| approvals | the required reviewers have approved (`required_approvals`, default 1) and nobody has asked for changes |
| tasks | every task on the pull request is resolved |
| conflicts | it still applies to its target (the diffstat answers 555 when it does not) |
| build | the newest run on the **source** commit is green |
| comments | every comment is resolved or replied to — the same rule the review chip counts by |

Hovering a dim button, or clicking one, says which condition fails and
its number: `Merge: 1 of 2 approvals`, `Merge: 2 tasks still open`.
Every field starts in the state that blocks, so a pull request nobody
has looked at is never ready by accident — it says `not checked yet`.

The look costs **one cached round per open pull request**, keyed by its
`updated_on`, taken for the row the cursor lands on and never again
while the pull request has not moved: the PR detail, the diffstat, the
comments (through the same cache the review chip uses, so an unmoved
pull request pays nothing for them) and — only when the row's builds
are not already open and fresh — the pipelines list. `--values` never
does any of this: the statusline run counts, it does not judge.

A ready button opens a confirm that **names** what it is about — the
title, `source → target`, and the strategy (`←→` cycles the ones
`merge_strategies` allows). Confirming does not call the merge API.
It dispatches a **Claude Code session** whose prompt carries the pull
request's URL and the chosen strategy and asks it to merge through the
Bitbucket API with `$BITBUCKET_ACCESS_TOKEN` (the variable's name, never
its value) and to report the outcome on its last line. The one
destructive action this pane offers goes through the thing you already
supervise — and the button then follows that session: a spinner while
it runs, `⏸` when it stops to ask you something, `[ view ]` when it
ends, a red `✗` with the reason when it fails. A merge that ends while
the pane does not have the keyboard sends a notification.

## The filter bar

The row under the tab strip is Bitbucket Cloud's own bar, working —
the reference painted four of these chips as placeholders that
answered a click with `filter not wired yet`, and the first port cut
them. Each chip is a ` key: value ` pill in the toolkit's toolbar
geometry (the tracker pane's), with its key beside it:

| PR tab | | |
|---|---|---|
| `status:` | `S` | **multi-select** — Open · Draft · Merged · Declined; `␣` toggles a box, `⏎` closes. Open + Draft is the open tree's default, Merged the merged tree's |
| `author:` | `U` | `all`, `me`, then everyone the loaded set names, sorted |
| `target:` | `T` | the destination branch, from the set |
| `show:` | `A` | `all` → `reviewing` (you are a REVIEWER, voted or not) → `awaiting me (N)` (a reviewer who has not voted — the pane's older `awaiting:` chip, folded in). The web's third value, *watching*, needs a watcher list Bitbucket's API does not expose, so it is not offered |

| pipelines tab | | |
|---|---|---|
| `run by:` | `U` | the people who ran them |
| `branch:` | `B` | the branch — the one chip that also finds a branch with no run yet |
| `type:` | `P` | `branch` · `pull-request` · `custom` · `tag`, off `target.type` / `ref_type` / `selector.type` |
| `status:` | `S` | `SUCCESSFUL` · `FAILED` · `IN_PROGRESS` · … — the values the runs carry |
| `trigger:` | `T` | `push` · `manual` · `schedule` |

A left click opens the chip's picker (a typed filter over its rows,
`↑↓`, `⏎`; `show:` has three values and a click cycles it, the way
the host's `sort:` chip does); a **right click** lists every value
with a `✓` on the live one, and a row of that menu applies it. A chip
off its default wears the active ink and the header reads `N of M`;
one that hides every row reads `no pull requests match`.

**Which filters cost a request.** Every chip is a predicate over the
rows already loaded — `participants`, `dest_branch`, a run's facts all
come with the listing — with two exceptions, both on the PR tab, both
one refetch through the ordinary refresh path and the shared bucket:

* **Status** that adds an API state the listing was not fetched with:
  Merged (or Declined) on the open tree, Open on the merged one. The
  refetch asks for the states together (`state=OPEN&state=MERGED`, one
  request per repo as before). Taking a state off is client-side.
* **Author `me`** in either direction — it is the mine-only fetch
  (`author.account_id = me` across the workspace, with the merged
  peek), which lists what the page did not. A named author is not.

Every pipelines chip, the target branch and `show:` never fetch.

A chip is an explicit ask, so it lifts the 24-hour window the tree
otherwise folds old rows behind: something that has been waiting on
you for three days is the whole point of `awaiting me`.

The chips persist **per tab, by name**, in `<config dir>/state.zon`
beside `config.zon` — never in the config, which stays the reference's
keys. A state file that will not read is an empty one.

## What the header says while it fetches

A reader once waited a minute under `loading…` unable to tell whether
the pane was fetching, queued behind the rate broker, or done with
nothing. While a fetch is out the caps header says which — in the same
words on this pane and the Jira one (`sdk.pane.chrome.fetchText`) —
and the refresh chip turns the host's own spinner ring:

| | |
|---|---|
| `⠋ fetching… 2/13 repos` | the first load, counting repos as they land |
| `(2 repos · 3 PRs)  ⠋ fetching…` | a refetch: the rows and their count stay on screen |
| `⠋ queued behind 3 requests` | held in the local broker's queue, that many ahead |
| `⠋ waiting for the API budget` | held on the shared file bucket (no broker) |
| `(2 repos · 3 PRs)  fetch failed: <why>` | the last fetch failed, and this is why — for every repo (`network error`), one (`web: HTTP 500`) or some (`2 of 5 repos: …`) |
| `(2 repos · 3 PRs)  as of 4m ago` | done; the age the family already says |

A failed refetch never empties the list: a repo that did not answer
keeps the rows it had (the same rule the Jira pane follows), and `as
of` stays on the last time every repo answered. Only a tab with
nothing to show paints the reason in place of the list.
| `no pull requests match` | the chips or the `/` query hid every row |

## The statusline chips

Three, because they are three numbers about three different things.

**`bitbucket_prs.prs_mine`** — `󰂨 N(K)`: N open pull requests you
authored in the last `chip_stale_after_days`, off the excluded
branches, K of them still without an approval. `󰂨 …` at rest, `󰂨 !` in
red on a failure. A click opens the mine-only tab.

**`bitbucket_prs.reviews_mine`** — ` M`: review threads across those
pull requests that are still **waiting on someone** — neither marked
resolved nor replied to. A reply is an answer whoever wrote it ("I
disagree" closes a loop as surely as a fix does) and the resolve button
is used unevenly across teams, so counting only `resolution` would call
every answered thread unanswered. Blank at rest: it is published only
once the count has been taken, because a zero before then would read as
"nothing outstanding".

**`bitbucket_prs.reviews_pending`** — ` P`: open pull requests
waiting on **your** review — you are a reviewer and have not approved.
The one of the three that is your move. Counted out of the same listing
as the first chip (one BBQL asks for both sets), so it costs no extra
request. A click opens the pane with the awaiting filter already on.

Each chip's hover says what its number counts, names the top three by
title so you do not have to open the pane to find out which, and the
review one says
what the count cost — how many pull requests were answered off the
cache. See **Prefetch** below for why that matters: the review figure is
one `…/comments` request per pull request whose `updated_on` has
changed since the last run, and none for the rest, which is what keeps
a five-minute poll inside the bucket.

The pane recounts and publishes every five minutes over the Tier-2 file
channel, with the open count on the INTEGRATIONS badge.
`bitbucket_prs.refresh` and `--values --workspace W` do the same with no
pane open (a `term` child does not inherit `MNML_IPC_DIR`, so the
workspace names the channel), and mnml's own poller runs the latter on
the manifest's interval. `--values` also prints the JSON:
`{"open_mine":N,"unapproved_mine":K,"approved_mine":A,"reviews_pending":P,"unresolved_comments":M}`,
where `unresolved_comments` is `null` when the count was not taken.

## Prefetch — and the contract a poller runs it under

`mnml-bitbucket --prefetch` fetches every configured tab once, through
the same shared bucket as everything else, and writes each 2xx GET body
to `<config dir>/cache/` — one file per URL, with the URL and the time
in its first line. The pane, on open, serves each GET from that
directory **once**: the startup fetch lands off the disk, so the first
paint is rows instead of `loading… 0/13 repos`, and every request after
that (a refresh, `r`, the auto-refresh, a detail) goes to the API, so
nothing shown is more than one open stale. An entry older than an hour
is ignored. `--prefetch` clears the directory before it starts, so a
repo that left the config cannot keep answering.

**The poller contract.** mnml-zig's host poller runs a manifest's
`values_sources` line — `mnml-bitbucket --values --workspace <ws>`,
which is one request-shaped call, not this. `--prefetch` is the whole-
pane warm and is off by that poller unless a source sets
`.prefetch = true`, precisely because of the cadence below. Whatever
runs it — mnml's poller with that flag, `launchd`, `cron`, a `systemd`
timer — the contract is:

```sh
mnml-bitbucket --prefetch          # MNML_DATA_ROOT / MNML_BITBUCKET_CONFIG as the pane sees them
```

* **Output.** One line on stdout:
  `prefetched 3 tab(s) · 13 repos · 212 rows · 44 requests · 44 cache entries in <dir>`.
  Anything that went wrong is a line on stderr. Nothing else is
  printed, and no token is ever printed.
* **Exit codes.** `0` the cache is complete · `2` it ran and some repos
  failed (the cache holds the rest — a normal outcome under a 429, and
  not a reason to alert) · `1` it could not run at all (no config, no
  token, no tab, nothing fetched). Only `1` is worth surfacing.
* **How often.** One pass costs about `1 + tabs × (1 + repos)` requests
  — 44 for the thirteen-repo, three-tab config. The shared bucket
  refills at 0.22 requests/s, so that pass is ~200 s of the machine's
  whole Bitbucket budget. **Ten to fifteen minutes between passes** is
  the intended cadence: it leaves three quarters of the bucket for the
  panes and the scripts, and stays inside the cache's one-hour
  freshness. **Five minutes is the floor** — below that the passes
  overlap the budget and every other process on the bucket starts
  waiting. Never run two passes at once.
* **It is safe to run while a pane is open**: the limiter is
  cross-process, and the pane re-reads the cache only on its next open.
  mnml's poller skips a source whose pane is open anyway — that pane is
  already publishing the same segment.

**Merge-ready**, for the follow-up track that will paint it: a pull
request is merge-ready when it is approved by its required reviewers,
every task on it is resolved, it has no conflicts, its latest pipeline
is green, and every comment is either resolved or replied to.

## Rate limiting

Every request passes the shared token bucket the reference and the
Python scripts on this machine already take turns on —
`~/.tattle-claude-artifacts/bitbucket-ratelimit.json` (or
`$TATTLE_ARTIFACTS_ROOT`, `$BITBUCKET_RATELIMIT_STATE`, `<MNML_DATA_ROOT>/ratelimit/`),
0.22 requests/s, a burst of 40. A 429 is retried up to three times
honouring `Retry-After` (a park longer than 30 s is not slept through; the SDK's `ratelimit.Retry`, the Jira pane's too) and parks every process on
the bucket; nothing else is retried. A repo that fails keeps its row,
labelled `429 · retry in 30s` / `auth failed` / `no such repo`.

A thirteen-repo prefetch takes minutes under that bucket; the pane
paints `loading… 7/13 repos` and answers keys meanwhile.

## Testing

`zig build test` in this folder runs everything; `zig build` in the repo
root builds both binaries beside mnml and runs the same tests under
`zig build test`.

`tools/fake_bitbucket/` is a deterministic Bitbucket Cloud on the
loopback — `acme` with `api` and `web`: five pull requests, two merged
with merge commits, branches and pipeline runs dated against the clock,
approve / unapprove that land in its state, `--rate-limit-first N` to
429 the first N requests, `--delay-ms N` to hold every reply (the only
way to catch the pane with a fetch in flight on the loopback). `tests/e2e/integrations_bitbucket_*.test`
drive the pane through a real mount against it; `tools/bitbucket-diff.sh`
runs the reference and this pane on it and prints the content that
differs per screen.
