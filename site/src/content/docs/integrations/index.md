---
title: Integrations
description: Integrations are separate programs that mnml opens in a pane, installed from inside mnml and updated on their own schedule.
---

An integration is a separate program that mnml runs and shows in a
pane. It paints inside mnml's chrome, answers keys and clicks, and can
add commands to the palette and chips to the statusline. It runs in its
own process and talks to mnml over a local socket; it is not a plugin
loaded into mnml itself.

That split is deliberate. The mnml download stays **one binary**, and
each integration is released, versioned and installed on its own. You
install only the ones you use.

## The first-party set

Three integrations live in the mnml repository, under
[`integrations/`](https://github.com/chris-mclennan/mnml/tree/main/integrations):

| Integration | What it shows |
| ----------- | ------------- |
| **Jira** | Three panes on one binary: *Work* (tickets assigned to you, and recently done), *Fix Versions* (the current release grouped by status, with linked pull requests and pipelines) and *Boards* (the active sprint and backlog). |
| **Bitbucket** | Pull requests (open and merged, yours and those awaiting your review) and recent pipeline runs per repository and branch, with statusline counts. |
| **Sample** | The SDK's sample: a small counter pane that answers keys and clicks. It is the starting point for writing your own. |

<!-- video: jira -->

Each is released on its own tag in the repository, named
`<id>-v<version>` (for example `jira-v0.2.0`). Jira and Bitbucket need
credentials for your account; each one's README has its setup:
[Jira](https://github.com/chris-mclennan/mnml/tree/main/integrations/jira),
[Bitbucket](https://github.com/chris-mclennan/mnml/tree/main/integrations/bitbucket),
[Sample](https://github.com/chris-mclennan/mnml/tree/main/integrations/sample).

### Jira and Bitbucket 0.2.0 could not read their sites

> [!WARNING]
> Jira 0.2.0 and Bitbucket 0.2.0, the versions offered with mnml 0.3.0,
> fail against a real site. Jira and Bitbucket compress their answers
> whenever the client allows it, and 0.2.0 handed the compressed bytes
> straight to the JSON parser: every Jira pane said *the search answer
> was not JSON*, and the Bitbucket panes failed the same way.
>
> Version 0.2.1 of both reads the answer through its compression. To
> get it, update mnml itself to 0.3.1 or later — the Marketplace lists
> the integrations built for the mnml you are running — then open the
> Marketplace tab, where an installed 0.2.0 reads *update available*,
> and install it again. See [Updating](/docs/integrations/marketplace#updating).

If a site still answers with something that is not JSON, 0.2.1's
message says what arrived: the content-type, the size and the first
bytes.

## Installing

There are two ways, and both do the same thing underneath:

- **The first-launch wizard.** Its last section lists Jira and
  Bitbucket as checkboxes. Nothing is ticked by default; whatever you
  tick is installed when you leave the wizard.
- **The Marketplace.** Press `ctrl+shift+x` for the INTEGRATIONS
  section and switch to its Marketplace tab. See
  [Marketplace](/docs/integrations/marketplace).

Either way, mnml downloads the build for your platform, checks its
sha256 before anything is written, and sets it up.

## On the top bar

An installed integration can put a chip on the top bar, in the run
right of the right-panel toggle. The chips sit three cells apart — the
toggle's own rhythm — and a click opens the integration.

A newly installed integration starts **off** the top bar, however it
was installed: from the Marketplace, a local folder, a launcher file,
or `<binary> --install` in a shell. To put it there, right-click its row
on the Installed tab (or its icon on the activity bar) and choose
*Show on top bar*; *Hide from top bar* takes it off again.

mnml remembers the choice in `integrations-top-bar.txt` in your data
root (`~/.config/mnml` unless you moved it), one line per integration,
`on <id>` or `off <id>`. A reinstall, an update or a rebuild keeps
what you chose there, even though an integration's `--install` writes
its manifest from scratch. Upgrading from an mnml that did not keep
this file leaves every integration where it already was. The built-in
chips are not integrations and keep their own defaults, so Browser
keeps its chip.

## Private integrations

An integration does not have to be published. You can point mnml at a
folder on your machine or at a GitHub repository, and its integrations
list and install beside the public ones. See
[Private Sources](/docs/integrations/private-sources).

## Anything else in a pane

Any program on your `PATH` can run in a terminal pane with
`:term <command>`, without being an integration at all. Integrations add
what a plain terminal cannot: palette commands, statusline chips,
menus, and panes drawn in mnml's own style.

## Writing one

Integrations are written in Zig against `mnml-sdk`, which ships in the
repository under `sdk/`. The [SDK reference](/docs/integrations/sdk)
starts from the sample and walks through the whole thing. If all you
need is commands, keys and hooks inside mnml,
[a Lua script](/docs/lua) is less work.
