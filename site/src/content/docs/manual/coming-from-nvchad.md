---
title: Coming from NvChad
description: Translation guide for vim / NvChad users — input mode, motion + operator parity, the `<space>` leader trie, the chords that survive the move and the few that don't.
---

mnml was built by an NvChad refugee, for NvChad refugees. The vim input handler is first-class — not a "vim emulation layer" bolted onto a modeless editor — and the leader system is a built-in [which-key](/manual/editing/) trie under `<space>` with the chord vocabulary you already have in your fingers. If you came in from `nvim --clean` plus NvChad, almost everything you reach for already works.

This page is the migration map. It assumes you know vim. The job here is to point at the handful of places where mnml's chord differs from NvChad's, surface the new chords mnml added (Harpoon, integrations, AI panes), and tell you which Neovim feature isn't here so you can stop reaching for it.

## Set vim mode

`standard` is the default input style — flip it once and forget:

```toml
# ~/.config/mnml/config.toml
[editor]
input_style = "vim"
```

Or per-workspace at `<workspace>/.mnml/config.toml` if you want vim everywhere except one team's onboarding repo. Switch at runtime any time:

```vim
:set input=vim
:set input=standard
```

The runtime swap is non-destructive — your buffers, cursor, undo history, and macros survive the handler change. Toggle from the palette as **editor: toggle keymap**, the chord `<leader>tk`, or the bufferline mode chip. The architecture is documented in [Editing](/manual/editing/) — the short version is that both handlers translate keys into the same closed `EditOp` set, so the editor and every pane around it never branch on which mode is active.

If you launched mnml without setting the config, force it for one run:

```sh
mnml --input vim ~/some/project
```

## The chord translation

These are the chords NvChad ships with mnml's equivalents alongside. Categories follow how you'd actually learn them.

### Modes, motions, operators

These are pure-vim behavior, nothing to translate. mnml's vim handler covers them as you'd expect:

- Modes: `Esc` / `i` / `a` / `o` / `O` / `s` / `c…` / `v` / `V` / `Ctrl-V` / `R`
- Motions: `hjkl`, `wbge`, `0$^`, `f`/`t`/`F`/`T` plus `;` `,` repeat, `%`, `gg`/`G`, `H`/`M`/`L`, `Ctrl-D`/`Ctrl-U`/`Ctrl-F`/`Ctrl-B`, `{` / `}` for paragraph nav, `( )` for sentence nav
- Operators: `d` / `c` / `y` / `>` / `<` / `=` / `gU` / `gu` / `gq` / `gJ` (no-space join) / `~` (toggle case)
- Text objects: `iw`/`aw`, `i(`/`a(`, `i"`/`a"`, `ip`/`ap`, `is`/`as`, plus tree-sitter `if`/`af` (function), `ic`/`ac` (class), `ia`/`aa` (argument), `ii`/`ai` (indent)
- Visual-block (`Ctrl-V`) + `I` / `A` to insert/append on every line — the real multi-cursor for the column case

The `.` dot-repeat, jumplist (`Ctrl-O` / `Ctrl-I`), and changelist (`g;` / `g,`) all work. Macros (`qa…q@a`) and named/numbered registers (`"ay`, `"+y`, `"0p`) are persisted across restarts.

See [Editing](/manual/editing/) for the full operator + text-object inventory; this page won't repeat it.

### Buffers, tabs, splits

