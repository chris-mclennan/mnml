//! Per-integration Settings pane — right-click a chip → "Configure…"
//! (or `integration_settings.show <id>`) → a modal form of the
//! integration's `[[auth]]` fields with masked text-input for
//! secrets. Save writes back to the manifest TOML under
//! `[auth_values]`.
//!
//! Companion to the global-settings overlay (`settings_overlay`) but
//! scoped to ONE integration. Task #892 (Phase 2B of the first-launch
//! wizard bundle, 2026-08-11).

use super::*;

/// State carried across renders while the settings pane is open.
/// `None` on `App.integration_settings` ⇒ pane closed.
#[derive(Debug, Clone)]
pub struct IntegrationSettingsState {
    /// Which integration we're editing (matches `manifest.id`).
    pub integration_id: String,
    /// Manifest snapshot at open time — used to render the form
    /// schema. Not re-read on save; caller applies the values via
    /// [`Self::values`] + writes them to disk.
    pub schema: Vec<crate::integration_manifest::AuthField>,
    /// Current editable value for each field (parallel index to
    /// `schema`). Populated at open from the manifest's stored
    /// `[auth_values]` block, falling back to `env_fallback` if any.
    pub values: Vec<String>,
    /// Which field the user is focused on. Indexes into `schema`.
    pub focused: usize,
    /// When Some, that field is in text-edit mode — printable
    /// keys append to the buffer, Enter commits + returns to nav
    /// mode, Esc cancels + returns to nav mode. Nav mode: arrow
    /// keys move focus.
    pub editing: Option<EditBuffer>,
    /// Absolute path of the TOML file the integration lives in;
    /// where save writes.
    pub source_path: std::path::PathBuf,
}

#[derive(Debug, Clone)]
pub struct EditBuffer {
    /// Character buffer being typed. UTF-8; cursor tracking is
    /// end-of-buffer only in this phase (no left/right in-field).
    pub text: String,
    /// The value the field had before edit — restored on Esc.
    pub original: String,
}

impl App {
    /// Open the pane for `integration_id`. If no matching manifest
    /// is loaded, or the manifest has no `[[auth]]` block, toast +
    /// no-op. Idempotent — if the pane is already open on the same
    /// integration, no-op; otherwise close + reopen.
    pub fn open_integration_settings(&mut self, integration_id: &str) {
        let manifest = self
            .integration_manifests
            .iter()
            .find(|m| m.id == integration_id)
            .cloned();
        let Some(manifest) = manifest else {
            self.toast(format!(
                "integration `{integration_id}` not installed — nothing to configure"
            ));
            return;
        };
        if manifest.auth.is_empty() {
            self.toast(format!(
                "integration `{integration_id}` doesn't declare any auth fields to configure"
            ));
            return;
        }
        // Read current values from the manifest file's [auth_values]
        // block, falling back to env vars declared in env_fallback.
        let stored: Option<toml::Value> = std::fs::read_to_string(&manifest.source_path)
            .ok()
            .and_then(|s| toml::from_str::<toml::Value>(&s).ok())
            .and_then(|v| v.get("auth_values").cloned());
        let values: Vec<String> = manifest
            .auth
            .iter()
            .map(|field| {
                if let Some(t) = stored.as_ref()
                    && let Some(v) = t.get(&field.key).and_then(|x| x.as_str())
                {
                    return v.to_string();
                }
                if let Some(env_name) = &field.env_fallback
                    && let Ok(v) = std::env::var(env_name)
                {
                    return v;
                }
                String::new()
            })
            .collect();
        self.integration_settings = Some(IntegrationSettingsState {
            integration_id: integration_id.to_string(),
            schema: manifest.auth.clone(),
            values,
            focused: 0,
            editing: None,
            source_path: manifest.source_path.clone(),
        });
    }

    pub fn close_integration_settings(&mut self) {
        self.integration_settings = None;
    }

