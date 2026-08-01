//! Variable substitution engine for launcher action templates.
//!
//! A launcher's `run` string can reference mnml runtime context via
//! `{{name}}` tokens — e.g. `code {{workspace}}/{{current_file}}:{{cursor_line}}`.
//! At spawn time [`expand`] walks the template, substitutes each
//! recognized token, and leaves unrecognized tokens literal (best-effort:
//! a launcher misspelling `{{workspce}}` still executes with the literal
//! text, easier to debug than a hard error).
//!
//! ## Supported variables
//!
//! | Token | Meaning | Empty when |
//! |---|---|---|
//! | `{{workspace}}` | absolute path of the active workspace root | never |
//! | `{{workspace_name}}` | basename of the workspace | never |
//! | `{{current_file}}` | active file path relative to workspace | no editor pane focused |
//! | `{{current_file_abs}}` | absolute path of the current file | no editor pane focused |
//! | `{{current_file_dir}}` | directory of the current file (abs) | no editor pane focused |
//! | `{{cursor_line}}` | 1-indexed cursor line | no editor pane focused |
//! | `{{cursor_col}}` | 1-indexed cursor column | no editor pane focused |
//! | `{{selection}}` | selected text (single line) | no selection |
//!
//! ## Not implemented yet
//!
//! - `{{prompt:name}}` — prompt user for a value at spawn time.
//!   Requires the launcher-edit-overlay work in P5; substitution
//!   happens async through the prompt subsystem, not synchronously
//!   in `expand`. For now, `{{prompt:*}}` tokens are left literal.
//!
//! ## Design notes
//!
//! - Templates are string-in / string-out. No syntax tree, no
//!   escaping — just find/replace of a small closed set of tokens.
//! - Unknown tokens stay literal. Rationale: launchers may target
//!   OS templating conventions (`{{@}}`, `${VAR}`) that mnml
//!   shouldn't intercept.
//! - The engine is pure: it takes a [`TemplateContext`] snapshot,
//!   not a live App reference. Callers assemble the context from
//!   their side of the borrow.

use std::path::{Path, PathBuf};

/// Runtime context snapshot for template expansion. Assembled by
/// the caller from live App state. Kept small — one Option per
/// variable — so the engine stays a pure function of its inputs.
#[derive(Debug, Clone, Default)]
pub struct TemplateContext {
    pub workspace: PathBuf,
    pub current_file: Option<PathBuf>,
    pub cursor_line: Option<usize>,
    pub cursor_col: Option<usize>,
    pub selection: Option<String>,
}

impl TemplateContext {
    /// Build a minimal context with only the workspace root — used
    /// when the caller doesn't need editor-side variables.
    pub fn workspace_only(workspace: PathBuf) -> Self {
        Self {
            workspace,
            current_file: None,
            cursor_line: None,
            cursor_col: None,
            selection: None,
        }
    }
}

/// Expand `{{name}}` tokens in `template` using `ctx`. Unknown
/// tokens are left literal.
pub fn expand(template: &str, ctx: &TemplateContext) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(open) = rest.find("{{") {
        // Copy up to the `{{`.
        out.push_str(&rest[..open]);
        let after_open = &rest[open + 2..];
        if let Some(close) = after_open.find("}}") {
            let token = &after_open[..close];
            let replaced = substitute(token, ctx);
            match replaced {
                Some(value) => out.push_str(&value),
                None => {
                    // Unknown token — leave literal (including the braces).
                    out.push_str("{{");
                    out.push_str(token);
                    out.push_str("}}");
                }
            }
            rest = &after_open[close + 2..];
        } else {
            // Unmatched `{{` — treat as literal for the rest of the string.
            out.push_str("{{");
            rest = after_open;
        }
    }
    out.push_str(rest);
    out
}

