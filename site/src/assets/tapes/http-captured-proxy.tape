# http-captured-proxy — `mnml proxy` + `:http.view_captured`
#
# 1. Launch mnml in a fresh tempdir workspace.
# 2. Open a shell pane (`:term.shell`).
# 3. Run `mnml proxy --url https://news.ycombinator.com --seconds 5` in
#    the shell. The proxy spawns headless Chrome, drives it to HN, and
#    streams per-request log lines as `Network.requestWillBeSent` fires.
# 4. Once `ok — N requests captured` lands, focus back to the editor
#    and `:http.view_captured` opens the picker over the resulting
#    `.rqst/captured/log.jsonl`.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-captured-proxy.tape

Output site/src/assets/tapes/http-captured-proxy.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font mnml"
Set FontSize    13
Set Width       1280
Set Height      760
Set Padding     20
Set TypingSpeed 50ms
Set Theme       "Catppuccin Mocha"

# ── setup (hidden) ───────────────────────────────────────────────────────
Hide
Type "MNML_DEMO=$(mktemp -d) && cd $MNML_DEMO"
Enter
Sleep 200ms
# Seed a README so an editor pane gets focused (no-buffers state
# leaves focus on the tree, which doesn't accept `:`-prefixed
# ex-commands — the picker would never open).
Type "echo '# proxy demo workspace' > README.md"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 400ms
Show

# ── launch mnml ──────────────────────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml . --input vim"
Sleep 400ms
Enter
Sleep 3s

Escape
Sleep 600ms

# ── open the README so the editor pane gets focus (without an editor
# pane focused, `:` ex-cmdline doesn't trigger). ─────────────────────────
Ctrl+P
Sleep 800ms
Type "readme"
Sleep 500ms
Enter
Sleep 1.2s

# ── open the scratch terminal (Esc releases focus, cleaner than
# `:term.shell` which is a regular pane and can't be Esc'd out of). ──
Type ":term.scratch_toggle"
Sleep 500ms
Enter
Sleep 1.5s

# ── run mnml proxy against HN ───────────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml proxy --url https://news.ycombinator.com --seconds 5 --idle-ms 2000"
Sleep 500ms
Enter

# Wait for headless Chrome to spawn, attach, fire requests, and exit.
# Typical timing: ~1-2s spawn, then per-request lines stream in, then
# the --seconds cap triggers shutdown with `ok — N requests captured`.
Sleep 9s

# ── release focus from the scratch term, then open the captured picker ─
Escape
Sleep 600ms

Type ":http.view_captured"
Sleep 500ms
Enter
Sleep 2s

# ── browse a couple of rows ─────────────────────────────────────────────
Down
Sleep 400ms
Down
Sleep 400ms
Down
Sleep 800ms

# ── settle ──────────────────────────────────────────────────────────────
Sleep 2.5s
