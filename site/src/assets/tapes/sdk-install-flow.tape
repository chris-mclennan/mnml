# sdk-install-flow — the end-to-end Integration SDK story.
#
# Records the flow a user follows to add a sibling to mnml after
# mnml 0.2:
#
#   1. cargo install a sibling (mnml-forge-github here)
#   2. run `<sibling> --install` — writes the manifest
#   3. mnml re-scans on `integrations.refresh` (or restart)
#   4. rail chip + palette command + <leader>iG chord appear
#
# Renders to: sdk-install-flow.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     vhs site/src/assets/tapes/sdk-install-flow.tape

Output site/src/assets/tapes/sdk-install-flow.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1200
Set Height      680
Set Padding     20
Set TypingSpeed 45ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ────────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Type "clear"
Enter
Sleep 300ms
Show

# ── 1. install the sibling binary ────────────────────────────────────────
Type "# 1. Install a sibling binary from GitHub"
Enter
Sleep 400ms
Type "$ cargo install --git https://github.com/chris-mclennan/mnml-forge-github mnml-forge-github"
Enter
Sleep 800ms
Type "#   ...cargo output snipped..."
Enter
Sleep 400ms
Type "#   Installed package mnml-forge-github"
Enter
Sleep 1.4s

# ── 2. --install writes the manifest ────────────────────────────────────
Type "# 2. Register with mnml — writes ~/.config/mnml/integrations/github.toml"
Enter
Sleep 400ms
Type "$ mnml-forge-github --install"
Enter
Sleep 500ms
Type "wrote manifest: /Users/you/.config/mnml/integrations/github.toml"
Enter
Sleep 300ms
Type "run mnml + integrations.refresh (or restart) to pick up the rail chip"
Enter
Sleep 1.8s

# ── 3. show the on-disk manifest ─────────────────────────────────────────
Type "# 3. What did --install write?"
Enter
Sleep 300ms
Type "$ cat ~/.config/mnml/integrations/github.toml"
Enter
Sleep 400ms
Type "id = 'github'"
Enter
Type "name = 'GitHub'"
Enter
Type "binary = 'mnml-forge-github'"
Enter
Type "category = 'forge'"
Enter
Type ""
Enter
Type "[chip]"
Enter
Type "glyph = '4'"
Enter
Type "color = 'fg'"
Enter
Type "tooltip = 'GitHub Actions + PRs'"
Enter
Type "enabled = true"
Enter
Type ""
Enter
Type "[[commands]]"
Enter
Type "id = 'github.open'"
Enter
Type "title = 'GitHub: open'"
Enter
Type "keys = ['<leader>iG']"
Enter
Type "run = ':term mnml-forge-github'"
Enter
Sleep 2.2s

# ── 4. mnml would pick this up on next `integrations.refresh` ────────────
Type "# 4. In mnml:"
Enter
Type "#      :integrations.refresh   →   rail chip appears"
Enter
Sleep 300ms
Type "#      <leader>iG              →   fires the sibling"
Enter
Sleep 300ms
Type "#      also runnable from the palette as github.open"
Enter
Sleep 2.5s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 1.2s
