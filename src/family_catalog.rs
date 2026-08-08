//! Hardcoded catalog of known `mnml-*` family siblings.
//!
//! Drives the `+` "Add integration" discovery overlay: lists every
//! sibling the user might want, regardless of whether they currently
//! have it installed. Each entry carries:
//!
//!  - `binary` — leaf name we probe via `integration_detect`
//!  - `repo_url` + `pinned_version` — what we'd run for `cargo install`
//!  - `icon_template` — the default `[[ui.integration_icon]]` shape
//!    (glyph / color / fallback / tooltip / command) we'd add to the
//!    user's rail config if they accept the row
//!
//! Updating: add an entry here when you publish a new public sibling.
//! Keep order stable per category — overlay rendering preserves it.

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Category {
    Aws,
    Db,
    Forge,
    Tracker,
    Fs,
    Test,
    Music,
    Web,
    Obs,
    Msg,
    Cdn,
    Virt,
    Other,
}

impl Category {
    pub fn header(self) -> &'static str {
        match self {
            Category::Aws => "AWS",
            Category::Db => "Databases",
            Category::Forge => "Forges (SCM)",
            Category::Tracker => "Trackers",
            Category::Fs => "Filesystems",
            Category::Test => "Test runners",
            Category::Music => "Music",
            Category::Web => "Web",
            Category::Obs => "Observability",
            Category::Msg => "Messaging",
            Category::Cdn => "CDN / Edge",
            Category::Virt => "Virtualization & containers",
            Category::Other => "Other",
        }
    }
}

#[derive(Copy, Clone, Debug)]
pub struct IconTemplate {
    pub glyph: &'static str,
    pub fallback: &'static str,
    pub color: &'static str,
    pub label: &'static str,
}

/// Mount manifest stub — present for catalog entries whose sibling
/// speaks the Bridge tier-4 Mount protocol (renders into an mnml
/// pane via UDS). Look up via `mount_stub_for(id)`. Used by the
/// auto-installer to write a real `<id>.toml` manifest after
/// `cargo install` completes. Pty-only siblings (most) have no
/// entry — `mount_stub_for` returns None.
#[derive(Copy, Clone, Debug)]
pub struct MountStub {
    /// Display label shown in the activity-bar tooltip + pane title.
    pub name: &'static str,
    /// Nerd Font glyph used as the activity-bar icon.
    pub icon: &'static str,
    /// Named theme color — one of the names allowed by
    /// `mount_manifest::ALLOWED_COLORS`.
    pub color: &'static str,
}

/// Look up the Mount manifest stub for a given family `id`. Returns
/// None for Pty-only siblings. Kept as a separate table from
/// `CATALOG` so existing entries don't need to grow a field every
/// time the Mount story expands.
pub fn mount_stub_for(id: &str) -> Option<MountStub> {
    MOUNT_STUBS
        .iter()
        .find(|(catalog_id, _)| *catalog_id == id)
        .map(|(_, stub)| *stub)
}

const MOUNT_STUBS: &[(&str, MountStub)] = &[];

#[derive(Copy, Clone, Debug)]
pub struct IntegrationApp {
    /// Stable id (matches the `IntegrationIcon.id` we'd register).
    pub id: &'static str,
    /// Binary leaf name probed by `integration_detect`.
    pub binary: &'static str,
    pub category: Category,
    pub repo_url: &'static str,
    pub pinned_version: &'static str,
    /// One-line description (shown in overlay + as tooltip).
    pub one_liner: &'static str,
    pub icon: IconTemplate,
}

impl IntegrationApp {
    /// `true` when this catalog entry isn't a separate cargo-install
    /// sibling but is built into mnml core (HTTP client today, maybe
    /// more in future). Marked by `pinned_version == "built-in"` as
    /// the sentinel.
    pub fn is_builtin(&self) -> bool {
        self.pinned_version == "built-in"
    }

    /// `true` when this catalog entry uses a custom palette command
    /// instead of `:term <binary>` — used to route mixr (and any
    /// future similar siblings) to their dedicated open handler.
    pub fn uses_custom_command(&self) -> bool {
        self.id == "mixr"
    }

    /// `true` for entries that should be hidden from public UI
    /// surfaces (Integrations rail discovery overlay + install
    /// picker). Currently unused — the last private entry was
    /// removed 2026-07-03 (moved to the Integration SDK's
    /// user-managed manifests). Kept as an API hook for future
    /// private-catalog needs.
    pub fn is_private(&self) -> bool {
        false
    }

