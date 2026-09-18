# mnml-bitbucket

Bitbucket Cloud as two mnml chips, on the SDK: **Bitbucket PRs** — the
open and merged pull requests across your workspace, one tree per
repo, a detail with the comments, approve — and **Bitbucket
Pipelines** — each repo's branches with the latest run on each. The
screens are the Rust reference's (`docs/ui-spec/bitbucket/README.md`
is the inventory), painted in mnml-zig's own chrome.

```
 BITBUCKET PRS  (2 repos · 5 PRs)                                   author: all  
  1 Open + Draft (3)   2 Merged (2)
  󰍉 / filter
  REPO / #PR                   STATE      AUTHOR         BRANCH             UPDATED      TITLE
▌ ▾ api                        2 PRs      Chris M        chris/fix-login    2026-09-01   #1234 · Fix the login redirect
       #1234                   OPEN       Chris M        chris/fix-login    2026-09-01   Fix the login redirect
       #1198                   OPEN       Dana R         dana/timeout       2026-08-31   Bump the client timeout to 30s
  ▾ web                        1 PR       Chris M        chris/empty-state  2026-09-01   #820 · Redesign the empty state
                                                                                                Show more (1)
 Open + Draft · 2 repos, 5 PRs       ↓ move · ⏎ expand · o open on web · d detail · m open↔merged · r refresh · ? keys · q quit
```

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
reads a file) and `.rate` (`rate_per_sec`, `capacity`, `max_attempts`,
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
| `⏎` `␣` | expand / collapse a repo; open a merged PR's post-merge pipeline line; lift the `Show more (N)` footer |
| `→` `l` · `←` `h` | expand or step in · collapse or step up |
| `e` `c` | expand / collapse every repo |
| `x` `H` `s` `⌥↑` `⌥↓` | hide this repo · un-hide all · cycle the scope · reorder (all persist) |
| `o` · `y` | open on the web · copy the URL |
| `d` · `^d` `^u` | the detail · scroll it |
| `a` | approve / withdraw (with the detail open) |
| `m` · `⇥` `⇤` · `1`–`9` | open ↔ merged · next / previous tab · a tab |
| `/` `esc` | filter · clear |
| `r` `?` `q` | refresh · keys · quit |

Mouse: every row, tab, chip and hint word is a hit target sized to what
it paints — a click on a row selects that row (and toggles a repo
header or a merged PR, as the reference does), a right-click opens the
row's menu, the wheel moves the cursor or scrolls the detail under it.

## The statusline chips

Two, because they are two numbers about two different things.

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

Each chip's hover says what its number counts, and the review one says
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
`{"open_mine":N,"unapproved_mine":K,"approved_mine":A,"unresolved_comments":M}`,
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
honouring `Retry-After` (clamped to 30 s) and parks every process on
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
429 the first N requests. `tests/e2e/integrations_bitbucket_*.test`
drive the pane through a real mount against it; `tools/bitbucket-diff.sh`
runs the reference and this pane on it and prints the content that
differs per screen.
