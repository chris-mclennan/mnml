//! Parse a Playwright `trace.zip` into a flat, time-ordered list of [`TraceEvent`]s
//! for the native [`TracePane`](super::trace_pane::TracePane) — a text timeline of
//! the actions / console output / page errors recorded during a (failed) test, so
//! you can see what happened without the Playwright trace-viewer GUI.
//!
//! The zip's `*.trace` entries are NDJSON event streams (one JSON object per line).
//! The shapes change between Playwright versions; we handle the common ones: the
//! paired `before`/`after` action records (matched by `callId` — start time +
//! params from the `before`, end time + error from the `after`), the older flat
//! `action` record, `console` messages, and `error` (uncaught) records. Snapshots,
//! screencast frames, resources and internal `log` lines are skipped. Times are
//! whatever monotonic clock the trace uses, re-based so the first event is `+0`.

use std::io::Read;
use std::path::Path;

use serde_json::Value;

/// One row in the timeline.
#[derive(Debug, Clone)]
pub struct TraceEvent {
    /// Milliseconds since the first event in the trace.
    pub at_ms: f64,
    /// Duration of an action, if known (ms).
    pub dur_ms: Option<f64>,
    pub kind: EventKind,
    /// The headline (`page.goto("https://…")`, the console text, …).
    pub title: String,
    /// Extra detail — the action params, the error message + stack, …. May be empty.
    pub detail: String,
    /// `Some` if this event is (or carries) an error.
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Action,
    Console,
    Error,
    Stdio,
}

impl EventKind {
    pub fn glyph(self) -> &'static str {
        match self {
            EventKind::Action => "⏵",
            EventKind::Console => "▸",
            EventKind::Error => "✗",
            EventKind::Stdio => "›",
        }
    }
}

/// Read + parse `trace.zip` at `path`. `Err` with a human-readable reason on a
/// bad/unreadable archive; `Ok(vec![])` if the archive has no recognisable events.
pub fn parse_trace_zip(path: &Path) -> Result<Vec<TraceEvent>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("opening {}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("reading trace.zip: {e}"))?;
    let mut ndjson = String::new();
    for i in 0..zip.len() {
        let mut entry = match zip.by_index(i) {
            Ok(e) => e,
            Err(_) => continue,
        };
        // `<context-id>.trace` (and the older bare `trace.trace`) hold the events;
        // there's also `*.network` (network NDJSON) and `*.stacks` we ignore here.
        let name = entry.name().to_string();
        if !name.ends_with(".trace") {
            continue;
        }
        let _ = entry.read_to_string(&mut ndjson);
        ndjson.push('\n');
    }
    if ndjson.trim().is_empty() {
        return Ok(Vec::new());
    }
    Ok(parse_ndjson(&ndjson))
}

/// Parse a concatenation of `*.trace` NDJSON into time-ordered events.
pub fn parse_ndjson(text: &str) -> Vec<TraceEvent> {
    // `before` records keyed by callId, awaiting their `after`.
    let mut pending: std::collections::HashMap<String, (f64, String, String)> =
        std::collections::HashMap::new();
    let mut events: Vec<TraceEvent> = Vec::new();

    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        match v.get("type").and_then(Value::as_str).unwrap_or("") {
            "before" => {
                let call_id = str_field(&v, "callId");
                let start = num_field(&v, "startTime").unwrap_or(0.0);
                let (title, detail) = action_title(&v);
                if !call_id.is_empty() {
                    pending.insert(call_id, (start, title, detail));
                } else {
                    events.push(TraceEvent {
                        at_ms: start,
                        dur_ms: None,
                        kind: EventKind::Action,
                        title,
                        detail,
                        error: None,
                    });
                }
            }
            "after" => {
                let call_id = str_field(&v, "callId");
                let end = num_field(&v, "endTime");
                let err = error_text(v.get("error"));
                if let Some((start, title, detail)) = pending.remove(&call_id) {
                    events.push(TraceEvent {
                        at_ms: start,
                        dur_ms: end.map(|e| (e - start).max(0.0)),
                        kind: EventKind::Action,
                        title,
                        detail,
                        error: err,
                    });
                }
            }
            // Older single-record action format.
            "action" => {
                let start = num_field(&v, "startTime").unwrap_or(0.0);
                let end = num_field(&v, "endTime");
                let (title, detail) = action_title(&v);
                events.push(TraceEvent {
                    at_ms: start,
                    dur_ms: end.map(|e| (e - start).max(0.0)),
                    kind: EventKind::Action,
                    title,
                    detail,
                    error: error_text(v.get("error"))
                        .or_else(|| v.get("metadata").and_then(|m| error_text(m.get("error")))),
                });
            }
            "console" => {
                let kind = str_field(&v, "messageType");
                let t = v
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let is_err = kind == "error";
                events.push(TraceEvent {
                    at_ms: num_field(&v, "time").unwrap_or(0.0),
                    dur_ms: None,
                    kind: if is_err {
                        EventKind::Error
                    } else {
                        EventKind::Console
                    },
                    title: format!(
                        "console.{}: {}",
                        if kind.is_empty() { "log" } else { &kind },
                        first_line(&t)
                    ),
                    detail: t,
                    error: is_err.then(|| "console error".to_string()),
                });
            }
            "error" => {
                let msg = error_text(v.get("error")).unwrap_or_else(|| "(error)".to_string());
                events.push(TraceEvent {
                    at_ms: num_field(&v, "time").unwrap_or(0.0),
                    dur_ms: None,
                    kind: EventKind::Error,
                    title: format!("⚠ {}", first_line(&msg)),
                    detail: msg.clone(),
                    error: Some(msg),
                });
            }
            "stdout" | "stderr" => {
                let txt = v
                    .get("text")
                    .and_then(Value::as_str)
                    .or_else(|| v.get("message").and_then(Value::as_str))
                    .unwrap_or("")
                    .trim()
                    .to_string();
                if !txt.is_empty() {
                    events.push(TraceEvent {
                        at_ms: num_field(&v, "time").unwrap_or(0.0),
                        dur_ms: None,
                        kind: EventKind::Stdio,
                        title: first_line(&txt),
                        detail: txt,
                        error: None,
                    });
                }
            }
            _ => {} // snapshots / screencast / log / resources / context-options …
        }
    }
    // Anything still pending never got its `after` — emit it with no duration.
    for (_, (start, title, detail)) in pending {
        events.push(TraceEvent {
            at_ms: start,
            dur_ms: None,
            kind: EventKind::Action,
            title,
            detail,
            error: None,
        });
    }

    events.sort_by(|a, b| {
        a.at_ms
            .partial_cmp(&b.at_ms)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    // Re-base times so the first event is +0.
    if let Some(t0) = events.first().map(|e| e.at_ms) {
        for e in &mut events {
            e.at_ms -= t0;
        }
    }
    events
}

fn str_field(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("").to_string()
}

fn num_field(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(Value::as_f64)
}

/// Build a `class.method(arg, …)` headline + a param detail string from an action
/// record (handles both the `apiName` shape and the `class`+`method` shape).
fn action_title(v: &Value) -> (String, String) {
    let name = v
        .get("apiName")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| {
            let class = str_field(v, "class");
            let method = str_field(v, "method");
            match (class.is_empty(), method.is_empty()) {
                (false, false) => format!("{class}.{method}"),
                (true, false) => method,
                _ => "action".to_string(),
            }
        });
    let params = v.get("params");
    let summary = params.map(param_summary).unwrap_or_default();
    let detail = params
        .map(|p| serde_json::to_string_pretty(p).unwrap_or_default())
        .unwrap_or_default();
    let title = if summary.is_empty() {
        name
    } else {
        format!("{name}({summary})")
    };
    (title, detail)
}

