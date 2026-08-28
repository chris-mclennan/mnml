---
title: Word & line motion, and keys.doctor
description: Why mnml binds word/line motion to four different chords, which ones your terminal actually delivers, and how the keys.doctor probe tells you the difference.
---

Standard mode binds "jump a word" to `Option/Alt+←/→` **and** `Ctrl+←/→`, and "jump to line start/end" to `Cmd+←/→` **and** `Home`/`End`. That redundancy isn't indecision — it's the only way the motion works everywhere. No single chord survives every platform: macOS eats `Ctrl+←/→` before the terminal sees it, `Option+←/→` only arrives as ALT if the terminal has been told to send it, and `Cmd` is forwarded by some terminals and swallowed by others.

The bad part is that the failure is silent and misattributed. You press `Ctrl+→`, nothing happens, and you reasonably conclude mnml's word-jump is broken. It isn't — the keystroke was intercepted several layers up and never reached the process. mnml can't detect that passively either: a key that never arrives is indistinguishable from a key you didn't press. So mnml ships a probe instead — `keys.doctor` — which asks you to press each chord and reports what actually got through.

## The bindings

Standard mode, in an editor pane:

| Chord | Motion | Notes |
|---|---|---|
| `Option/Alt+←` / `Option/Alt+→` | Word left / right | macOS-native word motion |
| `Ctrl+←` / `Ctrl+→` | Word left / right | Linux/Windows-native word motion |
| `Cmd+←` / `Cmd+→` | Line start / end | macOS-native; mirrors `Home`/`End` exactly |
| `Home` / `End` | Line start / end | All platforms; `Fn+←/→` on a MacBook |
| `Ctrl+Home` / `Ctrl+End` | Buffer start / end | `Ctrl+End` lands at the *end* of the last line |
| `Ctrl+Backspace` / `Ctrl+Delete` | Delete word left / right | |

