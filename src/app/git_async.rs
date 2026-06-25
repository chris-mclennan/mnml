//! Background-thread runner for `git push` / `pull` / `fetch` /
//! `cherry-pick`. Same pattern as the sibling crates' loader-thread
//! refactor (slack/teams/gmail/mandrill/buttondown/docker async
//! migrations earlier today): the App sends a job + drains results
//! in `tick()`, so a slow remote / credential-prompt / SSH key
//! prompt no longer freezes the UI thread.
//!
//! Surface visible to the rest of `App`:
//! * [`GitJob`] / [`GitResult`] enums + `spawn_git_loader` builder.
//! * App stores the `Sender<GitJob>` + `Receiver<GitResult>` returned
//!   here as `git_loader_tx` / `git_loader_rx`.
//! * `App::run_git_{fetch,pull,push,cherry_pick}` now SEND the job
//!   (instead of calling the sync helper directly) and toast a
//!   pending status. `App::drain_git_results` (called from `tick`)
//!   applies the result.
//!
//! Push has a fallback: if the first `git push` fails with "no
//! upstream branch", retry with `--set-upstream origin <current>`.
//! That fallback lives ON the loader thread so a slow network only
//! pays the cost ONCE per user action; the alternative (toast then
//! re-send) would cost two round-trips through the channel and
//! show a confusing intermediate "no upstream" error before the
//! retry recovered.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread;

#[derive(Debug, Clone)]
pub enum GitJob {
    Fetch {
        repo: PathBuf,
    },
    Pull {
        repo: PathBuf,
    },
    Push {
        repo: PathBuf,
        current_branch: Option<String>,
    },
    CherryPick {
        repo: PathBuf,
        hash: String,
    },
    /// `git blame` for `rel` (workspace-relative) under `repo`.
    /// Carries `path` (absolute) so the result can re-find the open
    /// editor pane after the shell-out returns. Used by
    /// `toggle_blame` and `refresh_blame_for`.
    /// untouched-surfaces-hunt-2026-06-08 SEV-2 #9.
    Blame {
        repo: PathBuf,
        rel: String,
        path: PathBuf,
    },
    /// `git checkout` (local), `git checkout --track` (remote-track),
    /// or `git checkout` (plain id). `kind` distinguishes which
    /// branch helper to call. `from_branch` is carried through so
    /// post-success undo-stack registration can fire on the main
    /// thread without re-querying. untouched-surfaces SEV-2 #9.
    Checkout {
        repo: PathBuf,
        kind: CheckoutKind,
        target: String,
        from_branch: Option<String>,
    },
    /// 2026-06-21 power-user-ws-git SEV-2 merge-rebase-block-ui:
    /// merge / rebase / delete-branch / worktree-add /
    /// worktree-remove all sync-shell-out'd on the main app
    /// thread, freezing UI for the duration. Now via the loader.
    Merge {
        repo: PathBuf,
        name: String,
    },
    Rebase {
        repo: PathBuf,
        name: String,
    },
    DeleteBranch {
        repo: PathBuf,
        name: String,
    },
    WorktreeAdd {
        repo: PathBuf,
        path: PathBuf,
        branch: String,
    },
    WorktreeRemove {
        repo: PathBuf,
        path: PathBuf,
    },
}

/// Which checkout helper to call. The string carried in the job's
/// `target` is the bare branch / remote ref (no `local:` / `remote:`
/// prefix — those are stripped on the caller side).
#[derive(Debug, Clone, Copy)]
pub enum CheckoutKind {
    /// `git checkout -- <branch>`. Joins the undo stack.
    Local,
    /// `git checkout --track -- <remote>`. Creates a new local
    /// tracking branch; does NOT join the undo stack (redo semantics
    /// get fuzzy when an extra branch was created as a side effect).
    RemoteTrack,
}

/// What the loader thread reports back.
#[derive(Debug)]
pub enum GitResult {
    Fetched(Result<String, String>),
    Pulled(Result<String, String>),
    Pushed {
        kind: PushKind,
        result: Result<String, String>,
    },
    CherryPicked {
        hash: String,
        result: Result<String, String>,
    },
    /// Blame result. `lines` is empty when the file is untracked or
    /// the path isn't in any commit yet. Caller matches by `path`
    /// to find the editor pane to update.
    Blamed {
        path: PathBuf,
        lines: Vec<crate::git::blame::BlameLine>,
    },
    /// Checkout result. `from_branch` is carried through unchanged
    /// so the post-success handler can register the undo + run
    /// after_checkout without re-querying.
    CheckedOut {
        kind: CheckoutKind,
        from_branch: Option<String>,
        result: Result<String, String>,
    },
    Merged {
        name: String,
        result: Result<(), String>,
    },
    Rebased {
        name: String,
        result: Result<(), String>,
    },
    BranchDeleted {
        name: String,
        result: Result<(), String>,
    },
    WorktreeAdded {
        path: PathBuf,
        branch: String,
        result: Result<(), String>,
    },
    WorktreeRemoved {
        path: PathBuf,
        result: Result<(), String>,
    },
}