    /// The full `cargo install` invocation a user would run. Returns
    /// a no-op note for built-in entries (they ship with mnml core).
    ///
    /// When `pinned_version == "main"` we drop the `--tag` flag so
    /// the command tracks HEAD (used for in-development siblings
    /// that haven't tagged a release yet).
    pub fn install_command(&self) -> String {
        if self.is_builtin() {
            return format!(
                "({} is built into mnml core — no install needed)",
                self.binary
            );
        }
        if self.pinned_version == "main" {
            return format!("cargo install --git {} {}", self.repo_url, self.binary);
        }
        format!(
            "cargo install --git {} --tag {} {}",
            self.repo_url, self.pinned_version, self.binary
        )
    }

    /// The launch command to invoke when the rail chip is clicked.
    /// Built-in entries use a per-id command like `:http.send` rather
    /// than `:term <binary>`; mixr uses `:mixr.show` (dedicated open
    /// handler that reuses an already-open pty).
    pub fn launch_command(&self) -> String {
        if self.uses_custom_command() {
            return match self.id {
                "mixr" => "mixr.show".to_string(),
                _ => format!(":term {}", self.binary),
            };
        }
        if self.is_builtin() {
            return match self.id {
                "http" => ":http.send".to_string(),
                _ => format!(":term {}", self.binary),
            };
        }
        format!(":term {}", self.binary)
    }
}

/// The catalog. Order here is the in-overlay order (grouped by
/// category by the renderer).
/// 2026-08-01 (P1b) — CATALOG emptied. The marketplace module
/// (`crate::marketplace`) is now the source of truth for what apps
/// exist. Callers of `CATALOG.iter()` return empty here; users install
/// apps via the Integrations panel Marketplace tab or by running
/// `<sibling> --install` directly after `cargo install`.
pub const CATALOG: &[IntegrationApp] = &[];

pub fn catalog() -> &'static [IntegrationApp] {
    CATALOG
}

/// Find a catalog entry by binary name.
pub fn find_by_binary(name: &str) -> Option<&'static IntegrationApp> {
    CATALOG.iter().find(|s| s.binary == name)
}

/// Auto-discovered sibling — found at runtime on `$PATH` or a
/// well-known dir, but not present in the hardcoded `CATALOG`.
/// Owns its strings (the catalog uses `&'static str` because every
/// entry is known at compile time; discovered entries can't be).
///
/// Install command is `None` because we don't know the repo URL —
/// the user already has the binary. The `+` overlay surfaces these
/// as installed-but-not-yet-in-rail, with `i` and `y` no-ops.
#[derive(Debug, Clone)]
pub struct DiscoveredApp {
    pub id: String,
    pub binary: String,
    pub category: Category,
    pub one_liner: String,
    pub icon: OwnedIconTemplate,
}

#[derive(Debug, Clone)]
pub struct OwnedIconTemplate {
    pub glyph: String,
    pub fallback: String,
    pub color: String,
    pub label: String,
}

impl DiscoveredApp {
    /// Stringly `:term <binary>` invocation. Mirrors
    /// `IntegrationApp::launch_command()`.
    pub fn launch_command(&self) -> String {
        format!(":term {}", self.binary)
    }
}

