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
            Category::Other => "Other",
        }
    }
}

#[derive(Copy, Clone, Debug)]
pub struct IconTemplate {
    pub glyph: &'static str,
    pub fallback: &'static str,
    pub color: &'static str,
    pub tooltip: &'static str,
}

#[derive(Copy, Clone, Debug)]
pub struct FamilySibling {
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

impl FamilySibling {
    /// The full `cargo install` invocation a user would run.
    pub fn install_command(&self) -> String {
        format!(
            "cargo install --git {} --tag {} {}",
            self.repo_url, self.pinned_version, self.binary
        )
    }

    /// The `:host.launch <binary>` shape that the rail chip should
    /// invoke when clicked.
    pub fn launch_command(&self) -> String {
        format!(":host.launch {}", self.binary)
    }
}

/// The catalog. Order here is the in-overlay order (grouped by
/// category by the renderer).
pub const CATALOG: &[FamilySibling] = &[
    // ── AWS ───────────────────────────────────────────────────
    FamilySibling {
        id: "codebuild",
        binary: "mnml-aws-codebuild",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-codebuild",
        pinned_version: "v0.1.0",
        one_liner: "AWS CodeBuild project + build viewer",
        icon: IconTemplate {
            glyph: "\u{F0E7B}", // nf-md-package_variant
            fallback: "CB",
            color: "yellow",
            tooltip: "AWS CodeBuild",
        },
    },
    FamilySibling {
        id: "cloudwatch_logs",
        binary: "mnml-aws-cloudwatch-logs",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs",
        pinned_version: "v0.2.0",
        one_liner: "Live tail CloudWatch log groups",
        icon: IconTemplate {
            glyph: "\u{F0E5C}", // nf-md-text-box-search
            fallback: "CW",
            color: "yellow",
            tooltip: "CloudWatch Logs live tail",
        },
    },
    FamilySibling {
        id: "amplify",
        binary: "mnml-aws-amplify",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-amplify",
        pinned_version: "v0.1.0",
        one_liner: "Amplify apps + branches + deploy jobs",
        icon: IconTemplate {
            glyph: "\u{F087D}", // nf-md-rocket-launch
            fallback: "Am",
            color: "purple",
            tooltip: "Amplify apps + deploys",
        },
    },
    FamilySibling {
        id: "lambda",
        binary: "mnml-aws-lambda",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-lambda",
        pinned_version: "v0.2.0",
        one_liner: "Lambda function browser + log-tail handoff",
        icon: IconTemplate {
            glyph: "\u{F0EBF}",
            fallback: "La",
            color: "orange",
            tooltip: "Lambda function browser",
        },
    },
    FamilySibling {
        id: "eventbridge",
        binary: "mnml-aws-eventbridge",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-eventbridge",
        pinned_version: "v0.2.0",
        one_liner: "EventBridge buses + rules + per-rule targets",
        icon: IconTemplate {
            glyph: "\u{F0CE0}",
            fallback: "EB",
            color: "pink",
            tooltip: "EventBridge buses + rules",
        },
    },
    FamilySibling {
        id: "rds",
        binary: "mnml-aws-rds",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-rds",
        pinned_version: "v0.1.0",
        one_liner: "RDS DB instances + Aurora clusters browser",
        icon: IconTemplate {
            glyph: "\u{F1C0}", // nf-fa-database
            fallback: "RD",
            color: "blue",
            tooltip: "RDS database browser",
        },
    },
    FamilySibling {
        id: "ecs",
        binary: "mnml-aws-ecs",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-ecs",
        pinned_version: "v0.1.0",
        one_liner: "ECS clusters + services with deployment + events",
        icon: IconTemplate {
            glyph: "\u{F0F12}", // nf-md-server
            fallback: "EC",
            color: "green",
            tooltip: "ECS clusters + services",
        },
    },
    FamilySibling {
        id: "ecr",
        binary: "mnml-aws-ecr",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-ecr",
        pinned_version: "v0.1.0",
        one_liner: "ECR repositories + image tags browser",
        icon: IconTemplate {
            glyph: "\u{F03D7}", // nf-md-archive
            fallback: "ER",
            color: "purple",
            tooltip: "ECR container registry",
        },
    },
    FamilySibling {
        id: "cognito",
        binary: "mnml-aws-cognito",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-cognito",
        pinned_version: "v0.1.0",
        one_liner: "Cognito User Pool + recent users browser",
        icon: IconTemplate {
            glyph: "\u{F0004}", // nf-md-account_circle
            fallback: "Co",
            color: "cyan",
            tooltip: "Cognito User Pools + users",
        },
    },
    FamilySibling {
        id: "sqs",
        binary: "mnml-aws-sqs",
        category: Category::Aws,
        repo_url: "https://github.com/chris-mclennan/mnml-aws-sqs",
        pinned_version: "v0.1.0",
        one_liner: "SQS queue browser with lazy per-queue attributes",
        icon: IconTemplate {
            glyph: "\u{F09FE}", // nf-md-mailbox_outline
            fallback: "Sq",
            color: "yellow",
            tooltip: "SQS queues",
        },
    },
    // ── Filesystem / Storage ──────────────────────────────────
    FamilySibling {
        id: "s3",
        binary: "mnml-fs-s3",
        category: Category::Fs,
        repo_url: "https://github.com/chris-mclennan/mnml-fs-s3",
        pinned_version: "v0.2.0",
        one_liner: "Amazon S3 bucket + object browser",
        icon: IconTemplate {
            glyph: "\u{F0162}", // nf-md-bucket_outline
            fallback: "S3",
            color: "orange",
            tooltip: "Amazon S3 browser",
        },
    },
    // ── Databases ─────────────────────────────────────────────
    FamilySibling {
        id: "dynamodb",
        binary: "mnml-db-dynamodb",
        category: Category::Db,
        repo_url: "https://github.com/chris-mclennan/mnml-db-dynamodb",
        pinned_version: "v0.1.0",
        one_liner: "DynamoDB table browser (scan-based)",
        icon: IconTemplate {
            glyph: "\u{F1C0}", // nf-fa-database
            fallback: "Dy",
            color: "teal",
            tooltip: "DynamoDB table browser",
        },
    },
    // ── Forges (SCM) ──────────────────────────────────────────
    FamilySibling {
        id: "bitbucket",
        binary: "mnml-forge-bitbucket",
        category: Category::Forge,
        repo_url: "https://github.com/chris-mclennan/mnml-forge-bitbucket",
        pinned_version: "v0.1.0",
        one_liner: "Bitbucket PR + pipeline viewer",
        icon: IconTemplate {
            glyph: "\u{F0CB1}",
            fallback: "BB",
            color: "blue",
            tooltip: "Bitbucket viewer",
        },
    },
    FamilySibling {
        id: "github",
        binary: "mnml-forge-github",
        category: Category::Forge,
        repo_url: "https://github.com/chris-mclennan/mnml-forge-github",
        pinned_version: "v0.1.0",
        one_liner: "GitHub PR + Actions viewer",
        icon: IconTemplate {
            glyph: "\u{F02A4}",
            fallback: "GH",
            color: "green",
            tooltip: "GitHub viewer",
        },
    },
    FamilySibling {
        id: "gitlab",
        binary: "mnml-forge-gitlab",
        category: Category::Forge,
        repo_url: "https://github.com/chris-mclennan/mnml-forge-gitlab",
        pinned_version: "v0.1.0",
        one_liner: "GitLab MR + pipeline viewer",
        icon: IconTemplate {
            glyph: "\u{F0BA3}",
            fallback: "GL",
            color: "orange",
            tooltip: "GitLab viewer",
        },
    },
    FamilySibling {
        id: "azdevops",
        binary: "mnml-forge-azdevops",
        category: Category::Forge,
        repo_url: "https://github.com/chris-mclennan/mnml-forge-azdevops",
        pinned_version: "v0.1.0",
        one_liner: "Azure DevOps PR + pipeline viewer",
        icon: IconTemplate {
            glyph: "\u{F0805}",
            fallback: "AZ",
            color: "cyan",
            tooltip: "Azure DevOps viewer",
        },
    },
    // ── Trackers ──────────────────────────────────────────────
    FamilySibling {
        id: "jira",
        binary: "mnml-tracker-jira",
        category: Category::Tracker,
        repo_url: "https://github.com/chris-mclennan/mnml-tracker-jira",
        pinned_version: "v0.2.0",
        one_liner: "Jira ticket browser (JQL + auto-resolved tabs)",
        icon: IconTemplate {
            glyph: "\u{F0824}",
            fallback: "Ji",
            color: "blue",
            tooltip: "Jira tickets",
        },
    },
    FamilySibling {
        id: "linear",
        binary: "mnml-tracker-linear",
        category: Category::Tracker,
        repo_url: "https://github.com/chris-mclennan/mnml-tracker-linear",
        pinned_version: "v0.1.0",
        one_liner: "Linear issue browser",
        icon: IconTemplate {
            glyph: "\u{F12F2}",
            fallback: "Ln",
            color: "purple",
            tooltip: "Linear issues",
        },
    },
    // ── Test runners ──────────────────────────────────────────
    FamilySibling {
        id: "playwright",
        binary: "mnml-test-playwright",
        category: Category::Test,
        repo_url: "https://github.com/chris-mclennan/mnml-test-playwright",
        pinned_version: "v0.1.0",
        one_liner: "Playwright trace viewer",
        icon: IconTemplate {
            glyph: "\u{F0E66}",
            fallback: "Pw",
            color: "green",
            tooltip: "Playwright traces",
        },
    },
    FamilySibling {
        id: "cypress",
        binary: "mnml-test-cypress",
        category: Category::Test,
        repo_url: "https://github.com/chris-mclennan/mnml-test-cypress",
        pinned_version: "v0.1.0",
        one_liner: "Cypress mochawesome result viewer",
        icon: IconTemplate {
            glyph: "\u{F0E66}",
            fallback: "Cy",
            color: "green",
            tooltip: "Cypress results",
        },
    },
];

pub fn catalog() -> &'static [FamilySibling] {
    CATALOG
}

