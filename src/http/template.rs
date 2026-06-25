//! `{{VAR}}` substitution with workspace-local env files.
//!
//! - The active env is a named file `<workspace>/.mnml/env/<name>.env` (chosen by
//!   `--env NAME` or `$MNML_ENV`); a missing file just means no overrides.
//! - `{{NAME}}` resolves from that file first, then from process env vars.
//! - `{{$uuid}}` / `{{$timestamp}}` / … are dynamic — a fresh value per call.
//! - An unresolved `{{FOO}}` is left verbatim in the output (so it shows up in
//!   any failure) and can be listed via [`unresolved`].
//! - Var names are `[A-Za-z0-9_]+` (or `$[A-Za-z0-9_]+` for dynamics);
//!   whitespace inside `{{ FOO }}` is allowed.
//!
//! A trimmed implementation — the faker-style name lists and the
//! calendar-formatting dynamics are intentionally out of scope; we
//! keep the handful of substitutions that need no extra machinery.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

#[derive(Debug, Clone, Default)]
pub struct EnvSet {
    pub name: Option<String>,
    pub vars: HashMap<String, String>,
}

impl EnvSet {
    pub fn empty() -> Self {
        Self::default()
    }

    /// Load `<workspace>/.mnml/env/<name>.env`, with a fall-back to
    /// `<workspace>/.rqst/env/<name>.env` for workspaces ported over
    /// from the legacy rqst app. `.mnml/` wins when both exist so a
    /// migrating user can override per-key without losing the
    /// originals. Missing file ⇒ empty set (the name is still
    /// recorded). 2026-06-19 — phase 1 of the rqst→mnml port-back.
    pub fn load(workspace: &Path, name: &str) -> Self {
        let mut vars = HashMap::new();
        // Read the legacy .rqst path first so .mnml overrides on the
        // SAME key win in the final map.
        for sub in [".rqst", ".mnml"] {
            let path = workspace.join(sub).join("env").join(format!("{name}.env"));
            if let Ok(text) = fs::read_to_string(&path) {
                for line in text.lines() {
                    if let Some((k, v)) = parse_env_line(line) {
                        vars.insert(k, v);
                    }
                }
            }
        }
        Self {
            name: Some(name.to_string()),
            vars,
        }
    }

    /// Pick the env in this order:
    ///   1. `explicit` (the `--env NAME` CLI flag / palette arg)
    ///   2. `$MNML_ENV`
    ///   3. `<workspace>/.rqst/config`'s `default_env=…` (rqst legacy
    ///      workspaces; phase 1 of the port-back means a user
    ///      launching mnml at a `~/Projects/tattle-mnml-workspace`
    ///      gets `dev` selected without re-configuring)
    /// `None`/empty ⇒ empty set.
    pub fn select(workspace: &Path, explicit: Option<&str>) -> Self {
        let name = explicit
            .map(str::to_string)
            .or_else(|| std::env::var("MNML_ENV").ok())
            .or_else(|| read_rqst_config_default_env(workspace))
            .filter(|s| !s.trim().is_empty());
        match name {
            Some(n) => Self::load(workspace, &n),
            None => Self::empty(),
        }
    }

    /// Active env name (`Some("dev")`) — set by [`Self::select`] /
    /// [`Self::load`]. `None` only on `Self::empty()`.
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    pub fn lookup(&self, key: &str) -> Option<String> {
        if let Some(v) = self.vars.get(key) {
            return Some(v.clone());
        }
        std::env::var(key).ok()
    }
}

/// Built-in dynamic variables (`{{$NAME}}`). Each call returns a fresh value;
/// `None` for unrecognised names so the caller can flag them.
pub fn dynamic_var(name: &str) -> Option<String> {
    match name {
        "uuid" | "guid" => Some(uuid_v4()),
        "timestamp" | "epochMs" => Some(unix_ms().to_string()),
        "epoch" | "epochS" => Some((unix_ms() / 1000).to_string()),
        "randomInt" => Some((small_random_u32() % 1_000_000).to_string()),
        "randomHex" => Some(format!("{:08x}", small_random_u32())),
        "randomString" => Some(uuid_v4().replace('-', "")[..16].to_string()),
        "randomBool" => Some(
            if small_random_u32().is_multiple_of(2) {
                "true"
            } else {
                "false"
            }
            .to_string(),
        ),
        _ => None,
    }
}

/// Substitute every resolvable `{{VAR}}` / `{{$DYN}}` in `text`; leave the rest verbatim.
pub fn expand(text: &str, env: &EnvSet) -> String {
    let mut out = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 1 < bytes.len()
            && bytes[i] == b'{'
            && bytes[i + 1] == b'{'
            && let Some(end_off) = text[i + 2..].find("}}")
        {
            let name = text[i + 2..i + 2 + end_off].trim();
            if is_valid_var_name(name)
                && let Some(value) = resolve(name, env)
            {
                out.push_str(&value);
                i += 2 + end_off + 2;
                continue;
            }
        }
        let c = text[i..].chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

/// Every `{{VAR}}` in `text` that can't be resolved (in source order, deduped).
pub fn unresolved(text: &str, env: &EnvSet) -> Vec<String> {
    let mut missing: Vec<String> = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 1 < bytes.len()
            && bytes[i] == b'{'
            && bytes[i + 1] == b'{'
            && let Some(end_off) = text[i + 2..].find("}}")
        {
            let name = text[i + 2..i + 2 + end_off].trim();
            if is_valid_var_name(name)
                && resolve(name, env).is_none()
                && !missing.iter().any(|m| m == name)
            {
                missing.push(name.to_string());
            }
            i += 2 + end_off + 2;
            continue;
        }
        let c = text[i..].chars().next().unwrap();
        i += c.len_utf8();
    }
    missing
}

