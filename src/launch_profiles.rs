//! AI launch profiles — multiple named launch commands per AI chip
//! (task #1203, 2026-08-25).
//!
//! A user who sometimes wants plain `claude` and sometimes a wrapper
//! script (e.g. tattle-claude-workspace's `bin/claude-multi.sh` with
//! its `--add-dir` flags) declares both as *profiles* of the SAME
//! `claude_code` chip instead of installing a second integration:
//!
//! ```toml
//! # <workspace>/.mnml/integrations/claude_code.toml
//! default_profile = "multi-repo"
//!
//! [[launch_profile]]
//! name = "multi-repo"
//! command = "{{workspace}}/bin/claude-multi.sh"
//! ```
//!
//! The chip's right-click menu grows "New session: <name>" rows (fire
//! one session with that profile, no state change) and "Default:
//! <name>" rows (persist `default_profile` to the workspace manifest).
//! Plain clicks / palette commands keep spawning the default profile
//! via `pty_pane::resolve_launcher`, which delegates here.
//!
//! Scopes + precedence (same file pair the manifest loader uses):
//!   - `~/.config/mnml/integrations/<id>.toml` — user-global
//!   - `<workspace>/.mnml/integrations/<id>.toml` — workspace (wins)
//!
//! Back-compat: the single-field `launcher = "…"` form written by the
//! chip's "Set launcher script…" prompt becomes a profile named
//! `wrapper`, and stays the default when no explicit
//! `default_profile` key is present — existing setups behave
//! identically.
//!
//! `command` is an executable path (template-expanded — `{{workspace}}`
//! etc. via [`crate::launcher_template`]), NOT a shell line. Flags
//! belong inside a wrapper script; mnml appends its own args
//! (`--session-id`, `--append-system-prompt`, …) after the exe.

use std::path::Path;

/// The implicit profile every AI chip has: the bare product binary
/// (`claude` / `codex`) on PATH.
pub const BUILTIN_PROFILE: &str = "default";

/// Name given to the legacy single-field `launcher = "…"` override so
/// it participates in the profile list.
pub const LEGACY_PROFILE: &str = "wrapper";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchProfile {
    pub name: String,
    /// Unexpanded command template — expand at spawn time so a
    /// workspace switch doesn't bake in a stale path.
    pub command: String,
}

#[derive(Debug, Clone)]
pub struct LaunchProfiles {
    /// Builtin first, then user-scope, then workspace-scope entries
    /// (same-name later entries replace earlier ones in place).
    pub profiles: Vec<LaunchProfile>,
    pub default_name: String,
}

impl LaunchProfiles {
    /// Load + merge both scopes for integration `id`.
    pub fn load(workspace: &Path, id: &str, default_exe: &str) -> Self {
        let user_text = user_manifest_path(id).and_then(|p| std::fs::read_to_string(p).ok());
        let ws_text = std::fs::read_to_string(workspace_manifest_path(workspace, id)).ok();
        merge(default_exe, user_text.as_deref(), ws_text.as_deref())
    }

    /// The default profile's command, template-expanded — what a
    /// plain chip click / palette command should spawn.
    pub fn default_command(&self, workspace: &Path) -> String {
        self.command_for(&self.default_name, workspace)
            .unwrap_or_else(|| {
                // default_name always names a profile (merge guarantees
                // it), but stay total anyway.
                self.profiles
                    .first()
                    .map(|p| p.command.clone())
                    .unwrap_or_default()
            })
    }

    /// A named profile's command, template-expanded. `None` when the
    /// name doesn't resolve (e.g. a workspace-scoped profile
    /// referenced from a different workspace).
    pub fn command_for(&self, name: &str, workspace: &Path) -> Option<String> {
        let p = self.profiles.iter().find(|p| p.name == name)?;
        let ctx =
            crate::launcher_template::TemplateContext::workspace_only(workspace.to_path_buf());
        Some(crate::launcher_template::expand(&p.command, &ctx))
    }
}

fn user_manifest_path(id: &str) -> Option<std::path::PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        std::path::PathBuf::from(home)
            .join(".config")
            .join("mnml")
            .join("integrations")
            .join(format!("{id}.toml")),
    )
}

