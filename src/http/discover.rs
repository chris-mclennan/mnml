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
    /// When `true`, walk each generated stub's JSON body and swap
    /// ISO 8601 timestamp strings for `{{$isoTimestamp}}` and
    /// lowercase-UUID strings for `{{$uuid}}`. Kills swagger-side
    /// timestamp/UUID churn — every re-sync produces byte-identical
    /// output modulo real API changes.
    /// 2026-07-09 Tier 1 of the dynamic-realistic roadmap.
    pub normalize: bool,
    /// When `true`, emit additional edge-case variants alongside
    /// the happy-path stub — `<opId>.edge-min.curl` (minLength
    /// strings, minimum numbers, non-first enum values) and
    /// `<opId>.edge-max.curl` (maxLength strings, maximum numbers,
    /// last enum values). Skipped for operations without a JSON
    /// body schema. Tier 7 of the dynamic-realistic roadmap.
    pub edge_cases: bool,
    /// When `false` (default), skip writing files that already exist —
    /// prevents silent overwrite of hand-edits. `true` restores the
    /// old always-overwrite behavior. api-workflow round-9 SEV-2
    /// 2026-07-11.
    pub force: bool,
}

/// Returns `(written, skipped)` — files skipped because they already
/// exist and `--force` wasn't set. api-workflow round-9 SEV-2
/// 2026-07-11 — was Result<usize, String> (only wrote count).
pub fn run(opts: &Options) -> Result<(usize, usize), String> {
    let text = if opts.spec.starts_with("http://") || opts.spec.starts_with("https://") {
        let req = super::Request {
            method: "GET".to_string(),
            url: opts.spec.clone(),
            headers: vec![("accept".to_string(), "application/json".to_string())],
            body: None,
            insecure: false,
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

    // Tier 6 — track login-shaped endpoints per tag and every
    // request file we write, so a `.chain.json` template per tag
    // (containing a login endpoint) can be emitted after the main
    // loop as a starter chain.
    let mut count = 0usize;
    let mut skipped = 0usize;
    let mut login_by_tag: std::collections::BTreeMap<String, ChainStep> =
        std::collections::BTreeMap::new();
    let mut requests_by_tag: std::collections::BTreeMap<String, Vec<ChainStep>> =
        std::collections::BTreeMap::new();
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
            let hints = login_extract_hints(path, &method.to_uppercase(), op, &spec);
            let named = collect_named_examples(op);
            if named.is_empty() {
                let curl = render_curl(
                    &base_url,
                    path,
                    method,
                    op,
                    &spec,
                    None,
                    opts.normalize,
                    None,
                );
                let file = dir.join(format!("{file_base}.curl"));
                // api-round-14 SEV-1 2026-07-16 — `count += 1` used
                // to run unconditionally after the if/else, so a
                // re-run against unchanged stubs reported "wrote N"
                // for N files it had actually skipped. The chain-
                // step / login-index side-effects still fire on
                // skip (they need the file's chain position even
                // when the file itself already exists); only the
                // "wrote" counter needs to gate on the write path.
                if !opts.force && file.exists() {
                    skipped += 1;
                } else {
                    std::fs::write(&file, curl)
                        .map_err(|e| format!("write {}: {e}", file.display()))?;
                    count += 1;
                }
                let rel = format!("{folder}/{file_base}.curl");
                let step = ChainStep {
                    request: rel,
                    extract: hints.clone(),
                };
                if !hints.is_empty() {
                    login_by_tag.entry(folder.clone()).or_insert(step.clone());
                }
                requests_by_tag
                    .entry(folder.clone())
                    .or_default()
                    .push(step);
                // Tier 7 edge-case variants — only when the operation
                // has a body schema and opts.edge_cases is on.
                if opts.edge_cases && has_body_schema(op) {
                    for (label, edge) in &[("edge-min", EdgeCase::Min), ("edge-max", EdgeCase::Max)]
                    {
                        let curl = render_curl(
                            &base_url,
                            path,
                            method,
                            op,
                            &spec,
                            None,
                            opts.normalize,
                            Some(*edge),
                        );
                        let file = dir.join(format!("{file_base}.{label}.curl"));
                        if !opts.force && file.exists() {
                            skipped += 1;
                        } else {
                            std::fs::write(&file, curl)
                                .map_err(|e| format!("write {}: {e}", file.display()))?;
                            count += 1;
                        }
                    }
                }
            } else {
                for named in named {
                    let safe = sanitize(&named.name);
                    let curl = render_curl(
                        &base_url,
                        path,
                        method,
                        op,
                        &spec,
                        Some(&named),
                        opts.normalize,
                        None,
                    );
                    let file = dir.join(format!("{file_base}.{safe}.curl"));
                    // api-round-14 SEV-1 2026-07-16 — same double-
                    // count fix as the un-named branch above.
                    if !opts.force && file.exists() {
                        skipped += 1;
                    } else {
                        std::fs::write(&file, curl)
                            .map_err(|e| format!("write {}: {e}", file.display()))?;
                        count += 1;
                    }
                    let rel = format!("{folder}/{file_base}.{safe}.curl");
                    let step = ChainStep {
                        request: rel,
                        extract: hints.clone(),
                    };
                    if !hints.is_empty() {
                        login_by_tag.entry(folder.clone()).or_insert(step.clone());
                    }
                    requests_by_tag
                        .entry(folder.clone())
                        .or_default()
                        .push(step);
                }
            }
        }
    }
    // Tier 6 — emit `.chain.json` starters per tag with a login
    // endpoint. Chain lives at `<opts.out>/chains/<tag>-flow.chain.json`
    // and contains the login step plus one representative non-login
    // request from the same tag (picked deterministically). Users
    // move to `.mnml/chains/` (or run sync, which handles the move
    // for them) and edit from there.
    emit_chain_templates(&opts.out, &login_by_tag, &requests_by_tag)?;
    Ok((count, skipped))
}

#[derive(Clone)]
struct ChainStep {
    request: String,
    extract: Vec<(String, String)>,
}

fn emit_chain_templates(
    out: &std::path::Path,
    login_by_tag: &std::collections::BTreeMap<String, ChainStep>,
    requests_by_tag: &std::collections::BTreeMap<String, Vec<ChainStep>>,
) -> Result<(), String> {
    if login_by_tag.is_empty() {
        return Ok(());
    }
    // Chains live at the top of `opts.out`. Steps reference
    // `<tag>/<file>.curl` — chain::resolve_request_path walks
    // relative to the chain's own dir first, so `<out>/<tag>/<file>`
    // resolves cleanly without needing `..` prefixes.
    for (tag, login) in login_by_tag {
        let mut steps: Vec<Value> = Vec::new();
        steps.push(step_to_json(login));
        if let Some(list) = requests_by_tag.get(tag)
            && let Some(other) = list.iter().find(|s| s.request != login.request)
        {
            let mut step = other.clone();
            step.extract.clear();
            steps.push(step_to_json(&step));
        }
        let file = out.join(format!("{tag}-flow.chain.json"));
        // Never clobber a user's chain — discover is a generator,
        // not a source-of-truth for chains they've hand-edited.
        if file.exists() {
            continue;
        }
        let text = serde_json::to_string_pretty(&Value::Array(steps))
            .map_err(|e| format!("serialize chain: {e}"))?;
        std::fs::write(&file, text).map_err(|e| format!("write {}: {e}", file.display()))?;
    }
    Ok(())
}

