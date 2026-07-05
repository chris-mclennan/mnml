//! HTTP send + `.http` / `.curl` / `.rest` file + request pane.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move: no API
//! change. Owns the `http.*` palette commands, the background HTTP
//! worker thread, request-pane multi-block writeback, and the
//! `splice_http_block` free fn.

use super::*;

/// Result of a backgrounded `:ws.send` worker.
pub struct WsSendReply {
    pub url: String,
    pub message: String,
    pub result: Result<WsSendOutput, String>,
}

pub struct WsSendOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub elapsed_ms: u128,
}

/// Run `websocat --exit-on-eof -n1 <url>` with `message` written to
/// stdin. Polls for child exit up to `timeout_ms`; kills + reports
/// "timeout" on overrun. Called from a worker thread.
fn run_websocat_send(
    url: &str,
    message: &str,
    timeout_ms: u64,
    headers: &[(String, String)],
) -> Result<WsSendOutput, String> {
    let mut cmd = std::process::Command::new("websocat");
    cmd.arg("--exit-on-eof").arg("-n1").arg(url);
    for (k, v) in headers {
        cmd.arg("-H").arg(format!("{k}: {v}"));
    }
    cmd.stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn websocat: {e} (is it on PATH?)"))?;
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        let _ = writeln!(stdin, "{message}");
        drop(stdin);
    }
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                let out = child
                    .wait_with_output()
                    .map_err(|e| format!("websocat wait: {e}"))?;
                return Ok(WsSendOutput {
                    stdout: out.stdout,
                    stderr: out.stderr,
                    elapsed_ms: started.elapsed().as_millis(),
                });
            }
            Ok(None) => {
                if started.elapsed().as_millis() as u64 > timeout_ms {
                    let _ = child.kill();
                    return Err(format!("timeout after {timeout_ms}ms"));
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(e) => return Err(format!("websocat: {e}")),
        }
    }
}

/// Replace the named block inside an `.http` / `.rest` source with the
/// pre-rendered `new_block` text, leaving every other block untouched.
/// `name` is what `RequestPane.source_block_name` stored — `Some(s)` means
/// the matched block had `### s` (or `### ` alone when `s.is_empty()`); the
/// only `None` case here is a single-block file, which the caller handles
/// separately. Returns `None` when the file no longer parses as multi-block,
/// or no block matches — caller falls back to whole-file overwrite.
fn splice_http_block(existing: &str, name: Option<&str>, new_block: &str) -> Option<String> {
    let blocks = crate::http::file::parse_all(existing).ok()?;
    if blocks.len() < 2 {
        return None;
    }
    let lines: Vec<&str> = existing.split('\n').collect();
    // Resolve the `### name` separator on each block (`Block.name` is the text
    // after `###`; we also need to know whether the block had a separator at
    // all, since the leading block in a multi-block file doesn't).
    let block_separator_name = |b: &crate::http::file::Block| -> Option<String> {
        lines
            .get(b.start_line)
            .and_then(|l| l.trim_start().strip_prefix("###"))
            .map(|rest| rest.trim().to_string())
    };
    let target_idx = blocks.iter().position(|b| match name {
        // Match both "had a `###` separator" and the right name.
        Some(want) => block_separator_name(b).is_some_and(|n| n == want),
        // We only call this with `Some(name)` from the caller, but stay safe.
        None => block_separator_name(b).is_none(),
    })?;
    let target = &blocks[target_idx];
    let last_idx = lines.len().saturating_sub(1);
    let end = target.end_line.min(last_idx);
    // The replacement carries its own trailing newline (from `as_http_block`).
    // Trim it before splicing so the file's existing line structure isn't
    // double-newlined when we re-join.
    let replacement = new_block.trim_end_matches('\n');
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    out.extend(lines[..target.start_line].iter().map(|s| s.to_string()));
    for line in replacement.split('\n') {
        out.push(line.to_string());
    }
    // api-workflow-user 3rd 2026-06-29 SEV-3: preserve the blank
    // separator between the unnamed leading block and the first
    // `###` block. The leading block's `end_line` absorbs the
    // trailing blank line; `as_http_block(None)` doesn't emit a
    // replacement, so the splice removed the blank silently.
    // Restore it by checking whether the line we're about to
    // splice over (lines[end]) was blank AND there's a following
    // `###` block in the suffix — that's the leading-block
    // signature.
    let removed_blank = lines.get(end).is_some_and(|l| l.trim().is_empty());
    let next_starts_with_separator = lines
        .get(end + 1)
        .is_some_and(|l| l.trim_start().starts_with("###"));
    if removed_blank && next_starts_with_separator {
        out.push(String::new());
    }
    if end < last_idx {
        out.extend(lines[end + 1..].iter().map(|s| s.to_string()));
    }
    let mut joined = out.join("\n");
    // Preserve the original file's trailing-newline policy.
    if existing.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    Some(joined)
}

/// Does the `.env` file at `path` contain a (non-comment) line
/// for `key`? Used by `write_env_var` to decide which file gets
/// the write when both `.mnml/env/` and `.rqst/env/` exist.
fn file_contains_env_key(path: &std::path::Path, key: &str) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    text.lines().any(|line| {
        let trimmed = line.trim_start();
        if trimmed.starts_with('#') {
            return false;
        }
        trimmed
            .split_once('=')
            .is_some_and(|(k, _)| k.trim() == key)
    })
}

