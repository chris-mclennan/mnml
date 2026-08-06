//! Marketplace — federated discovery of mnml apps and launchers.
//!
//! Queries two kinds of external sources to build the "installable
//! things" list shown in mnml's Integrations panel Marketplace tab:
//!
//! 1. **Apps** — compiled siblings on crates.io tagged with the
//!    `mnml-integration` keyword. Anyone can publish. Discovery is
//!    fully public — mnml doesn't gate what appears.
//! 2. **Launchers** — TOML descriptors under a configured GitHub
//!    repo's folder (default: `chris-mclennan/mnml-integrations/launchers`).
//!    Third parties run their own launcher catalogs by adding their
//!    repo to `[[marketplace.source]]` in user config.
//!
//! ## Design
//!
//! - **Blocking fetch on a background thread.** Matches the sibling
//!   loader pattern (`mpsc` channel, main loop polls). Kept out of
//!   this module — this file only exposes synchronous fetch helpers
//!   that a caller wraps in `thread::spawn`.
//! - **Local cache** at `~/.cache/mnml/marketplace.json`. Read on
//!   demand; write after every successful fetch. TTL configurable
//!   (`cache_ttl_secs`, default 3600). Stale-while-revalidate is
//!   the caller's decision.
//! - **Optional gh-auth-token acceleration.** Detected at runtime
//!   via `gh auth token`. Present → 5000 req/hr on GitHub; absent
//!   → 60 req/hr unauth. Neither path fails; the cache absorbs the
//!   rate-limit difference.
//! - **No hardcoded sources.** The default source list ships in
//!   `default_sources()`, but every mnml install can override /
//!   extend via `[[marketplace.source]]` in config. No repo name
//!   is baked into the marketplace query path.
//!
//! ## Not in this module
//!
//! - Config parsing of `[[marketplace.source]]` — P4b.
//! - UI wiring to the Integrations panel Marketplace tab — P4b.
//! - Async plumbing (spawn thread, mpsc) — P4b.
//! - Install actions (cargo install, download TOML) — P4b.
//!
//! P4a's scope is just: fetch → parse → cache round-trip, plus
//! type shapes the UI can render against.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// One entry in the marketplace — an app or a launcher the user
/// could install. Rendered as a row in the Marketplace tab.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketplaceEntry {
    /// Which source produced this entry. Rendered as a small tag
    /// so the user can tell "reference collection" from "third-party".
    pub source_id: String,
    /// App or launcher. Drives install method + rendering.
    pub kind: MarketplaceKind,
    /// Stable id — either the crate name (apps) or the launcher
    /// TOML's `id` field (launchers).
    pub id: String,
    /// Short display name — from Cargo.toml `description` (first
    /// sentence) or the launcher TOML's `label` field.
    pub label: String,
    /// Longer form — from Cargo.toml `description` (full) or the
    /// launcher TOML's `description` field.
    pub description: Option<String>,
    /// `install_command` for apps ("cargo install foo"), download
    /// URL for launchers.
    pub install: InstallSpec,
    /// Optional metadata — downloads (crates.io), stars (GitHub),
    /// last-updated timestamp. Populated when the source provides
    /// it; renderers use it as a sort key.
    #[serde(default)]
    pub stats: EntryStats,
    /// #849 — tagged at fetch time by matching `source_id` against
    /// [`default_sources()`]. Official entries render with a green
    /// badge and sort first; Community entries with a grey badge.
    /// `#[serde(default)]` = older caches deserialize as
    /// `Community` (safe under-count).
    #[serde(default)]
    pub provenance: Provenance,
    /// 2026-08-05 — Nerd Font glyph rendered in the marketplace row,
    /// so an unlisted entry looks like its installed counterpart at
    /// a glance. Sources:
    ///   1. Launcher TOMLs — pulled from `chip.glyph` at parse time.
    ///   2. `builtin_catalog()` — well-known crates.io app IDs
    ///      hardcoded in mnml so users see icons on first fetch
    ///      before any hosted catalog is deployed.
    ///   3. (Future) hosted catalog JSON on mnml's site, fetched as
    ///      a `Catalog` source variant that enriches entries by id.
    /// `None` triggers the kind-based fallback in the renderer.
    #[serde(default)]
    pub glyph: Option<String>,
    /// Companion to `glyph` — theme color name (`"blue"`, `"cyan"`,
    /// `"yellow"`, …), applied to the glyph span. `None` → `t.fg`.
    #[serde(default)]
    pub color: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MarketplaceKind {
    /// Compiled sibling with its own binary. Install via `cargo install`.
    App,
    /// TOML descriptor. Install by downloading the file to
    /// `~/.config/mnml/integrations/<id>.toml`.
    Launcher,
}