fn has_body_schema(op: &Value) -> bool {
    op.get("requestBody")
        .and_then(|rb| rb.get("content"))
        .and_then(|c| c.get("application/json"))
        .and_then(|j| j.get("schema"))
        .is_some()
        || op
            .get("parameters")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter().any(|p| {
                    p.get("in").and_then(Value::as_str) == Some("body") && p.get("schema").is_some()
                })
            })
            .unwrap_or(false)
}

fn step_to_json(step: &ChainStep) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert("request".to_string(), Value::String(step.request.clone()));
    if !step.extract.is_empty() {
        let mut ex = serde_json::Map::new();
        for (var, path) in &step.extract {
            ex.insert(var.clone(), Value::String(format!("${path}")));
        }
        obj.insert("extract".to_string(), Value::Object(ex));
    }
    Value::Object(obj)
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

/// Replace ISO 8601 timestamps and lowercase UUIDs found inside a
/// JSON-body string with the corresponding `{{$dynamic}}` template
/// vars. Applied after body serialization so both example-derived
/// and schema-synthesized bodies get the treatment.
///
/// Rules (Tier 1, 2026-07-09):
/// - ISO 8601: `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}` optional `.fraction`,
///   optional `Z` or `±HH:MM`. Distinctive enough that false positives
///   on non-timestamp strings are near-zero.
/// - UUID: 8-4-4-4-12 lowercase hex. Uppercase excluded to avoid
///   matching user-defined constants that happen to be UUID-shaped.
/// - Preserves the surrounding JSON string quotes (`"..."`) so the
///   result still parses as valid JSON.
/// Public shim over `normalize_dynamic_values` so the palette-side
/// `http.regenerate_body` command can reuse the exact same detection
/// as the discover-side sync normalization.
pub fn normalize_dynamic_values_public(body: &str) -> String {
    normalize_dynamic_values(body)
}

