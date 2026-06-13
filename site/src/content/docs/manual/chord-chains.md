---
title: Chord chains — two-stroke keybindings (`ctrl+k ctrl+i` and friends)
description: How mnml binds and resolves multi-stroke chord chains — the VS-Code / vim `timeoutlen` idiom, the ambiguous-prefix case, and how to write your own.
---

mnml's keymap takes single chords (`ctrl+s`, `alt+k`, `f3`) and **chord chains** — whitespace-separated sequences like `ctrl+k ctrl+i` (VS Code's "hover") or `ctrl+w h` (vim's "focus left split"). A chord chain is one binding the user types as two key presses in a row; the keymap waits for the second stroke before deciding what to fire.

This page covers the chain syntax accepted in TOML, the resolution rules (including the ambiguous case where a prefix is *also* bound on its own), the abort + timeout behavior, and the built-in chains that ship with mnml.

## The spec syntax

A key spec in a `[keys.global]` / `[keys.vim]` / `[keys.standard]` table — or in any `Command.keys` default — is a string. Single-token specs are single chords. Whitespace-separated multi-token specs are chord chains:

```toml
[keys.global]
"ctrl+k ctrl+i"   = "lsp.hover"            # two strokes
"ctrl+k ctrl+s"   = "view.settings"        # two strokes, shares the ctrl+k prefix
"ctrl+w h"        = "split.focus_left"     # two strokes (vim-style)
"ctrl+s"          = "file.save"            # one stroke
"alt+k"           = "lsp.hover"            # one stroke, same command via a different chord
```

Each token parses through the standard `parse_key_spec` rules — modifiers (`ctrl+`, `shift+`, `alt+`, `cmd+` / `super+`) in any order, then a named key (`enter`, `tab`, `esc`, `space`, `f5`, `pageup`, …) or a single character. Any token that doesn't parse drops the **whole** spec with a startup warning:

```
mnml: command `foo.bar` declares key `ctrl++ x` that doesn't parse — chord ignored, command still palette-reachable
```

The warning surfaces immediately at startup so a typo doesn't silently strand a binding for weeks. The command stays reachable from the palette.

Empty / `"none"` / `"unbound"` as the *value* (not the key) removes the binding at that sequence — useful for unlearning a default:

```toml
[keys.vim]
"ctrl+w" = ""           # remove the vim window-prefix default
```

## How resolution works

When you press a key, mnml feeds the chord into a pending sequence and looks it up. The lookup returns one of four results — captured by `SeqResolution`:

| Result | Meaning | What mnml does |
|---|---|---|
| `Run(id)` | Exact match; no longer binding extends this sequence. | Fire `id` immediately, clear pending. |
| `Pending` | No exact match, but the sequence is a prefix of one or more longer bindings. | Hold the chord, start a 1s deadline, wait for the next key. |
| `PendingWithFallback(id)` | The sequence is *both* bound on its own AND a prefix of longer bindings. | Hold for 1s — if the next key extends, fire the longer binding; if it doesn't or the timeout elapses, fire `id`. |
| `None` | Nothing matches, nothing pending. | Clear pending, fall through to the focused pane handler. |

The third row is the interesting one — vim's "ambiguous prefix" case. `ctrl+k` is bound to `whichkey.leader` (it opens the leader popup), and `ctrl+k ctrl+i` is bound to `lsp.hover`. Pressing `ctrl+k` alone needs to *eventually* open the leader popup, but only after mnml is sure you weren't about to follow with `ctrl+i`.

The resolution plays out three ways:

1. You press `ctrl+k` then `ctrl+i` within 1s → `Run("lsp.hover")` fires the moment the second key lands. The leader popup never paints.
2. You press `ctrl+k` and pause past 1s → the deadline elapses, `tick_chord_chain` fires `whichkey.leader`. The popup opens.
3. You press `ctrl+k` then `Esc` → pending clears silently. No command fires. (Vim's `Ctrl+C` / `Esc` convention — abort without committing.)

The 1s window is `CHORD_CHAIN_TIMEOUT_MS` in `src/tui.rs`. It mirrors vim's `g:timeoutlen` default and is roughly what VS Code uses; it isn't a config knob yet.

### What happens when a chain bottoms out

If you start a chain that doesn't extend cleanly — say `ctrl+k` then a key that doesn't continue any binding — mnml does three things in order:

1. Fires the prior pending's fallback (if there was one), so `ctrl+k` → `j` opens the leader popup *then* sends `j` as a fresh stroke.
2. Clears pending state.
3. Replays the current key as a brand-new sequence start. If it binds, fire it; otherwise fall through to the focused pane handler.

This means a botched chain never *eats* the second key. You always either fire the canonical inner command (the fallback), get a single-key binding on the new stroke, or pass the stroke through to the editor / tree.

## Discovering chains

Three surfaces show you every bound chain:

- **`:Maps`** — opens an ex-command-line listing of every binding with its sequence in canonical spec form (`ctrl+k ctrl+i  →  lsp.hover`). Chord-chains render with the chord tokens joined by a space.
- **`<leader>?`** — the cheatsheet pane. Same data, sectioned by command-group, searchable with `/`. See [Cheatsheet — all chords](/manual/cheatsheet-all/).
- **`F1` / `Ctrl-Shift-P`** — the command palette. Every command shows its bound chord on the right. Chord chains render the same way.

For the leader trie specifically (`<space>…` in vim mode, `Ctrl-K…` in standard mode), the [which-key](#chord-chains-and-the-leader-popup) popup paints continuations as you type the prefix.

## Aborting an in-flight chain

Two ways to back out of a pending prefix without firing the fallback:

- **`Esc`** — the canonical abort. Clears pending, doesn't fire the fallback. Symmetric with `Esc` in every other modal state.
- **Wait past the 1s deadline** — `tick_chord_chain` runs every frame from the main loop, so a dangling prefix resolves on its own ~1s after you give up. If there's a fallback, this fires it (the popup opens, etc.); if there isn't, the pending just clears.

A focus change (clicking another pane, opening the palette, etc.) also clears pending state. The chain layer never survives a modal overlay open / close.

## Built-in chord chains

The shipped chains today:

| Chain | Command | Notes |
|---|---|---|
| `ctrl+k ctrl+i` | `lsp.hover` | VS Code's "hover" chord. Replaced the earlier `alt+k` shortcut (kept palette-reachable). |
| `ctrl+w h` / `j` / `k` / `l` | `split.focus_*` | Vim window navigation. The `ctrl+w` prefix is its own group with ~12 leaf chords. |
| `ctrl+w >` / `<` / `+` / `-` | `split.resize_*` | Vim window resize. |
| `ctrl+w H` / `J` / `K` / `L` | `split.move_*` | Vim "move split to edge." |
| `ctrl+w x` / `r` / `T` / `o` | `split.swap` / `rotate` / `to_tab` / `close_others` | Misc vim window ops. |

`ctrl+w` itself is bound to `whichkey.window` (a sub-leader for the window-prefix group), so it's the canonical `PendingWithFallback` case in vim mode — the popup paints after 1s if you don't extend.

Standard-mode keeps `ctrl+w` as `buffer.close` (the VS Code chord). The vim-mode `ctrl+w` window-prefix bindings are only reachable when `input_style = "vim"`.

## Chord chains and the leader popup

The leader popup (`<space>` in vim, `Ctrl-K` in standard) is itself just a `PendingWithFallback` chain — `whichkey.leader` is the fallback for the `<space>` prefix. Press `<space>`, wait, and the popup paints; press `<space> f f` quickly and the file picker opens before the popup ever renders.

This means the leader trie composes with chord chains naturally. You don't need to bind `<space> g d` as a chord chain in TOML — it's a node in the [which-key trie](/manual/coming-from-nvchad/#the-leader-trie) that the popup walks automatically.

The chord-chain layer is for chains *outside* the leader trie: `ctrl+k ctrl+i` (VS Code-style), `ctrl+w h` (vim-style), and anything you wire up under `[keys.global]` with a whitespace-separated spec.

## Examples

### Bind VS Code's go-to-symbol chain

VS Code's "Show All Symbols" is `Ctrl+T`; "Go to Symbol in File" is `Ctrl+Shift+O`. Want a two-stroke variant? Wire it up:

```toml
[keys.standard]
"ctrl+k ctrl+s"   = "lsp.workspace_symbols"
"ctrl+k ctrl+f"   = "lsp.document_symbols"
"ctrl+k ctrl+o"   = "lsp.outline"
```

`ctrl+k` is already `whichkey.leader` in standard mode, so each binding is a `PendingWithFallback` extension. Pressing `ctrl+k` and waiting still opens the leader popup — the new bindings shadow nothing.

### Bind vim-style `g`-prefix chains

In vim, `gd` is `lsp.goto_definition` and `gD` is `lsp.goto_declaration` — but those are *editor* chords, handled by the vim input handler from buffer focus, not the keymap. If you want a global `g`-prefix chain that fires from any focus, use a chord chain at the keymap layer:

```toml
[keys.global]
"g d"   = "lsp.goto_definition"     # space between, two distinct chords
"g r"   = "lsp.find_references"
```

Note the space — `"gd"` is a single chord (the literal character `g`, then immediately `d` — which `parse_key_spec` reads as the `d` chord, dropping the `g`). The whitespace-separated form is what makes it a *chain*.

### Bind a three-key chain

Chains can be longer than two strokes — the keymap is `HashMap<Vec<Chord>, String>`, no length cap. Use sparingly:

```toml
[keys.standard]
"ctrl+k ctrl+r ctrl+f"   = "git.refresh"
```

Three strokes means two 1s windows in the worst case. Reach for it when the prefix is genuinely shared (a custom `ctrl+k ctrl+r` group), not as a substitute for a single binding.

## Next

- [Editing](/manual/editing/) — the input-layer architecture and how chord resolution sits above it
- [Coming from NvChad](/manual/coming-from-nvchad/) — the leader trie reference, `<space>` chord vocabulary
- [Coming from VS Code](/manual/coming-from-vscode/) — the `Ctrl+K` chord vocabulary
- [Cheatsheet — all chords](/manual/cheatsheet-all/) — every default binding in one searchable table
- [Settings & configuration](/manual/settings/) — `[keys.*]` overlay rules + the rest of the TOML schema