/// Insert-or-replace a `KEY=VALUE` line in an `.env` file body.
/// Preserves comments + ordering of other keys. If `var` isn't
/// present, appends a new line. Used by the lookup picker's
/// final stage to write picked items to the active env file.
/// Errs only when a malformed value would corrupt the file.
fn upsert_env_var(existing: &str, var: &str, value: &str) -> Result<String, String> {
    if value.contains('\n') {
        return Err("lookup: value can't contain newline".into());
    }
    let mut replaced = false;
    let mut out = String::with_capacity(existing.len() + var.len() + value.len() + 8);
    for line in existing.lines() {
        let trimmed = line.trim_start();
        if !replaced
            && !trimmed.starts_with('#')
            && let Some((k, _)) = trimmed.split_once('=')
            && k.trim() == var
        {
            out.push_str(&format!("{var}={value}\n"));
            replaced = true;
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if !replaced {
        if !out.ends_with('\n') && !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&format!("{var}={value}\n"));
    }
    Ok(out)
}

impl App {
    /// `http.insert_header` — opens a picker over common HTTP
    /// header names. Enter inserts `Name: ` at the active Request
    /// pane's Headers cursor (or appends if no Headers field
    /// focus). Saves the user typing `Content-Type`/`Accept`/etc
    /// from memory.
    pub fn http_insert_header_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        const COMMON_HEADERS: &[(&str, &str)] = &[
            // Content negotiation
            ("Accept", "Acceptable media types for the response"),
            (
                "Accept-Encoding",
                "Acceptable content encodings (gzip, br, …)",
            ),
            ("Accept-Language", "Preferred natural languages"),
            ("Accept-Charset", "Preferred character sets"),
            ("Content-Type", "Media type of the request body"),
            ("Content-Length", "Size of the request body in bytes"),
            (
                "Content-Encoding",
                "Encoding applied to the body (gzip, br, …)",
            ),
            ("Content-Disposition", "Attachment / inline indicator"),
            // Auth + identity
            (
                "Authorization",
                "Credentials for authentication (Bearer, Basic, …)",
            ),
            ("Cookie", "HTTP cookies"),
            ("X-Api-Key", "API key (convention)"),
            ("X-Auth-Token", "Auth token (convention)"),
            // Caching / conditionals
            ("Cache-Control", "Caching directives (no-cache, max-age=…)"),
            ("Pragma", "Implementation-specific cache directives"),
            ("If-Match", "Conditional request — match this ETag"),
            (
                "If-None-Match",
                "Conditional request — NOT this ETag (caching)",
            ),
            (
                "If-Modified-Since",
                "Conditional request — modified after this date",
            ),
            (
                "If-Unmodified-Since",
                "Conditional request — not modified since",
            ),
            // Routing / origin
            ("Host", "Target hostname (usually auto-set by clients)"),
            ("Origin", "Origin of the request (CORS)"),
            ("Referer", "URL of the referring page"),
            ("User-Agent", "Client identification string"),
            // CORS preflight (request side)
            (
                "Access-Control-Request-Method",
                "CORS preflight — intended method",
            ),
            (
                "Access-Control-Request-Headers",
                "CORS preflight — intended headers",
            ),
            // Proxy / forwarding
            ("X-Forwarded-For", "Original client IP (proxy chain)"),
            (
                "X-Forwarded-Proto",
                "Original scheme (http/https) through proxy",
            ),
            ("X-Forwarded-Host", "Original Host header through proxy"),
            ("X-Real-IP", "Original client IP (nginx convention)"),
            // Tracing / debugging
            ("X-Trace-Id", "Distributed-trace correlation id"),
            ("X-Request-Id", "Request correlation id"),
            ("X-Correlation-Id", "Correlation id (convention)"),
            // GraphQL / RPC
            ("X-GraphQL-Operation", "GraphQL operation name"),
            // Misc
            ("X-Requested-With", "XMLHttpRequest / fetch indicator"),
            ("DNT", "Do Not Track preference (1 = opt-out)"),
            ("Upgrade-Insecure-Requests", "1 = prefer HTTPS (CSP)"),
        ];
        let items: Vec<PickerItem> = COMMON_HEADERS
            .iter()
            .map(|(name, hint)| {
                PickerItem::new(name.to_string(), name.to_string(), hint.to_string())
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::HttpHeader,
            "Insert HTTP header",
            items,
        ));
    }

    /// Accept handler for `PickerKind::HttpHeader`. Inserts
    /// `<name>: ` at the Headers cursor (or appends as a new
    /// line if there's existing content).
    pub fn accept_http_header(&mut self, name: &str) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let to_insert = if rp.headers_buffer.is_empty() || rp.headers_buffer.ends_with('\n') {
                format!("{name}: ")
            } else {
                format!("\n{name}: ")
            };
            let cursor = rp.headers_buffer.len();
            rp.headers_buffer.push_str(&to_insert);
            rp.headers_cursor = rp.headers_buffer.len();
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.focus = crate::request_pane::EditField::Headers;
            rp.edit_tab = crate::request_pane::EditTab::Headers;
            self.toast(format!("header: inserted {name}"));
            let _ = cursor;
        }
    }

    /// Open a picker of every `.env` file the workspace knows about
    /// (both `.mnml/env/*.env` and `.rqst/env/*.env`). Accepting a
    /// row sets `App::http_env_override` so subsequent
    /// `EnvSet::select*` calls resolve against the picked env. (#11)
    pub fn open_http_env_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for sub in [".mnml", ".rqst"] {
            let dir = self.workspace.join(sub).join("env");
            if let Ok(rd) = std::fs::read_dir(&dir) {
                for entry in rd.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) == Some("env")
                        && let Some(stem) = path.file_stem().and_then(|s| s.to_str())
                    {
                        seen.insert(stem.to_string());
                    }
                }
            }
        }
        if seen.is_empty() {
            self.toast("http: no `.env` files under `.mnml/env/` or `.rqst/env/`");
            return;
        }
        let current = self.http_env_override.clone().or_else(|| {
            std::env::var("MNML_ENV")
                .ok()
                .filter(|s| !s.trim().is_empty())
        });
        let items: Vec<PickerItem> = seen
            .into_iter()
            .map(|name| {
                let hint = if Some(&name) == current.as_ref() {
                    "current".to_string()
                } else {
                    String::new()
                };
                PickerItem::new(name.clone(), name, hint)
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::HttpEnv, "Pick env", items));
    }

    /// Accept handler for `PickerKind::HttpEnv`. Stores the picked
    /// env name on `App::http_env_override`.
    pub fn accept_http_env(&mut self, name: &str) {
        self.http_env_override = Some(name.to_string());
        self.toast(format!("http env: {name}"));
    }

    /// Clear the runtime env override so `EnvSet::select` falls back
    /// to `MNML_ENV` / config default again.
    pub fn http_reset_env(&mut self) {
        if self.http_env_override.take().is_some() {
            self.toast("http env: reset to default");
        }
    }

    /// Dispatcher for Auth-tab row clicks. `id` matches the
    /// row's stable id stored in App.rects.request_auth_rows.
    pub fn http_auth_row_clicked(&mut self, id: &str) {
        match id {
            "set_bearer" => {
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::HttpAuthBearer,
                    "Bearer token:".to_string(),
                ));
            }
            "set_basic" => {
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::HttpAuthBasic,
                    "Basic auth — user:password:".to_string(),
                ));
            }
            "set_api_key" => {
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::HttpAuthApiKey,
                    "X-Api-Key value:".to_string(),
                ));
            }
            "apply_preset" => self.auth_apply_preset_picker(),
            "save_preset" => self.auth_save_preset_prompt(),
            "clear" => self.http_auth_clear(),
            _ => {}
        }
    }

    /// Replace (or insert) a header on the active Request pane.
    /// Used by the Auth tab to set Authorization / X-Api-Key.
    pub fn http_auth_set(&mut self, name: &str, value: &str) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let pos = rp
                .request
                .headers
                .iter()
                .position(|(k, _)| k.eq_ignore_ascii_case(name));
            if let Some(i) = pos {
                rp.request.headers[i].1 = value.to_string();
            } else {
                rp.request
                    .headers
                    .push((name.to_string(), value.to_string()));
            }
            rp.headers_buffer = crate::request_pane::headers_to_text(&rp.request.headers);
            rp.headers_cursor = rp.headers_buffer.len();
            self.toast(format!("auth: set {name}"));
        }
    }

    /// Remove the Authorization header from the active Request.
    pub fn http_auth_clear(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let pre = rp.request.headers.len();
            rp.request
                .headers
                .retain(|(k, _)| !k.eq_ignore_ascii_case("authorization"));
            if rp.request.headers.len() < pre {
                rp.headers_buffer = crate::request_pane::headers_to_text(&rp.request.headers);
                rp.headers_cursor = rp.headers_buffer.len();
                self.toast("auth: cleared Authorization");
            } else {
                self.toast("auth: no Authorization header to clear");
            }
        }
    }

    /// `http.save_response` — open a prompt for the destination
    /// path; on Enter, write the active Done response body there.
    pub fn http_save_response_prompt(&mut self) {
        use crate::request_pane::RunState;
        let has_done = matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(rp)) if matches!(rp.state, RunState::Done(_))
        );
        if !has_done {
            self.toast("http.save_response: no Done response on active pane");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::HttpSaveResponse,
            "Save response to file:".to_string(),
        ));
    }

    /// Accept handler for `PromptKind::HttpSaveResponse`. Writes
    /// the active pane's Done response body to `path`.
    pub fn http_save_response_to(&mut self, path: &str) {
        use crate::request_pane::RunState;
        let path = path.trim();
        if path.is_empty() {
            self.toast("save: path can't be empty");
            return;
        }
        let Some(cur) = self.active else { return };
        let body = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => match &rp.state {
                RunState::Done(r) => r.body.clone(),
                _ => return,
            },
            _ => return,
        };
        let p = if path.starts_with('/') {
            std::path::PathBuf::from(path)
        } else {
            self.workspace.join(path)
        };
        if let Some(parent) = p.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("save: mkdir {}: {e}", parent.display()));
            return;
        }
        match std::fs::write(&p, &body) {
            Ok(()) => self.toast(format!(
                "save: wrote {} bytes → {}",
                body.len(),
                p.display()
            )),
            Err(e) => self.toast(format!("save: write {}: {e}", p.display())),
        }
    }

    /// `:http.run_chain` — picker over `.mnml/chains/*.chain.json`.
    /// Accept fires the chain in a worker thread; the step-by-step
    /// trace lands in a `[chain-trace]` scratch when done. Postman
    /// runner arc — Postman collections are imported into mnml's
    /// chain format via `:http.import_postman` then run with this.
    pub fn open_http_chain_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let chains_dir = self.workspace.join(".mnml").join("chains");
        let mut entries: Vec<std::path::PathBuf> = match std::fs::read_dir(&chains_dir) {
            Ok(rd) => rd
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.file_name()
                        .and_then(|s| s.to_str())
                        .is_some_and(|n| n.ends_with(".chain.json"))
                })
                .collect(),
            Err(_) => Vec::new(),
        };
        if entries.is_empty() {
            self.toast(format!(
                "http.run_chain: no chains at {}",
                chains_dir.display()
            ));
            return;
        }
        entries.sort();
        let items: Vec<PickerItem> = entries
            .iter()
            .map(|p| {
                let name = p
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("?")
                    .trim_end_matches(".chain.json")
                    .to_string();
                let n_steps = std::fs::read_to_string(p)
                    .ok()
                    .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
                    .and_then(|v| v.as_array().map(|a| a.len()))
                    .unwrap_or(0);
                PickerItem::new(
                    p.to_string_lossy().to_string(),
                    name,
                    format!("{n_steps} step(s)"),
                )
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::HttpChains, "HTTP chains", items));
    }

    /// Backing for the `HttpChains` picker's accept handler — spawn
    /// a worker that runs the chain and replies via
    /// `http_chain_chan`.
    pub fn http_chain_run_path(&mut self, chain_file: std::path::PathBuf) {
        if self.http_chain_in_flight {
            self.toast("http.run_chain: a chain is already running");
            return;
        }
        let tx = self
            .http_chain_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let workspace = self.workspace.clone();
        // qa-7th api SEV-2 2026-06-30 — chain runner ignored the
        // `[http] default_env` TOML config. Other call sites use
        // EnvSet::select_with_config_default; chain went straight
        // through `std::env::var`. Fall back to the config default
        // when MNML_ENV isn't set.
        let env_name = std::env::var("MNML_ENV")
            .ok()
            .or_else(|| self.config.http.default_env.clone());
        // 2026-06-21 — pass the cookie jar to the chain runner so
        // multi-step authenticated flows (login → use session
        // cookie) actually work.
        let cookie_jar = self.cookie_jar.clone();
        self.http_chain_in_flight = true;
        self.toast(format!(
            "chain: running {}…",
            chain_file
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("?")
        ));
        std::thread::Builder::new()
            .name("mnml-chain-run".into())
            .spawn(move || {
                let mut trace = String::new();
                let result = crate::http::chain::run(
                    &chain_file,
                    &workspace,
                    env_name.as_deref(),
                    &mut trace,
                    Some(cookie_jar),
                );
                let _ = tx.send((trace, result));
            })
            .ok();
    }

    /// `tick` hook — drain `:http.run_chain` worker replies.
    pub fn drain_http_chain(&mut self) {
        let replies: Vec<(String, Result<(), String>)> = match &self.http_chain_chan {
            Some((_, rx)) => rx.try_iter().collect(),
            None => return,
        };
        for (trace, result) in replies {
            self.http_chain_in_flight = false;
            let mut body = trace;
            let summary = match &result {
                Ok(()) => "✓ chain completed successfully".to_string(),
                Err(e) => format!("✗ chain failed: {e}"),
            };
            body.push_str("\n────\n");
            body.push_str(&summary);
            body.push('\n');
            self.open_scratch_with_text("[chain-trace]".to_string(), body);
            self.toast(summary);
        }
    }

    /// `:http.ai_build` — open a prompt asking for a natural-language
    /// request description, then spawn a worker that calls Claude
    /// (`api_client::nl_to_curl`). The reply lands as a curl command;
    /// `drain_http_ai_build` parses it, opens a new Request pane,
    /// switches it to the Source tab so the user can see what came
    /// back. Requires `$ANTHROPIC_API_KEY`.
    pub fn http_ai_build_prompt(&mut self) {
        if std::env::var("ANTHROPIC_API_KEY").is_err() {
            self.toast("http.ai_build: $ANTHROPIC_API_KEY not set");
            return;
        }
        if self.http_ai_build_in_flight {
            self.toast("http.ai_build: a build is already in flight");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::HttpAiBuild,
            "Describe the request (NL → curl):".to_string(),
        ));
    }

    /// Accept handler for the `HttpAiBuild` prompt. Spawns a worker
    /// thread calling `api_client::nl_to_curl`.
    pub fn http_ai_build_accept(&mut self, description: String) {
        if description.trim().is_empty() {
            self.toast("http.ai_build: empty description");
            return;
        }
        let tx = self
            .http_ai_build_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let model = self.ai_model();
        self.http_ai_build_in_flight = true;
        self.toast("http.ai_build: calling Claude…");
        std::thread::Builder::new()
            .name("mnml-http-ai-build".into())
            .spawn(move || {
                let result = crate::ai::api_client::nl_to_curl(&description, model.as_deref());
                let _ = tx.send(result);
            })
            .ok();
    }

    /// `tick` hook — drain replies from the `:http.ai_build` worker.
    /// Parses the curl reply + opens a new Request pane with the
    /// parsed request loaded. Single-shot per call.
    pub fn drain_http_ai_build(&mut self) {
        let replies: Vec<Result<String, String>> = match &self.http_ai_build_chan {
            Some((_, rx)) => rx.try_iter().collect(),
            None => return,
        };
        for result in replies {
            self.http_ai_build_in_flight = false;
            match result {
                Ok(curl) => match crate::http::parse(&curl) {
                    Ok(parsed) => {
                        self.open_new_request_pane();
                        // 2026-06-21 api-workflow SEV-2: was
                        // `let Some(cur) = self.active else { continue };`
                        // which silently dropped the AI-built curl
                        // if open_new_request_pane somehow didn't
                        // set self.active. Now: toast a clear
                        // error and skip; the user knows Claude's
                        // reply was lost.
                        let Some(cur) = self.active else {
                            self.toast(
                                "http.ai_build: couldn't open a Request pane — reply dropped",
                            );
                            continue;
                        };
                        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
                            rp.headers_buffer =
                                crate::request_pane::headers_to_text(&parsed.headers);
                            rp.headers_cursor = rp.headers_buffer.len();
                            rp.url_cursor = parsed.url.len();
                            rp.body_cursor = parsed.body.as_deref().map(str::len).unwrap_or(0);
                            rp.source_buffer = curl.clone();
                            rp.source_cursor = curl.len();
                            rp.request = parsed;
                            rp.view = crate::request_pane::ViewMode::Edit;
                            // Land on the Source tab so the user
                            // immediately sees the curl Claude
                            // produced (auditable before re-firing).
                            rp.edit_tab = crate::request_pane::EditTab::Source;
                        } else {
                            self.toast(
                                "http.ai_build: opened pane wasn't a Request pane — reply dropped",
                            );
                            continue;
                        }
                        self.toast("http.ai_build: ✓ ready (Source tab)");
                    }
                    Err(e) => {
                        self.toast(format!("http.ai_build: parse failed: {e}"));
                    }
                },
                Err(e) => {
                    self.toast(format!("http.ai_build: {e}"));
                }
            }
        }
    }

    /// `:ws.connect` — open a Prompt for a wss:// URL. Each
    /// connection opens its own `Pane::Websocket`; multiple
    /// connections can run side by side.
    pub fn ws_connect_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::WsConnect,
            "WebSocket URL (wss://…):".to_string(),
        ));
    }

    /// `:ws.send_message` — open a Prompt for the message to send.
    /// The message goes to the focused `Pane::Websocket`.
    pub fn ws_send_message_prompt(&mut self) {
        let Some(i) = self.active else {
            self.toast("ws: focus a ws pane first");
            return;
        };
        if !matches!(self.panes.get(i), Some(Pane::Websocket(_))) {
            self.toast("ws: focus a ws pane first");
            return;
        }
        // 2026-06-21 api-workflow SEV-3: stash the WS pane index
        // at prompt-open time so the accept handler sends to the
        // right pane even if the user switched focus mid-prompt.
        // Was: accept handler re-checked `self.active`; switching
        // panes silently dropped the typed message.
        self.pending_ws_send_pane = Some(i);
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::WsSendMessage,
            "Message to send:".to_string(),
        ));
    }

    /// `:ws.disconnect` — close the focused WS pane's connection.
    /// The pane stays open showing the final log; user closes it
    /// like any other pane (`:close` / `Ctrl+W`).
    pub fn ws_disconnect(&mut self) {
        let Some(i) = self.active else {
            self.toast("ws: no focused pane");
            return;
        };
        if let Some(Pane::Websocket(p)) = self.panes.get_mut(i) {
            p.close();
            self.toast("ws: closing…");
        } else {
            self.toast("ws: focus a ws pane first");
        }
    }

    /// Accept handler — actually connects. Opens a new pane split
    /// off the active leaf.
    pub fn ws_connect_to(&mut self, url: &str) {
        let url = url.trim().to_string();
        if url.is_empty() {
            self.toast("ws: URL can't be empty");
            return;
        }
        // 2026-06-21 power-user-ws-git SEV-3: reject obviously
        // non-WS schemes up front so the user doesn't end up
        // staring at a zombie `· closed` tab while wondering
        // what happened. http:// / https:// / file:// / etc. are
        // dropped here; ws:// + wss:// pass through, and bare
        // host:port goes through (tungstenite accepts the
        // protocol-less form).
        let lower = url.to_lowercase();
        if !lower.starts_with("ws://") && !lower.starts_with("wss://") {
            // Allow bare host:port (no scheme at all) but reject
            // anything with a scheme that ISN'T ws/wss.
            if lower.contains("://") {
                self.toast(format!(
                    "ws: only ws:// and wss:// URLs are supported (got {url})"
                ));
                return;
            }
        }
        let opts = crate::websocket::WsConnectOpts {
            subprotocols: self.config.ws.subprotocols.clone(),
            ping_interval_secs: self.config.ws.ping_interval_secs,
            reconnect_max_attempts: self.config.ws.reconnect_max_attempts,
        };
        let pane = Pane::Websocket(crate::websocket::WebsocketPane::connect(url.clone(), opts));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
        self.toast(format!("ws: connecting to {url}"));
    }

    /// Accept handler — sends the typed message on the focused WS pane.
    pub fn ws_send_on_active(&mut self, message: &str) {
        // Prefer the pane we were focused on at prompt-open time
        // (stashed in `pending_ws_send_pane`). Fall back to current
        // focus for backward compat / direct callers.
        let target = self.pending_ws_send_pane.take().or(self.active);
        let Some(i) = target else {
            self.toast("ws: no focused pane");
            return;
        };
        let Some(Pane::Websocket(p)) = self.panes.get_mut(i) else {
            self.toast("ws: focus a ws pane first (was the WS pane closed?)");
            return;
        };
        p.input = message.to_string();
        p.input_cursor = message.len();
        p.send_input();
    }

    /// Drain incoming WebSocket events for every `Pane::Websocket`.
    /// Called from `App.tick`.
    pub fn drain_websocket(&mut self) {
        for i in 0..self.panes.len() {
            if let Some(Pane::Websocket(p)) = self.panes.get_mut(i) {
                p.drain();
            }
        }
    }

    /// `ws.send` — one-shot WebSocket fire-and-receive via the
    /// system `websocat` binary. Sends `message`, waits for a
    /// single response, closes. Multi-round-trip or persistent
    /// streams are v2 (would need a Pane::Websocket).
    ///
    /// Active editor JSON shape:
    ///   { "url": "wss://…",
    ///     "message": "string payload",
    ///     "timeout_ms": 5000,  // optional
    ///     "headers": { "name": "value" } } // optional
    pub fn ws_send_active(&mut self) {
        let buf_text = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) => b.editor.text().to_string(),
            _ => {
                self.toast("ws.send: no active editor");
                return;
            }
        };
        let cfg: serde_json::Value = match serde_json::from_str(&buf_text) {
            Ok(v) => v,
            Err(e) => {
                self.toast(format!("ws.send: not valid JSON: {e}"));
                return;
            }
        };
        let url = cfg.get("url").and_then(|v| v.as_str()).map(str::to_string);
        let Some(url) = url else {
            self.toast("ws.send: missing 'url' field");
            return;
        };
        let message = cfg
            .get("message")
            .map(|v| match v {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            })
            .unwrap_or_default();
        let timeout_ms = cfg
            .get("timeout_ms")
            .and_then(|v| v.as_u64())
            .unwrap_or(5000);
        let headers: Vec<(String, String)> = cfg
            .get("headers")
            .and_then(|v| v.as_object())
            .map(|obj| {
                obj.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        let tx = self
            .ws_send_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let worker_url = url.clone();
        let worker_msg = message.clone();
        self.toast(format!("ws: connecting {url}…"));
        // 2026-06-21 — was: busy-polled child.wait_with_output() on
        // the main app thread for up to timeout_ms ms, freezing
        // every render tick (the api-workflow SEV-1 finding). Now:
        // spawn a worker that does the websocat call + sends back
        // the result via `ws_send_chan`; drain_ws_send opens the
        // scratch when it arrives.
        std::thread::Builder::new()
            .name("mnml-ws-send".into())
            .spawn(move || {
                let result = run_websocat_send(&worker_url, &worker_msg, timeout_ms, &headers);
                let _ = tx.send(WsSendReply {
                    url: worker_url,
                    message: worker_msg,
                    result,
                });
            })
            .ok();
    }

    /// Tick hook — render any completed `:ws.send` worker replies
    /// into a `[ws-response]` scratch.
    pub fn drain_ws_send(&mut self) {
        let replies: Vec<WsSendReply> = match &self.ws_send_chan {
            Some((_, rx)) => rx.try_iter().collect(),
            None => return,
        };
        for reply in replies {
            let mut body = format!("# ws {}\n\n## sent\n\n{}\n\n", reply.url, reply.message);
            match reply.result {
                Ok(out) => {
                    let stdout = String::from_utf8_lossy(&out.stdout);
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    if !stdout.is_empty() {
                        body.push_str("## received\n\n");
                        body.push_str(&stdout);
                    }
                    if !stderr.is_empty() {
                        body.push_str("\n## stderr\n\n");
                        body.push_str(&stderr);
                    }
                    self.toast(format!("ws: ok ({}ms) → [ws-response]", out.elapsed_ms));
                }
                Err(e) => {
                    body.push_str(&format!("\n## error\n\n{e}\n"));
                    self.toast(format!("ws.send: {e}"));
                }
            }
            self.open_scratch_with_text("[ws-response]".to_string(), body);
        }
    }

    /// 2026-06-21 — `:ws.history` opens a picker over past
    /// connections. Reads `~/.mnml/ws-history/*/history.jsonl`,
    /// sorts by last activity desc, shows URL + msg count.
    /// Accept opens a connection to that URL and a `[ws-history-
    /// <host>]` scratch with the last 200 lines of the history
    /// for context.
    pub fn ws_history_picker(&mut self) {
        let rows = crate::websocket::read_ws_history();
        if rows.is_empty() {
            self.toast("ws.history: empty (no past connections persisted)");
            return;
        }
        use crate::picker::{Picker, PickerItem, PickerKind};
        let items: Vec<PickerItem> = rows
            .into_iter()
            .map(|(url, _ts, count)| {
                let detail = format!("{count} msgs");
                PickerItem::new(url.clone(), url, detail)
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::WsHistory,
            "ws history (past connections)",
            items,
        ));
    }

    /// Accept handler for `:ws.history` picker — open a scratch
    /// with the last 200 history lines and start a fresh
    /// connection to the same URL.
    pub fn ws_history_open(&mut self, url: String) {
        // 1) Seed a scratch with the last ~200 lines of history
        // so the user can see what they've sent / received.
        if let Some(home) = std::env::var_os("HOME") {
            let host = url
                .strip_prefix("wss://")
                .or_else(|| url.strip_prefix("ws://"))
                .unwrap_or(&url)
                .split('/')
                .next()
                .unwrap_or("?");
            let slug: String = host
                .replace(':', "_")
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-' {
                        c
                    } else {
                        '_'
                    }
                })
                .collect();
            let path = std::path::PathBuf::from(home)
                .join(".mnml/ws-history")
                .join(&slug)
                .join("history.jsonl");
            if let Ok(text) = std::fs::read_to_string(&path) {
                let lines: Vec<&str> = text.lines().collect();
                let start = lines.len().saturating_sub(200);
                let mut body = format!("# ws history — {host}\n\n");
                for l in &lines[start..] {
                    body.push_str(l);
                    body.push('\n');
                }
                self.open_scratch_with_text(format!("[ws-history-{host}]"), body);
            }
        }
        // 2) Start a fresh connection to the URL.
        self.ws_connect_to(&url);
    }

    /// `http.format_body` — parse the active Request pane's Body
    /// as JSON and rewrite with 2-space indent. No-op if Body
    /// isn't valid JSON (toasts the parse error).
    pub fn http_format_body(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.format_body: no active Request pane");
            return;
        };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let body = match rp.request.body.as_deref() {
                Some(b) if !b.trim().is_empty() => b.to_string(),
                _ => {
                    self.toast("http.format_body: Body is empty");
                    return;
                }
            };
            match serde_json::from_str::<serde_json::Value>(&body) {
                Ok(v) => match serde_json::to_string_pretty(&v) {
                    Ok(pretty) => {
                        rp.body_cursor = pretty.len();
                        rp.request.body = Some(pretty);
                        self.toast("body: formatted as JSON");
                    }
                    Err(e) => self.toast(format!("body: format failed: {e}")),
                },
                Err(e) => self.toast(format!("body: not valid JSON: {e}")),
            }
        }
    }

    /// `http.show_schema_errors` — opens a `[schema-errors]` scratch
    /// with the full validator-error list for the active Request
    /// pane's last response. Falls back to a toast when there's no
    /// validation result on the response (no sidecar, or response
    /// already validated cleanly).
    pub fn http_show_schema_errors(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.show_schema_errors: no active Request pane");
            return;
        };
        use crate::request_pane::RunState;
        let (status, errors, schema_path) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => match &rp.state {
                RunState::Done(rv) | RunState::Streaming(rv) => {
                    // 2026-06-21 api-workflow SEV-2 — distinguish
                    // "no sidecar" from "validation not yet run".
                    // For streaming responses, schema_result is None
                    // until Close; the old toast falsely blamed the
                    // sidecar.
                    let Some(sr) = rv.schema_result.as_ref() else {
                        if matches!(rp.state, RunState::Streaming(_)) {
                            self.toast(
                                "schema: stream still open — wait for close before validating",
                            );
                        } else {
                            self.toast("schema: no sidecar (.schema.json) for this request");
                        }
                        return;
                    };
                    (sr.status.clone(), sr.errors.clone(), sr.schema_path.clone())
                }
                _ => {
                    self.toast("schema: no completed response");
                    return;
                }
            },
            _ => {
                self.toast("http.show_schema_errors: not a Request pane");
                return;
            }
        };
        use crate::http::schema::SchemaStatus;
        let sidecar = schema_path
            .as_ref()
            .and_then(|p| p.to_str())
            .unwrap_or("<unknown>");
        let body = match status {
            SchemaStatus::Valid => {
                self.toast(format!("✓ schema valid ({sidecar})"));
                return;
            }
            SchemaStatus::NoSidecar => {
                self.toast("schema: no sidecar (.schema.json) for this request");
                return;
            }
            SchemaStatus::NotJson => format!("Body isn't JSON — schema ({sidecar}) skipped.\n"),
            SchemaStatus::ReadError(e) => {
                format!("Schema read error ({sidecar}):\n  {e}\n")
            }
            SchemaStatus::SchemaParseError(e) => {
                format!("Schema parse error ({sidecar}):\n  {e}\n")
            }
            SchemaStatus::Invalid => {
                let mut out = format!("✗ Schema validation failed ({sidecar})\n");
                out.push_str(&format!("  {} error(s):\n\n", errors.len()));
                for (i, e) in errors.iter().enumerate() {
                    out.push_str(&format!("  {:>3}. {e}\n", i + 1));
                }
                out
            }
        };
        self.open_scratch_with_text("[schema-errors]".to_string(), body);
    }

    /// `http.revalidate_schema` — re-run schema validation against
    /// the existing response body. Useful after editing the
    /// sidecar `.schema.json` without re-firing the request.
    pub fn http_revalidate_schema(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.revalidate_schema: no active Request pane");
            return;
        };
        use crate::request_pane::RunState;
        let (source_path, body) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => match &rp.state {
                RunState::Done(rv) => (rp.source_path.clone(), rv.body.clone()),
                RunState::Streaming(_) => {
                    self.toast("schema: stream still open — wait for close before revalidating");
                    return;
                }
                _ => {
                    self.toast("schema: no completed response");
                    return;
                }
            },
            _ => {
                self.toast("http.revalidate_schema: not a Request pane");
                return;
            }
        };
        let result = crate::http::schema::validate_for(source_path.as_deref(), &body);
        let summary = match &result.status {
            crate::http::schema::SchemaStatus::Valid => "✓ schema re-validated: valid".to_string(),
            crate::http::schema::SchemaStatus::Invalid => {
                format!("✗ schema re-validated: {} error(s)", result.errors.len())
            }
            crate::http::schema::SchemaStatus::NoSidecar => {
                "schema: no sidecar (.schema.json) for this request".to_string()
            }
            crate::http::schema::SchemaStatus::NotJson => {
                "schema: response body isn't JSON".to_string()
            }
            crate::http::schema::SchemaStatus::ReadError(e) => {
                format!("schema: read error — {e}")
            }
            crate::http::schema::SchemaStatus::SchemaParseError(e) => {
                format!("schema: parse error — {e}")
            }
        };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur)
            && let RunState::Done(rv) = &mut rp.state
        {
            rv.schema_result = Some(result);
        }
        self.toast(summary);
    }

    /// Click on the Method chip opens this dropdown — one entry
    /// per HTTP verb. Each entry calls `:http.set_method:<VERB>`
    /// which sets that exact verb on the active Request pane.
    /// Postman-style verb picker.
    pub fn open_method_dropdown(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("GET", MenuAction::Command("http.set_method.get")),
            MenuItem::new("POST", MenuAction::Command("http.set_method.post")),
            MenuItem::new("PUT", MenuAction::Command("http.set_method.put")),
            MenuItem::new("PATCH", MenuAction::Command("http.set_method.patch")),
            MenuItem::new("DELETE", MenuAction::Command("http.set_method.delete")),
            MenuItem::new("HEAD", MenuAction::Command("http.set_method.head")),
            MenuItem::new("OPTIONS", MenuAction::Command("http.set_method.options")),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Method".into()), anchor, items));
    }

    /// Backing for the 7 `:http.set_method.<verb>` palette
    /// commands. Sets the method on the active Request pane.
    pub fn http_set_method(&mut self, verb: &str) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.request.method = verb.to_string();
            self.toast(format!("method: {verb}"));
        }
    }

    /// Right-click on any Request pane Edit-mode field row →
    /// field-aware context menu. Common actions (Send / Copy as
    /// curl / Switch to Response) appear for every field; the
    /// Method row adds "Cycle method" so users can change the
    /// verb without keyboard. v2 ideas: "Format JSON" on Body,
    /// "Paste cookies" on Headers. 2026-06-19 — vscode-user-mouse
    /// agent flagged the earlier "Request" title + URL-only naming
    /// as misleading.
    pub fn open_request_field_context_menu(
        &mut self,
        field: crate::request_pane::EditField,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        use crate::request_pane::EditField;
        let mut items = vec![
            MenuItem::new("Send", MenuAction::Command("http.send")),
            MenuItem::new(
                "Paste curl from clipboard",
                MenuAction::Command("http.paste_curl"),
            ),
            MenuItem::new("Copy as curl", MenuAction::Command("http.copy_curl")),
            MenuItem::new(
                "Switch to Response",
                MenuAction::Command("http.toggle_view"),
            ),
        ];
        if matches!(field, EditField::Method) {
            items.insert(
                0,
                MenuItem::new("Cycle method", MenuAction::Command("http.cycle_method")),
            );
        }
        let title = match field {
            EditField::Url => "Request · URL",
            EditField::Method => "Request · Method",
            EditField::Headers => "Request · Headers",
            EditField::Body => "Request · Body",
            EditField::Source => "Request · Source",
        };
        self.context_menu = Some(ContextMenu::new(Some(title.into()), anchor, items));
    }

    /// Deprecated alias — kept while existing callers migrate. New
    /// callers should use [`Self::open_request_field_context_menu`]
    /// with the actual field.
    pub fn open_request_url_context_menu(&mut self, anchor: (u16, u16)) {
        self.open_request_field_context_menu(crate::request_pane::EditField::Url, anchor);
    }

    /// `y` in the browser pane's network panel — copy the selected request as a
    /// curl command to the clipboard.
    pub fn copy_net_entry_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_net().map(crate::browser_pane::NetEntry::as_curl),
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no network request selected"),
        }
    }

    /// `Enter` in the browser pane's network panel — open the selected request in a
    /// `Pane::Request` (split below the browser) and re-send it.
    pub fn open_net_entry_as_request(&mut self) {
        let Some(cur) = self.active else { return };
        let request = match self.panes.get(cur) {
            Some(Pane::Browser(b)) => b
                .selected_net()
                .map(crate::browser_pane::NetEntry::to_request),
            _ => None,
        };
        let Some(request) = request else {
            self.toast("no network request selected");
            return;
        };
        let script = crate::http::script::Script::default();
        let job_id = self.spawn_http_job(request.clone(), script.clone(), None);
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            None, request, script, job_id,
        ));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// `http.edit_env` — structured env-file editor. Opens a
    /// picker listing every `KEY=VALUE` pair in the active env
    /// file plus a synthetic `+ Add new variable…` row at the top.
    /// Phase 3 polish of the rqst→mnml port-back.
    pub fn http_edit_env_open(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let env_name = crate::http::template::EnvSet::select_with_config_default(
            &self.workspace,
            self.http_env_override.as_deref(),
            self.config.http.default_env.as_deref(),
        )
        .name()
        .map(str::to_string)
        .unwrap_or_else(|| "dev".to_string());
        // 2026-06-19 — api-workflow-user SEV-3: read BOTH .rqst/
        // and .mnml/ env files so keys exclusive to .mnml/ surface
        // in the picker. `.mnml/` wins same-key (matches EnvSet::
        // load precedence).
        let mut by_key: std::collections::BTreeMap<String, String> =
            std::collections::BTreeMap::new();
        for sub in [".rqst", ".mnml"] {
            let env_path = self
                .workspace
                .join(sub)
                .join("env")
                .join(format!("{env_name}.env"));
            let text = std::fs::read_to_string(&env_path).unwrap_or_default();
            for line in text.lines() {
                let trimmed = line.trim_start();
                if trimmed.is_empty() || trimmed.starts_with('#') {
                    continue;
                }
                if let Some((k, v)) = trimmed.split_once('=') {
                    by_key.insert(k.trim().to_string(), v.trim().to_string());
                }
            }
        }
        let mut items: Vec<PickerItem> = Vec::new();
        items.push(PickerItem::new(
            "+add".to_string(),
            "+ Add new variable…".to_string(),
            String::new(),
        ));
        for (key, val) in by_key {
            let preview = if val.len() > 48 {
                format!("{}…", &val[..46])
            } else {
                val.clone()
            };
            items.push(PickerItem::new(key.clone(), key, preview));
        }
        self.open_picker(Picker::new(
            PickerKind::EnvVars,
            format!("Env vars · {env_name}.env"),
            items,
        ));
    }

    /// Accept handler for `PickerKind::EnvVars`. The `+add`
    /// synthetic id opens the add-key prompt; any other id is an
    /// existing key — stash it + open the edit-value prompt seeded
    /// with the current value.
    pub fn accept_env_vars(&mut self, id: &str) {
        if id == "+add" {
            self.prompt = Some(crate::prompt::Prompt::new(
                crate::prompt::PromptKind::EnvAddKey,
                "KEY=VALUE for new env var:".to_string(),
            ));
            return;
        }
        let env_name = crate::http::template::EnvSet::select_with_config_default(
            &self.workspace,
            self.http_env_override.as_deref(),
            self.config.http.default_env.as_deref(),
        )
        .name()
        .map(str::to_string)
        .unwrap_or_else(|| "dev".to_string());
        // 2026-06-19 — api-workflow third hunt SEV-2: previously
        // seeded the prompt from a hardcoded `.rqst/env/` path, so
        // a key whose `.mnml/` value was shown in the picker would
        // pre-fill with the stale `.rqst/` baseline. Now read in
        // the same .rqst→.mnml order as `http_edit_env_open` and
        // pick the last value seen — matches the picker display.
        let current_val = ["", ".rqst", ".mnml"]
            .iter()
            .filter(|s| !s.is_empty())
            .filter_map(|sub| {
                let p = self
                    .workspace
                    .join(sub)
                    .join("env")
                    .join(format!("{env_name}.env"));
                std::fs::read_to_string(p).ok()
            })
            .flat_map(|text| {
                text.lines()
                    .filter_map(|l| {
                        let t = l.trim_start();
                        if t.starts_with('#') {
                            return None;
                        }
                        let (k, v) = t.split_once('=')?;
                        (k.trim() == id).then(|| v.to_string())
                    })
                    .collect::<Vec<_>>()
            })
            .last()
            .unwrap_or_default();
        self.pending_env_edit_key = Some(id.to_string());
        let mut prompt = crate::prompt::Prompt::new(
            crate::prompt::PromptKind::EnvEditValue,
            format!("Value for {id}:"),
        );
        let cursor = current_val.len();
        prompt.input = current_val;
        prompt.cursor = cursor;
        self.prompt = Some(prompt);
    }

    /// Accept handler for `PromptKind::EnvEditValue`. Upserts
    /// `<pending_env_edit_key>=<typed>` into the active env file.
    ///
    /// 2026-06-19 — api-workflow-user SEV-3: earlier impl trimmed
    /// the value, silently dropping intentional leading/trailing
    /// whitespace (`API_KEY= Bearer xyz` → `API_KEY=Bearer xyz`).
    /// Now preserves the typed value verbatim. Newlines are still
    /// rejected by `upsert_env_var` (would corrupt the file).
    pub fn accept_env_edit_value(&mut self, value: &str) {
        let Some(key) = self.pending_env_edit_key.take() else {
            return;
        };
        self.write_env_var(&key, value);
    }

    /// Accept handler for `PromptKind::EnvAddKey`. Splits the
    /// typed `KEY=VALUE` and upserts. Toasts an error for
    /// malformed input (no `=`, empty key).
    pub fn accept_env_add_key(&mut self, input: &str) {
        let Some((key, value)) = input.split_once('=') else {
            self.toast("env: input must be KEY=VALUE");
            return;
        };
        let key = key.trim();
        if key.is_empty() {
            self.toast("env: key can't be empty");
            return;
        }
        self.write_env_var(key, value.trim());
    }

    /// Shared write-back path for `EnvEditValue` + `EnvAddKey`
    /// + `LookupVarName`. Resolves the active env file, upserts,
    /// toasts the result. Creates the parent dir if missing.
    ///
    /// 2026-06-19 — api-workflow-user SEV-3: when both `.mnml/`
    /// and `.rqst/` env files exist and the key lives in `.mnml/`,
    /// writing to `.rqst/` is overshadowed on next request (same-
    /// key precedence). Now writes to WHICHEVER existing file
    /// contains the key; new keys go to `.mnml/` (the preferred
    /// mnml-native location).
    fn write_env_var(&mut self, key: &str, value: &str) {
        let env_name = crate::http::template::EnvSet::select_with_config_default(
            &self.workspace,
            self.http_env_override.as_deref(),
            self.config.http.default_env.as_deref(),
        )
        .name()
        .map(str::to_string)
        .unwrap_or_else(|| "dev".to_string());
        let mnml_path = self
            .workspace
            .join(".mnml")
            .join("env")
            .join(format!("{env_name}.env"));
        let rqst_path = self
            .workspace
            .join(".rqst")
            .join("env")
            .join(format!("{env_name}.env"));
        // Decide target: .mnml takes precedence (the authoritative
        // EnvSet::load reader), so a key that lives there gets the
        // write. Otherwise a key already in .rqst gets the write
        // there. New keys default to .mnml (preferred location).
        let mnml_has = file_contains_env_key(&mnml_path, key);
        let rqst_has = file_contains_env_key(&rqst_path, key);
        let env_path = if mnml_has || (!rqst_has) {
            mnml_path
        } else {
            rqst_path
        };
        let existing = std::fs::read_to_string(&env_path).unwrap_or_default();
        let updated = match upsert_env_var(&existing, key, value) {
            Ok(s) => s,
            Err(e) => {
                self.toast(format!("env: {e}"));
                return;
            }
        };
        if let Some(parent) = env_path.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("env: mkdir {}: {e}", parent.display()));
            return;
        }
        match std::fs::write(&env_path, updated) {
            Ok(()) => self.toast(format!("wrote {key}={value} → {}", env_path.display())),
            Err(e) => self.toast(format!("env: write {}: {e}", env_path.display())),
        }
    }

    /// `http.next_block` — move the cursor to the `###` line of
    /// the next block in a multi-block `.http` / `.rest` file. If
    /// the cursor is at/past the last block, wrap to the first.
    /// http-2nd 2026-06-28 SEV-3b — was no chord/command path.
    pub fn http_next_block(&mut self) {
        self.move_to_http_block(true);
    }

    /// `http.prev_block` — mirror of `next_block` for the
    /// previous-block direction.
    pub fn http_prev_block(&mut self) {
        self.move_to_http_block(false);
    }

    fn move_to_http_block(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("http.next/prev_block: no active editor");
            return;
        };
        let ext = b
            .path
            .as_ref()
            .and_then(|p| p.extension())
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        // qa-5th 2026-06-29 SEV-2: was `"http" | "rest"` — silently
        // rejected .curl files. The sibling guards at lines 2328
        // and 2919 (the send-request paths) include "curl" too.
        // For consistency, accept all three; the empty-blocks toast
        // below handles the single-block .curl case gracefully.
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            self.toast("http.next/prev_block: needs an open .http/.rest/.curl file");
            return;
        }
        let text = b.editor.text().to_string();
        let cur_row = b.editor.row_col().0;
        // qa-6th nvchad SEV-2: was using parse_all, which requires
        // every block's body to parse cleanly as an HTTP request.
        // For .curl files the bodies are `curl -X POST ...` invocations
        // that parse_block rejects — parse_all returned Err, the
        // outer toast fired with "parse error" (which the agent
        // didn't see because of run-command toast timing), and
        // cursor didn't move. Block nav only needs the `###`
        // separator positions; scan for them directly.
        let blocks: Vec<usize> = text
            .lines()
            .enumerate()
            .filter_map(|(i, l)| l.trim_start().starts_with("###").then_some(i))
            .collect();
        if blocks.is_empty() {
            self.toast("http.next/prev_block: no ### blocks in file");
            return;
        }
        // For files where the FIRST block has no `###` separator
        // (leading unnamed block in .http/.rest), treat line 0 as
        // an implicit block start so prev from anywhere in the
        // leading block can wrap to "start of leading block".
        let mut starts: Vec<usize> = blocks.clone();
        if starts.first().copied() != Some(0) {
            starts.insert(0, 0);
        }
        let target_row = if forward {
            starts
                .iter()
                .find(|&&l| l > cur_row)
                .copied()
                .unwrap_or(starts[0])
        } else {
            starts
                .iter()
                .rev()
                .find(|&&l| l < cur_row)
                .copied()
                .unwrap_or_else(|| *starts.last().unwrap())
        };
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(target_row, 0);
        }
        // input-handler-reviewer W-2 2026-06-28: programmatic
        // cursor jumps need to scroll the viewport — without
        // reveal_pane, jumping to a block above/below the
        // current viewport leaves the cursor offscreen.
        if let Some(id) = self.active {
            self.reveal_pane(id);
        }
    }

    /// `http.lookup` — open the lookup picker (stage 1: pick a
    /// `.curl` file under `<workspace>/.rqst/lookups/`). Subsequent
    /// stages — fire-request → pick-item → enter-var-name → write-
    /// to-env — are chained by the picker/prompt accept handlers.
    /// Phase 7 of the rqst→mnml port-back.
    pub fn http_lookup_open(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        // http-2nd 2026-06-28 SEV-3a: use the recursive walker
        // (crate::http::lookup::scan_lookups). Was a flat read_dir
        // that silently missed `requests/auth/login.curl` nested
        // under a subdirectory.
        let workspace = self.workspace.clone();
        let mut items: Vec<PickerItem> = crate::http::lookup::scan_lookups(&workspace)
            .into_iter()
            .map(|path| {
                let label = crate::http::lookup::relative_label(&path, &workspace);
                PickerItem::new(path.to_string_lossy().into_owned(), label, String::new())
            })
            .collect();
        if items.is_empty() {
            let dir = workspace.join(".rqst").join("lookups");
            self.toast(format!(
                "no lookups in {} — add a `.curl` file under that dir",
                dir.display()
            ));
            return;
        }
        items.sort_by(|a, b| a.label.cmp(&b.label));
        self.open_picker(Picker::new(PickerKind::LookupFile, "Lookup file", items));
    }

    /// Accept handler for `PickerKind::LookupFile`. Spawns a
    /// background thread that fires the chosen `.curl` file as an
    /// HTTP request; on response, `App::tick`'s drain opens the
    /// `LookupItem` picker with parsed list rows.
    pub fn accept_lookup_file(&mut self, file_path: &std::path::Path) {
        use crate::http::{self, template::EnvSet};
        let text = match std::fs::read_to_string(file_path) {
            Ok(t) => t,
            Err(e) => {
                self.toast(format!("lookup: read {}: {e}", file_path.display()));
                return;
            }
        };
        let mut request = match http::parse(&text) {
            Ok(r) => r,
            Err(e) => {
                self.toast(format!("lookup: parse {}: {e}", file_path.display()));
                return;
            }
        };
        let script = http::script::parse(&text);
        let mut env = EnvSet::select_with_config_default(
            &self.workspace,
            self.http_env_override.as_deref(),
            self.config.http.default_env.as_deref(),
        );
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in request.headers.iter_mut() {
            *v = http::template::expand(v, &env);
        }
        if let Some(body) = request.body.as_mut() {
            *body = http::template::expand(body, &env);
        }
        let file_label = crate::http::lookup::relative_label(file_path, &self.workspace);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let result = http::send(&request)
                .map(|r| (r.body, file_label.clone()))
                .map_err(|e| format!("lookup fire: {e}"));
            let _ = tx.send(result);
        });
        self.lookup_fire_rx = Some(rx);
        self.lookup_fire_started = Some(std::time::Instant::now());
        self.toast("lookup: firing request…");
    }

    /// Drain the in-flight lookup-fire result. On success, parses
    /// the response body for list items and opens the
    /// `PickerKind::LookupItem` picker. Called from `App::tick`.
    pub fn drain_lookup_fire_result(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let Some(rx) = self.lookup_fire_rx.as_ref() else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok((body, label))) => {
                self.lookup_fire_rx = None;
                let Some(parsed) = crate::http::lookup::parse_items(&body) else {
                    self.toast(format!(
                        "lookup: {label} response wasn't a recognized list shape"
                    ));
                    return;
                };
                if parsed.is_empty() {
                    self.toast(format!("lookup: {label} returned 0 items"));
                    return;
                }
                let items: Vec<PickerItem> = parsed
                    .iter()
                    .enumerate()
                    .map(|(i, item)| {
                        PickerItem::new(i.to_string(), item.label.clone(), item.id.clone())
                    })
                    .collect();
                self.pending_lookup_items = parsed;
                self.open_picker(Picker::new(
                    PickerKind::LookupItem,
                    format!("Lookup item · {label}"),
                    items,
                ));
            }
            Ok(Err(e)) => {
                self.lookup_fire_rx = None;
                self.toast(e);
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.lookup_fire_rx = None;
                self.toast("lookup: worker dropped");
            }
        }
    }

    /// Accept handler for `PickerKind::LookupItem`. Stashes the
    /// picked item's id into `pending_lookup_picked_id` and opens
    /// the var-name prompt.
    pub fn accept_lookup_item(&mut self, idx: usize) {
        let Some(item) = self.pending_lookup_items.get(idx).cloned() else {
            return;
        };
        self.pending_lookup_picked_id = Some(item.id.clone());
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::LookupVarName,
            format!("Env var name for {} ({}):", item.label, item.id),
        ));
    }

    /// Accept handler for `PromptKind::LookupVarName`. Writes
    /// `<var>=<id>` to `<workspace>/.rqst/env/<current>.env`
    /// (appending or replacing in place if the var exists), toasts
    /// the write.
    pub fn accept_lookup_var_name(&mut self, var: &str) {
        let var = var.trim();
        if var.is_empty() {
            self.toast("lookup: var name can't be empty");
            return;
        }
        let Some(id) = self.pending_lookup_picked_id.take() else {
            return;
        };
        // 2026-06-19 — unified with `write_env_var` so the lookup
        // write respects the same `.mnml/` vs `.rqst/` precedence
        // the env editor uses: existing key → its file; new key →
        // `.mnml/env/` (preferred).
        self.write_env_var(var, &id);
    }

    /// `http.capture_now` — append every NetEntry from the active
    /// browser pane into `<workspace>/.rqst/captured/log.jsonl`.
    /// The captured log persists across browser sessions so the
    /// user can review or re-fire entries later. Phase 4 of the
    /// rqst→mnml port-back.
    pub fn http_capture_browser_net_to_log(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.capture_now: no active pane");
            return;
        };
        let entries: Vec<crate::http::captured::CapturedRow> = match self.panes.get(cur) {
            Some(Pane::Browser(b)) => {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                b.net
                    .iter()
                    .map(|n| crate::http::captured::CapturedRow {
                        at: now,
                        request_id: n.request_id.clone(),
                        method: n.method.clone(),
                        url: n.url.clone(),
                        headers: n.headers.clone(),
                        body: n.post_data.clone(),
                        paused: false,
                    })
                    .collect()
            }
            _ => {
                self.toast("http.capture_now: needs an active browser pane");
                return;
            }
        };
        if entries.is_empty() {
            self.toast("http.capture_now: browser pane has no network entries yet");
            return;
        }
        let log_path = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join("log.jsonl");
        if let Some(parent) = log_path.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("http.capture_now: mkdir {}: {e}", parent.display()));
            return;
        }
        let count = entries.len();
        let mut written = 0;
        match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            Ok(mut f) => {
                use std::io::Write;
                for row in &entries {
                    if let Ok(line) = serde_json::to_string(row)
                        && f.write_all(line.as_bytes()).is_ok()
                        && f.write_all(b"\n").is_ok()
                    {
                        written += 1;
                    }
                }
                self.toast(format!(
                    "http.capture_now: wrote {written}/{count} entries to {}",
                    log_path.display()
                ));
            }
            Err(e) => self.toast(format!(
                "http.capture_now: open {}: {e}",
                log_path.display()
            )),
        }
    }

    /// `http.view_captured` — load `.rqst/captured/log.jsonl` and
    /// open a picker over the entries. Enter opens the chosen row
    /// as a fresh `.curl` editor buffer (via `CapturedRow::to_curl`)
    /// so the user can fire it again. Phase 4 of the rqst→mnml
    /// port-back — replaces the v1 stub that just opened the JSONL
    /// file in an editor.
    pub fn open_http_captured_log(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let path = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join("log.jsonl");
        let rows = crate::http::captured::load(&path);
        if rows.is_empty() {
            self.toast(format!(
                "http.view_captured: no entries at {} — run http.capture_now first",
                path.display()
            ));
            return;
        }
        let items: Vec<PickerItem> = rows
            .iter()
            .enumerate()
            .map(|(i, r)| {
                // Display: "METHOD short_url" (matching browser pane's
                // short_url convention — host + path, no scheme/query).
                let short = r
                    .url
                    .strip_prefix("https://")
                    .or_else(|| r.url.strip_prefix("http://"))
                    .unwrap_or(&r.url);
                let short = short.split(['?', '#']).next().unwrap_or(short);
                let detail = if r.body.as_deref().unwrap_or("").is_empty() {
                    String::new()
                } else {
                    format!("(body: {} bytes)", r.body.as_deref().unwrap().len())
                };
                PickerItem::new(i.to_string(), format!("{} {short}", r.method), detail)
            })
            .collect();
        self.pending_captured_rows = rows;
        self.open_picker(Picker::new(
            PickerKind::CapturedRows,
            "Captured requests",
            items,
        ));
    }

    /// `http.history_global` — load `~/.config/mnml/history-global.jsonl`
    /// and open a picker over the most recent 100 entries across
    /// ALL workspaces. Detail line shows the workspace name + status.
    /// Useful when you remember firing a request but not which
    /// project you were in. Enter opens a `.curl` scratch so you
    /// can re-fire it from the current workspace.
    pub fn open_http_history_global(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let rows = crate::http::history::tail_global(100);
        if rows.is_empty() {
            let path = crate::http::history::global_history_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "(HOME unset)".to_string());
            self.toast(format!("http.history_global: no entries yet at {path}"));
            return;
        }
        let items: Vec<PickerItem> = rows
            .iter()
            .enumerate()
            .rev()
            .map(|(i, v)| {
                let method = v
                    .get("method")
                    .and_then(|s| s.as_str())
                    .unwrap_or("?")
                    .to_string();
                let url = v
                    .get("url")
                    .and_then(|s| s.as_str())
                    .unwrap_or("")
                    .to_string();
                let workspace = v
                    .get("workspace")
                    .and_then(|s| s.as_str())
                    .unwrap_or("?")
                    .to_string();
                let status = v.get("status").and_then(|s| s.as_u64());
                let dur = v.get("duration_ms").and_then(|d| d.as_u64());
                let detail = match (status, dur) {
                    (Some(s), Some(d)) => format!("{workspace} · {s} · {d}ms"),
                    (Some(s), None) => format!("{workspace} · {s}"),
                    (None, Some(d)) => format!("{workspace} · FAILED · {d}ms"),
                    (None, None) => format!("{workspace} · FAILED"),
                };
                let short = url
                    .strip_prefix("https://")
                    .or_else(|| url.strip_prefix("http://"))
                    .unwrap_or(&url)
                    .split(['?', '#'])
                    .next()
                    .unwrap_or(&url)
                    .to_string();
                PickerItem::new(i.to_string(), format!("{method} {short}"), detail)
            })
            .collect();
        self.pending_history_rows = rows;
        self.open_picker(Picker::new(
            PickerKind::HistoryRows,
            "HTTP history · all workspaces",
            items,
        ));
    }

    /// `http.history` — load `.rqst/history.jsonl` and open a
    /// picker over the most recent 100 entries. Enter opens the
    /// chosen entry's method/URL as a `.curl` scratch buffer so
    /// the user can re-fire it. Phase 9 of the rqst→mnml
    /// port-back — replaces the v1 stub that just opened the file
    /// in an editor.
    pub fn open_http_history(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let workspace = self.workspace.clone();
        let rows = crate::http::history::tail(&workspace, 100);
        if rows.is_empty() {
            self.toast(format!(
                "http.history: no history yet at {}",
                workspace.join(".rqst").join("history.jsonl").display()
            ));
            return;
        }
        let items: Vec<PickerItem> = rows
            .iter()
            .enumerate()
            .rev()
            .map(|(i, v)| {
                let method = v
                    .get("method")
                    .and_then(|s| s.as_str())
                    .unwrap_or("?")
                    .to_string();
                let url = v
                    .get("url")
                    .and_then(|s| s.as_str())
                    .unwrap_or("")
                    .to_string();
                let status = v.get("status").and_then(|s| s.as_u64());
                let dur = v.get("duration_ms").and_then(|d| d.as_u64());
                let detail = match (status, dur) {
                    (Some(s), Some(d)) => format!("{s} · {d}ms"),
                    (Some(s), None) => format!("{s}"),
                    (None, Some(d)) => format!("FAILED · {d}ms"),
                    (None, None) => "FAILED".to_string(),
                };
                let short = url
                    .strip_prefix("https://")
                    .or_else(|| url.strip_prefix("http://"))
                    .unwrap_or(&url)
                    .split(['?', '#'])
                    .next()
                    .unwrap_or(&url)
                    .to_string();
                PickerItem::new(i.to_string(), format!("{method} {short}"), detail)
            })
            .collect();
        self.pending_history_rows = rows;
        self.open_picker(Picker::new(PickerKind::HistoryRows, "HTTP history", items));
    }

    /// `http.save_mock` — freeze the active Request pane's response
    /// to disk as a `<source>.curl.mock.json` sidecar. The mock
    /// captures status + status_text + headers + body so it can be
    /// re-served by `http.replay_mock` for offline review or
    /// canned-data testing. Phase 6 of the rqst→mnml port-back.
    pub fn http_save_active_response_as_mock(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.save_mock: no active pane");
            return;
        };
        let (source_path, source_block_name, mock) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(rp_path) = rp.source_path.as_ref() else {
                    self.toast("http.save_mock: pane has no source file path");
                    return;
                };
                let crate::request_pane::RunState::Done(rv) = &rp.state else {
                    self.toast("http.save_mock: response not ready yet");
                    return;
                };
                (
                    rp_path.clone(),
                    rp.source_block_name.clone(),
                    crate::http::mock::Mock {
                        status: rv.status,
                        status_text: rv.status_text.clone(),
                        headers: rv.headers.clone(),
                        body: rv.body.clone(),
                    },
                )
            }
            _ => {
                self.toast("http.save_mock: needs an active Request pane");
                return;
            }
        };
        // http-2nd SEV-2: multi-block .http files share the sibling
        // path so block A's mock overwrote block B's. Use per-block
        // path when a named block is the source.
        let mock_path =
            crate::http::mock::sibling_path_for_block(&source_path, source_block_name.as_deref());
        match crate::http::mock::save(&mock_path, &mock) {
            Ok(()) => self.toast(format!("saved mock → {}", mock_path.display())),
            Err(e) => self.toast(format!("http.save_mock: {e}")),
        }
    }

    /// `http.replay_mock` — load the active Request pane's sibling
    /// `.mock.json` and serve it as if it had been the live
    /// response. The pane's state flips to `Done` with the mock's
    /// status / headers / body — no network call. Phase 6 of the
    /// rqst→mnml port-back.
    pub fn http_replay_active_request_from_mock(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.replay_mock: no active pane");
            return;
        };
        let mock_path = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(p) = rp.source_path.as_ref() else {
                    self.toast("http.replay_mock: pane has no source file path");
                    return;
                };
                // http-2nd SEV-2: prefer the per-block path when
                // the source has a named block; fall back to the
                // bare sibling for unnamed leading blocks.
                crate::http::mock::sibling_path_for_block(p, rp.source_block_name.as_deref())
            }
            _ => {
                self.toast("http.replay_mock: needs an active Request pane");
                return;
            }
        };
        let mock = match crate::http::mock::load(&mock_path) {
            Ok(m) => m,
            Err(e) => {
                self.toast(format!("http.replay_mock: {e}"));
                return;
            }
        };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.state =
                crate::request_pane::RunState::Done(Box::new(crate::request_pane::ResponseView {
                    status: mock.status,
                    status_text: mock.status_text,
                    headers: mock.headers,
                    body: mock.body,
                    elapsed: std::time::Duration::ZERO,
                    assertions: Vec::new(),
                    captures: Vec::new(),
                    schema_result: None,
                    sse_event_count: 0,
                }));
            rp.view = crate::request_pane::ViewMode::Response;
        }
        self.toast(format!("replayed mock ({})", mock_path.display()));
    }

    /// Parse the active editor as an HTTP request, expanding env
    /// vars from `.mnml/env/$MNML_ENV` (or `.rqst/env/`). Returns
    /// `None` when there's no active editor, it isn't a recognized
    /// HTTP file, or parsing/template expansion fails. Used by
    /// `http.bench` and similar one-off-request commands; the
    /// richer `send_request_from_active` path does full multi-block
    /// block-aware parsing for `.http` / `.rest`.
    fn parse_active_as_request(&mut self) -> Option<crate::http::Request> {
        use crate::http::{self, template::EnvSet};
        let cur = self.active?;
        // From a Request pane, just clone the in-flight request.
        if let Some(Pane::Request(rp)) = self.panes.get(cur) {
            return Some(rp.request.clone());
        }
        let (ext, text, cursor_row) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => (
                b.language_ext.clone().unwrap_or_default(),
                b.editor.text().to_string(),
                b.editor.row_col().0,
            ),
            _ => return None,
        };
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            return None;
        }
        // qa-7th api SEV-2 2026-06-30 — was matches!("http" | "rest"),
        // so .curl files always fell to the whole-file parse and
        // ignored cursor position on multi-block .curl. Extended
        // to .curl via the same line-scan strategy as
        // move_to_http_block: find ### separators directly, slice
        // out the cursor's block, parse JUST that block.
        let lines: Vec<&str> = text.split('\n').collect();
        let block_src = if matches!(ext.as_str(), "http" | "rest")
            && let Ok(blocks) = http::file::parse_all(&text)
        {
            // .http/.rest still use parse_all (rich block metadata).
            let b = blocks
                .iter()
                .find(|b| cursor_row >= b.start_line && cursor_row <= b.end_line)
                .unwrap_or(&blocks[0]);
            Some(lines[b.start_line..=b.end_line.min(lines.len().saturating_sub(1))].join("\n"))
        } else {
            // .curl (and the catch-all): scan ### markers directly
            // since parse_all rejects curl-syntax block bodies.
            let starts: Vec<usize> = lines
                .iter()
                .enumerate()
                .filter_map(|(i, l)| l.trim_start().starts_with("###").then_some(i))
                .collect();
            if starts.is_empty() {
                None
            } else {
                let block_start = starts
                    .iter()
                    .rev()
                    .find(|&&s| s <= cursor_row)
                    .copied()
                    .unwrap_or(starts[0]);
                let block_end = starts
                    .iter()
                    .find(|&&s| s > block_start)
                    .map(|&n| n - 1)
                    .unwrap_or(lines.len().saturating_sub(1));
                Some(lines[block_start..=block_end].join("\n"))
            }
        };
        let (mut request, script_src) = match block_src {
            Some(src) => match http::parse(&src) {
                Ok(r) => (r, src),
                Err(_) => return None,
            },
            None => match http::parse(&text) {
                Ok(r) => (r, text.clone()),
                Err(_) => return None,
            },
        };
        let script = http::script::parse(&script_src);
        let mut env = EnvSet::select_with_config_default(
            &self.workspace,
            self.http_env_override.as_deref(),
            self.config.http.default_env.as_deref(),
        );
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in request.headers.iter_mut() {
            *v = http::template::expand(v, &env);
        }
        if let Some(body) = request.body.as_mut() {
            *body = http::template::expand(body, &env);
        }
        Some(request)
    }

    /// `http.bench` — fire the active editor's request `n` times
    /// across `concurrency` worker threads, then write the summary
    /// trace to the clipboard and toast a one-liner. The full
    /// trace has the p50/p95/p99/max + status-class breakdown so
    /// the user can paste it into a buffer for inspection. Phase 5
    /// of the rqst→mnml port-back; 2026-06-19.
    ///
    /// Runs on a background thread (10 sequential 30-second
    /// reqwest calls = up to 5 minutes of frozen UI without
    /// this). `App::tick` drains the result channel.
    pub fn http_bench_active(&mut self, n: u32, concurrency: u32) {
        if self.http_bench_rx.is_some() {
            self.toast("http.bench already running");
            return;
        }
        let Some(req) = self.parse_active_as_request() else {
            self.toast("http.bench: no active .http/.curl/.rest editor");
            return;
        };
        let (tx, rx) = std::sync::mpsc::channel();
        let progress = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let progress_worker = progress.clone();
        std::thread::spawn(move || {
            let trace =
                crate::http::bench::run_with_progress(&req, n, concurrency, Some(progress_worker));
            let _ = tx.send(trace);
        });
        self.http_bench_rx = Some(rx);
        self.http_bench_started = Some(std::time::Instant::now());
        self.http_bench_progress = Some((progress, n));
        self.toast(format!(
            "http.bench: firing {n}× ({concurrency} concurrent)…"
        ));
    }

    /// Drain the in-flight `http.bench` result and surface it via
    /// toast + clipboard. Called from `App::tick`.
    pub fn drain_http_bench_result(&mut self) {
        let Some(rx) = self.http_bench_rx.as_ref() else {
            return;
        };
        match rx.try_recv() {
            Ok(trace) => {
                self.http_bench_rx = None;
                // Pull the "bench summary" headline out for the
                // toast; the FULL trace also opens as a scratch
                // buffer so the user can read / share / save it
                // directly. Earlier impl only put the trace on
                // the clipboard (mouse hunt SEV-3: invisible,
                // and the toast's "trace → clipboard" hint
                // wasn't clickable). Clipboard still gets a copy
                // for paste-into-elsewhere workflows.
                let headline = trace
                    .lines()
                    .find(|l| l.trim_start().starts_with("bench summary"))
                    .unwrap_or("bench: complete")
                    .trim()
                    .to_string();
                self.clipboard.set(trace.clone(), false);
                self.open_scratch_with_text("[bench-trace]".to_string(), trace);
                self.toast(format!(
                    "{headline} · full trace → [bench-trace] + clipboard"
                ));
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.http_bench_rx = None;
                self.toast("http.bench: worker dropped");
            }
        }
    }

    /// `jwt.decode` — decode the JWT currently on the clipboard
    /// (claims segment only — signature isn't verified, this is
    /// purely a display tool for tokens you already have). Toasts
    /// the headline claims (`sub`, `email`, `exp`) so a user can
    /// quickly check who/when a token is for. Phase 8 of the
    /// rqst→mnml port-back; 2026-06-19.
    pub fn jwt_decode_clipboard(&mut self) {
        let token = self.clipboard.text();
        if token.trim().is_empty() {
            self.toast("jwt.decode: clipboard is empty");
            return;
        }
        let Some(claims) = crate::jwt::decode(&token) else {
            self.toast("jwt.decode: not a valid JWT (3 dot-separated segments)");
            return;
        };
        let mut parts: Vec<String> = Vec::new();
        if let Some(sub) = claims.sub.as_deref() {
            parts.push(format!("sub={sub}"));
        }
        if let Some(email) = claims.email.as_deref() {
            parts.push(format!("email={email}"));
        }
        if let Some(exp) = claims.exp_display() {
            parts.push(format!("exp={exp}"));
        }
        if claims.is_expired() {
            parts.push("EXPIRED".into());
        }
        let msg = if parts.is_empty() {
            "jwt.decode: (token has no standard claims)".to_string()
        } else {
            format!("jwt: {}", parts.join(" · "))
        };
        self.toast(msg);
    }

    /// `sse.parse_active_response` — parse the active Request
    /// pane's Done response body as Server-Sent Events and toast
    /// the event count + first event's name/data preview. Useful
    /// when an endpoint streams `data: <json>` lines and you want
    /// to confirm the SSE shape without reading raw text. The full
    /// progressive streaming-send display (per-event response pane
    /// updates) is a v2 follow-up. Phase 8 follow-up of the
    /// rqst→mnml port-back.
    pub fn sse_parse_active_response(&mut self) {
        let body = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                Pane::Request(rp) => match &rp.state {
                    crate::request_pane::RunState::Done(rv) => Some(rv.body.clone()),
                    _ => None,
                },
                _ => None,
            });
        let Some(body) = body else {
            self.toast("sse.parse: no active Request pane with a Done response");
            return;
        };
        let mut reader = crate::sse::Reader::new(body.as_bytes());
        let mut events: Vec<crate::sse::Event> = Vec::new();
        while let Ok(Some(evt)) = reader.next_event() {
            events.push(evt);
        }
        if events.is_empty() {
            self.toast("sse.parse: body has no SSE events (no blank-line-delimited data blocks)");
            return;
        }
        let first = &events[0];
        let preview = if first.data.len() > 40 {
            format!("{}…", &first.data[..38])
        } else {
            first.data.clone()
        };
        let label = if first.name.is_empty() {
            String::new()
        } else {
            format!(" [{}]", first.name)
        };
        self.toast(format!(
            "sse: {} event(s){label} · first: {preview}",
            events.len()
        ));
    }

    /// `auth.save_preset` — read the active Request pane's
    /// Authorization header, prompt for a preset name, write to
    /// `.mnml/auth/<name>.txt`. Useful when a long-lived token is
    /// the only thing distinguishing several environments — store
    /// once, apply later via `:auth.apply_preset`.
    pub fn auth_save_preset_prompt(&mut self) {
        let Some(cur) = self.active else {
            self.toast("auth: no active Request pane");
            return;
        };
        let has = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => rp
                .request
                .headers
                .iter()
                .any(|(k, _)| k.eq_ignore_ascii_case("authorization")),
            _ => false,
        };
        if !has {
            self.toast("auth: active Request has no Authorization header");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::AuthSavePreset,
            "Preset name (filename stem):".to_string(),
        ));
    }

    /// Accept handler for `PromptKind::AuthSavePreset`.
    pub fn accept_auth_save_preset(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            self.toast("auth: preset name can't be empty");
            return;
        }
        let safe_name: String = name
            .chars()
            .map(|c| {
                if c.is_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        let Some(cur) = self.active else { return };
        let header_value = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => rp
                .request
                .headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
                .map(|(_, v)| v.clone()),
            _ => None,
        };
        let Some(value) = header_value else { return };
        let path = self
            .workspace
            .join(".mnml")
            .join("auth")
            .join(format!("{safe_name}.txt"));
        if let Some(parent) = path.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("auth: mkdir: {e}"));
            return;
        }
        match std::fs::write(&path, &value) {
            Ok(()) => self.toast(format!("auth: saved → {}", path.display())),
            Err(e) => self.toast(format!("auth: write failed: {e}")),
        }
    }

    /// `auth.apply_preset` — picker over `.mnml/auth/*.txt`. Enter
    /// reads the preset and sets the active Request pane's
    /// Authorization header to its content.
    pub fn auth_apply_preset_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let auth_dir = self.workspace.join(".mnml").join("auth");
        let entries: Vec<PickerItem> = match std::fs::read_dir(&auth_dir) {
            Ok(rd) => rd
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|x| x == "txt"))
                .filter_map(|e| {
                    let stem = e.path().file_stem()?.to_string_lossy().into_owned();
                    let preview = std::fs::read_to_string(e.path())
                        .ok()
                        .map(|s| {
                            let line = s.lines().next().unwrap_or("").to_string();
                            if line.len() > 48 {
                                format!("{}…", &line[..46])
                            } else {
                                line
                            }
                        })
                        .unwrap_or_default();
                    Some(PickerItem::new(stem.clone(), stem, preview))
                })
                .collect(),
            Err(_) => Vec::new(),
        };
        if entries.is_empty() {
            self.toast(format!(
                "auth: no presets in {} (save with :auth.save_preset)",
                auth_dir.display()
            ));
            return;
        }
        self.open_picker(Picker::new(
            PickerKind::AuthPresets,
            "Auth presets",
            entries,
        ));
    }

    /// Accept handler for `PickerKind::AuthPresets`.
    pub fn accept_auth_preset(&mut self, name: &str) {
        let path = self
            .workspace
            .join(".mnml")
            .join("auth")
            .join(format!("{name}.txt"));
        let value = match std::fs::read_to_string(&path) {
            Ok(s) => s.trim_end().to_string(),
            Err(e) => {
                self.toast(format!("auth: read {}: {e}", path.display()));
                return;
            }
        };
        let Some(cur) = self.active else {
            self.toast("auth: no active Request pane");
            return;
        };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            // Replace existing Authorization header in-place, or
            // append a new one. Also reflect into headers_buffer
            // (the editable textarea source of truth) so the user
            // sees the change in the Headers tab immediately.
            let existing = rp
                .request
                .headers
                .iter()
                .position(|(k, _)| k.eq_ignore_ascii_case("authorization"));
            if let Some(i) = existing {
                rp.request.headers[i].1 = value.clone();
            } else {
                rp.request
                    .headers
                    .push(("Authorization".to_string(), value.clone()));
            }
            rp.headers_buffer = crate::request_pane::headers_to_text(&rp.request.headers);
            rp.headers_cursor = rp.headers_buffer.len();
            self.toast(format!("auth: applied {name}"));
        }
    }

    /// `cookies.delete` — picker over jar entries; Enter removes
    /// the selected cookie + persists. Companion to `cookies.show`
    /// (which copies on Enter).
    pub fn cookies_delete_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let Ok(jar) = self.cookie_jar.lock() else {
            self.toast("cookies: jar lock poisoned");
            return;
        };
        let items: Vec<PickerItem> = jar
            .iter()
            .map(|(host, name, value)| {
                let preview = if value.len() > 32 {
                    format!("{}…", &value[..30])
                } else {
                    value.to_string()
                };
                let id = format!("{host}\t{name}");
                let label = format!("{host}  ·  {name}  ·  {preview}");
                PickerItem::new(id, label, String::new())
            })
            .collect();
        let total = items.len();
        drop(jar);
        if items.is_empty() {
            self.toast("cookies: jar is empty");
            return;
        }
        self.open_picker(Picker::new(
            PickerKind::CookiesDelete,
            format!("Delete cookie ({total} total)"),
            items,
        ));
    }

    /// `cookies.show` — picker over every entry in the persistent
    /// cookie jar. Rows: `<host> · <name> · <preview>`. Enter
    /// copies `<name>=<value>` to clipboard.
    pub fn cookies_show_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let Ok(jar) = self.cookie_jar.lock() else {
            self.toast("cookies: jar lock poisoned");
            return;
        };
        let mut items: Vec<PickerItem> = jar
            .iter()
            .map(|(host, name, value)| {
                let preview = if value.len() > 32 {
                    format!("{}…", &value[..30])
                } else {
                    value.to_string()
                };
                let id = format!("{host}\t{name}");
                let label = format!("{host}  ·  {name}  ·  {preview}");
                PickerItem::new(id, label, String::new())
            })
            .collect();
        let total = items.len();
        drop(jar);
        if items.is_empty() {
            items.push(PickerItem::new(
                "_empty".to_string(),
                "(jar is empty — :http.send accumulates from Set-Cookie)".to_string(),
                String::new(),
            ));
        }
        self.open_picker(Picker::new(
            PickerKind::Cookies,
            format!("Cookies ({total} total)"),
            items,
        ));
    }

    /// `cookies.clear` — drop every cookie from the jar (in-memory
    /// + persisted file). Useful when login state on a domain has
    /// gone bad and you want a fresh start.
    pub fn cookies_clear_jar(&mut self) {
        let prev = {
            let Ok(mut jar) = self.cookie_jar.lock() else {
                self.toast("cookies: jar lock poisoned");
                return;
            };
            let prev = jar.total();
            jar.clear();
            let _ = jar.save(&self.workspace);
            prev
        };
        self.toast(format!("cookies: cleared {prev} entries"));
    }

    /// `cookies.persist` — write the in-memory jar to
    /// `.mnml/cookies.json` immediately. The jar auto-flushes on
    /// some mutations but this is the explicit "flush now" path.
    pub fn cookies_persist(&mut self) {
        let outcome = {
            let Ok(jar) = self.cookie_jar.lock() else {
                self.toast("cookies: jar lock poisoned");
                return;
            };
            let total = jar.total();
            match jar.save(&self.workspace) {
                Ok(p) => Ok((total, p)),
                Err(e) => Err(e),
            }
        };
        match outcome {
            Ok((n, p)) => self.toast(format!("cookies: wrote {n} entries → {}", p.display())),
            Err(e) => self.toast(format!("cookies: write failed: {e}")),
        }
    }

    /// `cookies.normalize_clipboard` — read the clipboard, run it
    /// through `crate::cookies::normalize_cookie_value` to collapse
    /// any of the three DevTools paste shapes into the canonical
    /// `name=value; name=value; …` form, and write the result back
    /// to the clipboard. Lets a user paste cookies copied from
    /// Chrome's Network or Application tab, run this, then paste
    /// the result into a `Cookie:` header value without hand-
    /// editing. Phase 8 follow-up of the rqst→mnml port-back.
    pub fn cookies_normalize_clipboard(&mut self) {
        let raw = self.clipboard.text();
        if raw.trim().is_empty() {
            self.toast("cookies.normalize: clipboard is empty");
            return;
        }
        let normalized = crate::cookies::normalize_cookie_value(&raw);
        if normalized.is_empty() {
            self.toast("cookies.normalize: no cookie pairs found");
            return;
        }
        let preview = if normalized.len() > 64 {
            format!("{}…", &normalized[..62])
        } else {
            normalized.clone()
        };
        self.clipboard.set(normalized, false);
        self.toast(format!("cookies: {preview} (copied)"));
    }

    /// `auth.extract_bearer` — pull a bearer token out of arbitrary
    /// clipboard text (a paste of `Authorization: Bearer eyJ…` or
    /// just `Bearer eyJ…`, or the bare JWT itself). Writes the
    /// extracted token back to the clipboard so the user can paste
    /// it into an env file. Phase 8 of the rqst→mnml port-back.
    pub fn auth_extract_bearer_from_clipboard(&mut self) {
        let raw = self.clipboard.text();
        match crate::auth::extract_bearer_from_clipboard(&raw) {
            Some(token) => {
                let preview = if token.len() > 18 {
                    format!("{}…{}", &token[..6], &token[token.len() - 6..])
                } else {
                    token.clone()
                };
                self.clipboard.set(token, false);
                self.toast(format!("bearer: {preview} (copied)"));
            }
            None => {
                self.toast("auth.extract_bearer: no bearer token found");
            }
        }
    }

    /// `http.sync` — read `<workspace>/.mnml/sources.json` (or
    /// `<workspace>/.rqst/sources.json` for legacy workspaces) and
    /// regenerate `.curl` stub files for every `kind: "swagger"`
    /// source. Runs on a background thread (reqwest's blocking
    /// client has a 30-second per-request timeout; 6 sources ×
    /// 30s = potentially 3 minutes of frozen UI without this).
    /// `App::tick` drains the result channel + toasts. Reviewer-
    /// flagged 2026-06-19 — phase 2 of the rqst→mnml port-back.
    pub fn http_sync_sources(&mut self) {
        if self.http_sync_rx.is_some() {
            self.toast("http.sync already running");
            return;
        }
        let workspace = self.workspace.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let result = crate::http::sources::run_sync(&workspace);
            let _ = tx.send(result);
        });
        self.http_sync_rx = Some(rx);
        self.http_sync_started = Some(std::time::Instant::now());
        self.toast("http.sync: fetching swagger sources…");
    }

    /// Drain the in-flight `http.sync` result. Called from
    /// `App::tick`; no-op when nothing is pending or the worker
    /// hasn't responded yet.
    pub fn drain_http_sync_result(&mut self) {
        let Some(rx) = self.http_sync_rx.as_ref() else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok((_trace, total))) => {
                self.http_sync_rx = None;
                self.toast(format!(
                    "http.sync: wrote {total} request stub(s) — tree refreshed"
                ));
                self.tree.refresh();
            }
            Ok(Err(e)) => {
                self.http_sync_rx = None;
                self.toast(format!("http.sync failed: {e}"));
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.http_sync_rx = None;
                self.toast("http.sync: worker dropped");
            }
        }
    }

    /// `http.send` — parse the active `.http`/`.rest`/`.curl` editor (the block
    /// under the cursor for multi-block `.http` files), expand `{{vars}}` against
    /// `.mnml/env/$MNML_ENV`, open a `Pane::Request` split, and fire the request
    /// on a background thread. `tick` delivers the response.
    pub fn send_request_from_active(&mut self) {
        use crate::http::{self, template::EnvSet};
        let Some(cur) = self.active else {
            self.toast("no active editor");
            return;
        };
        // From an existing request pane, `http.send` just re-fires it.
        if matches!(self.panes.get(cur), Some(Pane::Request(_))) {
            self.refire_request(cur);
            return;
        }
        let (path, ext, text, cursor_row) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => (
                b.path.clone(),
                b.language_ext.clone().unwrap_or_default(),
                b.editor.text().to_string(),
                b.editor.row_col().0,
            ),
            _ => {
                self.toast("not an editor");
                return;
            }
        };
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            self.toast("http.send needs a .http / .rest / .curl file");
            return;
        }

        // Pick the request + the directive text. For `.http`/`.rest`, use the
        // block under the cursor; otherwise treat the whole buffer as one request.
        // `source_block_name` is captured iff the file is genuinely multi-block
        // (>1 parsed block) — single-block files round-trip through the simple
        // overwrite path on save.
        // qa-7th api SEV-2 2026-06-30 — extended to .curl via
        // direct ### scan; parse_all rejects curl-syntax bodies
        // so it can't dispatch .curl on its own.
        let lines: Vec<&str> = text.split('\n').collect();
        let (mut request, script_src, source_block_name): (http::Request, String, Option<String>) = {
            // .http/.rest still use parse_all for rich metadata.
            if matches!(ext.as_str(), "http" | "rest")
                && let Ok(blocks) = http::file::parse_all(&text)
            {
                let b = blocks
                    .iter()
                    .find(|b| cursor_row >= b.start_line && cursor_row <= b.end_line)
                    .unwrap_or(&blocks[0]);
                let src =
                    lines[b.start_line..=b.end_line.min(lines.len().saturating_sub(1))].join("\n");
                let block_name = if blocks.len() > 1 {
                    if lines
                        .get(b.start_line)
                        .is_some_and(|l| l.trim_start().starts_with("###"))
                    {
                        Some(b.name.clone().unwrap_or_default())
                    } else {
                        None
                    }
                } else {
                    None
                };
                (b.request.clone(), src, block_name)
            } else {
                // .curl (and other): scan ### directly.
                let starts: Vec<usize> = lines
                    .iter()
                    .enumerate()
                    .filter_map(|(i, l)| l.trim_start().starts_with("###").then_some(i))
                    .collect();
                let (slice, block_name) = if starts.is_empty() {
                    (text.clone(), None)
                } else {
                    let block_start = starts
                        .iter()
                        .rev()
                        .find(|&&s| s <= cursor_row)
                        .copied()
                        .unwrap_or(starts[0]);
                    let block_end = starts
                        .iter()
                        .find(|&&s| s > block_start)
                        .map(|&n| n - 1)
                        .unwrap_or(lines.len().saturating_sub(1));
                    let name = if lines
                        .get(block_start)
                        .is_some_and(|l| l.trim_start().starts_with("###"))
                    {
                        let after_hashes = lines[block_start]
                            .trim_start()
                            .trim_start_matches('#')
                            .trim()
                            .to_string();
                        Some(after_hashes)
                    } else {
                        None
                    };
                    (lines[block_start..=block_end].join("\n"), name)
                };
                match http::parse(&slice) {
                    Ok(r) => (r, slice, block_name),
                    Err(e) => {
                        self.toast(format!("can't parse request: {e}"));
                        return;
                    }
                }
            }
        };
        let script = http::script::parse(&script_src);
        let mut env = EnvSet::select_with_config_default(
            &self.workspace,
            self.http_env_override.as_deref(),
            self.config.http.default_env.as_deref(),
        );
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in &mut request.headers {
            *v = http::template::expand(v, &env);
        }
        if let Some(b) = &mut request.body {
            *b = http::template::expand(b, &env);
        }

        let job_id = self.spawn_http_job(request.clone(), script.clone(), path.clone());
        let mut rp = crate::request_pane::RequestPane::new(path, request, script, job_id);
        rp.source_block_name = source_block_name;
        let new_id =
            self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, Pane::Request(rp));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Re-send the request a `Pane::Request` already holds (its `r` key / re-`http.send`).
    fn refire_request(&mut self, pane_id: PaneId) {
        // Apply edits from the Headers field (the editable buffer is the
        // source of truth in Edit mode — parse it back before sending).
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.commit_headers();
        }
        let (request, script, source_path) = match self.panes.get(pane_id) {
            Some(Pane::Request(rp)) => (
                rp.request.clone(),
                rp.script.clone(),
                rp.source_path.clone(),
            ),
            _ => return,
        };
        let job_id = self.spawn_http_job(request, script, source_path);
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.job_id = job_id;
            rp.state = crate::request_pane::RunState::Sending;
            rp.scroll = 0;
        }
    }

    /// Allocate a job id, ensure the result channel exists, spawn the worker.
    /// `source_path` (the request's `.curl` / `.http` source file, if any)
    /// is threaded through so the worker can resolve a sibling
    /// `*.schema.json` and validate the response body.
    fn spawn_http_job(
        &mut self,
        mut request: crate::http::Request,
        script: crate::http::script::Script,
        source_path: Option<std::path::PathBuf>,
    ) -> u64 {
        use crate::request_pane::ResponseView;
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .http_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        // 2026-06-19 — cookie jar v1: if the request URL's host
        // has cookies stored, inject a Cookie header (only when
        // the caller didn't already set one). The header value
        // is the on-the-wire `name=v; name=v` form via
        // CookieJar::cookie_header_for.
        let jar = self.cookie_jar.clone();
        if let Some(host) = crate::cookie_jar::CookieJar::host_of(&request.url)
            && !request
                .headers
                .iter()
                .any(|(k, _)| k.eq_ignore_ascii_case("cookie"))
            && let Ok(j) = jar.lock()
            && let Some(cookie) = j.cookie_header_for(&host)
        {
            request.headers.push(("Cookie".to_string(), cookie));
        }
        let host_for_record = crate::cookie_jar::CookieJar::host_of(&request.url);
        std::thread::spawn(move || {
            let result: Result<ResponseView, String> = (|| {
                let resp = crate::http::send(&request)?;
                // Record any Set-Cookie headers from the response.
                if let Some(host) = &host_for_record
                    && let Ok(mut j) = jar.lock()
                {
                    for (k, v) in &resp.headers {
                        if k.eq_ignore_ascii_case("set-cookie") {
                            j.record_set_cookie(host, v);
                        }
                    }
                }
                let assertions = crate::http::script::run_assertions(
                    &script,
                    resp.status,
                    &resp.headers,
                    &resp.body,
                );
                let mut env = crate::http::template::EnvSet::empty();
                let captures = crate::http::script::apply_captures(
                    &script,
                    &resp.headers,
                    &resp.body,
                    &mut env,
                );
                let schema_result = source_path
                    .as_deref()
                    .map(|p| crate::http::schema::validate_for(Some(p), &resp.body));
                Ok(ResponseView {
                    status: resp.status,
                    status_text: resp.status_text,
                    headers: resp.headers,
                    body: resp.body,
                    elapsed: resp.elapsed,
                    assertions,
                    captures,
                    schema_result,
                    sse_event_count: 0,
                })
            })();
            let _ = tx.send((job_id, result));
        });
        job_id
    }

    /// `http.paste_curl` — read the clipboard, parse as curl /
    /// `.http` / `.rest`, overwrite the active Request pane's
    /// Method / URL / Headers / Body. Postman-style "paste a curl
    /// from Chrome DevTools" workflow. If no active Request pane,
    /// opens a blank one first (`:http.new` + `:http.paste_curl`
    /// chain works seamlessly).
    pub fn http_paste_curl_to_active(&mut self) {
        let raw = self.clipboard.text();
        if raw.trim().is_empty() {
            self.toast("http.paste_curl: clipboard is empty");
            return;
        }
        self.http_paste_curl_from_text(&raw);
    }

    /// Core impl behind `http.paste_curl` — parses `raw` as curl /
    /// `.http` / `.rest` and populates the active Request pane's
    /// fields. Opens a new Request pane first if none is active
    /// (matches paste_curl's "just make it work" idiom). Shared
    /// with the bracketed-paste handler so pasting a curl into a
    /// blank Request pane populates the form directly.
    pub fn http_paste_curl_from_text(&mut self, raw: &str) {
        if raw.trim().is_empty() {
            return;
        }
        let parsed = match crate::http::parse(raw) {
            Ok(r) => r,
            Err(e) => {
                self.toast(format!("http.paste_curl: parse failed: {e}"));
                return;
            }
        };
        let has_request = matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(_))
        );
        if !has_request {
            self.open_new_request_pane();
        }
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.headers_buffer = crate::request_pane::headers_to_text(&parsed.headers);
            rp.headers_cursor = rp.headers_buffer.len();
            rp.url_cursor = parsed.url.len();
            rp.body_cursor = parsed.body.as_deref().map(str::len).unwrap_or(0);
            rp.request = parsed;
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.focus = crate::request_pane::EditField::Url;
            rp.edit_tab = crate::request_pane::EditTab::Body;
        }
        let preview = if raw.trim().len() > 56 {
            format!("{}…", &raw.trim()[..54])
        } else {
            raw.trim().to_string()
        };
        self.toast(format!("paste_curl: populated from {preview}"));
    }

    /// Cheap "does this look like a curl / http-file paste?" check.
    /// Used by the bracketed-paste handler to decide whether to
    /// route a paste into the Request pane's field-population path
    /// or fall through to the default (text-insert into focused
    /// field). Handles the "curl -X POST ..." shape plus the
    /// bare-URL + method-verb-prefix shapes that the http/rest
    /// parsers accept.
    pub fn text_looks_like_curl(raw: &str) -> bool {
        let trimmed = raw.trim_start();
        if trimmed.starts_with("curl ") || trimmed.starts_with("curl\t") {
            return true;
        }
        // "GET https://..." / "POST http://..." shape.
        for verb in [
            "GET ", "POST ", "PUT ", "PATCH ", "DELETE ", "HEAD ", "OPTIONS ",
        ] {
            if let Some(rest) = trimmed.strip_prefix(verb)
                && (rest.starts_with("http://") || rest.starts_with("https://"))
            {
                return true;
            }
        }
        false
    }

    /// `http.paste_source` — parse the active Request pane's
    /// `source_buffer` (Source tab) into the structured Method /
    /// URL / Headers / Body fields, clear the buffer, switch to
    /// Body tab. Same parse pipeline as `:http.paste_curl` (just
    /// reads from the pane field instead of the clipboard).
    pub fn http_parse_source_buffer(&mut self) {
        let Some(cur) = self.active else {
            self.toast("paste_source: no active Request pane");
            return;
        };
        let src = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => rp.source_buffer.clone(),
            _ => {
                self.toast("paste_source: active pane is not a Request");
                return;
            }
        };
        if src.trim().is_empty() {
            self.toast("paste_source: Source buffer is empty");
            return;
        }
        let parsed = match crate::http::parse(&src) {
            Ok(r) => r,
            Err(e) => {
                self.toast(format!("paste_source: parse failed: {e}"));
                return;
            }
        };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.headers_buffer = crate::request_pane::headers_to_text(&parsed.headers);
            rp.headers_cursor = rp.headers_buffer.len();
            rp.url_cursor = parsed.url.len();
            rp.body_cursor = parsed.body.as_deref().map(str::len).unwrap_or(0);
            rp.request = parsed;
            rp.source_buffer.clear();
            rp.source_cursor = 0;
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.edit_tab = crate::request_pane::EditTab::Body;
            rp.focus = crate::request_pane::EditField::Url;
            self.toast("paste_source: populated from Source buffer");
        }
    }

    /// `http.diff_last_two` — open a scratch buffer with a
    /// textual diff between the active Request pane's previous
    /// Done response and the current one. Lines starting with
    /// `-` came only from previous, `+` came only from current,
    /// ` ` were shared.
    pub fn http_diff_last_two(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.diff: no active Request pane");
            return;
        };
        let (prev, current) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let cur_rv = match &rp.state {
                    crate::request_pane::RunState::Done(rv) => Some(rv.clone()),
                    _ => None,
                };
                (rp.prev_response.clone(), cur_rv)
            }
            _ => return,
        };
        let (Some(prev), Some(current)) = (prev, current) else {
            self.toast("http.diff: need at least 2 successful sends to diff");
            return;
        };
        let mut out = String::new();
        out.push_str("# HTTP diff — last two responses\n\n");
        out.push_str(&format!(
            "status: {} {} → {} {}\n",
            prev.status, prev.status_text, current.status, current.status_text
        ));
        out.push_str(&format!(
            "elapsed: {}ms → {}ms\n\n",
            prev.elapsed.as_millis(),
            current.elapsed.as_millis()
        ));
        // Headers (set comparison). Render unchanged / removed / added.
        out.push_str("## headers\n\n");
        let prev_set: std::collections::HashSet<(String, String)> =
            prev.headers.iter().cloned().collect();
        let curr_set: std::collections::HashSet<(String, String)> =
            current.headers.iter().cloned().collect();
        for (k, v) in &prev.headers {
            if curr_set.contains(&(k.clone(), v.clone())) {
                out.push_str(&format!("  {k}: {v}\n"));
            } else {
                out.push_str(&format!("- {k}: {v}\n"));
            }
        }
        for (k, v) in &current.headers {
            if !prev_set.contains(&(k.clone(), v.clone())) {
                out.push_str(&format!("+ {k}: {v}\n"));
            }
        }
        out.push_str("\n## body\n\n");
        // Simple line-by-line diff (no LCS — fast + readable for
        // most API responses).
        let p_lines: Vec<&str> = prev.body.lines().collect();
        let c_lines: Vec<&str> = current.body.lines().collect();
        let max = p_lines.len().max(c_lines.len());
        for i in 0..max {
            let pl = p_lines.get(i).copied().unwrap_or("");
            let cl = c_lines.get(i).copied().unwrap_or("");
            if pl == cl {
                out.push_str(&format!("  {pl}\n"));
            } else {
                if !pl.is_empty() {
                    out.push_str(&format!("- {pl}\n"));
                }
                if !cl.is_empty() {
                    out.push_str(&format!("+ {cl}\n"));
                }
            }
        }
        self.open_scratch_with_text("[http-diff]".to_string(), out);
    }

    /// `http.fan_envs` — fan the active Request out against every
    /// env file in the workspace (one fire per env, concurrent),
    /// collect the (env, status, ms, error) tuples, render a
    /// table summary to clipboard + a one-line toast headline.
    /// The fastest way to verify "does this work against dev,
    /// staging, AND prod?" without manually swapping envs.
    pub fn http_fan_envs(&mut self) {
        let Some(request) = self.parse_active_as_request() else {
            self.toast("http.fan_envs: no active .http/.curl/.rest editor");
            return;
        };
        let mut env_names: Vec<String> = Vec::new();
        for sub in [".mnml", ".rqst"] {
            let dir = self.workspace.join(sub).join("env");
            if let Ok(rd) = std::fs::read_dir(&dir) {
                for e in rd.flatten() {
                    let p = e.path();
                    if p.extension().is_some_and(|x| x == "env")
                        && let Some(stem) = p.file_stem().and_then(|s| s.to_str())
                    {
                        let s = stem.to_string();
                        if !env_names.contains(&s) {
                            env_names.push(s);
                        }
                    }
                }
            }
        }
        if env_names.is_empty() {
            self.toast("http.fan_envs: no env files found in .mnml/env or .rqst/env");
            return;
        }
        let workspace = self.workspace.clone();
        let raw_request = request.clone();
        let started = std::time::Instant::now();
        // Concurrent fan-out: one thread per env. Each thread
        // reads its own EnvSet, expands the request URL/headers/
        // body, fires via crate::http::send, returns the tuple.
        let (tx, rx) = std::sync::mpsc::channel();
        for env_name in env_names.iter() {
            let tx = tx.clone();
            let env_name = env_name.clone();
            let ws = workspace.clone();
            let req_template = raw_request.clone();
            std::thread::spawn(move || {
                let env = crate::http::template::EnvSet::load(&ws, &env_name);
                let mut req = req_template.clone();
                req.url = crate::http::template::expand(&req.url, &env);
                for (_, v) in req.headers.iter_mut() {
                    *v = crate::http::template::expand(v, &env);
                }
                if let Some(b) = req.body.as_mut() {
                    *b = crate::http::template::expand(b, &env);
                }
                let started = std::time::Instant::now();
                let result = match crate::http::send(&req) {
                    Ok(resp) => Ok((resp.status, started.elapsed())),
                    Err(e) => Err(e),
                };
                let _ = tx.send((env_name, result));
            });
        }
        drop(tx);
        // Collect all results (blocking — fan_envs is short-lived).
        let mut rows: Vec<(String, String)> = Vec::new();
        let mut clipboard_text = String::from("env\tstatus\tms\n");
        let mut ok_count = 0usize;
        while let Ok((env_name, result)) = rx.recv() {
            let line = match result {
                Ok((status, elapsed)) => {
                    let ms = elapsed.as_millis();
                    if (200..300).contains(&status) {
                        ok_count += 1;
                    }
                    clipboard_text.push_str(&format!("{env_name}\t{status}\t{ms}\n"));
                    format!("{env_name}: {status} ({ms}ms)")
                }
                Err(e) => {
                    clipboard_text.push_str(&format!("{env_name}\tERR\t{e}\n"));
                    format!("{env_name}: ERR ({e})")
                }
            };
            rows.push((env_name, line));
        }
        let elapsed = started.elapsed().as_millis();
        let total = rows.len();
        let summary = rows
            .iter()
            .map(|(_, l)| l.as_str())
            .collect::<Vec<_>>()
            .join(" · ");
        self.clipboard.set(clipboard_text, false);
        self.toast(format!(
            "fan_envs: {ok_count}/{total} OK in {elapsed}ms · {summary} · (full table → clipboard)"
        ));
    }

    /// `http.import_postman` — read a Postman Collection v2.1
    /// JSON from clipboard and explode it into N `.curl` files
    /// under `<workspace>/.rqst/captured/postman-<collection-name>/`.
    /// Folder hierarchy is flattened into filenames so the
    /// collection's grouping survives (`<group>__<request>.curl`).
    /// Postman variables (`{{token}}`) are preserved verbatim —
    /// they match mnml's existing template syntax so they round-
    /// trip through `:http.send` naturally.
    pub fn http_import_postman_from_clipboard(&mut self) {
        let raw = self.clipboard.text();
        if raw.trim().is_empty() {
            self.toast("http.import_postman: clipboard is empty");
            return;
        }
        let parsed: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(v) => v,
            Err(e) => {
                self.toast(format!("postman: not valid JSON: {e}"));
                return;
            }
        };
        // Postman collection top-level shape: { info: { name }, item: [...] }
        let coll_name = parsed
            .get("info")
            .and_then(|i| i.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("collection")
            .chars()
            .map(|c| if c.is_alphanumeric() { c } else { '_' })
            .collect::<String>();
        let Some(items) = parsed.get("item").and_then(|i| i.as_array()) else {
            self.toast("postman: missing `item` array (not a Collection?)");
            return;
        };
        let out_dir = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join(format!("postman-{coll_name}"));
        if let Err(e) = std::fs::create_dir_all(&out_dir) {
            self.toast(format!("postman: mkdir {}: {e}", out_dir.display()));
            return;
        }
        // Walk the (potentially nested) item tree. Each leaf has a
        // `request` field; each folder has its own `item` array.
        fn walk(
            items: &[serde_json::Value],
            prefix: &str,
            out_dir: &std::path::Path,
            counter: &mut usize,
            written: &mut usize,
        ) {
            for item in items {
                let name = item
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("unnamed")
                    .chars()
                    .map(|c| if c.is_alphanumeric() { c } else { '_' })
                    .collect::<String>();
                if let Some(sub) = item.get("item").and_then(|i| i.as_array()) {
                    let new_prefix = if prefix.is_empty() {
                        name.clone()
                    } else {
                        format!("{prefix}__{name}")
                    };
                    walk(sub, &new_prefix, out_dir, counter, written);
                    continue;
                }
                let Some(req) = item.get("request") else {
                    continue;
                };
                let method = req
                    .get("method")
                    .and_then(|m| m.as_str())
                    .unwrap_or("GET")
                    .to_uppercase();
                let url = req
                    .get("url")
                    .and_then(|u| match u {
                        serde_json::Value::String(s) => Some(s.clone()),
                        serde_json::Value::Object(_) => {
                            u.get("raw").and_then(|r| r.as_str()).map(str::to_string)
                        }
                        _ => None,
                    })
                    .unwrap_or_default();
                if url.is_empty() {
                    continue;
                }
                let mut curl = format!("curl -X {method} '{url}'");
                if let Some(headers) = req.get("header").and_then(|h| h.as_array()) {
                    for h in headers {
                        let (Some(name), Some(value)) = (
                            h.get("key").and_then(|n| n.as_str()),
                            h.get("value").and_then(|v| v.as_str()),
                        ) else {
                            continue;
                        };
                        if h.get("disabled").and_then(|d| d.as_bool()).unwrap_or(false) {
                            continue;
                        }
                        curl.push_str(&format!(" \\\n  -H '{name}: {value}'"));
                    }
                }
                if let Some(body) = req.get("body")
                    && let Some(raw) = body.get("raw").and_then(|r| r.as_str())
                    && !raw.is_empty()
                {
                    let escaped = raw.replace('\'', "'\\''");
                    curl.push_str(&format!(" \\\n  --data '{escaped}'"));
                }
                let stem = if prefix.is_empty() {
                    format!("{counter:03}_{name}")
                } else {
                    format!("{counter:03}_{prefix}__{name}")
                };
                *counter += 1;
                let path = out_dir.join(format!("{stem}.curl"));
                if std::fs::write(&path, curl).is_ok() {
                    *written += 1;
                }
            }
        }
        let mut counter = 0usize;
        let mut written = 0usize;
        walk(items, "", &out_dir, &mut counter, &mut written);
        self.toast(format!(
            "postman: wrote {written} curls → {}",
            out_dir.display()
        ));
    }

    /// `http.import_har` — read a HAR (HTTP Archive) from the
    /// clipboard, write one `.curl` file per HAR entry into
    /// `<workspace>/.rqst/captured/har-<ts>/`. The natural follow-
    /// up to `:http.paste_curl` for users with many requests:
    /// "save all as HAR" in DevTools, paste here, get N fireable
    /// curls. Spec: <http://www.softwareishard.com/blog/har-12-spec/>.
    pub fn http_import_har_from_clipboard(&mut self) {
        let raw = self.clipboard.text();
        if raw.trim().is_empty() {
            self.toast("http.import_har: clipboard is empty");
            return;
        }
        let parsed: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(v) => v,
            Err(e) => {
                self.toast(format!("har: not valid JSON: {e}"));
                return;
            }
        };
        let entries = parsed
            .get("log")
            .and_then(|l| l.get("entries"))
            .and_then(|e| e.as_array());
        let Some(entries) = entries else {
            self.toast("har: missing log.entries (not a HAR file?)");
            return;
        };
        // Stable directory name: timestamp from the first entry's
        // startedDateTime, falling back to a counter, so the path
        // is deterministic across re-imports.
        let stem = entries
            .first()
            .and_then(|e| e.get("startedDateTime"))
            .and_then(|s| s.as_str())
            .map(|s| s.replace(':', "-").chars().take(19).collect::<String>())
            .unwrap_or_else(|| "import".to_string());
        let out_dir = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join(format!("har-{stem}"));
        if let Err(e) = std::fs::create_dir_all(&out_dir) {
            self.toast(format!("har: mkdir {}: {e}", out_dir.display()));
            return;
        }
        let mut written = 0usize;
        for (i, entry) in entries.iter().enumerate() {
            let Some(req) = entry.get("request") else {
                continue;
            };
            let method = req
                .get("method")
                .and_then(|m| m.as_str())
                .unwrap_or("GET")
                .to_uppercase();
            let Some(url) = req.get("url").and_then(|u| u.as_str()) else {
                continue;
            };
            let mut curl = format!("curl -X {method} '{url}'");
            if let Some(headers) = req.get("headers").and_then(|h| h.as_array()) {
                for h in headers {
                    let (Some(name), Some(value)) = (
                        h.get("name").and_then(|n| n.as_str()),
                        h.get("value").and_then(|v| v.as_str()),
                    ) else {
                        continue;
                    };
                    // Skip pseudo-headers; Chrome HAR emits them
                    // (`:method`, `:authority`) but they're not
                    // usable as curl `-H` args.
                    if name.starts_with(':') {
                        continue;
                    }
                    curl.push_str(&format!(" \\\n  -H '{name}: {value}'"));
                }
            }
            if let Some(post) = req
                .get("postData")
                .and_then(|p| p.get("text"))
                .and_then(|t| t.as_str())
                && !post.is_empty()
            {
                let escaped = post.replace('\'', "'\\''");
                curl.push_str(&format!(" \\\n  --data '{escaped}'"));
            }
            // Filename: derived from host + path so users can grep.
            // Plain parse — strip query string, sanitize each
            // component to ASCII alphanum/underscore.
            let host_path = {
                let stripped = url.split('?').next().unwrap_or(url);
                let after_scheme = stripped
                    .split_once("://")
                    .map(|(_, r)| r)
                    .unwrap_or(stripped);
                after_scheme
                    .chars()
                    .map(|c| if c.is_alphanumeric() { c } else { '_' })
                    .collect::<String>()
                    .chars()
                    .take(80)
                    .collect::<String>()
            };
            let stem = if host_path.is_empty() {
                format!("entry_{i:03}")
            } else {
                format!("{i:03}_{host_path}")
            };
            let path = out_dir.join(format!("{stem}.curl"));
            if std::fs::write(&path, curl).is_ok() {
                written += 1;
            }
        }
        self.toast(format!(
            "har: wrote {written} curls → {}",
            out_dir.display()
        ));
    }

    /// `http.params_add` — open a prompt to type `KEY=VALUE`,
    /// append to the active Request pane's URL as a query
    /// parameter. Used when on the Params tab and you want to add
    /// a new param without hand-editing the URL field.
    pub fn http_params_add(&mut self) {
        let has_request = matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(_))
        );
        if !has_request {
            self.toast("http.params_add: no active Request pane");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::HttpParamAdd,
            "Query parameter KEY=VALUE:".to_string(),
        ));
    }

    /// Accept handler for `PromptKind::HttpParamAdd`. Appends the
    /// param to the active URL with the correct separator.
    pub fn accept_http_param_add(&mut self, input: &str) {
        let Some((key, value)) = input.split_once('=') else {
            self.toast("params: input must be KEY=VALUE");
            return;
        };
        let key = key.trim();
        if key.is_empty() {
            self.toast("params: key can't be empty");
            return;
        }
        let value = value.trim();
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let sep = if rp.request.url.contains('?') {
                '&'
            } else {
                '?'
            };
            rp.request.url.push(sep);
            rp.request.url.push_str(key);
            rp.request.url.push('=');
            rp.request.url.push_str(value);
            rp.url_cursor = rp.request.url.len();
            // Auto-switch to Params tab so user sees the addition.
            rp.edit_tab = crate::request_pane::EditTab::Params;
            self.toast(format!("params: added {key}={value}"));
        }
    }

    /// Delete a single query param `key` from the active URL.
    /// Used by the Params-tab row click. No-op when the param
    /// isn't present.
    pub fn http_params_delete(&mut self, key: &str) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let url = &rp.request.url;
            let Some(qi) = url.find('?') else { return };
            let (base, query) = url.split_at(qi);
            let query = &query[1..]; // strip the leading `?`
            let remaining: Vec<&str> = query
                .split('&')
                .filter(|kv| {
                    let k = kv.split_once('=').map(|(k, _)| k).unwrap_or(*kv);
                    k != key
                })
                .collect();
            let new_url = if remaining.is_empty() {
                base.to_string()
            } else {
                format!("{base}?{}", remaining.join("&"))
            };
            rp.request.url = new_url;
            rp.url_cursor = rp.request.url.len();
            self.toast(format!("params: deleted {key}"));
        }
    }

    /// `http.params_clear` — strip the entire `?…` portion from
    /// the active Request URL.
    pub fn http_params_clear(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            if let Some(i) = rp.request.url.find('?') {
                let removed = rp.request.url[i..].to_string();
                rp.request.url.truncate(i);
                rp.url_cursor = rp.request.url.len();
                self.toast(format!("params: cleared {removed}"));
            } else {
                self.toast("params: no query string on URL");
            }
        }
    }

    /// `http.abort` — release the UI-side tracking for any
    /// in-flight HTTP work (bench / sync / lookup fire). The
    /// worker thread keeps running until it naturally completes
    /// (~seconds for bench / sync, possibly minutes for SSE), but
    /// the user gets immediate UI feedback that they've moved on.
    /// Late results from the orphaned thread land on a dropped
    /// receiver and are silently discarded.
    ///
    /// True cancellation (interrupting a worker mid-network-call)
    /// is a v3 follow-up that would need cooperative cancel tokens
    /// threaded through reqwest::blocking — or a switch to async
    /// reqwest with proper drop semantics. The simpler "drop the
    /// rx" path covers the user-visible case (toast clears, "next
    /// thing please") without rearchitecting the worker shape.
    pub fn http_abort_all(&mut self) {
        // 2026-06-21 api-workflow SEV-2 — was leaving
        // http_chain_in_flight + http_ai_build_in_flight set, so a
        // stalled chain or AI build was unrecoverable. Now resets
        // both flags. The chain / ai-build workers themselves can't
        // be killed mid-flight (std HTTP / Anthropic API are
        // blocking), but the user can retry instead of waiting.
        let was_active = self.http_bench_rx.is_some()
            || self.http_sync_rx.is_some()
            || self.lookup_fire_rx.is_some()
            || self.http_chain_in_flight
            || self.http_ai_build_in_flight;
        self.http_bench_rx = None;
        self.http_sync_rx = None;
        self.lookup_fire_rx = None;
        self.http_chain_in_flight = false;
        self.http_ai_build_in_flight = false;
        if was_active {
            self.toast("http: released UI tracking (worker finishes in background)");
        } else {
            self.toast("http: nothing in flight");
        }
    }

    /// `http.cycle_method` — cycle the active Request pane's
    /// method through the standard verbs. Same gesture as Space
    /// when the Method field is focused, but reachable from the
    /// palette / Method-row context menu without keyboard focus.
    pub fn http_cycle_method(&mut self) {
        let Some(cur) = self.active else { return };
        // 2026-06-19 — api-workflow third hunt SEV-3: this used an
        // inline verb list that swapped PATCH and DELETE vs
        // `STANDARD_METHODS`, so the palette command's cycle order
        // diverged from Space-key cycling in the Method field. Use
        // the canonical list.
        let new_method = if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            let cycled = crate::request_pane::cycle_method(&rp.request.method);
            rp.request.method = cycled.clone();
            Some(cycled)
        } else {
            None
        };
        if let Some(m) = new_method {
            self.toast(format!("method: {m}"));
        }
    }

    /// `http.new` — open a blank Request pane in Edit mode for
    /// the "I want to start a request without thinking about files
    /// first" Postman-style workflow. The pane has:
    ///   * Method = GET, URL = empty, headers = none, body = none
    ///   * view = Edit (the form is visible immediately)
    ///   * focus = URL (typing populates URL)
    ///   * state = Failed("(not sent — press `r` to fire)") so
    ///     the response panel shows a useful hint instead of an
    ///     empty Sending… spinner
    ///   * source_path = None (Ctrl+S toasts "no source file";
    ///     save-as is a v2 follow-up)
    /// User-requested 2026-06-19 — closing the "where's the new-
    /// request button" gap.
    pub fn open_new_request_pane(&mut self) {
        use crate::request_pane::{EditField, RequestPane, RunState, ViewMode};
        let request = crate::http::Request {
            method: "GET".to_string(),
            url: String::new(),
            headers: Vec::new(),
            body: None,
        };
        let mut pane = RequestPane::new(None, request, crate::http::script::Script::default(), 0);
        pane.view = ViewMode::Edit;
        pane.focus = EditField::Url;
        pane.state = RunState::Failed("not sent yet · press `r` to fire".to_string());
        let new_id = match self.active {
            Some(cur) => {
                self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, Pane::Request(pane))
            }
            None => {
                self.panes.push(Pane::Request(pane));
                let new_id = self.panes.len() - 1;
                // 2026-06-19 — api-workflow third hunt caught SEV-1:
                // the earlier path forgot to seed the layout tree
                // (still `Layout::Empty`), so the new pane was
                // tracked in panes[] + active but rendered nothing.
                // Mirror what every other empty-state landing path
                // does (e.g. `open_path` at mod.rs:5247).
                *self.layout_mut() = crate::layout::Layout::leaf(new_id);
                new_id
            }
        };
        self.active = Some(new_id);
        self.focus = Focus::Pane;
        self.toast("new request — Tab cycles fields, `r` fires");
    }

    /// `http.send_streaming` — like `http.send`, but the response
    /// is read as Server-Sent Events. The worker keeps the
    /// connection open (no client timeout), pulls events through
    /// `crate::sse::Reader`, and renders the buffered event list
    /// into the Response pane body when the stream closes. Use for
    /// Anthropic / OpenAI / SSE-style `text/event-stream` endpoints
    /// where the server holds the socket and pushes events over
    /// time.
    ///
    /// Buffered (not progressive): events are collected server-side
    /// then displayed at end. Progressive in-pane display as events
    /// arrive is a v2 follow-up. Phase 8 polish — 2026-06-19.
    pub fn send_streaming_from_active(&mut self) {
        let Some(request) = self.parse_active_as_request() else {
            self.toast("http.send_streaming: no active .http/.curl/.rest editor");
            return;
        };
        let script = crate::http::script::Script::default();
        let job_id = self.spawn_sse_streaming_job(request.clone(), script.clone());
        let Some(cur) = self.active else {
            return;
        };
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            None, request, script, job_id,
        ));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
        self.toast("http.send_streaming: opening SSE stream…");
    }

    /// Background worker for SSE streaming. Builds a reqwest client
    /// with NO timeout (servers keep SSE connections open
    /// indefinitely; a 30s default would close us first), fires the
    /// request, wraps the response in `crate::sse::Reader`, drains
    /// every event, and posts a synthetic `ResponseView` whose body
    /// is the formatted event list (`[event_name] data` per
    /// block) over the existing `http_chan`. Status / headers /
    /// elapsed pulled from the underlying response.
    fn spawn_sse_streaming_job(
        &mut self,
        request: crate::http::Request,
        _script: crate::http::script::Script,
    ) -> u64 {
        use crate::request_pane::SseStreamMsg;
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .sse_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        std::thread::spawn(move || {
            // 2026-06-20 — progressive display. Worker now sends
            // Open → Event* → Close (was: buffered all events,
            // sent one synthetic ResponseView). App.tick mutates
            // the matching pane's Streaming state in real time.
            let send_err = |error: String| {
                let _ = tx.send(SseStreamMsg::Error { job_id, error });
            };
            let _result: Result<(), String> = (|| {
                // 2026-06-19 — api-workflow-user agent flagged
                // that `timeout(None)` leaks the worker thread for
                // any endpoint that holds the socket without
                // sending events (long-poll, badly-configured
                // SSE, hung server). A per-read timeout of 60s
                // exits the loop on quiet sockets without
                // blocking SSE streams that actually emit events
                // (every event resets the timer in `read_line`).
                // Generous overall timeout so a slow SSE server
                // can stream for many minutes; quiet sockets exit
                // via the natural timeout. Full cancellation
                // (Esc to abort an in-flight stream) is a v2
                // follow-up that would need a channel back to
                // the worker.
                let client = reqwest::blocking::Client::builder()
                    .timeout(std::time::Duration::from_secs(600))
                    .build()
                    .map_err(|e| format!("client build failed: {e}"))?;
                let method = reqwest::Method::from_bytes(request.method.to_uppercase().as_bytes())
                    .map_err(|_| format!("invalid HTTP method {:?}", request.method))?;
                let mut req = client.request(method, &request.url);
                for (k, v) in &request.headers {
                    req = req.header(k, v);
                }
                if let Some(body) = &request.body {
                    req = req.body(body.clone());
                }
                let started = std::time::Instant::now();
                let resp = req.send().map_err(|e| format!("send: {e}"))?;
                let status = resp.status().as_u16();
                let status_text = resp.status().canonical_reason().unwrap_or("").to_string();
                let headers: Vec<(String, String)> = resp
                    .headers()
                    .iter()
                    .map(|(k, v)| (k.as_str().to_string(), v.to_str().unwrap_or("").to_string()))
                    .collect();
                // Open message → App allocates Streaming state.
                if tx
                    .send(SseStreamMsg::Open {
                        job_id,
                        status,
                        status_text,
                        headers,
                        started,
                    })
                    .is_err()
                {
                    return Ok(()); // receiver dropped → abort
                }
                let mut reader = crate::sse::Reader::new(resp);
                loop {
                    match reader.next_event() {
                        Ok(Some(evt)) => {
                            if tx
                                .send(SseStreamMsg::Event {
                                    job_id,
                                    name: evt.name,
                                    data: evt.data,
                                })
                                .is_err()
                            {
                                return Ok(());
                            }
                        }
                        Ok(None) => break,
                        Err(e) => {
                            let _ = tx.send(SseStreamMsg::Error {
                                job_id,
                                error: e.to_string(),
                            });
                            return Ok(());
                        }
                    }
                }
                let _ = tx.send(SseStreamMsg::Close { job_id });
                Ok(())
            })();
            if let Err(e) = _result {
                send_err(e);
            }
        });
        job_id
    }

    /// `http.copy_curl` — copy the active request (in an editor: parse the buffer;
    /// in a request pane: the request it holds) to the clipboard as a curl command.
    pub fn copy_active_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => Some(rp.as_curl()),
            Some(Pane::Editor(b))
                if matches!(b.language_ext.as_deref(), Some("http" | "rest" | "curl")) =>
            {
                crate::http::parse(b.editor.text()).ok().map(|r| {
                    crate::request_pane::RequestPane::new(None, r, Default::default(), 0).as_curl()
                })
            }
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no request here to copy"),
        }
    }

    /// Deliver any completed background HTTP sends to their request panes.
    /// 2026-06-20 — drain progressive SSE stream messages and
    /// mutate the matching Request pane's Streaming state.
    pub(super) fn drain_sse_jobs(&mut self) {
        use crate::request_pane::{ResponseView, RunState, SseStreamMsg};
        let Some((_, rx)) = &self.sse_chan else {
            return;
        };
        let msgs: Vec<SseStreamMsg> = rx.try_iter().collect();
        for msg in msgs {
            match msg {
                SseStreamMsg::Open {
                    job_id,
                    status,
                    status_text,
                    headers,
                    started,
                } => {
                    // Find pane with matching job_id.
                    if let Some((pid, _)) = self
                        .panes
                        .iter()
                        .enumerate()
                        .find(|(_, p)| matches!(p, Pane::Request(r) if r.job_id == job_id))
                        && let Some(Pane::Request(rp)) = self.panes.get_mut(pid)
                    {
                        // 2026-06-21 SEV-3 fix: capture any
                        // prior Done into prev_response BEFORE
                        // overwriting state with Streaming.
                        if let RunState::Done(prev) =
                            std::mem::replace(&mut rp.state, RunState::Sending)
                        {
                            rp.prev_response = Some(prev);
                        }
                        rp.state = RunState::Streaming(Box::new(ResponseView {
                            status,
                            status_text,
                            headers,
                            body: String::new(),
                            elapsed: started.elapsed(),
                            assertions: Vec::new(),
                            captures: Vec::new(),
                            schema_result: None,
                            sse_event_count: 0,
                        }));
                    }
                }
                SseStreamMsg::Event { job_id, name, data } => {
                    if let Some((pid, _)) = self
                        .panes
                        .iter()
                        .enumerate()
                        .find(|(_, p)| matches!(p, Pane::Request(r) if r.job_id == job_id))
                        && let Some(Pane::Request(rp)) = self.panes.get_mut(pid)
                        && let RunState::Streaming(rv) = &mut rp.state
                    {
                        if !name.is_empty() {
                            rv.body.push_str(&format!("[{name}]\n"));
                        }
                        rv.body.push_str(&data);
                        rv.body.push_str("\n\n");
                        // 2026-06-21 api-workflow SEV-2: proper
                        // per-pane SSE event counter. Was
                        // pushing empty ("", "") into captures
                        // — abused as a counter, then clobbered
                        // any real @capture results on Close.
                        rv.sse_event_count = rv.sse_event_count.saturating_add(1);
                    }
                }
                SseStreamMsg::Close { job_id } => {
                    // prev_response was already captured at the
                    // start of the stream (when we replaced any
                    // prior Done with the new Streaming). Here we
                    // just promote the in-flight Streaming → Done.
                    if let Some((pid, _)) = self
                        .panes
                        .iter()
                        .enumerate()
                        .find(|(_, p)| matches!(p, Pane::Request(r) if r.job_id == job_id))
                        && let Some(Pane::Request(rp)) = self.panes.get_mut(pid)
                    {
                        let source_path = rp.source_path.clone();
                        if let RunState::Streaming(rv) =
                            std::mem::replace(&mut rp.state, RunState::Sending)
                        {
                            let mut rv = *rv;
                            // captures stays untouched — was
                            // being cleared as part of the
                            // event-counter hack.
                            rv.schema_result = source_path
                                .as_deref()
                                .map(|p| crate::http::schema::validate_for(Some(p), &rv.body));
                            rp.state = RunState::Done(Box::new(rv));
                        }
                    }
                }
                SseStreamMsg::Error { job_id, error } => {
                    if let Some((pid, _)) = self
                        .panes
                        .iter()
                        .enumerate()
                        .find(|(_, p)| matches!(p, Pane::Request(r) if r.job_id == job_id))
                        && let Some(Pane::Request(rp)) = self.panes.get_mut(pid)
                    {
                        rp.state = RunState::Failed(error);
                    }
                }
            }
        }
    }

    pub(super) fn drain_http_jobs(&mut self) {
        use crate::request_pane::RunState;
        let Some((_, rx)) = &self.http_chan else {
            return;
        };
        let done: Vec<HttpJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        let workspace = self.workspace.clone();
        for (job_id, result) in done {
            let Some(Pane::Request(rp)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Request(rp) if rp.job_id == job_id && matches!(rp.state, RunState::Sending)),
            ) else {
                continue;
            };
            match result {
                Ok(rv) => {
                    let failed = rv.assertions.iter().filter(|a| !a.passed).count();
                    let total = rv.assertions.len();
                    toasts.push(if total > 0 {
                        format!(
                            "← {} · {}/{} asserts passed",
                            rv.status,
                            total - failed,
                            total
                        )
                    } else {
                        format!("← {} {}", rv.status, rv.status_text)
                    });
                    // Phase 9 — append to .rqst/history.jsonl so
                    // grep/jq workflows AND the in-app `http.history`
                    // viewer see the request.
                    crate::http::history::append_with_global_mirror(
                        &workspace,
                        &crate::http::history::Entry {
                            method: &rp.request.method,
                            url: &rp.request.url,
                            status: Some(rv.status),
                            duration_ms: Some(rv.elapsed.as_millis()),
                            body_bytes: Some(rv.body.len()),
                            error: None,
                            headers: Some(&rp.request.headers),
                            request_body: rp.request.body.as_deref(),
                        },
                    );
                    // 2026-06-19 — diff support: shift the
                    // previous Done into prev_response so
                    // :http.diff_last_two can compare. Done →
                    // prev_response; new rv → state.
                    if let RunState::Done(prev) =
                        std::mem::replace(&mut rp.state, RunState::Done(Box::new(rv)))
                    {
                        rp.prev_response = Some(prev);
                    }
                }
                Err(e) => {
                    toasts.push(format!("request failed: {e}"));
                    // Failed sends still get a history entry so
                    // forensic queries can find them.
                    crate::http::history::append_with_global_mirror(
                        &workspace,
                        &crate::http::history::Entry {
                            method: &rp.request.method,
                            url: &rp.request.url,
                            status: None,
                            duration_ms: None,
                            body_bytes: None,
                            error: Some(&e),
                            headers: Some(&rp.request.headers),
                            request_body: rp.request.body.as_deref(),
                        },
                    );
                    rp.state = RunState::Failed(e);
                }
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    /// `Ctrl+S` over the active `Pane::Request` — write the current request
    /// (with the in-pane edits applied) back to its source file as a curl
    /// command. Pane has no `source_path` ⇒ toast and bail.
    pub fn save_request_to_source(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.commit_headers();
        }
        // Snapshot the pane state in one pass so we can let go of the borrow
        // before any disk I/O.
        let (path, ext, source_block_name, curl_text, http_block) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(p) = rp.source_path.clone() else {
                    self.toast("no source file to save to (re-fire is in-memory only)");
                    return;
                };
                let ext = p
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                (
                    p,
                    ext,
                    rp.source_block_name.clone(),
                    rp.as_curl(),
                    rp.as_http_block(rp.source_block_name.as_deref()),
                )
            }
            _ => return,
        };
        // Multi-block `.http` / `.rest` source: splice just that block in
        // place so the other blocks survive. If the splice can't find a
        // home for the edit (file was edited externally and the block we
        // sent from is gone) we refuse rather than overwrite — losing the
        // other blocks would be the worst possible outcome.
        // http-2nd 2026-06-28 SEV-1: was guarded on
        // `source_block_name.is_some()` so unnamed LEADING blocks
        // (no `###` separator) fell through to the whole-file
        // overwrite — destroying every subsequent `### named` block.
        // splice_http_block correctly handles `None` (matches the
        // leading block by the no-separator-name predicate), so the
        // only fix needed is to enter the splice path for all .http
        // sources, not just named-block ones.
        if matches!(ext.as_str(), "http" | "rest") {
            let existing = match std::fs::read_to_string(&path) {
                Ok(t) => t,
                Err(e) => {
                    self.toast(format!("save failed: {e}"));
                    return;
                }
            };
            // http-2nd 2026-06-28 SEV-2: splice_http_block returns
            // None when blocks.len() < 2 (single-block file). The
            // old gate `source_block_name.is_some()` skipped the
            // splice for single-block sources; removing it (5020def)
            // for leading-block correctness made single-block .http
            // saves error-toast instead of falling through. If the
            // file is multi-block, splice returns Some; if it's
            // single-block, splice returns None and we fall through
            // to the whole-file overwrite below.
            if let Some(new_text) =
                splice_http_block(&existing, source_block_name.as_deref(), &http_block)
            {
                match std::fs::write(&path, &new_text) {
                    Ok(()) => {
                        let rel = rel_path(&self.workspace, &path);
                        self.toast(format!("saved block → {rel}"));
                        self.git.refresh();
                    }
                    Err(e) => self.toast(format!("save failed: {e}")),
                }
                return;
            }
            // Single-block .http/.rest — splice returned None
            // because blocks.len() < 2. Fall through to overwrite.
        }
        // Single-block source (`.curl`, or `.http` whose only block is the
        // one we're saving): overwrite with the curl one-liner. Same as the
        // pre-multi-block behavior.
        match std::fs::write(&path, format!("{curl_text}\n")) {
            Ok(()) => {
                let rel = rel_path(&self.workspace, &path);
                self.toast(format!("saved request → {rel}"));
                self.git.refresh();
            }
            Err(e) => self.toast(format!("save failed: {e}")),
        }
    }
}

