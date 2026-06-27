//! One-stop install helper for mnml family siblings. Used by:
//!   - the `mounts.install` palette command (#1)
//!   - the Integrations rail "Install" affordance (#2)
//!   - the `install_mnml_sibling` AI tool (#3)
//!   - the "X not installed — install? y/n" prompt that fires when
//!     a sibling-handoff (CloudWatch / S3) hits a missing binary
//!
//! All four code paths funnel through `install_sibling` so the
//! spawn shape, env var setup, and progress UX stay identical.

use crate::family_catalog::{FamilySibling, MountStub, mount_stub_for};

/// What to do once a sibling install finishes successfully.
/// Captured at prompt time so users don't have to re-trigger their
/// original action after waiting for `cargo install` to complete.
/// Replayed by `App::drain_install_post_actions` on each tick.
#[derive(Debug, Clone)]
pub enum PostInstallAction {
    /// Open a CloudWatch Logs Pty for `log_group` (optionally
    /// filtered by `filter`). Triggered when the user invoked
    /// "Tail logs" on a cloud-agent row but the cloudwatch-logs
    /// sibling wasn't installed.
    CloudWatchLogs {
        log_group: String,
        filter: String,
        label: String,
    },
    /// Open the S3 browser Pty pointed at `bucket`+`prefix`.
    /// Triggered when the user invoked "Browse S3 artifacts" or
    /// `:s3.open` but the s3 sibling wasn't installed.
    S3Browse {
        bucket: String,
        prefix: String,
        label: String,
    },
}

/// What kind of install just happened. Surfaced to callers so they
/// can chain "click again to use" affordances correctly.
#[derive(Debug, Clone, Copy)]
pub enum InstallKind {
    /// Pty-only sibling — just runs.
    Pty,
    /// Mount sibling — also wrote an activity-bar manifest.
    Mount,
}

/// Look up a family entry by id. Wrapper so callers don't need to
/// import the catalog directly.
pub fn lookup(id: &str) -> Option<&'static FamilySibling> {
    crate::family_catalog::CATALOG.iter().find(|s| s.id == id)
}

/// Build the argv for `cargo install` based on the catalog entry's
/// `repo_url` + `pinned_version`. When the pin is `"main"` we drop
/// the `--tag` flag so cargo follows HEAD (used for in-development
/// siblings that haven't tagged a release yet).
pub fn cargo_install_argv(sibling: &FamilySibling) -> Vec<String> {
    let mut argv = vec![
        "cargo".to_string(),
        "install".to_string(),
        "--git".to_string(),
        sibling.repo_url.to_string(),
    ];
    if sibling.pinned_version != "main" && sibling.pinned_version != "built-in" {
        argv.push("--tag".to_string());
        argv.push(sibling.pinned_version.to_string());
    }
    argv.push(sibling.binary.to_string());
    argv
}

/// mnml's compile-time target triple (e.g. `aarch64-apple-darwin`).
/// Set in build.rs from cargo's `TARGET` env var. Used to pick the
/// matching prebuilt asset from each sibling repo's `latest-build`
/// release.
pub const TARGET: &str = env!("MNML_TARGET");

/// Build a `sh -c` argv that tries to download + extract the
/// sibling's prebuilt binary from its repo's rolling `latest-build`
/// GitHub Release. If the asset is missing for the current target
/// (Windows currently, or a sibling that hasn't been set up yet),
/// falls back to `cargo install --git`. The Pty pane the user sees
/// is either a fast `curl | tar` (~1-2s) or the familiar cargo
/// compile (~30-60s) — same UX shape.
///
/// On Windows mnml falls through to cargo install today; the
/// prebuilt zip extraction story for PowerShell isn't worth the
/// shell-quoting pain when the macOS/Linux paths are the priority.
pub fn install_pipeline_argv(sibling: &FamilySibling) -> Vec<String> {
    if TARGET.contains("windows") {
        return cargo_install_argv(sibling);
    }
    let cargo_install = cargo_install_argv(sibling).join(" ");
    let url = format!(
        "{}/releases/download/latest-build/{}-{}.tar.gz",
        sibling.repo_url, sibling.binary, TARGET
    );
    let script = format!(
        r#"set -e
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
URL='{url}'
echo "→ trying prebuilt: $URL"
if curl -sL --fail -o "$TMP/sib.tar.gz" "$URL"; then
  tar -xzf "$TMP/sib.tar.gz" -C "$TMP"
  mkdir -p ~/.cargo/bin
  cp "$TMP/{binary}-{target}/{binary}" ~/.cargo/bin/{binary}
  chmod +x ~/.cargo/bin/{binary}
  echo "✓ installed {binary} from prebuilt"
else
  echo "→ no prebuilt for {target}, falling back to source compile"
  {cargo_install}
fi
"#,
        url = url,
        binary = sibling.binary,
        target = TARGET,
        cargo_install = cargo_install,
    );
    vec!["sh".to_string(), "-c".to_string(), script]
}

/// Write the Mount manifest to `~/.config/mnml/mounts/<id>.toml`.
/// Caller is responsible for refreshing `App::mount_manifests`.
/// Returns the path written so the caller can surface it in a toast.
pub fn write_mount_manifest(
    family_id: &str,
    stub: &MountStub,
    binary: &str,
) -> std::io::Result<std::path::PathBuf> {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "$HOME not set"))?;
    let dir = home.join(".config").join("mnml").join("mounts");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{family_id}.toml"));
    let body = format!(
        r#"id = "{family_id}"
name = "{name}"
binary = "{binary}"
icon = "{icon}"
color = "{color}"
"#,
        name = stub.name,
        icon = stub.icon,
        color = stub.color,
    );
    std::fs::write(&path, body)?;
    Ok(path)
}

/// Determine the install kind for a catalog entry. Used by callers
/// to know whether they need to bother with the manifest write.
pub fn install_kind(family_id: &str) -> InstallKind {
    if mount_stub_for(family_id).is_some() {
        InstallKind::Mount
    } else {
        InstallKind::Pty
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cargo_install_uses_tag_for_pinned_version() {
        // Synthetic — every catalog pin is currently `main`
        // (2026-06-26 audit; see TODO.md). This test pins the
        // tagged-install path independently so the --tag emission
        // stays under coverage regardless of catalog state.
        let sib = crate::family_catalog::FamilySibling {
            id: "synth",
            binary: "mnml-synth",
            category: crate::family_catalog::Category::Other,
            repo_url: "https://github.com/chris-mclennan/mnml-synth",
            pinned_version: "v9.9.9",
            one_liner: "synthetic test entry",
            icon: crate::family_catalog::IconTemplate {
                glyph: "X",
                fallback: "Sy",
                color: "white",
                tooltip: "synth",
            },
        };
        let argv = cargo_install_argv(&sib);
        assert!(argv.iter().any(|a| a == "--tag"));
        assert!(argv.iter().any(|a| a == sib.pinned_version));
    }

    #[test]
    fn cargo_install_skips_tag_for_main() {
        let sib = crate::family_catalog::CATALOG
            .iter()
            .find(|s| s.id == "tattle_tests")
            .expect("tattle_tests in catalog");
        let argv = cargo_install_argv(sib);
        assert!(!argv.iter().any(|a| a == "--tag"));
    }

    #[test]
    fn install_kind_mount_for_tattle_tests() {
        assert!(matches!(install_kind("tattle_tests"), InstallKind::Mount));
    }

    #[test]
    fn install_kind_pty_for_cloudwatch() {
        assert!(matches!(install_kind("cloudwatch_logs"), InstallKind::Pty));
    }
}
