//! Manifest loader for third-party integration integrations.
//!
//! Mirrors [`mount_manifest`] but for the Pty-launcher-style
//! integration icons (things that live in the rail's INTEGRATIONS
//! section — Bitbucket, GitHub, Slack, Datadog, …). Instead of
//! forcing every user to hand-write `[[ui.integration_icon]]`
//! entries in `config.toml`, a integration ships a manifest and
//! auto-installs it on `<integration> --install`.
//!
//! ## Where manifests live
//!
//!   1. `<workspace>/.mnml/integrations/<id>.toml` — workspace-local.
//!   2. `~/.config/mnml/integrations/<id>.toml` — user-global.
//!
//! Workspace manifests override user-global on id collision.
//! Explicit `[[ui.integration_icon]]` entries in user config
//! override BOTH (users always win over integration-authored defaults).
//!
//! ## Full schema
//!
//! ```toml
//! # ── Identity ────────────────────────
//! id          = "slack"                     # unique stable slug
//! name        = "Slack"                     # display
//! description = "Slack browse + post"       # optional
//! version     = "0.1.0"                     # semver — optional
//! binary      = "mnml-msg-slack"            # PATH or absolute
//! category    = "msg"                       # msg/forge/tracker/aws/db/…
//!
//! # ── Rail chip ──────────────────────
//! [chip]
//! glyph          = "9"                # Nerd Font glyph
//! fallback       = "Sk"                     # 2-char text
//! color          = "purple"                 # theme color name
//! label          = "Slack"
//! enabled        = true                     # rendered by default
//! in_palette_bar = false                    # false → INTEGRATIONS section
//! badge_key      = "slack"                  # section id for badges
//!
//! # ── Palette commands ───────────────
//! [[commands]]
//! id    = "slack.open"
//! title = "Slack: open"
//! group = "integrations"                    # optional
//! keys  = ["<leader>iS"]                    # optional; multiple allowed
//! run   = ":term mnml-msg-slack"            # ex-command line
//!
//! # ── Context menu additions ─────────
//! [[context_menu]]
//! target  = "tree.file"                     # tree.file|tree.dir|tab|agent.row|pane
//! title   = "Send via Slack"
//! command = "slack.send_file"
//!
//! # ── Menu-bar entries ───────────────
//! [[menu_bar]]
//! path    = "File > Send via Slack"
//! command = "slack.send_file"
//!
//! # ── Statusline segment (static) ────
//! [statusline]
//! side          = "right"
//! segment_id    = "slack"
//! initial_text  = "◇ slack"
//! initial_color = "comment"
//! click_command = "slack.open"
//!
//! # ── OS notification policy ─────────
//! [notifications]
//! os_notify_on      = "error_only"          # never|error_only|always
//! os_rate_limit_sec = 5                     # min secs between OS pings
//!
//! # ── Environment / preconditions ────
//! [requires]
//! env    = ["SLACK_TOKEN"]                  # dim chip if missing
//! binary = "mnml-msg-slack"                 # PATH-verified at discovery
//! ```

use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Named theme colors the manifest accepts. Unknown values fall
/// back to `cyan` on render. Keeping this small keeps
/// theme-implementation details out of the public manifest
/// surface (same rule mount manifests use).
pub const ALLOWED_COLORS: &[&str] = &[
    "red", "orange", "yellow", "green", "blue", "cyan", "teal", "purple", "pink", "comment",
    "magenta", "fg", "bg2", "white", "black",
];

/// OS notification escalation policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OsNotifyPolicy {
    /// OS notifications disabled for this integration.
    #[default]
    Never,
    /// Fire OS notification only when the integration calls `notify`
    /// with `Level::Error`, or via the auto-escalation rule
    /// (persistent-error → auto-notify).
    ErrorOnly,
    /// Fire OS notification for every `notify` call the integration
    /// makes, regardless of level. Rate-limited by
    /// `os_rate_limit_sec`.
    Always,
}

/// A whole integration manifest, parsed from one TOML file.
#[derive(Debug, Clone, Deserialize)]
pub struct IntegrationManifest {
    // ── Identity ───────────────────────────────
    pub id: String,
    /// Short display name (~20 chars). Rendered as the chip hover,
    /// the tree row label in the Integrations panel, the picker
    /// row, and the detail-pane header. Was `chip.tooltip` before
    /// 2026-08-01; moved up to top level next to `description`
    /// since it's integration-identity, not chip-visuals.
    pub label: String,
    /// One-sentence longer form. Rendered in the detail-pane
    /// subtitle. Optional.
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    /// The compiled integration's binary name (`mnml-aws-amplify`, etc.).
    /// `None` = this manifest is a launcher — no binary of its own,
    /// its actions launch external CLIs via templated `run` strings.
    /// See `crate::launcher_template` for the substitution engine.
    #[serde(default)]
    pub binary: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    // ── Detail-pane metadata (all optional) ────
    // 2026-07-31 — for `Pane::IntegrationDetail`. Rendered as
    // clickable "↗ Homepage / Repository / Docs" rows + a byline
    // "vX.Y.Z by author".
    #[serde(default)]
    pub homepage: Option<String>,
    #[serde(default)]
    pub docs: Option<String>,
    #[serde(default)]
    pub repository: Option<String>,
    #[serde(default)]
    pub author: Option<String>,