    /// Build the env-var injection map for an integration's Pty
    /// spawn: for each `[[auth]]` field whose `env_fallback` names an
    /// env var AND whose stored `[auth_values]` value is non-empty,
    /// pair `env_fallback → stored value`. Fields with no
    /// env_fallback are skipped — those are pane-only values the
    /// integration would have to read from the manifest directly.
    ///
    /// Skipping empty values means a user who cleared a field in
    /// the pane falls back to their shell's export (if any) rather
    /// than getting the env var wiped by an empty injection.
    ///
    /// Called by `open_pty_dir` right before spawn; result is
    /// merged into `BinaryProfile.env`. Phase 2E (2026-08-11).
    pub fn integration_auth_env(&self, integration_id: &str) -> Vec<(String, String)> {
        // 2026-08-11 — extended from "just this integration's auth"
        // to "this integration's auth PLUS every OTHER installed
        // integration's auth-values that name an env_fallback".
        // Rationale: many integrations share env conventions
        // (jira's Fix Versions view reads $BITBUCKET_ACCESS_TOKEN
        // that the bitbucket integration configures; git tools read
        // $GITHUB_TOKEN that the github integration configures). Without
        // cross-integration sharing, each integration that consumes a
        // "foreign" env var had to redeclare it in its own [[auth]]
        // (bad UX — user re-enters the same token twice).
        //
        // Precedence when the same env-var name appears in multiple
        // integrations' [auth_values]: the CURRENT integration wins,
        // then in load order for the rest. Rare — usually only one
        // integration owns a given env var.
        let mut env_map: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        // Helper: resolve the effective (key → value) auth-values
        // map for one manifest. Reads disk `[auth_values]`, then
        // overlays `manifest.override_auth_values` (task #933) —
        // override wins per-key so a workspace `.override.toml`
        // shadows a user-config saved token for the workspace
        // without touching user config.
        let effective_auth_values = |m: &crate::integration_manifest::IntegrationManifest| {
            let mut stored: std::collections::HashMap<String, String> =
                std::fs::read_to_string(&m.source_path)
                    .ok()
                    .and_then(|s| toml::from_str::<toml::Value>(&s).ok())
                    .and_then(|v| v.get("auth_values").cloned())
                    .and_then(|v| v.as_table().cloned())
                    .map(|t| {
                        t.into_iter()
                            .filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string())))
                            .collect()
                    })
                    .unwrap_or_default();
            for (k, v) in &m.override_auth_values {
                stored.insert(k.clone(), v.clone());
            }
            stored
        };
        // Pass 1 — every OTHER integration's auth-values, lowest
        // priority. Skipped for integrations with no [[auth]].
        for manifest in self
            .integration_manifests
            .iter()
            .filter(|m| m.id != integration_id && !m.auth.is_empty())
        {
            let stored = effective_auth_values(manifest);
            for field in &manifest.auth {
                let Some(env_name) = field.env_fallback.as_ref() else {
                    continue;
                };
                let Some(stored_val) = stored.get(&field.key) else {
                    continue;
                };
                if !stored_val.is_empty() {
                    env_map
                        .entry(env_name.clone())
                        .or_insert_with(|| stored_val.clone());
                }
            }
        }
        // Pass 2 — the CURRENT integration's auth-values overwrite
        // any conflicting keys from pass 1.
        if let Some(manifest) = self
            .integration_manifests
            .iter()
            .find(|m| m.id == integration_id)
            && !manifest.auth.is_empty()
        {
            let stored = effective_auth_values(manifest);
            for field in &manifest.auth {
                let Some(env_name) = field.env_fallback.as_ref() else {
                    continue;
                };
                let Some(stored_val) = stored.get(&field.key) else {
                    continue;
                };
                if !stored_val.is_empty() {
                    env_map.insert(env_name.clone(), stored_val.clone());
                }
            }
        }
        env_map.into_iter().collect()
    }

    /// Task #933 — collect the `[env]` overrides for ONE
    /// integration's spawn. Merged into `BinaryProfile.env` by
    /// `open_pty_dir`. Independent of the `[[auth]]` schema —
    /// arbitrary key = value pairs.
    ///
    /// Deliberately does NOT cross-share across integrations, in
    /// contrast to `integration_auth_env`. Rationale: auth_env's
    /// cross-share is gated by `AuthField.env_fallback` — a
    /// declared, conventional env-var name (`$BITBUCKET_ACCESS_TOKEN`)
    /// that other integrations are documented to consume. `override_env`
    /// has no such convention — keys are arbitrary — so cross-sharing
    /// would leak, say, a jira `[env]` block into every other
    /// integration's Pty spawn (including external-tool launchers
    /// like `htop` / `btop`, which route through the same
    /// `open_pty_dir` path via `run_external_tool`). Empty
    /// override_env is a no-op.
    pub fn integration_override_env(&self, integration_id: &str) -> Vec<(String, String)> {
        self.integration_manifests
            .iter()
            .find(|m| m.id == integration_id)
            .map(|m| {
                m.override_env
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// True when the integration has at least one `required = true`
    /// auth field with no stored `[auth_values]` value AND no env
    /// var declared by its `env_fallback` (or that env var is unset).
    /// Used by `run_dynamic_command` to short-circuit on first action
    /// dispatch and open the Settings pane instead of silently
    /// failing (Phase 2D).
    pub fn integration_has_missing_required_auth(&self, integration_id: &str) -> bool {
        let Some(manifest) = self
            .integration_manifests
            .iter()
            .find(|m| m.id == integration_id)
        else {
            return false;
        };
        let required: Vec<&crate::integration_manifest::AuthField> =
            manifest.auth.iter().filter(|f| f.required).collect();
        if required.is_empty() {
            return false;
        }
        let stored: Option<toml::Value> = std::fs::read_to_string(&manifest.source_path)
            .ok()
            .and_then(|s| toml::from_str::<toml::Value>(&s).ok())
            .and_then(|v| v.get("auth_values").cloned());
        // #1103 f/u (2026-08-20) — false-positive guard fix. Many
        // pre-`[auth]` integrations (mnml-tracker-jira, mnml-forge-*)
        // persist their credentials in their OWN
        // `~/.config/<binary>.toml` (+ sometimes a
        // `~/.config/<binary>/token` sidecar), not in mnml's
        // `[auth_values]` block. Before this fix, clicking the
        // integration's chip fired the Configure pane every time — user
        // hits "why is mnml asking me to set up Jira, I've been
        // using it for months?".
        //
        // Heuristic: if the integration's canonical self-managed config
        // file exists AND is non-empty, treat auth as satisfied
        // regardless of mnml's `[auth_values]`. mnml can't parse
        // each integration's config schema, so the presence check is
        // the best we can do without a manifest-level opt-out
        // (follow-up: add `[auth] self_configured = true` to the
        // manifest schema for a stronger signal).
        if let Some(binary) = manifest.binary.as_deref() {
            let basename = binary.rsplit('/').next().unwrap_or(binary);
            if let Some(home) = std::env::var_os("HOME") {
                let config_toml = std::path::Path::new(&home)
                    .join(".config")
                    .join(format!("{basename}.toml"));
                if config_toml.metadata().map(|m| m.len() > 0).unwrap_or(false) {
                    return false;
                }
            }
        }
        required.iter().any(|field| {
            let has_stored = stored
                .as_ref()
                .and_then(|t| t.get(&field.key))
                .and_then(|v| v.as_str())
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            if has_stored {
                return false;
            }
            let has_env = field
                .env_fallback
                .as_ref()
                .and_then(|n| std::env::var(n).ok())
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            !has_env
        })
    }

    /// Palette-command entry: enumerate all installed integrations
    /// that declare `[[auth]]` fields. If none, toast; if exactly
    /// one, open the pane directly; if several, open the picker
    /// overlay so the user picks by id.
    pub fn open_integration_configure_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let matches: Vec<(String, String, String)> = self
            .integration_manifests
            .iter()
            .filter(|m| !m.auth.is_empty())
            .map(|m| {
                let subtitle = m
                    .description
                    .clone()
                    .unwrap_or_else(|| format!("{} fields", m.auth.len()));
                (m.id.clone(), m.label.clone(), subtitle)
            })
            .collect();
        match matches.len() {
            0 => self.toast(
                "No installed integration declares auth fields yet. \
                 Right-click a chip → \"Configure…\" once one does.",
            ),
            1 => self.open_integration_settings(&matches[0].0),
            _ => {
                let items: Vec<PickerItem> = matches
                    .into_iter()
                    .map(|(id, label, subtitle)| PickerItem::new(&id, label, subtitle))
                    .collect();
                self.open_picker(Picker::new(
                    PickerKind::IntegrationConfigure,
                    "Configure integration auth — pick one",
                    items,
                ));
            }
        }
    }

    /// Picker-accept handler for `PickerKind::IntegrationConfigure`.
    /// `id` is the integration manifest id.
    pub fn accept_integration_configure(&mut self, id: &str) {
        self.open_integration_settings(id);
    }

    /// #1103 f/u7 (2026-08-20) — spawn `<binary> --diag` for the
    /// given integration id. Resolves the manifest's binary, opens
    /// a Pty pane, and runs the diag subcommand. If the integration
    /// has no binary, toasts an explanation and no-ops. Called by:
    ///   - chip context menu → "Run diagnostics"
    ///   - palette command `integrations.diag`
    ///   - picker → `open_integration_diag_picker` (2+ installed)
    pub fn run_integration_diag(&mut self, integration_id: &str) {
        let Some(binary) = self
            .integration_manifests
            .iter()
            .find(|m| m.id == integration_id)
            .and_then(|m| m.binary.clone())
        else {
            self.toast(format!(
                "integration `{integration_id}` has no binary — nothing to diagnose"
            ));
            return;
        };
        self.run_ex_command(&format!("term {binary} --diag"));
        self.toast(format!("running diagnostics for `{integration_id}`…"));
    }

    /// Palette-command entry: enumerate every installed integration
    /// that declares a binary. If none, toast; if one, run its
    /// `--diag` directly; if many, open a picker.
    pub fn open_integration_diag_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let matches: Vec<(String, String, String)> = self
            .integration_manifests
            .iter()
            .filter(|m| m.binary.is_some())
            .map(|m| {
                let subtitle = m
                    .description
                    .clone()
                    .unwrap_or_else(|| m.binary.clone().unwrap_or_default());
                (m.id.clone(), m.label.clone(), subtitle)
            })
            .collect();
        match matches.len() {
            0 => self.toast("No installed integration has a binary to diagnose."),
            1 => self.run_integration_diag(&matches[0].0),
            _ => {
                let items: Vec<PickerItem> = matches
                    .into_iter()
                    .map(|(id, label, subtitle)| PickerItem::new(&id, label, subtitle))
                    .collect();
                self.open_picker(Picker::new(
                    PickerKind::IntegrationDiag,
                    "Run diagnostics — pick an integration",
                    items,
                ));
            }
        }
    }

    /// Picker-accept handler for `PickerKind::IntegrationDiag`.
    pub fn accept_integration_diag(&mut self, id: &str) {
        self.run_integration_diag(id);
    }

    /// Persist the current values to the manifest's TOML under
    /// `[auth_values]`. In-place merge preserves the manifest's own
    /// fields (`id`, `[chip]`, `[[commands]]`, `[[auth]]`) so we
    /// only touch the values block. Then close the pane.
    pub fn save_integration_settings(&mut self) {
        let Some(state) = self.integration_settings.take() else {
            return;
        };
        let path = &state.source_path;
        let existing = std::fs::read_to_string(path).unwrap_or_default();
        // Parse, mutate [auth_values], re-serialize. toml crate's
        // Serializer doesn't preserve comments — acceptable trade
        // for the auth-values block (author's original file is
        // preserved on the OTHER keys via the schema; only
        // [auth_values] is a mnml-managed block).
        let mut doc: toml::Value = match toml::from_str(&existing) {
            Ok(v) => v,
            Err(_) => toml::Value::Table(toml::value::Table::new()),
        };
        let Some(table) = doc.as_table_mut() else {
            self.toast(format!(
                "manifest at {} isn't a TOML table — refusing to save",
                path.display()
            ));
            return;
        };
        let auth_values: &mut toml::value::Table = match table.entry("auth_values".to_string()) {
            toml::map::Entry::Occupied(mut e) => {
                if !e.get().is_table() {
                    *e.get_mut() = toml::Value::Table(toml::value::Table::new());
                }
                e.into_mut().as_table_mut().expect("just ensured table")
            }
            toml::map::Entry::Vacant(v) => v
                .insert(toml::Value::Table(toml::value::Table::new()))
                .as_table_mut()
                .expect("just inserted table"),
        };
        for (field, value) in state.schema.iter().zip(state.values.iter()) {
            if value.is_empty() {
                auth_values.remove(&field.key);
            } else {
                auth_values.insert(field.key.clone(), toml::Value::String(value.clone()));
            }
        }
        let serialized = match toml::to_string(&doc) {
            Ok(s) => s,
            Err(e) => {
                self.toast(format!("save auth: serialize failed: {e}"));
                return;
            }
        };
        if let Err(e) = crate::app::backup::write_toml_with_backup(path, &serialized, "settings") {
            self.toast(format!("save auth: write {}: {e}", path.display()));
            return;
        }
        self.toast(format!("Saved auth for `{}`", state.integration_id));
    }

    // ── Nav ──────────────────────────────────────────────────

    pub fn integration_settings_move_focus(&mut self, delta: i32) {
        if let Some(s) = self.integration_settings.as_mut()
            && !s.schema.is_empty()
        {
            let len = s.schema.len() as i32;
            s.focused = (s.focused as i32 + delta).rem_euclid(len) as usize;
        }
    }

    pub fn integration_settings_begin_edit(&mut self) {
        if let Some(s) = self.integration_settings.as_mut() {
            let cur = s.values.get(s.focused).cloned().unwrap_or_default();
            s.editing = Some(EditBuffer {
                text: cur.clone(),
                original: cur,
            });
        }
    }

    pub fn integration_settings_edit_push(&mut self, c: char) {
        if let Some(s) = self.integration_settings.as_mut()
            && let Some(buf) = s.editing.as_mut()
        {
            buf.text.push(c);
        }
    }

    pub fn integration_settings_edit_backspace(&mut self) {
        if let Some(s) = self.integration_settings.as_mut()
            && let Some(buf) = s.editing.as_mut()
        {
            buf.text.pop();
        }
    }

    pub fn integration_settings_edit_commit(&mut self) {
        if let Some(s) = self.integration_settings.as_mut()
            && let Some(buf) = s.editing.take()
        {
            let idx = s.focused;
            if let Some(slot) = s.values.get_mut(idx) {
                *slot = buf.text;
            }
        }
    }

    pub fn integration_settings_edit_cancel(&mut self) {
        if let Some(s) = self.integration_settings.as_mut()
            && let Some(buf) = s.editing.take()
        {
            // Restore original value (no-op if never edited).
            let idx = s.focused;
            if let Some(slot) = s.values.get_mut(idx) {
                *slot = buf.original;
            }
        }
    }
}