| What you do in NvChad | What it is in mnml |
|---|---|
| `:e <file>` | `:e <file>` — opens new buffer (creates if missing) |
| `:bn` / `:bp` / `:bd` | `:bn` / `:bp` / `:bd` (also `:b <name>` fuzzy match) |
| `<leader>fb` (buffer picker) | `<leader>fb` |
| `:tabnew` / `gt` / `gT` / `:tabclose` | All present |
| `:vsp` / `:sp` | `:vsplit` / `:split`, plus the `<leader>sv` / `<leader>ss` chords |
| `Ctrl-w h/j/k/l` | `Ctrl-w h/j/k/l` (also `<leader>sh`/`sj`/`sk`/`sl`) |
| `Ctrl-w w` cycle | `Ctrl-w w` (also `<leader>sw`) |
| `Ctrl-w c` close | `Ctrl-w c` or `Ctrl-w q` (also `<leader>sc`) |
| `Ctrl-w =` equalize | `Ctrl-w =` |
| `Ctrl-w o` close-others | `Ctrl-w o` (also `<leader>so`) |
| `Ctrl-w >` `<` `+` `-` resize | `Ctrl-w >` `<` `+` `-` |
| `Ctrl-w T` move to new tab | `Ctrl-w T` |
| `Ctrl-w f` split-open file under cursor | `Ctrl-w f` |
| `Ctrl-w d` split + goto definition | `Ctrl-w d` |
| `Ctrl-w n` new scratch split | `Ctrl-w n` |

`Ctrl-w H/J/K/L` (move split to the far edge of the parent) and `Ctrl-w x` / `Ctrl-w r` (swap / rotate) work too. Maximize the active split with `Ctrl-w _` (height) or `Ctrl-w |` (width).

### Search, find, jump

| NvChad | mnml |
|---|---|
| `/pattern` `?pattern` `n` `N` `*` `#` | All present |
| `:noh` / `:nohlsearch` | `:noh` / `:nohlsearch` |
| `:%s/old/new/g` (and `/gc` confirm) | Yes — including ranges, `:'<,'>s/…`, `:s//repl/g` repeat-search |
| `:g/pattern/d` / `:v/pattern/d` | Present |
| `gf` open file under cursor | `gf` (mnml maps to `editor.open_at_cursor`) |
| `gx` open URL under cursor | `gx` (opens in OS browser) |
| `gd` / `gD` LSP goto def / declaration | `gd` / `gD` |
| `Ctrl-]` jump to tag (= goto def) | `Ctrl-]` (mapped to `lsp.goto_definition`) |
| `Ctrl-T` jump back | `Ctrl-T` (mapped to `nav.back`) |
| `K` hover docs | `K` (LSP hover popup) |

`gi` (jump to last-insert + insert), `gI` (insert at column 0), `gv` (restore last visual), `g;` / `g,` (changelist) are present.

### Marks, registers, macros

All present with vim's exact semantics:

- `ma` set local mark, `mA` global mark
- `'a` jump to line, `` `a `` jump to exact column
- `"ay` / `"ap`, `"+y` / `"+p` (system clipboard), `"*y` / `"*p` (X11/Wayland primary)
- `"0p` last yank, `"1p`–`"9p` delete ring
- `qa`…`q` record, `@a` replay, `5@a` replay 5×, `@@` repeat last

Marks + macros persist across mnml restarts via per-workspace `<workspace>/.mnml/` storage. The delete ring resets at startup (vim parity).

### Insert-mode helpers

- `Ctrl-R <reg>` paste register inline (vim canonical)
- `Ctrl-V <key>` insert next keystroke verbatim (use for literal Tab, etc.)
- `Ctrl-O <cmd>` one-shot Normal — fire one normal command then back to Insert
- `Ctrl-N` / `Ctrl-P` walk the completion popup
- `Ctrl-Space` request LSP completion explicitly

### Folding

`za` toggle, `zc` close, `zo` open, `zR` open-all, `zM` close-all, `zf` create fold (visual or with motion). LSP-supplied fold ranges + indent-fallback folds both work; `za` toggles whichever applies at the cursor.

## The `<leader>` trie

