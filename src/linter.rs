//! External linter integration. Picks a linter command for the active
//! buffer's filetype, runs it (in a background thread; linters can be
//! slow), parses the output into LSP-shaped `Diagnostic`s, and surfaces
//! them on `Buffer.linter_diagnostics`. The diagnostics pane + gutter
//! signs + statusline counts merge LSP and linter diagnostics.
//!
//! Two sources of truth:
//!   - `[linters.<ext>] cmd = "..."` + `parser = "..."` in the user's
//!     config (highest priority — overrides defaults).
//!   - The built-in `DEFAULT_LINTERS` table for common extensions.
//!
//! `{file}` in a command is substituted with the workspace-relative
//! path. Output is parsed by the named parser ("eslint", "tsc", "ruff",
//! "shellcheck", "vimgrep"). Non-zero exit codes are *expected* (most
//! linters exit non-zero when they find issues) so the parser runs on
//! stdout even on non-zero exit; only spawn failures are toasted.

use std::path::{Path, PathBuf};

use crate::lsp::{Diagnostic, Pos, Range, Severity};

/// Built-in defaults. First entry whose command resolves wins.
pub const DEFAULT_LINTERS: &[(&str, &[(&str, &str)])] = &[
    // (ext, [(parser, cmd), ...])
    (
        "ts",
        &[(
            "eslint",
            "eslint --no-color --format=unix --stdin --stdin-filename {file}",
        )],
    ),
    (
        "tsx",
        &[(
            "eslint",
            "eslint --no-color --format=unix --stdin --stdin-filename {file}",
        )],
    ),
    (
        "js",
        &[(
            "eslint",
            "eslint --no-color --format=unix --stdin --stdin-filename {file}",
        )],
    ),
    (
        "jsx",
        &[(
            "eslint",
            "eslint --no-color --format=unix --stdin --stdin-filename {file}",
        )],
    ),
    (
        "py",
        &[("ruff", "ruff check --no-color --output-format=concise -")],
    ),
    ("sh", &[("shellcheck", "shellcheck --format=gcc -")]),
    ("bash", &[("shellcheck", "shellcheck --format=gcc -")]),
    ("zsh", &[("shellcheck", "shellcheck --format=gcc -")]),
];

/// Config table entry — `[linters.<ext>] cmd = "..."` `parser = "eslint"`.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct LinterEntry {
    #[serde(default, deserialize_with = "deserialize_cmd_list")]
    pub cmd: Vec<String>,
    /// Parser name: `"eslint"` / `"tsc"` / `"ruff"` / `"shellcheck"` /
    /// `"vimgrep"` (default). Falls back to `"vimgrep"` for unknown
    /// names — the most permissive parser, accepts `path:line:col: msg`.
    #[serde(default)]
    pub parser: Option<String>,
}

fn deserialize_cmd_list<'de, D>(d: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum One {
        S(String),
        Many(Vec<String>),
    }
    match One::deserialize(d)? {
        One::S(s) => Ok(vec![s]),
        One::Many(v) => Ok(v),
    }
}

/// Resolved linter recipe — what the App fires.
#[derive(Debug, Clone)]
pub struct LinterCmd {
    pub cmd: String,
    pub parser: String,
}

/// Look up the linter recipe(s) for an extension. Config table
/// overrides built-in defaults.
pub fn linters_for(
    cfg: &std::collections::BTreeMap<String, LinterEntry>,
    ext: &str,
) -> Vec<LinterCmd> {
    if let Some(entry) = cfg.get(ext) {
        let parser = entry.parser.clone().unwrap_or_else(|| "vimgrep".into());
        return entry
            .cmd
            .iter()
            .map(|c| LinterCmd {
                cmd: c.clone(),
                parser: parser.clone(),
            })
            .collect();
    }
    for (e, list) in DEFAULT_LINTERS {
        if *e == ext {
            return list
                .iter()
                .map(|(p, c)| LinterCmd {
                    cmd: c.to_string(),
                    parser: p.to_string(),
                })
                .collect();
        }
    }
    Vec::new()
}

