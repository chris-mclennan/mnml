---
title: First-launch wizard
description: The one-time-ever modal that auto-opens on a fresh mnml install — Nerd Font check, keyboard probe, vim vs standard input, AI CLI install, AI billing routing, ghost-text backend, and the VS Code `code` shim.
---

The first time you run mnml on a machine, a centered modal opens over the editor asking seven things: whether your terminal font renders Nerd Font glyphs, which modifier chords your terminal actually forwards, vim or standard editing, whether to install Claude Code + Codex, where AI calls should be billed, which ghost-text backend to use, and whether to symlink the VS Code `code` shim. Answer or dismiss. Answers persist to your global config; the flag flips so the modal doesn't come back.

The wizard is a companion to the per-workspace welcome overlay (which teaches shortcuts and fires once per project). On a genuine first launch both are triggered, and the wizard paints completely over the welcome card — so the welcome stands down while the wizard is up and surfaces on the next frame once you close it. A click or `Esc` aimed at the wizard can't retire a card you never saw.

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

## The seven sections

The overlay is a single scrollable card, ~74 chars wide, centered. Each section has a header row (`▸` marks focus), a wrapped body-description, and one or more interactive widgets — a vertical radio group (`●` / `○`), an inline chip row, a live checklist, or a detection badge. A full-screen dim backdrop paints under the card so tree / editor content doesn't bleed past its right edge.

The order isn't arbitrary — it was reshuffled once because dependencies didn't flow. Ghost text used to be asked *first*, before the CLIs were installed or the billing question had been raised, which is a chicken-and-egg wall a user hit and reported. Now each section only asks something the ones above it have made answerable.

| # | Section | What it does at Finish |
|---|---------|------------------------|
| 1 | Nerd Font | Diagnostic only — no config write. `Space` auto-installs Symbols Nerd Font Mono |
| 2 | Keyboard | Live key-arrival probe. Nothing persists. `Space` applies the ghostty fix |
| 3 | Input style | Persists `[editor] input_style` — only if you actually cycled the row |
| 4 | Claude Code + Codex | `Space` = spawn a Pty pane running `npm install -g …` |
| 5 | AI billing preference | Persists `[ai.routing.claude] backend` / `[ai.routing.codex] backend` — only if you cycled a row |
| 6 | AI ghost-text | Persists `[ai] suggest_backend` + `[ai] inline_suggestions` (`false` on Skip) |
| 7 | VSCode `code` shim | `Space` = spawn a Pty pane running `sudo ln -sf …` |

Sections 3, 5 and 6 are choice UIs — they write to the answer struct as you cycle and only reach disk at Finish. Sections 1, 4 and 7 fire real install commands on `Space` and immediately close the wizard as "Ask me later" so the Pty pane is visible; re-open with `first_launch.show` once installs are done. Section 2 changes nothing at all — it's a measurement.

## Keys

| Key | Action |
|-----|--------|
| `↑` `↓` / `j` `k` | Move focused section (inside section 5, move between the Claude and Codex rows first) |
| `1`–`7` | Jump directly to section N |
| `←` `→` / `h` `l` | Cycle the focused section's choice (sections 1, 3, 5, 6) |
| `y` / `n` | Nerd Font quick-answer (section 1) |
| `Space` | Fire the section's action — font install (1), keyboard fix (2), CLI install (4), cycle routing (5), shim install (7) |
| `Enter` | Finish — commit answers, set `first_launch_complete = true`, toast |
| `Esc` | Ask me later — close without setting the flag |

`Enter` and `Esc` are the two exits, and they mean different things: `Enter` says "I'm done, don't ask again", `Esc` says "I'll get to it, remind me tomorrow". Both close the modal cleanly.

Two navigation details worth knowing:

- **Modified arrows never cycle a choice.** Every section's `←` / `→` arm is guarded against modifiers, so the probe chords in section 2 (`Ctrl+→`, `Option+→`, `Cmd+→`) can't quietly change the radio you're standing on while you test your keyboard.
- **Section 5 has two rows.** `↓` moves from Claude to Codex before advancing to the next section, so `j` can't drop out of routing before you've answered for Codex.

## Section 1 — Nerd Font

mnml uses Nerd Font glyphs for icons throughout the UI. The section body renders four sample glyphs:

```
Sample glyphs:   ▸   󰈙   󰅖   ●
```

If those show up as icons, press `y`. If they render as boxes or `?` marks, press `n` — or press `Space` and mnml installs Symbols Nerd Font Mono for you:

| OS | Command |
|---|---|
| macOS | `brew install --cask font-symbols-only-nerd-font` |
| Linux | download `NerdFontsSymbolsOnly.zip` into `~/.local/share/fonts/nerd-symbols`, unzip, `fc-cache -f` |
| Windows | `winget install --id NerdFonts.SymbolsOnly -e` |

The install runs in a Pty pane (the wizard closes so you can watch it), and the toast that follows names the follow-up step for your detected terminal — installing the font isn't enough, you still have to point the terminal at it and restart.

