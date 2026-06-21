---
finding: nvchad-agents-dashboard-vim-chord-collisions
severity: SEV-2
agent: nvchad-power-user
repro: headless-ipc
---

# Claude Agents dashboard chord vocabulary stomps several vim canonical bindings

The dashboard (`src/tui.rs:1885-2066`) binds bare alphabetic keys
for what NvChad users expect to be vim motion / operator / prefix
keys. Each binding is locally sensible — but the *aggregate*
shape forces a vim user to consciously un-learn for this pane:

| chord    | mnml action                  | vim canon                    | severity within hunt |
|----------|------------------------------|------------------------------|----------------------|
| `g`      | `cycle_group_by()`           | gg-prefix → top of buffer    | hot — `gg` is no-op  |
| `G`      | (unbound)                    | last line                    | no-op (annoying)     |
| `w`      | toggle workspace-only        | next-word motion             | hot                  |
| `s`      | `cycle_sort()`               | substitute char              | mild (no editor)     |
| `c`      | `YankCwd`                    | change-operator prefix       | mild                 |
| `t`      | `OpenTranscript` (= Enter)   | find-char on line            | mild                 |
| `T`      | `ResumeSessionInTmnl`        | find-char on line, backward  | mild                 |
| `o`      | `ResumeSession`              | open-line below              | mild                 |
| `e`      | `ExportMarkdown`             | end-of-word motion           | mild                 |
| `p`      | toggle pause                 | paste-after                  | mild                 |
| `r`      | refresh                      | replace single char          | mild                 |
| `v`      | `cycle_detail()`             | start visual mode            | mild                 |
| `<spc>`  | toggle multi-select          | `<leader>` chord prefix      | hot — eats leader    |
| `0`      | clear state filter           | jump to col 0                | mild                 |
| `1..4`   | state-filter `1..4`          | count prefix                 | hot                  |
| `>` / `<`| cycle source filter          | indent / outdent             | mild                 |

## Reproduction (concrete examples)

```jsonc
// gg should jump to top — instead it's two no-op group_by cycles.
{"cmd":"run-command","id":"ai.agents_dashboard"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"j"}{"cmd":"key","key":"j"}{"cmd":"key","key":"j"}
{"cmd":"key","key":"g"}{"cmd":"key","key":"g"}
{"cmd":"snapshot"}                                // cursor still at row 4
```

**Expected** (vim user): `gg` jumps to the top row of the list.

**Actual**: cursor stays where the `jjj` left it. Each `g` cycles
`group_by` between Source ↔ Workspace; two cycles return to the
original grouping. Net effect: silent no-op.

```jsonc
// G should jump to last row — currently completely unbound.
{"cmd":"key","key":"G"}
{"cmd":"snapshot"}                                // cursor stays
```

**Expected**: jump to last visible row. Note that `KeyCode::End`
does this work (`src/tui.rs:1925`) — but no `Char('G')` alias.

```jsonc
// w should advance by word — instead toggles workspace-only.
{"cmd":"key","key":"w"}
{"cmd":"snapshot"}                                // toast says
                                                  // "showing this
                                                  // workspace only"
```

`w` reflexively starts the prefix for `dw` (delete word) / `cw`
(change word) / `yw` (yank word) — none of those make sense in
this pane, but the impulse fires the workspace filter as a hard
state mutation. The toast says nothing about how to un-toggle.

## Source pointer

`src/tui.rs:1936-2058` (the alphabetic-char arms above).
`KeyCode::Char('g')` at 1965 vs `KeyCode::Home | Char('g')` (the
diagnostics pane's smarter pattern at line 2464) — the agents
pane could/should bind `gg` as a chord (collected via local
prefix flag) and keep `g` for `cycle_group_by` only after a
timeout.

## Notes

The dashboard's help overlay (`?` / F1) does document each
chord. Discoverability is OK. But the *muscle-memory penalty*
for a vim user is heavy: every other pane in mnml has converged
on `gg`/`G` for top/bottom, this one didn't.

Two cheap improvements:

1. Add `Char('G')` aliases for End (matches the cheatsheet /
   diagnostics conventions).
2. Move the rare chords (`w` workspace, `s` sort, `c` yank-cwd,
   `g` group-by) under `<leader>` or capital-letter (`W`, `S`,
   `C`, `G` … wait, conflict with End). Or accept the cost and
   surface a "press `?` for chord help" hint in the title strip
   the way the Cheatsheet pane does.
