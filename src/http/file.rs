//! Parser for the `.http` / `.rest` request-file format (humao.rest-client,
//! JetBrains' HTTP Client, VS Code's REST client) — and `.curl` files, which the
//! auto-detector in [`super::parse`] routes to the cURL parser instead.
//!
//! Grammar (the supported subset):
//!
//! ```text
//! file        := request ("###" "\n" request)*
//! request     := comment* request-line "\n" headers ("\n" body)?
//! comment     := ("#" | "//") .*
//! request-line:= [METHOD " "] url (" HTTP/" version)?
//! headers     := (Name ":" Value "\n")*
//! body        := raw bytes until EOF or the next `###`
//! ```
//!
//! Out of scope (not parsed): response-handler scripts (`> {% … %}`), pre-request
//! scripts, `< file` body references. Ported from `../rqst/src/http_file.rs`.

use super::{ParseError, Request};

/// Parse the first non-empty request block in a `.http` / `.rest` file.
pub fn parse(input: &str) -> Result<Request, ParseError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(ParseError::Empty);
    }
    parse_block(first_request_block(trimmed))
}

/// One parsed request from a multi-request `.http` file, with the 0-based
/// inclusive line range it occupies in the original source (the `###` separator
/// line, if any, is the start) — used to map an editor cursor to the "active"
/// request.
#[derive(Debug, Clone)]
pub struct Block {
    pub name: Option<String>,
    pub start_line: usize,
    pub end_line: usize,
    pub request: Request,
}

/// Parse every request block in a `.http` / `.rest` file. Empty blocks
/// (whitespace + comments only) are skipped.
pub fn parse_all(input: &str) -> Result<Vec<Block>, ParseError> {
    if input.trim().is_empty() {
        return Err(ParseError::Empty);
    }
    let lines: Vec<&str> = input.split('\n').collect();
    let separators: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.trim_start().starts_with("###"))
        .map(|(i, _)| i)
        .collect();

    let mut ranges: Vec<(usize, usize, Option<String>)> = Vec::new();
    if separators.is_empty() {
        ranges.push((0, lines.len().saturating_sub(1), None));
    } else {
        if separators[0] > 0 {
            ranges.push((0, separators[0] - 1, None));
        }
        for (idx, &sep) in separators.iter().enumerate() {
            let end = separators
                .get(idx + 1)
                .map(|next| next - 1)
                .unwrap_or(lines.len().saturating_sub(1));
            ranges.push((sep, end, parse_separator_name(lines[sep])));
        }
    }

    let last = lines.len().saturating_sub(1);
    let mut out: Vec<Block> = Vec::new();
    for (start, end, name) in ranges {
        let end = end.min(last);
        let block_text: String = lines[start..=end].join("\n");
        let body = block_text.trim_start_matches(|c: char| c == '#' || c.is_whitespace());
        if !has_real_content(body) {
            continue;
        }
        let inner: String = if lines[start].trim_start().starts_with("###") {
            lines[(start + 1).min(end + 1)..=end].join("\n")
        } else {
            block_text
        };
        let request = parse_block(&inner)?;
        out.push(Block {
            name,
            start_line: start,
            end_line: end,
            request,
        });
    }
    if out.is_empty() {
        return Err(ParseError::Empty);
    }
    Ok(out)
}

/// The request block containing `cursor_line`; falls back to the first block.
pub fn parse_at_line(input: &str, cursor_line: usize) -> Result<Request, ParseError> {
    let blocks = parse_all(input)?;
    for b in &blocks {
        if cursor_line >= b.start_line && cursor_line <= b.end_line {
            return Ok(b.request.clone());
        }
    }
    Ok(blocks[0].request.clone())
}

fn parse_separator_name(line: &str) -> Option<String> {
    let rest = line.trim_start().strip_prefix("###")?.trim();
    (!rest.is_empty()).then(|| rest.to_string())
}

fn first_request_block(input: &str) -> &str {
    let mut start = 0usize;
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let line_start = i;
        while i < bytes.len() && bytes[i] != b'\n' {
            i += 1;
        }
        if input[line_start..i].trim_start().starts_with("###") {
            let after = if i < bytes.len() { i + 1 } else { i };
            let candidate = input[start..line_start].trim();
            if has_real_content(candidate) {
                return candidate;
            }
            start = after;
        }
        if i < bytes.len() {
            i += 1;
        }
    }
    input[start..].trim()
}

fn has_real_content(s: &str) -> bool {
    s.lines().any(|l| {
        let t = l.trim();
        !t.is_empty() && !t.starts_with('#') && !t.starts_with("//")
    })
}

