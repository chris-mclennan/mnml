---
title: Security & hardening
description: Workspace trust, what mnml refuses to send to an AI backend, owner-only writes for every credential-bearing file, portable data roots, and how integration tokens are scoped at spawn time.
---

mnml runs language servers, formatters, debug adapters, shell commands and AI tooling on your behalf, and it stores credentials for a couple of dozen integrations. That makes three boundaries worth documenting rather than leaving to the source: **what a repository you just cloned is allowed to run**, **what leaves your machine**, and **what lands on disk and with what permissions**.

This page is the user-facing view of those boundaries. It describes behavior that ships today — the config keys, the dialogs, the file modes, and the one command (`workspace.review_trust`) that lets you audit a decision after the fact. If you've found a way around any of it, [`SECURITY.md`](https://github.com/chris-mclennan/mnml/blob/main/SECURITY.md) has the private reporting channel.

## Workspace trust

`Config::load` layers `<workspace>/.mnml/config.toml` over your global config, and several of those keys name a binary that mnml then runs. Without a gate, cloning a repo and opening it was arbitrary code execution: `[lsp.evil] cmd = "/bin/sh"` fires the moment you open a matching file, and `[[startup.layout]] kind = "pty"` fires at startup with no interaction at all.

So mnml scans a workspace's `.mnml/` before honouring any of it, and asks.

### What counts as a claim

Five config shapes are treated as executable. Everything else in the same files — themes, keymaps, editor settings, extensions lists — is applied unconditionally.

| Kind | Config key | When it would run |
|---|---|---|
| Language server | `[lsp.<name>] cmd` / `args` | when you open a file |
| Format on save | `[formatters.<ext>] cmd` | when you save |
| Markdown preview | `[ui] md_preview_engine = "custom:…"` | when you preview markdown |
| Run at startup | `[[startup.layout]] kind = "pty"` | immediately, on open |
| Integration | `.mnml/integrations/*.toml` — `[[commands]]`, `launcher`, `[[launch_profile]]`, `[env]` | when you click its chip |

The scan is deliberately narrow, and the exclusions matter as much as the inclusions:

- An `[lsp.rust]` table with **no `cmd`** isn't a claim. Overriding only `extensions` or `root_markers` reuses the built-in binary — nothing new executes.
- `md_preview_engine = "builtin"` / `"glow"` / `"pandoc"` aren't claims. Only the `custom:` form runs an arbitrary command.
- `[[startup.layout]]` entries with `kind = "editor"` aren't claims. They open a file; they don't spawn anything.
- An integration manifest's `[env]` block **is** a claim even with no command attached, because it shapes the spawn — `PATH`, `DYLD_INSERT_LIBRARIES`, `GIT_SSH_COMMAND` are all reachable that way.
- A malformed or unreadable file yields **no claims** rather than an error. That's the safe direction: a file mnml can't parse is one it can't execute from either.

The consequence of scanning first is that the prompt stays rare. A repo with no `.mnml/`, or one carrying only a theme and some keymaps, never prompts — which is what keeps the dialog worth reading instead of reflexively dismissing. This is a deliberate divergence from the ask-about-every-folder model.

### The dialog

When claims exist and haven't been approved at their current fingerprint, mnml opens a confirm dialog at startup listing the actual commands:

```
mnml/.mnml/ declares:

  • integration claude_code · multi-repo: /Users/you/…/claude-multi.sh
      runs when you click its chip
  • language server rust · rust-analyzer
      runs when you open a file
  • run at startup · npm run dev
      runs immediately, on open

Trust this workspace only if you know where it came from.
Editing, git, and search work either way.

                        [ Trust ]   [ Don't trust ]
```

Three details are load-bearing:

- **The real command is shown**, middle-elided at 72 characters rather than truncated from the tail. Both ends of a command carry signal — the basename identifies a script, and the tail is where a `| sh` hides — so head-only truncation threw away exactly the half you need. Control characters are replaced with spaces so an escape sequence can't redraw the dialog around itself.
- **Each claim names its entry** (`integration claude_code`, not just `integration`). This matters most in the shadowing case, where a repo ships `integrations/claude_code.toml` to override *your* claude_code. The name comes from the config key or the file stem — never from the manifest's own `label`, which is a string the workspace under judgement wrote and could choose to make reassuring.
- **"Don't trust" is focused**, so a reflexive `Enter` declines. `Esc` routes to the same button.

