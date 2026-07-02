//! Background "is there a newer release?" check — notification only.
//!
//! On startup we spawn a background thread that does a single HTTP
//! GET against the GitHub releases API for the configured repo
//! (`chris-mclennan/mnml`). If the response carries a `tag_name`
//! semver-newer than `CARGO_PKG_VERSION`, we stash it on a shared
//! `Arc<UpdateCheck>` that `App::tick` polls. First tick after data
//! arrives, a toast goes up telling the user how to upgrade — the
//! message adapts to how they installed:
//!
//! - `~/.cargo/bin/mnml`        → `cargo install mnml-rs`
//! - `/opt/homebrew/bin/mnml`   → `brew upgrade mnml`
//! - `/usr/local/bin/mnml`      → `brew upgrade mnml` (Intel prefix)
//! - `/Applications/mnml.app/…` → GitHub releases URL (download DMG)
//! - Anywhere else              → `git pull && cargo install --path .`
//!
//! Silently no-op in headless mode (no toast surface). No config
//! knob for now — the check is cheap (one HTTP call, 10s timeout,
//! runs on a fresh thread), and the toast fires at most once per
//! session.
//!
//! Deliberately notification-only: no in-app installer, no sudo/UAC
//! dance, no SHA256 verification. User does the upgrade themselves
//! via the familiar channel. See git history around commit
//! d015b0b if you want the full-blown installer variant back.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Repo to query — `<owner>/<name>`. Used in the GitHub API URL
/// and the human-readable release link.
pub const REPO: &str = "chris-mclennan/mnml";

/// User-Agent the GitHub API requires for unauthenticated reads.
const USER_AGENT: &str = "mnml-update-check (https://github.com/chris-mclennan/mnml)";

/// How mnml was installed on this machine. Detected once at startup
/// by looking at `current_exe()` — determines which upgrade command
/// the toast recommends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallChannel {
    /// `cargo install mnml-rs` — binary lives under `~/.cargo/bin/`.
    Cargo,
    /// Homebrew — binary lives under `/opt/homebrew/bin/`
    /// (Apple Silicon) or `/usr/local/bin/` (Intel).
    Homebrew,
    /// Installed as `mnml.app` — binary lives inside a
    /// `.app/Contents/Resources/bin/` bundle.
    AppBundle,
    /// Anywhere else — likely a `git pull && cargo install --path .`
    /// dev build.
    Source,
}

impl InstallChannel {
    /// Best-guess based on the running binary's absolute path.
    pub fn detect() -> Self {
        let exe = std::env::current_exe().ok();
        let path = exe.as_ref().and_then(|p| p.to_str()).unwrap_or("");
        if path.contains("/.cargo/bin/") {
            InstallChannel::Cargo
        } else if path.starts_with("/opt/homebrew/") || path.starts_with("/usr/local/") {
            InstallChannel::Homebrew
        } else if path.contains(".app/Contents/") {
            InstallChannel::AppBundle
        } else {
            InstallChannel::Source
        }
    }

    /// Text the toast tells the user to run/do to upgrade. Includes
    /// the version tag so the message stands on its own.
    pub fn upgrade_hint(self, latest: &str) -> String {
        match self {
            InstallChannel::Cargo => format!("cargo install mnml-rs  → v{latest}"),
            InstallChannel::Homebrew => format!("brew upgrade mnml  → v{latest}"),
            InstallChannel::AppBundle => {
                format!("download v{latest}: {}", UpdateCheck::release_url(latest))
            }
            InstallChannel::Source => {
                format!("git pull && cargo install --path .  → v{latest}")
            }
        }
    }
}

/// Shared between the background fetch thread and the main loop.
/// Wrapped in `Arc` so it's cheap to clone the reader handle into
/// `App`.
pub struct UpdateCheck {
    /// `Some("0.1.3")` once the HTTP fetch resolves and the tag is
    /// strictly newer than `CARGO_PKG_VERSION`. `None` while still
    /// fetching, or when we're already on latest.
    pub latest_version: Mutex<Option<String>>,
    /// Set true once `App::tick` has surfaced the result to the
    /// user. Prevents the toast from re-firing on every tick.
    pub announced: AtomicBool,
    /// Where mnml was installed — determines the toast message.
    pub channel: InstallChannel,
}