/// #849 — provenance of a marketplace entry. Tagged at fetch time
/// by matching the entry's source-id against the shipped default
/// list — NOT a manifest field (any author could set that). The
/// gatekeeper is who has write access to the source repo /
/// crates-io-keyword-cache, and that's exactly what
/// `default_sources()` catalogs.
///
/// Rendering:
/// - Official entries get a green `✓ Official` chip in the
///   marketplace tab row.
/// - Community entries get a grey `~ Community` chip.
/// - Default sort puts Official first, then Community, alphabetical
///   within each group.
///
/// Users overriding a default via a custom-id source (adding
/// `chris-mclennan/mnml-integrations` under a different id) still
/// get the Official tag because the repo URL / crates-keyword
/// matches — see `provenance_for()`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provenance {
    /// First-party — an entry from a source in
    /// [`default_sources()`], matched by source id.
    Official,
    /// Third-party — a user-added source, or any source whose id
    /// isn't in the built-in defaults. Default when deserializing
    /// older caches that predate the field.
    #[serde(other)]
    #[default]
    Community,
}

/// Determine the provenance for a source id by matching against
/// the shipped defaults. Any source that matches a default-source
/// id is Official; everything else is Community.
///
/// This is a fetch-time function that runs when an entry is being
/// constructed. Serialized entries carry their provenance in the
/// cache directly (see `MarketplaceEntry::provenance`), so
/// consumers reading the cache don't need to re-derive it.
pub fn provenance_for(source_id: &str) -> Provenance {
    if default_sources().iter().any(|s| s.id() == source_id) {
        Provenance::Official
    } else {
        Provenance::Community
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InstallSpec {
    /// `cargo install <name>` — for crates.io apps. `--git` variant
    /// is P4b future work when we support git-only apps.
    Cargo { name: String },
    /// HTTP URL to the raw launcher TOML. Downloading it + writing
    /// to `~/.config/mnml/integrations/<id>.toml` completes install.
    LauncherToml { url: String },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EntryStats {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub downloads: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stars: Option<u64>,
    /// Unix timestamp in seconds — from source's "updated_at".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<u64>,
}

/// One configured marketplace source. Users add these via
/// `[[marketplace.source]]` in config; defaults live in
/// [`default_sources()`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Source {
    /// crates.io keyword search — every public crate tagged with
    /// `keyword` shows up. The default `mnml-integration` finds
    /// every published mnml app regardless of author.
    CratesKeyword { id: String, keyword: String },
    /// GitHub repository folder — every `.toml` file directly under
    /// `path` is treated as a launcher descriptor. The user can
    /// point at their own repo to run a private launcher catalog.
    GithubLauncherFolder {
        id: String,
        repo: String,
        path: String,
    },
}

impl Source {
    pub fn id(&self) -> &str {
        match self {
            Source::CratesKeyword { id, .. } => id,
            Source::GithubLauncherFolder { id, .. } => id,
        }
    }
}

/// The default source list mnml ships with. Users' config
/// `[[marketplace.source]]` entries append to this (or replace if
/// they set `[marketplace] use_defaults = false`).
pub fn default_sources() -> Vec<Source> {
    vec![
        Source::CratesKeyword {
            id: "crates.io".to_string(),
            keyword: "mnml-integration".to_string(),
        },
        Source::GithubLauncherFolder {
            id: "chris-mclennan/mnml-integrations".to_string(),
            repo: "chris-mclennan/mnml-integrations".to_string(),
            path: "launchers".to_string(),
        },
    ]
}

// ── crates.io API response shapes ────────────────────────────────
//
// crates.io returns JSON with a `crates: [...]` array. Only the
// fields we render / sort by land in this Deserialize.

#[derive(Debug, Deserialize)]
struct CratesResponse {
    #[serde(default)]
    crates: Vec<CratesCrate>,
}

#[derive(Debug, Deserialize)]
struct CratesCrate {
    #[serde(rename = "name")]
    name: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    downloads: Option<u64>,
    /// ISO 8601 timestamp like "2026-08-01T18:00:00.000000+00:00".
    #[serde(default)]
    updated_at: Option<String>,
}

/// Parse a crates.io keyword-search JSON response into a list of
/// marketplace entries. Pure — takes the response body, no HTTP.
pub fn parse_crates_response(source_id: &str, body: &str) -> Result<Vec<MarketplaceEntry>, String> {
    let resp: CratesResponse =
        serde_json::from_str(body).map_err(|e| format!("crates.io json: {e}"))?;
    let provenance = provenance_for(source_id);
    let out = resp
        .crates
        .into_iter()
        .map(|c| {
            let label = c.name.clone();
            let (glyph, color) = catalog_lookup(&c.name);
            MarketplaceEntry {
                source_id: source_id.to_string(),
                kind: MarketplaceKind::App,
                id: c.name.clone(),
                label,
                description: c.description,
                install: InstallSpec::Cargo { name: c.name },
                stats: EntryStats {
                    downloads: c.downloads,
                    stars: None,
                    updated_at: c.updated_at.and_then(|s| parse_iso8601_secs(&s)),
                },
                provenance,
                glyph,
                color,
            }
        })
        .collect();
    Ok(out)
}

// ── GitHub Contents API response shapes ──────────────────────────
//
// The `/contents/<path>` endpoint returns an array of file objects.
// For each `.toml` file we also fetch its raw content via
// `download_url` and parse it as an IntegrationManifest.

#[derive(Debug, Deserialize)]
struct GhFileEntry {
    name: String,
    #[serde(rename = "type")]
    entry_type: String,
    download_url: Option<String>,
}

/// Filter a GitHub contents-API response body to just the `.toml`
/// file entries directly under the folder. Returns
/// `(filename, download_url)` pairs the caller feeds to
/// [`parse_launcher_toml`] after fetching each file's contents.
pub fn parse_github_folder_response(body: &str) -> Result<Vec<(String, String)>, String> {
    let entries: Vec<GhFileEntry> =
        serde_json::from_str(body).map_err(|e| format!("github contents json: {e}"))?;
    let out = entries
        .into_iter()
        .filter(|e| e.entry_type == "file" && e.name.ends_with(".toml"))
        .filter_map(|e| e.download_url.map(|url| (e.name, url)))
        .collect();
    Ok(out)
}

/// Parse a launcher TOML file's raw contents into a marketplace
/// entry. Uses the existing `IntegrationManifest` type so the
/// schema stays in sync with what mnml expects on install.
pub fn parse_launcher_toml(
    source_id: &str,
    download_url: &str,
    body: &str,
) -> Result<MarketplaceEntry, String> {
    let m: crate::integration_manifest::IntegrationManifest =
        toml::from_str(body).map_err(|e| format!("launcher toml: {e}"))?;
    // Launcher glyph comes from the manifest's chip spec. Fall back
    // to the builtin catalog by id (e.g. a manifest that omits chip
    // still shows a recognizable icon if we know the id).
    let (chip_glyph, chip_color) = match &m.chip {
        Some(c) => (Some(c.glyph.clone()), Some(c.color.clone())),
        None => (None, None),
    };
    let (fallback_glyph, fallback_color) = catalog_lookup(&m.id);
    Ok(MarketplaceEntry {
        source_id: source_id.to_string(),
        kind: MarketplaceKind::Launcher,
        id: m.id,
        label: m.label,
        description: m.description,
        install: InstallSpec::LauncherToml {
            url: download_url.to_string(),
        },
        stats: EntryStats::default(),
        provenance: provenance_for(source_id),
        glyph: chip_glyph.or(fallback_glyph),
        color: chip_color.or(fallback_color),
    })
}

/// Marketplace row glyph lookup — well-known IDs get their real
/// Nerd Font codepoint + color; anything else returns `(None, None)`
/// so the renderer falls back to a neutral kind icon (package for
/// App, plug for Launcher). No monograms — a two-letter placeholder
/// was worse than an honest generic icon.
///
/// Launcher entries also get their glyph from their TOML manifest
/// (populated in `parse_launcher_toml`), which takes precedence
/// over this table. This table is here for **crates.io apps** —
/// mnml has no manifest to consult until after install.
///
/// Future: a `Catalog` source variant will fetch a JSON on the
/// mnml site that OVERRIDES this map so community entries pick up
/// icons without a mnml release.
pub fn catalog_lookup(id: &str) -> (Option<String>, Option<String>) {
    // All codepoints below are inside the standard Nerd Fonts
    // ranges (Devicons E700-E8EF, Codicons EA60-EC1E, MDI
    // F0001-F1AFF) OR the mnml-baked PUA range (F1B00-F20FF).
    // Ghostty's `font-codepoint-map` must route these to a real
    // Nerd Font (e.g. Symbols Nerd Font Mono) for the last three
    // ranges, and to MnmlSymbols for the PUA one.
    let (glyph, color): (&str, &str) = match id {
        // System monitors — real MDI codepoints (verified in font).
        // Prior F0AEF/F0AF5/F0AF6 were md-alpha_b/h/i (letter icons),
        // corrected 2026-08-05.
        "btop" => ("\u{F0A07}", "red"),   // md-monitor_dashboard
        "htop" => ("\u{F0379}", "green"), // md-monitor
        "iftop" => ("\u{F06F3}", "cyan"), // md-network

        // Editors / IDEs — nf-dev-vscode (E8DA). Chose over cod-
        // vscode (EC29) because ghostty 1.3.1 doesn't route EC29
        // even with the codicon range extended — devicon E8DA
        // renders reliably. Both are official VS Code glyphs.
        "vscode" | "VSCode" => ("\u{E8DA}", "blue"),

        // AI (first-party, baked into MnmlSymbols)
        "claude_code" | "claude-code" => ("\u{F1E00}", "orange"),
        "codex" => ("\u{F1E01}", "cyan"),

        // Browser — nf-cod-browser
        "browser" => ("\u{EB01}", "blue"),

        // Database family — dev-database (E64D is in Devicons)
        "mnml-db" => ("\u{E64D}", "blue"),

        // Database drivers — real engine icon + brand color.
        // The [driver] tag is purple (family), but the glyph itself
        // uses each engine's brand color so the icons read like the
        // real logos, not a uniform purple wash.
        "mnml-db-driver-postgres" => ("\u{E76E}", "blue"), // dev-postgresql — postgres elephant blue
        "mnml-db-driver-mariadb" => ("\u{E828}", "teal"),  // dev-mariadb — dark teal seal
        "mnml-db-driver-mysql" => ("\u{E704}", "orange"),  // dev-mysql — orange dolphin
        "mnml-db-driver-redis" => ("\u{E76D}", "red"),     // dev-redis — red cube
        "mnml-db-driver-sqlite" => ("\u{E7C4}", "blue"),   // dev-sqlite
        "mnml-db-driver-docdb" => ("\u{F1C11}", "blue"), // AWS DocumentDB SVG bake — matches redshift/dynamodb AWS blue
        "mnml-db-driver-clickhouse" => ("\u{F1C0F}", "yellow"), // ClickHouse SVG bake in MnmlSymbols
        "mnml-db-driver-redshift" => ("\u{F1C10}", "blue"), // AWS Redshift SVG bake (blue cylinder + graph)
        "mnml-db-driver-dynamodb" => ("\u{F1C06}", "blue"), // AWS SVG bake — DynamoDB blue

        // SCM hosts — Devicons range (E5FA-E8EF).
        "mnml-scm-bitbucket" | "mnml-forge-bitbucket" | "bitbucket" => ("\u{E703}", "blue"),
        "mnml-scm-github" | "mnml-forge-github" | "github" => ("\u{E709}", "fg"),

        // Messaging — Font Awesome BMP (F000-F2E0). Yellow matches
        // the "star" accent color in Slack's brand palette — more
        // distinctive than the aubergine purple and doesn't collide
        // with the mnml-db family purple.
        "mnml-msg-slack" | "slack" => ("\u{F198}", "yellow"),

        // Jira tracker app (3 chips on install) — same F0303 as
        // the launcher so preview matches the installed chip.
        "mnml-tracker-jira" => ("\u{F0303}", "blue"),

        // AWS integrations — SVGs baked from
        // ~/Downloads/mnml-aws-icon-preview-inverted at F1C03-F1C0E.
        // Colors sourced directly from each SVG's fill= attribute so
        // the marketplace matches AWS's official brand palette:
        //   #ED7100 orange  = Compute (ECR, ECS, Lambda)
        //   #C925D1 purple  = Database + DevTools (DynamoDB, RDS, CodeBuild)
        //   #E7157B magenta = App Integration + Observability
        //                     (EventBridge, SNS, SQS, CloudWatch)
        //   #DD344C red     = Security + Front-End (Cognito, Amplify)
        "mnml-aws-amplify" => ("\u{F1C0E}", "red"), // #DD344C
        "mnml-aws-cloudwatch" => ("\u{F1C03}", "magenta"), // #E7157B
        "mnml-aws-codebuild" => ("\u{F1C04}", "purple"), // #C925D1
        "mnml-aws-cognito" => ("\u{F1C05}", "red"), // #DD344C
        "mnml-aws-dynamodb" => ("\u{F1C06}", "purple"), // #C925D1
        "mnml-aws-ecr" => ("\u{F1C07}", "orange"),  // #ED7100
        "mnml-aws-ecs" => ("\u{F1C08}", "orange"),  // #ED7100
        "mnml-aws-eventbridge" => ("\u{F1C09}", "magenta"), // #E7157B
        "mnml-aws-lambda" => ("\u{F1C0A}", "orange"), // #ED7100
        "mnml-aws-rds" => ("\u{F1C0B}", "purple"),  // #C925D1
        "mnml-aws-sns" => ("\u{F1C0C}", "magenta"), // #E7157B
        "mnml-aws-sqs" => ("\u{F1C0D}", "magenta"), // #E7157B

        // Anything else — no match; renderer skips the leading
        // glyph column and just prints the [kind] tag.
        _ => return (None, None),
    };
    (Some(glyph.to_string()), Some(color.to_string()))
}

// ── Cache ─────────────────────────────────────────────────────────

/// Serialized cache file at `~/.cache/mnml/marketplace.json`. Keeps
/// each source's last-successful entries + a Unix-seconds timestamp
/// so we can honor TTL on next load.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MarketplaceCache {
    /// Unix seconds when the cache was last successfully written.
    pub fetched_at: u64,
    /// TTL applied on this write — carried in the file so a shorter
    /// runtime TTL doesn't retroactively invalidate a stale cache.
    /// (Runtime always respects the LATEST of file TTL and config
    /// TTL — err on the side of showing something rather than
    /// nothing.)
    pub ttl_secs: u64,
    pub entries: Vec<MarketplaceEntry>,
}

impl MarketplaceCache {
    /// Standard file location. In HOME mode this is the XDG cache
    /// dir (`~/.cache/mnml/marketplace.json`, kept separate from
    /// `~/.config/mnml/` to follow XDG conventions). In portable
    /// mode the cache lives under `<mnml-data>/cache/` so a
    /// portable install stays self-contained.
    pub fn path() -> Option<PathBuf> {
        if crate::data_root::data_root_kind() == crate::data_root::DataRootKind::Portable {
            return Some(
                crate::data_root::data_root()
                    .join("cache")
                    .join("marketplace.json"),
            );
        }
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        Some(home.join(".cache").join("mnml").join("marketplace.json"))
    }

    /// Load from disk. Returns `None` on any error (missing file,
    /// parse fail, wrong shape) — the cache is best-effort.
    pub fn load_from(path: &Path) -> Option<Self> {
        let text = std::fs::read_to_string(path).ok()?;
        let mut cache: Self = serde_json::from_str(&text).ok()?;
        // 2026-08-05 — enrich pre-glyph caches on load so users see
        // icons without waiting for the next refresh. New fetches
        // already populate `glyph`/`color`; this is only for entries
        // serialized before the field existed.
        for e in &mut cache.entries {
            if e.glyph.is_none() {
                let (g, c) = catalog_lookup(&e.id);
                e.glyph = g;
                e.color = c;
            }
        }
        Some(cache)
    }

    /// Write to disk. Creates the parent dir if missing. Returns
    /// error string on failure so the caller can toast it, but the
    /// caller never NEEDS to succeed — the cache write is a nice-
    /// to-have on top of the successful fetch.
    pub fn save_to(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("mkdir cache: {e}"))?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| format!("serialize marketplace cache: {e}"))?;
        std::fs::write(path, json).map_err(|e| format!("write cache: {e}"))
    }

    /// Has the cache exceeded its TTL? `Some(true)` means expired
    /// (data still safe to render, but a refresh is due). `Some(false)`
    /// means still fresh. `None` when the fetched_at timestamp is
    /// wrong (system clock in a bad state) — treat as expired.
    pub fn is_expired(&self) -> bool {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        now.saturating_sub(self.fetched_at) > self.ttl_secs
    }
}

