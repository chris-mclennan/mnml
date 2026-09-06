---
severity: SEV-3
status: fixed
---
# Documented, keybound commands that only toast `not implemented yet`: `search.toggle_regex`, `view.image_open`, `view.activity_integrations` (`ctrl+shift+x`)

**Command ids:** `search.toggle_regex` (`docs/commands.md:423`), `view.image_open` (`:176`), `view.activity_integrations` (`:129`, bound to `ctrl+shift+x` in both profiles). Reproduced on two fresh launches each, 2/2. (`view.activity_debug` / `ctrl+shift+d` is the same and was already noted as untouched in `vscode-tree-ctrl-shift-d-duplicates-file`.)

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"run-command","id":"search.toggle_regex"}
{"cmd":"snapshot"}
{"cmd":"run-command","id":"view.image_open"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+shift+x"}
{"cmd":"snapshot"}
```

**screen.txt** (toasts):
```
│ search.toggle_regex: not implemented yet │
│ view.image_open: not implemented yet │
│ view.activity_integrations: not implemented yet │
```
Each `command_run` event reports `ok:true`. The functionality exists by other routes: the grep inherits regex from the editor find bar's `alt+r` (`src/app/grep.zig:360`), and `{"cmd":"open","path":"vscode-scratch/pic.png"}` opens an image pane (`pic.png [PNG]`, the `no image protocol in this terminal` placeholder under `--ascii`, no crash).

**Expected**: the palette and the docs promise these; `docs/PARITY.md`'s Remaining table names only the integration-icon rail / `integrations.icon_picker` / `show_in_dev`, not these three. A VS Code user's Find-in-files regex toggle is a first-class button.
**Actual**: `notInBuild` stubs. Suggest either runners (`search.toggle_regex` = flip `GrepPane.flags.regex` + rerun; `view.image_open` = picker filtered to image extensions → `openPath`; `ctrl+shift+x` → the Integrations pane) or dropping them from `commands.md`.

**Source pointer**: `src/commands/specs.zig` (the three ids), `src/app/cmd_app.zig` `notInBuild`; `src/app/grep.zig:75,360` (`flags.regex` inherited, never toggled in-pane).

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `feat(commands): search.toggle_regex, view.image_open and view.activity_integrations run`.

- `search.toggle_regex` (`grep.zig`): flips the Search pane's regex flag
  and reruns; toasts `search regex: on|off`.
- `view.activity_integrations` (`integrations.zig`): the same runner as
  `integrations.show_installed`, so `ctrl+shift+x` opens the pane.
- `view.image_open`: `image_pane.zig` had a runner all along, but its table
  was never listed in `command.runner_tables`; it is now, and the runner is
  a picker of the workspace's image files (`image.isImagePath`) that opens
  the pick as an image pane, replacing the bare path prompt.
- `tests/e2e-zig/documented_commands.test`. `view.activity_debug` was not in
  this finding and is untouched.
