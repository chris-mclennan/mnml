//! `mnml discover SPEC` — read an OpenAPI / Swagger spec (a local JSON file or a
//! URL) and generate one `.curl` stub per operation, under
//! `<out>/<tag-or-untagged>/<operationId-or-method-path>.curl`.
//!
//! Path parameters become `{{name}}` (plug them in via `.mnml/env/*.env`); an
//! operation with a `security` requirement gets `Authorization: Bearer {{TOKEN}}`.
//!
//! JSON request body handling (in preference order):
//!   1. `requestBody.content."application/json".example` — a single named
//!      example. Emitted as-is into the `--data-raw` payload of one stub.
//!   2. `requestBody.content."application/json".examples` — a map of NAMED
//!      example payloads. Each entry becomes its own stub file named
//!      `<operationId>.<exampleName>.curl` with the example's `.value` as
//!      the body. Used when a single endpoint accepts many variants
//!      (event APIs — `POST /admin/event` with 200+ event-type examples).
//!   3. If neither `example` nor `examples` exists but `schema` does, walk
//!      the schema (`$ref`-resolving, cycle-safe, depth-capped) and
//!      synthesize a plausible skeleton body from type / format / enum /
//!      default hints. Missing fields fall back to placeholder values
//!      ("string", 0, `false`, "2026-01-01T00:00:00Z", etc.).
//!
//! Ported from `archived/rqst/src/discover.rs` on 2026-07-09 after
//! `mnml sync-check` showed nearly all "drift" on a real tattle workspace
//! was this feature regression, not actual upstream API changes.

use std::collections::HashSet;
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
                .unwrap_or_else(|| {
                    // 2026-07-09 — rqst-parity fallback name. Lower-
                    // case method + hyphen + path so the produced
                    // filename matches what tattle-style workspaces
                    // already have on disk (`post-admin-event`, not
                    // `POST_admin_event`). See sanitize's comment.
                    sanitize(&format!("{}-{}", method.to_lowercase(), path))
                });
            // If the operation has a NAMED-examples map, emit one
            // stub per example — `<operationId>.<exampleName>.curl`
            // — with each example's `.value` as the body. Falls
            // through to the default (one stub, `example`/schema-
            // synthesized body) when the map is absent.
            let named = collect_named_examples(op);
            if named.is_empty() {
                let curl = render_curl(&base_url, path, method, op, &spec, None);
                let file = dir.join(format!("{file_base}.curl"));
                std::fs::write(&file, curl)
                    .map_err(|e| format!("write {}: {e}", file.display()))?;
                count += 1;
            } else {
                for named in named {
                    let safe = sanitize(&named.name);
                    let curl = render_curl(&base_url, path, method, op, &spec, Some(&named));
                    let file = dir.join(format!("{file_base}.{safe}.curl"));
                    std::fs::write(&file, curl)
                        .map_err(|e| format!("write {}: {e}", file.display()))?;
                    count += 1;
                }
            }
        }
    }
    Ok(count)
}

struct NamedExample {
    name: String,
    summary: Option<String>,
    body: String,
}

/// Extract every `requestBody.content."application/json".examples.<name>`
/// entry as `(name, summary, serialized body)`. Ported from rqst so a
/// single event-API endpoint with N named variants explodes into N stubs.
fn collect_named_examples(op: &Value) -> Vec<NamedExample> {
    let Some(json) = op
        .get("requestBody")
        .and_then(|rb| rb.get("content"))
        .and_then(|c| c.get("application/json"))
    else {
        return Vec::new();
    };
    let Some(examples) = json.get("examples").and_then(Value::as_object) else {
        return Vec::new();
    };
    examples
        .iter()
        .filter_map(|(key, ex)| {
            let value = ex.get("value")?;
            let summary = ex
                .get("summary")
                .and_then(Value::as_str)
                .map(str::to_string);
            let body = serde_json::to_string(value).ok()?;
            Some(NamedExample {
                name: key.clone(),
                summary,
                body,
            })
        })
        .collect()
}

