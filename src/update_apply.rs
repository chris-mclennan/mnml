//! In-app update installer — the second half of the update story.
//!
//! [`crate::update_check`] does the "is there a newer release?" check
//! at launch and toasts when one's available. This module is the
//! "actually install it" path: download the appropriate artifact for
//! the current platform from GitHub Releases, verify SHA256 against
//! the published `sha256.sum`, run the platform-specific installer
//! (`installer` on macOS, `install` on Linux), and tell the user to
//! relaunch when the new binary's on disk.
//!
//! The installer runs in a Pty pane so the user watches download
//! progress + the `sudo` admin prompt + install output live. After
//! install completes, the currently-running mnml process keeps
//! working (its binary is in memory, not re-read from disk). The
//! user quits with `Ctrl+Q` and relaunches to use the new version.
//! Avoiding the "kill the process that's running the install" circle
//! keeps the implementation simple.
//!
//! Windows v0.1: prints a message pointing at the release URL. Full
//! `.msi` invocation via `msiexec` is a follow-up — UAC handling +
//! restart logic warrant a separate pass.
//!
//! Verified-by-design via the SHA256 check against `sha256.sum`,
//! which is signed implicitly by the GitHub Release upload chain
//! (Anthropic-style verification is overkill for what we ship today;
//! a forged `sha256.sum` from a compromised GitHub Releases would
//! be the breach point, and that's the same exposure normal users
//! have when they manually download).

use crate::app::App;
use crate::pty_pane::BinaryProfile;

/// User-facing entry point — kicks off the in-app update flow.
/// Spawns a Pty pane that runs the platform-specific install script.
pub fn run_install(app: &mut App, version: &str) {
    let script_path = match write_install_script(version) {
        Ok(p) => p,
        Err(e) => {
            app.toast(format!("update: couldn't write install script: {e}"));
            return;
        }
    };
    let cwd = app.workspace.clone();
    let cmdline = invocation_for_script(&script_path);
    let profile = BinaryProfile::task("mnml-update", &cmdline, cwd);
    app.open_pty(profile);
}

/// Compute the shell invocation that runs the install script. macOS +
/// Linux use bash; Windows v0.1 just runs the script directly (which
/// is itself a no-op message).
fn invocation_for_script(path: &std::path::Path) -> String {
    if cfg!(windows) {
        // No bash on bare Windows; the script for that platform is
        // currently a stub message, run via PowerShell.
        format!("powershell -File {}", path.display())
    } else {
        format!("bash {}", path.display())
    }
}

/// Write the install script to a temp file and chmod it (Unix).
/// Returns the path so [`run_install`] can spawn it.
fn write_install_script(version: &str) -> std::io::Result<std::path::PathBuf> {
    let script = build_script(version);
    let path = std::env::temp_dir().join(if cfg!(windows) {
        "mnml-update.ps1"
    } else {
        "mnml-update.sh"
    });
    std::fs::write(&path, script)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms)?;
    }
    Ok(path)
}

/// Per-platform install script. Lazy-resolves the target triple at
/// compile time via `cfg!` macros so each binary ships with exactly
/// one script branch baked in.
fn build_script(version: &str) -> String {
    let repo = crate::update_check::REPO;
    let base = format!("https://github.com/{repo}/releases/download/v{version}");

    if cfg!(target_os = "macos") {
        build_macos_script(&base, version)
    } else if cfg!(target_os = "linux") {
        build_linux_script(&base, version)
    } else {
        build_unsupported_script(&base, version)
    }
}

fn build_macos_script(base: &str, version: &str) -> String {
    // Target triple — compile-time architecture detection.
    let target = if cfg!(target_arch = "aarch64") {
        "aarch64-apple-darwin"
    } else {
        "x86_64-apple-darwin"
    };
    let artifact = format!("mnml-rs-{target}.pkg");
    format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "── mnml in-app update ──"
echo "  version: v{version}"
echo "  target:  {target}"
echo ""

artifact="{artifact}"
base="{base}"
sha_url="${{base}}/sha256.sum"
pkg_url="${{base}}/${{artifact}}"

echo "1/4  downloading sha256.sum…"
sha_file=$(mktemp)
trap 'rm -f "$sha_file"' EXIT
curl -fsSL "$sha_url" -o "$sha_file"
echo "     ok"

echo "2/4  downloading ${{artifact}}…"
pkg_dir=$(mktemp -d)
pkg_file="${{pkg_dir}}/${{artifact}}"
curl -fL "$pkg_url" -o "$pkg_file"
echo "     ok ($(du -h "$pkg_file" | awk '{{print $1}}'))"

echo "3/4  verifying SHA256…"
expected=$(awk -v f="${{artifact}}" '$2 == "*"f {{print $1; exit}}' "$sha_file")
actual=$(shasum -a 256 "$pkg_file" | awk '{{print $1}}')
echo "     expected: ${{expected:0:24}}…"
echo "     actual:   ${{actual:0:24}}…"
if [ "$expected" != "$actual" ]; then
    echo "     ✗ SHA256 mismatch — refusing to install"
    exit 1
fi
echo "     ✓ verified"

echo "4/4  installing — this will prompt for your admin password"
sudo installer -pkg "$pkg_file" -target /
echo "     ✓ install complete"

echo ""
echo "──────────────────────────────────────────────────────"
echo "  Quit mnml (Ctrl+Q) and relaunch to use v{version}."
echo "  Your current session is still running the old binary."
echo "──────────────────────────────────────────────────────"
"#
    )
}