fn normalize_dynamic_values(body: &str) -> String {
    use std::sync::OnceLock;
    static ISO_RX: OnceLock<regex::Regex> = OnceLock::new();
    static UUID_RX: OnceLock<regex::Regex> = OnceLock::new();
    let iso = ISO_RX.get_or_init(|| {
        // JSON strings only — bounded by quotes — so we don't
        // accidentally rewrite the same span twice. `?:` on the
        // fractional-seconds group so it's optional.
        regex::Regex::new(
            r#""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?""#,
        )
        .expect("ISO regex")
    });
    let uuid = UUID_RX.get_or_init(|| {
        regex::Regex::new(r#""[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}""#)
            .expect("UUID regex")
    });
    // `NoExpand` — otherwise `$uuid` / `$isoTimestamp` in the
    // replacement string would be treated as named-capture backrefs
    // (regex crate convention) and resolve to empty strings.
    let step1 = iso.replace_all(body, regex::NoExpand(r#""{{$isoTimestamp}}""#));
    let step2 = uuid.replace_all(&step1, regex::NoExpand(r#""{{$uuid}}""#));
    step2.into_owned()
}

/// Edge-case bias for body synthesis. `None` = happy path (Tier 2/3
/// defaults). `Some(EdgeCase::Min)` = boundary-minimum picks;
/// `Some(EdgeCase::Max)` = boundary-maximum picks.
#[derive(Copy, Clone, PartialEq, Eq)]
pub(crate) enum EdgeCase {
    Min,
    Max,
}

#[allow(clippy::too_many_arguments)]
fn render_curl(
    base_url: &str,
    path: &str,
    method: &str,
    op: &Value,
    spec: &Value,
    named: Option<&NamedExample>,
    normalize: bool,
    edge: Option<EdgeCase>,
) -> String {
    // Path params: `{id}` → `{{id}}`, plus Tier 4 well-known-ID
    // upgrade. Buffer the param name between `{` and `}`, then
    // check if it matches an env-var rule (`merchantId` →
    // `MERCHANT_ID`, `userId` → `USER_ID`, etc). When it does,
    // emit the env-var form so users tune once via
    // `.mnml/env/dev.env` instead of hand-editing.
    let mut url_path = String::new();
    let mut buf = String::new();
    let mut in_brace = false;
    for c in path.chars() {
        match c {
            '{' => {
                in_brace = true;
                buf.clear();
            }
            '}' if in_brace => {
                in_brace = false;
                let name = if let Some(env) = crate::http::faker::id_env_var(&buf) {
                    env.to_string()
                } else {
                    buf.clone()
                };
                url_path.push_str(&format!("{{{{{name}}}}}"));
                buf.clear();
            }
            other if in_brace => buf.push(other),
            other => url_path.push(other),
        }
    }
    // Query + header params from the swagger `parameters` array
    // (2026-07-09 Tier 5). Required ones become part of the curl
    // — `?filter={{filter}}` in the URL, `-H '<name>: {{value}}'`
    // in the header block. Optional ones surface as commented
    // hints below the curl so users can uncomment when needed
    // without hunting the swagger.
    let (required_query, optional_query, required_headers, optional_headers) =
        collect_query_and_header_params(op, spec);
    if !required_query.is_empty() {
        url_path.push('?');
        for (i, (name, value)) in required_query.iter().enumerate() {
            if i > 0 {
                url_path.push('&');
            }
            url_path.push_str(name);
            url_path.push('=');
            url_path.push_str(value);
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
    // Tier 6 — auto extract hints for login-shaped endpoints so
    // chains can pick up an access token without the user reading
    // the response schema. Rendered as `# extract: VAR=$.path`
    // lines directly after the METHOD marker; `.chain.json` steps
    // read the same syntax verbatim (see `chain::parse` for the
    // parse side) and users can lift these into a chain step
    // uncommented.
    for (var, path_expr) in login_extract_hints(path, &method_upper, op, spec) {
        out.push_str(&format!("# extract: {var}=${path_expr}\n"));
    }
    // Body decision: named-example wins, then plain `.example`,
    // then schema synthesis. Passed to the header-line logic so
    // -X inference matches curl's own defaults.
    let body = if let Some(n) = named {
        Some(if normalize {
            normalize_dynamic_values(&n.body)
        } else {
            n.body.clone()
        })
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
                let mut synthesized = synth_example_edge(schema, spec, &mut visited, 0, "", edge);
                // Tier 3 — coherence pass: sync sibling fields
                // (email ← firstName+lastName, updatedAt ← createdAt
                // + 30min, total ← amount * quantity, etc.) before
                // serialization + normalize.
                coherence_pass(&mut synthesized);
                serde_json::to_string(&synthesized).ok()
            })
            .map(|s| {
                if normalize {
                    normalize_dynamic_values(&s)
                } else {
                    s
                }
            })
    };
    let mut header_lines: Vec<String> = vec![
        "  -H 'accept: application/json'".to_string(),
        "  -H 'Authorization: Bearer {{TOKEN}}'".to_string(),
    ];
    for (name, value) in &required_headers {
        header_lines.push(format!("  -H '{name}: {value}'"));
    }
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
    // Optional query / header params surface as commented hints so
    // users can uncomment when needed.
    if !optional_query.is_empty() || !optional_headers.is_empty() {
        out.push('\n');
        out.push_str("# Optional parameters (uncomment to use):\n");
        for (name, value) in &optional_query {
            out.push_str(&format!("#   ?{name}={value}\n"));
        }
        for (name, value) in &optional_headers {
            out.push_str(&format!("#   -H '{name}: {value}'\n"));
        }
    }
    out
}

/// Detect login-shaped endpoints and return the `(var, json_path)`
/// pairs a chain step should extract from the response — Tier 6 of
/// the dynamic-realistic roadmap. `path` is the OpenAPI path,
/// `method` the uppercase HTTP method, `op` the operation object,
/// `spec` the full spec (for `$ref` walks into the response schema).
///
/// Rules — all HEURISTICS, deliberately narrow to avoid false
/// positives. A returned hint that doesn't apply to the user's
/// backend is a lint they can remove; a missed hint is silent.
///
/// 1. Path segment ending in one of: `login`, `signin`, `sign-in`,
///    `sign_in`, `token`, `authenticate`, `oauth/token`, `sessions`.
///    Case-insensitive on the last segment only.
/// 2. Method must be POST (login endpoints don't GET).
/// 3. If the response schema has a property named `access_token` /
///    `accessToken` → extract `TOKEN=$.access_token` (or the actual
///    key). Same for `refresh_token` → `REFRESH_TOKEN`. Same for
///    `id_token` → `ID_TOKEN`.
/// 4. When the response schema is unknown but the path is
///    login-shaped, fall back to `TOKEN=$.access_token` as the
///    conventional guess.
fn login_extract_hints(
    path: &str,
    method: &str,
    op: &Value,
    spec: &Value,
) -> Vec<(String, String)> {
    if method != "POST" {
        return Vec::new();
    }
    let last = path
        .rsplit('/')
        .find(|s| !s.is_empty())
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_login = matches!(
        last.as_str(),
        "login" | "signin" | "sign-in" | "sign_in" | "token" | "authenticate" | "sessions"
    );
    if !is_login {
        return Vec::new();
    }
    // Walk `responses.200 | 201 | default → .content."application/json".schema`
    // (with `$ref` resolution) and pluck token-shaped property names.
    let mut hints: Vec<(String, String)> = Vec::new();
    let schema = op
        .get("responses")
        .and_then(Value::as_object)
        .and_then(|responses| {
            responses
                .get("200")
                .or_else(|| responses.get("201"))
                .or_else(|| responses.get("default"))
        })
        .and_then(|r| r.get("content"))
        .and_then(|c| c.get("application/json"))
        .and_then(|j| j.get("schema"));
    let props: Vec<String> = if let Some(schema) = schema {
        let resolved = if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
            resolve_ref(spec, r).unwrap_or(schema)
        } else {
            schema
        };
        resolved
            .get("properties")
            .and_then(Value::as_object)
            .map(|p| p.keys().cloned().collect())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    let mut push_if_matches = |candidates: &[&str], var: &str| {
        for name in &props {
            let key = name.to_ascii_lowercase().replace(['_', '-'], "");
            if candidates.iter().any(|c| c == &key.as_str()) {
                hints.push((var.to_string(), format!(".{name}")));
                return;
            }
        }
    };
    push_if_matches(&["accesstoken", "token"], "TOKEN");
    push_if_matches(&["refreshtoken"], "REFRESH_TOKEN");
    push_if_matches(&["idtoken"], "ID_TOKEN");
    // Fallback — path is login-shaped but response schema is unknown
    // or lacks token-shaped fields. Assume `access_token` as the
    // 90%-common convention (OAuth 2.0). Users prune if their API
    // uses a different field.
    if hints.is_empty() {
        hints.push(("TOKEN".to_string(), ".access_token".to_string()));
    }
    hints
}

/// Collect query + header parameters from a swagger operation.
/// Returns `(required_query, optional_query, required_headers,
/// optional_headers)`. Each entry is `(name, value)` where `value`
/// is either the parameter's example / default / enum-first / a
/// `{{name}}` template placeholder (fallback).
///
/// Path-level `parameters` and operation-level `parameters` are
/// merged; the operation's take precedence when a name collides.
/// `$ref` in the parameters array is resolved through the spec's
/// components.
///
/// Ports Swagger 2.0's `parameters.in` = `path|query|header|body`
/// and OpenAPI 3's identical shape.
///
/// 2026-07-09 Tier 5.
#[allow(clippy::type_complexity)]
fn collect_query_and_header_params(
    op: &Value,
    spec: &Value,
) -> (
    Vec<(String, String)>,
    Vec<(String, String)>,
    Vec<(String, String)>,
    Vec<(String, String)>,
) {
    let mut req_q = Vec::new();
    let mut opt_q = Vec::new();
    let mut req_h = Vec::new();
    let mut opt_h = Vec::new();
    let params = op.get("parameters").and_then(Value::as_array);
    let Some(params) = params else {
        return (req_q, opt_q, req_h, opt_h);
    };
    for p in params {
        // Resolve `$ref` if the parameter is a component reference.
        let resolved = if let Some(r) = p.get("$ref").and_then(Value::as_str) {
            match resolve_ref(spec, r) {
                Some(v) => v,
                None => continue,
            }
        } else {
            p
        };
        let name = match resolved.get("name").and_then(Value::as_str) {
            Some(n) => n.to_string(),
            None => continue,
        };
        let loc = resolved
            .get("in")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !matches!(loc, "query" | "header") {
            continue;
        }
        let required = resolved
            .get("required")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let value = param_placeholder_value(resolved, &name);
        let bucket = match (loc, required) {
            ("query", true) => &mut req_q,
            ("query", false) => &mut opt_q,
            ("header", true) => &mut req_h,
            ("header", false) => &mut opt_h,
            _ => unreachable!(),
        };
        bucket.push((name, value));
    }
    (req_q, opt_q, req_h, opt_h)
}

/// Pick a placeholder value for a swagger parameter — favors
/// `example` / `default` / `enum.first` / a `{{name}}` env-var
/// template as the fallback so users can override via
/// `.mnml/env/<env>.env` without hand-editing the curl.
fn param_placeholder_value(param: &Value, name: &str) -> String {
    // OpenAPI 3: `schema.example` / `schema.default` /
    // `schema.enum[0]`. Swagger 2.0: fields on `param` directly.
    let schema_or_self = param.get("schema").unwrap_or(param);
    if let Some(ex) = schema_or_self.get("example") {
        return json_to_string_flat(ex);
    }
    if let Some(default) = schema_or_self.get("default") {
        return json_to_string_flat(default);
    }
    if let Some(en) = schema_or_self.get("enum").and_then(Value::as_array)
        && let Some(first) = en.first()
    {
        return json_to_string_flat(first);
    }
    // Fallback: `{{camelCaseName}}` template placeholder.
    format!("{{{{{name}}}}}")
}

/// Flatten a JSON value into a compact string suitable for
/// embedding in a URL query or header value (no quotes; scalars
/// as-is; objects/arrays JSON-stringified).
fn json_to_string_flat(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".to_string(),
        _ => v.to_string(),
    }
}

/// Recursively synthesize an example JSON value from a schema.
/// Handles `$ref` (with a visited set to prevent cycles), `example`,
/// `default`, `type` (object/array/string/integer/number/boolean),
/// `format` hints (date-time / date / email / uuid), `enum` (first
/// value), and the composition keywords `allOf` / `oneOf` / `anyOf`
/// (takes the first branch). Depth capped at 5 to keep pathological
/// deeply-recursive specs from blowing the stack.
/// Tier 7 entrypoint — same walk as the base synthesizer but with an
/// edge-case bias applied at leaves (`Min` picks minLength/minimum/
/// non-first-enum; `Max` picks maxLength/maximum/last-enum).
/// `None` = happy path (Tier 2/3 defaults).
fn synth_example_edge(
    schema: &Value,
    spec: &Value,
    visited: &mut HashSet<String>,
    depth: u32,
    prop: &str,
    edge: Option<EdgeCase>,
) -> Value {
    match edge {
        None => synth_example_hinted(schema, spec, visited, depth, prop),
        Some(e) => synth_example_edge_inner(schema, spec, visited, depth, prop, e),
    }
}

fn synth_example_edge_inner(
    schema: &Value,
    spec: &Value,
    visited: &mut HashSet<String>,
    depth: u32,
    prop: &str,
    edge: EdgeCase,
) -> Value {
    if depth > 5 {
        return Value::Null;
    }
    if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
        if visited.contains(r) {
            return Value::Null;
        }
        visited.insert(r.to_string());
        if let Some(resolved) = resolve_ref(spec, r) {
            return synth_example_edge_inner(resolved, spec, visited, depth + 1, prop, edge);
        }
        return Value::Null;
    }
    // Even in edge mode, an explicit example is authoritative —
    // we only touch synthesis defaults.
    if let Some(example) = schema.get("example") {
        return example.clone();
    }
    let ty = schema.get("type").and_then(Value::as_str).unwrap_or("");
    match ty {
        "object" => {
            let mut obj = serde_json::Map::new();
            if let Some(props) = schema.get("properties").and_then(Value::as_object) {
                for (k, v) in props {
                    obj.insert(
                        k.clone(),
                        synth_example_edge_inner(v, spec, visited, depth + 1, k, edge),
                    );
                }
            }
            Value::Object(obj)
        }
        "array" => {
            let item = schema
                .get("items")
                .map(|i| synth_example_edge_inner(i, spec, visited, depth + 1, "", edge))
                .unwrap_or(Value::Null);
            // Min → single-element array (smallest non-empty).
            // Max → three-element array (a variety pick users can
            // trim). Empty arrays would break required-min-items
            // validators in half the specs we care about.
            if edge == EdgeCase::Max {
                Value::Array(vec![item.clone(), item.clone(), item])
            } else {
                Value::Array(vec![item])
            }
        }
        "string" => {
            // Enum: min → last entry, max → first entry (both pick
            // the non-canonical option so the emitted stub differs
            // from the happy-path).
            if let Some(en) = schema.get("enum").and_then(Value::as_array)
                && en.len() >= 2
            {
                return match edge {
                    EdgeCase::Min => en.last().cloned().unwrap_or(Value::Null),
                    EdgeCase::Max => en.first().cloned().unwrap_or(Value::Null),
                };
            }
            // Fixed-shape formats — return as-is regardless of
            // the length-edge bias. Truncating an ISO timestamp
            // to `minLength=1` yields `"2"`; padding an email
            // past `maxLength=64` yields `user@example.comxxx…`.
            // Neither is a useful edge case; both break the
            // format. api-workflow SEV-3 fix 2026-07-09.
            if let Some(fmt) = schema.get("format").and_then(Value::as_str)
                && matches!(fmt, "date-time" | "date" | "email" | "uuid")
            {
                return Value::String(match fmt {
                    "date-time" => "2026-01-01T00:00:00Z".to_string(),
                    "date" => "2026-01-01".to_string(),
                    "email" => "user@example.com".to_string(),
                    "uuid" => "00000000-0000-0000-0000-000000000000".to_string(),
                    _ => unreachable!(),
                });
            }
            let min_len = schema.get("minLength").and_then(Value::as_u64).unwrap_or(1) as usize;
            let max_len = schema
                .get("maxLength")
                .and_then(Value::as_u64)
                .unwrap_or(64) as usize;
            // Opaque-string base value — property-name faker
            // vocab still applies for a realistic-looking basis.
            let base = if !prop.is_empty()
                && let Some(Value::String(s)) = crate::http::faker::placeholder_for(prop, ty)
            {
                s
            } else {
                "string".to_string()
            };
            let n = match edge {
                EdgeCase::Min => min_len.max(1),
                EdgeCase::Max => max_len.min(64),
            };
            if n < base.chars().count() {
                Value::String(base.chars().take(n).collect())
            } else if n == base.chars().count() {
                Value::String(base)
            } else {
                let pad = "x".repeat(n - base.chars().count());
                Value::String(format!("{base}{pad}"))
            }
        }
        "integer" => {
            let mut v = match edge {
                EdgeCase::Min => schema.get("minimum").and_then(Value::as_i64).unwrap_or(0),
                EdgeCase::Max => schema
                    .get("maximum")
                    .and_then(Value::as_i64)
                    .unwrap_or(9999),
            };
            if let Some(excl) = schema.get("exclusiveMinimum").and_then(Value::as_i64)
                && edge == EdgeCase::Min
            {
                v = excl + 1;
            }
            if let Some(excl) = schema.get("exclusiveMaximum").and_then(Value::as_i64)
                && edge == EdgeCase::Max
            {
                v = excl - 1;
            }
            Value::Number(v.into())
        }
        "number" => {
            let v = match edge {
                EdgeCase::Min => schema.get("minimum").and_then(Value::as_f64).unwrap_or(0.0),
                EdgeCase::Max => schema
                    .get("maximum")
                    .and_then(Value::as_f64)
                    .unwrap_or(9999.99),
            };
            Value::Number(serde_json::Number::from_f64(v).unwrap_or(0.into()))
        }
        "boolean" => match edge {
            EdgeCase::Min => Value::Bool(false),
            EdgeCase::Max => Value::Bool(true),
        },
        _ => {
            for k in &["allOf", "oneOf", "anyOf"] {
                if let Some(arr) = schema.get(*k).and_then(Value::as_array) {
                    // Edge mode picks the LAST branch for `oneOf` /
                    // `anyOf` (second variant) so the emitted stub
                    // differs from the happy-path first-branch
                    // pick. `allOf` still uses the first (semantic
                    // conjunction has no "second" branch).
                    let pick = if *k == "allOf" {
                        arr.first()
                    } else if arr.len() >= 2 {
                        arr.last()
                    } else {
                        arr.first()
                    };
                    if let Some(chosen) = pick {
                        return synth_example_edge_inner(
                            chosen,
                            spec,
                            visited,
                            depth + 1,
                            prop,
                            edge,
                        );
                    }
                }
            }
            Value::Null
        }
    }
}

/// Same as `synth_example` but with a property-name hint — used
/// during object descent so `firstName` / `emailAddress` / etc.
/// route through the faker vocab (Tier 2) instead of producing
/// the naive `"string"` fallback. Empty `prop` = no hint.
fn synth_example_hinted(
    schema: &Value,
    spec: &Value,
    visited: &mut HashSet<String>,
    depth: u32,
    prop: &str,
) -> Value {
    if depth > 5 {
        return Value::Null;
    }
    if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
        if visited.contains(r) {
            return Value::Null;
        }
        visited.insert(r.to_string());
        if let Some(resolved) = resolve_ref(spec, r) {
            return synth_example_hinted(resolved, spec, visited, depth + 1, prop);
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
    // Faker vocab wins when the property name matches a known
    // rule for this type — realistic values instead of "string" / 0.
    if !prop.is_empty()
        && let Some(v) = crate::http::faker::placeholder_for(prop, ty)
    {
        return v;
    }
    match ty {
        "object" => {
            let mut obj = serde_json::Map::new();
            if let Some(props) = schema.get("properties").and_then(Value::as_object) {
                for (k, v) in props {
                    obj.insert(
                        k.clone(),
                        synth_example_hinted(v, spec, visited, depth + 1, k),
                    );
                }
            }
            Value::Object(obj)
        }
        "array" => {
            let item = schema
                .get("items")
                .map(|i| synth_example_hinted(i, spec, visited, depth + 1, ""))
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
                    return synth_example_hinted(first, spec, visited, depth + 1, prop);
                }
            }
            Value::Null
        }
    }
}

/// Tier 3 — walk a synthesized JSON body and fix up sibling
/// fields inside every object so the body is internally
/// coherent. Doesn't touch fields with values that look
/// user-provided (`example`/`default`); only overrides the
/// canonical faker fallbacks.
///
/// Runs recursively — nested objects and arrays get the same
/// treatment.
///
/// Rules (all applied per-object):
///   - `email` derived from `firstName` + `lastName` when both
///     are the faker defaults ("John" / "Smith" → `john.smith@example.com`)
///   - `fullName` / `name` / `displayName` derived from same
///   - `updatedAt` / `endTime` / `modifiedAt` = the corresponding
///     `createdAt` / `startTime` / `insertedAt` + 30 minutes
///     when both are ISO strings and updated matches created
///     (naive schema-synth outputs identical timestamps)
///   - `total` derived from `amount` * `quantity` (or `price` *
///     `quantity`) when total looks like the amount's default
///   - `total` derived from `subtotal` + `tax` when both present
pub(crate) fn coherence_pass(v: &mut Value) {
    match v {
        Value::Object(obj) => {
            // First recurse so nested objects are coherent before
            // this level pulls from them.
            for (_, child) in obj.iter_mut() {
                coherence_pass(child);
            }
            // Snapshot sibling values by lowercased key as owned data
            // so the mutable-borrow window on `obj` below stays
            // clean. This runs once per object; the pass is small.
            let keys: Vec<String> = obj.keys().cloned().collect();
            let mut lc_str: std::collections::HashMap<String, String> =
                std::collections::HashMap::new();
            let mut lc_num: std::collections::HashMap<String, f64> =
                std::collections::HashMap::new();
            let mut lc_present: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for k in &keys {
                let lk = crate::http::faker::normalize_key(k);
                lc_present.insert(lk.clone());
                if let Some(s) = obj.get(k).and_then(Value::as_str) {
                    lc_str.insert(lk.clone(), s.to_string());
                }
                if let Some(n) = obj.get(k).and_then(Value::as_f64) {
                    lc_num.insert(lk, n);
                }
            }
            // Derive coherent email + fullName + username.
            let first = lc_str
                .get("firstname")
                .or_else(|| lc_str.get("givenname"))
                .or_else(|| lc_str.get("fname"))
                .cloned();
            let last = lc_str
                .get("lastname")
                .or_else(|| lc_str.get("familyname"))
                .or_else(|| lc_str.get("surname"))
                .or_else(|| lc_str.get("lname"))
                .cloned();
            if let (Some(f), Some(l)) = (first, last) {
                let derived_email =
                    format!("{}.{}@example.com", f.to_lowercase(), l.to_lowercase());
                let derived_full = format!("{f} {l}");
                let derived_user = format!(
                    "{}{}",
                    f.chars().next().unwrap_or('j').to_ascii_lowercase(),
                    l.to_lowercase()
                );
                for k in &keys {
                    let lk = crate::http::faker::normalize_key(k);
                    match lk.as_str() {
                        "email" | "emailaddress" | "emailid"
                            if obj.get(k).and_then(Value::as_str) == Some("user@example.com") =>
                        {
                            obj.insert(k.clone(), Value::String(derived_email.clone()));
                        }
                        "fullname" | "name" | "displayname"
                            if obj.get(k).and_then(Value::as_str) == Some("John Smith") =>
                        {
                            obj.insert(k.clone(), Value::String(derived_full.clone()));
                        }
                        "username" if obj.get(k).and_then(Value::as_str) == Some("jsmith") => {
                            obj.insert(k.clone(), Value::String(derived_user.clone()));
                        }
                        _ => {}
                    }
                }
            }
            // Derive coherent timestamp pair — updated 30min after created.
            for (created_key, updated_key) in &[
                ("createdat", "updatedat"),
                ("createdat", "modifiedat"),
                ("insertedat", "updatedat"),
                ("starttime", "endtime"),
                ("startsat", "endsat"),
            ] {
                let created = lc_str.get(*created_key).cloned();
                let updated_exists = lc_present.contains(*updated_key);
                if let (Some(created), true) = (created, updated_exists)
                    && let Some(bumped) = bump_iso_by_minutes(&created, 30)
                {
                    for k in &keys {
                        if crate::http::faker::normalize_key(k) == *updated_key
                            && obj.get(k).and_then(Value::as_str) == Some(created.as_str())
                        {
                            obj.insert(k.clone(), Value::String(bumped.clone()));
                        }
                    }
                }
            }
            // Derive coherent total: amount * quantity or subtotal + tax.
            let amount = lc_num
                .get("amount")
                .or_else(|| lc_num.get("price"))
                .copied();
            let quantity = lc_num
                .get("quantity")
                .or_else(|| lc_num.get("qty"))
                .copied();
            let subtotal = lc_num.get("subtotal").copied();
            let tax = lc_num.get("tax").copied();
            let derived_total = if let (Some(s), Some(t)) = (subtotal, tax) {
                Some(round_money(s + t))
            } else if let (Some(a), Some(q)) = (amount, quantity) {
                Some(round_money(a * q))
            } else {
                None
            };
            if let Some(total) = derived_total {
                for k in &keys {
                    if crate::http::faker::normalize_key(k) == "total"
                        && obj.get(k).and_then(Value::as_f64) == Some(9.99)
                        && let Some(n) = serde_json::Number::from_f64(total)
                    {
                        obj.insert(k.clone(), Value::Number(n));
                    }
                }
            }
        }
        Value::Array(arr) => {
            for item in arr {
                coherence_pass(item);
            }
        }
        _ => {}
    }
}

fn round_money(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Parse an ISO 8601 timestamp (`YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]`)
/// and bump it forward by `minutes`. Returns the new stamp in the
/// same shape as the input (preserves fractional seconds + zone).
/// `None` for unparseable inputs — caller keeps the original value.
fn bump_iso_by_minutes(input: &str, minutes: i64) -> Option<String> {
    let (year, month, day, hour, minute, sec, rest) = parse_iso(input)?;
    let total_min = hour as i64 * 60 + minute as i64 + minutes;
    let day_offset = total_min.div_euclid(24 * 60);
    let mod_min = total_min.rem_euclid(24 * 60) as u32;
    let new_hour = mod_min / 60;
    let new_min = mod_min % 60;
    let (nyear, nmonth, nday) =
        civil_from_days(days_from_civil(year, month, day) + day_offset as i32);
    let base = format!("{nyear:04}-{nmonth:02}-{nday:02}T{new_hour:02}:{new_min:02}:{sec:02}");
    Some(format!("{base}{rest}"))
}

#[allow(clippy::type_complexity)]
fn parse_iso(input: &str) -> Option<(i32, u32, u32, u32, u32, u32, String)> {
    // Minimal parser: `YYYY-MM-DDTHH:MM:SS` prefix + anything else
    // (fractional + zone) captured as `rest`. Reject if the prefix
    // isn't exactly that shape.
    let bytes = input.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let get = |s: usize, e: usize| -> Option<&str> { input.get(s..e) };
    let year: i32 = get(0, 4)?.parse().ok()?;
    if bytes[4] != b'-' {
        return None;
    }
    let month: u32 = get(5, 7)?.parse().ok()?;
    if bytes[7] != b'-' {
        return None;
    }
    let day: u32 = get(8, 10)?.parse().ok()?;
    if bytes[10] != b'T' {
        return None;
    }
    let hour: u32 = get(11, 13)?.parse().ok()?;
    if bytes[13] != b':' {
        return None;
    }
    let minute: u32 = get(14, 16)?.parse().ok()?;
    if bytes[16] != b':' {
        return None;
    }
    let sec: u32 = get(17, 19)?.parse().ok()?;
    let rest = input.get(19..).unwrap_or("").to_string();
    Some((year, month, day, hour, minute, sec, rest))
}

/// Howard Hinnant civil_from_days — days-since-epoch → (Y,M,D).
/// Copy of `template.rs::civil_from_days` to avoid making that
/// helper `pub`. Correct for the entire Gregorian range.
fn civil_from_days(z: i32) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i32 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn days_from_civil(y: i32, m: u32, d: u32) -> i32 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u32;
    let doy = (153 * if m > 2 { m - 3 } else { m + 9 } + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe as i32 - 719_468
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        assert_eq!(n.0, 3);
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        assert_eq!(n.0, 2, "should emit one stub per named example");
        let created =
            std::fs::read_to_string(out.join("Admin/TriggerEvent.OrderCreated.curl")).unwrap();
        // 2026-07-09 — with serde_json's `preserve_order` feature
        // enabled, field ORDER matches the input (swagger source
        // order). `eventName` was declared first in the fixture
        // above, so it comes first here.
        assert!(
            created.contains(r#"--data-raw '{"eventName":"OrderCreated","data":{"id":1}}'"#),
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("things/CreateThing.curl")).unwrap();
        // 2026-07-09 — Tier 2 faker now returns "John Smith" for a
        // property named `name`, not the generic "string" fallback.
        assert!(
            body.contains(r#""name":"John Smith""#),
            "synthesized name: {body}"
        );
        assert!(body.contains(r#""count":1"#), "synthesized count: {body}");
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("nodes/PostNode.curl")).unwrap();
        // "id" must be filled; "child" nullifies at the cycle break.
        assert!(body.contains(r#""id":0"#), "cycle-broken body: {body}");
    }

    #[test]
    fn normalize_replaces_iso_timestamps_and_uuids() {
        let raw = r#"{"orderId":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","asOfDate":"2026-07-09T17:35:39.4944815Z","label":"OrderCreated"}"#;
        let out = normalize_dynamic_values(raw);
        assert!(
            out.contains(r#""orderId":"{{$uuid}}""#),
            "uuid not replaced: {out}"
        );
        assert!(
            out.contains(r#""asOfDate":"{{$isoTimestamp}}""#),
            "iso timestamp not replaced: {out}"
        );
        // Non-matching strings unchanged.
        assert!(out.contains(r#""label":"OrderCreated""#));
    }

    #[test]
    fn normalize_ignores_uppercase_uuid_and_date_only() {
        let raw = r#"{"const":"ABCDEF12-3456-7890-ABCD-EF1234567890","birthDate":"2026-07-09","note":"1234-5678"}"#;
        let out = normalize_dynamic_values(raw);
        // Uppercase UUIDs left alone (could be user constants).
        assert!(out.contains("ABCDEF12-3456-7890-ABCD-EF1234567890"));
        // Date-only strings left alone (could be business data).
        assert!(out.contains(r#""birthDate":"2026-07-09""#));
        assert!(out.contains(r#""note":"1234-5678""#));
    }

    #[test]
    fn discover_normalize_flag_wires_through_to_generated_body() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/e": {
                  "post": {
                    "operationId": "Ping",
                    "tags": ["p"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "example": {
                            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                            "at": "2026-07-09T17:35:39.4944815Z"
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
            normalize: true,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("p/Ping.curl")).unwrap();
        assert!(body.contains(r#""id":"{{$uuid}}""#), "body: {body}");
        assert!(body.contains(r#""at":"{{$isoTimestamp}}""#), "body: {body}");
    }

    #[test]
    fn edge_cases_flag_emits_min_and_max_variants_per_body_operation() {
        // Tier 7: --edge-cases produces the happy-path stub plus
        // `<op>.edge-min.curl` (minimum boundary values, last enum)
        // and `<op>.edge-max.curl` (maximum boundary values, first
        // enum + longer strings).
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
                    "operationId": "createThing",
                    "tags": ["things"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "properties": {
                              "name": { "type": "string", "minLength": 3, "maxLength": 8 },
                              "status": { "type": "string", "enum": ["draft","published","archived"] },
                              "score": { "type": "integer", "minimum": 1, "maximum": 100 }
                            }
                          }
                        }
                      }
                    }
                  }
                },
                "/things/{id}": {
                  "get": { "operationId": "getThing", "tags": ["things"] }
                }
              }
            }"#,
        )
        .unwrap();
        let out = dir.path().join("o");
        let n = run(&Options {
            spec: spec.to_string_lossy().into_owned(),
            out: out.clone(),
            base_url: None,
            normalize: false,
            edge_cases: true,
            force: true,
        })
        .unwrap();
        // 1 happy for POST + 2 edge for POST + 1 happy for GET = 4.
        assert_eq!(n.0, 4);
        let happy = std::fs::read_to_string(out.join("things/createThing.curl")).unwrap();
        let emin = std::fs::read_to_string(out.join("things/createThing.edge-min.curl")).unwrap();
        let emax = std::fs::read_to_string(out.join("things/createThing.edge-max.curl")).unwrap();
        // Happy-path: Tier 2 faker vocab wins over enum-first, so
        // `status` becomes "active" (the canonical faker default).
        assert!(
            happy.contains(r#""status":"active""#),
            "happy status: {happy}"
        );
        // Min-edge picks the LAST enum ("archived") and boundary score=1.
        assert!(
            emin.contains(r#""status":"archived""#),
            "min status: {emin}"
        );
        assert!(emin.contains(r#""score":1"#), "min score: {emin}");
        // Max-edge picks the FIRST enum ("draft") and boundary score=100.
        assert!(emax.contains(r#""status":"draft""#), "max status: {emax}");
        assert!(emax.contains(r#""score":100"#), "max score: {emax}");
        // GET has no body → no edge variants emitted.
        assert!(!out.join("things/getThing.edge-min.curl").exists());
    }

    #[test]
    fn edge_cases_preserves_format_typed_strings_intact() {
        // api-workflow SEV-3 regression lock 2026-07-09.
        // date-time / date / email / uuid fields shouldn't get
        // length-boundary trimming — that produces `"2"` and
        // `"u"` on edge-min, and format-breaking x-padded
        // suffixes on edge-max.
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
                    "operationId": "createThing",
                    "tags": ["things"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "properties": {
                              "createdAt": { "type": "string", "format": "date-time" },
                              "email":     { "type": "string", "format": "email" },
                              "id":        { "type": "string", "format": "uuid" }
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
            normalize: false,
            edge_cases: true,
            force: true,
        })
        .unwrap();
        let emin = std::fs::read_to_string(out.join("things/createThing.edge-min.curl")).unwrap();
        let emax = std::fs::read_to_string(out.join("things/createThing.edge-max.curl")).unwrap();
        for body in &[emin, emax] {
            assert!(
                body.contains(r#""createdAt":"2026-01-01T00:00:00Z""#),
                "createdAt intact: {body}"
            );
            assert!(
                body.contains(r#""email":"user@example.com""#),
                "email intact: {body}"
            );
            assert!(
                body.contains(r#""id":"00000000-0000-0000-0000-000000000000""#),
                "uuid intact: {body}"
            );
        }
    }

    #[test]
    fn edge_cases_flag_off_by_default_produces_only_happy_path() {
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
                    "operationId": "createThing",
                    "tags": ["things"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": { "type": "object" }
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        assert!(out.join("things/createThing.curl").exists());
        assert!(!out.join("things/createThing.edge-min.curl").exists());
        assert!(!out.join("things/createThing.edge-max.curl").exists());
    }

    #[test]
    fn coherence_pass_derives_email_from_first_last() {
        let mut v = serde_json::json!({
            "firstName": "John",
            "lastName": "Smith",
            "emailAddress": "user@example.com",
            "fullName": "John Smith",
            "username": "jsmith",
        });
        coherence_pass(&mut v);
        assert_eq!(v["emailAddress"], "john.smith@example.com");
        assert_eq!(v["fullName"], "John Smith");
        // username derived from first-initial + last (jsmith is
        // already the canonical shape but proves coherence works
        // when first/last vary via example overrides).
        assert_eq!(v["username"], "jsmith");
    }

    #[test]
    fn coherence_pass_bumps_updated_after_created() {
        let mut v = serde_json::json!({
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
        });
        coherence_pass(&mut v);
        assert_eq!(v["updatedAt"], "2026-01-01T00:30:00Z");
    }

    #[test]
    fn coherence_pass_computes_total_from_amount_and_quantity() {
        let mut v = serde_json::json!({
            "amount": 9.99,
            "quantity": 3,
            "total": 9.99,
        });
        coherence_pass(&mut v);
        assert_eq!(v["total"].as_f64().unwrap(), 29.97);
    }

    #[test]
    fn coherence_pass_computes_total_from_subtotal_plus_tax() {
        let mut v = serde_json::json!({
            "subtotal": 20.0,
            "tax": 1.6,
            "total": 9.99,
        });
        coherence_pass(&mut v);
        assert_eq!(v["total"].as_f64().unwrap(), 21.6);
    }

    #[test]
    fn coherence_pass_recurses_into_nested_objects_and_arrays() {
        let mut v = serde_json::json!({
            "user": { "firstName": "John", "lastName": "Smith", "email": "user@example.com" },
            "items": [
                { "amount": 5.0, "quantity": 2, "total": 9.99 }
            ]
        });
        coherence_pass(&mut v);
        assert_eq!(v["user"]["email"], "john.smith@example.com");
        assert_eq!(v["items"][0]["total"].as_f64().unwrap(), 10.0);
    }

    #[test]
    fn login_endpoints_emit_extract_hints_and_chain_template() {
        // Tier 6: a POST /auth/login with an access_token in the
        // response schema gets `# extract: TOKEN=$.access_token` in
        // the curl header and an `auth-flow.chain.json` starter.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/auth/login": {
                  "post": {
                    "operationId": "login",
                    "tags": ["auth"],
                    "responses": {
                      "200": {
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "properties": {
                                "access_token": { "type": "string" },
                                "refresh_token": { "type": "string" }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                },
                "/auth/me": {
                  "get": { "operationId": "getMe", "tags": ["auth"] }
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let login_body = std::fs::read_to_string(out.join("auth/login.curl")).unwrap();
        assert!(
            login_body.contains("# extract: TOKEN=$.access_token"),
            "extract TOKEN hint missing: {login_body}"
        );
        assert!(
            login_body.contains("# extract: REFRESH_TOKEN=$.refresh_token"),
            "extract REFRESH_TOKEN hint missing: {login_body}"
        );
        // getMe is not login-shaped → no extract hint.
        let me_body = std::fs::read_to_string(out.join("auth/getMe.curl")).unwrap();
        assert!(
            !me_body.contains("# extract:"),
            "non-login should have no extract hint: {me_body}"
        );
        // Chain template exists with login + one non-login step.
        let chain_path = out.join("auth-flow.chain.json");
        let chain_text = std::fs::read_to_string(&chain_path).unwrap();
        let chain: serde_json::Value = serde_json::from_str(&chain_text).unwrap();
        let steps = chain.as_array().unwrap();
        assert_eq!(steps.len(), 2, "chain has 2 steps: {chain_text}");
        assert_eq!(steps[0]["request"].as_str().unwrap(), "auth/login.curl");
        assert_eq!(
            steps[0]["extract"]["TOKEN"].as_str().unwrap(),
            "$.access_token"
        );
        assert_eq!(steps[1]["request"].as_str().unwrap(), "auth/getMe.curl");
    }

    #[test]
    fn login_extract_hint_falls_back_when_schema_absent() {
        // A POST /login with no response schema → conventional
        // `TOKEN=$.access_token` fallback still emitted.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/login": {
                  "post": { "operationId": "signIn", "tags": ["auth"] }
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("auth/signIn.curl")).unwrap();
        assert!(
            body.contains("# extract: TOKEN=$.access_token"),
            "fallback missing: {body}"
        );
    }

    #[test]
    fn no_chain_template_when_no_login_endpoint() {
        // Tier 6 only emits chain templates for tags with login-
        // shaped endpoints. A spec without any login → no chains.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/things": {
                  "get": { "operationId": "listThings", "tags": ["things"] }
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let has_chain = std::fs::read_dir(&out)
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().ends_with(".chain.json"));
        assert!(!has_chain, "no chain template expected");
    }

    #[test]
    fn path_params_upgrade_to_env_vars_when_named_as_wellknown_ids() {
        // Tier 4: `{merchantId}` in the path → `{{MERCHANT_ID}}`,
        // not `{{merchantId}}`. Unknown-name path params fall
        // through to the existing camelCase templating.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/merchants/{merchantId}/locations/{locationId}/thing/{thingId}": {
                  "get": {
                    "operationId": "getThing",
                    "tags": ["things"]
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("things/getThing.curl")).unwrap();
        // merchantId + locationId are known → env vars.
        assert!(
            body.contains("/merchants/{{MERCHANT_ID}}/"),
            "MERCHANT_ID: {body}"
        );
        assert!(
            body.contains("/locations/{{LOCATION_ID}}/"),
            "LOCATION_ID: {body}"
        );
        // thingId is unknown → keep the original name.
        assert!(body.contains("/thing/{{thingId}}"), "unknown kept: {body}");
    }

    #[test]
    fn faker_vocab_fills_realistic_placeholders_by_property_name() {
        // Tier 2: firstName + lastName + email + merchantId + status
        // + quantity all get realistic values instead of the naive
        // "string" / 0 fallback.
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/customers": {
                  "post": {
                    "operationId": "createCustomer",
                    "tags": ["customers"],
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "properties": {
                              "firstName": { "type": "string" },
                              "lastName": { "type": "string" },
                              "emailAddress": { "type": "string" },
                              "merchantId": { "type": "integer" },
                              "status": { "type": "string" },
                              "quantity": { "type": "integer" }
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("customers/createCustomer.curl")).unwrap();
        assert!(body.contains(r#""firstName":"John""#), "firstName: {body}");
        assert!(body.contains(r#""lastName":"Smith""#), "lastName: {body}");
        // Tier 3 coherence pass runs after faker vocab and derives
        // email from firstName + lastName in the same object.
        assert!(
            body.contains(r#""emailAddress":"john.smith@example.com""#),
            "email: {body}"
        );
        assert!(
            body.contains(r#""merchantId":"{{MERCHANT_ID}}""#),
            "merchantId env-var: {body}"
        );
        assert!(body.contains(r#""status":"active""#), "status: {body}");
        assert!(body.contains(r#""quantity":1"#), "quantity: {body}");
    }

    #[test]
    fn required_query_params_become_url_query_string() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/things": {
                  "get": {
                    "operationId": "listThings",
                    "tags": ["things"],
                    "parameters": [
                      { "name": "merchantId", "in": "query", "required": true,
                        "schema": { "type": "integer" } },
                      { "name": "status", "in": "query", "required": true,
                        "schema": { "type": "string", "enum": ["active","inactive"] } }
                    ]
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("things/listThings.curl")).unwrap();
        assert!(
            body.contains("things?merchantId={{merchantId}}&status=active"),
            "url query missing: {body}"
        );
    }

    #[test]
    fn required_header_params_become_dash_h_lines() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/things": {
                  "get": {
                    "operationId": "listThings",
                    "tags": ["things"],
                    "parameters": [
                      { "name": "X-Merchant-Id", "in": "header", "required": true,
                        "schema": { "type": "string" } }
                    ]
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("things/listThings.curl")).unwrap();
        assert!(
            body.contains("-H 'X-Merchant-Id: {{X-Merchant-Id}}'"),
            "header line missing: {body}"
        );
    }

    #[test]
    fn optional_params_surface_as_commented_hints() {
        let dir = tempfile::tempdir().unwrap();
        let spec = dir.path().join("s.json");
        std::fs::write(
            &spec,
            r#"{
              "openapi": "3.0.0",
              "servers": [{ "url": "https://api.example.com" }],
              "paths": {
                "/things": {
                  "get": {
                    "operationId": "listThings",
                    "tags": ["things"],
                    "parameters": [
                      { "name": "cursor", "in": "query", "required": false,
                        "schema": { "type": "string" } },
                      { "name": "X-Debug", "in": "header", "required": false,
                        "schema": { "type": "boolean", "default": false } }
                    ]
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        let body = std::fs::read_to_string(out.join("things/listThings.curl")).unwrap();
        assert!(
            body.contains("# Optional parameters (uncomment to use):"),
            "hint header missing: {body}"
        );
        assert!(
            body.contains("#   ?cursor={{cursor}}"),
            "cursor hint: {body}"
        );
        assert!(
            body.contains("#   -H 'X-Debug: false'"),
            "X-Debug hint (with default): {body}"
        );
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
            normalize: false,
            edge_cases: false,
            force: true,
        })
        .unwrap();
        // 2026-07-09 — hyphens (matches rqst-parity `sanitize`).
        let f = std::fs::read_to_string(out.join("untagged/get-ping.curl")).unwrap();
        assert!(f.contains("curl 'https://x.test/api/ping'"), "{f}");
    }
}
