---
title: Private Sources
description: Install integrations that are not published — from a folder on your machine or from a GitHub repository — through the same Marketplace.
---

Not every integration belongs in a public index. An integration for
your team's internal tools, or one you are still writing, can live in
a folder or a repository of your own, and mnml will list and install
it beside the published ones. Its rows are badged **Private**.

## Adding a source

There are four ways in, and they all run the same code:

- the Marketplace tab's **`+ source`** chip (it shrinks to ` + ` when
  the column is narrow);
- the tab strip's right-click menu, *Add a private source (a folder or
  owner/repo)…*;
- the command palette: `marketplace.add_source`;
- the first-launch wizard's **Private integrations** row, under the
  Jira and Bitbucket checkboxes.

Each one opens a one-line prompt. Type a folder or a GitHub
repository and press `Enter`; `Esc` or an empty line changes nothing.
A folder's integrations are listed straight away; a repository's
follow once GitHub answers.

## What you can type

**A folder.** Anything that starts with `/`, `~` or `.`, or that names
an existing directory, is read as a folder. `~` is expanded, and a
relative path is resolved against the workspace.

```text
~/src/my-integrations
```

**A GitHub repository**, as `owner/repo`, optionally followed by
`:dir` for the folder inside it that holds the integrations (the
default is `apps`):

```text
my-org/editor-tools
my-org/editor-tools:integrations
```

**A GitHub URL**, pasted as you copied it. All of these work:

```text
https://github.com/my-org/editor-tools
github.com/my-org/editor-tools
https://github.com/my-org/editor-tools.git
https://github.com/my-org/editor-tools/tree/main/integrations
git@github.com:my-org/editor-tools.git
```

A `/tree/<branch>/<dir>` URL keeps the folder and drops the branch.

mnml refuses, by name, a URL on any host other than GitHub, a GitHub
URL that names no repository, a path that is not a folder, and a folder
with nothing in it to install. It also notices a source you already
added under another spelling — a different case, or a symlink to the
same folder — instead of adding it twice.

## What a source folder holds

A source can hold two kinds of thing:

- **Integrations** — each in its own subfolder with a `build.zig` and a
  `manifest.zon`. A folder that is itself one integration counts too.
- **Launchers** — `*.zon` files that describe a chip for a program you
  already have on your `PATH`.

## How a private integration installs

Private integrations are installed from source, so you need
[Zig 0.16.0](https://ziglang.org/download/) on your `PATH`.

- **From a folder**, mnml runs `zig build -Doptimize=ReleaseSafe` in the
  integration's folder, installs the result under your data root, and
  remembers the folder so it can be rebuilt later.
- **From GitHub**, mnml clones the repository (`git clone --depth 1`)
  into your data root, or pulls it if it is already there, and then
  builds it the same way.

A private integration built from a folder is the one that gets a
`rebuild` chip when mnml moves to a newer SDK; see
[Rebuilding](/docs/integrations/marketplace#rebuilding).

> [!NOTE]
> mnml lists a GitHub source through GitHub's public contents API and
> sends no credentials when it does. A **private** repository therefore
> will not list: clone it yourself and add the folder instead.

## Where sources are saved

A new source is added to `marketplace.sources` in your **home**
`config.zon` — never a workspace's, so a repository you clone cannot
add a source for you. The file is edited in place, so its comments and
the sources already there are kept:

```zig
.{
    .marketplace = .{
        .sources = .{
            .{ .local_folder = .{ .id = "my-integrations", .path = "~/src/my-integrations" } },
            .{ .github_monorepo_apps = .{ .id = "editor-tools", .repo = "my-org/editor-tools", .apps_dir = "apps" } },
        },
    },
}
```

There is no command to remove a source yet: delete its line from
`config.zon`.

> [!TIP]
> With no sources configured at all, mnml also lists the folder
> `marketplace/local/` inside your data root. Put or symlink a folder of
> integrations there and it shows up for you alone, with no config.

## Writing an integration

The [SDK reference](/docs/integrations/sdk) covers the manifest, the
SDK and the Dev tab you build with while you work.
