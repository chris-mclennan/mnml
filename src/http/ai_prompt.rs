//! Structured "debug this failure" prompt builder for the Request pane.
//! Given a failed request/response pair, produces a markdown prompt
//! ready to paste into Claude / Codex / etc. The prompt keeps the
//! signal (method, URL, status, error body, env context, schema
//! validation) and redacts obvious credentials in headers + body so
//! users don't leak secrets to their AI provider by accident.
//!
//! 2026-07-09 — user request. Palette entry `http.copy_ai_prompt`
//! and the `⚡ AI` chip in the Response block header both route
//! here.

use crate::request_pane::{RequestPane, RunState};

/// Build the markdown prompt for the given Request pane.
/// Returns `None` when the response isn't in a failure state
/// (nothing useful to ask an AI about).
pub fn build_prompt(rp: &RequestPane, active_env_name: Option<&str>) -> Option<String> {
    let (status_line, response_headers, response_body, elapsed_ms, schema_errors) = match &rp.state
    {
        RunState::Done(r) if !(200..300).contains(&r.status) => (
            Some(format!("HTTP {} {}", r.status, r.status_text)),
            r.headers.clone(),
            r.body.clone(),
            Some(r.elapsed.as_millis()),
            schema_errors_of(r.schema_result.as_ref()),
        ),
        RunState::Done(r)
            if r.schema_result.as_ref().is_some_and(|s| {
                matches!(s.status, crate::http::schema::SchemaStatus::Invalid)
            }) =>
        {
            (
                Some(format!("HTTP {} {}", r.status, r.status_text)),
                r.headers.clone(),
                r.body.clone(),
                Some(r.elapsed.as_millis()),
                schema_errors_of(r.schema_result.as_ref()),
            )
        }
        RunState::Failed(msg) => (
            Some(format!("(transport error) {msg}")),
            Vec::new(),
            String::new(),
            None,
            Vec::new(),
        ),
        _ => return None,
    };

    let mut out = String::new();
    out.push_str("I'm hitting an error on this HTTP request. Help me figure out why.\n\n");
    out.push_str("## Request\n");
    out.push_str(&format!("{} {}\n", rp.request.method, rp.request.url));
    for (k, v) in &rp.request.headers {
        out.push_str(&format!("{k}: {}\n", redact_header_value(k, v)));
    }
    if let Some(body) = &rp.request.body
        && !body.is_empty()
    {
        out.push('\n');
        out.push_str(&truncate_with_marker(body, 2048));
        if !body.ends_with('\n') {
            out.push('\n');
        }
    }
    out.push('\n');

    out.push_str("## Response\n");
    if let Some(sl) = status_line {
        if let Some(ms) = elapsed_ms {
            out.push_str(&format!("{sl}  (elapsed: {ms}ms)\n"));
        } else {
            out.push_str(&format!("{sl}\n"));
        }
    }
    for (k, v) in &response_headers {
        out.push_str(&format!("{k}: {v}\n"));
    }
    if !response_body.is_empty() {
        out.push('\n');
        out.push_str(&truncate_with_marker(&response_body, 2048));
        if !response_body.ends_with('\n') {
            out.push('\n');
        }
    }
    out.push('\n');

    let (defined, undefined) = classify_vars(
        &rp.request.url,
        &rp.headers_buffer,
        rp.request.body.as_deref(),
    );
    if let Some(env) = active_env_name {
        out.push_str("## Env / context\n");
        out.push_str(&format!("- active env: {env}\n"));
        if !defined.is_empty() {
            out.push_str(&format!("- defined vars used: {}\n", defined.join(", ")));
        }
        if !undefined.is_empty() {
            out.push_str(&format!("- undefined vars: {}\n", undefined.join(", ")));
        }
        out.push('\n');
    } else if !defined.is_empty() || !undefined.is_empty() {
        out.push_str("## Env / context\n");
        if !defined.is_empty() {
            out.push_str(&format!("- vars in template: {}\n", defined.join(", ")));
        }
        if !undefined.is_empty() {
            out.push_str(&format!("- undefined vars: {}\n", undefined.join(", ")));
        }
        out.push('\n');
    }

    if !schema_errors.is_empty() {
        out.push_str("## Schema validation\n");
        for err in &schema_errors {
            out.push_str(&format!("- {err}\n"));
        }
        out.push('\n');
    }

    out.push_str("## What I've tried\n(fill me in)\n");
    Some(out)
}

