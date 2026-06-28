//! Hand-picked Nerd Font glyph catalog — the seed pool for
//! the `integrations.icon_picker` overlay (#607).
//!
//! Not exhaustive (Nerd Fonts ships ~10k glyphs); this is just the
//! common-case bench so users can find an icon for their sibling
//! integration without leaving mnml. Each entry: `(codepoint_hex,
//! name, category)`. The picker shows them all, filterable by name
//! / category — accept copies the literal char + `\u{XXXX}`
//! escape to the clipboard.
//!
//! To add more: drop a line here. The picker re-reads on every
//! open; no codegen, no bake step.

/// One catalog entry.
pub struct IconEntry {
    /// Hex codepoint (no `\u{}` — just the digits, e.g. `"F0E2D"`).
    pub codepoint: &'static str,
    /// Human name — what the user searches by.
    pub name: &'static str,
    /// Coarse grouping; surfaced as a chip in the picker row.
    pub category: &'static str,
}

/// Compile-time catalog. Categorized loosely by usage domain so
/// the user can scan a category prefix (`fs/`, `git/`, `ai/`,
/// etc.) and find the family of icons fast.
#[rustfmt::skip]
pub const ICON_CATALOG: &[IconEntry] = &[
    // ── filesystem / files ──
    IconEntry { codepoint: "F0226", name: "file", category: "fs" },
    IconEntry { codepoint: "F0770", name: "folder", category: "fs" },
    IconEntry { codepoint: "F0207", name: "file-document", category: "fs" },
    IconEntry { codepoint: "F015B", name: "file-tree", category: "fs" },
    IconEntry { codepoint: "F0BE7", name: "folder-open", category: "fs" },
    IconEntry { codepoint: "F02DC", name: "harddisk", category: "fs" },
    IconEntry { codepoint: "F0EBC", name: "aws-s3", category: "fs" },
    IconEntry { codepoint: "F046A", name: "cloud-upload", category: "fs" },

    // ── git / forge ──
    IconEntry { codepoint: "F02A4", name: "github", category: "git" },
    IconEntry { codepoint: "F03A4", name: "git", category: "git" },
    IconEntry { codepoint: "E703",  name: "bitbucket", category: "git" },
    IconEntry { codepoint: "F296",  name: "gitlab", category: "git" },
    IconEntry { codepoint: "F0418", name: "source-branch", category: "git" },
    IconEntry { codepoint: "F068C", name: "source-merge", category: "git" },
    IconEntry { codepoint: "F062D", name: "source-pull", category: "git" },

    // ── shell / terminal ──
    IconEntry { codepoint: "F018D", name: "terminal", category: "shell" },
    IconEntry { codepoint: "F0676", name: "console", category: "shell" },
    IconEntry { codepoint: "F040A", name: "shell", category: "shell" },
    IconEntry { codepoint: "F085A", name: "monitor-dashboard", category: "shell" },
    IconEntry { codepoint: "F085F", name: "monitor-eye (btop-ish)", category: "shell" },
    IconEntry { codepoint: "F048D", name: "network", category: "shell" },

    // ── cloud / aws / infra ──
    IconEntry { codepoint: "F0492", name: "hammer-wrench (codebuild)", category: "cloud" },
    IconEntry { codepoint: "F0E5C", name: "text-box-search (cloudwatch)", category: "cloud" },
    IconEntry { codepoint: "F0E7B", name: "cloud-outline", category: "cloud" },
    IconEntry { codepoint: "EBE8",  name: "azure", category: "cloud" },
    IconEntry { codepoint: "F0868", name: "docker", category: "cloud" },
    IconEntry { codepoint: "F10FE", name: "kubernetes", category: "cloud" },

    // ── tickets / pm ──
    IconEntry { codepoint: "F0411", name: "jira", category: "pm" },
    IconEntry { codepoint: "F015A", name: "linear", category: "pm" },
    IconEntry { codepoint: "F1A4F", name: "todo", category: "pm" },

    // ── messaging ──
    IconEntry { codepoint: "F03EF", name: "slack", category: "msg" },
    IconEntry { codepoint: "F0FA1", name: "microsoft-teams", category: "msg" },
    IconEntry { codepoint: "F03BC", name: "gmail", category: "msg" },
    IconEntry { codepoint: "F01EF", name: "email-check", category: "msg" },
    IconEntry { codepoint: "F0EB1", name: "email-newsletter", category: "msg" },
    IconEntry { codepoint: "F01F0", name: "email-search", category: "msg" },

    // ── ai / coding ──
    IconEntry { codepoint: "F8B0",  name: "claude-spark (mnml-patched)", category: "ai" },
    IconEntry { codepoint: "F8B1",  name: "codex (mnml-patched)", category: "ai" },
    IconEntry { codepoint: "F085B", name: "brain", category: "ai" },
    IconEntry { codepoint: "F02D3", name: "robot", category: "ai" },

    // ── http ──
    IconEntry { codepoint: "F1D8",  name: "paper-plane", category: "http" },
    IconEntry { codepoint: "F1D8B", name: "send", category: "http" },
    IconEntry { codepoint: "F0415", name: "plus (new request)", category: "http" },
    IconEntry { codepoint: "F0EA0", name: "web", category: "http" },

    // ── observability ──
    IconEntry { codepoint: "F1A0F", name: "dog (datadog)", category: "obs" },
    IconEntry { codepoint: "F09C8", name: "chart-line", category: "obs" },
    IconEntry { codepoint: "F0F46", name: "alert-circle", category: "obs" },

    // ── ui chrome ──
    IconEntry { codepoint: "EC02",  name: "layout-sidebar-left-off", category: "ui" },
    IconEntry { codepoint: "EBA6",  name: "layout-sidebar-left", category: "ui" },
    IconEntry { codepoint: "F0415", name: "plus", category: "ui" },
    IconEntry { codepoint: "F0233", name: "google-chrome", category: "ui" },
    IconEntry { codepoint: "F0239", name: "google-chrome (filled)", category: "ui" },
    IconEntry { codepoint: "F1011", name: "music", category: "ui" },
    IconEntry { codepoint: "F0E58", name: "test-tube", category: "ui" },

    // ── general purpose ──
    IconEntry { codepoint: "F02A5", name: "lightning-bolt", category: "misc" },
    IconEntry { codepoint: "F11AB", name: "rocket", category: "misc" },
    IconEntry { codepoint: "F0668", name: "test-tube-alt", category: "misc" },
    IconEntry { codepoint: "F0493", name: "hammer", category: "misc" },
    IconEntry { codepoint: "F004D", name: "shield", category: "misc" },
    IconEntry { codepoint: "F0D1B", name: "key", category: "misc" },
    IconEntry { codepoint: "F069D", name: "lock", category: "misc" },
];
