# Should I live in mnml-zig yet? — a parity report, 2026-09-20

Written for one reader deciding whether to move their daily editing from
the Rust mnml (frozen at 0.2.21) to mnml-zig (main `aeec0cb`). Every
number comes from `docs/PARITY.md`'s own tally script, the corpus, and
the manifests in `~/.config/mnml/integrations/`, not from memory.

## The short answer

mnml-zig has every editor, pane, git, LSP, debugger, HTTP and UI feature
the Rust version lists, plus 35 it does not. What you give up on day one
is **integrations**: three exist (Jira, Bitbucket, the sample), the other
28 Rust ones do not, and the ones you use are the three that exist. The
rest of the gap is nine deliberate cuts, none of which you use, and a
list of things that have never been looked at on real pixels.

## The ledger in numbers

| | count |
|---|---|
| Rust feature rows checked | 556 |
| done | 547 |
| partial | 0 |
| missing | 0 |
| cut on purpose | 9 |
| Zig-only additions | 35 |
| deliberate differences noted `// changed` | 21 |
| corpus scenarios, all green at 120×40 | 609 files, 660 checks |
| gate sweep at 80×24 / 120×40 / 200×60 | 141 / 141 |
| unit tests | 1818 |
| commits | 1431 |

## What you give up on day one

### Integrations you have installed under the Rust app

From your `~/.config/mnml/integrations/` (TOML = Rust era, ZON = Zig):

| integration | Zig | note |
|---|---|---|
| jira_work, jira_boards, jira_fix_versions | **yes** | rebuilt on the Zig SDK; the cache, warmer, broker, responsive buttons and actionable toasts are Zig-only |
| bitbucket_prs, bitbucket_pipelines | **yes** | same |
| claude_code, codex | **yes** | sessions panel, chips, cards; the Rust `mnml-*` launcher TOMLs are not read, the Zig host finds the CLIs itself |
| browser, vscode, btop, iftop | launcher-only | `:term` / launcher rows still work; the Rust manifest rows for them are not read (the dock's launchers cover this) |
| github | **no** | `mnml-forge-github` has no Zig build; the cross-host PR picker is a cut |
| codebuild, amplify | **no** | the AWS family has no Zig build |
| your private coverage integration | **no** | would need its own Zig build |

Everything else in the Rust integrations monorepo (the other AWS panes,
GitLab, Azure DevOps, Slack, Teams, Gmail, Calendar, Datadog, Cypress,
Playwright, S3, Azure blob, Docker, Cloudflare, the db drivers) has no
Zig counterpart. The plan always said the integrations are rewritten
after the cutover; Jira and Bitbucket came first because you use them
daily.

### The nine cuts (and where you learn about each)

| cut | you see |
|---|---|
| Cross-host PR picker (`pr.picker`) | a toast naming the reason |
| `pr.refresh` cache | same toast |
| Ghost text from a local FIM model | `suggest_backend = local` toasts a migration note; the API backend works |
| brotli in the HTTP client | gzip/deflate only; no visible change |
| Source-aware media dispatch (mixr / AppleScript) | the `♪` chip and `preferred_music_app` are accepted and ignored |
| Mixr panel size chips | absent |
| Glyph-builder SVG preview / font patching | a toast; the font ships baked instead |
| `Retry-After` header on a 429 | a fixed cooldown instead |
| Bitbucket's four placeholder chips | absent — they did nothing in Rust either |

### Deliberate differences you will notice

- The Claude chip is one colour always and a click shows the Sessions
  panel; Rust paled it when idle and started a new session on every click.
- The maximize button zooms the active pane; Rust dropped the chrome.
- The sidebar and the right panel are one idea: every section has a side.
- Diagnostics open in the bottom dock by default, not the right column.
- Config is ZON, not TOML; your Rust config was converted once and the
  two files never touch each other.
- Trash, find history and persisted undo live under the data root, not
  in the workspace.
- The clock is local time on macOS/Linux; Windows shows UTC.

## What you gain

Things the Rust version does not have, all on main today:

- **Sessions**: the panel with cards, the card banner in the pane's
  colours, session persistence of panes, layout, tab pages, chrome, pins
  and widgets.
- **Chrome**: the launcher dock (icon / icon+label, any edge, pins),
  edge grips and pins on every auto-hiding surface, the Settings overlay
  with scrollbar and section strip, `:set` over every discrete field,
  the CMD chip and click-away on the `:` line, a real cursor owned by one
  surface, the hollow unfocused cursor (glyph landing this week), a
  coloured rail on every pane (landing this week).
- **Git**: line-level stage/unstage/discard, stash and commit these lines,
  conflict resolution in the editor.
- **Navigation**: harpoon, live grep picker, workspace grep pane.
- **Data layer for Jira and Bitbucket**: an on-disk cache keyed by server
  stamps, a warmer on paced intervals, delta polls, conditional requests,
  one priority broker per service shared with your Python tools, a
  request log and the REQUESTS pane, and the design language enforced by
  a toolkit both panes draw through.
- **Daily-driver plumbing**: a stable install verb and a dev profile with
  its own data root, so developing never touches the copy you type in.
- **Verification**: 609 scenario scripts, a size sweep, colour assertions,
  a work-data audit, and a ghostty harness in progress so a tester can
  drive the real window.

## What has not been looked at on real pixels

Everything above is verified headless. These are the items whose look is
asserted by codepoint or colour value only, and the first things a real
window will judge:

- the `⋯` / `⋮` grips, the Claude figure (the installed font currently
  carries the spark at that codepoint — a font fix is in flight), the
  fa-eye glyph on the Review button (came back blank in one capture),
  fourteen integration chip glyphs with no ASCII fallback;
- the pane rail on every pane kind, the dock centred at your window size,
  the statusline hover lists;
- Windows and Linux at runtime (cross-compile only);
- live Atlassian conditional requests (Bitbucket documents them; Jira's
  search is a POST and has none) and a 429 under pacing.

No persona hunt has run since 2026-09-09. Its findings are still
untracked in the `hunt` worktree.

## Risk you carry by switching now

- A bug you hit costs you a restart of the editor you are typing in,
  unless you run the installed stable copy and develop in the dev
  profile, which is exactly what the profile split is for.
- The integration wire is at protocol 3 as of today; every restart after
  a merge that touches it needs a rebuild and reinstall of both
  integrations, or the panes go quiet.
- The Rust app keeps working unchanged beside it. Nothing about the
  switch is one-way: both binaries, data roots and instance markers are
  separate, and `mnml-rs` on your PATH keeps the old one a keystroke away.

## Recommendation

Switch for the parts you use most, which are the parts that are ahead:
editing, git, the sessions panel, Jira and Bitbucket. Keep the Rust
binary on your PATH under another name for the GitHub and AWS panes
until their Zig builds exist. Run the installed stable copy, not the
build output, so agents rebuilding never swap the binary under you.

Before calling it the daily driver, let the harness land and run one
hunt pass at your window size. That is the difference between "no
failing test" and "no bug I would notice", and it is the one thing the
Rust version had that the Zig one has not had yet.

## Day-one checklist

1. `./run.sh install --dry-run`, then `./run.sh install --force` (the
   force replaces the stale Rust binary from August at `~/.local/bin/mnml`;
   rename it to `mnml-rs` first if you want it kept).
2. Restart ghostty after the font track's install step, so the figure and
   the hollow cursor render.
3. Copy the Python broker client into the plugins repo (branch is ready,
   unpushed) so your Claude sessions queue behind the panes.
4. Delete the leftover `card-preview-backup` branch.
5. Say go on the hunt.
