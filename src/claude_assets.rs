//! Discovery of a workspace's Claude Code assets — agents, slash
//! commands and skills.
//!
//! **User ask 2026-08-30:** TODO rows should offer actions like "fix" or
//! "implement", and "need a way for tattle people to have it use our
//! agents/skills/commands but if user not have that it just uses claude
//! code or codex."
//!
//! Nothing here knows about Tattle, deliberately. It reads whatever
//! `.claude/` the WORKSPACE happens to have: in tattle-claude-workspace
//! that surfaces their agents, in a stranger's repo it finds nothing and
//! the caller falls back to a plain Claude Code / Codex session. mnml's
//! own repo gets it for free — it already ships 13 agents.
//!
//! Workspace assets take precedence over the user's `~/.claude/` ones of
//! the same name, matching how Claude Code itself resolves them.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum AssetKind {
    Agent,
    Command,
    Skill,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudeAsset {
    pub kind: AssetKind,
    /// Invocation name — the frontmatter `name:` for an agent, else the
    /// file stem.
    pub name: String,
    /// One-line summary from frontmatter `description:`, for the menu's
    /// secondary text. Empty when absent.
    pub description: String,
    pub path: PathBuf,
    /// True when it came from the workspace rather than `~/.claude/`.
    pub workspace_scoped: bool,
}

impl ClaudeAsset {
    /// How this asset is named in a prompt to Claude Code.
    ///
    /// Agents are addressed in prose because that is how Claude Code
    /// dispatches them; commands are slash-invoked; a skill is named and
    /// left for the model to load.
    pub fn prompt_prefix(&self) -> String {
        match self.kind {
            AssetKind::Agent => format!("Use the {} agent to ", self.name),
            AssetKind::Command => format!("/{} ", self.name),
            AssetKind::Skill => format!("Using the {} skill, ", self.name),
        }
    }

    /// Menu label.
    pub fn label(&self) -> String {
        match self.kind {
            AssetKind::Agent => format!("agent: {}", self.name),
            AssetKind::Command => format!("/{}", self.name),
            AssetKind::Skill => format!("skill: {}", self.name),
        }
    }
}

