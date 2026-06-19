---
title: "New request — Postman-style scratch pane"
description: "`:http.new`, paste-curl from clipboard, the tabbed Edit view (Body/Headers/Params/Vars/Source), the field-aware right-click menu, and the `+` chip on the INTEGRATIONS rail."
---

The HTTP client has two front doors. The original one is file-first: open a `.http` or `.curl` file, point your cursor at the block you want, fire `http.send`. That's still the right shape when the request lives next to the code it hits and you want it version-controlled.

This page is about the second door — an in-memory Postman-style scratch pane that exists for the moments when you don't want files, you don't want a workspace, you just want to paste a curl from Chrome DevTools and watch the response. The pane has no `source_path`, never writes to disk on its own, and disappears with the session. Use it the same way you'd use the Postman "new request" tab: a holding area while you figure out what you actually want to keep.

## Opening a blank request

| Surface | Call |
|---|---|
| Palette | `HTTP: new blank request pane (Postman-style scratch)` |
| Ex-command | `:http.new` |
| Rail chip | The green `+` chip in the `> INTEGRATIONS` rail (id `http_new`) |
| Command id | `http.new` |

The chip is wired by default — no config required. It sits in the INTEGRATIONS rail next to the blue paper-plane `→` chip (`http`, fires `http.send`): `→` fires the active request, the green `+` opens a new one. Don't confuse it with the *other* `+` on the section header itself — that one (`integrations.add`) opens the **Add integration** overlay listed in [Installing integrations](/manual/integrations/installing/). The two chips have different colors (the rail-row `+` is green; the section-header `+` follows the header's foreground).

What you get when the pane lands:

- **Method** = `GET`
- **URL** = empty
- **Headers** = none
- **Body** = none
- **View mode** = Edit (the form is visible immediately, no flip)
- **Focused field** = URL (typing populates the URL row)
- **State indicator** = `✗ last send: (not sent — type a URL, then press 'r' to fire)`

The state-indicator hint is deliberate — an empty Sending… spinner would lie about what the pane is doing, and a blank Response area would be ambiguous. The hint tells you the contract: fill in the URL, then `r` fires the request.

A toast lands too: `new request — Tab cycles fields, 'r' fires`. That's the only reminder you get for this pane; everything else is on the form.

### Where the pane lands

- If you already have an active pane, the new request splits vertically next to it.
- If you have nothing open (an empty workspace landing), it takes the full body — the layout tree is seeded with `Layout::Leaf` so the pane actually renders. (An earlier shipped version forgot this and drew nothing on empty-state landings; a SEV-1 fix on 2026-06-19 plugged the gap.)

Focus follows the new pane.

### Saving — there's no file, by design

`Ctrl-S` (standard) and `:w` (vim) both toast `no source file to save to (re-fire is in-memory only)`. Saving these scratch requests to disk is a v2 feature; today the pattern is:

1. Iterate on the request in the scratch pane until it works.
2. Use `http.copy_curl` (palette **HTTP: copy as curl**, vim `<leader>hy`) to get the parsed request as a curl one-liner.
3. Paste it into a `.curl` or `.http` file alongside the code that calls it. Now it's version-controlled.

## Paste curl from clipboard

This is the Postman flow's headline gesture. Copy a curl command from Chrome DevTools' Network panel (right-click a request → Copy → Copy as cURL), bring it into mnml, and one chord populates Method / URL / Headers / Body.

