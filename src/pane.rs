//! The "open thing" abstraction. `Editor` is the workhorse; `MdPreview` is a
//! read-only rendered-markdown view; `Diff` is a `git diff` view with hunk
//! navigation + staging. Later tracks add `Pty`, `Request`, `Ai` — each is
//! additive (a new variant + a renderer + a `match` arm here), never a refactor.

use std::path::PathBuf;

use crate::ai::AiPane;
use crate::bitbucket::{BitbucketPipelinesPane, BitbucketPullRequestsPane};
use crate::browser_pane::BrowserPane;
use crate::buffer::Buffer;
use crate::github::{GithubActionsPane, GithubPullRequestsPane};
use crate::azdevops::{AzDevOpsBuildsPane, AzDevOpsPullRequestsPane};
use crate::gitlab::{GitlabMergeRequestsPane, GitlabPipelinesPane};
use crate::git::diff::Hunk;
use crate::git::graph::GitGraphPane;
use crate::git::stage::GitStatusPane;
use crate::grep_pane::GrepPane;
use crate::lsp::diagnostics_pane::DiagnosticsPane;
use crate::lsp::outline_pane::OutlinePane;
use crate::playwright::TestsPane;
use crate::playwright::flaky_pane::FlakyPane;
use crate::playwright::trace_pane::TracePane;
use crate::pty_pane::PtySession;
use crate::request_pane::RequestPane;
#[cfg(feature = "private")]
use crate::private::codebuilds_pane::CodeBuildsPane;
#[cfg(feature = "private")]
use crate::private::private_executions_pane::TestExecutionsPane;

// `Editor`'s payload (`Buffer`) is much bigger than the others'; boxing it would
// ripple a `Box` through every `Pane::Editor(b)` site for a handful of bytes of
// slack in a Vec that holds ~1–10 panes. Not worth it (revisit if more chunky
// variants land).
#[allow(clippy::large_enum_variant)]
pub enum Pane {
    Editor(Buffer),
    /// A rendered-markdown view of `path`. `source` is a snapshot of the `.md`
    /// text (refreshed when the source buffer is saved); `scroll` is the top row.
    MdPreview(MdPreview),
    /// A `git diff` view (hunk nav + stage/unstage).
    Diff(DiffView),
    /// A graphical-Git-GUI-style commit-DAG browser (`git log --all` + commit details).
    GitGraph(GitGraphPane),
    /// A staging view — worktree/index file lists + stage/unstage + commit.
    GitStatus(GitStatusPane),
    /// A request fired from a `.http`/`.curl` file, with its response.
    Request(RequestPane),
    /// An embedded terminal (shell / `claude` / `codex`).
    Pty(PtySession),
    /// An AI one-shot (`claude -p`) prompt + its answer.
    Ai(AiPane),
    /// A Playwright test run + its results tree.
    Tests(TestsPane),
    /// A parsed Playwright `trace.zip` shown as a text timeline.
    Trace(TracePane),
    /// The flaky-test dashboard — every wobbly test in the workspace's history.
    Flaky(FlakyPane),
    /// A persistent symbol outline for one editor — the `documentSymbol` reply,
    /// rendered as an indented list with click/Enter-to-jump.
    Outline(OutlinePane),
    /// A Chrome the IDE is driving over CDP — a console / nav / eval log.
    Browser(BrowserPane),
    /// A workspace-wide LSP-diagnostics ("Problems") list.
    Diagnostics(DiagnosticsPane),
    /// A workspace-grep results list — browsable, jump-and-stay.
    Grep(GrepPane),
    /// Vim's quickfix list — same UI as `Grep` but a distinct pane so
    /// `:grep` results aren't clobbered when something else (an LSP
    /// references call, `:cexpr`, …) populates the quickfix.
    Quickfix(GrepPane),
    /// Vim's `q:` — a scrollable list of recent `:` cmdline entries.
    /// Enter re-fires the highlighted entry; Esc closes.
    CmdlineHistory(CmdlineHistoryPane),
    /// Bitbucket Cloud pipelines list — recent CI runs across every
    /// configured `[[bitbucket.repos]]` entry, grouped by repo.
    BitbucketPipelines(BitbucketPipelinesPane),
    /// Bitbucket Cloud open pull requests list — sibling of the pipelines pane.
    BitbucketPullRequests(BitbucketPullRequestsPane),
    /// GitHub Actions workflow runs list — symmetric to the Bitbucket pane.
    GithubActions(GithubActionsPane),
    /// GitHub open pull requests list.
    GithubPullRequests(GithubPullRequestsPane),
    /// GitLab CI pipelines list.
    GitlabPipelines(GitlabPipelinesPane),
    /// GitLab open merge requests list.
    GitlabMergeRequests(GitlabMergeRequestsPane),
    /// Azure DevOps builds list.
    AzDevOpsBuilds(AzDevOpsBuildsPane),
    /// Azure DevOps active pull requests list.
    AzDevOpsPullRequests(AzDevOpsPullRequestsPane),
    /// DocumentDB live `TestExecutions` browser (the private integration org build). Behind
    /// the `private` Cargo feature — the lean build doesn't have this.
    #[cfg(feature = "private")]
    TestExecutions(TestExecutionsPane),
    /// AWS CodeBuild recent-builds browser (the private integration org build). Behind the
    /// `private` Cargo feature.
    #[cfg(feature = "private")]
    CodeBuilds(CodeBuildsPane),
}