### Untrusted is restricted, not broken

Declining doesn't refuse to open the workspace. Suppression is surgical — only the exec-bearing keys are dropped from the workspace layer:

- Your global language servers, formatters and debug adapters keep working.
- The same `.mnml/config.toml`'s theme, keymaps and editor settings still apply.
- An untrusted `[lsp.rust]` that only widens `extensions` still applies against the global binary; only its `cmd` / `args` are stripped.
- Editing, git, search and the HTTP client are untouched.

A `RESTRICTED` chip appears in the statusline so a language server that isn't running reads as a decision you made rather than an mnml bug. Click it to reopen the dialog.

### Fingerprinting

Trust is recorded as `(canonical path, fingerprint)`, where the fingerprint covers the exec-bearing claims only:

```toml
# ~/.config/mnml/trusted_workspaces.toml
# Workspaces you've allowed to run programs declared in their
# own .mnml/ config (language servers, formatters, startup
# commands). Key = canonical path, value = a fingerprint of
# what was approved — if the workspace's config changes,
# mnml asks again. Delete a line to revoke.

"/Users/you/Projects/mnml" = "9f2c1ab4e05d7731"
```

That shape produces three properties:

- **A later `git pull` re-prompts.** Trusting the repo today doesn't bless a command someone adds tomorrow — the claims change, the fingerprint changes, and mnml asks again.
- **Cosmetic edits don't re-prompt.** Switching the theme in the same file leaves the fingerprint alone.
- **A symlink can't launder a directory into a trusted one.** The key is canonicalized before lookup.

The store lives in your user config directory, never in the workspace — a trust record inside `.mnml/` would be writable by the very repo it's meant to gate. The digest is FNV-1a, chosen deliberately: it exists to notice *change*, not to authenticate. Anyone who can forge a fingerprint match can already edit the config, which is the thing being gated.

### Reviewing and revoking

```vim
:workspace.review_trust
```

Palette title: *"Workspace: review what this workspace is allowed to run"*. It opens the same claim list either way, and only the buttons differ:

| State | Buttons | What `Enter` / `Esc` do |
|---|---|---|
| Not yet trusted | `Trust` / `Don't trust` | Nothing changes |
| Already trusted | `Revoke` / `Keep trusted` | Nothing changes |

The review pair reads back-to-front on purpose. `Esc` routes to the cancel slot, so putting the inert choice there makes a dismissal mean "leave it alone" — and default focus sits on that same slot, so `Enter` is inert too. Revoking takes an explicit `←` / `Tab` then `Enter`.

Revoking is honest about its limit: the config keys were applied at startup and the processes they named may already be running, so the toast reads *"Trust revoked — restart mnml to stop running this workspace's commands."*

Granting trust re-materialises everything the gate suppressed without a restart — config is re-loaded with exec keys honoured, and integration manifests are re-scanned and re-merged in that order.

### Where the gate sits

Every consumer of workspace-supplied exec config routes through one helper (`workspace_trust::is_workspace_trusted`), because the check was open-coded twice and missed once. The miss was real: `LaunchProfiles::load` read `<ws>/.mnml/integrations/<id>.toml` with a plain read, so a repo's `[[launch_profile]] command` still spawned on a chip click *after* the user declined. Three consumers now share the helper — config load, integration manifests, and launch profiles.

Adding a launch profile via a chip menu writes the workspace manifest, which an untrusted workspace won't load; the toast says so rather than reporting plain success.

`--demo` records a real trust entry for the bundled demo fixture (whose integration overrides point Jira / Bitbucket / GitHub at a local mock server) rather than adding a "sandbox implies trusted" bypass. `--sandbox` accepts *any* directory, so a blanket exemption would reopen the hole the gate exists to close.

## What mnml won't send to an AI backend

Inline suggestions (ghost text) ship up to ~3000 characters of buffer context around your cursor to whichever backend you configured. Two rules bound that.