    // ── Registered surfaces ────────────────────
    #[serde(default)]
    pub chip: Option<ChipSpec>,
    #[serde(default)]
    pub commands: Vec<CommandSpec>,
    #[serde(default)]
    pub context_menu: Vec<ContextMenuEntry>,
    #[serde(default)]
    pub menu_bar: Vec<MenuBarEntry>,
    #[serde(default)]
    pub statusline: Option<StatuslineSpec>,
    /// Data sources this integration wants mnml to poll on its
    /// behalf — one background thread per source, runs `command`,
    /// parses stdout JSON, caches under `id` for chip rendering
    /// (below). Added 2026-08-17 alongside the paired
    /// `statusline_segments` block. Zero or more chips can share
    /// one source, so an integration whose CLI returns
    /// `{"open": 3, "approved": 1, "stale": 4}` in one shot pays
    /// for exactly one spawn regardless of how many chips read
    /// which subset.
    #[serde(default)]
    pub values_sources: Vec<ValuesSource>,
    /// Statusline chips this integration wants rendered, each
    /// referencing one [`values_sources`] entry via `source` and
    /// formatting a template like `"{open}({approved})"` against
    /// the polled JSON blob. See [`StatuslineSegment`] for the
    /// template rules and install-gate semantics. Added 2026-08-17.
    #[serde(default)]
    pub statusline_segments: Vec<StatuslineSegment>,
    /// #1117 (2026-08-21) — background prefetch declarations. Each
    /// entry names a full-pane data fetch that mnml runs in the
    /// background at `poll_interval_secs` and caches to
    /// `~/.cache/mnml/prefetch/<integration_id>-<prefetch_id>.json`.
    /// When the user opens a Pty pane for this integration launched
    /// with `--only <kind>`, mnml stamps `MNML_PREFETCH_CACHE_FILE=
    /// <path>` on the child env if the launch's kind matches the
    /// prefetch decl's `for_pane_kind`. The integration binary
    /// checks that env at startup and, if the cache is fresh
    /// (age < 3 × poll_interval), hydrates its state from the JSON
    /// instead of doing a cold fetch — the pane paints populated
    /// on frame one. Idempotent no-op for integrations that don't
    /// implement the hydration side.
    #[serde(default)]
    pub prefetch: Vec<PrefetchSource>,
    #[serde(default)]
    pub settings: Vec<SettingsPage>,
    #[serde(default)]
    pub notifications: Option<NotificationsSpec>,
    #[serde(default)]
    pub requires: Option<Requires>,

    /// Auth fields the integration needs before its actions can
    /// run. Rendered by the per-integration Settings pane
    /// (`integration_settings.show`) as a form; save writes the
    /// user's values back to the manifest TOML at the top level
    /// under an `[auth]` table. Phase 2B / 2026-08-11.
    #[serde(default)]
    pub auth: Vec<AuthField>,

    // ── Source tracking ────────────────────────
    #[serde(skip)]
    pub source_path: PathBuf,

    /// Extra env vars this integration's Pty spawns should inject,
    /// merged from `.override.toml`'s `[env]` block after base
    /// manifest load. Task #933 — lets a workspace override (e.g.
    /// demo mode's `demo/workspace/.mnml/integrations/jira.override.toml`)
    /// declare per-integration env vars in the manifest layer instead
    /// of via process-global `unsafe std::env::set_var` at startup.
    /// Consumed by `open_pty_dir` — injected ONLY into this
    /// integration's own spawns (no cross-share, unlike
    /// `integration_auth_env`, whose share is gated by known
    /// `env_fallback` names).
    #[serde(skip)]
    pub override_env: std::collections::HashMap<String, String>,

    /// Values to overlay on top of the disk `[auth_values]` table
    /// (see `AuthField`), merged from `.override.toml`'s
    /// `[auth_values]` block. Task #933 — override WINS on
    /// per-key conflict so a workspace override can shadow a
    /// user's saved value without touching their user-config file.
    /// Consumed by `App::integration_auth_env`.
    #[serde(skip)]
    pub override_auth_values: std::collections::HashMap<String, String>,

    /// #1088 (2026-08-19) — merged from `.override.toml`'s
    /// `auto_update = <bool>` field so the right-click menu can
    /// reflect the current effective state without re-reading the
    /// TOML each frame. `None` = user hasn't set it (falls through
    /// to the global `[integrations] auto_update_{cargo,git}`).
    #[serde(skip)]
    pub auto_update_override: Option<bool>,
}

