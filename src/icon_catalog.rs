//! Hand-picked Nerd Font glyph catalog — the seed pool for
//! the `integrations.icon_picker` overlay (#607).
//!
//! Not exhaustive (Nerd Fonts ships ~10k glyphs); this is just the
//! common-case bench so users can find an icon for their integration
//! integration without leaving mnml. Each entry: `(codepoint_hex,
//! name, category)`. The picker shows them all, filterable by name
//! / category — accept copies the literal char + `\u{XXXX}`
//! escape to the clipboard.
//!
//! To add more: drop a line here. The picker re-reads on every
//! open; no codegen, no bake step.
//!
//! ## Custom mnml-patched glyph codepoint layout
//!
//! mnml's own branded logos (AWS Amplify, Claude Code, etc.) live in
//! the Supplementary Private Use Area past U+F1AF0 — the end of
//! Material Design Icons — because that's the first range every
//! Nerd Font leaves untouched. Reserved blocks:
//!
//! - `U+F1B00 – U+F1BFF` — AWS Architecture (256 slots)
//! - `U+F1C00 – U+F1CFF` — Integration-shipped icons (SDK feature 2026-07-31)
//!   Auto-assigned by mnml at startup for any SVG a integration drops into
//!   `~/.config/mnml/glyphs/<id>.svg` via `mnml-bridge`'s
//!   `install_integration` when `ChipSpec::glyph_svg` is set. Integrations
//!   don't hardcode codepoints from this block unless they explicitly
//!   set `ChipSpec::glyph_codepoint` (usually just for backwards-compat
//!   with a codepoint mnml core used to bake). See
//!   `src/app/integration_glyphs.rs`.
//! - `U+F1D00 – U+F1DFF` — Azure (reserved, unused)
//! - `U+F1E00 – U+F1EFF` — AI tools: Claude Code, Codex, Copilot, Cursor, Aider, etc.
//! - `U+F1F00 – U+F1FFF` — SaaS integrations: Datadog, PagerDuty, Notion, Linear, …
//! - `U+F2000 – U+F20FF` — Dev tools: Docker, npm, PostgreSQL, Redis, Kafka, …
//!
//! Never allocate custom glyphs at U+F300+ or below U+F1AF0 — those
//! ranges clash with Nerd Fonts' Font Logos and Material Design Icons
//! blocks respectively, and terminals that ship a bundled Nerd Font
//! (Ghostty) will shadow mnml's patch with the stock glyph.

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
    IconEntry { codepoint: "F04B1", name: "slack", category: "msg" },
    IconEntry { codepoint: "F0FA1", name: "microsoft-teams", category: "msg" },
    IconEntry { codepoint: "F03BC", name: "gmail", category: "msg" },
    IconEntry { codepoint: "F01EF", name: "email-check", category: "msg" },
    IconEntry { codepoint: "F0EB1", name: "email-newsletter", category: "msg" },
    IconEntry { codepoint: "F01F0", name: "email-search", category: "msg" },

    // ── ai / coding ──
    // F1E00/F1E01 — the mnml-owned pair baked into MnmlSymbols.ttf
    // from assets/glyphs/ai/ every startup; center_frac tunable via
    // the glyph builder. The old JBM-NF-patched F8B0/F8B1 pair was
    // retired 2026-08-25 (stock Nerd Fonts have nothing there, so
    // any font reinstall broke them; old configs migrate on load).
    IconEntry { codepoint: "F1E00", name: "ai-claude-spark", category: "ai" },
    IconEntry { codepoint: "F1E01", name: "ai-codex", category: "ai" },

    // ── aws (mnml-patched from official AWS Architecture Icons ──
    // Two variants per service: inverted (transparent bg, colored
    // lines — the default) and color (colored bg, white lines).
    // Layout: U+F1B00-F1B0B = inverted, U+F1B10-F1B1B = color.
    //
    // 2026-07-04 — moved from U+F300+ to U+F1B00+ because U+F300-F381
    // is Nerd Fonts' Font Logos block (Alpine, Debian, Ubuntu, etc)
    // and our custom AWS glyphs collided — Ghostty was rendering the
    // Alpine mountain logo for our "amplify" codepoint. U+F1AF1+ is
    // truly free (past the end of Material Design Icons at U+F1AF0)
    // so no Nerd Font ever claims these codepoints.
    //
    // 2026-08-01 — Stage 2 of the integration-owned icon SDK moved
    // per-service AWS SVGs into their own `mnml-aws-*` integration repos
    // (each integration pins its old codepoint via `ChipSpec::glyph_codepoint`
    // so upgrading users' configs keep rendering). Only amplify + dynamodb
    // entries remain in this picker: only dynamodb (deferred until
    // transition (see `config.rs`), dynamodb is deferred until it moves
    // to `mnml-db`. Migrated codepoints (F1B01-F1B06, F1B08-F1B0B, and
    // their F1B1X color variants) are still valid — mnml discovers each
    // integration's SVG on `integrations.refresh` and bakes it at the pinned
    // codepoint on `integrations.bake_integration_glyphs`.
    IconEntry { codepoint: "F1B07", name: "aws-dynamodb (inverted)", category: "aws" },
    IconEntry { codepoint: "F1B17", name: "aws-dynamodb (color)", category: "aws" },
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

    // ── languages / runtimes ──
    IconEntry { codepoint: "E68B",  name: "rust", category: "lang" },
    IconEntry { codepoint: "E724",  name: "go-gopher", category: "lang" },
    IconEntry { codepoint: "E73C",  name: "python", category: "lang" },
    IconEntry { codepoint: "E60E",  name: "typescript", category: "lang" },
    IconEntry { codepoint: "E60C",  name: "javascript", category: "lang" },
    IconEntry { codepoint: "E718",  name: "nodejs", category: "lang" },
    IconEntry { codepoint: "E7A8",  name: "ruby", category: "lang" },
    IconEntry { codepoint: "E7C5",  name: "swift", category: "lang" },
    IconEntry { codepoint: "E70C",  name: "kotlin", category: "lang" },
    IconEntry { codepoint: "E738",  name: "java", category: "lang" },
    IconEntry { codepoint: "E712",  name: "elixir", category: "lang" },
    IconEntry { codepoint: "F0B1B", name: "deno", category: "lang" },
    IconEntry { codepoint: "F03A2", name: "lua", category: "lang" },

    // ── package managers ──
    IconEntry { codepoint: "E71E",  name: "npm", category: "pkg" },
    IconEntry { codepoint: "F011B", name: "yarn", category: "pkg" },
    IconEntry { codepoint: "F02E0", name: "pnpm", category: "pkg" },
    IconEntry { codepoint: "F11B0", name: "bun", category: "pkg" },
    IconEntry { codepoint: "F03A1", name: "pip / python pkg", category: "pkg" },
    IconEntry { codepoint: "F092B", name: "cargo / crates", category: "pkg" },

    // ── general purpose ──
    IconEntry { codepoint: "F02A5", name: "lightning-bolt", category: "misc" },
    IconEntry { codepoint: "F11AB", name: "rocket", category: "misc" },
    IconEntry { codepoint: "F0668", name: "test-tube-alt", category: "misc" },
    IconEntry { codepoint: "F0493", name: "hammer", category: "misc" },
    IconEntry { codepoint: "F004D", name: "shield", category: "misc" },
    IconEntry { codepoint: "F0D1B", name: "key", category: "misc" },
    IconEntry { codepoint: "F069D", name: "lock", category: "misc" },
];
