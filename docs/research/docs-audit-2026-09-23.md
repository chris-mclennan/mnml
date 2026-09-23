# Docs audit — 2026-09-23

Twenty branches merged in a day, each appending rows to the user-facing
docs. This pass held every claim in the files below against the source,
by a grep or a run, and fixed what was wrong in place. Base: `main` at
`d34360fc`.

## Method

| file | how it was checked |
|---|---|
| `docs/CONFIG.md` | a throwaway test (not committed) parsed the ```` ```zon ```` block with the loader's own `parseLayer` and walked `Patch(Config)` against `Config{}`: every leaf the block leaves out, every scalar that differs from the default, every enum's tags. A script compared each `// .a \| .b` comment with the tags. The settings row count was counted from `src/app/settings.zig`'s `rows`; the clamps from the `*_min` / `*_max` constants and `load.zig`'s `normalize`. Every backticked command id in the prose was looked up in `src/commands/specs.zig`. |
| `docs/KEYMAP_PROFILES.md` | a parser over `specs.zig` produced every id's `vim` / `standard` / `both` / `vim_handler` chords; a script checked each row of *Every move made*, and the section, debugger and shifted-F-key tables were read against that output, the vim handler's `.window` switch in `src/input/vim.zig`, `src/app/whichkey.zig` and `src/tui/legacy_fkeys.zig`. |
| `docs/PARITY.md` | a script counted the `\| feature \| status \|` rows per section and found rows whose first cell repeats; 100 `done` rows were sampled at random (seeds 923, 7, 31, 99) and every backticked path and identifier in their "where" cell was checked for existence. `zig build -Dpartial=false` built (every id has a runner); `= cutRunner(` was counted. |
| `docs/CONTRIBUTING.md` | the gate list against `~/Backups/mnml-zig/scripts/chain-scrub.sh`, `run.sh check`, `build.zig`'s `check` / `arena-audit` / `chrome-audit` / `glyph-audit` / `hover-audit` steps and `tools/linux/entrypoint.sh`; named functions, tests and files grepped. |
| `docs/CONVENTIONS.md` | every backticked path and identifier grepped. |
| `docs/LUA.md` | `src/scripting/doc_check.zig` already holds the `####` headings against `api.zig` both ways; the contents table, prose `mnml.*` mentions, the hook table against `src/core/hooks.zig`, and the `script.*` table against the spec table were checked by hand. |
| `docs/SDK.md` | every `sdk.*` / `mnml_sdk.*` name against a `pub` declaration under `sdk/mnml-sdk/src`; the package layout against the directory. |
| `docs/commands.md` | `zig build docs` — no diff. |
| `docs/ui-spec/README.md` | every file it names (brace forms expanded) against the directory, and every `.txt` / `.jsonl` in the directory against a mention. |
| `README.md`, `docs/INSTALL-CHECKLIST.md` | every `run.sh` / `run.ps1` verb and flag against the scripts' `case` / `switch`; `mnml-jira --write-config`, `mnml-fake-jira --url-file`, `JIRA_BASE_URL=@file`, the refusal and `--version` strings against the source. |

## Drift found

