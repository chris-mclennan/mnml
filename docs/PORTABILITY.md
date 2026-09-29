# Portability audit — macOS, Linux, Windows

mnml ships for five targets: `aarch64-macos`, `x86_64-macos`,
`x86_64-linux-gnu`, `aarch64-linux-gnu` and `x86_64-windows-gnu`. Zig
analyses code lazily, so a `builtin.os.tag == .windows` branch, a
Linux-only libc dependency or a Windows-skipped test that no longer
compiles is invisible until that target is built — and a cross-build
proves only that it compiles, never that it runs. This page is the
static half of closing that: every POSIX-ism in `src/`, `integrations/`
and `sdk/` outside a platform guard, and what Windows does at each.

`docs/WINDOWS.md` is the other half — what has been run where, and the
checklist for a real Windows box. For Linux the other half is
`docs/PORTABILITY-linux.md`: the whole verification sequence *run* in a
Linux container (`tools/linux-verify.sh`), what failed there and what
still does.

## The gate

`zig build gate-targets` runs `zig build gate-build -Dtarget=<t>
-Doptimize=ReleaseSafe` for each of the five shipped targets, one after
another, each under its own prefix (`zig-out/gate-targets/<t>/gate/`):
the exe, every unit-test binary, the SDK samples (`mnml-hello`,
`mnml-sample`), the Jira / Bitbucket integrations and their fake
servers, and the fake DAP, LSP and Copilot servers. `./run.sh check` runs it; CI's `cross` job is the same
five targets as a matrix. A branch is not green until all five are.

What the audit found at `c886d11d` (before this pass):