fn resolve(name: &str, env: &EnvSet) -> Option<String> {
    match name.strip_prefix('$') {
        Some(dyn_name) => dynamic_var(dyn_name),
        None => env.lookup(name),
    }
}

fn is_valid_var_name(s: &str) -> bool {
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if first != '$' && !first.is_ascii_alphanumeric() && first != '_' {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Best-effort read of `<workspace>/.rqst/config` for the
/// `default_env=…` key. The file is rqst's KEY=VALUE format —
/// comments (`#`), blank lines, unrelated keys all silently
/// ignored. Returns `None` when the file is absent (a
/// non-migrated workspace) so `select` can fall through to its
/// other arms cleanly. Phase 1 of the rqst→mnml port-back —
/// 2026-06-19.
///
/// Value handling: assumes BARE values, like rqst's real config
/// files (`default_env=dev`). Surrounding quotes are NOT stripped
/// — a hypothetical `default_env="dev"` would resolve to env
/// `"dev"` (literal quotes), which the loader would then fail to
/// find and `select` would fall through to empty. Real workspaces
/// use the bare form so this isn't a live bug.
fn read_rqst_config_default_env(workspace: &Path) -> Option<String> {
    let text = fs::read_to_string(workspace.join(".rqst").join("config")).ok()?;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = trimmed.split_once('=')
            && k.trim() == "default_env"
            && !v.trim().is_empty()
        {
            return Some(v.trim().to_string());
        }
    }
    None
}

fn parse_env_line(line: &str) -> Option<(String, String)> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let (k, v) = trimmed.split_once('=')?;
    let key = k.trim().to_string();
    if key.is_empty() {
        return None;
    }
    let v = v.trim();
    let value = if v.len() >= 2
        && ((v.starts_with('"') && v.ends_with('"')) || (v.starts_with('\'') && v.ends_with('\'')))
    {
        v[1..v.len() - 1].to_string()
    } else {
        v.to_string()
    };
    Some((key, value))
}

// ── randomness (not crypto — just unique-payload generation) ──────────

fn uuid_v4() -> String {
    let mut b = random_bytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let mut s = String::with_capacity(36);
    for (i, byte) in b.iter().enumerate() {
        if matches!(i, 4 | 6 | 8 | 10) {
            s.push('-');
        }
        s.push_str(&format!("{byte:02x}"));
    }
    s
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    if let Ok(mut f) = fs::File::open("/dev/urandom")
        && f.read_exact(&mut buf).is_ok()
    {
        return buf;
    }
    // Fallback: nanoseconds + pid mixed via splitmix64 (Windows / no /dev/urandom).
    let mut seed = unix_ns() ^ ((std::process::id() as u128) << 64);
    for chunk in buf.chunks_mut(8) {
        seed = splitmix64(seed);
        let bytes = (seed as u64).to_le_bytes();
        for (i, b) in chunk.iter_mut().enumerate() {
            *b = bytes[i];
        }
    }
    buf
}

fn small_random_u32() -> u32 {
    let b = random_bytes(4);
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

fn splitmix64(mut z: u128) -> u128 {
    z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
    let mut x = z as u64;
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^= x >> 31;
    x as u128
}

fn unix_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn unix_ns() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> EnvSet {
        EnvSet {
            name: None,
            vars: pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    #[test]
    fn expand_substitutes_known_leaves_unknown() {
        let e = env(&[("BASE_URL", "https://api.example.com"), ("TOKEN", "abc")]);
        assert_eq!(
            expand("{{BASE_URL}}/users?t={{TOKEN}}&x={{MISSING}}", &e),
            "https://api.example.com/users?t=abc&x={{MISSING}}"
        );
        assert_eq!(expand("{{ BASE_URL }}", &e), "https://api.example.com");
    }

    #[test]
    fn unresolved_lists_missing_in_order_deduped() {
        let e = env(&[("A", "1")]);
        assert_eq!(unresolved("{{A}} {{B}} {{C}} {{B}}", &e), vec!["B", "C"]);
        assert!(unresolved("{{A}}", &e).is_empty());
    }

    #[test]
    fn dynamic_vars_expand_and_uuid_is_shaped() {
        let e = EnvSet::empty();
        let out = expand("{{$uuid}}", &e);
        assert_eq!(out.len(), 36);
        assert_eq!(out.matches('-').count(), 4);
        assert!(out.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
        // unknown dynamic stays verbatim
        assert_eq!(expand("{{$nope}}", &e), "{{$nope}}");
        // a numeric dynamic resolves to digits
        assert!(
            expand("{{$randomInt}}", &e)
                .chars()
                .all(|c| c.is_ascii_digit())
        );
    }

    #[test]
    fn parse_env_line_handles_quotes_and_comments() {
        assert_eq!(
            parse_env_line("FOO=bar"),
            Some(("FOO".into(), "bar".into()))
        );
        assert_eq!(
            parse_env_line("FOO = \"hello world\""),
            Some(("FOO".into(), "hello world".into()))
        );
        assert_eq!(parse_env_line("# comment"), None);
        assert_eq!(parse_env_line("=oops"), None);
        assert_eq!(parse_env_line(""), None);
    }
}