/// The most telling param of an action — a URL, selector, text, etc. — for the headline.
fn param_summary(params: &Value) -> String {
    let Some(obj) = params.as_object() else {
        return String::new();
    };
    for key in [
        "url",
        "selector",
        "text",
        "value",
        "key",
        "name",
        "expression",
        "state",
    ] {
        if let Some(s) = obj.get(key).and_then(Value::as_str) {
            return truncate(s, 60);
        }
    }
    String::new()
}

fn error_text(err: Option<&Value>) -> Option<String> {
    let e = err?;
    if e.is_null() {
        return None;
    }
    let msg = e
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| {
            e.get("error")
                .and_then(|x| x.get("message"))
                .and_then(Value::as_str)
        })
        .or_else(|| e.as_str())?;
    let stack = e
        .get("stack")
        .and_then(Value::as_str)
        .or_else(|| {
            e.get("error")
                .and_then(|x| x.get("stack"))
                .and_then(Value::as_str)
        })
        .unwrap_or("");
    let mut s = msg.trim().to_string();
    if !stack.is_empty() {
        s.push('\n');
        s.push_str(stack.trim());
    }
    (!s.is_empty()).then_some(s)
}

fn first_line(s: &str) -> String {
    truncate(s.lines().next().unwrap_or("").trim(), 100)
}

fn truncate(s: &str, max: usize) -> String {
    let s = s.replace(['\n', '\r'], " ");
    if s.chars().count() <= max {
        s
    } else {
        let keep: String = s.chars().take(max.saturating_sub(1)).collect();
        format!("{keep}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairs_before_after_and_collects_console_and_error() {
        let ndjson = r##"
{"type":"context-options","startTime":1000}
{"type":"before","callId":"c1","startTime":1000,"apiName":"page.goto","params":{"url":"https://example.com"}}
{"type":"console","messageType":"log","text":"hello","time":1100}
{"type":"after","callId":"c1","endTime":1500}
{"type":"before","callId":"c2","startTime":1500,"class":"Locator","method":"click","params":{"selector":"#go"}}
{"type":"after","callId":"c2","endTime":1600,"error":{"message":"locator.click: timeout","stack":"at foo.ts:3"}}
{"type":"error","time":1700,"error":{"message":"Uncaught TypeError: x is not a function"}}
"##;
        let evs = parse_ndjson(ndjson);
        // page.goto, console.log, Locator.click(err), error  → 4 events, time-ordered, re-based.
        assert_eq!(evs.len(), 4);
        assert_eq!(evs[0].at_ms, 0.0);
        assert!(evs[0].title.starts_with("page.goto(https://example.com"));
        assert_eq!(evs[0].dur_ms, Some(500.0));
        assert_eq!(evs[1].kind, EventKind::Console);
        assert!(evs[1].title.contains("hello"));
        assert!(evs[2].title.starts_with("Locator.click(#go"));
        assert!(evs[2].error.as_deref().unwrap().contains("timeout"));
        assert_eq!(evs[3].kind, EventKind::Error);
        assert!(evs[3].at_ms == 700.0);
    }

    #[test]
    fn empty_or_garbage_is_fine() {
        assert!(parse_ndjson("").is_empty());
        assert!(parse_ndjson("not json\n{also not\n").is_empty());
    }
}
