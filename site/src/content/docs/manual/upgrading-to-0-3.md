---
title: Upgrading to 0.3
description: What changes for a 0.2.x user moving to mnml 0.3.0 — the Zig rewrite. Same binary name and install channels; config moves from TOML to ZON via `mnml export-config-zon`; themes are built in; the keymap profiles tighten; a short list of cuts; how to pin 0.2.x.
---

mnml 0.3.0 is the same editor, rewritten in Zig. One static binary per platform, no runtime, the same command ids, the same `.test` corpus green on both sides (225 of 226 at 120x40). mnml 0.2.x — the Rust line — is frozen at **0.2.22** and stays installable; the two run side by side.

For most people the upgrade is three steps: run `mnml export-config-zon` on 0.2.22, install 0.3.0 through the channel you already use, launch. This page walks the changes in the order you meet them, and ends with how to stay on 0.2.x if you depend on something 0.3.0 does not carry yet.

## Before you upgrade: convert your config

**Do this first, while 0.2.22 is still on your PATH.** mnml 0.3.0 reads no TOML at all — not `config.toml`, not the theme files, not `trusted_workspaces.toml`. The converter lives in the last Rust release, because it is the one binary that still has the typed TOML schema.

```sh
mnml --version                 # 0.2.22 — the converter is in this release
mnml export-config-zon         # writes ~/.config/mnml/config.zon
```

It prints one line per run, plus one more when something did not fit:

```
wrote /Users/me/.config/mnml/config.zon — 61 value(s) migrated from /Users/me/.config/mnml/config.toml
7 item(s) could not be placed — see the `// unmigrated:` block at the end
```

The TOML file is left where it was. mnml 0.3.0 ignores it, and 0.2.22 ignores the ZON — so nothing about the conversion is a commitment. Run it as many times as you like.

### The flags

```
mnml export-config-zon [--out PATH] [--workspace DIR] [--in PATH] [--force]
```

| Flag | What it does |
|---|---|
| *(none)* | Converts the home config — `~/.config/mnml/config.toml` (or wherever `XDG_CONFIG_HOME` / `MNML_DATA_ROOT` put it) — and writes `config.zon` beside it |
| `--workspace DIR` (`-w`) | Converts `DIR/.mnml/config.toml` instead; the output lands at `DIR/.mnml/config.zon` |
| `--in PATH` (`-i`) | Converts this exact file; `config.zon` is written beside it |
| `--out PATH` (`-o`) | Writes somewhere else. The parent directory is created if needed |
| `--force` (`-f`) | Overwrites an existing output. Without it a second run stops with `… exists — pass --force to overwrite it` and writes nothing |

Run it once per TOML file you keep — the home file, then each workspace's `.mnml/config.toml`:

```sh
mnml export-config-zon                                   # home
mnml export-config-zon --workspace ~/code/proj           # one workspace
cd ~/code/other && mnml export-config-zon --in .mnml/config.toml   # the same, from inside
```

A missing source is an error (`… does not exist — nothing to convert`), not an empty file — so an unconverted workspace is one you never had a config for.

### What the output looks like

The converter walks the TOML as a value tree against a schema that mirrors mnml-zig's `Config.zig`, so the ZON carries **only the keys you set** — never a dump of every default. Each key gets a `//` comment from the schema's own doc table, and sections come out in the order of the [config reference](/manual/config-zon/). A real before/after, excerpted from the converter's own test fixture:

```toml
# 0.2.x — config.toml
[editor]
input_style = "vim"
tab_width = 2
chord_timeout_ms = 300

[ui]
theme = "gruvbox"
md_preview_engine = "custom:glow -s dark"

[keys.global]
"ctrl+p" = "picker.files"
"ctrl+shift+p" = "none"

[keys.vim]
"space f f" = "picker.files"
"g d" = "lsp.definition"

[formatters.rs]
cmd = "rustfmt --edition 2024"

[[marketplace.source]]
type = "crates_keyword"
id = "crates.io"
keyword = "mnml-integration"
```

