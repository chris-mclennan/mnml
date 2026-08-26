//! Append-only history log at `<workspace>/.rqst/history.jsonl`.
//!
//! One JSON line per completed request. Used for ad-hoc forensic queries:
//!   grep '"status":401' .rqst/history.jsonl
//!   jq -c 'select(.duration_ms > 1000)' .rqst/history.jsonl
//!
//! Append is open(append) + write — POSIX guarantees atomic appends for
//! lines under PIPE_BUF (4096 on Linux/macOS), and our lines are well
//! under that. No rename trick needed.
//!
//! 2026-06-20 — also mirror each line into a *global* log at
//! `~/.config/mnml/history-global.jsonl` with a `"workspace"` field
//! identifying the source. Lets `:http.history_global` recall a
//! request you made from any project, useful when you remember
//! firing it but not which workspace you were in.

use serde_json::Value;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct Entry<'a> {
    pub method: &'a str,
    pub url: &'a str,
    pub status: Option<u16>,
    pub duration_ms: Option<u128>,
    pub body_bytes: Option<usize>,
    pub error: Option<&'a str>,
    /// http-2nd 2026-06-28 SEV-3c — request headers as
    /// `Vec<(name, value)>`. Stored alongside the response
    /// metadata so the history picker can rebuild a usable
    /// curl command, not just `curl -X METHOD URL`.
    pub headers: Option<&'a [(String, String)]>,
    /// The serialised request body (utf-8 string). None when
    /// the request was bodyless.
    pub request_body: Option<&'a str>,
}

/// Header names whose values are credentials. Matched
/// case-insensitively — HTTP header names aren't case-sensitive, and
/// `.curl` files in the wild spell these every possible way.
const SENSITIVE_HEADERS: &[&str] = &[
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "api-key",
    "x-auth-token",
    "x-amz-security-token",
    "x-csrf-token",
];

pub fn is_sensitive_header(name: &str) -> bool {
    let lower = name.trim().to_ascii_lowercase();
    SENSITIVE_HEADERS.contains(&lower.as_str())
}

/// Decide what to persist for one request header.
///
/// History previously stored the template-EXPANDED value, so an
/// `Authorization: Bearer {{TOKEN}}` landed on disk as the resolved
/// secret. Expansion was deliberate — the history picker rebuilds a
/// runnable curl from these — so blanket redaction would trade one
/// problem for a broken feature.
///
/// Instead, for a sensitive header, prefer the UNEXPANDED `raw` when
/// it still carries a `{{VAR}}` reference: replay re-expands it
/// against the active env, so the entry stays runnable AND no secret
/// is written. Only when the user hard-coded a literal credential
/// (nothing to re-expand from) does the value get redacted — there is
/// no way to keep that replayable without storing the secret, and not
/// storing it is the right call.
///
/// Non-sensitive headers are unchanged: `Accept`, `Content-Type` and
/// friends are far more useful expanded.
pub fn header_value_for_history(name: &str, raw: &str, expanded: &str) -> String {
    if !is_sensitive_header(name) {
        return expanded.to_string();
    }
    if raw.contains("{{") && raw.contains("}}") {
        return raw.to_string();
    }
    "<redacted by mnml>".to_string()
}

/// JSON / form field names whose values are credentials.
const SENSITIVE_FIELDS: &[&str] = &[
    "password",
    "passwd",
    "secret",
    "client_secret",
    "clientsecret",
    "access_token",
    "refresh_token",
    "id_token",
    "api_key",
    "apikey",
    "private_key",
    "token",
];

/// What to persist for a request body.
///
/// Prefers the UNEXPANDED body for the same reason as headers: a body
/// referencing `{{CLIENT_SECRET}}` stays symbolic on disk and still
/// replays correctly. Then scrubs literal values for well-known
/// credential field names, which covers the case the template form
/// can't — a password typed directly into the request.
///
/// Not a JSON parser: bodies are frequently non-JSON (form-encoded,
/// GraphQL, XML) and a malformed one must still be scrubbed. This is a
/// deliberately blunt textual pass — it can over-redact a field
/// innocently named `token`, which is the safe direction.
pub fn body_for_history(raw: &str, expanded: &str) -> String {
    let base = if raw.contains("{{") && raw.contains("}}") {
        raw
    } else {
        expanded
    };
    scrub_sensitive_fields(base)
}

