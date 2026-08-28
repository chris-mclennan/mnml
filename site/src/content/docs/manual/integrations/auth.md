---
title: Integration auth
description: How mnml integrations declare their auth needs via `[[auth]]`, how users fill them in via the per-integration Settings pane, and how the values reach the sibling process as env vars at Pty spawn time.
---

Every integration that talks to a backend needs credentials — Slack wants a bot token, Bitbucket wants an app password, Jira wants a site URL + email + API token. The old answer was: edit your shell rc file, `export SLACK_BOT_TOKEN=...`, restart your shell, hope. mnml's answer is a **`[[auth]]` block in the manifest, a Configure… pane in the UI, and env-var injection at spawn time** — three moving parts that mean typing a token into mnml is enough for the sibling to see it.

This is a v0.2.11-onward flow. Manifests written against `mnml-bridge` 0.6 and earlier don't declare `[[auth]]`; those integrations still work — they just fall back to reading env vars from your shell the way they always did. Adding auth is opt-in per sibling.

## The three pieces

| Piece | Owned by | Lives at |
|-------|----------|----------|
| **Schema** — declares what fields the integration needs | The sibling author | `[[auth]]` blocks in the manifest TOML |
| **Values** — what the user typed | The user (via the Settings pane) | `[auth_values]` at the top of the same manifest TOML |
| **Injection** — reaches the sibling as env vars at spawn | mnml core | `open_pty_dir` merges into `BinaryProfile.env` |

The three pieces are decoupled: a sibling can declare fields without shipping any code changes (mnml drives the form), a user can save values into a manifest that has no schema (mnml warns), and env-var injection is silent — the sibling doesn't have to know about mnml's Settings pane, it just reads `$SLACK_BOT_TOKEN` like it always did.

## The `[[auth]]` schema

Sibling authors declare their auth needs via `mnml-bridge`'s `AuthField` type (0.7.0+). At install time (`<sibling> --install`), the SDK writes them into the manifest as an array of `[[auth]]` blocks:

```toml
# ~/.config/mnml/integrations/slack_channels.toml
id    = "slack_channels"
label = "Slack channels"
# ... chip, commands, etc.

[[auth]]
key          = "bot_token"
label        = "Slack bot token"
kind         = "secret"
env_fallback = "SLACK_BOT_TOKEN"
help_url     = "https://api.slack.com/apps"
help         = "Copy the Bot User OAuth Token."
required     = true

[[auth]]
key          = "team_id"
label        = "Team ID (optional)"
kind         = "text"
env_fallback = "SLACK_TEAM_ID"
required     = false
```

Field reference (from `src/integration_manifest.rs`):