### Ghost text is off until you turn it on

`[ai] inline_suggestions` defaults to **false**. An absent key means the question was never answered, and an unanswered question is not consent — so it reads as off. Three routes turn it on:

- The [first-launch wizard](/manual/first-launch/)'s AI ghost-text section.
- `ai.setup_suggestions` from the palette.
- Settings → AI, or `inline_suggestions = true` in config.

Choosing **Skip for now** in the wizard writes `inline_suggestions = false` *explicitly*, so a decline survives a future change of default. Pressing `Esc` ("ask me later") persists nothing at all — deferring leaves the feature off and the wizard reopens next launch.

### Secret-bearing filenames are excluded regardless

Opting into completions is not opting into uploading a credentials file, so mnml suppresses remote suggestions for files whose *name* looks secret-bearing — independent of the setting, and even for a user who explicitly enabled it:

| Suppressed | Still gets suggestions |
|---|---|
| `.env`, `.env.local`, `.env.production` | `.envrc` (direnv config), `environment.ts` |
| `id_rsa`, `id_ed25519`, any `id_*` | `id_rsa.pub` and anything else ending `.pub` |
| `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.ppk`, `*.jks`, `*.keystore` | `keyboard.rs` |
| anything containing `credential` or `secret` | `env/config.rs` (directory names don't count) |
| `.netrc`, `.pgpass`, `.htpasswd`, `.npmrc`, `.pypirc`, `.dockercfg` | ordinary source files |

Matching is on the file name, not the path, so a directory called `env/` doesn't blanket-suppress the feature. The list is conservative by design — a false positive costs you one missing suggestion, a false negative uploads a secret.

The **local FIM backend is exempt**: `mnml-fim-engine` runs in-process, nothing leaves the machine, and suppressing there would cost you completions for no benefit.

### The API key mnml deliberately drops

`$ANTHROPIC_API_KEY` is removed from the environment of every `claude` / `codex` spawn — the two AI stream paths, the natural-language-to-curl client, and every Pty pane. Claude Code prefers an inherited API key over your claude.ai login, so a key exported in your shell silently billed the metered API for work your Max/Pro subscription already covers.

The scrub **removes** the variable rather than blanking it (an empty-string key is still an auth source and would fail closed). It runs *before* an integration's `[env]` is applied, so an integration that explicitly declares the key in its `[auth_values]` still wins.

### The AI approval gate

When an agentic AI run wants to execute a shell command, the confirm dialog renders the **whole** command, hard-wrapped across lines. It used to reuse the transcript's summary, which cuts at 77 characters — so you approved `sh -c` on text you couldn't finish reading, and a model could put something innocuous in the visible head. Wrapping is hard rather than word-based specifically so a `| sh` with no space to break on can't be silently dropped, control characters are neutralised, and a 4000-character ceiling (disclosed in the dialog) stops a pathological input producing a dialog taller than the terminal.

Token entry is masked. `ai.link_claude_token` takes a blob carrying a long-lived refresh token; the prompt renders one bullet per character, preserving caret column and scroll window. It's display-only — paste and submit see the real text.

## Files at rest

### Owner-only writes

Everything mnml writes that can carry a credential goes out at mode `0600`:

- Integration manifests (their `[auth_values]` tokens) **and their timestamped backups**.
- The cookie jar.
- HTTP request history — both the workspace log and the global cross-workspace mirror.
- Captured browser traffic (`.rqst/captured/log.jsonl`).
- Agent transcript exports (verbatim shell lines).
- Auth presets (`.mnml/auth/*.txt` are literal `Authorization` values) and both env-file writers.
- The IPC channel's five files: `command`, `screen.txt`, `status.json`, `events.jsonl`, `rects.json`.

The writer does more than open with a mode. `.mode(0o600)` applies only at *creation*, so an existing 0644 file silently keeps it — which is the state every install that predates this change is in. So the helper opens at 0600 (no create-then-chmod window for new files) **and** explicitly tightens when the file already existed. Backups are tightened too: `fs::copy` propagates the source's mode, so backing up a pre-0600 manifest would faithfully reproduce its 0644, leaving readable copies of a token you'd just cleared.

`.gitignore` is deliberately excluded — it's a tracked repo file and *should* be world-readable. Windows has no umask or POSIX mode bits; these calls degrade to a plain write there.

### Auto-gitignore

On first creation of `.mnml/` in a git repo, mnml appends the state directories to the workspace's `.gitignore`:

```
.mnml/
.rqst/
```

`.rqst/` is the HTTP client's original home and is still live — request history, captured traffic, `env/` values, lookups. It's added only once it exists, so a repo that never touches the HTTP client doesn't get a stray line. The check tolerates the usual spellings (`x`, `x/`, `/x`, `/x/`, `x/**`) and is idempotent.

Deliberately **not** ignored: `.curl` / `.http` / `.rest` request files. Those are user-authored API definitions — committing them is the point of a collection — and they reference secrets through `{{VAR}}` rather than embedding them.

If `.gitignore` is a symlink, mnml refuses to touch it and prints a message telling you to add the entries yourself. That's the opposite call from the IPC scratch files, which are unlinked and recreated: `.gitignore` is your content, the IPC files are mnml's.

### History redaction

HTTP history has to stay replayable — the picker rebuilds a runnable curl from it — so blanket redaction would trade one problem for a broken feature. Instead, for sensitive headers and bodies mnml persists the **unexpanded** form:

```
Authorization: Bearer {{TOKEN}}     ← what lands on disk
```

Replay re-expands it against the active env, so the entry stays runnable and no secret is written. Only a hard-coded literal gets `<redacted by mnml>`, because there is no way to keep that replayable without storing it.

Sensitive headers: `authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key`, `x-auth-token`, `x-amz-security-token`, `x-csrf-token`. Everything else (`Accept`, `Content-Type`) is stored expanded, where it's far more useful.

Bodies get the same unexpanded preference plus a textual scrub of well-known credential field names — `password`, `passwd`, `secret`, `client_secret`, `access_token`, `refresh_token`, `id_token`, `api_key`, `private_key`, `token` — which catches literals the template path can't.

### The IPC screen dump

`screen.txt` is a verbatim copy of the rendered UI, rewritten roughly ten times a second. That includes an open `.env`, an `Authorization` header in a Request pane, or a token pasted into a prompt.

It is **off by default**:

```toml
# ~/.config/mnml/config.toml
[ipc]
write_screen = true   # default false
```

The audit that settled the default is worth knowing, because it looks like a developer-hostile choice: `./run.sh restart` only *writes* to the `command` mailbox and never reads the screen; the `.test` harness and every bug-hunt agent run headless, where the flag is forced on regardless. The remaining readers are all mnml's own development tooling. Defaulting on made every user pay for a benefit only the people best placed to set a config key received.

The gate is narrow — only `screen.txt`. The command mailbox, `status.json`, `events.jsonl` and `rects.json` are untouched, so `./run.sh restart` and every `mnml-bridge` integration keep working. Headless mode forces the flag on at startup, because `screen.txt` *is* its output.

### The IPC symlink guard

Git preserves symlinks, so a cloned repo can ship `.mnml/ipc/screen.txt` pointing at `~/.zshrc` — and the screen writer would truncate that target and keep overwriting it. mnml checks all four IPC files at init and unlinks any symlink before recreating it as a regular file. They're mnml-owned scratch with no user content to lose; refusing outright would brick the channel for the session.

## Where mnml keeps your data

`data_root()` is the single accessor for everything user-scoped — config, integrations, glyph cache, marketplace cache, the trust store. Resolution order:

1. **`MNML_DATA_ROOT`** — when set and non-empty, it wins outright and all other resolution is skipped. Useful for a per-shell mnml (`MNML_DATA_ROOT=/tmp/mnml-scratch mnml`) and for hermetic test runs.
2. **Portable mode** — `<binary_dir>/mnml-data/`, but only when it contains a `.opted-in` marker file.
3. **`$XDG_CONFIG_HOME/mnml/`** — when the variable is set and that location actually has state (or neither location does, in which case a new install respects your stated preference).
4. **`$HOME/.config/mnml/`** — the standard fallback.
5. `./mnml` — degenerate, only when there's no `HOME` at all.

### Portable mode

Portable mode keeps every user-scoped file next to the mnml binary instead of in `$HOME` — for USB sticks, restricted-`HOME` Windows setups, "try before you install" runs, and pinning data to a specific version.

The two-file gate is the point: a folder named `mnml-data/` next to the binary is *not* enough. Without `.opted-in`, mnml reports the state as awaiting consent (the first-run overlay defaults its choice to Portable and creates the marker if you accept) but keeps resolving to `HOME` until you say yes. An accidentally-named folder can't silently redirect your data.

`activate_portable()` creates the folder, the `.opted-in` gate, and the per-user choice marker. The process caches its portable-vs-home answer at first probe, so a restart is required after switching. `/version` and About report which layout you're in (`portable` / `normal`) so a bug report can say which store its files came from.

`--sandbox` is a different thing: it redirects `HOME` to a tempdir (re-execing itself to do so) and GCs stale sandbox roots, so the entire surface — config, glyphs, sessions, marketplace cache — is throwaway.

## Integration credentials

The full flow for declaring and entering integration auth lives in [Integration auth](/manual/integrations/auth/). Two behaviours belong here.

### Values are injected at spawn, not read by mnml

Stored `[auth_values]` reach a sibling as environment variables under each field's `env_fallback` name, applied when the Pty spawns. mnml itself never reads the token. A Pty that was already open when you saved a value doesn't see it — close it and re-fire the command.

### Cross-integration sharing is scoped to auth-declaring receivers

Many siblings read an env var another sibling owns — Jira's Fix Versions view reads the token Bitbucket configures. So mnml injects *every* installed integration's stored values, not just the firing one, which spares you typing the same token twice.

The rule that bounds it: **an integration receives the shared pool only if its own manifest declares at least one `[[auth]]` field.** Declaring no credentials is a statement that you need none.

That gate exists because `run_external_tool` stamps an integration id on a Pty purely so the pane tab can resolve a chip glyph — which meant launching `htop`, `btop`, `ncdu`, `lazygit`, `gh` or `dust` handed that process `$SLACK_BOT_TOKEN`, `$JIRA_API_TOKEN`, `$BITBUCKET_ACCESS_TOKEN` and friends. `htop` displays process environments; `lazygit` runs arbitrary git hooks.

If an integration genuinely consumes a foreign token but declares no auth of its own, it should declare an `[[auth]]` field naming that `env_fallback`. The *value* still comes from whichever integration stores it, so you never enter it twice. A shell `export` also still reaches the child — this governs only what mnml injects.

Precedence inside the injection: the firing integration's own values win, then the shared pool in load order, and empty stored values are skipped entirely so clearing a field falls back to your shell export rather than wiping it with an empty string.

## The Sonos stream server

The [Sonos](/manual/sonos/) loopback path runs a short-lived HTTP server that serves an mp3 encode of your Mac's system output, because that's how you tell a speaker to fetch a URL. Two constraints apply while it's live:

- It binds to **one interface** — the address already computed for the URL — rather than `0.0.0.0`. VPNs, secondary NICs and container bridges are dropped.
- It **checks the peer** and serves only the player. mnml sends `play_uri` to the group *coordinator*, which fetches and redistributes to the group, so a single allowed peer is correct for grouped rooms too. It fails closed: if the peer address can't be read, the answer is no.

The port is observable on the wire (the URL goes to the player over unencrypted UPnP), which is why the peer check exists at all rather than relying on the port being unguessable.

## Next

- [Integration auth](/manual/integrations/auth/) — the `[[auth]]` schema, the Configure… pane, and the first-hit guard
- [First-launch wizard](/manual/first-launch/) — where the ghost-text and AI-routing consent decisions are made
- [Settings & configuration](/manual/settings/) — the full TOML schema, including `[ipc]` and `[ai]`
- [Headless & .test](/manual/headless/) — the IPC channel these hardening rules apply to
- [AI panes](/manual/ai-panes/) — what the AI surface sends, and which backend runs where
