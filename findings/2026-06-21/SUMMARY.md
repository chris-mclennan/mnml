# QA sweep summary — 2026-06-21

11 agents fired in parallel against `HEAD = 90e554b` (the /qa-sweep skill
commit). Tree was clean apart from a fresh `findings/.gitkeep`.

## Counts

- **SEV-1: 7**  (critical — lost user work or broken core flow)
- **SEV-2: 32** (real friction, broken feature path)
- **SEV-3: 32** (cosmetic, label, polish)
- **Design issues: 8** (2 high · 3 medium · 3 low)

**Total: 79 findings + 8 design issues = 87 distinct items across 11 agents.**

The two `vscode-kbd-session-features.md` and
`vscode-mouse-session-features.md` files each contain a combined report —
9 and 12 sub-findings respectively. (The other 9 agents wrote one
file per finding.)

## SEV-1

- [api-workflow-history-picker-index-mismatch](api-workflow-history-picker-index-mismatch.md): `pending_history_rows` shared between `:http.history` and `:http.history_global` — Esc on one then opening the other resolves picker indices against stale rows · agent: api-workflow-user
- [api-workflow-ws-send-blocks-ui](api-workflow-ws-send-blocks-ui.md): `:ws.send` (websocat shell-out) busy-polls on the main app thread for up to 5s, freezing all UI · agent: api-workflow-user
- [claude-agents-codex-double-row](claude-agents-codex-double-row.md): every active Codex session appears TWICE in the dashboard — disk row stuck "ended", stub row "streaming"; killing the ended row toasts "no PID" while Codex is live · agent: claude-agents-power-user
- [nvchad-ctrlw-blocked-from-special-panes](nvchad-ctrlw-blocked-from-special-panes.md): Ctrl+W swallowed in every non-editor pane (Request / Diagnostics / Cheatsheet / ClaudeAgents / WS / Grep / Quickfix / CmdlineHistory) — vim users lose split nav anywhere outside the editor · agent: nvchad-user
- [nvchad-ws-pane-no-modal-awareness](nvchad-ws-pane-no-modal-awareness.md): WebSocket pane treats every printable char as text input — vim user typing `ihi` literally inserts `ihi` into the outgoing message · agent: nvchad-user
- [power-user-ws-git-worktree-add-sentinel-leaks](power-user-ws-git-worktree-add-sentinel-leaks.md): Esc on `:git.worktree_add` leaves `pending_worktree_path = Some(empty)` sentinel — NEXT `view.add_workspace` hijacks the typed path into the worktree-add flow · agent: power-user-ws-git
- [power-user-ws-git-ws-send-blocks-on-read](power-user-ws-git-ws-send-blocks-on-read.md): WS worker calls blocking `tungstenite::read()` before draining `out_rx` — first `:ws.send_message` to an echo/RPC server deadlocks · agent: power-user-ws-git

## SEV-2 highlights

Full list in this directory; calling out the high-impact themes:

