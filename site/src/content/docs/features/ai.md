---
title: AI Coding Sessions
description: Run Claude Code and Codex sessions side by side in mnml's terminal splits, see every session on the machine in one table, and get ghost-text suggestions as you type.
---

mnml does not ship its own AI agent. It runs the ones you already use —
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) and
[Codex](https://github.com/openai/codex) — in terminal panes beside your
code, and adds what a terminal alone cannot: a layout for running
several at once, a view of which ones need you, a worktree per session,
and a record of what each one changed and spent.

## Sessions in splits

A session is the real `claude` or `codex` program running in a
[terminal pane](/docs/features/terminal), so everything it can do in
your terminal it can do here. mnml finds both on your `PATH`.

| Command | Keys | What it does |
| ------- | ---- | ------------ |
| `ai.claude_code` | `space a c` | A new Claude Code session. |
| `ai.claude_code_new_x2` / `_x4` / `_x8` | — | Open 2, 4 or 8 sessions at once. |
| `ai.codex` | `space a x` | Focus the running Codex session, or start one. |
| `ai.codex_new` | `space a X` | A new Codex session. |
| `ai.new_session_worktree` | — | A new Claude Code session in its own git worktree. |

The `space …` chords are the vim profile's leader; in the standard
profile `ctrl+k` opens the same which-key menu, so `ctrl+k a c` starts a
session. There are also `_left`, `_right`, `_top` and `_bottom`
variants that open a session in that half of the screen.

By default (`ui.ai_layout_mode = .grid`), Claude Code sessions tile
themselves: two sit side by side, the third makes a 2×2 grid, and the
grid grows to 3×2 and then 4×2. A ninth session starts a new tab page.
Every step gives the splits equal room. Set `ui.ai_layout_mode = .tabs`
to open each session as a tab instead.

mnml starts each Claude Code session with a session id of its own
choosing, so it knows which transcript belongs to which pane from the
first frame.

## Knowing which session needs you

With several sessions running, the question is which one is waiting on
you. The **SESSIONS** section of the sidebar shows a card per session
pane — its name and its last exchange — sorted so the ones that need
you come first. Sessions of this workspace that are running outside
mnml are listed under them.

mnml decides a session needs you from what is on its screen: a
question such as *Do you want to…*, a `(y/n)` prompt, or a numbered
choice. When one starts waiting:

- a notice names it, and its tab is badged;
- a desktop notification arrives when its pane is not the focused one
  (`ui.session_notify`: `off`, `unfocused` or `always`);
- the terminal bell rings if you set `ui.session_bell = true`.

`sessions.next_waiting` jumps straight to the next session that needs
you — `space a j` in the vim profile, `ctrl+alt+n` in the standard one —
and `sessions.prev_waiting` goes back (`space a k`,
`ctrl+alt+shift+n`).

## Every session on the machine

`ai.dashboard` (`space a d`) opens the **sessions table**: every Claude
Code and Codex session on this machine, grouped by workspace, whether
mnml started it or not. mnml reads the transcripts the two tools already
write (under `~/.claude/projects` and `~/.codex/sessions`) and checks
which processes are alive; it needs no hooks installed in either tool.

Each row shows the session's state — *waiting*, *live*, *tool*, *idle*,
*failed* or *done* — its name, tokens, estimated cost, age and how many
files are dirty in its working directory. The table refreshes every few
seconds.

| Key | Action |
| --- | ------ |
| `/` | Filter by text. |
| `f` | Cycle the state filter. |
| `s` | Sort by state, tokens, cost or most recent. |
| `p` | Pause or resume the live refresh. |
| `E` | Show ended sessions (hidden after a day). |
| `Enter` | Resume the session in a terminal pane (`claude --resume`). |
| `t` | Open its transcript. |
| `space` | Tick a row, for acting on several at once. |
| `K` | Stop the session, or every ticked one, after a confirm. |
| `R` / `P` | Rename or pin it. |
| `e` | Export the transcript as Markdown. |

`sessions.changes` shows what a session changed since it started —
committed and uncommitted — and lets you diff, stage and commit it.

## A worktree per session

Two agents editing the same checkout will trip over each other.
`ai.new_session_worktree` asks for a branch name, runs
`git worktree add -b <name>`, and starts the session inside that new
worktree, with its tab labelled `@ <name>`. By default the worktrees go
in a `<repo>-worktrees` folder beside your repository;
`ai.default_worktree_root` moves them.

When the session is done, the row commands finish the job:

- `sessions.merge_worktree` merges its branch into your main checkout
  (`git merge --no-ff`), and refuses if your checkout has uncommitted
  changes;
- `sessions.remove_worktree` removes the worktree and its branch, and
  asks again before discarding uncommitted or unmerged work;
- `sessions.open_worktree_in_tree` adds the worktree to the file tree.

When a session ends and its worktree is still there, mnml tells you how
many commits are waiting in it.

## Spend and usage

- `ai.spend_today` opens a report of tokens and estimated cost across
  every Claude Code and Codex session touched in the last 24 hours,
  per workspace. The cost comes from a built-in price table; a model it
  does not know shows as *unknown*, not as $0.00.
- The statusline's Claude chip shows your plan's session and weekly
  usage, as a percentage, from Anthropic's usage endpoint for your Claude
  Code sign-in (link it with `ai.link_claude_token`). The Codex chip
  shows today's tokens, from Codex's own session files.
  `ai.claude_usage` and `ai.codex_usage` open the detail.

## Ghost text

Ghost text is a grey suggestion at the cursor as you type. `Tab` takes
all of it, `ctrl+right` one word and `ctrl+down` one line; any other key
dismisses it. It works in the standard profile and in vim's Insert mode.

`ai.setup_suggestions` picks where suggestions come from:

| Backend | What is sent, and where |
| ------- | ----------------------- |
| `claude-code` | About 2,000 characters before the cursor and 1,000 after, to Anthropic, through your own `claude` command and plan. |
| `claude-api` | The same window, to Anthropic, with your `ANTHROPIC_API_KEY`. |
| `copilot` | The **whole open file**, to GitHub, through Copilot's language server — only in a workspace you have opted in. |

Nothing is sent while `ai.inline_suggestions` is `false` or no backend
is chosen. A chip on the statusline shows whether a suggestion is
pending, arrived empty or failed.

### Copilot is off until a workspace opts in

Copilot's protocol sends whole files, so mnml treats the workspace, not
the setting, as the unit of consent. Before anything is sent, all four
must hold: the backend is `copilot`; you ran `ai.copilot_enable_here` in
this workspace; the workspace is trusted, so a cloned repository cannot
opt itself in; and the file is not excluded — secret-looking names such
as `.env*`, `*.pem`, `*.key` and `id_*`, anything in
`ai.copilot.exclude`, and anything gitignored.

mnml never downloads Copilot's server: install
`copilot-language-server` yourself. `ai.copilot_status` says what is
being shared right now, and why.

## Asking about code

Besides full sessions, a handful of commands send the current selection
or file to Claude with a question: `ai.ask` (`space a a`), `ai.explain`
(`space a e`), `ai.fix` (`space a f`), `ai.refactor` (`space a r`),
`ai.write_tests` (`space a w`) and `ai.chat` (`space a C`). In git,
`git.ai_commit` (`space g m`) writes a commit message.

When one of these works through the Claude API and wants to write a
file, you confirm every write first. Writing is off unless you set
`ai.api_write_tools = true`.

The keys and settings for all of this are in the
[command reference](/docs/reference/commands) and the
[configuration reference](/docs/config/reference).
