# http-auth-tab — Postman-style Request pane (Auth tab live in the strip)
#
# The Request pane has a 6-tab strip — Body / Headers / Params /
# Auth / Vars / Source — modelled on Postman's auth setup surface.
# Auth is the new tab that ships the credentials picker: a summary
# header up top + six clickable action rows underneath
# (`+ Set Bearer token…`, `+ Set Basic auth…`, `+ Set X-Api-Key…`,
# `↻ Apply saved preset…`, `💾 Save current as preset…`,
# `✗ Clear Authorization`).
#
# Each row dispatches through `App::http_auth_row_clicked` (see
# `src/app/http.rs` ~L218) — on click it opens the matching prompt
# and the accept path writes the `Authorization` header onto the
# active Request via `http_auth_set`. Apply-preset / save-preset
# round-trip through `.mnml/auth/*.txt`.
#
# Flow recorded (vim input mode — `:` ex-cmdline is the driver):
# 1. Pre-load the clipboard with a curl that already carries a
#    `Authorization: Bearer …` header (so once we paste, the
#    Auth surface has live state to summarise).
# 2. Launch mnml on a tempdir; Ctrl+P opens the seed README so an
#    editor pane has focus (without one, `:` can't reach cmdline).
# 3. `:http.paste_curl` mints a Request pane + parses the curl into
#    Method / URL / Headers / Body. Pane lands in Edit/Body view.
# 4. Tab strip becomes visible: `[Body] Headers Params Auth Vars
#    Source`. The Authorization header lives in the Headers buffer
#    (you can see it surfaced in the Response section's request-line
#    preview at the bottom of the pane).
# 5. `Ctrl+]` cycles the active tab forward; the Auth chip lights
#    up as the user clicks through. (In VHS 0.11 the chord-chain
#    interprets Ctrl+] aggressively under vim mode so the exact
#    landing tab varies — what's faithful is the *surface*:
#    the 6-tab Postman strip with Auth present and the populated
#    request data driving each tab's content.)
# 6. The Auth-tab summary, when active, reads
#    "Current:  Bearer · eyJhbGciOiJIUzI1NiJ9…" — derived from the
#    parsed Authorization header. Action rows render underneath.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-auth-tab.tape

Output site/src/assets/tapes/http-auth-tab.gif

Set Shell       "bash"
Set FontFamily  "JetBrainsMono Nerd Font, MnmlSymbols"
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
Type "echo '# auth-tab demo workspace' > README.md"
Enter
Sleep 200ms
Type "mkdir -p .mnml && touch .mnml/.welcomed"
Enter
Sleep 200ms
# Seed the clipboard with a curl carrying a Bearer token — the Auth
# tab summarises whatever's in the Authorization header.
Type `printf "%s" "curl 'https://api.example.com/v1/me' -H 'Accept: application/json' -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.demo-payload.sig'" | pbcopy`
Enter
Sleep 200ms
# Background driver — opens README, fires http.paste_curl, then walks
# the tab strip and lands on Auth via Ctrl+4 (VHS can't type that).
Type "(bash $HOME/Projects/mnml/site/src/assets/tapes/http-auth-tab-workspace/drive.sh $MNML_DEMO &) 2>/dev/null"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 400ms
Show

# ── launch mnml in vim input mode (cmdline `:` is the driver) ──────────
Type "$HOME/Projects/mnml/target/release/mnml . --input vim"
Sleep 400ms
Enter
Sleep 3s

Escape
Sleep 600ms

# ── all beats fire from the IPC driver ──────────────────────────────────
# 1. open README.md          → an editor pane behind the Request pane
# 2. http.paste_curl         → Request pane, Edit view, populated from the
#                              clipboard curl (URL + Accept + Authorization)
# 3. ctrl+]                  → one visible step along the tab strip
#                              (Params Body Headers Auth Vars Script)
# 4. ctrl+4                  → lands ON Auth: the credentials picker with
#                              its summary header + `+ Set Bearer token…`
#                              / `+ Set Basic auth…` / `↻ Apply saved
#                              preset…` action rows, reading against the
#                              Authorization header parsed out of the curl
Sleep 14s

# ── settle on the Auth tab ──────────────────────────────────────────────
Sleep 3s
