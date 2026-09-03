#!/usr/bin/env bash
# Transcript printed by sdk-install-flow.tape.
#
# This is a MOCK. It prints what the Integration SDK install flow looks
# like; it installs nothing. The tape used to fake this by typing
# prompt-prefixed lines at a live bash prompt, which bash then tried to
# execute — the published GIF was full of `bash: $: command not found`.
#
# Keeping the transcript here (rather than inside VHS `Type` strings)
# means it is readable, diffable, and free of VHS's own quoting rules.
#
# NOTE: nothing verifies these lines against the real binaries. If the
# SDK's output changes, this file will not notice — update it by hand.
set -u

# Clear the invoking command line off the screen before the tape's
# camera opens — VHS's Hide/Show gates frame CAPTURE, not what the
# terminal already has on it, so the `bash …` line survives otherwise.
clear

p() { printf '%s\n' "$1"; }

p '# 1. Install a sibling binary from GitHub'
sleep 0.5
p '$ cargo install --git https://github.com/chris-mclennan/mnml-forge-github mnml-forge-github'
sleep 0.9
p '    ...cargo output snipped...'
sleep 0.5
p '    Installed package mnml-forge-github'
sleep 1.5

p ''
p '# 2. Register with mnml — writes ~/.config/mnml/integrations/github.toml'
sleep 0.5
p '$ mnml-forge-github --install'
sleep 0.6
p 'wrote manifest: /Users/you/.config/mnml/integrations/github.toml'
sleep 0.4
p 'run mnml + integrations.refresh (or restart) to pick up the rail chip'
sleep 1.8

p ''
p '# 3. What did --install write?'
sleep 0.4
p '$ cat ~/.config/mnml/integrations/github.toml'
sleep 0.5
p "id = 'github'"
p "name = 'GitHub'"
p "binary = 'mnml-forge-github'"
p "category = 'forge'"
sleep 0.4
p ''
p '[chip]'
p "glyph = '\\uf09b'   # nerd-font GitHub mark"
p "color = 'fg'"
p "tooltip = 'GitHub Actions + PRs'"
p 'enabled = true'
sleep 0.4
p ''
p '[[commands]]'
p "id = 'github.open'"
p "title = 'GitHub: open'"
p "keys = ['<leader>iG']"
p "run = ':term mnml-forge-github'"
sleep 2.2

p ''
p '# 4. In mnml:'
sleep 0.3
p '#      :integrations.refresh   →   rail chip appears'
sleep 0.4
p '#      <leader>iG              →   fires the sibling'
sleep 0.4
p '#      also runnable from the palette as github.open'
sleep 0.5
