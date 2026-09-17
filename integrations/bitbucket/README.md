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
                                                                                          [ Show 1 more older ]
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

The reference's resolution, first hit wins: `BITBUCKET_API_TOKEN`,
`BITBUCKET_APP_PASSWORD`, `BITBUCKET_PERSONAL_TOKEN` (`email:token` is
fine — only the half after the colon is used), then
`<config dir>/token`. `BITBUCKET_ACCESS_TOKEN`, when set, is what `a`
(approve) sends instead — otherwise approve goes out on the read token,
as the reference does. Scopes: **Pull requests: Read**, **Account: Read**
for the mine / reviewing tabs and the chip, **Pull requests: Write** for
approve.

A token is never printed:

```sh
mnml-bitbucket --check      # config, token source + length, whoami, the tabs
mnml-bitbucket --diag       # the same as a tree, with the rate bucket
```

## Keys

`?` in the pane is the sheet; it and the hint row are generated from
the one table in `src/keymap.zig`, so neither can drift from what a key
does. The keys are the reference's:

| | |
|---|---|
| `j` `k` `↑` `↓` · `⇞` `⇟` · `g` `G` `⇱` `⇲` | move |
| `⏎` `␣` | expand / collapse a repo; open a merged PR's post-merge pipeline line; lift the `[ Show N more ]` footer |
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

## The statusline chip

The PRs manifest declares the segment `bitbucket_prs.prs_mine`
(`󰂨 …` at rest, click → the mine-only tab). The pane recounts it every
five minutes and publishes `󰂨 N(K)` — N open PRs you authored in the
last `chip_stale_after_days`, off the excluded branches, K still
without an approval — over the Tier-2 file channel, with the count on
the INTEGRATIONS badge; `󰂨 !` in red on a failure. `bitbucket_prs.refresh`
does the same with no pane open (`--refresh --workspace {{workspace}}`;
a `term` child does not inherit `MNML_IPC_DIR`, so the workspace names
the channel). `--values` prints the reference's JSON for a poller.

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
