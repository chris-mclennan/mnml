# http-vars-highlight-quickadd — undefined `{{VAR}}` tokens render in
# red; hovering shows a "not defined in active env" tooltip; right-
# clicking opens a context menu with "Set value…" that seeds a
# prompt to write the value into the active env file. On save the
# token re-tokenizes on the next draw and flips from red to cyan.
#
# Flow recorded:
#   1. Open `api.http` whose URL contains `{{DATABASE_URL}}`. The
#      token paints red because the active env (`dev.env`) doesn't
#      define `DATABASE_URL`.
#   2. Hover the token → "not defined in active env · click to open
#      env file" tooltip.
#   3. Right-click the token → context menu with:
#      • Set value…
#      • Jump to definition
#      • Copy variable name
#   4. Click "Set value…" → the EnvEditValue prompt opens, prefilled
#      with the current (empty) value.
#   5. Type `postgres://localhost/dev`, press Enter → mnml writes
#      `DATABASE_URL=postgres://localhost/dev` to `.mnml/env/dev.env`.
#   6. Next draw re-runs `EnvSet::select` → `DATABASE_URL` resolves →
#      token paints cyan.
#
# Implementation: VHS can't drive mouse, so a background driver
# (`http-vars-highlight-quickadd-workspace/drive.sh`) reads the
# `request_var:DATABASE_URL` rect (dumped in `rects.json` on every
# frame) and fires hover / right-click / menu-item-click / type /
# enter IPC commands to reproduce the interaction.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-vars-highlight-quickadd.tape

Output site/src/assets/tapes/http-vars-highlight-quickadd.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    12
Set Width       1600
Set Height      900
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ───────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Sleep 200ms
Type "mkdir -p .mnml/env .rqst && touch .mnml/.welcomed"
Enter
Sleep 100ms
# Active env defines BASE_URL but NOT DATABASE_URL. Legacy `.rqst/config`
# is what the token-tokenize path reads for the default-env pointer
# (draw-time `EnvSet::select` doesn't consult `.mnml/config.toml`
# today — 2026-07-07).
Type `printf '%s\n' 'BASE_URL=https://api.example.com' > .mnml/env/dev.env`
Enter
Sleep 100ms
Type `printf 'default_env=dev\n' > .rqst/config`
Enter
Sleep 100ms
# URL uses the undefined `{{DATABASE_URL}}` → token renders red.
Type `printf 'POST {{DATABASE_URL}}/users\n' > api.http`
Enter
Sleep 100ms
Type "git init -q && git config user.email demo@mnml.sh && git config user.name 'mnml demo'"
Enter
Sleep 100ms
# Background driver — hover / right-click / menu / type / enter.
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/http-vars-highlight-quickadd-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Sleep 100ms
Type "clear"
Enter
Sleep 300ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml ."
Sleep 400ms
Enter
Sleep 3s

Escape
Sleep 500ms

# ── beat 1: file opens, token red (~2s) ────────────────────────────────
Sleep 2s

# ── beat 2: hover → tooltip (~1.6s) ────────────────────────────────────
Sleep 1.6s

# ── beat 3: right-click → menu open (~1s) ──────────────────────────────
Sleep 1s

# ── beat 4: click "Set value…" → prompt seeds (~1s) ────────────────────
Sleep 1s

# ── beat 5: type value + Enter → token flips cyan (~2s) ───────────────
Sleep 3s

# ── settle on the final frame ─────────────────────────────────────────
Sleep 1s