| file | claim | truth | fix |
|---|---|---|---|
| CONFIG.md | the complete file names every key | `.ipc.allow_input` and the whole `.integrations.request_log` section were missing | added, at their defaults, with the comments `Config.zig` gives them |
| CONFIG.md | `.dock.labels` is `.icon_label \| .icon` | `DockLabels` also has `.label` (the word alone) | third value documented |
| CONFIG.md | `.tab_bar_ai_icon = .claude_code,` (no values) | `.none \| .claude_code \| .codex \| .both` | values listed |
| CONFIG.md | sections in schema order | `.cloud_run` / `.jira` / `.cloud_agents` sat at the end; `Config.zig` declares them after `.terminal` | moved |
| CONFIG.md | settings overlay: "73 rows in all"; number rows end at `chord_timeout_ms` | 104 rows plus the Reset row; `ai.suggest_idle_ms` and `ai.suggest_timeout_ms` are number rows too | count and list corrected |
| CONFIG.md | the block's test means "it cannot drift from the schema" | the test rejects unknown keys and missing sections; it does not compare values with the defaults | the note says what the test checks |
| CONFIG.md | — | `## Terminal panes` had no blank line before it | added |
| KEYMAP_PROFILES.md | `[keys.global]` / `[keys.vim]` / `[keys.standard]`, a `[keys.*]` line | the config is ZON: `.keys.global` / `.keys.vim` / `.keys.standard` | ZON spelling |
| KEYMAP_PROFILES.md | `view.toggle_tree`: vim `Ctrl-N`, `<leader>e` | `<leader>e` is `view.focus_tree`; the toggle is `<leader>te` | corrected |
| KEYMAP_PROFILES.md | `view.focus_right_panel`: `Ctrl+K R` | the spec binds `ctrl+k r` (lowercase) | corrected |
| PARITY.md | one row per feature | External linters, Code actions — quick-fix, Code actions — refactors + picker, and `dotnet test` in the results pane each appeared twice (keep-both merges) | one copy each, the one with the later notes |
| PARITY.md | totals: 552 done / 9 cut of 561 | 595 done / 7 cut of 602 once deduped and the two flips below applied; eight sections' counts were stale | table regenerated; a note that the jira (45) and bitbucket (42) sections are counted apart |
| PARITY.md | "Ids: 1039 … 1039 have runners (35 … `cutRunner`)" | 1120 spec ids, all with runners (`-Dpartial=false` builds), 32 `cutRunner` | corrected |
| PARITY.md | Curated `+` menu: `plus_sections`, New / Open / Panels / Tools / Integrations | `plus_tree` + `curate`: New / Open / AI / Dock, then the integrations group; *Reopen last closed (N)* leads | corrected |
| PARITY.md | Marketplace: `Pane.marketplace`, `src/ui/marketplace_view.zig` | no such pane variant or file; the Marketplace is a tab of `Pane.integrations`, painted by `src/ui/integrations_view.zig` | corrected |
| PARITY.md | Source-aware dispatch (mixr / AppleScript): `cut` | `now_playing.zig` drives Music / Spotify through `osascript`; only mixr's IPC is cut (a toast) | `done`, with the cut half named |
| PARITY.md | Idle `♪` chip, `preferred_music_app`: `cut`, "config keys accepted and ignored" | the idle form is painted from `ui.preferred_music_app` (`Source.ofPreferred`) and the player menu writes it | `done` |
| CONTRIBUTING.md | the gate: fmt over `src build.zig tools`, Debug + ReleaseSafe tests, …, hover-audit as 7b | the chain runs 14 steps: work-data audit, fmt over build.zig / build.zig.zon / src / themes / tools / integrations / sdk, arena-audit, `-Dpartial=false`, ReleaseSafe unit with `-Dtest-trace`, the Windows compile, glyph-audit, the ReleaseSafe build, the sweep, the corpus, pty-mouse, the two integration suites, run-sh-check, `zig build docs` | list rewritten in the chain's order; chrome / hover audits, pty-cursor, ui-diff and run-ps1 moved to "when the change reaches them" |
| CONTRIBUTING.md | step 7 repeated "`data/nerd-glyphnames.json`, with its `--ascii` twin;" | a merge left the line twice | gone with the rewrite |
| CONTRIBUTING.md | glyph-audit checks "every Nerd Font literal in `src/`" | `src/`, the SDK and `integrations/` (`build.zig`) | corrected |
| CONTRIBUTING.md | arena-audit "walks `src/` for the shape" | three walks: frame strings over `src/`, job-result arenas over `integrations/` and `sdk/`, inline `Io.Group` & co. in `Pane` payloads over `src/` | all three named |
| CONTRIBUTING.md | `./run.sh check` runs "1–5, 7, 7b, 11 and 12" | the numbers no longer mean anything after the rewrite | described by what it runs |
| CONTRIBUTING.md | `zig build check`: "… the sweep and `defaults.test`" | it also runs the whole corpus (`build.zig`) | corrected |
| CONTRIBUTING.md, README.md | "the 47-file Phase-0 gate" | `tools/gate.txt` lists 52 files | 52 |
| CONTRIBUTING.md, README.md | 394 `.test` files, 393/393; 1205 unit tests | 825 `.test` files (one `# requires: network`, three parked `*-skip`); the counts rot every merge | file count corrected; pass and unit counts replaced by where to read them |
| CONTRIBUTING.md | the corpus "~2.5 min" | at 825 files a partial run here did 79 in about six minutes | timing dropped |
| README.md | the gate paragraph and "`./run.sh check` runs all of it but the Windows gate-build and the two pty scripts" | out of step with the chain; `run.sh check` also skips ui-diff, the arena audit, `-Dpartial=false` and the integration suites | rewritten to match CONTRIBUTING |
| LUA.md | `save_pre` fields: `path`, `pane` | `HookArgs.save_pre` also carries `auto`, and `callHook` pushes every field | `auto` documented |
| SDK.md | the package layout | `zon_edit.zig` and `pane/{action,build,merge,figure,work,expect,consistency_test}.zig` were missing | added |
| ui-spec/README.md | every dump described | `rust-editor`, `rust-diff`, `rust-outline` and `rust-request` (cut by `steps-http.jsonl`) were only mentioned in passing | a bullet each |

Per file: CONFIG.md 7, KEYMAP_PROFILES.md 3, PARITY.md 7, CONTRIBUTING.md 9
(two shared with README.md), README.md 3, LUA.md 1, SDK.md 1,
ui-spec/README.md 1, CONVENTIONS.md 0, INSTALL-CHECKLIST.md 0,
commands.md 0.

## Held as written

- Every scalar in CONFIG.md's block equals `Config{}`'s default (the
  walk found no difference); every `clamped to a..b` comment matches its
  constant or `normalize`; every command id the prose names exists.
- The 18 `ctrl+k …` standard chords ("eighteen"); no `both` chord on a
  vim-reserved `ctrl+` letter; the nine shifted-F-key commands; the
  Terminal.app / rxvt code tables; the `dap.*` tables; the quick-open
  prefixes (`cmd_picker.zig`).
- The workspace-trust table's rows against `trust.zig`'s `Sink`s.
- `docs/commands.md` (1120 commands in 49 groups) — `zig build docs`
  leaves it as it is.

## Not verified

- PARITY rows outside the 100 sampled: only their counts were checked.
  The sample checks that named files and symbols exist, not that the
  behaviour in the note is what the code does.
- Screen-level claims in `docs/ui-spec/README.md` (which row a thing
  paints on, diff counts such as "reads 38 beyond the rail") — they need
  `tools/ui-diff.sh` runs on a private fixture copy.
- INSTALL-CHECKLIST's per-step pass criteria on a guest (the fake Jira's
  twelve tickets, font install, Windows steps) — nothing here runs the
  guests.
- `tools/linux/run.sh corpus`'s "~12 min" — no container run.
- The chain's first line (`grep command_count` in `specs.zig` /
  `command.zig`) matches nothing in today's tree, so it prints an empty
  `pins:` line; that is a note on the script, which lives outside the
  repo, not on the docs.
- The full corpus was not run to completion (the partial run was 79 ok,
  0 failed); the sweep in the verification list was.
