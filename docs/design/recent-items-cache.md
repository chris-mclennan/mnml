# Recent-items cache

Status: design, not built. Examples use invented data (`ACME-123`,
`acme/widget`); nothing here comes from a real site.

## Why

Every integration knows the items it last polled and keeps that to
itself. Jira's `<data root>/cache/jira/` holds `dev-status.json` (an
`sdk.Store` of response bodies) and `sync.json`; Bitbucket's
`<config dir>/cache/link-ranges.json` holds number watermarks it
publishes over IPC. No titles anyone else can read. So the host links
`ACME-123` and `widget#45` (`src/app/link_rules.zig`) with an address
and a menu but no title, and a private loops pane fell back to a
prefetch file the Rust app used to write, which nobody writes now.

The fix is one shared, read-anywhere store of what the integrations have
recently seen, filled as a side effect of polls they already make.

## 1. Scope

Four kinds of item, each a small fixed record:

| kind       | id                    | fields |
|------------|-----------------------|--------|
| `ticket`   | `ACME-123`            | summary, status, status_category, assignee (display name), priority, type, fix_versions[], updated |
| `pr`       | `acme/widget#45`      | title, source_branch, dest_branch, author (display name), state, draft, updated |
| `pipeline` | `acme/widget!1234`    | state, result, ref_name, created, updated |
| `release`  | `ACME/2026.10`        | name, project, state (`unreleased`/`released`/`archived`), release_date, role (`current`/`next`/``), keys[] |

The id is what a link rule already matches, so the host looks an item
up with text it has in hand. `!` for pipelines keeps the two numbering
spaces apart in one id grammar.

Deliberately out:

* Bodies: descriptions, comments, diffs, logs, custom fields, the raw
  issue. A title is enough to label a link; a body is a second copy of
  the server that has to be kept honest.
* Account ids, emails, avatars. Display names only.
* Anything the integration did not already fetch for its own reasons.
  The cache never causes a request.
* Writes back to a server. The cache is read-only knowledge.
* Search across sources ("every item mentioning X"). `query` filters on
  the fixed fields; it is not an index of text.

## 2. Where it lives and its shape

Directory, resolved like the rate bucket (`sdk/mnml-sdk/src/ratelimit.zig`
`statePath`), so every process on the machine agrees on it:

1. `$MNML_SHARED_STATE_DIR/recent/`
2. `<MNML_DATA_ROOT>/recent/`
3. `~/.config/mnml/recent/`

One file per source and kind: `recent/<source>/<kind>.json`, e.g.
`recent/jira/ticket.json`, `recent/bitbucket/pr.json`. Whole-file JSON,
not JSON-lines and not SQLite:

* **Not SQLite:** no dependency today, a C build on three targets (core
  is `windows-gnu`) for a few thousand rows.
* **Not JSON-lines:** duplicates until a compaction, which is a rewrite
  anyway; every reader folds every line.
* **Not ZON:** anything should read it — a shell loop, a pane in
  another language. The directory's other shared files are JSON.
* **One file per source and kind:** Jira never contends with
  Bitbucket, and a bad write costs one kind of one source.

Shape:

```json
{"version":1,"source":"jira","kind":"ticket",
 "fresh_at":1791100000,"error_at":0,"stale_after_secs":1800,
 "records":[
  {"id":"ACME-123","seen_at":1791100000,"stale":false,"listings":["assigned_open"],
   "summary":"Fix the login redirect","status":"In Review","status_category":"indeterminate",
   "assignee":"Pat Example","priority":"High","type":"Bug",
   "fix_versions":["2026.10"],"updated":"2026-10-01T09:12:00.000+0000"}
 ]}
```

`fresh_at` is the last successful poll; `error_at` the last failed one
(newer than `fresh_at`: running but cannot reach the server);
`stale_after_secs` the writer's poll interval doubled; `seen_at` when
the record last came back from the server.

The index is the directory listing plus an in-memory map each reader
builds (kind + id → record) when a file's mtime moves. A separate index
file would be a second thing to keep atomic for no gain at this size.

**Eviction**, applied on every write, oldest `seen_at` first:

| kind       | keep                                   | max age |
|------------|----------------------------------------|---------|
| `ticket`   | 1000                                   | 30 days |
| `pr`       | 500                                    | 30 days |
| `pipeline` | 20 per repo                            | 14 days |
| `release`  | every `current`/`next` (pinned) + 20   | none for pinned, 180 days otherwise |