| Field | Type | Meaning |
|-------|------|---------|
| `key` | string | Required. What the value is stored under in `[auth_values]`, and the name the sibling would look it up by in the manifest. |
| `label` | string | Required. Human name in the Configure… pane (e.g. *"Slack bot token"*). |
| `kind` | string | `"secret"` (masked as bullets) / `"text"` / `"number"` / `"url"` / `"email"`. Defaults to `"text"`. |
| `env_fallback` | string \| null | The env-var name mnml injects the stored value under at Pty spawn. Also read as a fallback source when the pane opens. |
| `help` | string \| null | One-line description under the label. |
| `help_url` | string \| null | Rendered as a clickable *"Get one: <url>"* row under the value. |
| `required` | bool | When `true`, an integration command dispatched without a stored value AND no `env_fallback` env var set intercepts and opens the Configure… pane. See [first-hit guard](#first-hit-guard) below. |

The `kind` field is a rendering + storage hint today; Phase 4 will swap plaintext for OS-keychain backing (Keychain / libsecret / DPAPI) for `secret`-kind values without changing the schema. Same declaration, opaque backend upgrade.

### Authoring auth in a sibling

If you're building an integration and need auth (see [Building integrations](/manual/integrations/building/)), the additive change is one field on `IntegrationSpec`:

```rust
use mnml_bridge::{AuthField, IntegrationSpec, install_integration};

install_integration(&IntegrationSpec {
    id: "slack_channels".into(),
    // ... existing fields
    auth: vec![
        AuthField {
            key: "bot_token".into(),
            label: "Slack bot token".into(),
            kind: "secret".into(),
            env_fallback: Some("SLACK_BOT_TOKEN".into()),
            help_url: Some("https://api.slack.com/apps".into()),
            help: Some("Copy the Bot User OAuth Token.".into()),
            required: true,
        },
    ],
    ..Default::default()
})?;
```

Then your sibling reads `std::env::var("SLACK_BOT_TOKEN")` the way it always did — the pane user experience is fully additive on top of the existing env-var contract.

Requires `mnml-bridge = "0.7"`. 0.6 manifests continue to serialize identically (both `auth` and `AuthField` fields use `skip_serializing_if` / `#[serde(default)]`), so bumping the dep isn't a breaking change even without declaring auth.

## The Configure… pane

Right-click any integration chip. If the manifest declares `[[auth]]`, the context menu includes a **Configure…** row between *Edit…* and the built-in-launcher override. The row is surfaced conditionally — integrations with no auth block don't show it at all:

```rust
// src/app/context_menus.rs
let has_auth = self
    .integration_manifests
    .iter()
    .any(|m| m.id == id && !m.auth.is_empty());
if has_auth {
    items.push(MenuItem::new("Configure…", MenuAction::ConfigureIntegration(id.clone())));
}
```

Clicking the row opens the per-integration Settings pane — a centered modal (74 chars wide, matches the [first-launch wizard](/manual/first-launch/) card), one section per `[[auth]]` field, with a footer key-hint row:

```
╭───── Configure `slack_channels` — Ctrl+S save, Esc close ─────╮
│                                                                │
│  ▸ Slack bot token *                                           │
│    Copy the Bot User OAuth Token.                              │
│    ••••••••••••••••••••••••••••                                │
│    Get one: https://api.slack.com/apps                         │
│    Env fallback: $SLACK_BOT_TOKEN — not set                    │
│                                                                │
│    Team ID (optional)                                          │
│    (unset — Enter to configure)                                │
│    Env fallback: $SLACK_TEAM_ID ✓ set                          │
│                                                                │
│    [↑↓] move  · [Enter] edit  · [Ctrl+S] save  · [Esc] close  │
╰────────────────────────────────────────────────────────────────╯
```

Each field row renders:

- **Label** with a `▸` marker when focused; a trailing `*` when the field is `required = true`.
- **Help** on a dim second row (if the schema sets it).
- **Value** — masked as bullets (`•`) when `kind = "secret"`, plaintext otherwise. Unset fields render `(unset — Enter to configure)` in orange.
- **`Get one:` link** (if `help_url` is set) on a dim row.
- **`Env fallback:`** annotation showing whether the declared env var is currently set in mnml's process env — a quick sanity check for users transitioning from shell exports.

### Keys

The pane has two modes: NAV (default) and EDIT (while typing into a field).

| Mode | Key | Action |
|------|-----|--------|
| NAV | `↑` `↓` / `j` `k` | Move focused field |
| NAV | `Enter` | Begin editing the focused field |
| NAV | `Ctrl+S` | Save all fields to `[auth_values]`, close the pane, toast |
| NAV | `Esc` | Close without saving (in-progress edits are already committed via the Enter step) |
| EDIT | *printable* | Append to the buffer |
| EDIT | `Backspace` | Delete one char from the end |
| EDIT | `Enter` | Commit the edit, return to NAV |
| EDIT | `Esc` | Cancel the edit, restore the value the field had on edit-mode entry, return to NAV |

Editing is greedy — every printable key while a field is active gets appended to the buffer, even chars that would normally be mnml chords (there's no way to fire commands while editing a field). The pane's own Ctrl+S is the only Ctrl chord routed while a field is open.

Cursor tracking is end-of-buffer only in this phase — there's no in-field arrow-key navigation. If you paste a token and want to trim it, `Esc` and re-type.

### Where values live

Values are saved back to the top of the same manifest file under `[auth_values]`:

```toml
# ~/.config/mnml/integrations/slack_channels.toml
id    = "slack_channels"
label = "Slack channels"

[[auth]]                   # ← declared by the sibling
key = "bot_token"
kind = "secret"
env_fallback = "SLACK_BOT_TOKEN"
required = true

[auth_values]              # ← written by mnml on Ctrl+S
bot_token = "xoxb-..."
```

Save is an in-place TOML merge — the schema (`[[auth]]`), the chip (`[chip]`), commands (`[[commands]]`), and any other manifest fields are preserved. Only the `[auth_values]` table gets rewritten. Comments elsewhere in the file are preserved too; comments in the `[auth_values]` block itself are lost, since it's a mnml-managed table.

Empty values are pruned — if you clear a field to blank and save, the key is removed from `[auth_values]` entirely rather than stored as an empty string. This matters for the fallback story below.

## Precedence at open

When the pane opens for a field, mnml populates the input with (in order):

1. The value in `[auth_values][field.key]` if it exists and is non-empty.
2. The value of the env var named by `env_fallback` if that env var is set in mnml's own process env.
3. Empty string.

So a user with `SLACK_BOT_TOKEN` already exported in their shell rc sees their existing token pre-filled (masked) in the pane on first open. Saving it there de-duplicates the storage but doesn't break the shell export.

## Pty env-var injection

The point of `env_fallback` isn't just for the pre-fill. At Pty spawn time, mnml walks every installed manifest's `[auth_values]` block and injects the stored values as env vars under their `env_fallback` names. From `src/app/mod.rs::open_pty_dir`:

```rust
if let Some(integ_id) = profile.integration_id.clone() {
    let auth_env = self.integration_auth_env(&integ_id);
    for (k, v) in auth_env {
        if !profile.env.iter().any(|(pk, _)| pk == &k) {
            profile.env.push((k, v));
        }
    }
}
```

The `integration_auth_env` builder walks in two passes:

1. **Pass 1 — every OTHER installed integration** with `[[auth]]` fields whose `env_fallback` is set and whose `[auth_values]` entry is non-empty. Lower priority — first-writer wins on env-var collisions across integrations. **Skipped entirely unless the receiving integration declares at least one `[[auth]]` field of its own** (see below).
2. **Pass 2 — the CURRENT integration's** auth values. Overwrites any conflicting keys from pass 1.

Cross-integration sharing exists because many siblings read env vars that another sibling owns — Jira's "Fix Versions" view reads `$BITBUCKET_ACCESS_TOKEN` that the Bitbucket sibling configures; git-adjacent tools read `$GITHUB_TOKEN` that the GitHub sibling configures. Without pass 1, each consuming sibling would have to redeclare every foreign env var in its own `[[auth]]` block, and users would type the same token twice.

### Who receives the shared pool

Pass 1 answers "which env-var *names* may be shared". The receiver gate answers "which *spawns* may receive them", and it exists because `run_external_tool` stamps an integration id on a Pty purely so the pane tab can resolve a chip glyph — which meant launching `htop`, `btop`, `ncdu`, `lazygit`, `gh` or `dust` handed that process every credential mnml holds. `htop` displays process environments; `lazygit` runs arbitrary git hooks.

**An integration receives the foreign pool only if its own manifest declares `[[auth]]`.** Declaring no credentials is a statement that you need none. The case the cross-share was built for is preserved — `jira_fix_versions.toml` does declare `[[auth]]` — while `btop` / `iftop` / `browser` / `vscode` / `github` / `amplify` / `codebuild`, which declare none and reference no env var in their manifests, lose nothing they were using.

If your integration genuinely consumes a foreign token but declares no auth of its own, declare an `[[auth]]` field naming that `env_fallback`. The value still comes from whichever integration stores it, so the user never enters it twice. A shell `export` also still reaches the child — this governs only what mnml injects.

Values collide with the caller's `BinaryProfile.env` only for keys the caller hasn't already pushed — an explicit `profile.env.push(("SLACK_BOT_TOKEN", "override"))` from user code (rare) still wins. In practice mnml only pushes bridge env vars (`MNML_WORKSPACE`, `MNML_THEME`, `MNML_IPC_DIR`) before this step, so auth injection is unrestricted.

**Empty stored values are skipped.** If a user cleared a Configure… pane field to blank and saved (which removes the key from `[auth_values]`), the sibling falls back to whatever the user has exported in their shell — mnml doesn't wipe an existing shell-level export by injecting an empty string.

**Rust's `Command::envs`** overrides any inherited process env by key. So a value set in the pane wins over the user's shell export when both are present, even though pass 2 above merges them into the same map — the map's stored value is what mnml passes to the child, and the child sees exactly that.

### Effect for the three pilot siblings

The three siblings that shipped with auth blocks in 0.2.11:

| Sibling | Field(s) | Env vars injected |
|---------|----------|-------------------|
| `mnml-msg-slack` 0.1.3+ | `bot_token`, `team_id` | `$SLACK_BOT_TOKEN`, `$SLACK_TEAM_ID` |
| `mnml-forge-bitbucket` 0.3.3+ | `app_password`, `username` | `$BITBUCKET_APP_PASSWORD`, `$BITBUCKET_USERNAME` |
| `mnml-tracker-jira` 0.2.2+ | `site_url`, `email`, `api_token` | `$JIRA_URL`, `$JIRA_EMAIL`, `$JIRA_API_TOKEN` |

Sibling code doesn't have to change — they still read the env vars they always did. The pane just replaces "edit your .zshrc and restart your shell" with "type it here, done".

## First-hit guard

If a user fires an integration command (via palette, keybinding, or chip click) whose manifest declares a `required = true` field with no stored value and no env-fallback env var set, mnml intercepts the dispatch and opens the Configure… pane instead of silently failing.

From `src/app/mod.rs::run_dynamic_command`:

```rust
if let Some(integration_id) = self
    .integration_manifests
    .iter()
    .find(|m| m.commands.iter().any(|c| c.id == id))
    .map(|m| m.id.clone())
    && self.integration_has_missing_required_auth(&integration_id)
{
    self.toast(format!("`{integration_id}` needs setup — opening Configure…"));
    self.open_integration_settings(&integration_id);
    return true;
}
```

`integration_has_missing_required_auth` returns true when any of the manifest's required fields has neither:

- a non-empty value in `[auth_values][key]`, nor
- a non-empty value in the env var named by `env_fallback` (if set).

Optional fields (`required = false`) don't trip the guard — an integration can partially work with just its required credentials configured.

After Ctrl+S in the pane, the user re-fires the command manually. This is deliberate — the pane close doesn't auto-retry, because the pane close might be Esc (cancel) rather than Save. Toast tells them why: *`slack_channels needs setup — opening Configure…`*.

## The `integrations.configure_picker` command

For the "I know I need to configure something but I don't remember which chip" case, there's a palette command:

```vim
:integrations.configure_picker
```

Title in palette: *"Configure integration auth… (pick from installed)"*.

It enumerates every installed integration whose manifest declares `[[auth]]` and picks based on the count:

- **Zero matches** — toasts *"No installed integration declares auth fields yet. Right-click a chip → \"Configure…\" once one does."*
- **One match** — opens the Configure… pane for it directly.
- **Two or more** — opens a `PickerKind::IntegrationConfigure` picker (each row: id + label + description, or the count of fields if no description). Enter accepts and opens the pane.

The picker is the same fuzzy-picker surface every other `PickerKind::*` uses — type to narrow, `↑` / `↓` to move, `Enter` to accept, `Esc` to cancel. See the palette for what the row density looks like.

## Interaction with other modals

The Configure… pane stands down if a prompt, picker, or context menu is on top — those take Esc-precedence so you can dismiss the smaller thing first. Otherwise the pane is drawn last, with a full-screen dim backdrop so tree / editor content doesn't bleed past its right edge.

Only one integration's pane can be open at a time. Opening it for a different integration while one is already open closes the first, discards its in-progress edits, and opens the new one. Save-before-switch isn't automatic; use `Ctrl+S` if you want to commit.

## Storage security

Values are stored as plaintext in the manifest file today. Three guardrails:

- **The Configure… pane never re-renders `secret`-kind values in plaintext.** They're masked as bullet chars (`•`), capped at 40 to avoid leaking token-length metadata. This holds for values just typed in (edit-mode still masks) and for values loaded from the manifest.
- **Manifests are written owner-only (`0600`)**, and so are the timestamped backups mnml keeps when it rewrites one. The backups matter as much as the live file — clearing a token from the Configure… pane would otherwise leave readable copies of it behind. Files left at `0644` by an older mnml are tightened on the next write. See [Security & hardening](/manual/security/#owner-only-writes).
- **A workspace-supplied manifest is gated by [workspace trust](/manual/security/#workspace-trust)** before its commands, launch profiles or `[env]` are honoured at all.

Phase 4 will migrate `secret`-kind values into the OS keychain (macOS Keychain, Linux libsecret, Windows DPAPI) using the same schema — the `[auth_values]` file becomes an opaque handle, the keychain holds the actual token. Manifest-authored declarations don't change.

For now, if you'd rather keep tokens outside the manifest, leave the field blank in the pane and rely on the `env_fallback` shell export — the sibling still gets the value, and mnml never touches the storage.

## Troubleshooting

**Right-click doesn't show Configure…** — the integration's manifest doesn't declare any `[[auth]]` fields. Either the sibling hasn't opted into the schema yet (see [Building integrations](/manual/integrations/building/)) or you're right-clicking a launcher-style chip that doesn't need auth.

**Save writes an empty `[auth_values]` block** — every field is blank. Clearing a field to blank prunes its key on save, so `[auth_values]` may end up as `{ }` if you've cleared them all. Save is still a no-op that closes the pane; the env-injection walk skips the empty table.

**Sibling still says "not authenticated" after I saved** — env-var injection happens at Pty spawn time, not at save. Close the Pty pane (`Ctrl+D` inside, or the tab's close button) and re-fire the integration command; the fresh Pty gets the newly-saved values.

**Pre-fill shows my env var, but the sibling I already had running doesn't see it** — Pty spawn is the injection boundary. A Pty that was already open before you saved a value doesn't get the value; only new Pty spawns see auth env.

**First-hit guard opened the pane and I saved, but nothing happened** — save doesn't auto-retry the intercepted command. Re-fire it manually. If it intercepts again, one of the required fields still resolves empty — check the *Env fallback:* row on each field.

## Next

- [Integrations overview](/manual/integrations/overview/) — the "two flavors + one on-disk shape" model this auth schema slots into.
- [Installing integrations](/manual/integrations/installing/) — Marketplace tab, precedence, sidecar overrides; auth values are stored on the base manifest, not the override.
- [Building integrations](/manual/integrations/building/) — how a sibling declares `[[auth]]` via `mnml-bridge`.
- [Launcher manifests](/manual/integrations/launcher-manifests/) — the full manifest schema `[[auth]]` extends.
- [First-launch wizard](/manual/first-launch/) — the companion one-time setup flow for mnml itself.