**macOS 26 note:** use the auto-install. Dragging the `.ttf` into `~/Library/Fonts` or Font Book *looks* like it works — Font Book reports "Installed" — but CoreText silently fails to register unsigned Nerd Fonts under user or system scope, and terminals then fall back to an embedded older copy that renders some icons (notably the git pull glyph at U+EB40) with the wrong outline. The Homebrew cask path bypasses the failing validator.

The `y` / `n` answer itself isn't written to config — it's diagnostic. mnml ships an `--ascii` flag and an ASCII fallback per chip; the question exists so users who don't know what a Nerd Font is find out early rather than staring at boxes forever.

## Section 2 — Keyboard

A live checklist of four chords. Press each one and watch it tick:

```
  ✓  ctrl_right     Word right (Linux/Windows native)
  ·  alt_right      Word right (macOS native)
  ·  cmd_right      End of line (macOS native)
  ✓  end            Control probe — end of line
```

Word and line motion in standard mode depend on your terminal actually forwarding those chords, and several don't by default — macOS binds `Ctrl+←/→` to Mission Control, and most macOS terminals use Option to compose accented characters rather than sending Alt. mnml can't detect this passively: a key that never arrives is indistinguishable from a key you didn't press. So the section asks you to press them.

The Keyboard section claims its probe chords *before* anything else interprets them — but only modified arrows and `End`, so plain arrows still move between sections. Under the checklist you get a verdict line and the remedy for the **first** missing chord, specific to the terminal mnml detected. Where an auto-fix exists (ghostty on macOS), the section grows a `Space — apply this fix` line.

Nothing here persists. Ticks are facts about your environment, not answers.

`keys.doctor` from the palette reopens the wizard focused on exactly this section — see [Word & line motion, and keys.doctor](/manual/keyboard-motion/) for the probe rules, the ghostty config write, and the per-terminal fixes.

## Section 3 — Input style

`vim` or `standard`. Snapshotted from `[editor] input_style` at open; the row matching your persisted value is tagged `(current)`.

- **standard** — modeless, VS Code / macOS shortcuts.
- **vim** — modal (`i` to insert, `Esc` to normal, `:` for ex-commands).

**The wizard only writes this key if you actually cycled the row** with `←` / `→` / `h` / `l`. The pre-selection is a display convenience, not intent — without the guard, a vim user who reopened the wizard for the Nerd Font check and hit `Enter` would silently lose vim mode.

You can always swap later via `editor.use_vim` / `editor.use_standard` from the palette, or `:set input=vim`. See [Editing](/manual/editing/) for the mode-by-mode reference.

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

## Section 5 — AI billing preference

Two rows — Claude Code and Codex — each an inline chip row rather than a vertical radio, so both fit at 74 cells:

```
   ▸ Claude Code:   Auto   [Sub]   API    Off
     Codex:        [Auto]   Sub    API    Off
```

`↑` / `↓` move between the two rows; `←` / `→` / `h` / `l` / `Space` cycle the focused row's choice. The `▸` marker shows which row your arrows will affect.

| Choice | Meaning |
|---|---|
| **Auto** | Leave the resolved default alone — no key is written |
| **Sub** | Route through the vendor's own CLI, reusing your Max/Pro or ChatGPT Plus plan (no per-token charge) |
| **API** | Bill against your pay-per-token console budget. Claude needs `$ANTHROPIC_API_KEY`, Codex needs `$OPENAI_API_KEY` |
| **Off** | Hide that product's chips and disable its commands entirely |

Pre-selected from the **declared** config value (not the resolved one), so a returning user sees their existing pin. Like input style, this only persists if you actually cycled a row — otherwise hitting `Enter` on a wizard you reopened for the font check would rewrite pins you'd set deliberately. Choosing Auto writes nothing, because leaving the keys undefined is what Auto means at the config level.

Persisted values land as:

```toml
[ai.routing.claude]
backend = "sub"

[ai.routing.codex]
backend = "off"
```

The change is also reflected in the live in-memory config, so chip visibility and command gating follow immediately without a restart.

## Section 6 — AI ghost-text

Choose your inline-completion backend:

- **Claude Code sub** — reuses your Max/Pro plan via the OAuth token Claude Code already caches. No separate API key. Recommended, and auto-selected when the `claude` binary is on `$PATH` *and* `~/.claude/` exists (a decent proxy for "signed in at least once").
- **Claude API** — bills a pay-per-token console budget; needs `$ANTHROPIC_API_KEY`.
- **Local model** — a ~1GB quantized model that runs fully in-process via the bundled `mnml-fim-engine` crate. Downloaded on first use and cached forever; no API key, offline thereafter.
- **Skip for now** — leaves inline suggestions off. Decide later via `ai.setup_suggestions`.

At Finish, the first three write `[ai] suggest_backend = "…"` **and** `[ai] inline_suggestions = true`.

