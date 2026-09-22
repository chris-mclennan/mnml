# The Bitbucket reference — every screen, every key

The inventory the Zig integration (`integrations/bitbucket/`) is built
from. The oracle is the Rust `mnml-forge-bitbucket` (0.3.29), built with
a base-URL override and run **against the offline fake server**
(`integrations/bitbucket/tools/fake_bitbucket/`, the `mnml-fake-bitbucket`
binary) — an invented workspace `acme` with repos `api` and `web`,
people `Chris M` / `Dana R` / `Sam K`, and ticket keys like `ENG-4210`.
No screen here was ever cut against the live Bitbucket API, and none may
be: a capture of somebody's real workspace must not reach a committed
file.

Re-cut the whole set with

```sh
zig build                       # mnml-fake-bitbucket
tools/bitbucket-capture.py      # → docs/ui-spec/bitbucket/rust-*.txt
tools/bitbucket-capture.py --only rust-full-merged-120x40   # just one
```

`MNML_BB_ORACLE_BIN` names the oracle build; each run gets its own
scratch `HOME` (so the keys that rewrite the config — `x` `H` `s`
`alt+↑↓` — cannot touch a real one) and its own rate-limit bucket. The
driver underneath is `tools/rust-capture.py` (a pty and a small VT
renderer; there is no tmux on the build machine).

The screens are the spec for **what is there** — every surface, action,
column and key — not the bytes: the port paints the same content in
mnml-zig's chrome (the caps header and chips, the `▌` marker, the theme
roles, the keymap-generated hint row).

