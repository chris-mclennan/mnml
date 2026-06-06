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
        pinned_version: "v0.1.0",
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
        pinned_version: "v0.1.0",
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
        pinned_version: "v0.1.0",
        one_liner: "EventBridge buses + rules-per-bus browser",
        icon: IconTemplate {
            glyph: "\u{F0CE0}",
            fallback: "EB",
            color: "pink",
            tooltip: "EventBridge buses + rules",
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
}
