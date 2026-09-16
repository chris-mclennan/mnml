# The Bitbucket reference — every screen, every key

The inventory the Zig integration (`integrations/bitbucket/`) is built
from. The oracle is the Rust `mnml-forge-bitbucket` (0.3.29) run live
with the user's real config, read-only, on a private rate bucket, and
the Rust mnml it mounts in. Every `rust-*.txt` here is a screen cut
with `tools/rust-capture.py` (a pty and a small VT renderer; there is
no tmux on the build machine). The screens are the spec for **what is
there** — every surface, action, column and key — not the bytes: the
port paints the same content in mnml-zig's chrome (the caps header and
chips, the `▌` marker, the theme roles, the keymap-generated hint row).

The config the captures ran on is the user's
`~/.config/mnml-forge-bitbucket.toml` with `repos` trimmed to four
(`app-a`, `acmeco-playwright`, `app-c`, `example.net`) — under
the shared bucket (0.22 requests/s) the thirteen-repo prefetch takes
four to twenty minutes and paints nothing until it is done. Every
request was a GET; the keys that write the config (`x` `H` `s` `alt+↑↓`)
ran against a scratch copy of it, and `a` (approve) was never pressed
on the live site — its screen is documented from `app.rs` and
exercised on the fake server.

## The app's own screens (`MNML_PANE=1`, 120×40 unless noted)

The pane is four bands: the tab strip (`┌ bitbucket ┐` box, one row of
`1.Open + Draft (49) │ 2.Merged (32) │ 3.Pipelines (18)` — hidden
under `--only`), the filter toolbar (chips), the table (a header row
and the rows), the status row (a status message on the left, the
hint chips on the right).