fn workspace_manifest_path(workspace: &Path, id: &str) -> std::path::PathBuf {
    workspace
        .join(".mnml")
        .join("integrations")
        .join(format!("{id}.toml"))
}

/// One parsed scope: the fields this module cares about, junk-tolerant
/// (the same files carry full IntegrationManifest content).
struct ScopeFields {
    legacy_launcher: Option<String>,
    profiles: Vec<LaunchProfile>,
    default_profile: Option<String>,
}

fn parse_scope(text: &str) -> ScopeFields {
    let mut out = ScopeFields {
        legacy_launcher: None,
        profiles: Vec::new(),
        default_profile: None,
    };
    let Ok(val) = text.parse::<toml::Value>() else {
        return out;
    };
    if let Some(s) = val.get("launcher").and_then(|v| v.as_str())
        && !s.trim().is_empty()
    {
        out.legacy_launcher = Some(s.trim().to_string());
    }
    if let Some(s) = val.get("default_profile").and_then(|v| v.as_str())
        && !s.trim().is_empty()
    {
        out.default_profile = Some(s.trim().to_string());
    }
    if let Some(arr) = val.get("launch_profile").and_then(|v| v.as_array()) {
        for entry in arr {
            let name = entry.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let command = entry.get("command").and_then(|v| v.as_str()).unwrap_or("");
            if !name.trim().is_empty() && !command.trim().is_empty() {
                out.profiles.push(LaunchProfile {
                    name: name.trim().to_string(),
                    command: command.trim().to_string(),
                });
            }
        }
    }
    out
}

/// Pure merge (testable without touching the filesystem).
///
/// Default-name precedence, first hit wins:
///   1. workspace `default_profile`
///   2. workspace legacy `launcher` (⇒ `wrapper`) — preserves the
///      pre-profiles behavior where the workspace override always won
///   3. user `default_profile`
///   4. user legacy `launcher` (⇒ `wrapper`)
///   5. builtin `default`
/// A default name that doesn't resolve to a profile falls back to
/// `default`.
fn merge(default_exe: &str, user_text: Option<&str>, ws_text: Option<&str>) -> LaunchProfiles {
    let user = user_text.map(parse_scope);
    let ws = ws_text.map(parse_scope);
    let mut profiles = vec![LaunchProfile {
        name: BUILTIN_PROFILE.to_string(),
        command: default_exe.to_string(),
    }];
    let mut upsert = |p: LaunchProfile| {
        if let Some(slot) = profiles.iter_mut().find(|q| q.name == p.name) {
            *slot = p;
        } else {
            profiles.push(p);
        }
    };
    for scope in [&user, &ws].into_iter().flatten() {
        if let Some(cmd) = &scope.legacy_launcher {
            upsert(LaunchProfile {
                name: LEGACY_PROFILE.to_string(),
                command: cmd.clone(),
            });
        }
        for p in &scope.profiles {
            upsert(p.clone());
        }
    }
    let scope_default = |s: &Option<ScopeFields>, explicit: bool| -> Option<String> {
        let s = s.as_ref()?;
        if explicit {
            s.default_profile.clone()
        } else {
            s.legacy_launcher
                .as_ref()
                .map(|_| LEGACY_PROFILE.to_string())
        }
    };
    let default_name = scope_default(&ws, true)
        .or_else(|| scope_default(&ws, false))
        .or_else(|| scope_default(&user, true))
        .or_else(|| scope_default(&user, false))
        .filter(|n| profiles.iter().any(|p| &p.name == n))
        .unwrap_or_else(|| BUILTIN_PROFILE.to_string());
    LaunchProfiles {
        profiles,
        default_name,
    }
}

/// The profiles declared in the WORKSPACE-scope manifest only —
/// what the right-click "Remove profile:" rows may delete (builtin
/// and user-global entries aren't removable from a workspace menu).
pub fn workspace_profiles(workspace: &Path, id: &str) -> Vec<LaunchProfile> {
    std::fs::read_to_string(workspace_manifest_path(workspace, id))
        .map(|t| parse_scope(&t).profiles)
        .unwrap_or_default()
}

