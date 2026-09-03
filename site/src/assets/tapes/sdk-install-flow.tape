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
# ── Why this is a scripted mock, and why that is written down ───────────
#
# This tape does NOT run a real install. It cannot: `cargo install --git`
# needs the network and a published repo, and takes minutes.
#
# The PREVIOUS version pretended otherwise — it used `Type "$ cargo
# install …"` followed by `Enter`, which types that text at a live bash
# prompt and executes it. bash then answered `bash: $: command not
# found` on nearly every line, and the same for `[[commands]]` and each
# `id = '…'` line of the "manifest". The published GIF was a screenful
# of shell errors.
#
# So the transcript is now printed by a prepared script instead. Same
# visuals, nothing executed, deterministic every render. If you change
# what the demo claims mnml does, change it here — this file is the only
# thing asserting it, and nothing verifies it against the real binary.
#
# Renders to: sdk-install-flow.gif
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     vhs site/src/assets/tapes/sdk-install-flow.tape

Output site/src/assets/tapes/sdk-install-flow.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font, MnmlSymbols"
Set FontSize    13
Set Width       1200
Set Height      680
Set Padding     20
Set TypingSpeed 45ms
Set Theme       "Catppuccin Mocha"

# ── setup ───────────────────────────────────────────────────────────────
# The transcript lives in sdk-install-flow.sh next to this file, so it
# stays readable and diffable instead of being escaped through VHS's
# `Type` strings (which its lexer will not accept anyway).
# Render from the REPO ROOT — `Output` above is root-relative, so
# running vhs from this directory writes a nested site/src/... path.
Hide
Type "clear"
Enter
Sleep 300ms

# Run it off-camera too — only its OUTPUT belongs on screen, not the
# `bash …` line, which would give the mock away and add nothing.
Type "bash site/src/assets/tapes/sdk-install-flow.sh"
Enter
# Let the script's own `clear` wipe the command line before capturing.
Sleep 400ms
Show

# The script paces itself; this just holds the camera open for it.
Sleep 14s

# ── settle on a final frame ──────────────────────────────────────────────
Sleep 1.5s