fn schema_errors_of(res: Option<&crate::http::schema::SchemaResult>) -> Vec<String> {
    let Some(res) = res else { return Vec::new() };
    if !matches!(res.status, crate::http::schema::SchemaStatus::Invalid) {
        return Vec::new();
    }
    res.errors.clone()
}

/// Redact obvious sensitive-value headers so pasting the prompt into
/// an AI service doesn't leak credentials. Match is case-insensitive
/// on the header NAME. Values become `<redacted>` — the header key
/// stays so the AI can see that auth WAS present.
pub fn redact_header_value(name: &str, value: &str) -> String {
    let lc = name.to_ascii_lowercase();
    let is_secret = lc == "authorization"
        || lc == "cookie"
        || lc == "proxy-authorization"
        || lc.contains("api-key")
        || lc.contains("api_key")
        || lc.contains("apikey")
        || lc.contains("token")
        || (lc.starts_with("x-") && lc.contains("secret"));
    if is_secret {
        // Keep the auth scheme prefix ("Bearer", "Basic") so the AI
        // can distinguish shapes; strip the token body.
        if let Some((scheme, _)) = value.split_once(' ') {
            return format!("{scheme} <redacted>");
        }
        return "<redacted>".to_string();
    }
    value.to_string()
}

fn truncate_with_marker(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        return s.to_string();
    }
    // Truncate at a UTF-8 char boundary so the marker isn't tacked
    // onto a partial code point.
    let mut end = max_bytes;
    while !s.is_char_boundary(end) && end > 0 {
        end -= 1;
    }
    format!("{}\n…truncated ({} bytes total)", &s[..end], s.len())
}

fn classify_vars(url: &str, headers: &str, body: Option<&str>) -> (Vec<String>, Vec<String>) {
    let mut all = std::collections::BTreeSet::new();
    scan_vars(url, &mut all);
    scan_vars(headers, &mut all);
    if let Some(b) = body {
        scan_vars(b, &mut all);
    }
    let (defined, undefined): (Vec<_>, Vec<_>) =
        all.into_iter().partition(|v| std::env::var(v).is_ok());
    (defined, undefined)
}

