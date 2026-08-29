//! AI usage meters — Claude Code (Max subscription OAuth quota) +
//! Codex (local JSONL token telemetry aggregation).
//!
//! Populated by background workers spawned from `App::maybe_refresh_ai_usage`
//! + drained per tick via `App::drain_ai_usage`. Renders as two
//! statusline chips (see `ui::statusline`) gated by each integration
//! icon's `enabled` flag.
//!
//! ## Auth
//!
//! Claude: reads an OAuth token from `~/.config/mnml/ai_token`
//! (written by the `:ai.link_claude_token` palette command — the
//! user pastes their Claude Code OAuth token once). The chip shows
//! `—` until the token file exists.
//!
//! Codex: no auth needed. The Codex CLI logs each turn to
//! `~/.codex/sessions/*.jsonl` (session files, one JSON per line);
//! we sum today's token counts across those files.

use std::path::{Path, PathBuf};
use std::sync::mpsc;

/// One Claude account's usage snapshot — pairs a display `name`
/// with a `ClaudeUsage` payload and a flag marking which account
/// the current mnml session is "actually running as" (used by the
/// statusline chip's default single-account rendering). Task #944
/// (2026-08-16) added multi-account tracking so the user can see
/// per-account % without account-switching.
///
/// 2026-08-16 identity extension — `email` and `org_name` are
/// populated best-effort from Anthropic's `/api/oauth/profile`
/// endpoint after a successful usage fetch (see
/// `fetch_claude_profile_best_effort`). A profile-fetch failure is
/// non-fatal (usage still returns); the fields simply stay `None`
/// and the render layer falls back to the account's display name.
#[derive(Debug, Clone, Default)]
pub struct ClaudeAccountUsage {
    pub name: String,
    pub usage: ClaudeUsage,
    pub is_active: bool,
    /// e.g. `"you@example.com"`. `None` when the identity endpoint
    /// isn't reachable, returned non-2xx, or was never queried
    /// (e.g. after a usage-fetch failure).
    pub email: Option<String>,
    /// e.g. `"Anthropic"` or `"you@example.com's Organization"`.
    /// Same `None` semantics as `email`.
    pub org_name: Option<String>,
}

/// Last-fetched snapshot for the Claude chip. `percent` is the 5-hour
/// window utilization; `weekly_percent` is the weekly window.
/// `resets_at` is a Unix timestamp when the current 5h window ends.
#[derive(Debug, Clone, Default)]
pub struct ClaudeUsage {
    pub percent: u16,
    pub weekly_percent: u16,
    pub resets_at: u64,
    /// Unix timestamp when the 7-day weekly window resets. Used by
    /// the `:ai.usage` panel to show "Resets Aug 10 at 2am" line.
    pub weekly_resets_at: u64,
    /// Per-model weekly limits (`kind == weekly_scoped` entries in
    /// the response). Populated when the user has model-specific
    /// caps (Fable, Opus, Sonnet, etc.).
    pub scoped_limits: Vec<ScopedLimit>,
    pub tokens_5h: u64,
    pub fetched_at: u64,
    pub last_error: Option<String>,
    /// 2026-08-16 — Unix seconds when we should retry after a 429.
    /// Populated from Anthropic's `Retry-After` header (which is a
    /// delta in seconds); the render loop's `maybe_refresh_ai_usage`
    /// skips spawning until `now >= retry_after_at`. Anthropic knows
    /// how long its own block lasts (typical: 30-3600s); honoring
    /// the header beats mnml's fixed 5-min guess in both directions
    /// (shorter for brief blocks, longer for real hour+ blocks).
    /// Zero = no cooldown active.
    pub retry_after_at: u64,
}

/// One entry from the response's `limits[]` array with
/// `kind == weekly_scoped`. Represents a per-model or per-surface
/// weekly cap (e.g. "Current week (Fable)").
#[derive(Debug, Clone, Default)]
pub struct ScopedLimit {
    pub model_display_name: String,
    pub percent: u16,
    pub resets_at: u64,
}

/// Last-fetched snapshot for the Codex chip. Cumulative tokens
/// today across all `~/.codex/sessions/*.jsonl` sessions started
/// today, plus a coarse session count.
#[derive(Debug, Clone, Default)]
pub struct CodexUsage {
    pub tokens_today: u64,
    pub sessions_today: u64,
    pub fetched_at: u64,
    pub last_error: Option<String>,
}

/// Path where the user's Claude Code OAuth token lives after the
/// `:ai.link_claude_token` prompt persists it. Chmod 600. Returns
/// None if the data root can't be resolved (headless / bad env).
///
/// claude-agents-user r3+r4 (2026-08-05/06) — was `env::var("HOME")`
/// directly, bypassing the `data_root()` helper. Under Portable
/// mode that leaked the OAuth token to the real $HOME, defeating
/// the "no HOME footprint" guarantee. Now routes through
/// `crate::data_root::data_root()` like the ~13 other user-scoped
/// file callers migrated in the 2026-07 sweep.
pub fn claude_token_path() -> Option<PathBuf> {
    Some(crate::data_root::data_root().join("ai_token"))
}

pub fn read_claude_token() -> Option<String> {
    let path = claude_token_path()?;
    let raw = std::fs::read_to_string(path).ok()?;
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    // Two accepted formats:
    //   1. Plain access token string (starts with `sk-ant-…`)
    //   2. JSON with `accessToken` (+ optional `refreshToken`,
    //      `expiresAt`) — same shape as Claude Code's keychain
    //      `claudeAiOauth` entry so the user can paste the whole
    //      block instead of digging the accessToken out.
    if s.starts_with('{') {
        let v: serde_json::Value = serde_json::from_str(s).ok()?;
        // Accept either `{claudeAiOauth: {…}}` or a bare
        // `{accessToken: …}` inner object.
        let inner = v.get("claudeAiOauth").unwrap_or(&v);
        let token = inner.get("accessToken")?.as_str()?.trim().to_string();
        if token.is_empty() { None } else { Some(token) }
    } else {
        Some(s.to_string())
    }
}

/// If the on-disk token file is a JSON blob with a `refreshToken`,
/// return it. `None` when the file is a plain-string token or the
/// blob doesn't include a refresh token. Reads from the default
/// single-account path; multi-account callers use
/// [`read_refresh_token_at`] with the account-specific path.
pub fn read_claude_refresh_token() -> Option<String> {
    let path = claude_token_path()?;
    read_refresh_token_at(&path)
}

/// Persist the OAuth token to `~/.config/mnml/ai_token` with 0600
/// perms (owner read/write only). Idempotent — overwrites the
/// existing file if any.
///
/// Accepts EITHER a plain `sk-ant-oat…` access token OR the whole
/// `claudeAiOauth` JSON blob (as pasted from `security
/// find-generic-password -s 'Claude Code-credentials' -w`). Storing
/// the JSON preserves the refresh token so mnml can auto-refresh on
/// 401 without prompting the user daily.
pub fn write_claude_token(token: &str) -> Result<PathBuf, String> {
    let path = claude_token_path().ok_or_else(|| "no $HOME".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {e}"))?;
    }
    // Best-effort: if the input is a JSON blob, pretty-print it so
    // the on-disk file is readable if the user cats it. Otherwise
    // store verbatim.
    let trimmed = token.trim();
    let to_write = if trimmed.starts_with('{') {
        serde_json::from_str::<serde_json::Value>(trimmed)
            .and_then(|v| serde_json::to_string_pretty(&v))
            .unwrap_or_else(|_| trimmed.to_string())
    } else {
        trimmed.to_string()
    };
    // 2026-08-08 (reviewer follow-up) — close the write-then-chmod
    // race. `fs::write` creates at the process umask (usually 0644)
    // BEFORE `set_permissions` narrows to 0600, leaving a brief
    // window where another local user could read the token. Open
    // with the correct mode from the start.
    write_secret_file(&path, to_write.as_bytes())?;
    Ok(path)
}

