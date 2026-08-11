---
title: First-launch wizard
description: The one-time-ever modal that auto-opens on a fresh mnml install to pick AI ghost-text backend, vim vs standard input, verify Nerd Font glyphs, and offer to install Claude Code + Codex + the `code` shim + process monitors.
---

The first time you run mnml on a machine, a centered modal opens over the editor asking six things: which AI ghost-text backend to use, vim or standard editing, whether your terminal font renders Nerd Font glyphs, and whether you'd like mnml to install Claude Code + Codex, the VS Code `code` shim, and the process monitors (`btop` / `htop` / `iftop`). Answer or dismiss. Answers persist to your global config; the flag flips so the modal doesn't come back.

The wizard is a companion to the per-workspace welcome overlay (which teaches shortcuts and fires once per project) — welcome runs first, wizard runs next, and after that mnml is quiet until you ask.

## When it opens

Three triggers:

- **First-ever launch.** `main.rs` checks `[ui] first_launch_complete` at startup. Default is `false`, so the wizard opens after the per-workspace welcome runs.
- **Any time you re-open it.** Palette command `first_launch.show` (title: *"First-launch setup wizard (reopen)"*, group `view`). Handy to re-verify state after installing a Nerd Font or bouncing the machine.
- **After you skipped it.** Esc = "Ask me later" leaves the flag `false`, so the wizard reopens on the next mnml launch. Only `Enter` (Finish) flips the flag to `true`.

To silence the wizard permanently without answering anything:

```toml
# ~/.config/mnml/config.toml
[ui]
first_launch_complete = true
```

To make it come back:

```toml
[ui]
first_launch_complete = false
```

Or drop the key entirely — the default is `false`.

## The six sections

The overlay is a single scrollable card, ~74 chars wide, centered. Each section has a header row (`▸` marks focus), a wrapped body-description, and one or more interactive widgets — either a vertical radio group (`●` / `○`), a check-box list, or a detection badge. A full-screen dim backdrop paints under the card so tree / editor content doesn't bleed past its right edge.

| # | Section | What it does at Finish |
|---|---------|------------------------|
| 1 | AI ghost-text | Persists `[ai] suggest_backend` + `[ai] inline_suggestions = true` (unless "Skip") |
| 2 | Input style | Persists `[editor] input_style` = `vim` or `standard` |
| 3 | Nerd Font | Diagnostic only — no config write; "No" toasts the nerdfonts.com link |
| 4 | Claude Code + Codex | Space = spawn a Pty pane running `npm install -g …` |
| 5 | VSCode `code` shim | Space = spawn a Pty pane running `sudo ln -sf …` |
| 6 | Process monitors | Space = spawn a Pty pane running `brew install …` for whatever's checked |

Sections 1-3 are pure choice UIs — they write to the answer struct as you cycle, and get committed to disk only at Finish. Sections 4-6 fire real install commands on `Space` and immediately close the wizard as "Ask me later" so the Pty pane is visible; you re-open with `first_launch.show` once installs are done.

## Keys

| Key | Action |
|-----|--------|
| `↑` `↓` / `j` `k` | Move focused section |
| `1`–`6` | Jump directly to section N |
| `←` `→` / `h` `l` | Cycle the focused section's choice (sections 1, 2, 3) |
| `y` / `n` | Nerd Font quick-answer (section 3) |
| `Space` | Fire section-specific action — install (4, 5, 6) |
| `b` / `t` / `i` | Toggle each monitor checkbox (section 6) |
| `Enter` | Finish — commit answers, set `first_launch_complete = true`, toast |
| `Esc` | Ask me later — close without setting the flag |

`Enter` and `Esc` are the two exits, and they mean different things: `Enter` says "I'm done, don't ask again", `Esc` says "I'll get to it, remind me tomorrow". Both close the modal cleanly.

## Section 1 — AI ghost-text

Choose your inline-completion backend:

