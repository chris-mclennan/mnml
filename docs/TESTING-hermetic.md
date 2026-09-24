# Hermetic tests

The unit suite and the `.test` corpus run on machines where other copies
of mnml-zig are running the same suites at the same time: up to ten
agents, each in its own worktree, and CI runners that share hosts. A test
is **hermetic** when nothing outside its own temp directory, its own
process group and its own environment can change its verdict — another
run of the same test included.

This file is the inventory: every site found that reached past its test,
what it shared, and what it does now. It was built by grepping the corpus
(`tests/e2e/**/*.test`: `serve` ports, `shell` steps, `# env:` lines),
the unit tests and `tools/*.sh` for fixed ports, fixed `/tmp` paths,
`$TMPDIR` names, the real `HOME`, machine-wide `ps`/`pgrep`/`pkill`,
short wall-clock waits and an unset `MNML_DATA_ROOT`; then by running
the whole corpus under `env -i` with `TMPDIR` inside a git worktree, and
twice at once from two worktrees beside a live broker and a stray fake
`claude`.

The mechanical parts are guarded: `src/e2e/corpus.zig` fails the unit
suite on a fixed `--port`/`serve` port, a `# env:` value under `/tmp`, a
header built from `$PWD`, and a `shell` step that looks at or kills
processes machine-wide; and at run time the **git guard** fails any file
whose `git` — the App's or a `shell` step's — acts on a repository
outside the run's temp root.

## The rules

- **Ports**: never chosen. Fake servers take `--port 0 --url-file F`;
  the runner's mocks are `serve 0 …`, named `${SERVE_PORT}` (the first)
  and `${SERVE_PORT_<n>}` anywhere in the file, `# env:` lines included.
- **Paths**: under the file's workspace (`$MNML_E2E_WORKSPACE`) or data
  root (`$MNML_DATA_ROOT`), or a unit test's `std.testing.tmpDir`. A
  derived path too long for a `sockaddr_un` falls back to a `/tmp` name
  that hashes the long path — distinct per bucket, per checkout.
- **Processes**: a file's `shell` steps run in one process group of the
  file's own (`$MNML_AGENTS_PGID`); the App's session scan sees only that
  group and its own descendants; the file's end kills the group.
- **Environment**: a file starts from an allowlist of the run's
  environment (`e2e.runner.hermeticEnv`) with a `HOME` of the run's own,
  `$MNML_SHIMS/ai` first on `PATH`, the terminal pinned to the one the
  corpus was written in, and git fenced at the temp root. Unit-test
  binaries run with `HOME=<cache>/unit-home` and without the variables
  that name live state (`build.zig`, `hermeticUnitEnv`).
- **Time**: wait for a condition, not a clock. `expect within <ms> …`
  polls; a `wait` is for letting a clock-driven thing happen, never for
  "long enough for the machine to catch up".
- **Git**: the run's own cwd is its temp root, `GIT_CEILING_DIRECTORIES`
  is the temp root in the process environment and every file's, and the
  App's repository and root-marker walks honour it. A `git` shim first on
  `PATH` (`GitGuard`) follows `-C` to where git will act and, when that
  is a repository outside the temp root, writes it down; the file fails
  with `git ran against a repository outside the run's temp root
  (<repository>): git <args> — a test must never reach the checkout it
  runs in`.
- **Flakes are reported, not hidden**: `mnml-zig test` retries a failing
  file once and names a pass on the retry as `FLAKY` — as it happens and
  in the trailer (`N/M passed (…), K FLAKY (passed only on a retry)` then
  one `FLAKY <file> — first run: <why>` line each). `--strict` retries
  nothing.

## The sites

Counts: **45 sites fixed** (among them 15 fixed-port files, 7 terminal-name
files, 6 `$PWD` files, 3 temp-path-length files and five app bugs the
work surfaced), and **kept, each with its reason**: the mount-socket
fallback, 15 files that name a port nothing listens on, two tool `pkill`s
already scoped by a unique path, `zig` on `PATH`, and the corpus's
remaining fixed `wait`s as a category.