/// One field the user needs to configure before the integration
/// can talk to its backend — a token, a base URL, an email, etc.
/// Declared once in the integration's manifest at install time;
/// the mnml Settings pane renders one form control per entry and
/// writes the user's answer back to the TOML.
///
/// Storage: values are written to `[auth]` at the top level of the
/// same TOML file:
///
/// ```toml
/// # ~/.config/mnml/integrations/slack_channels.toml
/// id = "slack_channels"
/// ...
///
/// [[auth]]
/// key = "bot_token"
/// label = "Slack bot token"
/// kind = "secret"
/// env_fallback = "SLACK_BOT_TOKEN"
/// help_url = "https://api.slack.com/apps"
/// required = true
///
/// [auth_values]  # ← written by mnml when the user saves
/// bot_token = "xoxb-..."
/// ```
///
/// Phase 4 will move `secret`-kind values into the OS keychain
/// (Keychain / libsecret / DPAPI) — same schema, different backend.
#[derive(Debug, Clone, Deserialize)]
pub struct AuthField {
    /// Key the user's answer is written under in `[auth_values]`.
    pub key: String,
    /// Human label rendered next to the input (e.g.
    /// `"Slack bot token"`).
    pub label: String,
    /// `"secret"` (masked in the UI, keychain-backed in Phase 4)
    /// / `"text"` / `"number"` / `"url"` / `"email"`.
    #[serde(default = "default_kind")]
    pub kind: String,
    /// Env-var name to fall back to when `[auth_values]` doesn't
    /// have a value. Lets existing env-var users skip re-entry
    /// (Slack, Jira, GitHub CLI all have long-standing env-var
    /// conventions).
    #[serde(default)]
    pub env_fallback: Option<String>,
    /// One-line help URL rendered as a clickable "how to get one"
    /// link under the field.
    #[serde(default)]
    pub help_url: Option<String>,
    /// One-sentence inline help under the label.
    #[serde(default)]
    pub help: Option<String>,
    /// When true, an integration action fired without a value here
    /// (and no env_fallback set) triggers the first-hit auth prompt
    /// (Phase 2D).
    #[serde(default)]
    pub required: bool,
}

fn default_kind() -> String {
    "text".to_string()
}

/// The rail chip — what shows up in the INTEGRATIONS section (or
/// the palette bar when `in_palette_bar = true`).
#[derive(Debug, Clone, Deserialize)]
pub struct ChipSpec {
    pub glyph: String,
    pub fallback: String,
    pub color: String,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub in_palette_bar: bool,
    #[serde(default)]
    pub badge_key: Option<String>,
    /// 2026-07-31 — integration-icons SDK. When set, mnml-bridge's
    /// `install_integration` copied a SVG (owned by the integration)
    /// to `~/.config/mnml/glyphs/<id>.svg`. mnml discovers it at
    /// startup + on `integrations.refresh`, assigns a codepoint in
    /// the integration PUA range (`U+F1C00-F1CFF`), and bakes it into
    /// MnmlSymbols.ttf on `integrations.bake_integration_glyphs`. The
    /// manifest's own `glyph` string takes precedence if set —
    /// this only kicks in when `glyph` is empty AND an SVG exists.
    #[serde(default)]
    pub glyph_svg: Option<String>,
    /// 2026-07-31 — explicit codepoint override for the SVG bake.
    /// Uppercase hex, no `U+` prefix (e.g. `"F1B00"`). Trusted;
    /// no range check. Used by integrations that used to depend on
    /// mnml core having baked their glyph at a fixed codepoint,
    /// so an upgrade to the SDK doesn't move their icon.
    #[serde(default)]
    pub glyph_codepoint: Option<String>,
}

fn default_enabled() -> bool {
    true
}

