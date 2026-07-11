//! Parse a pasted `curl …` command into a [`Request`]. Handles the flags Chrome
//! / Firefox / Playwright "Copy as cURL" emit (`-X`, `-H`, `-d`/`--data*`, `-b`,
//! `-A`, `-e`, plus the no-op `--compressed`/`-L`/`-k`/`-s`), bash-style quoting
//! and `\`-newline continuations, and strips any response body a tool appended
//! after the command.

use super::{ParseError, Request, dedupe_keep_last};

/// Parse a cURL command. The leading `curl` token is optional.
pub fn parse_curl(input: &str) -> Result<Request, ParseError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(ParseError::Empty);
    }
    let isolated = isolate_curl(trimmed);
    let joined = strip_line_continuations(&isolated);
    let tokens = tokenize(&joined)?;
    if tokens.is_empty() {
        return Err(ParseError::Empty);
    }
    let start = usize::from(tokens[0].eq_ignore_ascii_case("curl"));

    let mut method: Option<String> = None;
    let mut url: Option<String> = None;
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut body: Option<String> = None;
    let mut cookies: Vec<String> = Vec::new();
    let mut insecure = false;
    let mut multipart_parts: Vec<MultipartPart> = Vec::new();

    let mut i = start;
    while i < tokens.len() {
        let t = tokens[i].as_str();
        // 1 unless a flag consumes the following token as its value.
        let mut advance = 1usize;
        match t {
            "-X" | "--request" => {
                if let Some(v) = tokens.get(i + 1) {
                    method = Some(v.to_uppercase());
                    advance = 2;
                }
            }
            "-H" | "--header" => {
                if let Some(v) = tokens.get(i + 1) {
                    if let Some(kv) = split_header(v) {
                        headers.push(kv);
                    }
                    advance = 2;
                }
            }
            "-d" | "--data" | "--data-raw" | "--data-binary" | "--data-ascii"
            | "--data-urlencode" => {
                if let Some(v) = tokens.get(i + 1) {
                    body = Some(v.clone());
                    advance = 2;
                }
            }
            "-b" | "--cookie" => {
                if let Some(v) = tokens.get(i + 1) {
                    cookies.push(v.clone());
                    advance = 2;
                }
            }
            "-A" | "--user-agent" => {
                if let Some(v) = tokens.get(i + 1) {
                    headers.push(("user-agent".to_string(), v.clone()));
                    advance = 2;
                }
            }
            "-e" | "--referer" => {
                if let Some(v) = tokens.get(i + 1) {
                    headers.push(("referer".to_string(), v.clone()));
                    advance = 2;
                }
            }
            // api-workflow round 6 SEV-2 2026-07-11 — `-u user:pass`
            // used to fall through the unknown-flag branch and the
            // next token `user:pass` was mis-parsed as the URL,
            // silently discarding the real URL. Convert to a
            // base64 Basic Authorization header.
            "-u" | "--user" => {
                if let Some(v) = tokens.get(i + 1) {
                    use base64::{Engine, engine::general_purpose::STANDARD};
                    let encoded = STANDARD.encode(v.as_bytes());
                    headers.push(("authorization".to_string(), format!("Basic {encoded}")));
                    advance = 2;
                }
            }
            // `-F field=value` / `-F field=@file` / `-F field=<file`
            // → collect into `multipart_parts` and encode as
            // `multipart/form-data` with a boundary at the end. This
            // is the CORRECT vim: previously we accumulated the raw
            // `key=value&key=@path` string into a
            // `application/x-www-form-urlencoded` body, so file
            // uploads posted the literal `@path` string, which is
            // silent corruption for anyone using `-F name=@…`.
            // `--form-string` never loads files (the vim's
            // documented promise); collect it as a plain-text part.
            //
            // Path resolution: `@` / `<` prefixed paths are read
            // relative to CWD at parse time. `.curl` files opened
            // from a Request pane don't reach here with a source-dir
            // hint; that's a follow-up. For the CLI (`mnml run FILE`)
            // CWD is typically the workspace, which is the right
            // base for relative uploads.
            // api-workflow round-7 SEV-1 partial fix 2026-07-11.
            "-F" | "--form" | "--form-string" => {
                if let Some(v) = tokens.get(i + 1) {
                    let allow_file = t != "--form-string";
                    if let Some((name, spec)) = v.split_once('=') {
                        multipart_parts.push(parse_multipart_spec(name, spec, allow_file));
                    }
                    advance = 2;
                }
            }
            "--url" => {
                if let Some(v) = tokens.get(i + 1) {
                    if url.is_none() {
                        url = Some(v.clone());
                    }
                    advance = 2;
                }
            }
            // `-k` / `--insecure` — skip TLS certificate verification.
            // api-workflow round 6 SEV-2 2026-07-11: was previously
            // a documented no-op; now sets a flag that http::send()
            // wires into reqwest's `danger_accept_invalid_certs`.
            "-k" | "--insecure" => {
                insecure = true;
            }
            // Flags we accept and ignore.
            "--compressed" | "--location" | "-L" | "--silent" | "-s" | "--fail" | "-f" | "-i"
            | "--include" | "-#" | "--progress-bar" | "-v" | "--verbose" => {}
            _ => {
                // An unknown `-flag` is skipped without eating the next token (we
                // can't know if it takes an argument; over-eating loses the URL
                // more often than under-eating mis-parses). A bare word is the URL.
                if !(t.starts_with('-') && t.len() > 1) && url.is_none() {
                    url = Some(tokens[i].clone());
                }
            }
        }
        i += advance;
    }

    let url = url.ok_or(ParseError::NoUrl)?;

    if !cookies.is_empty()
        && !headers
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("cookie"))
    {
        headers.push(("cookie".to_string(), cookies.join("; ")));
    }

    // Multipart body assembly — takes precedence over `-d` (curl
    // canonical: `-F` implies `POST` multipart). Non-empty
    // `multipart_parts` overrides `body`.
    if !multipart_parts.is_empty() {
        let boundary = format!(
            "----mnmlBoundary{}",
            multipart_parts.len() * 7919 + url.len()
        );
        body = Some(encode_multipart(&boundary, &multipart_parts));
        // Overwrite / add the Content-Type header.
        headers.retain(|(k, _)| !k.eq_ignore_ascii_case("content-type"));
        headers.push((
            "content-type".to_string(),
            format!("multipart/form-data; boundary={boundary}"),
        ));
    }

    let method = method.unwrap_or_else(|| {
        if body.is_some() {
            "POST".to_string()
        } else {
            "GET".to_string()
        }
    });

    Ok(Request {
        method,
        url,
        headers: dedupe_keep_last(headers),
        body,
        insecure,
    })
}