/// Task #949 — Multi-account-aware token write. Same JSON/plain
/// autodetect as `write_claude_token` but persists to an explicit
/// path instead of the default single-account location. Used by the
/// keychain-resync path on 401 to update whichever token file we
/// were reading from.
pub fn write_claude_token_to(path: &Path, token: &str) -> Result<PathBuf, String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {e}"))?;
    }
    let trimmed = token.trim();
    let to_write = if trimmed.starts_with('{') {
        serde_json::from_str::<serde_json::Value>(trimmed)
            .and_then(|v| serde_json::to_string_pretty(&v))
            .unwrap_or_else(|_| trimmed.to_string())
    } else {
        trimmed.to_string()
    };
    write_secret_file(path, to_write.as_bytes())?;
    Ok(path.to_path_buf())
}

/// Task #949 — Blocking read of the macOS keychain's `Claude Code-
/// credentials` entry, safe to call from a worker thread (never from
/// the UI thread — `security` can pop a GUI auth prompt). Returns the
/// raw password contents (typically the `claudeAiOauth` JSON blob).
/// `None` on any failure — empty output, non-zero exit, missing
/// `security` binary. Callers use this as a best-effort auto-resync
/// after a refresh-token attempt has already failed.
fn read_keychain_claude_token_blocking() -> Option<String> {
    // macOS-only. On other platforms, Claude Code's credential store
    // shape is different and mnml doesn't try to auto-resync there.
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("security")
            .args([
                "find-generic-password",
                "-s",
                "Claude Code-credentials",
                "-w",
            ])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if raw.is_empty() { None } else { Some(raw) }
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// Task #949 — Extract the access token from a possibly-JSON blob.
/// Returns `Some(token)` when the input parses as JSON with an
/// `accessToken` field (Claude Code's keychain shape) or as a plain
/// `sk-ant-…` string. `None` for junk. Same logic as `read_claude_token`
/// but taking a string arg instead of a file path.
fn parse_access_token(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    if s.starts_with('{') {
        let v: serde_json::Value = serde_json::from_str(s).ok()?;
        let inner = v.get("claudeAiOauth").unwrap_or(&v);
        let token = inner.get("accessToken")?.as_str()?.trim().to_string();
        if token.is_empty() { None } else { Some(token) }
    } else {
        Some(s.to_string())
    }
}

/// Create-or-truncate a file with mode 0600 on Unix, using
/// `OpenOptions` so the file never exists at the umask default
/// during the write. Falls back to plain `fs::write` on non-Unix
/// (Windows perms model is different anyway).
fn write_secret_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
            .map_err(|e| format!("open: {e}"))?;
        f.write_all(bytes).map_err(|e| format!("write: {e}"))?;
        f.flush().map_err(|e| format!("flush: {e}"))?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, bytes).map_err(|e| format!("write: {e}"))
    }
}

/// Claude Code's public OAuth client id — the same value the
/// keychain-cached `claudeAiOauth` blob was minted against, so
/// mnml's refresh must present it to Anthropic's token endpoint.
const CLAUDE_OAUTH_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";

/// POST the refresh token to Claude's OAuth token endpoint. On
/// success, writes the new `{accessToken, refreshToken, expiresAt}`
/// JSON blob back to the given path (or the default single-account
/// path when `write_back_path` is None), preserving auto-refresh
/// next cycle, and returns the new access token. Errors bubble up
/// as human-readable strings — the caller falls back to the
/// original 401 message.
fn try_refresh_claude_token(
    client: &reqwest::blocking::Client,
    refresh_token: &str,
    write_back_path: Option<&Path>,
) -> Result<String, String> {
    #[derive(serde::Deserialize)]
    struct TokenResp {
        access_token: String,
        refresh_token: Option<String>,
        expires_in: Option<u64>,
    }
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLAUDE_OAUTH_CLIENT_ID,
    });
    let body_str = serde_json::to_string(&body).map_err(|e| format!("refresh body: {e}"))?;
    let resp = client
        .post("https://console.anthropic.com/v1/oauth/token")
        .header("Content-Type", "application/json")
        .body(body_str)
        .send()
        .map_err(|e| format!("refresh: {e}"))?;
    let status = resp.status();
    let text = resp.text().map_err(|e| format!("refresh body read: {e}"))?;
    if !status.is_success() {
        return Err(format!("refresh HTTP {}", status.as_u16()));
    }
    let tr: TokenResp = serde_json::from_str(&text).map_err(|e| format!("refresh parse: {e}"))?;
    let expires_at_ms = tr
        .expires_in
        .map(|s| (now_unix().saturating_add(s)).saturating_mul(1000))
        .unwrap_or(0);
    let new_refresh = tr.refresh_token.as_deref().unwrap_or(refresh_token);
    let blob = serde_json::json!({
        "claudeAiOauth": {
            "accessToken": tr.access_token,
            "refreshToken": new_refresh,
            "expiresAt": expires_at_ms,
        }
    });
    // Multi-account: write back to the SAME path we read the
    // refresh token from, not the default. Single-account still
    // routes through `write_claude_token` for the default path so
    // its parent-dir creation + secret perms are honored.
    match write_back_path {
        Some(p) => {
            let s = serde_json::to_string_pretty(&blob).unwrap_or_else(|_| blob.to_string());
            let _ = write_secret_file(p, s.as_bytes());
        }
        None => {
            let _ = write_claude_token(&blob.to_string());
        }
    }
    Ok(tr.access_token)
}

/// 2026-08-08 — background lookup of the Claude Code OAuth blob from
/// the macOS Keychain. Ctrl+K in the LinkClaudeToken prompt used to
/// shell out to `security` synchronously on the event-loop thread —
/// macOS can pop an auth-prompt modal here that blocks indefinitely,
/// freezing the whole TUI. Same shape as `spawn_claude_fetch`: worker
/// thread + mpsc; drained by the per-tick `drain_pending_keychain`.
///
/// Returns an mpsc Receiver — poll via `try_recv`. Ok(String) is the
/// raw `claudeAiOauth` JSON blob (or the whole password field, if the
/// user's Keychain entry stores something else). Err carries a short
/// human-readable message for a toast.
pub fn spawn_keychain_claude_token() -> mpsc::Receiver<Result<String, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = match std::process::Command::new("security")
            .args([
                "find-generic-password",
                "-s",
                "Claude Code-credentials",
                "-w",
            ])
            .output()
        {
            Ok(out) if out.status.success() => {
                let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if raw.is_empty() {
                    Err("keychain returned empty — is Claude Code auth'd?".to_string())
                } else {
                    Ok(raw)
                }
            }
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                Err(format!(
                    "keychain lookup failed: {}",
                    stderr.trim().lines().next().unwrap_or("unknown error")
                ))
            }
            Err(e) => Err(format!("could not run `security`: {e}")),
        };
        let _ = tx.send(result);
    });
    rx
}