| screen | file | reached by | shows |
|---|---|---|---|
| Open + Draft tree, first paint | `rust-full-open-collapsed` | launch (the reference auto-expands every repo on the first fetch) | toolbar `[ 󰍉 Search ] [ Status: Open ▾ ] [ Author ▾ ] [ Target branch ▾ ] … [ 󰑐 Refresh ]`; columns `REPO / #PR · STATE · AUTHOR · BRANCH · UPDATED · TITLE`; a repo header row ` ▼ adx  15 PRs  <author> <branch> <date> #638 · <title>` (the header previews its first PR; an empty repo shows `last merged` + its last merge; an erroring repo shows `429 · retry in 30s` / `auth failed` / `no such repo` in red); PR rows `     #638  OPEN  Claude  fix/… 2026-09-16  <title>`; status `Open + Draft · 49 rows` |
| a PR row focused | `rust-full-open-pr-focused` | `j` `j` | the cursor row on a dark ground (no marker glyph) |
| detail, loading | `rust-full-detail-loading` | `d` | the right 45%: `┌ ws/repo#id ┐` box, `loading detail…` |
| detail | `rust-full-detail`, `rust-c-detail` | `d` (2 requests: PR, comments) | `STATE · source → dest`, `author: X · updated: YYYY-MM-DD`, `○ not approved · N total` (or `✓ you approved · N total`), blank, title (bold), blank, description (wrapped) or `(no description)`, blank, `comments (N, most-recent first):`, each `  author · date` then the body indented; the list squeezes to `REPO STATE AUTHOR BRANCH UPDATED TITLE` at 55% |
| detail scrolled | `rust-full-detail-scrolled`, `rust-c-detail-ctrl-d/u` | `ctrl+d` / `ctrl+u` (4 lines) | the same, offset |
| detail follows the cursor | `rust-c-detail-next-row` | `j` with the detail open | the next PR's detail |
| expand all / collapse all | `rust-full-open-expand-all`, `rust-full-open-collapse-all` | `e` / `c` | every repo open / every header alone (previews kept) |
| the footer | `rust-full-open-end` | `G` | `[ Show 22 more older ]` as the last row — the workspace tabs keep PRs updated in the last 24 h; `Enter` on it lifts the window (`rust-full-open-show-all`, merged capped at 20 per repo) |
| Merged tree | `rust-full-merged` | `m` (open↔merged) or `2` / `Tab` / the Status chip | the same columns; `Status: Merged ▾`; PR rows carry a caret `▶ #5287  MERGED …`; `[ Show 73 more older ]` |
| a merged PR opened | `rust-full-merged-repo-expanded` → `rust-full-merged-pr-fetching` → `rust-full-merged-pr-pipeline` | `Enter` / `l` on a merged PR | the row grows to two lines: `  → fetching pipeline for <sha7> on <dest>…`, then `  ✓ SUCCESSFUL  #26679  on main  2026-09-15  5m12s` (or `  → no pipeline ran on <sha> (<dest>)`); `h` closes it; status `PR #N: K pipeline(s) on merge commit` |
| Pipelines tree | `rust-full-pipelines` | `3` | toolbar `[ Branch ▾ ] [ Pipeline type ▾ ] [ Status: Pipelines ▾ ] [ Trigger type ▾ ]` … `[ Run pipeline ] [ Schedules ] [ Caches ] [ Usage ] [ 󰑐 Refresh ]`; columns `REPO / BRANCH · STATE · BUILD · RESULT · DATE`; ` ▼ merchant-dashboard  4 branches`; branch rows `     main  COMPLETED  #10179  SUCCESSFUL  2026-09-11` or `     bugfix/…  —`; the branches are curated to the majors (main/master/develop/staging/prod…), the newest of each `release/*` `hotfix/*` family, and the single newest feature branch, non-eternals dropped after 14 quiet days; repos sorted by their newest run |
| tree keys | `rust-full-pipelines-right-expands`, `-left-collapses`, `-expand-all` | `l`/`→` expand-or-descend, `h`/`←` collapse-or-ascend, `e`, `c` | as named |
| refresh | `rust-full-refresh-in-flight` → `rust-full-after-refresh` | `r` or the Refresh pill | status `refreshing <tab>…` then `<tab> · N repos, M PRs` (`(K errored)` when some repo failed); the UI freezes during the fetch |
| the Search chip | `rust-full-click-search-chip` | click `[ 󰍉 Search ]` | status `filter not wired yet (round-1 visual)` — a dead placeholder, like Target branch / Branch / Pipeline type / Trigger type |
| the Status chip | `rust-full-click-status-chip` | click | cycles to the next tab |
| the Author chip | `rust-full-click-author-chip-refreshing` → `rust-full-click-author-chip` | click | toggles mine-only: `[ Author: Chris McLennan ▾ ]`, refetches with `author.account_id = me` (open + one merged peek), status `<tab>: filter → Authored by me`; click again → `All` |
| tab keys | `rust-full-tab-key` | `Tab` / `Shift+Tab` / `1`–`9` | the strip's highlight moves |
| paging | `rust-full-pgdn`, `rust-full-home`, `rust-c-pgdn/pgup/end` | `PageDown` / `PageUp` / `Home`,`g` / `End`,`G` | ±10 rows, the ends |
| hide a repo | `rust-c-hide-repo` | `x` on a tree row | the repo's rows go, status `hid adx (H to un-hide all)`, `hidden_repos` written to the TOML (comments dropped) |
| un-hide | `rust-c-unhide-all` | `H` | the repos return (collapsed), status `un-hid 1 repo(s)`; `nothing hidden` when the list is empty |
| scope | `rust-c-scope-cycle-1/2/3` | `s` | status `scope: explicit` → `scope: all` → `scope: recent`; written to the TOML; the tabs refetch |
| reorder | `rust-c-reorder-down`, `-up` | `alt+↓` / `alt+↑` on a tree row | the repo swaps places; `repo_order` written |
| mine-only launch | `rust-mine-120x40`, `rust-mine-pr-row`, `-end`, `-show-all` | `--only prs-mine` (the statusline chip's click) | one tab `Mine`; `[ Author: Chris McLennan ▾ ]`; each repo shows my open PRs plus one merged peek; `[ Show 76 more merged ]` |
| open on the web | (not pressed live — it opens the user's browser) | `o` / `Enter` on a non-tree row | `webbrowser::open(url)`; status `opened <url>` / `open failed: <e>`; PR → its html link, branch → `…/branch/<name>`, pipeline → `…/pipelines/results/<n>`, repo header → `…/pull-requests` or `…/branches` |
| copy the URL | (not pressed live — it writes the clipboard) | `y` | `pbcopy` / `xclip` / `wl-copy` / `clip`; status `copied <url>` / `copy failed: <e>` |
| approve | (not pressed live) | `a` with the detail open | `POST …/approve` or `DELETE` when `✓ you approved`; status `approved ws/repo#id` / `unapproved …` / `approval toggle failed: <e>`; `approve needs Account:Read on the app password` when whoami failed |
| 80×24 | `rust-prs-80x24`, `rust-prs-detail-80x24`, `rust-prs-merged-80x24`, `rust-pipelines-80x24`, `-collapsed` | | the columns squeeze to `R STAT AUT BRAN`; the toolbar drops its right side; the hint chips drop from the front |
| the hint strip | every status row | | `1-9 tab · ↑↓/jk move · ↵ expand · o open on web · d detail · a approve · m open↔merged · r refresh · q quit`, right-aligned, dropped from the front under overflow; each chip is a click target that synthesises the key |
| errors | (in source: `draw_table`) | | a tab whose fetch failed: `error: <e>` + `Press r to retry.` in red; an empty tab: `(no PRs match this tab)` / `(no pipelines have run on this repo)` / `(no branches in this repo)` / `(no repos in scope)`; before the first fetch: `loading…` |
| rate limit | (in source: `RepoPrs.error`) | | a 429 is retried up to 3 times honouring `Retry-After` (≤ 30 s) and penalises the shared bucket (`~/.tattle-claude-artifacts/bitbucket-ratelimit.json`, shared with the Python scripts); the repo's header row then reads `429 · retry in 30s` in red and the status counts it as errored |

The keys, from `keys.rs`: `q` `ctrl+c` quit · `r` refresh · `↑`/`k` `↓`/`j` · `PageUp` `PageDown` · `Home`/`g` `End`/`G` · `→`/`l` `←`/`h` (tree) · `Enter`/`Space` toggle (tree) · `Enter`/`o` open on the web · `y` copy the URL · `Tab` `Shift+Tab` `m` next/prev tab · `1`–`9` tab · `e` `c` expand/collapse all (tree) · `x` hide · `H` un-hide all · `s` cycle the scope · `alt+↑` `alt+↓` reorder (tree) · `d` detail · `ctrl+u` `ctrl+d` scroll the detail · `a` approve (detail open). There is no key sheet and no filter.

## The headless surfaces (`rust-headless-json.txt`)

`--values` → `{"open_mine":N,"unapproved_mine":K,"approved_mine":A}`
(my OPEN PRs across `repos`, updated in the last `chip_stale_after_days`,
not on a `^release/` / `^hotfix/` branch; non-zero exit with a stderr
line on failure, 10 s timeout). `--list-prs --json` →
`{"host":"bitbucket","prs":[…]}` over the per-repo `pull_requests` tabs
only (the workspace kinds are skipped — with the user's config the list
is empty). `--find-pipeline-for-pr --owner --repo --branch --json` →
`{"url":"https://bitbucket.org/…/pipelines/results/N"}` or `{"url":null}`.
`--check` prints the config path, `token source: env: … (loaded, N chars)`,
workspace, email, refresh, scope, whoami, the tabs, then a live probe.
`--diag` is the same as a tree with the runtime. `--prefetch` emits the
tabs' rows as JSON for the Rust mnml's prefetch worker.

## What the app paints into the Rust mnml (`rust-mnml-*`)

Cut from a Rust mnml run headless with the user's real manifests
(`rust-mnml-integrations-sidebar-375x90` and `rust-mnml-statusline-375x90`
are from the user's running instance, via its IPC channel):

* **INTEGRATIONS rows** (`rust-mnml-integrations-160x48`): two rows,
  `󰂨 Bitbucket Pipelines / bitbucket_pipelines.open` and `󰂨 Bitbucket PRs 0.3.2… / bitbucket_prs.open`,
  both `category = forge`, `in_palette_bar = false` (no palette-bar chip).
* **the pane** (`rust-mnml-prs-160x48`, `rust-mnml-pipelines-160x48`):
  a `:term` pane titled `󰂨 Bitbucket PRs`, the app's own screen inside
  it (`MNML_PANE=1`: no outer border); it reads `Bitbucket · loading…`
  for the minutes the prefetch takes (`rust-mnml-prs-loading`).
* **the statusline chip** (`rust-mnml-start` → `rust-mnml-prs`): the
  manifest's `[[statusline_segments]]` `bitbucket_prs_mine`, glyph `󰂨`,
  colour `#8BBF4E`, right side, fed by `[[values_sources]]`
  `mnml-forge-bitbucket --values` every 300 s (staggered 2 s × index,
  clamped 30–3600 s). It reads `󰂨 …` (comment colour, "waiting for
  first poll") until the poll answers, then `󰂨 {open_mine}({unapproved_mine})`
  in the manifest's colour, `󰂨 !` in red when the poll fails with no
  prior value (what the captures show — the poll's 10 s timeout under
  the shared bucket), the last value in yellow when a later poll
  fails, `󰂨 ⧗` in yellow when the binary is missing. Tooltip: `Open
  PRs you authored (last 90 days, non-release) — parens = still-needs-review
  count. Click to open the mine-only PRs tab.` Click →
  `bitbucket_prs.open_mine` (`--only prs-mine`). The app itself writes
  no Tier-2 line and sets no activity badge: the Rust mnml polls
  `--values` and paints the segment.

## What the port keeps, changes and needs a decision on

Kept: every screen above, its columns and keys, the two chips, the
config keys by name, the shared rate bucket, the headless JSON
surfaces, the persisting keys, approve. Changed for mnml-zig's chrome:
the toolbar is the caps header's chips; the tab strip is mnml's
`1 Open + Draft (47)  2 Merged (32)` line; the cursor row carries the
`▌` marker; columns are dropped whole below their width instead of
squeezed; the hint row is generated from the keymap and its words are
click targets; `?` opens a key sheet; the pane paints its progress
during a fetch instead of freezing. Left out: the four placeholder
chips that do nothing in the reference (`Target branch`, `Branch`,
`Pipeline type`, `Trigger type`); `--prefetch` (mnml-zig has no
prefetch worker). Added: a working `/` filter behind the filter pill
(the reference's Search chip is a dead placeholder), a right-click row
menu of the same actions. Each of these is listed for the user's
decision in the port's report.
