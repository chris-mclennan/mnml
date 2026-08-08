---
title: Installing integrations
description: Three ways to install an mnml integration — Marketplace tab clicks, the `launcher.add_local` palette command for private launchers, and hand-editing a manifest. Precedence, on-disk paths, sidecar overrides, and how the Installed / Marketplace tabs decide which is which.
---

Installing an mnml integration means getting one file onto disk: a manifest at `~/.config/mnml/integrations/<id>.toml`. mnml scans that folder on startup, merges it with the three core built-ins and any `<id>.override.toml` sidecars, and paints the resulting rail. Three flows land files in the right place; picking the right one depends on where the integration comes from.

This page covers the mechanics. For the "what is an integration in the first place" model see [Integrations overview](/manual/integrations/overview/); for the manifest schema see [Launcher manifests](/manual/integrations/launcher-manifests/).

## Where integrations live

Four on-disk layers, in **increasing precedence**:

| Layer | Path | Written by |
|---|---|---|
| **Core built-in defaults** | mnml core (`src/config.rs::Config::default`) | mnml |
| **Base manifest** | `~/.config/mnml/integrations/<id>.toml` — or `<workspace>/.mnml/integrations/<id>.toml` (workspace beats user on id collision) | Marketplace install, `<sibling> --install`, `launcher.add_local`, or you by hand |
| **Override sidecar** | `~/.config/mnml/integrations/<id>.override.toml` | The right-click **Edit…** overlay, the detail-pane buttons, `integrations.toggle_enabled` |
| **Rail order** | `[ui] integration_icon_order = [...]` in `~/.config/mnml/config.toml` | Right-click **Move up / down / to top / to bottom** |

Two files can't coexist at the same layer for the same `id` — the second one drops (with a stderr log). Different layers with the same id merge field-by-field, with the higher layer winning per field.

Built-in defaults ship for exactly three integrations: `browser`, `claude_code`, `codex`. Every other chip — every AWS viewer, database browser, forge dashboard, messaging integration — comes from a manifest you install.

## Path 1 — Marketplace install

The primary flow. Open the activity-bar Integrations panel, click **Marketplace**, and left-click any row you want. mnml handles the download / install and drops the file in `~/.config/mnml/integrations/<id>.toml`.

Two kinds of Marketplace row need two different install paths:

### `[launcher]` rows (cyan tag)

mnml fetches the TOML directly and writes it to `~/.config/mnml/integrations/<id>.toml`. Complete in ~200ms. Toast on success:

```
installed htop → /Users/you/.config/mnml/integrations/htop.toml
```

`integrations.refresh` runs automatically, so the chip lands on the Installed tab immediately.

### `[app]` rows (orange tag)

mnml spawns a Pty pane running `cargo install <name>`. Watch the compile output there. When it finishes, run the sibling's own `--install` subcommand (if it has one) to register its manifest:

```sh
mnml-db-postgres --install
```

Then `:integrations.refresh` in mnml to see the chip.

The two-step split is deliberate — cargo takes minutes, manifest registration takes milliseconds, and splitting them means the manifest write can't race the build. If a sibling doesn't ship an `--install` subcommand, fall back to hand-authoring a manifest — see [Launcher manifests](/manual/integrations/launcher-manifests/).

See [Marketplace](/manual/integrations/marketplace/) for source configuration, cache TTL, provenance tagging, and adding your own launcher-manifest folder as a source.

## Path 2 — `launcher.add_local`

For private launchers you don't want to share via any marketplace. The palette command opens an edit overlay pre-seeded with `:term ` as the command; type in id / label / glyph / fallback / color / command, hit Save, and mnml writes a full `<id>.toml` manifest to `~/.config/mnml/integrations/`.

```vim
:launcher.add_local
```

No restart, no marketplace roundtrip. The chip appears immediately.

