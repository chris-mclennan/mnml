# External tools

The Integrations rail launches a small catalog of terminal tools directly
into a pty pane: htop, btop, iftop, and any others added to
`src/tools.rs::EXTERNAL_TOOLS`.

## Branded icons — MnmlSymbols font

mnml ships branded logos for its integrations (AWS Amplify, Lambda, ECS,
Claude Code, Codex, etc.) at codepoints `U+F1B00 – U+F20FF`. These live
in `MnmlSymbols.ttf` — a symbols-only font that layers under whatever
programming font your terminal already uses.

### Install

```
scripts/build_mnml_symbols.sh
```

Copies `MnmlSymbols.ttf` to `~/Library/Fonts/` on macOS and flushes the
font cache. Any monospaced font you already use (JetBrainsMono NF, Fira
Code, Hack, MesloLGS, etc.) keeps rendering everything else — MnmlSymbols
only serves the specific codepoints mnml owns.

### Per-terminal config

The codepoints `U+F1B00 – U+F20FF` are outside every stock Nerd Font
range, so most terminals fall back automatically. Ghostty and a few
others need one config line pointing that range at `MnmlSymbols`:

#### Ghostty (`~/.config/ghostty/config`)
```
font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols
```
Restart Ghostty after saving.

#### kitty (`~/.config/kitty/kitty.conf`)
```
symbol_map U+F1B00-U+F20FF MnmlSymbols
```

#### wezterm (`~/.config/wezterm/wezterm.lua`)
```lua
config.font = wezterm.font_with_fallback({
  "JetBrainsMono Nerd Font",  -- or whatever your primary is
  "MnmlSymbols",
})
```

#### Alacritty (`~/.config/alacritty/alacritty.toml`)
Alacritty doesn't support per-codepoint fallback — it uses the OS's font
substitution. As long as `MnmlSymbols` is installed system-wide, Alacritty
picks it up for codepoints its primary font doesn't cover.

#### iTerm2
Preferences → Profiles → Text → Font → tick "Use a different font for
non-ASCII text" → set to `MnmlSymbols`. Or leave off; iTerm2's OS
fallback usually finds it.

#### Terminal.app (macOS)
Uses OS font fallback — installing `MnmlSymbols` is sufficient.

## Tools that need root

`iftop` (and future additions like `tcpdump` / `dtrace`) need packet-capture
privileges. mnml launches them under `sudo`, so you'll see a password prompt
each time the pty pane starts:

```
Password:
```

## Passwordless

If you use iftop often and don't want to type your password on each launch,
add a narrow sudoers.d rule that permits **only** that one binary without a
password.

macOS (Apple Silicon Homebrew):

```
echo "$USER ALL=(root) NOPASSWD: /opt/homebrew/sbin/iftop" | \
  sudo tee /etc/sudoers.d/mnml-iftop >/dev/null && \
  sudo chmod 440 /etc/sudoers.d/mnml-iftop
```

macOS (Intel Homebrew) — replace the path with `/usr/local/sbin/iftop`.

Linux — usually `/usr/sbin/iftop`. Verify with `which iftop`.

**One password prompt now, none afterwards.** The rule is scoped to that
exact binary, so every other `sudo` command still asks for your password.
Homebrew upgrades leave the symlink alone, so the rule survives
`brew upgrade iftop`.

To undo:

```
sudo rm /etc/sudoers.d/mnml-iftop
```

## Why not a wizard inside mnml?

Because mnml editing `/etc/sudoers.d/` sets a bad precedent — sudoers is a
security control, not something a text editor should be modifying on your
behalf. If you want the rule, run the one-liner above yourself.

## Alternative: BPF group (macOS)

iftop only needs `/dev/bpf*` access, not full root. If you have Wireshark
installed you already have its `ChmodBPF` LaunchDaemon; add yourself to the
`access_bpf` group and iftop skips sudo entirely:

```
sudo dseditgroup -o edit -a "$USER" -t user access_bpf
```

Log out + back in for group membership to take effect. Then update the
launcher in `src/tools.rs` to drop `needs_sudo: true` (or configure it per
your setup).