### Shared sockets, locks and files (7 fixed, 1 kept)

| Site | Shared | Fix |
|---|---|---|
| `sdk/mnml-sdk/src/broker.zig` `socketPath` fallback | `/tmp/mnml-broker-<service>.sock` and its `.lock` for EVERY deep bucket: each unit test's private bucket under `.zig-cache/tmp`, each corpus file's data root, another checkout's tests. A second `Server.start` unlinked the first's socket; the election lock was shared. Broke `app.broker` (3 tests), `broker_cli` (acquire, status), the SDK broker harness tests, and `run-sh-check` "broker status: an ordinary path still reports an absent broker" whenever another mnml-zig held the lock | `/tmp/mnml-broker-<service>-<sha256(long path)[:6] hex>.sock` (`fallbackPath`); tests: pinned name, two deep buckets → two sockets/locks, two live brokers coexist |
| `sdk/clients/ratelimit_broker.py` | the same fallback name | the same hash with `hashlib` (pinned digest in the Zig test) |
| `tests/e2e/integrations_broker_header.test` | `JIRA_/BITBUCKET_BROKER_SOCKET=/tmp/mnml-e2e-broker-*.sock` — two runs took each other's election | overrides dropped: the sockets derive from the file's own buckets (or their hashed fallback) |
| LSP unit tests (`app.lsp`, `lsp_decor`, `lsp_rename`, `lsp_format`, `lsp_semantic`) | fixed `/tmp/mnml-zig-fake-lsp{,-other,-open,-readonly,-warn}.ts`, written, chmod-ed and deleted by concurrent runs | `TestRig.scratch(name)`: `/tmp/mnml-zig-lsp-<pid>/<name>`; three tests rooted there so their labels stay workspace-relative |
| `e2e.runner.makeTempDir` / `makeDataRoot` | `mnml-e2e-<6 hex>` under a `TMPDIR` shared by every run, created with `createDirPath` — a name another run held was silently shared | exclusive `mkdir`, retried on `PathAlreadyExists` |
| `app/mount_pane.zig` spawn | the IPC channel dir existed only as the mount socket's parent; a workspace too deep for a `sockaddr_un` put the socket in `/tmp` and the channel never existed — every integration's chip, toast and `term` dispatch went nowhere (`integrations_jira_work_tree`, `integrations_jira_fix_versions` under a deep `TMPDIR`) — a product bug the corpus found | `preparedIpcDir` creates it before spawning (and for poll jobs) |
| `tools/seed-sessions-home.sh stop` | `pkill -f -- "--resume 5e551011-…"`: another dump's copies share the ids | the fake `claude` records its pid; `stop` kills recorded pids only |
| `bridge/host.zig` mount socket fallback `/tmp/mnml-mount-<pid>-<id>.sock` | — | kept: pid + id are unique per live process |

### Ports (15 files fixed, 15 kept)

| Site | Fix |
|---|---|
| `serve <fixed>` — `ai_api_mock_ok` / `_429` / `_500` / `_stalls` (19711–19714, arrived from main during this work; the guard failed the unit suite on them), `cmdline_bar_inflight` (19893), `http_directives_not_body` (19892), `integrations_marketplace_github` (19801, in a `# env:` line too), `http/http-env-nested-var` (19602), `http/http-json-numbers-kept` (19605, 19606), `http/http-multipart-send` (19891), `http/http-no-redirect-302` (19882), `http/http-path-param` (19890), `http/http-save-bare-separator-blocks` (19601), `http/http-timeout-trips` (19881), `http/http-url-space-refused` (19603) | `serve 0` + `${SERVE_PORT}` / `${SERVE_PORT_2}`: the runner binds every `serve 0` when the file starts (`mock.Server.listenOn`), before the App, and serves it at its step. Two runs of one file used to fail `AddressInUse` |
| Fake Jira / Bitbucket servers | already `--port 0 --url-file` (guarded since before) |
| Addresses nothing listens on — `127.0.0.1:19876` / `19877` / `19878` / `18726` / `:1` in `http_request_pane`, `http_request_pane_keys`, `http_response_strip_narrow`, `http_curl_multi_block_send_uses_cursor`, `lua_http_hooks`, `integrations_jira_blocked`, and in `http/`: `http-diff-last-two-guard`, `http-fan-envs`, `http-format-body`, `http-headers-complete-value`, `http-mock-round-trip`, `http-response-search`, `http-schema-validate`, `http-status-chip`, `sse-parse-active-response` | kept: no test binds them any more (the guard refuses a fixed `serve`), they are below every OS's ephemeral range (macOS 49152+, Linux 32768+), and the screens assert the 5-digit width |