/// One palette command the integration provides.
#[derive(Debug, Clone, Deserialize)]
pub struct CommandSpec {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub keys: Vec<String>,
    /// Ex-command line to execute when the command fires
    /// (e.g. `":term mnml-msg-slack"` or `"slack.internal_action"`).
    pub run: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ContextMenuEntry {
    /// Target entity — `tree.file`, `tree.dir`, `tab`,
    /// `agent.row`, `pane`. Unknown values ignored at merge time.
    pub target: String,
    pub title: String,
    pub command: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MenuBarEntry {
    /// Slash-separated path like `"File > Send via Slack"`.
    pub path: String,
    pub command: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StatuslineSpec {
    /// `"left"` | `"right"`.
    #[serde(default = "default_side")]
    pub side: String,
    pub segment_id: String,
    #[serde(default)]
    pub initial_text: String,
    #[serde(default)]
    pub initial_color: Option<String>,
    #[serde(default)]
    pub click_command: Option<String>,
    /// Priority for overflow truncation — higher wins. 100 by
    /// default; 200 = "always show", 50 = "nice to have".
    #[serde(default = "default_priority")]
    pub priority: u8,
    /// Minimum width before the segment is dropped entirely.
    #[serde(default = "default_min_width")]
    pub min_width: u16,
    /// Maximum width; longer content gets truncated.
    #[serde(default = "default_max_width")]
    pub max_width: u16,
}

fn default_side() -> String {
    "right".to_string()
}
fn default_priority() -> u8 {
    100
}
fn default_min_width() -> u16 {
    4
}
fn default_max_width() -> u16 {
    30
}

/// One polling data source declared by an integration. mnml
/// spawns a background thread that runs `command` on
/// `poll_interval_secs` and parses stdout as JSON, caching the
/// resulting map under `id` for the paired `[[statusline_segments]]`
/// entries to template-render against. Any error (spawn fail,
/// non-JSON stdout, non-object shape) is recorded on the snapshot
/// so the chip can surface a distinct `!` state instead of just
/// going blank. See `src/app/statusline_segments.rs` for the
/// worker/render lifecycle.
#[derive(Debug, Clone, Deserialize)]
pub struct ValuesSource {
    /// Unique-across-all-integrations id. Referenced by
    /// [`StatuslineSegment::source`].
    pub id: String,
    /// Command line to spawn on the poll cadence. First token is
    /// the binary (PATH-resolved with the same walk as
    /// [`crate::integration_manifest::binary_on_path`]); remaining
    /// whitespace-split tokens are argv. No shell expansion.
    pub command: String,
    /// Seconds between polls. `None` (or missing in TOML) falls
    /// back to [`crate::app::statusline_segments::DEFAULT_POLL_SECS`].
    /// Clamped to `[MIN_POLL_SECS, MAX_POLL_SECS]` at spawn time.
    #[serde(default)]
    pub poll_interval_secs: Option<u64>,
}

/// #1117 (2026-08-21) — one background-prefetch declaration. mnml
/// runs `command` at `poll_interval_secs` (jittered by source
/// index — see `start_statusline_segment_workers`), captures stdout
/// verbatim, and writes it to
/// `~/.cache/mnml/prefetch/<integration_id>-<id>.json`. The
/// integration binary reads the file via `MNML_PREFETCH_CACHE_FILE`
/// env when its Pty pane spawns; the freshness gate (age vs poll
/// interval) is enforced integration-side. `for_pane_kind` filters
/// which `--only <kind>` launches get the env stamp — omitted =
/// every launch of this integration.
#[derive(Debug, Clone, Deserialize)]
pub struct PrefetchSource {
    pub id: String,
    pub command: String,
    #[serde(default)]
    pub poll_interval_secs: Option<u64>,
    #[serde(default)]
    pub for_pane_kind: Option<String>,
}

/// One statusline chip declared by an integration. References a
/// [`ValuesSource`] via `source`; renders `format` templated
/// against that source's latest polled JSON. Install-gated (the
/// parent integration's chip must be enabled AND its backing
/// binary must be on PATH) — a chip whose gate fails is not
/// rendered. See `src/app/statusline_segments.rs`.
#[derive(Debug, Clone, Deserialize)]
pub struct StatuslineSegment {
    /// Unique id — also the key mnml stores click-routing and
    /// hover-help under.
    pub id: String,
    /// The [`ValuesSource::id`] this chip reads.
    pub source: String,
    /// Nerd Font (or emoji) glyph prepended to the rendered text.
    pub glyph: String,
    /// Named theme color (`cyan` / `green` / `yellow` / `red` /
    /// `blue` / `magenta` / `comment` / `fg` / `orange` / …). See
    /// [`ALLOWED_COLORS`] for the accepted set. Unknown values
    /// fall back to `comment` at render time.
    pub color: String,
    /// Format template — `{key}` and `{a.b}` substitute values
    /// from the source's JSON. Missing keys render as `?`, non-
    /// string primitives render via `to_string`.
    pub format: String,
    /// Hover-help body shown in the tooltip and info panel. `None`
    /// falls back to a generic "click to fire `<click_command>`"
    /// line when a click command is set, or the chip id otherwise.
    #[serde(default)]
    pub tooltip: Option<String>,
    /// Palette command id fired on left-click. `None` = display-
    /// only (no click affordance).
    #[serde(default)]
    pub click_command: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingsPage {
    pub section: String,
    pub label: String,
    #[serde(default)]
    pub help: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotificationsSpec {
    #[serde(default)]
    pub os_notify_on: OsNotifyPolicy,
    #[serde(default = "default_rate_limit")]
    pub os_rate_limit_sec: u64,
}

fn default_rate_limit() -> u64 {
    5
}

#[derive(Debug, Clone, Deserialize)]
pub struct Requires {
    #[serde(default)]
    pub env: Vec<String>,
    #[serde(default)]
    pub binary: Option<String>,
}

// ── Loader ──────────────────────────────────────────

/// Scan both manifest dirs and return the merged list. Workspace
/// entries shadow user-global entries with the same id.
///
/// The workspace half is skipped entirely for an untrusted workspace:
/// a manifest registers runnable commands and supplies `[env]` for
/// spawns (so `PATH` / `DYLD_INSERT_LIBRARIES` are in play, not just
/// the command string). Trust is consulted here rather than passed in
/// by callers so the gate can't be forgotten at a call site — and so
/// the user clicking Trust is picked up by the next
/// `integrations.refresh` without extra wiring.
pub fn load_all(workspace: &Path) -> Vec<IntegrationManifest> {
    let claims = crate::workspace_trust::scan(workspace);
    let trusted = claims.is_empty()
        || crate::workspace_trust::is_trusted(
            workspace,
            &crate::workspace_trust::fingerprint(&claims),
        );
    load_all_scoped(workspace, user_dir(), trusted)
}

/// Same as `load_all` but with an explicit user-config base
/// directory (used by tests to isolate from `~/.config/mnml/`).
/// Pass `None` to skip the user-global scan entirely.
pub fn load_all_with_user_base(
    workspace: &Path,
    user_base: Option<PathBuf>,
) -> Vec<IntegrationManifest> {
    load_all_scoped(workspace, user_base, true)
}

/// [`load_all_with_user_base`] plus the workspace-trust decision.
/// `trusted = false` drops the workspace manifest dir.
pub fn load_all_scoped(
    workspace: &Path,
    user_base: Option<PathBuf>,
    trusted: bool,
) -> Vec<IntegrationManifest> {
    let mut out: Vec<IntegrationManifest> = Vec::new();

    // User-global first (lower priority).
    if let Some(dir) = user_base {
        scan_dir(&dir, &mut out);
    }
    // Workspace second (higher priority) — trusted workspaces only.
    if trusted {
        scan_dir(&workspace.join(".mnml").join("integrations"), &mut out);
    }

    // Dedup by id, keeping the LAST occurrence (workspace wins).
    let mut seen: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut keep = vec![true; out.len()];
    for (i, m) in out.iter().enumerate() {
        if let Some(&prev) = seen.get(&m.id) {
            keep[prev] = false;
        }
        seen.insert(m.id.clone(), i);
    }
    out.into_iter()
        .enumerate()
        .filter_map(|(i, m)| if keep[i] { Some(m) } else { None })
        .collect()
}

/// User-config dir for integration manifests. Routes through
/// [`data_root`](crate::data_root::data_root) so portable-mode
/// installs read/write here-not-HOME (task #858).
pub fn user_dir() -> Option<PathBuf> {
    Some(crate::data_root::data_root().join("integrations"))
}

/// User-supplied per-field overrides for an integration's rendered
/// chrome. Persisted alongside the canonical manifest as
/// `<id>.override.toml` — same folder, same discovery pass. Every
/// field is `Option<T>`: present = "user cares", absent = "inherit
/// from the base manifest".
///
/// **Scope.** Overrides cover the chip visuals + user-preference
/// fields (`enabled`, `in_palette_bar`) + top-level `label` /
/// `description`. Command bodies, statusline segments, context-menu
/// entries, and other structural surfaces stay canonical — an
/// override that redefined a command's `run` string could silently
/// break the integration's contract with mnml.
///
/// **Why a separate file, not a config.toml block.** Pre-2026-08-03
/// user overrides lived in `[[ui.integration_icon]]` blocks inside
/// mnml's config.toml. Two shapes (manifest vs config raw), two
/// discovery passes, and reinstall couldn't reason about "did the
/// user customize this?" without cross-referencing. One folder =
/// one backup unit + one uninstall gesture.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct IntegrationManifestOverride {
    /// Must match the base manifest's `id`. Present-check-required
    /// so a stray file can't accidentally override an unrelated
    /// integration.
    pub id: String,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub chip: Option<ChipOverride>,
    /// `[env]` — extra env vars this integration's Pty spawns
    /// should inject. Task #933 (2026-08-12). Arbitrary keys; not
    /// tied to the `[[auth]]` schema and NOT cross-shared with
    /// other integrations (contrast: `[auth_values]` propagates
    /// via `AuthField.env_fallback`; `[env]` has no matching
    /// convention, so cross-share would leak arbitrary keys into
    /// unrelated spawns). Copied into
    /// `IntegrationManifest::override_env` by `apply_to`, then
    /// consumed at spawn time by `open_pty_dir` for this
    /// integration only. Cross-integration secret sharing should
    /// go through `[auth_values]` (which uses `env_fallback` to
    /// name the env var the other integrations expect).
    #[serde(default)]
    pub env: Option<std::collections::HashMap<String, String>>,
    /// `[auth_values]` — values to overlay on top of the disk
    /// `[auth_values]` for this integration. Task #933
    /// (2026-08-12). Keys should match a base-manifest
    /// `[[auth]].key`; values follow the same shape (secret
    /// strings, URLs, etc.). OVERRIDE WINS on per-key conflict
    /// with the disk value — so a workspace override can shadow
    /// a user's saved token for the current workspace without
    /// touching the user-config file.
    #[serde(default)]
    pub auth_values: Option<std::collections::HashMap<String, String>>,
    /// #993 step 1 (2026-08-19). Per-integration opt-in override for
    /// auto-update. When set, wins over the global
    /// `Config::integrations.auto_update_{cargo,git}` regardless of
    /// direction — a user with the global `true` can disable
    /// auto-update on a specific integration by writing
    /// `auto_update = false` here; and vice versa. Absent → fall
    /// through to the global. Design:
    /// `docs/design/auto-update-integrations.md`.
    #[serde(default)]
    pub auto_update: Option<bool>,
}

/// Chip-level overrides. Every field optional; only set ones win.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ChipOverride {
    #[serde(default)]
    pub glyph: Option<String>,
    #[serde(default)]
    pub fallback: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    /// Show/hide the chip. Was the primary field users overrode
    /// via the old `[[ui.integration_icon]]` schema.
    #[serde(default)]
    pub enabled: Option<bool>,
    /// Route to the palette-bar cluster rather than the rail. Also
    /// carried over from the old schema.
    #[serde(default)]
    pub in_palette_bar: Option<bool>,
}

impl IntegrationManifestOverride {
    /// Merge `self` into `base`, mutating `base` in place with
    /// whatever fields the override supplied. Fields the override
    /// left `None` keep base's value.
    pub fn apply_to(self, base: &mut IntegrationManifest) {
        if let Some(v) = self.label {
            base.label = v;
        }
        if let Some(v) = self.description {
            base.description = Some(v);
        }
        if let Some(o) = self.chip
            && let Some(chip) = base.chip.as_mut()
        {
            if let Some(v) = o.glyph {
                chip.glyph = v;
            }
            if let Some(v) = o.fallback {
                chip.fallback = v;
            }
            if let Some(v) = o.color
                && ALLOWED_COLORS.contains(&v.as_str())
            {
                chip.color = v;
            }
            if let Some(v) = o.enabled {
                chip.enabled = v;
            }
            if let Some(v) = o.in_palette_bar {
                chip.in_palette_bar = v;
            }
        }
        // Task #933 — layer the two new tables onto the base
        // manifest's runtime-only override_* fields via `extend`
        // (later inserts win per-key). In practice each base
        // manifest gets exactly one `.override.toml` applied to
        // it — `load_all_with_user_base` dedupes whole manifests
        // by id (workspace replaces user-global entirely, not a
        // per-key merge across scopes), so the per-key overwrite
        // only matters if a single override file ever grew a
        // duplicate key inside one table (toml disallows that at
        // parse time, so also effectively never).
        if let Some(env) = self.env {
            base.override_env.extend(env);
        }
        if let Some(av) = self.auth_values {
            base.override_auth_values.extend(av);
        }
        if let Some(au) = self.auto_update {
            base.auto_update_override = Some(au);
        }
    }
}

fn scan_dir(dir: &Path, out: &mut Vec<IntegrationManifest>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    // First pass: parse every `.toml` in the dir, keeping
    // `<id>.override.toml` files aside for a second pass. Doing it
    // in one directory read means we don't care about order (an
    // override file listed before its base still works).
    let mut manifests_added: Vec<usize> = Vec::new();
    let mut overrides: Vec<(String, IntegrationManifestOverride)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(fname) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        // `.override.toml` — user-supplied per-field diffs, applied
        // after the base manifest for the same id lands. Extracted
        // id = filename with `.override.toml` stripped.
        if let Some(stem) = fname.strip_suffix(".override.toml") {
            let text = match std::fs::read_to_string(&path) {
                Ok(t) => t,
                Err(_) => continue,
            };
            match toml::from_str::<IntegrationManifestOverride>(&text) {
                Ok(ov) => {
                    // Defense-in-depth: the id inside the file MUST
                    // match the id in the filename. Guards against a
                    // stray rename silently retargeting overrides at
                    // an unrelated integration.
                    if ov.id != stem {
                        continue;
                    }
                    overrides.push((stem.to_string(), ov));
                }
                Err(_) => continue,
            }
            continue;
        }
        // Regular base manifest.
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        match toml::from_str::<IntegrationManifest>(&text) {
            Ok(mut m) => {
                // 2026-08-01 (P3) — `binary` is now Option: launchers
                // (data-only manifests, no compiled integration) leave it
                // unset. Validate id + label; binary check happens at
                // spawn time in run_ex_command when the manifest
                // actually runs.
                if m.id.is_empty() || m.label.is_empty() {
                    continue;
                }
                // Sanitize unknown chip color → None (renderer
                // will fall back to cyan).
                if let Some(chip) = m.chip.as_mut()
                    && !ALLOWED_COLORS.contains(&chip.color.as_str())
                {
                    chip.color = "cyan".to_string();
                }
                m.source_path = path;
                manifests_added.push(out.len());
                out.push(m);
            }
            Err(_) => continue,
        }
    }
    // Second pass: apply overrides in-place. An override with no
    // matching base is silently dropped — dead data, not an error.
    //
    // #1109 (2026-08-20): match on manifest.id OR the manifest's
    // binary basename. Multi-manifest crates (e.g. `mnml-tracker-jira`
    // produces `jira_work` + `jira_boards` + `jira_fix_versions`) get
    // their auto-update override written to `<crate>.override.toml`
    // (keyed by binary), so the crate-scoped override must fan out
    // to every manifest that shares that binary. Single-manifest
    // integrations (browser, codex) still match on id.
    for (id, ov) in overrides {
        let mut matched = false;
        for &i in &manifests_added {
            let bin_matches = out[i]
                .binary
                .as_deref()
                .map(|b| b.rsplit('/').next().unwrap_or(b) == id)
                .unwrap_or(false);
            if out[i].id == id || bin_matches {
                ov.clone().apply_to(&mut out[i]);
                matched = true;
            }
        }
        // The `for` loop above deliberately does NOT `break` on a
        // hit — a crate-scoped override must apply to every manifest
        // that shares the binary. `matched` is retained only so a
        // future warn-on-dead-override lint has a hook; today it's
        // a no-op (existing behavior: silent drop).
        let _ = matched;
    }
}

impl IntegrationManifest {
    /// True if this integration's `[requires]` predicates are all
    /// satisfied on the current machine. Used by the discovery
    /// overlay to dim chips whose backing integration isn't ready
    /// (missing env var, binary not on PATH).
    pub fn is_ready(&self) -> bool {
        let Some(req) = &self.requires else {
            return true;
        };
        for name in &req.env {
            if std::env::var_os(name).is_none() {
                return false;
            }
        }
        if let Some(bin) = &req.binary
            && !binary_on_path(bin)
        {
            return false;
        }
        true
    }
}

fn binary_on_path(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        if dir.join(name).is_file() {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_manifest() {
        let toml = r#"
id = "slack"
label = "Slack"
binary = "mnml-msg-slack"
"#;
        let m: IntegrationManifest = toml::from_str(toml).unwrap();
        assert_eq!(m.id, "slack");
        assert_eq!(m.label, "Slack");
        assert_eq!(m.binary.as_deref(), Some("mnml-msg-slack"));
        assert!(m.chip.is_none());
        assert!(m.commands.is_empty());
        assert!(m.notifications.is_none());
    }

    #[test]
    fn parses_full_manifest() {
        let toml = r#"
id = "slack"
label = "Slack"
description = "Slack browse + post"
version = "0.1.0"
binary = "mnml-msg-slack"
category = "msg"

[chip]
glyph = "S"
fallback = "Sk"
color = "purple"
enabled = true
in_palette_bar = false
badge_key = "slack"

[[commands]]
id = "slack.open"
title = "Slack: open"
group = "integrations"
keys = ["<leader>iS"]
run = ":term mnml-msg-slack"

[[context_menu]]
target = "tree.file"
title = "Send via Slack"
command = "slack.send_file"

[statusline]
side = "right"
segment_id = "slack"
initial_text = "◇ slack"
initial_color = "comment"
click_command = "slack.open"

[notifications]
os_notify_on = "error_only"
os_rate_limit_sec = 5

[requires]
env = ["SLACK_TOKEN"]
binary = "mnml-msg-slack"
"#;
        let m: IntegrationManifest = toml::from_str(toml).unwrap();
        assert_eq!(m.id, "slack");
        assert_eq!(m.chip.as_ref().unwrap().glyph, "S");
        assert_eq!(m.commands.len(), 1);
        assert_eq!(m.commands[0].id, "slack.open");
        assert_eq!(m.context_menu.len(), 1);
        assert_eq!(m.statusline.as_ref().unwrap().segment_id, "slack");
        assert_eq!(
            m.notifications.as_ref().unwrap().os_notify_on,
            OsNotifyPolicy::ErrorOnly
        );
        assert_eq!(m.requires.as_ref().unwrap().env, vec!["SLACK_TOKEN"]);
    }

    #[test]
    fn workspace_overrides_user() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("integrations");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("foo.toml")).unwrap();
        writeln!(
            f,
            r#"id = "foo"
label = "Workspace Foo"
binary = "mnml-foo"
"#
        )
        .unwrap();
        let manifests = load_all_with_user_base(&ws, None);
        assert_eq!(manifests.len(), 1);
        assert_eq!(manifests[0].label, "Workspace Foo");
    }

    #[test]
    fn unknown_chip_color_falls_back() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("integrations");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("foo.toml")).unwrap();
        writeln!(
            f,
            r#"id = "foo"
label = "Foo"
binary = "mnml-foo"

[chip]
glyph = "F"
fallback = "F"
color = "nonsense-neon"
"#
        )
        .unwrap();
        let manifests = load_all_with_user_base(&ws, None);
        assert_eq!(manifests.len(), 1);
        assert_eq!(manifests[0].chip.as_ref().unwrap().color, "cyan");
    }

    #[test]
    fn drops_manifest_missing_required_id() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let ws = tmp.path().join("ws");
        let ws_dir = ws.join(".mnml").join("integrations");
        std::fs::create_dir_all(&ws_dir).unwrap();
        let mut f = std::fs::File::create(ws_dir.join("bad.toml")).unwrap();
        writeln!(f, r#"name = "No Id" # missing id"#).unwrap();
        let manifests = load_all_with_user_base(&ws, None);
        assert!(manifests.is_empty());
    }

    #[test]
    fn is_ready_checks_env_and_binary() {
        // No requires → always ready.
        let m = IntegrationManifest {
            id: "x".into(),
            label: "X".into(),
            description: None,
            version: None,
            binary: Some("mnml-x".into()),
            category: None,
            chip: None,
            commands: vec![],
            context_menu: vec![],
            menu_bar: vec![],
            statusline: None,
            values_sources: vec![],
            statusline_segments: vec![],
            settings: vec![],
            notifications: None,
            requires: None,
            auth: vec![],
            prefetch: vec![],
            source_path: PathBuf::new(),
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            override_env: std::collections::HashMap::new(),
            override_auth_values: std::collections::HashMap::new(),
            auto_update_override: None,
        };
        assert!(m.is_ready());

        // Missing env → not ready.
        let m = IntegrationManifest {
            requires: Some(Requires {
                env: vec!["DEFINITELY_NOT_SET_ENV_12345".to_string()],
                binary: None,
            }),
            ..m
        };
        assert!(!m.is_ready());
    }

    #[test]
    fn override_toml_layers_on_base_manifest_by_id() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("htop.toml"),
            r#"id = "htop"
