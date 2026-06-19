# http-lookup-flow — 4-stage `:http.lookup` walkthrough
#
# 1. Launch mnml in a tempdir pre-seeded with .rqst/lookups/users.curl
#    pointed at jsonplaceholder.typicode.com/users (returns a bare JSON
#    array with `id` + `name` fields — exactly the shape lookup picks).
# 2. `:http.lookup` opens the file picker.
# 3. Enter on users.curl → background fire (toast: "firing request…").
# 4. The item picker opens with the list of users (id + name).
# 5. Pick "Leanne Graham" → var-name prompt pre-fills `USER_ID`.
# 6. Enter → toast confirms `wrote USER_ID=1 → .rqst/env/dev.env`.
#
# Regenerate with VHS (https://github.com/charmbracelet/vhs):
#     cargo build --release
#     vhs site/src/assets/tapes/http-lookup-flow.tape

Output site/src/assets/tapes/http-lookup-flow.gif

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
Type "mkdir -p .rqst/lookups .rqst/env"
Enter
Sleep 200ms
Type `echo "curl '{{BASE_URL}}/users' -H 'Accept: application/json'" > .rqst/lookups/users.curl`
Enter
Sleep 200ms
Type "echo 'BASE_URL=https://jsonplaceholder.typicode.com' > .rqst/env/dev.env"
Enter
Sleep 200ms
Type "echo 'default_env=dev' > .rqst/config"
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

# ── Stage 1: pick a lookup file ──────────────────────────────────────────
Type ":http.lookup"
Sleep 600ms
Enter
Sleep 1.5s

# Picker shows .rqst/lookups/users.curl already selected.
Sleep 1.2s
Enter
Sleep 800ms

# ── Stage 2: background fire ────────────────────────────────────────────
# Toast: "lookup: firing request…" — wait for the response to land
# (jsonplaceholder is usually <500ms but give it room).
Sleep 3s

# ── Stage 3: item picker (one row per user) ─────────────────────────────
Sleep 1.5s

# First row is "Leanne Graham (id: 1)" — commit it.
Enter
Sleep 800ms

# ── Stage 4: var-name prompt — type USER_ID ─────────────────────────────
Sleep 1.5s
Type "USER_ID"
Sleep 600ms
Enter
Sleep 2s

# ── Final frame: toast confirms `wrote USER_ID=1 → …/dev.env` ──────────
Sleep 2s
