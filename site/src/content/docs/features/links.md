---
title: Links
description: URLs, ticket keys and pull-request references become links wherever mnml shows text — on session cards, in terminals, editors, previews and toasts — through one rule set the installed integrations declare.
---

A ticket key in a session's output, a pull request named in a commit
message, a URL in a test log: mnml turns each into a link wherever it
shows the text, and opens it in your browser when you ask.

mnml itself knows only one shape of link: a plain `http://` or
`https://` URL. Everything else — `ACME-123`, `widget#42` — links
because an installed integration says what it looks like and where it
goes. With no integration declaring a shape, only URLs link. There is
one rule set, built from the integrations you have installed, and every
place that shows text reads the same one.

## What links

Three kinds of text become links:

| Text | Example | Links because |
| ---- | ------- | ------------- |
| A URL | `https://example.com/build/7` | It starts `http://` or `https://`. Always on. |
| A ticket key | `ACME-123` | The [Jira integration](/docs/integrations) declares Jira's key shape and opens it on your site. |
| A pull-request reference | `widget#42` | The [Bitbucket integration](/docs/integrations) declares `<repo>#<number>` and opens that pull request in your workspace. |

A few rules hold for all of them:

- **A URL ends where the sentence does.** It runs to the next space,
  quote, `>`, `)` or `]`, less a trailing `.`, `,` or `;`.
- **Only web addresses open.** A `file://` or `javascript:` URL is never
  handed to a browser.
- **A declared shape matches a whole word.** No letter, digit or `_`
  may touch it on either side, so `XACME-1` does not yield `ACME-1`.
- **URLs come first.** A key inside a URL stays part of the URL.

### Ticket keys

The Jira integration declares any key in Jira's own shape — capital
letters and digits, a dash, a number — and opens it at
`<your site>/browse/<key>`. It is the shape of every Jira project, not
the projects you belong to, so a key from any project on your site
links.

Your site's address is written into the rule when you install the
integration, from its config's site URL; without one, mnml takes it
from `$JIRA_URL`. Until one of them has a value the rule is not in
force: nothing breaks, keys just do not link.

### Pull-request references

The Bitbucket integration links a pull request written the way people
write one: the repository, `#`, the number. `widget#42` opens pull
request 42 of the `widget` repository in your Bitbucket workspace.

When you install it, the integration reads its own config and narrows
the rule:

- The config's **workspace** is written into the address. Without a
  config, mnml takes the workspace from `$BITBUCKET_WORKSPACE`.
- If the config lists **repos**, only those repositories link —
  `widget#42` does, `elsewhere#42` does not. With no list, any
  repository name does.
- It adds the long form, `<workspace>/<repo>#<number>`, beside the short
  one.

A bare number links too — `Pull request 5505`, `PR #5505`,
`pipeline 10554` — when only one repository could mean it. Each repo is
at its own height (one in the 5000s, another in the 7000s), so the
integration's statusline poll publishes the lowest and highest pull
request and pipeline number it has seen in each, and mnml looks the
number up there, allowing 50 above the highest for one opened since the
poll. One repository: the number links to it. Several: it links to the
first — your workspace's own repository first — and its right-click
menu lists `Open in <repo>` for each. None, or before the first poll: it
stays plain text. In a terminal, Ctrl/Cmd+click opens it.

Some references never link:

- **A bare `#42`.** It names no repository, so there is nothing to open.
- **A reference inside a path**, such as `src/notes#3`.
- **`owner/repo#5`**, unless `owner` is your workspace. That owner may
  belong to another forge.

