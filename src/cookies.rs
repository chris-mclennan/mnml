//! Cookie helpers — small surface that pays for itself when the user
//! pastes cookies copied from browser DevTools. DevTools renders the
//! same cookies in inconsistent shapes:
//!
//! ```text
//! Format A (Network tab, "Request Cookies"):
//!     sessionid=abc123
//!     csrftoken=xyz789
//!
//! Format B (Application tab, "Cookies"):
//!     sessionid: abc123
//!     csrftoken: xyz789
//!
//! Format C (correct on-the-wire form):
//!     sessionid=abc123; csrftoken=xyz789
//! ```
//!
//! `normalize_cookie_value` collapses any of those into the canonical
//! `name=value; name=value; ...` form. The Headers tab calls it when
//! the user pastes into a `Cookie:` header value so they don't have
//! to hand-edit the result. There's nothing magic — just a permissive
//! parser plus a strict re-emitter.

/// Normalize an arbitrary cookie-shaped paste into canonical form.
/// Empty pairs and stray separators are dropped silently.
pub fn normalize_cookie_value(raw: &str) -> String {
    let mut pairs: Vec<(String, String)> = Vec::new();
    // Split on either `;` or newline — browser DevTools sometimes
    // outputs one cookie per line, sometimes the proper `;` form.
    let chunks = raw.split([';', '\n']);
    for chunk in chunks {
        let trimmed = chunk.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Prefer `=` as the separator; fall back to `:` only when
        // there's no `=` in the chunk (DevTools "Application" tab
        // formats as `name: value`).
        let (name, value) = if let Some((n, v)) = trimmed.split_once('=') {
            (n, v)
        } else if let Some((n, v)) = trimmed.split_once(':') {
            (n, v)
        } else {
            // Bare `name` with no value — skip rather than emit
            // something malformed.
            continue;
        };
        let name = name.trim();
        let value = value.trim();
        if name.is_empty() {
            continue;
        }
        pairs.push((name.to_string(), value.to_string()));
    }
    pairs
        .into_iter()
        .map(|(n, v)| format!("{n}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// Case-insensitive check: is this header name `Cookie`? Header
/// matching elsewhere in rqst is case-insensitive (HTTP/1.1 spec)
/// so we follow the same convention here.
pub fn is_cookie_header(name: &str) -> bool {
    name.eq_ignore_ascii_case("cookie")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_through_canonical_form_unchanged() {
        let canonical = "sessionid=abc; csrftoken=xyz";
        assert_eq!(normalize_cookie_value(canonical), canonical);
    }

    #[test]
    fn collapses_newline_separated_pairs() {
        let raw = "sessionid=abc\ncsrftoken=xyz\n";
        assert_eq!(normalize_cookie_value(raw), "sessionid=abc; csrftoken=xyz");
    }

    #[test]
    fn rewrites_colon_form_into_equals_form() {
        let raw = "sessionid: abc\ncsrftoken: xyz";
        assert_eq!(normalize_cookie_value(raw), "sessionid=abc; csrftoken=xyz");
    }

    #[test]
    fn handles_mixed_separators_and_extra_whitespace() {
        let raw = "  sessionid=abc ;  csrftoken: xyz  ;\n  trace=42\n";
        assert_eq!(
            normalize_cookie_value(raw),
            "sessionid=abc; csrftoken=xyz; trace=42"
        );
    }

    #[test]
    fn drops_empty_or_nameless_pairs() {
        let raw = ";; sessionid=abc; ;=value-with-no-name; csrftoken=xyz;";
        assert_eq!(normalize_cookie_value(raw), "sessionid=abc; csrftoken=xyz");
    }

    #[test]
    fn empty_input_yields_empty_output() {
        assert_eq!(normalize_cookie_value(""), "");
        assert_eq!(normalize_cookie_value(" \n ; ; "), "");
    }

    #[test]
    fn preserves_value_with_embedded_equals() {
        // base64 / signed cookies often contain `=` inside the value;
        // only the FIRST `=` is the name/value separator.
        let raw = "auth=eyJhbGciOiJIUzI1NiJ9.payload=";
        assert_eq!(
            normalize_cookie_value(raw),
            "auth=eyJhbGciOiJIUzI1NiJ9.payload="
        );
    }

    #[test]
    fn is_cookie_header_is_case_insensitive() {
        assert!(is_cookie_header("Cookie"));
        assert!(is_cookie_header("cookie"));
        assert!(is_cookie_header("COOKIE"));
        assert!(!is_cookie_header("Set-Cookie"));
        assert!(!is_cookie_header("Authorization"));
    }
}
