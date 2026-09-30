---
title: Build mnml from Source
description: Build mnml yourself with Zig, for when there is no prebuilt binary for your platform or you want to work on mnml itself.
---

> [!TIP]
> **Most people should not need this page.** Every release ships a
> prebuilt binary for macOS, Linux and Windows. See
> [Install](/docs/install) first; building from source is for platforms
> without a binary, and for working on mnml.

## Zig version

mnml builds with **Zig 0.16.0, exactly**. Zig is still changing from
release to release, so an older or newer compiler is not expected to
build it. The version is pinned as `minimum_zig_version` in
[`build.zig.zon`](https://github.com/chris-mclennan/mnml/blob/main/build.zig.zon),
and the release pipeline runs on nothing else.

| mnml version | Zig version |
| ------------ | ----------- |
| 0.3.x        | 0.16.0      |

If your package manager ships a different Zig, use a static build from
the [Zig downloads page](https://ziglang.org/download/).

## Dependencies

There are no system libraries to install. `zig build` fetches every
dependency itself and checks each one against the hash in
`build.zig.zon`: the terminal library (libghostty's `ghostty-vt` Zig
module), the vaxis terminal UI library, Lua 5.4, and the tree-sitter
grammars. The first build downloads them; later builds reuse Zig's
cache.

## Building

```sh
git clone https://github.com/chris-mclennan/mnml
cd mnml
zig build -Doptimize=ReleaseSafe
```

The binary is `zig-out/bin/mnml-zig`. `-Doptimize=ReleaseSafe` is the
same optimisation mode every release ships; a plain `zig build` is a
Debug build, which is noticeably slower to use.

Run it on a folder:

```sh
./zig-out/bin/mnml-zig ~/src/my-project
```

## Installing your build

On macOS and Linux, `./run.sh install` builds ReleaseSafe and installs
the result as `mnml` under `~/.local` (set `PREFIX` to change it). It
refuses to install from a tree with uncommitted changes, so every
installed binary can be traced back to a commit, and it will not
overwrite an `mnml` that is not this program without `--force`.

```sh
./run.sh install --dry-run   # print the plan, change nothing
./run.sh install
```

On Windows, `run.ps1` has the same `install` verb (Windows PowerShell
5.1 or PowerShell 7). It installs into `%LOCALAPPDATA%\Programs\mnml`.

## Running the tests

```sh
zig build unit        # the unit suite
zig build test        # the unit suite, then the end-to-end gate
zig build e2e         # the whole .test corpus
```

Every unit test and every `.test` script runs on a leak-checking
allocator, and a leak fails the test.

## Going further

If you want to work on mnml rather than just run it, read
[`docs/CONTRIBUTING.md`](https://github.com/chris-mclennan/mnml/blob/main/docs/CONTRIBUTING.md)
(the verification sequence a change goes through) and the
[README](https://github.com/chris-mclennan/mnml/blob/main/README.md),
which lists every `zig build` step and every `./run.sh` verb.