```zig
// 0.3.0 — config.zon, as written by `mnml export-config-zon`
.{
    // ── editor ─────────────────────────────────────────────────────────────
    .editor = .{
        // .vim | .standard
        .input_style = .vim,
        // Spaces per tab stop.
        .tab_width = 2,
        // vim's timeoutlen; clamped to 100..5000
        .chord_timeout_ms = 300,
    },

    // ── ui ─────────────────────────────────────────────────────────────────
    .ui = .{
        // any theme name; an open set
        .theme = "gruvbox",
        // .builtin | .glow | .pandoc | .{ .custom = "cmd" } (exec-bearing)
        .md_preview_engine = .{ .custom = "glow -s dark" },
    },

    // ── keys ───────────────────────────────────────────────────────────────
    .keys = .{
        // Bindings for both profiles.
        .global = .{
            .@"ctrl+p" = "picker.files",
            .@"ctrl+shift+p" = "none",
        },
        // Bindings on top of .global in the vim profile.
        .vim = .{
            .@"g d" = "lsp.definition",
            .@"space f f" = "picker.files",
        },
    },

    // ── formatters ─────────────────────────────────────────────────────────
    .formatters = .{
        .rs = .{
            // argv; {file} becomes the workspace-relative path
            .cmd = .{ "rustfmt", "--edition", "2024" },
        },
    },

    // ── marketplace ────────────────────────────────────────────────────────
    .marketplace = .{
        // Extra catalog sources — a tagged union per entry.
        .sources = .{
            .{
                .crates_keyword = .{
                    // Source id.
                    .id = "crates.io",
                    // crates.io keyword to list.
                    .keyword = "mnml-integration",
                },
            },
        },
    },
}
```

The transforms you can see in that excerpt are the whole list of shape changes:

| 0.2.x TOML | 0.3.0 ZON |
|---|---|
| `input_style = "vim"` and every other closed-set string | an enum literal — `.input_style = .vim` |
| `[keys.global] "ctrl+p" = "…"` | `.keys = .{ .global = .{ .@"ctrl+p" = "…" } }` |
| a formatter / linter `cmd = "rustfmt --edition 2024"` string | an argv list — `.cmd = .{ "rustfmt", "--edition", "2024" }` |
| `md_preview_engine = "custom:cmd"` | `.md_preview_engine = .{ .custom = "cmd" }` |
| `[[marketplace.source]] type = "crates_keyword"` | `.marketplace.sources = .{ .{ .crates_keyword = .{ … } } }` — a tagged union |
| `[[ui.integration_icon]]` | `.ui.integration_icons = .{ … }` |
| `[startup] tasks`, `[[startup.layout]]`, `default_workspace` | one `.startup = .{ .tasks, .layout, .default_workspace }` |
| `[abbr]` | `.abbr` |
| `claude_show_all_accounts = "ticker"` (the bool-or-string) | a bool |
| `[ai] backend = "cli"` / `"subscription"` / `"http"` (the Rust aliases) | folded onto `.auto` / `.api` / `.sub` / `.off` |
| legacy glyph names; retired integration ids (`bitbucket`, `linear`, `gitlab`, `cypress`, `slack`) | remapped / dropped, with a note |

### The `// unmigrated:` block

Anything the converter could not place lands verbatim at the end of the file, commented out, so nothing is lost silently — and so a bad literal never reaches the 0.3.0 loader, which drops the whole section on one bad field. The block has two kinds of line. From the same fixture:

```zig
// unmigrated:
// note: ui.integration_icon[1]: dropped — "slack" is a retired integration
// note: ui.coverage_chip_mode: not one of .both | .feature | .code | .ticker
// note: ai.claude_show_all_accounts = "ticker": became `true`; the 0.2.x display mode has no bool form
// note: linters.py.parser: not one of .vimgrep | .eslint | .tsc | .ruff | .shellcheck | .pattern
// mode = "standard"
//
// [keys.emacs]
// "ctrl+x" = "app.quit"
//
// [ui]
// coverage_chip_mode = "sideways"
// launcher_tooltip = "legacy key"
```

**`// note:` lines** describe a value that was changed or dropped on the way. Read each one and decide:

- *dropped — retired integration* — nothing to do; the id no longer exists in 0.3.0.
- *not one of …* — the value is outside the Zig enum. The key is absent from the ZON above, so the shipped default applies. Pick one of the listed literals and add the key by hand if you want something other than the default.
- *became `true`* — a lossy fold. Check the resulting line in the body and flip it if the guess was wrong.
- an integer *out of range for `u8` / `u16`* — the Zig side has a narrower type; choose a value that fits.

**Commented TOML** below the notes is every key the schema does not have at all: a top-level key 0.3.0 never read (`mode`), a whole section that belongs to a retired integration (`[playwright.docdb]`, `[[github.repos]]`), a keymap profile that does not exist (`[keys.emacs]`), a `[ui]` key that was renamed or removed. Most of it is safe to delete. If one of those keys was doing something for you, the [config reference](/manual/config-zon/) is the list of what exists now.

