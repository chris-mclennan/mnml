//! The baked-in HTTP request client.
//!
//! - [`Request`] — method / url / headers / body, the shared shape every source
//!   parses into (pasted curl via [`curl`], `.http`/`.rest`/`.curl` files via
//!   [`file`]).
//! - [`template`] — `{{VAR}}` substitution from `.mnml/env/<name>.env` (then
//!   process env), plus dynamic `{{$uuid}}` / `{{$timestamp}}` / … vars.
//! - [`script`] — `@set-header` / `@set-env` (pre-request) and `@assert` /
//!   `@capture` (post-response) directives carried in `#` comments.
//! - [`chain`] — `.chain.json` sequences: each step extracts response values into
//!   variables the later steps `{{…}}`.
//! - [`discover`] — read an OpenAPI / Swagger spec → one `.curl` stub per operation.
//! - [`send`] — fire a [`Request`] with `reqwest`'s blocking client, capture the
//!   [`Response`] (status, headers, body, elapsed).
//!
//! Still to come (its own pass): editable request-pane field tabs (right now you
//! edit the `.http` file in a normal editor).

pub mod ai_prompt;
pub mod bench;
pub mod captured;
pub mod chain;
pub mod curl;
pub mod discover;
pub mod faker;
pub mod file;
pub mod history;
pub mod lookup;
pub mod mock;
pub mod proxy;
pub mod schema;
pub mod script;
pub mod sources;
pub mod template;

use std::time::{Duration, Instant};

/// A request, independent of where it was parsed from. Header names keep their
/// source casing; order is preserved.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Request {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
    /// `-k` / `--insecure` — skip TLS certificate verification.
    /// api-workflow round 6 SEV-2 2026-07-11: was previously
    /// parsed and thrown away, so users with self-signed hosts
    /// got a generic transport error instead of the connection
    /// they explicitly asked for.
    pub insecure: bool,
}

/// Why parsing a request from text failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    NoUrl,
    UnterminatedQuote,
    Empty,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::NoUrl => write!(f, "no URL found in request"),
            ParseError::UnterminatedQuote => write!(f, "unterminated quote in curl command"),
            ParseError::Empty => write!(f, "empty input"),
        }
    }
}

impl std::error::Error for ParseError {}

/// Parse a request from text, auto-detecting between a pasted cURL command and
/// the `.http` / `.rest` (REST-Client) format. Tries cURL first — the dominant
/// case for pasted requests — unless the text unambiguously looks like an `.http`
/// file (a leading HTTP-method line), then falls back to the `.http` parser.
pub fn parse(input: &str) -> Result<Request, ParseError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(ParseError::Empty);
    }
    if looks_like_http_file(trimmed) {
        return file::parse(trimmed);
    }
    match curl::parse_curl(trimmed) {
        Ok(r) => Ok(r),
        Err(curl_err) => file::parse(trimmed).map_err(|_| curl_err),
    }
}

fn looks_like_http_file(text: &str) -> bool {
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') || t.starts_with("//") {
            continue;
        }
        let head = t.split_whitespace().next().unwrap_or("");
        return matches!(
            head.to_ascii_uppercase().as_str(),
            "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS"
        );
    }
    false
}

/// A captured HTTP response.
#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub status_text: String,
    pub headers: Vec<(String, String)>,
    /// Best-effort UTF-8 view of the body for the response viewer
    /// (invalid bytes replaced with U+FFFD). Displays HTML / JSON /
    /// text correctly.
    pub body: String,
    /// Raw response bytes — the authoritative source of truth. Use
    /// this when writing the response to disk (e.g. saving a PNG or
    /// PDF) so binary payloads aren't corrupted by `body`'s lossy
    /// UTF-8 replacement. api-workflow SEV-1 2026-07-11.
    pub body_bytes: Vec<u8>,
    pub elapsed: Duration,
    /// Best-effort per-phase timing. reqwest::blocking exposes two
    /// natural boundaries: `builder.send()` returning means DNS +
    /// connect + TLS + request-send + response-headers are all done;
    /// the body-read loop that follows measures the body-recv phase.
    /// Everything before `send()` returns is bundled as
    /// `wait` (waiting for the server to start responding); the
    /// body-read time is `receive`. Total is `elapsed`.
    pub timing: Timing,
}

/// Best-effort per-phase timings for a completed request. See
/// `Response::timing`.
#[derive(Debug, Clone, Copy, Default)]
pub struct Timing {
    /// From `send()` invocation to headers received.
    pub wait: Duration,
    /// From headers-received to body-read completion.
    pub receive: Duration,
}

impl Response {
    /// Case-insensitive header lookup (first match).
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    pub fn content_type(&self) -> Option<&str> {
        self.header("content-type")
    }
    pub fn looks_like_json(&self) -> bool {
        self.content_type()
            .map(|ct| ct.contains("json"))
            .unwrap_or(false)
            || {
                let b = self.body.trim_start();
                b.starts_with('{') || b.starts_with('[')
            }
    }
}