fn parse_block(block: &str) -> Result<Request, ParseError> {
    let mut lines = block.lines();
    let request_line = loop {
        let Some(l) = lines.next() else {
            return Err(ParseError::Empty);
        };
        let t = l.trim();
        if t.is_empty() || t.starts_with('#') || t.starts_with("//") {
            continue;
        }
        break t.to_string();
    };
    let (method, url) = split_request_line(&request_line)?;

    let mut headers: Vec<(String, String)> = Vec::new();
    let mut body_lines: Vec<&str> = Vec::new();
    let mut in_body = false;
    for raw in lines {
        if in_body {
            body_lines.push(raw);
            continue;
        }
        let t = raw.trim();
        if t.is_empty() {
            in_body = true;
        } else if t.starts_with('#') || t.starts_with("//") {
            // skip comment lines among the headers
        } else if let Some((k, v)) = t.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        } else {
            // Not a header and not blank — start of body (fault-tolerant; some
            // editors omit the separating blank line).
            body_lines.push(raw);
            in_body = true;
        }
    }
    let body = {
        let joined = body_lines.join("\n");
        let trimmed = joined.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    };
    Ok(Request {
        method,
        url,
        headers,
        body,
    })
}

fn split_request_line(line: &str) -> Result<(String, String), ParseError> {
    let mut parts = line.split_whitespace();
    let first = parts.next().ok_or(ParseError::NoUrl)?;
    let (method, url) = match parts.next() {
        Some(s) => (first.to_uppercase(), s.to_string()),
        None if looks_like_url(first) => ("GET".to_string(), first.to_string()),
        None => return Err(ParseError::NoUrl),
    };
    if !looks_like_url(&url) {
        return Err(ParseError::NoUrl);
    }
    Ok((method, url))
}

fn looks_like_url(s: &str) -> bool {
    s.starts_with("http://")
        || s.starts_with("https://")
        || s.starts_with("{{")
        || s.starts_with('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_get() {
        let req = parse("GET https://api.example.com/users").unwrap();
        assert_eq!(req.method, "GET");
        assert_eq!(req.url, "https://api.example.com/users");
        assert!(req.headers.is_empty());
        assert!(req.body.is_none());
    }

    #[test]
    fn parses_post_with_headers_and_body() {
        let raw = "POST https://api.example.com/users\nContent-Type: application/json\nAuthorization: Bearer abc\n\n{\"name\": \"Alice\"}";
        let req = parse(raw).unwrap();
        assert_eq!(req.method, "POST");
        assert_eq!(req.headers.len(), 2);
        assert_eq!(
            req.headers[0],
            ("Content-Type".into(), "application/json".into())
        );
        assert_eq!(req.body.as_deref(), Some("{\"name\": \"Alice\"}"));
    }

    #[test]
    fn skips_leading_comments_and_picks_first_block() {
        let raw = "# get the user list\n// also a comment\nGET https://x/users\n\n###\nPOST https://x/b\n";
        let req = parse(raw).unwrap();
        assert_eq!(req.method, "GET");
        assert_eq!(req.url, "https://x/users");
    }

    #[test]
    fn bare_url_and_template_url_and_http_version() {
        assert_eq!(parse("https://api.example.com/u").unwrap().method, "GET");
        assert_eq!(
            parse("GET {{BASE_URL}}/users").unwrap().url,
            "{{BASE_URL}}/users"
        );
        assert_eq!(
            parse("GET https://x/u HTTP/1.1").unwrap().url,
            "https://x/u"
        );
    }

    #[test]
    fn errors() {
        assert_eq!(parse(""), Err(ParseError::Empty));
        assert_eq!(parse("   \n  "), Err(ParseError::Empty));
        assert_eq!(parse("nonsense"), Err(ParseError::NoUrl));
    }

    #[test]
    fn parse_all_and_at_line() {
        let raw = "GET https://x/a\n\n### Create\nPOST https://x/b\nContent-Type: application/json\n\n{\"x\":1}\n### Patch\nPATCH https://x/c\n";
        let blocks = parse_all(raw).unwrap();
        assert_eq!(blocks.len(), 3);
        assert!(blocks[0].name.is_none());
        assert_eq!(blocks[1].name.as_deref(), Some("Create"));
        assert_eq!(blocks[1].request.method, "POST");
        assert_eq!(blocks[2].name.as_deref(), Some("Patch"));
        for w in blocks.windows(2) {
            assert!(w[0].end_line < w[1].start_line);
        }
        assert_eq!(parse_at_line(raw, 0).unwrap().url, "https://x/a");
        assert_eq!(parse_at_line(raw, 3).unwrap().url, "https://x/b");
        assert_eq!(parse_at_line(raw, 8).unwrap().url, "https://x/c");
    }

    #[test]
    fn multiline_body_preserved() {
        let raw = "POST https://x/y\nContent-Type: text/plain\n\nline one\nline two\nline three";
        assert_eq!(
            parse(raw).unwrap().body.as_deref(),
            Some("line one\nline two\nline three")
        );
    }
}