/// One part of a `multipart/form-data` body assembled from `-F` flags.
#[derive(Debug, Clone)]
struct MultipartPart {
    name: String,
    /// The value to send. `filename` is set when the source spec used
    /// `@path` (file-attachment form) — curl sends
    /// `filename="basename"` on that Content-Disposition.
    value: String,
    filename: Option<String>,
    /// Optional `;type=…` override from the spec. Defaults are chosen
    /// based on whether the part is a file (application/octet-stream)
    /// or a text field (no explicit content-type).
    content_type: Option<String>,
    /// True when we attempted a file load but failed (missing file,
    /// or non-UTF-8 for now). Kept in the parts list so `encode_multipart`
    /// can surface a clear inline error placeholder rather than silently
    /// dropping the field.
    load_error: Option<String>,
}

/// Parse a `-F name=spec` payload. Handles:
/// - `spec = "value"` → plain text part
/// - `spec = "@path"` → file attachment (Content-Disposition filename=basename)
/// - `spec = "<path"` → file contents as the value (no filename)
/// - `spec = "…;type=X"` suffix → sets Content-Type on the part
///
/// When `allow_file` is false (i.e. `--form-string`) the `@`/`<` prefix
/// is treated as literal text.
fn parse_multipart_spec(name: &str, spec: &str, allow_file: bool) -> MultipartPart {
    // Peel off an optional `;type=…` trailer.
    let (body_spec, content_type) = if let Some((left, right)) = spec.split_once(';') {
        let ct = right
            .trim()
            .strip_prefix("type=")
            .map(|s| s.trim().to_string());
        (left, ct)
    } else {
        (spec, None)
    };
    let name = name.to_string();
    if !allow_file {
        return MultipartPart {
            name,
            value: body_spec.to_string(),
            filename: None,
            content_type,
            load_error: None,
        };
    }
    if let Some(path) = body_spec.strip_prefix('@') {
        return load_multipart_file_part(&name, path, true, content_type);
    }
    if let Some(path) = body_spec.strip_prefix('<') {
        return load_multipart_file_part(&name, path, false, content_type);
    }
    MultipartPart {
        name,
        value: body_spec.to_string(),
        filename: None,
        content_type,
        load_error: None,
    }
}