/// #1150 (2026-08-23) — spawn a background reader that pulls the
/// current Claude Code Keychain blob and returns just its refresh
/// token. Used to autodetect which configured account is the LIVE
/// Claude Code CLI login — the manual `active = true` config flag
/// drifted whenever a user switched Claude Code accounts without
/// touching mnml's config.toml.
///
/// Threaded because `security find-generic-password` can prompt for
/// permission (macOS) and blocks the calling thread until the user
/// clicks Allow. `Ok(None)` = Keychain returned a plain-string token
/// (no refreshToken to compare against); `Err` = tool failure. Both
/// leave the caller's cache untouched.
pub fn spawn_keychain_active_refresh_token() -> mpsc::Receiver<Result<Option<String>, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = match std::process::Command::new("security")
            .args([
                "find-generic-password",
                "-s",
                "Claude Code-credentials",
                "-w",
            ])
            .output()
        {
            Ok(out) if out.status.success() => {
                let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if raw.is_empty() {
                    Err("keychain returned empty — is Claude Code auth'd?".to_string())
                } else {
                    Ok(parse_refresh_token_from_blob(&raw))
                }
            }
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                Err(format!(
                    "keychain lookup failed: {}",
                    stderr.trim().lines().next().unwrap_or("unknown error")
                ))
            }
            Err(e) => Err(format!("could not run `security`: {e}")),
        };
        let _ = tx.send(result);
    });
    rx
}

/// Spawn a worker thread to fetch Claude usage from Anthropic's
/// undocumented OAuth-usage endpoint. Returns immediately with a
/// Receiver — poll via `try_recv()` in a per-tick drain. Emits Err
/// with a human-readable message on any failure (network, HTTP
/// status, JSON parse). No token = Err.
///
/// Reads the token from the default single-account path
/// (`data_root()/ai_token`). For the multi-account path see
/// [`spawn_claude_fetch_account`].
pub fn spawn_claude_fetch() -> mpsc::Receiver<Result<ClaudeUsage, FetchErr>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = fetch_claude_blocking();
        let _ = tx.send(result);
    });
    rx
}

/// Task #944 (2026-08-16). Per-account variant of
/// [`spawn_claude_fetch`] — the caller supplies the account's
/// display name (echoed back on the result) plus the on-disk
/// token path so the worker doesn't have to know about the config
/// or the "which account is active" question. Returns a Receiver
/// yielding [`ClaudeAccountUsage`] on success, [`FetchErr`] on
/// failure. `is_active` on the returned account is always false;
/// the caller stamps it based on the config.
pub fn spawn_claude_fetch_account(
    name: String,
    token_path: PathBuf,
) -> mpsc::Receiver<Result<ClaudeAccountUsage, FetchErr>> {
    spawn_claude_fetch_account_of(name, token_path, 1)
}

/// As [`spawn_claude_fetch_account`] plus the configured-account
/// count, which the keychain-resync guard needs to know whether there
/// are sibling accounts it could damage. #1232.
pub fn spawn_claude_fetch_account_of(
    name: String,
    token_path: PathBuf,
    account_count: usize,
) -> mpsc::Receiver<Result<ClaudeAccountUsage, FetchErr>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result =
            fetch_claude_account_blocking_of(&name, &token_path, account_count).map(|usage| {
                // Best-effort identity fetch — must not fail the whole
                // account snapshot if it 404s / times out. Reads the
                // token from the same on-disk file so a fresh refresh
                // (written by the usage fetch) is picked up. See
                // `fetch_claude_profile_best_effort`.
                let profile = std::fs::read_to_string(&token_path)
                    .ok()
                    .and_then(|raw| parse_token_blob(&raw))
                    .and_then(|token| fetch_claude_profile_best_effort(&token));
                // #1232 — this is the ONLY place identity is ever
                // observable, so it is the only place it can be
                // learned. Pin it here and every later write can be
                // checked against it.
                // A collision Err here means several token files are
                // sharing one credential (the #1232 state). Don't pin
                // — an unpinned account is correctly "unproven", and
                // the guard then refuses to write to it.
                if let Some(email) = profile.as_ref().and_then(|p| p.email.as_deref())
                    && let Err(clash) = pin_account_identity(&name, email)
                {
                    eprintln!("mnml: {clash}");
                }
                ClaudeAccountUsage {
                    name: name.clone(),
                    usage,
                    is_active: false,
                    email: profile.as_ref().and_then(|p| p.email.clone()),
                    org_name: profile.and_then(|p| p.org_name),
                }
            });
        let _ = tx.send(result);
    });
    rx
}

/// Read `token_path` and hit Anthropic's OAuth usage endpoint —
/// same wire logic as [`fetch_claude_blocking`] but the token
/// source is an arbitrary file (per-account, chosen by the
/// caller). Multi-account entry point. 2026-08-16.
pub fn fetch_claude_account_blocking(
    name: &str,
    token_path: &Path,
) -> Result<ClaudeUsage, FetchErr> {
    fetch_claude_account_blocking_of(name, token_path, 1)
}

/// As [`fetch_claude_account_blocking`], but told how many accounts
/// are configured so the keychain resync can refuse to cross-write
/// when there are siblings to damage. #1232.
pub fn fetch_claude_account_blocking_of(
    name: &str,
    token_path: &Path,
    account_count: usize,
) -> Result<ClaudeUsage, FetchErr> {
    let raw = std::fs::read_to_string(token_path)
        .map_err(|e| FetchErr::new(format!("read token {}: {e}", token_path.display())))?;
    let token = parse_token_blob(&raw).ok_or_else(|| FetchErr::new("not linked"))?;
    fetch_claude_with_token_for(&token, Some(token_path), name, account_count)
}

/// Public sibling of [`read_refresh_token_at`] — parses a Keychain
/// blob string (JSON with `claudeAiOauth.refreshToken`) and returns
/// the refresh token. Used by mnml's autodetect-active-account logic:
/// the Keychain's refresh token is a stable identity for "which
/// Claude Code account is currently logged in" (unlike accessToken,
/// which rotates hourly). Returns `None` for a plain-string token or
/// any JSON without a refreshToken. #1150 (2026-08-23).
/// Where each configured account's *identity* is pinned, so mnml can
/// tell accounts apart offline. #1232.
///
/// The token blob itself carries no identity — its keys are
/// `accessToken` / `refreshToken` / `expiresAt` /
/// `refreshTokenExpiresAt` / `scopes` / `subscriptionType` /
/// `rateLimitTier`, and nothing more. Identity only ever arrives over
/// the wire, from `/api/oauth/profile`. So we record it the first time
/// a fetch succeeds and treat it as that account's fingerprint from
/// then on.
///
/// Deliberately NOT stored in `config.toml`: this is learned state,
/// not user intent, and #1190 is a standing objection to code silently
/// rewriting the user's config.
fn identity_pin_path() -> PathBuf {
    crate::data_root::data_root().join("ai_account_identity.json")
}

/// `{account name → email}`. Missing/corrupt file reads as empty —
/// a lost pin costs one re-verification, never a wrong write.
pub fn load_identity_pins() -> std::collections::BTreeMap<String, String> {
    std::fs::read_to_string(identity_pin_path())
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

/// The email this account is known to be. `None` until its first
/// successful fetch.
pub fn pinned_email_for(name: &str) -> Option<String> {
    load_identity_pins().get(name).cloned()
}

/// What recording `name = email` should do, given what's already
/// pinned. Pure so the decision is testable without touching disk.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PinDecision {
    /// Already pinned to exactly this — don't churn the file.
    Unchanged,
    /// Safe to record.
    Write,
    /// `email` is already pinned to a DIFFERENT account. Recording it
    /// would leave two accounts claiming one identity, and a
    /// non-unique pin proves nothing — so refuse and name the clash.
    Collision { other: String },
}

pub(crate) fn plan_pin(
    pins: &std::collections::BTreeMap<String, String>,
    name: &str,
    email: &str,
) -> PinDecision {
    if pins.get(name).is_some_and(|p| same_identity(p, email)) {
        return PinDecision::Unchanged;
    }
    if let Some((other, _)) = pins
        .iter()
        .find(|(k, v)| k.as_str() != name && same_identity(v, email))
    {
        return PinDecision::Collision {
            other: other.clone(),
        };
    }
    PinDecision::Write
}