/// Vim's command-line window — `q:` opens a read-only list of recent ex
/// commands. Up/Down navigate; Enter re-fires the selected entry.
#[derive(Debug, Clone, Default)]
pub struct CmdlineHistoryPane {
    pub entries: Vec<String>,
    pub selected: usize,
    pub scroll: usize,
}

impl CmdlineHistoryPane {
    pub fn from_history(entries: &[String]) -> Self {
        // Newest entries first.
        let entries: Vec<String> = entries.iter().rev().cloned().collect();
        CmdlineHistoryPane {
            entries,
            selected: 0,
            scroll: 0,
        }
    }
    pub fn move_selection(&mut self, delta: isize) {
        if self.entries.is_empty() {
            return;
        }
        let max = self.entries.len() as isize - 1;
        self.selected = ((self.selected as isize + delta).clamp(0, max)) as usize;
    }
    pub fn selected_entry(&self) -> Option<&str> {
        self.entries.get(self.selected).map(String::as_str)
    }
}

pub struct MdPreview {
    pub path: PathBuf,
    pub source: String,
    pub scroll: usize,
}

impl MdPreview {
    pub fn title(&self) -> String {
        let name = self
            .path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "markdown".to_string());
        format!("{name} ◳")
    }

    /// Approximate cursor-tracking — scroll the preview so it lines up with
    /// the source buffer's cursor row. Uses a heading-aware heuristic: for
    /// each source line above `src_row`, count rendered rows as 1 for body
    /// lines and 2 for heading-introducing lines (`#…`) to mimic the
    /// renderer's padding around headings. Then clamp scroll to that count.
    pub fn sync_to_source_row(&mut self, src_row: usize) {
        let mut rendered = 0usize;
        for (i, line) in self.source.lines().enumerate() {
            if i >= src_row {
                break;
            }
            let t = line.trim_start();
            rendered += if t.starts_with('#') { 2 } else { 1 };
        }
        self.scroll = rendered;
    }
}

/// What a [`DiffView`] is showing.
#[derive(Debug, Clone)]
pub enum DiffScope {
    /// Unstaged changes — `git diff` for one file (`Some`) or the whole worktree.
    Unstaged(Option<PathBuf>),
    /// Staged changes — `git diff --cached`.
    Staged,
    /// The diff a commit introduced — `git show <hash>` (read-only, no staging).
    Commit(String),
    /// Buffer text vs its on-disk version (vim `:DiffOrig` shape).
    /// Read-only — hunks can't be staged.
    BufferVsDisk(PathBuf),
}

pub struct DiffView {
    pub scope: DiffScope,
    pub hunks: Vec<Hunk>,
    /// Top rendered row.
    pub scroll: usize,
    /// The "current" hunk index (what `s`/`u` act on, what `n`/`p` move).
    pub cursor: usize,
}

