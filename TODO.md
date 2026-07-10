# mnml TODO

Living list of work that's been considered but deliberately deferred.
Not a wishlist — only items where the scope/shape is already understood
and the only thing missing is a session to do it in.

## HTTP

### WebSocket support
**Status: complete.** Both tracks shipped:

- **One-shot**: `:ws.send` fires a single frame against a `.ws`
  JSON file (`{ url, message, timeout_ms?, headers? }`) and lands
  the reply in `[ws-response]`.
- **Persistent**: `:ws.connect` opens a `Pane::Websocket` with a
  live `tungstenite` worker, `[ws-<host>]` scratch log (`← text`
  in / `→ text` out), and `:ws.send_message` / `:ws.disconnect`
  companion commands. Multi-connection works: each `:ws.connect`
  spawns a fresh pane. `:ws.history` picker replays past
  connections from `~/.mnml/ws-history/<slug>/history.jsonl`.
- **Runtime knobs** (2026-07-03): `[ws]` config table —
  `subprotocols` (Sec-WebSocket-Protocol header), `ping_interval_secs`
  (default 30, 0=off), `reconnect_max_attempts` (default 3, 0=off,
  1s→2s→4s→8s→16s backoff).

Not planned: cookie-jar reuse on the upgrade handshake (mnml's
cookie jar is HTTP-only for now). Open a fresh ticket if there's
a specific workflow that needs it.

## Integrations

### GitHub Issues sibling (mnml-tracker-github)
**Shape:** a `mnml-tracker-*` sibling that mirrors the existing
`mnml-tracker-jira` + `mnml-tracker-linear` tools but for GitHub
Issues. Uses `gh api` under the hood (no new deps — the auth chain
that already backs `mnml-forge-github` reuses cleanly). Manifest
registers as `github_issues` (distinct from `github` forge chip).

Tabs: mirror the jira / linear shape — `Assigned to me`,
`Mentioned`, `Created by me`, plus configurable saved-search tabs
(e.g. by label / milestone / repo). Row Enter opens the console
URL; Enter on a body cell opens a scratch pane with the full
markdown for quick reference.

Sibling repo goes at `mnml-tracker-github` alongside the jira +
linear ones. Integration manifest registers `<leader>ig` chord for
"GitHub Issues: open". First-party family entry, not community.

## Other (uncategorized)

### Cloud agents list: compact vs standard view modes
**Status:** user request 2026-06-27 — current row UX feels guessy.

Today each cloud-agent row is one line: `▢ TE-NNNNN  state`.
With 14+ rows in a busy workspace, you can't tell what's what
without clicking through. User wants two view modes:

1. **Compact** (current) — one line per row, scannable list
   when there are many rows.
2. **Standard / expanded** — multi-line per row showing:
   ticket title (truncated), start time / duration, last log
   excerpt, current step / heartbeat. Enough to know what the
   run is doing without drilling in.
3. **Hover tooltip** (bonus) — even more detail when the user
   mouses over: full title, all metadata, retry count,
   parameters passed to the cloud run.

Persist the choice per-workspace in
`.mnml/cloud_agents_view.toml` so each project remembers.

Shape:
  - Toggle keybind on the cloud-agents panel (default `v`?).
  - Settings overlay row.
  - `src/ui/cloud_agents_panel.rs` already has the per-row
    rendering; add a `CloudAgentsView { Compact, Standard }`
    enum to App state + branch render accordingly.

### Cloud agents / Pty: tab strip should be per-split, not global
**Status:** caught 2026-06-27 — user reported "4 tabs" when
tailing two cloud runs.

Today: opening two Tail-logs flows creates two splits AND each
split's tab strip shows BOTH viewer buffers. Visually that's
"4 tabs" even though there are only 2 buffers in 2 splits.
The user's expectation is each split's tab strip shows only
the buffers IN that split.

Two paths:
  1. **Tab strip per-split scope** — render only the buffers
     attached to this split's tab group. Other buffers exist
     in other splits and aren't listed here. (Cleanest.)
  2. **Reuse existing split for similar opens** — clicking
     Tail logs a second time, when an existing cloudwatch
     viewer pane is open, route to that pane's split + open
     the new viewer as a TAB (not a new split). Both viewers
     visible in one split's tab strip; no second split.

Either path eliminates the "4 tabs" confusion. Path 2 is
more aggressive (changes pane-open routing); path 1 is just
UI scoping. Probably do both but path 1 first.