/// Record `name`'s identity, unless another account already claims it.
///
/// The collision case is not hypothetical — it is the state the #1232
/// bug leaves behind. Once several token files hold ONE credential,
/// every one of them fetches successfully and reports the same email.
/// Pinning each in turn would hand all of them the same "proof" of
/// identity, and the guard downstream would then wave through exactly
/// the cross-writes it exists to stop. So the first account to fetch
/// pins; the rest detect the clash, stay unpinned, and are correctly
/// treated as unproven until re-authed.
///
/// Returns `Err(description)` on collision so callers can surface it.
pub fn pin_account_identity(name: &str, email: &str) -> Result<(), String> {
    let email = email.trim();
    if name.is_empty() || email.is_empty() {
        return Ok(());
    }
    let mut pins = load_identity_pins();
    match plan_pin(&pins, name, email) {
        PinDecision::Unchanged => Ok(()),
        PinDecision::Collision { other } => Err(format!(
            "{name} and {other} both report {email} — their token files are \
             sharing one credential. Re-auth {name} (`R` in the Claude usage \
             pane) so it has its own."
        )),
        PinDecision::Write => {
            pins.insert(name.to_string(), email.to_string());
            if let Ok(json) = serde_json::to_string_pretty(&pins) {
                let _ = write_secret_file(&identity_pin_path(), json.as_bytes());
            }
            Ok(())
        }
    }
}

/// Case-insensitive, whitespace-tolerant email comparison — the
/// profile endpoint and a hand-seeded file can disagree on casing.
fn same_identity(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

/// Who does this token blob belong to? Costs one profile round-trip.
/// `None` on any failure, which callers must treat as "unproven" —
/// never as "matches".
fn identity_of_blob(raw: &str) -> Option<String> {
    let token = parse_token_blob(raw)?;
    fetch_claude_profile_best_effort(&token)?.email
}

/// Guard for every write that could replace one account's credential
/// with another's. Returns `Ok(())` only when the blob is *proven* to
/// belong to `name`.
///
/// #1232 — the keychain holds exactly ONE Claude login, and the
/// resync used to write it into whichever account happened to 401.
/// With three accounts configured that converged all three token
/// files onto a single credential (verified: three byte-identical
/// files), so every account reported the same usage and the same
/// email, and the other two accounts' refresh tokens were destroyed —
/// they could not recover without a manual re-seed.
pub fn verify_blob_belongs_to(name: &str, blob: &str, account_count: usize) -> Result<(), String> {
    let pins = load_identity_pins();
    // Whether this is a multi-account install is decided by the live
    // config OR the durable pin record, not config alone. Reviewer
    // catch: `[ai]` is whole-table-replaced across config layers
    // (`config.rs`, `self.ai = v`), so a workspace `.mnml/config.toml`
    // carrying ANY `[ai]` key drops `claude_accounts()` back to the
    // single synthetic "default" — which would silently switch this
    // guard off on a machine that genuinely has several accounts.
    // The pin file remembers what the config momentarily forgot.
    if account_count <= 1 && pins.len() <= 1 {
        return Ok(());
    }
    let Some(pinned) = pins.get(name) else {
        return Err(format!(
            "{name} has no pinned identity yet — refusing to overwrite its token \
             with an unverified blob (it will pin itself on the next successful fetch)"
        ));
    };
    // A pin is only evidence if it is UNIQUE. If two accounts claim
    // one identity their token files are already sharing a credential,
    // and "matches the pin" would wave through the very cross-write
    // this guard exists to stop.
    if let Some((other, _)) = pins
        .iter()
        .find(|(k, v)| k.as_str() != name && same_identity(v, pinned))
    {
        return Err(format!(
            "{name} and {other} are both pinned to {pinned}, so neither pin proves \
             anything — re-auth {name} (`R` in the Claude usage pane) before it can \
             be written"
        ));
    }
    match identity_of_blob(blob) {
        Some(actual) if same_identity(&actual, pinned) => Ok(()),
        Some(actual) => Err(format!(
            "that credential is {actual}, but {name} is {pinned} — not overwriting"
        )),
        None => Err(format!(
            "could not verify which account that credential belongs to — \
             not overwriting {name}"
        )),
    }
}

/// One configured account, as far as the recapture worker cares.
pub struct RecaptureTarget {
    pub name: String,
    pub token_path: PathBuf,
    /// `None` until this account's first successful fetch pins it.
    pub pinned_email: Option<String>,
}

/// #1232 — the smart replacement for the by-hand
/// `security find-generic-password … > ai_token.<name>` seeding step.
///
/// That command was account-blind: it copied whatever the keychain
/// held into whatever filename you typed, and nothing checked the two
/// matched. Get the account wrong and you silently overwrote a good
/// credential with a different account's.
///
/// This does the same capture, then *identifies* the blob over the
/// wire and routes it to the account it actually belongs to — so the
/// user runs `claude login` as whoever they like, presses one key, and
/// the credential lands in the right file or not at all.
///
/// Entirely off the UI thread: `security` can raise a GUI prompt and
/// the profile call is network.
pub fn spawn_keychain_recapture(
    targets: Vec<RecaptureTarget>,
) -> mpsc::Receiver<Result<String, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(recapture_from_keychain_blocking(&targets));
    });
    rx
}

fn recapture_from_keychain_blocking(targets: &[RecaptureTarget]) -> Result<String, String> {
    let blob = read_keychain_claude_token_blocking().ok_or_else(|| {
        "no Claude credential in the keychain — run `claude login` first".to_string()
    })?;
    let email = identity_of_blob(&blob).ok_or_else(|| {
        "captured a credential but couldn't verify who it belongs to \
         (profile lookup failed) — not writing it anywhere"
            .to_string()
    })?;

    let matches: Vec<&RecaptureTarget> = targets
        .iter()
        .filter(|t| {
            t.pinned_email
                .as_deref()
                .is_some_and(|p| same_identity(p, &email))
        })
        .collect();
    // Reviewer catch: a plain `.find()` would silently route to
    // whichever account happens to be declared first. When several
    // accounts claim one identity their files are already sharing a
    // credential, so "first match wins" is a coin flip on which one
    // gets repaired — refuse and make the ambiguity visible.
    if matches.len() > 1 {
        let names: Vec<&str> = matches.iter().map(|t| t.name.as_str()).collect();
        return Err(format!(
            "{} are all pinned to {email}, so it's ambiguous which one this \
             credential belongs to — their token files are sharing a login. \
             Re-auth them one at a time from distinct `claude login`s",
            names.join(" and ")
        ));
    }
    let Some(target) = matches.first().copied() else {
        // Name the accounts we DO know, so the user can see whether
        // they logged in as the wrong one or simply haven't pinned
        // this account yet.
        let known: Vec<&str> = targets
            .iter()
            .filter_map(|t| t.pinned_email.as_deref())
            .collect();
        return Err(if known.is_empty() {
            format!(
                "keychain holds {email}, but no account has a known identity yet — \
                 let a fetch succeed first so mnml learns which account is which"
            )
        } else {
            format!(
                "keychain holds {email}, which isn't any configured account ({}) — \
                 log in as the account you want to repair, then retry",
                known.join(", ")
            )
        });
    };

    write_claude_token_to(&target.token_path, &blob)
        .map_err(|e| format!("write {}: {e}", target.token_path.display()))?;
    Ok(format!("{} re-authed as {email}", target.name))
}

