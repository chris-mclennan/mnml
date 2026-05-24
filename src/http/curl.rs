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
            "--url" => {
                if let Some(v) = tokens.get(i + 1) {
                    if url.is_none() {
                        url = Some(v.clone());
                    }
                    advance = 2;
                }
            }
            // Flags we accept and ignore.
            "--compressed" | "--location" | "-L" | "--insecure" | "-k" | "--silent" | "-s"
            | "--fail" | "-f" | "-i" | "--include" | "-#" | "--progress-bar" | "-v"
            | "--verbose" => {}
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
    })
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