| Surface | Call |
|---|---|
| Palette | `HTTP: paste curl from clipboard — populate active Request pane` |
| Ex-command | `:http.paste_curl` |
| Chord (in Request pane Edit view) | `Ctrl+Shift+V` |
| Right-click menu | `Paste curl from clipboard` (visible on every field's menu) |
| Command id | `http.paste_curl` |

The parse layer is the same one the file reader uses: curl flags (`-X`, `--request`, `-H`, `--header`, `-d`, `--data`, `--data-raw`, `--data-binary`, `-u`), `\` line continuations, single + double quoting. So this also accepts pasted `.http`-format blocks (`POST /url\nContent-Type: …\n\nbody`) — anything `http::parse` can handle on a `.http`/`.curl`/`.rest` file works here.

### What the command does

1. Reads the system clipboard.
2. Parses it via `http::parse`. Failure toasts `http.paste_curl: parse failed: <err>` and leaves the pane alone.
3. If there's no active Request pane, opens a blank one first (`:http.new`'s landing logic, including the split-or-seed-layout dance).
4. Overwrites the active pane's Method / URL / Headers / Body with the parsed values.
5. Flips the pane to Edit view, focuses the URL field, and switches the Edit tab to **Body** so the populated body is visible at a glance.
6. Toasts `paste_curl: populated from <first 54 chars of clipboard>…`.

The auto-tab-switch to Body matters because the Source tab is the natural place to be when you're about to paste — its hint says exactly "Then run `:http.paste_curl` (or `Ctrl+Shift+V`) to populate fields." If the pane stayed on Source after the paste, you'd see the same hint text instead of your shiny new body. The SEV-3 fix on 2026-06-19 routes you to Body so the population is obvious.

### `Ctrl+Shift+V` vs `Ctrl+V`

The chord intentionally has Shift. Plain `Ctrl+V` keeps standard "paste plain text into the focused field" behavior — useful for pasting a single header value into the Headers buffer, or a JSON snippet into the Body. The Shift modifier is the cue to the editor that you want the whole-request semantics, not the per-field one.

### Right-click — the same gesture, by mouse

Every field's right-click menu carries **Paste curl from clipboard** as the second entry. You can right-click the URL row, the Method row, the Headers row, or the Body row and get there. The Params, Vars, and Source tab content rows also register click targets so right-clicking anywhere inside them fires the URL-titled menu — the menu's Paste curl entry is what most Source-tab right-clicks want. (A SEV-2 fix on 2026-06-19 added the missing rects; before that, right-clicking inside Source / Params / Vars produced nothing.)

## The tabbed Edit view

When the pane is in Edit mode, a tab strip sits between the URL row and the field content:

```
 [Body]   Headers   Params   Vars   Source
```

The active tab renders with bracket markers (`[Body]`), **bold**, and **underline**. Inactive tabs render dimmed. Color isn't the cue — the brackets + underline + bold survive on themes with close-step backgrounds and stay legible in monochrome (an earlier render relied on background-color alone, which flattened on close themes and was invisible to colorblind users; the SEV-3 fix on 2026-06-19 swapped to the textual cue).

### Switching tabs

| Chord | Action |
|---|---|
| `Ctrl+]` | Next tab (Body → Headers → Params → Vars → Source → Body) |
| `Ctrl+[` | Previous tab |
| `Ctrl+1` | Jump to **Body** |
| `Ctrl+2` | Jump to **Headers** |
| `Ctrl+3` | Jump to **Params** |
| `Ctrl+4` | Jump to **Vars** |
| `Ctrl+5` | Jump to **Source** |
| Mouse click | Click any chip |

The `Ctrl+]` / `Ctrl+[` / `Ctrl+1..5` chords are intercepted before the global chord chain so they work in both input modes. (Standard mode's keymap binds `Ctrl+]` / `Ctrl+[` to `editor.indent_line` / `outdent_line` globally; the dispatcher checks for a focused Request pane in Edit view first and steals the chord. Same intercept site handles `Ctrl+1..5`.)

`Tab` is reserved for cycling fields (URL → Method → Headers → Body → URL) — it does *not* switch tabs. The tab strip and the field focus are independent: you can be on the Headers tab with the URL field focused, for example, though most of the time you'll be on the tab whose field is focused because that's where the content lives.

### Per-tab content

#### Body

The existing multi-line Body field. Editable. JSON / XML / form-encoded — anything you can type in. `Tab` inside Body inserts a literal `\t` rather than cycling fields, because indented bodies are common.

#### Headers

The existing `Key: Value` list. Editable as a flat textarea — type `Authorization: Bearer xyz\n` to add a line. Header keys render in cyan + bold, values in foreground; lines without a `:` render dim (a visible hint they're not yet a valid header).

#### Params

Read-only display of the URL's query string parsed as `?key=value` pairs:

```
    foo = bar
    limit = 10
    (edit the URL field to change — Params is read-only for now)
```

Empty query string shows `(no query parameters — add ?key=value to URL)`. Editing live (adding / removing / reordering) is a v2 feature; today, edit the URL field and the Params tab reflects the new query string on next render.

#### Vars

Scaffold pointing at the structured env editor:

```
    Active env vars — open structured editor: :http.edit_env

    (Vars browser scaffold — uses :http.edit_env for editing)
```

The live env browser inside this tab is a v2 feature — render-time it'd need the workspace path threaded through to disk-read the active `.env` file. For now, run `:http.edit_env` to add / edit / remove a variable; the picker is the same one [HTTP envs & templating](/manual/http-envs/) describes.

#### Source

A paste-target hint:

```
    Paste a curl command or .http block here.
    Then run :http.paste_curl (or Ctrl+Shift+V) to populate fields.
    (clipboard paste-curl reads your system clipboard directly)
```

The "source" is the clipboard — the tab is documentation for the paste flow, not an editable buffer. An editable in-pane source field is a v2 feature; it'd need a 5th `EditField` variant, a cycle slot, and key routing. Today's Source tab is honest about being a hint surface and right-clicking anywhere in it fires the field-aware menu with Paste curl ready.

## Field-aware right-click menu

Every form row (Method / URL / Headers / Body) and the content of the Params / Vars / Source tabs registers a click rect. Right-clicking any of them opens a context menu with the field's name in the title bar (`Request · Method`, `Request · URL`, etc):

```
┌─ Request · Method ──────────┐
│  Cycle method               │ ← only on the Method row
│  Send                       │
│  Paste curl from clipboard  │
│  Copy as curl               │
│  Switch to Response         │
└─────────────────────────────┘
```

Common items appear on every field's menu:

| Item | What it does |
|---|---|
| **Send** | Same as `r` in Response view, or hitting Enter on URL / Method in Edit. Fires the request. |
| **Paste curl from clipboard** | `:http.paste_curl` — overwrites fields from clipboard. |
| **Copy as curl** | `:http.copy_curl` — copies the current request to the clipboard as a curl one-liner. |
| **Switch to Response** | Flips the pane to Response view (same as `Tab` / `Esc`). |

The Method row's menu prepends **Cycle method** so you can change the HTTP verb without keyboard focus on the field. See the next section for what cycling does.

Params, Vars, and Source content rows register as URL-field click targets — the URL-titled menu (with Send / Paste curl / Copy as curl / Switch to Response) fires from right-clicking inside any of those tabs.

## Cycling methods

| Surface | Call |
|---|---|
| Palette | `HTTP: cycle method (GET→POST→PUT→DELETE→PATCH→…)` |
| Ex-command | `:http.cycle_method` |
| Right-click menu | **Cycle method** on the Method row |
| Key (Method field focused) | `Space` |
| Command id | `http.cycle_method` |

The cycle order is `GET → POST → PUT → PATCH → DELETE → HEAD → OPTIONS → GET`. Unknown methods reset to POST.

All three surfaces share the same cycle helper now (`request_pane::cycle_method`), so the order is consistent. (Earlier, the palette command had `PATCH` and `DELETE` swapped versus the Space-key cycle on the focused field, leading to a "wait, I just hit cycle and now my method is wrong" bug. The SEV-3 fix on 2026-06-19 unified them.)

## Esc — return to Response

In Edit view, `Esc` flips the pane back to Response view — the inverse of `Tab`'s flip to Edit. Earlier behavior jumped focus to the file tree, which felt wrong because the pane was still useful. The SEV-3 fix on 2026-06-19 made `Esc` the textual inverse of `Tab`. From Response, `Esc` still jumps to the tree.

The chord summary:

| Chord | Edit view | Response view |
|---|---|---|
| `Tab` | Cycle fields (URL → Method → Headers → Body) | Flip to Edit |
| `Esc` | Flip to Response | Focus tree |
| `r` | (Literal char into focused field) | Re-fire the request |

## Quick reference

### Keys in the Request pane Edit view

| Chord | Action |
|---|---|
| `Tab` | Cycle field forward (URL → Method → Headers → Body → URL) |
| `Shift+Tab` | Cycle field backward |
| `Ctrl+]` / `Ctrl+[` | Next / previous tab |
| `Ctrl+1..5` | Jump directly to Body / Headers / Params / Vars / Source |
| `Ctrl+Shift+V` | Paste curl from clipboard (populate all fields) |
| `Ctrl+V` | Paste plain text into focused field |
| `Space` (Method focused) | Cycle HTTP verb |
| `Enter` (URL / Method) | Fire the request |
| `Enter` (Headers / Body) | Insert newline |
| `Esc` | Flip to Response view |

### Palette commands

| Command id | Title |
|---|---|
| `http.new` | HTTP: new blank request pane (Postman-style scratch) |
| `http.paste_curl` | HTTP: paste curl from clipboard — populate active Request pane |
| `http.cycle_method` | HTTP: cycle method (GET→POST→PUT→DELETE→PATCH→…) |
| `http.send` | HTTP: send active request (the existing file-driven `Pane::Request` opener) |
| `http.copy_curl` | HTTP: copy as curl |

The palette renders each row as `<group>  ·  <title>  ·  <id>` so typing the dotted id (`http.new`, `http.paste_curl`) jumps straight to the right entry — the fuzzy matcher strips `_` / `-` / `.` from the query before comparing, so `http.send_streaming` reads as `httpsendstreaming` against both the title text and the id suffix and matches both.

## Next

- [HTTP client](/manual/http/) — the file-driven surface (`.http` / `.curl` / `.rest`, `http.send`, the response view)
- [HTTP envs & templating](/manual/http-envs/) — `{{var}}` resolution + the `:http.edit_env` picker the Vars tab points at
- [HTTP helpers — JWT, bearer, cookies, SSE](/manual/http-helpers/) — clipboard utilities that pair with paste-curl (decode a token, normalise a cookie value)
- [HTTP history](/manual/http-history/) — every send (file-driven *and* scratch-pane) lands in `.rqst/history.jsonl` and is re-firable
- [Installing integrations](/manual/integrations/installing/) — how the `+` chip relates to the rest of the INTEGRATIONS rail