pub fn parse_refresh_token_from_blob(raw: &str) -> Option<String> {
    let s = raw.trim();
    if !s.starts_with('{') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(s).ok()?;
    let inner = v.get("claudeAiOauth").unwrap_or(&v);
    inner
        .get("refreshToken")
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Read `token_path` and extract its refresh token, if any. Public
/// sibling of the private [`read_refresh_token_at`] for the same
/// autodetect flow. #1150 (2026-08-23).
pub fn read_refresh_token_from_path(token_path: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(token_path).ok()?;
    parse_refresh_token_from_blob(&raw)
}

/// Extract a bearer access token from either a plain `sk-ant-…`
/// string or a `{claudeAiOauth: {accessToken: …}}` JSON blob.
/// Shared by `read_claude_token` and the multi-account fetcher.
fn parse_token_blob(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    if s.starts_with('{') {
        let v: serde_json::Value = serde_json::from_str(s).ok()?;
        let inner = v.get("claudeAiOauth").unwrap_or(&v);
        let token = inner.get("accessToken")?.as_str()?.trim().to_string();
        if token.is_empty() { None } else { Some(token) }
    } else {
        Some(s.to_string())
    }
}

/// Extract the refresh token from a `{claudeAiOauth: {…}}` JSON
/// blob stored at `token_path`. Returns `None` when the file is a
/// plain-string token or the JSON has no refreshToken.
fn read_refresh_token_at(token_path: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(token_path).ok()?;
    let s = raw.trim();
    if !s.starts_with('{') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(s).ok()?;
    let inner = v.get("claudeAiOauth").unwrap_or(&v);
    inner
        .get("refreshToken")
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Fetch failure payload. Carries the human-readable message and,
/// on 429s, the `Retry-After` header value (seconds) so the render
/// loop's throttle can honor Anthropic's own cooldown window instead
/// of guessing. 2026-08-16.
#[derive(Debug, Clone)]
pub struct FetchErr {
    pub message: String,
    pub retry_after_secs: Option<u64>,
}

impl FetchErr {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            retry_after_secs: None,
        }
    }
    fn with_retry_after(mut self, secs: u64) -> Self {
        self.retry_after_secs = Some(secs);
        self
    }
}

impl From<String> for FetchErr {
    fn from(s: String) -> Self {
        Self::new(s)
    }
}

fn fetch_claude_blocking() -> Result<ClaudeUsage, FetchErr> {
    let token = read_claude_token().ok_or_else(|| FetchErr::new("not linked"))?;
    // The default single-account path is the write-back destination
    // for a successful refresh — same as before this refactor.
    fetch_claude_with_token(&token, claude_token_path().as_deref())
}

/// Shared inner — takes an already-loaded bearer token (from
/// wherever the caller sourced it) plus the on-disk path to
/// write a refreshed token back to when Anthropic hands us one.
/// `refresh_write_back` may be None (won't attempt a refresh).
fn fetch_claude_with_token(
    token: &str,
    refresh_write_back: Option<&Path>,
) -> Result<ClaudeUsage, FetchErr> {
    // Single-account callers: `account_count = 1` disables the #1232
    // cross-write guard, which is correct — there is no sibling to
    // clobber and the legacy path must keep working untouched.
    fetch_claude_with_token_for(token, refresh_write_back, "", 1)
}

fn fetch_claude_with_token_for(
    token: &str,
    refresh_write_back: Option<&Path>,
    account_name: &str,
    account_count: usize,
) -> Result<ClaudeUsage, FetchErr> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| FetchErr::new(format!("http client: {e}")))?;
    let mut resp = client
        .get("https://api.anthropic.com/api/oauth/usage")
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .map_err(|e| FetchErr::new(format!("fetch: {e}")))?;
    // 2026-08-08 — auto-refresh on 401/403 when a refreshToken is
    // available. Claude Code OAuth tokens expire ~every 8h, and the
    // "re-link daily" UX was noise. Try once; on refresh success,
    // persist the new token JSON and re-issue the usage GET with the
    // fresh bearer. On refresh failure, fall through to the original
    // "token rejected" error so the chip still surfaces the state.
    if (resp.status() == 401 || resp.status() == 403)
        && let Some(back) = refresh_write_back
        && let Some(refresh) = read_refresh_token_at(back)
        && let Ok(new_access) = try_refresh_claude_token(&client, &refresh, Some(back))
    {
        resp = client
            .get("https://api.anthropic.com/api/oauth/usage")
            .header("Authorization", format!("Bearer {new_access}"))
            .send()
            .map_err(|e| FetchErr::new(format!("fetch (post-refresh): {e}")))?;
    }
    // Task #949 (2026-08-16) — auto-resync from keychain when
    // refresh flow fails. Common case: user ran `claude login`
    // fresh (e.g. after a session-timeout), updating the keychain,
    // but mnml's on-disk copy is stale + the refresh token in the
    // stale copy is also stale → refresh fails → chip stays dashed
    // until user manually re-runs the `security find-generic-
    // password … > ai_token` copy step. Try to grab the current
    // keychain blob; if it differs from what we tried, persist it
    // and re-fetch once. Only helpful for the account whose file
    // matches the currently-logged-in `claude` CLI account —
    // multi-account users still need to re-seed per account,
    // but the DEFAULT account path Just Works. Safe because we're
    // already on a worker thread — the `security` CLI's occasional
    // GUI prompt won't freeze the UI.
    if (resp.status() == 401 || resp.status() == 403)
        && let Some(back) = refresh_write_back
        && let Some(keychain_blob) = read_keychain_claude_token_blocking()
        && keychain_blob.trim() != token.trim()
    {
        // Task #961 (2026-08-16 reviewer follow-up) — try the fetch
        // FIRST, persist only on success. Prior order (persist →
        // fetch) could overwrite a working refreshToken in the old
        // blob with an equally-stale keychain blob if the user's
        // keychain hadn't actually been refreshed, losing the normal
        // refresh recovery path on the next cycle. Now the on-disk
        // token only changes when we've proven the keychain blob
        // actually works.
        let new_access =
            parse_access_token(&keychain_blob).unwrap_or_else(|| keychain_blob.clone());
        resp = client
            .get("https://api.anthropic.com/api/oauth/usage")
            .header("Authorization", format!("Bearer {new_access}"))
            .send()
            .map_err(|e| FetchErr::new(format!("fetch (post-keychain-resync): {e}")))?;
        if resp.status().is_success() {
            // #1232 — the blob fetching successfully proves it is a
            // VALID credential, not that it is THIS account's
            // credential. There is one keychain entry; before this
            // guard, whichever account happened to 401 got it written
            // into its file, and with three accounts configured all
            // three converged onto one login (three byte-identical
            // token files) while the other two accounts' refresh
            // tokens were destroyed.
            match verify_blob_belongs_to(account_name, &keychain_blob, account_count) {
                Ok(()) => {
                    let _ = write_claude_token_to(back, &keychain_blob);
                }
                Err(why) => {
                    // Surface it rather than silently declining, so
                    // the pane can tell the user this account needs a
                    // real re-auth and which login is actually loaded.
                    return Err(FetchErr::new(format!("needs re-auth: {why}")));
                }
            }
        }
    }
    let status = resp.status();
    // Extract `Retry-After` header BEFORE `resp.text()` consumes the
    // response. Anthropic emits it as a delta-seconds integer on 429s
    // (`retry-after: 3150` = wait 52 min). RFC-7231 also allows an
    // HTTP-date form; we try the numeric form first (Anthropic uses
    // that shape) and fall back to zero on parse failure — worst case
    // we just miss the header hint and fall back to the fixed 5-min
    // throttle. 2026-08-16.
    let retry_after_secs = resp
        .headers()
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u64>().ok());
    let text = resp
        .text()
        .map_err(|e| FetchErr::new(format!("body read: {e}")))?;
    // Debug hook — write the last response to a predictable path so
    // `:ai.show_last_response` can open it when the parser returns 0%
    // for something the endpoint clearly filled in. Best-effort, silent
    // on failure.
    //
    // claude-agents-power-user r5 (2026-08-08) SEV-1 — three separate
    // gaps closed here:
    //   1. Response body was written BEFORE `redact_bearer()` scrubbed
    //      it, defeating the mitigation added for auth middlewares that
    //      echo the `Authorization` header back in error strings.
    //   2. Path was `~/.cache/mnml/…` via bare `HOME`, bypassing
    //      `data_root()` — under `--sandbox` / Portable mode the OAuth
    //      response would leak to the real $HOME.
    //   3. File was written with default (0644) perms → other local
    //      users could read the response body. Chmod 600 like the
    //      sibling `ai_token`.
    let dir = crate::data_root::data_root().join("cache");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("ai_last_response.json");
    let scrubbed = redact_bearer(&text);
    // 2026-08-08 (reviewer follow-up) — use `write_secret_file` so the
    // file is created with 0600 from the start; the earlier
    // `fs::write` then `set_permissions` left a brief 0644 window.
    let _ = write_secret_file(
        &path,
        format!(
            "// HTTP {}\n// fetched_at: {}\n{}\n",
            status.as_u16(),
            now_unix(),
            scrubbed
        )
        .as_bytes(),
    );
    if !status.is_success() {
        // Reviewer 2026-08-05 — don't echo the response body on
        // auth failures. Some auth middlewares include the raw
        // Authorization header value in error strings ("invalid
        // Authorization header: Bearer sk-ant-oat-…"), which
        // would then flow into `last_error` → toast → `screen.txt`
        // on disk. Better to render a generic hint. For other
        // status codes, redact any bearer-token-like substring.
        let msg = if status.as_u16() == 401 || status.as_u16() == 403 {
            "token rejected — re-link via :ai.link_claude_token".to_string()
        } else {
            truncate(&redact_bearer(&text), 80)
        };
        let err = FetchErr::new(format!("HTTP {}: {}", status.as_u16(), msg));
        // On 429 with a numeric Retry-After, attach it so the render
        // loop can honor Anthropic's own cooldown window (see
        // `App::maybe_refresh_ai_usage`).
        let err = if status.as_u16() == 429
            && let Some(secs) = retry_after_secs
        {
            err.with_retry_after(secs)
        } else {
            err
        };
        return Err(err);
    }
    parse_claude_response(&text).map_err(FetchErr::new)
}

