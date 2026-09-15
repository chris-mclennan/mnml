# mnml-bitbucket

Bitbucket Cloud pull requests as an mnml pane: the review queue, the
ones you opened, one repo's list; a detail with the reviewers and their
votes, the build statuses, the diffstat, the diff and the comment
threads; and the actions — open, copy, approve, request changes,
comment, merge, and check the branch out in the workspace.

```
 1 Review (1)  ▸2 api (2)
/ filter · r refresh · d detail · ? keys
PR     STATE    AUTHOR        BRANCH → DEST             UPDATED    VOTES  B TITLE
#1234  OPEN     Chris M       chris/fix-login → main    2026-09-03 ✓1 ✗1  ✖ Fix the login redirect
#1198  OPEN     Dana R        dana/timeout → main       2026-09-02 ✓0 ✗0  ● Bump the client timeout
```

`d` opens the detail beside it (or over it, on a narrow pane):

```
acme/api#1234
OPEN · chris/fix-login → main
author: Chris M · updated: 2026-09-03
○ you: no vote · ✓1 approved · ✗1 changes requested

Fix the login redirect

issues: [1] ENG-4210

Fixes ENG-4210. The redirect dropped the query string when the session had expired.

reviewers
  ✓ Dana R  approved
  ✗ Sam K  changes requested

builds
  ● Pipeline #412  SUCCESSFUL
  ✖ Deploy to dev  FAILED

files (2)  +49  -4
  ~ src/auth/session.zig  +18 -4
  + tests/redirect.test  +31 -0

diff
  diff --git a/src/auth/session.zig b/src/auth/session.zig
  @@ -40,7 +40,9 @@ pub fn redirectTarget(req: Request) []const u8 {
  -        return "/login";
  +        return withQuery("/login", req.query);

activity (5)
  Dana R · 2026-09-01 10:00
    Nice catch — this has bitten us twice.
  Sam K · 2026-09-01 11:00  src/auth/session.zig:44
    withQuery needs to escape the value here.
     ↳ Chris M · 2026-09-01 11:30
       Good point, pushed an escape.
```

## Install

From this repo's INTEGRATIONS section (`ctrl+shift+x`), Dev tab: `i`
builds and installs the folder. By hand:

```sh
cd integrations/bitbucket && zig build
./zig-out/bin/mnml-bitbucket --install
```

`--install` writes two files: the manifest mnml reads
(`<data root>/integrations/bitbucket.zon` — the chip, the commands, the
statusline segment, the settings rows, the auth fields), and a config
scaffold for you to edit
(`<data root>/integrations/bitbucket/config.zon`). The manifest is
public; the config is private to this machine and nothing else reads it.

## Auth

Two tokens, one wire format. Bitbucket authenticates an Atlassian API
token and a Bitbucket app password the same way; what separates them is
the scope you granted and the rate-limit bucket they draw from.

| | read (the lists and the detail) | write (approve / comment / merge) |
|---|---|---|
| 1 | `BITBUCKET_API_TOKEN` | `BITBUCKET_ACCESS_TOKEN` |
| 2 | `BITBUCKET_APP_PASSWORD` | `BITBUCKET_WRITE_TOKEN` |
| 3 | `BITBUCKET_PERSONAL_TOKEN` (`email:token` is fine — only the half after the colon is used) | `<config dir>/token.write` |
| 4 | `<config dir>/token` | the read token, marked as borrowed |

Scopes: **Pull requests: Read** at minimum, plus **Account: Read** for
the `mine` and `reviewing` tabs (they resolve your `account_id` through
`/2.0/user`). **Pull requests: Write** for the actions.

`BITBUCKET_REQUIRE_WRITE_TOKEN=1` turns the borrow off: a write with no
write token then refuses rather than going out under the read one.

A token is never printed. `--check` says where each came from and how
long it is, and nothing else:

```sh
mnml-bitbucket --check
```

```
config:      /Users/you/.config/mnml/integrations/bitbucket/config.zon
email:       you@example.com
workspace:   acme
repos:       2 (api, …)
tabs:        3
read token:  BITBUCKET_API_TOKEN (24 chars, not shown)
write token: BITBUCKET_ACCESS_TOKEN (24 chars, not shown)
api:         https://api.bitbucket.org/2.0
whoami:      Chris M (acct-chris)
```

`--diag` adds the per-tab breakdown and the cross-link state, for a bug
report.

## Config

`<data root>/integrations/bitbucket/config.zon`. First run writes a
commented scaffold and the pane says where.

```zig
.{
    .email = "you@example.com",
    .workspace = "acme",

    // Bitbucket has no workspace-wide pull-request endpoint: a mine /
    // reviewing / workspace tab queries each of these in turn. Keep it
    // to the repos you actually watch — enumerating a hundred on every
    // refresh is what lands an account in 429s.
    .repos = .{ "api", "web" },
    .hidden_repos = .{},

    .refresh_interval_secs = 300,
    .page_len = 50,
    .rate = .{ .min_interval_ms = 200, .max_attempts = 3, .default_backoff_secs = 15, .max_backoff_secs = 30 },

    .tabs = .{
        .{ .name = "Mine", .mode = .mine, .fallback = .workspace },
        .{ .name = "Review queue", .mode = .reviewing, .fallback = .none },
        .{ .name = "api", .mode = .repo, .repo = "api", .state = .OPEN },
    },

    .jira = .{ .enabled = true, .command = "jira.open", .base_url = "https://acme.atlassian.net", .project_keys = .{"TE"} },
    .github = .{ .enabled = false, .command = "github.open", .base_url = "" },
    .mnml = .{ .allow_checkout = true, .after_checkout_command = "git.refresh" },
}
```