Five screens the reference shows only *while a fetch is in flight*
(`rust-full-detail-loading`, `rust-c-detail-loading`,
`rust-full-refresh-in-flight`, `rust-full-merged-pr-fetching`,
`rust-full-click-author-chip-refreshing`) have no capture: the fake
server answers on the loopback faster than a frame, so the state never
paints. Their content is in the rows below instead. The eight
`rust-mnml-*` screens — the app inside the **Rust** mnml, and two cut
from the user's own running instance — are gone for the same reason the
rest were re-cut: they were live. Re-cutting them needs a Rust mnml
driven headless against the fake server, which this tool does not do.

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
| the Search chip | `rust-full-click-search-chip` | click `[ 󰍉 Search ]` | status `filter not wired yet (round-1 visual)` — a dead placeholder, like Target branch / Branch / Pipeline type / Trigger type (the port's toolbar answers all of these; see decision 1 below) |
| the Status chip | `rust-full-click-status-chip` | click | cycles to the next tab |
| the Author chip | `rust-full-click-author-chip` (the `…-refreshing` frame is too brief to catch offline) | click | toggles mine-only: `[ Author: Chris M ▾ ]`, refetches with `author.account_id = me` (open + one merged peek), status `<tab>: filter → Authored by me`; click again → `All` |
| tab keys | `rust-full-tab-key` | `Tab` / `Shift+Tab` / `1`–`9` | the strip's highlight moves |
| paging | `rust-full-pgdn`, `rust-full-home`, `rust-c-pgdn/pgup/end` | `PageDown` / `PageUp` / `Home`,`g` / `End`,`G` | ±10 rows, the ends |
| hide a repo | `rust-c-hide-repo` | `x` on a tree row | the repo's rows go, status `hid adx (H to un-hide all)`, `hidden_repos` written to the TOML (comments dropped) |
| un-hide | `rust-c-unhide-all` | `H` | the repos return (collapsed), status `un-hid 1 repo(s)`; `nothing hidden` when the list is empty |
| scope | `rust-c-scope-cycle-1/2/3` | `s` | status `scope: explicit` → `scope: all` → `scope: recent`; written to the TOML; the tabs refetch |
| reorder | `rust-c-reorder-down`, `-up` | `alt+↓` / `alt+↑` on a tree row | the repo swaps places; `repo_order` written |
| mine-only launch | `rust-mine-120x40`, `rust-mine-pr-row`, `-end`, `-show-all` | `--only prs-mine` (the statusline chip's click) | one tab `Mine`; `[ Author: Chris M ▾ ]`; each repo shows my open PRs plus one merged peek; `[ Show N more merged ]` |
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

## What the app paints into the Rust mnml

Read from the reference's manifests and `install.rs`. The screens that
once stood here were cut live and are gone (see the top of this file);
the facts are the spec, and the mnml-zig side of each is covered by
`tests/e2e/integrations_bitbucket_*.test`:

* **INTEGRATIONS rows**: two rows,
  `󰂨 Bitbucket Pipelines / bitbucket_pipelines.open` and `󰂨 Bitbucket PRs 0.3.2… / bitbucket_prs.open`,
  both `category = forge`, `in_palette_bar = false` (no palette-bar chip).
* **the pane**:
  a `:term` pane titled `󰂨 Bitbucket PRs`, the app's own screen inside
  it (`MNML_PANE=1`: no outer border); it reads `Bitbucket · loading…`
  for the minutes the prefetch takes.
* **the statusline chip**: the
  manifest's `[[statusline_segments]]` `bitbucket_prs_mine`, glyph `󰂨`,
  colour `#8BBF4E`, right side, fed by `[[values_sources]]`
  `mnml-forge-bitbucket --values` every 300 s (staggered 2 s × index,
  clamped 30–3600 s). It reads `󰂨 …` (comment colour, "waiting for
  first poll") until the poll answers, then `󰂨 {open_mine}({unapproved_mine})`
  in the manifest's colour, `󰂨 !` in red when the poll fails with no
  prior value (the poll's 10 s timeout under a busy shared bucket), the last value in yellow when a later poll
  fails, `󰂨 ⧗` in yellow when the binary is missing. Tooltip: `Open
  PRs you authored (last 90 days, non-release) — parens = still-needs-review
  count. Click to open the mine-only PRs tab.` Click →
  `bitbucket_prs.open_mine` (`--only prs-mine`). The app itself writes
  no Tier-2 line and sets no activity badge: the Rust mnml polls
  `--values` and paints the segment.

## What the port keeps, changes and decided

Kept: every screen above, its columns and keys, the two chips, the
config keys by name, the shared rate bucket, the headless JSON
surfaces, the persisting keys, approve. Changed for mnml-zig's chrome:
the toolbar is the caps header's chips; the tab strip is mnml's
`1 Open + Draft (47)  2 Merged (32)` line; the cursor row carries the
`▌` marker; columns are dropped whole below their width instead of
squeezed; the hint row is generated from the keymap and its words are
click targets; `?` opens a key sheet; the pane paints its progress
during a fetch instead of freezing.

The six the user settled:

1. **The chips are back, and they work — as the web's bar.** The
   reference's `Target branch`, `Branch`, `Pipeline type` and
   `Trigger type` painted and answered a click with `filter not wired
   yet (round-1 visual)`, and the first port cut them. Looking at the
   panes beside Bitbucket Cloud's own pages, the user asked for the WEB
   bar, working: on the PR pane `/` search, then **Status** (Open /
   Draft / Merged / Declined, a multi-select, Open + Draft by default),
   **Author** (all / me / everyone the loaded set names), **Target
   branch**, and the right-hand **show:** selector (all / reviewing /
   awaiting me — the web's *Watching* needs a watcher list the API does
   not expose, so it is not offered; the pane's older `awaiting:` chip
   is the third value); on the pipelines pane **Run by**, **Branch**,
   **Pipeline type**, **Status**, **Trigger type**. They are a toolbar
   row under the tab strip (`Painter.toolbarRow` in the SDK, the
   tracker pane's toolbar geometry) of ` key: value ` chips: a click
   opens the chip's picker (`show:` cycles), a right click lists every
   value with a `✓` on the live one, and each has a key (`S` `U` `T`
   `A` / `U` `B` `P` `S` `T`) in the sheet's `filters` section. Every
   chip narrows the rows already loaded; only a Status that adds an
   API state and Author `me` refetch, through the ordinary path. The
   choices persist per tab in `<config dir>/state.zon`. The screens:
   `zig-prs-*.txt`, `zig-prs-status-picker-*.txt`,
   `zig-prs-show-menu-*.txt`, `zig-prs-awaiting-*.txt`,
   `zig-pipelines-*.txt`, `zig-pipelines-status-picker-*.txt` at
   120×40 and 80×24, cut by `tools/bitbucket-spec.sh` from the pane's
   own `--dump` against the fake server, the way the `rust-*` set was
   cut from the reference. `integrations_bitbucket_filters.test`,
   `integrations_bitbucket_pipelines_filters.test` and the pane's unit
   tests drive them.

   Two more of the user's asks landed with it. **The rows fold with
   the tree's chevron** (`` / `` — the toolkit's `open_glyph` /
   `closed_glyph`, the host's `src/ui/expander.zig` codepoints, `v` /
   `>` under `--ascii`) rather than the reference's `▾` / `▸`. And
   **the header says what a fetch is doing** while one is out —
   `⠋ fetching… 2/13 repos`, `queued behind 3 requests`, `waiting for
   the API budget`, `fetch failed: …`, `no pull requests match` — with
   the refresh chip turning the host's own spinner ring (the SESSIONS
   section's frames and step, pinned equal in `src/ui/list_panel.zig`);
   the Jira pane's header took the same treatment through the same SDK
   function. `integrations_bitbucket_inflight.test` holds the fake with
   `--delay-ms` to paint it.
2. **A working `/` filter** behind the pill, the shape the sibling Jira
   integration uses: `/` opens it, typing narrows live, `⏎` commits,
   `esc` clears and leaves, the caps header reads `N of M` while it
   narrows, and the hint row says what the filter answers to.
3. **A right-click row menu**, deterministic per row kind — repo
   header, PR, merged PR, the `Show N more` footer, branch — offering
   only actions the pane already answers to by key. No writes were
   invented; approve appears only where its key is bound.
4. **`--prefetch` is kept and wired.** It fetches every tab through the
   shared bucket and writes the bodies to `<config dir>/cache/`; the
   pane serves each URL from there once, so its first paint is rows.
   The integration README carries the contract a poller runs it under.
5. **The token is `BITBUCKET_ACCESS_TOKEN` when set, the token file
   otherwise** — the reference's three variables still resolve between
   them. `--check` names the source and the length, never the token.
6. **`space i b` / `space i l`** open the two chips, and the leader
   popup lists them under `+integrations` — the tree reads the
   registry, so a built-in row always wins the key.
