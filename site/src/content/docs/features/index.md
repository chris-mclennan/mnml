---
title: Features
description: What mnml does, for people editing code and for people running AI coding agents alongside it.
---

mnml is a terminal IDE. It runs inside the terminal you already use —
locally or over SSH — as one binary with nothing else to install.

Its features serve two kinds of work, and most days are a mix of both.

**Editing code.** The editor itself: a Neovim-style modal keymap or a
VS Code-style modeless one, tree-sitter highlighting, language servers,
a debugger, git, an HTTP client, and terminal panes for everything else.
These are the features that make the hours you spend writing code
better, whatever else you are doing.

**Running AI agents alongside it.** More and more of the typing is done
by Claude Code or Codex, and the work becomes supervising several of
them at once. mnml runs those agents in its own splits, tells you which
one is waiting on you, gives each its own git worktree, and shows every
session on the machine in one table — while the editor stays right
there for reviewing and fixing what they wrote.

## Feature Highlights

- **[AI coding sessions](/docs/features/ai)**: Claude Code and Codex in
  terminal splits that tile themselves, a sessions table for every
  session on the machine, a git worktree per session, spend and usage
  on the statusline, and ghost-text suggestions.

- **[Two complete keymaps](/docs/features/editor#two-keymap-profiles)**:
  vim (Neovim and NvChad's chords, with which-key under `space`) or
  standard (VS Code's). Neither is an afterthought bolted onto the other.

- **[NvChad's chrome](/docs/features/editor#the-frame)**: a file tree,
  buffer line, powerline statusline and file icons, in NvChad's 94
  base46 colour themes — with a command palette, right-click menus and
  the mouse everywhere.

- **[Terminal panes on libghostty](/docs/features/terminal)**: shells,
  runners and tools in splits, emulated by the same library Ghostty is
  built on.

- **[Git](/docs/features/git)**: staging down to single lines, blame,
  a commit graph with an interactive-rebase planner, and conflicts
  resolved in the editor.

- **[Language intelligence](/docs/features/editor#language-servers)**:
  LSP for diagnostics, completion, navigation, rename, formatting and
  code actions; 41 tree-sitter grammars compiled in; a Debug Adapter
  Protocol debugger.

- **[An HTTP client](/docs/features/http)**: requests as `.http` and
  `.curl` files in your repository, environments, chains, mocks and
  history, and the same client on the command line.

- **Tests and tasks**: run the whole suite, one file, or the test at the
  cursor with your project's own runner (Cargo, npm, pytest, Go, Zig and
  others), re-run only the failures, and run configured tasks in
  terminal panes.

- **[Lua scripting](/docs/lua)**: an `init.lua` for your own commands,
  keys, hooks, statusline segments and pickers, with Lua 5.4 compiled in.

- **[Integrations](/docs/integrations)**: Jira and Bitbucket panes, a
  Marketplace to install them from, and private sources for your own.

- **Workspace trust**: settings in a repository you cloned that could
  run a program — a language server, a formatter, a task, a script — are
  held back until you trust that workspace, and you are asked once.

- **Everywhere**: macOS, Linux and Windows builds from one codebase.
  With a [Nerd Font](https://www.nerdfonts.com/) it draws icons; with
  `--ascii` it needs none.
