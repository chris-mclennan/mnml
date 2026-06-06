//! App methods for the cross-host PR picker (`pr.picker`) and the
//! Tab → pipeline cross-nav. Fans out to `mnml-forge-*` siblings
//! via [`crate::scm`].

use crate::app::App;
use crate::picker::{Picker, PickerItem, PickerKind};
use crate::scm::{self, SiblingPr};
use std::sync::mpsc;
use std::thread;

/// Unit separator. Doesn't appear in URLs or labels — used to pack
/// the cross-nav payload (`url\x1Fhost\x1Fowner\x1Frepo\x1Fbranch`)
/// into a single PickerItem id so Tab/Enter can both unpack it.
const US: char = '\x1F';

impl App {
    /// `pr.picker` palette command — opens a fuzzy picker over every
    /// open PR/MR across all configured `mnml-forge-*` siblings.
    /// Enter on a row opens the PR URL; Tab on a row jumps to the
    /// matching pipeline/build (host-specific cross-nav).
    ///
    /// First call (or stale cache) blocks ~1-3 seconds while the
    /// siblings answer; subsequent calls within 5 minutes use the
    /// cache. The user can force a refresh with `pr.refresh`.
    pub fn open_pr_picker(&mut self) {
        let fresh = self
            .scm_pr_cache
            .as_ref()
            .map(|c| !c.is_stale())
            .unwrap_or(false);
        if !fresh {
            // Synchronous fan-out — keeps the UX simple at the cost
            // of a brief block. The background-fetch path (when the
            // cache is non-empty but stale) lives in
            // `kick_off_scm_pr_refresh`.
            self.toast("loading PRs from forge siblings…");
            self.scm_pr_cache = Some(scm::aggregate_all());
        }
        let Some(cache) = self.scm_pr_cache.as_ref() else {
            unreachable!("aggregate_all always returns a cache");
        };
        if cache.prs.is_empty() {
            if cache.errors.is_empty() {
                self.toast(
                    "no open PRs across installed forge siblings (mnml-forge-bitbucket / github / gitlab / azdevops)",
                );
            } else {
                let summary = cache
                    .errors
                    .iter()
                    .map(|(bin, _)| bin.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");
                self.toast(format!("0 PRs (errors: {summary})"));
            }
            return;
        }
        let items: Vec<PickerItem> = cache.prs.iter().map(pr_to_item).collect();
        let mut title = format!("Open PRs ({})", cache.prs.len());
        if !cache.errors.is_empty() {
            title.push_str(&format!(
                " · {} sibling errors (Esc to dismiss)",
                cache.errors.len()
            ));
        }
        self.open_picker(Picker::new(PickerKind::OpenPullRequests, title, items));
    }

    /// `pr.refresh` palette command — discards the cached PR list
    /// and kicks off a background fan-out. The result lands on the
    /// `scm_pr_pending` channel; the main `tick` drains it.
    pub fn refresh_scm_prs(&mut self) {
        if self.scm_pr_pending.is_some() {
            self.toast("PR refresh already in flight");
            return;
        }
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let cache = scm::aggregate_all();
            let _ = tx.send(cache);
        });
        self.scm_pr_pending = Some(rx);
        self.toast("refreshing PRs across forge siblings…");
    }

    /// Drain `scm_pr_pending` from the main `tick`. Called every
    /// frame; no-op when nothing's pending.
    pub fn drain_scm_pr_pending(&mut self) -> bool {
        let Some(rx) = self.scm_pr_pending.as_ref() else {
            return false;
        };
        match rx.try_recv() {
            Ok(cache) => {
                let n = cache.prs.len();
                self.scm_pr_cache = Some(cache);
                self.scm_pr_pending = None;
                self.refresh_rail_pulls();
                self.toast(format!("PRs refreshed: {n} across forge siblings"));
                true
            }
            Err(mpsc::TryRecvError::Empty) => false,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.scm_pr_pending = None;
                false
            }
        }
    }

    /// Cross-nav handler for `PickerKind::OpenPullRequests` Enter:
    /// unpack the URL from the packed payload and open in browser.
    pub fn accept_pr_picker_primary(&mut self, item_id: &str) {
        let url = item_id.split(US).next().unwrap_or(item_id);
        crate::app::open_url_external(url);
        self.toast(format!("opened {url}"));
    }

    /// Cross-nav handler for `PickerKind::OpenPullRequests` Tab:
    /// unpack the host/owner/repo/branch, ask the matching sibling
    /// to look up the pipeline URL, open in browser.
    ///
    /// Synchronous (~1 sec) — we're already in a picker-accept
    /// path, so the UX is "Tab pressed → brief pause → browser
    /// opens or toast explains why not."
    pub fn accept_pr_picker_secondary(&mut self, item_id: &str) {
        let parts: Vec<&str> = item_id.split(US).collect();
        if parts.len() < 5 {
            self.toast("this PR row has no branch — Tab cross-nav unavailable");
            return;
        }
        let (host, owner, repo, branch) = (parts[1], parts[2], parts[3], parts[4]);
        if branch.is_empty() {
            self.toast(format!(
                "no source branch on this PR (host: {host}) — Tab cross-nav unavailable"
            ));
            return;
        }
        match scm::find_pipeline_url(host, owner, repo, branch) {
            Some(url) => {
                crate::app::open_url_external(&url);
                self.toast(format!("opened pipeline {url}"));
            }
            None => self.toast(format!("no pipeline found for {owner}/{repo}@{branch}")),
        }
    }
}

fn pr_to_item(pr: &SiblingPr) -> PickerItem {
    let id = format!(
        "{}{US}{}{US}{}{US}{}{US}{}",
        pr.url,
        pr.host,
        pr.owner,
        pr.repo,
        pr.source_branch.as_deref().unwrap_or(""),
    );
    let host_chip = host_chip(&pr.host);
    let label = format!(
        "{host_chip}  {}/{}#{} {}",
        pr.owner, pr.repo, pr.id, pr.title
    );
    let detail = format!("by {} · {}", pr.author, short_date(&pr.updated_at));
    PickerItem::new(id, label, detail)
}

fn host_chip(host: &str) -> &'static str {
    match host {
        "bitbucket" => "BB",
        "github" => "GH",
        "gitlab" => "GL",
        "azdevops" => "AZ",
        _ => "??",
    }
}

fn short_date(s: &str) -> String {
    s.chars().take(10).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pr_item_id_packs_payload() {
        let pr = SiblingPr {
            id: "1".into(),
            url: "https://example.com/pr/1".into(),
            owner: "foo".into(),
            repo: "bar".into(),
            title: "t".into(),
            author: "a".into(),
            source_branch: Some("feat/x".into()),
            dest_branch: Some("main".into()),
            state: "open".into(),
            updated_at: "2026-06-06T15:43:00Z".into(),
            remote_url_https: "https://example.com/foo/bar.git".into(),
            remote_url_ssh: "git@example.com:foo/bar.git".into(),
            host: "github".into(),
        };
        let item = pr_to_item(&pr);
        let parts: Vec<&str> = item.id.split('\x1F').collect();
        assert_eq!(parts.len(), 5);
        assert_eq!(parts[0], "https://example.com/pr/1");
        assert_eq!(parts[1], "github");
        assert_eq!(parts[2], "foo");
        assert_eq!(parts[3], "bar");
        assert_eq!(parts[4], "feat/x");
    }
}
