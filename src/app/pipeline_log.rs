//! Pipeline-log fetcher — shared machinery the 4 SCM hosts call.
//!
//! Each host (bitbucket / github / gitlab / azdevops) has its own
//! `open_*_pipeline_log` opener that delegates to `spawn_log_fetch_inner`
//! here. Replies stream over a single shared mpsc channel that
//! `drain_pipeline_log_events` drains per `App::tick`.
//!
//! Extracted from `app/mod.rs` (file-split follow-up).

use super::*;

impl App {
    /// Host-aware log fetcher. The three id strings are host-specific —
    /// see `bitbucket::LogHost`'s docs for the per-host mapping. `host_extra`
    /// is only consulted by `LogHost::Gitlab` (carries the API base URL).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn spawn_log_fetch_inner(
        &mut self,
        job_id: u64,
        host: crate::bitbucket::LogHost,
        auth_env: String,
        id1: String,
        id2: String,
        id3: String,
        host_extra: String,
        cancel: std::sync::Arc<std::sync::atomic::AtomicBool>,
    ) {
        let tx = self.ensure_pipeline_log_chan_tx();
        std::thread::spawn(move || {
            use crate::bitbucket::{LogHost, PipelineLogEvent};
            if cancel.load(std::sync::atomic::Ordering::Relaxed) {
                return;
            }
            let token = match std::env::var(&auth_env) {
                Ok(v) => v,
                Err(_) => {
                    let _ = tx.send(PipelineLogEvent::Failed {
                        job_id,
                        err: format!("missing auth: set ${auth_env}"),
                    });
                    return;
                }
            };
            if cancel.load(std::sync::atomic::Ordering::Relaxed) {
                return;
            }
            let result = match host {
                LogHost::Bitbucket => {
                    let auth_header = crate::bitbucket::api::auth_header_value(&token);
                    let client = match crate::bitbucket::api::build_client() {
                        Ok(c) => c,
                        Err(e) => {
                            let _ = tx.send(PipelineLogEvent::Failed { job_id, err: e });
                            return;
                        }
                    };
                    crate::bitbucket::api::fetch_combined_pipeline_log(
                        &client,
                        &auth_header,
                        &id1,
                        &id2,
                        &id3,
                    )
                }
                LogHost::Github => {
                    let auth_header = crate::github::api::auth_header_value(&token);
                    let client = match crate::github::api::build_client() {
                        Ok(c) => c,
                        Err(e) => {
                            let _ = tx.send(PipelineLogEvent::Failed { job_id, err: e });
                            return;
                        }
                    };
                    let run_id: u64 = match id3.parse() {
                        Ok(n) => n,
                        Err(_) => {
                            let _ = tx.send(PipelineLogEvent::Failed {
                                job_id,
                                err: format!("bad GH run_id: {id3}"),
                            });
                            return;
                        }
                    };
                    crate::github::api::fetch_combined_run_log(
                        &client,
                        &auth_header,
                        &id1,
                        &id2,
                        run_id,
                    )
                }
                LogHost::Gitlab => {
                    let auth_header = crate::gitlab::api::auth_header_value(&token);
                    let client = match crate::gitlab::api::build_client() {
                        Ok(c) => c,
                        Err(e) => {
                            let _ = tx.send(PipelineLogEvent::Failed { job_id, err: e });
                            return;
                        }
                    };
                    let pipeline_id: u64 = match id2.parse() {
                        Ok(n) => n,
                        Err(_) => {
                            let _ = tx.send(PipelineLogEvent::Failed {
                                job_id,
                                err: format!("bad GL pipeline_id: {id2}"),
                            });
                            return;
                        }
                    };
                    crate::gitlab::api::fetch_combined_pipeline_log(
                        &client,
                        &host_extra,
                        &auth_header,
                        &id1,
                        pipeline_id,
                    )
                }
                LogHost::Azure => {
                    let auth_header = crate::azdevops::api::auth_header_value(&token);
                    let client = match crate::azdevops::api::build_client() {
                        Ok(c) => c,
                        Err(e) => {
                            let _ = tx.send(PipelineLogEvent::Failed { job_id, err: e });
                            return;
                        }
                    };
                    let build_id: u64 = match id3.parse() {
                        Ok(n) => n,
                        Err(_) => {
                            let _ = tx.send(PipelineLogEvent::Failed {
                                job_id,
                                err: format!("bad AZ build_id: {id3}"),
                            });
                            return;
                        }
                    };
                    crate::azdevops::api::fetch_combined_build_log(
                        &client,
                        &auth_header,
                        &id1,
                        &id2,
                        build_id,
                    )
                }
            };
            match result {
                Ok(log) => {
                    let _ = tx.send(PipelineLogEvent::Done { job_id, log });
                }
                Err(err) => {
                    let _ = tx.send(PipelineLogEvent::Failed { job_id, err });
                }
            }
        });
    }

    fn ensure_pipeline_log_chan_tx(
        &mut self,
    ) -> std::sync::mpsc::Sender<crate::bitbucket::PipelineLogEvent> {
        if let Some((tx, _)) = &self.pipeline_log_chan {
            tx.clone()
        } else {
            let (tx, rx) = std::sync::mpsc::channel();
            let tx_clone = tx.clone();
            self.pipeline_log_chan = Some((tx, rx));
            tx_clone
        }
    }

    /// Drain finished pipeline-log fetches into the matching pane.
    /// Called by `App::tick`.
    pub fn drain_pipeline_log_events(&mut self) {
        let Some((_, rx)) = &self.pipeline_log_chan else {
            return;
        };
        let mut events: Vec<crate::bitbucket::PipelineLogEvent> = Vec::new();
        while let Ok(ev) = rx.try_recv() {
            events.push(ev);
        }
        for ev in events {
            use crate::bitbucket::PipelineLogEvent;
            use crate::bitbucket::PipelineLogState;
            match ev {
                PipelineLogEvent::Done { job_id, log } => {
                    for pane in self.panes.iter_mut() {
                        if let Pane::BitbucketPipelineLog(p) = pane
                            && p.job_id == job_id
                        {
                            p.state = PipelineLogState::Done(log);
                            break;
                        }
                    }
                }
                PipelineLogEvent::Failed { job_id, err } => {
                    for pane in self.panes.iter_mut() {
                        if let Pane::BitbucketPipelineLog(p) = pane
                            && p.job_id == job_id
                        {
                            p.state = PipelineLogState::Failed(err);
                            break;
                        }
                    }
                }
            }
        }
    }

    /// `r` in a `Pane::BitbucketPipelineLog` — re-fetch the log.
    pub fn refetch_active_pipeline_log(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => return,
        };
        let Some(Pane::BitbucketPipelineLog(pane)) = self.panes.get_mut(id) else {
            return;
        };
        // Reset state. Spawn a fresh job so stale replies can't clobber.
        pane.cancel
            .store(true, std::sync::atomic::Ordering::Relaxed);
        let new_cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let new_job = self.pipeline_log_next_job;
        self.pipeline_log_next_job = self.pipeline_log_next_job.wrapping_add(1);
        let host = pane.host;
        let id1 = pane.workspace.clone();
        let id2 = pane.slug.clone();
        let id3 = pane.pipeline_uuid.clone();
        let host_extra = pane.host_extra.clone();
        pane.job_id = new_job;
        pane.cancel = new_cancel.clone();
        pane.state = crate::bitbucket::PipelineLogState::Fetching;
        pane.scroll = 0;
        let auth_env = match host {
            crate::bitbucket::LogHost::Bitbucket => self
                .config
                .bitbucket
                .auth_env
                .clone()
                .unwrap_or_else(|| "BITBUCKET_TOKEN".to_string()),
            crate::bitbucket::LogHost::Github => self
                .config
                .github
                .auth_env
                .clone()
                .unwrap_or_else(|| "GITHUB_TOKEN".to_string()),
            crate::bitbucket::LogHost::Gitlab => self
                .config
                .gitlab
                .auth_env
                .clone()
                .unwrap_or_else(|| "GITLAB_TOKEN".to_string()),
            crate::bitbucket::LogHost::Azure => self
                .config
                .azdevops
                .auth_env
                .clone()
                .unwrap_or_else(|| "AZDO_TOKEN".to_string()),
        };
        self.spawn_log_fetch_inner(
            new_job, host, auth_env, id1, id2, id3, host_extra, new_cancel,
        );
    }

    /// `Enter` in the pipeline-log pane — open the pipeline's web URL.
    pub fn open_active_pipeline_log_url(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::BitbucketPipelineLog(pane)) = self.panes.get(id) else {
            return;
        };
        let url = pane.web_url.clone();
        open_url_external(&url);
        self.toast("opened pipeline in browser");
    }

    /// `y` in the pipeline-log pane — copy the URL.
    pub fn copy_active_pipeline_log_url(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::BitbucketPipelineLog(pane)) = self.panes.get(id) else {
            return;
        };
        let url = pane.web_url.clone();
        self.clipboard.set_yank(url, false);
        self.toast("copied pipeline URL");
    }
}

