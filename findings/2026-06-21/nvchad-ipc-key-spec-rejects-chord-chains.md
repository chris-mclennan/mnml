---
finding: nvchad-ipc-key-spec-rejects-chord-chains
severity: SEV-3
agent: nvchad-power-user
repro: headless-ipc
---

# `parse_key_spec` rejects whitespace-separated chord chains — IPC `key` command cannot fire vim chord sequences in a single event

`src/input/keymap.rs:327-340` (`parse_key_spec`) handles a single
chord; the module docstring at line 6-8 advertises whitespace-
separated chord chains, but only `parse_chord_chain` (line 312)
implements them. The IPC `Key` apply path (`src/ipc/mod.rs:443`)
calls `parse_key_spec` — single chord only.

Result: a script that wants to fire `Ctrl+W h` as one IPC event
gets:

```jsonl
{"event":"key_unparsed","key":"ctrl+w h"}
```

…and the keystroke is dropped. Scripts have to manually split
into two `key` events.

## Reproduction

```jsonc
{"cmd":"key","key":"ctrl+w h"}
{"cmd":"snapshot"}
```

`events.jsonl` line:

```jsonl
{"event":"key_unparsed","key":"ctrl+w h"}
```

The companion working form:

```jsonc
{"cmd":"key","key":"ctrl+w"}
{"cmd":"key","key":"h"}
```

…dispatches correctly and Ctrl+W h fires.

## Source pointer

- `src/input/keymap.rs:327` — `parse_key_spec` is single-chord
  only despite the module-level docstring promising chains.
- `src/input/keymap.rs:312` — the real `parse_chord_chain`
  function exists but is not the function the IPC uses.
- `src/ipc/mod.rs:444` — `if let Some(ev) = parse_key_spec(spec)`
  — this is where the chain gets turned into a no-op.

## Notes

This is a test-tooling bug, not a user-facing one — a real
keyboard never sends two chords in one event. But the prior
nvchad / vscode bug-hunt scripts in `findings/` use chord-chain
strings (`"ctrl+w h"`, `"ctrl+k ctrl+i"`) that the docstring
says are accepted. Either:

1. Have IPC `Key` call `parse_chord_chain` and synthesize each
   chord as a separate `dispatch_key`, OR
2. Update the docstring to make the single-chord limit explicit
   so future hunt scripts don't burn a snapshot pretending they
   fired Ctrl+W h.

Either fix makes the IPC's promise match its behavior. The
quickest path for hunt scripts is option 1 (auto-split) — same
mechanism Lua-as-config would use for `{"<C-w>h"}` chord
declarations.