/// Find a catalog entry by binary name.
pub fn find_by_binary(name: &str) -> Option<&'static FamilySibling> {
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
pub struct DiscoveredSibling {
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
    pub tooltip: String,
}

impl DiscoveredSibling {
    /// Stringly `:host.launch <binary>` invocation. Mirrors
    /// `FamilySibling::launch_command()`.
    pub fn launch_command(&self) -> String {
        format!(":host.launch {}", self.binary)
    }
}

/// Reference to *some* sibling — either a hardcoded catalog entry
/// or an auto-discovered one. Lets the discovery overlay render
/// both kinds with one code path.
#[derive(Debug, Clone)]
pub enum SiblingRef {
    Catalog(&'static FamilySibling),
    Discovered(DiscoveredSibling),
}

impl SiblingRef {
    pub fn id(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.id,
            SiblingRef::Discovered(s) => &s.id,
        }
    }
    pub fn binary(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.binary,
            SiblingRef::Discovered(s) => &s.binary,
        }
    }
    pub fn category(&self) -> Category {
        match self {
            SiblingRef::Catalog(s) => s.category,
            SiblingRef::Discovered(s) => s.category,
        }
    }
    pub fn one_liner(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.one_liner,
            SiblingRef::Discovered(s) => &s.one_liner,
        }
    }
    pub fn icon_glyph(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.icon.glyph,
            SiblingRef::Discovered(s) => &s.icon.glyph,
        }
    }
    pub fn icon_fallback(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.icon.fallback,
            SiblingRef::Discovered(s) => &s.icon.fallback,
        }
    }
    pub fn icon_color(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.icon.color,
            SiblingRef::Discovered(s) => &s.icon.color,
        }
    }
    pub fn icon_tooltip(&self) -> &str {
        match self {
            SiblingRef::Catalog(s) => s.icon.tooltip,
            SiblingRef::Discovered(s) => &s.icon.tooltip,
        }
    }
    pub fn launch_command(&self) -> String {
        match self {
            SiblingRef::Catalog(s) => s.launch_command(),
            SiblingRef::Discovered(s) => s.launch_command(),
        }
    }
    /// Install command — `Some` for catalog entries, `None` for
    /// discovered ones (we don't know the repo URL). Used to decide
    /// whether the `i`/`y` actions show an actionable command.
    pub fn install_command(&self) -> Option<String> {
        match self {
            SiblingRef::Catalog(s) => Some(s.install_command()),
            SiblingRef::Discovered(_) => None,
        }
    }
    pub fn is_discovered(&self) -> bool {
        matches!(self, SiblingRef::Discovered(_))
    }
}

