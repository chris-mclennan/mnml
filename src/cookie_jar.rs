//! Domain-keyed cookie jar — persists across sends so authenticated
//! flows (login → use session token → logout) survive the natural
//! "each :http.send is fresh" worker model.
//!
//! Scope: simple jar (name → value per domain). No expires/secure/
//! samesite enforcement — those would be belt-and-braces for what's
//! effectively a developer tool firing curls during the day. The
//! `Set-Cookie` parser splits on `;`, takes the first `name=value`
//! pair, ignores everything after.
//!
//! Persistence: `.mnml/cookies.json` keyed by canonical host
//! (lowercase, no trailing dot). Read on App init, written on
//! `:cookies.persist` or implicit on certain mutations.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default)]
pub struct CookieJar {
    /// host (lowercased) → Vec<(name, value)>. Order-stable so the
    /// emitted Cookie header is deterministic.
    by_host: HashMap<String, Vec<(String, String)>>,
}

impl CookieJar {
    pub fn new() -> Self {
        Self::default()
    }

    /// Read jar JSON from `.mnml/cookies.json`. Missing file ⇒ empty
    /// jar (the normal case on first launch). Malformed JSON ⇒ empty
    /// jar + log to stderr.
    pub fn load(workspace: &Path) -> Self {
        let path = workspace.join(".mnml").join("cookies.json");
        let Ok(text) = std::fs::read_to_string(&path) else {
            return Self::new();
        };
        let Ok(parsed): Result<serde_json::Value, _> = serde_json::from_str(&text) else {
            eprintln!("cookie_jar: {} is not valid JSON; starting fresh", path.display());
            return Self::new();
        };
        let mut by_host = HashMap::new();
        if let Some(obj) = parsed.as_object() {
            for (host, val) in obj {
                let mut pairs = Vec::new();
                if let Some(host_obj) = val.as_object() {
                    for (name, value) in host_obj {
                        if let Some(v) = value.as_str() {
                            pairs.push((name.clone(), v.to_string()));
                        }
                    }
                }
                if !pairs.is_empty() {
                    by_host.insert(host.to_lowercase(), pairs);
                }
            }
        }
        Self { by_host }
    }

    /// Write the jar to `.mnml/cookies.json`. Creates the parent dir
    /// if needed; returns the path written so callers can toast.
    pub fn save(&self, workspace: &Path) -> Result<PathBuf, String> {
        let path = workspace.join(".mnml").join("cookies.json");
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {e}"))?;
        }
        let mut out = serde_json::Map::new();
        for (host, pairs) in &self.by_host {
            let mut obj = serde_json::Map::new();
            for (n, v) in pairs {
                obj.insert(n.clone(), serde_json::Value::String(v.clone()));
            }
            out.insert(host.clone(), serde_json::Value::Object(obj));
        }
        let text = serde_json::to_string_pretty(&serde_json::Value::Object(out))
            .map_err(|e| format!("serialize: {e}"))?;
        std::fs::write(&path, text).map_err(|e| format!("write: {e}"))?;
        Ok(path)
    }

    /// Parse a Set-Cookie header value, store the name=value pair
    /// under `host`. Anything past the first `;` (Domain / Path /
    /// Expires / Secure / HttpOnly / SameSite) is ignored — the jar
    /// is intentionally simple.
    pub fn record_set_cookie(&mut self, host: &str, set_cookie: &str) {
        let host = host.to_lowercase();
        let head = set_cookie.split(';').next().unwrap_or("").trim();
        let Some((name, value)) = head.split_once('=') else {
            return;
        };
        let name = name.trim().to_string();
        let value = value.trim().to_string();
        if name.is_empty() {
            return;
        }
        let entries = self.by_host.entry(host).or_default();
        if let Some(existing) = entries.iter_mut().find(|(n, _)| *n == name) {
            existing.1 = value;
        } else {
            entries.push((name, value));
        }
    }

    /// Produce the `Cookie:` header value for the given host. Returns
    /// `None` if the jar has no cookies for that host.
    pub fn cookie_header_for(&self, host: &str) -> Option<String> {
        let host = host.to_lowercase();
        let pairs = self.by_host.get(&host)?;
        if pairs.is_empty() {
            return None;
        }
        Some(
            pairs
                .iter()
                .map(|(n, v)| format!("{n}={v}"))
                .collect::<Vec<_>>()
                .join("; "),
        )
    }

    /// Drop every cookie. Used by `:cookies.clear`.
    pub fn clear(&mut self) {
        self.by_host.clear();
    }

    /// Remove a single cookie by `(host, name)`. Returns true when
    /// a cookie was actually removed. Drops the host entry entirely
    /// when its last cookie is removed (keeps `total()` honest).
    pub fn remove(&mut self, host: &str, name: &str) -> bool {
        let host = host.to_lowercase();
        let Some(entries) = self.by_host.get_mut(&host) else {
            return false;
        };
        let pre = entries.len();
        entries.retain(|(n, _)| n != name);
        let removed = entries.len() < pre;
        if entries.is_empty() {
            self.by_host.remove(&host);
        }
        removed
    }

    /// Total cookie count (across all hosts). For toast messages.
    pub fn total(&self) -> usize {
        self.by_host.values().map(|v| v.len()).sum()
    }

    /// Iterate `(host, name, value)` for picker / inspection.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &str, &str)> {
        self.by_host
            .iter()
            .flat_map(|(h, ps)| ps.iter().map(move |(n, v)| (h.as_str(), n.as_str(), v.as_str())))
    }

    /// Extract the host from a URL string. Simple parser — splits
    /// off the scheme, takes everything up to the first `/` or `:`.
    pub fn host_of(url: &str) -> Option<String> {
        let after = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
        let host = after.split(['/', '?', '#']).next()?;
        let host = host.split(':').next()?; // strip port
        if host.is_empty() {
            None
        } else {
            Some(host.to_lowercase())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_emit() {
        let mut jar = CookieJar::new();
        jar.record_set_cookie("example.com", "sessionid=abc; Path=/; HttpOnly");
        jar.record_set_cookie("example.com", "csrf=xyz");
        let header = jar.cookie_header_for("example.com").unwrap();
        assert_eq!(header, "sessionid=abc; csrf=xyz");
    }

    #[test]
    fn host_case_insensitive() {
        let mut jar = CookieJar::new();
        jar.record_set_cookie("Example.COM", "a=1");
        assert!(jar.cookie_header_for("example.com").is_some());
    }

    #[test]
    fn host_of_strips_scheme_path_port() {
        assert_eq!(
            CookieJar::host_of("https://api.example.com:8443/users?x=1"),
            Some("api.example.com".to_string())
        );
    }

    #[test]
    fn record_updates_existing() {
        let mut jar = CookieJar::new();
        jar.record_set_cookie("x", "k=v1");
        jar.record_set_cookie("x", "k=v2");
        assert_eq!(jar.cookie_header_for("x"), Some("k=v2".to_string()));
    }
}
