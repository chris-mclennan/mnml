---
title: HTTP Request pane — variables, edit split & panel filter
description: Three surface polish items on the HTTP client — a side-by-side edit split so Body and Vars sit next to each other, {{VAR}} tokens that highlight + jump + hover across every field, and a `/` filter at the top of the HTTP activity-bar panel.
---

Three separate polish items on mnml's HTTP surface all shipped together in July 2026 and are described here in one page because they compound: the `{{var}}` token you see cyan-highlighted in the Body tab is also clickable, also gets a hover tooltip, and — with the side-by-side edit split active — sits right next to the Vars tab you'd otherwise have to swap in to check it. The `/` filter on the HTTP activity-bar panel is the same idiom.

None of these change what the request pane *is*. They just make composing a request less swap-heavy.

## The `[⇔]` edit split chip

The Request block's border row carries a floating `⇔` chip near its right end. Click it — or run `:http.toggle_edit_split` — and the edit area splits into two independently-tabbed sides:

```
┌─ Request ──────────────────────────────────── [⇔]  [▤] ─┐
│  Body   [Headers]  Params   Auth   Vars   Source        │
│                                                          │
│  {                     │  ↕ Body   [Vars]  Params  …    │
│    "id": 42            │                                 │
│    "org": "{{ORG}}"    │  Active env vars — dev.env      │
│  }                     │                                 │
│                        │  ORG = acme                     │
│                        │  BASE_URL = https://api...      │
└──────────────────────────────────────────────────────────┘
                         ↑ 1-cell divider — click to cycle ratio
```

The left side keeps rendering the **primary tab** (whichever of Body / Headers / Params / Auth / Vars / Source was already active), and the right side renders a **secondary tab** you pick independently. Default secondary tab = **Vars** — or **Body** when the primary is already Vars — because "see the body and the env vars at the same time" is the flow that pushed this feature out the door.

The right side has its own clickable tab strip. Click any label there — `Body`, `Params`, `Auth`, `Headers`, `Source`, `Vars` — to change what the secondary side shows without disturbing the primary. Any pairing works: `Body | Vars`, `Params | Body`, `Auth | Headers`, `Source | Body`. Palette-driven pairings are a v2 nicety; today the picker is the chip strip.

### Cycling the ratio

The 1-cell vertical bar between the two sides is a **clickable divider**. Each click cycles the primary/secondary split ratio through three presets:

| Cell width band | Next ratio |
|---|---|
| 0 – 39 % | 50 / 50 |
| 40 – 59 % | 70 / 30 (primary wider) |
| 60 – 100 % | 30 / 70 (secondary wider) |

Full drag-resize is queued as v2 — click-to-cycle covers the "I want a bit more room for the JSON body" case for now.

### Below the minimum width

The split needs at least **48 cells** of edit-area width (24 per side plus the divider). Below that threshold the pane silently degrades to primary-only — cells aren't collapsed to unreadable widths just to keep the split open. Widen the pane or drop the split with the chip.

### Keyboard vs mouse in the split

**v1 caveat**: keyboard input targets the **primary** side only. `Tab`, `Ctrl+1..6`, `Ctrl+]`, `Ctrl+[`, typing into Body — all of it goes to the primary. The secondary side is **click-editable**:

- **Vars cells** — click a row to edit that var (opens the `:http.edit_env` prompt).
- **Params rows** — click `+ Add new parameter…` or an existing row.
- **Add-KV / KV cell** — flat kv tables (Headers, Params) accept clicks on the value.
- **Auth action rows** — click any `+ Set Bearer token…`, `↻ Apply saved preset…`, etc.

So the flow that works today is: keep the Body in the primary side (keyboard-editable), pin the Vars to the secondary side (click any missing var to `Set value…`). A v2 pass will route keyboard input to whichever side the caret last touched.

### Palette + hover

