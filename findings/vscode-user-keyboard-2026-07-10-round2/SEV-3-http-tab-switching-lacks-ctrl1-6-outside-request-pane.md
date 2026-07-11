# SEV-3 — HTTP palette commands (http.*) mostly have no chord

## What I did

Grepped `src/command.rs` for every `id: "http.` block and counted
`keys: &[]`. Every one had empty keys. The Request-pane's tab strip
is instead bound to Ctrl+]/Ctrl+[ and Ctrl+1..6 *when a Request
pane is the active pane* (`src/tui/mod.rs:1879-1937`) — which is
the right place for those. But outside that pane:

- `http.send` — palette only.
- `http.toggle_edit_split` — palette only.
- `http.next_block` / `http.prev_block` — palette only.
- `http.pick_env` / `http.edit_env` / `http.new_env` / `http.reset_env` — palette only.
- `http.run_chain` — palette only.
- `http.save` / `http.save_mock` / `http.replay_mock` — palette only.
- `http.paste_curl` — palette only.

## Why it matters

The Request pane surface is one of mnml's headline features. A VS Code
keyboard-purist would expect at least the send verb on a chord. The
existing chord list has room: `Ctrl+Alt+R`, `Ctrl+Alt+Enter`, etc.

The palette works — you can fuzzy-search "http.send" — but at 40+
`http.` commands the palette is a noisy landing.

## Suggested fix (not applied)

Give at least the top-3 http verbs a chord: `http.send`,
`http.pick_env`, `http.toggle_edit_split`. Consider a `<leader>h`
whichkey submenu (there IS one at `src/whichkey.rs:165` with `s ->
http.send`, but that's vim-mode only in practice).

## Severity

SEV-3 — every command is reachable via palette; the friction is
that a headline feature has no keyboard "shortcut" beyond the type-
n-search flow.
