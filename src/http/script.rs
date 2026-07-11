//! `@`-prefixed directives carried in `.http` / `.curl` comments:
//!
//! ```text
//! # @set-header Authorization = Bearer {{TOKEN}}
//! # @set-env REQUEST_ID = {{$uuid}}
//! GET https://api.example.com/users/1
//! # @assert status == 200
//! # @assert header.Content-Type contains json
//! # @assert json $.name == "Alice"
//! # @assert json $.id is number
//! # @assert body contains hello
//! # @capture user_id = json $.id
//! # @capture trace_id = header X-Request-Id
//! ```
//!
//! `@set-*` (pre-request) run before sending — `@set-env` feeds `{{NAME}}`
//! substitution; `@set-header` overrides a header. `@assert` and `@capture`
//! (post-response) run against the result; captures land in the `EnvSet` so a
//! follow-up request can `{{name}}` them. Directive lines that don't parse are
//! silently treated as plain comments.

use serde_json::Value;

use super::Request;
use super::template::{self, EnvSet};

/// Comparison operators allowed in `@assert`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Contains,
}

impl CmpOp {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "==" | "=" => Self::Eq,
            "!=" => Self::Ne,
            "<" => Self::Lt,
            "<=" => Self::Le,
            ">" => Self::Gt,
            ">=" => Self::Ge,
            "contains" => Self::Contains,
            _ => return None,
        })
    }
    fn label(self) -> &'static str {
        match self {
            Self::Eq => "==",
            Self::Ne => "!=",
            Self::Lt => "<",
            Self::Le => "<=",
            Self::Gt => ">",
            Self::Ge => ">=",
            Self::Contains => "contains",
        }
    }
}

/// `is <type>` accepted in JSON assertions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JsonType {
    Number,
    String,
    Bool,
    Array,
    Object,
    Null,
}

impl JsonType {
    fn parse(s: &str) -> Option<Self> {
        Some(match s.to_ascii_lowercase().as_str() {
            "number" | "num" => Self::Number,
            "string" | "str" => Self::String,
            "bool" | "boolean" => Self::Bool,
            "array" | "list" => Self::Array,
            "object" | "obj" => Self::Object,
            "null" => Self::Null,
            _ => return None,
        })
    }
    fn matches(self, v: &Value) -> bool {
        matches!(
            (self, v),
            (Self::Number, Value::Number(_))
                | (Self::String, Value::String(_))
                | (Self::Bool, Value::Bool(_))
                | (Self::Array, Value::Array(_))
                | (Self::Object, Value::Object(_))
                | (Self::Null, Value::Null)
        )
    }
    fn label(self) -> &'static str {
        match self {
            Self::Number => "number",
            Self::String => "string",
            Self::Bool => "bool",
            Self::Array => "array",
            Self::Object => "object",
            Self::Null => "null",
        }
    }
}

/// One parsed `@assert` directive.
#[derive(Debug, Clone, PartialEq)]
pub enum Assertion {
    Status {
        op: CmpOp,
        value: i64,
    },
    Header {
        name: String,
        op: CmpOp,
        value: String,
    },
    BodyContains(String),
    /// `@assert json <path> <op> <value>` — `value` parsed lazily (string /
    /// number / bool all comparable).
    JsonValue {
        path: String,
        op: CmpOp,
        raw_value: String,
    },
    JsonType {
        path: String,
        ty: JsonType,
    },
}

impl Assertion {
    /// Render the assertion as it appears in the source — for pass/fail summaries.
    pub fn label(&self) -> String {
        match self {
            Self::Status { op, value } => format!("status {} {}", op.label(), value),
            Self::Header { name, op, value } => format!("header.{} {} {}", name, op.label(), value),
            Self::BodyContains(s) => format!("body contains {s:?}"),
            Self::JsonValue {
                path,
                op,
                raw_value,
            } => {
                format!("json {} {} {}", path, op.label(), raw_value)
            }
            Self::JsonType { path, ty } => format!("json {} is {}", path, ty.label()),
        }
    }
}

/// Pre-request side effect.
#[derive(Debug, Clone, PartialEq)]
pub enum PreHook {
    SetHeader { name: String, value: String },
    SetEnv { name: String, value: String },
}

