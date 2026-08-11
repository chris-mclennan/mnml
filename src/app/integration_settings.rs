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
    /// that declare `[[auth]]` fields. If exactly one, open it
    /// directly; if none, toast; if several, toast + point at
    /// right-click chip → "Configure…" for now. A dedicated
    /// PickerKind::IntegrationConfigure is a Phase-3 follow-up.
    pub fn open_integration_configure_picker(&mut self) {
        let matches: Vec<String> = self
            .integration_manifests
            .iter()
            .filter(|m| !m.auth.is_empty())
            .map(|m| m.id.clone())
            .collect();
        match matches.len() {
            0 => self.toast(
                "No installed integration declares auth fields yet. \
                 Right-click a chip → \"Configure…\" once one does.",
            ),
            1 => self.open_integration_settings(&matches[0]),
            n => self.toast(format!(
                "{n} integrations have auth fields. Right-click the chip you \
                 want and pick \"Configure…\" (picker overlay lands in Phase 3)."
            )),
        }
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
        if let Err(e) = std::fs::write(path, serialized) {
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
