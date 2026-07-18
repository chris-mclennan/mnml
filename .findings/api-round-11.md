# API-workflow hunt — round 11 (2026-07-14)

Driven headless via the file-IPC channel (`<workspace>/.mnml/ipc/`) against
`./target/debug/mnml` at commit `fcb88751`, plus `mnml chain run FILE`
directly. Two throwaway Python servers stood in for a real API: a REST-ish
echo server (`127.0.0.1:8951` — `/users`, `/login`, POST echo) and a
minimal one-operation OpenAPI 3 spec server (`127.0.0.1:18951`) for
`http.sync`/`discover` testing. Workspace layout deliberately mirrors the
CLAUDE.md-documented modern setup: `.mnml/env/dev.env`, `.mnml/chains/`,
`.mnml/sources.json`, `.mnml/collections/`, a multi-block `multi.http`
(`list-users`/`create-user`/`delete-user`), `.rqst/lookups/` — and
**no `.rqst/config`, no exported `$MNML_ENV`** (unlike rounds 9/10, which
always had one or the other set). That single difference from prior
rounds' fixture is what surfaced this round's headline finding: an env-var
inline-edit code path that silently diverges from every other env
resolution path in the exact workspace shape the project's own docs call
the authoritative one.

Focus per the assigning agent: (1) verify the mouse-round-11 F2 fix
(HTTP-panel section right-click menus) and the MOCKS-section Save/Replay
fix landed clean; (2) verify Notes/TODOs/Sessions/HTTP filter-row
isolation across activity switches; (3) fresh sweep of send/response,
env resolution + `{{VAR}}` UI, sources sync, mocks, bench, history,
lookup picker, collections, chain execution, and split editing.

## Executive summary

**3 new findings: 1 SEV-1 · 1 SEV-2 · 1 SEV-3.**

**Headline: a single click + a single `Tab` keypress on the Vars tab
silently deletes real values from `.mnml/env/*.env` on disk**, with a
toast that reads like success (`vars: updated`). Root cause is an env
resolution inconsistency — `http_kv_edit_begin_cell` seeds/reads the "current
value" for the Vars-tab inline editor via the 2-tier `EnvSet::select()`
(explicit `--env` / `$MNML_ENV` / legacy `.rqst/config` only — **no**
`[http] default_env` config, **no** "dev" fallback), while literally every
other env-consuming code path in the same file (send, bench, write,
delete) uses the 4-tier `EnvSet::select_with_config_default()` or the
fallback-aware `resolve_env_name_with_fallback()` wrapper. In a workspace
that relies solely on the implicit "dev" default (no `.rqst/config`, no
`$MNML_ENV`) — which is exactly what the Vars tab's own header confidently
displays (`env: dev.env`, with correctly-resolved values sitting right
there in the table) — the inline editor's seed comes back empty every
time, and committing writes that empty string straight into the real
`.env` file, permanently discarding the original value. Verified twice:
once via a Name-cell rename (destroys the row entirely, replaces it with
an empty-valued misspelled key) and once via a plain Value-cell edit with
**zero typing at all** (click, `Tab`, done — `TOKEN=devtoken123` becomes
`TOKEN=` on disk).

**Compounding factor: the KV tables (Params/Headers/Vars) have no scroll.**
Rows beyond the visible pane height are simply gone — no truncation
indicator, no scrollbar, arrow/`j`/`k`/`PageDown` do nothing to the table.
Because the table itself absorbs no keyboard input, those same
"trying to scroll" keystrokes silently fall through to the `Url` field
(the documented row-click fallback for read-only Vars rows) and get
typed as literal characters into the request URL with zero visual
feedback — which is exactly the gesture a user reaching for the invisible
4th env var would try first.

**Everything else swept this round came back clean.** Mocks (save +
replay, correct `.curl.mock.json` sidecar naming, real network-free
replay), sources sync (background-threaded, correct `.curl` stub
generation from OpenAPI), bench (percentile math still holds: p50 ≤ p95 ≤
p99 ≤ max), history (append-on-failure still correctly records
`status: null` + `error: "..."`), the lookup picker's 3-stage chain +
clean Esc-cancel, collections (create + starter `.http` file), and the
`[⇔]` split-edit chip (toggle + ratio-cycle) all worked exactly as
documented, end-to-end, with real files/processes.