/// Send `req` synchronously and capture the response. `Err` carries a one-line
/// description of a transport / build failure (DNS, TLS, connect, timeout, …).
pub fn send(req: &Request) -> Result<Response, String> {
    let mut client_builder = reqwest::blocking::Client::builder().timeout(Duration::from_secs(30));
    if req.insecure {
        client_builder = client_builder.danger_accept_invalid_certs(true);
    }
    let client = client_builder
        .build()
        .map_err(|e| format!("client build failed: {e}"))?;

    let method = reqwest::Method::from_bytes(req.method.to_uppercase().as_bytes())
        .map_err(|_| format!("invalid HTTP method {:?}", req.method))?;

    let mut builder = client.request(method, &req.url);
    for (k, v) in &req.headers {
        builder = builder.header(k.as_str(), v.as_str());
    }
    if let Some(body) = &req.body {
        builder = builder.body(body.clone());
    }

    let start = Instant::now();
    let resp = builder.send().map_err(|e| transport_error(&e))?;
    let wait = start.elapsed();
    let recv_start = Instant::now();
    let status = resp.status().as_u16();
    let status_text = resp.status().canonical_reason().unwrap_or("").to_string();
    let headers = resp
        .headers()
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string()))
        .collect();
    // Cap response body to 16 MiB. Without this, `resp.text()`
    // slurps the full body — a 10 GiB malicious response could
    // OOM-kill the process. 16 MiB is comfortably larger than any
    // JSON / HTML / text response we'd want to inspect via the
    // HTTP pane; anything past gets truncated with a marker.
    // untouched-surfaces-hunt-2026-06-08 SEV-2 #11.
    const MAX_BODY: usize = 16 * 1024 * 1024;
    let (body, body_bytes) = {
        use std::io::Read;
        let mut buf = Vec::with_capacity(64 * 1024);
        let mut reader = resp.take(MAX_BODY as u64 + 1);
        reader
            .read_to_end(&mut buf)
            .map_err(|e| format!("reading body failed: {e}"))?;
        let truncated = buf.len() > MAX_BODY;
        if truncated {
            buf.truncate(MAX_BODY);
        }
        // `body` is the display-safe UTF-8 view; `body_bytes` is the
        // raw payload for round-trip-safe disk writes. api-workflow
        // SEV-1 2026-07-11 — `save_response` used to write `body`
        // to disk, corrupting binary payloads (PNG/PDF/zip) at the
        // moment the response landed.
        let mut display = String::from_utf8_lossy(&buf).into_owned();
        if truncated {
            display.push_str(
                "\n\n[mnml: response body truncated at 16 MiB — drop to curl for the full payload]",
            );
        }
        (display, buf)
    };
    let receive = recv_start.elapsed();
    let elapsed = start.elapsed();

    Ok(Response {
        status,
        status_text,
        headers,
        body,
        body_bytes,
        elapsed,
        timing: Timing { wait, receive },
    })
}

fn transport_error(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        "request timed out".to_string()
    } else if e.is_connect() {
        format!("connection failed: {e}")
    } else if e.is_builder() {
        format!("bad request: {e}")
    } else {
        e.to_string()
    }
}

/// Deduplicate header pairs by case-insensitive name, keeping the last value but
/// the first-seen position. (cURL's last `-H` for a name wins.)
pub(crate) fn dedupe_keep_last(headers: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut order: Vec<String> = Vec::new();
    let mut last: std::collections::HashMap<String, (String, String)> =
        std::collections::HashMap::new();
    for (k, v) in headers {
        let key = k.to_ascii_lowercase();
        if !last.contains_key(&key) {
            order.push(key.clone());
        }
        last.insert(key, (k, v));
    }
    order.into_iter().filter_map(|k| last.remove(&k)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_dispatches_to_curl_and_http_file() {
        let c = parse("curl 'https://x.com/a' -H 'accept: */*'").unwrap();
        assert_eq!(c.url, "https://x.com/a");
        assert_eq!(c.method, "GET");

        let h = parse("POST https://x.com/b\nContent-Type: application/json\n\n{\"a\":1}").unwrap();
        assert_eq!(h.method, "POST");
        assert_eq!(h.url, "https://x.com/b");
        assert_eq!(h.body.as_deref(), Some("{\"a\":1}"));

        assert_eq!(parse("   "), Err(ParseError::Empty));
        // `curl <word>` treats the word as a URL, so a bare token parses (and
        // would then fail to send with a clear transport error) — matching cURL.
        assert_eq!(parse("nonsense").unwrap().url, "nonsense");
    }

    #[test]
    fn dedupe_keeps_last_value_at_first_position() {
        let got = dedupe_keep_last(vec![
            ("Accept".into(), "a".into()),
            ("X".into(), "1".into()),
            ("accept".into(), "b".into()),
        ]);
        assert_eq!(
            got,
            vec![("accept".into(), "b".into()), ("X".into(), "1".into())]
        );
    }
}
