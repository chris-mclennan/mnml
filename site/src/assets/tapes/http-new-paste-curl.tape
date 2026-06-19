# http-new-paste-curl — `:http.new` + paste-curl from clipboard
#
# The Postman-style entry point that shipped 2026-06-19. Two
# affordances, one user goal — "I just copied a curl from Chrome
# DevTools / Postman and want it firing":
#
#   :http.new          opens a blank Request pane in Edit view,
#                      Method=GET, URL empty, Body tab active.
#                      Same surface the bufferline `+` chip opens.
#   :http.paste_curl   reads the system clipboard, parses it
#                      (curl-flag syntax / .http / .rest), and
#                      populates Method / URL / Headers / Body
#                      of the active Request pane. Works whether
#                      a Request pane is open or not — it'll mint
#                      one on demand. The full-fat chord lives at
#                      Ctrl+Shift+V inside the Request pane in
#                      real interactive use.
#
# Flow recorded:
# 1. Pre-load the macOS clipboard with a curl via `pbcopy` before
#    launching mnml.
# 2. Open mnml on a tempdir with a single placeholder README so
#    focus lands in a normal editor state.
# 3. Open the README via Ctrl+P so the editor pane is focused (a
#    no-buffers tree leaves `:` unable to reach the cmdline).
# 4. `:http.paste_curl` from the editor — mints a Request pane,
#    parses the clipboard curl, populates URL / Headers, leaves
#    the pane focused in Edit/Body. Toast confirms.
# 5. Esc back to Response view, press `r` to fire — response
#    lands with 200 OK status, body pretty-printed.
#
# Note on the Ctrl+Shift+V chord: VHS's documented key syntax is
# `Ctrl+<key>` only (per `vhs new`) — Shift+Ctrl chords don't
# arrive distinct through the xterm.js layer VHS drives. The
# cmdline path `:http.paste_curl` hits the same App method
# (`http_paste_curl_to_active`) and produces the same toast +
# populated pane, so the recorded demo is faithful to the user
# observation even though the gesture differs.
#
# Why not include `:http.new` as a separate stage? Running
# `:http.new` from the editor focuses the new Request pane in
# Edit/URL mode, where every key (including `:`) types into the
# URL field — meaning the follow-up `:http.paste_curl` can't be
# fired from cmdline without first hopping focus back to the
# tree, which adds two pure-keyboard Escape gestures the recorded
# user doesn't need. `paste_curl` already opens a blank Request
# pane when none exists (see `http_paste_curl_to_active` in
# `src/app/http.rs`), so the recorded shortcut and the
# `:http.new` + Ctrl+Shift+V chord land on the same end state.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-new-paste-curl.tape

Output site/src/assets/tapes/http-new-paste-curl.gif

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
Type "echo '# new-request demo workspace' > README.md"
Enter
Sleep 200ms
# Pre-load the system clipboard with the curl the demo will paste.
# pbcopy is macOS-native; VHS for this family runs on macOS.
Type `printf "%s" "curl 'https://httpbin.org/get' -H 'Accept: application/json' -H 'X-Demo: tape'" | pbcopy`
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 400ms
Show

# ── launch mnml in the demo workspace ────────────────────────────────────
Type "$HOME/Projects/mnml/target/release/mnml . --input vim"
Sleep 400ms
Enter
Sleep 3s

# Dismiss any first-launch welcome overlay.
Escape
Sleep 800ms

# ── open the README so the editor pane is focused (without an editor
# pane focused, `:` ex-cmdline doesn't trigger). ─────────────────────────
Ctrl+P
Sleep 800ms
Type "readme"
Sleep 500ms
Enter
Sleep 1.5s

# ── Stage 1: :http.paste_curl mints a Request pane + populates it ───────
# Equivalent to: (a) clicking the `+ HTTP: new blank request` chip
# in the sidebar to run :http.new, then (b) pressing Ctrl+Shift+V
# inside the new pane. paste_curl handles both steps when there's
# no Request pane open yet — see open_new_request_pane().
Type ":http.paste_curl"
Sleep 600ms
Enter
Sleep 3s

# paste_curl auto-switches the pane to Edit view + Body tab and
# focuses the URL field. The toast confirms the parsed source.
# Linger so the populated form (GET · https://httpbin.org/get ·
# [Body] tab) is readable.
Sleep 2s

# ── Stage 2: flip to Response view (Esc) and fire (r) ───────────────────
# Esc-from-Edit toggles to Response view (post-2026-06-19 keymap);
# `r` from Response re-fires the request using the pane's current
# field values.
Escape
Sleep 800ms
Type "r"
Sleep 5s

# ── Final frame: 200 OK with the parsed Accept + X-Demo headers ────────
Sleep 2.5s