Size bound: 2 MiB per file; a write that would pass it drops the oldest
unpinned records until it fits. Readers refuse a file over 4 MiB (the
same "a cache is a hint" rule `sdk.Store` follows: a bad file reads as
empty, never as an error).

## 3. Writers

The integrations, and only the integrations. One SDK module,
`sdk.cache` (`sdk/mnml-sdk/src/cache.zig`), separate from `sdk.store`:
`store` is a private body cache keyed by the server's stamp; `cache` is
the shared, typed, small-record one.

```zig
try sdk.cache.put(gpa, io, env, .{
    .source = "jira",
    .kind = .ticket,
    .listing = "assigned_open",   // which poll this was
    .complete = true,             // the listing came back whole
    .stale_after_secs = 1800,
}, records);                      // []const sdk.cache.Ticket
sdk.cache.failed(gpa, io, env, "jira", .ticket); // bumps error_at only
```

* Typed records (`sdk.cache.Ticket`, `Pr`, `Pipeline`, `Release`) so
  Jira and Bitbucket cannot drift on a field name. Unknown fields in a
  file are kept on rewrite, so a newer writer's fields survive an
  older one.
* `put` upserts by id and sets `seen_at`. It never deletes on absence:
  "recent" means seen lately, not "still in the listing".
* With `.complete = true`, a record that named this listing last time
  and is missing now gets `stale = true` (it probably moved or closed;
  we no longer know its state). It clears the next time it is seen.
* Called where each integration already has the records in memory:
  Jira's `--values` search and its pane's tab fetches; Bitbucket's
  `computeValues` listing (PRs), its per-repo pipeline probe, and its
  pane's tabs; Jira's fix-versions fetch for releases, which also
  decides `current` (the unreleased version with the nearest release
  date) and `next` (the one after) per project.
* The host never writes. Even "stale because old" is computed on read.

**Atomic write and locking.** Readers never lock. A writer:

1. takes `recent/<source>/<kind>.lock` with `createFile(.., .lock =
   .exclusive)` — the pattern `ratelimit.zig` uses for its draws log,
   and needed because one integration runs as several processes (the
   pane, the statusline `--values` poller, the warmer);
2. reads the current file, merges, evicts;
3. writes `<kind>.json.tmp.<pid>` and renames it over `<kind>.json`;
4. drops the lock.

A reader therefore sees the whole old file or the whole new one. On
Windows a rename over a file a reader has open can fail; readers read
the file whole and close it at once, and the writer retries the rename
three times 50 ms apart, then gives up silently (the next poll writes
again). A lock it cannot take in 2 s is a skipped write, never a wait
on the paint loop: `put` is called from the integrations' worker
threads, not their render loop.

## 4. Readers

```zig
const t = sdk.cache.get(arena, io, env, .ticket, "ACME-123");        // ?Ticket
const prs = sdk.cache.query(arena, io, env, .pr, .{
    .repo = "acme/widget", .state = "OPEN", .since_secs = 7 * 86400, .limit = 50,
});
```

Each result carries `source`, `seen_at` and a computed `stale: bool`
(record flag, or the file past `stale_after_secs`, or `error_at` newer
than `fresh_at`). `get` with the same id from two sources (unlikely;
two Jira sites) returns the newest `seen_at`.

**The host** — `src/app/recent_items.zig`, read-only:

* Reloads a file when its mtime moves, on the stat tick the sessions
  dashboard already runs (`stat_tick_ms` on screen, `stat_tick_off_ms`
  off — see `refresh_cadence.zig`). No new timer, no read per frame.
