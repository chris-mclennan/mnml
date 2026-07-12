//! Request chains — a sequence of `.curl` / `.http` requests where each step can
//! extract values from its response into variables the later steps `{{…}}`.
//!
//! Chain file format (JSON, e.g. `<workspace>/.mnml/chains/<name>.chain.json`):
//!
//! ```json
//! [
//!   { "request": "auth/login.curl", "extract": { "TOKEN": "$.access_token" } },
//!   { "request": "merchant/get-locations.curl" }
//! ]
//! ```
//!
//! `extract` binds a variable name to a path into the JSON response body — the
//! same `.foo.bar[0]` / `$.path` subset [`super::script::resolve_json_path`]
//! accepts. `@assert` / `@capture` directives in a step's file work too (captures
//! also flow into the running env). The chain stops at the first transport error,
//! non-2xx/3xx status, failed assertion, or extraction that produces nothing.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::script::{self};
use super::template::{self, EnvSet};

#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub request: PathBuf,
    /// `(var_name, json_path)` extractions applied to the response.
    pub extract: Vec<(String, String)>,
}

/// Parse a `.chain.json` file body into steps. Returns
/// `(steps, unknown_keys)` where `unknown_keys` names any per-step
/// keys the parser doesn't understand — `if`, `retry`, `parallel`,
/// etc. Runtime callers surface these to the user so the silent
/// no-op behaviour is at least visible. api-workflow round-9 SEV-3
/// 2026-07-11.
pub fn parse(text: &str) -> Result<Vec<Step>, String> {
    parse_verbose(text).map(|(steps, _)| steps)
}

pub fn parse_verbose(text: &str) -> Result<(Vec<Step>, Vec<String>), String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("parse chain: {e}"))?;
    let arr = v.as_array().ok_or("chain must be a JSON array")?;
    let mut out = Vec::new();
    let mut unknown_keys: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    const KNOWN_KEYS: &[&str] = &["request", "extract"];
    for (i, step) in arr.iter().enumerate() {
        let request = step
            .get("request")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("step {i}: missing \"request\""))?
            .to_string();
        let extract = step
            .get("extract")
            .and_then(Value::as_object)
            .map(|obj| {
                obj.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        if let Some(obj) = step.as_object() {
            for k in obj.keys() {
                if !KNOWN_KEYS.contains(&k.as_str()) {
                    unknown_keys.insert(k.clone());
                }
            }
        }
        out.push(Step {
            request: PathBuf::from(request),
            extract,
        });
    }
    Ok((out, unknown_keys.into_iter().collect()))
}

/// Resolve `step.request` against, in order: absolute path → relative to
/// `chain_dir` → `workspace/.mnml/requests/` → `workspace`.
pub fn resolve_request_path(
    step_request: &Path,
    chain_dir: &Path,
    workspace: &Path,
) -> Option<PathBuf> {
    if step_request.is_absolute() {
        return step_request.is_file().then(|| step_request.to_path_buf());
    }
    [
        chain_dir.join(step_request),
        workspace.join(".mnml").join("requests").join(step_request),
        workspace.join(step_request),
    ]
    .into_iter()
    .find(|c| c.is_file())
}