When you are done, the block can stay — it is all comments — or go. A launch with a `config:` diagnostic in the toast log means a line still needs attention; the message names the file, line and column.

### The ZON is as sensitive as the TOML was

The converter copies values, not just keys. If your `config.toml` carried anything you would not paste into a public gist — a Jira domain, an AWS account id, an `.ai.claude_accounts` token path, a `[tools]` block with a credential — the `config.zon` now carries the same thing, in the same directory, with the same permissions. Treat it the way you treated the TOML. Do not commit a workspace `.mnml/config.zon` with secrets in it any more than you would have committed the `.mnml/config.toml`.

## Install 0.3.0

The binary is still `mnml`. Every channel keeps its name; only the asset filenames drop the `-rs`:

```sh
# macOS / Linux
brew install chris-mclennan/tap/mnml
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/chris-mclennan/mnml-zig/releases/latest/download/mnml-installer.sh | sh
```

```powershell
# Windows
winget install ChrisMcLennan.mnml
powershell -ExecutionPolicy Bypass -c "irm https://github.com/chris-mclennan/mnml-zig/releases/latest/download/mnml-installer.ps1 | iex"
```

Debian / Ubuntu and Fedora / RHEL packages (`mnml-<triple>.deb` / `.rpm`) sit on every release, as do the raw archives — `mnml-<triple>.tar.xz`, `.zip` on Windows — each with a `.sha256`. Five targets, all ReleaseSafe for a baseline CPU: `aarch64-apple-darwin`, `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `x86_64-pc-windows-gnu`. The one channel that is gone is `cargo install mnml-rs` — there is no crate to install; a source build is `zig build -Doptimize=ReleaseSafe` with Zig 0.16.0 exactly.

The [Install page](/install/) has the per-platform links. The 0.3.0 release lives under [`chris-mclennan/mnml-zig`](https://github.com/chris-mclennan/mnml-zig/releases) on GitHub; the tap and winget entries follow it automatically.

### First launch on 0.3.0

If `config.zon` is where 0.3.0 expects it, the editor starts on your settings. If it is not — you skipped the converter, or the file is somewhere else — 0.3.0 starts on the shipped defaults, opens the [first-launch wizard](/manual/first-launch/), and says so in a toast when a `config.toml` is sitting next to where the ZON file would be. Nothing is converted for you at launch.

Two more one-time prompts. **Workspace trust** starts over: `trusted_workspaces.toml` is not read, so every workspace whose config names a language server, formatter, linter, debug adapter or startup pty asks once more and is remembered in `trusted_workspaces.zon`. *Don't trust* is the focused choice; a reflexive Enter is the safe answer and the question comes back next launch. And `session.json` and `.rqst/history.jsonl` are read best-effort — unknown fields ignored — and rewritten in the 0.3 shape the first time they are saved.

## Config is ZON now

The three-layer model is unchanged — home, then workspace, then `--config`, each layered over the last, each mentioning only what it changes:

| Layer | 0.2.x | 0.3.0 |
|---|---|---|
| home | `~/.config/mnml/config.toml` | `~/.config/mnml/config.zon` |
| workspace | `<workspace>/.mnml/config.toml` | `<workspace>/.mnml/config.zon` |
| explicit | `--config PATH` | `--config PATH` |

What changes is what a bad file costs you. In 0.2.x a malformed file was skipped whole. In 0.3.0 **failure is local**: a syntax error drops that file; a typo inside `.ui` drops `.ui` for that file and `.editor` still applies; a bad `.lsp.rust` drops only `rust`. Every problem is one `file:line:col:` diagnostic in the toast log, never a failed start. Duplicate keys are an error. A value outside an enum's set is a type error at its line — `.input_style = "vim"` (a string) is wrong; `.input_style = .vim` is right.

Settings changed in the UI write back into the file in place — one value's bytes replaced, comments and order kept, the previous file copied to `backups/config.<timestamp>.zon` beside it (newest 50 kept). And `:set` reaches every discrete key by its dotted path or its bare name when only one section has it (`:set ui.line_numbers`, `:set nowrap`, `:set scroll_accel=fast`, `:set cursor_line?`), Tab-completing names and values.

The full key-by-key reference, with the ZON primer, is [Config reference (ZON)](/manual/config-zon/).

## Themes are built in

All 94 NvChad base46 palettes ship inside the binary as `themes/*.zon`, derived into every UI role at compile time. `.ui.theme = "gruvbox"` names one, case-insensitively; `:theme` opens the picker with live preview; `theme.toggle`, `theme.reset` and `theme.auto_system` work as before.

What is gone is the theme *file* in your data root. A custom `.toml` theme there is not read. If you have one, convert it to the ZON shape — `.name`, `.kind = .dark | .light`, `.base_30 = .{ … }`, `.base_16 = .{ … }` with `0xrrggbb` values — using `tools/theme_toml2zon.zig` in the mnml-zig repo (the script that produced the bundled files) and drop it beside them. A malformed theme fails the build, not the launch.

## Keymap profiles

0.3.0 binds every default chord to a profile: `both` chords fire under either input style; `vim` chords only under `.input_style = .vim`; `standard` only under `.standard`. The point of the split is that a vim user gets Neovim / NvChad-exact chords and a standard user gets VS Code's — two complete profiles, not one map with patches. Your own `.keys.global` still applies to both and `.keys.vim` / `.keys.standard` overlay their profile.

The rule that moved the most chords: **vim reserves `Ctrl+W G D U E Y R N H J T F B O`** — each has an insert- or normal-mode meaning the editor must receive. Any default 0.2.x chord that started with one of those is `standard`-only now. The second rule: **the `Ctrl+K …` menus are the standard profile's leader**; the vim profile keeps `Space` as its only which-key leader (NvChad uses `Ctrl+K` for window-up).

If you edit in vim mode, these are the chords that changed under your hands:

| Chord | 0.2.x (both profiles) | 0.3.0 in the vim profile | Why |
|---|---|---|---|
| `Ctrl+B` | toggle the file tree | **page back** (the pair of `Ctrl+F`) | it was shadowing vim's page motion. The tree is `Ctrl+N` or `Space e` |
| `Ctrl+O` | file picker | **jumplist back** in NORMAL; one-shot normal in INSERT (`:help i_CTRL-O`) | the picker opened over insert mode and ate the next keys. `Ctrl+P` still opens the picker in both profiles |
| `Ctrl+F` / `Ctrl+H` / `Ctrl+G` | find / replace / go to line | vim's own meanings | `/`, `:%s`, `:N` |
| `Ctrl+D` | add cursor at next word | half-page down | |
| `Ctrl+N` | new file | **toggle the file tree** (NvChad `<C-n>`) | |
| `Ctrl+R` / `Ctrl+T` / `Ctrl+W` / `Ctrl+J` | recent files / workspace symbol / close buffer / expand snippet | redo, and the editor's own meanings | `Space x` closes a buffer |
| `Ctrl+H` `Ctrl+J` `Ctrl+K` `Ctrl+L` | — | **window navigation** (NvChad `<C-h/j/k/l>`); from the leftmost split `Ctrl+H` enters the sidebar | in insert mode the editor still consumes them, as in Neovim |
| `Ctrl+K …` chords (`Ctrl+K Z`, `Ctrl+K W`, `Ctrl+K T`, `Ctrl+K Ctrl+S`, …) | fullscreen, close others, theme toggle, keys editor, … | not bound; `Ctrl+K` is window-up | reach them from the palette or `Space` menus |
| `Ctrl+]` | bracket match | bracket match (kept) | in standard it is indent |
| `Tab` / `Shift+Tab` | — | **next / previous buffer** (NvChad's bufferline), not jumplist-forward | `Ctrl+I` still reaches `nav.forward` under kitty; `Ctrl+Tab` does on every terminal |

And the NvChad chords that are new in the vim profile: `Space f w` grep, `Space e` tree, `Space x` close buffer, `Space h` / `Space v` horizontal / vertical terminal, `Space /` comment, `Space f m` format, `Space c h` cheatsheet, `Space w K` which-key, `g d` / `g D` / `g r` / `K` / `[ d` / `] d` for LSP.

If you edit in standard mode, the chords you know keep working — and two VS Code chords are new: `Ctrl+]` indents and `Ctrl+[` outdents. The one loss on the standard side is `view.redraw`, which has no chord in either profile now (`Ctrl+L` is select-line in standard, window-right in vim); it is palette-reachable.

The file tree and Files pane keep `Ctrl+X` / `Ctrl+C` / `Ctrl+V` / `Ctrl+D` for cut / copy / paste / duplicate in both profiles — neither edits text, so the insert-mode meanings never want them there — and the vim profile adds ranger's `y y` / `d d` / `P` on top (two keys, so a stray press cannot move a file).

Every move, with the reason, is in [`docs/KEYMAP_PROFILES.md`](https://github.com/chris-mclennan/mnml-zig/blob/main/docs/KEYMAP_PROFILES.md). The [NvChad](/manual/cheatsheet-nvchad/) and [VS Code](/manual/cheatsheet-vscode/) cheatsheets are the per-profile maps.

## What was cut, and what to do instead

Ten of 477 feature rows in the parity ledger are cuts — left out on purpose, each with a reason and a place the user learns it. In every case the command id still exists and toasts the reason rather than silently doing nothing.

**Local in-process FIM model (`mnml-fim-engine`).** A bundled model is a release-size and build-time cost 0.3.0 does not carry; ghost text is API-only. `ai.suggest_backend = local` in a converted config toasts the migration note. *Instead:* route ghost text through the API or the Claude Code subscription backend (`.ai.routing.claude.backend = .api | .sub`).

**brotli response decoding.** Zig's `std.compress` has gzip, deflate and zstd, not brotli, and the HTTP client only asks for encodings it can decode — `Accept-Encoding` never lists `br`. A server that forces a `br` body anyway is shown raw with a toast. *Instead:* nothing to do; nearly every server negotiates down to gzip.

**WebP images.** No decoder in `zigimg` for this release. PNG, JPEG and GIF render over kitty / iTerm2 / sixel as before; `view.image_open` and the markdown preview show a `[image: alt]` placeholder for `.webp`. *Instead:* convert to PNG if you need it inline.

**Glyph-builder SVG preview and Nerd Font patching.** SVG rasterising and font patching have no Zig path. The audit / bake half survives as `zig build glyph-audit`; `integrations.glyph_builder` and `patch_nerd_font_svg` toast the reason. *Instead:* patch fonts with the upstream Nerd Fonts tooling.

**TOML anywhere.** Config, themes, integration manifests, `trusted_workspaces.toml` — every persisted format is ZON. *Instead:* this page.

**The Rust integration binaries and their crates.io marketplace.** `mnml-forge-*`, `mnml-aws-*` and the rest do not run on 0.3.0; `pr.picker` / `pr.refresh` toast the reason, and a `crates_keyword` marketplace source is accepted and lists nothing. `:term <binary>` still runs any installed binary as a pty pane. *Instead:* see the next section.

**now-playing / Sonos / mixr transport.** macOS-only AppleScript plus a sibling-app IPC — not a terminal-IDE concern for the successor. Every `sonos.*` / `mixr.*` / `audio.*` id toasts; the `.sonos` config keys are accepted and ignored so a converted file still loads. *Instead:* the [mixr](https://mixr.sh) app has its own transport; pin 0.2.x if the statusline chip mattered.

**Playwright as the generic `test.*` runner.** The generic `test.run_*` runners keep the project's own command (cargo / npm / go / pytest); Playwright has its own ids (`test.run_playwright*`) and the Tests pane. Listed as a cut only because the spec titles still say "Playwright".

That is the whole list. The ledger's ten `cut` rows all fall under one of those headings — the cross-host PR picker and its refresh cache are the integrations cut seen from the git side, and the four now-playing rows are one cut. [`docs/PARITY.md`](https://github.com/chris-mclennan/mnml-zig/blob/main/docs/PARITY.md) has every row, with the file that implements each `done` one beside it.

## Integrations

**The 0.2.x integrations do not run on 0.3.0.** The bridge protocol they speak (v1, the `mnml-bridge` crate) is not in the Zig host; integrations are being rewritten in Zig on a v2 protocol with a Zig-native SDK, jira and bitbucket first. This is a post-cutover phase — 0.3.0 ships without them.

If your day depends on one — a Jira board pane, a Bitbucket PR list, the AWS CodeBuild dashboard — [pin 0.2.x](#pin-02x) and keep it until the Zig version of that integration lands. The 0.2.x crates stay published for 0.2.x users; the marketplace, the launcher manifests and the auth SDK all keep working there.

What 0.3.0 does have: `:term <binary>` opens any installed program as a pty pane, and the v2 wire plus `mnml-sdk` are documented for anyone who wants to write against them today. See [Zig SDK (bridge v2)](/manual/integrations/zig-sdk/).

## Lua: `init.lua`

0.3.0 embeds Lua 5.4. A `~/.config/mnml/init.lua` runs at startup and can register commands (under `user.<id>`, in the palette and bindable in `.keys`), map chords, subscribe to hooks (`save_post`, `open`, `diagnostics`, `git_status`, …), read and edit buffers through the same `EditOp`s the keys produce — so undo, dot-repeat and the LSP all see it — add a statusline segment, feed the picker, open a pane it renders itself, and run a shell command as a task. It cannot reach the file system, shell or network directly; there is no `require`, no `os`, no `io`. A workspace `.mnml/init.lua` runs only once the workspace is trusted, and is one of the claims the trust dialog lists. Every call runs under a 20 ms budget; a runaway script costs one toast, not the editor.

This is the extension surface that did not exist in 0.2.x. Until it has a page here, [`docs/LUA.md`](https://github.com/chris-mclennan/mnml-zig/blob/main/docs/LUA.md) is the reference and `docs/examples/init.lua` in the repo is the sample every surface appears in.

## Windows

0.3.0's Windows terminal layer is written from scratch rather than borrowed from a crate: ConPTY behind `Pane.pty` (two anonymous pipes, a reader thread, a watcher thread on the process handle), a `%COMSPEC% /d /c` shell for `:term <line>` and the runners, console-mode handling for the interactive loop, and a `ReadConsoleInputW` input worker that speaks the same key grammar as the POSIX side. `x86_64-pc-windows-gnu` stays the target, and the MSI, winget and the PowerShell installer are all in the release.

The caveat, in the project's own words: **the Windows backends were written without a Windows machine in the loop.** They type-check on every commit (the cross-compile gate builds the exe and every test binary), and the pieces that can run anywhere — the command-line quoting, exit-code mapping, the console input fold — have unit tests. What has *not* been proven is anything that touches a real console or a real child process: the interactive loop under Windows Terminal, mouse and resize, ConPTY output streaming, closing a pane mid-stream, exit codes. There is a step-by-step checklist in [`docs/WINDOWS.md`](https://github.com/chris-mclennan/mnml-zig/blob/main/docs/WINDOWS.md); if you are on Windows and run through it, an issue with the results is worth more than any other bug report right now. Known gaps to expect meanwhile: no job object (closing a pane kills the shell, not its grandchildren), `.test` files with a `shell` step are POSIX-only, and `~` in `projects_dir` reads `HOME` rather than `USERPROFILE`.

The [Troubleshooting](/troubleshooting/) page still covers the 0.2.x Windows notes (Git Bash for `.test`, the `-gnu` toolchain).

## Pin 0.2.x

If anything above is a blocker, stay on 0.2.22. It is the last Rust release and it does not move.

**Homebrew** — install, then pin so `brew upgrade` skips it:

```sh
brew install chris-mclennan/tap/mnml
brew pin mnml
# later, to move on: brew unpin mnml && brew upgrade mnml
```

If the tap has already rolled to 0.3.0, install the 0.2.22 archive directly instead — the tap only carries the newest formula:

```sh
curl -LO https://github.com/chris-mclennan/mnml/releases/download/v0.2.22/mnml-rs-aarch64-apple-darwin.tar.xz
tar xf mnml-rs-aarch64-apple-darwin.tar.xz && mv mnml ~/.local/bin/
```

(`x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` for the other triples; `.zip` on Windows.)

**winget** — install the exact version, then pin:

```powershell
winget install --id ChrisMcLennan.mnml --version 0.2.22
winget pin add --id ChrisMcLennan.mnml
```

**cargo** — the crate is `mnml-rs`; the binary it installs is `mnml`:

```sh
cargo install mnml-rs --version 0.2.22 --locked
```

**Both at once.** Nothing stops 0.2.22 and 0.3.0 from sharing a machine: they read different config files (`config.toml` / `config.zon`) and different trust files, and a dev build of 0.3.0 keeps its IPC beside a running 0.2.x (`ipc-zig`, its own marker file). Install 0.3.0 to a different directory or under a different name and switch with your PATH.

## Next

- [Config reference (ZON)](/manual/config-zon/) — every key, its type, default and comment; the ZON primer; workspace trust
- [Install](/install/) — the per-platform links
- [Settings & configuration](/manual/settings/) — the settings overlay and the everyday toggles
- [Cheatsheet — NvChad chord map](/manual/cheatsheet-nvchad/) and [Cheatsheet — VS Code chord map](/manual/cheatsheet-vscode/) — the two profiles
- [Changelog](/changelog/) and [Troubleshooting](/troubleshooting/)