/// Post-response side effect.
#[derive(Debug, Clone, PartialEq)]
pub enum PostHook {
    CaptureJson { name: String, path: String },
    CaptureHeader { name: String, header: String },
}

/// All directives parsed from one request block.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Script {
    pub pre: Vec<PreHook>,
    pub assertions: Vec<Assertion>,
    pub post: Vec<PostHook>,
}

impl Script {
    pub fn is_empty(&self) -> bool {
        self.pre.is_empty() && self.assertions.is_empty() && self.post.is_empty()
    }
}

/// Result of running one assertion against a response.
#[derive(Debug, Clone)]
pub struct AssertionResult {
    pub label: String,
    pub passed: bool,
    pub detail: Option<String>,
}

/// Parse all `@`-prefixed directives out of one request-block text. Unparseable
/// directive lines are ignored (they read as plain comments in other tools).
pub fn parse(block: &str) -> Script {
    let mut script = Script::default();
    for raw in block.lines() {
        let trimmed = raw.trim_start();
        if let Some(rest) = strip_comment_prefix(trimmed)
            && let Some(d) = rest.trim_start().strip_prefix('@')
        {
            parse_directive(d.trim(), &mut script);
        }
    }
    script
}

fn strip_comment_prefix(line: &str) -> Option<&str> {
    if line.starts_with("###") {
        return None; // block separator — not a directive carrier
    }
    line.strip_prefix('#').or_else(|| line.strip_prefix("//"))
}

fn parse_directive(d: &str, script: &mut Script) {
    if let Some(rest) = strip_kw(d, "set-header") {
        if let Some((name, value)) = split_eq(rest) {
            script.pre.push(PreHook::SetHeader {
                name: name.to_string(),
                value: value.to_string(),
            });
        }
    } else if let Some(rest) = strip_kw(d, "set-env") {
        if let Some((name, value)) = split_eq(rest) {
            script.pre.push(PreHook::SetEnv {
                name: name.to_string(),
                value: value.to_string(),
            });
        }
    } else if let Some(rest) = strip_kw(d, "assert") {
        if let Some(a) = parse_assertion(rest) {
            script.assertions.push(a);
        }
    } else if let Some(rest) = strip_kw(d, "capture")
        && let Some(p) = parse_capture(rest)
    {
        script.post.push(p);
    }
}

fn strip_kw<'a>(d: &'a str, kw: &str) -> Option<&'a str> {
    let rest = d.strip_prefix(kw)?;
    match rest.chars().next() {
        None => Some(rest),
        Some(c) if c.is_whitespace() => Some(rest.trim_start()),
        Some(_) => None,
    }
}

fn split_eq(s: &str) -> Option<(&str, &str)> {
    let (k, v) = s.split_once('=')?;
    let (k, v) = (k.trim(), v.trim());
    (!k.is_empty() && !v.is_empty()).then_some((k, v))
}

fn parse_assertion(rest: &str) -> Option<Assertion> {
    if let Some(after) = strip_kw(rest, "status") {
        let (op, value) = split_op_and_rest(after)?;
        return Some(Assertion::Status {
            op,
            value: value.trim().parse().ok()?,
        });
    }
    if let Some(after) = strip_kw(rest, "body") {
        let after = after.trim_start().strip_prefix("contains")?;
        return Some(Assertion::BodyContains(unquote(after.trim())));
    }
    if let Some(after) = rest.strip_prefix("header.") {
        let (name, rest_after) = split_word(after)?;
        let (op, value) = split_op_and_rest(rest_after)?;
        return Some(Assertion::Header {
            name: name.to_string(),
            op,
            value: unquote(value.trim()),
        });
    }
    if let Some(after) = strip_kw(rest, "json") {
        let (path, rest_after) = split_word(after)?;
        let rest_after = rest_after.trim_start();
        if let Some(ty_str) = rest_after.strip_prefix("is") {
            return Some(Assertion::JsonType {
                path: path.to_string(),
                ty: JsonType::parse(ty_str.trim())?,
            });
        }
        let (op, value) = split_op_and_rest(rest_after)?;
        return Some(Assertion::JsonValue {
            path: path.to_string(),
            op,
            raw_value: unquote(value.trim()),
        });
    }
    None
}