### Processes (2 fixed, a test added, 2 kept, 2 already scoped)

| Site | Shared | Fix |
|---|---|---|
| `app/agents.zig` `ps -axo pid=,command=` | the whole machine: two copies of `sessions_table_batch_kill.test` start fakes with the SAME session ids, and each run found — and SIGTERMed — the other's; Codex pids are claimed "first unclaimed codex on the machine", so any `codex` anywhere made a fixture session live (the `agents.scanInto` unit test) | `MNML_AGENTS_PGID`: the scan keeps processes in that group or descended from the App (`ps -axo pid=,ppid=,pgid=,command=`); the runner sets it per file; the unit scans use an empty scope |
| `shell` steps' background processes | fake `claude`s (60 s), fake servers (`--life-secs 180`) outlived the file and were seen by the next run | the runner starts a group leader per file, every `shell` step joins it (`spawn` with `pgid`), the file's end `kill(-pgid, SIGKILL)`s it |
| `sessions_table_batch_kill.test` | — | now also starts a same-id stray OUTSIDE the file's group and asserts the kill never reaches it (the old binary killed it) |
| `sessions_waiting_toast.test`, `sessions_cards.test` (`fake-ext.sh`) | the same machine-wide ids | covered by the scope and the group kill |
| `tools/run-sh-check.sh` `pkill -f -- "$MNML_BIN"` | — | kept: `$MNML_BIN` is its own `mktemp` path |
| `tools/compare.sh` `pkill -f -- "--headless --input $INPUT $COPY_DIR"` | — | kept: `$COPY_DIR` is a private copy; a dev tool outside the suite |
| runner heartbeat `pgrep -lP <self>`, `files_tree_preview_skips_heavy_file` `ps -o rss= -p $PPID` | — | already scoped |

### Environment (11 fixed, 1 kept)

