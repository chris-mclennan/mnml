//! Mason-style tools registry. A curated list of every external binary
//! mnml looks for (language servers, formatters, linters) along with a
//! suggested install command. The picker (`tools.installer`) shows the
//! list with ✓/✗ "is on PATH" status; accepting a row copies the
//! install command to the clipboard so the user can run it themselves.
//!
//! This is intentionally a *catalog*, not a full package manager.
//! Nvim's Mason maintains ~250 packages with per-platform install
//! recipes; mnml's MVP captures the high-value "what tools do I still
//! need to install?" gesture without the maintenance burden.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolKind {
    Lsp,
    Formatter,
    Linter,
}

impl ToolKind {
    pub fn label(self) -> &'static str {
        match self {
            ToolKind::Lsp => "lsp",
            ToolKind::Formatter => "fmt",
            ToolKind::Linter => "lint",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ToolEntry {
    /// Short display name (e.g. "prettier", "rust-analyzer").
    pub name: &'static str,
    /// What category of tool this is.
    pub kind: ToolKind,
    /// The binary the user needs on `$PATH`. Used by the "installed?" check.
    pub bin: &'static str,
    /// One-line description shown as the picker's detail.
    pub description: &'static str,
    /// Suggested install command (the user runs this themselves —
    /// mnml doesn't auto-install). The picker copies this to clipboard
    /// on accept.
    pub install: &'static str,
}

/// Curated list. Add entries here as mnml grows its language coverage.
pub const KNOWN_TOOLS: &[ToolEntry] = &[
    // ── language servers (mirror DEFAULT_LSPS in src/lsp/mod.rs) ──
    ToolEntry {
        name: "rust-analyzer",
        kind: ToolKind::Lsp,
        bin: "rust-analyzer",
        description: "Rust language server",
        install: "rustup component add rust-analyzer",
    },
    ToolEntry {
        name: "typescript-language-server",
        kind: ToolKind::Lsp,
        bin: "typescript-language-server",
        description: "TypeScript / JavaScript language server",
        install: "npm i -g typescript typescript-language-server",
    },
    ToolEntry {
        name: "pyright",
        kind: ToolKind::Lsp,
        bin: "pyright-langserver",
        description: "Python language server (pyright)",
        install: "npm i -g pyright",
    },
    ToolEntry {
        name: "gopls",
        kind: ToolKind::Lsp,
        bin: "gopls",
        description: "Go language server",
        install: "go install golang.org/x/tools/gopls@latest",
    },
    ToolEntry {
        name: "clangd",
        kind: ToolKind::Lsp,
        bin: "clangd",
        description: "C / C++ language server",
        install: "brew install llvm  (or: apt install clangd)",
    },
    ToolEntry {
        name: "lua-language-server",
        kind: ToolKind::Lsp,
        bin: "lua-language-server",
        description: "Lua language server",
        install: "brew install lua-language-server  (or: apt install lua-language-server / cargo install lua-language-server)",
    },
    ToolEntry {
        name: "yaml-language-server",
        kind: ToolKind::Lsp,
        bin: "yaml-language-server",
        description: "YAML language server",
        install: "npm i -g yaml-language-server",
    },
    ToolEntry {
        name: "bash-language-server",
        kind: ToolKind::Lsp,
        bin: "bash-language-server",
        description: "Bash / sh language server",
        install: "npm i -g bash-language-server",
    },
    ToolEntry {
        name: "vscode-css-language-server",
        kind: ToolKind::Lsp,
        bin: "vscode-css-language-server",
        description: "CSS / SCSS language server",
        install: "npm i -g vscode-langservers-extracted",
    },
    ToolEntry {
        name: "vscode-html-language-server",
        kind: ToolKind::Lsp,
        bin: "vscode-html-language-server",
        description: "HTML language server",
        install: "npm i -g vscode-langservers-extracted",
    },
    ToolEntry {
        name: "vscode-json-language-server",
        kind: ToolKind::Lsp,
        bin: "vscode-json-language-server",
        description: "JSON language server",
        install: "npm i -g vscode-langservers-extracted",
    },
    ToolEntry {
        name: "tailwindcss-language-server",
        kind: ToolKind::Lsp,
        bin: "tailwindcss-language-server",
        description: "Tailwind CSS language server",
        install: "npm i -g @tailwindcss/language-server",
    },
    ToolEntry {
        name: "ruby-lsp",
        kind: ToolKind::Lsp,
        bin: "ruby-lsp",
        description: "Ruby language server",
        install: "gem install ruby-lsp",
    },
    // ── formatters (mirror DEFAULT_FORMATTERS in src/formatter.rs) ──
    ToolEntry {
        name: "prettier",
        kind: ToolKind::Formatter,
        bin: "prettier",
        description: "JS / TS / CSS / HTML / MD / JSON / YAML formatter",
        install: "npm i -g prettier",
    },
    ToolEntry {
        name: "rustfmt",
        kind: ToolKind::Formatter,
        bin: "rustfmt",
        description: "Rust formatter",
        install: "rustup component add rustfmt",
    },
    ToolEntry {
        name: "gofmt",
        kind: ToolKind::Formatter,
        bin: "gofmt",
        description: "Go formatter (ships with the Go toolchain)",
        install: "Install Go: https://go.dev/dl/",
    },
    ToolEntry {
        name: "ruff",
        kind: ToolKind::Formatter,
        bin: "ruff",
        description: "Python formatter + linter",
        install: "pip install ruff  (or: brew install ruff)",
    },
    ToolEntry {
        name: "black",
        kind: ToolKind::Formatter,
        bin: "black",
        description: "Python formatter",
        install: "pip install black",
    },
    ToolEntry {
        name: "shfmt",
        kind: ToolKind::Formatter,
        bin: "shfmt",
        description: "Shell script formatter",
        install: "brew install shfmt  (or: go install mvdan.cc/sh/v3/cmd/shfmt@latest)",
    },
    ToolEntry {
        name: "stylua",
        kind: ToolKind::Formatter,
        bin: "stylua",
        description: "Lua formatter",
        install: "brew install stylua  (or: cargo install stylua)",
    },
    ToolEntry {
        name: "nixfmt",
        kind: ToolKind::Formatter,
        bin: "nixfmt",
        description: "Nix formatter",
        install: "nix profile install nixpkgs#nixfmt",
    },
    ToolEntry {
        name: "biome",
        kind: ToolKind::Formatter,
        bin: "biome",
        description: "JS / TS formatter + linter (prettier+eslint alternative)",
        install: "npm i -g @biomejs/biome",
    },
    // ── linters (mirror DEFAULT_LINTERS in src/linter.rs) ──
    ToolEntry {
        name: "eslint",
        kind: ToolKind::Linter,
        bin: "eslint",
        description: "JS / TS linter",
        install: "npm i -g eslint",
    },
    ToolEntry {
        name: "shellcheck",
        kind: ToolKind::Linter,
        bin: "shellcheck",
        description: "Shell script linter",
        install: "brew install shellcheck  (or: apt install shellcheck)",
    },
];

/// External terminal-app catalog — htop, iftop, btop, etc. These
/// are visible-binary tools the user runs interactively; the
/// integration_icon's `:tools.<id>` command fires
/// `App::run_external_tool(id)`, which either opens the binary in
/// a Pty pane or toasts a `brew install` hint.
///
/// Kept separate from `KNOWN_TOOLS` (LSP/fmt/lint installed-state
/// indicators) — same shape, but a different runtime gesture.
pub struct ExternalTool {
    pub id: &'static str,
    pub binary: &'static str,
    /// Homebrew formula name — usually the same as `binary`.
    pub brew_pkg: &'static str,
    /// apt package name on Debian / Ubuntu. Same as `brew_pkg` unless
    /// the package is named differently in the apt repo.
    pub apt_pkg: &'static str,
    pub label: &'static str,
}

/// Platform-appropriate install hint for a missing binary. Branches
/// on the host OS so a Linux user doesn't see `brew install` and a
/// Windows user gets a winget / scoop hint. Used by both the
/// external-tool launcher and the LSP missing-binary path.
pub fn install_hint(brew_pkg: &str, apt_pkg: &str) -> String {
    // Returns a clean shell-executable command — no parentheticals
    // or alternatives — so callers can both display AND run it.
    match std::env::consts::OS {
        "macos" => format!("brew install {brew_pkg}"),
        "linux" => format!("sudo apt install -y {apt_pkg}"),
        _ => format!("install {brew_pkg} via your package manager"),
    }
}

/// Whether `install_hint` returns a command that's safe to actually
/// SPAWN (vs just toast as a hint). True on macOS + Linux (brew /
/// apt are reasonable assumptions); false elsewhere where there's
/// no single canonical package manager.
pub fn install_is_spawnable() -> bool {
    matches!(std::env::consts::OS, "macos" | "linux")
}

pub const EXTERNAL_TOOLS: &[ExternalTool] = &[
    ExternalTool {
        id: "htop",
        binary: "htop",
        brew_pkg: "htop",
        apt_pkg: "htop",
        label: "htop — interactive process viewer",
    },
    ExternalTool {
        id: "iftop",
        binary: "iftop",
        brew_pkg: "iftop",
        apt_pkg: "iftop",
        label: "iftop — interactive bandwidth monitor",
    },
    ExternalTool {
        id: "btop",
        binary: "btop",
        brew_pkg: "btop",
        apt_pkg: "btop",
        label: "btop — resource monitor (cpu / mem / disk / net)",
    },
];

/// Check whether `bin` is on `$PATH`. Walks PATH directories looking
/// for a file matching `bin` (case-sensitive on Unix; honors `.exe` on
/// Windows). Returns `true` on first hit.
pub fn is_on_path(bin: &str) -> bool {
    let path = match std::env::var_os("PATH") {
        Some(p) => p,
        None => return false,
    };
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(bin);
        if candidate.is_file() {
            return true;
        }
        #[cfg(windows)]
        {
            for ext in &["exe", "cmd", "bat"] {
                let mut p = candidate.clone();
                p.set_extension(ext);
                if p.is_file() {
                    return true;
                }
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_tools_has_no_empty_names() {
        assert!(!KNOWN_TOOLS.is_empty());
        for t in KNOWN_TOOLS {
            assert!(!t.name.is_empty(), "empty name");
            assert!(!t.bin.is_empty(), "empty bin for {}", t.name);
            assert!(!t.install.is_empty(), "empty install for {}", t.name);
        }
    }

    #[test]
    fn is_on_path_finds_sh() {
        // `sh` should exist on every POSIX system; on Windows just skip.
        if cfg!(unix) {
            assert!(is_on_path("sh"));
        }
    }

    #[test]
    fn is_on_path_misses_garbage() {
        assert!(!is_on_path("this-binary-does-not-exist-zzz"));
    }
}