fn is_http_method(m: &str) -> bool {
    matches!(
        m.to_ascii_lowercase().as_str(),
        "get" | "post" | "put" | "patch" | "delete" | "head" | "options"
    )
}

fn render_curl(
    base_url: &str,
    path: &str,
    method: &str,
    op: &Value,
    spec: &Value,
    named: Option<&NamedExample>,
) -> String {
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
    // Header block matches rqst's `render_curl` output byte-for-
    // byte: `accept` + `Authorization: Bearer {{TOKEN}}` on every
    // stub (rqst always emitted both; downstream users strip or
    // template the token via env). Lowercased `content-type` added
    // when the request has a body.
    let method_upper = method.to_uppercase();
    let mut out = String::new();
    // Header block: `# summary\n`, `# description-line-1\n`,
    // ..., `# example: <name>\n`, `# METHOD /path\n`. Matches
    // rqst's leading-block layout so downstream tools that greps
    // for the METHOD-marker line still work.
    if let Some(summary) = op.get("summary").and_then(Value::as_str) {
        out.push_str(&format!("# {summary}\n"));
    }
    if let Some(desc) = op.get("description").and_then(Value::as_str) {
        for line in desc.lines() {
            out.push_str(&format!("# {line}\n"));
        }
    }
    if let Some(n) = named
        && let Some(s) = &n.summary
    {
        out.push_str(&format!("# example: {s}\n"));
    }
    out.push_str(&format!("# {method_upper} {path}\n"));
    // Body decision: named-example wins, then plain `.example`,
    // then schema synthesis. Passed to the header-line logic so
    // -X inference matches curl's own defaults.
    let body = if let Some(n) = named {
        Some(n.body.clone())
    } else {
        op.get("requestBody")
            .and_then(|rb| rb.get("content"))
            .and_then(|c| c.get("application/json"))
            .and_then(|j| j.get("example"))
            .or_else(|| {
                op.get("parameters")
                    .and_then(Value::as_array)?
                    .iter()
                    .find(|p| p.get("in").and_then(Value::as_str) == Some("body"))?
                    .get("schema")?
                    .get("example")
            })
            .and_then(|ex| serde_json::to_string(ex).ok())
            .or_else(|| {
                let schema = op
                    .get("requestBody")
                    .and_then(|rb| rb.get("content"))
                    .and_then(|c| c.get("application/json"))
                    .and_then(|j| j.get("schema"))
                    .or_else(|| {
                        op.get("parameters")
                            .and_then(Value::as_array)?
                            .iter()
                            .find(|p| p.get("in").and_then(Value::as_str) == Some("body"))?
                            .get("schema")
                    })?;
                let mut visited: HashSet<String> = HashSet::new();
                let synthesized = synth_example(schema, spec, &mut visited, 0);
                serde_json::to_string(&synthesized).ok()
            })
    };
    let mut header_lines: Vec<String> = vec![
        "  -H 'accept: application/json'".to_string(),
        "  -H 'Authorization: Bearer {{TOKEN}}'".to_string(),
    ];
    if body.is_some() {
        header_lines.push("  -H 'content-type: application/json'".to_string());
    }
    out.push_str(&format!("curl '{base_url}{url_path}' \\\n"));
    // -X is omitted when curl can infer the method from the
    // shape: bare GET (no body), or POST with a body. Everything
    // else needs explicit -X (matches rqst).
    let needs_explicit_method =
        (method_upper != "GET" && body.is_none()) || (method_upper != "POST" && body.is_some());
    if needs_explicit_method {
        out.push_str(&format!("  -X {method_upper} \\\n"));
    }
    for (i, line) in header_lines.iter().enumerate() {
        if i + 1 < header_lines.len() || body.is_some() {
            out.push_str(line);
            out.push_str(" \\\n");
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    if let Some(b) = body {
        out.push_str(&format!("  --data-raw '{}'\n", b.replace('\'', "'\\''")));
    }
    out
}

/// Recursively synthesize an example JSON value from a schema.
/// Handles `$ref` (with a visited set to prevent cycles), `example`,
/// `default`, `type` (object/array/string/integer/number/boolean),
/// `format` hints (date-time / date / email / uuid), `enum` (first
/// value), and the composition keywords `allOf` / `oneOf` / `anyOf`
/// (takes the first branch). Depth capped at 5 to keep pathological
/// deeply-recursive specs from blowing the stack.
fn synth_example(schema: &Value, spec: &Value, visited: &mut HashSet<String>, depth: u32) -> Value {
    if depth > 5 {
        return Value::Null;
    }
    if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
        if visited.contains(r) {
            return Value::Null;
        }
        visited.insert(r.to_string());
        if let Some(resolved) = resolve_ref(spec, r) {
            return synth_example(resolved, spec, visited, depth + 1);
        }
        return Value::Null;
    }
    if let Some(example) = schema.get("example") {
        return example.clone();
    }
    if let Some(default) = schema.get("default") {
        return default.clone();
    }
    let ty = schema.get("type").and_then(Value::as_str).unwrap_or("");
    match ty {
        "object" => {
            let mut obj = serde_json::Map::new();
            if let Some(props) = schema.get("properties").and_then(Value::as_object) {
                for (k, v) in props {
                    obj.insert(k.clone(), synth_example(v, spec, visited, depth + 1));
                }
            }
            Value::Object(obj)
        }
        "array" => {
            let item = schema
                .get("items")
                .map(|i| synth_example(i, spec, visited, depth + 1))
                .unwrap_or(Value::Null);
            Value::Array(vec![item])
        }
        "string" => {
            if let Some(fmt) = schema.get("format").and_then(Value::as_str) {
                Value::String(match fmt {
                    "date-time" => "2026-01-01T00:00:00Z".to_string(),
                    "date" => "2026-01-01".to_string(),
                    "email" => "user@example.com".to_string(),
                    "uuid" => "00000000-0000-0000-0000-000000000000".to_string(),
                    _ => "string".to_string(),
                })
            } else if let Some(en) = schema.get("enum").and_then(Value::as_array) {
                en.first()
                    .cloned()
                    .unwrap_or_else(|| Value::String("string".into()))
            } else {
                Value::String("string".to_string())
            }
        }
        "integer" => Value::Number(0.into()),
        "number" => Value::Number(serde_json::Number::from_f64(0.0).unwrap()),
        "boolean" => Value::Bool(false),
        _ => {
            // Fallback: composition keywords. Take the first branch.
            for k in &["allOf", "oneOf", "anyOf"] {
                if let Some(arr) = schema.get(*k).and_then(Value::as_array)
                    && let Some(first) = arr.first()
                {
                    return synth_example(first, spec, visited, depth + 1);
                }
            }
            Value::Null
        }
    }
}

/// Resolve a local `#/components/schemas/Foo` reference. Only local
/// refs are supported — external `spec.yaml#/…` refs return `None`.
fn resolve_ref<'a>(spec: &'a Value, r: &str) -> Option<&'a Value> {
    let r = r.strip_prefix("#/")?;
    let mut cur = spec;
    for part in r.split('/') {
        cur = cur.get(part)?;
    }
    Some(cur)
}

