//! Themed powerline shell prompt — installs `themes/mnml-prompt.sh` to
//! the user's config dir and emits the env vars the script reads.
//!
//! The script is sourceable from `~/.zshrc` / `~/.bashrc` via the
//! one-line opt-in documented in README.md. When `$MNML_PROMPT_SCRIPT`
//! is unset (normal shells outside mnml) the opt-in line is a
//! no-op.
//!
//! Used by [`crate::pty_pane::PtySession::spawn`] — any shell pty mnml
//! spawns inherits the env so its prompt themes against the current
//! mnml palette.
//!
//! Naming note: the related `crate::prompt` module is mnml's
//! single-line text-input overlay (command prompt for `:commit -m …`
//! and friends), nothing to do with shells.

use std::io;
use std::path::PathBuf;

use ratatui::style::Color;

use crate::ui::theme;

/// Embedded script content — written to disk lazily by
/// [`install_prompt_script`]. Bumping this string here is the
/// authoritative way to update the prompt across an mnml install.
const SCRIPT: &str = include_str!("../themes/mnml-prompt.sh");

/// `themes/mnml-prompt.sh` location on the user's machine. We write
/// to `$XDG_CONFIG_HOME/mnml/prompt.sh` (or `~/.config/mnml/prompt.sh`),
/// not the repo path, so this works for installed binaries that don't
/// have the source tree available.
pub fn script_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("mnml").join("prompt.sh")
}

/// Ensure the prompt script exists at [`script_path`] and matches the
/// embedded version. Returns the path on success. Idempotent — cheap
/// to call on every shell spawn.
///
/// We compare contents rather than mtime so an mnml upgrade with a
/// newer script gets picked up without the user having to delete the
/// installed copy by hand.
pub fn install_prompt_script() -> io::Result<PathBuf> {
    let path = script_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let needs_write = match std::fs::read_to_string(&path) {
        Ok(existing) => existing != SCRIPT,
        Err(_) => true,
    };
    if needs_write {
        std::fs::write(&path, SCRIPT)?;
    }
    Ok(path)
}

/// The env-var pairs to inject into a spawned shell so the prompt
/// script picks up the current mnml palette. `context_label` is the
/// chip text on the right side ("mnml" / shell-name).
pub fn theme_env_vars(context_label: &str) -> Vec<(String, String)> {
    let t = theme::cur();
    let mut out = vec![
        ("MNML_PROMPT_BG".into(), hex(t.bg_darker)),
        ("MNML_PROMPT_FG".into(), hex(t.fg)),
        // `teal` is the family's accent (matches the bufferline focused
        // tab + statusline mode chip); fall back to `blue` if a theme
        // happens to leave teal unset (none do today).
        ("MNML_PROMPT_ACCENT".into(), hex(t.teal)),
        ("MNML_PROMPT_GREEN".into(), hex(t.green)),
        ("MNML_PROMPT_RED".into(), hex(t.red)),
        ("MNML_PROMPT_YELLOW".into(), hex(t.yellow)),
        ("MNML_PROMPT_GREY".into(), hex(t.grey)),
        ("MNML_CONTEXT".into(), context_label.to_string()),
    ];
    // `MNML_PROMPT_SCRIPT` is set after [`install_prompt_script`] so it
    // always reflects the resolved on-disk path.
    if let Ok(path) = install_prompt_script() {
        out.push(("MNML_PROMPT_SCRIPT".into(), path.display().to_string()));
    }
    out
}

/// Stringify a [`ratatui::style::Color`] as `#RRGGBB`. Falls back to
/// `#000000` for named / indexed colors (the script's own defaults
/// kick in for those, which is fine — none of our shipped themes use
/// non-RGB colors).
fn hex(c: Color) -> String {
    match c {
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
        _ => "#000000".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_formats_rgb_lowercase() {
        assert_eq!(hex(Color::Rgb(0xAB, 0xCD, 0xEF)), "#abcdef");
        assert_eq!(hex(Color::Rgb(0, 0, 0)), "#000000");
        assert_eq!(hex(Color::Rgb(255, 255, 255)), "#ffffff");
    }

    #[test]
    fn hex_falls_back_on_named_colors() {
        // Named colors round-trip to "#000000" — the shell script's own
        // defaults are the real fallback here.
        assert_eq!(hex(Color::Reset), "#000000");
        assert_eq!(hex(Color::Blue), "#000000");
    }

    #[test]
    fn theme_env_vars_includes_all_keys_and_context() {
        // Sandbox `$HOME` so install_prompt_script() doesn't write to
        // the real `~/.config/mnml/prompt.sh` on a developer machine.
        let d = tempfile::tempdir().unwrap();
        // SAFETY: tests serialize env via this one writer.
        unsafe {
            std::env::set_var("HOME", d.path());
            std::env::remove_var("XDG_CONFIG_HOME");
        }
        let v = theme_env_vars("mnml");
        let keys: Vec<&str> = v.iter().map(|(k, _)| k.as_str()).collect();
        for needed in &[
            "MNML_PROMPT_BG",
            "MNML_PROMPT_FG",
            "MNML_PROMPT_ACCENT",
            "MNML_PROMPT_GREEN",
            "MNML_PROMPT_RED",
            "MNML_PROMPT_YELLOW",
            "MNML_PROMPT_GREY",
            "MNML_CONTEXT",
            "MNML_PROMPT_SCRIPT",
        ] {
            assert!(keys.contains(needed), "missing {needed} in env vars");
        }
        let ctx = v.iter().find(|(k, _)| k == "MNML_CONTEXT").unwrap();
        assert_eq!(ctx.1, "mnml");
        // Script written into the tempdir, not the real ~/.
        let script = v.iter().find(|(k, _)| k == "MNML_PROMPT_SCRIPT").unwrap();
        assert!(
            script
                .1
                .starts_with(d.path().display().to_string().as_str())
        );
        assert!(std::path::Path::new(&script.1).exists());
    }
}
