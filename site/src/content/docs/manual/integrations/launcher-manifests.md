---
title: Launcher manifests
description: The `IntegrationManifest` TOML schema — every field a pure-launcher or binary-sibling integration can declare. Template variables (`{{workspace}}`, `{{current_file}}`, …) that get substituted at spawn time. Worked examples for shelling to CLIs, workspace-scoped launchers, and Claude Code overrides.
---

A launcher manifest is a TOML file that tells mnml about one integration — its id and label, its chip visuals, the palette commands it registers, and any statusline / context-menu surfaces it wants. The same schema covers both flavors of integration:

- **Pure launchers** — `binary` field omitted; commands shell out via templated `run` strings to whatever CLI is on the user's `$PATH`.
- **Binary siblings** — `binary = "mnml-xxx"`; commands typically fire `:term mnml-xxx` and the compiled sibling takes it from there.

Everything is optional except `id` and `label` — a two-line file is a valid manifest. See [Integrations overview](/manual/integrations/overview/) for the model this fits into; this page is the field reference.

## Where a manifest lives

```
<workspace>/.mnml/integrations/<id>.toml            # workspace-local (higher precedence)
~/.config/mnml/integrations/<id>.toml               # user-global
~/.config/mnml/integrations/<id>.override.toml      # user sidecar — merged over the base
```

Workspace beats user on `id` collision. The `id` field inside the file is authoritative — the filename is convention only.

To re-scan without a restart: `:integrations.refresh` (palette).

