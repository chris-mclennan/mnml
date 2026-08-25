---
title: AI launch profiles
description: Wrap the Claude Code and Codex CLIs with named launch profiles — per-workspace wrapper scripts, a persisted default, and one-off sessions from the chip's right-click menu.
---

mnml spawns the AI CLIs — `claude` and `codex` — as pty panes, and by default it spawns the bare binary from your `PATH`. But real setups often want a *wrapper*: a multi-repo workspace that launches Claude with a stack of `--add-dir` flags, a script that exports project credentials first, a pinned binary from a specific toolchain. And the same person often wants both — the wrapper for day-to-day work in this workspace, the plain binary for a quick throwaway session.

**Launch profiles** solve this without installing a second integration. Each AI chip (`claude_code`, `codex`) carries a list of named launch commands declared in its integration manifest. One of them is the default — what a plain click or `:ai.claude_code` spawns. The rest are one right-click away: fire a single session with any profile, or flip the persisted default, straight from the chip's menu.

## The manifest keys

Profiles live in the same TOML files that carry the rest of an integration's manifest (glyph, color, auth fields, …):

| Scope | Path | Wins? |
|---|---|---|
| User-global | `~/.config/mnml/integrations/<id>.toml` | — |
| Workspace | `<workspace>/.mnml/integrations/<id>.toml` | Yes — per profile name |

`<id>` is `claude_code` or `codex`. Two keys matter:

```toml
# <workspace>/.mnml/integrations/claude_code.toml
default_profile = "multi-repo"

[[launch_profile]]
name    = "multi-repo"
command = "{{workspace}}/bin/claude-multi.sh"
```

- **`[[launch_profile]]`** — an array of `{ name, command }` tables. Declare as many as you like, in either scope.
- **`default_profile`** — names the profile a plain launch uses. Top-level key (it must sit above any `[table]` header in the file).

Every chip also has one implicit, always-present profile:

- **`default`** — the bare product binary (`claude` / `codex`) resolved on `PATH`. You never declare it; it's the zero-config behavior.

Both scopes merge at load time: builtin first, then user-global entries, then workspace entries. Same-name entries replace earlier ones in place — a workspace `[[launch_profile]]` named `fast` overrides a user-global `fast`; a profile literally named `default` replaces the builtin's command outright (a compact way to swap the binary for every launch without touching `default_profile` at all).

### `command` is an executable path, not a shell line

This is the rule that trips people up. The `command` value is the **exe mnml spawns directly** — there is no shell in between, so pipes, `&&`, environment assignments, and inline flags don't belong here. Flags go *inside a wrapper script*, because mnml appends its own arguments after the exe at spawn time:

```text
<your command> --session-id <uuid> --append-system-prompt "<.mnml/CLAUDE.md>" …
```

(For Claude Code; Codex currently gets no extra flags, but the same rule applies — mnml owns the argv tail.) A wrapper that adds flags and forwards mnml's looks like:

```bash
#!/bin/bash
# bin/claude-multi.sh — launch claude with sibling repos attached
exec claude \
  --add-dir ../shared-lib \
  --add-dir ../infra \
  "$@"
```

The `"$@"` matters — drop it and Claude loses the `--session-id` mnml uses for transcript mirroring and `--resume`.

### Template expansion

Commands are template-expanded at **spawn time** (not load time — switching workspaces never bakes in a stale path). The context is workspace-only, so the useful tokens are:

| Token | Expands to |
|---|---|
| `{{workspace}}` | Absolute path of the active workspace root |
| `{{workspace_name}}` | Basename of the workspace |

Editor-context tokens (`{{current_file}}`, `{{cursor_line}}`, …) exist in the wider [launcher template engine](/manual/integrations/launcher-manifests/) but expand to empty here — there's no "current file" at AI-chip-click time. Unknown tokens stay literal, so a typo executes visibly instead of vanishing.

## Creating profiles from the UI

You never have to touch the TOML. Right-click the Claude Code or
Codex chip and every profile operation is a menu row:

- **New launch profile…** — a two-step prompt: profile *name* (e.g.
  `multi-repo`), then its *command* (seeded with `{{workspace}}/` so a
  workspace-relative wrapper is a few keystrokes away). Accepting
  writes the `[[launch_profile]]` into
  `<workspace>/.mnml/integrations/<id>.toml` for you.
- **New session: <name>** — one row per resolved profile; fires a
  single session with that launcher (the tab is suffixed `(name)`).
- **Default: <name>** — persists which profile plain clicks use; the
  ✓ marks the current default.
- **Remove profile: <name>** — deletes a workspace-declared profile
  (and clears `default_profile` if it pointed there). Builtin and
  user-global profiles don't get remove rows — edit those files
  directly.

The TOML in the next section is what those menu actions read and
write — hand-editing and the UI stay interchangeable.

## The right-click menu

Profiles surface on both chip locations:

- the **integration chip** in the sidebar rail / integrations list, and
- the **per-leaf AI chips** in each pane's tab strip (top-right cluster, next to the terminal + H/V split buttons).

Right-click either. When two or more profiles resolve for the current workspace, the menu leads with flat profile rows:

```
Claude Code launcher
  New session: default
  New session: multi-repo
  ✓ Default: multi-repo
    Default: default
  ─────────────────────
  Toggle existing Claude Code pane
  New Claude Code session in left half
  …
```

| Row | What it does |
|---|---|
| `New session: <name>` | Spawns **one** session with that profile. No state change — the configured default is untouched. |
| `Default: <name>` | Persists `default_profile = "<name>"` into the **workspace** manifest. `✓` marks the current default. |