/// Replace the value following any `"<sensitive>": "…"` or
/// `<sensitive>=…` with a redaction marker.
fn scrub_sensitive_fields(body: &str) -> String {
    let lower = body.to_ascii_lowercase();
    // Cheap bail-out: most bodies mention none of these.
    if !SENSITIVE_FIELDS.iter().any(|f| lower.contains(f)) {
        return body.to_string();
    }
    let mut out = String::with_capacity(body.len());
    let bytes: Vec<char> = body.chars().collect();
    let mut i = 0usize;
    while i < bytes.len() {
        // Find the next `"` or `&`/`?` boundary-ish token start; we
        // scan for `name` followed by `":` or `=`.
        let rest_lower: String = lower.chars().skip(i).collect();
        let hit = SENSITIVE_FIELDS
            .iter()
            .filter_map(|f| rest_lower.find(f).map(|at| (at, *f)))
            .min_by_key(|(at, _)| *at);
        let Some((at, field)) = hit else {
            out.extend(bytes[i..].iter());
            break;
        };
        let start = i + at;
        out.extend(bytes[i..start].iter());
        out.push_str(field);
        let mut j = start + field.chars().count();
        // Skip a closing quote / whitespace / separator.
        let mut sep = String::new();
        while j < bytes.len() && (bytes[j].is_whitespace() || bytes[j] == '"' || bytes[j] == '\'') {
            sep.push(bytes[j]);
            j += 1;
        }
        if j < bytes.len() && (bytes[j] == ':' || bytes[j] == '=') {
            sep.push(bytes[j]);
            j += 1;
            while j < bytes.len() && bytes[j].is_whitespace() {
                sep.push(bytes[j]);
                j += 1;
            }
            out.push_str(&sep);
            // Consume the value: a quoted string, or up to the next
            // delimiter for form/loose syntax.
            if j < bytes.len() && (bytes[j] == '"' || bytes[j] == '\'') {
                let quote = bytes[j];
                j += 1;
                while j < bytes.len() && bytes[j] != quote {
                    j += 1;
                }
                if j < bytes.len() {
                    j += 1;
                }
                out.push_str("\"<redacted by mnml>\"");
            } else {
                while j < bytes.len() && !matches!(bytes[j], ',' | '&' | '}' | '\n' | ' ') {
                    j += 1;
                }
                out.push_str("<redacted by mnml>");
            }
        } else {
            out.push_str(&sep);
        }
        i = j;
    }
    out
}

/// Last-ditch scrub for values reaching history by some other path.
/// Catches a bare `Bearer <token>` / `Basic <b64>` even when the
/// header name wasn't recognised.
fn scrub_residual_credentials(value: &str) -> String {
    let lower = value.to_ascii_lowercase();
    for prefix in ["bearer ", "basic ", "token ", "sk-ant-", "sk-", "xox"] {
        if lower.starts_with(prefix) && value.len() > prefix.len() + 8 {
            return "<redacted by mnml>".to_string();
        }
    }
    value.to_string()
}