// ── Helpers ──────────────────────────────────────────────────────

/// Parse an ISO 8601 timestamp like `"2026-08-01T18:00:00Z"` or
/// `"2026-08-01T18:00:00.000000+00:00"` to Unix seconds. Returns
/// None on any parse failure — the timestamp is metadata for sort
/// order only, never load-bearing.
///
/// Hand-rolled to avoid pulling in chrono (not currently a mnml
/// dep). Supports the two forms crates.io / GitHub emit; anything
/// else returns None (the entry just loses its updated_at, doesn't
/// break rendering).
fn parse_iso8601_secs(s: &str) -> Option<u64> {
    // Expected shape: `YYYY-MM-DDTHH:MM:SS[.fraction][Z|+HH:MM|-HH:MM]`.
    // We split on 'T', parse each half, apply timezone offset.
    let (date_str, rest) = s.split_once('T')?;
    let date_parts: Vec<&str> = date_str.split('-').collect();
    if date_parts.len() != 3 {
        return None;
    }
    let year: i64 = date_parts[0].parse().ok()?;
    let month: u32 = date_parts[1].parse().ok()?;
    let day: u32 = date_parts[2].parse().ok()?;
    // Split time from timezone marker.
    let (time_str, tz_offset_secs) = if let Some(idx) = rest.find(['Z', '+', '-']) {
        let (t, tz) = rest.split_at(idx);
        let offset = match tz.chars().next()? {
            'Z' => 0i64,
            sign => {
                let after = &tz[1..];
                let (hh, mm) = after.split_once(':')?;
                let hh: i64 = hh.parse().ok()?;
                let mm: i64 = mm.parse().ok()?;
                let mag = hh * 3600 + mm * 60;
                if sign == '-' { -mag } else { mag }
            }
        };
        (t, offset)
    } else {
        // No timezone marker — assume UTC.
        (rest, 0i64)
    };
    // Strip fractional seconds if present.
    let time_str = time_str.split('.').next()?;
    let time_parts: Vec<&str> = time_str.split(':').collect();
    if time_parts.len() != 3 {
        return None;
    }
    let hh: u32 = time_parts[0].parse().ok()?;
    let mm: u32 = time_parts[1].parse().ok()?;
    let ss: u32 = time_parts[2].parse().ok()?;
    // Convert to Unix seconds via the days-since-epoch algorithm
    // used by every date library. mnml doesn't need microsecond
    // precision here (marketplace sort key), so u64 is fine.
    let epoch_days = days_since_epoch(year, month, day)?;
    let secs =
        epoch_days * 86_400 + (hh as i64) * 3600 + (mm as i64) * 60 + (ss as i64) - tz_offset_secs;
    u64::try_from(secs).ok()
}