### + New Cloud Agent wizard — Jira source + Kepler-inspired UX
**Status:** Phase 2a shipped 2026-06-27 (`698bff3`) — GitHub PRs +
Bitbucket PRs + Manual prompt sources, Claude Agent SDK as the
agent, multi-select checkboxes, action templates. This entry
captures what's next.

**Jira "assigned to me" source** (user request 2026-06-27):
  - Auth: ATL_JIRA_TOKEN or ATL_JIRA_API_KEY env var + the
    user's already-set TATTLE_USER_JIRA_NAME for queries.
  - REST: `GET /rest/api/3/search?jql=assignee=currentUser() AND status not in (Done,Closed)`
  - Same multi-select + action template flow as PRs. Submit:
    spawn Claude with the ticket key in the prompt + git
    branch creation hint.

**Kepler-inspired enhancements (worth borrowing):**
  - **Task-centric model.** A "task" = work spanning multiple
    repos, originated from a PR OR a ticket. Sessions list
    shows tasks, not raw runs. Maps onto our cloud-agent rows
    nicely.
  - **Kanban-by-status.** Group rail rows: Needs Attention ·
    Active · Idle · Errored · Inactive (we already do partial:
    Action needed / Running / Done). Extend to match Kepler's
    five-bucket model.
  - **Agent-agnostic step.** Add an optional "Agent" step at
    the END of the wizard (defaulting to Claude). User can
    pick Codex / Open Code / future agents per-session.
    Different agents = different spawn commands but same
    submit shape.
  - **Bidirectional Console / redirect mid-session.** The
    CloudAgentRun pane could grow a small "send a message to
    the agent" textarea at the bottom (writes to the agent's
    stdin or session via SDK).

**Codex agent kind** (deferred, not urgent):
  - Spawn shape similar to Claude: `codex --print "<prompt>"`.
  - Auth via env (OPENAI_API_KEY or similar).
  - Same Action templates apply.

### + New Cloud Agent wizard — expanded scope (phase 2)
**Status:** v1 wizard scaffolding landed 2026-06-27 with the ECS runner + Claude managed paths. User then expanded the scope —
captured here for phase 2.

**New step structure (replaces the simple 2-agent picker):**