/// Read `path` (relative to CWD, or absolute), returning a
/// `MultipartPart`. Files whose contents aren't valid UTF-8 are
/// tagged with a `load_error` so `encode_multipart` can surface a
/// clear message instead of silent corruption. When `attach_filename`
/// is true, the Content-Disposition gets `filename="basename"` (curl's
/// `@` form); false = `<` form (contents-as-value, no filename).
fn load_multipart_file_part(
    name: &str,
    path: &str,
    attach_filename: bool,
    content_type: Option<String>,
) -> MultipartPart {
    let name = name.to_string();
    let basename = std::path::Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(path)
        .to_string();
    let ct = content_type.or_else(|| {
        if attach_filename {
            Some("application/octet-stream".to_string())
        } else {
            None
        }
    });
    match std::fs::read(path) {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(text) => MultipartPart {
                name,
                value: text,
                filename: attach_filename.then_some(basename),
                content_type: ct,
                load_error: None,
            },
            Err(_) => MultipartPart {
                name,
                value: String::new(),
                filename: attach_filename.then_some(basename),
                content_type: ct,
                load_error: Some(format!("binary file {path} — mnml multipart is text-only")),
            },
        },
        Err(e) => MultipartPart {
            name,
            value: String::new(),
            filename: attach_filename.then_some(basename),
            content_type: ct,
            load_error: Some(format!("can't read {path}: {e}")),
        },
    }
}

/// Assemble the RFC-2046 multipart body. Text-only; binary files land
/// as an inline `[LOAD-ERROR: …]` placeholder so the failure is
/// visible in the request rather than silently absent.
fn encode_multipart(boundary: &str, parts: &[MultipartPart]) -> String {
    let mut out = String::new();
    for part in parts {
        out.push_str("--");
        out.push_str(boundary);
        out.push_str("\r\n");
        out.push_str("Content-Disposition: form-data; name=\"");
        out.push_str(&part.name);
        out.push('"');
        if let Some(fname) = &part.filename {
            out.push_str("; filename=\"");
            out.push_str(fname);
            out.push('"');
        }
        out.push_str("\r\n");
        if let Some(ct) = &part.content_type {
            out.push_str("Content-Type: ");
            out.push_str(ct);
            out.push_str("\r\n");
        }
        out.push_str("\r\n");
        if let Some(err) = &part.load_error {
            out.push_str("[LOAD-ERROR: ");
            out.push_str(err);
            out.push(']');
        } else {
            out.push_str(&part.value);
        }
        out.push_str("\r\n");
    }
    out.push_str("--");
    out.push_str(boundary);
    out.push_str("--\r\n");
    out
}

/// Strip anything that isn't part of the curl command — tools (Playwright, …)
/// append the response body after the invocation, which a quote-aware tokenizer
/// chokes on. Take consecutive lines while each is "continued" (trailing `\` or
/// still inside an open quote); stop at the first clean line.
fn isolate_curl(s: &str) -> String {
    let lines: Vec<&str> = s.lines().collect();
    let start = lines
        .iter()
        .position(|l| l.trim_start().starts_with("curl"))
        .unwrap_or(0);
    let mut out: Vec<&str> = Vec::new();
    let mut open_quote: Option<char> = None;
    for line in &lines[start..] {
        let trimmed_end = line.trim_end();
        let backslash_continues = trimmed_end.ends_with('\\');
        let visible = if backslash_continues {
            &trimmed_end[..trimmed_end.len() - 1]
        } else {
            trimmed_end
        };
        let was_in_quote = open_quote.is_some();
        open_quote = scan_quote_state(visible, open_quote);
        out.push(line);
        if !backslash_continues
            && open_quote.is_none()
            && (was_in_quote || !visible.trim().is_empty())
        {
            break;
        }
    }
    out.join("\n")
}