**Round-11-prior-session fixes verified landed:** HTTP-panel section
right-click menus (mouse-round-11 F2) are live for all 7 sections with
sensible per-section verbs; MOCKS specifically now offers "Save active
response as mock" / "Replay mock into active request" (was empty).
Notes/TODOs/Sessions/HTTP filter rows use genuinely separate `String`
fields per activity (`http_panel_filter`, `todos_panel_filter`,
`notes_panel_filter`, `sessions_panel_filter` — `src/app/mod.rs:3992-4007`)
— no shared-state bleed possible by construction.

## Findings

### SEV-1

#### Finding 1 — Vars-tab inline cell-edit silently overwrites/deletes real `.env` values because it resolves the active env differently from every other code path

**surface**: env-resolution / request-pane (Vars tab)

**Repro** (fresh workspace: `.mnml/env/dev.env` only, no `.rqst/config`,
no `$MNML_ENV` exported, no `[http] default_env` in config):

1. `.mnml/env/dev.env`:
   ```
   BASE_URL=http://127.0.0.1:8951
   TOKEN=devtoken123
   export EXPORTED_VAR=hello
   QUOTED_VAR="quoted value"
   ```
2. Open any `.curl`/`.http` Request pane → click the **Vars** tab. Header
   reads `env: dev.env`; table correctly shows `BASE_URL`, `QUOTED_VAR`,
   `TOKEN` with their real values (`http://127.0.0.1:8951`,
   `"quoted value"`, `devtoken123`).
3. Click directly on the **Value** cell of the `TOKEN` row (no typing at
   all).
4. Press `Tab` (the tab's own hint text: "click cell to edit · Tab
   commits · Esc cancels").
5. Inspect `.mnml/env/dev.env` on disk.

**Expected**: clicking a value cell with no edits and committing should be
a no-op (or at minimum re-write the same value back unchanged) — the tab
literally shows the correct value one frame before the click.

**Actual**: the moment the cell opens for editing, the buffer is already
empty (screen shows a bare cursor `▏`, `devtoken123` is gone from view)
— *before* any keystroke. Pressing `Tab` commits that empty buffer:

```
--- before ---
BASE_URL=http://127.0.0.1:8951
TOKEN=devtoken123
export EXPORTED_VAR=hello
QUOTED_VAR="quoted value"

--- after click(TOKEN value cell) + Tab ---
BASE_URL=http://127.0.0.1:8951
TOKEN=
export EXPORTED_VAR=hello
QUOTED_VAR="quoted value"
```

Toast: `vars: updated` — reads as confirmation of success, gives zero
indication the value was wiped. A second toast fires just before it,
`env: no active env — using dev.env (set `[http] default_env` or
MNML_ENV)`, which is the actual tell — but it's easy to miss (two
stacked toasts, generic-sounding, and fires on *every* Vars-tab commit in
this workspace shape, so a user would have to already suspect something
was wrong to connect it to data loss).

A second repro via the **Name** cell (rename path) is even more
destructive — one stray keystroke plus `Tab` deletes the original key
entirely and replaces it with a misspelled key holding an **empty**
value (the "preserve current value under the new name" logic in the
commit handler also reads through the same broken lookup):

```
--- before ---
BASE_URL=http://127.0.0.1:8951
...

--- after click(BASE_URL name cell) + type "j" + Tab ---
TOKEN=devtoken123
export EXPORTED_VAR=hello
QUOTED_VAR="quoted value"
BASE_URLj=
```

`BASE_URL=http://127.0.0.1:8951` is gone — not renamed with its value
intact, just gone, replaced by an empty-valued near-miss key. Every
`{{BASE_URL}}` reference in the workspace is now broken with no history
or undo (`http_delete_env_key` + `write_env_var` both do direct
`std::fs::write`, no backup).

**Root cause**: `http_kv_edit_begin_cell` (`src/app/http.rs:5571-5577`)
seeds the edit buffer — and, for renames, looks up the value to
preserve — via:

