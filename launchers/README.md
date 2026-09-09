# Launchers

A launcher is an integration manifest without a `binary`. It ships no
program of its own: each of its commands carries a `run` line — an ex
line, usually `:term <tool> …` — that starts something already on the
machine, in a pty pane. Installing one is copying its `.zon` into
`<data root>/integrations/`; there is nothing to build. This folder is
mnml's own set:

| file | what it starts |
|---|---|
| `btop.zon` | `btop`, the resource monitor |
| `htop.zon` | `htop`, the process viewer — its chip glyph is pinned by codepoint (`glyph_codepoint`) |
| `iftop.zon` | `iftop`, the bandwidth monitor |
| `vscode.zon` | the `code` CLI — the reference for templated `run` lines |

## The shape

```zig
.{
    .id = "htop",                       // a file name: [A-Za-z0-9_.-]
    .label = "htop",
    .description = "Interactive process viewer",
    .category = "system",
    .chip = .{
        .glyph = "\u{F0AEF}",           // a Nerd Font glyph, or…
        .glyph_codepoint = "F1D00",     // …a codepoint painted verbatim when .glyph is empty
        .fallback = "H",                // 1–3 plain characters for ui.ascii_icons / no Nerd Font
        .color = "green",               // red orange yellow green blue cyan teal purple pink comment fg, or #rrggbb
        .enabled = true,
        .in_palette_bar = false,        // true puts the chip on the palette bar
    },
    .commands = .{
        .{ .id = "htop.open", .title = "htop: open", .keys = .{"space i H"}, .run = ":term htop" },
    },
}
```

The rules `validate` applies (the SDK's and mnml's, the same function):
the `id` is a file name; a manifest without a `binary` has at least one
command; every command of such a launcher has a `run` (or `ex`) line.
Every `chip` needs a `fallback` — a launcher renders somewhere without
the font. The rest of the manifest schema (`settings`, `statusline`,
`requires`, …) is `sdk/mnml-sdk/src/manifest.zig` and `docs/SDK.md`.

## Template tokens

A `run` line names mnml's context with `{{token}}`; mnml expands it
when the command fires (`src/app/launcher_template.zig`):

| token | value | empty when |
|---|---|---|
| `{{workspace}}` | absolute path of the workspace root | never |
| `{{workspace_name}}` | its basename | never |
| `{{current_file}}` | the active file, workspace-relative (absolute outside the workspace) | no editor pane is active |
| `{{current_file_abs}}` | the active file, absolute | no editor pane is active |
| `{{current_file_dir}}` | the active file's directory, absolute | no editor pane is active |
| `{{cursor_line}}` | 1-based cursor line | no editor pane is active |
| `{{cursor_col}}` | 1-based cursor column | no editor pane is active |
| `{{selection}}` | the selected text, its first line | nothing is selected |

An unknown token — a misspelling, `{{prompt:name}}`, an OS templating
form — stays as written, so the line still runs and the literal shows
what went wrong.

`:term code --goto {{current_file_abs}}:{{cursor_line}}:{{cursor_col}}`
is `vscode.zon`'s `vscode.open_current_file`.

## Firing

A launcher's command runs from the palette, its chord, Enter on its
Installed row, its palette-bar chip, and a pinned activity-bar icon
(`ui.activity_bar_pinned_integrations`; *Add to activity bar* on the
row's or the chip's menu). A `term <prog>` line whose program is not on
PATH toasts `<prog> is not on PATH — brew install <prog>` (the
platform's package verb) instead of opening a pane that dies.

Workspace manifests (`<ws>/.mnml/integrations/*.zon`) are gated by
workspace trust like every other exec-bearing file: an untrusted
checkout's launchers are not scanned, so their `run` lines cannot fire.

## Getting one

- **Marketplace tab** — a `github_launcher_folder` source lists every
  `.zon` under a repo path; a `local_folder` source lists a folder on
  this machine. `MNML_MARKETPLACE_LOCAL=launchers` from a checkout of
  this repo lists this folder (its rows read `✓ Official`: this folder
  is the official set). `i` / *Install* copies the file.
- **Dev tab** — a workspace that holds `sdk/mnml-sdk` (this repo) lists
  `launchers/*.zon` beside its `integrations/`; *Install* copies the file.
- **`launcher.add_local`** — a prompt for a `.zon` path (`~` and
  workspace-relative paths fine).

## Submitting one

Add `<id>.zon` here with a comment header saying what it starts, a
`fallback` on the chip, a `run` line per command, and `zig build test`
green — `launchers: every file in launchers/ …` in
`src/app/launchers.zig` parses the folder. Name the tool, not a
product family; keep `id` equal to the file's stem.