fn build_linux_script(base: &str, version: &str) -> String {
    let target = if cfg!(target_arch = "aarch64") {
        "aarch64-unknown-linux-gnu"
    } else {
        "x86_64-unknown-linux-gnu"
    };
    let artifact = format!("mnml-rs-{target}.tar.xz");
    // Linux flow: download tarball, extract, copy binary to
    // `~/.cargo/bin/mnml` (always on a Rust-user's PATH).
    format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "── mnml in-app update ──"
echo "  version: v{version}"
echo "  target:  {target}"
echo ""

artifact="{artifact}"
base="{base}"
sha_url="${{base}}/sha256.sum"
tarball_url="${{base}}/${{artifact}}"

echo "1/4  downloading sha256.sum…"
sha_file=$(mktemp)
trap 'rm -f "$sha_file"' EXIT
curl -fsSL "$sha_url" -o "$sha_file"
echo "     ok"

echo "2/4  downloading ${{artifact}}…"
tmp_dir=$(mktemp -d)
tarball="${{tmp_dir}}/${{artifact}}"
curl -fL "$tarball_url" -o "$tarball"
echo "     ok ($(du -h "$tarball" | awk '{{print $1}}'))"

echo "3/4  verifying SHA256…"
expected=$(awk -v f="${{artifact}}" '$2 == "*"f {{print $1; exit}}' "$sha_file")
actual=$(sha256sum "$tarball" | awk '{{print $1}}')
echo "     expected: ${{expected:0:24}}…"
echo "     actual:   ${{actual:0:24}}…"
if [ "$expected" != "$actual" ]; then
    echo "     ✗ SHA256 mismatch — refusing to install"
    exit 1
fi
echo "     ✓ verified"

echo "4/4  extracting + installing to ~/.cargo/bin/mnml…"
tar -C "$tmp_dir" -xf "$tarball"
target_bin="$HOME/.cargo/bin/mnml"
mkdir -p "$(dirname "$target_bin")"
install -m 0755 "${{tmp_dir}}"/*/mnml "$target_bin"
echo "     ✓ installed: $target_bin"

echo ""
echo "──────────────────────────────────────────────────────"
echo "  Quit mnml (Ctrl+Q) and relaunch to use v{version}."
echo "  Your current session is still running the old binary."
echo "──────────────────────────────────────────────────────"
"#
    )
}

fn build_unsupported_script(base: &str, version: &str) -> String {
    // Windows + BSDs fall here — in-app install is a v0.x follow-up.
    // Surface a clear message + the release URL so the user can
    // download manually.
    format!(
        r#"Write-Host "── mnml in-app update ──"
Write-Host "  version: v{version}"
Write-Host ""
Write-Host "In-app install on this platform is a v0.x follow-up."
Write-Host "Download the installer manually:"
Write-Host "  {base}/"
Write-Host ""
Write-Host "Press Enter to close this pane."
$null = Read-Host
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_script_embeds_version_and_target() {
        let s = build_macos_script("https://x.test/v0.99.0", "0.99.0");
        assert!(s.contains("v0.99.0"));
        assert!(s.contains("mnml-rs-"));
        assert!(s.contains("apple-darwin"));
        assert!(s.contains("sudo installer -pkg"));
        assert!(s.contains("SHA256 mismatch"));
    }

    #[test]
    fn linux_script_uses_cargo_bin_dest() {
        let s = build_linux_script("https://x.test/v0.99.0", "0.99.0");
        assert!(s.contains(".cargo/bin/mnml"));
        assert!(s.contains("sha256sum"));
        assert!(s.contains("tar -C"));
    }

    #[test]
    fn build_script_dispatches_per_target_os() {
        // Compile-time dispatch via cfg!; we can only assert on the
        // host platform.
        let s = build_script("0.99.0");
        if cfg!(target_os = "macos") {
            assert!(s.contains("sudo installer -pkg"));
        } else if cfg!(target_os = "linux") {
            assert!(s.contains(".cargo/bin/mnml"));
        } else {
            assert!(s.contains("manually"));
        }
    }

    #[test]
    fn invocation_for_script_uses_powershell_on_windows() {
        let p = std::path::Path::new("/tmp/x.sh");
        let cmd = invocation_for_script(p);
        if cfg!(windows) {
            assert!(cmd.starts_with("powershell"));
        } else {
            assert!(cmd.starts_with("bash"));
        }
    }
}