pub fn append(workspace: &Path, entry: &Entry) {
    let dir = workspace.join(".rqst");
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    // `.rqst/` is created lazily, on the first request — well after
    // `Ipc::init` ran its gitignore pass at startup. Re-run it here so
    // the directory that holds resolved `Authorization` headers gets
    // ignored the moment it comes into existence, rather than waiting
    // for the next launch. Cheap: early-returns once covered.
    let _ = crate::ipc::ensure_workspace_gitignore(workspace);
    let path = dir.join("history.jsonl");
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let payload = serde_json::json!({
        "ts": ts,
        "method": entry.method,
        "url": entry.url,
        "status": entry.status,
        "duration_ms": entry.duration_ms,
        "body_bytes": entry.body_bytes,
        "error": entry.error,
        // Defense in depth: callers should route sensitive headers
        // through `header_value_for_history`, but a future call site
        // that forgets shouldn't write a live token to disk.
        "headers": entry.headers.map(|hs| {
            hs.iter()
                .map(|(k, v)| {
                    if is_sensitive_header(k) && !(v.contains("{{") && v.contains("}}")) {
                        (k.clone(), "<redacted by mnml>".to_string())
                    } else {
                        (k.clone(), scrub_residual_credentials(v))
                    }
                })
                .collect::<Vec<_>>()
        }),
        "request_body": entry.request_body.map(scrub_sensitive_fields),
    });
    let mut line = match serde_json::to_string(&payload) {
        Ok(s) => s,
        Err(_) => return,
    };
    line.push('\n');
    // Entries carry template-EXPANDED request headers, so an
    // `Authorization: Bearer {{TOKEN}}` lands here as the resolved
    // secret, alongside request bodies (login payloads, OAuth
    // client_secrets). Owner-only. NOTE: permissions are only half the
    // fix — the values are still stored in cleartext, and the
    // workspace copy sits inside the project tree where `git add -A`
    // can stage it. Redaction + gitignore are tracked separately.
    if let Ok(mut f) = crate::secret_file::append_secret(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Wrapper that writes to the workspace log AND mirrors to the
/// global log. The global log lets `:http.history_global` show
/// cross-workspace request history. App callers should prefer this
/// over [`append`] — tests use [`append`] directly to avoid HOME
/// pollution.
pub fn append_with_global_mirror(workspace: &Path, entry: &Entry) {
    append(workspace, entry);
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    append_global(workspace, entry, ts);
}

/// Mirror an entry into `~/.config/mnml/history-global.jsonl` with a
/// `workspace` field added so `:http.history_global` can show where
/// the request originated. Best-effort — silently no-ops if HOME
/// isn't set or the file can't be opened.
fn append_global(workspace: &Path, entry: &Entry, ts: u128) {
    let Some(path) = global_history_path() else {
        return;
    };
    if let Some(parent) = path.parent()
        && fs::create_dir_all(parent).is_err()
    {
        return;
    }
    let workspace_label = workspace
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();
    let payload = serde_json::json!({
        "ts": ts,
        "workspace": workspace_label,
        "workspace_path": workspace.to_string_lossy(),
        "method": entry.method,
        "url": entry.url,
        "status": entry.status,
        "duration_ms": entry.duration_ms,
        "body_bytes": entry.body_bytes,
        "error": entry.error,
        // Defense in depth: callers should route sensitive headers
        // through `header_value_for_history`, but a future call site
        // that forgets shouldn't write a live token to disk.
        "headers": entry.headers.map(|hs| {
            hs.iter()
                .map(|(k, v)| {
                    if is_sensitive_header(k) && !(v.contains("{{") && v.contains("}}")) {
                        (k.clone(), "<redacted by mnml>".to_string())
                    } else {
                        (k.clone(), scrub_residual_credentials(v))
                    }
                })
                .collect::<Vec<_>>()
        }),
        "request_body": entry.request_body.map(scrub_sensitive_fields),
    });
    let mut line = match serde_json::to_string(&payload) {
        Ok(s) => s,
        Err(_) => return,
    };
    line.push('\n');
    // Entries carry template-EXPANDED request headers, so an
    // `Authorization: Bearer {{TOKEN}}` lands here as the resolved
    // secret, alongside request bodies (login payloads, OAuth
    // client_secrets). Owner-only. NOTE: permissions are only half the
    // fix — the values are still stored in cleartext, and the
    // workspace copy sits inside the project tree where `git add -A`
    // can stage it. Redaction + gitignore are tracked separately.
    if let Ok(mut f) = crate::secret_file::append_secret(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// `~/.config/mnml/history-global.jsonl`, or whatever
/// `$MNML_HISTORY_GLOBAL_PATH` points to (used by tests to avoid
/// touching the real user log). Returns `None` if neither is set.
pub fn global_history_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("MNML_HISTORY_GLOBAL_PATH") {
        return Some(PathBuf::from(p));
    }
    Some(crate::data_root::data_root().join("history-global.jsonl"))
}

/// Read the last `n` entries from the global history log (most
/// recent last). Used by `:http.history_global`.
pub fn tail_global(n: usize) -> Vec<Value> {
    let Some(path) = global_history_path() else {
        return Vec::new();
    };
    let Ok(text) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut out: Vec<Value> = text
        .lines()
        .rev()
        .take(n)
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    out.reverse();
    out
}

/// Rebuild a `curl` command from a history entry. Uses the persisted
/// `headers` + `request_body` when present; falls back to the minimal
/// `curl -X METHOD URL` form for older entries. Returns
/// `(curl_text, method, url)` so callers can drive `open_curl_scratch`.
/// Shared between the `HistoryRows` picker and the sectioned HTTP
/// sidebar so both re-fire history the same way.
pub fn entry_to_curl(v: &Value) -> (String, String, String) {
    let method = v
        .get("method")
        .and_then(|s| s.as_str())
        .unwrap_or("GET")
        .to_string();
    let url = v
        .get("url")
        .and_then(|s| s.as_str())
        .unwrap_or("")
        .to_string();
    let mut curl = String::from("curl");
    curl.push_str(&format!(" -X {method}"));
    if let Some(headers) = v.get("headers").and_then(|h| h.as_array()) {
        for h in headers {
            if let Some(pair) = h.as_array()
                && pair.len() == 2
                && let (Some(name), Some(value)) = (pair[0].as_str(), pair[1].as_str())
            {
                let escaped_value = value.replace('\'', r"'\''");
                curl.push_str(&format!(" -H '{name}: {escaped_value}'"));
            }
        }
    }
    if let Some(body) = v.get("request_body").and_then(|b| b.as_str())
        && !body.is_empty()
    {
        let escaped_body = body.replace('\'', r"'\''");
        curl.push_str(&format!(" --data-raw '{escaped_body}'"));
    }
    curl.push_str(&format!(" '{url}'"));
    (curl, method, url)
}

/// Read the last `n` history entries (most recent last). Used by the
/// (future) Ctrl+H history modal. Reads the entire file and tail-truncates,
/// which is fine for files up to a few MB; rotate later if needed.
pub fn tail(workspace: &Path, n: usize) -> Vec<Value> {
    let path = workspace.join(".rqst").join("history.jsonl");
    let Ok(text) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut out: Vec<Value> = text
        .lines()
        .rev()
        .take(n)
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    out.reverse();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── redaction ────────────────────────────────────────────────

    #[test]
    fn templated_auth_header_is_stored_unexpanded_so_replay_still_works() {
        // The point of the design: no secret on disk AND the history
        // entry stays runnable, because replay re-expands the var.
        let out = header_value_for_history("Authorization", "Bearer {{TOKEN}}", "Bearer sk-live-1");
        assert_eq!(out, "Bearer {{TOKEN}}");
        assert!(!out.contains("sk-live-1"));
    }

    #[test]
    fn hardcoded_auth_header_is_redacted() {
        // Nothing to re-expand from, so replayability has to give.
        let out = header_value_for_history("authorization", "Bearer sk-live-1", "Bearer sk-live-1");
        assert!(out.contains("redacted"));
        assert!(!out.contains("sk-live-1"));
    }

    #[test]
    fn ordinary_headers_keep_their_expanded_value() {
        let out = header_value_for_history("Accept", "{{FMT}}", "application/json");
        assert_eq!(out, "application/json");
    }

    #[test]
    fn sensitive_header_matching_is_case_insensitive() {
        for name in ["Authorization", "AUTHORIZATION", "x-api-key", "X-Api-Key"] {
            assert!(is_sensitive_header(name), "{name} should be sensitive");
        }
        for name in ["Accept", "Content-Type", "X-Request-Id"] {
            assert!(!is_sensitive_header(name), "{name} should not be");
        }
    }

    #[test]
    fn body_prefers_the_template_form() {
        let out = body_for_history(
            r#"{"client_secret":"{{SECRET}}"}"#,
            r#"{"client_secret":"live-value"}"#,
        );
        assert!(!out.contains("live-value"));
    }

    #[test]
    fn literal_credential_fields_in_a_body_are_scrubbed() {
        let out = scrub_sensitive_fields(r#"{"user":"ava","password":"hunter2"}"#);
        assert!(!out.contains("hunter2"), "got: {out}");
        assert!(out.contains("ava"), "non-secret fields survive: {out}");
        assert!(out.contains("password"), "field NAME is kept: {out}");
    }

    #[test]
    fn form_encoded_credentials_are_scrubbed() {
        let out = scrub_sensitive_fields("grant_type=password&client_secret=abc123&scope=read");
        assert!(!out.contains("abc123"), "got: {out}");
        assert!(out.contains("scope=read"), "rest survives: {out}");
    }

    #[test]
    fn body_without_credential_fields_is_untouched() {
        let body = r#"{"name":"ava","tags":["a","b"],"count":3}"#;
        assert_eq!(scrub_sensitive_fields(body), body);
    }

    #[test]
    fn scrubbing_a_malformed_body_does_not_panic() {
        // Bodies are often not JSON at all, and a truncated one must
        // still be handled — this runs on every request.
        for body in [
            r#"{"password":"#,
            r#"password"#,
            r#"{"password":"unterminated"#,
            "password=",
            "",
            "{{password}}",
        ] {
            let _ = scrub_sensitive_fields(body);
        }
    }

    #[test]
    fn residual_bearer_values_are_caught_by_the_safety_net() {
        assert!(scrub_residual_credentials("Bearer sk-ant-abcdefghijklmnop").contains("redacted"));
        assert!(scrub_residual_credentials("application/json") == "application/json");
    }

    #[test]
    fn persisted_entry_never_contains_a_hardcoded_secret() {
        // End-to-end through the actual writer, since that's where a
        // missed sanitiser would show up.
        let dir = tempfile::tempdir().unwrap();
        let headers = vec![
            (
                "Authorization".to_string(),
                "Bearer sk-live-SECRET".to_string(),
            ),
            ("Accept".to_string(), "application/json".to_string()),
        ];
        append(
            dir.path(),
            &Entry {
                method: "POST",
                url: "https://api.example.com/login",
                status: Some(200),
                duration_ms: Some(5),
                body_bytes: Some(2),
                error: None,
                headers: Some(&headers),
                request_body: Some(r#"{"password":"hunter2"}"#),
            },
        );
        let text = std::fs::read_to_string(dir.path().join(".rqst/history.jsonl")).unwrap();
        assert!(!text.contains("sk-live-SECRET"), "header leaked:\n{text}");
        assert!(!text.contains("hunter2"), "body leaked:\n{text}");
        assert!(text.contains("application/json"), "benign header kept");
    }

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rqst-history-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn append_writes_jsonl_in_dot_rqst() {
        let dir = temp("append");
        append(
            &dir,
            &Entry {
                method: "POST",
                url: "https://x/y",
                status: Some(200),
                duration_ms: Some(123),
                body_bytes: Some(456),
                error: None,
                headers: None,
                request_body: None,
            },
        );
        let path = dir.join(".rqst/history.jsonl");
        assert!(path.exists());
        let text = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 1);
        let parsed: Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(parsed["method"], "POST");
        assert_eq!(parsed["status"], 200);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tail_returns_last_n_entries_in_order() {
        let dir = temp("tail");
        for i in 0..5 {
            append(
                &dir,
                &Entry {
                    method: "GET",
                    url: &format!("https://x/{i}"),
                    status: Some(200),
                    duration_ms: Some(i),
                    body_bytes: Some(0),
                    error: None,
                    headers: None,
                    request_body: None,
                },
            );
        }
        let recent = tail(&dir, 3);
        assert_eq!(recent.len(), 3);
        // last three URLs in insertion order
        assert_eq!(recent[0]["url"], "https://x/2");
        assert_eq!(recent[1]["url"], "https://x/3");
        assert_eq!(recent[2]["url"], "https://x/4");
        let _ = fs::remove_dir_all(&dir);
    }

    // Serialize the two tests that mutate the process-wide
    // MNML_HISTORY_GLOBAL_PATH env var. Serialized against every
    // other process-env mutator across the crate via
    // crate::test_env_lock(), so a discovery/cdp/prompt HOME test
    // can't race the global-history-path override.

    #[test]
    fn append_with_global_mirror_writes_workspace_and_global() {
        let _guard = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = temp("mirror");
        let global = dir.join("global.jsonl");
        // EnvGuard restores MNML_HISTORY_GLOBAL_PATH on scope exit,
        // panic-safe. Prior manual save/restore skipped restoration
        // whenever a mid-test assertion failed.
        let _env = crate::EnvGuard::set("MNML_HISTORY_GLOBAL_PATH", &global);
        append_with_global_mirror(
            &dir,
            &Entry {
                method: "GET",
                url: "https://x/global",
                status: Some(200),
                duration_ms: Some(7),
                body_bytes: Some(0),
                error: None,
                headers: None,
                request_body: None,
            },
        );
        assert!(dir.join(".rqst/history.jsonl").exists());
        assert!(global.exists());
        let text = fs::read_to_string(&global).unwrap();
        let entry: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(entry["url"], "https://x/global");
        assert!(entry["workspace"].as_str().is_some());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tail_global_returns_n_recent_from_env_path() {
        let _guard = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = temp("tail-global");
        let global = dir.join("global.jsonl");
        let _env = crate::EnvGuard::set("MNML_HISTORY_GLOBAL_PATH", &global);
        for i in 0..4 {
            append_with_global_mirror(
                &dir,
                &Entry {
                    method: "GET",
                    url: &format!("https://x/g/{i}"),
                    status: Some(200),
                    duration_ms: Some(i),
                    body_bytes: Some(0),
                    error: None,
                    headers: None,
                    request_body: None,
                },
            );
        }
        let recent = tail_global(2);
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0]["url"], "https://x/g/2");
        assert_eq!(recent[1]["url"], "https://x/g/3");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_records_error_when_set() {
        let dir = temp("err");
        append(
            &dir,
            &Entry {
                method: "GET",
                url: "https://broken",
                status: None,
                duration_ms: None,
                body_bytes: None,
                error: Some("connection refused"),
                headers: None,
                request_body: None,
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries[0]["status"], serde_json::Value::Null);
        assert_eq!(entries[0]["error"], "connection refused");
        let _ = fs::remove_dir_all(&dir);
    }

    /// test-writer 2026-06-28 coverage gap: the new headers +
    /// request_body fields must persist correctly. Without this
    /// lock-in, an accidental rename in the json! call would
    /// silently break picker.rs's curl-rebuild path.
    #[test]
    fn append_writes_headers_and_body_to_jsonl() {
        let dir = temp("headers-body");
        let headers = vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("Authorization".to_string(), "Bearer abc123".to_string()),
        ];
        let body = r#"{"name":"alice"}"#;
        append(
            &dir,
            &Entry {
                method: "POST",
                url: "https://x/y",
                status: Some(200),
                duration_ms: Some(50),
                body_bytes: Some(10),
                error: None,
                headers: Some(&headers),
                request_body: Some(body),
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries.len(), 1);
        let v = &entries[0];
        let h = v["headers"].as_array().expect("headers is array");
        assert_eq!(h.len(), 2);
        assert_eq!(h[0][0], "Content-Type");
        assert_eq!(h[0][1], "application/json");
        // 2026-08-26 — this used to assert `Bearer abc123` round-tripped
        // verbatim, which is exactly the leak being fixed: the header
        // name is still recorded (so the entry shows an authed request
        // was made) but a hard-coded credential never reaches disk.
        // A `{{VAR}}` form would be preserved instead — see
        // `templated_auth_header_is_stored_unexpanded_so_replay_still_works`.
        assert_eq!(h[1][0], "Authorization");
        assert!(
            h[1][1].as_str().is_some_and(|s| s.contains("redacted")),
            "expected redaction, got {:?}",
            h[1][1]
        );
        assert_eq!(v["request_body"].as_str(), Some(body));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_with_none_headers_and_body_serialises_null() {
        let dir = temp("none-headers");
        append(
            &dir,
            &Entry {
                method: "GET",
                url: "https://x/y",
                status: Some(200),
                duration_ms: Some(5),
                body_bytes: Some(0),
                error: None,
                headers: None,
                request_body: None,
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries[0]["headers"], serde_json::Value::Null);
        assert_eq!(entries[0]["request_body"], serde_json::Value::Null);
        let _ = fs::remove_dir_all(&dir);
    }
}
