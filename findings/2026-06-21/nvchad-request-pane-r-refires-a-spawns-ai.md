---
finding: nvchad-request-pane-r-refires-a-spawns-ai
severity: SEV-2
agent: nvchad-power-user
repro: headless-ipc
---

# Request pane Response-view single-letter chords fire side-effects vim users never asked for

`src/tui.rs:5440-5455` — the Request pane's Response view binds
several letters to one-shot actions that collide with vim
muscle memory:

| chord | mnml action                              | vim canon            |
|-------|------------------------------------------|----------------------|
| `r`   | `app.send_request_from_active()`         | replace single char  |
| `a`   | `app.ai_debug_request()` (opens AI pane) | append after cursor  |
| `e`   | `rp.toggle_view()`                       | end-of-word motion   |
| `y`   | `app.copy_active_curl()`                 | yank (close enough!) |
| `Y`   | `app.copy_active_response_body()`        | yank-to-EOL          |
| `g`   | scroll to top                            | gg / g-prefix start  |
| `G`   | scroll to bottom                         | last line            |

`r` and `a` are the bad ones. They have observable side-effects
the user can't undo.

## Reproduction

```jsonc
{"cmd":"open","path":"api.curl"}                 // GET httpbin.org/get
{"cmd":"run-command","id":"http.send"}
{"cmd":"wait_ms","ms":1500}
{"cmd":"key","key":"r"}                          // expected: noop in
                                                 // response view ("r"
                                                 // is replace-char
                                                 // only in editor)
{"cmd":"wait_ms","ms":1200}
{"cmd":"snapshot"}
```

**Expected** (vim user reflex): `r` in a non-editor surface is
inert; `a` is inert; the user can scan/navigate without firing
HTTP traffic.

**Actual**:
- `r` re-fires the active request. `last: 200 (134 ms)` increments.
  If the .curl is a `POST` / `DELETE` / `PUT` against a real
  service, `r` is a destructive op the user fired by accident.
- `a` opens an `AI: debug request …` pane (`status.json` shows a
  new pane added with title `"AI: debug request …"`). This costs
  real tokens against the user's Anthropic key.
- `e` toggles to Edit view — visible, recoverable, just surprising.

## Source pointer

`src/tui.rs:5448-5452`:

```rust
KeyCode::Char('r') => app.send_request_from_active(),
KeyCode::Char('y') => app.copy_active_curl(),
KeyCode::Char('Y') => app.copy_active_response_body(),
KeyCode::Char('e') => rp.toggle_view(),
KeyCode::Char('.') | KeyCode::Char('a') => app.ai_debug_request(),
```

## Notes

The fix is to either gate these chords behind `<leader>` /
register-prefix (`<leader>r` for re-fire, `<leader>a` for AI),
or require a modifier (`Ctrl+R` for re-fire — VS Code-ish, also
better signals destructive intent). The current shape means a vim
user staring at a JSON response and typing `a` to start editing
above their selection just billed Anthropic.

`y`/`Y` are the only ones that read as "vim-ish" — copy is close
enough to yank that muscle memory survives.

Bigger picture: the Response-view dispatcher should *not* unconditionally
`return true;` at line 5456 — it should fall through for unhandled
chords so the global vim handler (and `Ctrl+W`, `:`, etc.) can pick
them up. Same shape as the Ctrl+W finding.