/// Days between 1970-01-01 and the given Gregorian date. Returns
/// None for pre-epoch dates (the marketplace never sees those).
///
/// Uses the algorithm from Howard Hinnant's date-time paper —
/// straight arithmetic, no lookup tables.
fn days_since_epoch(year: i64, month: u32, day: u32) -> Option<i64> {
    if year < 1970 || month == 0 || month > 12 || day == 0 || day > 31 {
        return None;
    }
    let y = if month <= 2 { year - 1 } else { year };
    let m = if month <= 2 { month + 9 } else { month - 3 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let doy = ((153 * m as u64 + 2) / 5) + day as u64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe as i64 - 719_468;
    Some(days)
}

// ── HTTP fetch — blocking, one function per source type ──────────
//
// Callers wrap these in `thread::spawn` if they need async delivery
// (see the amplify sibling for the pattern). The functions are
// blocking on purpose: unit-testable, cacheable, no runtime dep.

/// Standard mnml User-Agent for outbound HTTP. GitHub rejects
/// requests without one; crates.io accepts anything but likes
/// unique agents for analytics.
fn user_agent() -> String {
    format!("mnml-marketplace/{}", env!("CARGO_PKG_VERSION"))
}

/// Blocking HTTP fetch for a source. Attaches gh auth token to
/// GitHub requests when available. 10s timeout — matches the
/// max the user should ever wait on a marketplace refresh.
///
/// Returns entries on success; the caller decides whether to
/// merge with cache or overwrite.
pub fn fetch_source(source: &Source) -> Result<Vec<MarketplaceEntry>, String> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(user_agent())
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("build http client: {e}"))?;
    match source {
        Source::CratesKeyword { id, keyword } => {
            let url = format!(
                "https://crates.io/api/v1/crates?keyword={}&per_page=100",
                keyword
            );
            let body = client
                .get(&url)
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.text())
                .map_err(|e| format!("crates.io fetch: {e}"))?;
            parse_crates_response(id, &body)
        }
        Source::GithubLauncherFolder { id, repo, path } => {
            let list_url = format!("https://api.github.com/repos/{}/contents/{}", repo, path);
            let mut req = client.get(&list_url);
            if let Some(tok) = detect_gh_auth_token() {
                req = req.bearer_auth(tok);
            }
            let body = req
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.text())
                .map_err(|e| format!("github contents: {e}"))?;
            let files = parse_github_folder_response(&body)?;
            let mut entries = Vec::with_capacity(files.len());
            for (name, download_url) in files {
                // Best-effort: skip individual files that fail to
                // fetch or parse rather than failing the whole
                // source. Errors go to stderr for diagnostics.
                match client.get(&download_url).send().and_then(|r| r.text()) {
                    Ok(toml_body) => match parse_launcher_toml(id, &download_url, &toml_body) {
                        Ok(entry) => entries.push(entry),
                        Err(e) => eprintln!("marketplace: skip {name}: {e}"),
                    },
                    Err(e) => eprintln!("marketplace: fetch {name}: {e}"),
                }
            }
            Ok(entries)
        }
    }
}

