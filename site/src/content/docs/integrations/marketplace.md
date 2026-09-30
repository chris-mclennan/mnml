---
title: Marketplace
description: Browse, install, update and rebuild integrations from the INTEGRATIONS section's Marketplace tab.
---

The Marketplace is a tab in the INTEGRATIONS section. It lists the
integrations built for your version of mnml and your platform, and
installs them with one key.

## Opening it

Press `ctrl+shift+x` (in both keymap profiles) to open the INTEGRATIONS
section. It has three tabs:

| Tab | Key | What it holds |
| --- | --- | ------------- |
| Installed | `1` | What you have installed, with its commands and settings. |
| Marketplace | `2` | What you can install. |
| Dev | `3` | Integrations you are building from a local folder. Shown when `marketplace.show_dev_tab` is on. |

`Tab` cycles through them. From the command palette,
`integrations.show_marketplace` opens the Marketplace tab directly.

## Reading a row

Each row names the integration, its version and where it came from,
with its description on a second line. A badge says who publishes it:

- **✓ Official** — from mnml's own release index.
- **~ Community** — from a public source someone else maintains.
- **Private** — from a [private source](/docs/integrations/private-sources)
  you added.

A state follows: *not installed*, *installed*, or *update available*
when the index has a newer version than the one you have.

## Installing

Move to a row and press `i`, or right-click it and choose *Install*.
For a published integration, mnml:

1. picks the build for your platform from the index;
2. downloads it;
3. checks its sha256, and stops with nothing installed if it does not
   match;
4. unpacks the binary into your data root, under
   `integrations/<id>/bin/`, and links it into the data root's `bin/`;
5. runs the integration's own `--install` step, which registers its
   panes, commands and chips.

The integration's commands are in the palette as soon as it finishes.

<!-- video: marketplace -->

> [!NOTE]
> The data root is `~/.config/mnml` unless you have moved it with
> `MNML_DATA_ROOT`. A portable install keeps it in a `mnml-data` folder
> beside the binary instead.

## Where the list comes from

Every mnml release carries a file named `integrations.json` among its
release assets. That file is the index: for each integration, its
version, the SDK it was built with, and a download and sha256 for each
platform. The Marketplace reads the index that belongs to **your**
release, so it only offers integrations built for the mnml you are
running.

A row is listed only when both of these are true:

- it was built with an SDK your mnml supports, and
- there is a build for your platform.

Press `r` on the tab, or run `marketplace.refresh`, to fetch the list
again. The fetch runs in the background; mnml stays usable while it
does.

## Updating

When the index has a newer version of an integration you have, its row
says *update available*. Installing it again replaces the old build.

## Rebuilding

An integration built from a folder (a private source, or the Dev tab)
records which SDK it was built with. When your mnml moves to a newer
SDK, the Installed tab marks that row with a yellow `rebuild` chip.
`integrations.rebuild_focused` rebuilds the focused one from its folder;
`integrations.rebuild_stale` rebuilds every one that is behind.

If the folder it was built from is gone, or the integration was
downloaded rather than built, the chip reads `old SDK` instead, since
there is nothing to rebuild from. Install a newer version to clear it.

## Removing

Removal happens on the **Installed** tab: press `x` on a row, choose
*Uninstall…* from its right-click menu, or use the button in its detail
view. mnml asks first, then removes the integration's registration and
its link in the data root's `bin/`.

## Turning it off

Set `marketplace.enabled = false` in your `config.zon` (or switch the
*Marketplace* row in the settings overlay) and mnml makes no Marketplace
requests at all. Integrations you already installed keep working.

```zig
.{
    .marketplace = .{ .enabled = false },
}
```

The [configuration reference](/docs/config/reference) documents the
rest of the `marketplace` keys.