label = "htop"
description = "Interactive process viewer"
[chip]
glyph = "H"
fallback = "H"
color = "cyan"
enabled = true
in_palette_bar = false
"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("htop.override.toml"),
            r#"id = "htop"
label = "Top"
[chip]
color = "green"
in_palette_bar = true
"#,
        )
        .unwrap();
        let mut out = Vec::new();
        scan_dir(dir.path(), &mut out);
        assert_eq!(
            out.len(),
            1,
            "override file should not become its own manifest"
        );
        let m = &out[0];
        // Overrides won on the fields they set.
        assert_eq!(m.label, "Top");
        assert_eq!(m.chip.as_ref().unwrap().color, "green");
        assert!(m.chip.as_ref().unwrap().in_palette_bar);
        // Base kept the fields the override left None.
        assert_eq!(m.description.as_deref(), Some("Interactive process viewer"));
        assert_eq!(m.chip.as_ref().unwrap().glyph, "H");
        assert!(m.chip.as_ref().unwrap().enabled);
    }

    #[test]
    fn override_toml_env_and_auth_values_land_on_manifest() {
        // Task #933 — verify the two new tables round-trip through
        // scan_dir + apply_to and end up on the base manifest's
        // runtime `override_env` / `override_auth_values`.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("jira.toml"),
            r#"id = "jira"
label = "Jira"
[chip]
glyph = "J"
fallback = "J"
color = "cyan"
"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("jira.override.toml"),
            r#"id = "jira"

[env]
JIRA_BASE_URL = "http://localhost:7071/jira"
JIRA_PROJECT = "NTL"

[auth_values]
api_token = "demo-token"
email = "ava@bloomlabs.dev"
"#,
        )
        .unwrap();
        let mut out = Vec::new();
        scan_dir(dir.path(), &mut out);
        assert_eq!(out.len(), 1);
        let m = &out[0];
        assert_eq!(
            m.override_env.get("JIRA_BASE_URL").map(String::as_str),
            Some("http://localhost:7071/jira")
        );
        assert_eq!(
            m.override_env.get("JIRA_PROJECT").map(String::as_str),
            Some("NTL")
        );
        assert_eq!(
            m.override_auth_values.get("api_token").map(String::as_str),
            Some("demo-token")
        );
        assert_eq!(
            m.override_auth_values.get("email").map(String::as_str),
            Some("ava@bloomlabs.dev")
        );
    }

    #[test]
    fn override_with_mismatched_id_is_ignored() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("htop.toml"),
            r#"id = "htop"