/// Push outcome flavor — affects the toast prefix.
#[derive(Debug, Clone, Copy)]
pub enum PushKind {
    /// Plain `git push` succeeded.
    Normal,
    /// `git push --set-upstream origin <branch>` succeeded after
    /// the plain push reported "no upstream branch".
    SetUpstream,
}

/// Spawn the git-loader thread. Returns `(job_tx, result_rx)` for
/// App to store. Dropping `job_tx` (App-drop) closes the channel
/// and the thread exits cleanly.
pub fn spawn_git_loader() -> (Sender<GitJob>, Receiver<GitResult>) {
    let (job_tx, job_rx) = channel::<GitJob>();
    let (res_tx, res_rx) = channel::<GitResult>();
    thread::Builder::new()
        .name("mnml-git-loader".into())
        .spawn(move || {
            while let Ok(job) = job_rx.recv() {
                let result = match job {
                    GitJob::Fetch { repo } => {
                        GitResult::Fetched(crate::git::sync::fetch_all(&repo))
                    }
                    GitJob::Pull { repo } => {
                        GitResult::Pulled(crate::git::sync::pull_ff_only(&repo))
                    }
                    GitJob::Push {
                        repo,
                        current_branch,
                    } => match crate::git::sync::push(&repo) {
                        Ok(s) => GitResult::Pushed {
                            kind: PushKind::Normal,
                            result: Ok(s),
                        },
                        Err(e)
                            if (e.contains("has no upstream branch")
                                || e.contains("--set-upstream"))
                                && let Some(branch) = current_branch
                                && !branch.is_empty() =>
                        {
                            GitResult::Pushed {
                                kind: PushKind::SetUpstream,
                                result: crate::git::sync::push_set_upstream(&repo, &branch),
                            }
                        }
                        Err(e) => GitResult::Pushed {
                            kind: PushKind::Normal,
                            result: Err(e),
                        },
                    },
                    GitJob::CherryPick { repo, hash } => GitResult::CherryPicked {
                        result: crate::git::commit::cherry_pick(&repo, &hash),
                        hash,
                    },
                    GitJob::Blame { repo, rel, path } => GitResult::Blamed {
                        lines: crate::git::blame::blame(&repo, &rel),
                        path,
                    },
                    GitJob::Checkout {
                        repo,
                        kind,
                        target,
                        from_branch,
                    } => {
                        let result = match kind {
                            CheckoutKind::Local => {
                                crate::git::branch::checkout(&repo, &target).map(|_| target.clone())
                            }
                            CheckoutKind::RemoteTrack => {
                                crate::git::branch::checkout_track(&repo, &target)
                                    .map(|_| target.clone())
                            }
                        };
                        GitResult::CheckedOut {
                            kind,
                            from_branch,
                            result,
                        }
                    }
                    GitJob::Merge { repo, name } => GitResult::Merged {
                        result: crate::git::branch::merge(&repo, &name),
                        name,
                    },
                    GitJob::Rebase { repo, name } => GitResult::Rebased {
                        result: crate::git::branch::rebase(&repo, &name),
                        name,
                    },
                    GitJob::DeleteBranch { repo, name } => GitResult::BranchDeleted {
                        result: crate::git::branch::delete_branch(&repo, &name),
                        name,
                    },
                    GitJob::WorktreeAdd { repo, path, branch } => GitResult::WorktreeAdded {
                        result: crate::git::branch::worktree_add(&repo, &path, &branch),
                        path,
                        branch,
                    },
                    GitJob::WorktreeRemove { repo, path } => GitResult::WorktreeRemoved {
                        result: crate::git::branch::worktree_remove(&repo, &path),
                        path,
                    },
                };
                if res_tx.send(result).is_err() {
                    // App dropped the receiver — exit cleanly.
                    break;
                }
            }
        })
        .expect("spawn mnml-git-loader");
    (job_tx, res_rx)
}
