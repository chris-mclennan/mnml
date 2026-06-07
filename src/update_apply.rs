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
//! Windows: downloads the platform `.msi`, SHA256-verifies, then
//! invokes `msiexec` via `Start-Process -Verb RunAs` so the UAC
//! elevation prompt pops automatically. The Pty pane stays open
//! during the elevated install so the user sees the progress bar
//! + can read the post-install relaunch hint.
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
    } else if cfg!(target_os = "windows") {
        build_windows_script(&base, version)
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

fn build_windows_script(base: &str, version: &str) -> String {
    // cargo-dist publishes `mnml-rs-<target>.msi` for Windows.
    // ARM64 Windows ships as `aarch64-pc-windows-msvc` if/when we
    // add it; for now x86_64 is the only target.
    let target = if cfg!(target_arch = "aarch64") {
        "aarch64-pc-windows-msvc"
    } else {
        "x86_64-pc-windows-msvc"
    };
    let artifact = format!("mnml-rs-{target}.msi");
    // PowerShell flow:
    //   1) Download sha256.sum + the .msi to a temp dir.
    //   2) Get-FileHash + compare to the published sum. Refuse to
    //      install on mismatch (same as macOS / Linux paths).
    //   3) Start-Process -Verb RunAs msiexec /i <file> /qb!
    //      — `-Verb RunAs` triggers UAC; `/qb!` is "basic UI, no
    //      modal at end" so the install runs to completion without
    //      a final dialog the user has to click through.
    //   4) -Wait so we don't relinquish the pty until the elevated
    //      msiexec finishes (otherwise the pane closes before the
    //      user knows whether the install succeeded).
    format!(
        r#"$ErrorActionPreference = 'Stop'
Write-Host "── mnml in-app update ──"
Write-Host "  version: v{version}"
Write-Host "  target:  {target}"
Write-Host ""

$artifact = "{artifact}"
$base     = "{base}"
$shaUrl   = "$base/sha256.sum"
$msiUrl   = "$base/$artifact"

Write-Host "1/4  downloading sha256.sum…"
$shaFile = New-TemporaryFile
Invoke-WebRequest -Uri $shaUrl -OutFile $shaFile.FullName -UseBasicParsing | Out-Null
Write-Host "     ok"

Write-Host "2/4  downloading $artifact…"
$tmpDir  = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString()))
$msiPath = Join-Path $tmpDir.FullName $artifact
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing | Out-Null
$size = (Get-Item $msiPath).Length
Write-Host "     ok ($([math]::Round($size/1MB, 1)) MB)"

Write-Host "3/4  verifying SHA256…"
$expected = (Get-Content $shaFile.FullName |
    ForEach-Object {{ $_ -split '\s+' }} |
    Select-Object -First 2 |
    Where-Object {{ $_ -match '^[0-9a-f]{{64}}$' }} |
    Select-Object -First 1)
# Format above is `<hash>  *<artifact>` — we split on whitespace and
# pick the first hex64 token. Fall back to a per-line search if the
# sums file lists multiple artifacts (one per platform).
if (-not $expected) {{
    $line = Select-String -Path $shaFile.FullName -Pattern $artifact -SimpleMatch | Select-Object -First 1
    if ($line) {{
        $expected = ($line.Line -split '\s+' | Where-Object {{ $_ -match '^[0-9a-f]{{64}}$' }} | Select-Object -First 1)
    }}
}}
if (-not $expected) {{
    Write-Host "     ✗ no SHA256 entry for $artifact in sha256.sum — refusing to install"
    exit 1
}}
$actual = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash.ToLower()
Write-Host "     expected: $($expected.Substring(0, 24))…"
Write-Host "     actual:   $($actual.Substring(0, 24))…"
if ($expected -ne $actual) {{
    Write-Host "     ✗ SHA256 mismatch — refusing to install"
    exit 1
}}
Write-Host "     ✓ verified"

Write-Host "4/4  installing — Windows will show a UAC elevation prompt"
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$msiPath`"", '/qb!' -Verb RunAs -Wait -PassThru
if ($proc.ExitCode -ne 0) {{
    Write-Host "     ✗ msiexec exited with code $($proc.ExitCode)"
    exit $proc.ExitCode
}}
Write-Host "     ✓ install complete"

Remove-Item -Recurse -Force $tmpDir.FullName -ErrorAction SilentlyContinue
Remove-Item -Force $shaFile.FullName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "──────────────────────────────────────────────────────"
Write-Host "  Quit mnml (Ctrl+Q) and relaunch to use v{version}."
Write-Host "  Your current session is still running the old binary."
Write-Host "──────────────────────────────────────────────────────"
Write-Host ""
Write-Host "Press Enter to close this pane."
$null = Read-Host
"#
    )
}

fn build_unsupported_script(base: &str, version: &str) -> String {
    // BSDs / unknown OSes fall here. Surface a clear message + the
    // release URL so the user can download manually.
    format!(
        r#"Write-Host "── mnml in-app update ──"
Write-Host "  version: v{version}"
Write-Host ""
Write-Host "In-app install isn't wired for this platform."
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
        } else if cfg!(target_os = "windows") {
            assert!(s.contains("msiexec"));
        } else {
            assert!(s.contains("manually"));
        }
    }

    #[test]
    fn windows_script_uses_msiexec_with_elevation_and_sha_verify() {
        let s = build_windows_script("https://x.test/v0.99.0", "0.99.0");
        // SHA256 verify before install.
        assert!(s.contains("Get-FileHash"));
        assert!(s.contains("SHA256 mismatch"));
        // msiexec with UAC elevation + wait.
        assert!(s.contains("msiexec"));
        assert!(s.contains("-Verb RunAs"));
        assert!(s.contains("-Wait"));
        // Artifact name follows the cargo-dist convention.
        assert!(s.contains("mnml-rs-"));
        assert!(s.contains("pc-windows-msvc.msi"));
        // Version is templated.
        assert!(s.contains("v0.99.0"));
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