| Surface | Call |
|---|---|
| Chip | `⇔` on the Request block's border row |
| Ex-command | `:http.toggle_edit_split` |
| Palette | `HTTP: toggle side-by-side edit split (Body|Vars default)` |

Hover the chip: `click: split the edit area side-by-side · e.g. Body on the left, Vars on the right`. When already open the hint reads `click: close side-by-side edit split · click a right-side tab to change what it shows`.

## `{{VAR}}` highlighting across the pane

Every editable field in the Request pane now tokenizes `{{VAR}}` and colors the tokens by resolution status. What was previously a plain-white block of `{{TOKEN}}` text — visually indistinguishable from a real string — is now unmistakable at a glance.

### Colors

| State | Style | Meaning |
|---|---|---|
| Resolved | cyan · bold | The active env file defines this key (or the name is a dynamic built-in like `$uuid`) |
| Unresolved | red · bold | No key by that name in the active env, and it isn't a dynamic built-in |

The active env file is the same one the runtime substituter picks — `.mnml/env/<name>.env` overrides `.rqst/env/<name>.env` on the same key, and the active env resolves per the standard chain (`--env` → `$MNML_ENV` → `default_env` → `dev`). See [HTTP envs & templating](/manual/http-envs/) for the full precedence.

### Where the highlighting works

| Surface | Coverage |
|---|---|
| **URL field** | Full tokenizer |
| **Body — plain / non-JSON** | Per-line tokenizer |
| **Body — JSON** | Per-character merge with tree-sitter JSON coloring; var color wins over syntax color |
| **Params — value cells** | Per-value tokenizer |
| **Headers — value cells** | Per-value tokenizer |
| **Vars tab** | *(no highlighting — it IS the vars)* |
| **Source tab** | *(paste-target hint surface, no highlighting)* |

