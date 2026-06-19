//! Tiny JWT decoder (claims only, no signature verification).
//!
//! JWTs are three base64url-encoded segments separated by `.`. We only
//! care about the middle segment — the JSON claims. Signatures are
//! deliberately ignored: we're not authenticating, just *displaying*
//! information about a token the user already has.

use serde_json::Value;

#[derive(Debug, Clone)]
pub struct Claims {
    /// Unix-seconds expiry (`exp`). None if the JWT didn't have one.
    pub exp: Option<i64>,
    /// Unix-seconds issued-at (`iat`).
    pub iat: Option<i64>,
    pub sub: Option<String>,
    pub email: Option<String>,
    /// The raw JSON value for callers that want extra fields.
    pub raw: Value,
}

impl Claims {
    /// Returns true if `exp` is in the past (relative to system clock).
    pub fn is_expired(&self) -> bool {
        let Some(exp) = self.exp else {
            return false;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        exp < now
    }

    /// Format `exp` as `YYYY-MM-DD HH:MM UTC` plus a relative phrase like
    /// `(7 days)` or `(expired 2 hours ago)`.
    pub fn exp_display(&self) -> Option<String> {
        let exp = self.exp?;
        let date = format_unix_seconds(exp);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let delta = exp - now;
        let rel = if delta >= 0 {
            format_relative(delta, "")
        } else {
            format_relative(-delta, "expired ")
        };
        Some(format!("{date} ({rel})"))
    }
}

/// Decode the claims segment of a JWT. Does not verify the signature.
pub fn decode(token: &str) -> Option<Claims> {
    let parts: Vec<&str> = token.trim().split('.').collect();
    if parts.len() < 2 {
        return None;
    }
    let body = base64url_decode(parts[1])?;
    let json: Value = serde_json::from_slice(&body).ok()?;
    Some(Claims {
        exp: json.get("exp").and_then(|v| v.as_i64()),
        iat: json.get("iat").and_then(|v| v.as_i64()),
        sub: json.get("sub").and_then(|s| s.as_str()).map(String::from),
        email: json.get("email").and_then(|s| s.as_str()).map(String::from),
        raw: json,
    })
}

/// Heuristic: a token "looks like a JWT" if it has 3 dot-separated
/// base64url-y segments and the middle one decodes to a JSON object.
pub fn looks_like_jwt(token: &str) -> bool {
    let parts: Vec<&str> = token.trim().split('.').collect();
    if parts.len() != 3 {
        return false;
    }
    let Some(body) = base64url_decode(parts[1]) else {
        return false;
    };
    matches!(
        serde_json::from_slice::<Value>(&body)
            .ok()
            .map(|v| v.is_object()),
        Some(true)
    )
}

fn base64url_decode(input: &str) -> Option<Vec<u8>> {
    let mut bytes: Vec<u8> = input.bytes().filter(|&b| b != b'=' && b != b'\n').collect();
    while !bytes.len().is_multiple_of(4) {
        bytes.push(b'=');
    }
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        if chunk.len() < 4 {
            return None;
        }
        let mut buf = [0u8; 4];
        for (i, &c) in chunk.iter().enumerate() {
            buf[i] = match c {
                b'A'..=b'Z' => c - b'A',
                b'a'..=b'z' => c - b'a' + 26,
                b'0'..=b'9' => c - b'0' + 52,
                b'-' | b'+' => 62,
                b'_' | b'/' => 63,
                b'=' => 64,
                _ => return None,
            };
        }
        if buf[0] == 64 || buf[1] == 64 {
            return None;
        }
        out.push((buf[0] << 2) | (buf[1] >> 4));
        if buf[2] != 64 {
            out.push((buf[1] << 4) | (buf[2] >> 2));
            if buf[3] != 64 {
                out.push((buf[2] << 6) | buf[3]);
            }
        }
    }
    Some(out)
}

/// Civil-calendar formatting for unix seconds (UTC). Avoids dragging in
/// `chrono` for one helper. Algorithm: Howard Hinnant's `civil_from_days`.
pub fn format_unix_seconds(secs: i64) -> String {
    let secs_per_day: i64 = 86_400;
    let days = secs.div_euclid(secs_per_day);
    let day_secs = secs.rem_euclid(secs_per_day);
    let hour = day_secs / 3600;
    let minute = (day_secs / 60) % 60;
    let second = day_secs % 60;
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}Z")
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn format_relative(seconds: i64, prefix: &str) -> String {
    if seconds < 60 {
        format!("{prefix}{seconds}s")
    } else if seconds < 3600 {
        format!("{prefix}{}m", seconds / 60)
    } else if seconds < 86_400 {
        let h = seconds / 3600;
        format!("{prefix}{h} hour{}", if h == 1 { "" } else { "s" })
    } else {
        let d = seconds / 86_400;
        format!("{prefix}{d} day{}", if d == 1 { "" } else { "s" })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hand-crafted JWT: header `{"alg":"none"}`, body `{"sub":"abc","exp":3155759600}`,
    /// signature empty. exp = 2069-12-31 23:33:20 UTC.
    fn sample_token() -> String {
        let header = base64url_encode_str(r#"{"alg":"none"}"#);
        let body = base64url_encode_str(r#"{"sub":"abc","exp":3155759600,"email":"x@y"}"#);
        format!("{header}.{body}.")
    }

    fn base64url_encode_str(s: &str) -> String {
        base64url_encode(s.as_bytes())
    }

    fn base64url_encode(bytes: &[u8]) -> String {
        const ALPHA: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let b0 = chunk[0];
            let b1 = chunk.get(1).copied().unwrap_or(0);
            let b2 = chunk.get(2).copied().unwrap_or(0);
            out.push(ALPHA[(b0 >> 2) as usize] as char);
            out.push(ALPHA[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            if chunk.len() > 1 {
                out.push(ALPHA[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char);
            }
            if chunk.len() > 2 {
                out.push(ALPHA[(b2 & 0x3F) as usize] as char);
            }
        }
        out
    }

    #[test]
    fn decode_extracts_known_claims() {
        let claims = decode(&sample_token()).unwrap();
        assert_eq!(claims.exp, Some(3_155_759_600));
        assert_eq!(claims.sub.as_deref(), Some("abc"));
        assert_eq!(claims.email.as_deref(), Some("x@y"));
    }

    #[test]
    fn looks_like_jwt_accepts_3_segments_with_json_body() {
        assert!(looks_like_jwt(&sample_token()));
        assert!(!looks_like_jwt("not.a.jwt"));
        assert!(!looks_like_jwt("eyJxxx"));
    }

    #[test]
    fn format_unix_seconds_known_dates() {
        assert_eq!(format_unix_seconds(0), "1970-01-01 00:00:00Z");
        assert_eq!(format_unix_seconds(1_700_000_000), "2023-11-14 22:13:20Z");
    }

    #[test]
    fn is_expired_works_in_past_and_future() {
        let mut c = Claims {
            exp: Some(0),
            iat: None,
            sub: None,
            email: None,
            raw: serde_json::Value::Null,
        };
        assert!(c.is_expired());
        c.exp = Some(i64::MAX);
        assert!(!c.is_expired());
    }
}