/// Substitute `{file}` placeholder. Mirrors `formatter::expand_cmd`.
pub fn expand_cmd(template: &str, workspace: &Path, path: Option<&Path>) -> String {
    if !template.contains("{file}") {
        return template.to_string();
    }
    let file_str = match path {
        Some(p) => p
            .strip_prefix(workspace)
            .map(|r| r.display().to_string())
            .unwrap_or_else(|_| p.display().to_string()),
        None => "stdin".to_string(),
    };
    template.replace("{file}", &shell_quote(&file_str))
}

fn shell_quote(s: &str) -> String {
    if !s
        .chars()
        .any(|c| c.is_whitespace() || c == '\'' || c == '"' || c == '\\' || c == '$' || c == '`')
    {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// Run a linter synchronously. Returns parsed diagnostics regardless of
/// exit code (linters typically exit non-zero on findings). Only spawn
/// errors return `Err`.
pub fn run_linter(
    recipe: &LinterCmd,
    workspace: &Path,
    input: &str,
    file_path: Option<&Path>,
) -> Result<Vec<Diagnostic>, String> {
    use std::io::Write;
    let cmd = expand_cmd(&recipe.cmd, workspace, file_path);
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    let mut child = std::process::Command::new(&shell)
        .arg("-c")
        .arg(&cmd)
        .current_dir(workspace)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes());
    }
    let out = child.wait_with_output().map_err(|e| format!("wait: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    // Combine stdout + stderr for parsing — some linters write to stderr.
    let combined = if stdout.is_empty() { stderr } else { stdout };
    Ok(parse_output(&recipe.parser, &combined, file_path))
}

/// Parse linter output by named parser. Falls back to vimgrep for unknown.
pub fn parse_output(parser: &str, text: &str, file_path: Option<&Path>) -> Vec<Diagnostic> {
    match parser {
        "eslint" => parse_eslint_unix(text, file_path),
        "tsc" => parse_tsc(text, file_path),
        "ruff" => parse_ruff(text, file_path),
        "shellcheck" => parse_shellcheck_gcc(text, file_path),
        _ => parse_vimgrep(text, file_path),
    }
}

/// `path:line:col: message [rulename] (severity)` — eslint `--format=unix`.
/// `severity` is "Error" or "Warning" (eslint's two levels).
fn parse_eslint_unix(text: &str, file_path: Option<&Path>) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    for line in text.lines() {
        // Split on first `:` after the first non-empty char that's not part
        // of a Windows drive letter; for our purposes `path:line:col: msg`.
        let (lo, msg) = match split_path_line_col(line) {
            Some(v) => v,
            None => continue,
        };
        if !path_matches(&lo.0, file_path) {
            continue;
        }
        let (severity, message) = if let Some(rest) = msg.strip_suffix(" (Warning)") {
            (Severity::Warning, rest.to_string())
        } else if let Some(rest) = msg.strip_suffix(" (Error)") {
            (Severity::Error, rest.to_string())
        } else {
            (Severity::Warning, msg)
        };
        out.push(Diagnostic {
            range: line_col_range(lo.1, lo.2),
            severity,
            message,
            source: Some("eslint".into()),
        });
    }
    out
}

/// `path(line,col): error TSnnnn: message` — TypeScript compiler.
fn parse_tsc(text: &str, file_path: Option<&Path>) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    for line in text.lines() {
        // Find `(LINE,COL):` shape.
        let Some(lp) = line.find('(') else { continue };
        let Some(rp) = line[lp..].find(')') else {
            continue;
        };
        let coords = &line[lp + 1..lp + rp];
        let mut parts = coords.splitn(2, ',');
        let (l, c) = match (parts.next(), parts.next()) {
            (Some(l), Some(c)) => (l, c),
            _ => continue,
        };
        let (Ok(line_no), Ok(col)) = (l.trim().parse::<u32>(), c.trim().parse::<u32>()) else {
            continue;
        };
        let path_part = line[..lp].trim();
        if !path_matches(path_part, file_path) {
            continue;
        }
        let after = &line[lp + rp + 1..];
        let after = after.trim_start_matches(':').trim();
        let (severity, rest) = if let Some(r) = after.strip_prefix("error") {
            (Severity::Error, r.trim_start().to_string())
        } else if let Some(r) = after.strip_prefix("warning") {
            (Severity::Warning, r.trim_start().to_string())
        } else {
            (Severity::Error, after.to_string())
        };
        out.push(Diagnostic {
            range: line_col_range(line_no.saturating_sub(1), col.saturating_sub(1)),
            severity,
            message: rest,
            source: Some("tsc".into()),
        });
    }
    out
}