/// Walk `$PATH` + well-known dirs and synthesize a `DiscoveredSibling`
/// for every `mnml-<class>-<name>` binary that ISN'T already in the
/// hardcoded `CATALOG`. Categories are derived from the class prefix
/// (`aws` → `Aws`, `db` → `Db`, etc.); unknown classes land in
/// `Other`. Icon templates use category-derived defaults so the
/// rows render with the right family-feel.
pub fn discover_uncataloged() -> Vec<DiscoveredSibling> {
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
        out.push(DiscoveredSibling {
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
/// already passed [`integration_detect::looks_like_mnml_sibling`].
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
        Category::Other => "cyan",
    }
    .to_string();
    let tooltip = format!("mnml-{}-{}", category_class(category), name);
    OwnedIconTemplate {
        glyph,
        fallback,
        color,
        tooltip,
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
        Category::Other => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_is_nonempty_and_distinct() {
        assert!(!CATALOG.is_empty());
        let mut binaries: Vec<&str> = CATALOG.iter().map(|s| s.binary).collect();
        binaries.sort();
        let len_before = binaries.len();
        binaries.dedup();
        assert_eq!(binaries.len(), len_before, "duplicate binary in catalog");
    }

    #[test]
    fn install_command_uses_tagged_install() {
        let s = find_by_binary("mnml-aws-lambda").expect("lambda in catalog");
        let cmd = s.install_command();
        assert!(cmd.contains("--git"));
        assert!(cmd.contains("--tag"));
        assert!(cmd.contains("mnml-aws-lambda"));
        assert!(cmd.starts_with("cargo install"));
    }

    #[test]
    fn launch_command_uses_host_launch() {
        let s = find_by_binary("mnml-fs-s3").expect("s3 in catalog");
        assert_eq!(s.launch_command(), ":host.launch mnml-fs-s3");
    }

    #[test]
    fn every_repo_url_is_github() {
        for s in CATALOG {
            assert!(
                s.repo_url.starts_with("https://github.com/chris-mclennan/"),
                "{} repo_url not on chris-mclennan org: {}",
                s.binary,
                s.repo_url
            );
        }
    }

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

    #[test]
    fn sibling_ref_catalog_passthrough_methods() {
        let s = CATALOG.first().unwrap();
        let r = SiblingRef::Catalog(s);
        assert_eq!(r.id(), s.id);
        assert_eq!(r.binary(), s.binary);
        assert_eq!(r.category(), s.category);
        assert!(r.install_command().is_some());
        assert!(!r.is_discovered());
    }

    #[test]
    fn sibling_ref_discovered_has_no_install_command() {
        let d = DiscoveredSibling {
            id: "x".into(),
            binary: "mnml-other-x".into(),
            category: Category::Other,
            one_liner: "auto-discovered other sibling".into(),
            icon: OwnedIconTemplate {
                glyph: "g".into(),
                fallback: "Ot".into(),
                color: "cyan".into(),
                tooltip: "mnml-other-x".into(),
            },
        };
        let r = SiblingRef::Discovered(d);
        assert!(r.is_discovered());
        assert!(r.install_command().is_none());
        assert_eq!(r.launch_command(), ":host.launch mnml-other-x");
    }
}