/// Reference to *some* sibling — either a hardcoded catalog entry
/// or an auto-discovered one. Lets the discovery overlay render
/// both kinds with one code path.
#[derive(Debug, Clone)]
pub enum AppRef {
    Catalog(&'static IntegrationApp),
    Discovered(DiscoveredApp),
}

impl AppRef {
    pub fn id(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.id,
            AppRef::Discovered(s) => &s.id,
        }
    }
    pub fn binary(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.binary,
            AppRef::Discovered(s) => &s.binary,
        }
    }
    pub fn category(&self) -> Category {
        match self {
            AppRef::Catalog(s) => s.category,
            AppRef::Discovered(s) => s.category,
        }
    }
    pub fn one_liner(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.one_liner,
            AppRef::Discovered(s) => &s.one_liner,
        }
    }
    pub fn icon_glyph(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.icon.glyph,
            AppRef::Discovered(s) => &s.icon.glyph,
        }
    }
    pub fn icon_fallback(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.icon.fallback,
            AppRef::Discovered(s) => &s.icon.fallback,
        }
    }
    pub fn icon_color(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.icon.color,
            AppRef::Discovered(s) => &s.icon.color,
        }
    }
    pub fn icon_label(&self) -> &str {
        match self {
            AppRef::Catalog(s) => s.icon.label,
            AppRef::Discovered(s) => &s.icon.label,
        }
    }
    pub fn launch_command(&self) -> String {
        match self {
            AppRef::Catalog(s) => s.launch_command(),
            AppRef::Discovered(s) => s.launch_command(),
        }
    }
    /// Install command — `Some(cargo cmd)` for cargo-install catalog
    /// entries, `None` for discovered entries (we don't know the repo
    /// URL) AND for built-in catalog entries (they're already part of
    /// mnml core). Drives the `i`/`y` actions in the discovery overlay.
    pub fn install_command(&self) -> Option<String> {
        match self {
            AppRef::Catalog(s) if s.is_builtin() => None,
            AppRef::Catalog(s) => Some(s.install_command()),
            AppRef::Discovered(_) => None,
        }
    }

    /// `true` when this sibling is built into mnml core (HTTP) rather
    /// than a standalone install. Built-ins always count as installed
    /// by the discovery overlay.
    pub fn is_builtin(&self) -> bool {
        matches!(self, AppRef::Catalog(s) if s.is_builtin())
    }
    pub fn is_discovered(&self) -> bool {
        matches!(self, AppRef::Discovered(_))
    }
}

/// Walk `$PATH` + well-known dirs and synthesize a `DiscoveredApp`
/// for every `mnml-<class>-<name>` binary that ISN'T already in the
/// hardcoded `CATALOG`. Categories are derived from the class prefix
/// (`aws` → `Aws`, `db` → `Db`, etc.); unknown classes land in
/// `Other`. Icon templates use category-derived defaults so the
/// rows render with the right family-feel.
pub fn discover_uncataloged() -> Vec<DiscoveredApp> {
    let cataloged: std::collections::HashSet<&str> = CATALOG.iter().map(|s| s.binary).collect();
    let mut out = Vec::new();
    for binary in crate::integration_detect::discover_mnml_binaries() {
        if cataloged.contains(binary.as_str()) {
            continue;
        }
        let (class, name) = split_sibling_name(&binary);
        let category = class_to_category(class);
        let icon = synth_icon_for(category, name);
        let id = name.replace('-', "_");
        let one_liner = format!("auto-discovered {} sibling", class);
        out.push(DiscoveredApp {
            id,
            binary,
            category,
            one_liner,
            icon,
        });
    }
    out
}

/// `mnml-<class>-<name>` → (`class`, `name`). Assumes the binary
/// already passed [`integration_detect::looks_like_mnml_integration`].
fn split_sibling_name(binary: &str) -> (&str, &str) {
    let rest = binary.strip_prefix("mnml-").unwrap_or(binary);
    rest.split_once('-').unwrap_or((rest, ""))
}

fn class_to_category(class: &str) -> Category {
    match class {
        "aws" => Category::Aws,
        "db" => Category::Db,
        "forge" => Category::Forge,
        "tracker" => Category::Tracker,
        "fs" => Category::Fs,
        "test" => Category::Test,
        "music" => Category::Music,
        "web" => Category::Web,
        "obs" => Category::Obs,
        "msg" => Category::Msg,
        "cdn" => Category::Cdn,
        "virt" => Category::Virt,
        _ => Category::Other,
    }
}

/// Synthesize an icon template for a discovered sibling. Each category
/// gets a distinct color so the rail strip stays scannable; we use a
/// generic `cog` glyph for the icon since we don't know the right
/// per-tool one.
fn synth_icon_for(category: Category, name: &str) -> OwnedIconTemplate {
    // Generic nerd-font glyph (nf-fa-cog).
    let glyph = "\u{F013}".to_string();
    // 2-char fallback derived from the binary name.
    let fallback = name
        .chars()
        .take(2)
        .collect::<String>()
        .to_ascii_uppercase();
    let color = match category {
        Category::Aws => "yellow",
        Category::Db => "teal",
        Category::Forge => "blue",
        Category::Tracker => "purple",
        Category::Fs => "orange",
        Category::Test => "green",
        Category::Music => "pink",
        Category::Web => "blue",
        Category::Obs => "purple",
        Category::Msg => "green",
        Category::Cdn => "orange",
        Category::Virt => "blue",
        Category::Other => "cyan",
    }
    .to_string();
    let label = format!("mnml-{}-{}", category_class(category), name);
    OwnedIconTemplate {
        glyph,
        fallback,
        color,
        label,
    }
}