/// Add (or update, when the name already exists) one
/// `[[launch_profile]]` in the workspace-scope manifest. Text-level
/// edit so comments and unrelated keys survive. Names/commands with
/// double quotes are rejected — they'd break the TOML we emit.
pub fn add_profile(workspace: &Path, id: &str, name: &str, command: &str) -> Result<(), String> {
    let name = name.trim();
    let command = command.trim();
    if name.is_empty() || command.is_empty() {
        return Err("name and command must be non-empty".into());
    }
    if name.contains('"') || command.contains('"') {
        return Err("double quotes aren't allowed".into());
    }
    let dir = workspace.join(".mnml").join("integrations");
    let path = dir.join(format!("{id}.toml"));
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let mut out = if let Some((start, end)) = find_profile_block(&existing, name) {
        // Replace the block wholesale — simplest way to keep name +
        // command adjacent and drop any stale extra keys.
        let lines: Vec<&str> = existing.lines().collect();
        let mut rebuilt: Vec<String> = lines[..start].iter().map(|l| l.to_string()).collect();
        rebuilt.push("[[launch_profile]]".to_string());
        rebuilt.push(format!("name = \"{name}\""));
        rebuilt.push(format!("command = \"{command}\""));
        rebuilt.extend(lines[end..].iter().map(|l| l.to_string()));
        rebuilt.join("\n")
    } else {
        let mut text = existing.trim_end().to_string();
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        text.push_str(&format!(
            "[[launch_profile]]\nname = \"{name}\"\ncommand = \"{command}\""
        ));
        text
    };
    if !out.ends_with('\n') {
        out.push('\n');
    }
    std::fs::write(&path, out).map_err(|e| format!("write {}: {e}", path.display()))
}

/// Remove one `[[launch_profile]]` from the workspace-scope manifest;
/// also drops a `default_profile` key that pointed at it (resolution
/// falls back to the builtin). Errors when the name isn't declared in
/// the workspace file (builtin / user-global profiles aren't ours to
/// delete here).
pub fn remove_profile(workspace: &Path, id: &str, name: &str) -> Result<(), String> {
    let path = workspace_manifest_path(workspace, id);
    let existing =
        std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let Some((start, end)) = find_profile_block(&existing, name) else {
        return Err(format!("profile `{name}` isn't in the workspace manifest"));
    };
    let lines: Vec<&str> = existing.lines().collect();
    let mut rebuilt: Vec<String> = Vec::with_capacity(lines.len());
    for (i, l) in lines.iter().enumerate() {
        if i >= start && i < end {
            continue;
        }
        let trimmed = l.trim_start();
        if trimmed.starts_with("default_profile") && trimmed.contains(&format!("\"{name}\"")) {
            continue;
        }
        rebuilt.push(l.to_string());
    }
    let mut out = rebuilt.join("\n");
    if !out.ends_with('\n') {
        out.push('\n');
    }
    std::fs::write(&path, out).map_err(|e| format!("write {}: {e}", path.display()))
}

/// Line range `[start, end)` of the `[[launch_profile]]` block whose
/// `name` matches, where `start` is the header line and `end` is the
/// next table header (or EOF).
fn find_profile_block(text: &str, name: &str) -> Option<(usize, usize)> {
    let lines: Vec<&str> = text.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        if lines[i].trim() == "[[launch_profile]]" {
            let mut end = i + 1;
            while end < lines.len() && !lines[end].trim_start().starts_with('[') {
                end += 1;
            }
            let has_name = lines[i + 1..end].iter().any(|l| {
                let t = l.trim_start();
                t.starts_with("name") && t.contains(&format!("\"{name}\""))
            });
            if has_name {
                return Some((i, end));
            }
            i = end;
        } else {
            i += 1;
        }
    }
    None
}