**Skip writes `inline_suggestions = false` explicitly.** That write isn't redundant with the config default. The row's label promises "decide later", so a declining user has to end up off and *stay* off even if the default changes — and for one window it didn't: Skip fell through to a default of `true`, so the label said one thing and the code did the other. Skipping also suppresses the one-time discoverability hint, since you just saw the feature and said no.

Ghost text is opt-in because it ships up to ~3000 characters of buffer context to a remote backend. Files whose names look secret-bearing are never sent regardless of the setting — see [Security & hardening](/manual/security/#what-mnml-wont-send-to-an-ai-backend). See [AI panes](/manual/ai-panes/) for the full breakdown of inline vs pane-driven AI.

## Section 7 — VSCode `code` shim

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

## What persists at Finish

On `Enter`, mnml commits the collected answers to your global config in one pass and toasts *"Setup saved. Reopen anytime via `first_launch.show`."*

Writes go through the same `persist_ui_*` / `persist_editor_*` / `persist_ai_*` helpers that every runtime toggle in mnml uses (see [Configuration](/manual/settings/#persisting-toggles) for the in-place TOML merge semantics). Unrelated keys and comments in your `config.toml` survive untouched — only the specific keys the wizard writes get updated.

Concretely, from a stock install choosing `vim`, Claude Code on **Sub**, and the `local` ghost-text backend:

```toml
# ~/.config/mnml/config.toml
[ui]
first_launch_complete = true

[editor]
input_style = "vim"

[ai]
inline_suggestions = true
suggest_backend = "local"

[ai.routing.claude]
backend = "sub"
```

Nerd Font answers, the keyboard probe's ticks, and the install-fired flags aren't persisted — those either fire immediately (install actions) or are diagnostic only.

If a write fails — no `$HOME`, a non-writable config dir, a portable-mode path that drifted — the toast names the first error and says the wizard will reopen next launch, rather than reporting success and silently resetting.

## What Esc leaves behind

Nothing. The `[ui] first_launch_complete` flag stays `false`, the answer struct is dropped, and the wizard reopens on the next launch. Toast: *"Wizard skipped — will ask again next launch. `first_launch.show` to reopen now."*

This is deliberate — the wizard is short and the questions matter (a user who never picks an AI backend gets no ghost text; a user who never chooses vim vs standard gets whichever default happens to ship). Making Esc genuinely mean "later" rather than "never" nudges users through it eventually.

If you actively don't want to see the wizard again, either press `Enter` on a stock set of answers, or set `first_launch_complete = true` in config directly.

## What happens on the next launch

`main.rs` re-reads `[ui] first_launch_complete` at startup. If `true`, the wizard is skipped entirely. If `false`, it opens after the workspace welcome. There's no per-session state — leave a machine for a month, come back, the flag is still what you left it as.

Install actions (sections 1, 4 and 7) close the wizard as "Ask me later" specifically so the wizard reopens next launch and you can verify the install worked. If Claude Code + Codex are both detected on that next open, section 4's badge flips to `[✓ installed]` and Space toasts the "already installed" no-op instead of firing another install.

## Interaction with other modals

The wizard stands down if a prompt, picker, or context menu is on top — those take Esc-precedence so you can dismiss the smaller thing first without losing your wizard answers. Otherwise the wizard is drawn last, so it wins over the underlying pane chrome.

The per-workspace welcome card is the reverse: it stands down while the wizard is up. On a genuine first launch both are triggered and the wizard paints over the card completely, so keying dismissal off "is the welcome enabled" meant the very first click — and the `Esc` that means "ask me later" on the wizard — retired a cheatsheet nobody had seen and wrote `.mnml/.welcomed`. One predicate now answers "is the card actually painted", and the drawer and both dismiss paths share it.

Startup ordering (from `main.rs`):

1. Portable-choice modal (rare — first-launch inside a freshly-created `mnml-data/`).
2. Per-workspace welcome overlay (`.mnml/.welcomed` gate).
3. First-launch wizard (`first_launch_complete` gate).
4. Reset-toast (only after `app.reset_to_defaults`).
5. Marketplace refresh (background thread).
6. Startup workspace picker (`--startup-picker` flag).

Each is independent and idempotent — modals stack, dismissing one reveals the next.

## Next

- [Word & line motion, and keys.doctor](/manual/keyboard-motion/) — the probe behind section 2, and every per-terminal fix it can suggest.
- [AI panes](/manual/ai-panes/) — how the ghost-text backend and routing choices fit into the broader AI surface.
- [Editing](/manual/editing/) — vim vs standard, the choice from section 3, with the full mode-by-mode reference.
- [Security & hardening](/manual/security/) — what ghost text will and won't send, and why it's off until you answer.
- [Integration auth](/manual/integrations/auth/) — the companion "one-time setup" flow for integrations that need tokens.
- [Settings & configuration](/manual/settings/) — the schema-driven overlay for everyday toggles, and every knob in the TOML config.