Fast when what you want is *"a chip that runs this shell command"* — a wrapper around a workspace-specific script, a Claude launcher with custom flags, a `k9s --context=staging` shortcut. For anything more permanent — something you want to share, or reuse across workspaces via `{{workspace}}` — write a manifest by hand. See [Launcher manifests](/manual/integrations/launcher-manifests/#add-a-local-launcher-in-app) for the tradeoffs.

## Path 3 — hand-authored manifest

Open your editor, drop a TOML file at `~/.config/mnml/integrations/<id>.toml`, run `:integrations.refresh`:

```toml
id    = "notes"
label = "Notes"

[chip]
glyph    = "\u{F02D6}"
fallback = "N"
color    = "yellow"

[[commands]]
id    = "notes.open"
title = "Notes: open today's file"
run   = ":e ~/notes/{{workspace_name}}.md"
```

`{{workspace_name}}` gets substituted at spawn time — see [Launcher manifests → template variables](/manual/integrations/launcher-manifests/#template-variables) for the full vocabulary.

## Precedence

Four layers stack per `id`. Higher layers override lower ones:

1. **Core built-in defaults** in mnml (only for `browser` / `claude_code` / `codex`).
2. **Base manifest** — `<workspace>/.mnml/integrations/<id>.toml` (higher) or `~/.config/mnml/integrations/<id>.toml` (lower).
3. **Override sidecar** — `<id>.override.toml` in the same folder. Deep-merged per field.
4. **User order** — `[ui] integration_icon_order` in `~/.config/mnml/config.toml`.

### Override sidecar semantics

An `<id>.override.toml` file is a **per-field diff** applied over the base manifest at scan time. Every field is optional; absent fields inherit from the base:

```toml
# ~/.config/mnml/integrations/htop.override.toml
id = "htop"

[chip]
color = "green"
in_palette_bar = true
```

Given a base `htop.toml` with `color = "cyan"` and `in_palette_bar = false`, the effective chip renders **green** and pins to the **palette bar**. Every other field (glyph, fallback, commands, all statusline / notifications / requires structure) still comes from the base.

The override's `id` field must match the base's `id` (and the filename's stem). A stray rename can't accidentally retarget the sidecar at an unrelated integration — mismatched files are silently dropped.

The scope of what an override can change is deliberately narrow:

| Field | Overridable |
|---|---|
| Top-level `label`, `description` | Yes |
| `[chip]` — `glyph`, `fallback`, `color`, `enabled`, `in_palette_bar` | Yes |
| `[[commands]]` — command bodies, `run` strings, keys | No — canonical |
| `[[context_menu]]`, `[[menu_bar]]`, `[statusline]`, `[notifications]`, `[requires]` | No — canonical |

Command bodies stay canonical because an override that redefined a `run` string could silently break the sibling's contract with mnml. Overrides are for cosmetics + preference bits; structural integration stays with the sibling author.

### Promotion when there's no base

For the three built-in chips (`browser`, `claude_code`, `codex`), the "canonical" is Rust code in mnml core — not a file on disk. If you right-click one of them and hit **Edit…**, mnml has nowhere to write an override sidecar (an orphan override with no base gets dropped at the next scan). Instead, the save promotes to a full authored `<id>.toml`, which subsequent scans then treat as a normal base manifest:

```
~/.config/mnml/integrations/claude_code.toml   ← promoted from the built-in default
```

From this point forward the chip is a regular installed manifest, not a built-in default — and further edits will start writing `claude_code.override.toml` sidecars over that base.

### User-config overrides

Legacy `[[ui.integration_icon]]` blocks in `~/.config/mnml/config.toml` still parse for backwards compatibility, but they're now treated as thin overrides — user config is authoritative only for `enabled`, `in_palette_bar`, and rail order:

```toml
[[ui.integration_icon]]
id             = "browser"
enabled        = true
in_palette_bar = true
```

The chip's glyph, color, fallback, and command all come from the built-in / manifest source. If your `id` matches nothing (no built-in, no installed manifest), the entry is silently dropped — user config isn't a valid place to author a fresh chip definition anymore.

For everything except toggling enable + palette-bar pinning + rail order, use the sidecar file (usually via **Edit…** in the right-click menu) instead.

## The Installed / Marketplace tabs

The activity-bar Integrations panel splits every configured integration into two tabs based on the `enabled` field:

| Tab | Contents | Sort |
|---|---|---|
| **Installed** | Every integration where `enabled = true` | `[ui] integration_icon_order`, then base order |
| **Marketplace** | Every integration where `enabled = false`, **plus** everything mnml learned about from marketplace source fetches | Alphabetic by label |

Chips default to `enabled = false` — a fresh install is intentionally quiet. Enable a chip by right-clicking → **Enable**, via `integrations.toggle_enabled` from the palette, or by adding an override with `[chip] enabled = true`.

### Filter row

Press `/` while the panel is focused, or click the search glyph at the top, to open the filter. Typing narrows both tabs across `label`, `id`, and `command`. `Esc` clears the filter and returns focus to the tree.

## The right-click chip menu

Right-click any integration chip (in the rail, the palette bar, or the panel) for a context menu. The full list of entries — some show conditionally based on the chip's state and command shape:

| Action | Command id | Effect |
|---|---|---|
| Enable / Disable | `integrations.toggle_enabled` | Flip the `enabled` field — persist to `<id>.override.toml` (or promote to `<id>.toml` for built-ins) |
| View details | `integrations.show_details` | Open `Pane::IntegrationDetail` in the right side panel |
| Move to top / up / down / to bottom | — | Reorder within the effective rail, persist to `[ui] integration_icon_order` |
| Edit… | `integrations.edit` | Open the edit overlay for this integration; save writes an override sidecar |
| Set launcher script… | — | (Only for `claude_code` / `codex`) supply a workspace-scoped wrapper script |
| Add / Remove activity bar | — | (Only for chips whose command is `:term <binary>`) dock the sibling as an activity-bar Mount pane |
| Copy id | `integrations.copy_id` | Yank the chip's `id` to the clipboard |
| Show manifest… | `integrations.show_manifest` | Open the on-disk manifest file (workspace, else user) |
| Bake / tune glyph… | `integrations.glyph_builder` | Open the glyph builder pre-loaded at this chip's codepoint |
| Remove | `integrations.remove` | Delete the manifest, override, glyph SVG + assignments entry, and the in-memory rail entry |

Keyboard equivalents live under `<leader>i`. Available chords: `<leader>id` (details), `<leader>ie` (enable/disable), `<leader>ip` (icon picker), `<leader>ih` / `<leader>iI` / `<leader>ir` (external tool launchers htop / iftop / btop). Palette pickers cover every menu item (`integrations.edit`, `integrations.remove`, `integrations.copy_id`, `integrations.show_manifest`) so nothing is mouse-only.

### The Remove confirm dialog

Every path that removes an integration routes through a two-button confirmation:

```
Remove integration 'my-tool' from the rail?
[ Remove ]  [ Cancel ]
```

`Cancel` is the default focus, so an accidental `Enter` doesn't remove the chip. Arrow keys / `Tab` move between buttons. `Remove` does a full uninstall — every trace of the integration leaves the disk:

- `~/.config/mnml/integrations/<id>.toml` — base manifest.
- `~/.config/mnml/integrations/<id>.override.toml` — user sidecar (if present).
- `~/.config/mnml/glyphs/<id>.svg` — sibling-shipped SVG glyph (if present).
- The `<id>` entry in `~/.config/mnml/glyphs/assignments.toml` (if present).
- The in-memory rail entry, which is then flushed to config.toml if the chip had `[[ui.integration_icon]]` state.

One button, one gesture, everything gone. There's no separate "hide the chip but keep the manifest" gesture — for that, use **Disable** instead (chip flips to Marketplace tab, files stay on disk).

## Detection — is the binary actually there?

For any command that starts with `:term <binary>`, mnml probes whether `<binary>` is on `$PATH` before treating the chip as ready. Missing binaries trigger `(binary not installed)` on picker rows and dim the chip in the discovery overlay.

The probe walks `$PATH` first, then a per-OS list of well-known install dirs:

| OS | Locations checked (in order) |
|---|---|
| macOS | `$PATH` → `~/.cargo/bin` → `/opt/homebrew/bin` (Apple Silicon) → `/usr/local/bin` (Intel) |
| Linux | `$PATH` → `~/.cargo/bin` → `/home/linuxbrew/.linuxbrew/bin` → `/usr/local/bin` |
| Windows | `%PATH%` → `%USERPROFILE%\.cargo\bin` → `%LOCALAPPDATA%\Programs\` |

The fallback list exists because a launcher / IDE / tmux spawn may not inherit your shell's full `PATH`. Without the fallback you'd `cargo install mnml-msg-slack`, see it in any shell, then launch mnml from a wrapper that doesn't run your `.zshrc` and watch the chip vanish despite the binary sitting in `~/.cargo/bin`. The direct probe covers those cases.

Results cache per session. After a fresh `cargo install` outside of mnml, drop the cache:

```vim
:integrations.refresh_binary_cache
```

Or restart mnml. The Marketplace-tab install path (`cargo install <name>` in a Pty pane) drops the cache automatically when the pane exits.

Internal palette commands with no prefix (e.g. `ai.claude_code`, `http.send`, `browser.open`) never route through the probe — they don't shell out, so they're always assumed available.

## Troubleshooting

### "I installed via `cargo install` but the chip doesn't appear"

Likely a `PATH`-inheritance issue — the shell mnml was spawned from doesn't have `~/.cargo/bin` on `PATH`, or your `cargo install --root` prefix is non-standard.

mnml's well-known-locations fallback covers `~/.cargo/bin` directly. If the chip still doesn't resolve, the binary likely landed somewhere unusual — check `cargo install --list` to see where. If your install prefix is non-standard:

- Move the binary into `~/.cargo/bin` (a symlink works), or
- Prepend the target directory to `PATH` in your shell profile and relaunch.

### "The chip is dim / greyed out"

Two things trigger visual dimming:

- **`enabled = false`** — the chip is a Marketplace entry, not an Installed one. Right-click → **Enable** to activate it.
- **`[requires]` predicate failed** — the manifest declared an env var or binary requirement that isn't satisfied on the current machine. Set the env var or install the binary; the chip un-dims on next render.

Which of the two applies is visible in the panel: `enabled = false` chips live on the Marketplace tab; `requires` failures live on the Installed tab with a subtle red suffix.

### "I edited the chip in the Edit overlay but the change reverted"

You almost certainly hit the promotion-vs-override path. If the id is one of the built-in defaults (`browser` / `claude_code` / `codex`) and there was no base manifest yet, the first save writes a full `<id>.toml`. Look for that file in `~/.config/mnml/integrations/`; if it's there, subsequent edits write `<id>.override.toml` sidecars on top. If it's missing, the write failed — check `~/.config/mnml/integrations/` permissions and mnml's stderr for a write error.

### "The marketplace tab is empty"

Three checks:

1. Confirm `[marketplace] enabled = true` (or unset — defaults to true).
2. Run `:marketplace.refresh`. First-time launches don't auto-fetch — you drive the refresh explicitly.
3. Check `~/.cache/mnml/marketplace.json` — a corrupt or empty cache falls back to "nothing to render". Delete it and refresh again.

If GitHub is returning 403s, install `gh` and run `gh auth login` — see [Marketplace → GitHub rate limits](/manual/integrations/marketplace/#github-rate-limits).

### "I want a chip that doesn't run a binary"

Use a pure launcher. Drop a TOML with no `binary` field in `~/.config/mnml/integrations/<id>.toml`:

```toml
id    = "notes"
label = "Notes"

[chip]
glyph    = "\u{F02D6}"
fallback = "N"
color    = "yellow"

[[commands]]
id    = "notes.open"
title = "Notes: open today's file"
run   = ":e ~/notes/{{workspace_name}}.md"
```

`{{workspace_name}}` gets substituted at spawn time — see [Launcher manifests → template variables](/manual/integrations/launcher-manifests/#template-variables) for the full vocabulary.

## Next

- [Integrations overview](/manual/integrations/overview/) — the model.
- [Marketplace](/manual/integrations/marketplace/) — federated discovery, source config, cache, provenance.
- [Launcher manifests](/manual/integrations/launcher-manifests/) — every field a manifest can declare.
- [Building integrations](/manual/integrations/building/) — authoring a launcher (or, rarely, a binary sibling).
- [Community integrations](/manual/integrations/community/) — where to find and share what others have published.