/// Persist `default_profile = "<name>"` into the workspace-scope
/// manifest, preserving everything else in the file. The key must sit
/// ABOVE any `[table]` / `[[array]]` header to stay top-level, so it's
/// inserted before the first header line when not already present.
pub fn set_default_profile(workspace: &Path, id: &str, name: &str) -> Result<(), String> {
    let dir = workspace.join(".mnml").join("integrations");
    let path = dir.join(format!("{id}.toml"));
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let key_line = format!("default_profile = \"{name}\"");
    let mut lines: Vec<String> = existing
        .lines()
        .filter(|l| !l.trim_start().starts_with("default_profile"))
        .map(|l| l.to_string())
        .collect();
    let insert_at = lines
        .iter()
        .position(|l| l.trim_start().starts_with('['))
        .unwrap_or(lines.len());
    lines.insert(insert_at, key_line);
    let mut out = lines.join("\n");
    if !out.ends_with('\n') {
        out.push('\n');
    }
    std::fs::write(&path, out).map_err(|e| format!("write {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_files_yields_builtin_only() {
        let lp = merge("claude", None, None);
        assert_eq!(lp.profiles.len(), 1);
        assert_eq!(lp.profiles[0].name, "default");
        assert_eq!(lp.profiles[0].command, "claude");
        assert_eq!(lp.default_name, "default");
    }

    #[test]
    fn legacy_workspace_launcher_stays_default() {
        // The pre-profiles "Set launcher script…" file must behave
        // identically: its command is what a plain click spawns.
        let ws = r#"launcher = "{{workspace}}/bin/claude-multi.sh""#;
        let lp = merge("claude", None, Some(ws));
        assert_eq!(lp.default_name, "wrapper");
        assert_eq!(
            lp.profiles
                .iter()
                .find(|p| p.name == "wrapper")
                .unwrap()
                .command,
            "{{workspace}}/bin/claude-multi.sh"
        );
        let cmd = lp.default_command(Path::new("/tmp/proj"));
        assert_eq!(cmd, "/tmp/proj/bin/claude-multi.sh");
    }

    #[test]
    fn explicit_default_profile_beats_legacy_launcher() {
        let ws = "launcher = \"/opt/wrap.sh\"\ndefault_profile = \"default\"\n";
        let lp = merge("claude", None, Some(ws));
        // Both profiles exist; the explicit key pins default back to
        // the bare binary.
        assert_eq!(lp.profiles.len(), 2);
        assert_eq!(lp.default_name, "default");
        assert_eq!(lp.default_command(Path::new("/w")), "claude");
    }

    #[test]
    fn named_profiles_parse_and_default_resolves() {
        let ws = "default_profile = \"multi-repo\"\n\n\
                  [[launch_profile]]\n\
                  name = \"multi-repo\"\n\
                  command = \"{{workspace}}/bin/claude-multi.sh\"\n";
        let lp = merge("claude", None, Some(ws));
        assert_eq!(lp.profiles.len(), 2);
        assert_eq!(lp.default_name, "multi-repo");
        assert_eq!(
            lp.default_command(Path::new("/w")),
            "/w/bin/claude-multi.sh"
        );
        // Non-default profile still reachable by name.
        assert_eq!(
            lp.command_for("default", Path::new("/w")).as_deref(),
            Some("claude")
        );
    }

    #[test]
    fn workspace_profile_replaces_same_name_user_profile() {
        let user = "[[launch_profile]]\nname = \"fast\"\ncommand = \"/usr/bin/claude-fast\"\n";
        let ws = "[[launch_profile]]\nname = \"fast\"\ncommand = \"/opt/claude-faster\"\n";
        let lp = merge("claude", Some(user), Some(ws));
        assert_eq!(lp.profiles.len(), 2);
        assert_eq!(
            lp.command_for("fast", Path::new("/w")).as_deref(),
            Some("/opt/claude-faster")
        );
        // No default_profile anywhere → builtin stays default.
        assert_eq!(lp.default_name, "default");
    }

    #[test]
    fn user_default_applies_when_workspace_silent() {
        let user = "default_profile = \"fast\"\n\
                    [[launch_profile]]\n\
                    name = \"fast\"\n\
                    command = \"/usr/bin/claude-fast\"\n";
        let lp = merge("claude", Some(user), None);
        assert_eq!(lp.default_name, "fast");
    }

    #[test]
    fn unknown_default_falls_back_to_builtin() {
        // A user-global `default_profile = "multi-repo"` referencing a
        // profile only defined in some OTHER workspace's manifest must
        // not break this workspace — fall back to the bare binary.
        let user = "default_profile = \"multi-repo\"\n";
        let lp = merge("claude", Some(user), None);
        assert_eq!(lp.default_name, "default");
        assert_eq!(lp.default_command(Path::new("/w")), "claude");
    }

    #[test]
    fn junk_file_is_tolerated() {
        let lp = merge("codex", Some("this is [not toml"), None);
        assert_eq!(lp.profiles.len(), 1);
        assert_eq!(lp.default_name, "default");
    }

    #[test]
    fn profile_named_default_overrides_builtin_command() {
        // Power move: a [[launch_profile]] named "default" swaps the
        // builtin command without needing default_profile at all.
        let ws = "[[launch_profile]]\nname = \"default\"\ncommand = \"/opt/claude-wrapped\"\n";
        let lp = merge("claude", None, Some(ws));
        assert_eq!(lp.profiles.len(), 1);
        assert_eq!(lp.default_command(Path::new("/w")), "/opt/claude-wrapped");
    }

    #[test]
    fn set_default_profile_inserts_above_tables_and_replaces() {
        let dir =
            std::env::temp_dir().join(format!("mnml-launch-profiles-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let manifest_dir = dir.join(".mnml").join("integrations");
        std::fs::create_dir_all(&manifest_dir).unwrap();
        std::fs::write(
            manifest_dir.join("claude_code.toml"),
            "# comment kept\n\n[[launch_profile]]\nname = \"m\"\ncommand = \"/x\"\n",
        )
        .unwrap();
        set_default_profile(&dir, "claude_code", "m").unwrap();
        let text = std::fs::read_to_string(manifest_dir.join("claude_code.toml")).unwrap();
        let key_pos = text.find("default_profile = \"m\"").unwrap();
        let table_pos = text.find("[[launch_profile]]").unwrap();
        assert!(
            key_pos < table_pos,
            "top-level key must precede tables:\n{text}"
        );
        assert!(text.starts_with("# comment kept"));
        // Re-set to another name — replaces, doesn't duplicate.
        set_default_profile(&dir, "claude_code", "default").unwrap();
        let text = std::fs::read_to_string(manifest_dir.join("claude_code.toml")).unwrap();
        assert_eq!(text.matches("default_profile").count(), 1);
        assert!(text.contains("default_profile = \"default\""));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn add_update_remove_profile_roundtrip() {
        let dir =
            std::env::temp_dir().join(format!("mnml-launch-profiles-test3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Add into a missing file.
        add_profile(&dir, "claude_code", "multi", "{{workspace}}/bin/m.sh").unwrap();
        let ws_profiles = workspace_profiles(&dir, "claude_code");
        assert_eq!(ws_profiles.len(), 1);
        assert_eq!(ws_profiles[0].command, "{{workspace}}/bin/m.sh");
        // Same-name add updates in place (no duplicate block).
        add_profile(&dir, "claude_code", "multi", "/opt/m2.sh").unwrap();
        let ws_profiles = workspace_profiles(&dir, "claude_code");
        assert_eq!(ws_profiles.len(), 1);
        assert_eq!(ws_profiles[0].command, "/opt/m2.sh");
        // Second profile + default pointing at the first; comments
        // and the default key must survive the add.
        set_default_profile(&dir, "claude_code", "multi").unwrap();
        add_profile(&dir, "claude_code", "fast", "/opt/fast").unwrap();
        let lp = LaunchProfiles::load(&dir, "claude_code", "claude");
        assert_eq!(lp.default_name, "multi");
        assert_eq!(lp.profiles.len(), 3);
        // Removing the default profile also drops the default key —
        // resolution falls back to builtin.
        remove_profile(&dir, "claude_code", "multi").unwrap();
        let lp = LaunchProfiles::load(&dir, "claude_code", "claude");
        assert_eq!(lp.default_name, "default");
        assert!(lp.profiles.iter().all(|p| p.name != "multi"));
        assert!(lp.profiles.iter().any(|p| p.name == "fast"));
        // Removing an undeclared name errors instead of no-op.
        assert!(remove_profile(&dir, "claude_code", "ghost").is_err());
        // Quotes rejected.
        assert!(add_profile(&dir, "claude_code", "bad\"name", "/x").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn set_default_profile_creates_missing_file() {
        let dir =
            std::env::temp_dir().join(format!("mnml-launch-profiles-test2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        set_default_profile(&dir, "codex", "default").unwrap();
        let text =
            std::fs::read_to_string(dir.join(".mnml").join("integrations").join("codex.toml"))
                .unwrap();
        assert_eq!(text, "default_profile = \"default\"\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