/// Pull a `key: value` line out of leading `---` frontmatter.
///
/// Deliberately not a YAML parser: the two fields wanted are simple
/// scalars, and a dependency to read them would be out of proportion.
/// Scanning stops at the closing `---` so a `name:` inside the body
/// cannot be mistaken for the header's.
fn frontmatter_field(body: &str, key: &str) -> Option<String> {
    let rest = body.strip_prefix("---")?;
    let end = rest.find("\n---")?;
    let pat = format!("{key}:");
    for line in rest[..end].lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix(&pat) {
            let v = v.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

fn scan(dir: &Path, kind: AssetKind, workspace_scoped: bool, out: &mut Vec<ClaudeAsset>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let path = e.path();
        // A skill is a DIRECTORY holding SKILL.md; agents and commands
        // are single `.md` files.
        let (doc, stem) = if kind == AssetKind::Skill {
            if !path.is_dir() {
                continue;
            }
            (path.join("SKILL.md"), path.file_name())
        } else {
            if path.extension().and_then(|x| x.to_str()) != Some("md") {
                continue;
            }
            (path.clone(), path.file_stem())
        };
        let Some(stem) = stem.map(|s| s.to_string_lossy().into_owned()) else {
            continue;
        };
        let body = std::fs::read_to_string(&doc).unwrap_or_default();
        out.push(ClaudeAsset {
            kind,
            name: frontmatter_field(&body, "name").unwrap_or(stem),
            description: frontmatter_field(&body, "description").unwrap_or_default(),
            path,
            workspace_scoped,
        });
    }
}

/// Everything discoverable for `workspace`, workspace-scoped first.
///
/// A workspace asset SHADOWS a user-level one of the same kind and name,
/// which is how Claude Code resolves them — otherwise a repo's own
/// `developer` agent would compete with a personal one in the menu.
pub fn discover(workspace: &Path) -> Vec<ClaudeAsset> {
    let mut out = Vec::new();
    let ws = workspace.join(".claude");
    scan(&ws.join("agents"), AssetKind::Agent, true, &mut out);
    scan(&ws.join("commands"), AssetKind::Command, true, &mut out);
    scan(&ws.join("skills"), AssetKind::Skill, true, &mut out);

    if let Some(home) = std::env::var_os("HOME") {
        let user = PathBuf::from(home).join(".claude");
        let mut user_assets = Vec::new();
        scan(
            &user.join("agents"),
            AssetKind::Agent,
            false,
            &mut user_assets,
        );
        scan(
            &user.join("commands"),
            AssetKind::Command,
            false,
            &mut user_assets,
        );
        scan(
            &user.join("skills"),
            AssetKind::Skill,
            false,
            &mut user_assets,
        );
        user_assets.retain(|u| !out.iter().any(|w| w.kind == u.kind && w.name == u.name));
        out.extend(user_assets);
    }
    // Stable menu order: kind, then name. Discovery order is directory
    // order, which is arbitrary and would shuffle the menu between runs.
    out.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.name.cmp(&b.name)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A workspace with assets, plus an isolated HOME.
    ///
    /// Every test here needs the HOME redirect: `discover` reads
    /// `~/.claude/` too, so without it a test picks up the developer's
    /// real agents — nondeterministic on its own, and it raced the tests
    /// that DO swap HOME, passing alone and failing in the suite.
    fn ws() -> (tempfile::TempDir, tempfile::TempDir, crate::EnvGuard) {
        let home = tempfile::tempdir().unwrap();
        // EnvGuard, not a raw `set_var`: the guard RESTORES HOME on drop.
        // A raw set left every later test pointing at a deleted tempdir,
        // which is how an unrelated test started failing in the suite
        // while passing alone.
        let guard = crate::EnvGuard::set("HOME", home.path());
        let d = tempfile::tempdir().unwrap();
        let c = d.path().join(".claude");
        std::fs::create_dir_all(c.join("agents")).unwrap();
        std::fs::create_dir_all(c.join("commands")).unwrap();
        std::fs::create_dir_all(c.join("skills/drive-mnml")).unwrap();
        std::fs::write(
            c.join("agents/code-reviewer.md"),
            "---\nname: code-reviewer\ndescription: Rust review for mnml changes.\ntools: Read\n---\n\nYou are a reviewer.\n",
        )
        .unwrap();
        std::fs::write(c.join("commands/qa-sweep.md"), "Run the QA sweep.\n").unwrap();
        std::fs::write(
            c.join("skills/drive-mnml/SKILL.md"),
            "---\nname: drive-mnml\ndescription: Screenshot and click the real window.\n---\n",
        )
        .unwrap();
        (d, home, guard)
    }

    #[test]
    fn finds_agents_commands_and_skills() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, _home, _g) = ws();
        let found = discover(d.path());
        let names: Vec<String> = found.iter().map(|a| a.label()).collect();
        assert!(
            names.contains(&"agent: code-reviewer".to_string()),
            "{names:?}"
        );
        assert!(names.contains(&"/qa-sweep".to_string()), "{names:?}");
        assert!(
            names.contains(&"skill: drive-mnml".to_string()),
            "{names:?}"
        );
    }

    /// The agent's frontmatter `name:` wins over the filename — they can
    /// differ, and the frontmatter one is what Claude Code dispatches on.
    #[test]
    fn an_agents_name_comes_from_frontmatter_not_the_filename() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, _home, _g) = ws();
        let c = d.path().join(".claude/agents");
        std::fs::write(
            c.join("wrong-filename.md"),
            "---\nname: real-name\ndescription: x\n---\nbody\n",
        )
        .unwrap();
        let found = discover(d.path());
        assert!(
            found.iter().any(|a| a.name == "real-name"),
            "used the filename instead of the frontmatter name"
        );
    }

    /// A `name:` in the BODY must not be mistaken for the header's — the
    /// scan has to stop at the closing `---`.
    #[test]
    fn a_name_in_the_body_is_not_read_as_frontmatter() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, _home, _g) = ws();
        std::fs::write(
            d.path().join(".claude/agents/plain.md"),
            "No frontmatter here.\nname: not-a-header\n",
        )
        .unwrap();
        let found = discover(d.path());
        assert!(
            found.iter().any(|a| a.name == "plain"),
            "fell back wrongly: {:?}",
            found.iter().map(|a| &a.name).collect::<Vec<_>>()
        );
        assert!(
            !found.iter().any(|a| a.name == "not-a-header"),
            "read a body line as frontmatter"
        );
    }

    /// A workspace asset shadows a user one of the same name, or a repo's
    /// own agent competes in the menu with a personal one.
    #[test]
    fn a_workspace_asset_shadows_the_user_one() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, home, _g) = ws();
        std::fs::create_dir_all(home.path().join(".claude/agents")).unwrap();
        std::fs::write(
            home.path().join(".claude/agents/code-reviewer.md"),
            "---\nname: code-reviewer\ndescription: personal one\n---\n",
        )
        .unwrap();

        let found = discover(d.path());
        let hits: Vec<&ClaudeAsset> = found.iter().filter(|a| a.name == "code-reviewer").collect();
        assert_eq!(hits.len(), 1, "the same agent appeared twice: {hits:?}");
        assert!(hits[0].workspace_scoped, "the user's copy won");
    }

    /// A workspace with no `.claude/` yields nothing, so the caller can
    /// fall back to a plain Claude Code / Codex session.
    #[test]
    fn a_workspace_without_claude_assets_finds_none() {
        let d = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _h = crate::EnvGuard::set("HOME", home.path());
        assert!(discover(d.path()).is_empty());
    }

    #[test]
    fn prompt_prefixes_match_how_each_kind_is_invoked() {
        let mk = |kind, name: &str| ClaudeAsset {
            kind,
            name: name.into(),
            description: String::new(),
            path: PathBuf::new(),
            workspace_scoped: true,
        };
        assert_eq!(
            mk(AssetKind::Agent, "developer").prompt_prefix(),
            "Use the developer agent to "
        );
        assert_eq!(mk(AssetKind::Command, "fix").prompt_prefix(), "/fix ");
        assert_eq!(
            mk(AssetKind::Skill, "verify").prompt_prefix(),
            "Using the verify skill, "
        );
    }

    /// Menu order must be stable — directory order is arbitrary and
    /// would reshuffle the menu between runs.
    #[test]
    fn discovery_order_is_stable() {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let (d, _home, _g) = ws();
        for n in ["zeta.md", "alpha.md"] {
            std::fs::write(
                d.path().join(".claude/agents").join(n),
                "---\nname: x\n---\n",
            )
            .unwrap();
        }
        let a: Vec<String> = discover(d.path()).iter().map(|x| x.label()).collect();
        let b: Vec<String> = discover(d.path()).iter().map(|x| x.label()).collect();
        assert_eq!(a, b);
        let agents: Vec<&String> = a.iter().filter(|l| l.starts_with("agent:")).collect();
        let mut sorted = agents.clone();
        sorted.sort();
        assert_eq!(agents, sorted, "agents are not name-sorted: {agents:?}");
    }
}