/// Replace anything that looks like a bearer token with `<redacted>`
/// so error responses that echo it back can't leak into logs /
/// toasts / on-disk screen.txt. Matches `sk-ant-…`, `sk-…`, and
/// generic `Bearer <hex-ish blob>` shapes.
fn redact_bearer(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(idx) = rest.find(['s', 'B']) {
        out.push_str(&rest[..idx]);
        let tail = &rest[idx..];
        // Consume until whitespace / closing quote / end
        let end = tail
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'')
            .unwrap_or(tail.len());
        let candidate = &tail[..end];
        let looks_bearer = candidate.starts_with("sk-")
            || candidate.starts_with("Bearer ")
            || candidate.starts_with("sk_ant")
            || (candidate.len() > 40 && candidate.starts_with("sk"));
        if looks_bearer {
            out.push_str("<redacted>");
        } else {
            out.push_str(candidate);
        }
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

/// Parsed subset of Anthropic's `/api/oauth/profile` response —
/// only the fields the account chip cares about (see
/// [`fetch_claude_profile_best_effort`]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct ProfileInfo {
    email: Option<String>,
    org_name: Option<String>,
}

/// GET `https://api.anthropic.com/api/oauth/profile` with the
/// given bearer token and pull out `account.email` + `organization.name`.
/// Any failure — no client, network, non-2xx, JSON parse — returns
/// `None`. Timeouts are aggressive (5s) so a slow identity endpoint
/// doesn't stall the usage-fetch worker meaningfully. Callers who
/// need to distinguish "no data" from "known no email" should treat
/// `None` as "unknown, don't render".
fn fetch_claude_profile_best_effort(token: &str) -> Option<ProfileInfo> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("mnml/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .ok()?;
    let resp = client
        .get("https://api.anthropic.com/api/oauth/profile")
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/json")
        .send()
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let text = resp.text().ok()?;
    parse_profile_response(&text)
}

/// Parse Anthropic's `/api/oauth/profile` response body.
/// Verified shape (2026-08-16):
///   `{account: {uuid, full_name, display_name, email, has_claude_max,
///               has_claude_pro, created_at},
///     organization: {uuid, name, organization_type, billing_type, …},
///     application: {…}}`
/// Returns `None` when JSON is invalid; a partial payload (one field
/// missing) still returns `Some` with the available field set.
fn parse_profile_response(text: &str) -> Option<ProfileInfo> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let email = v
        .get("account")
        .and_then(|a| a.get("email"))
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let org_name = v
        .get("organization")
        .and_then(|o| o.get("name"))
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    if email.is_none() && org_name.is_none() {
        return None;
    }
    Some(ProfileInfo { email, org_name })
}

/// Parse the real Anthropic `/api/oauth/usage` response.
/// Verified shape (2026-08-05):
///   `{five_hour: {utilization, resets_at (ISO-8601 string), …},
///     seven_day: {utilization, resets_at, …},
///     limits: [{kind: "session"|"weekly_all"|…, percent, resets_at, …}], …}`
/// Both `five_hour` and `seven_day` are optional (older tiers may
/// omit); the `limits[]` array is the fallback when the top-level
/// shortcuts are missing.
fn parse_claude_response(text: &str) -> Result<ClaudeUsage, String> {
    let v: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("parse json: {e}"))?;
    let (percent, resets_at) = extract_session(&v);
    let (weekly_percent, weekly_resets_at) = extract_weekly(&v);
    let scoped_limits = extract_scoped_limits(&v);
    Ok(ClaudeUsage {
        percent,
        weekly_percent,
        resets_at,
        weekly_resets_at,
        scoped_limits,
        tokens_5h: 0, // endpoint doesn't return raw token counts
        fetched_at: now_unix(),
        last_error: None,
        retry_after_at: 0,
    })
}