fn category_class(category: Category) -> &'static str {
    match category {
        Category::Aws => "aws",
        Category::Db => "db",
        Category::Forge => "forge",
        Category::Tracker => "tracker",
        Category::Fs => "fs",
        Category::Test => "test",
        Category::Music => "music",
        Category::Web => "web",
        Category::Obs => "obs",
        Category::Msg => "msg",
        Category::Cdn => "cdn",
        Category::Virt => "virt",
        Category::Other => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_is_empty_after_p1b() {
        // 2026-08-01 (P1b) — inverted assertion. Marketplace is now
        // the source of truth for available apps; CATALOG deliberately
        // stays empty. This test locks the invariant so re-populating
        // the const is caught in code review.
        assert!(CATALOG.is_empty());
    }

    #[test]
    fn install_command_uses_tagged_install() {
        // Synthetic entry — every catalog pin is currently `main`
        // (2026-06-26 audit; see TODO.md). This test exercises the
        // tagged path explicitly so the --tag emission stays under
        // test coverage regardless of catalog state.
        let synth = IntegrationApp {
            id: "synth",
            binary: "mnml-synth",
            category: Category::Other,
            repo_url: "https://github.com/chris-mclennan/mnml-synth",
            pinned_version: "v9.9.9",
            one_liner: "synthetic test entry",
            icon: IconTemplate {
                glyph: "X",
                fallback: "Sy",
                color: "white",
                label: "synth",
            },
        };
        let cmd = synth.install_command();
        assert!(cmd.contains("--git"));
        assert!(cmd.contains("--tag v9.9.9"));
        assert!(cmd.contains("mnml-synth"));
        assert!(cmd.starts_with("cargo install"));
    }

    // 2026-08-01 (P1b) — install_command_skips_tag_when_pin_is_main,
    // launch_command_uses_term, and every_repo_url_is_github were
    // catalog-content assertions; the CATALOG is empty now
    // (marketplace is the source of truth) so these tests have
    // nothing to run against. Deleted.

    #[test]
    fn split_sibling_name_canonical() {
        assert_eq!(split_sibling_name("mnml-aws-lambda"), ("aws", "lambda"));
        assert_eq!(split_sibling_name("mnml-tracker-jira"), ("tracker", "jira"));
        assert_eq!(
            split_sibling_name("mnml-aws-cloudwatch-logs"),
            ("aws", "cloudwatch-logs")
        );
    }

    #[test]
    fn class_to_category_maps_known_classes() {
        assert_eq!(class_to_category("aws"), Category::Aws);
        assert_eq!(class_to_category("db"), Category::Db);
        assert_eq!(class_to_category("forge"), Category::Forge);
        assert_eq!(class_to_category("tracker"), Category::Tracker);
        assert_eq!(class_to_category("fs"), Category::Fs);
        assert_eq!(class_to_category("test"), Category::Test);
        assert_eq!(class_to_category("unknown"), Category::Other);
    }

    #[test]
    fn synth_icon_picks_color_per_category() {
        assert_eq!(synth_icon_for(Category::Aws, "x").color, "yellow");
        assert_eq!(synth_icon_for(Category::Db, "x").color, "teal");
        assert_eq!(synth_icon_for(Category::Other, "x").color, "cyan");
    }

    // 2026-08-01 (P1b) — sibling_ref_catalog_passthrough_methods and
    // builtin_catalog_entry_has_no_install_command needed real
    // CATALOG entries. Deleted with the catalog emptying.

    #[test]
    fn sibling_ref_discovered_has_no_install_command() {
        let d = DiscoveredApp {
            id: "x".into(),
            binary: "mnml-other-x".into(),
            category: Category::Other,
            one_liner: "auto-discovered other sibling".into(),
            icon: OwnedIconTemplate {
                glyph: "g".into(),
                fallback: "Ot".into(),
                color: "cyan".into(),
                label: "mnml-other-x".into(),
            },
        };
        let r = AppRef::Discovered(d);
        assert!(r.is_discovered());
        assert!(r.install_command().is_none());
        assert_eq!(r.launch_command(), ":term mnml-other-x");
    }
}
