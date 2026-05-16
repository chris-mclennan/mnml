//! Conform-style external formatters. Picks a command for the active
//! buffer's filetype, pipes the source through it via `$SHELL -c`, and
//! lets the caller (`App::format_external`) splice the stdout back.
//!
//! Two sources of truth:
//!   - `[formatters.<ext>] cmd = "..."` in the user's config (highest
//!     priority — overrides defaults).
//!   - The built-in `DEFAULT_FORMATTERS` table for common extensions.
//!
//! `{file}` in a command is substituted with the buffer's path (so
//! prettier can pick its `.prettierrc`-driven extension behavior). The
//! buffer text is streamed in on stdin; formatter stdout replaces the
//! buffer contents. Non-zero exit ⇒ no change + error preview toast.

use std::path::Path;

/// Built-in defaults — paths that assume the binary is on $PATH. Each
/// entry is a list so the caller can fall through (e.g. try `prettierd`
/// before `prettier`). First successful run wins.
pub const DEFAULT_FORMATTERS: &[(&str, &[&str])] = &[
    ("rs", &["rustfmt --emit stdout"]),
    (
        "ts",
        &[
            "prettier --stdin-filepath {file}",
            "biome format --stdin-file-path={file}",
        ],
    ),
    (
        "tsx",
        &[
            "prettier --stdin-filepath {file}",
            "biome format --stdin-file-path={file}",
        ],
    ),
    (
        "js",
        &[
            "prettier --stdin-filepath {file}",
            "biome format --stdin-file-path={file}",
        ],
    ),
    (
        "jsx",
        &[
            "prettier --stdin-filepath {file}",
            "biome format --stdin-file-path={file}",
        ],
    ),
    ("json", &["prettier --stdin-filepath {file}"]),
    ("css", &["prettier --stdin-filepath {file}"]),
    ("scss", &["prettier --stdin-filepath {file}"]),
    ("html", &["prettier --stdin-filepath {file}"]),
    ("md", &["prettier --stdin-filepath {file}"]),
    ("mdx", &["prettier --stdin-filepath {file}"]),
    ("yaml", &["prettier --stdin-filepath {file}"]),
    ("yml", &["prettier --stdin-filepath {file}"]),
    ("py", &["ruff format -", "black -q -"]),
    ("go", &["gofmt"]),
    ("sh", &["shfmt -i 2"]),
    ("bash", &["shfmt -i 2"]),
    ("zsh", &["shfmt -i 2"]),
    ("lua", &["stylua -"]),
    ("nix", &["nixfmt"]),
];

/// Look up the formatter command list for an extension. Config table
/// overrides built-in defaults; an empty list means "no formatter".
pub fn formatters_for(
    cfg: &std::collections::BTreeMap<String, FormatterEntry>,
    ext: &str,
) -> Vec<String> {
    if let Some(entry) = cfg.get(ext) {
        return entry.cmd.to_vec();
    }
    for (e, list) in DEFAULT_FORMATTERS {
        if *e == ext {
            return list.iter().map(|s| s.to_string()).collect();
        }
    }
    Vec::new()
}

/// Substitute `{file}` in a command template with the buffer's path
/// (workspace-relative if possible; absolute otherwise). Returns the
/// command verbatim if `{file}` isn't present.
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

/// Minimal shell-safe quoting for the `{file}` substitution. Wraps the
/// value in single quotes and escapes inner single quotes.
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

/// Run a formatter command synchronously: writes `input` to stdin,
/// returns `Ok(stdout)` on exit 0, `Err(preview)` otherwise. The
/// formatter inherits the workspace as its cwd.
pub fn run_formatter(cmd: &str, workspace: &Path, input: &str) -> Result<String, String> {
    use std::io::Write;
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    let mut child = std::process::Command::new(&shell)
        .arg("-c")
        .arg(cmd)
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
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let preview: String = stderr.trim().chars().take(120).collect();
        return Err(format!(
            "exit {} — {preview}",
            out.status.code().unwrap_or(-1)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Config table entry — `[formatters.<ext>] cmd = ["..."]` (TOML).
/// Single-string forms are accepted via `Deserialize` flattening.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct FormatterEntry {
    #[serde(default, deserialize_with = "deserialize_cmd_list")]
    pub cmd: Vec<String>,
}

/// Accept either a string or a list-of-strings for `cmd`.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expand_substitutes_file_placeholder() {
        let ws = Path::new("/repo");
        let p = Path::new("/repo/src/main.rs");
        assert_eq!(
            expand_cmd("prettier --stdin-filepath {file}", ws, Some(p)),
            "prettier --stdin-filepath src/main.rs"
        );
    }

    #[test]
    fn expand_quotes_paths_with_spaces() {
        let ws = Path::new("/repo");
        let p = Path::new("/repo/Has Space/x.ts");
        let got = expand_cmd("prettier --stdin-filepath {file}", ws, Some(p));
        assert!(got.contains("'Has Space/x.ts'"));
    }

    #[test]
    fn expand_leaves_template_alone_when_no_placeholder() {
        let ws = Path::new("/repo");
        let got = expand_cmd("gofmt", ws, Some(Path::new("/repo/main.go")));
        assert_eq!(got, "gofmt");
    }

    #[test]
    fn formatters_for_picks_config_over_defaults() {
        let mut cfg = std::collections::BTreeMap::new();
        cfg.insert(
            "rs".to_string(),
            FormatterEntry {
                cmd: vec!["custom-rust-fmt".into()],
            },
        );
        let got = formatters_for(&cfg, "rs");
        assert_eq!(got, vec!["custom-rust-fmt".to_string()]);
    }

    #[test]
    fn formatters_for_returns_defaults_for_known_ext() {
        let cfg = std::collections::BTreeMap::new();
        let got = formatters_for(&cfg, "py");
        assert!(got.iter().any(|c| c.starts_with("ruff format")));
    }

    #[test]
    fn formatters_for_empty_for_unknown_ext() {
        let cfg = std::collections::BTreeMap::new();
        assert!(formatters_for(&cfg, "unobtanium").is_empty());
    }
}
