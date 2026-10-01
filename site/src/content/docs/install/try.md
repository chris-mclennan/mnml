---
title: Try It First
description: Run mnml in a throwaway home with --sandbox, or open a ready-made sample project with --demo, without touching your own config, sessions or credentials.
---

Two flags let you look around before mnml has any of your settings:

- **`mnml --sandbox`** runs mnml against a throwaway home directory.
  You see what a brand-new user sees, and nothing you do reaches your
  real config, state or credentials.
- **`mnml --demo`** is a sandbox with something in it: a small Zig
  project with git history, a stand-in Claude Code session, and — in a
  source build — offline Jira and Bitbucket panes. It needs no network
  and no account.

Both remove everything they made when mnml exits.

> [!NOTE]
> Both flags are POSIX only: macOS and Linux. They work by mnml
> re-executing itself, which Windows cannot do, so on Windows mnml
> refuses the flag with a message. To get the same effect there, point
> `HOME`, `XDG_CONFIG_HOME` and `MNML_DATA_ROOT` at a throwaway folder
> yourself.

## `--sandbox`

```sh
mnml --sandbox                 # the sandbox's own empty workspace
mnml --sandbox ~/src/my-app    # your project, with a throwaway home
mnml --sandbox-keep            # the same, and the directory survives the exit
```

What happens, in order:

1. Before any config is read, mnml makes a directory named
   `mnml-sandbox-XXXXXXXX` under your temp folder (`$TMPDIR`, else
   `/tmp`).
2. It re-executes itself — the same process id — with these set on top
   of the environment you started it with. Everything else passes
   through unchanged.

   | Variable | Set to |
   | -------- | ------ |
   | `HOME` | the sandbox directory |
   | `XDG_CONFIG_HOME` | `<sandbox>/xdg` |
   | `MNML_DATA_ROOT` | `<sandbox>/xdg/mnml` |
   | `MNML_SANDBOX` | the sandbox directory |