fn scan_vars(text: &str, out: &mut std::collections::BTreeSet<String>) {
    let mut i = 0;
    let bytes = text.as_bytes();
    while i + 1 < bytes.len() {
        if bytes[i] == b'{' && bytes[i + 1] == b'{' {
            let start = i + 2;
            let mut end = start;
            while end + 1 < bytes.len() && !(bytes[end] == b'}' && bytes[end + 1] == b'}') {
                end += 1;
            }
            if end + 1 < bytes.len() && end > start {
                let name = &text[start..end];
                // Skip built-in dynamics like `{{$uuid}}` /
                // `{{$isoTimestamp}}` — they aren't env-defined.
                if !name.starts_with('$') {
                    out.insert(name.trim().to_string());
                }
                i = end + 2;
                continue;
            }
        }
        i += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::Request;
    use crate::request_pane::{RequestPane, ResponseView, RunState};
    use std::time::Duration;

    fn pane_with_failure(status: u16, body: &str) -> RequestPane {
        let req = Request {
            method: "POST".to_string(),
            url: "https://api.example.com/orders".to_string(),
            headers: vec![
                ("accept".to_string(), "application/json".to_string()),
                (
                    "Authorization".to_string(),
                    "Bearer secret-token-12345".to_string(),
                ),
                ("X-Merchant-Id".to_string(), "42".to_string()),
            ],
            body: Some(r#"{"amount":10.0,"merchantId":"{{MERCHANT_ID}}"}"#.to_string()),
        };
        let mut rp = RequestPane::new(None, req, crate::http::script::Script::default(), 0);
        rp.state = RunState::Done(Box::new(ResponseView {
            status,
            status_text: "Bad Request".to_string(),
            headers: vec![("content-type".to_string(), "application/json".to_string())],
            body: body.to_string(),
            elapsed: Duration::from_millis(123),
            timing: crate::http::Timing::default(),
            assertions: Vec::new(),
            captures: Vec::new(),
            schema_result: None,
            sse_event_count: 0,
        }));
        rp
    }

    #[test]
    fn build_prompt_returns_none_when_response_is_2xx() {
        let rp = pane_with_failure(200, "{}");
        assert!(build_prompt(&rp, Some("dev")).is_none());
    }

    #[test]
    fn build_prompt_includes_method_url_and_status_line() {
        let rp = pane_with_failure(400, r#"{"error":"missing merchantId"}"#);
        let prompt = build_prompt(&rp, Some("dev")).unwrap();
        assert!(prompt.contains("POST https://api.example.com/orders"));
        assert!(prompt.contains("HTTP 400 Bad Request"));
        assert!(prompt.contains("(elapsed: 123ms)"));
        assert!(prompt.contains(r#""error":"missing merchantId""#));
    }

    #[test]
    fn build_prompt_redacts_authorization_header() {
        let rp = pane_with_failure(401, "");
        let prompt = build_prompt(&rp, Some("dev")).unwrap();
        assert!(prompt.contains("Bearer <redacted>"));
        assert!(!prompt.contains("secret-token-12345"));
        // Non-secret headers pass through.
        assert!(prompt.contains("X-Merchant-Id: 42"));
    }

    #[test]
    fn build_prompt_lists_defined_and_undefined_vars() {
        // The MERCHANT_ID var isn't set in the environment during
        // tests → classified as undefined.
        let rp = pane_with_failure(400, "");
        let prompt = build_prompt(&rp, Some("dev")).unwrap();
        assert!(prompt.contains("undefined vars: MERCHANT_ID"));
        assert!(prompt.contains("active env: dev"));
    }

    #[test]
    fn build_prompt_omits_env_section_when_no_env_and_no_vars() {
        let mut rp = pane_with_failure(500, "boom");
        rp.request.body = None;
        rp.request.url = "https://api.example.com/health".to_string();
        rp.request.headers = Vec::new();
        let prompt = build_prompt(&rp, None).unwrap();
        assert!(!prompt.contains("## Env"));
    }

    #[test]
    fn truncate_with_marker_appends_when_over_limit() {
        let long = "x".repeat(2100);
        let out = truncate_with_marker(&long, 2048);
        assert!(out.starts_with(&"x".repeat(2048)));
        assert!(out.contains("…truncated (2100 bytes total)"));
    }

    #[test]
    fn truncate_with_marker_passthrough_when_within_limit() {
        let s = "short";
        assert_eq!(truncate_with_marker(s, 2048), "short");
    }

    #[test]
    fn redact_header_covers_api_key_variants() {
        assert_eq!(redact_header_value("X-API-Key", "abc"), "<redacted>");
        assert_eq!(redact_header_value("x-api_key", "abc"), "<redacted>");
        assert_eq!(redact_header_value("x-apikey", "abc"), "<redacted>");
        assert_eq!(
            redact_header_value("Authorization", "Basic abc"),
            "Basic <redacted>"
        );
        assert_eq!(redact_header_value("Cookie", "session=abc"), "<redacted>");
        // Non-secret headers untouched.
        assert_eq!(redact_header_value("Accept", "*/*"), "*/*");
    }
}