### Tabs — `kind` / `mode` / `fallback`

* **`kind`** is what the tab lists. `.pull_requests` today; the field
  exists so a pipelines or branches tab is additive rather than a
  rename.
* **`mode`** is whose pull requests: `.repo` (one repo's list, needs
  `repo`), `.mine` (the ones you opened), `.reviewing` (the ones you are
  a reviewer on), `.workspace` (every one in `repos`, any author).
* **`fallback`** is what the tab shows when `mode` cannot run — the
  token has no **Account: Read**, or `/2.0/user` failed. `.none` leaves
  the tab empty *and says why*; `.repo` drops to this tab's `repo`;
  `.workspace` drops to every open pull request in `repos`. A tab that
  fell back says so in the strip: `1 Mine (7) [workspace]`.

Per-tab extras: `workspace` overrides the top-level one, `state` is
`.OPEN` / `.MERGED` / `.DECLINED` / `.SUPERSEDED`, and `q` is raw
Bitbucket Query Language layered under the mode's own predicate
(`updated_on >= 2026-01-01`).

### Cross-links

A pull request's title and body are scanned for issue keys. `i` opens
the next one — through the **jira integration's command when it is
installed** (`<data root>/integrations/jira.zon` is there), and through
`jira.base_url` in a browser when it is not. `project_keys` is worth
filling in: without it `UTF-8` and `SEV-1` read as issue keys too.

`[github]` is the same rule for a mirror of the same source, and
`[mnml]` is what the pane may do to the editor's workspace: whether `C`
may check a branch out, and which mnml command to run after it does.

## Keys

| | |
|---|---|
| `1`-`9` · `tab` · `shift+tab` | switch tab |
| `j` `k` `↑` `↓` `g` `G` | move · `ctrl+d` `ctrl+u` page (or scroll the detail) |
| `enter` `o` | open in a browser |
| `y` · `Y` | copy the URL · copy the branch |
| `d` · `D` | detail · fold the diff away |
| `a` · `A` | approve · withdraw the approval |
| `x` · `X` | request changes · withdraw the request |
| `c` | comment |
| `m` · `s` | merge · cycle the merge strategy |
| `C` | check the branch out in the workspace |
| `i` | open the next issue key |
| `/` · `esc` | filter · clear |
| `r` · `?` · `q` | refresh · keys · quit |

Every write is confirmed first, and the confirm names what it is about
to do — the merge one names the strategy and whether the source branch
closes. The comment prompt is a real text field: `←` `→` `home` `end`
`backspace` `delete` `ctrl+u`, and a paste arrives whole.

Mouse: a click on the tab strip switches tabs, a click on a row selects
it, a right-click on a row opens its detail, and the wheel moves the
selection.

## Checking a branch out

`C` is the only action that touches your working tree, so it decides
before it acts. The workspace must be a git repository whose `origin` is
this pull request's repo — in any of the spellings Bitbucket writes
(`https://…/acme/api.git`, `git@bitbucket.org:acme/api.git`,
`ssh://…`) — and the working tree must be clean. Anything else is a
refusal that names the rule it broke, and `mnml.allow_checkout = false`
turns the whole thing off.

## Rate limiting

Bitbucket counts per account, so a fan-out over ten repos is what trips
the ceiling. Every request passes a gate (`rate.min_interval_ms`
between two), a 429 is retried up to `rate.max_attempts` times honouring
`Retry-After` (clamped by `max_backoff_secs`), and **nothing else is
retried** — a 401 will not become a 200 by asking twice. A repo that
fails leaves a line under the list (`! ghost: no such repo`) instead of
blanking the tab.

## The statusline segment

The manifest declares a segment keyed `bitbucket.review`; the running
pane replaces its text with the live review-queue count (`BB·3`) over
the Tier-2 file-IPC channel, and sets the INTEGRATIONS activity badge to
the same number. Clicking it runs `bitbucket.review_queue`.

`bitbucket.refresh` does the same with no pane open: it runs
`mnml-bitbucket --refresh --workspace {{workspace}}` in a task pane,
counts the queue and republishes. The `--workspace` is load-bearing — a
`term` child does not inherit `MNML_IPC_DIR`, so without it the refresh
can count but has nowhere to publish.

## Testing

`zig build test` in this folder runs everything; `zig build` in the repo
root builds both binaries beside mnml and runs the same tests under
`zig build test`.

`tools/fake_bitbucket/` is a deterministic Bitbucket Cloud on the
loopback — four pull requests in `acme/api` and `acme/web`, one merged,
one with a reviewer who asked for changes, one that quotes a Jira key.
It answers the list, the detail, the activity, the diffstat, the diff,
the commit statuses, approve / request-changes (and their DELETEs),
comments and merge, and it remembers what the writes did so a test can
assert the effect rather than the request. `--rate-limit-first N` makes
it 429 the first N requests; `--url-file` writes the port it got, which
is how the corpus points the pane at it without ever choosing one.

```sh
mnml-fake-bitbucket --port 0 --url-file bb.url --lifetime-secs 120 &
BITBUCKET_BASE_URL=@bb.url BITBUCKET_API_TOKEN=x mnml-bitbucket --check
```

The corpus drives the whole pane through a real mount socket:
`tests/e2e/integrations_bitbucket_pane.test` (install, both tabs, the
filter, the detail, approve, comment, merge, the checkout refusal, the
key help), `…_statusline.test` and `…_setup.test`.

## What is not here

The Rust `mnml-forge-bitbucket`'s pipelines and branches tabs, its repo
tree with per-branch pipeline status, and its runtime scope cycling —
see `docs/PARITY.md`'s bitbucket section for the whole list and why.