/// Best-effort GitHub auth token discovery — invokes `gh auth token`
/// if the `gh` CLI is on PATH and authenticated. Returns None on
/// any failure. Used by the fetcher to attach `Authorization: Bearer …`
/// on GitHub requests, unlocking 5000 req/hr instead of 60.
///
/// Not called during tests — pure runtime helper.
pub fn detect_gh_auth_token() -> Option<String> {
    let out = std::process::Command::new("gh")
        .args(["auth", "token"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let token = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if token.is_empty() { None } else { Some(token) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_sources_include_crates_and_github() {
        let s = default_sources();
        assert_eq!(s.len(), 2);
        assert!(matches!(s[0], Source::CratesKeyword { .. }));
        assert!(matches!(s[1], Source::GithubLauncherFolder { .. }));
    }

    #[test]
    fn parses_crates_response_with_all_fields() {
        let body = r#"{
            "crates": [
                {
                    "name": "mnml-aws-amplify",
                    "description": "AWS Amplify viewer for mnml",
                    "downloads": 42,
                    "updated_at": "2026-08-01T18:00:00.000000+00:00"
                },
                {
                    "name": "mnml-msg-slack",
                    "description": null,
                    "downloads": null,
                    "updated_at": null
                }
            ]
        }"#;
        let entries = parse_crates_response("crates.io", body).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].id, "mnml-aws-amplify");
        assert_eq!(entries[0].label, "mnml-aws-amplify");
        assert_eq!(
            entries[0].description.as_deref(),
            Some("AWS Amplify viewer for mnml")
        );
        assert_eq!(entries[0].stats.downloads, Some(42));
        assert!(entries[0].stats.updated_at.is_some());
        assert!(matches!(entries[0].kind, MarketplaceKind::App));
        assert!(matches!(entries[0].install, InstallSpec::Cargo { .. }));
        assert_eq!(entries[1].description, None);
        assert_eq!(entries[1].stats.downloads, None);
    }

    #[test]
    fn parses_crates_response_empty() {
        let entries = parse_crates_response("s", r#"{"crates":[]}"#).unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn parses_crates_response_malformed_returns_error() {
        assert!(parse_crates_response("s", "not json").is_err());
    }

    #[test]
    fn parses_github_folder_response_filters_to_toml_files() {
        let body = r#"[
            {
                "name": "htop.toml",
                "type": "file",
                "download_url": "https://raw.githubusercontent.com/x/y/main/launchers/htop.toml"
            },
            {
                "name": "README.md",
                "type": "file",
                "download_url": "https://raw.githubusercontent.com/x/y/main/launchers/README.md"
            },
            {
                "name": "subfolder",
                "type": "dir",
                "download_url": null
            },
            {
                "name": "iftop.toml",
                "type": "file",
                "download_url": "https://raw.githubusercontent.com/x/y/main/launchers/iftop.toml"
            }
        ]"#;
        let entries = parse_github_folder_response(body).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].0, "htop.toml");
        assert_eq!(entries[1].0, "iftop.toml");
    }

    #[test]
    fn parses_launcher_toml_end_to_end() {
        let body = r#"
id = "htop"
label = "htop"
description = "Interactive process viewer"

[chip]
glyph = "5"
fallback = "H"
color = "green"
enabled = false

[[commands]]
id = "htop.open"
title = "htop: open"
group = "system"
run = ":term htop"
"#;
        let entry = parse_launcher_toml("src", "https://example/htop.toml", body).unwrap();
        assert_eq!(entry.id, "htop");
        assert_eq!(entry.label, "htop");
        assert_eq!(
            entry.description.as_deref(),
            Some("Interactive process viewer")
        );
        assert!(matches!(entry.kind, MarketplaceKind::Launcher));
        match &entry.install {
            InstallSpec::LauncherToml { url } => assert_eq!(url, "https://example/htop.toml"),
            _ => panic!("wrong install spec"),
        }
    }

    #[test]
    fn cache_roundtrips_via_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marketplace.json");
        let original = MarketplaceCache {
            fetched_at: 1_754_000_000,
            ttl_secs: 3600,
            entries: vec![MarketplaceEntry {
                source_id: "crates.io".to_string(),
                kind: MarketplaceKind::App,
                id: "mnml-x".to_string(),
                label: "mnml-x".to_string(),
                description: Some("An x".to_string()),
                install: InstallSpec::Cargo {
                    name: "mnml-x".to_string(),
                },
                stats: EntryStats {
                    downloads: Some(100),
                    stars: None,
                    updated_at: Some(1_753_000_000),
                },
                provenance: Provenance::Official,
                glyph: None,
                color: None,
            }],
        };
        original.save_to(&path).unwrap();
        let loaded = MarketplaceCache::load_from(&path).unwrap();
        assert_eq!(loaded.entries.len(), 1);
        assert_eq!(loaded.entries[0].id, "mnml-x");
        assert_eq!(loaded.fetched_at, 1_754_000_000);
    }

    /// #849 — the two default-source ids get `Official`; anything
    /// else is `Community`. Round-trips through the `default_sources()`
    /// list so any future addition of a default source is
    /// automatically covered.
    #[test]
    fn provenance_for_default_source_ids_is_official() {
        for source in default_sources() {
            assert_eq!(
                provenance_for(source.id()),
                Provenance::Official,
                "default source {:?} should be Official",
                source.id()
            );
        }
    }

    #[test]
    fn provenance_for_user_added_source_is_community() {
        for id in ["my-catalog", "some-other-source", ""] {
            assert_eq!(
                provenance_for(id),
                Provenance::Community,
                "unknown source id {id:?} should be Community"
            );
        }
    }

    /// Unrecognized provenance string (say a future variant an
    /// older mnml doesn't know about) deserializes as Community
    /// via `#[serde(other)]`. Distinct from the "field missing"
    /// case above — both mechanisms are required, both land on
    /// the same safe under-count.
    #[test]
    fn unknown_provenance_string_deserializes_as_community() {
        let unknown_variant = r#"{
            "fetched_at": 1754000000,
            "ttl_secs": 3600,
            "entries": [{
                "source_id": "crates.io",
                "kind": "app",
                "id": "foo",
                "label": "Foo",
                "description": null,
                "install": {"kind": "cargo", "name": "foo"},
                "stats": {},
                "provenance": "premium"
            }]
        }"#;
        let cache: MarketplaceCache = serde_json::from_str(unknown_variant).unwrap();
        assert_eq!(cache.entries[0].provenance, Provenance::Community);
    }

    /// Old cache entries lacking the field deserialize as
    /// `Community` (the `#[serde(default)]`). Users on stale
    /// caches never see false-Official labels for arbitrary crates.
    #[test]
    fn old_cache_entries_default_to_community_provenance() {
        let old_shape = r#"{
            "fetched_at": 1754000000,
            "ttl_secs": 3600,
            "entries": [{
                "source_id": "crates.io",
                "kind": "app",
                "id": "foo",
                "label": "Foo",
                "description": null,
                "install": {"kind": "cargo", "name": "foo"},
                "stats": {}
            }]
        }"#;
        let cache: MarketplaceCache = serde_json::from_str(old_shape).unwrap();
        assert_eq!(cache.entries.len(), 1);
        assert_eq!(cache.entries[0].provenance, Provenance::Community);
    }

    #[test]
    fn cache_missing_file_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.json");
        assert!(MarketplaceCache::load_from(&path).is_none());
    }

    #[test]
    fn cache_expiry_math() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let fresh = MarketplaceCache {
            fetched_at: now,
            ttl_secs: 3600,
            entries: vec![],
        };
        assert!(!fresh.is_expired());
        let stale = MarketplaceCache {
            fetched_at: now - 4000,
            ttl_secs: 3600,
            entries: vec![],
        };
        assert!(stale.is_expired());
    }

    #[test]
    fn parses_iso_8601_variations() {
        assert!(parse_iso8601_secs("2026-08-01T18:00:00Z").is_some());
        assert!(parse_iso8601_secs("2026-08-01T18:00:00.000000+00:00").is_some());
        assert!(parse_iso8601_secs("not a timestamp").is_none());
    }
}