Hold `Shift` with any of the motions above to extend the selection instead of replacing it — the shift handling lives in one `mv` helper, so every motion behaves the same way (start a selection if there isn't one, extend it if there is).

`Cmd+←` is not a shortcut to column 0. It routes through the same `smart_home` closure as `Home`, so it inherits VS Code's smart-home behavior: the first press lands on the first non-whitespace character, a second press (cursor already there) goes to column 0. On a line with no leading whitespace it goes straight to column 0 — no wasted keypress. The two routes share one implementation specifically so they can't drift apart, and there's a test (`cmd_left_and_home_agree_in_both_smart_home_states`) asserting they agree in both states.

One deliberate non-binding: `Ctrl+Alt+←/→` is a plain character-wise `MoveLeft`/`MoveRight`, not a word jump. The word-motion arms are guarded (`alt && !ctrl`, `ctrl && !alt`), so a combined chord doesn't accidentally count as either single modifier.

### Vim mode doesn't have this problem

Word motion in vim mode is `w` / `b` / `e` (and `W` / `B` / `E` for WORDs) — unmodified letters that every terminal forwards, on every platform, with zero configuration. Line motion is `0` / `^` / `$`. Vim mode maps `Home` and `End` onto `MoveLineStart` / `MoveLineLastChar` as a convenience, but it has no modified-arrow word motion at all.

So: **everything on this page is a standard-mode concern.** If you're in vim mode and `Option+→` does nothing, that's expected — use `w`. See [Editing](/manual/editing/) for the full modal surface.

## keys.doctor

`keys.doctor` is a live checklist. It shows four chords; you press each one and watch it tick. A tick is a fact about your environment, not an answer to a question — nothing on this screen persists to config.

### Two ways in

- **The first-launch wizard's Keyboard section.** New installs hit it automatically — it's the second section, right after the Nerd Font check, because it answers the same shape of question: *does this terminal actually deliver what mnml needs?* Neither is detectable from inside the process; both work by asking you to look at (or press) something.
- **The `keys.doctor` palette command** — "Keyboard doctor (which modifier chords reach mnml?)". Run it any time from `Ctrl-Shift-P`. It reopens the wizard focused on the Keyboard section rather than being a second UI over the same engine, because people switch terminals, or skipped the wizard. Unlike `first_launch.show`, firing it while the wizard is already open re-focuses that section instead of bailing — so it never looks like a no-op.

Inside the wizard: `↑↓` / `j k` move between sections, `1`–`7` jump straight to one (Keyboard is `2`), `Enter` finishes, `Esc` is "ask me later". The Keyboard section claims its probe chords *before* anything else interprets them, but only modified arrows and `End` — plain arrows still move between sections, so navigation is untouched.

### What it probes

| Probe | Chord | What it proves |
|---|---|---|
| `ctrl_right` | `Ctrl+→` | Word right (Linux/Windows native) |
| `alt_right` | `Option/Alt+→` | Word right (macOS native) |
| `cmd_right` | `Cmd+→` | End of line (macOS native) |
| `end` | `End` | Control probe — end of line (all platforms; `Fn+→` on a MacBook) |

Only one direction each. Left and right are symmetric in every layer that intercepts them, so proving `→` arrives proves `←` does too.

`End` is the **control probe**. It's excluded from the verdict — it isn't there to tell you your environment is healthy, it's there to tell you the harness works. If even `End` never ticks, keys aren't reaching mnml at all, which is a different problem from "your terminal eats modifiers".

Two matching rules worth knowing:

- **Shift is ignored.** `Shift+Alt+→` still ticks the Alt probe. The question is only "is ALT being forwarded", and Shift doesn't change that answer. Exotic flags some terminals attach (`KEYPAD`, `CAPS_LOCK`) are ignored for the same reason.
- **Combined modifiers credit nothing.** `Ctrl+Alt+→` is a distinct chord and ticks neither the Ctrl probe nor the Alt probe. Crediting it would report a modifier as working when it isn't.

### Reading the result

The line under the checklist is one of three:

```
Nothing pressed yet — try the chords above.
All chords arrive — word and line motion will work everywhere.
2 not arriving: Ctrl+→, Option/Alt+→. mnml is bound correctly; something above it is intercepting.
```

Below that, the remedy for the **first** missing chord only — one clear next step beats a wall of conditional advice. The remedy text is specific to the terminal mnml detected, and when an auto-fix exists the section grows a `Space — apply this fix` line.

Terminal detection reads what the environment advertises: `TERM_PROGRAM` (ghostty / iTerm.app / apple_terminal / wezterm), then `KITTY_WINDOW_ID` and `WT_SESSION`, then `TERM` (kitty / alacritty), falling back to unknown. Note this is the *outermost* thing visible from inside the process — under tmux or ssh those variables describe whatever is nearest, so a remedy may name the wrong terminal in a nested session. The generic advice still applies.

## The ghostty auto-fix

Ghostty on macOS is the one case mnml fixes for you, because its config path and grammar are both unambiguous. With `Option/Alt+→` unticked and ghostty detected, `Space` writes `macos-option-as-alt = true` to your ghostty config.

The write is a targeted text edit, not a parse-and-reserialize. Ghostty's config is line-oriented `key = value`, not TOML — round-tripping it would reformat the file and drop your comments. Specifically:

- **The original is backed up first**, beside the file as `config.pre-mnml-<timestamp>`.
- **An existing `macos-option-as-alt = false` is flipped in place** rather than appending a duplicate, so you never end up with two conflicting assignments.
- **A commented-out `# macos-option-as-alt = ...` is not an assignment.** It's left exactly as you wrote it, and the real setting is appended.
- **Already `true`?** Nothing is written. The chord is failing for some other reason — or ghostty simply needs restarting.
- **The file and its parent directory are created** if they don't exist.
- **Everything else in the file survives untouched** — `font-family`, `font-codepoint-map`, your keybinds, your comments.

An appended setting comes with a breadcrumb, because a line appearing in your terminal config with no explanation is its own small mystery:

```
# Added by mnml (keys.doctor): send Option as Alt so
# Option+←/→ reaches the app as a word-motion chord.
# Without this, Option composes special characters instead.
macos-option-as-alt = true
```

The result line says what actually happened — "Added…", "Flipped…", or "…already has macos-option-as-alt = true" — rather than a generic "done", so "already set" doesn't read as "fixed". **Restart ghostty afterwards**; the setting is read at startup.

Config path resolution follows ghostty's own: `$XDG_CONFIG_HOME/ghostty/config` when that variable is set and non-empty, otherwise `~/.config/ghostty/config` (on macOS *and* Linux — ghostty does not put its config file in `~/Library/Application Support`).

Every other terminal gets instructions instead. That asymmetry is deliberate: guessing at seven more config grammars is how this becomes a pile of fragile writers, and mnml should not write into a file whose format it doesn't understand.

## Fixes, per layer

### macOS Mission Control eats `Ctrl+←/→`

macOS binds `Ctrl+←/→` to Mission Control's "move left/right a space" whenever you have more than one Space — which is the default state on most machines. The key never reaches the terminal, let alone mnml.

Free it in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, or just use `Option+←/→` instead. Both are bound to the same motion; you only need one of them to arrive.

If `Ctrl+←/→` is missing on Linux or Windows, that's unusual — it's normally forwarded. Check your terminal or window manager for a conflicting global shortcut.

### Ghostty — `macos-option-as-alt`

Ghostty defaults to using Option for special characters (`Option+e` → `é`) rather than sending Alt. One line forwards it, unlocking `Option+←/→` and every other Alt chord:

```
# ~/.config/ghostty/config
macos-option-as-alt = true
```

Press `Space` in the Keyboard section to have mnml write it, or add it yourself. Restart ghostty either way.

### iTerm2 — Left Option = "Esc+"

iTerm2 defaults the Left Option key to "Normal", which composes characters rather than sending Alt. Set **Settings → Profiles → Keys → Left Option key = "Esc+"**.

### Terminal.app — Use Option as Meta key

**Settings → Profiles → Keyboard → tick "Use Option as Meta key"**.

### Other terminals

On macOS generally, most terminals use Option to compose special characters rather than sending Alt — look for an "Option as Meta/Alt" setting in the preferences. Kitty and WezTerm forward Alt by default.

Off macOS, if `Alt+←/→` isn't arriving, check your terminal's key-encoding settings, or use `Ctrl+←/→` instead.

### `Cmd+←/→` — optional everywhere

Most terminals reserve Cmd for their own shortcuts and never forward it. Kitty and WezTerm (and ghostty with an explicit keybind) do, via the Kitty keyboard protocol, in which case crossterm reports it as `SUPER` and the `Cmd+arrow` arms fire. Where it doesn't arrive those arms are simply dead and `Home`/`End` cover line motion — on a MacBook that's `Fn+←/→`.

This is the one probe worth leaving unticked. Nothing in mnml is unreachable without it.

## Rebinding

The chords above are hardcoded defaults, not a fixed contract. `[keys.standard]` (and `[keys.global]`, which standard-specific entries override) is consulted **before** the built-in logic, so you can remap or unbind any of them without touching source:

```toml
# ~/.config/mnml/config.toml
[keys.standard]
"alt+b" = "move_word_left"      # readline muscle memory
"alt+f" = "move_word_right"
"ctrl+left" = "unbound"         # stop Ctrl+← doing anything
"cmd+right" = "move_line_end"   # skip smart-home on Cmd+←'s twin
```

Modifier prefixes parse as `ctrl+` / `c-`, `alt+` / `a-` / `meta+`, `shift+` / `s-`, and `super+` / `cmd+` / `win+`. Key names include `left`, `right`, `home`, `end`, `pageup`, `pagedown`. The motion action names are `move_word_left`, `move_word_right`, `move_line_start`, `move_line_end`, `move_buffer_start`, `move_buffer_end`, `move_left`, `move_right`, `move_up`, `move_down`, `delete_word_left`, `delete_word_right`, plus `unbound` (or `none`) to disable a chord entirely.

Plain typed characters with no modifiers bypass the override table, so a stray `"a" = "cut_selection"` can't turn the a-key into a cut. A `cmd+…` spec parses on every platform; where the terminal doesn't forward SUPER it sits inert rather than spewing a startup warning.

## Next

- [Editing](/manual/editing/) — the two input modes, and everything both share
- [First-launch wizard](/manual/first-launch/) — the other environment checks that ship in the same overlay
- [Cheatsheet — VS Code chord map](/manual/cheatsheet-vscode/) — the full standard-mode key surface
- [Platform support](/manual/platform-support/) — what mnml expects from each OS and terminal
- [Settings & configuration](/manual/settings/) — the full `[keys.*]` schema and everything else in `config.toml`
