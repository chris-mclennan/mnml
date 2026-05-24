# Blit-host integrations — design briefs

Planning doc for the next round of blit-host integrations (the third
class of integration — see [`docs/PLUGINS.md`](PLUGINS.md)). This is
**design-only** — no commitments to implementation timelines. Each
section describes the shape of a *prospective* blit-host binary that
mnml would host via `:host.launch <binary>` (or via a launcher-icon
chip in the bufferline).

## What's a blit-host binary?

Recap from PLUGINS.md: an out-of-process program that owns a pane and
renders into it via `tmnl-protocol` over a Unix socket
(`<binary> --blit <socket>`). It can ship any deps, present any UI,
and hold any state — mnml just paints the cells it sends and forwards
input back. The contract:

| Required wire messages | Direction | Purpose |
|------------------------|-----------|---------|
| `Hello { version }`    | server→client | mnml greets the child on connect |
| `Resize { cols, rows }`| server→client | initial pane size + on every resize |
| `Palette { bg, fg, accent }` | server→client | mnml's active theme |
| `Input(KeyInput \| MouseInput)` | server→client | key + mouse events |
| `Quit`                 | server→client | mnml is shutting down |
| `Frame { runs, cursor }` | client→server | the child's rendered cells |
| `Title { text }`       | client→server | the pane's tab title |

The child binary owns its own:

- **Deps** (database driver, REST client, etc.) — nothing leaks into
  mnml's `Cargo.toml`.
- **Auth** (env vars, config files, OS keyring) — picked from where
  the user already keeps them; mnml doesn't proxy.
- **Persistent state** (cached results, last-opened collection,
  cursor positions) — in `~/.cache/<binary>/` or a per-workspace
  override.

## Common UX patterns

The three integrations below share a small set of UI primitives. Each
binary should pick from them rather than reinvent — keeps everything
visually consistent inside mnml.

### List + detail split

The dominant pattern — left column is a scrollable list of items
(rows, tickets, runs), right column shows the focused item's details.

```
┌─ items ──────────────────────┬─ detail ──────────────────────┐
│ ▶ #4521 fix auth middleware  │ #4521 — Open                  │
│   #4519 update README        │ Author: alice                 │
│   #4517 refactor cache       │ Branch: feature/auth → main   │
│                              │ ───                           │
│                              │ Description text here…        │
└──────────────────────────────┴───────────────────────────────┘
```

Sizing: left ~40%, right ~60% (configurable). `Tab` swaps focus.
`↑↓ jk` move within list. `Enter` opens the canonical action
(launch in browser, run query, etc.). `Esc` returns focus to mnml's
tree.

### Header chrome

Top row: a 1-line header strip with status chips (connection state,
record count, last-refresh time). Painted on `bg_dark`, glyphs in the
palette's `accent` color. The mixr panel and the AWS CodeBuilds pane
both already follow this shape; reuse it.

### Bottom hint bar (optional)

Single-line keymap hint at the bottom of the pane (`Enter` open ·
`y` copy · `r` refresh · `Esc` tree). Costs one row; can be
configurable per binary.

### Fuzzy filter

A single keystroke (`/`) opens a 1-line input above the list; typing
filters the list in real time. Mirrors mnml's command palette behavior
so the muscle memory transfers. Cancellable with `Esc`.

---

## 1. Database viewers

**Goal:** browse / query relational + key-value databases from a pane.
One binary per backend — each is its own dep tree.

### Prospective binaries

| Binary | Crate(s) | Auth |
|--------|----------|------|
| `mnml-db-postgres` | `sqlx` or `tokio-postgres` | `PGUSER`/`PGHOST`/`PGPASSWORD` env vars OR `~/.pgpass` OR config-supplied `DATABASE_URL` |
| `mnml-db-mysql`    | `sqlx` or `mysql_async`    | `MYSQL_*` env vars OR `~/.my.cnf` OR config-supplied URL |
| `mnml-db-redis`    | `redis-rs`                 | `REDIS_URL` env var |
| `mnml-db-sqlite`   | `rusqlite`                 | path to `.sqlite` file as binary arg |

### UI shape (per binary)