/// `path:line:col: CODE message` — ruff `--output-format=concise`.
fn parse_ruff(text: &str, file_path: Option<&Path>) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    for line in text.lines() {
        let Some((lo, msg)) = split_path_line_col(line) else {
            continue;
        };
        if !path_matches(&lo.0, file_path) {
            continue;
        }
        out.push(Diagnostic {
            range: line_col_range(lo.1, lo.2),
            severity: Severity::Warning,
            message: msg,
            source: Some("ruff".into()),
        });
    }
    out
}

/// `path:line:col: severity: code: message` — shellcheck `--format=gcc`.
fn parse_shellcheck_gcc(text: &str, file_path: Option<&Path>) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    for line in text.lines() {
        let Some((lo, msg)) = split_path_line_col(line) else {
            continue;
        };
        if !path_matches(&lo.0, file_path) {
            continue;
        }
        // `error:` / `warning:` / `note:` prefix.
        let (severity, rest) = if let Some(r) = msg.strip_prefix("error: ") {
            (Severity::Error, r.to_string())
        } else if let Some(r) = msg.strip_prefix("warning: ") {
            (Severity::Warning, r.to_string())
        } else if let Some(r) = msg.strip_prefix("note: ") {
            (Severity::Info, r.to_string())
        } else {
            (Severity::Warning, msg)
        };
        out.push(Diagnostic {
            range: line_col_range(lo.1, lo.2),
            severity,
            message: rest,
            source: Some("shellcheck".into()),
        });
    }
    out
}

/// `path:line:col: message` — the generic fallback.
fn parse_vimgrep(text: &str, file_path: Option<&Path>) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    for line in text.lines() {
        let Some((lo, msg)) = split_path_line_col(line) else {
            continue;
        };
        if !path_matches(&lo.0, file_path) {
            continue;
        }
        out.push(Diagnostic {
            range: line_col_range(lo.1, lo.2),
            severity: Severity::Warning,
            message: msg,
            source: None,
        });
    }
    out
}

/// Split a `<path>:<line>:<col>: <msg>` line. Returns
/// `((path, line0, col0), msg)`. Lines/cols are converted to 0-based.
fn split_path_line_col(line: &str) -> Option<((String, u32, u32), String)> {
    // Walk from the right so a `:` in the message doesn't fool us.
    // First find `: ` (colon + space) marking the message boundary.
    let msg_sep = line.find(": ")?;
    let head = &line[..msg_sep];
    let msg = line[msg_sep + 2..].trim().to_string();
    // `head` should now be `path:line:col` (col optional).
    let mut parts: Vec<&str> = head.rsplitn(3, ':').collect();
    parts.reverse();
    let (path, line_no, col_no) = match parts.as_slice() {
        [p, l, c] => (
            (*p).to_string(),
            (*l).trim().parse::<u32>().ok()?,
            (*c).trim().parse::<u32>().unwrap_or(1),
        ),
        [p, l] => ((*p).to_string(), (*l).trim().parse::<u32>().ok()?, 1),
        _ => return None,
    };
    Some((
        (path, line_no.saturating_sub(1), col_no.saturating_sub(1)),
        msg,
    ))
}