#[cfg(test)]
mod pipeline_log_tests {
    use super::*;

    #[test]
    fn drain_pipeline_log_events_routes_done_to_pane() {
        // No real worker; we inject events on the channel directly.
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Open a log pane manually.
        let job = 42;
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let pane = crate::bitbucket::PipelineLogPane::new(
            "test pane".to_string(),
            "ws".into(),
            "slug".into(),
            "{uuid-x}".into(),
            "https://example/p/123".into(),
            job,
            cancel.clone(),
        );
        app.panes.push(Pane::BitbucketPipelineLog(pane));
        let pane_id = app.panes.len() - 1;
        // Hook up the channel + push a Done event.
        let tx = app.ensure_pipeline_log_chan_tx();
        tx.send(crate::bitbucket::PipelineLogEvent::Done {
            job_id: job,
            log: "hello world".to_string(),
        })
        .unwrap();
        app.drain_pipeline_log_events();
        // Pane state should have flipped to Done.
        if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get(pane_id) {
            match &p.state {
                crate::bitbucket::PipelineLogState::Done(text) => {
                    assert_eq!(text, "hello world");
                }
                other => panic!("expected Done, got {other:?}"),
            }
        } else {
            panic!("expected BitbucketPipelineLog pane");
        }
    }

    #[test]
    fn drain_pipeline_log_events_routes_failed() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let job = 99;
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let pane = crate::bitbucket::PipelineLogPane::new(
            "x".to_string(),
            "ws".into(),
            "slug".into(),
            "{u}".into(),
            "https://example".into(),
            job,
            cancel,
        );
        app.panes.push(Pane::BitbucketPipelineLog(pane));
        let pane_id = app.panes.len() - 1;
        let tx = app.ensure_pipeline_log_chan_tx();
        tx.send(crate::bitbucket::PipelineLogEvent::Failed {
            job_id: job,
            err: "boom".to_string(),
        })
        .unwrap();
        app.drain_pipeline_log_events();
        if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get(pane_id) {
            match &p.state {
                crate::bitbucket::PipelineLogState::Failed(msg) => assert_eq!(msg, "boom"),
                other => panic!("expected Failed, got {other:?}"),
            }
        }
    }
}