> [!NOTE]
> Ticket keys and pull-request references are new in the 0.2.2 releases
> of the Jira and Bitbucket integrations. Each integration writes its
> rule when it is installed, so an integration installed before then
> links nothing until you install it again. See
> [Updating](/docs/integrations/marketplace#updating).

## Where links show

Every surface that shows text it did not write goes through the same
rules:

- **SESSIONS cards** in the sidebar: a session's name, its output and
  its ticket chip.
- **The sessions table**: each row's summary.
- **Terminal panes**, including AI session panes.
- **Editors.**
- **The Markdown preview.**
- **The git graph**: a commit's message in the detail column.
- **Toasts.**
- **HTTP responses**: the response body.

How a link looks and opens depends on whether the surface already uses
a plain click for something else.

### On cards, panels, previews and toasts

A link wears a **dotted underline** in the text's own colour. Under the
pointer it lights in the theme's accent with a solid underline.

| Action | What it does |
| ------ | ------------ |
| Click | Opens the link in your browser. |
| Right-click | A menu with *Copy link* and *Open link*. |
| Wheel | Scrolls whatever the link sits on. A link never stops a list scrolling. |

A SESSIONS card's own menu also lists each link on the card as an
`Open …` row. Right-click the card for it, or press `Shift+F10`
(`view.context_menu_at_focus`) on the focused card.

### In terminal panes

A terminal pane shows links the same way — dotted at rest, lit under
the pointer — but a plain press there still starts a selection, as it
always has. To open a link:

| Action | What it does |
| ------ | ------------ |
| `Ctrl`+click (`Cmd`+click on macOS) | Opens the link. |
| Right-click | *Copy link* and *Open link*, above the menu's *Copy*. |
| Click or drag | Starts a selection, as before. |

A hyperlink the program printed itself (OSC 8) counts too, as it does in
Ghostty.

When the program in the pane takes the mouse — an editor, a pager in
mouse mode — clicks belong to it. Hold `Shift` as well, the same way you
would to select text yourself.

A link broken across two rows by the terminal's soft wrap links whole
on both rows. The pane matches a line only once it has held still for a
frame, so a flood of output costs nothing extra; the links appear the
moment the output stops.

### In editors

In an editor, a URL, ticket key or pull-request reference lights under
the pointer. Nothing is underlined at rest, so your code reads as it
always did.

| Profile | Open the link under the cursor | Open the link under the pointer |
| ------- | ------------------------------ | ------------------------------- |
| vim | `gx` | `Ctrl`/`Cmd`+click |
| standard | `editor.open_url_at_cursor` from the palette | `Ctrl`/`Cmd`+click |

Links a language server reports for the file (`textDocument/documentLink`)
take precedence and are underlined in the accent colour at rest.

## What a link names

A ticket key that an integration has lately polled says what it is.
Rest the pointer on `ACME-123` — on a card, in a terminal, wherever it
links — and a small box shows `ACME-123 · Fix the login redirect · In
Review`; right-click it and the menu's first row says the same. The
title comes from the shared recent-items cache, which the Jira
integration fills as a side effect of the polls it already makes (its
statusline figures and its pane's tabs), so it costs no request. When
the integration has not polled for a while, or its last poll failed,
the title stays and adds how old it is — `as of 3h ago`. A key the
cache has not seen links as before, with no title. Set
`recent_items.enabled = false` in the config to turn it off.

## Which link a menu is for

When you right-click a link in a terminal, on a session card or in the
sessions table, the link stays lit — the accent, a solid underline —
for as long as its menu is open. With several links on one line, you
can see which one *Copy link* and *Open link* will use before you choose.

## Where a link opens

A link opens in your operating system's default browser. To use a
different one, name it in `config.zon`:

```zig
.{ .ui = .{ .external_browser = "Firefox" } }
```

On macOS the name is an application (`open -a`); on Windows it goes
through `start`; elsewhere it is a program on your `PATH`. A workspace
you have not trusted cannot set it, so a repository cannot pick your
browser for you.

*Copy link* puts the address on the system clipboard, ready to paste in
another app.

## Declaring links in an integration

If you write an integration, its manifest can teach mnml a shape of
text. A manifest's `links` field is a list of pairs: a `pattern` to find
and a `url` template for the address it opens.

```zig
.links = .{
    .{ .pattern = "[A-Z][A-Z0-9]+-\\d+", .url = "{site_url}/browse/{0}" },
},
```

That is the Jira integration's own declaration.

### The pattern

`pattern` is a Perl-style regular expression, matched case-sensitively.
A match must stand alone as a word, and a match inside a URL mnml has
already linked is left to the URL. An empty pattern, or one that does
not compile, is refused with a warning toast naming the integration and
the index of the entry, such as `integrations: jira: links[0]: …`.

### The address template

`url` is a template with three kinds of placeholder:

| Placeholder | Becomes |
| ----------- | ------- |
| `{0}` or `{match}` | The whole match. |
| `{1}` … `{9}` | The pattern's capture groups. A group that took no part is empty. |
| `{<key>}` | A value the integration was configured with, such as `{site_url}`. |

Matched text is percent-encoded where a URL needs it. Whatever the
template expands to must start `http://` or `https://`; mnml refuses
anything else and toasts why.

A capture group carries part of the match into the address. This is
Bitbucket's declaration, as shipped:

```zig
.links = .{
    .{ .pattern = "(?<![/\\w.-])([A-Za-z0-9_.-]+)#(\\d+)", .url = "https://bitbucket.org/{workspace}/{1}/pull-requests/{2}" },
},
```

`{1}` is the repository and `{2}` the number. The lookbehind keeps a
path's `src/notes#3` and another forge's `owner/repo#5` from linking.

### Binding `{<key>}`

A `{<key>}` is bound once, when mnml reads the manifests, never for each
match. mnml looks for its value in this order:

1. **Your `--install`.** The integration can write the value in before
   it writes its manifest, from what only it knows, with
   `sdk.manifest.bindLinks`. The Jira integration writes its config's
   site URL this way; Bitbucket rewrites its whole rule from its config.
2. **The manifest's `settings[]`** entry of that key, if it has a value.
3. **The environment variable** that the `auth[]` field of that key
   names as its `env_fallback` — Jira's `site_url` falls back to
   `$JIRA_URL`, Bitbucket's `workspace` to `$BITBUCKET_WORKSPACE`.

A rule with a value still missing is not in force. That is not an
error: mnml notes it and moves on, and the rule takes effect once the
integration is set up and installed again, or `integrations.refresh`
reads the manifests again.

### Which rule wins

mnml builds the rule set when it reads the manifests — at startup,
after an install, and on `integrations.refresh` — never for each frame.
When text could match more than one rule, the first wins:

1. URLs.
2. Each integration's rules, in the order the INTEGRATIONS section lists
   the integrations (by label), and within one manifest in its own order.

So where two integrations both match the same words, the first one
listed opens. A disabled integration — its chip turned off — declares
nothing.

The [SDK reference](/docs/integrations/sdk) has the rest of the manifest
format, and the sample integration's `manifest.zon` carries a working
`links` entry to start from.

## Next

- [Integrations](/docs/integrations) — the Jira and Bitbucket
  integrations that declare ticket keys and pull-request references.
- [Terminal](/docs/features/terminal) — selecting, copying and the rest
  of what a terminal pane does.
- [AI sessions](/docs/features/ai) — the SESSIONS cards and the sessions
  table, where most links show up.
- [SDK](/docs/integrations/sdk) — writing an integration, `links` included.
- [Configuration reference](/docs/config/reference) — `ui.external_browser`
  and every other key.
