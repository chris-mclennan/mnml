---
title: About mnml
description: What mnml is, why it is written in Zig and built on libghostty, and where it came from.
---

mnml is a terminal IDE. It gives you NvChad's look — a file tree, a
buffer line, a powerline statusline, file icons and the base46 colour
themes — around an editor you drive the way you already know: modal,
with Neovim's keys and NvChad's leader menus, or modeless, with
VS Code's. Language servers, a debugger, git, terminal panes, an HTTP
client and AI coding sessions are built in. It is one static binary, it
runs inside the terminal you already use, and it is scriptable in Lua.

mnml is a passion project, built by one person in their spare time. It
is not a company's product. Please keep that in mind when you file an
issue or a request.

## Two ways to type, no compromise

Most editors pick a side. Vim users get a modal editor and a plugin for
everything else; everyone else gets a modeless editor and a vim plugin
that is never quite right. mnml has **two complete keymap profiles**,
and neither is a layer over the other. The vim profile follows Neovim
and NvChad chord for chord; the standard profile follows VS Code.

This is a rule inside the code, not just a feature: the editor, the
panes and the renderer never ask which profile is active. Keys are
translated into editing operations at one boundary, so a feature added
for one profile works in the other without a special case.

## Why Zig

mnml is written in [Zig](https://ziglang.org). The reasons are
practical:

- **One static binary, no runtime.** There is nothing to install beside
  it, and nothing to keep in sync with it. The same tree builds for
  macOS, Linux and Windows.
- **Memory you can account for.** Every unit test and every end-to-end
  test runs on an allocator that fails the test if a single byte leaks.
  Release builds keep Zig's safety checks on.
- **The terminal core is Zig too** (below), so mnml uses it as a plain
  Zig module rather than through a C interface.

## Built on libghostty

mnml's terminal panes — shells, test runners, Claude Code and Codex
sessions — are emulated by **libghostty**, the core of the
[Ghostty](https://ghostty.org) terminal. Ghostty's authors describe it as
a cross-platform library that "provides the core terminal emulation" and
that aims "to enable other terminal emulator projects to be built on top
of a shared core". mnml is one of the projects that takes them up on it:
a program running in an mnml pane gets the same emulation it would get in
Ghostty. See [Terminal](/docs/features/terminal) for what that means in
practice.

mnml is not affiliated with Ghostty. It uses the library, and it works
well in Ghostty — it is developed in it — but it runs in any modern
terminal.

## Scriptable in Lua

Neovim users expect to shape their editor with an `init.lua`, and mnml
keeps that promise. Lua 5.4 is compiled into the binary; a script can
add commands, keys, hooks, statusline segments, pickers and panes. See
[Lua Scripting](/docs/lua).

## History

mnml began as a Rust project. The 0.2.x releases — the last was 0.2.22 —
were written in Rust, and that code is archived, read-only, at
[chris-mclennan/mnml-rust](https://github.com/chris-mclennan/mnml-rust).

mnml 0.3.0 is a rewrite from scratch in Zig. It kept what people used
0.2.x for — the same editor, panes, keymaps and look — and the 0.2.x
feature list was checked row by row until the new version matched it.
The rewrite is what made the single static binary, the leak-checked test
suite and libghostty's terminal core possible. The
[0.3.0 release notes](/docs/install/release-notes/0-3-0) tell the rest.

## License

mnml is free and open source, under your choice of the
[MIT](https://github.com/chris-mclennan/mnml/blob/main/LICENSE-MIT) or
[Apache 2.0](https://github.com/chris-mclennan/mnml/blob/main/LICENSE-APACHE)
license. The source is on
[GitHub](https://github.com/chris-mclennan/mnml).