3. mnml opens. Without a workspace argument it opens
   `<sandbox>/workspace`, an empty folder, not the directory you ran it
   from. With no config in the throwaway home, the
   [first-launch setup](/docs/getting-started#the-first-launch) appears,
   just as it would for someone who has never run mnml.

Anything started from inside — a shell pane, an integration, another
`mnml` command — inherits the same variables, so it is sandboxed too.

### What is real, and what is not touched

The sandbox swaps the **home**, not the machine. The programs are the
real ones on your `PATH`: a shell pane is your shell, `git` is your
`git`, and a Claude Code session is your `claude`, now starting from a
home with none of your sign-ins.

When you name a workspace, those are your real files: mnml edits and
saves them as usual. What the sandbox protects is everything mnml keeps
*about* you:

- your `config.zon`, your `init.lua`, installed integrations and their
  credentials all live under the real home, which this run never sees;
- the workspace's saved session is neither restored nor written on
  exit (`session.save` by hand still writes it);
- the running-instance marker is left to your real mnml, so tools that
  find "the running mnml" still find yours.

### Telling it apart

A yellow ` sandbox ` chip sits beside the mode on the statusline, the
window title reads `mnml [sandbox] — <workspace>`, and the first frame
shows a notice naming the directory. Click the chip to see the paths
again.

If `MNML_SANDBOX` is set but `HOME` is not actually a throwaway folder,
or the data root points outside it, the chip turns red and reads
` sandbox? `, with a warning that stays until you dismiss it — the run
is **not** isolated.

### Cleaning up

On exit, the process that made the directory removes it, and says so
on the terminal. `--sandbox-keep` keeps it instead and prints its path.

The same cleanup runs when mnml is told to stop rather than quit:
SIGTERM, SIGHUP or SIGINT — a closed terminal window, a `kill`, a
stopped container — end the run the way a quit does. The terminal is
given back, the directory is removed, and the exit status is 128 plus
the signal number (143 for SIGTERM). A second signal while that is
happening exits at once. Only a crash or `kill -9` leaves the directory
behind, for your OS's temp cleanup.

Two smaller rules:

- A nested mnml started in a shell pane never removes the sandbox, and
  mnml never removes a directory it did not make.
- If `HOME` is already a throwaway directory under the temp folder,
  `--sandbox` uses it as it is rather than making another.

`--sandbox` belongs to the app — the terminal UI and `--headless`. A
one-shot command such as `mnml run FILE` ignores it.

## `--demo`

```sh
mnml --demo
```

`--demo` opens its own workspace, so it takes no workspace argument,
and it will not start from inside a sandbox. Everything in it is made
fresh for the run and removed on exit.

What happens, in order:

1. **The sandbox.** Exactly as above: a throwaway home and a re-exec.
   On top of the sandbox's variables, the demo puts a folder of
   stand-ins first on `PATH`, points Jira and Bitbucket at offline
   servers, turns off the update check, and makes links open nothing.
   It also **removes** `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, the
   Bitbucket token variables and the integration config overrides from
   the environment, so nothing in the demo can reach a real account.
2. **The workspace.** A small Zig project called `tour` is written from
   files carried inside the mnml binary, and `git` gives it a history:
   five commits and a merge, a commit by a second author, an open
   `feature/cli-args` branch, then one modified file and one untracked
   file, so the git views have something to show. Without `git` the
   files are there and the history is not.
3. **The home.** A `config.zon` that skips the first-launch setup, an
   `init.lua` that sets up the first screen, three earlier agent
   transcripts for the sessions views, and configs for Jira and
   Bitbucket.
4. **The integrations and the offline servers.** If the Jira and
   Bitbucket integrations and the two offline servers
   (`mnml-fake-jira`, `mnml-fake-bitbucket`) sit beside the `mnml`
   binary, they are installed into the throwaway home and started on
   ports the OS picks.
5. **The first screen.** `src/util.zig` in the editor, a Claude Code
   session on its right, and a shell under that, with a ` demo ` chip
   where the sandbox chip would be.

The `init.lua` that draws that screen is the throwaway home's own: edit
it and save to watch a script reload.

### What is real, and what is a stand-in

| Part | Real or stand-in |
| ---- | ---------------- |
| mnml itself — the editor, splits, tree, git views, terminal panes, settings | Real. |
| The `tour` project and its git history | Real files and a real repository, made by your `git` for this run. |
| The shell under the session | Your real shell. |
| The Claude Code session | A **stand-in**: a short script named `claude` that prints a sample exchange and stays open. No model runs, nothing is sent anywhere, and no account is needed. `codex` is a stand-in too. |
| The three earlier sessions in the sessions views | Planted transcripts. |
| Jira and Bitbucket | The real integrations, talking to **offline stand-in servers** on your machine with sample data. |
| The request files in `requests/` | Real `.http` files, aimed at those offline servers. |

### Where the Jira and Bitbucket panes come from

The demo only uses what sits beside the `mnml` binary, and what is
missing is skipped and named in the first frame's notice — the rest of
the demo still opens.

- **A source build** (`zig build`) puts the integrations and both
  offline servers in `zig-out/bin` beside the binary, so
  `./zig-out/bin/mnml-zig --demo` opens all of it. See
  [Build from Source](/docs/install/build).
- **A release download or package** carries `mnml` alone. The demo
  then opens the project, the git history and the stand-in session,
  and its notice says the Jira and Bitbucket panes are not installed.

### Cleaning up

On exit — a quit, or SIGTERM, SIGHUP or SIGINT as described
[above](#cleaning-up) — the offline servers are stopped first, then the
whole sandbox, workspace included, is removed. The servers are also
told to exit when mnml's process does.

## Next

When you are ready for the real thing, run `mnml` in a project of your
own: [Getting Started](/docs/getting-started) walks through the first
launch.