/// Resolve a single token name to its runtime value.
///
/// Returns:
/// - `Some(String)` when the token is recognized (even if the
///   underlying value is empty — an empty current_file becomes `""`
///   in the output, not a literal `{{current_file}}`).
/// - `None` when the token isn't recognized — caller preserves
///   the literal `{{name}}`.
fn substitute(token: &str, ctx: &TemplateContext) -> Option<String> {
    // `{{prompt:name}}` — reserved for P5. Left literal for now.
    if token.starts_with("prompt:") {
        return None;
    }
    match token {
        "workspace" => Some(ctx.workspace.to_string_lossy().into_owned()),
        "workspace_name" => Some(
            ctx.workspace
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
        ),
        "current_file" => Some(
            ctx.current_file
                .as_ref()
                .map(|p| relative_or_abs(p, &ctx.workspace))
                .unwrap_or_default(),
        ),
        "current_file_abs" => Some(
            ctx.current_file
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default(),
        ),
        "current_file_dir" => Some(
            ctx.current_file
                .as_ref()
                .and_then(|p| p.parent())
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default(),
        ),
        "cursor_line" => Some(ctx.cursor_line.map(|n| n.to_string()).unwrap_or_default()),
        "cursor_col" => Some(ctx.cursor_col.map(|n| n.to_string()).unwrap_or_default()),
        "selection" => Some(ctx.selection.clone().unwrap_or_default()),
        _ => None,
    }
}

/// If `p` is under `workspace`, render it workspace-relative;
/// otherwise render its absolute form. Uses `strip_prefix` — no
/// canonicalization (`current_file` is expected to already be an
/// absolute path from the editor pane).
fn relative_or_abs(p: &Path, workspace: &Path) -> String {
    match p.strip_prefix(workspace) {
        Ok(rel) => rel.to_string_lossy().into_owned(),
        Err(_) => p.to_string_lossy().into_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> TemplateContext {
        TemplateContext {
            workspace: PathBuf::from("/proj/foo"),
            current_file: Some(PathBuf::from("/proj/foo/src/main.rs")),
            cursor_line: Some(42),
            cursor_col: Some(7),
            selection: Some("hello".to_string()),
        }
    }

    #[test]
    fn expands_workspace() {
        assert_eq!(expand("cd {{workspace}}", &ctx()), "cd /proj/foo");
    }

    #[test]
    fn expands_workspace_name() {
        assert_eq!(expand("{{workspace_name}}", &ctx()), "foo");
    }

    #[test]
    fn expands_current_file_relative_to_workspace() {
        assert_eq!(expand("{{current_file}}", &ctx()), "src/main.rs");
    }

    #[test]
    fn expands_current_file_abs() {
        assert_eq!(
            expand("{{current_file_abs}}", &ctx()),
            "/proj/foo/src/main.rs"
        );
    }

    #[test]
    fn expands_current_file_dir() {
        assert_eq!(expand("{{current_file_dir}}", &ctx()), "/proj/foo/src");
    }

    #[test]
    fn expands_cursor_position() {
        assert_eq!(
            expand("{{current_file}}:{{cursor_line}}:{{cursor_col}}", &ctx()),
            "src/main.rs:42:7"
        );
    }

    #[test]
    fn expands_selection() {
        assert_eq!(expand("echo {{selection}}", &ctx()), "echo hello");
    }

    #[test]
    fn empty_current_file_when_none() {
        let mut c = ctx();
        c.current_file = None;
        assert_eq!(expand("code {{current_file}}", &c), "code ");
    }

    #[test]
    fn unknown_token_stays_literal() {
        assert_eq!(expand("run {{typo}} now", &ctx()), "run {{typo}} now");
    }

    #[test]
    fn prompt_token_stays_literal() {
        // {{prompt:X}} is reserved for P5 — must not silently drop.
        assert_eq!(
            expand("diff {{prompt:target}}", &ctx()),
            "diff {{prompt:target}}"
        );
    }

    #[test]
    fn unmatched_open_brace_stays_literal() {
        assert_eq!(expand("weird {{ no close", &ctx()), "weird {{ no close");
    }

    #[test]
    fn no_tokens_passes_through() {
        assert_eq!(expand("just a plain string", &ctx()), "just a plain string");
    }

    #[test]
    fn empty_input() {
        assert_eq!(expand("", &ctx()), "");
    }

    #[test]
    fn multiple_same_token() {
        assert_eq!(
            expand("{{workspace}}/{{workspace}}", &ctx()),
            "/proj/foo//proj/foo"
        );
    }

    #[test]
    fn current_file_outside_workspace_falls_back_to_abs() {
        let mut c = ctx();
        c.current_file = Some(PathBuf::from("/tmp/outside.rs"));
        assert_eq!(expand("{{current_file}}", &c), "/tmp/outside.rs");
    }

    #[test]
    fn workspace_only_context_leaves_editor_vars_empty() {
        let c = TemplateContext::workspace_only(PathBuf::from("/proj/bar"));
        assert_eq!(
            expand("{{workspace}} {{current_file}} {{cursor_line}}", &c),
            "/proj/bar  "
        );
    }
}