/// Run the chain in `chain_file`, writing a step-by-step trace into `out`. `Ok`
/// when every step succeeded; `Err(msg)` (with the trace already in `out`) at the
/// first failure.
pub fn run(
    chain_file: &Path,
    workspace: &Path,
    env_name: Option<&str>,
    out: &mut String,
    // 2026-06-21 api-workflow SEV-2 cookie-inject-missing-from-chain:
    // optional jar. When present, each step's request gets a Cookie
    // header injected if the host has a cookie + the request didn't
    // already set one; Set-Cookie response headers are recorded.
    // Threaded through from App::http_chain_run_path. CLI callers
    // pass None — they don't have an App.
    cookie_jar: Option<std::sync::Arc<std::sync::Mutex<crate::cookie_jar::CookieJar>>>,
) -> Result<(), String> {
    let text = std::fs::read_to_string(chain_file)
        .map_err(|e| format!("read {}: {e}", chain_file.display()))?;
    let (steps, unknown_keys) = parse_verbose(&text)?;
    if steps.is_empty() {
        return Err("chain has no steps".into());
    }
    // api-workflow round-9 SEV-3 2026-07-11 — chain step keys that
    // the parser doesn't understand (`if`, `retry`, `parallel`, ...)
    // used to be silently accepted. Surface them at trace-line time.
    if !unknown_keys.is_empty() {
        out.push_str(&format!(
            "[chain] WARNING: ignored keys not yet implemented: {}\n",
            unknown_keys.join(", ")
        ));
    }
    let chain_dir = chain_file.parent().unwrap_or(Path::new("."));
    let mut env = EnvSet::select(workspace, env_name);

    for (i, step) in steps.iter().enumerate() {
        let path = resolve_request_path(&step.request, chain_dir, workspace)
            .ok_or_else(|| format!("step {}: cannot find {}", i + 1, step.request.display()))?;
        let raw =
            std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let script = script::parse(&raw);
        let mut req = super::parse(&raw).map_err(|e| format!("step {}: parse: {e}", i + 1))?;
        script::apply_pre(&script, &mut req, &mut env);
        let unresolved = {
            let mut m: Vec<String> = Vec::new();
            for s in std::iter::once(&req.url)
                .chain(req.headers.iter().map(|(_, v)| v))
                .chain(req.body.iter())
            {
                for v in template::unresolved(s, &env) {
                    if !m.contains(&v) {
                        m.push(v);
                    }
                }
            }
            m
        };
        if !unresolved.is_empty() {
            return Err(format!(
                "step {}: unresolved vars: {}",
                i + 1,
                unresolved.join(", ")
            ));
        }
        req.url = template::expand(&req.url, &env);
        for (_, v) in &mut req.headers {
            *v = template::expand(v, &env);
        }
        if let Some(b) = &mut req.body {
            *b = template::expand(b, &env);
        }

        let _ = writeln!(
            out,
            "──── step {}/{} — {} {}",
            i + 1,
            steps.len(),
            req.method,
            req.url
        );
        // Inject cookies for this URL before sending. Mirrors the
        // single-request `App::spawn_http_job` cookie logic.
        if let Some(jar_arc) = cookie_jar.as_ref()
            && let Some(host) = crate::cookie_jar::CookieJar::host_of(&req.url)
            && !req
                .headers
                .iter()
                .any(|(k, _)| k.eq_ignore_ascii_case("cookie"))
            && let Ok(j) = jar_arc.lock()
            && let Some(cookie) = j.cookie_header_for(&host)
        {
            req.headers.push(("Cookie".to_string(), cookie));
        }
        let resp = super::send(&req).map_err(|e| format!("step {}: {e}", i + 1))?;
        // Record any Set-Cookie headers from the response.
        if let Some(jar_arc) = cookie_jar.as_ref()
            && let Some(host) = crate::cookie_jar::CookieJar::host_of(&req.url)
            && let Ok(mut j) = jar_arc.lock()
        {
            for (k, v) in &resp.headers {
                if k.eq_ignore_ascii_case("set-cookie") {
                    j.record_set_cookie(&host, v);
                }
            }
        }
        let _ = writeln!(
            out,
            "  ← {} {}  ({} ms)",
            resp.status,
            resp.status_text,
            resp.elapsed.as_millis()
        );

        // Assertions for this step.
        let mut step_failed = 0;
        for r in script::run_assertions(&script, resp.status, &resp.headers, &resp.body) {
            if r.passed {
                let _ = writeln!(out, "  ✓ {}", r.label);
            } else {
                step_failed += 1;
                match &r.detail {
                    Some(d) => {
                        let _ = writeln!(out, "  ✗ {} — {d}", r.label);
                    }
                    None => {
                        let _ = writeln!(out, "  ✗ {}", r.label);
                    }
                }
            }
        }
        // Captures (into the running env).
        for (name, value) in script::apply_captures(&script, &resp.headers, &resp.body, &mut env) {
            let _ = writeln!(out, "  ⇒ {name} = {value}");
        }
        if step_failed > 0 {
            return Err(format!("step {}: {step_failed} assertion(s) failed", i + 1));
        }
        if !(200..400).contains(&resp.status) {
            return Err(format!(
                "step {}: stopping at non-success {}",
                i + 1,
                resp.status
            ));
        }

        // `extract` map → env vars for the next step.
        if !step.extract.is_empty() {
            let json: Option<Value> = serde_json::from_str(&resp.body).ok();
            for (var, jpath) in &step.extract {
                let value = json
                    .as_ref()
                    .and_then(|v| script::resolve_json_path(v, jpath))
                    .map(|v| match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    });
                match value {
                    Some(v) => {
                        let _ = writeln!(out, "  ⇒ {var} = {v}  (extract {jpath})");
                        env.vars.insert(var.clone(), v);
                    }
                    None => {
                        return Err(format!(
                            "step {}: extract '{var}' from {jpath} produced nothing",
                            i + 1
                        ));
                    }
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_steps_and_extractions() {
        let text = r#"[
            { "request": "auth/login.curl", "extract": { "TOKEN": "$.access_token" } },
            { "request": "merchant/get.curl" }
        ]"#;
        let steps = parse(text).unwrap();
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[0].request, PathBuf::from("auth/login.curl"));
        assert_eq!(
            steps[0].extract,
            vec![("TOKEN".to_string(), "$.access_token".to_string())]
        );
        assert!(steps[1].extract.is_empty());
    }

    #[test]
    fn rejects_non_array() {
        assert!(parse("{}").unwrap_err().contains("array"));
        assert!(parse("[{}]").unwrap_err().contains("request"));
    }

    #[test]
    fn resolves_request_relative_to_chain_dir() {
        let dir = tempfile::tempdir().unwrap();
        let chain_dir = dir.path().join("chains");
        std::fs::create_dir_all(&chain_dir).unwrap();
        let req = chain_dir.join("a.curl");
        std::fs::write(&req, "GET https://x/a\n").unwrap();
        assert_eq!(
            resolve_request_path(Path::new("a.curl"), &chain_dir, dir.path()),
            Some(req)
        );
        assert_eq!(
            resolve_request_path(Path::new("nope.curl"), &chain_dir, dir.path()),
            None
        );
    }
}