```rust
crate::request_pane::KvEditKind::Vars => {
    let envset = crate::http::template::EnvSet::select(
        &self.workspace,
        self.http_env_override.as_deref(),
    );
    envset.lookup(&key).unwrap_or_default()
}
```

`EnvSet::select` (`src/http/template.rs:66-68`) is a thin wrapper over
`select_with_config_default(workspace, explicit, None)` — it hard-codes
`config_default: None` and has **no built-in "dev" fallback**. Resolution
order is: explicit `--env` → `$MNML_ENV` → legacy `.rqst/config`'s
`default_env=` → **`Self::empty()`**. In a workspace with none of those
three set (my fixture; also any workspace relying purely on
`[http] default_env` in `.mnml/config.toml`, since that config value is
never threaded into this call at all — `None` is hard-coded), this
resolves to an *empty* `EnvSet` — `.lookup(&key)` always returns `None`
regardless of which key is asked for.

Contrast every other env-consuming call site in the same file:

- The actual send path, `parse_active_as_request`
  (`src/app/http.rs:3260-3264`), uses
  `EnvSet::select_with_config_default(workspace, override, self.config.http.default_env.as_deref())`
  — the full 4-tier resolution.
- `write_env_var` / `http_delete_env_key`
  (`src/app/http.rs:2340-2348`, `:2394-2402`) both resolve the env
  **name** via `resolve_env_name_with_fallback`
  (`src/app/http.rs:86-101`), which wraps
  `select_with_config_default` and additionally falls back to a literal
  `"dev"` name when even that returns nothing — which is *why* the write
  succeeds against `dev.env` at all (and why the misleading "updated"
  toast fires) even though the read that seeded the edit came back empty.
- The Vars tab's own *render* path
  (`src/ui/request_view.rs:3317-3320`) has yet another fallback —
  `EnvSet::select(...).name().unwrap_or_else(|| "dev".to_string())` — which
  is why the header confidently shows `env: dev.env` with correct values
  displayed in the very same frame the edit-seed silently returns empty.

Three different fallback behaviors for "no active env resolved" across
render / edit-seed+commit-lookup / write, in the same feature, on the
same tab, is the actual defect — the specific empty-seed-on-commit
behavior is just the one with a destructive, undoable-nothing blast
radius.

