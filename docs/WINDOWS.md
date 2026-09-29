# mnml-zig on Windows

The Windows backends were written without a Windows machine in the
loop. This page says exactly what that means: what exists, what has
been proven (and how), what has not, and what to run on a Windows box
to close the gap. Target stays `x86_64-windows-gnu` (DESIGN.md E6).

## What is implemented

| Surface | POSIX | Windows | Selected by |
|---|---|---|---|
| pty session | `src/pty/session_posix.zig` — openpty / fork / execve / poll | `src/pty/session_windows.zig` — ConPTY, two anonymous pipes, `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, a reader thread into the SPSC ring, a watcher thread on the process handle | `src/pty/root.zig` (`builtin.os.tag`) |
| shell for `:term <line>` and the runners | `sh -c` | `%COMSPEC% /d /c` | `pty.shellArgv` |
| terminal session | `src/tui/term_posix.zig` — termios + `/dev/tty` | `src/tui/term_windows.zig` — console modes (VT in, VT out, no newline auto-return, quick-edit off), UTF-8 output code page, `CONIN$` when stdin is redirected | `src/tui/term.zig` |
| input worker | `src/tui/input_posix.zig` — tty read in an `Io.Group` task + SIGWINCH self-pipe | `src/tui/input_windows.zig` — `ReadConsoleInputW` on a thread; key records → bytes → the same `vaxis.Parser`; `WINDOW_BUFFER_SIZE_EVENT` → `.winsize`; native mouse records for consoles that do not translate the mouse | `src/tui/input.zig` |
| panic hook | resets modes + termios | resets modes + console modes + code page | `Term.Panic` (root `panic` in `main.zig`) |

Shared between the two: `src/tui/caps.zig` (the environment's
truecolor / quirk verdicts — `WT_SESSION` and `ConEmuANSI` count as
24-bit), `src/tui/input_common.zig` (the parse loop, the fold of
parsed events into the queue and into vaxis, key naming),
`src/pty/common.zig` (`Notify`, `Exit`), `src/pty/win_cmdline.zig`
(argv → `CreateProcessW` command line, exit code → `Exit`, the
`COMSPEC` choice).

`src/main.zig` no longer returns early on Windows: `mnml-zig [WS]`
runs the interactive loop there, `test` and `--headless` as before.

`docs/PORTABILITY.md` is the static audit beside this ledger: every
POSIX-ism outside a platform guard, and what Windows does at each.

## What has been proven

On macOS, for every commit:

- `zig build` and `zig build test` — native (the tty test skips under
  a pipe).
- `zig build gate-build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe`
  and the same with `-Doptimize=Debug` — produce `zig-out/gate/{mnml-zig,
  test-main,test-pty,test-tui,test-tree-sitter,test-highlight}.exe`,
  beside the SDK samples (`mnml-hello`, `mnml-sample`), the Jira and
  Bitbucket integrations and the fake servers (`mnml-fake-jira`,
  `mnml-fake-bitbucket`, `mnml-fake-dap`, `mnml-fake-lsp`,
  `mnml-fake-copilot`). `zig build gate-targets` runs it for all five
  shipped targets.
  Because Zig analyzes lazily, the `pty` and `tui` test binaries are
  what prove the Windows backends type-check: their `refAllDecls`
  reach every public function of `session_windows.zig`,
  `term_windows.zig` and `input_windows.zig`.

Unit tests that run on every host and cover the Windows code:

- `win_cmdline.zig`: the command-line quoting (std's own
  `argvToCommandLineWindows` vectors), `exitFromCode` (bytes are codes,
  NTSTATUS values read as `signal`), `defaultShell` (`COMSPEC`, never
  `SHELL`).
- `root.zig`: the backend selection, `shellArgv` on both platforms.
- `input_windows.zig`: the record fold — a VT sequence split one unit
  per key record comes out as one key; key-ups and lone modifiers are
  dropped; `wRepeatCount` repeats; a surrogate pair becomes one code
  point, an orphaned half is dropped; native mouse press / drag /
  release / motion / wheel; the inclusive window rectangle.
- `term_windows.zig`: the raw input and output mode words (what is
  set, what is cleared, what is kept) and the SDK bit values.
- `caps.zig`: `WT_SESSION` / `ConEmuANSI` truecolor.
- `runners.zig`: `findOnPath` with the platform delimiter and
  `PATHEXT`.
- `data_root.zig`: `USERPROFILE` as the home when `HOME` is unset.
- `sdk/mnml-sdk/src/manifest.zig`: the same rung on the SDK side, so
  `<integration> --install` finds a data root on Windows without being
  handed `MNML_DATA_ROOT`.
- `run.ps1` structure, via `tools/run-ps1-check.py` (in `run.sh check`):
  brace / quote / here-string balance, the 5.1-incompatible spellings,
  every verb reachable, and the refusals, build lines, font destination
  and dry-run phrases present by name. Structure only — it is not a run.

## What has NOT been proven — run this on a Windows box

Everything that touches the real console or a real child process.
Checklist, in order; each step assumes the previous passed.

`docs/INSTALL-CHECKLIST.md` → *Windows 11* is the wider, install-shaped
version of this: prerequisites, `run.ps1 install`, the font, the first
launch, a file, a terminal pane, the Jira pane against the offline fake,
quit-and-return — plus the UTM pristine-snapshot routine. That one is
for a clean guest; this one is for the console and ConPTY surfaces
specifically.

### Build + unit tests

```powershell
zig version            # 0.16.0
zig build
zig build test         # expect the POSIX-only tests to report SKIP, nothing to fail
```

`zig build test` on Windows skips: the POSIX session tests (the file
is not even imported there), every test that scripts a `/bin/sh` fake —
the pty panes (`pty_pane.zig`), `:term` (`cmd_term.zig`), the LSP /
DAP / jsonrpc / AI-CLI fakes and more — and the tty-under-a-pipe test.
`docs/PORTABILITY.md` → *Tests that skip on Windows* counts them per
file.

### The interactive loop (Windows Terminal)

```powershell
zig build
.\zig-out\bin\mnml-zig.exe C:\some\workspace
```

1. It starts in the alt screen with the file tree, no stray text from
   the capability probe (the OSC 66 / DECRQM queries are written
   before the screen is cleared; a terminal that echoes them as text
   would show garbage for a frame — if it does, `applyTerminalQuirks`
   in `caps.zig` is where a `WT_SESSION` correction goes).
2. Keys: letters, arrows, Home/End, PageUp/Down, F-keys, `ctrl+p`
   (palette), `ctrl+shift+p`, `alt+…`. Under `ENABLE_VIRTUAL_TERMINAL_INPUT`
   these are VT sequences; the parser is the POSIX one. Windows Terminal
   does not speak the kitty keyboard protocol, so `ctrl+shift+…` chords
   that only CSI u can distinguish will not; that is expected.
3. Mouse: click a tree row, drag a split, wheel over a list. Windows
   Terminal translates the mouse to SGR reports once mnml sets mouse
   mode. Classic conhost may deliver native records instead — the
   worker handles both, but only one path was ever going to be hit.
4. Resize the window: the layout must follow. This is the
   `WINDOW_BUFFER_SIZE_EVENT` path (`GetConsoleScreenBufferInfo`'s
   `srWindow`, not the record's own size, which is the buffer's).
5. Paste (right-click or `ctrl+shift+v` in Windows Terminal): arrives
   bracketed.
6. `:q` — the console is back to normal: cursor visible, no alt
   screen, typing echoes, `ctrl+c` interrupts again.
7. Crash on purpose — the panic trace prints on a readable console.
   No command panics on purpose today (a Lua error is caught and
   toasted, never a panic), so this step waits for a real crash or a
   debug hook.
8. Redirected stdin: `echo | .\zig-out\bin\mnml-zig.exe` — must still
   take keys (it opens `CONIN$`). Redirected stdout must refuse with
   "stdout is not a terminal".

### ConPTY

1. `:term` — a `cmd.exe` prompt in a pane below. `dir`, `cls`,
   `color 0a`, `exit`. The pane shows `[exited 0]`.
2. `:term pwsh` (or `powershell`) — the prompt renders, `Get-ChildItem`
   colours come through.
3. `:term ping -n 3 127.0.0.1` — output arrives as it is produced
   (the reader thread / ring / `.pty_readable` path), then the exit.
4. Resize the pane (drag the split, resize the window) with `pwsh`
   running — `$Host.UI.RawUI.WindowSize` follows
   (`ResizePseudoConsole`).
5. A big burst: `:term type C:\Windows\System32\drivers\etc\hosts`
   then `:term dir /s C:\Windows\System32` and close the pane
   mid-stream. Neither the UI nor the close may hang: the watcher
   thread, not the UI thread, closes the pseudoconsole after exit;
   `deinit` closes it with the reader discarding. This is the one
   design point that was reasoned about rather than observed —
   `ClosePseudoConsole` blocking until the output pipe is drained is
   documented behaviour on Windows 10 and reportedly relaxed on 11.
6. Exit codes: `:term cmd /c exit 3` → `[exited 3]`. A crashed child
   (`0xC0000005`) reads as a signal-style exit.
7. `git status` in a pane (`git.exe` resolved through `PATHEXT`) and
   `npm run build` (`npm.cmd`) — the runners.
8. The child's `TERM` is `xterm-256color`, `COLORTERM=truecolor`
   (`applyTerm` in `session_windows.zig`); `echo %TERM%`.
9. `deinit` of a still-running child (`:term ping -t 127.0.0.1`, close
   the pane): the child is `TerminateProcess`d. Grandchildren it
   started are not (no job object yet — see gaps).

### Headless + e2e

```powershell
.\zig-out\bin\mnml-zig.exe test --parse
$env:MNML_E2E_ALLOW_SHELL = "0"
.\zig-out\bin\mnml-zig.exe test
```

`shell` steps in `.test` files are `sh -c` and stay POSIX; with the
variable at `0` they are refused rather than run through `cmd`.

## Known gaps

- **`run.ps1` is the install, and it has never been run.** The four
  daily-driver verbs now have a PowerShell twin — `run.ps1 install`,
  `install-font`, `installed-status`, `profile` — with run.sh's
  semantics, refusals and dry-run plan. Only the STRUCTURE of it has
  been checked (`tools/run-ps1-check.py`, which `run.sh check` runs);
  the real check, `tools/run-ps1-check.ps1`, needs a PowerShell and has
  not executed anywhere yet. `docs/INSTALL-CHECKLIST.md` → *Windows 11*
  step W-0 is the first run of both.

  Three things it does differently from run.sh, because Windows differs:

  - The prefix defaults to `%LOCALAPPDATA%\Programs\mnml`, not
    `~/.local`.
  - `<data root>\bin\<name>.exe` is a **copy**, not a symlink: a
    symlink needs Developer Mode or elevation, and `linkBeside`
    (`src/config/seed.zig`) already falls back to copying for the same
    reason. `installed-status` therefore compares hashes where run.sh
    reads a link target.
  - `install-font` writes the per-user font directory **and** registers
    the face under HKCU (below).

  Still bash-only, and still by hand on Windows: the restart loop,
  `headless`, `shot`, `fresh`, `clean`, `menu`, and the IPC verbs
  (`restart` / `stop` / `status`). Those drive a running instance,
  which is a separate pass.

  Profiles themselves are the program and work there —
  `MNML_PROFILE=dev` / `--profile dev` moves the data root
  (`%USERPROFILE%\.config\mnml-dev`, via `data_root.zig`'s USERPROFILE
  rung), the session file, the IPC mailbox, the marker under `%TEMP%`,
  and paints the `dev` chip. `run.ps1 profile` prints all four from the
  binary itself, which is how a first Windows session confirms them.

  The SDK had the other half of that rung missing: `manifest.zig`'s
  `dataRoot` went `MNML_DATA_ROOT` → `XDG_CONFIG_HOME` → `HOME` and
  stopped, so a bare `mnml-jira.exe --install` on Windows answered
  `error.NoHome` and wrote nothing. It reads `USERPROFILE` now, the way
  `data_root.zig` always did. `run.ps1 install` passes `MNML_DATA_ROOT`
  explicitly and never depended on it; a user running the binary by
  hand did.
- **The font gap is closed by `run.ps1 install-font`.** A file is not an
  installed font on Windows, so the verb does both halves: it puts the
  merged face in `%LOCALAPPDATA%\Microsoft\Windows\Fonts` and names it
  under `HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` as
  `MnmlSymbols (TrueType)` — per-user, no elevation, the same shape
  `first_launch_install.zig` uses for the Nerd Font. It merges rather
  than overwrites (`zig build font-merge -Dfont-in=… -Dfont-out=…`, a
  build step that always ran on Windows) and backs the old face up to
  `%USERPROFILE%\Backups\mnml-zig\fonts\` first. A machine-wide
  `C:\Windows\Fonts\MnmlSymbols.ttf` is merged FROM but never written
  to — that would need elevation, and a per-user face wins for the user
  anyway.

  Without the face, mnml's own block falls back rather than rendering
  as `?` — the unfocused pty pane's cursor paints `▯` in place of
  `U+F2001` — because `font_scan` reads the installed face's cmap and
  only offers a glyph it actually carries;
  `%LOCALAPPDATA%\Microsoft\Windows\Fonts` is already in `fontDirs`,
  so the check works there.

  What is still open: Windows Terminal has **no font-fallback list**, so
  MnmlSymbols only ever fills mnml's own `U+F1B00–U+F20FF`. Nerd Font
  icons need the profile's own font face to be a full patched mono
  (`terminalHint` in `first_launch_install.zig` says so). And there is
  still no MSI step for the font — the installer drops it under the
  prefix and leaves the font directory alone, like every other package.
- **CI runs the unit suite on `windows-latest`** (`ci.yml`'s `unit`
  job: `zig build unit` in Debug with each test's name streamed, and
  `zig build test` in ReleaseSafe; its `check` job runs fmt, the
  ReleaseSafe build, the audits and the gate at three sizes) — the
  POSIX-scripted tests skip there. Nothing in CI runs the
  interactive loop or a ConPTY child; the checklist above is still the
  only way to see those. `docs/PORTABILITY.md` lists the Windows-skipped
  tests and what, if anything, runs in their place.
- **No job object.** `Session.deinit` terminates the direct child only;
  a shell's own children survive. `CreateJobObjectW` +
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is the fix.
- **`ClosePseudoConsole` on a child that never exits**: `deinit`
  terminates it first, so the close returns; but a child in an
  uninterruptible state could hold it. Untested.
- **The e2e runner's `shell` steps** (`src/e2e/runner.zig`) are
  `<shell> -c`; `mnml-zig test`'s shell is `MNML_E2E_SHELL` or
  `/bin/sh` (never `$SHELL`).
  Windows runs `.test` files fine as long as they have no `shell`
  step.
- **`~` expansion, the projects dir, the startup picker's home and
  `App.processEnv`** — closed by the portability pass
  (`docs/PORTABILITY.md`): `USERPROFILE` is a home everywhere the app
  asks for one (`src/core/os_path.zig`), `~\` expands, and
  `processEnv` reads the PEB block on Windows instead of returning an
  empty map.
- **Tool install hints** (`runners.zig` `Tool.install`) show the
  Homebrew line on Windows.
- **Bridge mounts** (`src/bridge/host.zig`, Unix domain sockets,
  `supported = Io.net.has_unix_sockets`) exist but have never bound a
  socket on Windows; Windows 10 1803+ supports `AF_UNIX`, and
  `docs/PORTABILITY.md` → *Sockets* has the rest.
- **Kitty keyboard / graphics, mode 2027, explicit width**: whatever
  the terminal answers is honoured, but vaxis on Windows never pushes
  the kitty flags (`enableDetectedFeatures` hard-sets legacy SGR
  there), so `ctrl+shift+…` chords that need CSI u stay indistinct
  under Windows Terminal.
- **Classic conhost** (not Windows Terminal): VT processing needs
  Windows 10 1809+; older consoles fail `Term.init` with
  `NoVirtualTerminal` instead of printing escapes as text.
