//! Response-body JSON schema validation. Sidecar pattern:
//!
//! ```text
//! requests/users.curl          ← the request
//! requests/users.schema.json   ← validated against the response body
//! ```
//!
//! After every `:http.send`, if a sidecar exists, the response body
//! is parsed as JSON and validated against the schema. The result
//! lands on `ResponseView.schema_result` and shows as a one-line
//! footer in the Response view (✓ valid / ✗ N errors). The full
//! error list is reachable via `:http.show_schema_errors`.
//!
//! Resolution order, for source path `foo.<ext>`:
//!   1. `foo.schema.json`
//!   2. `foo.<ext>.schema.json` (so multi-suffix files like
//!      `users.http` can have `users.http.schema.json`)
//!
//! v1: a single schema per source file. v2 (per-block schemas for
//! multi-block `.http` files via `foo.<block>.schema.json`) is
//! queued — see TODO.md.
//!
//! v1 only validates JSON response bodies. Non-JSON bodies surface
//! `SchemaStatus::NotJson` so the footer can say so honestly
//! instead of silently passing.

use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SchemaStatus {
    /// Sidecar exists, body parses, validates.
    Valid,
    /// Sidecar exists, body parses, validation found errors.
    Invalid,
    /// No `*.schema.json` sibling found.
    NoSidecar,
    /// Sidecar found but couldn't be read.
    ReadError(String),
    /// Sidecar isn't a valid JSON schema.
    SchemaParseError(String),
    /// Body isn't JSON (couldn't be parsed for validation).
    NotJson,
}

#[derive(Clone, Debug)]
pub struct SchemaResult {
    pub status: SchemaStatus,
    /// Concrete error strings produced by the validator. Empty for
    /// `Valid` / `NoSidecar`; populated for `Invalid`.
    pub errors: Vec<String>,
    /// The sidecar path that was used (if any).
    pub schema_path: Option<PathBuf>,
}

impl SchemaResult {
    pub fn no_sidecar() -> Self {
        Self {
            status: SchemaStatus::NoSidecar,
            errors: Vec::new(),
            schema_path: None,
        }
    }
}

/// Look for a sibling `<stem>.schema.json` next to the request file.
/// Tries two stem forms — see module docs.
pub fn resolve_sidecar(source_path: &Path) -> Option<PathBuf> {
    let parent = source_path.parent()?;
    let file_name = source_path.file_name()?.to_str()?;

    // Try `<stem>.schema.json` first (strip the final extension).
    if let Some(stem) = source_path.file_stem().and_then(|s| s.to_str()) {
        let cand = parent.join(format!("{stem}.schema.json"));
        if cand.is_file() {
            return Some(cand);
        }
    }

    // Then `<filename>.schema.json` (full filename with extension).
    let cand = parent.join(format!("{file_name}.schema.json"));
    if cand.is_file() {
        return Some(cand);
    }

    None
}

/// Validate `body` against the schema at `schema_path`. Returns a
/// fully-populated `SchemaResult` for any outcome — never panics on
/// malformed schemas / non-JSON bodies.
pub fn validate_body(body: &str, schema_path: &Path) -> SchemaResult {
    let schema_text = match std::fs::read_to_string(schema_path) {
        Ok(s) => s,
        Err(e) => {
            return SchemaResult {
                status: SchemaStatus::ReadError(e.to_string()),
                errors: Vec::new(),
                schema_path: Some(schema_path.to_path_buf()),
            };
        }
    };
    let schema_val: serde_json::Value = match serde_json::from_str(&schema_text) {
        Ok(v) => v,
        Err(e) => {
            return SchemaResult {
                status: SchemaStatus::SchemaParseError(e.to_string()),
                errors: Vec::new(),
                schema_path: Some(schema_path.to_path_buf()),
            };
        }
    };
    let body_val: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => {
            return SchemaResult {
                status: SchemaStatus::NotJson,
                errors: Vec::new(),
                schema_path: Some(schema_path.to_path_buf()),
            };
        }
    };

    let validator = match jsonschema::validator_for(&schema_val) {
        Ok(v) => v,
        Err(e) => {
            return SchemaResult {
                status: SchemaStatus::SchemaParseError(e.to_string()),
                errors: Vec::new(),
                schema_path: Some(schema_path.to_path_buf()),
            };
        }
    };

    let errors: Vec<String> = validator
        .iter_errors(&body_val)
        .map(|e| {
            // jsonschema's Display is "<message> at <pointer>" — the
            // pointer (instance_path) is the JSON path inside the body
            // where the failure occurred. Prefix with that path so the
            // error list scans cleanly.
            let path = e.instance_path.to_string();
            if path.is_empty() {
                e.to_string()
            } else {
                format!("{path}: {e}")
            }
        })
        .collect();

    let status = if errors.is_empty() {
        SchemaStatus::Valid
    } else {
        SchemaStatus::Invalid
    };
    SchemaResult {
        status,
        errors,
        schema_path: Some(schema_path.to_path_buf()),
    }
}

/// Convenience: resolve sidecar + validate in one call. Returns
/// `NoSidecar` if there's no schema next to the source file.
pub fn validate_for(source_path: Option<&Path>, body: &str) -> SchemaResult {
    let Some(src) = source_path else {
        return SchemaResult::no_sidecar();
    };
    let Some(schema) = resolve_sidecar(src) else {
        return SchemaResult::no_sidecar();
    };
    validate_body(body, &schema)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn write(dir: &Path, name: &str, content: &str) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, content).unwrap();
        p
    }

    #[test]
    fn no_sidecar_returns_nosidecar() {
        let r = validate_for(None, "{}");
        assert_eq!(r.status, SchemaStatus::NoSidecar);
    }

    #[test]
    fn resolves_stem_dot_schema_json() {
        let d = tempdir().unwrap();
        let src = write(d.path(), "users.curl", "GET /users");
        write(d.path(), "users.schema.json", r#"{"type":"object"}"#);
        let found = resolve_sidecar(&src);
        assert_eq!(found.unwrap().file_name().unwrap(), "users.schema.json");
    }

    #[test]
    fn valid_body() {
        let d = tempdir().unwrap();
        let src = write(d.path(), "users.curl", "GET /users");
        write(
            d.path(),
            "users.schema.json",
            r#"{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}"#,
        );
        let r = validate_for(Some(&src), r#"{"name":"alice"}"#);
        assert_eq!(r.status, SchemaStatus::Valid);
        assert!(r.errors.is_empty());
    }

    #[test]
    fn invalid_body_reports_errors() {
        let d = tempdir().unwrap();
        let src = write(d.path(), "users.curl", "GET /users");
        write(
            d.path(),
            "users.schema.json",
            r#"{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}"#,
        );
        let r = validate_for(Some(&src), r#"{"name":42}"#);
        assert_eq!(r.status, SchemaStatus::Invalid);
        assert!(!r.errors.is_empty());
    }

    #[test]
    fn non_json_body_reported_as_not_json() {
        let d = tempdir().unwrap();
        let src = write(d.path(), "users.curl", "GET /users");
        write(d.path(), "users.schema.json", r#"{"type":"object"}"#);
        let r = validate_for(Some(&src), "<html>not json</html>");
        assert_eq!(r.status, SchemaStatus::NotJson);
    }

    #[test]
    fn malformed_schema_surfaces_parse_error() {
        let d = tempdir().unwrap();
        let src = write(d.path(), "users.curl", "GET /users");
        write(d.path(), "users.schema.json", "{ not json");
        let r = validate_for(Some(&src), r#"{"name":"x"}"#);
        assert!(matches!(r.status, SchemaStatus::SchemaParseError(_)));
    }
}