| target | `gate-build` | why |
|---|---|---|
| `x86_64-windows-gnu` | **failed** | four test-only compile errors: a pid parsed as `i32` handed to `child_os.gone` (a HANDLE there), `SIG.KILL` (Windows's `SIG` has none), `Permissions.fromMode` (attributes on Windows) |
| `x86_64-linux-gnu` | **failed** | `mnml-jira`, `mnml-bitbucket`, `mnml-fake-bitbucket`: `std.c.getpid` / `std.c.kill` with no libc linked — macOS always links libc, Linux does not |
| `aarch64-linux-gnu` | **failed** | the same three |
| `x86_64-macos` | ok | |
| `aarch64-macos` | ok | |

After this pass all five exit 0 under `zig build gate-targets`, as do
`zig build jira-integration bitbucket-integration -Dtarget=<t>` and the
stand-alone `integrations/jira` and `integrations/bitbucket` builds for
each target.

## How to read the table

- **guarded** — the site already has a platform arm (or lives in a file
  only one platform compiles) and the Windows arm does the right thing.
- **fixed** — this pass gave it a Windows / Linux answer.
- **documented** — POSIX-only on purpose or for now; the Windows row
  says what happens there and what closing it needs.

The pure rules the fixes share live in `src/core/os_path.zig` —
`home` (`HOME`, else `USERPROFILE`), `tempDir` (`TMPDIR`, `TEMP`,
`TMP`), `expandTilde` (`~\` too), `splitLocation` (a drive letter is
part of the path), `Candidates` / `which` (`;` and `PATHEXT`) — with the
rules as values, so the Windows answers are unit-tested on every host.
The SDK's URL opener is `sdk/mnml-sdk/src/platform.zig`.

## Build and compile

| site | status | Windows / Linux |
|---|---|---|
| `build.zig` `sdk_mod`, `sdk/mnml-sdk/build.zig` | fixed | `.link_libc = true`: `warm.zig`'s `std.c.kill` / `std.c.getpid` compile on Linux; every integration importing the SDK inherits it |
| `build.zig` + `integrations/bitbucket/build.zig` fake Bitbucket | fixed | `.link_libc = true` for its `std.c.kill(parent, 0)`, as `mnml-fake-jira` already had |
| `src/app/integration_poll.zig` "stopping the poller … reaps its child" | fixed | skips on Windows (the child is `/bin/sh`, the probe `kill(pid, 0)`); it no longer stops the Windows test binary compiling |
| `src/app/lsp_format.zig` `lintFailed` test | fixed | `.signal = .TERM` (exists on every `SIG`) — the test runs on Windows |
| `src/editor/safe_write.zig` "a save that fails part-way…" | fixed | the mode-survives half is POSIX-only; the bytes half runs on Windows |
| `build.zig` `gate-targets`, `run.sh check`, `tools/run-sh-check.sh` | fixed | the local chain now cross-compiles all five targets and fails on any |

## Home, temp, environment

| site | status | Windows |
|---|---|---|
| `src/config/data_root.zig` `Env.home` | guarded | `HOME`, else `USERPROFILE` |
| `sdk/mnml-sdk/src/manifest.zig` `dataRoot` | guarded | the same rung |
| `sdk/mnml-sdk/src/request_log.zig` | guarded | `HOME` orelse `USERPROFILE` |
| `integrations/jira/src/auth.zig` | guarded | `HOME` orelse `USERPROFILE` |
| `src/app/font_scan.zig` | guarded | `USERPROFILE`, `;`, `%LOCALAPPDATA%\Microsoft\Windows\Fonts` |
| `src/app.zig` `App.homeDir` | fixed | read `HOME` only → `os_path.home` |
| `src/app.zig` `App.userHome` (new) | fixed | the loaded config's home, else the App env's; replaces six `homeDir() orelse env.get("HOME")` sites: `coverage.zig`, `files_pane.zig`, `launch_profiles.zig`, `session_worktree.zig`, `tree.zig`, `sessions.zig` |
| `src/app.zig` `App.expandTilde` | fixed | `~\…` expands, `USERPROFILE` is a home |
| `src/app.zig` `App.processEnv` | fixed | returned an EMPTY map on Windows; now the PEB block (`Environ{ .block = .global }`) |
| `src/config/load.zig` `projects_dir` / `default_workspace` `~` | fixed | `USERPROFILE`, `~\` |
| `src/app/startup_picker.zig` `wanted` | fixed | launched in `%USERPROFILE%` shows the picker; trims `\` too |
| `src/app/now_playing.zig` | fixed | mixr's `~/.mixr/quick.txt` under `USERPROFILE` (the osascript half is macOS's) |
| `sdk/mnml-sdk/src/ratelimit.zig` `statePath` | fixed | `USERPROFILE` rung (it went `HOME` → cwd) |
| `integrations/bitbucket/src/config.zig` `dataRoot` | fixed | `USERPROFILE` rung, matching the SDK |
| `sdk/mnml-sdk/src/broker.zig` `socketPath` fallback | fixed | `%TEMP%\mnml-broker-<svc>-<hash>.sock`, not `\tmp\…` on the current drive |
| `src/main.zig` `test` temp root | fixed | `os_path.tempDir` — `C:\Windows\Temp` rather than `/tmp` when nothing is set |
| `src/app/info_view_audit.zig` scratch workspace | fixed | read `TMPDIR` only → `os_path.tempDir` |
| `src/tui/marker.zig` | guarded | `TMPDIR`, `TEMP`, `TMP`, `USER`, `USERNAME` |
| `src/bridge/host.zig` `socketPath` | guarded | never takes the `/tmp` fallback on Windows |
| `src/ai/usage.zig` token path `~/` | guarded | the home it is handed is `App.homeDir` (now `USERPROFILE`-aware); `~\` is not expanded there |
| `src/app/setup.zig` `tilde` / `~/.local/bin` | guarded | only on the POSIX branch; Windows returns the PowerShell PATH line first |
| `src/app/ghostty_config.zig` | documented | `XDG_CONFIG_HOME`, `HOME`: Ghostty has no Windows build, so there is no config to find |

## PATH lookup and shells

| site | status | Windows |
|---|---|---|
| `src/pty/root.zig` `shellArgv` | guarded | `%COMSPEC% /d /c` (`win_cmdline.defaultShell`) |
| `src/app/pty_pane.zig` default shell | guarded | `COMSPEC`, never `SHELL` |
| `src/app/ex_verbs.zig` `:!` | guarded | `cmd.exe /C` |
| `src/app/runners.zig` `findOnPath` / `pathOf` | guarded | delimiter + `PATHEXT` |
| `src/core/clipboard_os.zig`, `src/app/font_scan.zig`, `src/ai/cli.zig`, `src/app/scripts.zig`, `src/app/integrations.zig`, `src/app/integrations_tools.zig` | guarded | split on `std.fs.path.delimiter` / `;` |
| `src/app/dispatch.zig` `filterThroughShell` (`!` filter) | fixed | was `/bin/sh -c`; now `pty.shellArgv` |
| `src/app/lsp.zig` `onPath` / `resolveOnPath` | fixed | split on `:` — every `C:\…` entry broke — and no `PATHEXT` (`typescript-language-server.cmd`); now `os_path.which` |
| `src/app/ai.zig` `binaryOnPath` | fixed | `:` and `/` joins; `claude.exe` never found; now `os_path.which` |
| `src/cdp/client.zig` `resolveBinary` | fixed | `:`; now `os_path.which` |
| `src/cdp/client.zig` `candidates` | fixed | Chrome / Chromium / Edge's `Program Files` paths (none is on `PATH` on Windows) |
| `src/cdp/client.zig` `available` / `spawn` (puppeteer cache) | fixed | `~/.cache/puppeteer` under `USERPROFILE` (it read `HOME`) |
| `src/app/cmd_app.zig` `onPath` | fixed | had `;`, lacked `PATHEXT`; now `os_path.which` |
| `src/e2e/runner.zig` `shell` steps, `src/main.zig` `mnml test` (`MNML_E2E_SHELL` or `/bin/sh`) | documented | `<shell> -c`: `.test` shell steps are POSIX sh by definition, and the runner never reads `$SHELL`. Windows runs the corpus with `MNML_E2E_ALLOW_SHELL=0` (refused, not run through `cmd`); a Git-for-Windows `sh.exe` named by `MNML_E2E_SHELL` is the way to run them |
| `integrations/jira/src/dispatch.zig` `termLine` / `firePrompt`, `integrations/bitbucket/main.zig` `dispatchSession` | documented | `sh -c 'claude <<'MNML_EOF' …'`: needs an `sh` on `PATH` (Git for Windows' `usr\bin`); without one the host's `:term` fails to spawn and says so. Closing it: pass the prompt as `claude`'s argv (no shell) or through a temp file |

## Processes and signals

| site | status | Windows |
|---|---|---|
| `src/pty/session_posix.zig` (openpty, fork, execve, fcntl, poll, `kill(-pgrp)`, SIG) | guarded | not compiled: `pty/root.zig` selects `session_windows.zig` (ConPTY) |
| `src/tui/term_posix.zig`, `src/tui/input_posix.zig` (termios, SIGWINCH self-pipe) | guarded | `term_windows.zig` / `input_windows.zig` (console modes, `ReadConsoleInputW`) |
| `src/pty_demo.zig` | guarded | not built (`demos_supported`) |
| `src/headless.zig` signal handlers | guarded | no-op; the IPC `quit` is the way out |
| `src/core/child.zig` `reapAbandoned` / `gone` / `goneWithin` | guarded | no-op / true: `Child.kill` terminates and waits there |
| `src/cdp/profile.zig` `SingletonLock` probe, orphan stop | guarded | `free` / true: Chrome's lock is not a symlink on Windows |
| `src/e2e/runner.zig` `childrenSummary` (`pgrep`) | guarded | null |
| `sdk/mnml-sdk/src/warm.zig`, `integrations/*/main.zig`, fake servers: `getpid` / `kill(pid, 0)` | guarded | pid 0 / "alive" |
| `src/app/agents.zig` `runningPids` (`ps -axo pid=,ppid=,pgid=,command=`) | documented | no `ps`: the scan finds no process, so every agent transcript reads as done rather than running. Closing it: `Get-CimInstance Win32_Process` (or `wmic process get ProcessId,CommandLine`) for the same pid + command line pairs |
| `src/pty/session_windows.zig` job object | documented | `deinit` terminates the direct child only; a shell's own children survive. `CreateJobObjectW` + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` |

## Opening things, the clipboard

| site | status | Windows |
|---|---|---|
| `src/core/clipboard_os.zig` | guarded | `clip.exe` / `powershell Get-Clipboard` |
| `integrations/jira/src/os.zig`, `integrations/bitbucket/src/os.zig` clipboard | guarded | `clip` |
| `src/app/cmd_view.zig` `revealArgv` | guarded | `explorer /select,<path>` |
| `src/app/browser_open.zig` default | fixed | was `cmd /c start "" <url>`: `cmd` re-parses the line, so `?a=1&b=2` lost everything after `&` — and a URL out of a ticket could name a second command. Now `rundll32 url.dll,FileProtocolHandler <url>` (no `cmd`) |
| `src/app/browser_open.zig` named browser (`ui.external_browser`) | fixed | still `start` (it resolves `msedge` through App Paths); the URL's `cmd` metacharacters are `^`-escaped |
| `integrations/jira/src/os.zig`, `integrations/bitbucket/src/os.zig` `openArgv` | fixed | the same `cmd /c start` → `sdk.platform.openUrlArgv` (`rundll32`) |
| `src/ai/usage.zig` keychain (`security`) | guarded | macOS only |

## Paths in output and on disk

| site | status | Windows |
|---|---|---|
| `src/app/loclist.zig`, `src/app/ex.zig` `:cexpr` / `:lexpr` | fixed | split `C:\a.zig:12:3: msg` at the drive's colon (path `C`); now `os_path.splitLocation` |
| `src/lsp/tools.zig` gcc-style parser, `src/app/tests_pane.zig` locations | guarded | scan for the numeric fields / split from the right, so a drive letter survives |
| `"{s}/{s}"` joins: `ai/usage.zig`, `app/ai.zig`, `runners.zig`, `scripts.zig`, `scripts_panel.zig`, `settings.zig`, `editor/safe_write.zig`, `broker.zig` (beside the state) | documented | work: Win32 takes `/` as a separator. A path built this way shows mixed separators in a toast |
| `0o600` / `0o755` modes: `ipc/channel.zig`, `ai/usage.zig`, `first_launch.zig`, `launch_profiles.zig` | guarded | `.default_file` |
| symlinks: `app/integrations.zig`, `app/marketplace.zig`, `config/seed.zig` | guarded | fall back to a copy (no symlink privilege) |
| symlinks: `app/transfers.zig` (copying a link) | guarded | a link that cannot be recreated is skipped and counted |
| symlinks: `app/setup.zig` `install_to_path` | guarded | Windows never reaches it |
| `src/app/trash.zig` | guarded | its own trash under the data root on every platform |

## Sockets

| site | status | Windows |
|---|---|---|
| `src/bridge/host.zig` mounts, `sdk/mnml-sdk/src/broker.zig` | documented | Unix domain sockets. Windows 10 1803+ has `AF_UNIX`; whether Zig 0.16's `Io.net.UnixAddress` binds there has not been run. The paths are Windows-shaped (above) |

## Tests that skip on Windows

138 test blocks `return error.SkipZigTest` on Windows directly (142
skip sites in 53 files, four of them in helpers the tests call; a few
more skip through a helper, like `sessions.zig`'s fake `claude`),
almost all because they script `/bin/sh` fakes — an LSP, a DAP
adapter, a pty child. In 48 of the 53 files other tests in the same
file run on Windows. The six whose Windows build had no running test
when this audit was made (`child.zig` has one now):

| file | skipped | the Windows side |
|---|---|---|
| `src/core/child.zig` | 4 | new: "a waited child is gone, on every platform" runs `cmd.exe /d /c exit 3` there |
| `src/app/cmd_term.zig` | 6 | `pty/root.zig`'s `shellArgv` tests and `win_cmdline.zig` (every host) cover the argv; ConPTY itself has no runtime test |
| `src/app/pty_search.zig` | 4 | the search is over the ghostty-vt grid; only the child that fills it is POSIX. No Windows-side test |
| `src/app/ai_grid.zig` | 6 | none: every test drives a fake `claude` shell script |
| `src/app/script_task.zig` | 3 | none |
| `src/e2e/cancel_probe.zig` | 1 | none: a SIGIO-cancellation probe, POSIX by nature |

CI's `check` matrix runs `zig build test` on `windows-latest`, so a
Windows-side test does execute on every push there — which is why the
ones above were not written blind: a new test that has never run on a
Windows machine would be a guess checked in.

## The big gaps

1. **Nothing here has run on a Windows machine.** ConPTY
   (`src/pty/session_windows.zig`), the console session and the input
   worker exist and compile; `docs/WINDOWS.md` has the checklist. CI's
   `windows-latest` job runs the unit suite and the gate, never the
   interactive loop or a pty.
2. **No job object** for pty children (above).
3. **Agents scan** — `ps` (above).
4. **Integration dispatch** needs `sh` (above).
5. **Unix sockets** for bridge mounts and the broker are unproven on
   Windows (above).