/// Per-model weekly limits from the `limits[]` array. Each entry
/// with `kind == "weekly_scoped"` carries a nested
/// `scope.model.display_name` we surface as the row label.
fn extract_scoped_limits(v: &serde_json::Value) -> Vec<ScopedLimit> {
    let Some(arr) = v.get("limits").and_then(|x| x.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in arr {
        let kind = entry.get("kind").and_then(|x| x.as_str()).unwrap_or("");
        if kind != "weekly_scoped" {
            continue;
        }
        let name = entry
            .get("scope")
            .and_then(|s| s.get("model"))
            .and_then(|m| m.get("display_name"))
            .and_then(|x| x.as_str())
            .unwrap_or("?")
            .to_string();
        let pct = entry
            .get("percent")
            .and_then(|x| x.as_f64())
            .map(|n| n.round().clamp(0.0, 999.0) as u16)
            .unwrap_or(0);
        let resets = entry
            .get("resets_at")
            .and_then(|x| x.as_str())
            .and_then(parse_iso8601_secs)
            .unwrap_or(0);
        out.push(ScopedLimit {
            model_display_name: name,
            percent: pct,
            resets_at: resets,
        });
    }
    out
}

/// Pull the 5h/session utilization + reset time. Preferred path:
/// `five_hour.utilization` + `.resets_at`. Fallback: scan the
/// `limits[]` array for `kind == "session"`.
fn extract_session(v: &serde_json::Value) -> (u16, u64) {
    if let Some(fh) = v.get("five_hour") {
        let util = fh
            .get("utilization")
            .and_then(|x| x.as_f64())
            .map(|n| n.round().clamp(0.0, 999.0) as u16)
            .unwrap_or(0);
        let resets = fh
            .get("resets_at")
            .and_then(|x| x.as_str())
            .and_then(parse_iso8601_secs)
            .unwrap_or(0);
        if util > 0 || resets > 0 {
            return (util, resets);
        }
    }
    // Fallback: limits[] with kind "session".
    if let Some(limits) = v.get("limits").and_then(|x| x.as_array()) {
        for entry in limits {
            let kind = entry.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            if kind == "session" {
                let pct = entry
                    .get("percent")
                    .and_then(|x| x.as_f64())
                    .map(|n| n.round().clamp(0.0, 999.0) as u16)
                    .unwrap_or(0);
                let resets = entry
                    .get("resets_at")
                    .and_then(|x| x.as_str())
                    .and_then(parse_iso8601_secs)
                    .unwrap_or(0);
                return (pct, resets);
            }
        }
    }
    (0, 0)
}

/// Same pattern for the 7-day/weekly window. Preferred:
/// `seven_day.utilization`. Fallback: `limits[]` with kind
/// `weekly_all` (the top-level weekly, not per-model scoped).
fn extract_weekly(v: &serde_json::Value) -> (u16, u64) {
    if let Some(sd) = v.get("seven_day") {
        let util = sd
            .get("utilization")
            .and_then(|x| x.as_f64())
            .map(|n| n.round().clamp(0.0, 999.0) as u16)
            .unwrap_or(0);
        let resets = sd
            .get("resets_at")
            .and_then(|x| x.as_str())
            .and_then(parse_iso8601_secs)
            .unwrap_or(0);
        if util > 0 || resets > 0 {
            return (util, resets);
        }
    }
    if let Some(limits) = v.get("limits").and_then(|x| x.as_array()) {
        for entry in limits {
            let kind = entry.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            if kind == "weekly_all" {
                let pct = entry
                    .get("percent")
                    .and_then(|x| x.as_f64())
                    .map(|n| n.round().clamp(0.0, 999.0) as u16)
                    .unwrap_or(0);
                let resets = entry
                    .get("resets_at")
                    .and_then(|x| x.as_str())
                    .and_then(parse_iso8601_secs)
                    .unwrap_or(0);
                return (pct, resets);
            }
        }
    }
    (0, 0)
}

/// Depth-first search for a key anywhere in the JSON tree, capped
/// at MAX_DEPTH so a pathological / attacker-crafted deep JSON can't
/// blow the worker's stack. Returns the first match. Used only as a
/// FALLBACK — see `parse_claude_response` for the preferred
/// known-path lookups.
fn walk<'a>(v: &'a serde_json::Value, key: &str, depth: usize) -> Option<&'a serde_json::Value> {
    const MAX_DEPTH: usize = 8;
    if depth > MAX_DEPTH {
        return None;
    }
    if let Some(map) = v.as_object() {
        if let Some(hit) = map.get(key) {
            return Some(hit);
        }
        for val in map.values() {
            if let Some(hit) = walk(val, key, depth + 1) {
                return Some(hit);
            }
        }
    }
    if let Some(arr) = v.as_array() {
        for item in arr {
            if let Some(hit) = walk(item, key, depth + 1) {
                return Some(hit);
            }
        }
    }
    None
}

/// Minimal ISO-8601 → Unix seconds parser. Handles the shape
/// Anthropic's OAuth-usage endpoint writes for `resets_at`:
/// `2026-08-05T22:50:00.123240+00:00` or `2026-08-05T22:50:00Z`.
fn parse_iso8601_secs(s: &str) -> Option<u64> {
    if s.len() < 19 {
        return None;
    }
    let (y, rest) = (s.get(0..4)?.parse::<i64>().ok()?, s.get(5..)?);
    let (mo, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (d, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (h, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let (mi, rest) = (rest.get(0..2)?.parse::<u64>().ok()?, rest.get(3..)?);
    let sec: u64 = rest.get(0..2)?.parse().ok()?;
    // Skip optional `.fff…` fractional seconds, then read the tz.
    let tz_start = rest.get(2..)?;
    let tz_str = if let Some(dot) = tz_start.strip_prefix('.') {
        dot.trim_start_matches(|c: char| c.is_ascii_digit())
    } else {
        tz_start
    };
    let tz_offset_secs: i64 = match tz_str.chars().next() {
        Some('Z') | Some('z') | None => 0,
        Some(sign_ch) if sign_ch == '+' || sign_ch == '-' => {
            let sign: i64 = if sign_ch == '-' { -1 } else { 1 };
            let body = tz_str.get(1..)?;
            let (hh, mm) = if let Some((h_str, m_str)) = body.split_once(':') {
                (h_str.parse::<i64>().ok()?, m_str.parse::<i64>().ok()?)
            } else if body.len() >= 4 {
                (
                    body.get(0..2)?.parse::<i64>().ok()?,
                    body.get(2..4)?.parse::<i64>().ok()?,
                )
            } else {
                return None;
            };
            sign * (hh * 3600 + mm * 60)
        }
        _ => 0,
    };
    let year_days = |y: i64| -> i64 {
        let y = y - 1;
        (y * 365) + (y / 4) - (y / 100) + (y / 400)
    };
    let is_leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = if is_leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut d_of_year: i64 = (d as i64) - 1;
    for m_idx in 0..(mo as usize).saturating_sub(1) {
        d_of_year += month_days.get(m_idx).copied().unwrap_or(0) as i64;
    }
    let days_since_epoch = year_days(y) - year_days(1970) + d_of_year;
    let local_secs = days_since_epoch * 86400 + (h as i64) * 3600 + (mi as i64) * 60 + sec as i64;
    let utc_secs = local_secs - tz_offset_secs;
    if utc_secs < 0 {
        None
    } else {
        Some(utc_secs as u64)
    }
}

/// Spawn a worker to scan `~/.codex/sessions/*.jsonl` for today's
/// files + sum per-turn token counts. Codex CLI writes one JSON
/// object per line; we look for `token_usage.total_tokens` (or
/// similar) on each and add.
pub fn spawn_codex_fetch() -> mpsc::Receiver<Result<CodexUsage, String>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = fetch_codex_blocking();
        let _ = tx.send(result);
    });
    rx
}

fn fetch_codex_blocking() -> Result<CodexUsage, String> {
    let sessions_dir = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|h| h.join(".codex").join("sessions"))
        .ok_or_else(|| "no $HOME".to_string())?;
    if !sessions_dir.exists() {
        return Ok(CodexUsage {
            last_error: Some("~/.codex/sessions not found".into()),
            fetched_at: now_unix(),
            ..Default::default()
        });
    }
    let mut tokens_today = 0u64;
    let mut sessions_today = 0u64;
    let entries = std::fs::read_dir(&sessions_dir).map_err(|e| format!("read_dir: {e}"))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        // Filter to files modified today — cheap prefilter before
        // reading the (potentially large) file.
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(mtime) = meta.modified() else { continue };
        if !is_today(mtime) {
            continue;
        }
        sessions_today += 1;
        tokens_today += sum_tokens_in_jsonl(&path).unwrap_or(0);
    }
    Ok(CodexUsage {
        tokens_today,
        sessions_today,
        fetched_at: now_unix(),
        last_error: None,
    })
}

