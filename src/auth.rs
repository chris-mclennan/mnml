/// Pull a bearer token out of arbitrary clipboard text. Accepts:
///   "eyJ..."
///   "Bearer eyJ..."
///   "Authorization: Bearer eyJ..."
///   "authorization: bearer eyJ..."
/// Returns the bare token (no "Bearer " prefix), trimmed.
pub fn extract_bearer_from_clipboard(s: &str) -> Option<String> {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return None;
    }

    let lower = trimmed.to_ascii_lowercase();
    if let Some(idx) = lower.find("bearer ") {
        let after = &trimmed[idx + "bearer ".len()..];
        let token = after
            .split(|c: char| c.is_whitespace())
            .next()
            .unwrap_or("")
            .trim_matches(|c: char| c == '"' || c == '\'');
        if !token.is_empty() {
            return Some(token.to_string());
        }
    }

    // Fall back to assuming the whole pasted blob IS the token, as long as it
    // doesn't contain spaces or newlines (paranoia against pasting random
    // text by mistake).
    let single = trimmed
        .split(|c: char| c.is_whitespace())
        .next()
        .unwrap_or("");
    if single.len() == trimmed.len() && !single.is_empty() {
        return Some(single.to_string());
    }
    None
}

/// Replace the bearer token in a curl command's Authorization header.
/// Returns the rewritten command. If no Authorization: Bearer header is found,
/// returns None.
pub fn replace_bearer_in_curl(curl_text: &str, new_token: &str) -> Option<String> {
    // Look for `Authorization: Bearer <token>` inside any header value, case
    // insensitively. Easiest portable approach: walk the string and find
    // the substring "earer " (after "B" or "b") then the next single quote.
    let lower = curl_text.to_ascii_lowercase();
    let needle = "authorization: bearer ";
    let idx = lower.find(needle)?;
    let token_start = idx + needle.len();
    // Token ends at the next single quote (the curl header is single-quoted)
    // or at a whitespace/newline if for some reason it's unquoted.
    let rest = &curl_text[token_start..];
    let token_end_rel = rest.find(['\'', '"', '\n']).unwrap_or(rest.len());
    let token_end = token_start + token_end_rel;

    let mut out = String::with_capacity(curl_text.len() + new_token.len());
    out.push_str(&curl_text[..token_start]);
    out.push_str(new_token);
    out.push_str(&curl_text[token_end..]);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_raw() {
        assert_eq!(
            extract_bearer_from_clipboard("eyJabc.def.ghi"),
            Some("eyJabc.def.ghi".to_string())
        );
    }

    #[test]
    fn extract_with_prefix() {
        assert_eq!(
            extract_bearer_from_clipboard("Bearer eyJabc.def.ghi"),
            Some("eyJabc.def.ghi".to_string())
        );
        assert_eq!(
            extract_bearer_from_clipboard("Authorization: Bearer eyJabc.def.ghi"),
            Some("eyJabc.def.ghi".to_string())
        );
        assert_eq!(
            extract_bearer_from_clipboard("authorization: bearer eyJabc.def.ghi\n"),
            Some("eyJabc.def.ghi".to_string())
        );
    }

    #[test]
    fn replace_in_curl() {
        let input = "curl 'https://x.com/' \\\n  -H 'Authorization: Bearer oldtoken'";
        let out = replace_bearer_in_curl(input, "newtoken").unwrap();
        assert!(out.contains("Bearer newtoken"));
        assert!(!out.contains("oldtoken"));
    }

    #[test]
    fn replace_lower_case() {
        let input = "curl 'https://x.com/' -H 'authorization: bearer abc.def.ghi'";
        let out = replace_bearer_in_curl(input, "xxx").unwrap();
        assert!(out.contains("bearer xxx"));
    }

    #[test]
    fn no_bearer_returns_none() {
        let input = "curl 'https://x.com/' -H 'X-Api-Key: foo'";
        assert!(replace_bearer_in_curl(input, "xxx").is_none());
    }
}