impl DiffView {
    pub fn new(scope: DiffScope, hunks: Vec<Hunk>) -> Self {
        DiffView {
            scope,
            hunks,
            scroll: 0,
            cursor: 0,
        }
    }
    pub fn title(&self) -> String {
        match &self.scope {
            DiffScope::Unstaged(Some(p)) => format!(
                "diff: {}",
                p.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            ),
            DiffScope::Unstaged(None) => "diff: worktree".to_string(),
            DiffScope::Staged => "diff: staged".to_string(),
            DiffScope::Commit(h) => format!("commit {}", h.chars().take(9).collect::<String>()),
            DiffScope::BufferVsDisk(p) => format!(
                "buffer vs disk: {}",
                p.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            ),
        }
    }
}

impl Pane {
    /// Short title for the bufferline tab.
    pub fn title(&self) -> String {
        match self {
            Pane::Editor(b) => b.display_name(),
            Pane::MdPreview(p) => p.title(),
            Pane::Diff(d) => d.title(),
            Pane::GitGraph(g) => g.tab_title(),
            Pane::GitStatus(g) => g.tab_title(),
            Pane::Request(r) => r.title(),
            Pane::Pty(s) => s.title(),
            Pane::Ai(a) => a.tab_title(),
            Pane::Tests(t) => t.tab_title(),
            Pane::Trace(t) => t.tab_title(),
            Pane::Flaky(f) => f.tab_title(),
            Pane::Outline(o) => o.tab_title(),
            Pane::Browser(b) => b.tab_title(),
            Pane::Diagnostics(d) => d.tab_title(),
            Pane::Grep(g) => g.tab_title(),
            Pane::Quickfix(g) => format!("Quickfix · {}", g.hits.len()),
            Pane::CmdlineHistory(_) => "q:".to_string(),
            Pane::BitbucketPipelines(p) => p.tab_title(),
            Pane::BitbucketPullRequests(p) => p.tab_title(),
            Pane::GithubActions(p) => p.tab_title(),
            Pane::GithubPullRequests(p) => p.tab_title(),
            Pane::GitlabPipelines(p) => p.tab_title(),
            Pane::GitlabMergeRequests(p) => p.tab_title(),
            Pane::AzDevOpsBuilds(p) => p.tab_title(),
            Pane::AzDevOpsPullRequests(p) => p.tab_title(),
            #[cfg(feature = "private")]
            Pane::TestExecutions(p) => p.tab_title(),
            #[cfg(feature = "private")]
            Pane::CodeBuilds(p) => p.tab_title(),
        }
    }

    /// True if the pane has unsaved changes (drives the `●` marker).
    pub fn is_dirty(&self) -> bool {
        match self {
            Pane::Editor(b) => b.dirty,
            Pane::MdPreview(_)
            | Pane::Diff(_)
            | Pane::GitGraph(_)
            | Pane::GitStatus(_)
            | Pane::Request(_)
            | Pane::Pty(_)
            | Pane::Ai(_)
            | Pane::Tests(_)
            | Pane::Trace(_)
            | Pane::Flaky(_)
            | Pane::Outline(_)
            | Pane::Browser(_)
            | Pane::Diagnostics(_)
            | Pane::Grep(_)
            | Pane::Quickfix(_)
            | Pane::CmdlineHistory(_)
            | Pane::BitbucketPipelines(_)
            | Pane::BitbucketPullRequests(_)
            | Pane::GithubActions(_)
            | Pane::GithubPullRequests(_)
            | Pane::GitlabPipelines(_)
            | Pane::GitlabMergeRequests(_)
            | Pane::AzDevOpsBuilds(_)
            | Pane::AzDevOpsPullRequests(_) => false,
            #[cfg(feature = "private")]
            Pane::TestExecutions(_) => false,
            #[cfg(feature = "private")]
            Pane::CodeBuilds(_) => false,
        }
    }

    pub fn as_editor(&self) -> Option<&Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
            _ => None,
        }
    }

    pub fn as_editor_mut(&mut self) -> Option<&mut Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
            _ => None,
        }
    }
}