fn parse_capture(rest: &str) -> Option<PostHook> {
    let (name, value) = split_eq(rest)?;
    if let Some(after) = strip_kw(value, "json") {
        let path = after.trim().to_string();
        return (!path.is_empty()).then_some(PostHook::CaptureJson {
            name: name.to_string(),
            path,
        });
    }
    if let Some(after) = strip_kw(value, "header") {
        let header = after.trim().to_string();
        return (!header.is_empty()).then_some(PostHook::CaptureHeader {
            name: name.to_string(),
            header,
        });
    }
    None
}

fn split_op_and_rest(s: &str) -> Option<(CmpOp, &str)> {
    let s = s.trim_start();
    // Longest operators first so `<=` doesn't match `<`.
    for op in ["==", "!=", "<=", ">=", "contains", "<", ">", "="] {
        if let Some(rest) = s.strip_prefix(op) {
            return Some((CmpOp::parse(op)?, rest));
        }
    }
    None
}

fn split_word(s: &str) -> Option<(&str, &str)> {
    let s = s.trim_start();
    let end = s.find(char::is_whitespace).unwrap_or(s.len());
    (end > 0).then(|| (&s[..end], &s[end..]))
}

fn unquote(s: &str) -> String {
    if s.len() >= 2
        && ((s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')))
    {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}

/// Apply pre-request hooks. `env` is mutated in place so subsequent `{{NAME}}`
/// substitution (URL / body) sees `@set-env` values.
pub fn apply_pre(script: &Script, request: &mut Request, env: &mut EnvSet) {
    for hook in &script.pre {
        match hook {
            PreHook::SetHeader { name, value } => {
                let rendered = template::expand(value, env);
                request
                    .headers
                    .retain(|(k, _)| !k.eq_ignore_ascii_case(name));
                request.headers.push((name.clone(), rendered));
            }
            PreHook::SetEnv { name, value } => {
                let rendered = template::expand(value, env);
                env.vars.insert(name.clone(), rendered);
            }
        }
    }
}

/// Run every assertion against a response, preserving source order.
pub fn run_assertions(
    script: &Script,
    status: u16,
    headers: &[(String, String)],
    body: &str,
) -> Vec<AssertionResult> {
    let parsed: Option<Value> = serde_json::from_str(body).ok();
    script
        .assertions
        .iter()
        .map(|a| run_one(a, status, headers, body, parsed.as_ref()))
        .collect()
}

fn run_one(
    a: &Assertion,
    status: u16,
    headers: &[(String, String)],
    body: &str,
    json: Option<&Value>,
) -> AssertionResult {
    let label = a.label();
    let (passed, detail) = match a {
        Assertion::Status { op, value } => {
            let actual = status as i64;
            let ok = cmp_int(*op, actual, *value);
            (ok, (!ok).then(|| format!("got {actual}")))
        }
        Assertion::Header { name, op, value } => {
            let actual = headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            let ok = cmp_str(*op, actual, value);
            (ok, (!ok).then(|| format!("got {actual:?}")))
        }
        Assertion::BodyContains(s) => {
            let ok = body.contains(s.as_str());
            (ok, (!ok).then(|| "not found in body".to_string()))
        }
        Assertion::JsonValue {
            path,
            op,
            raw_value,
        } => match json {
            None => (false, Some("response body is not JSON".to_string())),
            Some(j) => match resolve_json_path(j, path) {
                None => (false, Some(format!("path {path} not found"))),
                Some(v) => {
                    let ok = compare_json_to_raw(v, *op, raw_value);
                    (ok, (!ok).then(|| format!("got {v}")))
                }
            },
        },
        Assertion::JsonType { path, ty } => match json {
            None => (false, Some("response body is not JSON".to_string())),
            Some(j) => match resolve_json_path(j, path) {
                None => (false, Some(format!("path {path} not found"))),
                Some(v) => (ty.matches(v), None),
            },
        },
    };
    AssertionResult {
        label,
        passed,
        detail,
    }
}

fn cmp_int(op: CmpOp, a: i64, b: i64) -> bool {
    match op {
        CmpOp::Eq => a == b,
        CmpOp::Ne => a != b,
        CmpOp::Lt => a < b,
        CmpOp::Le => a <= b,
        CmpOp::Gt => a > b,
        CmpOp::Ge => a >= b,
        CmpOp::Contains => false,
    }
}

fn cmp_str(op: CmpOp, a: &str, b: &str) -> bool {
    match op {
        CmpOp::Eq => a == b,
        CmpOp::Ne => a != b,
        CmpOp::Contains => a.to_ascii_lowercase().contains(&b.to_ascii_lowercase()),
        CmpOp::Lt => a < b,
        CmpOp::Le => a <= b,
        CmpOp::Gt => a > b,
        CmpOp::Ge => a >= b,
    }
}

fn compare_json_to_raw(v: &Value, op: CmpOp, raw: &str) -> bool {
    if let (Some(actual), Ok(expected)) = (v.as_f64(), raw.parse::<f64>()) {
        match op {
            CmpOp::Eq => return (actual - expected).abs() < f64::EPSILON,
            CmpOp::Ne => return (actual - expected).abs() >= f64::EPSILON,
            CmpOp::Lt => return actual < expected,
            CmpOp::Le => return actual <= expected,
            CmpOp::Gt => return actual > expected,
            CmpOp::Ge => return actual >= expected,
            CmpOp::Contains => {}
        }
    }
    if let Some(b) = v.as_bool() {
        let expected = matches!(raw.to_ascii_lowercase().as_str(), "true" | "1" | "yes");
        match op {
            CmpOp::Eq => return b == expected,
            CmpOp::Ne => return b != expected,
            _ => {}
        }
    }
    let actual = match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    cmp_str(op, &actual, raw)
}

/// Resolve a `.foo.bar[0]` path against a `serde_json::Value` (a leading `$` is
/// accepted for jsonpath-style writers). `None` if the path doesn't exist.
pub fn resolve_json_path<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    let mut path = path.trim();
    if let Some(rest) = path.strip_prefix('$') {
        path = rest;
    }
    let mut cur = v;
    let mut chars = path.chars().peekable();
    let mut buf = String::new();
    let mut state = PathState::Start;
    while let Some(&c) = chars.peek() {
        match (state, c) {
            (PathState::Start, '.') => {
                chars.next();
                state = PathState::Key;
                buf.clear();
            }
            (PathState::Start, '[') => {
                chars.next();
                state = PathState::Idx;
                buf.clear();
            }
            (PathState::Start, _) => {
                state = PathState::Key;
                buf.clear();
            }
            (PathState::Key, '.') | (PathState::Key, '[') => {
                cur = cur.get(buf.as_str())?;
                chars.next();
                state = if c == '[' {
                    PathState::Idx
                } else {
                    PathState::Key
                };
                buf.clear();
            }
            (PathState::Key, _) => {
                buf.push(c);
                chars.next();
            }
            (PathState::Idx, ']') => {
                cur = cur.get(buf.parse::<usize>().ok()?)?;
                chars.next();
                state = PathState::Start;
                buf.clear();
            }
            (PathState::Idx, _) => {
                buf.push(c);
                chars.next();
            }
        }
    }
    if state == PathState::Key && !buf.is_empty() {
        cur = cur.get(buf.as_str())?;
    }
    Some(cur)
}

#[derive(Clone, Copy, PartialEq)]
enum PathState {
    Start,
    Key,
    Idx,
}

/// Apply post-response captures to the `EnvSet` (so a follow-up request can
/// `{{name}}` them). Returns the `(name, value)` pairs actually applied.
pub fn apply_captures(
    script: &Script,
    headers: &[(String, String)],
    body: &str,
    env: &mut EnvSet,
) -> Vec<(String, String)> {
    let parsed: Option<Value> = serde_json::from_str(body).ok();
    let mut applied = Vec::new();
    for hook in &script.post {
        let value = match hook {
            PostHook::CaptureJson { path, .. } => parsed
                .as_ref()
                .and_then(|v| resolve_json_path(v, path))
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                }),
            PostHook::CaptureHeader { header, .. } => headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(header))
                .map(|(_, v)| v.clone()),
        };
        if let Some(v) = value {
            let name = match hook {
                PostHook::CaptureJson { name, .. } | PostHook::CaptureHeader { name, .. } => {
                    name.clone()
                }
            };
            env.vars.insert(name.clone(), v.clone());
            applied.push((name, v));
        }
    }
    applied
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_directive_kinds() {
        let block = "# @set-header Authorization = Bearer abc\n\
                     # @set-env TRACE = xyz\n\
                     GET https://x/u\n\
                     # @assert status == 200\n\
                     # @assert header.Content-Type contains json\n\
                     # @assert json $.name == \"Alice\"\n\
                     # @assert json $.id is number\n\
                     # @assert body contains hello\n\
                     # @capture user_id = json $.id\n\
                     # @capture trace = header X-Request-Id\n";
        let s = parse(block);
        assert_eq!(s.pre.len(), 2);
        assert_eq!(s.assertions.len(), 5);
        assert_eq!(s.post.len(), 2);
        assert_eq!(
            s.pre[0],
            PreHook::SetHeader {
                name: "Authorization".into(),
                value: "Bearer abc".into()
            }
        );
        assert_eq!(
            s.assertions[0],
            Assertion::Status {
                op: CmpOp::Eq,
                value: 200
            }
        );
    }

    #[test]
    fn unparseable_directives_are_ignored() {
        let s = parse("# @assert wat\n# @capture = nope\n# not a directive\nGET /\n");
        assert!(s.is_empty());
    }

    #[test]
    fn run_assertions_pass_and_fail() {
        let block = "GET /\n\
                     # @assert status == 200\n\
                     # @assert status < 500\n\
                     # @assert header.content-type contains json\n\
                     # @assert body contains needle\n\
                     # @assert json $.id == 42\n\
                     # @assert json $.id is number\n\
                     # @assert json $.name == \"Bob\"\n";
        let s = parse(block);
        let headers = vec![("Content-Type".to_string(), "application/json".to_string())];
        let body = r#"{"id":42,"name":"Alice","haystack":"has a needle in it"}"#;
        let r = run_assertions(&s, 200, &headers, body);
        assert_eq!(r.len(), 7);
        assert!(r[0].passed); // status == 200
        assert!(r[1].passed); // status < 500
        assert!(r[2].passed); // content-type contains json
        assert!(r[3].passed); // body contains needle
        assert!(r[4].passed); // json $.id == 42
        assert!(r[5].passed); // json $.id is number
        assert!(!r[6].passed); // json $.name == "Bob"  (it's Alice)
        assert!(r[6].detail.as_deref().unwrap().contains("Alice"));
    }

    #[test]
    fn json_path_resolves_keys_and_indices() {
        let v: Value = serde_json::from_str(r#"{"a":{"b":[10,20,{"c":"deep"}]}}"#).unwrap();
        assert_eq!(
            resolve_json_path(&v, "$.a.b[1]").unwrap().as_i64(),
            Some(20)
        );
        assert_eq!(
            resolve_json_path(&v, "a.b[2].c").unwrap().as_str(),
            Some("deep")
        );
        assert!(resolve_json_path(&v, "$.a.x").is_none());
        assert!(resolve_json_path(&v, "$.a.b[9]").is_none());
    }

    #[test]
    fn pre_hooks_and_captures_round_trip_through_env() {
        let mut env = EnvSet::empty();
        env.vars.insert("TOKEN".into(), "tok123".into());
        let s = parse(
            "# @set-header Authorization = Bearer {{TOKEN}}\n\
             # @set-env REQ = {{$randomHex}}\n\
             GET https://x/u\n\
             # @capture id = json $.id\n\
             # @capture loc = header Location\n",
        );
        let mut req = Request {
            method: "GET".into(),
            url: "https://x/u".into(),
            headers: vec![("Authorization".into(), "stale".into())],
            body: None,
            insecure: false,
        };
        apply_pre(&s, &mut req, &mut env);
        assert_eq!(
            req.headers
                .iter()
                .find(|(k, _)| k == "Authorization")
                .unwrap()
                .1,
            "Bearer tok123"
        );
        assert_eq!(env.vars.get("REQ").unwrap().len(), 8); // {{$randomHex}} → 8 hex chars

        let headers = vec![("Location".to_string(), "/users/7".to_string())];
        let applied = apply_captures(&s, &headers, r#"{"id":7}"#, &mut env);
        assert_eq!(
            applied,
            vec![("id".into(), "7".into()), ("loc".into(), "/users/7".into())]
        );
        assert_eq!(env.vars.get("id").map(String::as_str), Some("7"));
    }
}