/// Track single/double-quote state across a line; returns the still-open quote
/// (None if balanced). Backslash escapes the next char inside double quotes only.
fn scan_quote_state(line: &str, mut open: Option<char>) -> Option<char> {
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match (open, c) {
            (None, '\'') => open = Some('\''),
            (None, '"') => open = Some('"'),
            (Some('\''), '\'') => open = None,
            (Some('"'), '\\') => {
                chars.next();
            }
            (Some('"'), '"') => open = None,
            _ => {}
        }
    }
    open
}

fn strip_line_continuations(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\'
            && i + 1 < bytes.len()
            && (bytes[i + 1] == b'\n' || bytes[i + 1] == b'\r')
        {
            out.push(' ');
            i += 2;
            if i < bytes.len() && bytes[i] == b'\n' {
                i += 1;
            }
            continue;
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

fn tokenize(s: &str) -> Result<Vec<String>, ParseError> {
    let mut tokens: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut in_token = false;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' | '\n' | '\r' => {
                if in_token {
                    tokens.push(std::mem::take(&mut cur));
                    in_token = false;
                }
            }
            '\'' => {
                in_token = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(ch) => cur.push(ch),
                        None => return Err(ParseError::UnterminatedQuote),
                    }
                }
            }
            '"' => {
                in_token = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => {
                            if let Some(&next) = chars.peek() {
                                match next {
                                    '"' | '\\' | '$' | '`' | '\n' => {
                                        cur.push(chars.next().unwrap());
                                    }
                                    _ => cur.push('\\'),
                                }
                            }
                        }
                        Some(ch) => cur.push(ch),
                        None => return Err(ParseError::UnterminatedQuote),
                    }
                }
            }
            '\\' => {
                in_token = true;
                if let Some(next) = chars.next() {
                    cur.push(next);
                }
            }
            _ => {
                in_token = true;
                cur.push(c);
            }
        }
    }
    if in_token {
        tokens.push(cur);
    }
    Ok(tokens)
}