- **Claude API** — fastest; needs `$ANTHROPIC_API_KEY`.
- **Local model** — a ~1GB quantized model that runs fully in-process via the sibling `fim-engine` crate. Downloaded on first use and cached forever; no API key, offline thereafter.
- **Skip for now** — leaves inline suggestions off. Decide later via `ai.setup_suggestions` from the palette.

Snapshotted at open — if `[ai] suggest_backend` is already set, that choice is pre-selected. At Finish, non-Skip picks write both `[ai] suggest_backend = "..."` and `[ai] inline_suggestions = true` via `persist_ai_string` / `persist_ai_bool`. Skip writes nothing.

See [AI panes](/manual/ai-panes/) for the full breakdown of inline vs pane-driven AI.

## Section 2 — Input style

`vim` or `standard`. Snapshotted from `[editor] input_style` at open, so if you've already committed to a mode via config or `:set input=…`, it's pre-selected.

- **vim** — modal (`i` to insert, `Esc` to normal, `:` for ex-commands).
- **standard** — modeless like VS Code / macOS.

You can always swap later via `editor.use_vim` / `editor.use_standard` from the palette, or `:set input=vim` from vim mode. See [Editing](/manual/editing/) for the mode-by-mode reference.

## Section 3 — Nerd Font

Self-report. The section body renders four sample glyphs:

```
Sample glyphs:   ▸   󰈙   󰅖   ●
```