**Shipped-today regressions in code from this session's commits:**
- `claude-agents-token-flicker` — `live_tail_selected()` clobbers `lifetime_cache` values every 500ms, chips visibly oscillate
- `claude-agents-spend-today-tail-only` — `:ai.spend_today` uses tail-window parse not the lifetime cache, undercounts long sessions by 80%+
- `claude-agents-selection-lost-on-refresh` — when selected session disappears (filter/rolloff/kill), cursor stays at stale out-of-bounds index
- `claude-agents-file-click-offset-wrong` — Files drill-down click rects use raw `detail_scroll` not `actual_scroll`, click targets vanish past end
- `power-user-ai-utf8-truncation-panic` — `&diff[..32_000]` byte-slicing in `:ai.explain_diff` + `:ai.write_pr_description` **panics on multi-byte UTF-8 boundary** (reproduced with 4-byte emoji at byte 31_999). Same pattern in 3 pre-existing commands.
- `power-user-ai-no-in-flight-guard` — none of the 4 new AI commands have the in-flight guard `:http.ai_build` has — rapid double-fire silently drops first reply, still bills tokens
- `power-user-ws-git-esc-destroys-connection` — Esc in WS pane closes the connection instead of blurring focus (flagged by 4 separate agents)
- `power-user-ws-git-merge-rebase-block-ui` — all 5 new git accept handlers (merge/rebase/delete_branch/worktree_add/worktree_remove) sync-shell-out on main thread, freezing UI. Codebase has async `git_loader_tx` pattern; new handlers regressed it.
- `power-user-ws-git-no-refresh-after-mutations` — new handlers skip `after_git_change()`, git rail keeps showing deleted branches / removed worktrees
- `power-user-ws-git-merge-rebase-detached-head` — `current()` returns None on detached HEAD, "exclude current" excludes nothing, picker offers invalid choices
- `vscode-git-merge-rebase-picker-single-click-no-confirm` — single mouse click in `:git.merge` / `:git.rebase` pickers immediately fires the action with no confirm prompt while sibling pickers do gate (confirmed live: click fast-forwarded `main` onto a feature branch)
- `vscode-peek-overlay-mouse-cannot-dismiss` — peek_definition_overlay captures zero mouse input; clicks inside box pass through to editor (mutating it), clicks outside don't dismiss
- `power-user-lsp-cheat-test-peek-pending-flag-leak-on-no-lsp` — `pending_peek_definition` only cleared in GotoDefinition handler; no-LSP / null-result paths leak the flag, next `gd` opens overlay instead of jumping
- `power-user-lsp-cheat-test-peek-any-key-closes-and-falls-through` — peek overlay's `_ => app.peek_overlay = None` falls through to editor; in vim mode pressing `x` to dismiss also deletes char under cursor (flagged by 2 agents)
- `power-user-lsp-cheat-test-cheatsheet-Z-asymmetry-after-single-collapse` — `Z` is `is_empty? collapse_all : expand_all`; after a single `z`, `Z` wipes user's collapse instead of folding the rest
- `power-user-lsp-cheat-test-cheatsheet-filter-ignores-collapsed-sections` — `visible_sections()` empties collapsed groups BEFORE filtering; `/save` won't surface a row in a collapsed section
- `power-user-lsp-cheat-test-runners-manifest-detection-only-checks-workspace-root` — `:cargo/npm/pytest/go` never walk up the tree; subdir of a monorepo gets "no manifest" toast even though the tool itself would find one
- `multilang-pytest-tests-dir-false-positive` — `:pytest.run` from mnml itself (has `tests/`) spawns pytest against a Rust codebase. Real
- `multilang-npm-toast-malformed-id` — toast embeds full subcmd in command ID: `npm.run dev: no package.json` instead of `npm.run: no package.json`. Affects 8 commands.
- `nvchad-ex-cmdline-blocked-in-special-panes` — `:` (ex-cmdline) silently dropped from Cheatsheet / Diagnostics / ClaudeAgents / Request / Grep. Same swallow-then-return shape as Ctrl+W. Single fix at the pane-dispatcher level addresses both.
- `nvchad-cheatsheet-z-collides-with-fold-prefix` — `z` and `Z` stomp vim's fold prefix. `zc` half-fires (section collapse + swallow of `c`); `ZZ` becomes "toggle-all twice → no-op" instead of vim save+quit
- `nvchad-agents-dashboard-vim-chord-collisions` — dashboard binds 13 single-letter chords colliding with vim canonicals; `gg` is no-op (two group_by cycles), `G` is unbound, `w` mutates workspace filter
- `nvchad-request-pane-r-refires-a-spawns-ai` — Response view bare `r` re-fires request (destructive on PUT/DELETE), bare `a` opens AI debug (spends real tokens). Pre-existing.
- `api-workflow-cookie-inject-missing-from-chain` — `http::chain::run` bypasses `App::spawn_http_job`'s cookie injection. Multi-step authenticated chain flows silently break.
- `api-workflow-ws-worker-blocking-read` — same root cause as SEV-1 `ws-send-blocks-on-read`, different failure mode (disconnect-doesn't-work on a quiet server, stuck `Closing`, zombie threads)
- `api-workflow-http-abort-misses-chain-and-ai` — `http_abort_all` doesn't reset `http_chain_in_flight` or `http_ai_build_in_flight`; no escape from a stalled chain/AI build short of restart
- (additional ~10 SEV-2s in dir — full list above; click any file for the writeup)

## SEV-3

32 cosmetic / polish issues. Highlights:
- `claude-agents-codex-export-stale-comment` — Codex export writes "transcript format isn't parsed yet" but the parser shipped 3 commits ago
- `claude-agents-dead-scroll-field` — `ClaudeAgentsPane::scroll: usize` never written or read (dead state from earlier design — confirmed by my own code comment)
- `claude-agents-title-chips-missing-with-text-filter` — when filter active, title bar drops sort/source/ws/multi-select chips
- `nvchad-ipc-key-spec-rejects-chord-chains` — `parse_key_spec` is single-chord only despite docstring promising whitespace-separated chains. Test-tooling concern.
- `power-user-ai-base-ref-chain-misses-trunk-develop` — `:ai.write_pr_description`/`:ai.recompose_branch` only check `[origin/main, origin/master, main, master]` — repos with `trunk` or `develop` fail
- `power-user-ai-recompose-drops-claude-session-trailer` — system prompt only mentions `Co-Authored-By:` in preserve clause; Claude will strip the `Claude-Session:` trailer
- `multilang-npm-run-hardcoded-dev` — `:npm.run` hardcoded to `npm run dev`; projects using `start:dev` / `vite` / `next dev` get wrong command
- `multilang-go-run-hardcoded-dot` — `:go.run` hardcoded to `go run .`; most non-trivial Go projects put main in `cmd/<app>/main.go`

## Design findings (claude-agents-dashboard.md)

Full report at `design-reviews/2026-06-21/claude-agents-dashboard.md` (in the agent's output — file not staged to disk by agent, content captured in earlier transcript).

| Severity | Issue |
|---|---|
| high | No whichkey/leader chord for the dashboard — palette-only entry |
| high | Column-header row scrolls off with the data after `j × viewport-height` presses |
| medium | `:ai.agents_dashboard` is the only noun-phrase command in the `ai` group (rename to `:ai.dashboard`) |
| medium | `☑` glyph means two things on same row (multi-select mark + todo-progress counter) |
| medium | `K`/`R` opposite-case for opposite-danger pairing reads as risk-tier-equal in help overlay |
| low | `let _group = p.group_by.label()` dead binding — never wired into title bar (also flagged by power-user-claude-agents as `dead-scroll-field`) |
| low | Export dir `.mnml/claude-exports/` embeds product name vs other `.mnml/<flat-slug>/` neighbors |
| low | Empty-state message doesn't teach the next action |

Also called out FOUR patterns working well: transition toasts, dual refresh rate, drill-down scroll scoping, batch-kill safety. Multi-source design (Claude + Codex in one pane) validated as the right call.

## Patterns across the sweep

Several findings were independently flagged by multiple agents — strong signal:

- **Esc in WS pane destroys connection** flagged by 4 agents (nvchad, vscode-kbd, vscode-mixed, power-user-ws-git)
- **Peek overlay falls through on any key** flagged by 2 agents (vscode-kbd, power-user-lsp-cheat-test)
- **Runners don't walk up for monorepo manifest detection** flagged by 2 agents (multilang, power-user-lsp-cheat-test)
- **Every new command has empty `keys: &[]`** flagged across 3+ agents — real discoverability gap
- **Sync-shell-outs on main thread** — pattern across `:ws.send`, `:grpc.send`, all 5 new git accept handlers

## Coverage notes

All 11 agents reported back successfully. None errored or died.

Agents that ran:
- claude-agents-power-user (dashboard)
- multilang-dev-user (TS/Py/Go workspaces — staged 20 new e2e tests)
- api-workflow-user (HTTP / WS / chain / schema / AI build)
- nvchad-user (vim chord vocabulary)
- vscode-user (mixed mouse + keyboard)
- vscode-user-keyboard (keyboard purist)
- vscode-user-mouse (mouse purist)
- design-critic (dashboard design)
- power-user-ws-git (WebSocket + 5 git pickers — staged 8 e2e probes)
- power-user-ai (4 new AI commands)
- power-user-lsp-cheat-test (peek overlay + cheatsheet collapse + test runners — staged 4 e2e probes)

Agents staged **32 new `.test` repro files** under `tests/e2e/` across the sweep — those alone are a significant test-suite expansion.

Tree at sweep time was clean; the SEV-1s are all in shipped code, not in
working-tree-only changes. If you fix the SEV-1s and re-run a narrower
`/qa-sweep dashboard` or `/qa-sweep http`, the fixes can be verified
against the same `.test` files the agents wrote.