1. **Agent**: Claude Code · Codex · ECS runner · GitKraken
   Kepler · Keck (user clarification needed on the last two —
   are these distinct tools, or one product I'm missing?) ·
   Other (free-form binary).
2. **Source / trigger**: Assigned to me · Pick from PR list ·
   Pick from ticket list · Manual prompt.
3. **Multi-select** (when source is a list): checkbox list of
   PRs or tickets; the wizard fires one run per checked item OR
   one run per batch depending on the action.
4. **Action**: Triage · Review · Test · (custom suggestions —
   "Document", "Write tests", "Find regressions", "Update
   dependencies", etc).
5. **(Claude managed only) Sandbox**: Cloud · Self-hosted local
   · Self-hosted remote (Vercel/Cloudflare/Modal/etc).
6. **Review & submit.**

**Required new wiring:**
  - GitHub PR list per repo (use `gh pr list` or GraphQL).
  - Jira "assigned to me" list (REST API: `/rest/api/3/search?jql=assignee=currentUser()`).
  - Cloud-run ticket list (DynamoDB scan, wired in `ecs_runner.rs`).
  - Multi-select checkbox widget — generic, useful elsewhere.
  - Action templates per (agent, action) combo — these become
    the initial prompt sent to the agent.
  - Agent invocation per kind:
    - Claude Code: spawn `claude --resume`-style or
      `claude --new-session <prompt>` Pty pane.
    - Codex: `codex --new-session <prompt>` Pty.
    - ECS runner: existing `fire_cloud_run`.
    - GitKraken Kepler: need to investigate API.
  - For multi-select + batch: a "run N agents in parallel"
    fan-out flow with progress tracking.

### External tool install — htop, iftop, btop, …
**Status:** user request 2026-06-27 — `:tools.htop` currently
errors with "unknown command".

Today the install flow only handles `mnml-*` family siblings via
cargo. Want to extend to common terminal tools (htop, iftop, btop,
ncdu, lazygit, …) that ship via brew / apt. Same y/n prompt + Pty
install pane shape.

Shape:
  - New `src/external_tools.rs` with an EXTERNAL_TOOLS catalog —
    each entry: `id, binary, description, brew_name, apt_name,
    icon`.
  - `:tools.<id>` palette command (or `:install <id>`) routes
    through `install_external_tool` instead of `install_sibling`.
  - Install Pty runs `brew install <name>` on macOS, falls back to
    apt/dnf on Linux. Post-install auto-retry just spawns
    `:term <binary>`.
  - Surface in the Integrations Marketplace tab alongside family
    siblings — same picker UX.

Suggested initial catalog:
  - htop, btop, ncdu, lazygit, fzf, ripgrep, jq, yq, gh,
    tldr, bat, dust, watch, iftop, bandwhich

Why deferred: needs decisions on (a) catalog scope (where do we
draw the line between "useful tools" and "anything brew has"),
(b) Linux package-manager detection, (c) how the install flow
differs from cargo (brew is idempotent, apt needs sudo). Probably
needs a design doc + small PR per layer.

### Git-graph: repo dropdown + tighter sidebars
**Status:** captured 2026-06-27 — user request after looking at the
git-graph in `tattle-claude-workspace`.

Two complaints rolled into one entry:

1. **Repo selection dropdown at the top of the file browser
   panel** (left rail of the git-graph view). Currently shows the
   workspace name as plain text ("tattle-claude-workspace") right
   above the branch tree. In a multi-repo workspace
   (`[[workspaces]]` config + sub-repos discovered by
   `git::repos::discover_repos`), the user has to switch active
   repo via `:git.switch_repo` or the picker; not discoverable.
   Make the name itself the affordance — click → dropdown of
   discovered repos, select → switches the entire git-graph view
   (branches, commits, working-tree changes panel) to that repo.
   This is what GitHub Desktop / GitKraken / Tower all do.

2. **Tighten the left + right sidebars on git-graph**. The user's
   read on the proportions: left rail (LOCAL/REMOTE/WORKTREES
   tree) + right rail (WIP / Unstaged Files / Staged / Commit) are
   each ~25% of the viewport, center commit-list is ~50%. Pull
   both sidebars in by ~50-100px so the center commit message
   column gets more breathing room. The narrow center is the bit
   that's hardest to read — sidebars can spare the pixels.

Implementation sketch:
  - `src/ui/git_graph_view.rs` already lays out the three columns
    via ratatui constraints. Bump the centre weight (or set
    explicit min widths on the side columns instead of
    percentage-based).
  - For the dropdown: extend `App::repos` (already populated by
    `discover_repos`) and add a click-rect on the workspace-name
    row → opens a picker over the repos + the existing
    `switch_active_repo` accept handler.

### Multi-pane siblings (Mount or Pty)
**Status:** deferred 2026-06-26 — captured before it gets baked in.

Today: each Mount manifest = one Mount pane (one UDS, one render
loop). Each Pty profile = one Pty pane. A sibling that wants
multiple visual surfaces (main view + detail panel, dashboard +
log tail, …) has to either render both inside one pane (manual
internal split) or use the `OpenPty` tier-2 IPC to spawn a second
Pty as a side effect.

That's fine for today's single-pane siblings but won't scale to
richer integrations. Bake the multi-pane assumption into the
protocol now so we don't have to retrofit.

Shape (draft — discuss before coding):
  - Manifest gains `[[panes]]` array — each entry has its own
    `id`, `name`, `icon`, `color`, and an optional `mode`
    selector that mnml passes to the sibling on spawn
    (`--mode list`, `--mode detail`, etc.). Each entry registers
    its own activity-bar icon.
  - Clicking icon N spawns the sibling with `--mode <n.mode>` —
    or, if it's already running and the sibling registered itself
    for multiplexing, sends an "open pane" message over the
    existing UDS.
  - On the Pty side: a sibling can send a tier-2
    `OpenAdditionalPty { label, cmd, args, alongside? }` IPC to
    open companion panes that mnml tracks as related (e.g. closes
    them together if the user closes the parent).

Open questions: how does mnml know two panes are "the same
sibling" for status / cleanup purposes? Is it parent-PID, manifest
id, or a sibling-asserted group token? Keep cleanup safe under
crashes (sibling main pane dies, side panel becomes orphan).

### Pre-built sibling binaries (no bundling)
**Status:** deferred 2026-06-26. User explicitly chose NOT to
bundle siblings into mnml core ("the name is minimal — if the
ecosystem grows, mnml shouldn't gatekeep which integrations are
core enough to ship"). Compile time on first install (~30-60s)
remains the main UX cost; auto-retry (commit 9460403) covers the
"forgot to re-click" half of the pain.

Next step when ready: GitHub Releases with pre-built signed
binaries per sibling, served via `cargo-binstall` (or a mnml
built-in downloader). Reuse the same standard-tier runner set
mnml itself uses (audit 2026-06-26 — all five are free on public
repos):
  - macos-14 (Apple Silicon) — `aarch64-apple-darwin`
  - macos-15-intel — `x86_64-apple-darwin`
  - windows-2022 — `x86_64-pc-windows-msvc`
  - ubuntu-22.04-arm — `aarch64-unknown-linux-gnu`
  - ubuntu-22.04 — `x86_64-unknown-linux-gnu`

DON'T switch to `*-xlarge` or `*-large` runners — those are
paid even on public repos.

The existing `scripts/notarize-dmg.sh` cert plumbing
(`APPLE_DEVELOPER_ID_CERT_BASE64` env) can be reused per sibling
repo's CI workflow. ~15 min per repo to set up; 32 repos → ~8
hours mechanical work; ~$0/year ongoing.

Trigger: push-to-main publishes to a `main-latest` GitHub
release. `cargo-binstall` picks up the latest binary; no manual
tagging required, no forgotten-fix risk.

### Audit + re-tag siblings post-tmnl-protocol removal
**Status:** caught 2026-06-26 when a user `:install`-ed
`mnml-aws-cloudwatch-logs` and the build broke on a missing
`tmnl-protocol` workspace member. Pinned `cloudwatch_logs` to
`"main"` as a stopgap (see family_catalog.rs).

Background: 2026-06-22 we ripped tmnl-protocol out of every
sibling repo (mnml became terminal-agnostic — see commit
ce99b59 / memory). Most sibling repos still have tagged
releases (v0.1.0, v0.2.0, …) that predate the removal and
reference `tmnl-protocol` as a path/workspace dep. `cargo
install` on those tags fails immediately.

Required work (per sibling, ~30 to audit):
  1. In each `mnml-*` repo's main branch, verify the workspace
     Cargo.toml no longer lists `tmnl-protocol`
  2. If it still does, remove it + bump the version
  3. Tag a new release (v0.1.1 / v0.2.1 / etc.)
  4. Bump that sibling's `pinned_version` in
     family_catalog.rs back from `"main"` to the new tag

Easier in parallel — agent-able. Each sibling repo is small;
the fix per repo is mechanical.

Why deferred: cross-repo coordination + ~30 small PRs. The
stopgap (pin → main) works for users who hit it one-off.

### In-app icon designer for siblings + integrations
**Status:** deferred 2026-06-26 — user asked for it.

Today: each `family_catalog::FamilySibling` (35+ entries) carries
a hand-picked Nerd Font glyph as its activity-bar / rail icon.
Picking generic Nerd Font glyphs for real-company products
(AWS Lambda → rocket, Datadog → dog, Stripe → card…) looks
random and slightly off-brand. We already shipped one-off
custom icons for Claude Code + Codex that the user actually
liked. Want to generalize.

Shape: user drops an image (PNG/SVG) on the rail/integrations
overlay or runs `:icon.create <integration-id>`. We:
  1. Open a designer pane that lets the user crop, threshold,
     and scale the image into a 16×16 / 24×24 monochrome grid
     (one cell per terminal cell).
  2. Either embed it directly as a Sixel/Kitty graphics fragment
     in the rail row (when the terminal supports it — we already
     have this code path for image preview) OR encode it as a
     custom-glyph entry in `~/.config/mnml/icons/` that the rail
     renderer prefers over the Nerd Font fallback.

Why deferred: needs decisions on (a) image → glyph algorithm
(otsu threshold? edge-detect? user-painted?), (b) rendering
substrate (Sixel vs. Kitty vs. precomputed font slots), and
(c) how the user-stored icon overrides the catalog default.
Don't build until shape is settled — a half-done image flow
is worse than just keeping the Nerd Font icons.

Pick up when the user has a few hours and an integration whose
current glyph annoys them enough to drive the design.

### ~~HTTP: drop non-dirty "new request" tab on navigate-away~~
**Shipped 2026-07-09.** `set_activity_section` in `layout.rs`
now marks the auto-opened Request pane `is_preview = true`
and closes any preview Request pane on leaving HTTP. First
edit promotes to a permanent tab (existing
`tui/handlers/pane.rs` promotion path handles this). 3 unit
tests (`entering_http_opens_...`, `leaving_http_drops_...`,
`leaving_http_keeps_promoted_...`).

### ~~TODOs panel: 1-cell padding between rescan icon and label~~
**Verified stale 2026-07-09.** Audit: `todos_panel.rs:266`
renders `"⟳  Rescan"` with a 2-space gap (intentional —
comment on-site explains `⟳` eats its right sidebearing in
Nerd Font). HTTP panel refresh chips use icon-only codicons
(no adjacent label to kiss). Notes panel has no Rescan chip.
No `⟳` + adjacent word without a gap remains in the tree.

### ~~TODOs panel: add `/` filter row (parity with HTTP / Agents)~~
**Shipped 2026-07-09.** `todos_panel_filter` state + filter row
render + `/`-focus keybinding + click-to-focus + click-outside-
to-unfocus. Header shows `(N of M hits)` when active. Matches
tag, path, or title case-insensitively.

### ~~TODOs panel: pick up `.fail` markers in Playwright workspaces~~
**Shipped 2026-07-09.** Playwright test files (`.spec.ts` /
`.test.ts` / `.spec.js` / `.test.js`) now get an extra scanner
pass that picks up `.fixme(` / `.fail(` / `.skip(` call-site
tokens. Mapped to FIXME / XXX / REVIEW respectively; the test
title (first quoted string in the call) becomes the entry
text. Non-test files still use the comment-only path.

### ~~Notes panel: add `/` filter row~~
**Shipped 2026-07-09.** Same idiom as TODOs above — filter row,
`/` to focus, Esc clears + unfocuses. Matches note file names
case-insensitively. Header shows `(N of M)` when active.

### ~~Notes panel: `+ New note` chip is a no-op~~
**Verified 2026-07-09.** Handler works — creates
`.mnml/notes/note-N.md`, refreshes the panel, opens as an
MdPreview pane. Locked in by 2 unit tests
(`notes_new_note_tests` in `src/app/workspace_methods.rs`).
The original report was stale; whatever regressed it was fixed
in a prior session and no follow-up was needed.

### ~~Tab bar: add Claude Code + Codex launcher icons~~
**Shipped 2026-07-09.** Bumped the `[ui] tab_bar_ai_icon`
default from `"none"` to `"both"` — every leaf's tab strip now
shows Claude Code + Codex chips left of the terminal glyph:
`[Claude][Codex][$][⊟][⊞]`. Chips were already implemented
and the click handler already routes to
`ai.claude_code_new` / `ai.codex_new`; only the default
needed flipping. Users can still opt out with `tab_bar_ai_icon
= "none"` (or `"claude_code"` / `"codex"` for one only).

### ~~Tab bar: right-click on AI launcher chip → placement menu~~
**Status:** captured 2026-07-08 user request.

Extend the far-right cluster of icons on the per-leaf tab
strip (currently `$` terminal / `⊟` split-vert / `⊞`
split-horiz) with two more chips positioned IMMEDIATELY LEFT
of the terminal glyph:

  [ Claude Code ] [ Codex ] [ $ ] [ ⊟ ] [ ⊞ ]

Click → spawn a fresh Claude Code / Codex session (mirrors
existing `ai.claude_code_new` / `ai.codex_new` commands) in
the current leaf.

Reuse the existing `tab_bar_ai_icon` config knob that already
gates `"claude_code"` / `"codex"` / `"both"` variants — but
this is asking to make BOTH visible unconditionally on the
tab bar, i.e. bump the default from `"none"` (current) to
`"both"`, or add a new `[ui] tab_bar_ai_launchers = true`
switch.

**Shipped 2026-07-09 (halves only).** Right-click on either
tab-strip AI chip opens a context menu:

    Claude Code launcher
      Open new Claude Code session (right dock)
      Toggle existing Claude Code pane
      Place new session in left half
      Place new session in right half
      Place new session in top half
      Place new session in bottom half

The chip's Claude/Codex kind is picked up from the `tag` field
already on `split_strip_ai_buttons`; the menu is symmetric.

New `crate::app::ai::PanePlacement` enum + `open_*_at`
methods. 8 palette commands registered
(`ai.claude_code_new_left/right/top/bottom`, ditto Codex) so
users can bind them to chords too.

**Deferred: quarters** (Top-left / Top-right / Bottom-left /
Bottom-right). Would need recursive split (horizontal split →
then vertical split on the chosen half → then move the new
pane into position). Not enough demand vs. drag-drop parity to
land in this pass.

### HTTP: dynamic + realistic request generation (roadmap)
**Status:** roadmap captured 2026-07-09. User wants stubs that
are "as dynamic and realistic as possible" — not just cleaner
sync diffs but genuinely usable ready-to-fire scaffolds. A
`↻ Regenerate` button on the Request pane rerolls example data
for repeated sends without manual editing.

**Tier 1 — dynamic value substitution (deterministic sync).**
`--normalize` flag on `mnml discover` / `mnml sync` /
`mnml sync-check` + palette `[http] sync_normalize = true`.
When on:
- ISO 8601 timestamp strings → `{{$timestamp}}`.
- Lowercase UUIDs → `{{$uuid}}`.
- Numeric ID fields where the name suggests randomness
  (`orderId` as int, `requestId`) → `{{$randomInt}}`.
Not substituted: date-only strings, epoch integers, uppercase
UUIDs — too many false positives.
Impact: swagger-side timestamp/UUID churn (117 files/sync on
tattle-mnml-workspace) drops to zero.

**Tier 2 — property-name-keyed faker vocab.** Small
`src/http/faker.rs` module. When schema-synthesis has a
`type: "string"` field with no example, look up the property
name and emit a realistic value instead of `"string"`:
- `firstName`/`givenName` → `"John"`
- `lastName`/`familyName`/`surname` → `"Smith"`
- `emailAddress`/`email` → `"user@example.com"`
- `phoneNumber`/`phone` → `"555-0100"`
- `city` → `"San Francisco"`
- `zipCode`/`postalCode` → `"94105"`
- `countryCode` → `"US"`
- `currency` → `"USD"`
- `merchantId`/`userId`/`accountId` → `{{MERCHANT_ID}}` etc
  (env-var references, not literal ints)
Similar heuristics for integer / enum types:
- `quantity` / `count` → `1`
- `price` / `amount` → `9.99`
- Enum: prefer "active"-like values over "deactivated" /
  "archived" / "cancelled" (skip words with `-ed` suffix
  and negative prefixes when possible).

**Tier 3 — coherent object graphs.** Cross-field consistency
within a single body:
- `firstName` + `lastName` on the same object → matched pair
  ("John" + "Smith", not two independent picks).
- `orderPlacedUtc` + `orderCompletedUtc` → picked ~30 min apart.
- `amount` + `currency` + `total` → math still works out.
- `email` matches `firstName.lastName@example.com` when both
  are on the same object.

**Tier 4 — well-known env-var relations.** Cross-request
consistency:
- Path params `{{merchantId}}` in URL, body, query all map to
  the same `MERCHANT_ID` env var (not three independent
  templates).
- Ship `.mnml/env/dev.env.example` with the common vars
  pre-seeded: `MERCHANT_ID=`, `USER_ID=`, `LOCATION_ID=`,
  `BASE_URL=`.

**Tier 5 — query params + headers from swagger `parameters`.**
Currently only path params are templated; query and header
params from swagger are silently dropped.
- Required query params → `?filter={{filter}}` appended to URL.
- Optional query params → commented-out `# ?filter=<value>`
  hint below the curl line.
- Header params → `-H '<name>: <example-or-template>'` in the
  header block.

**Tier 6 — auto chain generation + extract hints.**
- `POST /*/auth/login` stubs get a comment
  `# extract: TOKEN=$.access_token` documenting how a chain
  should pull the token.
- Endpoints returning `{ id: ... }` in the response schema
  get `# extract: LAST_ID=$.id`.
- Per-tag starter chains: `.mnml/chains/orders.chain.json`
  auto-generated as `login → create → get → update → delete`
  when the API surface has all four verbs on a resource.

**Tier 7 — happy-path + edge-case variety.** Optional flag
`--edge-cases` generates a `<base>.happy.curl` +
`<base>.edge.curl` pair for each operation. Happy = default
faker values. Edge = empty strings, min/max values, boundary
enum values. Skip unless requested.

**`↻ Regenerate` button on the Request pane.** Companion to
tiers 1-3. Chip on the Request block header (near `{ } Format`
and `↺ Refresh`). Click → walks the body, finds anything that
LOOKS like a dynamic value we could have generated (via the
same detection Tier 1 uses), and rerolls with fresh randoms.

Rules:
- Timestamps: new `now()` UTC.
- UUIDs (lowercase, standard shape): new `uuid_v4()`.
- Faker-vocab strings (matched against the small dictionary
  from Tier 2): pick a new value from the same category the
  original was in. E.g., `"John"` gets replaced by another
  first name, not by a city.
- Numeric IDs the tier-1 substitution would have caught: new
  randints in the same range.
- Do NOT touch: strings that don't match any known pattern
  (probably user-authored), literal `{{$uuid}}` / `{{$timestamp}}`
  templates already in place (those resolve at send anyway),
  path parameters, headers.

Right-click on the chip → menu:
- Regenerate all (default click behavior)
- Regenerate timestamps only
- Regenerate UUIDs only
- Regenerate faker fields only
- Convert to `{{$dynamic}}` templates (opposite direction —
  turn the concrete values back into placeholders so every
  send is fresh without a click).

Palette: `http.regenerate_body`, `http.convert_to_dynamic`.

**Practical sequence (recommended):**
1. Tier 1 — small, unblocks clean git history immediately.
2. Tier 5 — real feature gap; query/header params make stubs
   actually usable.
3. Tier 2 — big usability jump; scoped to one new module.
4. Regenerate button — depends on Tier 1 detection rules.
5. Tier 4 — cross-request consistency; env-var convention.
6. Tier 6 — auto chains; where mnml gets ahead of Postman/Bruno.
7. Tier 3 — polish on top of Tier 2.
8. Tier 7 — diminishing returns; skip unless requested.

### Activity sidebar: add / remove integrations from the UI + right-click menus
**Status:** captured 2026-07-09 user request. "todo add integrations
to the activity sidebar and removing. should probably also be in
right click menus to edit or remove. iterate as much as needed i
dont want to lose functionality."

Current shape:
- Integrations live in `.mnml/integrations/<id>.toml` (workspace)
  or `~/.config/mnml/integrations/<id>.toml` (user).
- The Integrations section on the activity sidebar reads
  `App::config.ui.integration_icons` at render time.
- Adding one today: manually author the TOML, then
  `:integrations.refresh` to pick it up.
- Removing: `:integration.uninstall <id>` OR delete the file
  and refresh.

What's missing (surface-level ergonomics):

**1. `+ Add integration` chip at the bottom of the section.**
Click → opens the marketplace picker (fuzzy over
`family_catalog::CATALOG` + community manifests). Accept →
downloads the sibling manifest, writes the TOML, refreshes.
Same install flow as `:sibling.install` but reachable without
palette-hunting.

**2. Right-click menu on any Integration chip.**
- Edit config (opens `<id>.toml` in an editor pane)
- Toggle enabled (mirrors `:integration.toggle_enabled`)
- Uninstall (with confirm)
- Copy id to clipboard
- View sibling repo (if the manifest has a `homepage` field)
- Show in Finder (macOS) / File Manager

**3. `- Remove` chip visible on hover.**
Same idiom as HTTP-panel CAPTURED clear chip — an `×` that
appears on the chip when the mouse is over it. Click → confirm
prompt → remove.

**4. Reorder via drag.**
Chips accept vertical drag-drop; the ordering persists to a
new `[ui] integration_order = ["id1","id2",...]` config key.
Users who install 15 siblings currently can't reorder the
common ones to the top.

**5. Import from URL / paste manifest.**
`+ Add integration` menu also offers "paste manifest…" — a
prompt where the user pastes a TOML block. Saves to
`.mnml/integrations/<id>.toml` after basic validation.
Same shape as `+ New env` / `+ New chain` prompts already in
the HTTP panel.

Non-goals (deliberately):
- In-app manifest EDITOR (grid / form). Config TOML in an editor
  pane is fine — text is the canonical source.
- Marketplace ratings / reviews. Local package management, not
  a curation portal.

Preserve functionality — the palette commands stay reachable
(`:integration.install`, `:integration.uninstall`,
`:integration.toggle_enabled`, `:integrations.refresh`) so
scripts and IPC callers don't break. UI adds are additive.

### HTTP: discover should expand `requestBody.content.*.examples` (map)
**Status: DONE 2026-07-09** — shipped in the same session.
`src/http/discover.rs` now handles `.examples` map expansion +
schema synthesis (ports both from `archived/rqst/src/discover.rs`).
Tests added:
`named_examples_map_expands_to_one_file_per_example`,
`schema_synthesis_fills_body_when_no_example_provided`,
`schema_synthesis_resolves_local_refs_and_survives_cycles`.

Historical note (why the entry existed):

Current: `src/http/discover.rs` handles `requestBody.content.
"application/json".example` (SINGULAR — one example → filled
into the stub body). Explicitly does NOT handle the plural
`examples` (map of named examples).

Impact on tattle workspace:
- `tasks-api` swagger: 2 real operations, but `POST /admin/event`
  has 219 named `examples`. Old rqst tool expanded that map into
  203 `TriggerEvent.<eventName>.curl` files (one per event
  type). Users navigated by event name via `Ctrl+O`.
- `integrations-api`: 247 operations, 1 with a 133-entry
  `examples` map. Existing 372 stubs = 247 + ~125 example
  expansions. New discover generates 247, so ~125 are
  effectively lost.

Fix shape:
- After emitting the "one stub per operation" default,
  iterate `requestBody.content.<mime>.examples` for each
  operation.
- For each `(name, example)` pair:
  - Emit an extra stub at `<tag>/<operationId>.<name>.curl`
    (or nested subdir `<tag>/<operationId>/<name>.curl`).
  - Fill the body with the named example's `.value` field.
- Add an `Options.expand_examples: bool` flag (default `true`)
  so users can opt out for surface-only discover.
- README the new file-count expectation.

Naming clash: existing tattle stubs use `TriggerEvent.<name>.curl`
where TriggerEvent is the operationId. That's the same pattern
the new expansion should produce. Keeps 1:1 filename parity
with the old rqst tool → `mnml sync-check` becomes a clean
"real drift" report on tattle workspaces.

Related: `mnml sync-check` (shipped 7b3dff9 / 4f3c4f6) currently
misreports 1959 files of drift on tattle-mnml-workspace almost
entirely because of this feature regression. Once expansion is
back, the drift number will collapse to actual API changes.

### ~~HTTP: "Generate AI prompt" button on failed requests~~
**Shipped 2026-07-09.** `⚡ AI` chip on the Response tab strip
(only when the response is a failure — non-2xx status,
schema-invalid, or transport error) copies a structured
markdown prompt to the system clipboard. New palette command
`http.copy_ai_prompt` for the same action. Hover tooltip
explains the redaction. Prompt structure:

    ## Request
    METHOD URL
    Headers (Authorization / *api-key* / Cookie / *secret*
      redacted; scheme kept: `Bearer <redacted>`)
    Body (truncated to 2KB with a marker if longer)

    ## Response
    HTTP <status>  (elapsed: <ms>ms)
    Headers + Body (2KB cap)

    ## Env / context
    - active env: <name>
    - defined vars used: …
    - undefined vars: …

    ## Schema validation
    - <errors>

    ## What I've tried
    (fill me in)

New module `src/http/ai_prompt.rs` — 8 unit tests (redaction
variants, truncation, env-var classification, failure state
detection). Right-click menu variants (Open in AI pane,
Save to `.mnml/ai-prompts/`) not shipped yet — plain click
covers the 90% case; extend later if the need surfaces.

Original spec preserved:

When a Request pane's response is a failure — non-2xx status,
schema validation error, connection error, timeout — surface a
one-click chip that copies (or opens) an AI-ready prompt with
all the details a coding assistant would need to help debug.

Shape of the generated prompt:

    I'm hitting an error on this HTTP request. Help me figure
    out why.

    ## Request
    METHOD URL
    (headers, with sensitive values redacted)
    (body)

    ## Response
    HTTP <status>  (elapsed: <ms>ms)
    (headers)
    (body — pretty-printed if JSON, capped at ~2KB with a
    `…truncated` marker)

    ## Env / context
    - active env: <name>
    - defined vars used: <list of {{VARS}} that were substituted>
    - undefined vars: <list of {{VARS}} that stayed literal>

    ## Schema validation (if a .schema.json sidecar exists)
    <the errors from schema_result>

    ## What I've tried
    (blank — for user to fill in)

Where the button lives:
- Response block header, right of the `copy` / `wrap` chips.
- Only shown when `RunState::Done` has status ∉ [200, 300) OR
  `schema_result` has errors OR `RunState::Failed`.
- Label: `⚡ AI` or `? AI prompt` (nerd glyph + short label).

Two flavors of click:
1. **Plain click** — copy the prompt to the clipboard, toast
   "prompt copied — paste into Claude / Codex".
2. **Right-click** — menu:
   - Copy to clipboard
   - Open in a new AI pane (spawns `ai.claude_code_new` /
     `ai.codex_new` with the prompt pre-filled)
   - Save as `.mnml/ai-prompts/<timestamp>-<method>-<url-slug>.md`

Also add ex/palette variants:
- `http.copy_ai_prompt` (palette)
- `http.ask_ai_about_failure` (opens AI pane with prompt)

Sensitive-value redaction: any header whose key matches
`(?i)authorization|api[_-]?key|token|cookie|x-.*-secret` gets
its value replaced with `<redacted>`. Same rule for body fields
that LOOK like tokens (Bearer-length strings, JWT shape).

Reason this beats "just paste the whole tab": the prompt is
structured for AI parsing, keeps the important context, and
strips secrets so users don't leak credentials into their AI
provider by accident.