1. **Connection screen** (first frame). List of saved connections (from
   the binary's own config). Enter on a row connects + jumps to (2).
   `n` starts a "new connection" form.
2. **Schema browser**. Tree of `database → schema → table/key-prefix`.
   Selecting a table or namespace updates the right pane to (3).
3. **Row / value viewer**. Tabular view of recent rows (LIMIT 100 by
   default) or a Redis key's value. Status chips show row count +
   truncation indicator.
4. **Query editor** (`q` toggles). Single-line at the bottom for ad-hoc
   `SELECT` / `EXPLAIN` / `GET` / `LRANGE` etc. Results replace the row
   viewer body.

### What lives in the binary

- Connection pooling (each binary picks one based on its crate).
- Query history (per workspace).
- Result paging + result-set virtualization (don't try to render 1M
  rows; show LIMIT N + a "fetch more" affordance).
- Type-specific formatting (Redis: list-vs-hash-vs-zset; Postgres:
  JSON/JSONB/arrays; MySQL: ENUM/SET).

### What lives in mnml

- The `:host.launch mnml-db-postgres` launcher (config-driven via
  `[[ui.launcher_icon]]`).
- Theme handoff (already in the protocol).

### Open questions

- Should the binaries be one-per-engine or one binary with a
  `--engine` flag? Per-engine is cleaner (each has its own deps); one
  binary's nice for distribution. Probably per-engine — `cargo install
  mnml-db-postgres` is a clearer install line.
- Should `EXPLAIN ANALYZE` results render as a tree visualisation?
  Bonus feature; not v1.
- "Open this query as a file" — should the binary be able to ask mnml
  to drop its current query into a new editor tab? Would need a new
  `Message::OpenEditor { path? }` in the protocol. Defer until v2.

---

## 2. Ticket viewers

**Goal:** browse your team's issue tracker (Linear / Jira / GitHub
Issues / GitLab Issues) without leaving the editor. One binary per
service.

### Prospective binaries

| Binary | API | Auth |
|--------|-----|------|
| `mnml-tickets-linear` | Linear GraphQL | `LINEAR_API_KEY` env var |
| `mnml-tickets-jira`   | Jira REST v3   | `JIRA_BASE_URL` + `JIRA_EMAIL` + `JIRA_API_TOKEN` env vars |
| `mnml-tickets-github` | GitHub REST    | `GITHUB_TOKEN` env var (already used elsewhere in mnml) |
| `mnml-tickets-gitlab` | GitLab REST    | `GITLAB_TOKEN` env var |

### UI shape

List + detail split. Left column: tickets the user owns / is assigned
to / has commented on (configurable via the binary's own filter
config). Right column: ticket detail (description, comments,
status, labels, linked PRs).

Default view: "what's on my plate today" — issues assigned to me,
open, sorted by recency. `g` cycles views (mine / project / cycle /
filter).

### Key bindings (consistent across all four binaries)

| Key | Action |
|-----|--------|
| `Enter` | open ticket in browser |
| `y` | copy ticket URL |
| `r` | refresh list |
| `c` | new comment (opens single-line input) |
| `s` | change status (small dropdown overlay) |
| `Tab` | swap focus list ↔ detail |
| `/` | filter |
| `Esc` | back to mnml's tree |

### What lives in the binary

- API client (GraphQL for Linear, REST for the others).
- Token storage (env var first; fall back to per-binary keyring).
- Cache (last-fetched list survives panel reopens).
- Optional polling for new tickets (toast on arrival).

### What lives in mnml

- Launcher icon per service (config).
- The `:host.launch mnml-tickets-linear` command line.

### Open questions

- Cross-cutting: when a user clicks a file/line reference inside a
  ticket description, can the binary ask mnml to open it? Same
  `Message::OpenEditor` extension as the database viewers. Defer.
- Multiple Linear/Jira workspaces — one binary instance per workspace
  (multi-tab) or one instance per workspace (multiple
  `:host.launch`)? Probably the latter — keeps each binary stateless
  per-instance.

---

## 3. Playwright runner integration

**Goal:** unclear — mnml already has Playwright integration
(`Pane::Tests`, `Pane::Trace`, `Pane::Flaky`). A blit-host binary
would need a different purpose.

### Three candidate interpretations

1. **"Richer test-results browser"** — A pane that wraps `npx
   playwright test --reporter=json` and renders results live. Status
   chips per test (pass/fail/flaky/skip), grouping by file/suite,
   timeline view of test durations, "rerun this test" affordance. May
   be redundant with the existing `Pane::Tests`; the value-add would
   be richer grouping/filtering than mnml's built-in pane.

2. **"CI test-results aggregator"** — A pane that aggregates results
   *across runs* (last 7 days of CI). Connects to CI providers
   (CodeBuild logs, GitHub Actions artifacts, Bitbucket Pipelines)
   and displays trend lines for each test. Useful for spotting flaky
   tests, regression sources, slowness. Closer to the deleted the private integration
   `TestExecutions` UI in spirit.

3. **"Trace-viewer overhaul"** — A pane that parses Playwright's
   `trace.zip` into an interactive timeline (network, console,
   action steps). Today mnml has `Pane::Trace` (text timeline); a
   blit-host binary could go richer (per-action screenshots,
   network waterfall).

### Decision needed

User flagged this as a planned integration but didn't specify which
interpretation. **Default assumption (1)** unless redirected: the
results browser. If (2) is the intent, scope balloons (CI provider
integration is itself a multi-week project — and overlaps with what
the AWS CodeBuild pane already does for one provider).

Recommend: pick (1) for v1. Can grow into (2) once the binary exists.
(3) is a separate side-project that doesn't need a blit-host
binary — it could be a Cargo feature in mnml itself if it grew that
much.

---

## Build / distribution

Each binary is its own crate. Two distribution paths:

1. **Public on crates.io.** `cargo install mnml-db-postgres`. Users
   choose which binaries to install. Simple, follows the unix-toolchain
   pattern.
2. **Bundled mnml plugin pack.** A separate `mnml-plugins` crate that
   depends on all of them and exposes one install line. Convenient,
   but pulls every binary's deps into the user's machine even if
   they don't use them.

Probably **(1)** — keeps mnml's "install just what you need"
philosophy. The launcher-icon strip already supports per-user
opt-in via config.

## Build order recommendation

If implementing in sequence:

1. **`mnml-db-postgres` first.** Validates the blit-host integration
   class end-to-end (real database, real deps, real query loop). The
   shape generalizes to MySQL/SQLite easily.
2. **`mnml-tickets-github` second.** GitHub auth is already wired
   into mnml (`GITHUB_TOKEN`); the API surface is well-documented.
   Validates the "ticket viewer" pattern.
3. **`mnml-tickets-linear` / `mnml-tickets-jira` after.** Same shape
   as GitHub; copy-paste-modify.
4. **`mnml-db-mysql` / `mnml-db-redis` / `mnml-db-sqlite` after.**
   Same shape as Postgres; copy-paste-modify.
5. **Playwright runner last.** Interpretation needs locking before
   anyone starts.

Each is its own multi-day project. The infrastructure is ready
(Phase 2's `pane_host` + Phase 37's launcher-icon config); the
binaries are the actual work.