fn split_header(s: &str) -> Option<(String, String)> {
    let idx = s.find(':')?;
    let (k, v) = s.split_at(idx);
    let k = k.trim().to_string();
    if k.is_empty() {
        return None;
    }
    Some((k, v[1..].trim().to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// api-workflow round 6 SEV-2 2026-07-11 — `-u user:pass` used
    /// to fall through the unknown-flag arm and the token after got
    /// mis-claimed as the URL, silently discarding the real URL.
    #[test]
    fn dash_u_creates_basic_auth_header_and_preserves_url() {
        let r = parse_curl("curl -u alice:s3cr3t 'https://x/a'").unwrap();
        assert_eq!(r.url, "https://x/a");
        let auth = r
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
            .map(|(_, v)| v.as_str());
        assert_eq!(auth, Some("Basic YWxpY2U6czNjcjN0"));
    }

    #[test]
    fn dash_capital_f_form_produces_multipart_body() {
        // api-workflow round-7 SEV-1 2026-07-11 — `-F` now builds
        // proper `multipart/form-data` (was: naive `a=1&b=2` under
        // `application/x-www-form-urlencoded`, which silently
        // corrupted `@file` uploads).
        let r = parse_curl("curl -F 'a=1' -F 'b=2' 'https://x/form'").unwrap();
        assert_eq!(r.url, "https://x/form");
        let ct = r
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            .map(|(_, v)| v.as_str())
            .unwrap();
        assert!(
            ct.starts_with("multipart/form-data; boundary="),
            "got: {ct}"
        );
        let body = r.body.expect("multipart body must be present");
        assert!(body.contains("name=\"a\""), "part a missing: {body}");
        assert!(body.contains("name=\"b\""), "part b missing: {body}");
        assert!(body.contains("\r\n\r\n1\r\n"), "value 1 missing");
        assert!(body.contains("\r\n\r\n2\r\n"), "value 2 missing");
    }

    #[test]
    fn dash_capital_f_at_file_reads_content() {
        // `-F name=@path` reads the file bytes (UTF-8) and includes
        // them as an attachment with filename set.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hello.txt");
        std::fs::write(&path, "hello world").unwrap();
        let cmd = format!("curl -F 'file=@{}' 'https://x/upload'", path.display());
        let r = parse_curl(&cmd).unwrap();
        let body = r.body.unwrap();
        assert!(body.contains("name=\"file\""), "field name missing");
        assert!(
            body.contains("filename=\"hello.txt\""),
            "filename missing: {body}"
        );
        assert!(body.contains("hello world"), "file contents missing");
        assert!(
            body.contains("Content-Type: application/octet-stream"),
            "default content-type missing"
        );
    }

    #[test]
    fn dash_capital_f_lt_file_with_type_override() {
        // `-F name=<path;type=X` reads file contents (no filename)
        // and sets the part Content-Type from the trailer.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("meta.json");
        std::fs::write(&path, r#"{"a":1}"#).unwrap();
        let cmd = format!(
            "curl -F 'json=<{};type=application/json' 'https://x/upload'",
            path.display()
        );
        let r = parse_curl(&cmd).unwrap();
        let body = r.body.unwrap();
        assert!(body.contains("name=\"json\""));
        assert!(!body.contains("filename=\""), "should not attach filename");
        assert!(body.contains("Content-Type: application/json"));
        assert!(body.contains(r#"{"a":1}"#));
    }

    #[test]
    fn chrome_get_with_headers() {
        let input = "curl 'https://api.example.com/foo?bar=1' \\\n  -H 'accept: application/json' \\\n  -H 'user-agent: Mozilla/5.0' \\\n  --compressed";
        let r = parse_curl(input).unwrap();
        assert_eq!(r.method, "GET");
        assert_eq!(r.url, "https://api.example.com/foo?bar=1");
        assert_eq!(r.headers.len(), 2);
        assert_eq!(r.body, None);
    }

    #[test]
    fn chrome_post_data_raw() {
        let input = "curl 'https://api.example.com/foo' \\\n  -H 'content-type: application/json' \\\n  --data-raw '{\"a\":1}' \\\n  --compressed";
        let r = parse_curl(input).unwrap();
        assert_eq!(r.method, "POST");
        assert_eq!(r.body.as_deref(), Some("{\"a\":1}"));
    }

    #[test]
    fn explicit_method_and_url_flag() {
        assert_eq!(
            parse_curl("curl -X DELETE 'https://x/a'").unwrap().method,
            "DELETE"
        );
        assert_eq!(
            parse_curl("curl --url https://x/b").unwrap().url,
            "https://x/b"
        );
    }

    #[test]
    fn embedded_single_quote_via_concat() {
        let r = parse_curl("curl 'https://x.com/path' -H 'cookie: a='\\''b'\\''c'").unwrap();
        assert_eq!(r.headers[0].1, "a='b'c");
    }

    #[test]
    fn strips_response_appended_after_curl() {
        let input = "curl 'https://api.example.com/foo' \\\n  -H 'accept: application/json' \\\n  --data-raw '{\"a\":1}'\n\nHTTP/1.1 200 OK\ncontent-type: application/json\n\n{\"result\":\"o'clock\"}";
        let r = parse_curl(input).unwrap();
        assert_eq!(r.url, "https://api.example.com/foo");
        assert_eq!(r.body.as_deref(), Some("{\"a\":1}"));
    }

    #[test]
    fn cookie_flag_becomes_header() {
        let r = parse_curl("curl 'https://x.com/' -b 'session=abc'").unwrap();
        assert!(
            r.headers
                .iter()
                .any(|(k, v)| k.eq_ignore_ascii_case("cookie") && v == "session=abc")
        );
    }

    #[test]
    fn no_url_errors() {
        assert_eq!(parse_curl("curl -X POST"), Err(ParseError::NoUrl));
        assert_eq!(parse_curl(""), Err(ParseError::Empty));
    }
}