With only the builtin `default` profile resolving (no manifests, or manifests without profiles), the rows don't appear at all — the menu stays as it was before profiles existed. Any custom profile, or a legacy `launcher =` override, activates them.

On the rail chip's menu the profile rows sit directly above **Set launcher script…**, which still shows the current single-override in its label when one is set.

### One-off sessions

`New session: <name>` always opens a **fresh split** — it deliberately bypasses the 2×2 / 3×2 auto-tile grid logic that plain Claude launches use, so a one-off wrapper session doesn't reshuffle your grid. If the profile isn't the builtin `default`, the tab label gets a suffix so concurrent sessions are tellable apart in the bufferline and pty tab strip:

```text
 Claude Code  ×   Claude Code (multi-repo)  ×   +
```

If a profile name doesn't resolve in this workspace (say, a stale menu after you deleted the manifest), the launch degrades to a toast — `launch profile 'multi-repo' not found for claude_code` — rather than spawning the wrong thing.

### Persisting a default

`Default: <name>` writes `default_profile = "<name>"` into `<workspace>/.mnml/integrations/<id>.toml`, creating the file and directories if needed. The write is surgical: everything else in the file — comments, `[[launch_profile]]` tables, auth values — is preserved, any existing `default_profile` line is replaced (never duplicated), and the key is inserted above the first table header so it stays top-level. A toast confirms: `default claude_code profile → multi-repo`.

From then on, every plain launch — chip left-click, `:ai.claude_code`, `<leader> a c`, the pty tab strip's `+`, the palette — spawns that profile.

## Default resolution, precisely

When mnml needs "the default command" it walks this precedence, first hit wins:

1. Workspace `default_profile`
2. Workspace legacy `launcher = "…"` (treated as choosing the `wrapper` profile)
3. User-global `default_profile`
4. User-global legacy `launcher = "…"`
5. Builtin `default`

A `default_profile` naming a profile that doesn't resolve in the current workspace falls back to `default` rather than failing — so a user-global `default_profile = "multi-repo"` referencing a profile that only exists in one workspace's manifest is harmless everywhere else: those workspaces just launch the bare binary.

Unparseable manifest files are tolerated (you get the builtin only), and blank `name` / `command` entries are skipped.

## Back-compat: the legacy `launcher =` override

Before profiles, the chip's right-click **Set launcher script…** prompt wrote a single-field override:

```toml
# <workspace>/.mnml/integrations/claude_code.toml
launcher = "{{workspace}}/bin/claude-multi.sh"
```

That form still works, unchanged — it now materializes as a profile named **`wrapper`**, and it stays the default when no explicit `default_profile` key is present. Existing setups behave identically; they just gain the menu rows (because `wrapper` + `default` = two profiles), so you can now fire a plain-`claude` session from an overridden workspace without editing anything.

**Set launcher script…** remains the quickest path for the simple case — one workspace, one wrapper, no ceremony. Enter a path to set it; submit an empty prompt to clear it (which deletes the file if `launcher` was its only field). Reach for `[[launch_profile]]` when you want *both* commands reachable, more than two, or a checked-in team default.

## The team-workspace pattern

The motivating case: a multi-repo workspace whose Claude sessions need sibling repos attached. Check the manifest and the wrapper into the repo:

```toml
# <workspace>/.mnml/integrations/claude_code.toml  — committed to git
default_profile = "multi-repo"

[[launch_profile]]
name    = "multi-repo"
command = "{{workspace}}/bin/claude-multi.sh"
```

```bash
#!/bin/bash
# bin/claude-multi.sh — committed to git, chmod +x
exec claude --add-dir ../shared-lib --add-dir ../infra "$@"
```

Everyone who clones the repo and opens it in mnml gets the wrapper as their default Claude launch — no per-machine setup, and `{{workspace}}` means it works wherever the clone lands. When someone wants a plain session (debugging the wrapper, or just a quick question with no multi-repo context), it's right-click → **New session: default**. The same shape works verbatim for `codex.toml`.

Because workspace entries win per name, a teammate can also layer a personal variant in `~/.config/mnml/integrations/claude_code.toml` — say a `fast` profile pointing at a different toolchain — and it shows up in the menu alongside the committed `multi-repo` in every workspace.

## How it relates to other launch surfaces

- **Profiles apply to the built-in AI chips only** (`claude_code`, `codex`) — the two cases where mnml itself chooses the exe. Community integrations control their own spawn via `binary = "…"` in their manifest, and shell / task panes have their own config (`$SHELL`, `[tasks.*]`).
- **Every default-profile launch path is covered** — chip clicks, `ai.claude_code` / `ai.codex` and their `_new` / placement variants, `claude --resume` re-attachment, and `ai.chat`-seeded sessions all resolve the exe through the same profile machinery.
- The manifest file is shared real estate: the same `<id>.toml` carries `enabled`, glyph/color overrides, and `[[auth]]` values. Profile loading is junk-tolerant — it reads only its three keys and ignores the rest.

## Next

- [AI panes](/manual/ai-panes/) — the pane-and-session surface these profiles feed: tab strips, ticket auto-naming, placement menus
- [Launcher manifests](/manual/integrations/launcher-manifests/) — the full template-token table and manifest schema for integration chips
- [Workspaces & the file rail](/manual/workspaces/) — how `<workspace>/.mnml/` scoping works across features
- [Integration auth](/manual/integrations/auth/) — the `[[auth]]` fields that share the same manifest files
- [Settings & configuration](/manual/settings/) — user-global vs workspace config precedence in general