fn sanitize(s: &str) -> String {
    // 2026-07-09 — align with the rqst convention (hyphens) so
    // existing tattle-style workspaces don't see cosmetic drift
    // (`post-events-deferred-clean.curl` — old — vs
    // `post_events_deferred_clean.curl` — mnml pre-port). Also
    // collapses runs of hyphens so `Get/By Id` doesn't produce
    // `Get--By--Id`. Matches
    // `archived/rqst/src/discover.rs::sanitize` byte-for-byte.
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
            out.push(c);
        } else {
            out.push('-');
        }
    }
    let collapsed: String = out
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if collapsed.is_empty() {
        "op".to_string()
    } else {
        collapsed
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
        // 2026-07-09 — rqst-parity: POST-with-body doesn't need
        // explicit `-X POST` (curl infers it from the presence of
        // --data-raw). Assert its ABSENCE.
        assert!(
            !post.contains("-X POST"),
            "POST+body shouldn't need -X: {post}"
        );
        assert!(post.contains(r#"--data-raw '{"name":"Alice"}'"#));
    }

    #[test]
    fn named_examples_map_expands_to_one_file_per_example() {
        // Regression lock for the tattle-workspace drift issue —
        // an event API endpoint with a `.examples` map (one payload
        // per event type) must produce ONE stub file per example.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("events.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/admin/event": {
                  "post": {
                    "operationId": "TriggerEvent",
                    "tags": ["Admin"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "examples": {
                            "OrderCreated": {
                              "summary": "Order Created",
                              "value": { "eventName": "OrderCreated", "data": { "id": 1 } }
                            },
                            "OrderCancelled": {
                              "value": { "eventName": "OrderCancelled", "data": { "id": 2 } }
                            }
                          }
                        }
                      }
                    }
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
        assert_eq!(n, 2, "should emit one stub per named example");
        let created =
            std::fs::read_to_string(out.join("Admin/TriggerEvent.OrderCreated.curl")).unwrap();
        // serde_json sorts object keys alphabetically on
        // serialization — assert on the sorted form.
        assert!(
            created.contains(r#"--data-raw '{"data":{"id":1},"eventName":"OrderCreated"}'"#),
            "OrderCreated body missing: {created}"
        );
        assert!(
            created.contains("# example: Order Created"),
            "example summary comment missing: {created}"
        );
        assert!(std::fs::exists(out.join("Admin/TriggerEvent.OrderCancelled.curl")).unwrap());
    }

    #[test]
    fn schema_synthesis_fills_body_when_no_example_provided() {
        // Regression lock for the "operation has a body schema but
        // no `example` field" case. Prior version wrote a TODO
        // placeholder — now we walk the schema and produce plausible
        // types + format-driven placeholder strings.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/things": {
                  "post": {
                    "operationId": "CreateThing",
                    "tags": ["things"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "properties": {
                              "name": { "type": "string" },
                              "count": { "type": "integer" },
                              "createdAt": { "type": "string", "format": "date-time" },
                              "id": { "type": "string", "format": "uuid" }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }"#,
        )
        .unwrap();
        let out = dir.path().join("o");
        run(&Options {
            spec: spec.to_string_lossy().into_owned(),
            out: out.clone(),
            base_url: None,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("things/CreateThing.curl")).unwrap();
        assert!(
            body.contains(r#""name":"string""#),
            "synthesized name: {body}"
        );
        assert!(body.contains(r#""count":0"#), "synthesized count: {body}");
        assert!(
            body.contains(r#""createdAt":"2026-01-01T00:00:00Z""#),
            "date-time format: {body}"
        );
        assert!(
            body.contains(r#""id":"00000000-0000-0000-0000-000000000000""#),
            "uuid format: {body}"
        );
    }

    #[test]
    fn schema_synthesis_resolves_local_refs_and_survives_cycles() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        // `Node` refers to itself via `.child` — walker must not
        // recurse infinitely; visited-set + depth cap catch it.
        std::fs::write(
            &spec,
            r##"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "components": {
                "schemas": {
                  "Node": {
                    "type": "object",
                    "properties": {
                      "id": { "type": "integer" },
                      "child": { "$ref": "#/components/schemas/Node" }
                    }
                  }
                }
              },
              "paths": {
                "/nodes": {
                  "post": {
                    "operationId": "PostNode",
                    "tags": ["nodes"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": { "$ref": "#/components/schemas/Node" }
                        }
                      }
                    }
                  }
                }
              }
            }"##,
        )
        .unwrap();
        let out = dir.path().join("o");
        run(&Options {
            spec: spec.to_string_lossy().into_owned(),
            out: out.clone(),
            base_url: None,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("nodes/PostNode.curl")).unwrap();
        // "id" must be filled; "child" nullifies at the cycle break.
        assert!(body.contains(r#""id":0"#), "cycle-broken body: {body}");
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
        // 2026-07-09 — hyphens (matches rqst-parity `sanitize`).
        let f = std::fs::read_to_string(out.join("untagged/get-ping.curl")).unwrap();
        assert!(f.contains("curl 'https://x.test/api/ping'"), "{f}");
    }
}