If those show up as icons in your terminal, press `y`. If they render as boxes or replacement glyphs, press `n` — mnml toasts a link to [nerdfonts.com/font-downloads](https://www.nerdfonts.com/font-downloads) so you can install one and set it as your terminal font.

The answer isn't written to config either way — it's diagnostic. mnml already ships an `--ascii` flag and an ASCII fallback per chip; the question exists so users who don't know what a Nerd Font is can find out early rather than staring at boxes forever.

## Section 4 — Claude Code + Codex

Detection badge for each CLI:

- `[✓ installed]` (green) — mnml probed `$PATH`, found the binary.
- `[ not installed — Space to install ]` (orange) — press Space to fire the install.

Space runs whichever of the two isn't already installed, combined into one Pty command:

```sh
npm install -g @anthropic-ai/claude-code && npm install -g @openai/codex
```

Requires `npm` on your `$PATH`. The wizard closes as "Ask me later" so the Pty pane is visible — watch the install output there. Re-open with `first_launch.show` after installs finish to see the badges flip.

If both CLIs are already installed, Space toasts *"Claude Code + Codex already installed."* and does nothing.

## Section 5 — VSCode `code` shim

If you use `code` from your terminal (e.g. `code some/file`), it needs to be on your `$PATH`. VS Code doesn't wire this up on install by default; you either open Command Palette → "Shell Command: Install 'code' command in PATH" from inside VS Code, or you symlink it yourself.

mnml probes for `code` on `$PATH`. If present, the badge shows `[✓ installed]`. If missing, Space fires:

```sh
sudo ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" /usr/local/bin/code
```

`sudo` needs a real TTY for the password prompt, which is why this fires inside a Pty pane rather than a background task. The wizard closes as "Ask me later" so you can enter your password.

Guardrails:

- If `code` is already on `$PATH`, Space toasts *"`code` shim already on PATH."* and no-ops.
- If `/Applications/Visual Studio Code.app` isn't at the expected path, Space toasts a hint to install VS Code first and no-ops. mnml won't create a broken symlink.

Only fires on macOS — the path is hardcoded to the standard .app bundle location.

## Section 6 — Process monitors

Optional TUI monitors reachable from mnml's `tools.*` palette family (`tools.btop` / `tools.htop` / `tools.iftop`). Nothing here is required to use mnml; the check-boxes just make it one gesture to install whichever ones you want.

| Key | Action |
|-----|--------|
| `b` / `B` | Toggle `btop` |
| `t` / `T` | Toggle `htop` |
| `i` / `I` | Toggle `iftop` |
| `Space` | Fire `brew install <checked-tools>` for whatever's currently checked |

Space with nothing checked toasts a reminder to check something first. The install runs via Homebrew and only works on macOS today — on Linux you'd install via your distro's package manager and mnml would pick them up on the next launch.

Once installed, the `tools.*` commands find them on `$PATH` automatically — see the *External tool launchers* line in [`FEATURES.md`](https://github.com/chris-mclennan/mnml/blob/main/FEATURES.md) for the full list.

## What persists at Finish

On `Enter`, mnml commits the collected answers to your global config in one pass and toasts *"Setup saved. Reopen anytime via `first_launch.show`."*

Writes go through the same `persist_ui_*` / `persist_editor_*` / `persist_ai_*` helpers that every runtime toggle in mnml uses (see [Configuration](/manual/settings/#persisting-toggles) for the in-place TOML merge semantics). Unrelated keys and comments in your `config.toml` survive untouched — only the specific keys the wizard writes get updated.

Concretely, from a stock install choosing `local` + `standard` + `y`:

```toml
# ~/.config/mnml/config.toml
[ui]
first_launch_complete = true

[editor]
input_style = "standard"

[ai]
inline_suggestions = true
suggest_backend = "local"
```

Nerd Font answers, monitor check-box state, and the AI/CLI install-fired flags aren't persisted — those either fire immediately (install actions) or are diagnostic only (Nerd Font).

## What Esc leaves behind

Nothing. The `[ui] first_launch_complete` flag stays `false`, the answer struct is dropped, and the wizard reopens on the next launch. Toast: *"Wizard skipped — will ask again next launch. `first_launch.show` to reopen now."*

This is deliberate — the wizard is short and the questions matter (a user who never picks an AI backend gets no ghost text; a user who never chooses vim vs standard gets whichever default happens to ship). Making Esc genuinely mean "later" rather than "never" nudges users through it eventually.

If you actively don't want to see the wizard again, either press `Enter` on a stock set of answers, or set `first_launch_complete = true` in config directly.

## What happens on the next launch

`main.rs` re-reads `[ui] first_launch_complete` at startup. If `true`, the wizard is skipped entirely. If `false`, it opens after the workspace welcome. There's no per-session state — leave a machine for a month, come back, the flag is still what you left it as.

Install actions (sections 4-6) close the wizard as "Ask me later" specifically so the wizard reopens next launch and you can verify the install worked. If Claude Code + Codex are both detected on that next open, section 4's badge flips to `[✓ installed]` and Space toasts the "already installed" no-op instead of firing another install.

## Interaction with other modals

The wizard stands down if a prompt, picker, or context menu is on top — those take Esc-precedence so you can dismiss the smaller thing first without losing your wizard answers. Otherwise the wizard is drawn last, so it wins over the underlying pane chrome.

Startup ordering (from `main.rs`):

1. Portable-choice modal (rare — first-launch inside a freshly-created `mnml-data/`).
2. Per-workspace welcome overlay (`.mnml/.welcomed` gate).
3. First-launch wizard (`first_launch_complete` gate).
4. Reset-toast (only after `app.reset_to_defaults`).
5. Marketplace refresh (background thread).
6. Startup workspace picker (`--startup-picker` flag).

Each is independent and idempotent — modals stack, dismissing one reveals the next.

## Next

- [AI panes](/manual/ai-panes/) — how the ghost-text backend from section 1 fits into the broader AI surface.
- [Editing](/manual/editing/) — vim vs standard, the choice from section 2, with the full mode-by-mode reference.
- [Integration auth](/manual/integrations/auth/) — the companion "one-time setup" flow for integrations that need tokens.
- [Settings & configuration](/manual/settings/) — the schema-driven overlay for everyday toggles, and every knob in the TOML config.
- [Startup picker](/manual/startup-picker/) — the workspace chooser that fires on launch when configured.
