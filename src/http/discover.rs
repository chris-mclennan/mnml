//! `mnml discover SPEC` — read an OpenAPI / Swagger spec (a local JSON file or a
//! URL) and generate one `.curl` stub per operation, under
//! `<out>/<tag-or-untagged>/<operationId-or-method-path>.curl`.
//!
//! Path parameters become `{{name}}` (plug them in via `.mnml/env/*.env`); an
//! operation with a `security` requirement gets `Authorization: Bearer {{TOKEN}}`;
//! a JSON request body is filled from `requestBody.content."application/json".
//! example` if the spec provides one. Schema-driven example synthesis and the
//! named-`examples` map are intentionally out of scope.

use std::path::PathBuf;

use serde_json::Value;

pub struct Options {
    /// Local file path or `http(s)://…` URL of the spec.
    pub spec: String,
    /// Directory to write the `.curl` tree into.
    pub out: PathBuf,
    /// Overrides the spec's `servers[0].url` (falls back to `{{BASE_URL}}`).
    pub base_url: Option<String>,
}

/// Returns the number of `.curl` files written.
pub fn run(opts: &Options) -> Result<usize, String> {
    let text = if opts.spec.starts_with("http://") || opts.spec.starts_with("https://") {
        let req = super::Request {
            method: "GET".to_string(),
            url: opts.spec.clone(),
            headers: vec![("accept".to_string(), "application/json".to_string())],
            body: None,
        };
        super::send(&req).and_then(|r| {
            if (200..300).contains(&r.status) {
                Ok(r.body)
            } else {
                Err(format!("fetching spec: HTTP {}", r.status))
            }
        })?
    } else {
        std::fs::read_to_string(&opts.spec).map_err(|e| format!("read {}: {e}", opts.spec))?
    };
    let spec: Value = serde_json::from_str(&text).map_err(|e| format!("parse spec: {e}"))?;

    let base_url = opts
        .base_url
        .clone()
        .or_else(|| {
            spec.get("servers")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(|s| s.get("url"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        // Swagger 2.0: host + basePath.
        .or_else(|| {
            let host = spec.get("host").and_then(Value::as_str)?;
            let base = spec.get("basePath").and_then(Value::as_str).unwrap_or("");
            let scheme = spec
                .get("schemes")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(Value::as_str)
                .unwrap_or("https");
            Some(format!("{scheme}://{host}{base}"))
        })
        .unwrap_or_else(|| "{{BASE_URL}}".to_string());
    let base_url = base_url.trim_end_matches('/').to_string();

    let paths = spec
        .get("paths")
        .and_then(Value::as_object)
        .ok_or("spec has no `paths`")?;
    std::fs::create_dir_all(&opts.out).map_err(|e| format!("mkdir {}: {e}", opts.out.display()))?;

    let mut count = 0usize;
    for (path, methods) in paths {
        let Some(methods) = methods.as_object() else {
            continue;
        };
        for (method, op) in methods {
            if !is_http_method(method) {
                continue;
            }
            let folder = op
                .get("tags")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(Value::as_str)
                .map(sanitize)
                .unwrap_or_else(|| "untagged".to_string());
            let dir = opts.out.join(&folder);
            std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
            let file_base = op
                .get("operationId")
                .and_then(Value::as_str)
                .map(sanitize)
                .unwrap_or_else(|| sanitize(&format!("{}_{}", method, path.trim_matches('/'))));
            let curl = render_curl(&base_url, path, method, op);
            let file = dir.join(format!("{file_base}.curl"));
            std::fs::write(&file, curl).map_err(|e| format!("write {}: {e}", file.display()))?;
            count += 1;
        }
    }
    Ok(count)
}

fn is_http_method(m: &str) -> bool {
    matches!(
        m.to_ascii_lowercase().as_str(),
        "get" | "post" | "put" | "patch" | "delete" | "head" | "options"
    )
}

fn render_curl(base_url: &str, path: &str, method: &str, op: &Value) -> String {
    // Path params `{id}` → `{{id}}`.
    let mut url_path = String::new();
    let mut in_brace = false;
    for c in path.chars() {
        match c {
            '{' => {
                in_brace = true;
                url_path.push_str("{{");
            }
            '}' if in_brace => {
                in_brace = false;
                url_path.push_str("}}");
            }
            other => url_path.push(other),
        }
    }
    let mut out = String::new();
    if let Some(summary) = op.get("summary").and_then(Value::as_str) {
        out.push_str(&format!("# {summary}\n"));
    } else if let Some(desc) = op.get("description").and_then(Value::as_str) {
        out.push_str(&format!("# {}\n", desc.lines().next().unwrap_or("")));
    }
    out.push_str(&format!("curl '{base_url}{url_path}'"));
    if !method.eq_ignore_ascii_case("get") {
        out.push_str(&format!(" \\\n  -X {}", method.to_uppercase()));
    }
    // Bearer auth if the operation declares a security requirement.
    let needs_auth = op
        .get("security")
        .and_then(Value::as_array)
        .map(|a| !a.is_empty())
        .unwrap_or(false);
    if needs_auth {
        out.push_str(" \\\n  -H 'Authorization: Bearer {{TOKEN}}'");
    }
    // JSON body from a provided example.
    let example = op
        .get("requestBody")
        .and_then(|rb| rb.get("content"))
        .and_then(|c| c.get("application/json"))
        .and_then(|j| j.get("example"))
        .or_else(|| {
            // Swagger 2.0: body parameter with a schema example.
            op.get("parameters")
                .and_then(Value::as_array)?
                .iter()
                .find(|p| p.get("in").and_then(Value::as_str) == Some("body"))?
                .get("schema")?
                .get("example")
        });
    if let Some(ex) = example {
        out.push_str(" \\\n  -H 'Content-Type: application/json'");
        let body = serde_json::to_string(ex).unwrap_or_else(|_| "{}".to_string());
        out.push_str(&format!(
            " \\\n  --data-raw '{}'",
            body.replace('\'', "'\\''")
        ));
    } else if !method.eq_ignore_ascii_case("get") && op.get("requestBody").is_some() {
        out.push_str(" \\\n  -H 'Content-Type: application/json'");
        out.push_str(" \\\n  --data-raw '{}'  # TODO: fill in the request body");
    }
    out.push('\n');
    out
}

fn sanitize(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = cleaned.trim_matches('_');
    if trimmed.is_empty() {
        "op".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_one_curl_per_operation() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("api.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com/v1" }],
              "paths": {
                "/users/{id}": {
                  "get": { "tags": ["users"], "operationId": "getUser", "summary": "Get a user" },
                  "delete": { "tags": ["users"], "operationId": "deleteUser", "security": [{ "bearer": [] }] }
                },
                "/users": {
                  "post": {
                    "tags": ["users"],
                    "operationId": "createUser",
                    "requestBody": { "content": { "application/json": { "example": { "name": "Alice" } } } }
                  }
                }
              }
            }"#,
        )
        .unwrap();
        let out = dir.path().join("out");
        let n = run(&Options {
            spec: spec.to_string_lossy().into_owned(),
            out: out.clone(),
            base_url: None,
        })
        .unwrap();
        assert_eq!(n, 3);
        let get = std::fs::read_to_string(out.join("users/getUser.curl")).unwrap();
        assert!(get.contains("curl 'https://api.example.com/v1/users/{{id}}'"));
        assert!(get.contains("# Get a user"));
        let del = std::fs::read_to_string(out.join("users/deleteUser.curl")).unwrap();
        assert!(del.contains("-X DELETE"));
        assert!(del.contains("Authorization: Bearer {{TOKEN}}"));
        let post = std::fs::read_to_string(out.join("users/createUser.curl")).unwrap();
        assert!(post.contains("-X POST"));
        assert!(post.contains(r#"--data-raw '{"name":"Alice"}'"#));
    }

    #[test]
    fn swagger2_host_basepath_and_untagged() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{ "swagger": "2.0", "host": "x.test", "basePath": "/api", "schemes": ["https"],
                "paths": { "/ping": { "get": {} } } }"#,
        )
        .unwrap();
        let out = dir.path().join("o");
        run(&Options {
            spec: spec.to_string_lossy().into_owned(),
            out: out.clone(),
            base_url: None,
        })
        .unwrap();
        let f = std::fs::read_to_string(out.join("untagged/get_ping.curl")).unwrap();
        assert!(f.contains("curl 'https://x.test/api/ping'"), "{f}");
    }
}