/// Compare a path from linter output to the buffer's path. We accept
/// matches whose suffix matches (so workspace-relative vs absolute, or
/// `stdin`-like placeholders that some linters emit, all line up).
fn path_matches(parsed: &str, expected: Option<&Path>) -> bool {
    let Some(expected) = expected else {
        return true;
    };
    let parsed_p = PathBuf::from(parsed);
    if parsed_p == expected {
        return true;
    }
    // Suffix match — eslint emits the workspace-relative path; the
    // expected is absolute. Walk components from the end.
    let exp_comps: Vec<_> = expected.components().collect();
    let par_comps: Vec<_> = parsed_p.components().collect();
    if par_comps.is_empty() {
        return false;
    }
    if par_comps.len() > exp_comps.len() {
        return false;
    }
    let off = exp_comps.len() - par_comps.len();
    par_comps
        .iter()
        .zip(exp_comps[off..].iter())
        .all(|(a, b)| a == b)
}

fn line_col_range(line0: u32, col0: u32) -> Range {
    Range {
        start: Pos {
            line: line0,
            character: col0,
        },
        end: Pos {
            line: line0,
            character: col0 + 1,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn eslint_unix_parses_one_diagnostic() {
        let out = "/repo/foo.ts:3:5: 'x' is defined but never used [Error/no-unused-vars] (Error)";
        let diags = parse_eslint_unix(out, Some(Path::new("/repo/foo.ts")));
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start.line, 2);
        assert_eq!(diags[0].range.start.character, 4);
        assert_eq!(diags[0].severity, Severity::Error);
        assert!(diags[0].message.contains("'x' is defined"));
    }

    #[test]
    fn tsc_parses_diagnostic() {
        let out = "src/foo.ts(10,3): error TS2304: Cannot find name 'fooo'.";
        let diags = parse_tsc(out, Some(Path::new("/repo/src/foo.ts")));
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start.line, 9);
        assert_eq!(diags[0].range.start.character, 2);
        assert_eq!(diags[0].severity, Severity::Error);
        assert!(diags[0].message.contains("TS2304"));
    }

    #[test]
    fn ruff_parses_diagnostic() {
        let out = "main.py:5:1: E402 module level import not at top of file";
        let diags = parse_ruff(out, Some(Path::new("/repo/main.py")));
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start.line, 4);
    }

    #[test]
    fn shellcheck_gcc_parses_warning() {
        let out = "-:5:7: warning: SC2086: Double quote to prevent globbing.";
        let diags = parse_shellcheck_gcc(out, None);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
    }

    #[test]
    fn vimgrep_falls_back_when_unknown_parser() {
        let out = "/repo/file.txt:1:1: something happened";
        let diags = parse_output("unknown", out, Some(Path::new("/repo/file.txt")));
        assert_eq!(diags.len(), 1);
    }

    #[test]
    fn linters_for_picks_config_over_defaults() {
        let mut cfg = std::collections::BTreeMap::new();
        cfg.insert(
            "py".to_string(),
            LinterEntry {
                cmd: vec!["my-py-linter".into()],
                parser: Some("ruff".into()),
            },
        );
        let got = linters_for(&cfg, "py");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].cmd, "my-py-linter");
    }

    #[test]
    fn linters_for_returns_defaults_for_known_ext() {
        let cfg = std::collections::BTreeMap::new();
        let got = linters_for(&cfg, "ts");
        assert!(got.iter().any(|c| c.cmd.contains("eslint")));
    }

    #[test]
    fn path_matches_handles_relative_and_absolute() {
        let abs = Path::new("/repo/src/foo.ts");
        assert!(path_matches("/repo/src/foo.ts", Some(abs)));
        assert!(path_matches("src/foo.ts", Some(abs)));
        assert!(path_matches("foo.ts", Some(abs)));
        assert!(!path_matches("bar.ts", Some(abs)));
    }
}