label = "htop"
[chip]
glyph = "H"
fallback = "H"
color = "cyan"
"#,
        )
        .unwrap();
        // Filename says htop, body says btop — must be rejected.
        std::fs::write(
            dir.path().join("htop.override.toml"),
            r#"id = "btop"
label = "wrong"
"#,
        )
        .unwrap();
        let mut out = Vec::new();
        scan_dir(dir.path(), &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].label, "htop"); // override rejected → base intact
    }

    /// #1109 (2026-08-20) — a crate-scoped override
    /// (`<crate>.override.toml`) fans out to every manifest whose
    /// `binary` basename matches. Regression: before the fix, the
    /// scanner only matched on `manifest.id == override.id`, so
    /// multi-manifest crates like `mnml-tracker-jira` (produces
    /// `jira_work` + `jira_boards` + `jira_fix_versions`) had their
    /// auto-update override silently dropped and the right-click
    /// menu label stayed stale.
    #[test]
    fn override_by_binary_basename_fans_out_to_all_manifests_sharing_crate() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("jira_work.toml"),
            r#"id = "jira_work"
label = "Jira Work"
binary = "mnml-tracker-jira"
"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("jira_boards.toml"),
            r#"id = "jira_boards"
label = "Jira Boards"
binary = "mnml-tracker-jira"
"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("mnml-tracker-jira.override.toml"),
            r#"id = "mnml-tracker-jira"