fn sum_tokens_in_jsonl(path: &Path) -> Option<u64> {
    use std::io::{BufRead, BufReader};
    // Reviewer 2026-08-05 — was `read_to_string` which slurped the
    // entire session file (potentially many MB after a long day).
    // Stream line-by-line so peak memory is bounded to one line +
    // its parsed Value. Also cap total lines read per file so a
    // runaway JSONL never blocks the worker indefinitely.
    const MAX_LINES_PER_FILE: usize = 100_000;
    let file = std::fs::File::open(path).ok()?;
    let reader = BufReader::new(file);
    let mut sum = 0u64;
    for (i, line) in reader.lines().enumerate() {
        if i >= MAX_LINES_PER_FILE {
            break;
        }
        let Ok(line) = line else { continue };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        // claude-agents-user r3+r4 (2026-08-05/06) — real Codex
        // rollout-*.jsonl files nest usage under
        // `payload.info.last_token_usage` (delta per turn) and
        // `.total_token_usage` (cumulative), NOT top-level
        // `token_usage`/`usage`. Prior key names never matched →
        // chip always read 0.
        //
        // MUST sum `last_token_usage` (delta), NOT
        // `total_token_usage` (cumulative — summing it inflates by
        // N× where N = event count in the file). See the same
        // rule enforced elsewhere: `src/claude_agents.rs:1814`
        // "total_token_usage is cumulative — overwrite, don't sum".
        //
        // No fallback keys — earlier fix added `token_usage`/`usage`
        // as "older schema" fallbacks but the delta-vs-cumulative
        // semantics of those keys is unverified, and this exact
        // ambiguity is what re-introduces the inflation bug (per
        // reviewer flag on 61a551c1). Better to under-count on an
        // unrecognized schema than silently over-count.
        let usage = walk(&v, "last_token_usage", 0);
        if let Some(usage) = usage {
            let inp = usage
                .get("input_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            let out = usage
                .get("output_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            let total = usage
                .get("total_tokens")
                .and_then(|x| x.as_u64())
                .unwrap_or(inp + out);
            sum += total;
        }
    }
    Some(sum)
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn is_today(t: std::time::SystemTime) -> bool {
    let Ok(dur) = t.duration_since(std::time::UNIX_EPOCH) else {
        return false;
    };
    let secs = dur.as_secs() as i64;
    let now = now_unix() as i64;
    // Same day if both round to the same `days` bucket. Approximate
    // (no local-TZ offset); good enough for today-vs-not.
    (secs / 86400) == (now / 86400)
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        s.chars().take(n).collect::<String>() + "…"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Verified against a real `/api/oauth/profile` response captured
    // on 2026-08-16 (email / uuid stripped). See ai_usage.rs top-of-file
    // docs for the endpoint's known-good shape.
    const PROFILE_FIXTURE: &str = r#"{
        "account": {
            "uuid": "00000000-0000-4000-8000-000000000000",
            "full_name": "Test User",
            "display_name": "Test",
            "email": "test@example.com",
            "has_claude_max": true,
            "has_claude_pro": false,
            "created_at": "2024-06-04T15:49:25.622079Z"
        },
        "organization": {
            "uuid": "00000000-0000-4000-8000-000000000001",
            "name": "Test Org",
            "organization_type": "claude_max",
            "billing_type": "stripe_subscription"
        },
        "application": {
            "uuid": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        }
    }"#;

    #[test]
    fn parse_profile_returns_email_and_org() {
        let got = parse_profile_response(PROFILE_FIXTURE).expect("some");
        assert_eq!(got.email.as_deref(), Some("test@example.com"));
        assert_eq!(got.org_name.as_deref(), Some("Test Org"));
    }

    #[test]
    fn parse_profile_tolerates_missing_organization() {
        let json = r#"{"account":{"email":"only@example.com"}}"#;
        let got = parse_profile_response(json).expect("some");
        assert_eq!(got.email.as_deref(), Some("only@example.com"));
        assert!(got.org_name.is_none());
    }

    #[test]
    fn parse_profile_tolerates_missing_account() {
        let json = r#"{"organization":{"name":"Anthropic"}}"#;
        let got = parse_profile_response(json).expect("some");
        assert!(got.email.is_none());
        assert_eq!(got.org_name.as_deref(), Some("Anthropic"));
    }

    #[test]
    fn parse_profile_returns_none_when_both_fields_absent() {
        // Body is valid JSON but carries neither account.email nor
        // organization.name — treat as "no signal" so the caller
        // doesn't stamp an empty pair over prior good data.
        let json = r#"{"account":{"uuid":"x"},"organization":{"uuid":"y"}}"#;
        assert!(parse_profile_response(json).is_none());
    }

    #[test]
    fn parse_profile_returns_none_on_bad_json() {
        assert!(parse_profile_response("not json").is_none());
        assert!(parse_profile_response("").is_none());
    }

    #[test]
    fn parse_profile_ignores_empty_strings() {
        // A whitespace-only or empty email/org field is treated as
        // absent — otherwise the render layer would show a blank
        // "@" glyph or double-space where the identity should be.
        let json = r#"{"account":{"email":"  "},"organization":{"name":""}}"#;
        assert!(parse_profile_response(json).is_none());
    }
}

#[cfg(test)]
mod identity_guard_tests {
    use super::*;

    /// #1232 — the whole point. With more than one account
    /// configured, an unverifiable blob must NOT be written, because
    /// the keychain holds exactly one login and writing it into
    /// whichever account happened to 401 is what silently collapsed
    /// three distinct credentials onto one.
    #[test]
    fn multi_account_refuses_an_unpinned_account() {
        let err = verify_blob_belongs_to("work", "{}", 3).unwrap_err();
        assert!(
            err.contains("no pinned identity"),
            "expected a refusal naming the missing pin, got: {err}"
        );
    }

    /// The complement — a single configured account keeps the old
    /// behavior exactly. There is no sibling to damage, and gating it
    /// would break the default-account convenience on a fresh install
    /// that has no pin yet. Without this the fix could be "refuse
    /// always" and the test above would still pass.
    #[test]
    fn single_account_is_never_gated() {
        assert!(verify_blob_belongs_to("default", "{}", 1).is_ok());
        assert!(verify_blob_belongs_to("", "anything", 0).is_ok());
    }

    fn pins(entries: &[(&str, &str)]) -> std::collections::BTreeMap<String, String> {
        entries
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// Reviewer catch, and the most important test here. The #1232
    /// bug leaves several token files holding ONE credential. Every
    /// one of them then fetches successfully and reports the same
    /// email. If each got pinned in turn, all of them would hold
    /// identical "proof" of identity and the guard would wave through
    /// exactly the cross-writes it exists to stop — the fix would
    /// launder the collapse instead of catching it.
    #[test]
    fn a_second_account_claiming_one_identity_is_a_collision_not_a_pin() {
        let existing = pins(&[("personal", "chris@example.com")]);
        assert_eq!(
            plan_pin(&existing, "work", "chris@example.com"),
            PinDecision::Collision {
                other: "personal".to_string()
            },
            "the 2nd account to report an already-claimed email must NOT pin"
        );
        // Re-pinning the SAME account is not a collision with itself.
        assert_eq!(
            plan_pin(&existing, "personal", "chris@example.com"),
            PinDecision::Unchanged
        );
        // And a genuinely distinct identity still pins.
        assert_eq!(
            plan_pin(&existing, "work", "work@example.com"),
            PinDecision::Write
        );
    }

    /// Casing must not be a way to sneak a duplicate past the
    /// collision check.
    #[test]
    fn collision_detection_ignores_case() {
        let existing = pins(&[("personal", "Chris@Example.com")]);
        assert!(matches!(
            plan_pin(&existing, "work", "chris@example.com"),
            PinDecision::Collision { .. }
        ));
    }

    #[test]
    fn identity_comparison_is_case_and_space_insensitive() {
        assert!(same_identity(" You@Example.com ", "you@example.com"));
        assert!(!same_identity("you@example.com", "other@example.com"));
    }
}