For JSON bodies the var color merges with tree-sitter JSON coloring on a per-character basis — quote punctuation and keys stay JSON-colored, `{{USER_ID}}` inside a string turns cyan-bold (or red-bold if `USER_ID` isn't in the active env). Both plain and JSON body paths emit the same click rects.

### Click to jump to the definition

Left-click any `{{VAR}}` token to jump to its definition:

- **Resolved** — opens `.mnml/env/<active>.env` (or `.rqst/env/<active>.env` if only the legacy file has it) and places the cursor on the `VAR=…` row. A leading `export ` prefix is tolerated on the line match, so `export TOKEN=…` works the same as `TOKEN=…`.
- **Unresolved** — opens the active env file at end-of-file, so the row you land on is exactly where an appended `VAR=…` will go. A toast reads `<VAR> not defined in <name>.env — jump to end so you can add it`.
- **Dynamic** (`$uuid`, `$timestamp`, etc.) — the token renders as resolved but isn't backed by any file, so click behavior is identical to unresolved (opens env at EOF).

The click rect is checked **before** the URL / Body field's regular click handler, so clicking a var doesn't first refocus the field.

### Hover tooltip

Hover a `{{VAR}}` token for a two-line tooltip:

```
{{TOKEN}}
= eyJhbGciOiJIUzI1NiJ9… · click to jump to env
```

The value line truncates to 100 characters plus `…` to keep the tooltip one row tall. Unresolved vars read `not defined in active env · click to open env file` instead.

Dynamic vars get the same hover treatment with the evaluated built-in value — `{{$uuid}}` hover shows a fresh UUID; `{{$timestamp}}` shows the current ms timestamp.

### Right-click menu

Right-click any `{{VAR}}` token for a context menu titled `{{VAR}}`:

| Item | What it does |
|---|---|
| **Set value…** | Opens the env-editor edit prompt seeded with the existing value (or empty for undefined vars). Accepting the prompt upserts `VAR=<value>` into the active env file. |
| **Jump to definition** | Same as left-click — opens the env file at the row (or EOF if undefined) |
| **Copy variable name** | Copies the bare `VAR` (no `{{ }}`) to the clipboard |

**Dynamic vars** (`$uuid`, `$timestamp`, `$epoch`, `$randomInt`, `$randomHex`, `$randomString`, `$randomBool` — plus aliases `guid`, `epochMs`, `epochS`) skip **Set value…** because they're built-ins, not env-file backed. **Jump to definition** for a dynamic still opens the active env file at EOF so you can pin an override if you want one.

The right-click rect for the var token is checked **before** the URL / body / value-cell field's regular right-click handler.

### Quick-add for undefined vars

The most useful compound flow — see a red `{{DATABASE_URL}}`, right-click it, hit **Set value…**, paste the URL, Enter. The var now defines cleanly in the active env file and the token flips to cyan-bold on the next render. No context switch, no picker, no scrolling through the env editor.

For dynamic vars this is a two-key **Jump to definition** into the env file so you can wire a static override that shadows the built-in for this workspace.

## HTTP panel `/` filter

The HTTP activity-bar panel — the seven-section rail (FILES / RECENT / CAPTURED / ENVS / CHAINS / MOCKS / COLLECTIONS) — grew a filter input right under the `HTTP` header:

```
HTTP           ↺ ↕
 / filter                  ← inactive placeholder
 ▸ FILES (24)
   users.http
   billing.curl
   …
```

Same idiom as the Agents and Cloud Agents panels: `/` focuses, typing appends, `Backspace` deletes, `Enter` unfocuses (leaving the filter applied), `Esc` clears the filter *and* unfocuses. Case-insensitive substring match.

### Focus + edit shape

| Key (when HTTP panel is focused) | Action |
|---|---|
| `/` | Focus the filter input |
| any letter / digit | Append to the filter |
| `Backspace` | Drop the last character |
| `Enter` | Unfocus (keep the filter applied) |
| `Esc` | Clear + unfocus |

Click the row also focuses — the filter input becomes clickable exactly like a text field. Click anywhere else in the panel to unfocus.

While focused the placeholder swaps to `type to filter…`, an inverted cursor `▍` blinks at the end, and the row's background lifts to `bg2` to signal input capture.

### What each section filters against

| Section | Filter target |
|---|---|
| **FILES** | Workspace-relative path — e.g. typing `bill` narrows to `billing.http`, `subdir/billing.curl` |
| **RECENT** | `<method> <url>` string of each history entry |
| **CAPTURED** | `<method> <url>` string of each captured browser row |
| **ENVS** | Env file name (without `.env`) |
| **CHAINS** | Chain filename (without `.chain.json`) |
| **MOCKS** | Mock filename (without `.mock.json`) |
| **COLLECTIONS** | **VS-Code-tree behavior** — see below |

### Collections filter — VS-Code style

Collections filter differently because they're two-level (folder + members). The rule set:

1. **Collection name matches** → the collection and *all* its members render.
2. **Collection name doesn't match, but some members do** → the collection stays visible, only matching members render below it. The collection auto-expands so hits are visible without clicking the chevron.
3. **Neither the name nor any member matches** → the collection is hidden entirely.

This matches how VS Code's Explorer filter works: a folder stays visible if anything inside it matches, and its expansion state is forced open so you see the hits.

The auto-expansion only lasts while the filter is non-empty — clear the filter and the collection's manually-set expand/collapse state is restored from `App::http_panel_collections_collapsed_dirs`.

## Next

- [HTTP Request pane — tabs & layout](/manual/http-edit-tabs/) — the three-panel Request pane, the six Edit tabs, the AI strip
- [HTTP envs & templating](/manual/http-envs/) — the `{{var}}` resolution the highlighting is built on, plus the `:http.edit_env` picker the right-click menu launches
- [HTTP client](/manual/http/) — the file-driven `.http` / `.curl` / `.rest` surface
- [Activity bar](/manual/activity-bar/) — the sectioned rail the HTTP panel lives in
- [New request — Postman-style scratch pane](/manual/http-new-request/) — `:http.new`, paste-curl from clipboard, the empty-pane landing