| Site | Shared | Fix |
|---|---|---|
| Every file's environment | the whole run environment: tokens, `CLAUDECODE`, `MNML_IPC_DIR` of the mnml whose terminal the run was started in (an integration under test wrote into that live channel), `XDG_CONFIG_HOME` | `hermeticEnv`: `PATH`, temp dirs, user/locale, Windows' system variables, `ZIG_*`, `MNML_E2E_*` and the runner's own helper paths; nothing else |
| `SHELL` (a terminal pane's shell, `pty.shellArgv`) | dropped with the rest, every pty file got `/bin/sh`: no bracketed paste, so a pasted block ran line by line (`pty_paste_sanitized` had to name zsh in its own `# env:`) | pinned: `/bin/zsh` on macOS — the platform's login shell, the one the corpus was written in, whatever the developer runs — and the host's `$SHELL` elsewhere; a file's `# env: SHELL=` wins (runner test `SHELL reaches a file's environment`) |
| The real `HOME` (corpus) | git identity, `~/.config/mnml`, Claude transcripts, `~/.tattle-claude-artifacts` buckets | `HOME=<run root>/home` |
| The real `HOME` (unit binaries) | the same; `persist_*` paths rewrote `~/.config/mnml`. The first run with a private HOME found the suite writing `.npm/`, `.rustup/settings.toml`, `.local/state/gh`, `.zsh_history`, `Library/Caches/node-gyp` and `Library/Application Support/vitest` into it — all of that used to land in the developer's own | `HOME=<cache>/unit-home`, live-state variables removed (`build.zig` `hermeticUnitEnv`) |
| `app/tests_pane.zig` unit tests (`test.run_playwright …`, `test.run_all on a vitest project …`) | ran the machine's real `npx playwright` / `npx vitest`, which fetched both from the npm registry in the background — network, CPU and an npm cache write, for a run the test cancels | the App's `PATH` is an empty directory: the spawn fails at once, as the test already allowed |
| `$TERM_PROGRAM` & friends | `launcher_dock_always`, `_always_outer`, `_icons`, `_keyboard`, `_placement`, `split_arrange_thirds`, `tab_cluster_preview` asserted `Terminal (sh)` — Apple Terminal's name — and failed in ghostty, in CI, under `env -i` | the runner pins `TERM_PROGRAM=Apple_Terminal`, `TERM`, `COLORTERM` and removes other emulators' marks; a file's own `# env:` wins |
| `claude` / `codex` on the host's `PATH` | the tab bar's AI chip shows only when one is found; the corpus was written where both were (`split_preview_keys` failed without them) — and a file could start the REAL CLI | `$MNML_SHIMS/ai` (sleeping stand-ins) first on every file's `PATH` |
| `# env: …=${PWD}` (`lua_example_eslint`, `_git_blame_line`, `_recent_commands`, `_surround_word`, `_todo_list`, and `lua_task_at_load_quits` from main) | `PWD` is a shell's; `env -i` and CI steps have none | `mnml-zig test` exports `MNML_REPO` (the checkout, `build_options.repo_dir`) |
| `TMPDIR` inside a git checkout | `repoAbove` and the LSP root walk climbed out of the workspace into the checkout: `git_commands_no_repo` saw its branches; `lsp_zsh_builtin_server`'s server was rooted at the checkout and wrote `lsp.log` into it | the runner sets `GIT_CEILING_DIRECTORIES=<temp root>`; `app/git.zig` `repoAbove` and `app/lsp.zig` `walkUp` honour it as git does |
| `shell` steps' interpreter | the developer's login shell (`$SHELL`) | `/bin/sh` (`MNML_E2E_SHELL` overrides) |
| The runner's own cwd and environment | the App runs in-process, so a child it spawns with neither a cwd nor an environment inherits the runner's: the checkout as cwd, no git fence — a stale `index.lock` in a worktree's git dir, and main's twice in a day, came from runs like this | the cwd is the run's temp root (test paths made absolute first); the git fence, the guard's `PATH` and its variables are set in the process environment too (`fenceProcess`) |
| `format_external_zig_fmt` | needs `zig` on `PATH` | kept on `PATH` (the allowlist keeps `PATH`); a runner without zig cannot build the suite either |

### `TMPDIR` length (3 fixed)

An assertion on the END of an absolute temp path is an assertion on how
long `TMPDIR` is: the pane clips it, the dialog wraps it.

| File | Fix |
|---|---|
| `git_worktree_remove_delete_branch` (`pick Force` wrapped across rows) | the words one at a time, and the confirm proved gone |
| `integrations_bitbucket_setup` (`never-written.zon` clipped) | the part every `TMPDIR` keeps (`/mnml-e2e-`) and the scaffold's content via `expect file` |
| `integrations_marketplace_mnml` (`bin/mnml-sample` clipped) | the confirm's lead words; the link's removal is asserted on disk |

### Wall-clock waits and races (7 fixed, 1 checked, 1 category)

| File | Fix |
|---|---|
| `sessions_needs_you` (failed once at 868/869, line 25: the toast) | three causes, found by running it five and six times at once: the toast is on screen for 4 s from the moment the prompt is seen and a loaded machine spent those between steps (now: poll the durable tab mark, `expect within 20000`, and read the toast back from `:messages`); the fake decided "first run or second" with a read-increment-write counter file, and two launches racing both read 0 (now: an atomic `mkdir`); and **an app bug** — the card list re-sorted only at the next scan, so the mark was painted at once while Enter on the top card still opened the card that used to be there (`sessions.trackNeedsYou` now re-sorts on the flip; unit test) |
| `sessions_tab_names` | the same racy counter | the same atomic `mkdir` |
| `integrations_pane_chrome` (FLAKY in a full run: line 59, the list's scrollbar thumb) | `wait 9000` → `expect within 30000` on the thumb |
| `statusline_hover_focus_bitbucket` (failed in BOTH concurrent runs of one attempt, at the same step: "detail fetch failed: ConnectionRefused" from its fake; four copies alone passed) | the fake Bitbucket, the fake Jira and the runner's mock all ran `accept(...) catch break` — one failed accept under load (a client that gave up first) ended the server for the rest of the file. A failed accept now waits 10 ms and goes on; the file also polls its two detail fetches |
| `line_blame` (failed in one of two concurrent runs, line 17) | **an app bug**: a blame answer is cached against the HEAD it was asked at, and one asked before the first status snapshot landed (HEAD "") never matched again — the blame never showed until the cursor moved. The status handler now re-asks for the cursor line (a cache hit when HEAD is unchanged); unit test. The file also polls the first answer (`expect within 15000`) |
| `integrations_jira_work_filter_jql` (line 43 `JIRA WORK (3)` under load) | `wait 8000` → `expect within 30000`; the JQL re-fetch → `expect within 15000` |
| `integrations_warmer_bitbucket_conditional` | the three `wait 4000`s → `expect within 20000–30000` on the screen and the wire log |
| `session_restore_claude_resume`, `session_restore_codex_resume` | checked: both fakes keep their first session alive until the restore replaces it, and the assertions are on `argv.log`, polled; they passed in both concurrent runs |
| The rest of the corpus: 348 files with a `wait` | every `expect` already polls for 3 s (`expect_budget_ms`); a `wait` before a key is the remaining risk. Not rewritten wholesale — the retry reports any that flake by name (`FLAKY`), which is where the next one to fix comes from |

### Tools that read the real `HOME` (2 known, each with its workaround)

A file's `HOME` is empty and the run's own. Two tools on a developer's
machine resolve state from `HOME` and misbehave without it; neither is
in the corpus, but a hunt repro that drives them meets both.

| Tool | What breaks under the private `HOME` | The sanctioned workaround |
|---|---|---|
| Chrome (the browser pane, `http.proxy`) on macOS | Chrome creates its "Safe Storage" keychain item on first launch; with no login keychain under that `HOME` it wedges in `SecKeychainItemCreateFromContent → makeLoginAuthUI` — no DevTools line, and it ignores SIGTERM. (Closing such a pane used to hang the app for good; `Launch.kill` now SIGKILLs after a grace, so it only fails the file.) | `--use-mock-keychain`, and it belongs in the **test's Chrome wrapper**, never in `cdp.chromeArgv` — that argv launches the user's own Chrome, whose real keychain is the right one. A file that launches a real Chrome puts a `chrome-for-testing` wrapper first on its `PATH` (`# env: PATH=<dir>:${PATH}`) that runs `exec "<Chrome binary>" --headless=new --use-mock-keychain "$@"`. `chrome-for-testing` is the first bare name `cdp.candidates` tries, after the puppeteer cache under `HOME` (empty here) — but after the absolute `/Applications/Google Chrome for Testing.app` path, so on a machine with that app installed the wrapper is not reached. |
| rustup's proxies (`cargo`, `rustc`, `rust-analyzer` in `~/.cargo/bin`) | a proxy finds its toolchains through `$RUSTUP_HOME`, by default `$HOME/.rustup`; under the run's `HOME` it has none and exits with "rustup could not choose a version … no default is configured" — an LSP file never sees its server start | the corpus uses the canned `tools/shims/cargo` (`# env: PATH=${MNML_SHIMS}:${PATH}`). A repro that needs the real toolchain names it through the pass-through prefix: run with `MNML_E2E_RUSTUP_HOME=$HOME/.rustup MNML_E2E_CARGO_HOME=$HOME/.cargo`, and the file says `# env: RUSTUP_HOME=${MNML_E2E_RUSTUP_HOME}` and `# env: CARGO_HOME=${MNML_E2E_CARGO_HOME}` — the developer's paths stay out of the file and out of every other file's environment. |

## Which tests walked up

Found with the guard itself: a probe build with the fixes that fence git
turned OFF (the ceiling in `repoAbove`, `walkUp`, the runner's env and
the process env; the cwd move) — main's behaviour — ran the whole corpus
from the checkout's root with `TMPDIR` inside the checkout. The guard
wrote down six `git` calls against the checkout, all from ONE file:

- `git_commands_no_repo.test` — `git.recent_branches` found no repository
  in its workspace, `requireRepo` → `repoAbove` climbed into the
  enclosing checkout and adopted it: `for-each-ref` (×2), then the status
  poll on that repo — `status --porcelain=v2 -b` (which refreshes the
  index under `index.lock`), `rev-parse --absolute-git-dir`,
  `diff -U0 HEAD`, `config remote.origin.url`. A run killed while that
  `status` held the lock leaves it stale: the `.git/index.lock` in main
  and in a worktree's git dir.

No `git` was spawned with an inherited cwd in that run; the cwd move
makes sure one never can. One more file climbed out, for an LSP root
rather than git: `lsp_zsh_builtin_server.test` (its `.git` root marker)
— it wrote `lsp.log` into the checkout's root. Both pass with the fence
on, and the guard stays on for every run.

## Proving it

The proof run is two full corpora at once, from two worktrees of the
same commit sharing one `TMPDIR` (inside a git worktree, `env -i`), with
a broker listening on the default socket and a stray fake `claude`
carrying a corpus session id — plus the unit suite run the same way.
Both corpus runs must be all-green in `--strict` (no retry): a retry
would hide exactly what the run is there to show.

How it was run (2026-09-23/24, macOS, ReleaseSafe):

- two worktrees of the same commit, each built on its own; both runs with
  `env -i PATH=… HOME=<worktree>/.verify/home TMPDIR=<worktree>/.verify/tmp`
  — the same `TMPDIR` for both, inside a git worktree;
- `mnml-zig broker serve` for `bitbucket` and `jira` running on the
  sockets that environment resolves by default;
- three stray fakes of our own outside any file's group: a `claude
  --resume` with `sessions_table_batch_kill`'s first session id, one with
  `sessions_waiting_toast`'s, and a `codex`;
- other agents' corpus runs going on the same machine throughout.

| Commit | Run | Result |
|---|---|---|
| `2cc39cef` (before the git guard) | unit, both worktrees at once | 2956/2958 and 2956/2958 (2 skipped each), exit 0 |
| | corpus, both at once, `--strict` — first attempt | 882/882 and 881/882: `line_blame` (the HEAD race, fixed) |
| | corpus, both at once, `--strict` — after that fix | **882/882 and 882/882**, exit 0 |
| rebased on main, with the git guard | unit, both at once | 3005/3007 and 3005/3007 (2 skipped each), exit 0 |
| | corpus, both at once, `--strict` | 939/940 and 939/940: `statusline_hover_focus_bitbucket` in both, at the same step (the fakes' accept loop, fixed) |
| `d6df4c48` (the accept-loop fix) | unit, both at once | 3005/3007 and 3005/3007, exit 0 |
| | corpus, both at once, `--strict` | **940/940 and 940/940**, exit 0 |

(Commit ids are the branch's before its last rebase onto main; after it,
the unit suite and the corpus were run again on the rebased tree — see
the branch's report.)

Both brokers survived every run, as did the `sessions_waiting_toast` and
`codex` strays. The stray carrying `sessions_table_batch_kill`'s id died
twice while other agents' corpus runs on the unfixed code were going:
our runs' scans are scoped (its replacement survived both of ours in the
`2cc39cef` attempt), and nothing else of ours signals a `claude
--resume`, so the likely killer is an unfixed run's machine-wide scan —
the bug this file is about, seen from the outside. Inferred, not traced.