#[cfg(test)]
mod http_tests {
    use super::*;

    #[test]
    fn request_pane_save_writes_curl_back_to_source() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("hello.curl");
        std::fs::write(&src, "curl 'https://x/'\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Build a Request pane manually (no real HTTP send — we just want to
        // exercise the save-back path).
        let (cmd_tx, _cmd_rx) = std::sync::mpsc::channel::<crate::cdp::CdpCommand>();
        let _ = cmd_tx; // silence unused; we don't have a worker
        let req = crate::http::Request {
            method: "POST".into(),
            url: "https://example.test/v1".into(),
            headers: vec![("Accept".into(), "application/json".into())],
            body: Some(r#"{"q":1}"#.into()),
        };
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            Some(src.clone()),
            req,
            crate::http::script::Script::default(),
            1,
        ));
        app.panes.push(pane);
        app.active = Some(app.panes.len() - 1);
        app.save_request_to_source();
        let on_disk = std::fs::read_to_string(&src).unwrap();
        assert!(on_disk.contains("curl 'https://example.test/v1'"));
        // POST + --data-raw lets curl infer POST, so `-X POST` is omitted.
        assert!(on_disk.contains("Accept: application/json"));
        assert!(on_disk.contains(r#"--data-raw '{"q":1}'"#));
    }

    #[test]
    fn splice_http_block_preserves_other_blocks() {
        let src = "\
### one
GET https://example.com/one

### two
POST https://example.com/two
Content-Type: application/json

{\"a\": 1}

### three
GET https://example.com/three
";
        let new_two = "### two\nPUT https://example.com/two-EDITED\n";
        let out = splice_http_block(src, Some("two"), new_two).unwrap();
        // The other blocks survive verbatim.
        assert!(out.contains("### one\nGET https://example.com/one"));
        assert!(out.contains("### three\nGET https://example.com/three"));
        // The target block is the edited one, not the original.
        assert!(out.contains("PUT https://example.com/two-EDITED"));
        assert!(!out.contains("POST https://example.com/two"));
        // Trailing-newline policy preserved.
        assert!(out.ends_with('\n'));
    }

    #[test]
    fn splice_http_block_returns_none_for_single_block() {
        let src = "GET https://example.com\n";
        let new_text = "### x\nPUT https://example.com\n";
        // Single-block file ⇒ caller falls back to whole-file overwrite.
        assert!(splice_http_block(src, Some("x"), new_text).is_none());
    }

    #[test]
    fn splice_http_block_returns_none_when_name_missing() {
        let src = "\
### a
GET https://example.com/a

### b
GET https://example.com/b
";
        // No block named "missing" ⇒ caller falls back to overwrite (which the
        // user would notice is destructive — better than silently editing the
        // wrong block).
        assert!(splice_http_block(src, Some("missing"), "### missing\nGET x\n").is_none());
    }

    #[test]
    fn splice_http_block_handles_unnamed_leading_block() {
        // The leading block in a multi-block .http file may not have a `###`
        // separator. Editing it shouldn't disturb the named blocks below.
        let src = "\
GET https://example.com/leading

### second
GET https://example.com/second
";
        let new_text = "PUT https://example.com/leading-EDITED\n";
        let out = splice_http_block(src, None, new_text).unwrap();
        assert!(out.contains("PUT https://example.com/leading-EDITED"));
        assert!(out.contains("### second\nGET https://example.com/second"));
        assert!(!out.contains("GET https://example.com/leading\n"));
    }

    #[test]
    fn splice_http_block_preserves_blank_separator_before_first_named_block() {
        // api-workflow-user 3rd 2026-06-29 SEV-3: editing the unnamed
        // leading block used to strip the blank line between it and
        // the first `### name` block (the leading block's end_line
        // absorbs the trailing blank, and as_http_block(None)
        // doesn't emit a replacement blank). Lock the fix.
        let src = "\
GET https://example.com/leading

### second
GET https://example.com/second
";
        let new_text = "PUT https://example.com/leading-EDITED\n";
        let out = splice_http_block(src, None, new_text).unwrap();
        // Blank line must survive between the replaced leading block
        // and the `### second` separator.
        assert!(
            out.contains("EDITED\n\n### second"),
            "expected blank line between leading-block replacement and `### second`, got:\n{out}"
        );
    }
}
