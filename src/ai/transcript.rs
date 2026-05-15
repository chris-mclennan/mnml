//! Read Claude Code's session transcript (`~/.claude/projects/<dashed-cwd>/<session-id>.jsonl`)
//! into a flat list of [`Turn`]s for the in-IDE conversation mirror — so a
//! `claude` pane (or a `claude -p` answer that's been promoted with `c`) shows up
//! nicely rendered next to the raw pty grid.
//!
//! The JSONL is one object per line. We care about the message lines (`type` =
//! `user` / `assistant`, with `message.role` + `message.content`); the meta lines
//! (`last-prompt`, `permission-mode`, `attachment`, `file-history-snapshot`, …)
//! and side-chain (sub-agent) lines are skipped. `message.content` is either a
//! string (a plain user message) or an array of blocks (`text` / `thinking` /
//! `tool_use` / `tool_result`).

use std::path::{Path, PathBuf};

use serde_json::Value;

/// One rendered conversation turn.
#[derive(Debug, Clone, PartialEq)]
pub enum Turn {
    User(String),
    Assistant(String),
    /// Assistant thinking — shown collapsed (we keep a short preview).
    Thinking(String),
    /// A tool call: `name` + a one-line summary of the input.
    ToolUse {
        name: String,
        summary: String,
    },
    /// A tool result — truncated to a couple of lines.
    ToolResult(String),
}

/// A single past session — the `<session-id>.jsonl` filename's stem,
/// the file's mtime (unix seconds), and the first user turn (up to
/// ~80 chars) as a label preview.
#[derive(Debug, Clone)]
pub struct PastSession {
    pub session_id: String,
    pub path: PathBuf,
    pub mtime: i64,
    pub preview: String,
}

/// Scan `~/.claude/projects/<dashed-cwd>/` for `*.jsonl` transcripts and
/// return a list newest-first. Each entry's `preview` is the first user
/// message (truncated). Best-effort — returns empty when $HOME isn't
/// set or the directory doesn't exist.
pub fn list_sessions(workspace: &Path) -> Vec<PastSession> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let dashed = workspace.to_string_lossy().replace(['/', '.'], "-");
    let dir = Path::new(&home)
        .join(".claude")
        .join("projects")
        .join(dashed);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<PastSession> = Vec::new();
    for e in entries.flatten() {
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let mtime = e
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let preview = first_user_message(&path).unwrap_or_default();
        out.push(PastSession {
            session_id: stem.to_string(),
            path: path.clone(),
            mtime,
            preview,
        });
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.mtime));
    out
}

fn first_user_message(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if v.get("type").and_then(Value::as_str) != Some("user") {
            continue;
        }
        let content = v.get("message").and_then(|m| m.get("content"))?;
        let text = match content {
            Value::String(s) => s.clone(),
            Value::Array(blocks) => blocks
                .iter()
                .filter_map(|b| {
                    if b.get("type").and_then(Value::as_str)? != "text" {
                        return None;
                    }
                    b.get("text").and_then(Value::as_str).map(String::from)
                })
                .next()?,
            _ => continue,
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        return Some(trimmed.chars().take(80).collect());
    }
    None
}

/// The expected transcript path for `session_id` run from `workspace`, or `None`
/// if `$HOME` isn't set. (Claude Code's project dir is the absolute cwd with `/`
/// and `.` turned into `-`.)
pub fn session_path(workspace: &Path, session_id: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let dashed = workspace.to_string_lossy().replace(['/', '.'], "-");
    Some(
        Path::new(&home)
            .join(".claude")
            .join("projects")
            .join(dashed)
            .join(format!("{session_id}.jsonl")),
    )
}

/// Read + parse the transcript at `path`. Empty on missing / unreadable.
pub fn read(path: &Path) -> Vec<Turn> {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text),
        Err(_) => Vec::new(),
    }
}

/// Parse JSONL `text` into turns (best-effort; unparseable / uninteresting lines skipped).
pub fn parse(text: &str) -> Vec<Turn> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if v.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue; // sub-agent chatter — too noisy for the mirror
        }
        let role = match v.get("type").and_then(Value::as_str) {
            Some("user") => "user",
            Some("assistant") => "assistant",
            _ => continue,
        };
        let Some(content) = v.get("message").and_then(|m| m.get("content")) else {
            continue;
        };
        match content {
            Value::String(s) => {
                let s = s.trim();
                if !s.is_empty() {
                    out.push(if role == "user" {
                        Turn::User(s.to_string())
                    } else {
                        Turn::Assistant(s.to_string())
                    });
                }
            }
            Value::Array(blocks) => {
                for b in blocks {
                    push_block(role, b, &mut out);
                }
            }
            _ => {}
        }
    }
    out
}

