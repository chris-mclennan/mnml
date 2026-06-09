//! Background "is there a newer release?" check.
//!
//! On startup we spawn a background thread that does a single HTTP
//! GET against the GitHub releases API for the configured repo
//! (`chris-mclennan/mnml`). If the response carries a `tag_name`
//! different from `CARGO_PKG_VERSION`, the result is stashed on a
//! shared `Arc<UpdateCheck>` that `App::tick` polls. First time
//! the check fires after data arrives, a toast goes up
//! ("v0.1.3 available — github.com/.../releases/tag/v0.1.3").
//!
//! Disabled by `[ui] check_updates = false` in the user's config,
//! and silently no-op in headless / blit modes (no statusline to
//! show the result, no toast surface).
//!
//! Deliberately simple — string-equality on the version tag, no
//! semver parsing. Triggers a false-positive only when running an
//! unreleased local dev build whose Cargo.toml version still
//! matches the latest tag — in that case the user dismisses the
//! toast and the session-once flag stops it from reappearing.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Repo to query — `<owner>/<name>`. Used in the GitHub API URL
/// and the human-readable release link.
pub const REPO: &str = "chris-mclennan/mnml";

/// User-Agent the GitHub API requires for unauthenticated reads.
const USER_AGENT: &str = "mnml-update-check (https://github.com/chris-mclennan/mnml)";

/// Polling interval for the foreground side — `App::tick` calls
/// `maybe_announce` at the editor's tick rate; the inner read is
/// near-free (one mutex lock), so this exists more as documentation
/// than as a knob.
pub const ANNOUNCE_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Shared between the background fetch thread and the main loop.
/// Wrapped in `Arc` so it's cheap to clone the reader handle into
/// `App`.
pub struct UpdateCheck {
    /// `Some("0.1.3")` once the HTTP fetch resolves and the tag
    /// differs from `CARGO_PKG_VERSION`. `None` while still
    /// fetching, or when we're already on latest.
    pub latest_version: Mutex<Option<String>>,
    /// Set true once `App::tick` has surfaced the result to the
    /// user (toast / statusline chip). Prevents the toast from
    /// re-firing on every tick.
    pub announced: AtomicBool,
}

impl UpdateCheck {
    /// Spawn the background fetch. Returns the shared handle the
    /// app polls. Non-blocking — the HTTP request runs on a fresh
    /// std thread so the editor never waits on it.
    pub fn spawn() -> Arc<Self> {
        let handle = Arc::new(Self {
            latest_version: Mutex::new(None),
            announced: AtomicBool::new(false),
        });
        let bg = Arc::clone(&handle);
        std::thread::spawn(move || {
            if let Some(latest) = fetch_latest_tag() {
                let current = env!("CARGO_PKG_VERSION");
                // 2026-06-08 hunt M6 (mixr-mirrored): was raw string
                // compare, which also fired on DOWNGRADE (running
                // a newer-than-release Cargo.toml against an older
                // GH tag). Only announce when remote is strictly
                // newer, semver-compared.
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
    /// user hasn't been told yet. Marks the check as announced so
    /// callers can fire a one-shot toast without bookkeeping.
    pub fn take_pending_announcement(&self) -> Option<String> {
        if self.announced.load(Ordering::Relaxed) {
            return None;
        }
        let latest = self.latest_version.lock().ok()?.clone()?;
        self.announced.store(true, Ordering::Relaxed);
        Some(latest)
    }

    /// Read-only access for the statusline chip. Doesn't flip the
    /// announced flag — just reports the cached result.
    pub fn latest(&self) -> Option<String> {
        self.latest_version.lock().ok()?.clone()
    }

    /// Human-readable URL the toast / chip points the user at.
    pub fn release_url(latest: &str) -> String {
        format!("https://github.com/{REPO}/releases/tag/v{latest}")
    }
}

/// Compare two semver-shaped strings. Returns true iff `remote` is
/// strictly newer than `local`. Tail segments default to 0 so "0.1"
/// < "0.1.1". Anything unparseable returns false — we'd rather skip
/// a real upgrade than announce a phantom one. Mirrors mixr's
/// implementation; small enough to keep in sync by hand.
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
        };
        assert_eq!(uc.take_pending_announcement().as_deref(), Some("0.99.0"));
        // Second call returns None even though latest_version is still set.
        assert!(uc.take_pending_announcement().is_none());
    }

    #[test]
    fn take_pending_announcement_none_when_no_data() {
        let uc = UpdateCheck {
            latest_version: Mutex::new(None),
            announced: AtomicBool::new(false),
        };
        assert!(uc.take_pending_announcement().is_none());
    }

    #[test]
    fn is_newer_does_not_announce_on_downgrade() {
        assert!(is_newer("0.1.10", "0.1.9")); // semver, not lex
        assert!(!is_newer("0.1.9", "0.1.10"));
        assert!(!is_newer("0.1.3", "0.1.3"));
        assert!(!is_newer("0.1.2", "0.1.4")); // the downgrade case
        assert!(is_newer("1.0.0", "0.99.0"));
        assert!(is_newer("v0.2.0", "0.1.0"));
        assert!(!is_newer("nightly", "0.1.0"));
        assert!(!is_newer("", "0.1.0"));
    }
}