impl UpdateCheck {
    /// Spawn the background fetch. Returns the shared handle the
    /// app polls. Non-blocking — the HTTP request runs on a fresh
    /// std thread so the editor never waits on it.
    pub fn spawn() -> Arc<Self> {
        let handle = Arc::new(Self {
            latest_version: Mutex::new(None),
            announced: AtomicBool::new(false),
            channel: InstallChannel::detect(),
        });
        let bg = Arc::clone(&handle);
        std::thread::spawn(move || {
            if let Some(latest) = fetch_latest_tag() {
                let current = env!("CARGO_PKG_VERSION");
                if is_newer(&latest, current)
                    && let Ok(mut slot) = bg.latest_version.lock()
                {
                    *slot = Some(latest);
                }
            }
        });
        handle
    }

    /// `Some(version)` once the background fetch resolves and the
    /// user hasn't been told yet. Flips the announced flag so
    /// callers can fire a one-shot toast without bookkeeping.
    pub fn take_pending_announcement(&self) -> Option<String> {
        if self.announced.load(Ordering::Relaxed) {
            return None;
        }
        let latest = self.latest_version.lock().ok()?.clone()?;
        self.announced.store(true, Ordering::Relaxed);
        Some(latest)
    }

    /// Human-readable release URL for the toast + copy/paste.
    pub fn release_url(latest: &str) -> String {
        format!("https://github.com/{REPO}/releases/tag/v{latest}")
    }
}

/// Compare two semver-shaped strings. Returns true iff `remote` is
/// strictly newer than `local`. Tail segments default to 0 so "0.1"
/// < "0.1.1". Anything unparseable returns false — we'd rather skip
/// a real upgrade than announce a phantom one.
fn is_newer(remote: &str, local: &str) -> bool {
    fn parts(v: &str) -> Option<(u64, u64, u64)> {
        let v = v.trim_start_matches('v').split(['-', '+']).next()?;
        let mut it = v.split('.').map(|s| s.parse::<u64>().ok());
        let major = it.next()??;
        let minor = it.next().flatten().unwrap_or(0);
        let patch = it.next().flatten().unwrap_or(0);
        Some((major, minor, patch))
    }
    match (parts(remote), parts(local)) {
        (Some(r), Some(l)) => r > l,
        _ => false,
    }
}

fn fetch_latest_tag() -> Option<String> {
    let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
    let resp = reqwest::blocking::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(10))
        .build()
        .ok()?
        .get(&url)
        .send()
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let body = resp.text().ok()?;
    let parsed: serde_json::Value = serde_json::from_str(&body).ok()?;
    let tag = parsed.get("tag_name")?.as_str()?;
    Some(tag.trim_start_matches('v').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_url_strips_v_prefix_consistently() {
        let url = UpdateCheck::release_url("0.1.3");
        assert_eq!(
            url,
            format!("https://github.com/{REPO}/releases/tag/v0.1.3")
        );
    }

    #[test]
    fn take_pending_announcement_is_one_shot() {
        let uc = UpdateCheck {
            latest_version: Mutex::new(Some("0.99.0".into())),
            announced: AtomicBool::new(false),
            channel: InstallChannel::Source,
        };
        assert_eq!(uc.take_pending_announcement().as_deref(), Some("0.99.0"));
        assert_eq!(uc.take_pending_announcement(), None, "second call is no-op");
    }

    #[test]
    fn is_newer_semver_compare() {
        assert!(is_newer("0.1.4", "0.1.3"));
        assert!(is_newer("0.2.0", "0.1.99"));
        assert!(is_newer("1.0.0", "0.99.99"));
        assert!(!is_newer("0.1.3", "0.1.4"), "same-minor downgrade");
        assert!(!is_newer("0.1.3", "0.1.3"), "same version");
        assert!(!is_newer("garbage", "0.1.3"), "unparseable → false");
    }

    #[test]
    fn upgrade_hint_matches_channel() {
        assert!(
            InstallChannel::Cargo
                .upgrade_hint("1.2.3")
                .contains("cargo install")
        );
        assert!(
            InstallChannel::Homebrew
                .upgrade_hint("1.2.3")
                .contains("brew upgrade")
        );
        assert!(
            InstallChannel::AppBundle
                .upgrade_hint("1.2.3")
                .contains("github.com")
        );
        assert!(
            InstallChannel::Source
                .upgrade_hint("1.2.3")
                .contains("git pull")
        );
    }
}