fn push_block(role: &str, b: &Value, out: &mut Vec<Turn>) {
    match b.get("type").and_then(Value::as_str) {
        Some("text") => {
            let t = b.get("text").and_then(Value::as_str).unwrap_or("").trim();
            if !t.is_empty() {
                out.push(if role == "user" {
                    Turn::User(t.to_string())
                } else {
                    Turn::Assistant(t.to_string())
                });
            }
        }
        Some("thinking") => {
            let t = b
                .get("thinking")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if !t.is_empty() {
                out.push(Turn::Thinking(first_line(t, 100)));
            }
        }
        Some("tool_use") => {
            let name = b
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("tool")
                .to_string();
            let summary = tool_input_summary(b.get("input"));
            out.push(Turn::ToolUse { name, summary });
        }
        Some("tool_result") => {
            let txt = match b.get("content") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Array(parts)) => parts
                    .iter()
                    .filter_map(|p| p.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n"),
                _ => String::new(),
            };
            let txt = txt.trim();
            if !txt.is_empty() {
                out.push(Turn::ToolResult(first_lines(txt, 2, 200)));
            }
        }
        _ => {}
    }
}

/// A short one-line summary of a tool call's input — the most telling field.
fn tool_input_summary(input: Option<&Value>) -> String {
    let Some(obj) = input.and_then(Value::as_object) else {
        return String::new();
    };
    for key in [
        "command",
        "file_path",
        "path",
        "pattern",
        "query",
        "url",
        "description",
        "prompt",
    ] {
        if let Some(v) = obj.get(key).and_then(Value::as_str) {
            return first_line(v, 80);
        }
    }
    // Fall back to a compact JSON-ish dump of the first key.
    obj.iter()
        .next()
        .map(|(k, v)| format!("{k}={}", first_line(&v.to_string(), 60)))
        .unwrap_or_default()
}

fn first_line(s: &str, max: usize) -> String {
    let line = s.lines().next().unwrap_or("").trim();
    truncate(line, max)
}

fn first_lines(s: &str, n: usize, max: usize) -> String {
    let joined: String = s.lines().take(n).collect::<Vec<_>>().join(" ⏎ ");
    truncate(joined.trim(), max)
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let keep: String = s.chars().take(max.saturating_sub(1)).collect();
        format!("{keep}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_path_dashes_the_cwd() {
        // SAFETY: test-local env mutation; this test doesn't run concurrently with
        // others that read HOME (and it restores it).
        let prev = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", "/home/x") };
        let p = session_path(Path::new("/Users/me/Projects/mnml"), "abc-123").unwrap();
        assert_eq!(
            p,
            Path::new("/home/x/.claude/projects/-Users-me-Projects-mnml/abc-123.jsonl")
        );
        match prev {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }

    #[test]
    fn parses_messages_tools_and_skips_meta_and_sidechains() {
        let jsonl = r#"
{"type":"last-prompt","sessionId":"s"}
{"type":"permission-mode","permissionMode":"plan"}
{"type":"user","message":{"role":"user","content":"hello there"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm\nlet me think"},{"type":"text","text":"Hi! Let me look."},{"type":"tool_use","name":"Bash","input":{"command":"ls -la /tmp\necho done"}}]}}
{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent noise"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"total 0\ndrwxr-xr-x  ...\nmore"}]}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}
"#;
        let turns = parse(jsonl);
        assert_eq!(turns.len(), 6);
        assert_eq!(turns[0], Turn::User("hello there".into()));
        assert!(matches!(&turns[1], Turn::Thinking(s) if s.starts_with("hmm")));
        assert_eq!(turns[2], Turn::Assistant("Hi! Let me look.".into()));
        assert!(
            matches!(&turns[3], Turn::ToolUse { name, summary } if name == "Bash" && summary == "ls -la /tmp")
        );
        assert!(matches!(&turns[4], Turn::ToolResult(s) if s.contains("total 0")));
        assert_eq!(turns[5], Turn::Assistant("Done.".into()));
        // the sidechain line was skipped
        assert!(
            !turns
                .iter()
                .any(|t| matches!(t, Turn::User(s) if s.contains("noise")))
        );
    }

    #[test]
    fn parsing_is_line_local_so_incremental_appends_work() {
        // The live-mirror refresh parses each new tail-of-file chunk separately and
        // appends — that's only sound if `parse` treats lines independently.
        let head = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"one\"}}\n";
        let tail = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}}\n";
        let whole = format!("{head}{tail}");
        let split: Vec<_> = parse(head).into_iter().chain(parse(tail)).collect();
        assert_eq!(split, parse(&whole));
        assert_eq!(
            split,
            vec![Turn::User("one".into()), Turn::Assistant("two".into())]
        );
    }
}
