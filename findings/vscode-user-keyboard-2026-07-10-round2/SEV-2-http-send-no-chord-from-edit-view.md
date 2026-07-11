# SEV-2 — HTTP request pane: no chord to send from Edit view

## What I did

Opened `api.http` (single GET). The pane opens in Edit view with URL
focused; the response strip below advertises `not sent yet · press
\`r\` to fire`.

1. Pressed lowercase `r` — inserted an `r` into the URL. (Right,
   because the URL field takes literal text; VS Code REST-client is
   the same.)
2. Pressed `Shift+R` — also inserted `R` into the URL. Nothing sent.
3. Tried `Ctrl+Enter` — nothing (no such binding).
4. Tried `Ctrl+Alt+R` (VS Code REST-client's send chord) — nothing.
5. Palette `Ctrl+Shift+P` → `http.send` — this works.

The comment at `src/tui/handlers/pane.rs:2825-2833` documents that
capital `R` was chosen as the "fire" chord, but that arm only runs
in the *Response* view (path guarded by a
`ViewMode::Response` match earlier in the function). So the workflow
is:

- Land in a fresh Request pane (Edit view, URL focused).
- Tab to Response view.
- Shift+R to fire.

That's three actions to a "send" the UI hint calls a single key.

## Why it matters

- The advertised chord in the UI is `r`; the actual chord is
  `Shift+R`; and neither works from the initial view (Edit) the pane
  opens into. Six of us reading this now can't agree on what the
  chord IS.
- VS Code REST-client users hit `Ctrl+Alt+R`. No mnml chord matches.
- The palette works — but you always have to run it, and Ctrl+P
  fuzzy-searches "http.send" doesn't rank the send command any better
  than 3 or 4 other `http.` commands.

## Suggested fix (not applied)

- Bind `http.send` to a chord that fires from any Request-pane view
  (Edit or Response). `Ctrl+Enter` is the natural pick — VS Code
  REST-client's `Ctrl+Alt+R` also fine. `<leader>hs` is already the
  vim path.
- Update `not sent yet · press \`r\` to fire` to reflect the actual
  chord (see the sibling SEV-3 finding on the "press `r` to fire"
  string).

## Severity

SEV-2 — the primary verb on the pane has no working chord from the
default landing view.