The sidecar `<id>.override.toml` is documented in [Installing → override sidecar semantics](/manual/integrations/installing/#override-sidecar-semantics). Manifest authors don't emit override files — those are user-owned; the manifest defines the base.

## Minimal launcher

```toml
id    = "htop"
label = "htop"

[[commands]]
id    = "htop.open"
title = "htop: open"
run   = ":term htop"
```

Three lines of identity, three lines of one palette command. No chip, no keybinding, no context menu. The command shows up in `Ctrl+Shift+P` as *"htop: open"* and runs `htop` in a Pty pane when accepted.

## Full schema

Everything below is optional except where noted.

### Identity

```toml
id          = "slack"              # required · unique stable slug
label       = "Slack"              # required · ~20 chars · chip hover / pane title
description = "Slack browse + post"  # one-sentence longer form for detail pane
version     = "0.1.0"              # semver; renders in detail-pane byline
binary      = "mnml-msg-slack"     # None (omitted) = pure launcher
category    = "msg"                # msg / forge / tracker / aws / db / fs / test / …
```

- **`binary`** decides the integration's flavor. Omitted → pure launcher (no compiled sibling; `run` templates carry the whole behavior). Set → binary sibling (mnml expects `mnml-msg-slack` on `$PATH` when a command runs `:term mnml-msg-slack`).
- **`label`** replaced `chip.tooltip` in 2026-08. Same value, promoted to the top level since it renders as more than a hover — the chip hover, the tree row label in the Integrations panel, the picker row, the detail-pane header.
- **`category`** is display-only — it drives the section header in the discovery overlay. Any string is legal; no closed set.

Detail-pane metadata for `Pane::IntegrationDetail` (all optional, all clickable links):

```toml
homepage   = "https://slack.com"
repository = "https://github.com/…/mnml-msg-slack"
docs       = "https://…/docs"
author     = "Ada Lovelace"
```

### `[chip]` — rail visuals

```toml
[chip]
glyph          = "\u{F0668}"       # single Nerd Font codepoint
fallback       = "Sk"              # 2-char text for --ascii mode
color          = "purple"          # named theme color
enabled        = true              # rendered by default (default: true)
in_palette_bar = false             # false → rail INTEGRATIONS section
badge_key      = "slack"           # section id for activity-bar badges
```

Named theme colors accepted by mnml: `red`, `orange`, `yellow`, `green`, `blue`, `cyan`, `teal`, `purple`, `pink`, `comment`, `magenta`, `fg`, `bg2`. Unknown names fall back to `cyan` at render.

Two SVG-glyph fields cover the "sibling ships its own icon" story (see [Building integrations → sibling icons](/manual/integrations/building/#sibling-icons)):

```toml
glyph_svg       = "slack.svg"      # sibling copies this via mnml-bridge
glyph_codepoint = "F1B00"          # explicit codepoint for the SVG bake
```

The manifest's own `glyph` takes precedence if set — `glyph_svg` only kicks in when `glyph` is empty AND an SVG has been dropped in `~/.config/mnml/glyphs/`. `glyph_codepoint` is trusted; no range check. Uppercase hex, no `U+` prefix.

### `[[commands]]` — palette entries

```toml
[[commands]]
id    = "slack.open"               # required
title = "Slack: open"              # required · palette row
group = "integrations"             # optional · palette grouping
keys  = ["<leader>iS"]             # optional · multiple allowed
run   = ":term mnml-msg-slack"     # required · ex-command line
```

- **`run`** is an ex-command string. Leading `:` is optional; either shape works. Any [template variable](#template-variables) in the string gets expanded before dispatch.
- **`keys`** are which-key chord specs. Multiple entries wire multiple chords to the same command; each entry is one keybinding.
- **`group`** is a display hint for palette grouping — it doesn't affect execution.

You can declare as many commands as you like — one for the primary launch, secondary ones for common actions:

```toml
[[commands]]
id = "postgres.open"
title = "PostgreSQL: open"
run = ":term mnml-db-postgres"

[[commands]]
id = "postgres.dump"
title = "PostgreSQL: dump active schema"
run = ":term pg_dump --schema-only {{env:DATABASE_URL}}"
```

### `[[context_menu]]` — right-click additions

```toml
[[context_menu]]
target  = "tree.file"              # tree.file | tree.dir | tab | agent.row | pane
title   = "Send via Slack"
command = "slack.send_file"
```

Extend mnml's right-click menus with sibling-provided items. `target` picks which right-click surface the entry appears in; unknown targets are silently dropped at merge time.

### `[[menu_bar]]` — menu-bar entries

```toml
[[menu_bar]]
path    = "File > Send via Slack"  # slash-separated menu path
command = "slack.send_file"
```

Add rows to mnml's menu bar. The `path` is a `>`-separated menu hierarchy; missing intermediate menus get created.

### `[statusline]` — sibling-owned segment

```toml
[statusline]
side          = "right"            # "left" | "right"
segment_id    = "slack"            # unique id used to update / clear later
initial_text  = "◇ slack"          # what renders on startup
initial_color = "comment"          # named theme color, optional
click_command = "slack.open"       # optional
priority      = 100                # 100 default; 200 = "always show"
min_width     = 4                  # drop segment below this width
max_width     = 30                 # truncate content above this
```

Reserves space in the statusline that the sibling can update at runtime via the [Bridge SDK's](/manual/bridge-mount/#tier-3--mnml-bridge-sdk) `statusline_set_segment` helper. Priority-based overflow: when statusline width is tight, low-priority segments drop first.

### `[notifications]` — OS notification policy

```toml
[notifications]
os_notify_on      = "error_only"   # never | error_only | always
os_rate_limit_sec = 5              # min secs between OS pings
```

Controls whether the sibling's `notify` calls escalate to OS notifications (OSC 9 / 777). `error_only` (the reasonable default for most siblings) fires only on `Level::Error`; `always` fires on every `notify`; `never` disables OS escalation entirely.

### `[requires]` — preconditions

```toml
[requires]
env    = ["SLACK_TOKEN"]           # dim chip if any of these is unset
binary = "mnml-msg-slack"          # PATH-verified at discovery
```

If any listed env var is missing, or the named binary isn't on `$PATH`, the discovery overlay dims the row and the manifest's `is_ready()` returns `false`. The chip still renders — this is a hint, not a hard gate.

### `[[settings]]` — settings-overlay pages

```toml
[[settings]]
section = "Slack"
label   = "Channel filter"
help    = "Comma-separated list of channels to prioritize"
```

Reserves rows in the mnml settings overlay. v1 is a metadata hook — the sibling handles actual value storage via `~/.config/mnml-msg-slack.toml` or similar; mnml just surfaces the section header + label.

## Template variables

Every `run` string is passed through `launcher_template::expand` before dispatch. Recognized `{{name}}` tokens get substituted; unrecognized tokens stay literal (so a typo like `{{workspce}}` reads as-typed at spawn time, easier to debug than a hard failure).

The full vocabulary:

| Token | Meaning | Empty when |
|---|---|---|
| `{{workspace}}` | Absolute path of the active workspace root | never |
| `{{workspace_name}}` | Basename of the workspace directory | never |
| `{{current_file}}` | Active file path, relative to workspace when possible | no editor pane focused |
| `{{current_file_abs}}` | Absolute path of the current file | no editor pane focused |
| `{{current_file_dir}}` | Directory of the current file (absolute) | no editor pane focused |
| `{{cursor_line}}` | 1-indexed cursor line | no editor pane focused |
| `{{cursor_col}}` | 1-indexed cursor column | no editor pane focused |
| `{{selection}}` | Selected text — single line only in v1 | no selection |

An empty value expands to an empty string, not a literal `{{name}}`. That means `code {{current_file}}` with no focused editor becomes `code ` (a launch-with-no-file that most CLIs handle gracefully) — not `code {{current_file}}` (which would fail to parse).

**Not yet implemented:** `{{prompt:<name>}}` — reserved for the launcher-edit overlay's prompt-at-spawn work. `{{prompt:target}}` in a `run` string stays literal for now; adding a prompt-at-spawn substitution requires plumbing through the async prompt subsystem.

### Worked examples

Open the current file's directory in `lazygit`:

```toml
[[commands]]
id    = "lazygit.here"
title = "lazygit: open at current file's dir"
run   = ":term lazygit -w {{current_file_dir}}"
```

Jump to the current position in an external editor:

```toml
[[commands]]
id    = "vscode.here"
title = "VS Code: open at cursor"
run   = ":term code -g {{current_file_abs}}:{{cursor_line}}:{{cursor_col}}"
```

Grep the workspace for the current selection:

```toml
[[commands]]
id    = "rg.selection"
title = "ripgrep: search workspace for selection"
run   = ":term rg -n {{selection}} {{workspace}}"
```

Workspace-specific Claude launcher (see [Absorbed launcher pattern](#absorbed-launcher-pattern) below):

```toml
[[commands]]
id    = "claude.custom"
title = "Claude: launch with workspace config"
keys  = ["<leader>ac"]
run   = ":term claude --dangerously-skip-permissions --project {{workspace}}"
```

## Add a local launcher in-app

For a private launcher you don't want to share via the marketplace, run:

```vim
:launcher.add_local
```

The palette command opens the integration edit overlay (`AddCustom` mode) with an empty `:term ` command pre-seeded. Fill in id / label / glyph / fallback / color / command, hit Save, and mnml writes a full `<id>.toml` authorial manifest to `~/.config/mnml/integrations/`. The chip appears immediately — no `integrations.refresh` needed.

The full flow:

1. `:launcher.add_local` (or bind it to a key via `[keys.global]`).
2. Type in the fields. `Tab` moves between them; `←→` cycles the color palette.
3. Save. mnml writes the file and updates the in-memory rail.

For anything more permanent than a one-off — a launcher you want in every workspace, or that you'd like others to install — the in-app overlay is still fine, but you can also write the manifest by hand. See [Integrations overview → three paths](/manual/integrations/overview/#adding-your-own--three-paths) for the tradeoffs.

## Absorbed launcher pattern

The old per-workspace Claude launcher override — a `[workspace] claude_launcher` config key that mnml used to shell to when `<leader>ac` fired inside a specific project — was retired when the launcher template shipped in 2026-08. The template model absorbs the same use case cleanly:

**Before** (dead — do not use):

```toml
# ~/.mnml/config.toml, per-workspace
[workspace]
claude_launcher = "claude --dangerously-skip-permissions --project /Users/me/proj"
```

**Now** — a workspace-local launcher manifest:

```toml
# <workspace>/.mnml/integrations/claude-custom.toml
id = "claude-custom"
label = "Claude (this project)"
category = "ai"

[chip]
glyph = "\u{F0668}"
fallback = "Cc"
color = "orange"

[[commands]]
id = "claude.custom"
title = "Claude Code: launch with project config"
keys = ["<leader>ac"]
run = ":term claude --dangerously-skip-permissions --project {{workspace}}"
```

Same behavior, and the manifest is portable — copy the file into another workspace's `.mnml/integrations/` folder and the chord + chip come with it. `{{workspace}}` expands per workspace, so one manifest can be shared across many projects.

If you want the launcher to only appear in one workspace, drop the manifest in `<workspace>/.mnml/integrations/` (workspace-local). To share it across every project, put it in `~/.config/mnml/integrations/` (user-global). Same file, different location.

## Merging with mnml core defaults

Three chips are hardcoded in mnml core: `browser`, `claude_code`, `codex`. When a manifest's `id` matches one of them, the manifest replaces the built-in as the effective base — mnml's default chip becomes just a fallback for the case where no manifest exists.

If a user hits **Edit…** on one of the three built-ins and no manifest exists for that id yet, the save promotes to a full authored `<id>.toml` in `~/.config/mnml/integrations/`. Subsequent edits write `<id>.override.toml` sidecars over that promoted base. See [Installing → promotion when there's no base](/manual/integrations/installing/#promotion-when-theres-no-base) for the exact behavior.

## Next

- [Installing integrations](/manual/integrations/installing/) — Marketplace tab, sidecar overrides, hand-editing config.
- [Marketplace](/manual/integrations/marketplace/) — how the Marketplace tab discovers launchers to install.
- [Integrations overview](/manual/integrations/overview/) — the two flavors, one on-disk shape.
- [Building integrations](/manual/integrations/building/) — authoring a launcher or (rarely) a binary sibling.
- [Bridge & Mount](/manual/bridge-mount/) — the runtime protocol siblings use once they need to talk back.