auto_update = true
"#,
        )
        .unwrap();
        let mut out = Vec::new();
        scan_dir(dir.path(), &mut out);
        assert_eq!(out.len(), 2);
        for m in &out {
            assert_eq!(
                m.auto_update_override,
                Some(true),
                "manifest {} did not receive the crate-scoped override",
                m.id
            );
        }
    }

    #[test]
    fn override_with_no_matching_base_is_silently_dropped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("ghost.override.toml"),
            r#"id = "ghost"
label = "orphan"
"#,
        )
        .unwrap();
        let mut out = Vec::new();
        scan_dir(dir.path(), &mut out);
        assert!(out.is_empty(), "orphan override must not create a manifest");
    }

    #[test]
    fn override_ignores_unknown_color() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("x.toml"),
            r#"id = "x"
label = "X"
[chip]
glyph = "x"
fallback = "x"
color = "cyan"
"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("x.override.toml"),
            r#"id = "x"
[chip]
color = "chartreuse-fluorescent"
"#,
        )
        .unwrap();
        let mut out = Vec::new();
        scan_dir(dir.path(), &mut out);
        assert_eq!(out.len(), 1);
        // Base color kept — the override's unknown color was rejected.
        assert_eq!(out[0].chip.as_ref().unwrap().color, "cyan");
    }
}