`<space>` is the leader in vim mode (it's `Ctrl-K` in standard mode — same trie, different entry chord). After `<space>` a which-key popup paints the available continuations. Press the next char to descend; press `Esc` to back out. Press `?` at the root for a full cheatsheet pane.

What follows is every chord the built-in trie ships with. Source of truth: `src/whichkey.rs`. Categories match the trie groups.

### `<leader>f` — find

| Chord | Command | Notes |
|---|---|---|
| `<leader>ff` | `picker.files` | Fuzzy file picker (NvChad parity) |
| `<leader>fb` | `picker.buffers` | Open-buffer picker |
| `<leader>fg` | `find.grep` | Workspace live-grep (NvChad parity — added 2026-06-08) |

`:Rg <pattern>` / `:vimgrep` and `Ctrl-Shift-F` also work for the workspace-grep pane.

### `<leader>b` — buffer

| Chord | Command |
|---|---|
| `<leader>bn` | `buffer.next` |
| `<leader>bp` | `buffer.prev` |
| `<leader>bd` | `buffer.close` |
| `<leader>br` | `buffer.reopen` (reopen the last-closed) |

NvChad's "close all but this" doesn't have a chord today — palette: **buffer: close others**.

### `<leader>t` — toggle

| Chord | Command |
|---|---|
| `<leader>te` | `view.toggle_tree` (file explorer) |
| `<leader>tk` | `editor.toggle_keymap` (vim ⇄ standard) |
| `<leader>tt` | `theme.pick` (theme picker) |
| `<leader>th` | `view.toggle_hidden` (hidden files in focused tree node) |
| `<leader>tH` | `view.toggle_hidden_all` (hidden files everywhere) |

### `<leader>g` — git

A deeper surface than NvChad ships. The full git story is on [Git](/manual/git/).

| Chord | Command |
|---|---|
| `<leader>gd` | diff file |
| `<leader>gD` | diff worktree |
| `<leader>gA` | diff all vs HEAD (multi-file) |
| `<leader>gp` | peek change at cursor |
| `<leader>gb` | blame toggle |
| `<leader>gc` | commit |
| `<leader>gl` | commit graph |
| `<leader>gs` | status / staging pane |
| `<leader>gm` | AI (Claude) commit message |
| `<leader>gM` | AI rewrite of HEAD's message |
| `<leader>gx` | Codex commit message |
| `<leader>go` | checkout branch |
| `<leader>gn` | new branch |
| `<leader>gw` | worktrees → shell |
| `<leader>gS` | stash (prompts for message) |
| `<leader>gP` | stash pop |

### `<leader>l` — LSP

| Chord | Command |
|---|---|
| `<leader>la` | code actions |
| `<leader>lc` | complete at cursor |
| `<leader>ls` | symbols in this file |
| `<leader>lS` | workspace symbols |
| `<leader>lo` | outline pane |
| `<leader>ld` | goto definition |
| `<leader>lh` | hover docs |
| `<leader>lr` | find references |
| `<leader>lR` | rename symbol |
| `<leader>le` | diagnostics list |
| `<leader>ln` | next diagnostic |
| `<leader>lp` | prev diagnostic |

### `<leader>s` — split

Mirror of `Ctrl-w` but via leader — handy when you set up a layout from scratch.

| Chord | Command |
|---|---|
| `<leader>sv` | split right |
| `<leader>ss` | split down |
| `<leader>sh/j/k/l` | focus left/down/up/right |
| `<leader>sw` | focus next split |
| `<leader>sc` | close split |
| `<leader>so` | close others |

### `<leader>h` — HTTP client

mnml ships an in-editor HTTP client (`.http` / `.curl` / `.rest` files). See [HTTP client](/manual/http/).

| Chord | Command |
|---|---|
| `<leader>hs` | send request |
| `<leader>hy` | copy as curl |
| `<leader>hd` | ask Claude (debug) |

### `<leader>T` — test (capital T)

| Chord | Command |
|---|---|
| `<leader>Ta` | run all |
| `<leader>Tf` | run this file |
| `<leader>Tt` | run test at cursor |
| `<leader>Tl` | re-run last-failed |
| `<leader>Th` | heal failing test (Claude) |
| `<leader>Tw` | flaky/wobbly dashboard |

### `<leader>P` — PRs (capital P)

| Chord | Command |
|---|---|
| `<leader>Pp` | cross-host PR picker |
| `<leader>Pr` | refresh cross-host cache (background) |

See [Cross-host PR workflow](/manual/cross-host-prs/).

### `<leader>i` — integrations

The integration siblings (forge / cloud / observability viewers) launch from here. Each chord opens a separate sibling binary as a [pane](/manual/integrations/installing/) — the sibling has to be installed for the chord to do anything visible.

| Chord | Command | Sibling |
|---|---|---|
| `<leader>ib` | Bitbucket viewer | `mnml-forge-bitbucket` |
| `<leader>ig` | GitHub viewer | `mnml-forge-github` |
| `<leader>il` | GitLab viewer | `mnml-forge-gitlab` |
| `<leader>iz` | Azure DevOps viewer | `mnml-forge-azdevops` |
| `<leader>ij` | Jira viewer | `mnml-tickets-jira` |
| `<leader>ic` | AWS CodeBuild | `mnml-aws-codebuild` |
| `<leader>iw` | CloudWatch Logs | `mnml-aws-cloudwatch-logs` |
| `<leader>ia` | AWS Amplify | `mnml-aws-amplify` |
| `<leader>iL` | AWS Lambda | `mnml-aws-lambda` |
| `<leader>ie` | AWS EventBridge | `mnml-aws-eventbridge` |
| `<leader>id` | DynamoDB | `mnml-db-dynamodb` |
| `<leader>is` | S3 browser | `mnml-fs-s3` |
| `<leader>iA` | Azure Blob | `mnml-fs-azure-blob` |
| `<leader>iR` | RDS | `mnml-aws-rds` |
| `<leader>iC` | ECS | `mnml-aws-ecs` |
| `<leader>iE` | ECR | `mnml-aws-ecr` |
| `<leader>io` | Cognito | `mnml-aws-cognito` |
| `<leader>iq` | SQS | `mnml-aws-sqs` |
| `<leader>iN` | SNS | `mnml-aws-sns` |
| `<leader>iD` | Datadog | `mnml-datadog` |
| `<leader>iK` | Docker | `mnml-docker` |
| `<leader>iF` | Cloudflare | `mnml-cloudflare` |
| `<leader>iG` | Gmail | `mnml-gmail` |
| `<leader>iS` | Slack | `mnml-slack` |
| `<leader>iT` | Teams | `mnml-teams` |
| `<leader>iM` | Mandrill | `mnml-mandrill` |
| `<leader>iB` | Buttondown | `mnml-buttondown` |
| `<leader>ih` | `htop` | system binary |
| `<leader>iI` | `iftop` | system binary |

### `<leader>a` — AI / terminal

| Chord | Command |
|---|---|
| `<leader>aa` | ask Claude |
| `<leader>ae` | explain selection |
| `<leader>af` | fix bugs |
| `<leader>ar` | refactor |
| `<leader>aw` | write tests |
| `<leader>am` | mirror Claude session |
| `<leader>ac` | open Claude Code |
| `<leader>aC` | Claude chat (with context) |
| `<leader>ax` | open Codex |
| `<leader>at` | shell pane |
| `<leader>aM` | mixr DJ panel |

### `<leader>I` — insert (capital I)

Note the capital — lowercase `i` is taken by integrations. NvChad's `<leader>i` for "insert" needed to move; capital `I` keeps the muscle memory close.

| Chord | Command |
|---|---|
| `<leader>Is` | snippet picker |
| `<leader>Ix` | expand snippet at cursor |

### `<leader>H` — Harpoon (capital H)

The [ThePrimeagen Harpoon](https://github.com/ThePrimeagen/harpoon) idiom — pin a small set of "I keep coming back to these" files, jump to them by index. mnml ships it as a built-in.

| Chord | Command |
|---|---|
| `<leader>Ha` | pin active file |
| `<leader>Hm` | menu / picker |
| `<leader>1` … `<leader>9` | jump to harpoon slot 1–9 |

### Top-level leader chords

| Chord | Command |
|---|---|
| `<leader>w` | save (write) |
| `<leader>q` | close buffer |
| `<leader>e` | toggle file tree |
| `<leader>p` | command palette |
| `<leader>o` | run task (palette-style task runner) |
| `<leader>m` | markdown preview |
| `<leader>B` | open browser (Chrome via CDP) |
| `<leader>r` | restart mnml |
| `<leader>?` | cheatsheet pane (every chord → command) |

## Differences worth knowing

Honest list of places where NvChad muscle memory doesn't translate cleanly.

### `<leader>i` is integrations, not insert

NvChad puts "insert" group under `<leader>i`. mnml has 28 integration siblings (one of them named `mnml-tickets-jira` — `<leader>ij`), so `<leader>i` is the integrations group. Snippets live under capital `<leader>I` instead. The trie test `integrations_group_is_reachable` enforces this — there was a regression in May 2026 where the two groups collided and silently nuked integrations.

### `<leader>w` closes a buffer? No — it saves

`<leader>w` is `file.save` (write). For "close buffer" use `<leader>q` (or `:bd`, or `<leader>bd`). The single-letter `<leader>w` matches more of the vim-ism of `:w` than NvChad's "window-close" interpretation.

### `Ctrl-D` / `Ctrl-U` half-page scroll vs multi-cursor

NvChad keeps `Ctrl-D` as vim's half-page-down. In mnml's vim mode it's the same — `Ctrl-D` scrolls a half page. (mnml's standard-mode `Ctrl-D` is the VS-Code-style "add next occurrence" multi-cursor chord, but that's a different mode entirely.)

### Telescope is `picker.*`, not `Telescope`

There's no `:Telescope` ex command. The two pickers you'd want:

- `Ctrl-P` opens the file picker (also `<leader>ff` / `picker.files`)
- `Ctrl-Shift-P` opens the command palette (also `F1`)

Fuzzy-search is built-in across both — `Ctrl-N` / `Ctrl-P` walk results, `Enter` picks.

### `:Telescope find_files` etc. — palette instead

The command palette (`Ctrl-Shift-P` / `<leader>p`) is the catch-all. Every command — every chord, every ex command, every plugin action — is reachable from it by name. If you forget a chord, search the palette for what you want to do.

### Plugin manager — there isn't one

mnml's "plugins" model is two parts: registered commands (Rust-side, in `src/command.rs`) and out-of-process sibling binaries hosted via [blit-host](/manual/integrations/installing/). There's no Lua, no Packer/Lazy, no per-buffer autocmds. If you need a thing, either it's already there as a command + chord, or you write a sibling.

### Treesitter is on by default — no `:TSInstall`

Tree-sitter highlighting + text objects (`if`/`af`, `ic`/`ac`, `ia`/`aa`, `ii`/`ai`) are baked in. Languages are bundled, no per-install step. If a language isn't highlighting, file an issue — that's a missing grammar, not a config problem.

### No `which-key.nvim` plugin to configure — the trie IS the config

The leader trie is the source of truth at `src/whichkey.rs`. A `[keys.leader]` config overlay for user-extensions is a planned refinement (today the trie is built-in); the popup itself is always on.

## First-launch checklist

A 60-second path from "fresh install" to "I can work like I did in NvChad."

1. **Set vim mode** in `~/.config/mnml/config.toml`:

   ```toml
   [editor]
   input_style = "vim"
   ```

2. **Launch** in your workspace:

   ```sh
   mnml ~/some/project
   ```

3. **Check the mode chip** in the bottom-left of the statusline. It should read `NORMAL` (block cursor). If it doesn't, `:set input=vim` and try again.

4. **Try a leader chord** — press `<space>`, wait a beat, the which-key popup should paint. Press `f` to descend into find, then `f` to open the file picker.

5. **Press `<leader>?`** to open the cheatsheet pane — every chord, every command, searchable.

You're in. The rest is muscle memory you already have.

## Next

- [Editing](/manual/editing/) — the architectural framing, ex commands, vim-surround, multi-cursor specifics
- [Settings & configuration](/manual/settings/) — TOML schema, the settings overlay, every config knob
- [LSP](/manual/lsp/) — language servers, completion, code actions, refactors
- [Git](/manual/git/) — the deeper git workflow under `<leader>g`
- [Cross-host PR workflow](/manual/cross-host-prs/) — `<leader>Pp` + the multi-host PR cache
- [Coming from VS Code](/manual/coming-from-vscode/) — the other half of the migration story, for teammates