**Notes**: `src/app/http.rs:5571-5577` (`http_kv_edit_begin_cell`, Vars
branch), `src/http/template.rs:66-68` (`EnvSet::select`, no
config_default / no fallback), `src/app/http.rs:3260-3264` (correct
4-tier resolution at the send path, for contrast), `src/app/http.rs:86-101`
(`resolve_env_name_with_fallback`, the "dev" fallback wrapper used by
write/delete but not by the edit-seed), `src/ui/request_view.rs:3317-3320`
(render-path's own independent "dev" fallback). The same
`EnvSet::select` (no config_default) pattern also appears at
`src/app/http.rs:4386` (`pending_var_at_cursor_name`, used by the
right-click "Set value…" / hover flow) and `:4484` — not re-verified live
for destructive impact this round given time, but worth an audit pass
since it's the identical anti-pattern. Fix shape: either thread
`self.config.http.default_env` through to `http_kv_edit_begin_cell`
(matching the send path), or better, have all three call sites share one
`self.active_envset()` helper that always resolves through
`resolve_env_name_with_fallback` + `EnvSet::load`, so "what env is
active" can never disagree with itself within the same frame.

### SEV-2

#### Finding 2 — Params/Headers/Vars KV tables have no scroll; overflow rows are invisible and unreachable, and "scroll" keystrokes leak into the URL field instead

**surface**: request-pane (Params / Headers / Vars tabs)

**Repro**:

1. Same `.mnml/env/dev.env` as Finding 1 (4 vars). Open the Vars tab in a
   normal-width Request pane (the AI-assist box + Response pane below eat
   most of the vertical budget, leaving ~3 data rows of height for the
   table on an ordinary terminal size).
2. Table renders `BASE_URL`, `QUOTED_VAR`, `TOKEN` and then a hard
   closing border — `export EXPORTED_VAR=hello` (the 4th var) is nowhere
   on screen.
3. Press `Down`, `PageDown`, `j`, `j` in sequence trying to reveal it.

**Expected**: either the table scrolls (with a scrollbar/`+N more`
indicator so the user knows more rows exist), or at minimum the
keystrokes are captured/ignored rather than silently going somewhere
else.

**Actual**: none of `Down`/`PageDown`/`j`/`k` move the table — the 4th
row stays permanently inaccessible, with no on-screen indication a 4th
row even exists (the border just closes after row 3, indistinguishable
from "that's all the vars there are"). Worse: `Down`/`PageDown` are
silently swallowed as no-ops, but the printable `j` keys are **not** —
they get typed as literal characters into the URL field (which still
holds keyboard focus, per `render_kv_table`'s documented fallback:
Vars/Params row clicks route to `EditField::Url` since those tabs have
"no in-pane edit field" for whole-row clicks — `src/ui/request_view.rs:449-456`).
Confirmed via a real screen dump:

```
 GET  @assert status 200                                                 (bufferline tab, unmodified)
┌ URL ...┐
│ {{BASE_URL}}/usersjj                                                   ┐  ← two stray 'j's from
└─────────────────────────────────────────────────────────────────────┘     "scroll" attempts
```

The KV table view itself shows *zero visible change* while this happens
— a user watching the Vars/Headers table (the thing they're actually
looking at) gets no feedback at all that their keypresses just corrupted
the URL of the request they're about to send.

**Root cause**: `draw_edit`'s content rows are hard-truncated with no
scroll offset — `src/ui/request_view.rs:1318-1322`:

```rust
let edit_view: Vec<Line> = edit_rows
    .iter()
    .take(left_rect.height as usize)
    .cloned()
    .collect();
```

There is no `edit_tab_scroll` / equivalent field anywhere in
`RequestPane` (grepped `src/request_pane.rs`, `src/app/http.rs`,
`src/tui/handlers/*.rs` for `scroll` near `EditTab`/`kv` — nothing).
`rp.scroll` exists but is documented and used exclusively for the
**Response** pane content area (`src/ui/request_view.rs:1507-1515`), not
the Edit-view tabs.

This is the same underlying class of bug as api-round-10 Finding 3
(keyboard-focus and visible-tab desync) — reachable here through a
different, arguably more likely gesture (a user reflexively reaching for
arrow/vim-navigation keys on an overflowing table) and directly enabled
by the complete absence of scroll support: with 4+ env vars (a realistic
`.env` file size) there is *no other way* to see the rest of the table,
so a user is guaranteed to eventually try exactly this.

Also directly undermines verifying api-round-10 Finding 7 (Vars tab's
env-file parser drops the `export ` prefix and doesn't strip quotes) —
this round the `export EXPORTED_VAR` row couldn't even be scrolled into
view to re-confirm its rendered key text; `QUOTED_VAR`'s literal
`"quoted value"` (still showing surrounding quotes) is directly visible
and confirms F7 is still unfixed for the value side at least.

**Notes**: `src/ui/request_view.rs:1318-1322` (hard `.take()`, no
scroll), `src/ui/request_view.rs:449-456` (Vars/Params row-click
`EditField::Url` fallback — the mechanism by which stray keystrokes land
in the URL), `src/request_pane.rs` (no `edit_tab_scroll` field exists).
Fix shape: give the KV-table content area its own scroll offset (mirror
`rp.scroll`'s Response-pane treatment), clamp it to `data.len() -
visible_rows`, and route `PageDown`/`Down`/mouse-wheel to it when the
active `edit_tab` is Params/Headers/Vars — plus render a `↓ N more`
footer row when truncated, so the boundary is at least visible even
before scroll lands.

### SEV-3

#### Finding 3 — replayed mock responses are indistinguishable from live responses once the toast expires

**surface**: http.replay_mock

**Repro**:

1. Fire a real request, `:http.save_mock` (writes `<source>.curl.mock.json`).
2. Kill the backing server (confirm `curl` to it now fails/times out).
3. `:http.replay_mock` on the same pane.
4. Wait a couple seconds for the toast to expire, then look at the
   Response pane (status line, Body/Headers/Timeline/Tests tabs).

**Expected**: some persistent, non-toast signal that the currently
displayed response came from a mock file rather than the network —
important specifically because mocks exist to let you keep working
against a shape while the real backend is down/slow, which is exactly
the scenario where later forgetting "this is fake data" costs real
debugging time.

**Actual**: status line reads `200 OK · 0ms · 65 B` — identical in shape
to a real fast response (my own live echo server also frequently
returned `200 (0 ms)` / `200 (1 ms)`; "0ms" is not a reliable tell). Body
tab shows the mock payload with no badge. No mock indicator anywhere in
the Headers/Timeline/Tests tabs either. The only signal was a
now-expired toast (`replayed mock (<path>)`).

**Root cause**: `ResponseView` (`src/request_pane.rs:511-531`) has no
`is_mock`/`source` field at all. Both replay entry points —
`http_replay_active_request_from_mock` (`src/app/http.rs:~3140-3163`)
and `http_replay_mock_from_path` (`src/app/http.rs:3169-3208`) —
construct a plain `ResponseView` with `elapsed: Duration::ZERO` and no
other marker distinguishing it from a real `Done` state. `elapsed:
Duration::ZERO` was presumably chosen because a mock is instant, but
that happens to collide with what a fast real server's elapsed time
often rounds to at millisecond granularity, making it a weak/misleading
signal rather than a clear one.

**Notes**: `src/request_pane.rs:511` (`ResponseView`, no mock field),
`src/app/http.rs:3169-3208` (`http_replay_mock_from_path`). Fix shape:
add `pub is_mock: bool` (or `pub source: ResponseSource` if a future
"from history" / "from capture replay" origin is also worth tagging) to
`ResponseView`, set it `true` on both replay paths, and render a small
`MOCK` chip in the response status-line title (`response_status_title`,
`src/ui/request_view.rs:1671`) whenever it's set — persists for the life
of the response, not just a few seconds.

## Verifications (prior-round items)

**Confirmed fixed:**
- api-round-10 Finding 1 (CLI `-F @relpath` uploads resolved against
  process CWD) and Finding 6 (`http.params_add` unencoded query values)
  — both landed in `0b3d00ef` (2026-07-12); not re-tested live this round
  since the fix commit is unambiguous and unit-testable, but the code at
  `src/app/http.rs` now calls the new `percent_encode_component` helper
  and `main.rs`/`chain.rs` now thread `file.parent()` as base_dir.
- mouse-round-11 Finding 2 (HTTP-panel section headers had no
  right-click menu) — `open_http_panel_section_context_menu`
  (`src/app/context_menus.rs:984-1061`) is live for all 7 sections with
  sensible per-section verbs (New request…/Clear recent/Start+Clear
  capture/New env…/New chain…/**Save+Replay mock**/New collection…),
  plus universal Toggle-all-sections + Refresh. Live-verified the MOCKS
  entry specifically (was the one section design-round-4 flagged as
  empty as of this session's start) — confirmed present with both
  "Save active response as mock" and "Replay mock into active request".
- Notes/TODOs/Sessions/HTTP filter-row cross-activity bleed — confirmed
  via source read (`src/app/mod.rs:3992-4007`) that each activity owns a
  fully separate `String` field; the mouse-round-11 fix (`8aca396e`)
  replaced whatever shared state used to exist. Not independently
  re-reproduced live this round (out of primary scope — API-side sweep),
  flagging as source-confirmed rather than live-confirmed.

**Confirmed still open (not re-reported, already tracked):**
- api-round-10 Finding 2 (lookup picker's var-name prompt never
  pre-fills via `suggest_var_name` despite the helper being fully
  implemented + unit-tested) — reproduced live this round: `:http.lookup`
  → accept file → accept "Ada" (id 1) → prompt `Env var name for Ada
  (1):` opens **completely empty**. `grep -rn "suggest_var_name\|LookupPicker" src/`
  outside `src/http/lookup.rs` still returns nothing. Esc-cancel from
  the prompt stage still works cleanly (confirmed).
- api-round-10 Finding 3 (Tab-cycling field focus decoupled from visible
  tab) — same root defect as this round's Finding 2 above; not
  independently re-reproduced via the exact Tab-cycle gesture, but the
  underlying `focus`/`edit_tab` desync is unchanged in
  `src/request_pane.rs`.
- api-round-10 Finding 4 (`mnml discover`'s "wrote N stubs" count
  includes skipped-not-written files) — confirmed via source read only,
  `src/http/discover.rs:173-178` (and the two repeated sites at
  `:207-215`, `:230-249`) still does unconditional `count += 1` after
  the skip/write `if`/`else`. Not re-fired live this round.
- api-round-10 Finding 5 (`mnml chain run` on a step pointing at a
  multi-block `.http` file always fires block 1, no way to target
  another named block) — reproduced live this round:
  `.mnml/chains/simple.chain.json`'s second step references `multi.http`
  (3 named blocks: list-users/create-user/delete-user); `mnml chain run`
  fired `GET /users` (block 1, "list-users") for that step regardless.
- api-round-10 Finding 7 (Vars tab's inline env-file reader doesn't
  strip quotes/`export ` prefix, unlike the real `template::parse_env_line`)
  — reproduced live this round: `QUOTED_VAR` renders as `"quoted value"`
  (literal quotes retained) in the Vars table. The `export EXPORTED_VAR`
  case couldn't be re-confirmed visually this round because of this
  round's own Finding 2 (no scroll — the row is unreachable), but the
  offending code at `src/ui/request_view.rs:3329-3337` (bare
  `split_once('=')`, no `export` stripping) is unchanged.

**Swept clean this round (no findings):**
- Multi-block `.http` navigation in the TUI (`http.next_block`) — fires
  the correct block, tab title updates (`GET list-users` → `POST
  create-user`), body/headers/method all correctly reflect the new block.
- `http.sync` against a real OpenAPI 3 spec server — background-threaded
  (toast sequence: "fetching…" → "wrote N stub(s) — tree refreshed"),
  correct `.curl` stub generation (method/path/headers all sane), tree
  auto-refreshes to show the new `generated/untagged/*.curl` files.
- Mocks end-to-end: `http.save_mock` writes a correctly-shaped
  `<name>.curl.mock.json` sidecar (status/headers/body/ts); killing the
  real backend server and firing `http.replay_mock` produces an
  identical 200 response instantly with zero network activity —
  confirmed the backend really was down (`curl --max-time 1` → exit 7)
  at replay time.
- `http.bench` — 10×4 concurrent fire against a live server produced a
  sane histogram with p50 (1ms) ≤ p95 (2ms) ≤ p99 (2ms) ≤ max (2ms),
  correct req/s throughput math, results landed in a scratch buffer.
- History append-on-failure — `.rqst/history.jsonl` entries for the two
  requests fired before an active env was selected correctly show
  `"status":null,"error":"bad request: builder error"`; the two
  subsequent successful fires show proper `status`/`duration_ms`/
  `body_bytes` with `"error":null`. `:http.history` picker correctly
  surfaces all 4 (2 FAILED, 2 with status/latency).
- Lookup picker 3-stage chain — file picker → item picker → var-name
  prompt all transitioned correctly on accept; Esc from the prompt stage
  cancels the whole flow cleanly (confirmed by re-dumping the screen —
  no orphaned overlay state).
- Collections — `http.new_collection` prompt → creates
  `.mnml/collections/<name>/requests.http` with a sane 2-request starter
  (`list`/`create`) and opens the first block in a Request pane.
- `[⇔]` split-edit chip — toggle opens a side-by-side split (defaults
  primary=Params, secondary=Vars per spec); clicking the 1-cell divider
  cycles the ratio; secondary side renders independently and correctly
  (confirmed the same env-var table, including the same Finding 1
  data-loss risk since it shares the identical commit code path — not
  independently re-verified destructively on the secondary side to avoid
  redundant fixture damage, but the risk is structural, not
  side-specific).