* `link_rules`: a span whose rule belongs to an integration gets an
  item lookup by the matched text (`ACME-123`, or the PR rule's
  `{workspace}/{1}#{2}`, or a `.range` link's resolved repo). Hovering
  the link shows `ACME-123 · Fix the login redirect · In Review`, the
  link's right-click menu gains the title as its header. Nothing is
  painted inline in the text; the cache labels links, it does not
  rewrite what the user wrote.
* Pickers (phase 2): the ticket and PR pickers offer recent items
  before a server search answers, marked `cached`.
* SESSIONS cards (phase 3): a card's link previews get the title the
  same way the hover does.

**Any pane** through the SDK, including a private integration. The
loops pane's TITLE column becomes: the lease's own summary → `sdk.cache
.get(.ticket, key)` → blank. The file format is documented in
`docs/SDK.md` as a contract, so a reader in another language reads the
JSON directly and applies the same staleness rule.

## 5. Freshness and offline

* **Integration not running.** The files stay. Readers keep showing
  what was last seen, with its age; once the file passes
  `stale_after_secs` every record reads as stale. Records past their
  kind's max age are dropped by the reader, so a source switched off
  for a month fades out without a writer.
* **Network down.** The writer calls `failed`; `error_at` moves,
  records do not. Readers see the last good values marked stale.
* **What stale looks like.** The hover keeps the title and adds
  `as of 3h ago` (`sdk.store.ageText`) in the dim colour; a stale item
  is never hidden, because an old title is more useful than none.
* **Refresh cadence.** The cache adds no polling and no request. It is
  as fresh as the polls the integrations already make: `--values` on
  the statusline's interval, the panes' own fetches, the warmer under
  `sdk.warm`'s budget rules. `ui.dashboard_refresh = manual` stops the
  host's dashboards, not the integrations' polls, so the cache keeps
  filling; the host still reloads changed files on the stat tick
  because a local stat costs nothing.

## 6. Privacy and work data

* The cache holds real company data and lives only under the shared
  state dir or data root on the user's machine. Never under a
  workspace's `.mnml/`, never in a repo, never in a bug report or
  `--diag` bundle.
* Files are written mode 0600; the directory 0700.
* Only the fields in §1. No bodies, no account ids, no emails.
* `mnml cache clear [source]` deletes the directory (the one thing the
  host may remove, on the user's ask).
* Tests point `MNML_SHARED_STATE_DIR` at a scratch dir (never `/tmp`
  shared paths, never the real one), and every fixture is invented:
  `ACME-*`, `acme/widget`, `Pat Example`. Records for integration tests
  come from the fake servers (`integrations/*/tools/fake_*`).
  `tools/work-data-audit.sh` stays at 0.

## 7. Migration

* **Bitbucket `link-ranges.json`: leave it.** It is a watermark table,
  not items, and its low watermark must outlive the 30-day `pr`
  eviction. It keeps its file and its IPC message. Later, the
  integration may derive the high watermark from `pr` records, but the
  table stays its own.
* **Jira `cache/jira/`: leave it.** `dev-status.json` is an
  `sdk.Store` of response bodies keyed by `updated` — a request saver,
  private by design. `sync.json` is the pane's own state. Neither is
  shared knowledge.
* **Rust-era prefetch files: ignore.** Nothing reads them after phase
  3. mnml does not delete files it did not write; the release note
  says they can be removed.
* **Loops pane:** phase 3 swaps its prefetch fallback for
  `sdk.cache.get`, and drops its reader of the old file.

## 8. Phases

**Phase 1 — store, Jira tickets, hover titles.** ~8 files.
`sdk/mnml-sdk/src/cache.zig` (+ `root.zig` export, tests),
`docs/SDK.md` (format contract), Jira `main.zig` (`--values`) and
`src/app.zig` (tab fetches) call `put`/`failed`,
`src/app/recent_items.zig` (host reader), `link_rules.zig` +
`ui/link_span.zig` (hover title), one `.test` e2e with a seeded
scratch dir.

**Phase 2 — PRs, pipelines, releases, pickers.** ~8 files.
Bitbucket `main.zig` `computeValues`, `src/fetch.zig` (pipeline probe),
`src/app.zig`; Jira fix-versions fetch (releases, current/next);
the ticket and PR pickers; `mnml cache clear`; e2e on both fake
servers.

**Phase 3 — loops pane, SESSIONS cards.** ~4 files in-repo plus the
private pane. SESSIONS card link previews; the loops pane's TITLE order;
removing its prefetch-file reader.

## 9. Open questions

1. Is 30 days / 1000 tickets the right "recent", or should it track
   the user's own working set (assigned, reported, watched) only?
2. Should assignee display names be in at all, given they are people's
   names on disk? (Proposed: yes, display names only.)
3. Releases: is "current" the nearest unreleased by date, or the one
   named in a setting? Projects without dates need a rule.
4. Hover only, or also a dim inline title after a bare `ACME-123` in
   the SESSIONS cards?
5. Do you want `mnml cache get <kind> <id>` on the CLI for shell
   tools, or is the documented file format enough?
6. Should the host offer a Settings row to turn the cache off
   (integrations stop writing), or is `mnml cache clear` enough?
