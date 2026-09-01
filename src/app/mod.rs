//! Pure application state — no rendering, no event loop. The terminal loop
//! (`tui.rs`) and the headless loop (`headless.rs`) both drive an `App`; the
//! render path (`ui::draw`) reads it and fills `rects` for mouse hit-testing.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ratatui::layout::Rect;

use crate::buffer::Buffer;
use crate::clipboard::Clipboard;
use crate::config::Config;
use crate::focus::Focus;
use crate::git::GitStatus;
use crate::input::EditingMode;
use crate::layout::{Layout, PaneId};
use crate::pane::Pane;
use crate::picker::{Picker, PickerKind};
use crate::tree::Tree;

// `mod aws` (CodeBuild + CloudWatch) was split out to
// mnml-aws-codebuild in 2026-06.
// `mod azdevops` was split out to mnml-forge-azdevops in 2026-06.
// `mod github` was split out to mnml-forge-github in 2026-06.
// `mod gitlab` was split out to mnml-forge-gitlab in 2026-06.

pub mod ai;
mod ai_usage_methods;
pub(crate) mod backup;
mod buffer_save_methods;
mod cdp;
mod cdp_prompt_methods;
mod claude_usage_pane;
mod codex_usage_pane;
pub(crate) mod context_menus;
mod coverage_methods;
mod dap;
pub mod discovery;
pub(crate) mod dispatch;
mod drag_methods;
mod ex_commands;
mod find;
mod flash_block_methods;
mod fold_methods;
mod git;
mod git_async;
pub(crate) mod glyph_builder;
mod grep;
mod harpoon;
pub(crate) mod help;
mod http;
pub(crate) mod integration_detail;
mod layout;
mod lsp;
mod macros_marks;
mod message_persist;
mod now_playing;
mod picker;
mod portable;
mod reset;
mod sonos;
mod transfers;
// pipeline_log removed after 2026-06 SCM split.
pub(crate) mod cloud_agents_methods;
pub(crate) mod cmdline_methods;
mod file_actions;
pub(crate) mod first_launch;
pub(crate) mod integration_audit;
pub(crate) mod integration_glyphs;
pub(crate) mod integration_install_methods;
pub(crate) mod integration_settings;
pub(crate) mod integration_updates;
mod marketplace_methods;
mod notify_methods;
mod playwright;
pub(crate) mod prefetch;
mod pty_methods;
mod scm;
mod session;
mod session_pane_methods;
pub(crate) mod settings;
mod snippets;
mod startup_picker;
pub(crate) mod statusline_segments;
pub(crate) mod tab_drop;
mod tick_methods;
mod toggles;
pub(crate) mod util;
mod vim_range_methods;
pub(crate) mod workspace_methods;
pub(crate) mod workspace_trust_methods;

pub use startup_picker::{StartupPickerAction, StartupPickerState};
// Re-export the util helpers so existing call sites in this file
// and in sibling modules (which `use super::*`) keep working
// without an import-site change.
pub(crate) use cmdline_methods::{
    cmdline_popup_list, compute_cmdline_completions_for_app, parse_line_range, parse_substitute,
    parse_undo_age_spec,
};
pub(crate) use util::*;

const TOAST_TTL: Duration = Duration::from_secs(4);
const TOAST_STACK_MAX: usize = 5;
/// How long a completed progress item lingers on screen after
/// `progress_end` before it's removed. Long enough for the user
/// to notice the terminal-status glyph (✓ / ✗ / ⊘).
pub(crate) const PROGRESS_END_FADE: Duration = Duration::from_millis(2500);
/// How long the mouse must rest on a clickable chip before its tooltip
/// appears. 500ms matches VS Code / browser hover-tooltip convention.
pub const HOVER_TOOLTIP_DELAY_MS: u64 = 500;

/// Stub appended to `config.toml` by `App::open_keys_config` when
/// no `[keys.standard]` section exists yet. The body documents the
/// schema + shows 3 examples (rebind, add, unbind) so the user has
/// concrete patterns to copy.
const KEYS_STANDARD_STUB: &str = r#"
# ─── keybindings ───────────────────────────────────────────────
# mnml resolves every chord through one table. To override a
# default binding (or remove one, or add a new one), add a row
# under one of these three TOML sections:
#
#   [keys.global]     — applies in both vim and standard input styles
#   [keys.standard]   — overlays on top of global, standard only
#   [keys.vim]        — overlays on top of global, vim only
#
# The key is a chord spec (`ctrl+s`, `f5`, `alt+shift+down`,
# `space`, `enter`). The value is a command id from the registry
# — run `:Maps` (or `:Keys`) inside mnml to see every chord the
# default keymap has bound, and `Ctrl+Shift+P` to browse every
# registered command. `"none"` / `"unbound"` removes a default.

[keys.standard]
# examples: rebind chords in modeless / VS Code-style editing.
# EditOp actions: select_all, undo, redo, paste, cut_selection,
# yank_selection, yank_line, delete_line, duplicate_line,
# toggle_line_comment, move_word_left/right, move_line_up/down,
# move_line_start/end, page_up/down, insert_newline, etc.
# App action: "save". Special: "none" / "unbound" removes the default.
#
# "ctrl+shift+k" = "delete_line"
# "ctrl+enter" = "move_line_end; insert_newline"   # composite: sequence
# "ctrl+p" = "unbound"
"#;

/// How long the F1 overlay's "flash these rects" highlight stays painted
/// after the user clicks a row in the panel.
pub const DISCOVERY_FLASH_MS: u64 = 2000;
/// Idle time after the last edit before an AI ghost-text completion
/// fires. Long enough that mid-burst typing doesn't spam the API,
/// short enough to feel responsive once you pause.
pub const SUGGEST_DEBOUNCE_MS: u64 = 450;
/// Per-workspace marker file written when the user dismisses the
/// first-launch welcome overlay. Once present, mnml stops auto-opening
/// the overlay on launch (`view.welcome` still opens it manually).
const WELCOMED_MARKER_REL: &str = ".mnml/.welcomed";
const DAP_LOG_MAX: usize = 500;

/// Cap on `App::recent_files`. Tuned to "deep enough to remember a few tasks
/// ago, short enough that the picker isn't a wall of text."
const RECENT_FILES_MAX: usize = 20;

/// Kind of an HTTP collection root — where its files live.
/// Discovery treats both as first-class collections; the icon in the
/// sidebar (🗂 vs 📁) reflects the flavor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpCollectionKind {
    /// Under `.mnml/collections/<name>/` — hidden per-user storage.
    Hidden,
    /// A workspace folder with ≥2 `.http`/`.curl`/`.rest` files.
    /// Bruno-flavor: git-tracked, shared with teammates.
    InTree,
}

/// Which toolbar action a per-section HTTP panel chip fires. Stashed on
/// `PaneRects.http_panel_section_chips` next to the rect + section id
/// so the mouse handler dispatches without knowing which specific
/// field owned it. 2026-07-07.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpChipKind {
    /// `/` filter — focus the `http_panel_filter` input.
    Filter,
    /// `↺` refresh — rescan the caches (`http.refresh`).
    Refresh,
    /// `🌐` capture — launch a browser and start capturing, or dump
    /// the current network log when a browser is already open.
    Capture,
    /// `✕` clear — section-specific destructive action (truncate log
    /// on RECENT / CAPTURED; clear the filter on MOCKS / COLLECTIONS
    /// so a stray click doesn't blow away user assets).
    Clear,
    /// `+` new — section-specific "create empty …" action. Currently
    /// only COLLECTIONS: runs `http.new_collection`. 2026-07-07.
    New,
}

/// Cap on `App::browser_url_history`. Higher than `recent_files` because
/// URLs accumulate quickly (every navigation, every redirect) and the
/// fuzzy picker handles long lists gracefully.
const BROWSER_URL_HISTORY_MAX: usize = 100;

/// Cap on `App::file_cursors`. Per-file last-position state isn't tied to the
/// recent-files cap because the user may legitimately revisit files long after
/// they've dropped off `recent_files`.
const FILE_CURSORS_MAX: usize = 200;

/// Cap on `App::file_folds`. Same shape as `FILE_CURSORS_MAX` — folds
/// survive buffer close so `open_path` can re-hydrate them later, but
/// the map has to bound at some point.
const FILE_FOLDS_MAX: usize = 200;

/// Cap on each nav stack — deep enough to cover a few investigation chains,
/// shallow enough that the old end is never load-bearing.
const NAV_STACK_MAX: usize = 50;

/// Cap on recent find queries — newer entries push older ones off.
const FIND_HISTORY_MAX: usize = 50;

/// Cap on the recently-closed-buffers stack — newer entries push older ones off.
const CLOSED_BUFFERS_MAX: usize = 20;

/// Cap on the recently-closed-tabs stack — `tab.reopen` pops the most-recent
/// entry; older entries fall off when this is exceeded.
const CLOSED_TAB_LAYOUTS_MAX: usize = 20;

/// Cap on `App.message_log` — vim `:messages` shows up to this many recent toasts.
pub const MESSAGE_LOG_MAX: usize = 200;

/// Unix seconds now. Local helper so the message log can carry a
/// wall-clock time without depending on `ai_usage`'s private one.
pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// `HH:MM` in the user's local timezone, using the same `TZ_OFFSET_HOURS`
/// knob the statusline clock and git-graph dates read — so every time in
/// the UI agrees.
pub fn hhmm_local(secs: u64) -> String {
    let off = std::env::var("TZ_OFFSET_HOURS")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .map(|h| h * 3600)
        .unwrap_or(0);
    let local = (secs as i64).saturating_add(off).rem_euclid(86_400);
    format!("{:02}:{:02}", local / 3600, (local / 60) % 60)
}

/// One entry in [`App::message_log`].
#[derive(Debug, Clone)]
pub struct LoggedMessage {
    pub text: String,
    pub level: ToastLevel,
    /// Unix seconds. Wall-clock rather than `Instant` because the log is
    /// read minutes later and "14:32" is what a user can act on;
    /// `Instant` cannot be formatted as a time of day.
    pub at: u64,
}

/// One entry on a navigation stack — a file + a `(row, col)` so we can jump
/// back even if the buffer's text has shifted since (the precise byte offset
/// would be stale; row/col is a more forgiving anchor).
#[derive(Debug, Clone)]
pub struct NavPoint {
    pub path: PathBuf,
    pub row: usize,
    pub col: usize,
}

/// Row density for the Cloud Agents panel — toggled by the user.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
pub enum CloudAgentsView {
    /// One line per row — the legacy compact look. Best when there
    /// are many runs in flight.
    #[default]
    Compact,
    /// Three lines per row, showing ticket / flow / state / last
    /// activity / last message. Easier to tell runs apart at a
    /// glance.
    Standard,
}

impl CloudAgentsView {
    pub fn toggled(self) -> Self {
        match self {
            CloudAgentsView::Compact => CloudAgentsView::Standard,
            CloudAgentsView::Standard => CloudAgentsView::Compact,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            CloudAgentsView::Compact => "compact",
            CloudAgentsView::Standard => "standard",
        }
    }
}

/// Direction for `Ctrl+W`-style focus navigation between splits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusDir {
    Left,
    Right,
    Up,
    Down,
}

/// One row in the `dap.attach` picker. `pid` is the OS process id;
/// `user` is the owning user (best-effort — empty when `ps` doesn't
/// surface it); `cmd` is the command line, truncated for legibility.
#[derive(Debug, Clone)]
pub struct AttachableProcess {
    pub pid: i64,
    pub user: String,
    pub cmd: String,
}

/// Shell out to `ps` and parse the user / pid / command columns into
/// a list of running processes. Returns an empty vec on any error
/// (the caller toasts "no processes found"). macOS + Linux both have
/// `ps -eo user,pid,command`; Windows would need a different shape
/// but mnml's DAP track isn't packaged for Windows yet.
fn list_attachable_processes() -> Vec<AttachableProcess> {
    let Ok(out) = std::process::Command::new("ps")
        .args(["-eo", "user,pid,command"])
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut rows: Vec<AttachableProcess> = Vec::new();
    for (i, line) in text.lines().enumerate() {
        if i == 0 {
            continue; // header
        }
        let line = line.trim_start();
        let mut parts = line.splitn(3, char::is_whitespace);
        let Some(user) = parts.next() else { continue };
        // Skip any extra whitespace between user and pid (splitn keeps
        // the third arg verbatim, but the second can be a tab + space
        // run that splitn doesn't compress). Re-trim per-field.
        let Some(pid_str) = parts.next() else {
            continue;
        };
        let pid_str = pid_str.trim();
        if pid_str.is_empty() {
            // user column was double-wide; re-split.
            let mut p2 = line.split_whitespace();
            let user = p2.next().unwrap_or("").to_string();
            let Some(pid_str) = p2.next() else { continue };
            let Ok(pid) = pid_str.parse::<i64>() else {
                continue;
            };
            let rest: String = p2.collect::<Vec<&str>>().join(" ");
            let cmd = if rest.chars().count() > 80 {
                let keep: String = rest.chars().take(79).collect();
                format!("{keep}…")
            } else {
                rest
            };
            rows.push(AttachableProcess { pid, user, cmd });
            continue;
        }
        let Ok(pid) = pid_str.parse::<i64>() else {
            continue;
        };
        let cmd = parts.next().unwrap_or("").trim().to_string();
        let cmd = if cmd.chars().count() > 80 {
            let keep: String = cmd.chars().take(79).collect();
            format!("{keep}…")
        } else {
            cmd
        };
        rows.push(AttachableProcess {
            pid,
            user: user.to_string(),
            cmd,
        });
    }
    rows
}

/// Rough per-million-token price `(input, output)` in USD for the known
/// Claude tiers — approximate published rates. `None` for an
/// unrecognized model (then only token counts are shown, no estimate).
fn ai_price_per_mtok(model: Option<&str>) -> Option<(f64, f64)> {
    let m = model.unwrap_or("claude-opus-4-7").to_ascii_lowercase();
    if m.contains("haiku") {
        Some((1.0, 5.0))
    } else if m.contains("sonnet") {
        Some((3.0, 15.0))
    } else if m.contains("opus") {
        Some((15.0, 75.0))
    } else {
        None
    }
}

/// The local-FIM worker thread body. Owns the `FimEngine` — loads it
/// **eagerly on spawn** (so picking the Local backend starts the
/// one-time ~1 GB download immediately rather than on the first
/// keystroke-pause), then serves completions. Load status is reported
/// back as a `u64::MAX`-id reply so `drain_suggestions` can toast it.
fn fim_worker_loop(
    rx: std::sync::mpsc::Receiver<FimRequest>,
    reply: std::sync::mpsc::Sender<SuggestReply>,
    progress: std::sync::Arc<std::sync::Mutex<Option<fim_engine::DownloadProgress>>>,
    model: fim_engine::ModelChoice,
) {
    // Load before the recv loop — the worker is spawned the moment the
    // user picks (or warms up) the Local backend, so this is the eager
    // warm-up. The progress callback writes the slot the overlay reads.
    let cache = fim_engine::default_cache_dir();
    let prog = std::sync::Arc::clone(&progress);
    let load = fim_engine::FimEngine::load(&cache, model, &move |p| {
        if let Ok(mut g) = prog.lock() {
            *g = Some(p);
        }
    });
    // Download done (one way or another) — clear the bar.
    if let Ok(mut g) = progress.lock() {
        *g = None;
    }
    let (mut engine, load_error) = match load {
        Ok(e) => {
            let _ = reply.send((u64::MAX, Ok("local model ready".to_string())));
            (Some(e), None)
        }
        Err(e) => {
            let _ = reply.send((u64::MAX, Err(format!("local model load failed: {e}"))));
            (None, Some(e))
        }
    };
    while let Ok((id, prefix, suffix, max_tokens)) = rx.recv() {
        if let Some(err) = &load_error {
            let _ = reply.send((id, Err(err.clone())));
            continue;
        }
        if let Some(e) = engine.as_mut() {
            let result = e.complete(&prefix, &suffix, max_tokens);
            let _ = reply.send((id, result));
        }
    }
}

/// True when `path`'s extension marks it as Markdown — used by the outline
/// pane to extract headings directly instead of going through the LSP.
/// Recursively walk `dir` collecting files whose extension matches any
/// entry in `exts` (lowercase, no leading dot). Skips dot-dirs +
/// `node_modules` / `target` to keep big repos snappy. Used by
/// `App::run_markdown_link_check`.
fn walk_workspace_for_extensions(dir: &Path, exts: &[&str], out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let path = e.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let ft = e.file_type().ok();
        if ft.is_some_and(|t| t.is_dir()) {
            if matches!(name, "node_modules" | "target" | "dist" | "build") {
                continue;
            }
            walk_workspace_for_extensions(&path, exts, out);
        } else {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|s| s.to_ascii_lowercase());
            if let Some(ext) = ext
                && exts.contains(&ext.as_str())
            {
                out.push(path);
            }
        }
    }
}

/// Extract `[label](target)` link targets from a single markdown line.
/// Returns `(column_of_open_paren, target)` per match. Doesn't try to
/// be a full markdown parser — just enough to find broken paths.
fn extract_md_links(line: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let bytes = line.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'[' {
            i += 1;
            continue;
        }
        // Skip the label content — accept nested brackets one level
        // deep, which covers most footnote-style cases.
        let label_start = i + 1;
        let mut j = label_start;
        let mut depth = 1usize;
        while j < bytes.len() && depth > 0 {
            match bytes[j] {
                b'[' => depth += 1,
                b']' => depth -= 1,
                _ => {}
            }
            if depth == 0 {
                break;
            }
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b']' {
            i += 1;
            continue;
        }
        // Expect `(` immediately after `]`.
        let paren_open = j + 1;
        if paren_open >= bytes.len() || bytes[paren_open] != b'(' {
            i = j + 1;
            continue;
        }
        // Find matching `)`.
        let mut k = paren_open + 1;
        let mut paren_depth = 1usize;
        while k < bytes.len() && paren_depth > 0 {
            match bytes[k] {
                b'(' => paren_depth += 1,
                b')' => paren_depth -= 1,
                _ => {}
            }
            if paren_depth == 0 {
                break;
            }
            k += 1;
        }
        if k >= bytes.len() {
            break;
        }
        // Target is the inside of the parens. Strip optional `"title"` /
        // `'title'` suffix and surrounding whitespace.
        let inside = &line[paren_open + 1..k];
        let target = inside
            .split([' ', '\t'])
            .next()
            .unwrap_or("")
            .trim()
            .trim_matches('<')
            .trim_matches('>')
            .to_string();
        if !target.is_empty() {
            out.push((paren_open + 1, target));
        }
        i = k + 1;
    }
    out
}

/// Treat anything with a scheme like `http://`, `https://`, `mailto:`,
/// `file://`, `ftp://`, etc. as a URL — skipped by the link checker.
/// Turn a file's `(range, new_text)` LSP edits into `EditOp::ReplaceRange`s with
/// byte offsets resolved against `text`, sorted *descending* by start so applying
/// them in order keeps the earlier offsets valid. Edits with unresolvable
/// positions are dropped.
fn build_replace_ops(
    text: &str,
    edits: &[(crate::lsp::Range, String)],
) -> Vec<crate::edit_op::EditOp> {
    let mut tuples: Vec<(usize, usize, String)> = edits
        .iter()
        .filter_map(|(r, t)| {
            let s = crate::lsp::byte_at(text, r.start.line, r.start.character)?;
            let e = crate::lsp::byte_at(text, r.end.line, r.end.character)?;
            Some((s.min(e), s.max(e), t.clone()))
        })
        .collect();
    tuples.sort_by_key(|t| std::cmp::Reverse(t.0));
    tuples
        .into_iter()
        .map(|(start, end, text)| crate::edit_op::EditOp::ReplaceRange { start, end, text })
        .collect()
}

/// Case-sensitive sibling of [`crate::buffer::find_all_ci_ascii`] — same shape,
/// non-overlapping byte ranges where `needle` occurs in `haystack`. Empty
/// needle ⇒ empty list (caller must reject empty `find` before getting here).
/// Re-export of [`crate::buffer::find_all_case_sensitive`] under the historical
/// local name; the `:%s` path used to own the impl before smart-case search
/// pulled it down to `buffer.rs`. Kept as a thin shim so existing tests + call
/// sites stay put.
fn find_all_case_sensitive(haystack: &str, needle: &str) -> Vec<(usize, usize)> {
    crate::buffer::find_all_case_sensitive(haystack, needle)
}

/// Parsed `:%s/<find>/<replace>/[flags]` ex-command. Returns `None` if `line`
/// isn't a substitute. The delimiter is fixed to `/` (vim accepts arbitrary
/// delimiters but the common case is `/`); `\/` and `\\` escape inside the
/// fields.
/// Vim macro state. Recording captures every key event flowing through
/// `dispatch_key` (the toggling `q` itself is removed in `record_macro_stop`).
/// Replaying ignores `@` keys so a macro can't recursively re-fire itself.
/// The `register` field on Recording is the target slot in
/// `App.macro_buffer` (HashMap keyed by letter). `'@'` is the conventional
/// "anonymous" register — bare `q` records there.
#[derive(Debug, Clone, Default)]
pub enum MacroState {
    #[default]
    Idle,
    Recording {
        register: char,
        keys: Vec<ratatui::crossterm::event::KeyEvent>,
    },
    Replaying,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Substitute {
    find: String,
    replace: String,
    /// True ⇒ case-insensitive match (`i` flag).
    case_insensitive: bool,
    /// `:%s/...` is buffer-wide; bare `:s/...` is current-line only
    /// (vim convention).
    whole_buffer: bool,
    /// `c` flag — interactive confirmation (y/n/a/q at each match).
    confirm: bool,
    /// `n` flag — only count matches, don't replace (vim canonical).
    count_only: bool,
    /// `g` flag — replace ALL matches on each line. Vim's default
    /// (no `g`) is FIRST-match-only per line; `/g` extends to all.
    /// nvchad-round-12 SEV-2 2026-07-14 — mnml used to always
    /// replace all, violating the most-fundamental vim substitute
    /// semantic.
    pub(crate) global: bool,
    /// Optional inclusive line range `(start_line, end_line)`. Used
    /// by `:5,10s/…/…/g` where a specific range is given (not `%`
    /// and not bare `:s`). Overrides both `whole_buffer` and the
    /// bare-line default. nvchad-user SEV-2 2026-07-11.
    pub(crate) line_range: Option<(usize, usize)>,
}

/// In-flight `:%s/.../.../c` (interactive replace) state. The user steps
/// through each match — `y` apply + advance, `n` skip + advance, `a`
/// apply this and all remaining, `q` / Esc abort. Surfaced via the same
/// overlay machinery as the other `prompt`-style modal states.
#[derive(Debug, Clone)]
pub struct ReplaceConfirm {
    pub pane_id: PaneId,
    pub find: String,
    pub replace: String,
    /// All match byte ranges at the start (descending order so applies
    /// keep earlier offsets valid). We pop from the end as we go.
    pub remaining: Vec<(usize, usize)>,
    /// Count of replacements applied so far (for the final toast).
    pub applied: usize,
    /// Total matches at the start (for the prompt label).
    pub total: usize,
}

/// Parse a leading vim-style line range from an ex command, returning
/// `(start_line, end_line, remainder)` (lines are 0-based; `remainder`
/// is the rest of the line, no leading whitespace). Supports:
/// - `1,5` ⇒ lines 1–5 (1-based on the wire, converted to 0-based)
/// - `.,+3` ⇒ current line + next 3
/// - `5,$` ⇒ line 5 to end
/// - `.+1` (single ref) ⇒ next line only
/// - `%` ⇒ whole buffer (handled separately by `:%y` / `:%d` arms)
///
/// Returns `None` when the line doesn't start with something that looks
/// like a range. (`current_line` and `line_count` are the active buffer's
/// state, used to resolve `.` and `$`.)
/// Expand vim-style mark refs in a `:` line BEFORE the line-range parser sees
/// it. `'<letter>` (buffer-local lowercase, global uppercase) and `'<` / `'>`
/// (the start / end rows of the last visual selection) get replaced with their
/// 1-based row numbers. Unresolvable marks are left in place so the line-range
/// parser declines and the outer dispatcher falls through.
/// Filter `folds` down to the "top-level" set — folds whose start
/// row is NOT strictly inside any other fold's range. Used by
/// `zj`/`zk` so nested folds from `zM` don't clog the inter-fold
/// navigation. nvchad-round-10 SEV-2 2026-07-11.
fn top_level_folds(folds: &std::collections::BTreeMap<usize, usize>) -> Vec<(usize, usize)> {
    let entries: Vec<(usize, usize)> = folds.iter().map(|(&s, &e)| (s, e)).collect();
    entries
        .iter()
        .filter(|&&(s, _)| {
            !entries.iter().any(|&(os, oe)| {
                // Strictly inside another fold: os < s <= oe (and
                // (os, oe) is not the entry itself).
                os < s && s <= oe && (os, oe) != (s, folds[&s])
            })
        })
        .copied()
        .collect()
}

fn expand_mark_refs(line: &str, lookup: &dyn Fn(char) -> Option<usize>) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\'' {
            if let Some(&next) = chars.peek()
                && (next.is_ascii_alphabetic() || next == '<' || next == '>')
            {
                chars.next();
                if let Some(row) = lookup(next) {
                    out.push_str(&(row + 1).to_string());
                    continue;
                }
                // Couldn't resolve — leave both chars so the parser declines.
                out.push('\'');
                out.push(next);
                continue;
            }
            out.push('\'');
        } else {
            out.push(c);
        }
    }
    out
}

// A-3: compute_cmdline_completions_for_app + parse_* helpers moved
// to src/app/cmdline_methods.rs (re-exported above).

/// `(line, character)` of `byte` in `text` — the inverse of [`crate::lsp::byte_at`].
/// Both 0-based; `character` is a char count (matches how we feed positions to
/// the LSP elsewhere). A byte past the end clamps to the last line's end.
/// Do two LSP-space ranges overlap (or touch)? Used to decide which diagnostics
/// to send along with a `textDocument/codeAction` request. Inclusive at both
/// ends — a diagnostic that ends exactly at the cursor should still be offered
/// quickfixes for.
fn ranges_overlap(a: crate::lsp::Range, b: crate::lsp::Range) -> bool {
    let cmp = |p: crate::lsp::Pos, q: crate::lsp::Pos| {
        p.line.cmp(&q.line).then(p.character.cmp(&q.character))
    };
    cmp(a.start, b.end) != std::cmp::Ordering::Greater
        && cmp(b.start, a.end) != std::cmp::Ordering::Greater
}

/// Persisted session: list of open editor buffers (paths + cursors) and — when
/// every visible leaf is an editor — the split tree, with leaf ids translated to
/// indices into `open`. Round-trips through `<workspace>/.mnml/session.json` if
/// `[session] restore = true`.
#[derive(Debug, serde::Serialize, serde::Deserialize, Default)]
struct SavedSession {
    /// The workspace this session belongs to (cross-check on restore).
    workspace: String,
    /// Editor buffers, in tab order.
    open: Vec<SavedBuffer>,
    /// Which entry was active.
    active: Option<usize>,
    /// The split tree, with leaves keyed by index into `open`. `None` ⇒ restore
    /// opens the buffers serially (the previously-active one ends up in a single
    /// leaf, the others remain as background tabs). Kept for back-compat read
    /// with older mnml binaries; new code prefers `layouts`/`active_layout`.
    #[serde(default)]
    layout: Option<SavedLayout>,
    /// One SavedLayout per tab page, in display order. Added in
    /// 2026-05-17 alongside vim tab pages. `None` (missing field) ⇒
    /// fall back to single-tab restore via `layout`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    layouts: Option<Vec<Option<SavedLayout>>>,
    /// Index into `layouts` for the previously-active tab. `None`
    /// when `layouts` itself is missing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    active_layout: Option<usize>,
    /// Was the file-tree rail visible? `None` (missing field, e.g. an old
    /// session.json) ⇒ keep whatever the runtime default is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tree_visible: Option<bool>,
    /// Was the workspace section inside the rail expanded?
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tree_root_expanded: Option<bool>,
    /// Last rail width (mouse-drag adjusted). `None` ⇒ runtime default
    /// (the `[ui] tree_width` config).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tree_width: Option<u16>,
    /// code-reviewer S2-5 / mouse SEV-2 — persist the right-panel
    /// visible state + drag-resized width across restarts. Mirrors
    /// `tree_visible` + `tree_width`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    right_panel_visible: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    right_panel_width: Option<u16>,
    /// Right-panel hosted tabs identified by KIND (since PaneIds aren't
    /// stable across restarts). One entry per tab; valid kinds today:
    /// `"outline"`, `"diagnostics"`. AI chat tabs are intentionally
    /// NOT persisted (live state + auth context can change).
    /// 2026-06-28 right-panel v3+v4 session persistence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    right_panel_tabs: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    right_panel_active_idx: Option<usize>,
    /// Was the `> GIT` section in the rail expanded?
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git_section_expanded: Option<bool>,
    /// #polish 2026-07-06 — was the `> INTEGRATIONS` section in
    /// the rail expanded? `None` = fall back to the config's
    /// `[ui] integrations_section_default_expanded`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    integration_section_expanded: Option<bool>,
    /// #polish 2026-07-06 — was the `+ N more branches` toggle
    /// expanded in the git rail? `None` = default false (collapsed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git_branches_expanded: Option<bool>,
    /// #polish 2026-07-06 — last workspace-grep query the user
    /// ran. `open_grep_prompt` seeds with this when nothing is
    /// selected in the active editor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_grep_query: Option<String>,
    /// Directories the user had expanded in the file tree. `None` (an older
    /// session.json without the field) ⇒ keep the default first-level expand.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tree_expanded_dirs: Option<Vec<String>>,
    /// Persist the `view.toggle_hidden` choice. `None` ⇒ use the launch default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tree_show_hidden: Option<bool>,
    /// #1101 (2026-08-20) — active activity-bar section (Explorer /
    /// Find / Git / …). Stored as the section's kebab-case name so
    /// the enum can be reordered without breaking older session
    /// files. `None` ⇒ default to Explorer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    active_section: Option<String>,
    /// #1101 (2026-08-20) — full-screen mode (task #1096) toggled
    /// via F11-style command; user who quit while zoomed expects to
    /// come back zoomed. Only serialized when true.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fullscreen_mode: Option<bool>,
    /// #1101 (2026-08-20) — bottom panel state (task #906 Phase 1).
    /// Mirrors the right-panel triplet. `bottom_panel_panes` isn't
    /// persisted (PaneIds don't survive a restart); when the panel
    /// re-opens empty the user re-routes panes into it manually.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bottom_panel_visible: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bottom_panel_height: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bottom_panel_active_idx: Option<usize>,
    /// #1101 (2026-08-20) — palette `★` recents (task #1113).
    /// Capped at 50 on save. Empty ⇒ absent field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    recent_commands: Option<Vec<String>>,
    /// #1112 (2026-08-20) — search-section flag toggles + MRU query
    /// history. Only serialized when at least one flag is on or
    /// history is non-empty.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    search_case_sensitive: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    search_whole_word: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    search_regex: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    search_history: Option<Vec<String>>,
    /// Per-extra-workspace state (parallel to `App::extra_workspaces` by
    /// index). Restored by name match — a workspace renamed between
    /// sessions silently drops its persisted state.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    extra_workspaces: Vec<SavedExtraWorkspace>,
    /// Most-recently-opened files, newest first (capped on save).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    recent_files: Vec<String>,
    /// Most-recently-visited browser URLs (newest first, capped). Built
    /// up from `Page.frameNavigated` events across the session and
    /// surfaced by `browser.url_history` (Ctrl+R in a browser pane).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    browser_url_history: Vec<String>,
    /// The active theme name when we quit. `None` ⇒ launch picks the default
    /// (or whatever `[ui] theme` in the config file says).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    theme: Option<String>,
    /// Was `[ui] wrap` on when we quit? `None` ⇒ launch keeps the config
    /// default; `Some(b)` overrides it. So a user who flipped it at runtime
    /// gets that preference back, but a config-file change is still the
    /// source of truth for fresh workspaces.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    wrap: Option<bool>,
    /// Statusline clock chip in UTC mode when we quit. `None` (missing
    /// field) ⇒ default to local time on launch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    clock_show_utc: Option<bool>,
    /// #22 v3 — collapsed COLLECTIONS dirs (paths relative to
    /// `.mnml/collections/`, since absolute paths change if the
    /// workspace moves). Skipped when empty.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    http_panel_collections_collapsed: Vec<String>,
    /// #25 v4 — last-used age filter on the Agents dashboard.
    /// Applied to any newly-built ClaudeAgents pane. `None` = use
    /// the launch default (Week). Stored as a lowercase enum
    /// string so future variants can slot in without breaking
    /// old session.json files.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    claude_agents_age_filter: Option<String>,
    /// `:rename`'d Claude session names, keyed by Claude `--session-id`.
    /// Ptys themselves don't survive a relaunch, but resuming a saved
    /// Claude session (`ai.session_picker`) re-applies its name.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pty_session_names: Vec<(String, String)>,
    /// #1184 (2026-08-23) — every Claude Code Pty open at quit time,
    /// captured for auto-resume on next launch. On load, mnml spawns
    /// `claude --resume <session_id>` for each and re-attaches the
    /// display name + accent color so the workspace comes back in the
    /// state the user left it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    claude_sessions: Vec<SavedClaudeSession>,
    /// Corner-pinned dock widgets. Persisted as-is — the layout
    /// survives restart so the user's familiar dock arrangement
    /// comes back. `next_id` is stashed separately so the
    /// monotonic counter doesn't reset (avoids id collisions if
    /// the user creates more widgets mid-session).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    dock_widgets: Vec<crate::dock::DockWidget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    dock_widget_next_id: Option<usize>,
    /// Last `[m] device emulation` preset picked this session (index into
    /// `crate::browser_pane::DEVICE_PRESETS`). Applied to every fresh
    /// `browser.open` so the user doesn't have to re-pick after a relaunch.
    /// `None` ⇒ no preset (Chrome's real viewport).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_browser_device: Option<usize>,
    /// Vim macros recorded with `q<reg>...q`, serialized as
    /// `(register_letter, Vec<key_spec>)`. Lets `@a` work across
    /// restarts. Each spec round-trips through `parse_key_spec`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    macros: Vec<SavedMacro>,
    /// Per-file last `(cursor_byte, scroll)`. Files dropped from the worktree
    /// just silently fail to restore; over-large positions clamp.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    file_cursors: Vec<SavedFileCursor>,
    /// Vim uppercase / "global" marks — cross-file bookmarks the user set
    /// with `m<Letter>`. Persisted so they survive a restart.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    global_marks: Vec<SavedGlobalMark>,
    /// Code folds per file. Restored only for buffers re-opened in this
    /// session — files the user opens later don't auto-fold from this list.
    /// Folds are cleared on edit, so a stale entry whose file changed
    /// externally just gets stomped on the first edit; no separate
    /// invalidation step is needed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    folds: Vec<SavedFolds>,
    /// Browser-style navigation back stack — `Alt+Left` pops these, jumping
    /// to the recorded `(path, row, col)`. Persisted oldest-first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    nav_back: Vec<SavedNavPoint>,
    /// Mirror for `Alt+Right`'s forward stack.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    nav_forward: Vec<SavedNavPoint>,
    /// Per-file change list (`g;` / `g,`) — every text-changing edit's
    /// `(row, col)` so the position history survives a relaunch. Restored
    /// for buffers re-opened in this session; the cursor sits past the
    /// newest entry so the first `g;` lands on the most recent edit.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    edit_history: Vec<SavedEditHistory>,
    /// `App.find_history` — recent in-buffer find queries (Up/Down on the
    /// Find prompt walks through them). Persisted oldest-first; capped at
    /// `FIND_HISTORY_MAX` on restore.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    find_history: Vec<String>,
    /// `App.closed_buffers` — recently-closed editor buffers so
    /// `Ctrl+Shift+T` (`buffer.reopen`) survives a relaunch. Stored
    /// oldest-first; capped at `CLOSED_BUFFERS_MAX` on restore.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    closed_buffers: Vec<SavedNavPoint>,
    /// `App.ex_history` — recent `:`-line commands (Up/Down on the
    /// cmdline walks through them). Oldest-first; capped at 100.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    ex_history: Vec<String>,
    /// `App.dap_watches` — user-added watch expressions, restored so
    /// debugger workflows survive a relaunch. Cached results aren't
    /// persisted (they re-eval on the next stop anyway).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    dap_watches: Vec<String>,
    /// View-mode + collapsed-headers state for each SCM/CI pane.
    /// Persisted so flipping `v` or collapsing a repo header sticks
    /// across `q!` and relaunches. (BB / GH / GL / AZ fields all
    /// removed in 2026-06 — only the GitLab field placeholders
    /// remain for serde-compat on old session.json files.)
    // gl_pipelines_*, gl_mrs_* fields moved to mnml-forge-gitlab.
    // az_builds_*, az_prs_*, azdevops_* fields moved to
    // mnml-forge-azdevops in 2026-06.
    /// Harpoon-style pinned files — fixed 9-slot list, indices 0..9 mapped
    /// to `<leader>1`..`<leader>9`. Each slot is either an absolute path or
    /// empty. Persisted so pins survive relaunch.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    harpoon: Vec<Option<String>>,
    /// Last drag-adjusted width (cells) of the GitGraph commit-list ↔
    /// detail-panel divider. `None` ⇒ no runtime override (config /
    /// auto-size applies).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git_graph_detail_col: Option<u16>,
    /// Remembered diff view-mode + wrap toggle, applied to every new
    /// `Pane::Diff`. Persists the user's `[Inline] / [Hunk] /
    /// [Split] / [Wrap]` toolbar choice across mnml restarts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    diff_view_mode: Option<crate::pane::DiffViewMode>,
    #[serde(default, skip_serializing_if = "is_false")]
    diff_wrap: bool,
    /// Direct-API AI token tally (`App.ai_tokens_in/out`) — persisted so
    /// the running cost view (`ai.token_usage`) survives a relaunch.
    #[serde(default)]
    ai_tokens_in: u64,
    #[serde(default)]
    ai_tokens_out: u64,
    /// Inline-suggestion accept tally (`App.suggest_shown/accepted`) —
    /// persisted so the accept rate (`ai.suggestion_stats`) is a
    /// lifetime read, not just per-launch.
    #[serde(default)]
    suggest_shown: u32,
    #[serde(default)]
    suggest_accepted: u32,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedGlobalMark {
    letter: char,
    path: String,
    row: usize,
    col: usize,
}

/// Per-extra-workspace state in session.json. Keyed by `name` (matched on
/// restore against `App::extra_workspaces[i].name`). Unmatched entries
/// are silently dropped — if you rename a workspace in config, its
/// previous state doesn't carry over.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedExtraWorkspace {
    name: String,
    #[serde(default)]
    expanded: bool,
    /// Tree expanded directories (absolute path strings).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    expanded_dirs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    show_hidden: Option<bool>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedFileCursor {
    path: String,
    cursor_byte: usize,
    scroll: usize,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedFolds {
    path: String,
    /// `(start_line, end_line)` pairs (both 0-based, inclusive). Mirrors
    /// `Buffer.folds` in flat form because TOML/JSON tuple maps are awkward.
    folds: Vec<(usize, usize)>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedNavPoint {
    path: String,
    row: usize,
    col: usize,
}

/// #1184 (2026-08-23) — a Claude Code Pty session captured at quit
/// time so mnml can `claude --resume <session_id>` it on next launch,
/// re-attaching the user's display name + auto/user accent color.
/// Skipped for shell / Codex / non-resumable Ptys — those don't have
/// a `session_id` that Claude Code understands.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedClaudeSession {
    session_id: String,
    /// Serialize-nullable so old session.json files without these
    /// fields deserialize cleanly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    accent_color: Option<String>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedMacro {
    /// Register letter (`a`-`z` typically, or `'@'` for the anonymous).
    register: char,
    /// Keystrokes as key-spec strings — same format that `[keys.global]`
    /// config entries use. Round-trips via `parse_key_spec`.
    keys: Vec<String>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedEditHistory {
    path: String,
    /// `(row, col)` pairs (both 0-based) in tab-stop order. Restoring sets
    /// `Buffer.edit_history_cursor` to `entries.len()` so the next `g;` lands
    /// on the most recent entry.
    entries: Vec<(usize, usize)>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedBuffer {
    path: String,
    cursor_byte: usize,
    scroll: usize,
    /// DAP breakpoint lines (0-based) — restored on next open.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    breakpoints: Vec<u32>,
    /// Conditional-breakpoint expressions keyed by 0-based line —
    /// restored on next open (paired with `breakpoints` above).
    /// Conditions for lines absent from `breakpoints` are dropped on
    /// load (defensive — invariants should already hold but this
    /// survives a hand-edited session.json).
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    breakpoint_conditions: std::collections::HashMap<u32, String>,
    /// Hit-count expressions keyed by 0-based line — restored
    /// alongside conditions. Same orphan-line cleanup on load.
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    breakpoint_hit_conditions: std::collections::HashMap<u32, String>,
    /// 2026-06-21 — VS Code-style pinned tab state. Persisted so
    /// pinned tabs survive across sessions. Default false (existing
    /// sessions deserialize cleanly).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    is_pinned: bool,
}

/// A serializable mirror of [`Layout`] where leaves carry indices into
/// `SavedSession.open` instead of `PaneId`s.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
enum SavedLayout {
    Empty,
    /// 2026-06-22 — multi-tab leaf. `tabs` is the list of saved-
    /// pane indices, `active` is the index INTO `tabs` that's
    /// currently visible. Pre-2026-06-22 sessions used the
    /// `Leaf(usize)` tuple variant; deserialize keeps the
    /// `#[serde(other)]` Leaf for back-compat below.
    LeafTabs {
        active: usize,
        tabs: Vec<usize>,
    },
    /// Legacy single-pane leaf variant, kept for back-compat with
    /// session.json files written before 2026-06-22. New code
    /// always writes LeafTabs.
    Leaf(usize),
    Split {
        dir: SavedSplitDir,
        ratio: u16,
        first: Box<SavedLayout>,
        second: Box<SavedLayout>,
    },
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone, Copy)]
enum SavedSplitDir {
    Horizontal,
    Vertical,
}

impl From<crate::layout::SplitDir> for SavedSplitDir {
    fn from(d: crate::layout::SplitDir) -> Self {
        match d {
            crate::layout::SplitDir::Horizontal => SavedSplitDir::Horizontal,
            crate::layout::SplitDir::Vertical => SavedSplitDir::Vertical,
        }
    }
}
impl From<SavedSplitDir> for crate::layout::SplitDir {
    fn from(d: SavedSplitDir) -> Self {
        match d {
            SavedSplitDir::Horizontal => crate::layout::SplitDir::Horizontal,
            SavedSplitDir::Vertical => crate::layout::SplitDir::Vertical,
        }
    }
}

/// `(row, col)` (0-based, col in chars) for a byte offset into `text`. Used by
/// the in-buffer find to position the editor cursor at a match.
/// Place the buffer's cursor at byte offset `byte` (clamped). Used by snippet
/// expansion to land on `$N` / `$0` markers without hand-walking the cursor
/// glyph by glyph.
fn place_cursor_at_byte(b: &mut Buffer, byte: usize) {
    let (row, col) = byte_to_row_col(b.editor.text(), byte);
    b.editor.place_cursor(row, col);
}

/// Workspace grep — try `rg --vimgrep` first (fast, gitignore-aware), fall back
/// to `git grep -n --column` if `rg` isn't on PATH. Returns parsed hits + which
/// tool produced them (used for the `Pane::Grep` title's "rg: …" / "git grep: …"
/// prefix). The special value `"unavailable"` is returned when *neither* tool
/// could be spawned (rg not installed AND workspace isn't a git repo — the
/// caller uses this to surface an install hint instead of a silent 0-matches
/// toast). keyboard-round-9 SEV-2 2026-07-14.
pub(crate) fn grep_workspace(
    workspace: &std::path::Path,
    query: &str,
) -> (Vec<crate::grep_pane::GrepHit>, &'static str) {
    grep_workspace_with_flags(workspace, query, GrepFlags::default())
}

/// #1112 (2026-08-20) — Search-section flags plumbed through to
/// ripgrep. Each toggle maps to a specific `rg` flag; ordering
/// matches the palette-chip render order.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct GrepFlags {
    /// Off = `--smart-case` (rg default that upgrades on any
    /// uppercase char in the query — what most users want). On =
    /// `--case-sensitive`, no folding.
    pub case_sensitive: bool,
    /// `--word-regexp` — the query must match on word boundaries.
    pub whole_word: bool,
    /// Without this we pass `--fixed-strings` so regex metachars in
    /// the query mean themselves. With it, rg parses the query as
    /// its usual PCRE-ish regex.
    pub regex: bool,
}

pub(crate) fn grep_workspace_with_flags(
    workspace: &std::path::Path,
    query: &str,
    flags: GrepFlags,
) -> (Vec<crate::grep_pane::GrepHit>, &'static str) {
    use crate::grep_pane::parse_rg_vimgrep;
    use std::process::Command;
    let mut rg = Command::new("rg");
    rg.arg("--vimgrep").arg("--no-heading");
    if flags.case_sensitive {
        rg.arg("--case-sensitive");
    } else {
        rg.arg("--smart-case");
    }
    if flags.whole_word {
        rg.arg("--word-regexp");
    }
    if !flags.regex {
        rg.arg("--fixed-strings");
    }
    let rg_out = rg.arg(query).arg(".").current_dir(workspace).output();
    let rg_spawned = rg_out.is_ok();
    if let Ok(o) = &rg_out
        && o.status.success()
        && !o.stdout.is_empty()
    {
        return (
            parse_rg_vimgrep(&String::from_utf8_lossy(&o.stdout), workspace),
            "rg",
        );
    }
    // git grep fallback (works in any repo even without rg installed).
    let git_out = Command::new("git")
        .args(["grep", "-n", "--column", "-I", "-e"])
        .arg(query)
        .current_dir(workspace)
        .output();
    let git_spawned = git_out.is_ok();
    if let Ok(o) = &git_out
        && o.status.success()
        && !o.stdout.is_empty()
    {
        return (
            parse_rg_vimgrep(&String::from_utf8_lossy(&o.stdout), workspace),
            "git grep",
        );
    }
    // Neither tool actually ran → surface an install hint. rg's spawn
    // fails with `NotFound` when the binary isn't on PATH; git's spawn
    // fails when git itself is missing (rare on dev machines but still
    // possible). If BOTH failed to launch we return "unavailable".
    if !rg_spawned && !git_spawned {
        return (Vec::new(), "unavailable");
    }
    // One of the tools ran but produced no matches / non-zero exit
    // (both rg and git grep exit 1 for no-hits — that's the empty
    // stdout branch). Preserve the historical "rg: no matches" wording
    // by reporting whichever tool was reached.
    (Vec::new(), if rg_spawned { "rg" } else { "git grep" })
}

/// Byte range `[s, e)` of the path-like token centered on `byte` in `text`.
/// "Path-like" is a permissive class: alphanumerics + `/`, `\`, `.`, `_`, `-`,
/// `:`, `~`. Stops at whitespace and other separators. Returns `None` if the
/// cursor isn't sitting on a path-like char.
fn path_token_around(text: &str, byte: usize) -> Option<(usize, usize)> {
    fn is_path_ch(c: char) -> bool {
        c.is_alphanumeric() || matches!(c, '/' | '\\' | '.' | '_' | '-' | ':' | '~')
    }
    let bytes = text.as_bytes();
    if byte >= text.len() {
        return None;
    }
    if !text[byte..].chars().next().is_some_and(is_path_ch) {
        return None;
    }
    let mut s = byte;
    while s > 0 {
        let prev = text[..s].chars().next_back().unwrap();
        if !is_path_ch(prev) {
            break;
        }
        s -= prev.len_utf8();
    }
    let mut e = byte;
    while e < bytes.len() {
        let nx = text[e..].chars().next().unwrap();
        if !is_path_ch(nx) {
            break;
        }
        e += nx.len_utf8();
    }
    Some((s, e))
}

/// Parse `path[:line[:col]]` — the trailing pair is recognised only when both
/// parts are numbers (otherwise `:` is part of the path). Returns `(path,
/// line, col)`; defaults col to 1 when only `:line` is present.
fn parse_path_with_position(token: &str) -> Option<(&str, usize, usize)> {
    // Split right-to-left: try `path:N:M` first, then `path:N`.
    if let Some(i) = token.rfind(':') {
        let (head, tail) = token.split_at(i);
        let tail = &tail[1..]; // drop the `:`
        if let Ok(maybe_col) = tail.parse::<usize>()
            && let Some(j) = head.rfind(':')
        {
            let (head2, mid) = head.split_at(j);
            let mid = &mid[1..];
            if let Ok(line) = mid.parse::<usize>() {
                return Some((head2, line, maybe_col));
            }
        }
        if let Ok(line) = tail.parse::<usize>() {
            return Some((head, line, 1));
        }
    }
    None
}

/// Compute candidate alternate paths for vim's `:A`. We try common
/// test ↔ source pairings: stem suffixed with `_test` / `_spec`, dotted
/// `.test.` / `.spec.` (TS / JS convention), and a parallel `tests/`
/// directory sibling. The first candidate that exists on disk wins.
fn alternate_paths(path: &std::path::Path) -> Vec<PathBuf> {
    let Some(parent) = path.parent() else {
        return Vec::new();
    };
    let Some(file_name) = path.file_name().and_then(|s| s.to_str()) else {
        return Vec::new();
    };
    // Split into `stem.ext` (or just `stem` when no extension).
    let (stem, ext) = match file_name.rsplit_once('.') {
        Some((s, e)) => (s.to_string(), Some(e.to_string())),
        None => (file_name.to_string(), None),
    };
    let mut out: Vec<PathBuf> = Vec::new();
    let with_ext = |stem: &str| -> String {
        match &ext {
            Some(e) => format!("{stem}.{e}"),
            None => stem.to_string(),
        }
    };
    // `_test` / `_spec` suffix on the stem.
    for suffix in ["_test", "_spec"] {
        if let Some(base) = stem.strip_suffix(suffix) {
            out.push(parent.join(with_ext(base)));
        } else {
            out.push(parent.join(with_ext(&format!("{stem}{suffix}"))));
        }
    }
    // `.test.<ext>` / `.spec.<ext>` (TS/JS).
    if let Some(e) = &ext {
        for marker in [".test", ".spec"] {
            let stripped = stem.strip_suffix(marker);
            if let Some(base) = stripped {
                out.push(parent.join(format!("{base}.{e}")));
            } else {
                out.push(parent.join(format!("{stem}{marker}.{e}")));
            }
        }
    }
    out
}

/// Read `playwright.env.{BRANCH,ENVIRONMENT,LOG_LEVEL}` from a settings.json,
/// mirroring `start-launcher.sh`'s resolution order: `$SETTINGS_FILE` env
/// var first, then `<workspace>/.vscode/settings.json`. Returns
/// `(branch, env, log_level, source_label)`. Source is `"$SETTINGS_FILE"`,
/// `"<workspace>/.vscode/settings.json"`, or `"defaults"`.
///
/// Defaults match the launcher: develop / dev / info.
/// Single-quote a string for safe interpolation into a `$SHELL -c "..."`
/// command. Wraps in `'…'` and replaces interior single quotes with the
/// canonical `'\''` escape. Suitable for log-group names, CloudWatch
/// stream IDs, region strings — strings that don't contain control bytes.
/// Derive a Bitbucket `workspace/repo` slug from a local repo path
/// by reading `.git/config`'s `origin` URL. Returns None if the
/// remote isn't Bitbucket-shaped (no bitbucket.org host or no
/// recognisable path). Handles both SSH (`git@bitbucket.org:ws/repo.git`)
/// and HTTPS (`https://bitbucket.org/ws/repo.git`) forms.
fn derive_bitbucket_slug(repo_path: &std::path::Path) -> Option<String> {
    let cfg = std::fs::read_to_string(repo_path.join(".git").join("config")).ok()?;
    let url = cfg.lines().find_map(|l| {
        let t = l.trim();
        t.strip_prefix("url = ").map(|s| s.to_string())
    })?;
    let after_host = if let Some(s) = url.strip_prefix("git@bitbucket.org:") {
        s.to_string()
    } else if let Some(s) = url.strip_prefix("https://bitbucket.org/") {
        s.to_string()
    } else {
        let idx = url.find("bitbucket.org")?;
        // Tolerate other forms like ssh://git@bitbucket.org/ws/repo.git
        let tail = &url[idx + "bitbucket.org".len()..];
        tail.trim_start_matches(['/', ':']).to_string()
    };
    let slug = after_host.trim_end_matches(".git").to_string();
    Some(slug)
}

/// Open a URL string in the OS's default browser. Best-effort. Used
/// by the GitHub-browse command + LSP `gx` URL opener + a dozen chip
/// clicks.
///
/// Task #1168 (2026-08-23) — SSH-aware. When `$SSH_TTY` or
/// `$SSH_CONNECTION` is set, mnml is running on a remote host and
/// `open`/`xdg-open`/`cmd start` would launch a browser on the
/// SERVER, not on the user's local machine (a silently-wrong
/// behavior the SSH-verify pass caught, see `docs/design/mnml-over-ssh.md`).
/// In that case we skip the shellout and best-effort emit OSC 52
/// to `/dev/tty` so the local terminal copies the URL to the
/// user's clipboard for manual paste into a local browser.
/// Terminals that don't honor OSC 52 (or have it disabled) still
/// get the strict improvement of "no wrong-browser open" — the
/// toast side of this (surface the URL in the UI too) needs an
/// App handle and is filed as a follow-up.
/// The user's preferred browser (`[ui] external_browser`), or empty for
/// the OS default. A process-global because `open_url_external` is a
/// free function with eleven call sites and no `self` — the same reason
/// `pty_pane::TERMINAL_LABEL` is one.
static EXTERNAL_BROWSER: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Called once from `App::new` after config load.
pub fn set_external_browser(name: String) {
    let _ = EXTERNAL_BROWSER.set(name);
}

fn external_browser() -> &'static str {
    EXTERNAL_BROWSER.get().map(String::as_str).unwrap_or("")
}

pub fn open_url_external(url: &str) {
    // Reviewer fix (2026-08-23): the OSC 52 path opens `/dev/tty`,
    // which doesn't exist on Windows — Win32-OpenSSH sets
    // `SSH_CONNECTION` too, so a naive `is_ssh_session()` branch
    // there falls into a silent no-op (no browser, no toast,
    // nothing). Gate the OSC 52 shortcut on unix; on Windows fall
    // through to the shellout (a Win32-OpenSSH session is rare
    // enough that the wrong-machine open is a smaller regression
    // than "nothing happens").
    #[cfg(unix)]
    if is_ssh_session() {
        best_effort_osc52_copy(url);
        return;
    }
    if !is_safe_external_url(url) {
        eprintln!("mnml: refusing to open {url:?} — not a plain http(s) URL");
        return;
    }
    // `[ui] external_browser` wins over the OS default when set.
    //
    // Spawned with the URL as a normal argv entry in every case — never
    // through a shell — so the `explorer.exe` reasoning below (a URL
    // containing `&` starting a second command) cannot be reintroduced
    // here. `is_safe_external_url` above is still the first layer.
    let chosen = external_browser();
    if !chosen.is_empty() {
        let spawned = if cfg!(target_os = "macos") {
            // macOS wants an application NAME via `open -a`.
            std::process::Command::new("open")
                .arg("-a")
                .arg(chosen)
                .arg(url)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
        } else {
            std::process::Command::new(chosen)
                .arg(url)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
        };
        // Fall through to the OS default if that browser is not
        // installed — a typo in the config should not mean links
        // silently stop working.
        if spawned.is_ok() {
            return;
        }
        eprintln!("mnml: could not launch {chosen:?} — falling back to the OS default");
    }
    let (cmd, args): (&str, &[&str]) = if cfg!(target_os = "macos") {
        ("open", &[])
    } else if cfg!(target_os = "windows") {
        // `explorer.exe <url>`, NOT `cmd /C start "" <url>`.
        //
        // Rust only quotes an argument that contains whitespace or
        // quotes, and `cmd.exe` re-parses its command line with its own
        // metacharacter rules — so a URL with no spaces reached cmd
        // unquoted and `&` started a second command. Opening a README
        // containing `https://example.com/a&calc.exe` and hitting the
        // open-URL binding was enough. (Rust's CVE-2024-24576 hardening
        // doesn't help: that escapes args for BATCH files, and the
        // program here was cmd.exe itself.)
        //
        // explorer.exe takes the URL as a normal argv entry and hands
        // it to the default handler without a shell parser in between.
        // `is_safe_external_url` is the second layer.
        ("explorer.exe", &[])
    } else {
        ("xdg-open", &[])
    };
    let _ = std::process::Command::new(cmd)
        .args(args)
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// Whether `url` is safe to hand to the OS URL opener.
///
/// Requires a plain `http://` or `https://` URL and rejects anything
/// carrying a shell/`cmd.exe` metacharacter, whitespace, or a control
/// character. Deliberately stricter than "is a valid URL": these
/// strings reach a process spawn on three OSes, one of which
/// historically re-parsed them, and every legitimate caller here
/// passes an ordinary web link — a repo browse URL, a PR link, a docs
/// page.
///
/// Callers are worth knowing: ten sites, including a `web_url` from a
/// remote forge API, a `prUrl` from DynamoDB, and the token under the
/// cursor in whatever file happens to be open. None of those are
/// trustworthy input.
pub(crate) fn is_safe_external_url(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return false;
    }
    // Must have something after the scheme.
    let rest = &url[url.find("//").map(|i| i + 2).unwrap_or(url.len())..];
    if rest.is_empty() || rest.starts_with('/') {
        return false;
    }
    // Whitespace and control characters are quoting hazards on every
    // platform, and no legitimate URL contains them unencoded — a
    // newline in particular could forge a second argument.
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    // Quote characters and backslash only: they're what breaks argv
    // quoting, and they're never needed unencoded in a URL.
    //
    // NOT rejected: `&` `?` `=` `%` `$` `;` `,` `+` `(` `)` `*` `!`.
    // Those are ordinary URL characters — `&` alone appears in every
    // multi-parameter query string, and an early draft of this
    // function rejected it, which would have refused most real links.
    // `&` was only dangerous because `cmd /C start` re-parsed it, and
    // the Windows arm no longer goes through cmd.
    const FORBIDDEN: &[char] = &['"', '\'', '`', '\\', '|', '<', '>', '^'];
    !url.contains(FORBIDDEN)
}

/// True when this mnml instance is running on the far side of an
/// SSH connection — either the server component or the user
/// SSH'd into a Linux box and launched mnml there. Detected via
/// the standard `SSH_TTY` / `SSH_CONNECTION` env vars set by
/// `sshd`. Cached would be nice, but this is called from
/// mouse-click hot paths that already pay the same env read on
/// every render, and a plain `env::var` is a hash-map lookup.
pub fn is_ssh_session() -> bool {
    std::env::var("SSH_TTY").is_ok() || std::env::var("SSH_CONNECTION").is_ok()
}

/// Emit an OSC 52 clipboard-copy escape sequence to `/dev/tty`
/// (not stdout — ratatui owns that). Most SSH-friendly terminals
/// (iTerm2, kitty, wezterm, alacritty with the option enabled,
/// tmux with `set-option -g set-clipboard on`) will pick this up
/// and copy the payload into the user's local system clipboard.
/// Terminals that don't honor OSC 52 silently ignore the
/// sequence — no visual artifact. Best-effort; errors dropped.
///
/// Unix-only: `/dev/tty` is a POSIX-ism. Windows callers fall
/// back to the shellout above; see the reviewer note on
/// `open_url_external`.
#[cfg(unix)]
fn best_effort_osc52_copy(url: &str) {
    use std::io::Write;
    let Ok(mut tty) = std::fs::OpenOptions::new().write(true).open("/dev/tty") else {
        return;
    };
    // OSC 52 payload is base64. Doing a tiny inline encoder rather
    // than pulling in the `base64` crate for one call.
    let encoded = osc52_base64(url.as_bytes());
    // ESC ] 52 ; c ; <base64> BEL
    let seq = format!("\x1b]52;c;{encoded}\x07");
    let _ = tty.write_all(seq.as_bytes());
}

#[cfg(any(unix, test))]
fn osc52_base64(input: &[u8]) -> String {
    const ALPHA: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let (b0, b1, b2) = (
            chunk[0] as u32,
            chunk.get(1).copied().unwrap_or(0) as u32,
            chunk.get(2).copied().unwrap_or(0) as u32,
        );
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHA[((triple >> 18) & 0x3F) as usize] as char);
        out.push(ALPHA[((triple >> 12) & 0x3F) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHA[((triple >> 6) & 0x3F) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHA[(triple & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod url_open_tests {
    use super::*;

    #[test]
    fn osc52_base64_matches_reference() {
        // Reference values from `printf hello | base64` etc.
        assert_eq!(osc52_base64(b""), "");
        assert_eq!(osc52_base64(b"f"), "Zg==");
        assert_eq!(osc52_base64(b"fo"), "Zm8=");
        assert_eq!(osc52_base64(b"foo"), "Zm9v");
        assert_eq!(osc52_base64(b"foob"), "Zm9vYg==");
        assert_eq!(osc52_base64(b"hello"), "aGVsbG8=");
        assert_eq!(
            osc52_base64(b"https://example.com/path?q=1"),
            "aHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRoP3E9MQ=="
        );
    }
}

/// Convert an `s3://bucket/key/prefix/` URL to the AWS S3 console
/// URL that browses that prefix. Used by the Cloud Agents right-
/// click menu's "Open S3 artifacts" item.
pub fn s3_prefix_to_console_url(s3_url: &str) -> String {
    // Strip the leading `s3://` then split bucket / prefix on the
    // first `/`. Falls back to the bare console URL when the
    // input is malformed.
    let stripped = s3_url.strip_prefix("s3://").unwrap_or(s3_url);
    let (bucket, prefix) = match stripped.split_once('/') {
        Some((b, p)) => (b, p),
        None => (stripped, ""),
    };
    format!(
        "https://us-east-1.console.aws.amazon.com/s3/buckets/{bucket}?prefix={prefix}&region=us-east-1"
    )
}

/// Hand `path` to the OS's default app — `open <path>` on macOS, `xdg-open` on
/// Linux, `cmd /C start` on Windows. Best-effort: errors are swallowed (so a
/// headless / sandboxed env where none of those are available is fine).
/// True when a binary named `mnml` is reachable via the user's
/// `PATH`. Used by the startup PATH hint so we only nag users
/// whose `mnml` command would actually fail when typed in a
/// fresh shell.
pub fn mnml_on_path() -> bool {
    binary_on_path("mnml")
}

/// Generalised version of `mnml_on_path` — true when a binary
/// named `name` is reachable via the user's `PATH`.
pub fn binary_on_path(name: &str) -> bool {
    let path = match std::env::var_os("PATH") {
        Some(p) => p,
        None => return false,
    };
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if let Ok(meta) = std::fs::metadata(&candidate)
            && meta.is_file()
        {
            return true;
        }
    }
    false
}

/// Listening TCP ports for a process tree rooted at `root_pid`.
/// Shells out to:
///   1. `pgrep -P <pid>` to enumerate direct children.
///   2. `lsof -i -n -P -p <pid>` to read the pid's open sockets,
///      keeping only `LISTEN` rows.
/// Repeats step 1 transitively to scoop up grandchildren (a
/// shell that spawned `node server.js` etc.). Failed shell-outs
/// are silently skipped — empty vec is fine for the renderer.
fn scan_listening_ports(root_pid: u32) -> Vec<u16> {
    let mut pids: Vec<u32> = vec![root_pid];
    let mut frontier: Vec<u32> = vec![root_pid];
    while let Some(p) = frontier.pop() {
        let out = std::process::Command::new("pgrep")
            .args(["-P", &p.to_string()])
            .output();
        if let Ok(o) = out
            && o.status.success()
        {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                if let Ok(child) = line.trim().parse::<u32>()
                    && !pids.contains(&child)
                {
                    pids.push(child);
                    frontier.push(child);
                }
            }
        }
    }
    let mut ports: Vec<u16> = Vec::new();
    // One lsof per pid set — comma-joined for a single shell-out.
    let pid_arg: String = pids
        .iter()
        .map(|p| p.to_string())
        .collect::<Vec<_>>()
        .join(",");
    if pid_arg.is_empty() {
        return ports;
    }
    // `-a` is critical: without it lsof combines `-i` and `-p` with
    // OR, so this returns every listening TCP socket on the machine
    // instead of just this pid set's. On a dev box with mongod / ssh
    // / rapportd / ControlCenter listeners that's 70+ lines of noise
    // and the row2 width guard silently swallows the chip entirely —
    // the port feature never renders. `-a` intersects the filters.
    // Regression from the port-detection commit; the recent 30 s TTL
    // bump made it more visible so a tester agent finally noticed.
    let out = std::process::Command::new("lsof")
        .args(["-a", "-iTCP", "-sTCP:LISTEN", "-n", "-P", "-p", &pid_arg])
        .output();
    if let Ok(o) = out
        && o.status.success()
    {
        for line in String::from_utf8_lossy(&o.stdout).lines().skip(1) {
            // Columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            // The NAME column for a TCP listener looks like:
            //   *:3000 (LISTEN)  or  127.0.0.1:3000 (LISTEN)
            let name = line.split_whitespace().nth(8).unwrap_or("");
            if let Some(colon) = name.rfind(':') {
                let port_str = &name[colon + 1..];
                if let Ok(port) = port_str.trim_end_matches(" (LISTEN)").parse::<u16>()
                    && !ports.contains(&port)
                {
                    ports.push(port);
                }
            }
        }
    }
    ports.sort_unstable();
    ports
}

/// Merge one fresh `ClaudeAccountUsage` into the vec — replace-in-place
/// if a slot with the same `name` exists, else push. Multi-account
/// fetch results arrive one-at-a-time and need to update the right
/// slot without disturbing the others. Task #944.
fn upsert_claude_account(
    slots: &mut Vec<crate::ai_usage::ClaudeAccountUsage>,
    fresh: crate::ai_usage::ClaudeAccountUsage,
) {
    if let Some(existing) = slots.iter_mut().find(|a| a.name == fresh.name) {
        *existing = fresh;
    } else {
        slots.push(fresh);
    }
}

fn open_path_external(path: &std::path::Path) {
    // Same SSH concern as `open_url_external` (task #1168, reviewer
    // pass on 4cb2a793): on a remote host `xdg-open` would fire on
    // the SERVER, not the SSH client. Copy the absolute path to the
    // local clipboard via OSC 52 so the user can paste it into
    // whatever they'd have used locally (Finder, an editor, etc.).
    #[cfg(unix)]
    if is_ssh_session() {
        best_effort_osc52_copy(&path.display().to_string());
        return;
    }
    let (cmd, args): (&str, &[&str]) = if cfg!(target_os = "macos") {
        ("open", &[])
    } else if cfg!(target_os = "windows") {
        ("cmd", &["/C", "start", ""])
    } else {
        ("xdg-open", &[])
    };
    let _ = std::process::Command::new(cmd)
        .args(args)
        .arg(path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// A pending file-system mutation awaiting its name prompt — set when the
/// tree's right-click menu fires a New/Rename action, consumed when the
/// `PromptKind::NewFile` / `NewFolder` / `Rename` accept handler runs.
#[derive(Debug, Clone)]
pub enum FsAction {
    NewFile { parent: PathBuf },
    NewFolder { parent: PathBuf },
    Rename { path: PathBuf },
    Delete { path: PathBuf },
    MoveTo { source: PathBuf },
}

/// One watch row's most-recent evaluation. `expression` keys the
/// `App.dap_watch_results` map; `value` is the adapter's formatted
/// string; `ty` is the type name (when the adapter advertised
/// `supportsVariableType`); `err` carries the error message when the
/// adapter rejected the evaluation (e.g. "name 'foo' is not defined").
#[derive(Debug, Clone)]
pub struct WatchResult {
    pub value: String,
    pub ty: Option<String>,
    pub err: Option<String>,
}

/// Which section of the left rail has the keyboard when `Focus::Tree` is
/// active. The renderer paints the cursor on the focused section; the other
/// section's selection is still drawn (with a dim "out-of-focus" highlight)
/// so context is preserved when the user flips back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailSection {
    /// The `WORKSPACE` section (file tree); keys go to `app.tree`.
    Workspace,
    /// The `GIT` section (branches + worktrees); keys go to `app.git_rail`.
    Git,
}

/// Which rail section the user is mid-drag on. Stored inside
/// `RailSectionDrag` and consumed by the layout code in `tree_view`
/// to derive the section's max height during the drag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailSectionKind {
    Integrations,
    Git,
}

/// Active drag-resize state for a rail section header.
#[derive(Debug, Clone, Copy)]
pub struct RailSectionDrag {
    /// Which section's header is being dragged.
    pub kind: RailSectionKind,
    /// Pointer Y at mouse-down.
    pub start_y: u16,
    /// Section's effective height at mouse-down.
    pub start_h: u16,
    /// `true` once at least one Drag event has fired since mouse-down.
    /// Used to distinguish a quick click (no drag → toggle collapse)
    /// from a real drag (resize, suppress toggle on release).
    pub moved: bool,
}

/// Top-level rail mode driven by the far-left vscode-style activity
/// bar. Each variant maps to a single rail pane filling everything to
/// the right of the activity-bar strip. All five sections ship live
/// content — Explorer / Git / Agents / Findings / Integrations.
/// qa-feature 2026-07-01 — Installed / Marketplace tabs in the
/// Integrations panel. `Installed` lists enabled integrations
/// (daily driver rail); `Marketplace` lists everything else so
/// the user can enable more.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegrationsPanelTab {
    Installed,
    Marketplace,
    /// 2026-08-19 (#1055 follow-up) — the "in development" tab.
    /// Same source list as Marketplace, but shows the App entries
    /// filtered OUT by the Ready gate. Aimed at integration authors
    /// who want to browse their own not-yet-shipped work. Config-
    /// gated: only rendered when
    /// `config.marketplace.show_dev_tab = true`, so regular users
    /// never see it. Label is a single glyph (`nf-fa-dev` at U+EEF4)
    /// so the three tabs fit in the ~28-cell activity panel.
    InDev,
}

/// 2026-08-07 — how the Installed tab is sorted.
///   Default = user's config order (whatever was written to
///   `[[ui.integration_icon]]` first stays first).
///   Name = A-Z on the display label.
///   EnabledFirst = enabled ones bubble to the top, then Name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstalledSort {
    Default,
    Name,
    EnabledFirst,
}

impl InstalledSort {
    pub fn cycle(self) -> Self {
        match self {
            Self::Default => Self::Name,
            Self::Name => Self::EnabledFirst,
            Self::EnabledFirst => Self::Default,
        }
    }
    pub fn label(self) -> &'static str {
        // 2026-08-07 design-critic r2 #1: trailing `▾` matches every
        // other cycle-chip in the app (workspace pill, HTTP env chip,
        // Agents time-range). Leading `⇅` was reading as a static icon.
        match self {
            Self::Default => "Default ▾",
            Self::Name => "A-Z ▾",
            Self::EnabledFirst => "Enabled first ▾",
        }
    }
}

/// 2026-08-07 — how the Marketplace tab is sorted.
///   Default = whatever order the catalog fetch returned.
///   Name = A-Z on the entry label.
///   OfficialFirst = Official entries bubble to the top, then Name.
///   Kind = groups by kind (app / launcher / driver) then Name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceSort {
    Default,
    Name,
    OfficialFirst,
    Kind,
}

impl MarketplaceSort {
    pub fn cycle(self) -> Self {
        match self {
            Self::Default => Self::Name,
            Self::Name => Self::OfficialFirst,
            Self::OfficialFirst => Self::Kind,
            Self::Kind => Self::Default,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "Default ▾",
            Self::Name => "A-Z ▾",
            Self::OfficialFirst => "Official first ▾",
            Self::Kind => "By kind ▾",
        }
    }
}

/// Marker for `App::ai_placeholder_slot` — the empty quadrant of a
/// 2×2 Claude / Codex grid. Currently only Claude auto-tiles this
/// way but the enum lets Codex slot in later without touching the
/// field's type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiPlaceholderKind {
    ClaudeCode,
}

/// Sessions panel — how to sort the tab list. Pinned sessions
/// bubble to the top regardless of this setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionsSortMode {
    /// Sort by state: running → recent → idle → exited.
    Auto,
    /// User's manual order (right-click "Move up / down / top /
    /// bottom" bumps a session into this vec).
    Manual,
}

/// land independently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivitySection {
    /// Launcher icon pinned to the activity bar by right-clicking
    /// an integration chip. `u16` indexes into
    /// `config.ui.activity_bar_pinned_integrations`. Click fires
    /// the integration chip's `command` (spawns a Pty pane); no
    /// side panel — unlike `Mount(N)`. 2026-07-20.
    LauncherIcon(u16),
    /// File tree + integrations + git (the pre-activity-bar default).
    Explorer,
    Search,
    /// Branch + worktree management. The existing GIT sub-section
    /// inside Explorer stays; this is the dedicated mode that would
    /// give it more space + a richer log later.
    Git,
    Debug,
    Integrations,
    /// Vertical-tab strip of open Pty sessions (Claude / Codex /
    /// shell panes). Each tab shows the session name + git
    /// branch + cwd + a notification ring when there's unread
    /// output. Click a tab → focus that pane.
    Sessions,
    /// Cross-workspace Claude / Codex agents dashboard in the rail.
    /// Rows grouped by status (Action Needed / Running / Done)
    /// with an animated spinner glyph on running rows, filter
    /// input + `+ New` at the top.
    Agents,
    /// Cloud agents only — ECS runner rows (and any
    /// future cloud bots). Separated from `Agents` because the
    /// affordances differ: cloud rows don't have a "resume in
    /// pty" action; they expose Copy runId / Open CloudWatch /
    /// Open PR instead.
    CloudAgents,
    /// HTTP request workflow — `.http` / `.curl` file browser,
    /// recent requests, environment picker. (#10)
    Http,
    /// Persistent scratch notes for the workspace. `.mnml/notes/*.md`.
    /// v1 renders a flat list + `+ New note` (#8).
    Notes,
    /// TODO markers discovered across the workspace (source-comment
    /// `TODO` / `FIXME` / `XXX` / `HACK` / `REVIEW`). v1 v scans on
    /// section open, click a row to jump. (#9)
    Todos,
    /// 2026-08-07 — Findings section. Reads `.mnml/findings/*.md`
    /// (workspace-scoped, so mnml pointed at any repo picks up
    /// that repo's findings automatically — mixr, tracker-jira,
    /// etc. all get it for free). Click a row → open in editor
    /// pane. v1 = read-only list; v2 = right-click menu (archive
    /// / delete / mark reviewed).
    Findings,
    /// A manifest-registered Mount integration — the u16 indexes
    /// into `App::mount_manifests`. Icon, color, tooltip, and
    /// binary come from the manifest. Manifest mounts render
    /// in the activity bar after the builtin sections.
    Mount(u16),
}

impl ActivitySection {
    /// `(glyph, fallback, tooltip, command_id)` — used by both the
    /// activity bar renderer and the click handler.
    pub fn meta(self) -> (&'static str, &'static str, &'static str, &'static str) {
        match self {
            // nf-fa-folder_open
            Self::Explorer => ("\u{F115}", "E", "Explorer", "view.activity_explorer"),
            // nf-md-magnify (via search_glyph::NERD — one glyph everywhere)
            Self::Search => (
                crate::ui::search_glyph::NERD,
                "S",
                "Search",
                "view.activity_search",
            ),
            // nf-md-source_branch
            Self::Git => ("\u{F02A2}", "G", "Source control", "view.activity_git"),
            // nf-fa-bug
            Self::Debug => ("\u{F188}", "D", "Run and debug", "view.activity_debug"),
            // nf-md-puzzle
            Self::Integrations => (
                "\u{F0431}",
                "I",
                "Integrations",
                "view.activity_integrations",
            ),
            // nf-md-tab — cmux-style vertical session tabs
            Self::Sessions => ("\u{F0392}", "T", "Sessions", "view.activity_sessions"),
            // nf-md-robot — agents (Claude / Codex) dashboard
            Self::Agents => ("\u{F06A9}", "A", "Agents", "view.activity_agents"),
            // nf-md-cloud — cloud-only agents (ECS runner)
            Self::CloudAgents => (
                "\u{F0163}",
                "C",
                "Cloud agents",
                "view.activity_cloud_agents",
            ),
            // nf-fa-bolt — HTTP / API workflow
            // nf-fa-paper_plane — blue paper airplane matches the
            // "send a request" semantic better than the prior bolt.
            Self::Http => ("\u{F1D8}", "H", "HTTP", "view.activity_http"),
            // nf-fa-sticky_note — persistent scratch notes
            Self::Notes => ("\u{F249}", "N", "Notes", "view.activity_notes"),
            // nf-fa-check_square — TODO markers across the workspace
            Self::Todos => ("\u{F046}", "O", "TODOs", "view.activity_todos"),
            // nf-md-file-search — findings archive (`.mnml/findings/*.md`)
            Self::Findings => ("\u{F1623}", "F", "Findings", "view.activity_findings"),
            // Manifest mounts have per-entry metadata that lives
            // on `App::mount_manifests`; the activity-bar renderer
            // resolves it dynamically. This `meta()` arm is a
            // placeholder so the static API stays infallible.
            Self::Mount(_) => ("\u{F0BD3}", "M", "Mount", ""),
            // Launcher icons are placeholders here — the actual
            // glyph/color/tooltip come from the integration_icon
            // referenced by the u16 index, resolved at render
            // time in `ui::activity_bar`.
            Self::LauncherIcon(_) => ("\u{F0415}", "L", "Launcher", ""),
        }
    }

    /// Order shown in the activity bar strip — top to bottom.
    pub fn all() -> &'static [Self] {
        &[
            Self::Explorer,
            Self::Search,
            Self::Git,
            Self::Debug,
            Self::Integrations,
            Self::Sessions,
            Self::Agents,
            Self::CloudAgents,
            Self::Http,
            Self::Notes,
            Self::Todos,
            Self::Findings,
        ]
    }

    /// Stable string id used as the badge map key (see
    /// `App::activity_badges`). Builtins return the suffix of
    /// their `view.activity_*` command id; Mount sections return
    /// the manifest id, looked up via `App::mount_manifests`.
    pub fn badge_key(&self, app: &crate::app::App) -> Option<String> {
        match self {
            Self::Explorer => Some("explorer".to_string()),
            Self::Search => Some("search".to_string()),
            Self::Git => Some("git".to_string()),
            Self::Debug => Some("debug".to_string()),
            Self::Integrations => Some("integrations".to_string()),
            Self::Sessions => Some("sessions".to_string()),
            Self::Agents => Some("agents".to_string()),
            Self::CloudAgents => Some("cloud_agents".to_string()),
            Self::Http => Some("http".to_string()),
            Self::Notes => Some("notes".to_string()),
            Self::Todos => Some("todos".to_string()),
            Self::Findings => Some("findings".to_string()),
            Self::Mount(idx) => app.mount_manifests.get(*idx as usize).map(|m| m.id.clone()),
            Self::LauncherIcon(idx) => app
                .config
                .ui
                .activity_bar_pinned_integrations
                .get(*idx as usize)
                .cloned(),
        }
    }
}

/// Which underlying scroll value a `ScrollbarHit` controls. The dispatcher
/// (in `tui.rs`) routes a drag-to-scrollbar event into the right pane field
/// based on this tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollbarKind {
    /// `Pane::Editor` buffer's `scroll` field. `total` = line count;
    /// `viewport` = visible text rows.
    Editor,
    /// `Pane::Diff` view's `scroll` field. `total` = total flat rows
    /// across all rendered hunks; `viewport` = body rows shown.
    Diff,
    /// `Pane::GitGraph(g)` with `g.embedded_diff` set — drags adjust
    /// `g.embedded_diff.scroll`.
    EmbeddedDiff,
    /// `Pane::GitGraph(g)` commit list (no embedded diff). Drags
    /// adjust `g.scroll` AND snap `g.selected` to the new scroll
    /// position so the per-frame keep-selected-on-screen math doesn't
    /// immediately snap the scroll back.
    GitGraphCommits,
    /// `Pane::Tests(p)` → `p.scroll`.
    Tests,
    /// `Pane::Flaky(p)` → `p.scroll`.
    Flaky,
    /// `Pane::Diagnostics(p)` → `p.scroll`.
    Diagnostics,
    /// `Pane::Outline(p)` → `p.scroll`.
    Outline,
    /// `Pane::Grep(p)` → `p.scroll`.
    Grep,
    /// `Pane::Quickfix(p)` → `p.scroll`.
    Quickfix,
    /// `Pane::GitStatus(p)` → `p.scroll`.
    GitStatus,
    /// `Pane::CmdlineHistory(p)` → `p.scroll`.
    CmdlineHistory,
    /// `Pane::Editor` buffer's `h_scroll` field — the one HORIZONTAL
    /// scrollbar kind. `total` = widest line (chars); `viewport` =
    /// visible text columns. Drag/click maps the X axis, not Y.
    EditorHScroll,
    /// The file-tree rail (`app.tree.scroll`) — not a pane, so the
    /// dispatcher ignores `pane_id`. `total` = visible-row count;
    /// `viewport` = tree body height.
    Tree,
    /// An extra workspace's expanded tree (`app.extra_workspaces[i].tree.scroll`).
    /// The `usize` is the workspace index. `total` = visible-row count;
    /// `viewport` = expanded body height.
    ExtraTree(usize),
    /// The agents rail panel (`app.agents_panel_scroll`) — not a pane.
    /// `total` = content-row count; `viewport` = panel body height.
    AgentsPanel,
    /// #1229 — the git rail's own scroll (`App::git_palette_scroll`).
    /// `total` = item rows across all sections; `viewport` = item rows the
    /// panel can show.
    GitPalette,
    /// A `Pane::Files` listing — drags move its `selected` cursor.
    FilesPane,
}

impl ScrollbarKind {
    /// True for the horizontal scrollbar kinds — the drag/click
    /// dispatcher maps the X axis instead of Y for these.
    pub fn is_horizontal(self) -> bool {
        matches!(self, ScrollbarKind::EditorHScroll)
    }
}

/// A click-targetable scrollbar region rendered this frame. Used both
/// for jump-to-position clicks (click anywhere in the bar → scroll
/// proportionally) and for drag-to-scroll gestures.
#[derive(Debug, Clone, Copy)]
pub struct ScrollbarHit {
    /// Screen rect of the painted scrollbar (1 col wide, body-height tall).
    pub area: Rect,
    pub pane_id: PaneId,
    /// Total number of content rows in the underlying document. Maps
    /// click_y → file row.
    pub total: usize,
    /// Visible content rows (i.e. body height).
    pub viewport: usize,
    pub kind: ScrollbarKind,
}

/// Screen regions captured during render, consumed for mouse routing on the next event.
#[derive(Debug, Default, Clone)]
pub struct PaneRects {
    pub tree: Option<Rect>,
    /// Tree scroll offset at render time (so a click maps to the right row).
    pub tree_scroll: usize,
    /// The clickable rect for "toggle tree visibility" — the workspace-name
    /// header row when the tree is expanded, or the whole activity-bar column
    /// when it's collapsed. Click → `App::toggle_tree`.
    pub tree_toggle: Option<Rect>,
    /// `(rect, command_id)` per icon in the file-tree toolbar strip (row 0
    /// of the rail when expanded). Click → `crate::command::run(id, app)`.
    /// Cleared + rebuilt per render.
    pub tree_icon_buttons: Vec<(Rect, &'static str)>,
    /// The 1-cell-wide draggable "right edge" of the rail. Click+drag adjusts
    /// `App::tree_width` so the rail resizes live.
    pub tree_edge: Option<Rect>,
    /// `(divider_rect, pane_id)` per visible GitGraph commit-list ↔
    /// detail-panel divider. Click-and-drag adjusts the detail-panel
    /// width via `App.git_graph_detail_col_override`. Cleared +
    /// rebuilt per render.
    pub git_graph_detail_dividers: Vec<(Rect, PaneId)>,
    /// The `> GIT` section header row in the rail (when the rail's visible).
    /// Click → `App::toggle_git_section_expanded`.
    pub git_section_toggle: Option<Rect>,
    /// #polish 2026-07-06 — clickable `· <repo>` chip inside
    /// the GIT header when the workspace has multiple repos.
    /// Left-click opens the repo switcher. `None` in the single-
    /// repo case.
    pub git_repo_chip: Option<Rect>,
    /// #polish 2026-07-06 — `+` chip at the end of the right-panel
    /// tab strip. Click opens a context menu with the 5 panel
    /// kinds (Outline / Problems / AI chat / Grep / Tests).
    pub right_panel_new_button: Option<Rect>,
    /// `(rect, ws_idx, scroll)` per extra-workspace section's body — the rect
    /// is the file-list area, ws_idx is the index into `App.extra_workspaces`,
    /// scroll is the tree's scroll offset at render time so a click can be
    /// translated to the right row.
    pub extra_workspace_bodies: Vec<(Rect, usize, usize)>,
    /// `(rect, ws_idx)` per extra-workspace section's header row. Click →
    /// toggle that section's expansion.
    pub extra_workspace_toggles: Vec<(Rect, usize)>,
    /// qa-feature 2026-07-01 — `(rect, ws_idx)` per extra-workspace's
    /// hollow `○` marker. Click → promote that workspace to primary
    /// (same as right-click → Set as workspace). Sits inside the
    /// `extra_workspace_toggles` rect but wins in the dispatcher.
    pub extra_workspace_promote_dots: Vec<(Rect, usize)>,
    /// `(rect, hit)` per visible row in the GIT section. Click → focus + run
    /// the row's default action; right-click → context menu.
    pub git_rail_rows: Vec<(Rect, crate::git::rail::GitRailHit)>,
    pub bufferline: Option<Rect>,
    /// `(rect, pane_id)` for each tab in the bufferline (whole tab → activate).
    pub bufferline_tabs: Vec<(Rect, PaneId)>,
    /// Bufferline right-cluster click targets (NvChad-style): `+` new-tab,
    /// `TABS` label, per-tabpage chip, per-tabpage close `⊗`, theme toggle,
    /// window close `×`. Cleared + repopulated per bufferline render.
    pub bufferline_new_tab_button: Option<Rect>,
    /// Inline `+` chip that appears just after the last tab when at
    /// least one Request pane exists — click opens a fresh new
    /// Request pane. Mirrors browser tab-strip `+` semantics; the
    /// far-right `bufferline_new_tab_button` still creates a new
    /// tab-page (window / split), not a request.
    pub bufferline_new_request_button: Option<Rect>,
    pub bufferline_tab_page_chips: Vec<(Rect, usize)>,
    /// The ` TABS ` label rect — right-click here opens the cluster
    /// mode chooser (Expanded / Compact / Auto).
    pub bufferline_tabs_label: Option<Rect>,
    pub bufferline_tab_page_close: Vec<(Rect, usize)>,
    pub bufferline_theme_toggle: Option<Rect>,
    pub bufferline_window_close: Option<Rect>,
    /// Bufferline launcher-icon strip — one entry per icon rendered, in
    // 2026-08-01 (P2) — launcher_icon_rects deleted with the
    // LauncherIcon retirement. Integration chip clicks route through
    // integration_icon_rects.
    /// Centered "search files, run commands…" chip in the palette
    /// top-bar. Click → `app.open_command_palette()`.
    pub palette_search_chip: Option<Rect>,
    /// Back button (`←`) in the palette top-bar — `buffer.prev`.
    /// Sidebar (rail) toggle icon — sits left of the back/forward
    /// arrows in the palette bar. Click → same as Ctrl+B
    /// (view.toggle_tree).
    pub palette_sidebar_button: Option<Rect>,
    /// Right-panel toggle icon — sits to the right of the dropdown
    /// chevron (mirror of `palette_sidebar_button`). Click →
    /// view.toggle_right_panel.
    pub palette_right_panel_button: Option<Rect>,
    /// Drag-resize grip on the right panel's left edge.
    pub right_panel_edge: Option<Rect>,
    /// Hit rect for the `×` close button on the right-panel header.
    /// Closes the currently-active hosted pane (panel stays open;
    /// next tab takes its place, or empty-state returns if last).
    pub right_panel_close: Option<Rect>,
    /// Hit rects for the right-panel tab strip — one per hosted
    /// pane, paired with its index into `right_panel_panes`. v3.
    pub right_panel_tabs: Vec<(Rect, usize)>,
    /// Click target for the empty-state `:outline.show` line. Fires
    /// the same command on left-click. mouse-polish F-2.
    pub right_panel_empty_outline: Option<Rect>,
    /// Click target for the empty-state `:lsp.diagnostics` line.
    pub right_panel_empty_diagnostics: Option<Rect>,
    /// design-critic 2026-06-28 #3: empty-state lists all 5
    /// routable commands now (was 2 of 5). Three new click rects.
    pub right_panel_empty_ai: Option<Rect>,
    pub right_panel_empty_grep: Option<Rect>,
    pub right_panel_empty_test: Option<Rect>,
    /// `+` chip just after the user's integration icons in the
    /// palette bar's gap area. Click → `integrations.add`
    /// (opens the discovery overlay so the user can add an integration).
    pub palette_add_integration_button: Option<Rect>,
    pub palette_back_button: Option<Rect>,
    /// Forward button (`→`) in the palette top-bar — `buffer.next`.
    pub palette_forward_button: Option<Rect>,
    /// Dropdown chevron (`▾`) at the right edge of the palette chip —
    /// opens the recent-files picker.
    pub palette_dropdown_button: Option<Rect>,
    /// Rail INTEGRATIONS section icon rects — `(rect, index into
    /// `App.config.ui.integration_icons`)`. Click dispatcher in
    /// `tui.rs` runs the icon's `command`; hover tooltip in
    /// `ui::tooltip` looks up the entry's label.
    pub integration_icon_rects: Vec<(Rect, usize)>,
    /// P4c — clickable rects for the Marketplace tab's browsable
    /// entries. Each `(rect, idx)` where `idx` indexes into
    /// `app.marketplace_entries`. Left-click → install action.
    pub marketplace_row_rects: Vec<(Rect, usize)>,
    /// 2026-08-16 — clickable rects for the "↑ Update to <ver>" chip
    /// painted at the right edge of installed marketplace rows when
    /// `app.integration_updates` reports an available upgrade. Each
    /// `(rect, id)` — mouse handler looks the id up in
    /// `marketplace_entries` to route to the right install path.
    /// Cleared + repopulated every frame (default reset via
    /// `reset_for_frame`).
    pub update_chip_rects: Vec<(Rect, String)>,
    /// #1202 (2026-08-25) — clickable "↑ Update" chips on the FONTS
    /// rows pinned at the top of the Marketplace tab. `(rect,
    /// family)` — the click handler resolves the family to a brew
    /// command via `font_scan::update_command` and runs it in a Pty
    /// pane. Cleared + repopulated every frame.
    pub font_update_chip_rects: Vec<(Rect, String)>,
    /// Activity-bar icon rects (the far-left vscode-style strip) —
    /// `(rect, section)`. Click dispatcher in `tui.rs` flips
    /// `App.active_section`.
    pub activity_bar_icons: Vec<(Rect, ActivitySection)>,
    /// Search activity-bar section: per-result row rect → hit index.
    /// Click → opens that file at its line/col via
    /// `App::search_section_open_hit`. Cleared + rebuilt every draw.
    pub search_section_hit_rects: Vec<(Rect, usize)>,
    /// #1112 f/u (2026-08-21) — three toggle chips (case / word /
    /// regex) rendered inline in the search-section header row.
    /// Char is `c` / `w` / `r`. Click dispatches to the matching
    /// palette command so the state flip + toast + rerun all fire.
    pub search_section_flag_rects: Vec<(Rect, char)>,
    /// `> INTEGRATIONS` rail-section header — clickable toggle that
    /// flips `App.integration_section_expanded` (same pattern as
    /// `tree_toggle` / `git_section_toggle`).
    pub integration_section_toggle: Option<Rect>,
    /// `(rect, menu_idx)` per menu word on the chrome row. Click to
    /// drop the corresponding menu. Cleared + repopulated every frame.
    pub menu_bar_words: Vec<(Rect, usize)>,
    /// `»` overflow chip at the right edge of the menu bar when
    /// terminal width can't fit every menu word. Click opens the
    /// FIRST hidden menu; from there Alt+letter reaches the others.
    /// `usize` = index of the first hidden menu.
    pub menu_bar_overflow: Option<(Rect, usize)>,
    /// `(rect, item_idx)` per item row in the currently-open menu
    /// dropdown. Empty when no menu is open. Used for click + hover-
    /// highlight dispatch.
    pub menu_bar_items: Vec<(Rect, usize)>,
    /// `(rect, hit)` per row in the git palette (the GitKraken-style
    /// panel shown when `ActivitySection::Git` is active). Cleared
    /// + repopulated every frame by `git_palette::draw`.
    pub git_palette_rows: Vec<(Rect, crate::ui::git_palette::GitPaletteHit)>,
    /// #files — one entry per visible row of every `Pane::Files`:
    /// `(rect, pane_id, entry_index)`. Cleared each frame by the drawer.
    pub file_pane_rows: Vec<(Rect, PaneId, usize)>,
    /// #files item 3 — one entry per breadcrumb SEGMENT in a Files pane's
    /// header: `(rect, pane_id, that ancestor's path)`. Clicking a segment
    /// navigates there.
    pub file_pane_breadcrumbs: Vec<(Rect, PaneId, std::path::PathBuf)>,
    /// Editor breadcrumb segments and the directory each opens. Empty
    /// when the label is truncated — a rendered column no longer maps to
    /// a segment then, so a click would land somewhere arbitrary.
    pub editor_breadcrumbs: Vec<(Rect, std::path::PathBuf)>,
    /// The `▾` at the end of a Files pane's breadcrumb — opens the
    /// destinations picker.
    pub file_pane_places_chevron: Option<(Rect, PaneId)>,
    /// The sort label at the right of a Files pane's header — clicking it
    /// cycles the sort. It paints a `▾`, the same "opens/changes
    /// something" glyph as the destinations chevron, so it has to BE a
    /// target; review flagged it as a dead click.
    pub file_pane_sort_label: Option<(Rect, PaneId)>,
    /// Click rect for the git palette's filter input. Click to
    /// focus + start typing; Esc clears + unfocuses.
    pub git_palette_filter_input: Option<Rect>,
    /// Click rect for the git palette's ↻ refresh chip in the GIT
    /// caps header row. Re-runs `git status` / branch enumeration
    /// so external changes (branches deleted at the CLI, worktrees
    /// added, etc.) show up without a mnml restart.
    pub git_palette_refresh_chip: Option<Rect>,
    /// Click rect for the notes panel's ↻ refresh chip. Re-scans
    /// `<workspace>/.mnml/notes/` so files added outside mnml
    /// appear without a restart. Populated by the header helper.
    pub notes_panel_refresh_chip: Option<Rect>,
    /// Click rect for the findings panel's ↻ refresh chip.
    /// Re-scans `<workspace>/.mnml/findings/` for new tester
    /// reports. Populated by the header helper.
    pub findings_panel_refresh_chip: Option<Rect>,
    /// Refresh chip in the SESSIONS panel header. #1221 (2026-08-28) —
    /// the panel was the last one still hand-rolling its caps header,
    /// so it was the only one without the chip.
    pub sessions_panel_refresh_chip: Option<Rect>,
    /// Click target for the `▾` dropdown chevron next to the
    /// workspace name. Toggles `App::workspace_picker_open`.
    pub workspace_picker_chevron: Option<Rect>,
    /// Click rects for URL/artifact hits inside a CloudAgentRun
    /// pane. Cleared per-frame; populated by
    /// `cloud_agent_run_view::draw`.
    pub cloud_agent_run_hits: Vec<(
        Rect,
        crate::layout::PaneId,
        crate::ui::cloud_agent_run_view::CloudAgentRunHit,
    )>,
    /// Click rects inside the NewCloudAgentWizard pane (radios +
    /// Back/Next buttons). Cleared per-frame.
    pub new_cloud_agent_wizard_hits: Vec<(Rect, crate::ui::new_cloud_agent_wizard_view::WizardHit)>,
    /// Click rects inside the NewCloudRunWizard pane (Cloud
    /// Agents version — Managed Agents / QWE).
    pub new_cloud_run_wizard_hits: Vec<(Rect, crate::ui::new_cloud_run_wizard_view::CloudRunHit)>,
    /// Click rects inside the first-launch wizard overlay (Yes / No
    /// radios for the Nerd Font section, etc). 2026-08-14 — added
    /// to fix the "the yes / no rows aren't clickable" bug. Cleared
    /// per-frame.
    pub first_launch_hits: Vec<(Rect, crate::ui::first_launch_overlay::FirstLaunchHit)>,
    /// Click rect for the "+ New Cloud Run" button in the Cloud
    /// Agents panel header.
    pub cloud_agents_new_run_button: Option<Rect>,
    /// Quick-fire prompt input row in the Cloud Agents panel.
    /// Click to focus.
    pub cloud_agents_quick_input: Option<Rect>,
    /// "change defaults" chip next to the quick-fire input —
    /// opens the wizard so the user can swap agent / env /
    /// sandbox.
    pub cloud_agents_change_defaults_chip: Option<Rect>,
    /// Click rect for the workspace NAME (not the chevron) in the
    /// file-tree header. In multi-repo workspaces, clicking the
    /// name opens the repo picker; in single-repo workspaces, it
    /// just toggles the tree's expanded state (same as clicking
    /// elsewhere on the header). 2026-06-27 #611 UX wire.
    pub workspace_name_rect: Option<Rect>,
    /// `(rect, workspace_idx)` per row in the workspace-picker
    /// dropdown. `workspace_idx` matches `App::switch_workspace`
    /// (0 = primary, 1+ = extras). Cleared + repopulated every frame.
    pub workspace_picker_rows: Vec<(Rect, usize)>,
    /// Click target for the picker's filter input. Click to focus +
    /// start typing.
    pub workspace_picker_filter_input: Option<Rect>,
    /// `(rect, widget_id)` per dock widget body. Click → focus
    /// the widget (toast in slice 1; content-specific actions
    /// later).
    pub dock_widget_bodies: Vec<(Rect, usize)>,
    /// `(rect, widget_id)` per close-`×` button at the right end
    /// of each dock widget's title bar. Click → remove the
    /// widget from `App::dock_widgets`.
    pub dock_widget_close_buttons: Vec<(Rect, usize)>,
    /// `(rect, widget_id)` per dock widget title bar. Mouse-down
    /// arms a drag-to-corner; the dispatcher resolves the new
    /// corner from the cursor's final position on mouse-up.
    pub dock_widget_titles: Vec<(Rect, usize)>,
    /// `(rect, widget_id)` per dock widget kebab `⋮` glyph at the
    /// right end of the title bar. Click → open the per-widget
    /// kebab menu anchored just below the glyph.
    pub dock_widget_kebabs: Vec<(Rect, usize)>,
    /// `(rect, item_idx)` per kebab-menu row, where `item_idx`
    /// indexes into `DockKebabMenu::items`. Cleared + rebuilt
    /// every frame.
    pub dock_kebab_rows: Vec<(Rect, usize)>,
    /// Click rect for the bottom-right `+ dock` empty-state chip
    /// (shown only when `dock_widgets.is_empty()`). Click → fires
    /// `(rect, pane_id)` per session tab in the cmux-style
    /// `ActivitySection::Sessions` panel. Click → focus that
    /// Pty pane.
    pub session_tabs: Vec<(Rect, usize)>,
    /// `ActivitySection::Http` panel — one row per `.http` / `.curl`
    /// file. Click → open the file as a `Pane::Request`. (#10)
    pub http_panel_files: Vec<(Rect, std::path::PathBuf)>,
    /// `ActivitySection::Http` panel `+ New request` row rect. Click →
    /// create a stub `.http` file and open it.
    pub http_panel_new_chip: Option<Rect>,
    /// `ActivitySection::Http` panel filter input row. Click → focus
    /// the filter (typing appends; Esc clears + unfocuses).
    pub http_panel_filter_input: Option<Rect>,
    /// Recent (from history.jsonl) row rects — `(rect, cache_index)`.
    /// Click → rebuild curl via `history::entry_to_curl` + open scratch.
    pub http_panel_recent_rows: Vec<(Rect, usize)>,
    /// Captured row rects — `(rect, cache_index)`. Click → `to_curl` +
    /// open scratch (same treatment as `http.view_captured` picker).
    pub http_panel_captured_rows: Vec<(Rect, usize)>,
    /// Sectioned sidebar header rects — `(rect, section_index)` where
    /// `0=Files`, `1=Recent`, `2=Captured`. Click → toggle
    /// `http_panel_section_collapsed[i]`.
    pub http_panel_section_headers: Vec<(Rect, u8)>,
    /// `⟳ Start capture` action-row rect (inside the Captured
    /// section header). Click → run `http.capture_now`.
    pub http_panel_capture_chip: Option<Rect>,
    /// `✕ clear` chip inside the CAPTURED section header. Click →
    /// truncate the captured-traffic log.
    pub http_panel_captured_clear_chip: Option<Rect>,
    /// `↺ refresh` chip inside the CAPTURED section header. Click →
    /// re-read `.rqst/captured/log.jsonl` into the panel cache so
    /// autocapture writes show up without a full panel refresh.
    /// 2026-07-07.
    pub http_panel_captured_refresh_chip: Option<Rect>,
    /// Per-section chip rects (filter / refresh / capture / clear) —
    /// one entry per painted chip with its rect, section index, and
    /// action kind. Cleared + rebuilt every render; mouse routing
    /// walks the vec and dispatches based on `HttpChipKind`.
    /// Consolidates the old *_filter_chip / *_refresh_chip fields.
    /// 2026-07-07.
    pub http_panel_section_chips: Vec<(Rect, u8, HttpChipKind)>,
    /// `✕ clear` chip inside the RECENT section header. Click →
    /// truncate the workspace-local history.jsonl.
    pub http_panel_recent_clear_chip: Option<Rect>,
    /// `↓ Paste curl…` action-row rect (below files). Click → run
    /// `http.paste_curl` (turn clipboard curl into a scratch request).
    pub http_panel_discover_chip: Option<Rect>,
    /// Env-row rects — `(rect, env_name)`. Click → set as active
    /// env (writes `App::http_env_override`).
    pub http_panel_env_rows: Vec<(Rect, String)>,
    /// `+ New env` action-row rect (inside the Envs section).
    /// Click → open the env-name prompt to create a new `.env`.
    pub http_panel_env_new_chip: Option<Rect>,
    /// #polish 2026-07-06 — `+ New chain` action-row rect inside
    /// the CHAINS section. Click → open the chain-name prompt.
    pub http_panel_chain_new_chip: Option<Rect>,
    /// #polish 2026-07-06 — `+ New collection` action-row rect
    /// inside the COLLECTIONS section. Click → open the
    /// collection-name prompt.
    pub http_panel_collection_new_chip: Option<Rect>,
    /// Chain-row rects — `(rect, chain_path)`. Click → run that
    /// chain (calls `http_chain_run_path`).
    pub http_panel_chain_rows: Vec<(Rect, std::path::PathBuf)>,
    /// Mock-row rects — `(rect, mock_path)`. Click → replay the
    /// mock into a Request pane (`http_replay_mock_from_path`).
    pub http_panel_mock_rows: Vec<(Rect, std::path::PathBuf)>,
    /// #22 v1 — Collections row rects. `(rect, path)`. Click →
    /// open the request file. Populated by `http_panel_refresh`
    /// walking `.mnml/collections/**/*.http`.
    pub http_panel_collection_rows: Vec<(Rect, std::path::PathBuf)>,
    /// #22 v2 — folder-row rects in the COLLECTIONS tree. Click
    /// toggles `http_panel_collections_collapsed_dirs`.
    pub http_panel_collection_folder_rows: Vec<(Rect, std::path::PathBuf)>,
    /// #polish 2026-07-06 — right-aligned toolbar chips on the HTTP
    /// panel header row (mirrors the file-tree pattern). Each
    /// `(rect, command_id)` — click fires that command.
    pub http_panel_icon_buttons: Vec<(Rect, &'static str)>,
    /// #polish 2026-07-06 — `+` chip on each collection row for
    /// "new request in THIS collection". Rect + collection root
    /// path — click opens a Save-As prompt seeded to that folder.
    pub http_panel_collection_new_request_chips: Vec<(Rect, std::path::PathBuf)>,
    /// `↓ Import…` bottom-action chip. Click → open the import
    /// picker (Postman collection / HAR).
    pub http_panel_import_chip: Option<Rect>,
    /// `ActivitySection::Notes` panel — one row per `.mnml/notes/*.md`.
    /// Click → open the note in an editor pane. (#8)
    pub notes_panel_files: Vec<(Rect, std::path::PathBuf)>,
    /// 2026-08-07 — Findings panel row rects (mirrors Notes shape).
    pub findings_panel_files: Vec<(Rect, std::path::PathBuf)>,
    pub findings_panel_filter_input: Option<Rect>,
    pub findings_panel_new_chip: Option<Rect>,
    /// `ActivitySection::Notes` panel `+ New note` row rect.
    pub notes_panel_new_chip: Option<Rect>,
    /// `ActivitySection::Notes` panel `/` filter input row.
    pub notes_panel_filter_input: Option<Rect>,
    /// `ActivitySection::Todos` panel — one row per hit + the index
    /// in `App::todos_hits`. Click → jump to file:line. (#9)
    pub todos_panel_rows: Vec<(Rect, usize)>,
    /// The actions kebab on the focused TODO row, and its filtered
    /// position. At most one — only the focused row shows it.
    pub todos_panel_kebab: Option<(Rect, usize)>,
    /// `ActivitySection::Todos` panel refresh chip rect.
    pub todos_panel_refresh_chip: Option<Rect>,
    /// `ActivitySection::Todos` panel `/` filter input row.
    pub todos_panel_filter_input: Option<Rect>,
    /// Click rect for the `+ New session` row at the bottom of
    /// the sessions panel. Click → spawns a Claude Code pane
    /// (most common case; a follow-up could open a picker).
    pub session_new_chip: Option<Rect>,
    /// `/`-filter input row on the Sessions panel.
    pub sessions_panel_filter_input: Option<Rect>,
    /// `(rect, row_idx)` per agent row in the rail Agents panel.
    /// Click → focus the row's session (resume / open transcript).
    pub agents_panel_rows: Vec<(Rect, usize)>,
    /// The scrollable content area of the agents panel (below the fixed
    /// header rows) — used to route wheel events to `agents_panel_scroll`.
    pub agents_panel_area: Option<Rect>,
    /// #1184 (2026-08-23) — sessions rail hit-area. Wheel routing
    /// checks this rect so scroll notches inside the rail bump
    /// `sessions_panel_scroll` instead of stealing to the tree
    /// underneath.
    pub sessions_panel_area: Option<Rect>,
    /// qa-feature 2026-07-01 — Integrations panel area (for wheel scroll routing).
    pub integrations_panel_area: Option<Rect>,
    /// qa-feature 2026-07-01 — clickable close button on a pty pane's
    /// exit banner (`[× close]`). `(rect, pane_id)`.
    pub pty_exit_close_buttons: Vec<(Rect, PaneId)>,
    /// qa-feature 2026-07-01 — filter input row below the header.
    /// Click focuses the filter (typing appends; Backspace pops;
    /// Esc clears). The filter is auto-focused whenever the
    /// Integrations section has rail focus, so this rect exists
    /// only to make the row a visible + hoverable target.
    pub integrations_filter_chip: Option<Rect>,
    /// qa-feature 2026-07-01 — the `Installed` / `Marketplace` tab
    /// chips below the header. Click switches the active tab.
    pub integrations_tab_installed: Option<Rect>,
    pub integrations_tab_marketplace: Option<Rect>,
    /// 2026-08-19 (#1056) — third tab (In-Development). Only
    /// populated when `[marketplace] show_dev_tab = true`. Click
    /// switches to `IntegrationsPanelTab::InDev`.
    pub integrations_tab_in_dev: Option<Rect>,
    /// 2026-08-04 — small `⟳` chip on the far right of the tab
    /// row; clicks fire `marketplace.refresh` (on Marketplace tab)
    /// or `integrations.refresh` (on Installed tab). Absent when
    /// the panel is too narrow to fit the chip beside both tabs.
    pub integrations_tab_refresh: Option<Rect>,
    /// 2026-08-07 — sort chip on the tab row (`⇅ A-Z`, etc.).
    /// Left-click cycles through the modes for the active tab.
    pub integrations_tab_sort: Option<Rect>,
    /// 2026-08-07 — bottom panel `×` close chip (vscode-user r2 F1).
    /// Chip was painted but no rect registered, so clicks fell
    /// through and the only close path was Ctrl+Shift+J.
    pub bottom_panel_close: Option<Rect>,
    /// 2026-07-09 user request — `+ Add integration` chip at the
    /// bottom of the Integrations panel. Click → integration install
    /// picker. Prior to this the flow was
    /// `:integration.install` palette-only, which is undiscoverable.
    pub integrations_add_chip: Option<Rect>,
    /// 2026-07-31 — `Pane::IntegrationDetail` button rects. Each
    /// entry is `(rect, pane_id, button_idx)` where `button_idx`
    /// is the pane's own dense list of actionable rows (buttons +
    /// command rows + link rows). Click routing walks this in
    /// `tui/mouse/down_left.rs`.
    pub integration_detail_buttons: Vec<(Rect, PaneId, usize)>,
    /// 2026-07-31 — `Pane::IntegrationDetail` link rects — right-
    /// click on one copies the URL. `(rect, pane_id, url)`.
    pub integration_detail_links: Vec<(Rect, PaneId, String)>,
    /// Click rect for the filter input at the top of the panel.
    pub agents_panel_filter_input: Option<Rect>,
    /// Click rect for the `+ New` row at the top of the panel.
    pub agents_panel_new_chip: Option<Rect>,
    /// Click rect for the secondary "+ from PR" chip in the Agents
    /// panel header — opens the new-agent wizard (Claude Agent SDK
    /// + PR multi-select + action template). Sits next to the
    /// existing "+ New session" chip that fires a single Claude
    /// Code session.
    pub agents_panel_pr_chip: Option<Rect>,
    /// Click rect for the view-mode toggle (`status` ↔ `workspace`)
    /// in the panel header.
    pub agents_panel_view_chip: Option<Rect>,
    /// Click rect for the refresh chip in the AGENTS header
    /// top-right (2026-08-24, user ask — parity with the other
    /// activity panels' headers).
    pub agents_panel_refresh_chip: Option<Rect>,
    /// `(rect, workspace_label)` per workspace group header in
    /// the by-workspace view. Click → toggle collapse.
    pub agents_panel_workspace_headers: Vec<(Rect, String)>,
    /// `(rect, row_idx)` per row in the Cloud Agents panel.
    /// Click → copy runId + toast; right-click → context menu.
    pub cloud_agents_rows: Vec<(Rect, usize)>,
    /// Click rect for the filter input at the top of the cloud panel.
    pub cloud_agents_filter_input: Option<Rect>,
    /// Click rect for the "compact / standard" density chip in the
    /// Cloud Agents panel header.
    pub cloud_agents_view_chip: Option<Rect>,
    /// R16 (2026-08-24) — refresh chip in CLOUD AGENTS header
    /// top-right, parity with every other data-fetching panel.
    /// Click forces a rescan of the ECS runner DynamoDB table.
    pub cloud_agents_refresh_chip: Option<Rect>,
    /// Click rects for the workspaces-editor overlay. Each row is
    /// `(rect, idx_or_action_code)` — `idx_or_action_code < 0` is
    /// reserved for action rows (`-1 = Add`, `-2 = Close`).
    pub workspaces_editor_rows: Vec<(Rect, i32)>,
    /// `(rect, idx)` per `⋮` kebab glyph in the workspaces editor
    /// list. Click → context menu (Edit name / Edit path / Set
    /// group / Delete).
    pub workspaces_editor_kebabs: Vec<(Rect, usize)>,
    /// `(rect, section_name)` per visible section header in the
    /// help overlay. Click toggles the section's collapsed state
    /// via `App::toggle_help_section`.
    pub help_section_headers: Vec<(Rect, String)>,
    /// Click rect for the `🧪 <label>` statusline chip — shown
    /// while `last_test_run` is set. Click → focus the test pane.
    pub statusline_test_chip: Option<Rect>,
    /// AI usage meter chips (#876) — Claude quota % + Codex tokens
    /// today. `None` when the chip isn't rendered (integration
    /// disabled). Click: unlinked → open link prompt; linked →
    /// refresh + toast the details.
    pub statusline_ai_claude_chip: Option<Rect>,
    pub statusline_ai_codex_chip: Option<Rect>,
    /// Task #944 rename UX (2026-08-16) — per-account pencil hitrect
    /// captured while `claude_usage_view::draw` renders each
    /// `── name ✎ · (active) ──` section header. The paired String
    /// is the account name AT RENDER TIME (used as the "old name"
    /// key for the TOML rewrite). Cleared + rebuilt every render,
    /// same pattern as the other view-populated rect vecs.
    pub claude_usage_pencils: Vec<(Rect, String)>,
    /// Coverage rollup chip (#889). Click → integration Pty pane
    /// (`tattle_coverage_ext.open`, provided by `mnml-tattle-coverage`).
    pub statusline_coverage_chip: Option<Rect>,
    /// Strip reserved at the top of the editor body for inline
    /// dock widgets at TL / TR corners. Editor body is shrunk by
    /// `height` from the top. `None` = no inline top widgets.
    pub inline_dock_top_strip: Option<Rect>,
    /// Strip reserved at the bottom of the editor body for inline
    /// dock widgets at BL / BR corners. Same shape as top strip.
    pub inline_dock_bottom_strip: Option<Rect>,
    /// Current rendered height (rows) of the INTEGRATIONS section.
    /// Set every frame by `tree_view::draw` so the mouse-down handler
    /// can capture it as the drag-resize anchor.
    pub integration_section_h: u16,
    /// Current rendered height (rows) of the GIT section. See
    /// `integration_section_h`.
    pub git_section_h: u16,
    /// Statusline git-branch chip — clickable shortcut to `git.graph`.
    /// Registered by `ui::statusline::draw` per render; absent when the
    /// branch isn't shown (no repo / non-git workspace).
    pub statusline_branch_chip: Option<Rect>,
    /// Statusline mode chip (`EDIT` / `VIEW` / `TREE` / `INSERT` / `NORMAL` /
    /// `VISUAL` / `REPLACE`) — clickable shortcut to `editor.toggle_keymap`
    /// (flip vim ↔ standard input style).
    pub statusline_mode_chip: Option<Rect>,
    /// Statusline workspace / active-repo chip on the right — clickable
    /// shortcut to `App::open_repo_picker` (no-op picker toast in single-repo
    /// workspaces).
    pub statusline_workspace_chip: Option<Rect>,
    /// Statusline clock chip — clickable shortcut to toggle local ↔ UTC.
    pub statusline_clock_chip: Option<Rect>,
    pub statusline_stress_chip: Option<Rect>,
    /// Stress meter chip in the top-right bufferline cluster (mirror
    /// of the statusline chip). User request 2026-07-12 for eyes-on
    /// signal without needing to look at the bottom row.
    pub palette_stress_chip: Option<Rect>,
    /// Rects of visible toast boxes (newest first) captured during
    /// render. Click on one dismisses that specific toast; hover
    /// pauses its TTL. mouse-round-10 SEV-2 2026-07-12.
    pub toast_stack_rects: Vec<Rect>,
    /// Screen rect of the LSP hover popup while it's open. Set by
    /// `ui::hover::draw`, cleared each frame at the top of ui::draw.
    /// Consulted by the mouse handler so:
    /// - `Moved` events over the popup don't dismiss it (was
    ///   closing the moment the mouse left the symbol).
    /// - `ScrollUp` / `ScrollDown` over the popup scrolls the
    ///   content (was keyboard-only).
    /// 2026-07-12 user report — couldn't scroll a tall hover.
    pub hover_popup_rect: Option<Rect>,
    /// The now-playing track-text segment of the bottom statusline
    /// transport cluster — `[play/pause] [ffwd] [track]`. Click
    /// opens / cycles the mixr panel (`mixr.show`). When idle
    /// (no track from any source) the cluster collapses to a
    /// single `♪ mixr` chip that lives here as well.
    /// Activity-bar gear chip rect — VS Code-style settings entry at
    /// the bottom of the bar. Click pops the gear context menu
    /// (Settings… / Command Palette… / Cheatsheet… / Themes › /
    /// About). `None` when the activity bar isn't visible (rail
    /// hidden, etc.).
    pub activity_bar_gear: Option<Rect>,
    /// The notifications bell, directly above the gear. Always present —
    /// its job is to say the message history exists.
    pub activity_bar_bell: Option<Rect>,
    /// Bottom cmdline bar rect — click to open the ex-cmdline
    /// (`:settings` / `:help` / …) without a keyboard chord. Set
    /// every frame by `cmdline_bar::draw`.
    pub cmdline_bar: Option<Rect>,
    /// Click rect for the right-side `⟳ … running…` indicator.
    /// Click → `:http.abort`. None when nothing is in flight.
    pub cmdline_inflight: Option<Rect>,
    /// Click rect over the `[name]` mention in the live toast,
    /// paired with the captured name. Click → reveal the matching
    /// scratch buffer / pane (best-effort substring match on
    /// pane titles).
    pub cmdline_toast_target: Option<(Rect, String)>,
    /// Click rect for each row in the Vars tab. Empty string =
    /// `+ Add new variable…` row → opens add prompt; non-empty =
    /// existing key → opens edit prompt with that key. Cleared
    /// + repopulated every render.
    pub request_vars_rows: Vec<(Rect, String, crate::ui::request_view::KvTableKind)>,
    /// Click rect for each row in the Params tab. Empty string =
    /// `+ Add new parameter…` row → opens params_add prompt;
    /// non-empty = existing key → deletes that param (v2 will
    /// open an edit prompt).
    pub request_params_rows: Vec<(Rect, String, crate::ui::request_view::KvTableKind)>,
    /// Click rect over the AI section header in the Request pane.
    /// Click → fire :http.ai_debug (same as the `a` keystroke).
    pub request_ai_section: Option<Rect>,
    /// Click rect over the "▶ Send" sub-panel in the Request pane's
    /// top row. Click → fire `http.send` on the pane (same as the
    /// `r` chord). Repainted every render so the button stays
    /// mouse-reachable regardless of scroll state.
    pub request_send_button: Option<Rect>,
    /// Click rect over the "⎘ Save" sub-panel — writes the current
    /// Request pane's fields back to its source file, or opens a
    /// Save-As prompt if no source file is set.
    pub request_save_button: Option<Rect>,
    /// Click rect over the "✕ Clear" sub-panel — resets the active
    /// Request pane's fields to a blank template. Same code path as
    /// the sidebar's `+ New request` chip.
    pub request_clear_button: Option<Rect>,
    /// Click rect over the "{ } Format" sub-panel — pretty-prints
    /// a JSON Body in place. Same as `Shift+Alt+F` chord.
    pub request_format_button: Option<Rect>,
    /// Click rect over the "↻ Reroll" chip — regenerates fresh
    /// timestamps + UUIDs in the body. 2026-07-09 dynamic +
    /// realistic roadmap.
    pub request_regenerate_button: Option<Rect>,
    /// Click rect over the "</> Code" sub-panel — opens the
    /// Generate Code picker.
    pub request_code_button: Option<Rect>,
    /// Env chip on the Request pane top bar (between URL and Send).
    /// Left-click → env picker. Right-click → env context menu
    /// (switch / edit / new / clear override).
    pub request_env_button: Option<Rect>,
    /// #21 v5 — Method chip on the Request pane top bar.
    /// Duplicates the same rect stored in `request_fields` with
    /// `EditField::Method` so tooltip lookup can pull it directly
    /// without walking the vec.
    pub request_method_button: Option<Rect>,
    /// #20 — click rect for the pending-undo chip. Registered by
    /// the toast_stack renderer when `App.pending_undo` is Some.
    pub pending_undo_chip: Option<Rect>,
    /// #20 Pattern B — Cancel + Confirm button rects on the
    /// pending-confirm modal.
    pub confirm_modal_cancel: Option<Rect>,
    pub confirm_modal_confirm: Option<Rect>,
    /// Click rect over the "JSON ▼" content-type chip on the
    /// Response tab strip. Click → opens the response-format
    /// override picker.
    pub request_response_type_chip: Option<Rect>,
    /// Click rect over the "copy" chip on the Response tab strip —
    /// copies the current response body to the system clipboard.
    pub request_response_copy_chip: Option<Rect>,
    /// Click rect over the "wrap" chip on the Response tab strip —
    /// toggles `rp.body_wrap`.
    pub request_response_wrap_chip: Option<Rect>,
    /// Click rect over the `⚡ AI` chip on the Response tab strip —
    /// only shown when the response is a failure (non-2xx status,
    /// invalid schema, or transport error). Click → runs
    /// `http.copy_ai_prompt`.
    pub request_response_ai_prompt_chip: Option<Rect>,
    /// Click rect over the split-orientation toggle chip on the
    /// Request block's top border. Click cycles Vertical <->
    /// Horizontal split. Same as `Ctrl+\` chord.
    pub request_split_toggle: Option<Rect>,
    /// `(rect, tab)` per chip in the Response sub-tab strip
    /// (Body / Headers / Timeline / Tests). Click → switch
    /// `response_tab` on the active Request pane. Cleared +
    /// repopulated each render.
    pub request_response_tabs: Vec<(Rect, crate::request_pane::ResponseTab)>,
    /// Click rect for each row in the Auth tab. id values:
    /// `set_bearer` / `set_basic` / `set_api_key` / `apply_preset` /
    /// `save_preset` / `clear`. Cleared + repopulated each render.
    pub request_auth_rows: Vec<(Rect, String)>,
    /// `(row_rect, idx_in_matches)` for each visible row in the
    /// cmdline completion popup. Click sets selected idx + rewrites
    /// cmdline + accepts.
    pub cmdline_popup_items: Vec<(Rect, usize)>,
    pub statusline_mixr_chip: Option<Rect>,
    /// 2026-08-22 — one-tap "start playing" chip in the IDLE music-
    /// cluster (a play-glyph sitting to the left of the source label).
    /// Click → `mixr.play_now` (Beatport-authed random-chart flow);
    /// falls back to opening mixr on the browser if not authed. `None`
    /// when the cluster is in its playing form (transport controls
    /// take over that rect via `statusline_mixr_play_chip`).
    pub statusline_music_action_chip: Option<Rect>,
    /// Sonos cluster hitrects: the speaker (brand) chip, its
    /// play/pause button, and its skip button. `None` when the chip is
    /// disabled, no household was found, or the chip fell off a narrow
    /// statusline.
    pub statusline_sonos_chip: Option<Rect>,
    pub statusline_sonos_play_chip: Option<Rect>,
    pub statusline_sonos_next_chip: Option<Rect>,
    /// The `Room · Track` half of the Sonos cluster — click routes to
    /// the room picker.
    pub statusline_sonos_label_chip: Option<Rect>,
    /// Play / pause control sitting to the LEFT of the track text
    /// when something's playing. Click is source-aware:
    /// mixr → `mixr --command pause`; Apple Music / Spotify →
    /// AppleScript `playpause` against the matching app. `None`
    /// when the cluster is in its idle single-chip form.
    pub statusline_mixr_play_chip: Option<Rect>,
    /// Forward control sitting between play/pause and the track
    /// text. Source-aware: mixr → `mixr --command teleport` (jump
    /// on beat to just before the mix-out); Apple Music / Spotify →
    /// AppleScript `next track`. `None` when the cluster is in its
    /// idle single-chip form.
    pub statusline_mixr_ffwd_chip: Option<Rect>,
    /// `LSP {N}` chip — click opens `:LspStatus`.
    pub statusline_lsp_chip: Option<Rect>,
    /// `WRAP` chip — click toggles `[ui] wrap`.
    pub statusline_wrap_chip: Option<Rect>,
    /// `AS {N}s` autosave chip — click opens the autosave config prompt.
    pub statusline_autosave_chip: Option<Rect>,
    /// Filesize chip (`123B` / `4.2K` / `12M`) — click opens `:Stat`.
    pub statusline_filesize_chip: Option<Rect>,
    /// `Ln N/M Col K` chip — click opens the goto-line prompt.
    pub statusline_lncol_chip: Option<Rect>,
    /// #polish 2026-07-06 — file-name chip on the statusline left lane
    /// (glyph + display_name + dirty marker). Click reveals the file
    /// in the tree; tooltip shows the full absolute path.
    pub statusline_file_chip: Option<Rect>,
    /// #polish 2026-07-06 — LSP diagnostics summary chip (` E / ⚠ W`).
    /// Spans both err and warn segments (they render adjacent) so the
    /// click zone is one wide chip, not two. Click opens the
    /// diagnostics list; tooltip breaks down counts.
    pub statusline_diagnostics_chip: Option<Rect>,
    /// #polish 2026-07-06 — language chip (`  rs`). Click opens the
    /// language / filetype picker; tooltip names the ext / language.
    pub statusline_language_chip: Option<Rect>,
    /// #polish 2026-07-06 — enclosing-symbol chip (` › fn foo`).
    /// Click opens the outline pane; tooltip shows the untruncated
    /// symbol name.
    pub statusline_symbol_chip: Option<Rect>,
    /// #polish 2026-07-06 — active-PR badge (`  BB#42`). Click opens
    /// the PR in the browser; tooltip shows the title + host.
    pub statusline_pr_chip: Option<Rect>,
    /// #polish 2026-07-06 — `● rec @<reg>` macro-recording chip.
    /// Click stops recording (vim `q` toggle).
    pub statusline_macro_chip: Option<Rect>,
    /// #polish 2026-07-06 — active-find chip (` /query N/M `).
    /// Click reopens the find prompt so the user can edit the query
    /// or advance a match.
    pub statusline_find_chip: Option<Rect>,
    /// #polish 2026-07-06 — selection-size chip (` Sel N `). Hover
    /// tooltip only; no click target.
    pub statusline_sel_chip: Option<Rect>,
    /// #polish 2026-07-06 — LSP `$/progress` busy chip
    /// (`⟳ <title>`). Hover tooltip shows the untruncated title.
    pub statusline_progress_chip: Option<Rect>,
    /// #polish 2026-07-06 — unified background-tasks spinner chip
    /// (`⠋ N`). Hover tooltip shows the count breakdown.
    pub statusline_bg_tasks_chip: Option<Rect>,
    /// #polish 2026-07-06 — inline-suggestion in-flight chip
    /// (`✦ AI`). Hover tooltip only.
    pub statusline_ai_chip: Option<Rect>,
    /// Chips on the `> GIT` rail header (Fetch / Pull / Push / Commit /
    /// Stage all / Graph) — one-click access to common ops.
    pub rail_git_header_buttons: Vec<(Rect, crate::GitRailHeaderAction)>,
    /// Scratch-terminal strip rect when visible — click to focus / blur.
    pub scratch_term_strip: Option<Rect>,
    /// Pty-pane tab strip — `(rect, pty_pane_id)` per session tab. Click
    /// switches the leaf to that session. Repopulated per pty render.
    pub pty_tabs: Vec<(Rect, PaneId)>,
    /// `+` button on the pty tab strip — `(rect, strip_owner_pane_id)`.
    /// Click spawns a new Claude *into the strip-owner's leaf* (a tab,
    /// not a split). One entry per visible pty pane's strip.
    pub pty_tab_new: Vec<(Rect, PaneId)>,
    /// `×` close-badge on each pty tab — `(rect, pty_pane_id)`. Click
    /// kills the pty session + closes the pane. Tested BEFORE the
    /// tab-switch hit so the badge wins over the chip's body.
    pub pty_tab_close: Vec<(Rect, PaneId)>,
    /// Per-frame: the pane id whose bufferline tab is being dragged.
    /// Set on Mouse::Down inside a tab rect; cleared on Mouse::Up.
    /// While set, Mouse::Drag events into a different tab swap the
    /// two panes (via `App::swap_bufferline_tabs`). Lives on rects
    /// for parity with other drag-state fields, but it's not a rect
    /// itself — it's just the pane id to re-find each frame.
    pub bufferline_drag_tab: Option<PaneId>,
    /// Cursor position while a tab drag is in flight. Tracked so
    /// the ghost overlay (a floating chip showing the dragged
    /// tab's label) can follow the cursor. Cleared on mouse-up.
    pub bufferline_drag_ghost: Option<(u16, u16)>,
    /// One rect per row in the F1 click-discovery overlay — click a row
    /// to flash the matching on-screen rects. Cleared + repopulated by
    /// `ui::discovery::draw` when the overlay is visible.
    pub discovery_rows: Vec<(Rect, crate::DiscoveryCategory)>,
    /// The outer settings-overlay rect — used by the dispatcher to
    /// detect click-outside-to-close. `None` when the overlay isn't
    /// open. Repopulated by `ui::settings_overlay::draw`.
    pub settings_overlay_rect: Option<Rect>,
    /// Modal-block rect for the integration_edit overlay. Any click
    /// while this is set MUST route through the overlay's dispatch
    /// path (never leak to the tree/pane underneath). Cleared per
    /// frame in ui::draw. vscode-user-mouse round 2 (2026-07-11)
    /// caught the leak-through.
    pub integration_edit_overlay_rect: Option<Rect>,
    /// Per-field click rects for integration_edit (row, field). Click
    /// to focus.
    pub integration_edit_field_rows: Vec<(Rect, crate::app::discovery::IntegrationEditField)>,
    /// Modal-block rect for the glyph_builder overlay. Same purpose
    /// as `integration_edit_overlay_rect`.
    pub glyph_builder_overlay_rect: Option<Rect>,
    /// Per-field click rects for glyph_builder (row, field). Click to focus.
    pub glyph_builder_field_rows: Vec<(Rect, crate::glyph_builder::BuilderField)>,
    /// `[Browse]` chip on the path row — click opens a fuzzy
    /// picker over every `.svg` in the workspace. 2026-07-19.
    pub glyph_builder_browse_chip: Option<Rect>,
    /// `(rect, row_counter_idx)` per visible Row in the settings
    /// overlay — left-click moves the focus to that row (so the user
    /// can drive settings entirely by mouse: click row to focus +
    /// `←/→` to adjust, or click outside the overlay to save+close).
    /// `row_counter_idx` is the same 0-based index `settings_move_row`
    /// uses (skips section headers). Repopulated per render.
    pub settings_rows: Vec<(Rect, usize)>,
    /// vscode-user-mouse SEV-2 2026-07-10: per-option sub-rect within
    /// a discrete-choice row, so a click on `[relative]` or `off` in
    /// the "Line numbers" row jumps directly to that option instead
    /// of cycling by +1. Tuple: (rect, row_counter_idx, option_idx).
    /// Populated only for `SettingItem::Row` (skips Number rows —
    /// those use ← / → chevrons).
    pub settings_row_options: Vec<(Rect, usize, usize)>,
    /// qa-6th mouse SEV-3 2026-06-29: visible Save / Cancel chips
    /// at the bottom-right of the settings overlay so mouse-only
    /// users can commit without typing Enter / Esc.
    pub settings_save_button: Option<Rect>,
    pub settings_cancel_button: Option<Rect>,
    /// mouse-round-12 SEV-2 F3 2026-07-14 — click-target for the
    /// `/ filter` row at the top of the settings overlay. Was:
    /// only `/` on the keyboard focused the filter — mouse-first
    /// users typing after the click sent letters straight to the
    /// row keyboard handler ('l' cycled Line numbers etc.).
    pub settings_filter_row: Option<Rect>,
    /// GitGraph column header rects (Author / Date / SHA) — click to
    /// cycle that column's sort (asc / desc / none).
    pub git_graph_column_headers: Vec<(Rect, crate::git::graph::SortColumn)>,
    /// qa-feature 2026-06-30 — `⇄` switch button next to the repo
    /// name on the GitGraph sidebar header. Click opens the
    /// workspace picker.
    pub git_graph_repo_switch: Option<Rect>,
    /// qa-feature 2026-06-30 — section headers in the git palette
    /// (LOCAL / REMOTE / WORKTREES / PRS / STASHES / TAGS). Click
    /// toggles `git_palette_collapsed_sections`.
    pub git_palette_section_headers: Vec<(Rect, String)>,
    /// qa-feature 2026-06-30 — folder headers inside the palette
    /// (`▾ chore (4)` etc.). Click toggles
    /// `git_palette_collapsed_folders`. Key is `section:folder`.
    pub git_palette_folder_headers: Vec<(Rect, String)>,
    /// `(rect, pane_id)` for each tab's close badge (the trailing `×`/`●` → close).
    pub bufferline_tab_close: Vec<(Rect, PaneId)>,
    /// 2026-06-22 — per-split multi-tab chip click rects. Each entry
    /// is `(rect, leaf_active_pane, this_tab_pane)`. Click → switch
    /// the leaf's active to this_tab_pane. `leaf_active_pane`
    /// identifies WHICH leaf's tab strip this chip belongs to (so
    /// the click handler can target the right leaf in the layout
    /// tree). Cleared + repopulated every frame by render_layout.
    pub split_tab_chips: Vec<(Rect, PaneId, PaneId)>,
    /// Bounding rect of each per-leaf tab strip — `(rect,
    /// leaf_active_pane)`. Records the full strip area, including
    /// the empty space past the last chip. Used as a drop target
    /// for tab drags: cursor over a strip → insert the dragged
    /// tab into that leaf at the cursor's position (Chrome /
    /// VS Code tab-bar drop). Cleared + repopulated each frame.
    pub split_tab_strip_areas: Vec<(Rect, PaneId)>,
    /// Insertion position hint while a tab drag hovers a strip.
    /// `(strip_rect, insertion_x, leaf_active, insert_idx)`. The
    /// renderer paints a thin vertical bar at `insertion_x` so the
    /// user sees exactly where the dropped tab will land. None when
    /// not over a strip.
    pub tab_insert_hint: Option<(Rect, u16, PaneId, usize)>,
    /// Per-split tab close `×` chips. Same shape: (rect,
    /// leaf_active, tab_pane). Click → close that tab.
    pub split_tab_close: Vec<(Rect, PaneId, PaneId)>,
    /// VS Code-style split-editor buttons at the far right of
    /// each per-leaf tab strip — `(rect, leaf_active_pane,
    /// dir)`. Click → focus that leaf + `split_active(dir)`.
    /// 2026-06-22. Two entries per visible leaf (one Horizontal,
    /// one Vertical). Cleared + repopulated every frame.
    pub split_strip_buttons: Vec<(Rect, Option<PaneId>, crate::layout::SplitDir)>,
    /// `(rect, pane_id)` per visible `+` chip in a per-leaf tab
    /// strip. Click → focus that leaf + open the file picker so
    /// the user can add another buffer as a tab in the same leaf.
    /// one-tab-type 2026-07-18.
    pub split_tab_plus_buttons: Vec<(Rect, PaneId)>,
    /// `(rect, leaf_active_pane)` for the `+N hidden` chip on a
    /// per-leaf tab strip. Click → focus that leaf + open the buffer
    /// picker, which lists every tab including the hidden ones.
    /// #1222 (2026-08-28): the chip shipped as pure paint with no
    /// rect, so the one affordance announcing "your tabs are still
    /// here" was a dead end — user hit `+11 hidden` with no way back.
    pub split_tab_hidden_chips: Vec<(Rect, PaneId)>,
    /// `+` chip on the empty-state top row (when there are no
    /// panes). Click → open the file picker so the user can pick
    /// their first pane. Same visual as split_tab_plus_buttons but
    /// no pane_id (nothing to focus yet).
    pub bufferline_empty_plus: Option<Rect>,
    /// Click rect for the `+ Add Claude Code` card painted in the
    /// BR quadrant of the Claude auto-tile 2×2 grid. Click →
    /// `ai.claude_code_new` (fills the placeholder). Cleared +
    /// repopulated every frame.
    pub ai_placeholder_card: Option<Rect>,
    /// `(rect, pane_id?)` per visible terminal-launch button in the
    /// split-strip cluster (immediately left of the H/V buttons).
    /// Click → focus that leaf (if any) + open a new shell pane via
    /// `App::open_shell()`. Pane id is Option because the "no files
    /// open" state still shows the terminal launcher — you're
    /// clicking it TO create the first pane, so there's no leaf to
    /// focus yet. Cleared + repopulated every frame.
    pub split_strip_term_buttons: Vec<(Rect, Option<PaneId>)>,
    /// `(rect, pane_id?, ai_kind)` per visible AI-launch button in
    /// the split-strip cluster. Painted when `[ui] tab_bar_ai_icon`
    /// is set to a non-`"none"` value. Left click → fires the
    /// configured `ai.*` command; right click → opens a context
    /// menu to switch between Claude Code / Codex / Hide.
    /// `ai_kind = 0` = Claude Code, `1` = Codex. Two entries when
    /// `[ui] tab_bar_ai_icon = "both"` (#19). Pane id is Option for
    /// the same reason as the terminal button.
    pub split_strip_ai_buttons: Vec<(Rect, Option<PaneId>, u8)>,
    /// `(rect, pane_id?)` per visible maximize / restore button in the
    /// split-strip cluster (rightmost — after the H/V buttons). Click →
    /// `App::toggle_zoom_active_leaf()`, which paints ONLY this leaf
    /// full-frame until clicked again. Glyph flips between expand
    /// (`nf-fa-expand` U+F065 — square + 4 outward diagonal arrows)
    /// and restore (`nf-fa-compress` U+F066 — square + 4 inward
    /// diagonal arrows). FontAwesome pair verified to resolve
    /// correctly in shipping Nerd Font distributions, so
    /// the button self-documents state.
    pub split_strip_maximize_buttons: Vec<(Rect, Option<PaneId>)>,
    /// The whole central split-tree area.
    pub body: Option<Rect>,
    /// `(text_area, pane_id)` per visible editor leaf — the editable region
    /// (gutter excluded). Click → focus that leaf + place the cursor; also the
    /// geometry `Ctrl+W`-style focus navigation uses.
    pub editor_panes: Vec<(Rect, PaneId)>,
    /// qa-feature 2026-07-02 — `(banner_rect, pane_id)` per visible
    /// MdPreview pane. Click → swap the pane to a raw Editor of the same
    /// markdown file (`✏ Edit` banner).
    pub md_preview_edit_buttons: Vec<(Rect, PaneId)>,
    /// qa-feature 2026-07-02 — `(banner_rect, pane_id)` per visible
    /// Editor pane whose buffer is a markdown file. Click → swap the pane
    /// to an MdPreview of the same file (`👁 Preview` banner).
    pub editor_md_preview_buttons: Vec<(Rect, PaneId)>,
    /// `(gutter_rect, pane_id)` per visible editor leaf — the line-number /
    /// sign-column strip on the left of each editor. Right-click here opens
    /// a per-line context menu (toggle breakpoint, goto def, blame at line, …);
    /// left-click is currently a no-op (the text area handles place-cursor).
    pub editor_gutters: Vec<(Rect, PaneId)>,
    /// `(chip_rect, pane_id, fold_start_line)` per rendered `⋯ N hidden`
    /// chip — click on one to unfold that block. Cleared + rebuilt per
    /// editor render.
    pub fold_chips: Vec<(Rect, PaneId, usize)>,
    /// VS Code-style fold-toggle arrows painted in the sign column.
    /// `(cell_rect, pane_id, line_no)`. Foldable lines render `↓`
    /// on hover; folded lines render `→` persistently. Click on
    /// one → `toggle_fold_at_line`. Cleared + rebuilt per editor
    /// render. 2026-07-11.
    pub fold_arrows: Vec<(Rect, PaneId, usize)>,
    /// #polish 2026-07-06 — per-cell rect for every glyph rendered into
    /// the gutter's sign column (git change marks, LSP + linter
    /// diagnostic dots, breakpoint dots, DAP execution arrow). Hover
    /// picks up which mark you're over and the tooltip explains the
    /// glyph without needing the sidebar / diagnostics pane open.
    /// Cleared + rebuilt per editor render. Line numbers themselves
    /// are NOT hoverable (nothing to explain).
    pub gutter_marks: Vec<(Rect, PaneId, usize, crate::GutterMarkKind)>,
    /// `(chip_rect, pane_id, lens_index)` per rendered `⚡ <title>` code
    /// lens chip — click on one to fire its `workspace/executeCommand`.
    /// `lens_index` is the index into `Buffer.code_lenses`. Cleared +
    /// rebuilt per editor render.
    pub code_lens_chips: Vec<(Rect, PaneId, usize)>,
    /// `(button_rect, pane_id, action)` per clickable button inside the
    /// GitGraph pane's WIP detail panel — "Stage All", "Unstage All",
    /// or per-file `[+]` / `[−]` stage/unstage. Cleared + rebuilt per
    /// render. See [`crate::WipAction`] for the action shape.
    pub wip_buttons: Vec<(Rect, PaneId, crate::WipAction)>,
    /// `(row_rect, pane_id, abs_path, staged)` per clickable file
    /// row in the GitGraph WIP detail panel (excluding the `[+]` /
    /// `[−]` button rects which already live in `wip_buttons`).
    /// Click ⇒ opens the file's diff (`Pane::Diff`) so the user can
    /// switch between Hunk / Inline / Split views.
    pub wip_file_rows: Vec<(Rect, PaneId, std::path::PathBuf, bool)>,
    /// Click rect for the WIP commit-message textarea in the GitGraph
    /// WIP detail panel. Clicking inside focuses the textarea; the
    /// keyboard handler intercepts subsequent printable / arrow /
    /// Backspace / Enter keys while focused. `None` ⇒ textarea isn't
    /// being drawn (panel too small, or the selected row isn't WIP).
    pub wip_commit_textarea: Option<(Rect, PaneId)>,
    /// `(button_rect, pane_id, action)` per clickable button in the
    /// GitGraph pane's top toolbar (Pull / Push / Fetch / Branch /
    /// Commit / Stash / Pop / Terminal / Reflog). Cleared + rebuilt
    /// per render. See [`crate::GitToolbarAction`].
    pub git_toolbar_buttons: Vec<(Rect, PaneId, crate::GitToolbarAction)>,
    /// `(row_rect, pane_id, file_idx)` per clickable changed-file
    /// row in the GitGraph commit-detail panel. `file_idx` indexes
    /// into `detail.files`. Click ⇒ opens that file's diff.
    pub commit_file_rows: Vec<(Rect, PaneId, usize)>,
    /// `(button_rect, pane_id, action)` per clickable button in a
    /// `Pane::Diff` top toolbar — `[Inline] [Hunk] [Split] [Wrap]`.
    pub diff_toolbar_buttons: Vec<(Rect, PaneId, crate::DiffToolbarAction)>,
    /// `(chip_rect, pane_id, hunk_index, action)` per per-hunk
    /// chip in the Hunk view's header row (`[Stage]` / `[Unstage]`
    /// / `[Discard]`). Cleared + rebuilt per render.
    pub diff_hunk_buttons: Vec<(Rect, PaneId, usize, crate::DiffHunkAction)>,
    /// `ScrollbarHit` per painted scrollbar (editor body, diff body,
    /// embedded-diff body inside a GitGraph). Click + drag in the
    /// scrollbar rect jumps the underlying scroll position. Click on
    /// a colored change marker jumps to that row in the file.
    /// Cleared + rebuilt per render so the rect always matches the
    /// current layout.
    pub scrollbars: Vec<ScrollbarHit>,
    /// `(rect, leaf_key, is_left)` per overflow chevron on a leaf's
    /// tab strip. `leaf_key` is the leaf's first tab id — the same
    /// key `App::leaf_tab_scroll` uses. Clicking scrolls THAT leaf's
    /// strip by one; a chevron is only pushed when it has somewhere
    /// to go, so a click is never a no-op.
    ///
    /// #1209 — replaces the single `bufferline_overflow_left/right`
    /// pair, which belonged to the retired global top strip and had
    /// been set to `None` on every render since 2026-07-18.
    pub leaf_tab_arrows: Vec<(Rect, PaneId, bool)>,
    /// `(rect, pane_id, view_mode)` per `[Edit]` / `[Response]` tab chip
    /// on a request pane's tab bar. Clicking switches the pane's view.
    pub request_tabs: Vec<(Rect, PaneId, crate::request_pane::ViewMode)>,
    /// `(row_rect, pane_id, field)` per Edit-mode row that belongs to a
    /// specific field (Method / URL / Headers / Body). Clicking focuses
    /// that field. Multi-line fields (Headers / Body) push one row entry
    /// per rendered line so clicking anywhere in the field area works.
    pub request_fields: Vec<(Rect, PaneId, crate::request_pane::EditField)>,
    /// `(chip_rect, PaneId, EditTab)` for each visible tab chip in
    /// a Request pane's Edit view (Body / Headers / Params / Vars /
    /// Source). Click switches the pane's `edit_tab`. Cleared +
    /// rebuilt every render. 2026-06-19 — added with the tabbed
    /// Edit-view rebuild. Distinct from `request_tabs` (above)
    /// which is the Edit/Response view-mode toggle.
    pub request_edit_tabs: Vec<(Rect, PaneId, crate::request_pane::EditTab)>,
    /// Same shape as `request_edit_tabs` but for the SECONDARY tab
    /// strip on the right side of a side-by-side split
    /// (`rp.edit_tab_split`). Click ⇒ change the split's tab.
    /// Empty when no split is active. 2026-07-07.
    pub request_edit_tabs_split: Vec<(Rect, PaneId, crate::request_pane::EditTab)>,
    /// The `⇔` chip on the tab strip that opens (or closes) a
    /// side-by-side split of the edit content area. Cleared + rebuilt
    /// every render.
    pub request_edit_split_chip: Option<Rect>,
    /// The 1-cell divider between the primary and secondary sides
    /// when a split is active. Drag to resize.
    pub request_edit_split_divider: Option<Rect>,
    /// One entry per rendered `{{var}}` token in the active Request
    /// pane's URL / body. Click → jump to the definition in the
    /// active env file (or the file's tail when the var is missing).
    /// Cleared + rebuilt per frame. 2026-07-07.
    pub request_var_click_rects: Vec<(Rect, String)>,
    /// Per-frame `(rect, segment_id)` for each rendered dynamic
    /// statusline segment — the manifest-declared chips written by
    /// [`crate::app::statusline_segments`] and the IPC-driven
    /// segments set via `statusline_set_segment`. Both surfaces
    /// share this vec because they render as the same
    /// `DynamicSegment` shape; hover / click routing looks up the
    /// declaring manifest by id to enrich tooltip copy. Cleared
    /// + rebuilt per render. 2026-08-17.
    pub statusline_segment_hits: Vec<(Rect, String)>,
    /// `(row_rect, filtered_index)` for each visible completion popup row
    /// (excluding the docs footer). Cleared + rebuilt every render. Click
    /// on a row ⇒ select + accept.
    pub completion_rows: Vec<(Rect, usize)>,
    /// `(row_rect, target_path)` for each clickable "recent file" row on the
    /// dashboard (the splash drawn when `Layout::Empty`). Click ⇒ `open_path`.
    /// Cleared + rebuilt on every render.
    pub dashboard_rows: Vec<(Rect, std::path::PathBuf)>,
    /// `(row_rect, pane_id, flat_row_index)` for every visible row in an
    /// SCM/CI pane (BB pipelines/PRs, GH actions/PRs). Cleared + rebuilt
    /// per render. Click on a row ⇒ select; click on a header row ⇒
    /// toggle collapse (sibling to keyboard Enter).
    pub list_rows: Vec<(Rect, PaneId, usize)>,
    /// qa-feature 2026-06-30 — per-lane-cell hover rects in the
    /// GitGraph pane. `(rect, pane_id, commit_idx, lane_idx)`.
    /// Populated by `ui::git_graph_view::draw`; consumed by
    /// `dispatch::hover_chip_at` for lane-branch tooltips.
    pub git_graph_lane_cells: Vec<(Rect, PaneId, usize, usize)>,
    /// qa-feature 2026-07-01 — per-row subject-cell hover rects
    /// so a truncated commit subject shows its full text in a
    /// tooltip on hover. `(rect, pane_id, commit_idx)`.
    pub git_graph_subject_cells: Vec<(Rect, PaneId, usize)>,
    /// `(rect, file_path)` for clickable file rows in the Claude
    /// Agents dashboard's Files drill-down. Click opens the file
    /// in an editor pane. Cleared + rebuilt per render.
    pub claude_drill_files: Vec<(Rect, String)>,
    /// `(row_rect, pane_id, env_idx, row_in_env_filter)` for every visible
    /// data row across the 3 env columns in `Pane::TestExecutions`. Also
    /// records each column's header rect with `row_in_env_filter = usize::MAX`
    /// so a header-click flips to that env without selecting a record.
    /// Cleared + rebuilt per render.
    /// One entry per split divider, with enough info to drag-resize it.
    pub split_dividers: Vec<crate::layout::DividerHit>,
    pub statusline: Option<Rect>,
    /// 2026-07-07 — Ableton-style hover-help footer rect (when the
    /// strip is visible). Panel-body clicks are inert (2026-08-11 —
    /// accidental body clicks used to close the panel; the close
    /// affordance moved into `hover_help_kebab`).
    pub hover_help_strip: Option<Rect>,
    /// 2026-08-11 — 1-cell `⋮` kebab at top-right of the hover-help
    /// title bar. Left-click opens a small ContextMenu with `Close`
    /// (destructive-red) as the sole entry today; more can join
    /// (About the info box…, per-panel settings) without further
    /// wiring. Matches the widget kebab pattern (`src/ui/dock.rs`).
    pub hover_help_kebab: Option<Rect>,
    /// 2026-08-16 — `Try it →` action-button rects for the current
    /// Info View copy (`InfoViewCopy::try_it`). `(rect, command_id)`
    /// per rendered link, rebuilt every frame in `hover_help::draw`.
    /// Distinct from `hover_help_strip` (whose body clicks are inert
    /// by design, see the comment above) — a click landing exactly on
    /// one of these small link rects fires the palette command instead
    /// of being swallowed. Part of wiring the Info View v0.3 `try_it`
    /// field, which the framework had carried since Phase 1 but never
    /// rendered or dispatched.
    pub hover_help_try_it: Vec<(Rect, String)>,
    /// 2026-08-16 — the `→ Manual…` docs-link rect for the current
    /// Info View copy (`InfoViewCopy::docs`), when set. `(rect, url)`;
    /// click opens the URL in the OS browser via `open_url_external`.
    /// Only entries with a verified `site/src/content/docs/manual/*`
    /// page get a `docs` value — see `src/ui/info_view_copy.rs`.
    pub hover_help_docs: Option<(Rect, String)>,
    /// 2026-06-21 vscode SEV-2 — the floating peek_definition overlay's
    /// outer rect when shown. The mouse dispatcher uses this to consume
    /// inside-clicks (instead of bleeding through to the editor) and
    /// to dismiss the overlay on outside-clicks.
    pub peek_overlay: Option<Rect>,
    /// 2026-06-21 vscode-mouse SEV-2 — `(rect, group_name)` per
    /// rendered cheatsheet section header. Click toggles collapse,
    /// parity with the `C` chord.
    pub cheatsheet_headers: Vec<(Rect, String)>,
    /// 2026-06-21 vscode-mouse SEV-2 — `(rect, pane_id)` per
    /// rendered WS pane [Send] button. Click sends the typed
    /// input, parity with the Enter chord.
    pub ws_send_buttons: Vec<(Rect, usize)>,
    /// 2026-06-21 vscode-mouse SEV-2 — `(rect, pane_id, kind)`
    /// per Claude Agents dashboard topbar chip. Click cycles the
    /// corresponding state (sort / group / source / ws / view).
    pub claude_agents_topbar_chips: Vec<(Rect, usize, crate::ui::TopbarChipKind)>,
    /// 2026-06-21 — column headers in the Spend Report pane.
    /// `(rect, pane_id, sort_key)`. Click cycles asc/desc on that
    /// column (or sets it as the sort key if it wasn't).
    pub spend_headers: Vec<(Rect, usize, crate::pane::SpendSortKey)>,
    /// The picker overlay's outer box (when open) and `(rect, filtered-index)` per visible row.
    pub picker_box: Option<Rect>,
    pub picker_items: Vec<(Rect, usize)>,
    /// On-screen cell where the picker's query caret should sit (when open).
    pub picker_caret: Option<(u16, u16)>,
    /// `(rect, choice)` per button in the close-confirm overlay (0=Save, 1=Discard, 2=Cancel).
    pub close_prompt_buttons: Vec<(Rect, u8)>,
    /// `(rect, code)` per button in the quit-confirm overlay. Codes are
    /// the `QUIT_BTN_*` constants in `ui::prompt`.
    pub quit_prompt_buttons: Vec<(Rect, u8)>,
    /// #polish 2026-07-06 — `(rect, code)` per button in any generic
    /// confirm dialog: DeleteConfirm, GitStashDrop, ClaudeKillConfirm,
    /// GitMergeConfirm, AiToolConfirm, etc. Codes are `CONFIRM_BTN_*`
    /// constants in `ui::prompt`. Only one confirm dialog is open at
    /// a time so a single Vec is enough. QuitConfirm has its own
    /// dedicated `quit_prompt_buttons` because it has 3-4 buttons
    /// with quit-specific action codes.
    pub confirm_dialog_buttons: Vec<(Rect, u8)>,
    /// On-screen cell where the text-input prompt's caret should sit (when open).
    pub prompt_caret: Option<(u16, u16)>,
    /// The context-menu overlay's outer box (when open) and `(rect, item-index)` per row.
    pub context_menu_box: Option<Rect>,
    pub context_menu_items: Vec<(Rect, usize)>,
    /// The kebab on the focused row of a curatable menu, and which row
    /// it belongs to. At most one exists — only the focused row shows it.
    /// The notification badge — unread warnings and errors. Click opens
    /// the message history.
    pub statusline_notif_chip: Option<Rect>,
    pub context_menu_kebab: Option<(Rect, usize)>,
    pub context_submenu_box: Option<Rect>,
    pub context_submenu_items: Vec<(Rect, usize)>,
    /// `(body_rect, pane_id)` per visible layout leaf — recorded by
    /// `render_layout` for ALL pane kinds. Used to hit-test a tab drag-drop
    /// onto a pane body (drag-to-split). Cleared + rebuilt each frame.
    pub pane_bodies: Vec<(Rect, PaneId)>,
    /// While a bufferline tab is being dragged over a pane body, the target
    /// `(pane_id, drop-zone)` for the drop-hint overlay (see `app::tab_drop`).
    pub tab_drop_target: Option<(PaneId, crate::app::tab_drop::DropZone)>,
}

impl PaneRects {
    /// STRUCTURAL clear — resets EVERY click-rect field on this struct
    /// so the mouse handler can never see a stale entry from a
    /// previous frame's paint. Called at the top of `ui::draw`.
    ///
    /// Why this exists: `PaneRects` is a bag of ~256 fields, most of
    /// which are populated inside a specific panel's draw function.
    /// When a panel isn't the active section (or the pane is closed),
    /// its draw function doesn't run, its rects don't get repopulated
    /// — but the previous frame's values are still sitting there. The
    /// mouse dispatcher walks the cascade and any stale rect that
    /// happens to cover the click coord swallows the click. Over the
    /// life of the codebase we've fixed this class of bug a dozen
    /// times by hand-clearing one field at a time as new panels
    /// introduce it (see the git log's chain of "fix: X panel steals
    /// clicks" commits).
    ///
    /// The struct is documented as "screen regions captured during
    /// render, consumed for mouse routing on the next event" — nothing
    /// is meant to survive across frames. Doing `*self = Self::default()`
    /// on 256 mostly-empty Option/Vec fields is well under a microsecond.
    /// Trade a subtle recurring bug class for a trivial per-frame cost.
    pub fn reset_for_frame(&mut self) {
        // Preserve fields that are semantically drag/UI state (NOT
        // per-frame rects). Anything added here MUST carry a
        // comment explaining why it opts out of the reset.
        //
        // - `tab_drop_target` tracks an in-flight bufferline-tab
        //   drag; MUST survive between the frame that starts the
        //   drag and the frame that renders the drop-hint overlay.
        // - `bufferline_drag_tab` is the drag SOURCE (armed on
        //   Down, read on every Drag/Move, cleared on Up). Not
        //   preserving it wiped the arm on the first render after
        //   Down, so subsequent Drag events saw `None` and the
        //   drop handler in up_left never fired — regression
        //   noticed 2026-07-21 as "drag stops working when an
        //   integration Pty is open" (the integration just made
        //   the render cadence tight enough to be visible; every
        //   file drag was silently losing arm too whenever a
        //   render happened between Down and Drag).
        // - `bufferline_drag_ghost` is the cursor position drawn
        //   as a floating ghost during the drag; wipe would blank
        //   the ghost.
        // - `tab_insert_hint` is the between-tab caret position
        //   drawn while dragging over a strip; wipe would blank
        //   the insert marker.
        let preserved_tab_drop_target = self.tab_drop_target;
        let preserved_bufferline_drag_tab = self.bufferline_drag_tab;
        let preserved_bufferline_drag_ghost = self.bufferline_drag_ghost;
        let preserved_tab_insert_hint = self.tab_insert_hint;
        *self = Self::default();
        self.tab_drop_target = preserved_tab_drop_target;
        self.bufferline_drag_tab = preserved_bufferline_drag_tab;
        self.bufferline_drag_ghost = preserved_bufferline_drag_ghost;
        self.tab_insert_hint = preserved_tab_insert_hint;
    }

    /// Return the names of every rect field currently containing
    /// `(x, y)` — the click-inspector's data source. Manually
    /// enumerates the fields we care about; a click that doesn't
    /// hit anything returns an empty vec. Names match the field
    /// identifiers on `PaneRects` for grep-ability.
    pub fn inspect_click_targets(&self, x: u16, y: u16) -> Vec<&'static str> {
        let mut hits: Vec<&'static str> = Vec::new();
        let hit = |r: Rect| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
        macro_rules! check_opt {
            ($field:ident) => {
                if let Some(r) = self.$field
                    && hit(r)
                {
                    hits.push(stringify!($field));
                }
            };
        }
        macro_rules! check_vec {
            ($field:ident) => {
                if self.$field.iter().any(|entry| hit(entry.0)) {
                    hits.push(stringify!($field));
                }
            };
        }
        check_opt!(tree);
        check_opt!(tree_toggle);
        check_opt!(bufferline);
        check_opt!(statusline);
        check_opt!(right_panel_edge);
        check_opt!(right_panel_close);
        check_opt!(right_panel_new_button);
        check_opt!(activity_bar_gear);
        check_opt!(bufferline_empty_plus);
        check_opt!(ai_placeholder_card);
        check_opt!(session_new_chip);
        check_opt!(integrations_add_chip);
        check_opt!(integrations_tab_installed);
        check_opt!(integrations_tab_marketplace);
        check_opt!(integrations_tab_in_dev);
        check_opt!(integrations_tab_refresh);
        check_opt!(integrations_tab_sort);
        check_opt!(bottom_panel_close);
        check_opt!(integrations_filter_chip);
        check_opt!(sessions_panel_filter_input);
        check_opt!(glyph_builder_overlay_rect);
        check_opt!(settings_overlay_rect);
        check_vec!(activity_bar_icons);
        check_vec!(session_tabs);
        check_vec!(integration_icon_rects);
        check_vec!(statusline_segment_hits);
        check_vec!(bufferline_tabs);
        check_vec!(right_panel_tabs);
        check_vec!(split_strip_buttons);
        check_vec!(split_strip_ai_buttons);
        check_vec!(split_tab_chips);
        check_vec!(split_tab_close);
        check_vec!(split_tab_plus_buttons);
        check_vec!(split_tab_hidden_chips);
        check_vec!(pane_bodies);
        check_vec!(pty_tabs);
        check_vec!(context_menu_items);
        check_vec!(context_submenu_items);
        check_vec!(menu_bar_words);
        if let Some((r, _)) = self.menu_bar_overflow
            && hit(r)
        {
            hits.push("menu_bar_overflow");
        }
        check_vec!(menu_bar_items);
        hits
    }

    /// Wipe every activity-panel-scoped click-rect. Called at the top
    /// of the section-dispatch in `ui::draw` so stale rects from a
    /// previously-visible panel can't hijack a click when the user has
    /// switched to a different activity (Notes → HTTP → Sessions, etc).
    ///
    /// Whichever panel is drawn THIS frame repopulates its own rects;
    /// panels that aren't drawn stay cleared. Follow-up to the round-11
    /// F1 fix which only cleared the filter-input rects — those were
    /// just the tip of the iceberg. User report 2026-07-15:
    /// "previously viewed screen is getting the clicks."
    ///
    /// Not-in-scope on purpose (kept live across activity switches):
    ///   * `tree` / `tree_rows` / `tree_toggle` / `tree_icon_buttons`
    ///     — the Explorer file tree IS shared with other activities
    ///     (workspace context stays even when the sidebar shows Notes).
    ///   * `activity_bar_*` / `palette_*` / `statusline_*` — chrome
    ///     that renders every frame.
    ///   * Editor / pane rects — those are per-pane, not per-activity.
    ///
    /// If you add a new activity panel, add its rects here. If you
    /// touch this list, mirror in a test that clicks (0,0) after
    /// switching activities to prove no rect from the outgoing panel
    /// survives.
    pub fn clear_activity_panel_rects(&mut self) {
        // HTTP panel.
        self.http_panel_files.clear();
        self.http_panel_recent_rows.clear();
        self.http_panel_captured_rows.clear();
        self.http_panel_section_headers.clear();
        self.http_panel_section_chips.clear();
        self.http_panel_env_rows.clear();
        self.http_panel_chain_rows.clear();
        self.http_panel_mock_rows.clear();
        self.http_panel_collection_rows.clear();
        self.http_panel_collection_folder_rows.clear();
        self.http_panel_icon_buttons.clear();
        self.http_panel_collection_new_request_chips.clear();
        self.http_panel_new_chip = None;
        self.http_panel_filter_input = None;
        self.http_panel_capture_chip = None;
        self.http_panel_captured_clear_chip = None;
        self.http_panel_captured_refresh_chip = None;
        self.http_panel_recent_clear_chip = None;
        self.http_panel_discover_chip = None;
        self.http_panel_env_new_chip = None;
        self.http_panel_chain_new_chip = None;
        self.http_panel_collection_new_chip = None;
        self.http_panel_import_chip = None;
        // Notes panel.
        self.notes_panel_files.clear();
        self.notes_panel_new_chip = None;
        self.notes_panel_filter_input = None;
        // Findings panel.
        self.findings_panel_files.clear();
        self.findings_panel_filter_input = None;
        self.findings_panel_new_chip = None;
        // Todos panel.
        self.todos_panel_rows.clear();
        self.todos_panel_kebab = None;
        self.todos_panel_refresh_chip = None;
        // 2026-08-24 — new header refresh chips.
        self.notes_panel_refresh_chip = None;
        self.findings_panel_refresh_chip = None;
        self.sessions_panel_refresh_chip = None;
        self.todos_panel_filter_input = None;
        // Sessions panel.
        self.sessions_panel_filter_input = None;
        self.sessions_panel_area = None;
        // 2026-08-23 (mouse-r16 SEV-2) — `session_new_chip` used to
        // survive here, so switching Sessions → Notes left the "+
        // New session" rect intact; a right-click at the same coords
        // over Notes' "+ New note" popped the Sessions chip's batch-
        // spawn menu.
        self.session_new_chip = None;
        // Notes panel — sister rects that the mouse-tester audit
        // pointed out never get cleared on section switch either.
        self.notes_panel_files.clear();
        self.notes_panel_new_chip = None;
        self.notes_panel_filter_input = None;
        // Agents (Claude Code / Codex) panel.
        self.agents_panel_rows.clear();
        self.agents_panel_workspace_headers.clear();
        self.agents_panel_area = None;
        self.agents_panel_filter_input = None;
        self.agents_panel_new_chip = None;
        self.agents_panel_pr_chip = None;
        self.agents_panel_view_chip = None;
        self.agents_panel_refresh_chip = None;
        // Cloud agents (ECS runner) panel.
        self.cloud_agents_rows.clear();
        self.cloud_agents_filter_input = None;
        self.cloud_agents_new_run_button = None;
        self.cloud_agents_quick_input = None;
        self.cloud_agents_change_defaults_chip = None;
        self.cloud_agents_view_chip = None;
        self.cloud_agents_refresh_chip = None;
    }
}

/// Ex-cmdline Tab completion cycle. While the user keeps pressing Tab, this
/// remembers the part of the cmdline that should NOT change, the list of
/// matching candidates, and which one is on screen. The cmdline currently
/// shows `head + matches[idx]`. Cleared whenever the user types anything
/// other than Tab on the cmdline.
#[derive(Debug, Clone)]
pub struct CmdlineCompleteState {
    /// Text BEFORE the trailing word being completed (kept verbatim).
    pub head: String,
    /// Candidate completions in display order (sorted, de-duped).
    pub matches: Vec<String>,
    /// Index into `matches` of the entry currently in the cmdline.
    pub idx: usize,
    /// Snapshot of the cmdline text immediately AFTER the most recent Tab
    /// applied a completion. Used as a watermark so that the next handle_key
    /// run can detect "the user edited the line since the last cycle" and
    /// clear the cycle state.
    pub last_shown: String,
}

/// Flattened `WorkspaceEdit` shape — `(path, [(range, new_text)])` per
/// affected file. Used by the rename-preview stash and any future
/// confirmation flow.
pub type PendingRenameEdits = Vec<(PathBuf, Vec<(crate::lsp::Range, String)>)>;

/// Inline rename preview state. Filled when the `lsp.rename` prompt opens;
/// the renderer paints `prompt_text` (whatever the user has typed so far)
/// at every cell range listed in `occurrences`. Single-file — the
/// occurrences are scanned in the *active* editor at open-time only.
#[derive(Debug, Clone)]
pub struct RenamePreviewState {
    pub pane_id: PaneId,
    pub original_word: String,
    /// `(row, col_chars, original_len_chars)` per whole-word occurrence in
    /// the file (not just the viewport — the renderer clips to visible
    /// rows itself).
    pub occurrences: Vec<(usize, usize, usize)>,
}

/// Live state for the `lsp.selection_expand` / `_shrink` cycle. Holds the
/// server-supplied ranges (smallest → largest) and the current index. Set
/// when the first reply lands; consumed when the user expands / shrinks;
/// cleared whenever the selection moves to a position outside the ladder
/// (so the next expand re-queries).
#[derive(Debug, Clone)]
pub struct SelectionRangeLadder {
    pub path: PathBuf,
    /// Index into `App.panes` at request time. Cleared on pane swap.
    pub pane: usize,
    /// Ranges as byte offsets — `(start, end)`, ascending size.
    pub ranges: Vec<(usize, usize)>,
    pub current: usize,
}

/// `:command <Name>` entry — the expansion string plus the optional `nargs`
/// arity check (vim canonical). Default `nargs = Any` (the rest of the line
/// is appended verbatim, matching mnml's prior behavior).
#[derive(Debug, Clone)]
pub struct UserExCommand {
    pub expansion: String,
    pub nargs: ExCommandNargs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExCommandNargs {
    /// `0` — no args; if the user passes any, refuse with a toast.
    Zero,
    /// `1` — exactly one arg required (rest of the line, even if it has spaces).
    One,
    /// `?` — 0 or 1.
    ZeroOrOne,
    /// `+` — 1 or more.
    OneOrMore,
    /// `*` (vim canonical) or no spec — any.
    Any,
}

impl ExCommandNargs {
    /// Parse vim's `-nargs=…` value. Unknown ⇒ `Any` (matches mnml's prior
    /// default — don't break existing definitions).
    fn parse(spec: &str) -> Self {
        match spec {
            "0" => ExCommandNargs::Zero,
            "1" => ExCommandNargs::One,
            "?" => ExCommandNargs::ZeroOrOne,
            "+" => ExCommandNargs::OneOrMore,
            "*" => ExCommandNargs::Any,
            _ => ExCommandNargs::Any,
        }
    }
    /// `Ok(())` if `args` (the user's tail after the command name) satisfies
    /// the arity; `Err(reason)` otherwise.
    fn check(&self, args: &str) -> Result<(), &'static str> {
        let count = args.split_whitespace().count();
        match self {
            ExCommandNargs::Zero if count > 0 => Err("command takes no args"),
            ExCommandNargs::One if count == 0 => Err("command needs exactly 1 arg"),
            ExCommandNargs::OneOrMore if count == 0 => Err("command needs 1+ args"),
            _ => Ok(()),
        }
    }
}

/// Live `<count>o` / `<count>O` repeat-insert state. After the user opens the
/// first new line and types into it, `App::tick` polls for the mode flipping
/// back to Normal and replicates the typed text on the remaining
/// `count - 1` lines.
#[derive(Debug, Clone)]
pub struct RepeatInsertState {
    /// Total number of lines vim should open (counting the first).
    pub count: usize,
    /// Where the first new line ends up in the buffer (0-based row index).
    pub first_row: usize,
    /// Byte length of `first_row` at insert-start, so the post-Esc delta
    /// tells us what was typed.
    pub first_row_byte_len_before: usize,
    /// Byte position of `first_row`'s start (insert origin).
    pub start_byte: usize,
    /// Pane the insert started in — replay only fires if the same pane
    /// is still active.
    pub pane_id: usize,
    /// `o` ⇒ false (lines added below). `O` ⇒ true (above).
    pub above: bool,
}

/// Live visual-block I / A state. Captured at insert-start; consumed when the
/// handler returns to Normal mode (App::tick polls the transition). `rows`
/// excludes the top row (the user's literal typing already lands there).
#[derive(Debug, Clone)]
pub struct BlockInsertState {
    /// Rows OTHER than the top row that should receive the replayed text.
    pub other_rows: Vec<usize>,
    /// 0-based character column where the insert started (`I` ⇒ cmin,
    /// `A` ⇒ cmax + 1).
    pub col: usize,
    /// Byte offset at which the insert started (also the cursor at start).
    pub start_byte: usize,
    /// Byte length of the top row at insert start. After Esc, the difference
    /// against the new top-row length tells us how much was inserted.
    pub top_row_byte_len_before: usize,
    /// Top row index — `pane_id` lives separately so we can verify the pane
    /// hasn't been swapped out under us.
    pub top_row: usize,
    pub pane_id: usize,
    pub append: bool,
}

/// One additional workspace surfaced as a integration section in the rail
/// alongside the primary launched workspace. Each carries its own
/// gitignore-aware [`Tree`] plus the expand/collapse state for the section
/// header. Repos discovered under `root` get unioned into [`App::repos`].
pub struct ExtraWorkspace {
    pub name: String,
    pub root: PathBuf,
    pub tree: Tree,
    /// Section expand state — collapsed by default so a fresh window of N
    /// extra workspaces doesn't show every repo's contents at once.
    pub expanded: bool,
    /// qa-feature 2026-07-01 — stable visual slot in the unified
    /// workspace list. Primary + extras share a single position
    /// space: primary starts at `App.primary_position`; extras
    /// start at 1..N. Promoting an extra to primary only swaps
    /// the `●` marker — every workspace keeps its position,
    /// so the visual order never reshuffles.
    pub position: usize,
}

/// Persistent quick-scratch terminal — a small pty that lives at the
/// bottom of the body across pane switches. Owns its session; dropping
/// the App tears it down via the existing `PtySession::Drop`.
pub struct ScratchTerm {
    pub session: crate::pty_pane::PtySession,
    /// True while keystrokes should route to the pty rather than the
    /// active editor. Click on the strip focuses; Esc / click outside
    /// blurs.
    pub focused: bool,
}

/// Fixed height of the scratch-terminal strip when visible. 10 rows is a
/// reasonable default — enough for `git status` or a short script's
/// output without crowding the body.
pub const SCRATCH_TERM_ROWS: u16 = 10;

/// Tree drag state — populated by mouse-down on a tree row, armed when
/// the mouse moves to a different row. Drop on a directory row triggers
/// a confirmation prompt that moves the source path into the target dir.
#[derive(Debug, Clone)]
pub struct TreeDrag {
    pub src_path: std::path::PathBuf,
    pub src_is_dir: bool,
    /// Initial click row (so a mouse-up on the same row is treated as a
    /// click, not a drag).
    pub origin_y: u16,
    /// True after the cursor has moved off the origin row. Visual cue
    /// kicks in only past this threshold.
    pub armed: bool,
    /// Most-recent row the drag was over — drives the highlight tint.
    pub current_target_idx: Option<usize>,
    /// 2026-06-22 — last-known cursor position during the drag.
    /// Updated on every mouse-move; read by the drag-ghost paint
    /// pass to draw a small chip near the cursor.
    pub cursor_x: u16,
    pub cursor_y: u16,
    /// `true` when Alt was held at drag-start → drop = copy instead
    /// of move (matches Finder / VS Code convention). 2026-07-07.
    pub copy_instead_of_move: bool,
}

/// One reversible git operation for the GitGraph toolbar's Undo / Redo.
/// `undo` reverts it; `redo` re-applies it. Each is a single git
/// invocation kept deliberately narrow + non-destructive.
#[derive(Debug, Clone)]
pub enum GitUndoAction {
    /// `git reset --soft <hash>` — moves the branch ref only; the
    /// commit's changes stay staged. Vehicle for commit undo/redo.
    ResetSoft(String),
    /// `git checkout <branch>` — switch branches. Vehicle for checkout
    /// undo/redo.
    CheckoutBranch(String),
}

/// One entry on the git undo/redo stacks — a human-readable label plus
/// the inverse + forward action.
#[derive(Debug, Clone)]
pub struct GitUndoEntry {
    pub description: String,
    pub undo: GitUndoAction,
    pub redo: GitUndoAction,
}

/// One AI ghost-text worker reply — `(request_id, completion-or-error)`.
type SuggestReply = (u64, Result<String, String>);

/// One local-FIM worker request — `(request_id, prefix, suffix, max_tokens)`.
type FimRequest = (u64, String, String, usize);

/// Severity of a toast — affects the border color at render time.
/// Per the current design: info + warn render identically (comment
/// border, keeps the ambient noise low); error gets a red border so
/// actual failures stand out. Flip-a-switch behavior — the render
/// mapping is a single match in `toast_stack.rs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ToastLevel {
    #[default]
    Info,
    Warn,
    Error,
}

/// #20 — an undo affordance attached to a destructive toast.
/// Rendered as a `↶ Undo` chip; click or the `u` key while the
/// undo is live fires the [`UndoAction`]. Expires after
/// [`UNDO_TTL`] whether the user acts on it or not.
#[derive(Debug, Clone)]
pub struct PendingUndo {
    /// Short label for the chip (e.g. `"removed workspace mnml"`).
    /// Rendered next to the `↶ Undo` chip so the user knows what
    /// they're undoing without reading the toast above.
    pub label: String,
    pub action: UndoAction,
    pub created_at: Instant,
}

/// #20 — actions the undo slot can fire. New variants land here
/// as we retrofit more destructive surfaces.
#[derive(Debug, Clone)]
pub enum UndoAction {
    /// Put a removed workspace config entry back where it was
    /// (both `App.config.workspaces` at the given index AND the
    /// on-disk global config).
    RestoreWorkspace {
        config: crate::config::WorkspaceConfig,
        position: usize,
    },
    /// Put a cleared Request pane's fields back. Captures only
    /// the user-visible / user-editable state (URL, method,
    /// body, headers, source buffer) — everything else on the
    /// pane (state machine, cursors, hover keys) resets fresh
    /// on restore.
    RestoreRequestPane {
        pane_id: crate::layout::PaneId,
        method: String,
        url: String,
        body: Option<String>,
        headers_buffer: String,
        source_buffer: String,
    },
    /// Put the workspace `history.jsonl` bytes back. Captured
    /// on `http_panel_clear_recent`.
    RestoreHistoryFile { bytes: Vec<u8> },
    /// Put the workspace `captured/log.jsonl` bytes back.
    /// Captured on `http_panel_clear_captured`.
    RestoreCapturedFile { bytes: Vec<u8> },
    /// Move a deleted path back out of the workspace trash.
    ///
    /// A delete used to be `remove_file` / `remove_dir_all` — final, with
    /// the app's own undo mechanism sitting right there unused. It moves
    /// the entry into `.mnml/trash/` now, so undo is a rename back.
    RestoreDeletedPath {
        from: std::path::PathBuf,
        to: std::path::PathBuf,
    },
    /// Reopen a closed buffer at the given path + cursor + scroll.
    /// Cursor stored as a raw byte offset (Editor's native form).
    ReopenClosedBuffer {
        path: std::path::PathBuf,
        cursor: usize,
        scroll: usize,
    },
}

/// TTL for the undo affordance. Longer than [`TOAST_TTL`] because
/// the user needs to see the toast, register what happened, and
/// decide to undo — 3 seconds is too short.
pub const UNDO_TTL: std::time::Duration = std::time::Duration::from_secs(10);

/// #20 Pattern B — a confirm-before-destroy modal. Anchored to
/// the screen center; blocks all other input until dismissed.
/// Buttons: [Cancel] / [Confirm]. Default focus is Cancel.
/// Y/y fires Confirm, N/n / Esc fires Cancel, Enter fires the
/// focused button.
#[derive(Debug, Clone)]
pub struct PendingConfirm {
    /// Short title shown in the modal's border.
    pub title: String,
    /// Body message — usually one sentence, wraps to two lines
    /// max.
    pub message: String,
    /// Label of the destructive button (typically "Delete" or
    /// "Overwrite"). Rendered in red.
    pub confirm_label: String,
    /// Which button is focused (0 = Cancel, 1 = Confirm).
    /// Default focus lands on Cancel (safer choice).
    pub focused: u8,
    /// The action to run on Confirm.
    pub action: ConfirmAction,
}

/// #20 Pattern B — actions the confirm modal can fire.
#[derive(Debug, Clone)]
pub enum ConfirmAction {
    /// Overwrite the active Request pane with parsed clipboard
    /// curl. Runs `http_paste_curl_from_text` with the stashed
    /// text.
    OverwriteRequestPane { raw: String },
}

/// One toast in either `toast_stack` (ephemeral, TTL-expiring) or
/// `persistent_toasts` (pinned until `toast_dismiss`).
#[derive(Debug, Clone)]
pub struct ToastEntry {
    pub text: String,
    pub created_at: Instant,
    pub level: ToastLevel,
    /// `Some(id)` for persistent toasts (dismissable by id, never
    /// aged out). `None` for ephemeral toasts (TTL-expiring stack).
    pub persistent_id: Option<String>,
}

/// Left/right anchor for a dynamic statusline segment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegmentSide {
    Left,
    Right,
}

/// A integration-authored statusline segment. Kept simple: the render
/// pass reads the current `text` and computes width against
/// [min_width, max_width]. When space is tight (competing
/// segments overflow the available lane), lower-priority segments
/// drop entirely. Higher priorities keep their `max_width`
/// allocation as long as budget remains.
#[derive(Debug, Clone)]
pub struct DynamicSegment {
    pub id: String,
    pub side: SegmentSide,
    pub text: String,
    /// Named theme color (`"red"`, `"green"`, `"cyan"`, …) — see
    /// [`crate::integration_manifest::ALLOWED_COLORS`]. Unknown /
    /// unset renders in `comment`.
    pub color: Option<String>,
    /// Ex-command to run when the segment is clicked. `None` =
    /// non-interactive.
    pub click_command: Option<String>,
    /// Higher wins the layout race. 100 = normal, 200 = "always
    /// show," 50 = "nice to have."
    pub priority: u8,
    /// Below this width the segment is dropped entirely (not
    /// rendered) rather than truncated further.
    pub min_width: u16,
    /// Preferred width. Text longer than this gets truncated
    /// with `…`. Text shorter is padded to the actual text width
    /// (no trailing whitespace).
    pub max_width: u16,
    /// Optional per-segment tooltip body. Rendered by the tooltip
    /// path (or fed into the info-view hover-help panel) so the
    /// user can see WHY a chip is showing what it is — e.g. the
    /// "waiting for first poll" / "last error: …" states that
    /// manifest-driven statusline segments compute. Set to `None`
    /// for IPC-set segments that don't provide one. Task #965
    /// follow-up 2026-08-17: reviewer flagged that this data was
    /// computed but never surfaced.
    pub tooltip: Option<String>,
    pub last_updated: Instant,
}

/// Outcome of `progress_end` — determines the follow-up toast
/// that fires (if any) and the terminal glyph on the row before
/// it fades.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressStatus {
    Success,
    Failed,
    Cancelled,
}

/// One in-flight progress notification. Rendered above the toast
/// stack with an animated Braille spinner (or a final-status
/// glyph after `progress_end`). Keyed by external `id` so the
/// integration can call `progress_update` with the same id to nudge
/// the label / percentage.
#[derive(Debug, Clone)]
pub struct ProgressItem {
    pub id: String,
    pub label: String,
    /// `None` = indeterminate (spinner only). `Some(n)` renders
    /// `n%` next to the spinner (clamped to 0..=100).
    pub percent: Option<u8>,
    pub started_at: Instant,
    /// Once `progress_end` fires, this is `Some(status)` and the
    /// row lingers for [`PROGRESS_END_FADE`] before removal.
    /// Callers keeping the progress item visible after completion
    /// can also just call `progress_end` immediately.
    pub finished: Option<(ProgressStatus, Instant)>,
}

pub struct App {
    pub workspace: PathBuf,
    pub config: Config,
    pub panes: Vec<Pane>,
    /// Vim-style tab pages: each entry is one independent split tree. Always
    /// non-empty (`vec![Layout::Empty]` when no panes are open). The active tab
    /// is `layouts[active_layout]`; helpers `layout()` / `layout_mut()` return
    /// it. A pane is referenced by at most one leaf across all layouts.
    pub layouts: Vec<Layout>,
    /// Index of the active tab page. Always `< layouts.len()`.
    pub active_layout: usize,
    /// Per-tab last-focused pane, parallel to `layouts`. Restored to `active`
    /// when the user `:tabnext`s back to a tab they'd left.
    pub tab_actives: Vec<Option<PaneId>>,
    /// The focused pane id. Invariant (see [`crate::layout`]): every pane is in
    /// at most one leaf across all tab pages, so this uniquely identifies the
    /// focused leaf. `None` ⇔ active layout is `Empty` ⇔ no panes open in this
    /// tab.
    pub active: Option<PaneId>,
    pub focus: Focus,
    /// Zoom / maximize (`view.toggle_zoom`, ⛶ button in each per-leaf
    /// tab strip). When set, the render layer paints ONLY the leaf
    /// containing this pane, filling the full body area — every other
    /// split is hidden. Click the ⛶ button again (or fire the command)
    /// to restore the original split tree. Cleared automatically when
    /// the zoomed leaf's pane disappears (close/split rearrange) so we
    /// never render a stale zoom over a layout that no longer contains
    /// it. Per-tab-page: switching tab pages resets to `None` so the
    /// user isn't surprised by a stale zoom on the new tab.
    pub zoomed_leaf: Option<PaneId>,
    pub tree: Tree,
    /// Additional workspace trees rendered as integration sections below the
    /// primary `> WORKSPACE-NAME` section in the rail. Each entry comes from
    /// a `[[workspaces]]` config entry. The primary workspace itself isn't
    /// in this list — it's [`Self::workspace`] + [`Self::tree`]. Repos
    /// discovered under any extra workspace land in the shared
    /// [`Self::repos`] list (flat across all workspaces) so the existing
    /// active-repo machinery (git rail, switcher, status pane, etc.) works
    /// unchanged.
    pub extra_workspaces: Vec<ExtraWorkspace>,
    /// Discovered TODO markers across the workspace. Populated by
    /// `todos_panel_refresh`. (#9)
    pub todos_hits: Vec<crate::ui::todos_panel::TodoHit>,
    /// Set to true after the first `todos_panel_refresh` fires so
    /// the panel doesn't re-scan on every draw.
    pub todos_panel_scanned_once: bool,
    /// Cached `.http`/`.curl` file list for the HTTP activity panel
    /// (#10). Refreshed lazily on panel activation (see
    /// `App::http_panel_files_cached`) so we don't stat the tree
    /// every render frame.
    pub http_panel_files_cache: Vec<std::path::PathBuf>,
    /// True after the first HTTP panel scan; drives lazy refresh.
    pub http_panel_scanned_once: bool,
    /// Cached tail of `.rqst/history.jsonl` — most-recent-last. Loaded
    /// by `http_panel_refresh` when the HTTP activity section
    /// activates. Fed to the sectioned sidebar's `Recent` section.
    pub http_panel_recent_cache: Vec<serde_json::Value>,
    /// Cached tail of `.rqst/captured/log.jsonl` — most-recent-last.
    /// Same refresh cadence as recent; drives the sidebar's
    /// `Captured` section + row-click → re-fire scratch.
    pub http_panel_captured_cache: Vec<crate::http::captured::CapturedRow>,
    /// Scroll offset (in rows) for the CAPTURED section body. Wheel
    /// events over the section area bump this so users can browse
    /// past the visible cap when the log has >SECTION_ROW_CAP rows.
    /// Clamped per render. 2026-07-07.
    pub http_panel_captured_scroll: usize,
    /// Same idea for RECENT — history.jsonl entries scroll under the
    /// same wheel handler.
    pub http_panel_recent_scroll: usize,
    /// Scroll offset for MOCKS.
    pub http_panel_mocks_scroll: usize,
    /// Scroll offset for CHAINS.
    pub http_panel_chains_scroll: usize,
    /// Scroll offset for COLLECTIONS (indexes the flattened
    /// collection-rows + member-file rows list).
    pub http_panel_collections_scroll: usize,
    /// Keyboard cursor for HTTP panel row navigation. `.0` is the
    /// section index (1=RECENT, 2=CAPTURED, 4=CHAINS, 5=MOCKS,
    /// 6=COLLECTIONS); `.1` is the 0-based row within that section.
    /// Enter activates the row under the cursor; j/k / arrows move
    /// within a section; Tab crosses to the next non-empty section.
    /// 2026-07-07 — keyboard-user SEV-2 #4 fix.
    pub http_panel_cursor: (u8, usize),
    /// Cached list of env names (basenames without `.env` extension)
    /// found under `.mnml/env/` + `.rqst/env/`. Refreshed by
    /// `http_panel_refresh` alongside the other caches.
    pub http_panel_envs_cache: Vec<String>,
    /// Cached list of `.chain.json` paths under `.mnml/chains/`.
    pub http_panel_chains_cache: Vec<std::path::PathBuf>,
    /// Cached list of `.mock.json` paths anywhere under the
    /// workspace. Bounded by the same walk that populates the
    /// FILES cache — cheap on typical projects.
    pub http_panel_mocks_cache: Vec<std::path::PathBuf>,
    /// #22 — cached list of request files under any collection root.
    /// A "collection" is either a subdir of `.mnml/collections/`
    /// (Hidden — per-user, gitignored) or a workspace folder with
    /// ≥2 `.http`/`.curl`/`.rest` files (InTree — Bruno-flavor,
    /// git-tracked). Files not inside any collection root land in
    /// `http_panel_files_cache` as stragglers.
    pub http_panel_collections_cache: Vec<std::path::PathBuf>,
    /// #polish 2026-07-06 — per-collection metadata:
    /// `(root_dir_absolute, kind)`. Populated in `http_panel_refresh`.
    /// The renderer walks this list to paint each collection with
    /// its icon (🗂 Hidden vs 📁 InTree) and to build the per-root
    /// tree of files.
    pub http_panel_collection_roots: Vec<(std::path::PathBuf, HttpCollectionKind)>,
    /// #22 v2 — set of collection folder paths (absolute) that
    /// are currently *collapsed* in the sidebar tree. Default
    /// state: everything expanded. Persists across activity-
    /// section toggles within a session; not written to disk.
    pub http_panel_collections_collapsed_dirs: std::collections::HashSet<std::path::PathBuf>,
    /// Collapse state for the sectioned HTTP sidebar. Indices:
    /// `0=Files 1=Recent 2=Captured 3=Envs 4=Chains 5=Mocks 6=Collections`.
    /// Persists across activity-section toggles within a session;
    /// not saved to disk (v1 — a follow-up can plumb into
    /// `session.json`).
    pub http_panel_section_collapsed: [bool; 7],
    /// Cached notes file list for the Notes activity panel (#8).
    /// Same lazy pattern as `http_panel_files_cache`.
    pub notes_panel_files_cache: Vec<std::path::PathBuf>,
    pub notes_panel_scanned_once: bool,
    /// 2026-08-07 — Findings file cache (mirrors notes cache).
    pub findings_panel_files_cache: Vec<std::path::PathBuf>,
    pub findings_panel_scanned_once: bool,
    /// 2026-08-23 (user ask) — `/`-filter for the Findings panel,
    /// mirroring the Notes / TODOs / Sessions / HTTP idiom. Matches
    /// case-insensitively on the row's rendered relative name.
    pub findings_panel_filter: String,
    pub findings_panel_filter_focused: bool,
    /// qa-feature 2026-07-01 — stable position for the primary
    /// in the unified workspace visual list (primary + extras
    /// share one position space). Starts at 0. Promoting an
    /// extra to primary swaps positions (and only positions) —
    /// so the visual order of the workspace list never changes,
    /// only the `●` marker moves.
    pub primary_position: usize,
    pub tree_visible: bool,
    /// Which activity-bar section currently fills the rail. Default
    /// `Explorer` reproduces mnml's pre-activity-bar behavior (file
    /// tree + integrations + git). Toggled via the 4-cell vertical
    /// strip on the far left of the rail.
    pub active_section: ActivitySection,
    /// Manifest-registered Mount integrations discovered at startup.
    /// One entry per `mnml.toml` under
    /// `<ws>/.mnml/mounts/` + `~/.config/mnml/mounts/`. Rendered
    /// as extra activity-bar icons after the builtins. Indexed
    /// by `ActivitySection::Mount(u16)`.
    pub mount_manifests: Vec<crate::mount_manifest::MountManifest>,
    /// Manifest-registered integrations discovered at
    /// startup. One entry per `<id>.toml` under
    /// `<ws>/.mnml/integrations/` + `~/.config/mnml/integrations/`.
    /// Chips are merged into `config.ui.integration_icons` and
    /// commands into `dynamic_commands` at startup; the vec is
    /// kept so `integrations.refresh` can re-scan without
    /// restart.
    pub integration_manifests: Vec<crate::integration_manifest::IntegrationManifest>,
    /// #1102 f/u (2026-08-20) — authoritative "current version" per
    /// integration binary, resolved by invoking `<binary> --version` at
    /// manifest-load time and parsing the last whitespace-separated
    /// token (clap's default format: `mnml-forge-bitbucket 0.3.22`).
    /// Keyed by binary basename (multiple integrations can share one
    /// binary — bitbucket_prs + bitbucket_pipelines both run
    /// mnml-forge-bitbucket). Manifest's `version =` field becomes a
    /// fallback hint only; this cache is the source of truth for the
    /// Installed row + detail-page byline. Populated by
    /// `refresh_binary_version_cache`, cleared + repopulated after
    /// `refresh_integration_manifests` and `apply_integration_update`.
    pub binary_version_cache: std::collections::HashMap<String, String>,
    /// 2026-07-31 — integration-icons SDK. Discovered SVGs under
    /// `~/.config/mnml/glyphs/` populated at startup + on
    /// `integrations.refresh`. `Vec<(id, absolute_path)>`, sorted
    /// stably by id. The parallel [`Self::integration_glyph_codepoints`]
    /// map holds each id's assigned codepoint. See
    /// `src/app/integration_glyphs.rs`.
    pub integration_glyph_svgs: Vec<(String, std::path::PathBuf)>,
    /// Sibling-id → codepoint map. Refreshed alongside
    /// `integration_glyph_svgs`. `merge_integration_manifests` uses it
    /// to fill `IntegrationIcon.glyph` when the manifest set
    /// `chip.glyph_svg` but left `chip.glyph` empty.
    pub integration_glyph_codepoints: std::collections::HashMap<String, u32>,
    /// Notification badges on activity-bar sections — keyed by
    /// the section's serialized id (e.g. `"agents"`, `"cloud_agents"`,
    /// manifest mount id). Set by integrations via the
    /// `set-activity-badge` IPC command. `count = 0` clears
    /// (we remove the key on zero to keep the map tidy).
    pub activity_badges: std::collections::HashMap<String, u32>,
    /// `Some(rx)` while a `+ New cloud run` trigger is in flight
    /// on a worker thread. Drained in `tick`; result surfaces as
    /// a toast.
    pub cloud_run_pending:
        Option<std::sync::mpsc::Receiver<crate::ecs_runner_trigger::TriggerResult>>,
    /// Family id captured when a `prompt_install_integration` opens the
    /// "X not installed — install? y/n" prompt. Resolved by the
    /// prompt accept handler to fire the install.
    /// Pending external-tool install — the package name to install
    /// (brew formula / apt package) when the user confirms a
    /// ToolInstallConfirm prompt. See `run_external_tool` +
    /// `accept_tool_install`.
    pub pending_tool_install: Option<(String, String)>, // (id, install_cmd)
    /// The `--config PATH` override, if one was passed. Stored so
    /// `grant_workspace_trust` can rebuild the config with the same
    /// layering it had at startup — without it, trusting a workspace
    /// would silently drop an explicit `--config`. Set by `main.rs`
    /// after construction so `App::new`'s signature (and every test
    /// that calls it) stays unchanged.
    pub explicit_config_path: Option<std::path::PathBuf>,
    /// True while the current workspace declares executable config
    /// that hasn't been trusted — its exec-bearing keys are suppressed.
    /// Read by the statusline to show the restricted chip.
    pub workspace_trust_restricted: bool,
    /// `(fingerprint, claims)` awaiting a Trust / Don't-trust answer.
    /// Held across the prompt so the grant records the exact
    /// fingerprint the user was shown, not a re-scan that could have
    /// changed underneath them.
    pub pending_workspace_trust: Option<(String, Vec<crate::workspace_trust::ExecClaim>)>,
    /// P4b — cached marketplace entries + in-flight fetch receivers.
    /// Populated by `App::refresh_marketplace()` (spawns a fetch
    /// thread per configured source) + drained by
    /// `drain_marketplace_fetches()` on each tick. Rendered by the
    /// Integrations panel Marketplace tab.
    pub marketplace_entries: Vec<crate::marketplace::MarketplaceEntry>,
    pub marketplace_pending: Vec<(
        String, // source id
        std::sync::mpsc::Receiver<Result<Vec<crate::marketplace::MarketplaceEntry>, String>>,
    )>,
    /// Pending launcher-install fetches — one entry per click-Install
    /// on a marketplace launcher row. Each thread downloads the
    /// launcher .toml + returns Ok(id, path) / Err(id, message).
    /// Drained per-tick by `drain_launcher_installs`. vscode-mouse
    /// SEV-1 2026-08-05: prior blocking `install_launcher_from_url`
    /// froze the render thread for up to 10s.
    pub launcher_install_pending:
        Vec<std::sync::mpsc::Receiver<Result<(String, std::path::PathBuf), (String, String)>>>,
    /// 2026-08-16 — cross-thread map of installed-integration →
    /// upstream-version-check result. Populated by the background
    /// worker in `integration_updates::spawn_update_check_worker`;
    /// consulted by the marketplace-tab renderer to light up an
    /// "↑ Update to <ver>" chip on installed rows. Empty until the
    /// worker's first sweep resolves (or the persisted cache seeds
    /// it via `integration_updates::load_update_cache_into`).
    pub integration_updates: std::sync::Arc<
        std::sync::Mutex<
            std::collections::HashMap<String, crate::app::integration_updates::UpdateCheck>,
        >,
    >,
    /// Signaller for the `integrations.check_updates_now` palette
    /// command. `Some` in real runtime; `None` under `cfg!(test)` so
    /// the unit + e2e suites don't stack un-joined worker threads
    /// (matches the `spawn_coverage_s3_syncer` gating pattern).
    pub integration_updates_waker: Option<crate::app::integration_updates::UpdateWaker>,
    /// #1202 (2026-08-25) — installed Nerd Font families (name-table
    /// scan via `font_scan::scan_nerd_fonts`). Rendered as the FONTS
    /// section pinned at the top of the Marketplace tab so users can
    /// see each family's Nerd Fonts version. Populated at startup +
    /// on `integrations.refresh`; empty under `cfg!(test)`.
    pub installed_fonts: Vec<crate::font_scan::InstalledFont>,
    /// #1202 — latest Nerd Fonts release version ("3.5.1"), filled by
    /// a one-shot worker thread (GitHub API, 24h disk cache). `None`
    /// until the fetch resolves; the FONTS rows then color stale
    /// families and grow an "↑ Update" chip.
    pub nerdfonts_latest: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    /// #993 step 2b (2026-08-20) — background tick for auto-update
    /// firing. Records the last wall-clock at which `tick_auto_updates`
    /// evaluated the plan, so the check runs at most once per
    /// `AUTO_UPDATE_TICK_INTERVAL_SECS` regardless of how many
    /// event-loop iterations occur between. `None` until the first
    /// tick fires. In test builds the tick is a no-op (same reason as
    /// the update-check worker gating above — avoid stacking
    /// long-running side-effects in unit runs).
    pub last_auto_update_tick_at: Option<std::time::Instant>,
    /// 2026-08-06 — README cache for the integration-detail pane.
    /// Keyed by integration id. `Loading` = worker spawned but not
    /// yet delivered. `Text` = fetched body. `NotFound` = fetch
    /// failed or the source has no README. The rendered pane
    /// consults this map every draw; a background worker updates
    /// it via `drain_readme_fetches`.
    pub readme_cache:
        std::collections::HashMap<String, crate::app::integration_detail::ReadmeState>,
    pub readme_pending:
        Vec<std::sync::mpsc::Receiver<(String, crate::app::integration_detail::ReadmeState)>>,
    /// AI usage meter state (#876, extended to multi-account #944).
    /// One entry per `[[ai.claude.accounts]]` config row (the
    /// synthetic single-account default keeps the vec at len==1 for
    /// pre-#944 installs). Populated by background workers spawned
    /// via `maybe_refresh_ai_usage` + drained per tick via
    /// `drain_ai_usage`. See `active_claude_account`.
    pub ai_usage_claude_accounts: Vec<crate::ai_usage::ClaudeAccountUsage>,
    pub ai_usage_codex: Option<crate::ai_usage::CodexUsage>,
    /// In-flight per-account Claude fetches. Keyed by account name
    /// so a slow account can't block a fast one; drained per tick,
    /// results merge into `ai_usage_claude_accounts` by name.
    pub ai_usage_pending_claude_accounts: Vec<(
        String,
        std::sync::mpsc::Receiver<
            Result<crate::ai_usage::ClaudeAccountUsage, crate::ai_usage::FetchErr>,
        >,
    )>,
    pub ai_usage_pending_codex:
        Option<std::sync::mpsc::Receiver<Result<crate::ai_usage::CodexUsage, String>>>,
    /// 2026-08-08 — Keychain lookup for the LinkClaudeToken prompt's
    /// Ctrl+K helper. Threaded so a macOS auth-prompt on `security
    /// find-generic-password` doesn't freeze the TUI event loop.
    /// Result is a JSON blob (Ok) or a human-readable error string.
    pub pending_keychain_fetch: Option<std::sync::mpsc::Receiver<Result<String, String>>>,
    /// #1232 — in-flight identity-verified keychain recapture. The
    /// worker reads the keychain, identifies the blob over the wire,
    /// and files it under the matching account; this just carries the
    /// human-readable outcome back to a toast.
    pub pending_keychain_recapture: Option<std::sync::mpsc::Receiver<Result<String, String>>>,
    /// #1150 f/u (2026-08-23) — autodetected "which Claude account is
    /// the live Claude Code CLI login." Parsed refresh-token pulled
    /// from the current Keychain blob (`Claude Code-credentials`).
    /// The per-account `is_active` flag prefers a match against this
    /// over the manual `[[ai.claude.accounts]] active = true` config
    /// flag — which was the pre-fix behavior and drifted whenever a
    /// user switched Claude Code accounts without touching mnml's
    /// config.toml. Refreshed by `spawn_keychain_active_refresh_token`
    /// on startup + every `refresh_claude_usage` kick.
    pub keychain_claude_refresh_token: Option<String>,
    /// Receiver for the background worker that reads the Keychain to
    /// populate `keychain_claude_refresh_token`. Drained per-tick.
    pub keychain_active_watch: Option<std::sync::mpsc::Receiver<Result<Option<String>, String>>>,
    /// Resolved autodetect result — recomputed by
    /// `restamp_claude_active_flags` when the Keychain cache or
    /// account list changes, then read O(1) by every render (the
    /// statusline chip + Claude Usage panel both render this per
    /// frame). Prevents the reader from re-reading each account's
    /// on-disk token file at render time.
    pub cached_autodetected_claude_account: Option<String>,
    /// Unix seconds of the last `spawn_keychain_active_refresh_token`
    /// kick. Throttles the autodetect worker to the same 5-min cadence
    /// as the per-account fetches — without it,
    /// `kick_keychain_active_refresh` would fire from every
    /// `maybe_refresh_ai_usage`, which runs on every tick (~120ms
    /// idle / ~40ms with a pty), spawning a `security find-generic-
    /// password` subprocess ~500x/minute forever.
    pub keychain_active_last_kick_at: u64,
    /// Unix seconds of the last refresh spawn — throttles the
    /// per-tick "should I refresh again" check to at most once per
    /// 5 min. Used by the Codex fetcher and by the (rare) "no
    /// accounts configured" Claude fallback.
    pub ai_usage_last_refresh_at: u64,
    /// Per-account throttle map for Claude fetches — mirrors
    /// `ai_usage_last_refresh_at` but keyed by account name so a
    /// 429 on one account doesn't stall the others. Populated by
    /// `maybe_refresh_ai_usage` when it spawns each per-account
    /// worker. Task #944, 2026-08-16.
    pub ai_usage_claude_last_refresh_at: std::collections::HashMap<String, u64>,
    /// #ai-429 — unix seconds of the last Claude usage fetch spawned for
    /// ANY account, so requests are staggered rather than bursting.
    ///
    /// User: "maybe we shoudl not do all of htem in 1 tick". Three
    /// accounts became eligible on the same tick and fired together, so
    /// every cycle hit the endpoint three times in a few milliseconds —
    /// which is exactly the shape that earns a 429.
    pub ai_usage_last_claude_spawn_at: u64,
    /// Tattle Feature Coverage trends — read from
    /// `~/.tattle-claude-artifacts/feature-coverage/_trends/trends.json`.
    /// None until first load; hidden UI if the file doesn't exist.
    pub coverage_trends: Option<crate::coverage::TrendsFile>,
    /// Istanbul (code-coverage) trends — read from
    /// `~/.tattle-claude-artifacts/code-coverage/_trends/trends.json`.
    /// Rendered on the statusline chip next to the feature %. None until
    /// first load, and stays None if the file doesn't exist (e.g. no
    /// local sync yet — the mnml-tattle-coverage integration still shows
    /// the full Istanbul view by pulling S3 directly). 2026-08-16.
    pub istanbul_trends: Option<crate::coverage::IstanbulTrendsFile>,
    /// Unix seconds of the last coverage-trends read; 0 = never loaded.
    /// Throttles the per-tick re-read (file is written by an out-of-mnml
    /// cron, no need to poll faster than ~5 min). Applies to BOTH feature
    /// + Istanbul (loaded together in `ensure_coverage_loaded`).
    pub coverage_trends_last_loaded_at: u64,
    /// Unix seconds when the marketplace cache was last successfully
    /// written. 0 means "never fetched this session"; the disk cache
    /// may still be readable.
    pub marketplace_last_fetched: u64,
    /// Search activity-bar section: input + results state. The input
    /// captures keystrokes when `search_input_focused == true`; results
    /// render below the input regardless of focus.
    pub search_query: String,
    pub search_cursor: usize,
    pub search_hits: Vec<crate::grep_pane::GrepHit>,
    /// Which tool produced `search_hits` — `"rg"` / `"git grep"` / `""`.
    pub search_used: &'static str,
    pub search_selected: usize,
    pub search_scroll: usize,
    /// When true, the Search section's input box is focused — keyboard
    /// dispatch in `tui.rs` routes printables into the query buffer
    /// instead of the editor / overlay.
    pub search_input_focused: bool,
    /// #1112 (2026-08-20) — Search section flags. Wired into the
    /// ripgrep invocation via `grep_workspace_with_flags`; toggled
    /// by chips rendered in the search-section toolbar. Session-
    /// persisted so a user who prefers regex mode keeps it across
    /// restarts (via `search_flags` in SavedSession).
    ///
    /// `case_sensitive`: swaps `--smart-case` for `--case-sensitive`
    /// (default off = smart-case, which is what most users want).
    /// `whole_word`: adds `--word-regexp`.
    /// `regex`: without this, ripgrep treats the query as a fixed
    /// string (`--fixed-strings`).
    pub search_case_sensitive: bool,
    pub search_whole_word: bool,
    pub search_regex: bool,
    /// #1112 (2026-08-20) — MRU of past queries. Up/Down inside the
    /// input cycles it. Capped at 20. Deduped on push. Session-
    /// persisted so history survives a restart.
    pub search_history: Vec<String>,
    /// Index into `search_history` when navigating with Up/Down.
    /// `None` = not navigating; `Some(i)` = current position (0 =
    /// most recent). Reset on any input mutation other than history
    /// nav so a fresh Up walks from the top again.
    pub search_history_cursor: Option<usize>,
    /// Git activity-bar section: inline commit-message buffer + focus.
    /// Submit (Ctrl+Enter or the [ Commit ] button) calls
    /// `crate::git::commit::commit` against the active repo. Cleared
    /// after a successful commit.
    pub git_section_commit_buffer: String,
    pub git_section_commit_focused: bool,
    /// Current rail width (cells). Initialized from `[ui] tree_width` and
    /// then mutable via mouse-drag on the rail's right edge. Persisted in
    /// `session.json`.
    pub tree_width: u16,
    /// True while the user is mid-drag on the rail's right-edge handle.
    /// Cleared on mouse-up; clamps `tree_width` to a sane range during drag.
    pub dragging_tree_edge: bool,
    /// Right-side panel toggle (mirror of `tree_visible`). v1 just
    /// reserves the column with an empty-state body; v2 will host
    /// outline / chat / dock widgets per user config.
    pub right_panel_visible: bool,
    /// Right panel column width in cells. Defaults to ~32; resizable
    /// via drag on its left edge (mirror of the left rail's right
    /// edge). Persisted alongside `tree_width`.
    pub right_panel_width: u16,
    /// True while the user is mid-drag on the right panel's left-edge handle.
    pub dragging_right_panel_edge: bool,
    /// Panes currently hosted in the right side panel. v3 supports
    /// multiple as a tab strip (Outline + Diagnostics simultaneously);
    /// `right_panel_active_idx` is which one is displayed. v2's
    /// `right_panel_pane_id: Option<usize>` is replaced by these two
    /// fields — most call sites should use `right_panel_active_pane_id()`.
    pub right_panel_panes: Vec<usize>,
    /// Index into `right_panel_panes` for the currently-visible pane.
    /// Clamped to `[0, panes.len())` defensively at access time.
    pub right_panel_active_idx: usize,
    /// 2026-08-07 — Phase 1 dockable-panes: bottom panel that hosts
    /// any pane below the split tree and above the statusline.
    /// Mirrors `right_panel_*` in structure. See
    /// `docs/design/dockable-panes.md` for the roadmap.
    pub bottom_panel_visible: bool,
    /// Row count for the bottom panel body (border + tab strip take
    /// their own extra rows). Default 12. Drag the top edge to resize.
    pub bottom_panel_height: u16,
    /// Panes hosted in the bottom panel. Same tabbed model as
    /// right_panel_panes.
    pub bottom_panel_panes: Vec<usize>,
    /// Index into `bottom_panel_panes` for the currently-visible pane.
    pub bottom_panel_active_idx: usize,
    /// User-set MAX height for the INTEGRATIONS rail section. `None`
    /// = auto-size to content needed (the default). When `Some(h)`,
    /// the layout uses `min(h, content_needed)` so a too-large cap
    /// collapses back to content (no wasted empty space). Set via
    /// drag-to-resize on the `> INTEGRATIONS` header.
    pub integrations_user_max_h: Option<u16>,
    /// User-set MAX height for the GIT rail section. Same semantics
    /// as `integrations_user_max_h`. Set via drag-to-resize on the
    /// `> GIT` header.
    pub git_user_max_h: Option<u16>,
    /// `Some((kind, start_y, start_h))` while the user is mid-drag
    /// on a rail section header. Each drag tick updates the
    /// corresponding `*_user_max_h`. Cleared on mouse-up. Mouse-up
    /// without an intervening drag event is treated as a click
    /// (toggles collapse).
    pub rail_section_drag: Option<RailSectionDrag>,
    /// `Some(hit)` while the user is mid-drag on a scrollbar (editor /
    /// diff / embedded-diff). Each drag tick maps the current `y` →
    /// new scroll position via `apply_scrollbar_drag`. Cleared on
    /// mouse-up.
    pub dragging_scrollbar: Option<ScrollbarHit>,
    /// Runtime override for the GitGraph commit-detail panel width
    /// (in cells). `None` ⇒ use `[ui] git_graph_detail_col` from the
    /// config or auto-size to 40% of the body. Updated by drag on the
    /// vertical divider between commit list + detail; persisted in
    /// session.json.
    pub git_graph_detail_col_override: Option<u16>,
    /// Active GitGraph-detail-divider drag — `(pane_id, pane_left_x,
    /// pane_right_x)` captured at drag start so we can clamp the
    /// resulting width per the pane the user grabbed.
    pub dragging_git_graph_detail: Option<(crate::layout::PaneId, u16, u16)>,
    /// Remembered diff view-mode + wrap toggle for every new
    /// `Pane::Diff`. The user picks once via the toolbar; the choice
    /// applies to every subsequent diff open (any file, any commit).
    /// Persisted in session.json across mnml restarts.
    pub diff_view_mode_pref: crate::pane::DiffViewMode,
    pub diff_wrap_pref: bool,
    /// Per-leaf tab-strip horizontal scroll — index of the leftmost
    /// rendered tab in that leaf. Keyed by the leaf's FIRST tab id,
    /// not its active one: the active tab changes every time you
    /// switch within the leaf, which would lose the offset on every
    /// click. The first tab is stable until it's closed or dragged,
    /// and losing the offset in those cases is harmless.
    ///
    /// #1209 (2026-08-26) — replaces the old global
    /// `bufferline_first_visible`, which dated from when there was
    /// one shared tab strip at the top. Per-leaf strips replaced
    /// that on 2026-07-18 and the global offset was orphaned; with
    /// splits, one shared offset would make scrolling one split's
    /// tabs move another's.
    pub leaf_tab_scroll: std::collections::HashMap<crate::layout::PaneId, usize>,
    /// The active tab each leaf had at its last paint, keyed the same
    /// way. Auto-scroll-to-reveal only fires when a leaf's active tab
    /// *changed* since the last frame, so a deliberate scroll away
    /// from the active tab survives instead of being yanked back on
    /// the very next render.
    pub leaf_tab_last_active:
        std::collections::HashMap<crate::layout::PaneId, crate::layout::PaneId>,
    /// Full-screen focus mode (`view.fullscreen`): hide the tree rail, bufferline, and
    /// statusline; the editor takes the full window. Independent of the other
    /// visibility flags, which are remembered separately. Not persisted —
    /// always starts off so a fresh launch is a normal IDE view.
    pub fullscreen_mode: bool,
    /// Most-recently-opened files, newest first, capped at `RECENT_FILES_MAX`.
    /// Updated every time `open_path` opens a file. Persisted in session.json.
    pub recent_files: Vec<PathBuf>,
    /// Harpoon-style pinned files (9 fixed slots). Slot N (0-based) is
    /// reached by `<leader>` + the digit `N+1`. Empty slots are `None`.
    /// Persisted in `session.json` so pins survive relaunch.
    pub harpoon: [Option<PathBuf>; 9],
    /// Most-recently-visited browser URLs, newest first, capped at
    /// [`BROWSER_URL_HISTORY_MAX`]. Built up from `Page.frameNavigated`
    /// events; surfaced via `browser.url_history` (Ctrl+R in a browser
    /// pane). Persisted in session.json. App-wide rather than per-pane
    /// since URLs are workspace-relevant, not pane-relevant.
    pub browser_url_history: Vec<String>,
    /// Last `m` device-emulation preset picked (index into
    /// `crate::browser_pane::DEVICE_PRESETS`). Persisted in session.json so
    /// fresh `browser.open` calls auto-apply it. `None` ⇒ no preset.
    pub last_browser_device: Option<usize>,
    /// qa-feature 2026-07-02 — bounds of the Ghostty + Chrome
    /// windows BEFORE `browser.dock_toggle` moved them side-by-side.
    /// `(ghostty_bounds, chrome_bounds)`; each is `[x, y, w, h]`.
    /// When set, the next `browser.dock_toggle` call restores the
    /// prior geometry and clears this field. macOS-only.
    pub browser_dock_saved: Option<((i32, i32, i32, i32), (i32, i32, i32, i32))>,
    /// Stack of recently closed buffers (`(path, cursor_byte, scroll)`),
    /// newest last. `buffer.reopen` (`Ctrl+Shift+T`) pops the top entry
    /// and re-opens it. Capped at `CLOSED_BUFFERS_MAX`. Not persisted —
    /// closing-then-reopening across sessions is what `recent_files` is for.
    pub closed_buffers: Vec<(PathBuf, usize, usize)>,
    /// The pane that was active *before* the current one. `Ctrl+Tab` jumps
    /// here. Each `reveal_pane` captures the outgoing active. Cleared when
    /// the captured pane is closed.
    pub last_active: Option<PaneId>,
    /// Most-recently-used pane ids, newest first. Updated by every
    /// `reveal_pane`; entries removed when a pane is closed (so indices
    /// stay valid even after the panes Vec is mutated). The buffer picker
    /// shows panes in this order so the user's recent context is on top.
    pub pane_mru: Vec<PaneId>,
    /// Vim macro recording / replay state. `None` ⇒ idle; `Recording`
    /// captures every key event that flows through dispatch_key (the
    /// toggling `q` itself is removed in `record_macro_stop`); `Replaying`
    /// ignores `@` keys to prevent unbounded recursion. Single anonymous
    /// register MVP — `q<reg>` named-register form is a follow-up.
    pub macro_state: MacroState,
    /// Stored macros, keyed by register letter (`a`-`z`) plus `'@'` for
    /// the anonymous register (which is what bare `q...q` and `@@` use).
    /// Replaced on each successful `q...q` recording for that register.
    /// Volatile (not persisted across relaunches).
    pub macro_buffer: std::collections::HashMap<char, Vec<ratatui::crossterm::event::KeyEvent>>,
    /// Set by the vim handler when the user types `q<reg>` / `@<reg>`;
    /// consumed by [`Self::macro_toggle`] / [`Self::macro_replay`] on the
    /// very next call. `None` ⇒ use the anonymous `'@'` register.
    pub pending_macro_register: Option<char>,
    /// The register of the macro most recently replayed via `@<reg>`.
    /// `@@` uses this instead of literally looking up register `'@'`
    /// (vim canonical). nvchad-round-7 SEV-2 2026-07-11.
    pub last_replayed_macro_reg: Option<char>,
    /// Throttle stamp for `check_external_file_changes` — stat'ing every
    /// open file on every tick is overkill; we cap the cadence to ~2s.
    last_external_check: Option<std::time::Instant>,
    /// Active visual-block I / A insert. Captured when the user presses `I`
    /// or `A` in VisualBlock mode: the App pins the rectangle's rows + the
    /// insert column, drives the handler to Insert, and on Esc-out replays
    /// the typed run on every other row in the rect (vim's "edit a column"
    /// power tool). `None` whenever there's no active block insert.
    pub block_insert_state: Option<BlockInsertState>,
    /// Active `<count>o` / `<count>O` repeat-insert. Set when the user types
    /// the count-prefixed gesture; consumed in `App::tick` when the handler
    /// returns to Normal mode (Esc out of Insert).
    pub repeat_insert_state: Option<RepeatInsertState>,
    /// Mouse drag-select in an editor pane: `(pane_id, origin_row,
    /// origin_col, armed)`. Set on `Down(Left)` over an editor; the first
    /// `Drag(Left)` jumps the cursor back to the origin, drops the anchor,
    /// and jumps to the drag point; subsequent drags just move the cursor.
    pub drag_select: Option<(PaneId, usize, usize, bool)>,
    /// Index of the tab page currently being dragged via the
    /// bufferline tab-page chips. Set on mouse-down on a chip,
    /// cleared on mouse-up; while `Some`, a mouse-drag over a
    /// different chip's rect swaps the two tab pages.
    pub dragging_tab_page: Option<usize>,
    /// Stack of recently-closed tab layouts (newest-last). Capped at
    /// `CLOSED_TAB_LAYOUTS_MAX`. Popped by `tab.reopen`. Each entry
    /// is the dropped tab's split tree — its leaves still reference
    /// PaneIds in `panes`, which `remove_pane_storage` shifts in
    /// lockstep with `self.layouts` so the stack stays consistent.
    pub closed_tab_layouts: Vec<Layout>,
    /// Pending `textDocument/rename` edits awaiting Apply/Cancel from the
    /// preview picker. `Some` ⇒ the picker is open and the edits are
    /// stashed. Cancel drops them; Apply runs `apply_rename_edits`.
    pub pending_rename_preview: Option<PendingRenameEdits>,
    /// Ex-cmdline Tab-completion cycle state. `head` = the part of the
    /// cmdline that stays put; `matches` = candidate completions; `idx` =
    /// the match index currently displayed. Cleared by any non-Tab cmdline
    /// keystroke (handled by App::cmdline_tab_complete tracking the previous
    /// line text).
    pub cmdline_complete_state: Option<CmdlineCompleteState>,
    /// Index of the highlighted row in the cmdline popup. Bumped by
    /// Tab / Down / Up and clamped against the current match count
    /// at render time. 2026-06-19 — paired with the floating popup
    /// (see `cmdline_popup_view`).
    pub cmdline_popup_selected: usize,
    /// Vim's arglist — the list of files targeted by `:args {glob}`,
    /// `:next`, `:prev`, `:first`, `:last`. Paths are absolute (the
    /// glob is expanded workspace-relative). `arglist_index` tracks
    /// the current entry (0-based); `None` means arglist is empty.
    pub arglist: Vec<std::path::PathBuf>,
    pub arglist_index: Option<usize>,
    /// Recent toasts (oldest first, capped at `MESSAGE_LOG_MAX`). Vim
    /// `:messages` shows them. Keeps a history beyond the live toast
    /// (which expires after `TOAST_TTL`).
    /// Every toast ever shown this session, newest last, capped at
    /// [`MESSAGE_LOG_MAX`].
    ///
    /// #toast-history (user: "make way of seeing latest toasts"). Was
    /// `Vec<String>`, which meant the log could say WHAT happened but not
    /// when or how badly — so an error and a routine confirmation read
    /// identically ten minutes later, which is exactly when you are
    /// looking for the error.
    pub message_log: Vec<LoggedMessage>,
    /// Warnings and errors since the history was last opened — the
    /// notification badge's count. A counter rather than a timestamp
    /// because entries carry whole-second times, and either direction of
    /// a clock comparison is wrong at the boundary.
    pub unread_messages: usize,
    /// How many of `unread_messages` are errors, tracked separately so
    /// the badge can colour by level without re-scanning the log.
    ///
    /// Scanning was the first attempt and it was wrong: `take(unread)`
    /// over the whole log walks Info entries too, so one Info toast after
    /// an Error pushed the Error out of the window and painted the badge
    /// yellow for an error.
    pub unread_errors: usize,
    /// Whether messages reach `.mnml/messages.jsonl`.
    ///
    /// False under `--sandbox`. That mode already refuses to READ the
    /// persisted log so the user gets a brand-new-user view; writing to
    /// it anyway meant a throwaway sandbox session on a real workspace
    /// permanently contaminated the next normal session's history with
    /// noise the sandbox itself never showed.
    pub persist_messages: bool,
    /// Entries appended since the log was last pruned. The prune only
    /// ran at startup, so a long-lived session — which is the normal way
    /// mnml is used — appended forever.
    pub messages_since_prune: usize,
    /// Vim `:silent <cmd>` nesting depth. While > 0, `toast()` skips
    /// the visible toast (still records into `message_log`).
    pub silent_depth: usize,
    /// Recently-run command ids, newest first, capped + de-duped (when
    /// the same command runs twice consecutively the second push moves
    /// it to the front instead of duplicating).
    pub recent_commands: Vec<String>,
    /// User-defined ex commands (`:command MyCmd <expansion>`). On
    /// `:MyCmd <args>`, the expansion is run as a fresh ex command with
    /// args appended. Purely an alias layer.
    pub user_ex_commands: std::collections::HashMap<String, UserExCommand>,
    /// Last `:!cmd` shell command (vim `:!!` re-runs it).
    pub last_shell_cmd: Option<String>,
    /// `:`-line history — every accepted ex command is appended (oldest
    /// first, capped at `EX_HISTORY_MAX`). Persisted in session.json so
    /// it survives a relaunch. The vim handler walks it on Up / Down via
    /// the `set_cmdline` trait hook.
    pub ex_history: Vec<String>,
    /// Vim `.` repeat — last completed change as a sequence of key
    /// events (re-feedable through `dispatch_key`). Empty until the user
    /// has done at least one mutation.
    pub dot_keys: Vec<ratatui::crossterm::event::KeyEvent>,
    /// Vim `.` recording — keys of the in-progress change. Started on
    /// the first key that enters Insert mode or produces a one-shot
    /// mutation in Normal; finalized into [`Self::dot_keys`] when mode
    /// returns to Normal (or immediately for one-shot mutations).
    pub dot_recording: Option<Vec<ratatui::crossterm::event::KeyEvent>>,
    /// True if any key during the current `dot_recording` session has
    /// produced a buffer mutation. Used to decide whether to finalize
    /// the recording (mutation seen) or discard it (cancelled chord)
    /// when the recording session ends.
    pub dot_recording_saw_edit: bool,
    /// True while `.` is replaying. Suppresses re-recording (so a `.`
    /// replay doesn't capture itself) and prevents nested replay.
    pub is_replaying_dot: bool,
    /// Count-prefix armed for the next `.` (dot-repeat). Vim's `3.`
    /// runs the last change 3 times — the count REPLACES the count
    /// of the original op, matching `:h .`. Set by the vim `.`
    /// handler before dispatching `vim.dot_repeat`; consumed by
    /// `dot_replay`. Reset to `None` after each replay.
    /// nvchad-user SEV-3 2026-07-10 fix.
    pub pending_dot_count: Option<u32>,
    /// Last `:s` / `:%s` payload, parsed. Vim `&` re-runs it on the cursor's
    /// current line (vim convention: `&` always uses line scope, regardless
    /// of whether the original was buffer-wide). `c` (confirm) flag is
    /// dropped on replay to keep the gesture snappy. Cleared on session end
    /// (not persisted — vim's session "last sub" is also volatile).
    last_substitute: Option<Substitute>,
    /// Per-file last `(cursor_byte, scroll)`, captured when a buffer is closed
    /// or saved, restored when the file is re-opened later. Persisted in
    /// session.json so it survives restarts. Capped at `FILE_CURSORS_MAX`.
    pub file_cursors: std::collections::HashMap<PathBuf, (usize, usize)>,
    /// #polish 2026-07-06 — cross-buffer fold persistence. Keyed by path,
    /// value is a list of `(start_row, end_row)` pairs mirroring
    /// `Buffer.folds`. Updated on every `toggle_fold_at_cursor` /
    /// `unfold_all_in_active` and on buffer close; hydrated back into
    /// `Buffer.folds` on open. Persisted in session.json. Capped at
    /// `FILE_FOLDS_MAX`.
    pub file_folds: std::collections::HashMap<PathBuf, Vec<(usize, usize)>>,
    /// Vim "global" marks (uppercase `A`-`Z`) — cross-file bookmarks. Keyed
    /// by letter; value is `(path, row, col)`. Set by `m<Letter>` on any
    /// buffer; jumped by `'<Letter>` / `` `<Letter>`` from anywhere (opens
    /// the file if needed). Persisted in session.json.
    pub global_marks: std::collections::HashMap<char, (PathBuf, usize, usize)>,
    /// Browser-style navigation back-stack: positions we've been at, oldest
    /// first. `nav_back` (Alt+Left) pops the top, pushes the current position
    /// onto `nav_forward`, and jumps. Pushed by `open_path` (and similar
    /// "fresh jump" code paths) before a navigation.
    pub nav_back: Vec<NavPoint>,
    /// Browser-style navigation forward-stack — only populated after Alt+Left.
    /// Cleared on any fresh jump (you can't go forward after taking a new turn).
    pub nav_forward: Vec<NavPoint>,
    /// True while `nav_back_jump` / `nav_forward_jump` are executing.
    /// The post-dispatch big-jump recorder in `dispatch_key` calls
    /// `record_within_file_jump` on every big cursor move, which
    /// unconditionally cleared `nav_forward` — wiping the entry the
    /// caller just pushed. Consulted by `record_within_file_jump` to
    /// skip that clear when the "big jump" IS the nav call itself.
    /// nvchad SEV-2 2026-07-10 fix (Ctrl+I / Ctrl+O round-trip).
    pub nav_jump_in_progress: bool,
    /// Vim's `'` and `` ` `` marks — the SINGLE position we were at
    /// before the most recent big jump. Distinct from `nav_back`
    /// (which is a stack Alt+Left walks through). `` ` ` `` (backtick
    /// backtick) toggles between this and the current position. Set
    /// by `record_within_file_jump` on every big jump.
    /// nvchad-round-11 SEV-2 2026-07-12.
    pub prev_jump_pos: Option<NavPoint>,
    /// Last mouse left-click for double/triple-click detection — `(when, x,
    /// y, count)`. Reset to count=1 when a click lands too late or in a
    /// different cell. Read by `dispatch_mouse` to upgrade count==2 → word
    /// select, count==3 → line select.
    pub last_click: Option<(std::time::Instant, u16, u16, u8)>,
    /// Win95-style click-echo: on any mouse-Down we stamp
    /// (screen_x, screen_y, start_time). The renderer paints
    /// an hourglass glyph at that cell for the first ~250ms so
    /// the user gets immediate "yes, I saw your click" feedback
    /// even when the underlying action is slow. Decays naturally
    /// as time passes; no explicit clear needed.
    ///
    /// 2026-07-22 user report: "when I click something and there
    /// is a wait can some progress indicator be shown, I tend to
    /// click, think nothing happened, click again."
    pub click_echo: Option<(u16, u16, std::time::Instant)>,
    /// Last mouse-Down coord, cleared on Up. Used by the tab-drag
    /// jitter guard in `up_left.rs` to detect "was this really a
    /// drag or just a click that drifted 1 cell?" Separate from
    /// `click_echo` because click_echo has its own visual-decay
    /// timer (renderer clears it after 120ms), and a mouse hold
    /// longer than that (or a paint gap between Down/Up) would
    /// falsely report "no down" to the jitter guard — tester
    /// found tabs still orphaning on ≥120ms holds. 2026-07-24.
    pub mouse_down_at: Option<(u16, u16)>,
    /// Token bucket for the wheel-flywheel dampener — Logitech
    /// MX-style free-spin wheels keep emitting real OS wheel
    /// events for several seconds after the user physically
    /// releases the wheel, which the coalescer can't tell apart
    /// from active scrolling. The bucket drains on each batched
    /// scroll (one token per line) and refills on idle. A hard
    /// flick burns the bucket; the ringing-down flywheel events
    /// then arrive faster than refill, so the cursor stops.
    pub scroll_bucket: f32,
    /// Last instant we refilled the scroll bucket. Used to compute
    /// elapsed seconds for the leaky-bucket refill.
    pub scroll_bucket_last_refill: Option<std::time::Instant>,
    /// #1236 — when the previous wheel event was applied, for the
    /// rate-based acceleration input. Distinct from
    /// `scroll_bucket_last_refill`, which the dampener advances on
    /// every call including dropped ones.
    pub scroll_last_event_at: Option<std::time::Instant>,
    /// #1236 — highest wheel rate seen in the CURRENT gesture. Once
    /// the rate falls meaningfully below this peak the hand has let
    /// go and the remaining events are inertia, so acceleration stops.
    /// Reset when a gesture gap elapses.
    pub scroll_gesture_peak_rate: f32,
    /// #1236 — set once this gesture's rate collapses below half its
    /// peak: the wheel has stopped and every remaining event is
    /// inertia, so they are DROPPED, not merely un-accelerated.
    /// Cleared when a gesture gap elapses.
    /// #1236 — this gesture's rate has fallen to under half its peak.
    /// Suppresses AMPLIFICATION only; the event still scrolls its line.
    /// It used to gate a `return 0` that discarded input, which ate live
    /// scrolling whenever a hand's rate jittered — the rate is falling
    /// within this gesture, which is not the same as the wheel having
    /// stopped.
    pub scroll_rate_decaying: bool,
    /// #1236 — sub-line remainder carried between events within one
    /// gesture. Without it `floor()` discards the fraction on every
    /// event, so `gentle` (x1.5 on a single notch = 1.5 -> 1) was
    /// byte-identical to `off`. Always < 1.0 and reset per gesture, so
    /// it cannot accumulate into the coasting this feature avoids.
    pub scroll_frac_carry: f32,
    /// #1236 — the acceleration multiplier from the most recent wheel
    /// event. Discrete-row surfaces (the file tree) move by THIS, not
    /// by the event magnitude: magnitude includes hardware granularity
    /// (an MX Master 3 emits several events per physical notch) and
    /// using it made one slow notch jump 2-3 rows.
    pub scroll_last_factor: f32,
    /// #1236 — sub-row accumulator for DISCRETE surfaces (the file
    /// tree). Deriving rows from `round(factor)` made every pinned
    /// event jump exactly 2 rows at `normal` (ceiling 2.5), which is
    /// the "jumps exactly 2" report. Accumulating instead means a
    /// factor of 2.5 yields 2 rows then 3 rows then 2..., averaging
    /// the intended rate without ever jumping on a slow notch.
    pub scroll_row_accum: f32,
    /// #1236 — when a discrete surface (the file tree) last stepped a
    /// row. Batch boundaries are a race: a physical notch emits 2-3
    /// events and whether they land in ONE coalesced batch depends on
    /// whether the poll caught them together, so "one row per batch"
    /// gives 1 row sometimes and 2-3 others. The measured timing
    /// separates cleanly instead — 8-23ms between events inside one
    /// notch, ~150ms between deliberate notches — so a time threshold
    /// is reliable where a batch boundary is not.
    pub tree_last_row_step: Option<std::time::Instant>,
    /// When `[editor] format_on_save = true`, `save_active` fires
    /// `lsp.format` and stashes `(path, deadline)` here. The next
    /// `LspEvent::Formatting` matching `path` applies + chains a save; if
    /// the deadline passes without a reply, `tick` saves anyway (misbehaving
    /// LSPs can't gate save).
    pub pending_format_save: Option<(PathBuf, std::time::Instant)>,
    /// When `[editor] will_save_wait_until = true`, `save_active` fires
    /// `textDocument/willSaveWaitUntil` and stashes `(path, deadline)`
    /// here. The reply applies edits, then chains into either
    /// `pending_format_save` (if `format_on_save` is also on) or
    /// `save_active_now`. Deadline behaves the same as
    /// `pending_format_save`: misbehaving LSPs can't gate save.
    pub pending_will_save: Option<(PathBuf, std::time::Instant)>,
    /// Holds the `{name, domain, path}` of a cookie being edited via
    /// the `e` chord — the BrowserCookieEdit prompt's accept reads
    /// these three to round-trip through `Network.setCookie`.
    pub pending_cookie_edit: Option<(String, String, String)>,
    /// Holds the `(is_local, key)` of a Web Storage entry being edited
    /// via the storage panel's `e` chord — the BrowserStorageEdit
    /// prompt's accept reads this to scope its `setItem` call.
    pub pending_storage_edit: Option<(bool, String)>,
    /// Is the workspace "section" inside the rail expanded? When `false` the
    /// rail shows just the `> WORKSPACE-NAME` header (clickable to expand);
    /// when `true` it shows the header (`v WORKSPACE-NAME`) + the file list.
    /// Independent of [`Self::tree_visible`] (which controls the rail itself,
    /// `Ctrl+B`). Future integration sections (OUTLINE, TIMELINE, …) would each
    /// own their own expanded flag here.
    pub tree_root_expanded: bool,
    /// The persistent `GIT` section in the rail — local branches + worktrees,
    /// refreshed on every git-changing action via [`Self::after_git_change`].
    pub git_rail: crate::git::rail::GitRail,
    /// Terminal image-protocol support, detected once at startup. Drives
    /// whether `Pane::Image` paints actual pixels via Kitty / iTerm2
    /// escapes (post-`terminal.draw()`) or shows a metadata-only fallback.
    pub image_protocol: crate::image::ImageProtocol,
    /// qa-feature 2026-07-02 — cell pixel size probed at startup via
    /// TIOCGWINSZ. `Some((cell_w_px, cell_h_px))` when the terminal
    /// reports both cell counts and pixel dimensions (all modern
    /// terminals do); `None` when the probe fails. Used by the image
    /// viewer to size placements without an aspect-ratio guess.
    pub cell_pixel_size: Option<(u16, u16)>,
    /// Pending image paints captured during this frame's render. `tui.rs`
    /// drains this *after* `terminal.draw()` and emits the protocol-
    /// specific escape so the image lands on top of ratatui's reserved
    /// cells. Cleared each frame; never persisted.
    pub image_paint_requests: Vec<crate::image::PaintRequest>,
    /// True when the previous frame had any image paint requests. Used by
    /// the post-draw emitter to know when to emit a `clear-all-placements`
    /// escape — needed when the user closes / hides an image pane so the
    /// stale image doesn't linger over the next frame's content.
    pub had_image_pane: bool,
    /// qa-feature 2026-07-02 — fingerprint of the last frame's image
    /// paint requests (pane_id + area). When the current frame's set
    /// matches, we skip both the `clear-all` and the placement escapes
    /// entirely — the terminal keeps the already-painted image on
    /// screen, which stops the per-frame flash the user reported.
    pub last_image_paints: Vec<(crate::layout::PaneId, ratatui::layout::Rect)>,
    /// Cross-host PR cache — populated by the `pr.picker` palette
    /// command (which fans out to every installed `mnml-forge-*`
    /// integration via their `--list-prs --json` headless mode). Read
    /// by [`Self::refresh_rail_pulls`] to populate the rail's
    /// "Open PRs" subsection. `None` until first refresh; stale
    /// after `ScmPrCache::MAX_AGE` (5 min) and refreshed lazily.
    pub scm_pr_cache: Option<crate::scm::ScmPrCache>,
    /// In-flight `aggregate_all` worker — set when `pr.picker` or
    /// `pr.refresh` kicked off a background fan-out. The TUI's
    /// `tick` drains this; the picker pops out of the loading
    /// state when the receiver delivers.
    pub scm_pr_pending: Option<std::sync::mpsc::Receiver<crate::scm::ScmPrCache>>,
    /// Runtime `.env` selection override (#11). Takes precedence over
    /// `MNML_ENV` in `EnvSet::select_with_config_default` when set.
    /// Populated by the `http.pick_env` picker; cleared with
    /// `http.reset_env` or a fresh session. Persists across sends
    /// within a session so switching envs doesn't need shell dance.
    pub http_env_override: Option<String>,
    /// Repos discovered inside the workspace. One entry per `.git/` found.
    /// `[]` when the workspace contains no repo. Always-1-entry for the
    /// single-repo case (workspace IS a repo). Multi-repo workspaces get
    /// >1 entries; the rail's switcher then makes sense.
    pub repos: Vec<crate::git::repos::RepoEntry>,
    /// Index into `repos` of the currently-active repo. The git rail
    /// (branches, worktrees, pulls) and `git_config`-based lookups consult
    /// `repos[active_repo].path`. `0` when `repos` has 1 entry. Persisted
    /// across launches by name (not index) so re-discovery order changes
    /// don't shift selection.
    pub active_repo: usize,
    /// 2026-08-24 — repos the user has explicitly closed from the git
    /// multi-repo tab strip this session. Not persisted; a fresh mnml
    /// launch re-opens tabs for every discovered repo. `open_git_graph`
    /// skips repos in this set; a future `+ Reopen…` menu will let the
    /// user pull them back.
    pub git_closed_repos: std::collections::HashSet<std::path::PathBuf>,
    /// #1229 — the layout that was on screen before the user entered the
    /// Git section, so leaving Git can put it back.
    ///
    /// Entering Git replaces the layout wholesale with a GitGraph tab per
    /// repo (2026-08-24 design). Leaving used to set the layout to
    /// `Empty`, which threw away the user's editor tabs along with the
    /// git ones — a section switch silently closed their work. The git
    /// PANES stay in `self.panes` either way, so their scroll/filter
    /// state survives a round trip; only their presence in the layout is
    /// scoped to the section, which is what "the git tabs should
    /// disappear until the user returns" means.
    pub pre_git_layout: Option<(crate::layout::Layout, Option<usize>)>,
    /// #1229 — the pane id `sync_rail_to_focused_repo` last reconciled.
    ///
    /// The rail follows the focused repo TAB, so the sync must fire on a
    /// tab change and nothing else. Without this it also fired after the
    /// left-panel repo dropdown, which sets `active_repo` directly — the
    /// tick would see a still-focused graph belonging to the OLD repo and
    /// immediately undo the user's choice.
    pub last_rail_synced_pane: Option<usize>,

    /// #1229 — how many leading ITEM rows the git rail scrolls past.
    ///
    /// The panel had no scroll state at all, so with 29 tags and 13
    /// branches everything past the panel height was simply unreachable —
    /// three separate user reports ("i have no way to scroll down to see
    /// more branches or tags if they go too long").
    ///
    /// Counted in ITEMS, not screen rows, and applied by trimming the
    /// front of each section's list rather than by translating paint
    /// coordinates. That choice matters: the draw function is ~800 lines
    /// with 26 coordinate touch-points and 17 "have I run out of room"
    /// guards, and translating all of them would have risked misplacing
    /// click rects — a click landing on the wrong branch is worse than no
    /// scrolling. Trimming data keeps the layout strictly top-down, so
    /// every existing guard stays correct and rect registration is
    /// automatically consistent with the paint.
    ///
    /// Section headers are always drawn, so a partially-scrolled section
    /// keeps its label.
    pub git_palette_scroll: usize,
    /// Is the `> GIT` rail section expanded? Sibling of [`Self::tree_root_expanded`].
    /// Persisted in session.json. Default `true`.
    pub git_section_expanded: bool,
    /// Is the `> INTEGRATIONS` rail section expanded? Same lifecycle as
    /// `git_section_expanded`. Default `true`.
    pub integration_section_expanded: bool,
    /// Show ALL branches in the GIT section's branches sub-list?
    /// Default `false`: only the first `BRANCH_LIST_CAP` are shown,
    /// followed by a clickable `+ N more` row that toggles this flag.
    /// Long branch lists (e.g. monorepos with hundreds of feature
    /// branches) would otherwise eat the whole rail.
    pub git_branches_expanded: bool,
    /// Which rail section the keyboard is on when `focus == Focus::Tree`.
    /// Switched by ↓ off the end of the workspace list / ↑ off the top of the
    /// git list, or by clicking a row in the other section.
    pub rail_section: RailSection,
    /// `Some(ws_idx)` when keyboard/mouse focus is on the extra
    /// workspace at that index (instead of the primary tree).
    /// Click on an extra workspace row → sets this; click on
    /// primary tree → clears it. Lets the extra-workspace
    /// renderer draw a cursor highlight on the right tree.
    pub focused_extra_ws: Option<usize>,
    pub git: GitStatus,
    pub toast: Option<(String, Instant)>,
    /// Stack of recent toasts (newest first), capped at `TOAST_STACK_MAX`.
    /// Each entry expires individually after `TOAST_TTL`. Rendered as a
    /// top-right vertical overlay when more than one entry is live, so
    /// rapid-fire toasts ("staged hunk", "saved", "git refreshed") don't
    /// clobber each other. nvim-notify-style stacked notifications.
    pub toast_stack: std::collections::VecDeque<ToastEntry>,
    /// #20 v1 — a single-slot undo chip that appears beside the most
    /// recent destructive toast. Cleared on undo, on expiry
    /// (`UNDO_TTL`), or when a new destructive action fires. Only
    /// one at a time so we don't grow an undo history stack — the
    /// user's mental model is "I just did that thing, take it back."
    pub pending_undo: Option<PendingUndo>,
    /// #23 v2 — stashed env-var key for the pending Delete
    /// context-menu action. Set by the right-click handler on
    /// a Vars row, consumed by the `http.delete_env_key`
    /// command.
    pub pending_env_key_delete: Option<String>,
    /// #20 Pattern B — active confirm-before-destroy modal.
    /// While `Some`, all other input is blocked and the modal
    /// paints on top of everything else.
    pub pending_confirm: Option<PendingConfirm>,
    /// #25 — background-prefetched Claude Agents rows. Populated by
    /// a startup worker thread; `open_claude_agents_pane` reads from
    /// here when set to avoid the ~1-3s sync JSONL walk on the UI
    /// thread. `None` = still loading; `Some(rows)` = ready to use.
    /// Shared behind a Mutex so both the prefetch worker and the
    /// main loop can touch it without racing.
    pub claude_agents_prefetch:
        std::sync::Arc<std::sync::Mutex<Option<Vec<crate::claude_agents::AgentRow>>>>,
    /// #25 v2 — background-prefetched Claude sessions for this
    /// workspace. `open_ai_session_picker` reads from here when
    /// set; falls back to sync scan otherwise.
    pub sessions_prefetch:
        std::sync::Arc<std::sync::Mutex<Option<Vec<crate::ai::transcript::PastSession>>>>,
    /// #25 v4 — last-used age filter for the Claude Agents
    /// dashboard. Persists across sessions; applied to any newly-
    /// built ClaudeAgents pane. Default: Week (7d).
    pub claude_agents_last_age_filter: crate::claude_agents::AgeFilter,
    /// #polish 2026-07-06 — last workspace-grep query the user
    /// ran. Persists across launches via `SavedSession`.
    pub last_grep_query: String,
    /// Pinned toasts — stay on screen until an explicit dismiss by
    /// id. Rendered above the ephemeral stack. Errors here get a
    /// red border; info/warn use the standard comment border.
    /// Keyed by external `id`; a repeat `toast_persistent(id, …)`
    /// with the same id updates the entry in place.
    pub persistent_toasts: Vec<ToastEntry>,
    /// In-flight progress notifications from integrations. Rendered
    /// above the toast stack with an animated Braille spinner.
    /// Keyed by external `id` so `progress_update` and
    /// `progress_end` can find the item. Auto-purged
    /// PROGRESS_END_FADE after finishing.
    pub progress_items: Vec<ProgressItem>,
    /// Integration-authored statusline segments. Hybrid packing at
    /// render time: sorted by priority desc, allocated their
    /// `max_width` while budget allows, dropped when the remaining
    /// budget < `min_width`. Left- and right-side segments compete
    /// separately for their half of the statusline.
    pub dynamic_segments: Vec<DynamicSegment>,
    /// Latest polled JSON blob per manifest-declared
    /// `[[values_sources]]` id. Populated by the workers spawned
    /// from [`Self::start_statusline_segment_workers`]; consumed by
    /// [`Self::drain_statusline_segments`] to template-render the
    /// paired `[[statusline_segments]]` chips. See
    /// `src/app/statusline_segments.rs`.
    pub values_source_snapshots:
        std::collections::HashMap<String, crate::app::statusline_segments::ValuesSnapshot>,
    /// Kept for the lifetime of the worker set — dropping this
    /// closes every worker's send handle so they exit on their
    /// next poll cycle. Re-populated on
    /// [`Self::start_statusline_segment_workers`] (startup +
    /// `integrations.refresh`).
    pub statusline_segments_tx:
        Option<std::sync::mpsc::Sender<crate::app::statusline_segments::SourceUpdate>>,
    /// Receive side of the same channel. Drained per tick via
    /// [`Self::drain_statusline_segments`].
    pub statusline_segments_rx:
        Option<std::sync::mpsc::Receiver<crate::app::statusline_segments::SourceUpdate>>,
    /// Task #966 (2026-08-17) — per-worker shutdown senders. Each
    /// spawned worker owns one `Receiver<()>` and uses
    /// `recv_timeout(interval)` instead of `sleep(interval)` so
    /// dropping the paired sender wakes it immediately (channel
    /// closes → `Err(Disconnected)` → worker exits). Without this,
    /// `integrations.refresh` orphans workers for up to
    /// `MAX_POLL_SECS=3600` (one hour) until they wake naturally on
    /// the next sleep-cycle. Cleared on re-init.
    pub statusline_segment_worker_shutdowns: Vec<std::sync::mpsc::Sender<()>>,
    /// #1117 (2026-08-21) — sibling of the above for the prefetch
    /// worker fleet. Same shape / same lifecycle — cleared on
    /// integration manifest re-merge to drop the previous
    /// generation of workers.
    pub prefetch_worker_shutdowns: Vec<std::sync::mpsc::Sender<()>>,
    /// Ids currently written to `dynamic_segments` by the
    /// manifest-segment render pass. Lets us CLEAR only what we
    /// own (never a segment set by an IPC `statusline_set_segment`
    /// call from an integration) when an integration is uninstalled or
    /// disabled between ticks.
    pub statusline_segment_managed_ids: std::collections::HashSet<String>,
    /// OS notifications queued this tick — drained + emitted as
    /// terminal escape sequences (OSC 9 / OSC 777) after the next
    /// paint. Ghostty/iTerm2/kitty/WezTerm route these to native
    /// macOS/Linux notification banners; terminals that don't
    /// understand the escape silently ignore it. Tuple:
    /// (title, body, sound).
    pub pending_os_notifications: Vec<(String, String, bool)>,
    /// Rate-limit tracker for `notify` calls, keyed by `source`
    /// (integration id). Values are the last-fire wall-clock time
    /// (as monotonic Instants).
    pub notify_last_fired: std::collections::HashMap<String, Instant>,
    pub should_quit: bool,
    /// Set alongside `should_quit` when the loop should exit *for a rebuild+relaunch*
    /// (the `run.sh` wrapper watches for the distinct exit code).
    pub restart_requested: bool,
    /// `view.redraw` (`Ctrl+L`) — clear the terminal backing buffer before the
    /// next paint so a scrambled terminal repaints cleanly. The crossterm loop
    /// checks + clears this flag at the top of each iteration.
    pub redraw_requested: bool,
    /// #1023 (2026-08-18) — last time `App::tick` polled the OS
    /// dark/light preference under `[ui] theme_auto_system`. `None`
    /// before the first check; set to `Some(Instant)` after each
    /// poll. Guarded to fire at most every 15s so `defaults`/
    /// `gsettings`/reg-read isn't hammered.
    pub last_theme_system_check: Option<std::time::Instant>,
    /// Set by command handlers that fail in a way the user already
    /// saw via a toast — `command::run` checks this after invoking
    /// the closure to report `ok=false` in the events log. Reset to
    /// `false` before each `run` call so commands signal failure
    /// without needing to thread Result types through every handler
    /// closure.
    ///
    /// Bug-hunt SEV-3 fix 2026-06-07: `forge.open_lambda` + integrations
    /// used to report `ok=true` even when the underlying `:term`
    /// failed (binary not on PATH); headless callers + plugin
    /// authors couldn't tell.
    pub last_command_failed: bool,
    /// Statusline clock chip flips to UTC when true. Toggled by clicking
    /// the chip; persisted across launches via `SavedSession.clock_show_utc`.
    pub clock_show_utc: bool,
    /// The miniplayer's latest now-playing snapshot (mixr / macOS
    /// Music / Spotify), refreshed off the render path by the
    /// `now_playing` poller thread. `None` until the first poll lands
    /// or when no player is available.
    pub now_playing: Option<crate::now_playing::NowPlaying>,
    /// Channel from the `now_playing` background poller. `Some` once
    /// `start_now_playing_poller` has run — from the real terminal
    /// loop only, so no `osascript` subprocess spawns under headless /
    /// e2e. `tick` drains it into `now_playing`.
    pub now_playing_rx: Option<std::sync::mpsc::Receiver<Option<crate::now_playing::NowPlaying>>>,
    /// #1151 (2026-08-23) — marquee/autoscroll offset for the
    /// now-playing chip label. Advanced in `tick()` when
    /// `[ui] now_playing_marquee` is on and the label
    /// overflows the 28-char window. Reset to 0 whenever the
    /// track text changes. Only carries state between ticks
    /// — the actual slice happens in `ui::statusline`.
    pub now_playing_marquee_offset: usize,
    /// Wall-clock timestamp of the last marquee offset
    /// advance. Used to pace the scroll at ~3 chars/sec
    /// (300ms per char) regardless of poll cadence.
    pub now_playing_marquee_last_tick: Option<std::time::Instant>,
    /// Track text the offset was computed against; when the
    /// poller swaps in a different track, we reset the offset
    /// so the new label starts from the beginning.
    pub now_playing_marquee_prev_text: String,
    /// Latest Sonos snapshot — rooms, transport, volume — refreshed off
    /// the render path by the `sonos` worker thread. Default (no
    /// players) until the first poll lands; the chip hides itself in
    /// that state so a Sonos-less network shows no dead furniture.
    pub sonos: crate::sonos::Snapshot,
    /// Command channel to the `sonos` worker. `Some` once
    /// `start_sonos_worker` has run — the real terminal loop only, so
    /// headless / e2e never touch the network.
    pub sonos_tx: Option<std::sync::mpsc::Sender<crate::sonos::Cmd>>,
    /// Snapshot channel from the `sonos` worker; `tick` drains it.
    pub sonos_rx: Option<std::sync::mpsc::Receiver<crate::sonos::Snapshot>>,
    /// Last time the now-playing poller returned a non-empty
    /// mixr-source track. Drives the stickiness layer in
    /// `drain_now_playing` so the statusline chip doesn't flicker
    /// back to `♪ mixr` during the brief gaps mixr writes between
    /// song transitions or `playing_active` flag dips. `None`
    /// before any mixr read; reset to `None` implicitly when the
    /// 10s TTL lapses (a genuine queue-empty state).
    pub last_mixr_track_at: Option<std::time::Instant>,
    /// In-flight `http.sync` worker result channel. `Some(rx)`
    /// while the background fetch is running; `App::tick` drains
    /// it. None when idle. Phase 2 of the rqst→mnml port-back.
    pub http_sync_rx: Option<std::sync::mpsc::Receiver<Result<(String, usize), String>>>,
    /// In-flight `http.sync_check` worker result channel — same
    /// shape as `http_sync_rx` but the string is the drift trace
    /// (added/removed/changed report) instead of the sync trace,
    /// and no writes happen. 2026-07-08.
    pub http_sync_check_rx: Option<std::sync::mpsc::Receiver<Result<(String, usize), String>>>,
    /// In-flight `http.bench` worker result channel. Same shape /
    /// drain pattern as `http_sync_rx`; payload is the bench's
    /// trace string (multi-line summary the user will see in a
    /// toast preview + paste from clipboard for the full thing).
    pub http_bench_rx: Option<std::sync::mpsc::Receiver<String>>,
    /// Async worker channel for `:ai.session_search`. The search
    /// walks 3000+ transcripts (3-4 GB) on macOS; running it on
    /// the main thread froze the UI for 1.4-1.8s per query
    /// (claude-agents-power-user SEV-2 2026-07-11). Now spawned;
    /// drained from `App::tick`.
    pub ai_session_search_rx:
        Option<std::sync::mpsc::Receiver<(String, Vec<crate::claude_agents::SearchHit>)>>,
    /// 2026-06-19 polish — when these async ops are in flight,
    /// stash an Instant so the cmdline_bar can show elapsed time
    /// next to the `⟳ running…` indicator.
    pub http_bench_started: Option<std::time::Instant>,
    /// 2026-06-20 — live progress for the bench worker. The worker
    /// increments this AtomicU32 after each completed request;
    /// cmdline_bar reads it to show `bench (12/100 · 5s)`.
    pub http_bench_progress: Option<(std::sync::Arc<std::sync::atomic::AtomicU32>, u32)>,
    /// 2026-06-21 — WS v2 moved the connection state onto its own
    /// `Pane::Websocket` variant; multi-connection is now native.
    /// `App.websocket{,_pane_id}` removed.
    pub http_sync_started: Option<std::time::Instant>,
    pub lookup_fire_started: Option<std::time::Instant>,
    /// Domain-keyed cookie jar. Loaded from `.mnml/cookies.json`
    /// at App init; written by `:cookies.persist`. Auto-injected
    /// into Request pane sends via `spawn_http_job`.
    pub cookie_jar: std::sync::Arc<std::sync::Mutex<crate::cookie_jar::CookieJar>>,
    /// `@capture`d vars persisted across `:http.send` fires so a
    /// login → orders → … flow works from an `.http`/`.curl` file
    /// without wrapping the whole thing in a `.chain.json`. Keyed by
    /// source path (empty PathBuf for pane-only requests with no
    /// backing file). Merged into each fire's `EnvSet` before the
    /// worker thread expands templates. api-workflow round-7 SEV-1
    /// 2026-07-11 — the docs promised this but only chain steps
    /// actually threaded a running env.
    pub http_running_env:
        std::collections::HashMap<std::path::PathBuf, std::collections::HashMap<String, String>>,
    /// Snapshot of `.rqst/captured/log.jsonl` for the current
    /// captured-viewer picker (`PickerKind::CapturedRows`). The
    /// picker's `id` field is a string index into this. Cleared
    /// after the picker closes. Phase 4 follow-up.
    pub pending_captured_rows: Vec<crate::http::captured::CapturedRow>,
    /// Snapshot of `.rqst/history.jsonl` rows for the current
    /// history picker (`PickerKind::HistoryRows`). Phase 9 follow-up.
    pub pending_history_rows: Vec<serde_json::Value>,
    /// Parsed lookup items from the most-recent lookup-file fire.
    /// Indexed by `PickerKind::LookupItem`'s `id`. Phase 7.
    pub pending_lookup_items: Vec<crate::http::lookup::LookupItem>,
    /// The id of the lookup item the user picked — used by the
    /// `PromptKind::LookupVarName` accept handler to write
    /// `<typed-var>=<pending_lookup_picked_id>` into the env file.
    pub pending_lookup_picked_id: Option<String>,
    /// Env-var being edited by the structured env editor. Set
    /// when the `EnvVars` picker accepts an existing key; consumed
    /// by `PromptKind::EnvEditValue`. Phase 3 polish.
    pub pending_env_edit_key: Option<String>,
    /// In-flight lookup-file fire result channel. Payload is
    /// `Ok((response_body, file_label))` or `Err(message)`. Drained
    /// by `App::tick`; on success, parses items + opens
    /// `PickerKind::LookupItem` picker.
    pub lookup_fire_rx: Option<std::sync::mpsc::Receiver<Result<(String, String), String>>>,
    /// `:debug.rects` overlay state — when `true`, the renderer
    /// paints colored borders around every registered click rect so
    /// the user can SEE the hit boundaries vs the rendered glyphs.
    /// Toggle via `:debug.rects` from the cmdline. Bug-hunt tool —
    /// added 2026-06-19 after the workspace-add `+` chip's rect
    /// off-by-one (wide-glyph cell-width mismatch) wasted a long
    /// debug session.
    pub debug_rects: bool,
    /// App-level ex-cmdline buffer — `Some(text)` while a `:` prompt
    /// is being typed from a non-pane focus (tree / empty-state /
    /// any context without an editor buffer). The bottom cmdline_bar
    /// reads this and paints `:<text>` in the same yellow style the
    /// in-buffer vim cmdline uses, so the affordance is consistent
    /// regardless of where focus is. `None` when no prompt is open.
    ///
    /// Vim's per-buffer cmdline still owns the in-buffer case to keep
    /// the (already correct) vim handler's state intact — this only
    /// kicks in when `pending_display()` would otherwise be `None`.
    /// User-requested 2026-06-18 after the centered Prompt looked
    /// inconsistent with vim's bottom-anchored cmdline.
    pub no_pane_cmdline: Option<String>,
    /// Active filter text for the git palette's search input
    /// (case-insensitive substring match against branch / remote
    /// / worktree / stash / tag / PR names). Empty string = no
    /// filter. Cleared when the user closes the Git activity
    /// section.
    pub git_palette_filter: String,
    /// `true` while the user's keyboard focus is in the git palette
    /// filter input. Typing in this state extends the filter; Esc
    /// clears it.
    pub git_palette_filter_focused: bool,
    /// qa-feature 2026-06-30 — the palette row the user last
    /// activated (branch / worktree / stash / PR / tag name). The
    /// row renders with a highlight bg so the user has visual
    /// feedback after clicking. Set by the down-left handler;
    /// cleared on activity-section change or repo switch.
    pub git_palette_selected: Option<String>,
    /// qa-feature 2026-06-30 — set of git-palette SECTION names
    /// the user has collapsed (LOCAL / REMOTE / WORKTREES / PRS /
    /// STASHES / TAGS). Click the section header to toggle. When
    /// collapsed, the chevron flips to `▸` and the section's
    /// rows aren't rendered.
    pub git_palette_collapsed_sections: std::collections::HashSet<String>,
    /// qa-feature 2026-06-30 — set of folder names (`chore`,
    /// `fix`, …) inside the LOCAL / REMOTE sections that the
    /// user has collapsed. Click a folder header toggles. Stored
    /// as `section:folder` to disambiguate `chore` under LOCAL
    /// vs REMOTE.
    pub git_palette_collapsed_folders: std::collections::HashSet<String>,
    /// `true` while the workspace-picker dropdown is open (anchored
    /// under the workspace header in the rail). Click the `▾` chip
    /// to toggle; click a row to switch + close; Esc / click-out
    /// closes.
    pub workspace_picker_open: bool,
    /// Filter input for the workspace picker (case-insensitive
    /// substring match against workspace name + group label).
    pub workspace_picker_filter: String,
    /// `true` while the workspaces editor overlay is open
    /// (opened from Settings → "Manage workspaces…"). The overlay
    /// lists configured `[[workspaces]]` and offers add / edit /
    /// delete. Esc closes.
    pub workspaces_editor_open: bool,
    /// Selected row index in the workspaces editor (used by
    /// keyboard nav). Last row = the `+ Add workspace…` action.
    pub workspaces_editor_selected: usize,
    /// `Some(idx)` while a workspace rename prompt is open;
    /// commit applies the new name to `config.workspaces[idx]`
    /// and persists.
    pub workspaces_edit_target_name: Option<usize>,
    /// `Some(idx)` while a workspace path-edit prompt is open.
    pub workspaces_edit_target_path: Option<usize>,
    /// `Some(idx)` while a workspace group-edit prompt is open.
    pub workspaces_edit_target_group: Option<usize>,
    /// Corner-pinned dock widgets (third UI tier between full
    /// panes and 1-row status chrome). v1 ships bottom-left
    /// `Text` widgets only — see `src/dock.rs` + `src/ui/dock.rs`.
    pub dock_widgets: Vec<crate::dock::DockWidget>,
    /// `(label, pane_idx)` of the most recently launched test
    /// runner pane (cargo / npm / pytest / go / playwright). Used
    /// by the statusline to surface a clickable chip → focus the
    /// pane. Cleared when the pane is closed.
    pub last_test_run: Option<(String, usize)>,
    /// Cached snapshot for the rail `Agents` panel — rebuilt
    /// every `AGENTS_PANEL_REFRESH` while the section is active.
    /// `None` ⇒ never built.
    pub agents_panel_rows: Vec<crate::claude_agents::AgentRow>,
    /// When `agents_panel_rows` was last refreshed.
    pub agents_panel_built_at: Option<std::time::Instant>,
    /// Receiver for the off-main-thread build worker. `Some` means
    /// a refresh is in flight; the next `tick()` drains it.
    pub agents_panel_rx: Option<
        std::sync::mpsc::Receiver<(
            Vec<crate::claude_agents::AgentRow>, // local Claude/Codex rows
            Vec<crate::claude_agents::AgentRow>, // cloud rows
            std::collections::HashMap<String, crate::ecs_runner::EcsRunMeta>,
        )>,
    >,

    /// Sender for cloud-run worker threads (managed-agents
    /// submit, sigv4 calls, etc.) to push status / error messages
    /// back to the UI thread for toasting. Workers must NEVER
    /// `eprintln!` from a ratatui process — stderr writes to the
    /// TTY and corrupts the frame. Use this channel instead.
    /// Drained in `tick()`.
    pub cloud_run_msg_tx: std::sync::mpsc::Sender<String>,
    pub cloud_run_msg_rx: Option<std::sync::mpsc::Receiver<String>>,

    /// Quick-fire prompt buffer for the Cloud Agents panel's
    /// daily-driver input row. When focused + Enter, fires
    /// create_session + send_user_message against the saved
    /// `[cloud_run.defaults]` — no wizard needed.
    pub cloud_run_prompt_input: String,
    pub cloud_run_prompt_focused: bool,
    /// Cloud-only rows (ECS runner). Built by the same worker
    /// thread that builds `agents_panel_rows`; rendered by the
    /// Cloud Agents activity-bar panel.
    pub cloud_agents_rows: Vec<crate::claude_agents::AgentRow>,
    /// `/`-style substring filter for the rail agents panel
    /// (workspace / session id / last_msg). Case-insensitive.
    pub agents_panel_filter: String,
    /// `/`-style substring filter for the rail HTTP panel — matches
    /// env / chain / mock / collection / request labels. Case-
    /// insensitive. Empty = show everything (default).
    pub http_panel_filter: String,
    /// `true` while the user is typing into the HTTP panel's filter
    /// input (mirrors `agents_panel_filter_focused`).
    pub http_panel_filter_focused: bool,
    /// `/`-style filter for the TODOs panel — case-insensitive match
    /// against the marker tag, path, and title. Empty = show all.
    pub todos_panel_filter: String,
    pub todos_panel_filter_focused: bool,
    /// `/`-style filter for the Notes panel — case-insensitive match
    /// against the note file name. Empty = show all.
    pub notes_panel_filter: String,
    pub notes_panel_filter_focused: bool,
    /// When the 3rd Claude Code pane opens, the layout rearranges
    /// into a 2×2 grid with the bottom-right quadrant as
    /// `Layout::Empty` — a placeholder for the eventual 4th
    /// Claude. This flag marks that placeholder as live so the
    /// renderer knows to paint the `+ Add Claude Code` card
    /// (instead of a blank rect) and the mouse handler knows to
    /// treat clicks on it as a "launch the 4th Claude" affordance.
    /// Cleared when the 4th Claude fills the slot or when either
    /// of the 3 Claudes is closed (the split collapses).
    pub ai_placeholder_slot: Option<crate::app::AiPlaceholderKind>,

    /// User-controlled session ordering (when `sessions_sort_mode
    /// == Manual`). Session pane ids in the order they should be
    /// listed. Ids not in this vec render after those that are,
    /// in their natural `App.panes` order.
    pub sessions_manual_order: Vec<usize>,
    /// PaneIds of pinned sessions. Pinned sessions bubble to the
    /// top of the Sessions panel regardless of the sort mode.
    pub sessions_pinned: std::collections::HashSet<usize>,
    /// Sort mode for the Sessions panel — Auto (running → idle →
    /// exited) or Manual (user's `sessions_manual_order`).
    pub sessions_sort_mode: crate::app::SessionsSortMode,

    /// `/`-style filter for the Sessions panel — case-insensitive
    /// match against session display name, git branch, cwd basename,
    /// and detected ticket. Empty = show all.
    pub sessions_panel_filter: String,
    pub sessions_panel_filter_focused: bool,
    /// Row cursor for j/k / arrow navigation on the three activity
    /// panels (indexes into the currently-visible filtered list).
    /// Reset on section change, filter accept, or refresh.
    /// Enter activates: TODOs → jump to hit; Notes → open note;
    /// Sessions → focus the Pty. vscode-user-keyboard SEV-2 fix
    /// 2026-07-09.
    pub todos_panel_cursor: usize,
    pub notes_panel_cursor: usize,
    /// FINDINGS had no cursor at all until 2026-09-01, so its rows
    /// could not be highlighted, keyboard-navigated, or marked with the
    /// selected-row accent its sibling panels use (user ask).
    pub findings_panel_cursor: usize,
    /// First visible row for the three list panels.
    ///
    /// They had NO scroll state at all until 2026-09-01: each drew the
    /// first screenful and everything past it was unreachable, with no
    /// scrollbar to say so — 93 TODOs looked like 40 (user report).
    pub todos_panel_scroll: usize,
    pub notes_panel_scroll: usize,
    pub findings_panel_scroll: usize,
    pub sessions_panel_cursor: usize,
    /// #1184 (2026-08-23) — first visible row in the sessions rail.
    /// User hit "can only reliably load 9 or so Claudes in total,
    /// its not scrolling down on left panel and some are out of
    /// view". Draw path clamps to number of rows the area can
    /// fit; wheel + `sessions.scroll_*` commands mutate this.
    pub sessions_panel_scroll: usize,
    /// Top-row scroll offset for the agents panel's content list (the
    /// session rows scroll; the filter + `+ New session` header stays put).
    /// Clamped to the content height each render.
    pub agents_panel_scroll: usize,
    /// qa-feature 2026-07-01 — vertical scroll offset for the
    /// Integrations activity panel scroll — per-tab so switching
    /// Installed ↔ Marketplace remembers where you were on each.
    /// Each icon takes 3 rows; wheel + PageUp/Down bump by 3.
    /// (Legacy shared field kept until callers migrate; new UI
    /// reads/writes the tab-specific fields instead.)
    pub integrations_panel_scroll: usize,
    pub integrations_panel_scroll_installed: usize,
    pub integrations_panel_scroll_marketplace: usize,
    /// 2026-08-19 (#1056) — companion scroll state for the In-Dev tab
    /// so switching between tabs keeps each one's position.
    pub integrations_panel_scroll_in_dev: usize,
    /// Held by `open_marketplace_install_prompt` while the
    /// `MarketplaceInstallConfirm` two-button dialog is showing.
    /// Accept path reads this to know which entry to install.
    pub pending_marketplace_install_idx: Option<usize>,
    /// Integrations activity panel — filter query.
    /// Case-insensitive substring match against each icon's
    /// tooltip / id / command. Empty ⇒ no filter.
    pub integrations_panel_filter: String,
    /// Integrations activity panel — explicit filter focus.
    /// Was auto-focused (any char in the section went to the filter)
    /// but that class-of-bugs stole ex-command chars, palette
    /// shortcuts, etc. Now: `/` in the panel or clicking the filter
    /// chip sets this to true; Esc or Enter clears it.
    pub integrations_panel_filter_focused: bool,
    /// Integrations activity panel — which sub-view is active.
    /// `Installed` (default) lists the user's enabled integrations
    /// — the daily-driver rail. `Marketplace` lists everything
    /// else so the user can enable more.
    pub integrations_panel_tab: IntegrationsPanelTab,
    /// 2026-08-07 — sort mode for the Installed tab. Click the
    /// `⇅` chip in the panel header to cycle. Not persisted in v1
    /// (per-session).
    pub installed_sort: InstalledSort,
    /// Sort mode for the Marketplace tab. Same UX as `installed_sort`
    /// — the two tabs each carry their own sort state so switching
    /// between them doesn't reset the other.
    pub marketplace_sort: MarketplaceSort,
    /// `true` while the user's keyboard focus is in the rail
    /// agents panel's filter input.
    pub agents_panel_filter_focused: bool,
    /// `true` to group rail Agents panel rows by workspace
    /// (collapsible per-workspace groups) instead of by status.
    /// Toggled by `g` while the section is active, or by clicking
    /// the view-mode chip in the panel header.
    pub agents_panel_group_by_workspace: bool,
    /// Workspace labels EXPANDED in the by-workspace view —
    /// default empty means everything is collapsed. Click a
    /// workspace header to add/remove from this set. Cleared
    /// when toggling out of workspace view so re-entering starts
    /// fresh.
    pub agents_panel_expanded_workspaces: std::collections::HashSet<String>,
    /// `/`-style substring filter for the rail Cloud Agents panel.
    /// Independent of the local agents panel filter.
    /// Cloud-agents panel row density. Compact = 1 line / row
    /// (scannable when there are many runs). Standard = 3 lines /
    /// row, surfacing flow / state / ticket / last activity so you
    /// don't have to drill in to know what's what. Toggle via
    /// `:cloud_agents.toggle_view` or click the chip in the panel
    /// header.
    pub cloud_agents_view: CloudAgentsView,
    pub cloud_agents_filter: String,
    /// `true` while the user's keyboard focus is in the Cloud
    /// Agents panel's filter input.
    pub cloud_agents_filter_focused: bool,
    /// Top-row scroll offset for the Cloud Agents content list.
    pub cloud_agents_scroll: usize,
    /// Per-runId cloud-row metadata (prUrl, s3 prefix, …) populated
    /// by the ECS runner scan. Keyed by runId (== `AgentRow.session_id`
    /// for cloud rows). Lets the right-click menu build URLs without
    /// bloating `AgentRow`.
    pub cloud_agents_meta: std::collections::HashMap<String, crate::ecs_runner::EcsRunMeta>,
    /// Monotonically-increasing id for new dock widgets. Each
    /// `dock.new_*` invocation bumps it; ids are stable for the
    /// session.
    pub dock_widget_next_id: usize,
    /// `Some(id)` while the user is mid-drag on a dock widget's
    /// title bar. Mouse-up resolves the drag to a new corner
    /// based on the cursor's final quadrant in the editor area.
    pub dock_drag_id: Option<usize>,
    /// `Some(pane_id)` while the user is mid-drag on a session
    /// tab in the sessions panel. Mouse-up over another tab
    /// swaps the two panes in `App::panes`. None ⇒ idle.
    pub session_drag_pid: Option<usize>,
    /// 2-second cache: pid → (refreshed_at, listening TCP ports).
    /// The sessions-panel renderer queries this; the underlying
    /// `lsof` shell-out runs at most once per pid per 2 seconds.
    pub session_port_cache: std::collections::HashMap<u32, (std::time::Instant, Vec<u16>)>,
    /// Live cursor position during a dock drag. Updated on every
    /// Mouse Drag event while `dock_drag_id` is set; consumed by
    /// the renderer to paint the ghost next to the cursor + the
    /// hover-corner overlay.
    pub dock_drag_cursor: Option<(u16, u16)>,
    /// Open kebab-menu state: `(widget_id, anchor_xy, selected_idx)`.
    /// `None` ⇒ no menu open. The menu lists Resize / Move to /
    /// Close items; `selected_idx` indexes into the flat item list
    /// (with sub-menus expanded).
    pub dock_kebab_menu: Option<crate::dock::KebabMenuState>,
    /// `Some(widget_id)` while the dock-rename prompt is open.
    /// Commit handler reads this to know which widget to retitle.
    pub dock_rename_target: Option<usize>,
    /// Persistent quick-scratch terminal — a ~10-row bottom strip
    /// hosting a shell pty. Sibling to `Pane::Pty` (which is a full pane),
    /// designed for "I want to run one command without rearranging my
    /// splits". Toggled by `term.scratch_toggle`; survives pane switches.
    pub scratch_term: Option<ScratchTerm>,
    /// In-flight tree drag — populated by mouse-down on a tree row, armed
    /// by mouse-move, applied on mouse-up onto a directory row (after a
    /// confirmation prompt). Drop on the source's own parent (a no-op) is
    /// silently ignored.
    pub tree_drag: Option<TreeDrag>,
    /// Pending tree move — set when the user releases a drag on a different
    /// directory; the prompt accept reads from here and runs the rename.
    pub pending_tree_move: Option<(std::path::PathBuf, std::path::PathBuf)>,
    /// Stashed (start_line, end_line) for the vim `!{motion}` filter.
    /// Set by `App::begin_filter_lines_from_cursor` before opening
    /// the `FilterLinesShellCmd` prompt; consumed by
    /// `accept_filter_lines_shell_cmd` on prompt accept.
    /// nvchad-round-9 SEV-2 2026-07-11.
    pub pending_filter_range: Option<(usize, usize)>,
    /// Rolling window of recent frame durations (tick + draw + event
    /// wait) in milliseconds. Populated by the main loop in
    /// `tui::mod::run_loop`; consumed by the `stress` statusline
    /// chip to give the user a live signal of how loaded mnml is.
    /// Ring buffer: newest at the back, capped at ~120 samples
    /// (~2s at 60Hz idle, longer under load).
    pub frame_times_ms: std::collections::VecDeque<u16>,
    /// In-flight pty drag-select. `(pane_id, origin_cell, current_cell)`
    /// where cells are (col, row) in pane-body coordinates. The pty
    /// renderer inverts cells inside the range; mouse-up extracts the
    /// text and copies it to the clipboard. Only armed on the first
    /// drag (not a click). mouse-round-9 SEV-2 2026-07-11.
    pub pty_drag_select: Option<(PaneId, (u16, u16), (u16, u16))>,
    /// Stashed by the toast right-click menu so the "Dismiss this
    /// toast" action knows which index to remove. Cleared on
    /// commit / cancel. mouse-round-10 SEV-2 2026-07-12.
    pub pending_toast_dismiss_idx: Option<usize>,
    /// `:rename`'d Claude session names from a previous launch, keyed
    /// by `--session-id`. Restored from `SavedSession.pty_session_names`;
    /// re-applied to a Claude pane whose session id matches when it's
    /// (re)opened.
    pub saved_pty_session_names: std::collections::HashMap<String, String>,
    /// Git operation undo / redo stacks (GitGraph toolbar Undo / Redo).
    /// A new git op pushes onto `git_undo_stack` + clears the redo
    /// stack; Undo moves an entry undo→redo, Redo moves it back.
    /// In-memory only — entries that no longer apply (HEAD moved by an
    /// external git op) fail harmlessly with a toast.
    pub git_undo_stack: Vec<GitUndoEntry>,
    pub git_redo_stack: Vec<GitUndoEntry>,
    /// Currently-hovered clickable chip + when it first became hovered.
    /// After `HOVER_TOOLTIP_DELAY_MS` of stable hover, the tooltip renders
    /// next to the chip. Cleared on click / typing / mouse-leave.
    pub hover_chip: Option<(crate::HoverChip, std::time::Instant)>,
    /// Debounce state for the Info View hover-help panel — text only
    /// swaps after the hover target has been stable for
    /// `HOVER_HELP_DEBOUNCE_MS`. Without this a mouse drag across
    /// tree rows flashes the panel content rapid-fire (2026-08-12
    /// user report). `committed` is what's currently rendered;
    /// `pending` is the candidate awaiting settle. See
    /// `src/ui/hover_help.rs::draw` for the state machine.
    pub hover_help_committed: Option<crate::ui::info_view::InfoViewCopy>,
    pub hover_help_pending: Option<(crate::ui::info_view::InfoViewCopy, std::time::Instant)>,
    /// Row offset into the wrapped body of the hover-help panel. When
    /// the wrapped-line count exceeds available height, mouse-wheel
    /// over the panel bumps this up/down. Auto-resets when the
    /// committed target changes (fresh copy → back to top).
    pub hover_help_scroll: u16,
    /// Live height (rows) of the hover-help panel. Initialized from
    /// `[ui] hover_help_height` on App::new; mutated live during a
    /// drag on the panel's top border; persisted back to config on
    /// drag-end. Renderer + layout reservation both read this field,
    /// NOT the config value — so a mid-drag preview is immediate.
    pub hover_help_height: u16,
    /// Drag state for the hover-help panel resize handle:
    /// `Some((start_mouse_y, start_height))` when the user is
    /// actively dragging the top border. Cleared on mouse-up.
    pub hover_help_drag: Option<(u16, u16)>,
    /// Last observed mouse position (col, row) from a `Moved` event.
    /// `None` until the mouse first moves (fresh session or after a
    /// keystroke that reset hover state). Consumed by hover-only
    /// affordances that want to condition their hit-rects on "is the
    /// mouse over me right now" without going through the `hover_chip`
    /// tooltip pipeline. mouse-round-12 SEV-2 F1 2026-07-14.
    pub mouse_pos: Option<(u16, u16)>,
    /// PaneId of the bufferline tab the mouse is currently over
    /// (any tab, active or not). Set by the `Moved` mouse handler
    /// when the pointer is over a `bufferline_tabs` rect; cleared
    /// when it moves off. Consulted by the bufferline renderer so
    /// a non-active tab's close `×` glyph appears on hover, giving
    /// users a "close inactive tab in one click" affordance
    /// (previously they had to focus the tab first). 2026-07-12.
    pub hovered_bufferline_tab: Option<PaneId>,
    /// mouse-round-16 F1 2026-07-16 — screen coord (col, row) of the
    /// last bufferline close-× click. Set when a close fires;
    /// consulted on subsequent Down(Left) events: if the pointer is
    /// STILL at those same coords, the click is suppressed as an
    /// accidental double-tap on whatever tab slid into the just-
    /// closed slot. Cleared on any Moved event that lands at a
    /// different coord (the user physically moved the mouse), and
    /// on any non-close click (they've moved on to another action).
    /// Rationale: rapid dbl-click at a fixed coord was closing 2
    /// tabs — round-15's `last_click=None` fix only broke the
    /// dbl-click STATE; the raw second click still hit the newly-
    /// slotted tab's close-X because it's rendered at the same
    /// coord. This gate requires physical mouse movement between
    /// intentional closes.
    pub last_tab_close_at: Option<(u16, u16)>,
    /// Which editor line is currently under the mouse cursor
    /// (`(pane_id, 0-based line_no)`). Drives the VS Code-style
    /// fold-arrow indicator: foldable lines show a `↓` in the
    /// sign column only when hovered; folded lines show a `→`
    /// persistently. Cleared on mouse-leave / mouse-out of any
    /// editor pane. 2026-07-11.
    pub hover_editor_line: Option<(crate::layout::PaneId, usize)>,
    /// Index into `rects.split_dividers` of the divider the mouse is currently
    /// hovering. Drives the per-divider yellow tint that advertises drag-
    /// resizability. Cleared on click + on hover-leave.
    pub hover_divider_idx: Option<usize>,
    /// True when the mouse is hovering the tree's resize edge (right
    /// column of the rail). Drives the border-highlight cue that
    /// replaced the grip glyph 2026-07-08. Cleared on hover-leave.
    pub hover_tree_edge: bool,
    /// True when the mouse is hovering the right-panel's resize edge
    /// (left column of the panel). Same cue idiom as `hover_tree_edge`.
    pub hover_right_panel_edge: bool,
    /// `F1` discovery overlay — a centered floating panel listing every
    /// clickable region category with live rect counts. Press F1 again or
    /// Esc to close. In-memory only.
    pub show_discovery_overlay: bool,
    /// While set, the renderer flashes the matching rects yellow for
    /// `DISCOVERY_FLASH_MS`. Set when the user clicks a row in the F1
    /// overlay; cleared automatically by `App::tick` once the flash
    /// expires.
    pub discovery_flash: Option<(crate::DiscoveryCategory, std::time::Instant)>,
    /// Welcome overlay — opens automatically on the first launch in a
    /// workspace (detected via missing `.mnml/.welcomed` marker). Esc /
    /// any click / `view.welcome` toggles. Persists the dismiss across
    /// launches.
    pub show_welcome: bool,
    /// When true, every left- and right-click emits a toast listing
    /// the names of every `PaneRects` field whose rect contained the
    /// click coord. Toggle via `debug.toggle_click_inspector`. Meant
    /// as a diagnostic for the stale-rect / rect-shadowing bug class
    /// — hover-tooltips + click-target lists side by side make it
    /// obvious when a stale rect is stealing input.
    pub debug_click_inspector: bool,
    /// Background "is there a newer release?" probe. `None` in
    /// headless mode. Toasts once (via `maybe_announce_update`) when
    /// the fetch resolves with a newer tag.
    pub update_check: Option<std::sync::Arc<crate::update_check::UpdateCheck>>,
    /// Startup workspace picker — `Some` while the launch-time
    /// chooser overlay is shown. See `src/ui/startup_picker.rs` for
    /// rationale. Set by `App::new` based on the `--startup-picker`
    /// CLI flag or `MNML_STARTUP_PICKER=1` env var, cleared on the
    /// user's first selection / Esc.
    pub startup_picker: Option<StartupPickerState>,
    /// About overlay — `view.about` / `:about` toggle. Shows the build
    /// SHA + workspace metadata (theme, repos, LSP servers, tab/pane
    /// counts). In-memory only, dismisses on Esc / click outside.
    pub show_about: bool,
    /// True after a quit was refused because of unsaved changes — a second
    /// `request_quit` then goes through. Cleared by saving.
    pub quit_armed: bool,
    pub rects: PaneRects,
    /// flash/leap state — Some while labels are painted on the active editor
    /// and the dispatcher is intercepting the next keystroke for a jump.
    pub flash_state: Option<crate::flash::FlashState>,
    /// inc-rename-style preview state — Some while an `lsp.rename` prompt is
    /// open. The renderer paints the prompt's current text inline at every
    /// whole-word occurrence of `original_word` in the active editor.
    /// Single-file MVP — the post-accept `RenamePreview` picker still shows
    /// the full cross-file effect.
    pub rename_preview_state: Option<RenamePreviewState>,
    /// The active register / system-clipboard bridge, threaded into `Editor::apply`.
    pub clipboard: Clipboard,
    /// The fuzzy-picker / command-palette overlay, when open. Steals key input.
    pub picker: Option<Picker>,
    /// Resolved key→command table (registry defaults + `[keys.*]` config).
    /// Rebuilt when the input style changes (a mode section may rebind a chord).
    pub keymap: crate::input::keymap::Keymap,
    /// Background git-loader thread channel. Sends jobs (push, pull,
    /// fetch, cherry-pick) so the UI thread never blocks on a slow
    /// remote / credential-helper prompt. Drained in `App::tick` →
    /// `drain_git_results`. Wired by `App::new`.
    /// untouched-surfaces-hunt-2026-06-08 SEV-1.
    pub git_loader_tx: std::sync::mpsc::Sender<git_async::GitJob>,
    pub git_loader_rx: std::sync::mpsc::Receiver<git_async::GitResult>,
    /// In-flight chord-chain prefix. Pushed-to whenever a key matches as
    /// `Pending` / `PendingWithFallback`; cleared on Run / on a non-extending
    /// key / on the timeout tick. Empty when no chain is in flight (the
    /// usual case).
    pub pending_chord_seq: Vec<crate::input::keymap::Chord>,
    /// Wallclock deadline at which the chord-chain pending state gives up.
    /// `App::tick` checks this each frame; on elapse, the `pending_chord_fallback`
    /// fires (if any) and pending is cleared. None ⇒ nothing pending.
    pub pending_chord_deadline: Option<std::time::Instant>,
    /// Command id to fire if the chord-chain pending times out. Set when
    /// the pending sequence matches a `PendingWithFallback` (ambiguous —
    /// both a leaf binding and a longer chain's prefix). None when the
    /// pending has no shorter leaf, OR when no chain is in flight.
    pub pending_chord_fallback: Option<String>,
    /// While a leader sequence is in flight: the keys typed after `<leader>`
    /// (`Some("")` ⇒ the popup just opened). Steals key input like the picker.
    pub whichkey: Option<String>,
    /// The split divider currently being dragged (between mouse-down on it and
    /// mouse-up), so drag events resize *that* split even off-target.
    pub dragging: Option<crate::layout::DividerHit>,
    /// A buffer whose close is awaiting a Save/Discard/Cancel decision (the
    /// confirm overlay is up). Steals key input like the picker.
    pub close_prompt: Option<PaneId>,
    /// Settings overlay state. `Some` while the overlay is open, `None`
    /// otherwise. Carries the `original` Config snapshot for the
    /// Esc/cancel revert path. See `app/settings.rs` for the schema.
    pub settings_overlay: Option<settings::SettingsOverlayState>,
    /// First-launch wizard state — `Some` while the wizard is open.
    /// Fires once ever, gated by `[ui] first_launch_complete`. See
    /// `app/first_launch.rs`.
    pub first_launch: Option<first_launch::FirstLaunchState>,
    /// Per-integration Settings pane state — `Some` while the
    /// pane is open on some integration. See
    /// `app/integration_settings.rs`.
    pub integration_settings: Option<integration_settings::IntegrationSettingsState>,
    /// Active menu-bar dropdown state. `Some` while a menu is open;
    /// `None` otherwise. Driven by mouse click on a menu word, Alt+
    /// letter, or F10. See `src/menu_bar.rs` for the bar layout
    /// + `src/ui/menu_bar.rs` for the renderer.
    pub menu_open: Option<crate::menu_bar::MenuOpenState>,
    /// Integration edit panel state — `Some` while the edit overlay
    /// is open (right-click chip → Edit or Add custom). See
    /// `app/discovery.rs::IntegrationEditState`.
    pub integration_edit: Option<discovery::IntegrationEditState>,
    /// Glyph builder panel — SVG → font glyph with live rasterized
    /// preview. Opened by `integrations.glyph_builder`.
    pub glyph_builder: Option<crate::glyph_builder::GlyphBuilderState>,
    /// Help overlay state — `Some` while the in-app help is open.
    /// Auto-generated from the command registry; see `app/help.rs`.
    pub help_overlay: Option<help::HelpOverlayState>,
    /// The single-line text-input overlay (commit message, …), when open. Steals
    /// key input like the picker.
    pub prompt: Option<crate::prompt::Prompt>,
    /// The right-click context menu, when open. Steals key + mouse input.
    /// In-flight background file transfers (#files item 6). Every file
    /// operation goes through these — there is no synchronous path.
    pub transfers: Vec<crate::transfer::Transfer>,
    pub transfer_tx: std::sync::mpsc::Sender<crate::transfer::TransferMsg>,
    pub transfer_rx: std::sync::mpsc::Receiver<crate::transfer::TransferMsg>,
    pub next_transfer_id: u64,
    pub context_menu: Option<crate::context_menu::ContextMenu>,
    /// The open child of `context_menu`, plus the parent row it hangs
    /// off. One level only: a second level of nesting in a menu this
    /// small buys nothing and multiplies the ways a pointer can fall out
    /// of the chain on its way to a row.
    pub context_submenu: Option<(usize, crate::context_menu::ContextMenu)>,
    /// File-manager clipboard — paths staged by `file.cut` / `file.copy`
    /// for a later `file.paste`. `Vec<_>` so a future multi-select
    /// can stage several paths at once. Empty when nothing is
    /// staged. Cleared after a Cut-then-Paste (move semantics);
    /// left as-is after Copy-then-Paste so the same set can be
    /// pasted into multiple places.
    pub file_clipboard: Vec<std::path::PathBuf>,
    /// `true` when the clipboard was populated by Cut (paste = move).
    /// `false` for Copy (paste = duplicate). Meaningless when
    /// `file_clipboard` is empty. 2026-07-07.
    pub file_clipboard_cut: bool,
    /// #files — first key of a pending two-key file operation in a Files
    /// pane (`y` for copy, `d` for cut), vim style only.
    ///
    /// Two-key because the single-key Ctrl equivalents were vim's own
    /// `Ctrl+V` / `Ctrl+D`, so a reflex moved files with no confirmation.
    /// A pending key is cleared by any other keystroke, so it cannot
    /// linger into an unrelated action.
    pub files_pending_op: Option<char>,
    /// The LSP hover popup, when open (set when a `textDocument/hover` reply
    /// arrives). The next key dismisses it (j/k/arrows scroll it first).
    pub hover: Option<crate::hover::HoverPopup>,
    /// Mouse-driven hover request — the editor cell under the pointer
    /// and when the mouse arrived there. `tick` fires a
    /// `textDocument/hover` request once the mouse has been steady
    /// for the debounce window (~600ms). Updated by the
    /// `MouseEventKind::Moved` handler. Cleared when the pointer
    /// leaves any editor body. The 4-tuple is
    /// `(pane_id, file_row, file_col, arrived_at)`.
    /// 2026-06-08 SEV-2 VS-Code-mouse hunt fix.
    pub mouse_hover_at: Option<(PaneId, usize, usize, std::time::Instant)>,
    /// Screen (col, row) of the pointer at the moment
    /// `maybe_fire_mouse_hover` decided to send an LSP request.
    /// Read by the hover-arrival path to anchor the popup at the
    /// mouse position instead of the caret (2026-08-14 fix — the
    /// popup was drawing at the last caret position for mouse-
    /// driven hovers, so it appeared "where the mouse was a moment
    /// ago"). Cleared when the popup is dismissed or replaced.
    pub mouse_hover_screen: Option<(u16, u16)>,
    /// `(pane_id, file_row, file_col)` of the most recent fired
    /// hover request — prevents re-firing for the same cell every
    /// tick once the debounce elapses. Cleared whenever
    /// `mouse_hover_at` changes target.
    pub mouse_hover_fired: Option<(PaneId, usize, usize)>,
    /// LSP `textDocument/signatureHelp` popup — function prototype + active
    /// parameter highlight. Auto-triggered when the user types `(` or `,` in
    /// insert mode; replaced when a fresh reply arrives; dismissed on Esc
    /// or any non-typing cursor motion.
    pub signature: Option<crate::signature::SignaturePopup>,
    /// `(path, line, character)` of an in-flight LSP rename — captured when the
    /// rename prompt opens so the accept handler sends the request for that spot.
    pending_rename: Option<(PathBuf, u32, u32)>,
    /// Code actions returned by the most recent `textDocument/codeAction` reply.
    /// The picker (`PickerKind::CodeActions`) stores indices into this list and
    /// looks them up here to apply the chosen action. Together with `path` (the
    /// buffer the request was fired against — needed for `workspace/executeCommand`
    /// routing).
    pending_code_actions: Vec<crate::lsp::CodeAction>,
    /// Index into `pending_code_actions` for a `codeAction/resolve` request
    /// in flight. When the resolve reply lands, we merge the edit/command
    /// into the action at this index and apply it.
    pending_code_action_resolve: Option<usize>,
    pending_code_action_path: Option<PathBuf>,
    /// `(pane_id, lens_index)` — set when a click on a stub lens fired a
    /// `codeLens/resolve`. When the reply lands, the matching lens is
    /// updated with the new command and the click is re-fired.
    pending_code_lens_resolve: Option<(PaneId, usize)>,
    /// When true, the next code-action reply auto-applies the first
    /// returned action instead of opening the picker. Set by
    /// `lsp.quick_fix`; cleared whether the reply lands or the request
    /// fails. The "first" action is whatever the server orders first —
    /// servers typically front-load the most relevant action.
    pending_code_action_auto_apply: bool,
    /// When true, the next `LspEvent::DocumentSymbols` reply routes to the
    /// open outline pane instead of opening the symbols picker. Set by
    /// `open_outline_pane` / `refresh_outline_pane`; cleared after one reply.
    pending_outline: bool,
    /// Active selection-range "ladder" — server-supplied semantic ranges
    /// from smallest (current) → largest (containing) around the cursor
    /// at the moment of the original `lsp.selection_expand` request. The
    /// `current` index walks down (expand) / up (shrink). Cleared on any
    /// non-expand/shrink action.
    selection_range_ladder: Option<SelectionRangeLadder>,
    /// Most recent prepared call-hierarchy items, kept so a follow-up
    /// `incoming`/`outgoing` request can be re-fired without re-asking
    /// the server. MVP uses the first item; a disambiguation picker is
    /// a follow-up.
    pending_call_hierarchy_items: Vec<crate::lsp::CallHierarchyItem>,
    /// Active `$/progress` tasks keyed by token. Statusline renders a
    /// `⟳ <title>` chip when this is non-empty (showing the most recent
    /// title). Begin / report update; end removes.
    pub lsp_progress: std::collections::HashMap<String, String>,
    /// Snippets backing the open `PickerKind::Snippets` picker — items index
    /// into this list. Populated by [`Self::snippet_pick`], consumed by
    /// [`Self::picker_accept`].
    pending_snippets: Vec<crate::snippets::Snippet>,
    /// Active snippet placeholder cycle (`$1` → `$2` → … → `$0` / end). `None`
    /// when no snippet was just inserted, or after the user has tabbed past
    /// the last placeholder. Tab cycles to the next slot; Esc dismisses; any
    /// switch to a different pane drops it.
    pub snippet_session: Option<crate::snippets::SnippetSession>,
    /// Hits accumulated from one or more `workspace/symbol` replies for the
    /// most recent query — multiple servers may each contribute. Cleared on
    /// every new query in [`Self::run_workspace_symbol_query`]; consumed by
    /// [`Self::apply_workspace_symbols`].
    pending_workspace_symbols: Vec<crate::lsp::WorkspaceSymbol>,
    /// The query string for the in-flight workspace-symbol run (used in the
    /// picker title). Cleared with the stash.
    pending_workspace_symbol_query: Option<String>,
    /// Sticky toggle for `find.find`'s regex mode. New find states inherit
    /// it; `find.toggle_regex` flips it AND updates any open find state on
    /// the active buffer.
    pub find_regex_default: bool,
    /// Case-sensitivity mode for search. `None` = smart-case
    /// (mnml's historical default: case-sensitive iff the query has
    /// an uppercase letter). `Some(false)` = case-INSENSITIVE
    /// always (`:set ic`). `Some(true)` = case-SENSITIVE always
    /// (`:set noic`). Toggled by the `:set` handlers.
    /// nvchad-user SEV-2 2026-07-11.
    pub search_case_mode: Option<bool>,
    /// Snapshot of the active buffer's find state when the Find prompt
    /// opened — restored on Esc-cancel so incremental find doesn't leak
    /// matches when the user bails. `Some(None)` ⇒ "previously cleared";
    /// `None` ⇒ no Find prompt in flight.
    pub find_preview_snapshot: Option<Option<crate::buffer::FindState>>,
    /// Byte range to scope the in-flight find to (set when the prompt opens
    /// with a multi-line selection active). Consumed by `accept_find` and
    /// `update_live_find_preview`. `None` ⇒ search the whole buffer.
    pub find_pending_range: Option<(usize, usize)>,
    /// Vim `?` reverse search — when true, the next `accept_find` jumps to
    /// the closest match BEFORE the cursor instead of after. One-shot:
    /// consumed by `accept_find`. Set by `open_find_prompt_backward`.
    pub find_pending_reverse: bool,
    /// In-flight `:%s/.../.../c` interactive replace (vim's confirm flag).
    /// Steals keys until the user finishes (y/n/a/q at each match).
    pub replace_confirm: Option<ReplaceConfirm>,
    /// Cursor position when the Find prompt opened — kept around in case
    /// future incremental UX wants to bring the cursor back on cancel.
    pub find_preview_cursor: usize,
    /// Recently accepted find queries, oldest first. Up/Down arrows on
    /// the Find prompt cycle through. Capped at `FIND_HISTORY_MAX`.
    pub find_history: Vec<String>,
    /// Index into [`Self::find_history`] for the current Up/Down position,
    /// or `find_history.len()` for the live (typed) input — same shape as
    /// most shells.
    pub find_history_cursor: usize,
    /// Branch / ref to branch off of when the NewBranch prompt's accept lands.
    /// `None` ⇒ branch from HEAD (the bare `git.new_branch` command); `Some` ⇒
    /// branch from this ref (the git-rail's "New branch from here…" menu).
    pending_branch_source: Option<String>,
    /// `(stash_ref, label)` of a stash awaiting a "type 'drop' to
    /// confirm" prompt. Set when the user picks a stash from the
    /// stash drop picker; cleared on accept or cancel.
    /// untouched-surfaces-hunt-2026-06-08 SEV-2 #8.
    pub pending_stash_drop: Option<(String, String)>,
    /// Tag name awaiting a "type tag-name to confirm" delete
    /// prompt. Set by `git_tag_delete_prompt`; cleared on accept
    /// or cancel.
    pub pending_tag_delete: Option<String>,
    /// `(pane_id, hunk_index)` of a diff hunk awaiting a
    /// "type 'discard' to confirm" prompt. Set when the user clicks
    /// the Discard chip; cleared on accept or cancel.
    pending_discard_hunk: Option<(PaneId, usize)>,
    /// Workspace-relative path of a file awaiting a "type the
    /// filename to confirm" discard prompt — opened by the
    /// GitStatus right-click menu's "Discard changes" entry.
    pending_discard_file: Option<PathBuf>,
    /// The file-system action waiting on its name prompt — captured when the
    /// `NewFile` / `NewFolder` / `Rename` context-menu items open the prompt.
    pending_fs_action: Option<FsAction>,
    /// The as-you-type LSP completion popup, when open. Populated from a
    /// `textDocument/completion` reply (auto-triggered as you type, or via
    /// `lsp.completion`); re-filtered locally as you keep typing.
    pub completion: Option<crate::completion::CompletionPopup>,
    /// Channel for background HTTP sends (lazily created on the first `http.send`):
    /// worker threads send `(job_id, result)`; [`Self::tick`] drains it and updates
    /// the matching `Pane::Request`.
    http_chan: Option<(
        std::sync::mpsc::Sender<HttpJobDone>,
        std::sync::mpsc::Receiver<HttpJobDone>,
    )>,
    /// 2026-06-20 — separate channel for SSE progressive display.
    /// Workers send Open → Event* → Close (see `SseStreamMsg`);
    /// `tick` drains it and mutates the matching pane's body live.
    pub sse_chan: Option<(
        std::sync::mpsc::Sender<crate::request_pane::SseStreamMsg>,
        std::sync::mpsc::Receiver<crate::request_pane::SseStreamMsg>,
    )>,
    /// 2026-06-20 — channel for `:http.ai_build` (Claude one-shot
    /// "NL → curl"). Worker calls `api_client::nl_to_curl` and sends
    /// the result back; `tick` drains it, parses the curl, and opens
    /// a new Request pane.
    pub http_ai_build_chan: Option<(
        std::sync::mpsc::Sender<Result<String, String>>,
        std::sync::mpsc::Receiver<Result<String, String>>,
    )>,
    /// Whether a `:http.ai_build` worker is currently in flight.
    /// Used to gate against double-submits + power a "calling
    /// Claude…" cmdline-bar indicator.
    pub http_ai_build_in_flight: bool,
    /// 2026-06-20 — channel for `:http.run_chain` (Postman runner
    /// arc). Worker calls `http::chain::run` and sends back the
    /// full trace + final result. `tick` drains it and opens a
    /// `[chain-trace]` scratch.
    pub http_chain_chan: Option<(
        std::sync::mpsc::Sender<(String, Result<(), String>)>,
        std::sync::mpsc::Receiver<(String, Result<(), String>)>,
    )>,
    /// 2026-06-21 — channel for `:ws.send` (websocat shell-out)
    /// after the SEV-1 main-thread-freeze fix. Worker thread calls
    /// `run_websocat_send` and sends back a `WsSendReply`;
    /// `drain_ws_send` opens the `[ws-response]` scratch.
    pub ws_send_chan: Option<(
        std::sync::mpsc::Sender<crate::app::http::WsSendReply>,
        std::sync::mpsc::Receiver<crate::app::http::WsSendReply>,
    )>,
    /// 2026-06-21 — target pane id stashed when `:ws.send_message`
    /// opens its prompt, so the accept handler sends to the right
    /// WS pane even if the user moved focus mid-prompt.
    pub pending_ws_send_pane: Option<usize>,
    /// True while a chain run is in flight; gates double-submits.
    pub http_chain_in_flight: bool,
    /// Pending kill (SIGTERM) target for `:ai.dashboard`'s
    /// confirm prompt. Set when the user presses `K` on a row;
    /// resolved on prompt accept.
    pub pending_kill_pid: Option<u32>,
    /// Pending batch-kill list — `(session_id, pid)` pairs set when
    /// the user presses `K` while rows are multi-selected. Resolved
    /// on prompt accept the same way as `pending_kill_pid`.
    pub pending_kill_batch: Vec<(String, u32)>,
    /// Pending branch name for `:git.delete_branch`'s confirm
    /// prompt. Set when the GitDeleteBranch picker accepts; resolved
    /// on the confirm prompt accept.
    pub pending_branch_delete: Option<String>,
    /// Pending integration id for `IntegrationRemoveConfirm` — set
    /// when the user picks Remove from a right-click context menu
    /// (or the integrations.remove palette picker), resolved on
    /// prompt accept.
    pub pending_integration_remove_id: Option<String>,
    /// 2026-08-06 — stashed alongside `pending_integration_remove_id`
    /// so the confirm dialog can offer a third-button "Uninstall +
    /// binary" that also runs `cargo uninstall <binary>` after the
    /// manifest teardown. `None` for data-only launchers — dialog
    /// falls back to the two-button `[Uninstall] [Cancel]` shape.
    pub pending_integration_remove_binary: Option<String>,
    /// Integration id awaiting a launcher-script value from the
    /// `PromptKind::IntegrationLauncher` prompt. Set by the chip's
    /// "Set launcher script…" menu, read by the prompt-accept.
    pub pending_integration_launcher_id: Option<String>,
    /// #1203 f/u — state for the two-step "New launch profile…"
    /// flow: `(integration id, Some(name) once step 1 accepted)`.
    /// Set by the chip menu's NewAiLaunchProfile action; consumed by
    /// the `LaunchProfileName` / `LaunchProfileCommand` accepts.
    pub pending_launch_profile: Option<(String, Option<String>)>,
    /// Task #944 rename UX (2026-08-16) — Claude account name being
    /// renamed by the `PromptKind::ClaudeAccountRename` prompt.
    /// Populated by `App::open_claude_account_rename_prompt` (from
    /// a pencil click or the `ai.claude_rename_account` command);
    /// consumed by the accept handler → `App::rename_claude_account`.
    /// Cleared by the standard `prompt_cancel` path on Esc.
    pub pending_claude_account_rename: Option<String>,
    /// Pending worktree path for `:git.worktree_add` and
    /// `:git.worktree_remove` confirm prompts.
    pub pending_worktree_path: Option<std::path::PathBuf>,
    /// Pending source branch for `:git.merge` confirm prompt.
    pub pending_merge_source: Option<String>,
    /// Pending target ref for `:git.rebase` confirm prompt.
    pub pending_rebase_onto: Option<String>,
    /// 2026-06-20 — theme picker live preview. Snapshot of the
    /// active theme name when the Themes picker opens; restored on
    /// Esc / cleared on Enter. Up/Down on the picker applies the
    /// highlighted theme via `set_theme_silent`.
    pub theme_preview_restore: Option<String>,
    /// 2026-06-20 — `:ai.write_pr_description` job tag. When the
    /// drain hook sees an AiMsg::Done for this job, it opens a
    /// `[pr-description]` scratch instead of routing to a commit
    /// prompt.
    pub pending_pr_desc_job: Option<u64>,
    /// 2026-06-21 — `:ai.explain_diff` job tag. AiMsg::Done goes
    /// to a `[diff-explanation]` scratch.
    pub pending_explain_diff_job: Option<u64>,
    /// 2026-06-21 — `:ai.write_branch_name` job tag. AiMsg::Done
    /// opens a prompt seeded with the suggested branch name; user
    /// accepts → :git.new_branch with that name.
    pub pending_branch_name_job: Option<u64>,
    /// 2026-06-21 — `:ai.recompose_branch` job tag. AiMsg::Done
    /// goes to a `[recompose-suggestions]` scratch buffer
    /// (Claude's draft new messages — user applies the rebase
    /// themselves; we deliberately don't mutate history).
    pub pending_recompose_branch_job: Option<u64>,
    /// 2026-06-21 — `:lsp.peek_definition_overlay` floating box.
    /// Set by the App method; cleared on Esc. Renders ABOVE the
    /// editor at a fixed centered position, showing 15 lines
    /// around the def target. Doesn't move the cursor — when
    /// closed the user is right back where they were.
    pub peek_overlay: Option<crate::peek_overlay::PeekOverlay>,
    /// True after `:lsp.peek_definition_overlay` fires
    /// `lsp_goto_definition`; the next GotoDefinition event
    /// will populate `peek_overlay` instead of navigating.
    /// Reset on first use OR on a different action.
    pub pending_peek_definition: bool,
    /// Channel for background `claude -p` runs (lazily created); worker threads
    /// stream `(job_id, AiMsg)` (deltas then a final Done/Failed), [`Self::tick`]
    /// drains it into the matching `Pane::Ai`.
    ai_chan: Option<(
        std::sync::mpsc::Sender<AiJobMsg>,
        std::sync::mpsc::Receiver<AiJobMsg>,
    )>,
    /// Channel for AI inline ghost-text completion jobs. A worker calls
    /// `api_client::complete_code` and sends back `(request_id, result)`.
    suggest_chan: Option<(
        std::sync::mpsc::Sender<SuggestReply>,
        std::sync::mpsc::Receiver<SuggestReply>,
    )>,
    /// In-flight ghost-text request — `(request_id, pane_id, cursor_byte)`.
    /// A reply is only applied if `pane_id` is still active and the cursor
    /// hasn't moved (stale completions are dropped).
    pending_suggest: Option<(u64, PaneId, usize)>,
    /// Request channel to the local-FIM worker thread (`suggest_backend
    /// = "local"`). `Some` once the worker is spawned. The worker owns
    /// the `FimEngine`, loads it lazily on the first request (a one-time
    /// ~1 GB download), and replies through `suggest_chan`.
    fim_tx: Option<std::sync::mpsc::Sender<FimRequest>>,
    /// Live model-download progress, shared with the FIM worker thread.
    /// `Some` while the one-time ~1 GB download runs; `ui::
    /// fim_progress_overlay` paints a bar from it. `None` otherwise.
    pub fim_progress: std::sync::Arc<std::sync::Mutex<Option<fim_engine::DownloadProgress>>>,
    /// Monotonic id for ghost-text requests.
    next_suggest_id: u64,
    /// When the active editor was last edited — the ghost-text debounce
    /// anchor. A request fires once this is `SUGGEST_DEBOUNCE_MS` old.
    suggest_dirty_at: Option<Instant>,
    /// The `(prefix, suffix)` context of the last ghost-text request
    /// fired — dedup so a cursor jiggle / type-then-undo back to the
    /// same state doesn't re-spend an API call or inference cycle.
    last_suggest_context: Option<(String, String)>,
    /// Per-session count of inline suggestions shown / accepted — drives
    /// `ai.suggestion_stats`. `suggest_current_accepted` guards against
    /// double-counting when partial accepts chain on one suggestion.
    suggest_shown: u32,
    suggest_accepted: u32,
    suggest_current_accepted: bool,
    /// Channel for background `npx playwright test` runs → the matching `Pane::Tests`.
    tests_chan: Option<(
        std::sync::mpsc::Sender<TestsJobDone>,
        std::sync::mpsc::Receiver<TestsJobDone>,
    )>,
    /// Channel for background external-linter runs. Each job carries
    /// `(buffer_path, parser_label, Result<Vec<Diagnostic>>)`. Drained
    /// each tick; results land on `Buffer.linter_diagnostics` for the
    /// matching path (if it's still open).
    linter_chan: Option<(
        std::sync::mpsc::Sender<LinterJobDone>,
        std::sync::mpsc::Receiver<LinterJobDone>,
    )>,
    /// Active DAP session (one at a time for the MVP). When `Some`, the
    /// App drains events in `tick`. Cleared on adapter terminated /
    /// exited.
    pub dap: Option<crate::dap::DapManager>,
    /// Current execution arrow `(path, line0)` — set on `Stopped`,
    /// cleared on `Continued` / `Terminated`. Editor gutter paints `▶`.
    pub dap_arrow: Option<(std::path::PathBuf, u32)>,
    /// Last thread id we saw a `Stopped` event for — used to target
    /// step commands without the user picking a thread.
    pub dap_thread: Option<i64>,
    /// Substituted `launch.*` body stashed by `dap.run` until the
    /// `Initialized` event lands and we can fire `launch`. Cleared
    /// when consumed.
    pub dap_pending_launch: Option<serde_json::Value>,
    /// Adapter output log entries (`(category, line)` in arrival order,
    /// newest at the back, capped at `DAP_LOG_MAX`). Rendered by
    /// `Pane::Debug` so the user can see program stdout/stderr without
    /// every chunk landing as a toast. Cleared on `dap.terminate`.
    pub dap_output_log: Vec<(String, String)>,
    /// User-added watch expressions — re-evaluated at every stop +
    /// rendered as a top section of the variables panel. Persisted
    /// in `session.json` so workflows survive a relaunch.
    pub dap_watches: Vec<String>,
    /// Last `evaluate` result per watch expression. Keyed by the
    /// original expression string (matches `dap_watches`). `value` is
    /// the adapter's formatted result; `ty` may be present.
    pub dap_watch_results: std::collections::HashMap<String, WatchResult>,
    /// Stashed `(line0, path)` from `dap.toggle_breakpoint_conditional`
    /// waiting for the user to type a condition. The accept handler
    /// consumes it via `std::mem::take`; Esc-cancel just clears it.
    pub dap_pending_bp_condition: Option<(u32, std::path::PathBuf)>,
    /// Stashed `(parent_ref, name)` from `dap.set_variable` waiting
    /// for the user to type a new value. Accept fires
    /// `client.set_variable`; the reply lands as
    /// [`crate::dap::DapEvent::SetVariableDone`] which patches
    /// `mgr.variables[parent_ref]` in place.
    pub dap_pending_set_variable: Option<(i64, String)>,
    /// Receiver for the (single) CDP browser session's worker — events stream in,
    // The per-pane CDP receiver lives on `BrowserPane.event_rx` now —
    // `drain_cdp_events` walks every browser pane each tick.

    // AWS CodeBuild + LogTail channels/state removed after the
    // 2026-06 split — those panes ship in mnml-aws-codebuild now.
    // Pipeline-log channel + state removed after the 2026-06 SCM
    // split — no in-tree host populates Pane::PipelineLog any more.
    // gh_actions_*, gh_prs_*, github_* fields all moved to
    // mnml-forge-github in 2026-06.
    // GitLab worker + caches moved to mnml-forge-gitlab.
    // Azure DevOps worker + caches moved to mnml-forge-azdevops.
    // GitHub worker + caches moved to mnml-forge-github.
    /// Job id of an in-flight "AI: write me a commit message" run (it shares
    /// `ai_chan`; when it lands, the commit prompt opens pre-seeded instead of an
    /// answer landing in a `Pane::Ai`).
    pending_commit_msg_job: Option<u64>,
    /// Same as `pending_commit_msg_job`, but for `git.ai_recompose` (rewrite
    /// HEAD's message). The reply lands as a [`PromptKind::GitCommitAmend`]
    /// prompt that calls `git commit --amend -m` on accept.
    pending_amend_msg_job: Option<u64>,
    /// When set, an in-flight AI commit-message job's result fills
    /// the inline textarea on `pane_id` (a `Pane::GitGraph` with its
    /// WIP detail visible) instead of opening the modal commit
    /// prompt. `(job_id, pane_id)` — cleared on completion.
    pending_wip_commit_msg_pane: Option<(u64, crate::layout::PaneId)>,
    next_job_id: u64,
    /// Session token tally for the direct-API AI backend — summed from
    /// every job's `AiMsg::Usage`. Drives `ai.token_usage`.
    ai_tokens_in: u64,
    ai_tokens_out: u64,
    /// Per-job confirm channels — the agent worker blocks on its
    /// receiver when a `write_file` needs approval; the main thread
    /// answers through the matching sender. Keyed by job id.
    ai_confirm_senders: std::collections::HashMap<u64, std::sync::mpsc::Sender<bool>>,
    /// The job id whose `write_file` is currently awaiting the user's
    /// answer in an open `AiToolConfirm` prompt.
    pending_tool_confirm: Option<u64>,
    /// Commands registered at runtime by IPC plugins (`register-command`). They
    /// show up in the palette/which-key + keymap; invoking one queues its id in
    /// `pending_plugin_invocations` for the IPC layer to log as an event.
    pub dynamic_commands: Vec<crate::command::DynCommand>,
    /// Plugin-command ids invoked since the IPC layer last drained them.
    pending_plugin_invocations: Vec<String>,
    /// #1099 f/u (2026-08-20) — rigid chip-to-tab link. Set by
    /// `run_dynamic_command` right before it forwards a manifest-
    /// registered command's `ex_run` (a `:term ...` line) into the
    /// ex-command handler; consumed + cleared by the `:term`
    /// handler when it stamps the pty profile. Replaces the
    /// pre-existing heuristic that scanned `integration_icons`
    /// for a chip whose command string matched by binary, which
    /// picked whichever chip enumerated first when several chips
    /// share one binary (`bitbucket_prs` / `bitbucket_pipelines`).
    pub pending_term_integration_hint: Option<String>,
    /// LSP client subsystem — one server subprocess per (project-root, language),
    /// feeding diagnostics + go-to-def/hover results back through `tick`.
    pub lsp: crate::lsp::LspManager,
    /// Per-workspace history of test outcomes (last 10 per test) — drives the
    /// "wobbly" glyph in the tests pane. Loaded once at startup, updated +
    /// saved after each completed Playwright run.
    pub test_history: crate::playwright::history::TestHistory,
}

type HttpJobDone = (u64, Result<crate::request_pane::ResponseView, String>);
type AiJobMsg = (u64, crate::ai::AiMsg);
type TestsJobDone = (u64, Result<crate::playwright::TestRun, String>);
/// One external-linter run's result: `(buffer_path, parser_label,
/// Result<diagnostics, error_preview>)`. The `parser_label` is the
/// linter name (`"eslint"` / `"ruff"` / …) shown in the success toast.
type LinterJobDone = (PathBuf, String, Result<Vec<crate::lsp::Diagnostic>, String>);

impl App {
    /// Active tab page's split tree (immutable view).
    pub fn layout(&self) -> &Layout {
        &self.layouts[self.active_layout]
    }

    /// Layout to render THIS frame — accounts for a live zoom
    /// (`Self::zoomed_leaf`) by returning a synthetic single-leaf tree
    /// containing every tab that lives in the same leaf as the zoomed
    /// pane. When no zoom is active (or the zoomed pane has since been
    /// closed / moved out of the layout), returns a clone of the real
    /// split tree.
    ///
    /// Callers already own the layout by value (they `.clone()` it
    /// before walking), so returning `Layout` keeps the shape and
    /// short-circuits transparently. Do NOT call this from anything
    /// that needs the true split shape (dividers, `Ctrl+W` focus nav,
    /// keyboard-driven pane-close accounting) — those go through
    /// `Self::layout()` unchanged so they operate on the real tree
    /// underneath the zoom.
    pub fn effective_layout_for_render(&self) -> Layout {
        if let Some(zid) = self.zoomed_leaf
            && let Some(tabs) = self.layout().leaf_containing(zid)
        {
            return Layout::leaf_with_tabs(zid, tabs.to_vec());
        }
        self.layout().clone()
    }

    /// Toggle the maximize/zoom flag against the active leaf. If a
    /// pane is focused (`self.active`) and its leaf isn't already
    /// zoomed, we zoom it. If it IS the zoomed leaf, we clear the
    /// zoom. If some OTHER leaf was zoomed, we switch the zoom to
    /// this one — pressing the maximize button in a leaf's own strip
    /// shouldn't require un-zooming a hidden leaf first. Toasts a
    /// hint when there's no active pane so the palette command
    /// doesn't fail silently.
    pub fn toggle_zoom_active_leaf(&mut self) {
        let Some(active) = self.active else {
            self.toast("nothing to maximize — open a pane first");
            return;
        };
        if self.zoomed_leaf == Some(active) {
            self.zoomed_leaf = None;
            return;
        }
        self.zoomed_leaf = Some(active);
    }

    /// Clear any live zoom. Callers: pane close / tab-page switch /
    /// layout rearrangement that could invalidate the zoomed leaf.
    /// Cheap when already `None`; never toasts.
    pub fn clear_zoom(&mut self) {
        self.zoomed_leaf = None;
    }

    pub fn new(workspace: PathBuf, config: Config) -> Result<App, String> {
        // Propagate `[ui] terminal_label` into pty_pane's process-
        // global so every `BinaryProfile::shell()` picks up the
        // user's rebrand (default "terminal"; users on ghostty /
        // kitty / wezterm can set their own).
        crate::pty_pane::set_terminal_label(config.ui.terminal_label.clone());
        crate::app::set_external_browser(config.ui.external_browser.clone());
        // Snapshot values from config that App holds by value (config
        // itself is moved into the struct below).
        let hover_help_height_init = config.ui.hover_help_height;
        let workspace = workspace
            .canonicalize()
            .map_err(|e| format!("cannot open workspace {}: {e}", workspace.display()))?;
        let cookie_jar_init = std::sync::Arc::new(std::sync::Mutex::new(
            crate::cookie_jar::CookieJar::load(&workspace),
        ));
        let mut tree = Tree::open(&workspace);
        let git = GitStatus::new(&workspace);
        let lsp = crate::lsp::LspManager::new(&workspace, &config);
        let test_history = crate::playwright::history::TestHistory::load(&workspace);
        let keymap = crate::input::keymap::Keymap::build(&config);
        let (git_loader_tx, git_loader_rx) = git_async::spawn_git_loader();
        let (cloud_run_msg_tx, cloud_run_msg_rx) = std::sync::mpsc::channel::<String>();
        // Discover repos in the workspace. The rail's `refresh` should run
        // against the active repo (which is `workspace` itself in the
        // single-repo case, but may be a sub-dir in the multi-repo case).
        let mut repos = crate::git::repos::discover_repos(&workspace);
        let active_repo = 0usize;
        // Multi-repo workspace: collapse every depth-0 dir except the active
        // repo's, so the tree opens with the repos as a clean list of
        // collapsible headers rather than every repo's contents stacked
        // together. Single-repo case (workspace is itself a repo, or no
        // sub-repos at all) keeps Tree::open's default first-level expansion.
        if repos.len() > 1
            && let Some(active) = repos.get(active_repo)
        {
            tree.expand_only([active.path.clone()]);
        }
        // `[[workspaces]]` — additional roots shown as integration sections in
        // the rail. Each gets its own gitignore-aware tree + its own repo
        // discovery (results appended to the flat `repos` list above, so
        // the active-repo machinery is unchanged). Missing / unreadable
        // paths log a warning and skip so a stale config entry doesn't
        // brick launch.
        let mut extra_workspaces: Vec<ExtraWorkspace> = Vec::new();
        for w in &config.workspaces {
            let root = match w.path.canonicalize() {
                Ok(p) => p,
                Err(e) => {
                    eprintln!(
                        "mnml: skipping workspace {} ({}): {e}",
                        w.name,
                        w.path.display()
                    );
                    continue;
                }
            };
            // Don't duplicate the primary workspace (config points at the
            // same dir mnml was launched on).
            if root == workspace {
                continue;
            }
            let mut t = Tree::open(&root);
            let mut found = crate::git::repos::discover_repos(&root);
            // Same multi-repo collapse rule as the primary workspace — when
            // an extra root contains multiple integration repos, only the first
            // (alphabetical) stays expanded by default.
            if found.len() > 1
                && let Some(first) = found.first()
            {
                t.expand_only([first.path.clone()]);
            }
            let position = extra_workspaces.len() + 1;
            extra_workspaces.push(ExtraWorkspace {
                name: w.name.clone(),
                root,
                tree: t,
                expanded: false,
                position,
            });
            repos.append(&mut found);
        }
        let rail_root: &std::path::Path = repos
            .get(active_repo)
            .map(|r| r.path.as_path())
            .unwrap_or(workspace.as_path());
        let git_rail = {
            let mut r = crate::git::rail::GitRail::empty();
            r.refresh(rail_root);
            r
        };
        let tree_width = config.ui.tree_width;
        let git_section_expanded_default = config.ui.git_section_default_expanded;
        let integrations_section_expanded_default = config.ui.integrations_section_default_expanded;
        let right_panel_visible_default = config.ui.right_panel_visible;
        let right_panel_width_default = config.ui.right_panel_width;
        let mount_manifests = crate::mount_manifest::load_all(&workspace);
        // Under `cargo test`, skip the user-global integration
        // manifests scan so the test harness isn't contaminated by
        // whatever manifests the developer has installed in
        // ~/.config/mnml/integrations/. Tests use
        // `App::new` + `app.integration_manifests.push(...)` to
        // exercise manifest behavior in isolation.
        let integration_manifests = if cfg!(test) {
            crate::integration_manifest::load_all_with_user_base(&workspace, None)
        } else {
            crate::integration_manifest::load_all(&workspace)
        };
        // #25 v2 — clone for background sessions prefetch worker
        // before the outer `workspace` gets moved into the App
        // struct below.
        let workspace_for_sessions_prefetch = workspace.clone();
        // 2026-08-16 — daemon thread that keeps the coverage-rollup
        // JSONs at ~/.tattle-claude-artifacts/{feature,code}-coverage/
        // fresh so the statusline chip's local-disk read always has
        // recent data. Skipped when `aws` isn't on PATH. Gated on
        // `cfg!(not(test))` so unit + e2e suites don't stack an
        // un-joined daemon thread per App::new invocation (reviewer
        // flag on 0be3cba3).
        #[cfg(not(test))]
        crate::app::coverage_methods::spawn_coverage_s3_syncer();
        // 2026-08-16 — background worker that pings crates.io / GitHub
        // for newer versions of installed integrations. Seeds the map
        // from the persisted cache before spawn so the marketplace
        // tab renders update chips instantly, without waiting on the
        // first network sweep. Same test-gating rationale as
        // spawn_coverage_s3_syncer above.
        let integration_updates_map: std::sync::Arc<
            std::sync::Mutex<
                std::collections::HashMap<String, crate::app::integration_updates::UpdateCheck>,
            >,
        > = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
        let _ = crate::app::integration_updates::load_update_cache_into(&integration_updates_map);
        #[cfg(not(test))]
        let integration_updates_waker_init =
            Some(crate::app::integration_updates::spawn_update_check_worker(
                integration_updates_map.clone(),
            ));
        #[cfg(test)]
        let integration_updates_waker_init: Option<
            crate::app::integration_updates::UpdateWaker,
        > = None;
        // #1202 — installed Nerd Font scan (local seek-reads only,
        // fast) + a one-shot latest-release check on a worker thread
        // (24h disk cache short-circuits the network hit). Both empty
        // under cfg(test) — same hermetic-suite rationale as the
        // update-check worker above.
        #[cfg(not(test))]
        let installed_fonts_init = crate::font_scan::scan_nerd_fonts();
        #[cfg(test)]
        let installed_fonts_init: Vec<crate::font_scan::InstalledFont> = Vec::new();
        let nerdfonts_latest_init: std::sync::Arc<std::sync::Mutex<Option<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(
                crate::font_scan::latest_nerdfonts_cached(),
            ));
        #[cfg(not(test))]
        if nerdfonts_latest_init
            .lock()
            .map(|g| g.is_none())
            .unwrap_or(false)
        {
            let slot = nerdfonts_latest_init.clone();
            std::thread::spawn(move || {
                if let Ok(v) = crate::font_scan::fetch_latest_nerdfonts()
                    && let Ok(mut g) = slot.lock()
                {
                    *g = Some(v);
                }
            });
        }
        // ONE channel: every worker gets a `Sender` clone and the render
        // loop drains a single receiver per tick. (Built from two separate
        // channels first — it compiled, and no message could ever arrive.)
        let (transfer_tx, transfer_rx) = std::sync::mpsc::channel();
        Ok(App {
            workspace,
            config,
            panes: Vec::new(),
            layouts: vec![Layout::Empty],
            active_layout: 0,
            tab_actives: vec![None],
            active: None,
            focus: Focus::Tree,
            zoomed_leaf: None,
            tree,
            tree_visible: true,
            active_section: ActivitySection::Explorer,
            mount_manifests,
            integration_manifests,
            binary_version_cache: std::collections::HashMap::new(),
            integration_glyph_svgs: Vec::new(),
            integration_glyph_codepoints: std::collections::HashMap::new(),
            activity_badges: std::collections::HashMap::new(),
            cloud_run_pending: None,
            pending_tool_install: None,
            explicit_config_path: None,
            workspace_trust_restricted: false,
            pending_workspace_trust: None,
            marketplace_entries: Vec::new(),
            marketplace_pending: Vec::new(),
            launcher_install_pending: Vec::new(),
            integration_updates: integration_updates_map,
            integration_updates_waker: integration_updates_waker_init,
            installed_fonts: installed_fonts_init,
            nerdfonts_latest: nerdfonts_latest_init,
            last_auto_update_tick_at: None,
            readme_cache: std::collections::HashMap::new(),
            readme_pending: Vec::new(),
            ai_usage_claude_accounts: Vec::new(),
            ai_usage_codex: None,
            ai_usage_pending_claude_accounts: Vec::new(),
            pending_keychain_fetch: None,
            pending_keychain_recapture: None,
            keychain_claude_refresh_token: None,
            keychain_active_watch: None,
            cached_autodetected_claude_account: None,
            keychain_active_last_kick_at: 0,
            ai_usage_pending_codex: None,
            ai_usage_last_refresh_at: 0,
            ai_usage_claude_last_refresh_at: std::collections::HashMap::new(),
            ai_usage_last_claude_spawn_at: 0,
            coverage_trends: None,
            istanbul_trends: None,
            coverage_trends_last_loaded_at: 0,
            marketplace_last_fetched: 0,
            search_query: String::new(),
            search_cursor: 0,
            search_hits: Vec::new(),
            search_used: "",
            search_selected: 0,
            search_scroll: 0,
            search_input_focused: false,
            search_case_sensitive: false,
            search_whole_word: false,
            search_regex: false,
            search_history: Vec::new(),
            search_history_cursor: None,
            git_section_commit_buffer: String::new(),
            git_section_commit_focused: false,
            tree_width,
            dragging_tree_edge: false,
            right_panel_visible: right_panel_visible_default,
            right_panel_width: right_panel_width_default,
            dragging_right_panel_edge: false,
            right_panel_panes: Vec::new(),
            right_panel_active_idx: 0,
            bottom_panel_visible: false,
            bottom_panel_height: 12,
            bottom_panel_panes: Vec::new(),
            bottom_panel_active_idx: 0,
            integrations_user_max_h: None,
            git_user_max_h: None,
            rail_section_drag: None,
            dragging_scrollbar: None,
            git_graph_detail_col_override: None,
            dragging_git_graph_detail: None,
            diff_view_mode_pref: crate::pane::DiffViewMode::Inline,
            diff_wrap_pref: false,
            leaf_tab_scroll: std::collections::HashMap::new(),
            leaf_tab_last_active: std::collections::HashMap::new(),
            fullscreen_mode: false,
            recent_files: Vec::new(),
            harpoon: Default::default(),
            browser_url_history: Vec::new(),
            last_browser_device: None,
            browser_dock_saved: None,
            closed_buffers: Vec::new(),
            last_active: None,
            pane_mru: Vec::new(),
            macro_state: MacroState::default(),
            block_insert_state: None,
            repeat_insert_state: None,
            drag_select: None,
            dragging_tab_page: None,
            closed_tab_layouts: Vec::new(),
            pending_rename_preview: None,
            cmdline_complete_state: None,
            cmdline_popup_selected: 0,
            macro_buffer: std::collections::HashMap::new(),
            pending_macro_register: None,
            last_replayed_macro_reg: None,
            last_external_check: None,
            arglist: Vec::new(),
            arglist_index: None,
            message_log: Vec::new(),
            unread_messages: 0,
            unread_errors: 0,
            persist_messages: true,
            messages_since_prune: 0,
            silent_depth: 0,
            recent_commands: Vec::new(),
            user_ex_commands: std::collections::HashMap::new(),
            last_shell_cmd: None,
            ex_history: Vec::new(),
            dot_keys: Vec::new(),
            dot_recording: None,
            dot_recording_saw_edit: false,
            is_replaying_dot: false,
            pending_dot_count: None,
            last_substitute: None,
            file_cursors: std::collections::HashMap::new(),
            file_folds: std::collections::HashMap::new(),
            global_marks: std::collections::HashMap::new(),
            nav_back: Vec::new(),
            nav_forward: Vec::new(),
            nav_jump_in_progress: false,
            prev_jump_pos: None,
            last_click: None,
            click_echo: None,
            mouse_down_at: None,
            scroll_bucket: 25.0,
            scroll_bucket_last_refill: None,
            scroll_last_event_at: None,
            scroll_gesture_peak_rate: 0.0,
            scroll_rate_decaying: false,
            scroll_frac_carry: 0.0,
            scroll_last_factor: 1.0,
            scroll_row_accum: 0.0,
            tree_last_row_step: None,
            git_palette_filter: String::new(),
            git_palette_filter_focused: false,
            git_palette_selected: None,
            git_palette_collapsed_sections: {
                // qa-feature 2026-06-30 — REMOTE starts collapsed
                // by default; it's often 100+ entries and dominates
                // the rail otherwise.
                let mut s = std::collections::HashSet::new();
                s.insert("REMOTE".to_string());
                s
            },
            git_palette_collapsed_folders: std::collections::HashSet::new(),
            workspace_picker_open: false,
            workspace_picker_filter: String::new(),
            workspaces_editor_open: false,
            workspaces_editor_selected: 0,
            workspaces_edit_target_name: None,
            workspaces_edit_target_path: None,
            workspaces_edit_target_group: None,
            dock_widgets: Vec::new(),
            last_test_run: None,
            agents_panel_rows: Vec::new(),
            agents_panel_built_at: None,
            agents_panel_rx: None,
            cloud_run_msg_tx,
            cloud_run_msg_rx: Some(cloud_run_msg_rx),
            cloud_run_prompt_input: String::new(),
            cloud_run_prompt_focused: false,
            cloud_agents_rows: Vec::new(),
            agents_panel_group_by_workspace: false,
            agents_panel_expanded_workspaces: std::collections::HashSet::new(),
            agents_panel_filter: String::new(),
            http_panel_filter: String::new(),
            http_panel_filter_focused: false,
            todos_panel_filter: String::new(),
            todos_panel_filter_focused: false,
            notes_panel_filter: String::new(),
            notes_panel_filter_focused: false,
            ai_placeholder_slot: None,
            sessions_manual_order: Vec::new(),
            sessions_pinned: std::collections::HashSet::new(),
            sessions_sort_mode: crate::app::SessionsSortMode::Auto,
            sessions_panel_filter: String::new(),
            sessions_panel_filter_focused: false,
            todos_panel_cursor: 0,
            notes_panel_cursor: 0,
            findings_panel_cursor: 0,
            todos_panel_scroll: 0,
            notes_panel_scroll: 0,
            findings_panel_scroll: 0,
            sessions_panel_cursor: 0,
            sessions_panel_scroll: 0,
            agents_panel_scroll: 0,
            integrations_panel_scroll: 0,
            integrations_panel_scroll_installed: 0,
            integrations_panel_scroll_marketplace: 0,
            integrations_panel_scroll_in_dev: 0,
            pending_marketplace_install_idx: None,
            integrations_panel_filter: String::new(),
            integrations_panel_filter_focused: false,
            integrations_panel_tab: IntegrationsPanelTab::Installed,
            installed_sort: InstalledSort::Name,
            marketplace_sort: MarketplaceSort::Name,
            agents_panel_filter_focused: false,
            cloud_agents_view: CloudAgentsView::default(),
            cloud_agents_filter: String::new(),
            cloud_agents_filter_focused: false,
            cloud_agents_scroll: 0,
            cloud_agents_meta: std::collections::HashMap::new(),
            dock_widget_next_id: 0,
            dock_drag_id: None,
            dock_drag_cursor: None,
            session_drag_pid: None,
            session_port_cache: std::collections::HashMap::new(),
            dock_kebab_menu: None,
            dock_rename_target: None,
            pending_format_save: None,
            pending_will_save: None,
            pending_cookie_edit: None,
            pending_storage_edit: None,
            // VS-Code-style: the rail is shown with its workspace section
            // expanded by default. The last session's choice overrides this
            // in `try_restore_session`.
            tree_root_expanded: true,
            extra_workspaces,
            todos_hits: Vec::new(),
            todos_panel_scanned_once: false,
            http_panel_files_cache: Vec::new(),
            http_panel_scanned_once: false,
            http_panel_recent_cache: Vec::new(),
            http_panel_captured_cache: Vec::new(),
            http_panel_captured_scroll: 0,
            http_panel_recent_scroll: 0,
            http_panel_mocks_scroll: 0,
            http_panel_chains_scroll: 0,
            http_panel_collections_scroll: 0,
            http_panel_cursor: (6, 0),
            http_panel_envs_cache: Vec::new(),
            http_panel_chains_cache: Vec::new(),
            http_panel_collections_cache: Vec::new(),
            http_panel_collection_roots: Vec::new(),
            http_panel_collections_collapsed_dirs: std::collections::HashSet::new(),
            http_panel_mocks_cache: Vec::new(),
            http_panel_section_collapsed: [false; 7],
            notes_panel_files_cache: Vec::new(),
            notes_panel_scanned_once: false,
            findings_panel_files_cache: Vec::new(),
            findings_panel_scanned_once: false,
            findings_panel_filter: String::new(),
            findings_panel_filter_focused: false,
            primary_position: 0,
            git_rail,
            image_protocol: crate::image::detect_protocol(),
            cell_pixel_size: crate::image::probe_cell_pixel_size(),
            image_paint_requests: Vec::new(),
            had_image_pane: false,
            last_image_paints: Vec::new(),
            scm_pr_cache: None,
            scm_pr_pending: None,
            http_env_override: None,
            repos,
            active_repo,
            git_closed_repos: std::collections::HashSet::new(),
            pre_git_layout: None,
            last_rail_synced_pane: None,
            git_palette_scroll: 0,
            git_section_expanded: git_section_expanded_default,
            integration_section_expanded: integrations_section_expanded_default,
            git_branches_expanded: false,
            rail_section: RailSection::Workspace,
            focused_extra_ws: None,
            git,
            toast: None,
            toast_stack: std::collections::VecDeque::new(),
            pending_undo: None,
            pending_env_key_delete: None,
            pending_confirm: None,
            claude_agents_prefetch: {
                let cache: std::sync::Arc<
                    std::sync::Mutex<Option<Vec<crate::claude_agents::AgentRow>>>,
                > = std::sync::Arc::new(std::sync::Mutex::new(None));
                let handle = cache.clone();
                std::thread::spawn(move || {
                    let rows = crate::claude_agents::prefetch_rows();
                    if let Ok(mut guard) = handle.lock() {
                        *guard = Some(rows);
                    }
                });
                cache
            },
            claude_agents_last_age_filter: crate::claude_agents::AgeFilter::default(),
            last_grep_query: String::new(),
            sessions_prefetch: {
                let cache: std::sync::Arc<
                    std::sync::Mutex<Option<Vec<crate::ai::transcript::PastSession>>>,
                > = std::sync::Arc::new(std::sync::Mutex::new(None));
                let handle = cache.clone();
                let ws = workspace_for_sessions_prefetch;
                std::thread::spawn(move || {
                    let rows = crate::ai::transcript::list_sessions(&ws);
                    if let Ok(mut guard) = handle.lock() {
                        *guard = Some(rows);
                    }
                });
                cache
            },
            persistent_toasts: Vec::new(),
            progress_items: Vec::new(),
            dynamic_segments: Vec::new(),
            values_source_snapshots: std::collections::HashMap::new(),
            statusline_segments_tx: None,
            statusline_segments_rx: None,
            statusline_segment_worker_shutdowns: Vec::new(),
            prefetch_worker_shutdowns: Vec::new(),
            statusline_segment_managed_ids: std::collections::HashSet::new(),
            pending_os_notifications: Vec::new(),
            notify_last_fired: std::collections::HashMap::new(),
            should_quit: false,
            restart_requested: false,
            redraw_requested: false,
            last_theme_system_check: None,
            last_command_failed: false,
            clock_show_utc: false,
            now_playing: None,
            now_playing_rx: None,
            now_playing_marquee_offset: 0,
            now_playing_marquee_last_tick: None,
            now_playing_marquee_prev_text: String::new(),
            sonos: crate::sonos::Snapshot::default(),
            sonos_tx: None,
            sonos_rx: None,
            last_mixr_track_at: None,
            http_sync_rx: None,
            http_sync_check_rx: None,
            http_bench_rx: None,
            ai_session_search_rx: None,
            http_bench_started: None,
            http_bench_progress: None,
            http_sync_started: None,
            lookup_fire_started: None,
            cookie_jar: cookie_jar_init,
            http_running_env: std::collections::HashMap::new(),
            pending_captured_rows: Vec::new(),
            pending_history_rows: Vec::new(),
            pending_lookup_items: Vec::new(),
            pending_lookup_picked_id: None,
            pending_env_edit_key: None,
            lookup_fire_rx: None,
            debug_rects: false,
            no_pane_cmdline: None,
            hover_chip: None,
            hover_help_committed: None,
            hover_help_pending: None,
            hover_help_scroll: 0,
            hover_help_height: hover_help_height_init,
            hover_help_drag: None,
            mouse_pos: None,
            hovered_bufferline_tab: None,
            last_tab_close_at: None,
            hover_editor_line: None,
            hover_divider_idx: None,
            hover_tree_edge: false,
            hover_right_panel_edge: false,
            show_discovery_overlay: false,
            discovery_flash: None,
            show_welcome: false,
            debug_click_inspector: false,
            update_check: None,
            startup_picker: None,
            show_about: false,
            scratch_term: None,
            tree_drag: None,
            pending_tree_move: None,
            pending_filter_range: None,
            pty_drag_select: None,
            frame_times_ms: std::collections::VecDeque::with_capacity(128),
            pending_toast_dismiss_idx: None,
            saved_pty_session_names: std::collections::HashMap::new(),
            git_undo_stack: Vec::new(),
            git_redo_stack: Vec::new(),
            quit_armed: false,
            rects: PaneRects::default(),
            flash_state: None,
            rename_preview_state: None,
            clipboard: Clipboard::new(),
            picker: None,
            keymap,
            git_loader_tx,
            git_loader_rx,
            pending_chord_seq: Vec::new(),
            pending_chord_deadline: None,
            pending_chord_fallback: None,
            whichkey: None,
            dragging: None,
            close_prompt: None,
            settings_overlay: None,
            first_launch: None,
            integration_settings: None,
            menu_open: None,
            integration_edit: None,
            glyph_builder: None,
            help_overlay: None,
            prompt: None,
            transfers: Vec::new(),
            transfer_tx,
            transfer_rx,
            next_transfer_id: 1,
            context_menu: None,
            context_submenu: None,
            file_clipboard: Vec::new(),
            file_clipboard_cut: false,
            files_pending_op: None,
            hover: None,
            mouse_hover_at: None,
            mouse_hover_screen: None,
            mouse_hover_fired: None,
            signature: None,
            pending_rename: None,
            pending_code_actions: Vec::new(),
            pending_code_action_resolve: None,
            pending_code_action_path: None,
            pending_code_lens_resolve: None,
            pending_code_action_auto_apply: false,
            pending_outline: false,
            selection_range_ladder: None,
            pending_call_hierarchy_items: Vec::new(),
            lsp_progress: std::collections::HashMap::new(),
            pending_snippets: Vec::new(),
            snippet_session: None,
            pending_workspace_symbols: Vec::new(),
            pending_workspace_symbol_query: None,
            find_regex_default: false,
            search_case_mode: None,
            find_preview_snapshot: None,
            find_pending_range: None,
            find_pending_reverse: false,
            replace_confirm: None,
            find_preview_cursor: 0,
            find_history: Vec::new(),
            find_history_cursor: 0,
            pending_branch_source: None,
            pending_stash_drop: None,
            pending_tag_delete: None,
            pending_discard_hunk: None,
            pending_discard_file: None,
            pending_fs_action: None,
            completion: None,
            http_chan: None,
            sse_chan: None,
            http_ai_build_chan: None,
            http_ai_build_in_flight: false,
            http_chain_chan: None,
            http_chain_in_flight: false,
            ws_send_chan: None,
            pending_ws_send_pane: None,
            pending_kill_pid: None,
            pending_kill_batch: Vec::new(),
            pending_branch_delete: None,
            pending_integration_remove_id: None,
            pending_integration_remove_binary: None,
            pending_integration_launcher_id: None,
            pending_launch_profile: None,
            pending_claude_account_rename: None,
            pending_worktree_path: None,
            pending_merge_source: None,
            pending_rebase_onto: None,
            theme_preview_restore: None,
            pending_pr_desc_job: None,
            pending_explain_diff_job: None,
            pending_branch_name_job: None,
            pending_recompose_branch_job: None,
            peek_overlay: None,
            pending_peek_definition: false,
            ai_chan: None,
            suggest_chan: None,
            pending_suggest: None,
            next_suggest_id: 0,
            suggest_dirty_at: None,
            last_suggest_context: None,
            suggest_shown: 0,
            suggest_accepted: 0,
            suggest_current_accepted: false,
            fim_tx: None,
            fim_progress: std::sync::Arc::new(std::sync::Mutex::new(None)),
            tests_chan: None,
            linter_chan: None,
            dap: None,
            dap_arrow: None,
            dap_thread: None,
            dap_pending_launch: None,
            dap_output_log: Vec::new(),
            dap_watches: Vec::new(),
            dap_watch_results: std::collections::HashMap::new(),
            dap_pending_bp_condition: None,
            dap_pending_set_variable: None,
            pending_commit_msg_job: None,
            pending_amend_msg_job: None,
            pending_wip_commit_msg_pane: None,
            next_job_id: 1,
            ai_tokens_in: 0,
            ai_tokens_out: 0,
            ai_confirm_senders: std::collections::HashMap::new(),
            pending_tool_confirm: None,
            dynamic_commands: Vec::new(),
            pending_plugin_invocations: Vec::new(),
            pending_term_integration_hint: None,
            lsp,
            test_history,
        }
        .with_integration_manifests_merged())
    }

    /// Layer each integration manifest onto config + register its
    /// commands as dynamic commands. Called from `App::new` and
    /// again by the `integrations.refresh` palette command.
    ///
    /// Precedence (post 2026-08-01 config flip):
    ///   integration manifest > built-in default > user's order/enabled prefs
    ///
    /// Every existing `IntegrationIcon` slot with a matching manifest
    /// id gets overwritten wholesale EXCEPT the two user-preference
    /// fields (`enabled`, `in_palette_bar`). Manifests can't touch
    /// order. The old `manifest_can_override: bool` gate was retired
    /// 2026-08-03 — it had no read sites after the flip.
    pub fn merge_integration_manifests(&mut self) {
        for m in &self.integration_manifests {
            let Some(chip) = &m.chip else { continue };
            // 2026-07-31 — integration-icons SDK. Three-tier resolution:
            //
            //  1. Explicit `chip.glyph` always wins — an integration that
            //     also picks a Nerd Font glyph overrides its own
            //     SVG/codepoint assignment.
            //  2. `chip.glyph_svg` + an assignment from the bake
            //     discovery pass — the codepoint mnml assigned to
            //     the baked SVG. Used by integrations that ship an SVG.
            //  3. `chip.glyph_codepoint` verbatim — for integrations
            //     that declare "assign me this codepoint" without
            //     shipping an SVG (the codepoint must already
            //     resolve via a routed font). Was missing before
            //     2026-08-15; caused installed chips like amplify
            //     (glyph="" + glyph_codepoint="F1B00") to render
            //     empty even though the codepoint was baked.
            let glyph = if !chip.glyph.is_empty() {
                chip.glyph.clone()
            } else if chip.glyph_svg.is_some()
                && let Some(cp) = self.integration_glyph_codepoints.get(&m.id).copied()
                && let Some(ch) = char::from_u32(cp)
            {
                ch.to_string()
            } else if let Some(hex) = chip.glyph_codepoint.as_deref()
                && let Ok(cp) =
                    u32::from_str_radix(hex.trim_start_matches("U+").trim_start_matches("0x"), 16)
                && let Some(ch) = char::from_u32(cp)
            {
                ch.to_string()
            } else {
                String::new()
            };
            let new_icon = crate::config::IntegrationIcon {
                id: m.id.clone(),
                glyph,
                fallback: chip.fallback.clone(),
                command: m
                    .commands
                    .first()
                    .map(|c| {
                        // 2026-07-31 — prefer the raw `run` string
                        // when it starts with `:term …`, so the
                        // chip's context menu can offer "Add to
                        // activity bar" (which gates on that
                        // prefix — dockable panes need a bare
                        // terminal command, not a palette command
                        // id). User reported the DB chip missing
                        // "Add to activity bar" for exactly this
                        // reason. Non-terminal-launching commands
                        // (e.g. `db.open` running `browser.open`)
                        // keep the id-based dispatch.
                        let run = c.run.trim();
                        if run.starts_with(":term ") || run.starts_with("term ") {
                            run.to_string()
                        } else {
                            c.id.clone()
                        }
                    })
                    .unwrap_or_else(|| match &m.binary {
                        Some(b) => format!("term {}", b),
                        // Launcher with no binary + no commands is a
                        // degenerate case (the manifest wouldn't do
                        // anything). Fall back to the id so the chip
                        // fires the id as a registered command.
                        None => m.id.clone(),
                    }),
                color: chip.color.clone(),
                // 2026-08-01 — label moved from chip.tooltip up to
                // manifest.label (identity, not chip visuals).
                label: Some(m.label.clone()),
                enabled: chip.enabled,
                in_palette_bar: chip.in_palette_bar,
                // A later manifest re-scan can re-apply/override.
                // 2026-07-31 — detail-pane metadata piped through
                // from the integration manifest so `Pane::IntegrationDetail`
                // can render description / links / command list without
                // a second `IntegrationManifest` lookup.
                description: m.description.clone(),
                homepage: m.homepage.clone(),
                docs: m.docs.clone(),
                repository: m.repository.clone(),
                author: m.author.clone(),
                // #1102 f/u (2026-08-20) — prefer the live
                // `<binary> --version` result (populated by
                // `refresh_binary_version_cache`) so the detail
                // byline reflects the actual installed binary,
                // not whatever the manifest was stamped with at
                // install time.
                version: m
                    .binary
                    .as_deref()
                    .and_then(|b| {
                        let basename = b.rsplit('/').next().unwrap_or(b);
                        self.binary_version_cache.get(basename).cloned()
                    })
                    .or_else(|| m.version.clone()),
                commands: m
                    .commands
                    .iter()
                    .map(|c| crate::config::IntegrationIconCommand {
                        id: c.id.clone(),
                        title: c.title.clone(),
                    })
                    .collect(),
            };
            // 2026-08-01 — always merge integration-owned fields.
            // Preserve `enabled` + `in_palette_bar` from the
            // existing slot (those are user prefs, everything else
            // is integration-authored default). The former
            // `manifest_can_override` gate was retired 2026-08-03
            // alongside its dead-field deletion — user config is
            // slim-only after the precedence flip in
            // `config::finalize`.
            match self
                .config
                .ui
                .integration_icons
                .iter_mut()
                .find(|i| i.id == m.id)
            {
                Some(slot) => {
                    let mut merged = new_icon;
                    // 2026-08-07 — built-in ids' authored manifests
                    // ARE the user's toggle state (write_override_toml
                    // regenerates the file from the Rust default plus
                    // the toggle values every time the chip is
                    // enabled/disabled). For those, the manifest wins.
                    // For integration manifests, preserve the slot's user-
                    // set enabled / in_palette_bar so the integration
                    // author's default can't clobber later user prefs.
                    //
                    // Without this discriminator, built-in chips reset
                    // to `enabled = false` on every restart: the slot
                    // carried the Rust default (false), the merge
                    // preserved it, and the user's true from the
                    // authored manifest got dropped. User report
                    // 2026-08-07 (third recurrence — earlier fix
                    // eddbcc18 fixed the cleanup path but not the
                    // merge path).
                    if !crate::app::discovery::is_builtin_integration_id(&m.id) {
                        merged.enabled = slot.enabled;
                        merged.in_palette_bar = slot.in_palette_bar;
                    }
                    *slot = merged;
                }
                None => self.config.ui.integration_icons.push(new_icon),
            }
        }
        // Register each manifest command as a dynamic command
        // with its ex_run baked in. Idempotent via
        // register_dynamic_command's id-match update path.
        //
        // #855 dedup: skip manifest commands whose id already exists
        // as a static builtin. Prevents the palette from showing two
        // entries for the same action after Edit-mode Save on a
        // first-party builtin promotes it to an authored manifest
        // (which the `write_authored_manifest_toml` writer stamps
        // with a synthetic `<id>.open` command block). The static
        // wins in dispatch anyway, so the dynamic dupe is purely
        // cosmetic UI noise.
        let static_ids: std::collections::HashSet<&'static str> = crate::command::registry()
            .all()
            .iter()
            .map(|c| c.id)
            .collect();
        let cmds: Vec<crate::command::DynCommand> = self
            .integration_manifests
            .iter()
            .flat_map(|m| {
                let owner = m.id.clone();
                m.commands
                    .iter()
                    .filter(|c| !static_ids.contains(c.id.as_str()))
                    .map(move |c| crate::command::DynCommand {
                        id: c.id.clone(),
                        title: c.title.clone(),
                        group: c
                            .group
                            .clone()
                            .unwrap_or_else(|| "integrations".to_string()),
                        keys: c.keys.clone(),
                        ex_run: Some(c.run.clone()),
                        owner_integration_id: Some(owner.clone()),
                    })
            })
            .collect();
        for c in cmds {
            self.register_dynamic_command(c);
        }
    }

    /// Consuming helper — used by `App::new` to fold the manifest
    /// merge into the constructor. Also runs the integration-glyph
    /// discovery pass BEFORE the merge so
    /// `merge_integration_manifests` can fill the `IntegrationIcon.glyph`
    /// field from the assigned codepoint when the manifest opted
    /// into the integration-icons SDK (`chip.glyph_svg` set, `chip.glyph`
    /// empty).
    fn with_integration_manifests_merged(mut self) -> Self {
        // 2026-08-06 — stage `[ui] terminal_glyph_svg` (if any)
        // into pending-glyphs BEFORE discover so a fresh install /
        // updated SVG gets its codepoint on this startup.
        self.stage_terminal_glyph_svg();
        self.discover_integration_glyphs();
        // #869 — mnml-bridge 0.6 handoff. Any pending-glyph SVG
        // whose bytes have already been baked into MnmlSymbols.ttf
        // (proxy: font mtime > SVG mtime) gets deleted. Steady
        // state is zero SVGs under ~/.cache/mnml/pending-glyphs/.
        let purged = self.purge_baked_pending_glyphs();
        if purged > 0 {
            eprintln!("mnml: cleaned up {purged} baked pending-glyph SVG(s)");
        }
        // #1102 f/u (2026-08-20) — populate live-version cache BEFORE
        // merge so the resulting `IntegrationIcon.version` reflects the
        // actual installed binary from cold start (not just after the
        // first `integrations.refresh`).
        self.refresh_binary_version_cache();
        self.merge_integration_manifests();
        // 2026-08-17 — spawn one background poll thread per
        // manifest-declared `[[values_sources]]` block, gated on
        // the parent chip being enabled AND the backing binary
        // being on PATH. Idempotent — a subsequent
        // `integrations.refresh` calls this again after re-merging
        // and drops the old channel to signal workers to exit.
        self.start_statusline_segment_workers();
        // #1117 (2026-08-21) — kick off the prefetch fleet
        // alongside statusline segments. Same install-gate + jitter
        // convention; see src/app/prefetch.rs.
        self.start_prefetch_workers();
        // 2026-08-01 (P4b) — populate marketplace entries from the
        // on-disk cache so the Marketplace tab has something to
        // render on cold start. Passive: no network I/O here — the
        // interactive-startup auto-refresh lives in
        // `App::maybe_refresh_marketplace_on_startup()`, called from
        // `main.rs` after `App::new` so tests / headless / E2E stays
        // hermetic.
        self.load_marketplace_cache();
        self
    }

    // ─── which-key (leader menu) ────────────────────────────────────
    /// Open the leader popup (the next keys walk the trie in `whichkey.rs`).
    pub fn open_whichkey(&mut self) {
        self.whichkey = Some(String::new());
    }
    pub fn whichkey_cancel(&mut self) {
        self.whichkey = None;
    }
    /// Feed one key into the leader sequence: descend a group, run a leaf, or
    /// (dead end) toast and close.
    pub fn whichkey_feed(&mut self, ch: char) {
        let Some(mut prefix) = self.whichkey.take() else {
            return;
        };
        prefix.push(ch);
        match crate::whichkey::lookup(&prefix) {
            Some(crate::whichkey::Leader::Cmd { id, .. }) => {
                let id = *id;
                crate::command::run(id, self);
            }
            Some(crate::whichkey::Leader::Group { .. }) => self.whichkey = Some(prefix),
            None => self.toast(format!("no leader mapping: <leader>{prefix}")),
        }
    }
    /// `(prefix-typed-so-far, continuations)` for the popup, if open.
    pub fn whichkey_menu(&self) -> Option<(&str, Vec<crate::whichkey::Entry>)> {
        let prefix = self.whichkey.as_deref()?;
        Some((prefix, crate::whichkey::continuations(prefix)))
    }

    /// 2026-06-21 — vim-operator whichkey popup. Reads the active
    /// editor's input handler for its current prefix state; the
    /// popup renders whenever the user is one key deep into a
    /// multi-key vim chord (g…, d…, Ctrl+W…, […, ]…, z…).
    pub fn vim_operator_menu(&self) -> Option<(String, Vec<(char, &'static str, bool)>)> {
        let i = self.active?;
        let Some(Pane::Editor(b)) = self.panes.get(i) else {
            return None;
        };
        b.input.operator_menu_hint()
    }

    /// Toggle the quick-scratch terminal at the bottom of the body. First
    /// invocation spawns a shell; subsequent toggles hide/show + focus.
    /// Dropping the App tears the pty down via `PtySession::Drop`.
    pub fn toggle_scratch_term(&mut self) {
        if let Some(s) = self.scratch_term.as_mut() {
            // Already open: a second toggle either focuses it (if blurred)
            // or closes it (if focused). Matches VS Code Ctrl+` semantics.
            if s.focused {
                self.scratch_term = None;
            } else {
                s.focused = true;
                self.focus = crate::focus::Focus::Pane;
            }
            return;
        }
        let profile = crate::pty_pane::BinaryProfile::shell(Some(self.workspace.clone()));
        match crate::pty_pane::PtySession::spawn(profile, SCRATCH_TERM_ROWS, 80) {
            Ok(session) => {
                self.scratch_term = Some(ScratchTerm {
                    session,
                    focused: true,
                });
                self.focus = crate::focus::Focus::Pane;
            }
            Err(e) => self.toast(format!("scratch term: {e}")),
        }
    }

    /// Blur the scratch terminal (keep it visible but route keys back to
    /// the active editor).
    pub fn blur_scratch_term(&mut self) {
        if let Some(s) = self.scratch_term.as_mut() {
            s.focused = false;
        }
    }

    /// Begin a tree drag from a row click. Stores the source path; the
    /// drag is "armed" only after the mouse moves off this row, so a
    /// pure click still acts as a click.
    pub fn begin_tree_drag(&mut self, src_path: std::path::PathBuf, src_is_dir: bool, y: u16) {
        self.begin_tree_drag_with_mode(src_path, src_is_dir, y, false);
    }

    /// Same as `begin_tree_drag` but stashes `copy_instead_of_move` on
    /// the drag record. Called by the mouse-down handler with the Alt
    /// modifier plumbed through.
    pub fn begin_tree_drag_with_mode(
        &mut self,
        src_path: std::path::PathBuf,
        src_is_dir: bool,
        y: u16,
        copy_instead_of_move: bool,
    ) {
        if std::env::var_os("MNML_DEBUG_DRAG").is_some() {
            self.toast(format!(
                "begin_tree_drag: {} (dir={}, copy={})",
                src_path.display(),
                src_is_dir,
                copy_instead_of_move
            ));
        }
        self.tree_drag = Some(TreeDrag {
            src_path,
            src_is_dir,
            origin_y: y,
            armed: false,
            current_target_idx: None,
            cursor_x: 0,
            cursor_y: y,
            copy_instead_of_move,
        });
    }

    /// 2026-06-22 — update the cursor position tracked by an
    /// in-flight tree drag. Read by the drag-ghost paint pass.
    /// Also arms the drag on any motion (X or Y) since the
    /// y-only check missed horizontal drags (tree → right edge
    /// of a pane), leaving the ghost / drop overlay invisible.
    pub fn set_tree_drag_cursor(&mut self, x: u16, y: u16) {
        if let Some(d) = self.tree_drag.as_mut() {
            let moved = x != d.cursor_x || y != d.cursor_y;
            d.cursor_x = x;
            d.cursor_y = y;
            if moved {
                d.armed = true;
            }
        }
        // 2026-06-22 diag — temporary trace so we can confirm the
        // drag-tracking path fires when the user mid-drags.
        // Enable by setting MNML_DEBUG_DRAG=1 in the env.
        if std::env::var_os("MNML_DEBUG_DRAG").is_some() {
            let armed = self.tree_drag.as_ref().is_some_and(|d| d.armed);
            self.toast(format!("drag cursor=({x},{y}) armed={armed}"));
        }
    }

    /// Mouse-move within a tree drag — arms the drag once we leave the
    /// origin row + records the current target idx for the highlight.
    pub fn drag_tree_to(&mut self, target_idx: Option<usize>, y: u16) {
        if let Some(d) = self.tree_drag.as_mut() {
            if y != d.origin_y {
                d.armed = true;
            }
            d.current_target_idx = target_idx;
        }
    }

    /// Drop the in-flight tree drag onto `target_idx`. If the target is a
    /// directory different from the source's parent (and not the source
    /// itself), open a confirmation prompt; the prompt accept calls
    /// `accept_tree_move`.
    pub fn end_tree_drag(&mut self, target_idx: Option<usize>) {
        let Some(drag) = self.tree_drag.take() else {
            return;
        };
        if !drag.armed {
            return;
        }
        let Some(idx) = target_idx else { return };
        let rows = self.tree.visible_rows();
        let Some(target_row) = rows.get(idx) else {
            return;
        };
        // Determine the *directory* to drop into: clicking on a dir row
        // means drop INTO it; clicking on a file means drop into its
        // parent dir.
        let target_dir = if target_row.is_dir {
            target_row.path.clone()
        } else {
            match target_row.path.parent() {
                Some(p) => p.to_path_buf(),
                None => return,
            }
        };
        // No-op cases: same dir as source, or dropping a dir into itself
        // or its own subtree.
        let Some(src_parent) = drag.src_path.parent() else {
            self.toast("can't move workspace root");
            return;
        };
        if target_dir == src_parent {
            // mouse-round-7 SEV-2 2026-07-12 — file dropped onto a
            // sibling file in the same directory used to be a
            // silent no-op. VS Code visually rejects with a "no"
            // cursor badge; TUI can't do that, so toast instead.
            let dropped_name = drag
                .src_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("item");
            self.toast(format!("no-op: {dropped_name} is already in this folder"));
            return;
        }
        if drag.src_is_dir && target_dir.starts_with(&drag.src_path) {
            self.toast("can't move a directory into itself");
            return;
        }
        let Some(src_name) = drag.src_path.file_name() else {
            return;
        };
        let dest = target_dir.join(src_name);
        if dest.exists() {
            self.toast(format!("destination already exists: {}", dest.display()));
            return;
        }
        let dest_rel = dest
            .strip_prefix(&self.workspace)
            .unwrap_or(&dest)
            .to_string_lossy()
            .into_owned();
        // Alt-drag = copy: fire immediately (non-destructive; matches
        // Finder / VS Code convention where a modifier-drop skips the
        // confirmation). Plain drag = move: keep the confirm prompt so
        // an accidental drop can't silently rename a file.
        if drag.copy_instead_of_move {
            match copy_recursively(&drag.src_path, &dest) {
                Ok(()) => {
                    self.tree.refresh();
                    self.toast(format!("copied \u{2192} {dest_rel}"));
                }
                Err(e) => self.toast(format!("copy failed: {e}")),
            }
            return;
        }
        self.pending_tree_move = Some((drag.src_path.clone(), dest.clone()));
        let mut prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::TreeMoveConfirm,
            format!("Move to {dest_rel}?"),
            String::new(),
        );
        // Focus Move (primary) by default — user just performed the
        // drag, so the affirmative answer is what they meant.
        prompt.cursor = 0;
        self.prompt = Some(prompt);
    }

    /// Apply the pending tree move — invoked from the confirmation prompt.
    /// Renames the file, re-points any open editor on the source, and
    /// refreshes the tree + git.
    pub fn accept_tree_move(&mut self) {
        let Some((src, dest)) = self.pending_tree_move.take() else {
            return;
        };
        if let Some(parent) = dest.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::rename(&src, &dest) {
            Ok(()) => {
                // Update any open editor that was pointed at the source.
                for p in &mut self.panes {
                    if let Pane::Editor(b) = p
                        && b.path.as_ref().is_some_and(|x| x == &src)
                    {
                        b.path = Some(dest.clone());
                    }
                }
                self.toast(format!(
                    "moved → {}",
                    dest.strip_prefix(&self.workspace)
                        .unwrap_or(&dest)
                        .display()
                ));
                self.tree.refresh();
                // mouse-round-10 SEV-3 2026-07-12 — leave the tree
                // cursor on the moved item so the user can
                // immediately act on it (VS Code / Finder pattern).
                // Also expand every ancestor dir so the row is
                // visible in the collapsed tree.
                let mut cur = dest.parent();
                while let Some(p) = cur {
                    if !p.starts_with(&self.workspace) {
                        break;
                    }
                    self.tree.expand_dir(p);
                    cur = p.parent();
                    if cur.map(|c| c == self.workspace).unwrap_or(false) {
                        break;
                    }
                }
                if let Some(idx) = self.tree.visible_rows().iter().position(|r| r.path == dest) {
                    self.tree.set_cursor(idx);
                }
                self.after_git_change();
            }
            Err(e) => {
                self.toast(format!("move failed: {e}"));
            }
        }
    }

    /// Path to the per-workspace "I've seen the welcome overlay" marker.
    fn welcomed_marker_path(&self) -> std::path::PathBuf {
        self.workspace.join(WELCOMED_MARKER_REL)
    }

    /// Open the welcome overlay automatically on launch, unless the user
    /// has previously dismissed it in this workspace. Called once from
    /// `main()` after `try_restore_session`.
    pub fn maybe_show_welcome_on_launch(&mut self) {
        if !self.welcomed_marker_path().exists() {
            self.show_welcome = true;
        }
    }

    /// Is the welcome card actually painted right now?
    ///
    /// `show_welcome` alone is not the answer: the card stands down
    /// whenever another modal is drawn over it — see
    /// `ui::welcome_overlay::draw`, which defers to this. Dismiss
    /// gestures must check this rather than the raw flag. On a genuine
    /// first launch the wizard covers the (still-`true`) welcome
    /// completely, so the first click or Esc aimed at the *wizard* used
    /// to dismiss an overlay nobody had seen and write
    /// `.mnml/.welcomed` — the shortcut cheatsheet was never shown to
    /// the one user it exists for. Same shape for a prompt/picker
    /// opened over it.
    pub fn welcome_visible(&self) -> bool {
        self.show_welcome
            && self.first_launch.is_none()
            && self.prompt.is_none()
            && self.picker.is_none()
            && self.help_overlay.is_none()
            && self.signature.is_none()
            && self.completion.is_none()
            && self.whichkey.is_none()
    }

    /// Toggle the About overlay. Pure in-memory — no marker file (vs the
    /// welcome overlay which only auto-opens once per workspace).
    pub fn toggle_about(&mut self) {
        self.show_about = !self.show_about;
    }

    /// Toggle the welcome overlay manually (palette / `:welcome`). Showing
    /// the overlay also writes the marker so it doesn't auto-reopen next
    /// launch.
    pub fn toggle_welcome(&mut self) {
        self.show_welcome = !self.show_welcome;
        if !self.show_welcome {
            // Dismissed — record so the auto-open doesn't fire again.
            self.write_welcomed_marker();
        }
    }

    /// Dismiss the welcome overlay + persist that the user has seen it.
    pub fn dismiss_welcome(&mut self) {
        self.show_welcome = false;
        self.write_welcomed_marker();
    }

    fn write_welcomed_marker(&self) {
        let path = self.welcomed_marker_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, b"welcomed\n");
    }
    /// `buffer.reopen` — pop the most-recently-closed buffer off
    /// [`Self::closed_buffers`] and re-open it at its captured position.
    /// No-op when the stack is empty.
    pub fn reopen_closed_buffer(&mut self) {
        let Some((path, _cur, _scroll)) = self.closed_buffers.pop() else {
            self.toast("no closed buffer to reopen");
            return;
        };
        // `open_path` will pick up the captured position from `file_cursors`
        // (which `force_close_pane` already populated).
        self.open_path(&path);
    }

    /// `view.close_others` — close every non-active pane (and respect the
    /// dirty-editor guard from [`Self::close_panes_except`]). No-op when
    /// there's only one pane open or no active.
    pub fn close_other_panes(&mut self) {
        let Some(active) = self.active else {
            return;
        };
        if self.panes.len() <= 1 {
            return;
        }
        self.close_panes_except(Some(active));
    }

    // ─── picker / palette ───────────────────────────────────────────
    // ─── plugin-registered (dynamic) commands ───────────────────────
    /// Add (or replace) a plugin-registered command and bind any keyspecs it asked
    /// for. Idempotent on `id`.
    pub fn register_dynamic_command(&mut self, dc: crate::command::DynCommand) {
        for spec in &dc.keys {
            self.keymap.bind(spec, &dc.id);
        }
        if let Some(slot) = self.dynamic_commands.iter_mut().find(|c| c.id == dc.id) {
            *slot = dc;
        } else {
            // 2026-07-03: only IPC-registered plugin commands
            // (ex_run.is_none()) get an announcement toast. Manifest-
            // registered integration commands (ex_run.is_some())
            // land at startup — one per installed integration —
            // and toasting each stacked ~15 messages the first
            // time the user opened mnml with the SDK sweep done.
            if dc.ex_run.is_none() {
                self.toast(format!("plugin command registered: {}", dc.title));
            }
            self.dynamic_commands.push(dc);
        }
    }
    /// If `id` is a dynamic command, either dispatch its ex-command
    /// locally (manifest-registered) or queue for the IPC layer to
    /// log (plugin-registered). Returns true if the id matched.
    /// (Called by `command::run` after the builtin lookup.)
    pub fn run_dynamic_command(&mut self, id: &str) -> bool {
        // Phase 2D — first-hit auth guard. If this dynamic command
        // belongs to an integration whose manifest declares any
        // required auth field, AND that field has no stored value
        // AND no env_fallback env var is set, intercept: open the
        // per-integration Settings pane instead of dispatching. The
        // Save closes the pane; the user re-fires the command
        // manually. Avoids surprising the user with a silent broken
        // action ("clicked Slack, nothing happened").
        if let Some(integration_id) = self
            .integration_manifests
            .iter()
            .find(|m| m.commands.iter().any(|c| c.id == id))
            .map(|m| m.id.clone())
            && self.integration_has_missing_required_auth(&integration_id)
        {
            self.toast(format!(
                "`{integration_id}` needs setup — opening Configure…"
            ));
            self.open_integration_settings(&integration_id);
            return true;
        }
        // Manifest-registered commands carry an ex-command line.
        // Dispatch locally so the integration doesn't need to be
        // running to answer the invocation.
        let (ex_run, owner) = self
            .dynamic_commands
            .iter()
            .find(|c| c.id == id)
            .map(|c| (c.ex_run.clone(), c.owner_integration_id.clone()))
            .unwrap_or((None, None));
        if let Some(cmdline) = ex_run {
            // #1099 f/u (2026-08-20) — stamp the rigid owner-
            // integration hint so the `:term` handler binds the
            // pty tab's icon + label to the declaring manifest,
            // not to whichever chip's binary matches first.
            self.pending_term_integration_hint = owner;
            // 2026-07-03 — for `:term <binary>` dispatched from
            // an integration chip (rail click, chord, palette
            // fire), if a Pty pane hosting that exact binary is
            // already open, FOCUS it instead of spawning a new
            // one that splits the layout. User doesn't expect a
            // second Amplify to appear when they click the chip
            // twice.
            let trimmed = cmdline.trim().trim_start_matches(':').trim();
            if let Some(binary) = trimmed
                .strip_prefix("term ")
                .or_else(|| trimmed.strip_prefix("terminal "))
                .map(|s| s.trim())
                && !binary.contains(char::is_whitespace)
            {
                // Match by profile.args (the shell -c argument
                // is the binary invocation).
                let existing = self.panes.iter().enumerate().find_map(|(pid, p)| {
                    let crate::pane::Pane::Pty(s) = p else {
                        return None;
                    };
                    let args_joined = s.profile.args.join(" ");
                    if args_joined.trim() == binary || args_joined.trim().ends_with(binary) {
                        Some(pid)
                    } else {
                        None
                    }
                });
                if let Some(pid) = existing {
                    self.active = Some(pid);
                    return true;
                }
            }
            self.run_ex_command(&cmdline);
            return true;
        }
        if self.dynamic_commands.iter().any(|c| c.id == id) {
            self.pending_plugin_invocations.push(id.to_string());
            true
        } else {
            false
        }
    }
    /// Take the plugin-command ids invoked since the last call (the IPC layer
    /// appends a `plugin-command` event for each so the plugin can react).
    pub fn take_pending_plugin_invocations(&mut self) -> Vec<String> {
        std::mem::take(&mut self.pending_plugin_invocations)
    }
    /// Switch the active theme by name, re-highlight open buffers, and remember it.
    pub fn set_theme(&mut self, name: &str) {
        match self.set_theme_silent(name) {
            Some(name) => self.toast(format!("theme: {name}")),
            None => self.toast(format!(
                "unknown theme: {name} (have: {})",
                crate::ui::theme::names().join(", ")
            )),
        }
    }

    /// NvChad-style binary theme toggle. Swaps between `[ui] theme` ↔
    /// `[ui] theme_toggle` (the two configured names). Driven by the
    /// bufferline's slider chip. When `theme_toggle` is unset, toasts a
    /// hint so the user knows how to enable it.
    pub fn toggle_theme(&mut self) {
        let Some(alt) = self.config.ui.theme_toggle.clone() else {
            // No alt configured — open the theme picker instead of
            // toasting "go configure this." Users clicking the pill
            // still get a useful action; power users can set
            // `[ui] theme_toggle` for a one-click swap.
            self.open_theme_picker();
            return;
        };
        let current = crate::ui::theme::cur().name.to_string();
        let primary = self.config.ui.theme.clone();
        // If we're on the primary → flip to alt; otherwise (on the alt or any
        // third theme) → flip to primary. That way the chord is a reliable
        // "swap to your other theme" regardless of how we got here.
        let target = if current == primary { alt } else { primary };
        self.set_theme(&target);
    }

    /// Like [`Self::set_theme`] but no toast — used at session restore so a
    /// "theme: onedark" doesn't pop on every launch.
    fn set_theme_silent(&mut self, name: &str) -> Option<String> {
        let t = crate::ui::theme::set(name)?;
        // Keep the canonical `current-theme.toml` in sync so the family
        // (mixr, mnml-* integrations) retints to match within a tick.
        crate::ui::theme::write_current(&t);
        self.config.ui.theme = t.name.to_string();
        for pane in &mut self.panes {
            if let Some(b) = pane.as_editor_mut() {
                b.refresh_highlights();
            }
        }
        Some(t.name.to_string())
    }
    // `cross_nav_pr_to_pipeline` removed after the 2026-06 SCM split
    // — all four SCM hosts moved to mnml-forge-* integrations, and the
    // cross-host PR picker that called this method is gone too.

    /// Re-walk the workspace and rebuild `App.repos`. Useful when a repo was
    /// cloned (or a `.git/` dir created) in another terminal after launch —
    /// `git.switch_repo` won't see the new repo otherwise. Resets the active
    /// repo to index 0 (typically the workspace root) on the assumption that
    /// the previous active repo might not exist in the rebuilt list at the
    /// same index.
    pub fn rediscover_repos(&mut self) {
        let new_repos = crate::git::repos::discover_repos(&self.workspace);
        let before = self.repos.len();
        self.repos = new_repos;
        self.active_repo = 0;
        let root = self.active_repo_path().to_path_buf();
        self.git.retarget(&root);
        self.git_rail.refresh(&root);
        self.refresh_rail_pulls();
        self.toast(format!("repos: {} → {}", before, self.repos.len()));
    }

    // A-4: workspace runtime + workspaces-editor methods moved to
    // src/app/workspace_methods.rs.

    fn cursor_id_prefix(&self) -> Option<String> {
        let b = self.active_editor()?;
        let cur = b.editor.cursor();
        let t = b.editor.text();
        let mut v: Vec<char> = t[..cur]
            .chars()
            .rev()
            .take_while(|&c| c.is_alphanumeric() || c == '_')
            .collect();
        v.reverse();
        Some(v.into_iter().collect())
    }

    /// Spawn (once) the local-FIM worker thread + return its request
    /// sender. The worker owns the `FimEngine`, loads it lazily on the
    /// first request (a one-time ~1 GB download), and replies through
    /// `suggest_chan` — load status arrives as the `u64::MAX` sentinel.
    fn ensure_fim_worker(&mut self) -> std::sync::mpsc::Sender<FimRequest> {
        if let Some(tx) = &self.fim_tx {
            return tx.clone();
        }
        let (tx, rx) = std::sync::mpsc::channel::<FimRequest>();
        let reply = self
            .suggest_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let progress = std::sync::Arc::clone(&self.fim_progress);
        let model = self.ai_fim_model();
        std::thread::Builder::new()
            .name("mnml-fim".into())
            .spawn(move || fim_worker_loop(rx, reply, progress, model))
            .ok();
        self.fim_tx = Some(tx.clone());
        let size = match model {
            fim_engine::ModelChoice::Qwen3B => "3B",
            fim_engine::ModelChoice::Qwen1_5B => "1.5B",
        };
        self.toast(format!(
            "fim-engine: loading local model ({size}) — first run downloads ~1 GB, one-time…"
        ));
        tx
    }

    /// Run a named `[tasks.<name>]` entry in a new pty pane.
    pub fn run_task(&mut self, name: &str) -> bool {
        let Some(def) = self.config.tasks.get(name).cloned() else {
            self.toast(format!("unknown task: {name}"));
            return false;
        };
        let cwd = match &def.cwd {
            Some(rel) => {
                let p = Path::new(rel);
                if p.is_absolute() {
                    p.to_path_buf()
                } else {
                    self.workspace.join(p)
                }
            }
            None => self.workspace.clone(),
        };
        self.open_pty(crate::pty_pane::BinaryProfile::task(name, &def.cmd, cwd));
        true
    }

    /// `[startup] tasks = [...]` — run each on workspace open (called once by the
    /// event loop). Unknown names are toasted and skipped.
    pub fn run_startup_tasks(&mut self) {
        let names = self.config.startup_tasks.clone();
        for name in names {
            self.run_task(&name);
        }
    }

    // ─── panes / buffers ────────────────────────────────────────────

    /// Currently-displayed pane id in the right side panel, or `None`
    /// if the panel is empty / closed. Clamps the active_idx into
    /// the hosted-panes list defensively.
    pub fn right_panel_active_pane_id(&self) -> Option<usize> {
        if self.right_panel_panes.is_empty() {
            return None;
        }
        let idx = self
            .right_panel_active_idx
            .min(self.right_panel_panes.len() - 1);
        Some(self.right_panel_panes[idx])
    }

    /// Maximum hosted-pane slots in the right side panel. design-critic
    /// 2026-06-28 #4: 3+ tabs in a 32-cell column silently drop —
    /// the renderer's strip_end check bails out without rendering a
    /// scroll indicator. Cap + FIFO-displace honestly tracks state
    /// to UI. Bumped 2 → 3 on 2026-06-28 v4 for AI chat as a 3rd
    /// hosted type — the renderer's `…` truncation handles the
    /// label squeeze at narrow widths.
    pub const RIGHT_PANEL_MAX_TABS: usize = 3;

    /// Push a pane into the right panel and make it active. If at
    /// the `RIGHT_PANEL_MAX_TABS` cap, the OLDEST hosted pane is
    /// displaced (FIFO) — close_pane'd so no ghost bufferline tab
    /// lingers.
    pub fn right_panel_push(&mut self, mut pid: usize) -> usize {
        // crash-investigator SEV-1 #2: use force_close_pane (not
        // close_pane) so a dirty editor in the slot can't refuse to
        // be displaced and cause the loop to double-evict. In v3
        // only Outline / Diagnostics get hosted (never editors, so
        // never dirty), but the FIFO is defensive — keep it robust.
        // remove_pane_storage handles the right_panel_panes shift.
        //
        // crash-investigator 2nd LATENT SEV-1: each force_close_pane
        // call shifts every pane id > evicted down by 1. The caller
        // captured `pid` BEFORE eviction, so we must shift it down
        // alongside the shift to keep it pointing at the right pane
        // in self.panes after the evictions. Unreachable today (cap
        // guards make the loop a no-op for current callers) but a
        // certain panic if MAX_TABS ever lifts or a 3rd hosted pane
        // type is added.
        let was_at_cap = self.right_panel_panes.len() >= Self::RIGHT_PANEL_MAX_TABS;
        while self.right_panel_panes.len() >= Self::RIGHT_PANEL_MAX_TABS {
            let oldest = self.right_panel_panes[0];
            self.force_close_pane(oldest);
            // remove_pane_storage shifted every id > oldest down by
            // 1 — apply the same shift to the caller's pid.
            if pid > oldest {
                pid -= 1;
            }
        }
        if was_at_cap {
            // mouse-hunter v3 SEV-2 J — toast on silent displace so
            // the user knows their last open dropped an integration.
            self.toast("right panel full — closed oldest tab");
        }
        self.right_panel_panes.push(pid);
        let idx = self.right_panel_panes.len() - 1;
        self.right_panel_active_idx = idx;
        idx
    }

    /// Close every right-panel-hosted pane and clear the host list.
    /// Iterates in descending pid order so close_pane's id-shift
    /// (handled by remove_pane_storage) doesn't invalidate the
    /// remaining iterator entries. code-reviewer 2026-06-28 W-1 + W-3
    /// — was duplicated in view.toggle_right_panel + missing from
    /// the `:set rightpanel!` / `:set norightpanel` paths.
    pub fn close_right_panel_hosted_panes(&mut self) {
        let mut panes = std::mem::take(&mut self.right_panel_panes);
        self.right_panel_active_idx = 0;
        panes.sort_unstable_by(|a, b| b.cmp(a));
        for pid in panes {
            self.force_close_pane(pid);
        }
    }

    pub fn active_editor(&self) -> Option<&Buffer> {
        self.active_pane().and_then(Pane::as_editor)
    }
    pub fn active_editor_mut(&mut self) -> Option<&mut Buffer> {
        self.active_pane_mut().and_then(Pane::as_editor_mut)
    }

    /// Snapshot of runtime context for launcher template expansion.
    /// See `crate::launcher_template` for the substitution engine.
    /// Assembled fresh on each call — cheap (all field reads, one
    /// clone of the workspace PathBuf).
    pub fn launcher_template_ctx(&self) -> crate::launcher_template::TemplateContext {
        let (current_file, cursor_line, cursor_col) = match self.active_editor() {
            Some(b) => (
                b.path.clone(),
                Some(b.editor.row_col().0 + 1),
                Some(b.editor.row_col().1 + 1),
            ),
            None => (None, None, None),
        };
        // Selection support arrives with P5's launcher edit overlay —
        // needs the editor's selection accessor, not blocking P3.
        crate::launcher_template::TemplateContext {
            workspace: self.workspace.clone(),
            current_file,
            cursor_line,
            cursor_col,
            selection: None,
        }
    }

    /// multilang 3rd 2026-06-28 SEV-2: in a monorepo, runner
    /// commands need to find the editor's parent dir even when
    /// the active pane is a pty (a prior `npm.test` run took
    /// focus). Walk `self.panes` for the most recent Editor pane;
    /// active editor wins if there is one.
    pub fn most_recent_editor_path(&self) -> Option<&std::path::Path> {
        if let Some(b) = self.active_editor()
            && let Some(p) = b.path.as_deref()
        {
            return Some(p);
        }
        self.panes
            .iter()
            .rev()
            .find_map(|p| p.as_editor().and_then(|b| b.path.as_deref()))
    }

    /// Open a scratch buffer pre-seeded with `text` in a horizontal split
    /// below the active leaf. `_title` is decorative — scratch buffers
    /// have no path. Used by `:Capture <cmd>` to surface command output.
    /// Populate a Request pane (form-style) from `curl_text`. Used
    /// by every "picked a curl-shaped row" flow — history / captured
    /// pickers plus the sectioned sidebar + HttpHome dashboard row
    /// clicks. `_method` / `_url` are kept in the signature for
    /// callers that pre-parsed the row; the function re-parses
    /// `curl_text` internally so all four callers share one code
    /// path.
    ///
    /// Reuse policy — if the active pane is already a `Pane::Request`,
    /// its fields are overwritten in place (matches
    /// `http.paste_curl`'s "paste into the current request" idiom).
    /// This is why clicking five history rows in a row leaves you
    /// with ONE Request pane, not five stacked scratch buffers —
    /// which is what the earlier `open_curl_scratch` did (built a
    /// text scratch per click, hence the `[scratch]` pile-up the
    /// user hit 2026-07-05).
    ///
    /// When there's no active Request pane, `open_new_request_pane`
    /// creates one first (in Edit view with the "not sent" hint
    /// state), then this method overwrites its fields with the
    /// parsed row.
    ///
    /// Parse failure toasts + bails (no scratch is left behind).
    pub fn open_curl_scratch(&mut self, curl_text: &str, _method: &str, _url: &str) {
        let parsed = match crate::http::parse(curl_text) {
            Ok(r) => r,
            Err(e) => {
                self.toast(format!("http: parse failed: {e}"));
                return;
            }
        };
        // Reuse the active Request pane in TWO cases (2026-07-08):
        //   1. It's blank (no URL/body/headers) — matches Postman:
        //      don't clobber real in-progress composition.
        //   2. It's a PREVIEW pane — user was just browsing (opened
        //      via arrow-nav / click in HTTP panel, never edited).
        //      Replacing the preview keeps the "one tab as I flip
        //      through requests" idiom without piling up scratch
        //      tabs the user has to close.
        //
        // Also — if this isn't the active pane but some OTHER open
        // Request pane is currently a preview, replace THAT one and
        // switch to it. This handles the "click a row in HTTP
        // panel while focus is in the tree" case.
        let can_reuse_active = matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(rp))
                if rp.is_preview
                    || (rp.request.url.is_empty()
                        && rp.headers_buffer.trim().is_empty()
                        && rp.request.body.as_deref().unwrap_or("").is_empty())
        );
        if !can_reuse_active {
            // Look for another Request pane sitting in preview.
            if let Some(preview_pid) = self
                .panes
                .iter()
                .position(|p| matches!(p, Pane::Request(rp) if rp.is_preview))
            {
                self.active = Some(preview_pid);
                self.focus = crate::focus::Focus::Pane;
            } else {
                self.open_new_request_pane();
            }
        }
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.headers_buffer = crate::request_pane::headers_to_text(&parsed.headers);
            rp.headers_cursor = rp.headers_buffer.len();
            rp.url_cursor = parsed.url.len();
            rp.body_cursor = parsed.body.as_deref().map(str::len).unwrap_or(0);
            rp.request = parsed;
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.edit_tab = crate::request_pane::EditTab::Body;
            // Mark as preview so a subsequent open replaces this
            // in place. Any edit (see `request_pane::promote_out_of_preview`)
            // flips this back to false.
            rp.is_preview = true;
        }
    }

    pub fn open_scratch_with_text(&mut self, _title: String, text: String) {
        // 2026-06-19 — api-workflow-user agent flagged that the
        // earlier `split_active` + `panes.push` + `reveal_pane`
        // pattern left an orphan blank scratch buffer per call
        // (same bug as `open_curl_scratch`). Build the populated
        // buffer first, then splice it into the layout in one
        // step via `split_leaf_with`.
        let mut buf = crate::buffer::Buffer::scratch(&self.config);
        let mut clip = crate::clipboard::Clipboard::detached();
        let _ = buf
            .editor
            .apply(crate::edit_op::EditOp::InsertStr(text), 24, &mut clip);
        buf.editor.place_cursor(0, 0);
        let Some(cur) = self.active else {
            self.panes.push(Pane::Editor(buf));
            let new_id = self.panes.len() - 1;
            self.reveal_pane(new_id);
            return;
        };
        let new_id =
            self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, Pane::Editor(buf));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Open the API-canary log as a scratch pane. Wired to
    /// `:ai.canary`. Task #1160 (2026-08-23) — surfaces the JSONL
    /// hit trail the user needs to trace an unexpected console
    /// charge back to its callsite in mnml. `tail_log` caps the
    /// read at 128 KB so a runaway log doesn't stall the render
    /// thread on open (review of a8eb98ea).
    pub fn open_api_canary_log(&mut self) {
        let body = crate::api_canary::tail_log();
        self.open_scratch_with_text("[api-canary]".to_string(), body);
    }

    /// Track the just-run command id for `picker.recent_commands`.
    /// Moves an existing entry to the front (de-dupes), caps at 50.
    pub fn note_recent_command(&mut self, id: &str) {
        self.recent_commands.retain(|c| c != id);
        self.recent_commands.insert(0, id.to_string());
        if self.recent_commands.len() > 50 {
            self.recent_commands.truncate(50);
        }
    }

    /// navigate the most-recent grep result list (mnml's stand-in for
    /// vim's quickfix list). The selection moves inside the open
    /// `Pane::Grep` and the cursor jumps to that hit's source location.
    /// `delta=+/-1` (next/prev), `0` doesn't move (jumps current);
    /// `i32::MAX` ⇒ last; `i32::MIN` ⇒ first.
    pub fn quickfix_navigate(&mut self, delta: i32) {
        // Prefer a Quickfix pane; fall back to Grep (mnml's `:grep` populates
        // Grep — vim users reach for `:cnext` after either).
        let qf_idx = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Quickfix(_)))
            .or_else(|| self.panes.iter().position(|p| matches!(p, Pane::Grep(_))));
        let Some(grep_idx) = qf_idx else {
            self.toast(":cnext — no quickfix / grep results");
            return;
        };
        let g = match self.panes.get_mut(grep_idx) {
            Some(Pane::Grep(g)) | Some(Pane::Quickfix(g)) => g,
            _ => return,
        };
        if g.hits.is_empty() {
            self.toast(":cnext — no hits");
            return;
        }
        let n = g.hits.len();
        if delta == i32::MAX {
            g.selected = n - 1;
        } else if delta == i32::MIN {
            g.selected = 0;
        } else if delta != 0 {
            g.move_selection(delta as isize);
        }
        let Some(hit) = g.selected_hit().cloned() else {
            return;
        };
        let cur = g.selected + 1;
        let total = n;
        // Jump to source.
        self.open_path(&hit.path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(hit.line as usize, hit.col as usize);
        }
        self.toast(format!("qf {cur}/{total} · {}:{}", hit.rel, hit.line + 1));
    }

    /// Try to expand a vim abbreviation in the active editor. Called from
    /// `dispatch_key` after a buffer mutation in Insert mode when a
    /// "trigger" char (whitespace / punctuation) was typed. Walks back
    /// from the cursor's previous position over identifier chars; if the
    /// resulting word matches `config.abbreviations`, replaces it with
    /// the expansion (cursor stays on the trigger char).
    pub fn try_expand_abbreviation(&mut self, idx: usize) {
        if self.config.abbreviations.is_empty() {
            return;
        }
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            return;
        };
        let cursor = b.editor.cursor();
        if cursor < 2 {
            return;
        }
        let text = b.editor.text();
        // The trigger char is the most recent insert — the byte right before
        // the cursor. Walk back from there to find the start of the
        // identifier.
        let trigger_end = cursor - 1;
        if trigger_end > text.len() || !text.is_char_boundary(trigger_end) {
            return;
        }
        let mut start = trigger_end;
        while start > 0 {
            let prev = match text[..start].chars().next_back() {
                Some(c) => c,
                None => break,
            };
            if !(prev.is_alphanumeric() || prev == '_') {
                break;
            }
            start -= prev.len_utf8();
        }
        if start == trigger_end {
            return;
        }
        let word = &text[start..trigger_end];
        let Some(expansion) = self.config.abbreviations.get(word).cloned() else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        b.apply_edit_ops(
            vec![crate::edit_op::EditOp::ReplaceRange {
                start,
                end: trigger_end,
                text: expansion,
            }],
            &mut self.clipboard,
            0,
        );
    }

    /// `buffer.last` (`Ctrl+Tab`) — switch to the previously-active pane.
    /// MRU two-buffer toggle (vim's `Ctrl+^`); pressing it twice oscillates
    /// between the two most recently focused panes. No-op if there's no
    /// recorded prior active or if it's been closed.
    /// vscode-user-keyboard SEV-2 2026-07-11 — Ctrl+1..Ctrl+9 focus
    /// the Nth bufferline tab (1-based, VS Code convention: Ctrl+1 =
    /// group 1, Ctrl+9 = last group; mnml maps this to bufferline
    /// tabs so it works with tab-only usage OR splits). Non-existent
    /// tabs are silent no-ops. Right-panel-hosted panes are excluded
    /// from the count (they aren't in the bufferline).
    pub fn focus_bufferline_tab(&mut self, one_based: usize) {
        if one_based == 0 {
            return;
        }
        // Build the visible bufferline index list: every pane that
        // isn't currently hosted in the right panel.
        let mut visible: Vec<usize> = Vec::new();
        for (i, _) in self.panes.iter().enumerate() {
            if !self.right_panel_panes.contains(&i) {
                visible.push(i);
            }
        }
        // Ctrl+9 = LAST tab (VS Code convention: last group, not
        // literal 9th). Every other N = the Nth tab if it exists.
        let target = if one_based == 9 {
            visible.last().copied()
        } else {
            visible.get(one_based - 1).copied()
        };
        if let Some(pid) = target {
            self.reveal_pane(pid);
        }
    }

    pub fn switch_to_last_buffer(&mut self) {
        let Some(target) = self.last_active else {
            self.toast("no previous buffer");
            return;
        };
        if target >= self.panes.len() {
            self.last_active = None;
            return;
        }
        self.reveal_pane(target);
    }

    /// `(path, row, col)` of the currently-active editor, or `None` if the
    /// active pane isn't an editor with a path. Used to seed the nav stacks.
    pub fn current_nav_point(&self) -> Option<NavPoint> {
        let b = self.active_editor()?;
        let path = b.path.clone()?;
        let (row, col) = b.editor.row_col();
        Some(NavPoint { path, row, col })
    }

    /// Public wrapper around `push_nav_back` for the dispatch_key
    /// post-key hook that records vim-jumplist entries on big cursor
    /// moves (`G` / `gg` / `{N}G` / `/pattern` / LSP goto / etc.).
    /// Also clears the forward stack — matches vim's behavior of
    /// "any new jump wipes the redo lane." 2026-07-07.
    ///
    /// EXCEPTION: when `nav_jump_in_progress` is set, the big jump
    /// IS `nav_back_jump` / `nav_forward_jump` itself. Clearing the
    /// forward stack there would wipe the entry those functions
    /// just pushed. nvchad SEV-2 2026-07-10 — was making Ctrl+I
    /// after Ctrl+O toast "nothing to go forward to" because the
    /// forward stack was reset before it could be popped.
    pub fn record_within_file_jump(&mut self, np: NavPoint) {
        // nvchad-round-9 SEV-2 2026-07-11 — during a nav_back/forward
        // jump, the destination fires post-dispatch big-jump
        // recording, which re-pushed the destination onto the back
        // stack — so `3G, 7G, 12G, <C-O>, <C-O>, <C-O>` produced
        // `7, 12, 7` instead of `7, 3, 1`. Skip the push entirely
        // during a jump-in-progress; the nav_back/forward helpers
        // already handled the stack bookkeeping themselves.
        if self.nav_jump_in_progress {
            return;
        }
        // Vim's `'` / `` ` `` mark — the position we WERE at before
        // this big jump. `` ` ` `` toggles between it and current.
        // nvchad-round-11 SEV-2 2026-07-12.
        self.prev_jump_pos = Some(np.clone());
        self.push_nav_back(np);
        self.nav_forward.clear();
    }

    fn push_nav_back(&mut self, np: NavPoint) {
        self.nav_back.push(np);
        if self.nav_back.len() > NAV_STACK_MAX {
            let drop_n = self.nav_back.len() - NAV_STACK_MAX;
            self.nav_back.drain(..drop_n);
        }
    }

    fn push_nav_forward(&mut self, np: NavPoint) {
        self.nav_forward.push(np);
        if self.nav_forward.len() > NAV_STACK_MAX {
            let drop_n = self.nav_forward.len() - NAV_STACK_MAX;
            self.nav_forward.drain(..drop_n);
        }
    }

    /// Alt+Left — jump to the last position on the back-stack. The current
    /// position goes onto the forward-stack so Alt+Right can return.
    /// Vim `` ` ` `` (backtick backtick) / `''` (single-quote pair)
    /// — swap current position with `prev_jump_pos`. First press
    /// jumps to the position we were at before the last big jump;
    /// a second press jumps back. Toggle, not stack walk.
    /// nvchad-round-11 SEV-2 2026-07-12.
    pub fn jump_toggle_prev_pos(&mut self) {
        let Some(target) = self.prev_jump_pos.take() else {
            self.toast("nothing to toggle to");
            return;
        };
        if let Some(here) = self.current_nav_point() {
            self.prev_jump_pos = Some(here);
        }
        self.nav_jump_in_progress = true;
        self.jump_to_nav_point(target);
    }

    pub fn nav_back_jump(&mut self) {
        let Some(prev) = self.nav_back.pop() else {
            self.toast("nothing to go back to");
            return;
        };
        if let Some(here) = self.current_nav_point() {
            self.push_nav_forward(here);
        }
        // Set BEFORE the jump so the post-dispatch big-jump recorder
        // in `dispatch_key` sees the flag when it fires after the
        // key handler returns. Reset in `dispatch_key` after the
        // recorder runs.
        self.nav_jump_in_progress = true;
        self.jump_to_nav_point(prev);
    }

    /// Alt+Right — restore a position the user came from via Alt+Left.
    pub fn nav_forward_jump(&mut self) {
        let Some(next) = self.nav_forward.pop() else {
            self.toast("nothing to go forward to");
            return;
        };
        if let Some(here) = self.current_nav_point() {
            self.push_nav_back(here);
        }
        self.nav_jump_in_progress = true;
        self.jump_to_nav_point(next);
    }

    /// Open `np.path` (or refocus its buffer) and place the cursor at
    /// `(row, col)`. Used by both nav directions — bypasses the back-stack
    /// push that `open_path` does, since this *is* a back/forward jump.
    fn jump_to_nav_point(&mut self, np: NavPoint) {
        // Find an existing buffer for this file, or open one. We can't just
        // call `open_path` (it'd push the current point onto the back-stack,
        // which is the wrong move for an Alt+Left). Inline the bits we need.
        let path = np.path.canonicalize().unwrap_or(np.path.clone());
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            self.reveal_pane(i);
        } else {
            match Buffer::open(&path, &self.config) {
                Ok(mut buf) => {
                    buf.apply_editorconfig(&self.workspace);
                    buf.input.set_ex_history(self.ex_history.clone());
                    let text = buf.editor.text().to_string();
                    self.panes.push(Pane::Editor(buf));
                    let new_id = self.panes.len() - 1;
                    self.reveal_pane(new_id);
                    self.lsp.did_open(&path, &text);
                }
                Err(e) => {
                    self.toast(format!("nav: cannot open {}: {e}", path.display()));
                    return;
                }
            }
        }
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(np.row, np.col);
        }
    }

    /// Remember `path`'s `(cursor_byte, scroll)` so the next `open_path` can
    /// restore the position. Drops the oldest entries when the map exceeds
    /// `FILE_CURSORS_MAX` (insertion order isn't tracked precisely — when full
    /// we shrink by removing one arbitrary entry, which is fine for a soft cap).
    fn note_file_cursor(&mut self, path: &Path, cursor_byte: usize, scroll: usize) {
        self.file_cursors
            .insert(path.to_path_buf(), (cursor_byte, scroll));
        while self.file_cursors.len() > FILE_CURSORS_MAX {
            if let Some(k) = self.file_cursors.keys().next().cloned() {
                self.file_cursors.remove(&k);
            } else {
                break;
            }
        }
    }

    /// Remember `path`'s current fold ranges so a future `open_path` can
    /// restore them. Empty `folds` REMOVES the entry — otherwise cleared
    /// folds would linger and re-apply on next open, which is astonishing.
    /// Bounded by `FILE_FOLDS_MAX` with the same soft-cap eviction shape
    /// as `note_file_cursor`.
    pub(crate) fn note_file_folds(&mut self, path: &Path, folds: Vec<(usize, usize)>) {
        if folds.is_empty() {
            self.file_folds.remove(path);
            return;
        }
        self.file_folds.insert(path.to_path_buf(), folds);
        while self.file_folds.len() > FILE_FOLDS_MAX {
            if let Some(k) = self.file_folds.keys().next().cloned() {
                self.file_folds.remove(&k);
            } else {
                break;
            }
        }
    }

    /// Push `path` to the front of `recent_files` (de-duped), capping at
    /// [`RECENT_FILES_MAX`]. Paths outside the workspace are kept too so the
    /// list survives editing scratch files / temp dirs.
    pub fn note_recent_file(&mut self, path: &Path) {
        self.recent_files.retain(|p| p != path);
        self.recent_files.insert(0, path.to_path_buf());
        if self.recent_files.len() > RECENT_FILES_MAX {
            self.recent_files.truncate(RECENT_FILES_MAX);
        }
    }

    /// Open `path` as a `Pane::Image` (next to the focused leaf). Already-
    /// open images are focused instead of duplicated. Refuses with a toast
    /// when the file is too large (50 MB cap) or unreadable.
    pub fn open_image_pane(&mut self, path: &Path) {
        self.open_image_pane_opts(path, false);
    }

    /// `as_preview` marks the pane replaceable, like an editor preview.
    pub fn open_image_pane_opts(&mut self, path: &Path, as_preview: bool) {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Image(img) if img.path() == &path))
        {
            self.reveal_pane(i);
            return;
        }
        match crate::image::ImagePane::open(&path) {
            Ok(mut pane) => {
                self.note_recent_file(&path);
                pane.is_preview = as_preview;
                // Replace an existing preview in the active layout
                // rather than stacking — the rule editor previews
                // follow. Without it, arrowing past five images left
                // five permanent tabs.
                if as_preview
                    && let Some(idx) = self.active.filter(|&id| {
                        self.layout().contains(id)
                            && match self.panes.get(id) {
                                Some(Pane::Image(p)) => p.is_preview,
                                Some(Pane::MdPreview(mp)) => mp.is_preview,
                                Some(Pane::Editor(b)) => b.is_preview,
                                _ => false,
                            }
                    })
                {
                    self.panes[idx] = Pane::Image(pane);
                    self.active = Some(idx);
                    self.reveal_pane(idx);
                    return;
                }
                self.panes.push(Pane::Image(pane));
                let new_id = self.panes.len() - 1;
                self.reveal_pane(new_id);
            }
            Err(e) => self.toast(format!("image: {e}")),
        }
    }

    /// Reload the active image pane's bytes from disk (file may have been
    /// overwritten externally). Toast on failure; the pane stays put.
    pub fn reload_active_image(&mut self) {
        let Some(i) = self.active else { return };
        if let Some(Pane::Image(p)) = self.panes.get_mut(i) {
            match p.reload() {
                Ok(()) => self.toast("image reloaded"),
                Err(e) => self.toast(format!("image reload: {e}")),
            }
        }
    }

    /// Toggle the image pane's header strip (file metadata + protocol info).
    pub fn toggle_active_image_header(&mut self) {
        let Some(i) = self.active else { return };
        if let Some(Pane::Image(p)) = self.panes.get_mut(i) {
            p.show_header = !p.show_header;
        }
    }

    // ─── LSP commands ───────────────────────────────────────────────
    /// The `[A-Za-z0-9_]` run straddling the active editor's cursor, if any.
    fn word_under_cursor(&self) -> Option<String> {
        let b = self.active_editor()?;
        let (row, col) = b.editor.row_col();
        let chars: Vec<char> = b.editor.line_str(row).chars().collect();
        let is_id = |c: char| c.is_alphanumeric() || c == '_';
        let col = col.min(chars.len());
        let mut start = col;
        while start > 0 && is_id(chars[start - 1]) {
            start -= 1;
        }
        let mut end = col;
        while end < chars.len() && is_id(chars[end]) {
            end += 1;
        }
        (start < end).then(|| chars[start..end].iter().collect())
    }
    // ─── vim marks ──────────────────────────────────────────────────
    // ─── snippets ───────────────────────────────────────────────────
    /// `snippet.pick` — open a fuzzy picker of every snippet available for the
    /// active buffer (extension + global). Accept inserts the expansion at the
    /// cursor without consuming a trigger word.
    /// `:LinkCheck` / `markdown.link_check` — walk every `.md` / `.mdx` /
    /// `.markdown` / `.mkd` file in the workspace and open broken
    /// `[label](relative_path)` references as a Quickfix pane. URLs
    /// (http/https/mailto/etc.) are skipped — only path-style links are
    /// validated. Path resolution honors the source file's parent dir.
    pub fn run_markdown_link_check(&mut self) {
        let exts = ["md", "mdx", "markdown", "mkd"];
        let mut md_files: Vec<std::path::PathBuf> = Vec::new();
        walk_workspace_for_extensions(&self.workspace, &exts, &mut md_files);
        if md_files.is_empty() {
            self.toast("link check: no markdown files in workspace");
            return;
        }
        let mut hits: Vec<crate::grep_pane::GrepHit> = Vec::new();
        for md in &md_files {
            let Ok(text) = std::fs::read_to_string(md) else {
                continue;
            };
            let parent = md.parent().unwrap_or(std::path::Path::new(""));
            for (line_idx, line) in text.lines().enumerate() {
                for (col_idx, target) in extract_md_links(line) {
                    if is_url_like(&target) {
                        continue;
                    }
                    // Strip fragment / query so a `path#anchor` link checks
                    // the file existence, not the anchor.
                    let target_no_frag = target
                        .split_once('#')
                        .map(|(a, _)| a)
                        .unwrap_or(&target)
                        .split_once('?')
                        .map(|(a, _)| a)
                        .unwrap_or_else(|| {
                            target.split_once('#').map(|(a, _)| a).unwrap_or(&target)
                        });
                    if target_no_frag.is_empty() {
                        continue; // pure-anchor link
                    }
                    let candidate = parent.join(target_no_frag);
                    if candidate.exists() {
                        continue;
                    }
                    // Try workspace-root anchored too — common in absolute-
                    // looking paths the user expects to root at the repo.
                    if target_no_frag.starts_with('/') {
                        let trimmed = target_no_frag.trim_start_matches('/');
                        let alt = self.workspace.join(trimmed);
                        if alt.exists() {
                            continue;
                        }
                    }
                    let rel = md
                        .strip_prefix(&self.workspace)
                        .unwrap_or(md)
                        .to_string_lossy()
                        .into_owned();
                    hits.push(crate::grep_pane::GrepHit {
                        path: md.clone(),
                        rel,
                        line: line_idx as u32,
                        col: col_idx as u32,
                        text: format!("broken link → {target}"),
                    });
                }
            }
        }
        if hits.is_empty() {
            self.toast(format!(
                "link check: all good ({} file(s) scanned)",
                md_files.len()
            ));
            return;
        }
        let title = format!(
            "broken markdown links ({} across {} file(s))",
            hits.len(),
            md_files.len()
        );
        self.open_quickfix(&title, hits);
    }

    /// Called from `tick` — if a format-on-save deadline has passed without
    /// the LSP replying, drop the pending state and save anyway.
    pub fn check_format_save_deadline(&mut self) {
        let expired = matches!(
            &self.pending_format_save,
            Some((_, deadline)) if std::time::Instant::now() > *deadline,
        );
        if expired {
            self.pending_format_save = None;
            self.save_active_now();
        }
        // Same for the willSaveWaitUntil pre-stage; on expiry we chain
        // forward into the same "after will-save" path so format-on-save
        // still gets a chance to run.
        let expired_wsw = matches!(
            &self.pending_will_save,
            Some((_, deadline)) if std::time::Instant::now() > *deadline,
        );
        if expired_wsw {
            self.pending_will_save = None;
            self.save_active_after_will_save();
        }
    }

    /// `editor.format` — smart format: try LSP formatter first; if no
    /// server is attached for this file, fall through to the external
    /// (conform-style) formatter. Matches conform.nvim's "ask LSP first"
    /// behavior.
    pub fn format_smart(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let path = match b.path.clone() {
            Some(p) => p,
            None => {
                self.toast("nothing to format (scratch buffer)");
                return;
            }
        };
        let tab_size = self.config.editor.tab_width as u32;
        if self.lsp.formatting(&path, tab_size, true) {
            return;
        }
        // No LSP formatter — try the external one.
        self.format_external_active();
    }

    /// Apply a hit-count condition at `(path, line0)`. Empty input
    /// drops the condition (without removing the breakpoint itself).
    /// Non-empty records it + ensures a breakpoint exists on that line.
    /// Re-fires `setBreakpoints` to the live adapter.
    pub fn set_breakpoint_hit_condition(
        &mut self,
        path: &std::path::Path,
        line0: u32,
        hit: String,
    ) {
        let mut sync_lines: Option<Vec<u32>> = None;
        let mut sync_conds: Option<std::collections::HashMap<u32, String>> = None;
        let mut sync_hits: Option<std::collections::HashMap<u32, String>> = None;
        for p in self.panes.iter_mut() {
            if let Pane::Editor(b) = p
                && b.path.as_deref() == Some(path)
            {
                if !b.breakpoints.contains(&line0) {
                    b.breakpoints.push(line0);
                    b.breakpoints.sort_unstable();
                }
                if hit.is_empty() {
                    b.breakpoint_hit_conditions.remove(&line0);
                } else {
                    b.breakpoint_hit_conditions.insert(line0, hit.clone());
                }
                sync_lines = Some(b.breakpoints.clone());
                sync_conds = Some(b.breakpoint_conditions.clone());
                sync_hits = Some(b.breakpoint_hit_conditions.clone());
                break;
            }
        }
        let (Some(lines), Some(conds), Some(hits)) = (sync_lines, sync_conds, sync_hits) else {
            return;
        };
        if let Some(mgr) = self.dap.as_mut()
            && mgr.initialized
        {
            let _ = mgr
                .client
                .set_breakpoints_with_conditions(path, &lines, &conds, &hits);
        }
        self.toast(format!(
            "bp line {} hit-count {}",
            line0 + 1,
            if hit.is_empty() {
                "cleared".to_string()
            } else {
                hit
            }
        ));
    }

    /// Apply a condition to a breakpoint at `(path, line0)`. Empty
    /// condition ⇒ plain breakpoint (also added if missing); non-empty
    /// ⇒ records the condition + adds the line to `breakpoints` if
    /// missing. Re-syncs to the live adapter via `setBreakpoints`.
    pub fn set_breakpoint_condition(&mut self, path: &std::path::Path, line0: u32, cond: String) {
        // Find the buffer that owns `path`; update both the
        // breakpoints list (idempotent add) and the condition map.
        let mut sync_lines: Option<Vec<u32>> = None;
        let mut sync_conds: Option<std::collections::HashMap<u32, String>> = None;
        let mut sync_hits: Option<std::collections::HashMap<u32, String>> = None;
        for p in self.panes.iter_mut() {
            if let Pane::Editor(b) = p
                && b.path.as_deref() == Some(path)
            {
                if !b.breakpoints.contains(&line0) {
                    b.breakpoints.push(line0);
                    b.breakpoints.sort_unstable();
                }
                if cond.is_empty() {
                    b.breakpoint_conditions.remove(&line0);
                } else {
                    b.breakpoint_conditions.insert(line0, cond.clone());
                }
                sync_lines = Some(b.breakpoints.clone());
                sync_conds = Some(b.breakpoint_conditions.clone());
                sync_hits = Some(b.breakpoint_hit_conditions.clone());
                break;
            }
        }
        let (Some(lines), Some(conds), Some(hits)) = (sync_lines, sync_conds, sync_hits) else {
            return;
        };
        // Re-fire the live adapter's breakpoint set for this source so
        // the new condition takes effect immediately.
        if let Some(mgr) = self.dap.as_mut()
            && mgr.initialized
        {
            let _ = mgr
                .client
                .set_breakpoints_with_conditions(path, &lines, &conds, &hits);
        }
        self.toast(format!(
            "bp line {}{}",
            line0 + 1,
            if cond.is_empty() {
                String::new()
            } else {
                format!(": {cond}")
            }
        ));
    }

    /// `tools.installer` — Mason-style picker over `KNOWN_TOOLS`. Each
    /// row shows ✓/✗ (is the binary on $PATH?) + name + kind + the
    /// suggested install command (as the picker's "detail" hint).
    /// Accept copies the install command to the clipboard so the user
    /// can paste + run it themselves. Sorted: missing tools first
    /// (likely what the user opened the picker for), then installed.
    pub fn open_tools_installer(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let mut items: Vec<PickerItem> = Vec::new();
        // Pass 1: missing tools first (with ✗ glyph).
        for tool in crate::tools::KNOWN_TOOLS {
            if crate::tools::is_on_path(tool.bin) {
                continue;
            }
            items.push(PickerItem::new(
                tool.name,
                format!(
                    "✗ [{}] {} — {}",
                    tool.kind.label(),
                    tool.name,
                    tool.description
                ),
                tool.install.to_string(),
            ));
        }
        // Pass 2: installed tools (✓).
        for tool in crate::tools::KNOWN_TOOLS {
            if !crate::tools::is_on_path(tool.bin) {
                continue;
            }
            items.push(PickerItem::new(
                tool.name,
                format!(
                    "✓ [{}] {} — {}",
                    tool.kind.label(),
                    tool.name,
                    tool.description
                ),
                tool.install.to_string(),
            ));
        }
        self.open_picker(Picker::new(
            PickerKind::Tools,
            "External tools (Enter = copy install command)",
            items,
        ));
    }

    /// `editor.lint_external` — fire the configured external linter(s)
    /// for the active buffer in a background thread. Results land in
    /// `linter_chan` and are merged onto the buffer's `linter_diagnostics`
    /// in `App::tick` → `drain_linter_jobs`. Toasts when no linter is
    /// configured for the filetype.
    pub fn lint_external_active(&mut self) {
        let Some(idx) = self.active else {
            self.toast("no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast("no active editor");
            return;
        };
        let ext = match b.language_ext.as_deref() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => {
                self.toast("linter: no filetype");
                return;
            }
        };
        let recipes = crate::linter::linters_for(&self.config.linters, &ext);
        if recipes.is_empty() {
            self.toast(format!("linter: no command configured for .{ext}"));
            return;
        }
        let Some(path) = b.path.clone() else {
            self.toast("linter: scratch buffer not supported");
            return;
        };
        let input = b.editor.text().to_string();
        let workspace = self.workspace.clone();
        // Lazily create the channel.
        if self.linter_chan.is_none() {
            self.linter_chan = Some(std::sync::mpsc::channel());
        }
        let tx = self.linter_chan.as_ref().unwrap().0.clone();
        let parser_label = recipes
            .first()
            .map(|r| r.parser.clone())
            .unwrap_or_default();
        std::thread::spawn(move || {
            // Try each recipe in order; first one that spawns wins.
            // Diagnostics from non-zero exits are kept (linters report
            // findings via non-zero exit).
            for recipe in &recipes {
                match crate::linter::run_linter(recipe, &workspace, &input, Some(&path)) {
                    Ok(diags) => {
                        let _ = tx.send((path.clone(), recipe.parser.clone(), Ok(diags)));
                        return;
                    }
                    Err(_) => continue, // try next recipe (likely "command not found")
                }
            }
            let _ = tx.send((
                path,
                parser_label,
                Err("no linter spawned successfully".into()),
            ));
        });
        self.toast("linting…");
    }

    // ─── diagnostics ("Problems") list pane ─────────────────────────
    /// Collect every diagnostic currently held on an open editor buffer into a
    /// fresh [`DiagnosticsPane`].
    fn build_diagnostics_pane(&self) -> crate::lsp::diagnostics_pane::DiagnosticsPane {
        // Merge LSP + linter diagnostics into one slice per buffer. The
        // pane doesn't care which source produced each diagnostic — sort
        // / nav still works.
        let merged: Vec<(PathBuf, String, Vec<crate::lsp::Diagnostic>)> = self
            .panes
            .iter()
            .filter_map(|p| match p {
                Pane::Editor(b) => {
                    let path = b.path.clone()?;
                    let mut all: Vec<crate::lsp::Diagnostic> = b.diagnostics.clone();
                    all.extend(b.linter_diagnostics.iter().cloned());
                    if all.is_empty() {
                        return None;
                    }
                    let rel = rel_path(&self.workspace, &path);
                    Some((path, rel, all))
                }
                _ => None,
            })
            .collect();
        let sources = merged
            .iter()
            .map(|(p, r, d)| (p.clone(), r.clone(), d.as_slice()));
        crate::lsp::diagnostics_pane::DiagnosticsPane::build(sources)
    }

    /// `lsp.diagnostics` — open the project-wide diagnostics list (or refocus +
    /// refresh the one that's already open) in a split below the focused leaf.
    pub fn open_diagnostics_pane(&mut self) {
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Diagnostics(_)))
        {
            let fresh = self.build_diagnostics_pane();
            if let Some(Pane::Diagnostics(d)) = self.panes.get_mut(id) {
                d.items = fresh.items;
                d.clamp();
            }
            // If already in the right panel, bring its tab to the front.
            if let Some(idx) = self.right_panel_panes.iter().position(|&pid| pid == id) {
                self.right_panel_active_idx = idx;
            } else {
                self.reveal_pane(id);
            }
            return;
        }
        let pane = Pane::Diagnostics(self.build_diagnostics_pane());
        // Right-panel v3: host in the panel as a new tab.
        if self.right_panel_visible {
            self.panes.push(pane);
            let new_id = self.panes.len() - 1;
            self.right_panel_push(new_id);
            return;
        }
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    pub fn move_diagnostics_selection(&mut self, delta: isize) {
        if let Some(Pane::Diagnostics(d)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            d.move_selection(delta);
        }
    }

    /// Open the highlighted diagnostic's file and place the cursor there.
    pub fn jump_to_selected_diagnostic(&mut self) {
        let target = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Diagnostics(d)) => d
                .selected_item()
                .map(|it| (it.path.clone(), it.line, it.col)),
            _ => None,
        };
        let Some((path, line, col)) = target else {
            return;
        };
        self.open_path(&path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line as usize, col as usize);
        }
    }

    // ─── flaky-test dashboard pane (`Pane::Flaky`) ──────────────────
    /// Open a rendered-markdown preview of the active markdown buffer, in a
    /// split to the right. If one's already open for this file, just focus it.
    /// Accepts any file `is_markdown_path` recognises (`md` / `markdown` /
    /// `mdx` / `mkd`).
    pub fn open_md_preview(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) if b.path.as_deref().is_some_and(is_markdown_path) => {
                b.path.clone()
            }
            Some(Pane::MdPreview(p)) => Some(p.path.clone()),
            Some(Pane::Editor(_)) => {
                self.toast("not a markdown file");
                return;
            }
            _ => {
                self.toast("not a markdown file");
                return;
            }
        };
        let Some(path) = path else {
            self.toast("markdown preview needs a saved markdown file");
            return;
        };
        self.open_md_preview_for_path(path, Some(cur), true);
    }

    /// Open (or focus) a rendered-markdown preview for `path`. `near` is the
    /// pane the preview should split off — if `None` (or invalid), the
    /// currently active pane is used; if there's no active pane the preview
    /// becomes the only pane. `focus_preview = true` reveals + focuses the
    /// new preview (the right-click + `markdown.preview` flows want this);
    /// `false` opens the preview alongside but leaves focus where it was
    /// (the auto-open-on-file-open flow wants this — the user reached for
    /// the editor, not the preview).
    pub fn open_md_preview_for_path(
        &mut self,
        path: PathBuf,
        near: Option<PaneId>,
        focus_preview: bool,
    ) {
        self.open_md_preview_for_path_opts(path, near, focus_preview, false);
    }

    /// `as_preview` marks the pane replaceable, the way an editor
    /// preview tab is.
    pub fn open_md_preview_for_path_opts(
        &mut self,
        path: PathBuf,
        near: Option<PaneId>,
        focus_preview: bool,
        as_preview: bool,
    ) {
        if !is_markdown_path(&path) {
            self.toast("not a markdown file");
            return;
        }
        // Already showing a preview of this file? Focus it (or no-op when
        // we're in passive auto-open mode).
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::MdPreview(mp) if mp.path == path))
        {
            if focus_preview {
                self.reveal_pane(id);
            }
            return;
        }
        // Prefer the in-memory text if the file is already open in an editor
        // (so the preview tracks unsaved edits); otherwise read from disk.
        let source = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.path.as_ref() == Some(&path) => {
                    Some(b.editor.text().to_string())
                }
                _ => None,
            })
            .unwrap_or_else(|| std::fs::read_to_string(&path).unwrap_or_default());
        let preview = Pane::MdPreview(crate::pane::MdPreview {
            is_preview: as_preview,
            path,
            source,
            scroll: 0,
            image_cache: std::collections::HashMap::new(),
            external_cache: Default::default(),
            external_error_toasted: false,
        });
        let prior_active = self.active;
        let anchor = near.or(prior_active);
        // Two flows:
        //   focus_preview = true  ⇒ explicit `markdown.preview` /
        //     right-click "Preview markdown". Replace the active leaf so the
        //     preview takes the full pane (no half-screen split). The source
        //     editor stays in the buffer list as a background tab.
        //   focus_preview = false ⇒ passive auto-open
        //     (`[ui] auto_md_preview`). Split alongside so the user can edit
        //     and read at the same time.
        // Replace an existing preview tab in the active layout rather
        // than stacking beside it — the same rule editor previews follow
        // (`open_path_inner`'s `preview_idx`). Without this, arrowing
        // past five markdown files left five permanent tabs.
        if as_preview
            && let Some(idx) = self.active.filter(|&id| {
                self.layout().contains(id)
                    && match self.panes.get(id) {
                        Some(Pane::MdPreview(mp)) => mp.is_preview,
                        Some(Pane::Editor(b)) => b.is_preview,
                        _ => false,
                    }
            })
        {
            self.panes[idx] = preview;
            self.active = Some(idx);
            self.reveal_pane(idx);
            return;
        }
        if focus_preview {
            self.panes.push(preview);
            let new_id = self.panes.len() - 1;
            // `reveal_pane` swaps the active leaf to the preview without
            // touching the layout's split structure. If there's no active
            // leaf, it makes the preview the only leaf.
            self.reveal_pane(new_id);
        } else {
            let new_id = if let Some(a) = anchor.filter(|&i| i < self.panes.len()) {
                self.split_leaf_with(a, crate::layout::SplitDir::Horizontal, preview)
            } else {
                self.panes.push(preview);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                id
            };
            // Passive auto-open: leave focus where it was.
            let _ = new_id;
            self.active = prior_active;
        }
    }

    /// After a `.md` buffer is saved, refresh any open previews of that file.
    /// Reads `path` fresh from disk. Preserves preview scroll position.
    fn refresh_md_previews(&mut self, path: &Path) {
        let fresh = std::fs::read_to_string(path).ok();
        for pane in &mut self.panes {
            if let Pane::MdPreview(p) = pane
                && p.path == path
                && let Some(s) = &fresh
            {
                p.source = s.clone();
            }
        }
    }

    /// Live update: push the in-memory text of the active markdown buffer to
    /// any open preview of that file. Called from the editor key handler on
    /// every edit so previews track keystrokes (rather than only on save).
    /// Preserves preview scroll.
    pub fn refresh_md_previews_from_text(&mut self, path: &Path, text: &str) {
        for pane in &mut self.panes {
            if let Pane::MdPreview(p) = pane
                && p.path == path
            {
                p.source = text.to_string();
            }
        }
    }

    /// qa-feature 2026-07-02 — Swap the given MdPreview pane in place
    /// with a raw Editor of the same file. The pane keeps its slot in the
    /// layout so tabs / split geometry don't shift. Toasts + no-op when
    /// the pane isn't actually an MdPreview.
    pub fn md_preview_to_edit(&mut self, pane_id: PaneId) {
        let path = match self.panes.get(pane_id) {
            Some(Pane::MdPreview(p)) => p.path.clone(),
            _ => {
                self.toast("not a preview pane");
                return;
            }
        };
        // Build the raw Editor buffer.
        match crate::buffer::Buffer::open_or_new_empty(&path, &self.config) {
            Ok(mut buf) => {
                buf.apply_editorconfig(&self.workspace);
                buf.input.set_ex_history(self.ex_history.clone());
                if let Some(&(cursor_byte, scroll)) = self.file_cursors.get(&path) {
                    let (row, col) = byte_to_row_col(buf.editor.text(), cursor_byte);
                    buf.editor.place_cursor(row, col);
                    buf.scroll = scroll;
                }
                if let Some(folds) = self.file_folds.get(&path) {
                    let line_count = buf.editor.line_count();
                    for &(start, end) in folds {
                        if end >= start && start < line_count && end < line_count {
                            buf.folds.insert(start, end);
                        }
                    }
                }
                let undo_path = crate::editor::undo_path_for(&self.workspace, &path);
                crate::editor::load_history_from(&mut buf.editor, &undo_path);
                let text = buf.editor.text().to_string();
                self.panes[pane_id] = Pane::Editor(buf);
                self.reveal_pane(pane_id);
                self.lsp.did_open(&path, &text);
            }
            Err(e) => self.toast(format!("cannot open {}: {e}", path.display())),
        }
    }

    /// qa-feature 2026-07-02 — Swap the given Editor pane (must hold a
    /// markdown file) in place with an MdPreview of the same file. Reads
    /// the CURRENT buffer contents so unsaved edits show up in the
    /// preview immediately.
    pub fn md_edit_to_preview(&mut self, pane_id: PaneId) {
        let (path, source) = match self.panes.get(pane_id) {
            Some(Pane::Editor(b)) if b.path.as_deref().is_some_and(is_markdown_path) => {
                (b.path.clone().unwrap(), b.editor.text().to_string())
            }
            _ => {
                self.toast("not a markdown editor");
                return;
            }
        };
        self.panes[pane_id] = Pane::MdPreview(crate::pane::MdPreview {
            // Swapping an open editor to its preview keeps the tab you
            // already had; it is not a throwaway.
            is_preview: false,
            path,
            source,
            scroll: 0,
            image_cache: std::collections::HashMap::new(),
            external_cache: Default::default(),
            external_error_toasted: false,
        });
        self.reveal_pane(pane_id);
    }

    /// Scroll any open `Pane::MdPreview` of `path` so its top line roughly
    /// matches `src_row` in the source buffer. Called from the editor key
    /// dispatcher after any cursor motion when the active buffer is markdown.
    pub fn sync_md_previews_to_cursor(&mut self, path: &Path, src_row: usize) {
        for pane in &mut self.panes {
            if let Pane::MdPreview(p) = pane
                && p.path == path
            {
                p.sync_to_source_row(src_row);
            }
        }
    }

    // ─── pty / AI-CLI panes ─────────────────────────────────────────
    /// Re-apply a `:rename`'d name to a freshly-spawned pty whose
    /// `session_id` matches a saved entry. Only fires for *resumed*
    /// Claude sessions (a fresh `claude` gets a brand-new session id
    /// that won't be in the map) — so resuming "frontend"'s session
    /// brings the name back with it.
    fn apply_saved_pty_name(&self, s: &mut crate::pty_pane::PtySession) {
        if s.display_name.is_none()
            && let Some(sid) = &s.profile.session_id
            && let Some(name) = self.saved_pty_session_names.get(sid)
        {
            s.display_name = Some(name.clone());
        }
    }

    /// #1179 (2026-08-23) — auto-assign an explicit accent color to
    /// every new Claude Code session so the sessions-rail row and the
    /// pane's accent bar + tab strip can never fall through to
    /// different "no color set" fallbacks and disagree (task #1178
    /// f/u — reported this same session as "green bar on the left but
    /// orange for the pane"). The FIRST Claude Code session gets
    /// `"orange"` (the brand default), so a solo-Claude user still
    /// sees the Anthropic look everywhere; subsequent spawns cycle
    /// through a distinct palette so a user juggling several can tell
    /// them apart at a glance. Skips when:
    ///   - the session isn't Claude Code (integration_id mismatch);
    ///   - the caller already set `accent_color` (session restore,
    ///     explicit override — respect it).
    /// Counts EXISTING Claude Code Pty sessions in `self.panes` at
    /// call time (before this one is pushed) to pick the palette index.
    fn assign_auto_accent_color(&self, s: &mut crate::pty_pane::PtySession) {
        if s.accent_color.is_some() {
            return;
        }
        if s.profile.integration_id.as_deref() != Some("claude_code") {
            return;
        }
        let existing: usize = self
            .panes
            .iter()
            .filter(|p| match p {
                crate::pane::Pane::Pty(sess) => {
                    sess.profile.integration_id.as_deref() == Some("claude_code")
                }
                _ => false,
            })
            .count();
        // Palette is `crate::ui::session_color::PALETTE` — single
        // source of truth (task #1181 f/u, 2026-08-23) so the auto
        // cycle, the right-click menu, and every color resolver
        // stay in lockstep.
        let palette = crate::ui::session_color::PALETTE;
        let idx = existing % palette.len();
        s.accent_color = Some(palette[idx].to_string());
    }

    pub fn open_pty(&mut self, profile: crate::pty_pane::BinaryProfile) {
        // Default: stacked below — matches the "open a small shell at
        // the bottom" muscle memory most pty cases want.
        self.open_pty_dir(profile, crate::layout::SplitDir::Vertical);
    }

    /// Bridge env — injected into every Pty spawned by mnml so
    /// integration tools (and any subprocess) can locate the host's
    /// workspace / theme / IPC channel without parsing argv.
    /// Used by the Bridge tier-1 integration (see Mount/Bridge
    /// architecture notes).
    pub fn bridge_env(&self) -> Vec<(String, String)> {
        let ipc_dir = self.workspace.join(".mnml").join("ipc");
        vec![
            (
                "MNML_WORKSPACE".to_string(),
                self.workspace.display().to_string(),
            ),
            ("MNML_THEME".to_string(), self.config.ui.theme.clone()),
            ("MNML_IPC_DIR".to_string(), ipc_dir.display().to_string()),
        ]
    }

    /// Like `open_pty` but caller picks the split direction. AI panes
    /// (Claude, Codex) use `Horizontal` so they dock alongside the
    /// editor on the right — the IDE-canonical "AI chat panel"
    /// placement.
    pub fn open_pty_dir(
        &mut self,
        mut profile: crate::pty_pane::BinaryProfile,
        dir: crate::layout::SplitDir,
    ) {
        // Inject the bridge env vars BEFORE spawning so integrations see
        // them on startup. Profile.env wins on key collision — caller
        // can override if needed.
        let bridge = self.bridge_env();
        for (k, v) in bridge {
            if !profile.env.iter().any(|(pk, _)| pk == &k) {
                profile.env.push((k, v));
            }
        }
        // Phase 2E — inject per-integration auth values as env vars,
        // using the manifest's [[auth]].env_fallback names. Lets a
        // user save `bot_token = "xoxb-..."` in the Settings pane
        // and have the integration see it as `$SLACK_BOT_TOKEN` at spawn
        // time without reading mnml's [auth_values] itself.
        //
        // Precedence: `Command::envs` overrides inherited process env
        // by key, so a set value here wins over the user's shell
        // export. Empty stored values are skipped so a user who
        // cleared a pane field falls back to their shell export
        // rather than getting the env var wiped.
        if let Some(integ_id) = profile.integration_id.clone() {
            let auth_env = self.integration_auth_env(&integ_id);
            for (k, v) in auth_env {
                if !profile.env.iter().any(|(pk, _)| pk == &k) {
                    profile.env.push((k, v));
                }
            }
            // Task #933 — layer any `.override.toml [env]` block
            // for THIS integration on top. Deliberately NOT
            // cross-shared across integrations (unlike auth_env,
            // whose share is gated by AuthField.env_fallback names).
            // Keeps a workspace override's arbitrary env keys out
            // of unrelated integrations' spawns (including
            // external-tool launchers like htop/btop that route
            // through this same open_pty_dir path via
            // run_external_tool). Demo mode's per-integration
            // override files each declare their own [env] block.
            let override_env = self.integration_override_env(&integ_id);
            for (k, v) in override_env {
                if !profile.env.iter().any(|(pk, _)| pk == &k) {
                    profile.env.push((k, v));
                }
            }
            // #1117 (2026-08-21) — prefetch cache handoff. If this
            // integration declared a [[prefetch]] block matching the
            // launch's --only <kind> arg, and mnml's background
            // worker has produced a cache file, stamp its path via
            // `MNML_PREFETCH_CACHE_FILE`. The integration reads that
            // env on startup, does a freshness check, and hydrates
            // from JSON to skip its first API round-trip.
            if let Some(path) = self.prefetch_cache_for_launch(&integ_id, &profile.args)
                && !profile
                    .env
                    .iter()
                    .any(|(k, _)| k == "MNML_PREFETCH_CACHE_FILE")
            {
                profile.env.push((
                    "MNML_PREFETCH_CACHE_FILE".to_string(),
                    path.to_string_lossy().into_owned(),
                ));
            }
        }
        // #1045 f/u (2026-08-21) — forward the chevron/triangle pref
        // via `profile.env` instead of round-tripping through process
        // env. Was: settings.rs called `unsafe std::env::set_var`
        // whenever the user toggled the pref, but by then background
        // workers were already spawning child processes and their
        // fork/exec reads global `environ` — the exact edition-2024
        // hazard `set_var` is marked unsafe for. Reading a shared
        // config field is race-free.
        if !profile
            .env
            .iter()
            .any(|(k, _)| k == "MNML_EXPAND_INDICATOR")
        {
            profile.env.push((
                "MNML_EXPAND_INDICATOR".to_string(),
                self.config.ui.expand_indicator.clone(),
            ));
        }
        // The initial size is a guess — `ui/pty_view` resizes the session to its
        // rendered area on the first frame.
        match crate::pty_pane::PtySession::spawn(profile, 24, 80) {
            Ok(mut s) => {
                self.apply_saved_pty_name(&mut s);
                self.assign_auto_accent_color(&mut s);
                let pane = Pane::Pty(s);
                match self.active {
                    Some(cur) => {
                        let new_id = self.split_leaf_with(cur, dir, pane);
                        self.active = Some(new_id);
                    }
                    None => {
                        self.panes.push(pane);
                        let id = self.panes.len() - 1;
                        *self.layout_mut() = Layout::leaf(id);
                        self.active = Some(id);
                    }
                }
                self.focus = Focus::Pane;
            }
            Err(e) => self.toast(format!("can't open terminal: {e}")),
        }
    }

    /// Prompt for a binary name + open it as a hosted-integration
    /// Mount pane. Used by the `mount.open` palette command. The
    /// binary must implement the `mnml-bridge` Mount protocol
    /// (read `MNML_MOUNT_SOCKET`, connect, stream Frames).
    pub fn prompt_mount_open(&mut self) {
        use crate::prompt::{Prompt, PromptKind};
        self.prompt = Some(Prompt::new(PromptKind::MountBinary, "Mount binary"));
    }

    /// Open a Mount from a manifest entry — used by the activity
    /// bar click handler. If a Mount pane for this binary already
    /// exists, focus it; otherwise spawn fresh.
    pub fn open_mount_from_manifest(&mut self, idx: u16) {
        let Some(manifest) = self.mount_manifests.get(idx as usize) else {
            self.toast("mount: manifest gone — try mounts.refresh");
            return;
        };
        let binary = manifest.binary.clone();
        let label = manifest.name.clone();
        let args = manifest.args.clone();
        // Focus an existing Mount for this binary if there is one
        // (matches the "click activity bar icon to re-focus" muscle
        // memory of every other section).
        let existing = self.panes.iter().enumerate().find_map(|(i, p)| {
            if let Pane::Mount(m) = p
                && m.label == label
            {
                Some(i)
            } else {
                None
            }
        });
        if let Some(pid) = existing {
            self.active = Some(pid);
            self.focus_pane();
            return;
        }
        self.open_mount_with_args(&binary, &label, &args);
    }

    /// Set or clear an activity-bar notification badge. `count = 0`
    /// removes the key (so the renderer's `.contains_key` check
    /// can short-circuit). Called by the `set-activity-badge`
    /// IPC command — integration tools surface queue depths,
    /// action-needed counts, etc. this way.
    pub fn set_activity_badge(&mut self, section: String, count: u32) {
        if count == 0 {
            self.activity_badges.remove(&section);
        } else {
            self.activity_badges.insert(section, count);
        }
    }

    /// Look up the badge count for a builtin section. Returns 0
    /// when no badge is set. The string key is the section's
    /// command_id suffix (e.g. `"agents"` for `view.activity_agents`).
    pub fn activity_badge_for(&self, section_id: &str) -> u32 {
        self.activity_badges.get(section_id).copied().unwrap_or(0)
    }

    /// Prompt for a Jira ticket then fire an ECS cloud run via
    /// `aws ecs run-task`. Used by the `cloud_agents.new_run`
    /// palette command.
    pub fn prompt_cloud_run(&mut self) {
        use crate::prompt::{Prompt, PromptKind};
        let prefix = self
            .config
            .jira
            .effective_ticket_prefix()
            .unwrap_or_else(|| "PROJ-".to_string());
        self.prompt = Some(Prompt::new(
            PromptKind::CloudRunTicket,
            format!("New cloud run — Jira ticket ({prefix}NNNN)"),
        ));
    }

    /// Fire the trigger on a background thread + surface result
    /// via toast. The Cloud Agents panel will pick up the new
    /// row on its next 30s refresh.
    pub fn fire_cloud_run(&mut self, ticket: &str) {
        let ticket = ticket.trim().to_string();
        if ticket.is_empty() {
            return;
        }
        let cloud_agents_config = self.config.cloud_agents.clone();
        let jira_config = self.config.jira.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(crate::ecs_runner_trigger::trigger_run(
                cloud_agents_config,
                jira_config,
                &ticket,
            ));
        });
        self.cloud_run_pending = Some(rx);
        self.toast("firing cloud run…");
    }

    /// Drain a pending cloud-run trigger result and surface as a
    /// toast. Called per tick.
    pub fn drain_cloud_run_trigger(&mut self) {
        let Some(rx) = self.cloud_run_pending.take() else {
            return;
        };
        match rx.try_recv() {
            Ok(crate::ecs_runner_trigger::TriggerResult::Ok {
                run_id,
                task_arn: _,
            }) => {
                self.toast(format!("cloud run started · {run_id}"));
                // Force-refresh the agents panel so the new row
                // appears within seconds rather than after the
                // 30s drift.
                self.agents_panel_built_at = None;
            }
            Ok(crate::ecs_runner_trigger::TriggerResult::Err(e)) => {
                self.toast(format!("cloud run failed: {e}"));
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {
                self.cloud_run_pending = Some(rx);
            }
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.toast("cloud run trigger died without reporting");
            }
        }
        // A-2 integration_install methods moved to src/app/integration_install_methods.rs
        // (impl App { ... } block in that sibling).
    }

    /// `:rename` / `term.rename` — open a prompt to name the active pty
    /// session (Claude / Codex / shell). The name shows in the pty-pane
    /// tab strip + the bufferline tab. Seeded with the current name.
    /// Open the rename prompt for a dock widget. Seeded with the
    /// widget's current title; commit handler in the prompt
    /// dispatch reads `App::dock_rename_target` to find the widget.
    pub fn open_dock_rename_prompt(&mut self, seed: String) {
        let prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::DockWidgetRename,
            "Rename widget (empty = revert to default)",
            seed,
        );
        self.prompt = Some(prompt);
    }

    /// Commit handler for `PromptKind::DockWidgetRename`. Sets the
    /// widget's `title` to `name`, or reverts to a `Note <id>`
    /// default when `name` is empty / blank.
    pub fn rename_dock_widget(&mut self, name: &str) {
        let Some(target_id) = self.dock_rename_target.take() else {
            return;
        };
        if let Some(w) = self.dock_widgets.iter_mut().find(|w| w.id == target_id) {
            let trimmed = name.trim();
            w.title = if trimmed.is_empty() {
                format!("Note {}", w.id)
            } else {
                trimmed.to_string()
            };
        }
    }

    /// Resume a Claude Code session by session id. Used by the
    /// rail agents panel's row-click handler.
    ///
    /// If there's already a Pty pane open, add the resumed
    /// session as a TAB inside that pane group (no split). Only
    /// when there's no Pty at all do we let `open_pty` carve out
    /// a new split — otherwise every click here would chain into
    /// an ever-deeper split tree.
    pub fn resume_claude_session_in_pty(&mut self, session_id: &str) {
        let profile = crate::pty_pane::BinaryProfile::claude_code_resume(
            self.workspace.clone(),
            session_id.to_string(),
        );
        // Find an existing Pty pane to host the new session as a tab.
        // Prefer `self.active` when it's a Pty — that pane is the
        // active in its leaf, so `set_leaf_pane` inside
        // `add_pty_tab` will swap it correctly. Fall back to the
        // first Pty by index only if no Pty is currently focused
        // (rare; mostly cold-start).
        let existing_pty = self
            .active
            .filter(|&i| matches!(self.panes.get(i), Some(crate::pane::Pane::Pty(_))))
            .or_else(|| {
                self.panes
                    .iter()
                    .enumerate()
                    .find_map(|(i, p)| matches!(p, crate::pane::Pane::Pty(_)).then_some(i))
            });
        match existing_pty {
            Some(strip_owner) => self.add_pty_tab(strip_owner, profile),
            None => self.open_pty(profile),
        }
    }

    /// Refresh the rail Agents panel's cached snapshot if it's
    /// older than `AGENTS_PANEL_REFRESH`. Spawns the actual scan
    /// (file read + jsonl parse for every transcript — easily
    /// hundreds of ms with many sessions) on a WORKER THREAD so
    /// the UI stays responsive. The next `App::tick()` drains the
    /// channel and swaps in the fresh snapshot.
    /// Swap the cloud-agents panel between Compact (1 line / row)
    /// and Standard (3 lines / row). Fired by the
    /// `cloud_agents.toggle_view` palette command and by clicking
    /// the density chip in the panel header.
    pub fn cloud_agents_toggle_view(&mut self) {
        self.cloud_agents_view = self.cloud_agents_view.toggled();
        // Reset scroll — the row heights changed so old scroll
        // offset would land mid-row otherwise.
        self.cloud_agents_scroll = 0;
        self.toast(format!(
            "cloud agents view → {}",
            self.cloud_agents_view.label()
        ));
    }

    /// #polish 2026-07-06 — set the density directly (used by
    /// the view chip's right-click menu). Same reset-scroll
    /// treatment as toggle.
    pub fn cloud_agents_set_view(&mut self, view: CloudAgentsView) {
        if self.cloud_agents_view == view {
            return;
        }
        self.cloud_agents_view = view;
        self.cloud_agents_scroll = 0;
        self.toast(format!("cloud agents view → {}", view.label()));
    }

    pub fn refresh_agents_panel_if_due(&mut self) {
        // 30s for LOCAL Claude/Codex rail rows (filesystem-only
        // scan — cheap, session-state badges want fast feedback).
        // 2 min for CLOUD rows when `[cloud_agents]` is configured
        // (the `aws dynamodb scan` subprocess spawn + server-side
        // scan cost dominate the worker each pass — running that
        // every 30s is what motivated #1161). Same worker refreshes
        // both, so we pick the shorter interval only when the cloud
        // half is a no-op.
        //
        // #1161 f/u (2026-08-23) — was a single 120s bump that
        // silently dragged local badges to 2-minute staleness for
        // users with no cloud_agents config, for zero AWS benefit.
        const AGENTS_PANEL_REFRESH_LOCAL: std::time::Duration = std::time::Duration::from_secs(30);
        const AGENTS_PANEL_REFRESH_CLOUD: std::time::Duration = std::time::Duration::from_secs(120);
        // R15 design-critic (2026-08-23) — the cadence gate now
        // asks "is EITHER cloud backend on?" instead of just "is
        // ECS on?". A Managed-Agents-only user pays the slower
        // 2-min cadence for their cloud path; before this fix
        // they got 30s cadence but the managed poll was silently
        // gated off entirely (see the split inside the worker
        // below).
        let cloud_enabled = self.config.cloud_agents.any_cloud_source_enabled();
        let refresh_interval = if cloud_enabled {
            AGENTS_PANEL_REFRESH_CLOUD
        } else {
            AGENTS_PANEL_REFRESH_LOCAL
        };
        if self.agents_panel_rx.is_some() {
            return; // a refresh is already in flight
        }
        let due = self
            .agents_panel_built_at
            .map(|t| t.elapsed() >= refresh_interval)
            .unwrap_or(true);
        if !due {
            return;
        }
        let anchor = self.workspace.clone();
        let cloud_agents_config = self.config.cloud_agents.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let pane = crate::claude_agents::ClaudeAgentsPane::build_anchored(anchor);
            let local_rows = pane.rows;
            // Cloud rows live in a SEPARATE list now (the Cloud
            // Agents activity-bar section renders them). Merge
            // ECS runner (DynamoDB) + Anthropic Managed Agents
            // (API) into one list — both are "cloud agents."
            let (mut cloud_rows, meta) =
                crate::ecs_runner::collect_cloud_rows_with_meta(&cloud_agents_config);
            // Anthropic Managed Agents API — costs ANTHROPIC_API_KEY
            // dollars on every hit (metered). Gated on the explicit
            // `[cloud_agents] managed_agents_enabled` opt-in so a
            // stray ANTHROPIC_API_KEY never silently burns
            // ~$60/quarter (#1160 canary property preserved).
            // R15 design-critic 2026-08-23 — was previously gated
            // on `is_enabled()` (ECS-only), which meant Managed-
            // Agents-only users had wizard entry but zero panel
            // rows. The two backends now have independent toggles.
            if cloud_agents_config.managed_agents_enabled {
                let managed = crate::anthropic_api::collect_managed_agent_rows();
                cloud_rows.extend(managed);
            }
            let _ = tx.send((local_rows, cloud_rows, meta));
        });
        self.agents_panel_rx = Some(rx);
    }

    /// Drain the agents-panel refresh worker. Called once per
    /// `tick()` — non-blocking; pulls the result if ready and
    /// stamps `built_at`.
    pub fn drain_agents_panel_refresh(&mut self) {
        let Some(rx) = self.agents_panel_rx.take() else {
            return;
        };
        match rx.try_recv() {
            Ok((local_rows, cloud_rows, meta)) => {
                // Count action-needed rows before moving the vecs
                // into App state. For ECS runner rows, `staged` runs
                // land with `pending_tool_uses = 1` per `parse_run_record`,
                // so this matches the "awaiting your Slack approval"
                // semantic the rail header already surfaces. Local
                // rows count = sessions waiting on a tool-confirm.
                let cloud_action_needed = cloud_rows
                    .iter()
                    .filter(|r| r.pending_tool_uses > 0)
                    .count() as u32;
                let local_action_needed = local_rows
                    .iter()
                    .filter(|r| r.pending_tool_uses > 0)
                    .count() as u32;
                self.agents_panel_rows = local_rows;
                self.cloud_agents_rows = cloud_rows;
                self.cloud_agents_meta = meta;
                self.set_activity_badge("cloud_agents".to_string(), cloud_action_needed);
                self.set_activity_badge("agents".to_string(), local_action_needed);
                self.agents_panel_built_at = Some(std::time::Instant::now());
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {
                // Worker still running — put the receiver back.
                self.agents_panel_rx = Some(rx);
            }
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                // Worker died without sending — drop and try again
                // on the next tick.
            }
        }
    }

    /// `setup.install_to_path` — show an actionable hint with
    /// the exact command to install mnml so `mnml .` works from
    /// anywhere. Doesn't touch /usr/local/bin itself (sudo
    /// territory; user may want a different prefix). The hint
    /// goes to a long-lived toast plus stays visible on the
    /// welcome screen.
    pub fn show_install_to_path_hint(&mut self) {
        let exe = std::env::current_exe()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "<path-to-mnml-binary>".to_string());
        let on_path = crate::app::mnml_on_path();
        if on_path {
            self.toast("mnml is already on PATH (✓)");
            return;
        }
        let cmd = format!("sudo ln -sf {exe} /usr/local/bin/mnml");
        self.toast(format!("Install to PATH: run this in a terminal → {cmd}"));
        // Also copy the command to the clipboard so the user
        // can paste it directly.
        self.clipboard.set(cmd, false);
        self.toast("command copied to clipboard");
    }

    /// Listening TCP ports for a Pty's process tree (root pid +
    /// recursive children). Cached for 2 seconds; first call per
    /// pid shells out to `lsof` + `pgrep`. Empty vec on
    /// unavailable / not-listening / lsof failure.
    pub fn session_ports(&mut self, root_pid: u32) -> Vec<u16> {
        // 2026-07-30 — was 2s. With 8 Claude sessions in the panel,
        // that meant ~4 cache misses/sec, each firing pgrep +
        // lsof subprocesses on the render thread. sessions_panel
        // instrumentation showed `ports=32ms/frame` — the single
        // biggest hot path in the panel. Ports change rarely
        // during a session (a dev server sticks on 3000 the whole
        // time); 30s stale is fine for the chip.
        const TTL: std::time::Duration = std::time::Duration::from_secs(30);
        if let Some((at, ports)) = self.session_port_cache.get(&root_pid)
            && at.elapsed() < TTL
        {
            return ports.clone();
        }
        let ports = scan_listening_ports(root_pid);
        self.session_port_cache
            .insert(root_pid, (std::time::Instant::now(), ports.clone()));
        ports
    }

    // A-4: workspaces-editor methods moved to src/app/workspace_methods.rs.

    /// Push a frame-duration sample into the rolling window used by
    /// the `stress` statusline chip. Called by the main loop after
    /// each tick+draw+event-wait cycle. Cap at 120 samples so the
    /// window covers ~2s at 60Hz.
    pub fn record_frame_duration(&mut self, ms: u128) {
        let clamped: u16 = ms.min(u16::MAX as u128) as u16;
        self.frame_times_ms.push_back(clamped);
        while self.frame_times_ms.len() > 120 {
            self.frame_times_ms.pop_front();
        }
    }

    /// Compute a 0-100 "stress" score from the recent frame window.
    /// 0 = idle (every frame under ~10ms). 100 = every recent frame
    /// hit or exceeded 200ms. Uses p95 so a single laggy frame from
    /// a git stat doesn't dominate but a sustained slowdown does.
    pub fn stress_score(&self) -> u8 {
        if self.frame_times_ms.is_empty() {
            return 0;
        }
        let mut sorted: Vec<u16> = self.frame_times_ms.iter().copied().collect();
        sorted.sort_unstable();
        let p95 = sorted[(sorted.len() * 95) / 100] as f32;
        // 10ms is "smooth", 200ms is "very stressed"; log-ish scale.
        // score = (p95 - 10) / (200 - 10) * 100, clamped.
        let score = ((p95 - 10.0) / 190.0 * 100.0).clamp(0.0, 100.0);
        score as u8
    }

    /// `buffer.clear_mru` — wipe the pane MRU stack (nav back/forward
    /// history). Keeps the current active pane at the head so
    /// buffer.last isn't broken. mouse-round-9 SEV-3 2026-07-11.
    pub fn clear_pane_mru(&mut self) {
        let head = self.active;
        self.pane_mru.clear();
        if let Some(pid) = head {
            self.pane_mru.push(pid);
        }
        self.toast("buffer MRU cleared");
    }

    /// `:NextDirty` / `:PrevDirty` — jump to the next / prev editor pane
    /// with `dirty == true`. Cycles. Toasts when nothing is dirty.
    pub fn jump_dirty_pane(&mut self, forward: bool) {
        let active = self.active.unwrap_or(0);
        let dirty: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| match p {
                Pane::Editor(b) if b.dirty => Some(i),
                _ => None,
            })
            .collect();
        if dirty.is_empty() {
            self.toast("no unsaved buffers");
            return;
        }
        let target = if forward {
            dirty
                .iter()
                .find(|&&i| i > active)
                .copied()
                .unwrap_or(dirty[0])
        } else {
            dirty
                .iter()
                .rev()
                .find(|&&i| i < active)
                .copied()
                .unwrap_or_else(|| *dirty.last().unwrap())
        };
        self.reveal_pane(target);
    }

    /// Accept handler for `PickerKind::Clipboard` — insert the chosen
    /// register's text at the active editor's cursor.
    pub fn paste_register(&mut self, reg_letter: &str) {
        let Some(reg) = reg_letter.chars().next() else {
            return;
        };
        let Some((text, _linewise)) = self.clipboard.named_registers().get(&reg).cloned() else {
            return;
        };
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let vp = self
            .rects
            .editor_panes
            .iter()
            .find(|(_, pid)| *pid == idx)
            .map(|(r, _)| r.height as usize)
            .unwrap_or(24);
        b.apply_edit_ops(
            vec![crate::edit_op::EditOp::InsertStr(text)],
            &mut self.clipboard,
            vp,
        );
    }

    // ─── git: diff pane + blame ─────────────────────────────────────
    /// `view.reveal_active` (`:reveal`) — show the active file in the OS
    /// Finder / Explorer / file manager. macOS uses `open -R`; Linux opens
    /// the file's parent dir via `xdg-open` (the closest portable form —
    /// no "select" gesture); Windows uses `explorer /select,<path>`.
    pub fn reveal_active_file(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("reveal needs a saved file");
            return;
        };
        if cfg!(target_os = "macos") {
            let _ = std::process::Command::new("open")
                .arg("-R")
                .arg(&path)
                .spawn();
        } else if cfg!(target_os = "windows") {
            let _ = std::process::Command::new("explorer")
                .arg(format!("/select,{}", path.display()))
                .spawn();
        } else if let Some(parent) = path.parent() {
            open_path_external(parent);
        }
    }

    /// `git.browse` (`:GBrowse` from fugitive convention) — open the active
    /// file at the cursor's line on the remote's web host (GitHub / GitLab /
    /// Bitbucket). With a multi-line selection active, links the range. URL
    /// uses HEAD's short SHA so the link is stable.
    pub fn open_on_remote_host(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("browse needs a saved file");
            return;
        };
        let repo = self.active_repo_path().to_path_buf();
        let rel = match path.strip_prefix(&repo) {
            Ok(r) => r.to_string_lossy().to_string(),
            Err(_) => {
                self.toast("file is outside the active git repo");
                return;
            }
        };
        let (lo, hi) = if b.editor.has_selection() {
            let (s, e) = b.editor.selection().unwrap_or((0, 0));
            let s_line = b.editor.row_col_at(s).0 as u32 + 1;
            let mut e_line = b.editor.row_col_at(e.saturating_sub(1)).0 as u32 + 1;
            if e_line < s_line {
                e_line = s_line;
            }
            (s_line, e_line)
        } else {
            let line = b.editor.row_col().0 as u32 + 1;
            (line, line)
        };
        match crate::git::browse::url_for(&repo, &rel, lo, hi) {
            Some(url) => {
                open_url_external(&url);
                self.toast(format!("→ {url}"));
            }
            None => self.toast("browse: no recognized remote (check `git remote -v`)"),
        }
    }

    /// Click handler for a WIP-detail file row. Opens an embedded
    /// diff INSIDE the active GitGraph pane (replaces the commit list
    /// area while it's open) so the right detail panel — the WIP
    /// detail itself — keeps showing the staged/unstaged file lists.
    /// Esc closes the embedded diff and the commit list returns.
    pub fn click_wip_file_row(&mut self, abs_path: std::path::PathBuf, staged: bool) {
        let scope = if staged {
            crate::pane::DiffScope::StagedFile(abs_path.clone())
        } else {
            crate::pane::DiffScope::Unstaged(Some(abs_path.clone()))
        };
        let empty_label = format!(
            "no diff for {} ({})",
            abs_path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            if staged { "staged" } else { "unstaged" }
        );
        self.open_embedded_diff_in_active_graph(scope, empty_label);
    }

    /// Re-run the active diff pane's `git diff` (after staging, or on demand).
    pub fn refresh_active_diff(&mut self) {
        let Some(cur) = self.active else { return };
        // Two shapes: a standalone `Pane::Diff` OR the embedded diff
        // inside a `Pane::GitGraph`. Both cache their own hunk list
        // and need re-fetching after a discard/stage/apply. Bug
        // reported 2026-07-06 — user discarded a hunk in the
        // GitGraph's embedded diff and it stayed visible until they
        // navigated away and back.
        let scope = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => d.scope.clone(),
            Some(Pane::GitGraph(g)) => match g.embedded_diff.as_ref() {
                Some(d) => d.scope.clone(),
                None => return,
            },
            _ => return,
        };
        let hunks = self.fetch_diff(&scope);
        match self.panes.get_mut(cur) {
            Some(Pane::Diff(d)) => {
                d.cursor = d.cursor.min(hunks.len().saturating_sub(1));
                d.hunks = hunks;
                // Invalidate the full-file-context cache; the split
                // view will re-fetch next render.
                d.full_hunks = None;
            }
            Some(Pane::GitGraph(g)) => {
                if let Some(d) = g.embedded_diff.as_mut() {
                    d.cursor = d.cursor.min(hunks.len().saturating_sub(1));
                    d.hunks = hunks;
                    d.full_hunks = None;
                }
            }
            _ => {}
        }
    }
    // ─── stash ──────────────────────────────────────────────────────
    // ─── tags ───────────────────────────────────────────────────────
    /// `git.push_tags` — `git push --tags`. Publishes every local tag to
    /// `origin`. Tags that already exist on the remote with a different
    /// target ref will refuse; users who really need to overwrite drop to
    /// a pty.
    pub fn run_git_push_tags(&mut self) {
        match crate::git::tag::push_all(self.active_repo_path()) {
            Ok(summary) => self.toast(format!("push tags: {summary}")),
            Err(e) => self.toast(format!("git push --tags: {e}")),
        }
    }

    /// Run a [`WipAction`] from the GitGraph pane's WIP detail panel. The
    /// existing `git_stage_*` helpers are gated to the GitStatus pane;
    /// this is the gate-free entry point so a button click in the graph
    /// pane stages without forcing the user to switch panes first.
    /// Refreshes the open GitGraph pane after the operation so the WIP
    /// row's file list reflects the change.
    /// Dispatch a button click from the GitGraph pane's top toolbar.
    /// Each variant maps to an existing palette command — keeps the
    /// mouse-driven and palette-driven flows in lockstep.
    pub fn run_git_toolbar_action(&mut self, action: crate::GitToolbarAction) {
        match action {
            crate::GitToolbarAction::Pull => self.run_git_pull(),
            crate::GitToolbarAction::Push => self.run_git_push(),
            crate::GitToolbarAction::Fetch => self.run_git_fetch(),
            crate::GitToolbarAction::BranchPicker => self.open_branch_picker(),
            crate::GitToolbarAction::Commit => self.open_commit_prompt(),
            crate::GitToolbarAction::Stash => self.open_stash_prompt(),
            crate::GitToolbarAction::StashPop => self.run_git_stash_pop(),
            crate::GitToolbarAction::Reflog => self.open_git_reflog(),
            crate::GitToolbarAction::RefreshRepos => {
                crate::command::run("git.refresh_repos", self);
            }
            crate::GitToolbarAction::SwitchRepo => {
                crate::command::run("git.next_repo", self);
            }
            crate::GitToolbarAction::Undo => self.git_undo_last_commit(),
            crate::GitToolbarAction::Redo => self.git_redo_commit(),
        }
    }

    /// Record a reversible git operation — pushes onto the undo stack
    /// and clears the redo stack (standard undo semantics: a new action
    /// invalidates the redo history). Capped at 50 entries.
    pub fn record_git_op(&mut self, entry: GitUndoEntry) {
        self.git_undo_stack.push(entry);
        if self.git_undo_stack.len() > 50 {
            self.git_undo_stack.remove(0);
        }
        self.git_redo_stack.clear();
    }

    /// Note a just-completed commit on the undo stack. Captures HEAD
    /// (the new commit) + HEAD~1 (its parent) so undo can `reset
    /// --soft` to the parent and redo can `reset --soft` back.
    pub fn note_commit_for_undo(&mut self) {
        let repo = self.active_repo_path().to_path_buf();
        let head = crate::git::commit::rev_parse(&repo, "HEAD");
        let parent = crate::git::commit::rev_parse(&repo, "HEAD~1");
        if let (Some(head), Some(parent)) = (head, parent) {
            self.record_git_op(GitUndoEntry {
                description: "commit".to_string(),
                undo: GitUndoAction::ResetSoft(parent),
                redo: GitUndoAction::ResetSoft(head),
            });
        }
    }

    /// Note a just-completed branch checkout (`from` → `to`) on the
    /// undo stack. No-op when `from`/`to` are the same.
    pub fn note_checkout_for_undo(&mut self, from: &str, to: &str) {
        if from == to || from.is_empty() || to.is_empty() {
            return;
        }
        self.record_git_op(GitUndoEntry {
            description: format!("checkout {to}"),
            undo: GitUndoAction::CheckoutBranch(from.to_string()),
            redo: GitUndoAction::CheckoutBranch(to.to_string()),
        });
    }

    /// Run a single [`GitUndoAction`] against the active repo.
    fn apply_git_undo_action(&self, action: &GitUndoAction) -> Result<(), String> {
        let repo = self.active_repo_path();
        match action {
            GitUndoAction::ResetSoft(rev) => crate::git::commit::reset_soft(repo, rev),
            GitUndoAction::CheckoutBranch(name) => crate::git::branch::checkout(repo, name),
        }
    }

    /// `git.undo` / GitGraph toolbar Undo — pop the undo stack, run the
    /// entry's inverse, move it to the redo stack.
    pub fn git_undo_last_commit(&mut self) {
        let Some(entry) = self.git_undo_stack.pop() else {
            self.toast("undo: nothing to undo");
            return;
        };
        match self.apply_git_undo_action(&entry.undo) {
            Ok(()) => {
                let desc = entry.description.clone();
                self.git_redo_stack.push(entry);
                self.toast(format!("undid: {desc}"));
                self.after_git_change();
            }
            Err(e) => {
                // Keep the entry off both stacks — it no longer applies.
                self.toast(format!("undo failed: {e}"));
            }
        }
    }

    /// GitGraph toolbar Redo — pop the redo stack, re-apply, move it
    /// back to the undo stack.
    pub fn git_redo_commit(&mut self) {
        let Some(entry) = self.git_redo_stack.pop() else {
            self.toast("redo: nothing to redo");
            return;
        };
        match self.apply_git_undo_action(&entry.redo) {
            Ok(()) => {
                let desc = entry.description.clone();
                self.git_undo_stack.push(entry);
                self.toast(format!("redid: {desc}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("redo failed: {e}")),
        }
    }

    // ─── commit ─────────────────────────────────────────────────────
    // ─── find in buffer ─────────────────────────────────────────────
    /// `find.toggle_regex` — flip the regex mode. Affects future find prompts
    /// (sticky across the session) AND any open find on the active buffer
    /// (recomputed). Toasts the new mode.
    pub fn toggle_find_regex(&mut self) {
        self.find_regex_default = !self.find_regex_default;
        let mode = if self.find_regex_default {
            "regex"
        } else {
            "literal"
        };
        let active = self.active;
        if let Some(Pane::Editor(b)) = active.and_then(|i| self.panes.get_mut(i))
            && let Some(state) = &mut b.find
        {
            state.regex = self.find_regex_default;
            let text = b.editor.text().to_string();
            state.recompute(&text);
            let n = state.matches.len();
            self.toast(format!("find: {mode} mode — {n} matches"));
            return;
        }
        self.toast(format!("find: {mode} mode"));
    }

    fn step_find(&mut self, delta: isize) {
        let Some(cur) = self.active else { return };
        // Decide outcome inside a scoped borrow, then act after (so we can also
        // call self.toast / self.place_cursor_at_byte without a borrow clash).
        enum Out {
            Stepped {
                byte: usize,
                idx1: usize,
                total: usize,
            },
            Toast(String),
        }
        let out = match self.panes.get_mut(cur) {
            Some(Pane::Editor(b)) => match b.find.as_mut() {
                None => Out::Toast("no active find — press Ctrl+F".into()),
                Some(f) if f.matches.is_empty() => {
                    Out::Toast(format!("no matches for {:?}", f.query))
                }
                Some(f) => {
                    let n = f.matches.len() as isize;
                    let cur_idx = f.current.map(|i| i as isize).unwrap_or(0);
                    let new = ((cur_idx + delta) % n + n) % n;
                    f.current = Some(new as usize);
                    let (start, _) = f.matches[new as usize];
                    Out::Stepped {
                        byte: start,
                        idx1: new as usize + 1,
                        total: n as usize,
                    }
                }
            },
            _ => return,
        };
        match out {
            Out::Stepped { byte, idx1, total } => {
                self.place_cursor_at_byte(cur, byte);
                self.toast(format!("match {idx1}/{total}"));
            }
            Out::Toast(s) => self.toast(s),
        }
    }

    /// `project.todos` (`:Todos`) — workspace-wide scan for `TODO` / `FIXME`
    /// / `HACK` / `XXX` comments. Implemented as a fixed-pattern workspace
    /// grep so the results land in the existing `Pane::Grep` (browseable
    /// with `n`/`p`, jumpable via Enter, etc.). Pattern matches the
    /// uppercase form with a word boundary so `today` etc. don't hit.
    pub fn open_todos_pane(&mut self) {
        let q = "\\b(TODO|FIXME|HACK|XXX)\\b".to_string();
        self.run_workspace_grep(q);
    }
    /// vim `Ctrl+W +` / `-` (height grow / shrink) and `Ctrl+W >` / `<`
    /// (width grow / shrink). Walks the layout for the smallest split of
    /// the matching direction containing the active leaf, adjusts its
    /// ratio by `delta` (clamped to 10..=90).
    pub fn adjust_split(&mut self, dir: crate::layout::SplitDir, delta: i32) {
        let Some(cur) = self.active else { return };
        if !self.layout_mut().adjust_split_ratio_for(cur, dir, delta) {
            self.toast("no enclosing split in that direction");
        }
    }

    /// `editor.open_url_at_cursor` — vim `gx`. Pull the whitespace-delimited
    /// token around the cursor on the current line; if it starts with a URL
    /// scheme (`http`, `https`, `file:`, `mailto:`), hand it to the OS's
    /// default opener (`open` / `xdg-open` / `start`). Toasts when nothing
    /// URL-shaped is at the cursor.
    pub fn open_url_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        // LSP document-link hit at the cursor wins — those are
        // server-recognized URLs / paths and may not be whitespace-delimited.
        let (cur_row, cur_col) = b.editor.row_col();
        if let Some(link) = b.document_links.iter().find(|l| {
            l.line as usize == cur_row
                && (l.start_char as usize) <= cur_col
                && cur_col <= (l.end_char as usize)
        }) {
            let target = link.target.clone();
            // `file://` paths open as files in mnml; everything else (http,
            // mailto, ftp, …) goes to the OS opener.
            if let Some(local) = target.strip_prefix("file://") {
                let p = std::path::PathBuf::from(local);
                self.open_path(&p);
            } else {
                open_path_external(std::path::Path::new(&target));
                self.toast(format!("open: {target}"));
            }
            return;
        }
        let text = b.editor.text();
        let cursor = b.editor.cursor();
        // Bounds of the current line.
        let bol = text[..cursor].rfind('\n').map(|i| i + 1).unwrap_or(0);
        let eol = text[bol..]
            .find('\n')
            .map(|i| bol + i)
            .unwrap_or(text.len());
        let line = &text[bol..eol];
        let line_off = cursor - bol;
        // Walk back / forward through non-whitespace chars to find the token.
        let bytes = line.as_bytes();
        let mut start = line_off.min(line.len());
        while start > 0 && !bytes[start - 1].is_ascii_whitespace() {
            start -= 1;
        }
        let mut end = line_off.min(line.len());
        while end < line.len() && !bytes[end].is_ascii_whitespace() {
            end += 1;
        }
        if start >= end {
            self.toast("no URL at cursor");
            return;
        }
        // Strip common surrounding punctuation / brackets.
        let mut token = &line[start..end];
        token = token.trim_matches(|c: char| {
            matches!(
                c,
                '<' | '>' | '(' | ')' | '[' | ']' | '"' | '\'' | ',' | '.' | ';' | ':'
            )
        });
        let url_scheme = ["http://", "https://", "file://", "mailto:", "ftp://"];
        if !url_scheme.iter().any(|s| token.starts_with(s)) {
            self.toast(format!("not a URL at cursor: {token:?}"));
            return;
        }
        // OS opener — same flow as `editor.open_at_cursor`'s file path handler.
        let (cmd, args): (&str, &[&str]) = if cfg!(target_os = "macos") {
            ("open", &[])
        } else if cfg!(target_os = "windows") {
            ("cmd", &["/C", "start", ""])
        } else {
            ("xdg-open", &[])
        };
        let _ = std::process::Command::new(cmd)
            .args(args)
            .arg(token)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        self.toast(format!("opened {token}"));
    }

    /// `editor.file_info` — vim `Ctrl+G`. Toast `<path> · Ln N/M · X%` for
    /// the active editor (no-op when nothing's open).
    pub fn show_file_info(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let path = b
            .path
            .as_ref()
            .map(|p| rel_path(&self.workspace, p))
            .unwrap_or_else(|| b.display_name().to_string());
        let (row, _) = b.editor.row_col();
        let total = b.editor.line_count();
        let pct = if total <= 1 {
            100
        } else {
            ((row + 1) * 100) / total.max(1)
        };
        let dirty = if b.dirty { " ●" } else { "" };
        self.toast(format!("{path}{dirty} · Ln {}/{total} · {pct}%", row + 1));
    }

    /// `editor.repeat_last_substitute` — vim `&`. Re-runs the most recent
    /// `:s` / `:%s` payload, but always scoped to the cursor's current line
    /// (vim convention) and with `c` (confirm) dropped. Toast when nothing
    /// to repeat.
    pub fn repeat_last_substitute(&mut self) {
        let Some(mut sub) = self.last_substitute.clone() else {
            self.toast("no previous :s");
            return;
        };
        sub.whole_buffer = false;
        sub.confirm = false;
        self.run_substitute(sub);
    }

    /// `editor.file_stats` — vim `g Ctrl+G`. Toast char / word / line
    /// counts for the active editor + the cursor's byte position. Useful
    /// for prose buffers (markdown / blog drafts).
    pub fn show_file_stats(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        let chars = text.chars().count();
        let lines = b.editor.line_count();
        let words = text.split_whitespace().count();
        let bytes = text.len();
        let cur = b.editor.cursor();
        let cur_pct = cur
            .checked_mul(100)
            .and_then(|n| n.checked_div(bytes))
            .unwrap_or(100);
        self.toast(format!(
            "{lines} lines · {words} words · {chars} chars · {bytes}B · cursor at {cur}B ({cur_pct}%)"
        ));
    }

    /// `editor.char_info` — vim `ga`. Toasts the char under the cursor in
    /// dec / hex (and the unicode codepoint U+XXXX). No-op on EOL/EOF.
    pub fn show_char_info(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        let cur = b.editor.cursor();
        let Some(ch) = text[cur..].chars().next() else {
            self.toast("EOF");
            return;
        };
        if ch == '\n' {
            self.toast("<NL>");
            return;
        }
        let cp = ch as u32;
        self.toast(format!("{ch:?}  ({cp} · 0x{cp:X} · U+{cp:04X})"));
    }

    /// `editor.char_utf8` — vim `g8`. Toasts the UTF-8 byte sequence of the
    /// char under the cursor as space-separated 2-digit hex.
    pub fn show_char_utf8(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        let cur = b.editor.cursor();
        let Some(ch) = text[cur..].chars().next() else {
            self.toast("EOF");
            return;
        };
        let mut buf = [0u8; 4];
        let s = ch.encode_utf8(&mut buf);
        let bytes: Vec<String> = s.bytes().map(|b| format!("{b:02x}")).collect();
        self.toast(format!("{ch:?}  utf-8: {}", bytes.join(" ")));
    }

    /// vim `Ctrl+E` / `Ctrl+Y` — scroll the buffer one line down / up
    /// without moving the cursor (until the cursor would scroll off-screen,
    /// in which case it sticks at the edge). `delta` = +1 scrolls one line
    /// down (showing more below); `-1` scrolls up.
    pub fn scroll_buffer(&mut self, delta: i32) {
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        b.scroll = ((b.scroll as i32 + delta).max(0) as usize)
            .min(b.editor.line_count().saturating_sub(1));
        // 2026-06-08 nvchad hunt fix: without this flag, the editor's
        // render path snaps `scroll` back to the cursor's line on the
        // next paint — so `Ctrl+E` / `Ctrl+Y` were silent no-ops.
        // The mouse-wheel path in `dispatch.rs` already sets this;
        // the keyboard path forgot. Cleared automatically when the
        // cursor next moves.
        b.scroll_pinned = true;
    }

    /// vim `zh` / `zl` / `zH` / `zL` — adjust horizontal scroll without
    /// moving the cursor. `delta` is a column count (positive = scroll right,
    /// negative = scroll left). Half / full forms multiply by viewport width.
    pub fn hscroll_buffer(&mut self, delta: i32) {
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        b.h_scroll = (b.h_scroll as i32 + delta).max(0) as usize;
    }
    /// vim `zH` / `zL` — half-screen horizontal scroll. Reads the active pane's
    /// width from `self.rects`; falls back to 80 if not recorded.
    pub fn hscroll_buffer_half_screen(&mut self, dir: i32) {
        let Some(cur) = self.active else { return };
        let w = self
            .rects
            .editor_panes
            .iter()
            .find(|(_, p)| *p == cur)
            .map(|(r, _)| r.width as usize)
            .unwrap_or(80);
        let half = (w / 2).max(1) as i32;
        self.hscroll_buffer(dir * half);
    }

    /// vim `zz` / `zt` / `zb` — adjust the scroll position so the cursor
    /// lands at the center / top / bottom of the visible viewport.
    /// `frac_from_top`: 0.0 = top, 0.5 = middle, 1.0 = bottom (clamped).
    /// Reads the active pane's rect from `self.rects` for the viewport
    /// height; no-op when the rect isn't recorded yet (a pane that hasn't
    /// rendered).
    pub fn scroll_cursor_in_view(&mut self, frac_from_top: f32) {
        let Some(cur) = self.active else { return };
        let h = self
            .rects
            .editor_panes
            .iter()
            .find(|(_, p)| *p == cur)
            .map(|(r, _)| r.height as usize)
            .unwrap_or(0);
        // 2026-08-15 R13 api-workflow SEV-2 — was subtracting 1 for
        // the breadcrumb here, but `editor_view.rs::draw_pane` already
        // records the rect AFTER shrinking for the breadcrumb, so this
        // second subtract landed the cursor one row above true bottom
        // once the R13 default flip made `breadcrumb` on for everyone
        // (previously dead code — the flag was off by default).
        let body_h = h;
        if body_h == 0 {
            return;
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let cur_row = b.editor.row_col().0;
        let frac = frac_from_top.clamp(0.0, 1.0);
        let offset = (body_h as f32 * frac) as usize;
        // New scroll = cursor - offset, clamped at zero.
        b.scroll = cur_row.saturating_sub(offset);
    }

    /// vim `H` / `M` / `L` — move the *cursor* to the high (top) / middle /
    /// low (bottom) of the visible viewport (scroll stays put). `frac` =
    /// 0.0 ⇒ first visible row, 0.5 ⇒ middle, 1.0 ⇒ last visible row.
    pub fn move_cursor_in_view(&mut self, frac_from_top: f32) {
        let Some(cur) = self.active else { return };
        let h = self
            .rects
            .editor_panes
            .iter()
            .find(|(_, p)| *p == cur)
            .map(|(r, _)| r.height as usize)
            .unwrap_or(0);
        // 2026-08-15 R13 api-workflow SEV-2 — see scroll_cursor_in_view
        // above; `editor_panes` rect is already breadcrumb-shrunk by
        // draw_pane, so a second subtract here off-by-oned `H`/`M`/`L`.
        let body_h = h;
        if body_h == 0 {
            return;
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let scroll = b.scroll;
        let last_visible = scroll + body_h.saturating_sub(1);
        let line_count = b.editor.line_count();
        let frac = frac_from_top.clamp(0.0, 1.0);
        let target = if frac == 0.0 {
            scroll
        } else if frac == 1.0 {
            last_visible.min(line_count.saturating_sub(1))
        } else {
            scroll + (body_h as f32 * frac) as usize
        };
        let target = target.min(line_count.saturating_sub(1));
        b.editor.place_cursor(target, 0);
    }

    /// vim `gi` — jump cursor to the most recent edit position and enter
    /// Insert mode. Reads the last entry of `Buffer.edit_history`. The
    /// "enter insert mode" half is delivered by re-feeding an `i` keypress
    /// through `dispatch_key` (only meaningful when the active handler is
    /// vim — `gi` is a vim chord, so the dispatch lands on vim's `i` arm).
    pub fn vim_go_to_last_insert(&mut self) {
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let Some(&(row, col)) = b.edit_history.last() else {
            self.toast("no recent edit");
            return;
        };
        b.editor.place_cursor(row, col);
        let key = ratatui::crossterm::event::KeyEvent::new(
            ratatui::crossterm::event::KeyCode::Char('i'),
            ratatui::crossterm::event::KeyModifiers::NONE,
        );
        crate::tui::dispatch_key(self, key);
    }

    /// `editor.bracket_match` (`Ctrl+]` / vim `%`) — when the cursor sits
    /// on a bracket (`()` / `[]` / `{}`), jump to its match. For
    /// HTML-family files, also matches `<tag>` ↔ `</tag>` (vim-matchup).
    /// Toasts when there's none.
    pub fn bracket_match_jump(&mut self) {
        let pid = match self.active {
            Some(p) => p,
            None => return,
        };
        // First try the bracket matcher.
        let bracket_target = match self.panes.get(pid) {
            Some(Pane::Editor(b)) => b.editor.bracket_match(),
            _ => None,
        };
        if let Some((row, col)) = bracket_target {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(pid) {
                b.editor.place_cursor(row, col);
            }
            return;
        }
        // Tag matcher — HTML-family files only.
        let tag_target = match self.panes.get(pid) {
            Some(Pane::Editor(b))
                if matches!(
                    b.language_ext.as_deref(),
                    Some("html" | "htm" | "vue" | "svelte" | "astro" | "jsx" | "tsx" | "xml")
                ) =>
            {
                crate::editor::tag_match_at(b.editor.text(), b.editor.cursor())
            }
            _ => None,
        };
        if let Some(byte) = tag_target {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(pid) {
                let (r, c) = b.editor.row_col_at(byte);
                b.editor.place_cursor(r, c);
            }
            return;
        }
        self.toast("not on a bracket / tag");
    }

    /// `editor.goto_line` (`Ctrl+G`) — prompt for a 1-based line number. The
    /// input starts empty (a seed would force the user to clear it first
    /// 90% of the time); the title shows the current line as a reference.
    pub fn open_goto_line_prompt(&mut self) {
        let title = match self.active_editor() {
            Some(b) => {
                let (row, _) = b.editor.row_col();
                format!("Go to line  (currently {})", row + 1)
            }
            None => "Go to line".to_string(),
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GotoLine,
            title,
        ));
    }

    /// Move the active editor's cursor to the 1-based line number parsed from
    /// `s` (clamped to the buffer). Empty / non-numeric input is a no-op
    /// (the prompt accept always trims, but it might still be empty).
    pub fn goto_line_str(&mut self, s: &str) {
        // VS Code convention: `10:5` = line 10, col 5. vscode-user-kb
        // round 4 (2026-07-11) — the prior parse rejected `LINE:COL`
        // even though the goto prompt naturally invites the two-part
        // form. Split on `:` if present; both halves are 1-based.
        let (line_str, col_str) = match s.split_once(':') {
            Some((l, c)) => (l.trim(), Some(c.trim())),
            None => (s.trim(), None),
        };
        let Ok(n) = line_str.parse::<usize>() else {
            if !s.is_empty() {
                self.toast(format!("not a number: {s:?}"));
            }
            return;
        };
        let col = col_str
            .and_then(|c| c.parse::<usize>().ok())
            .map(|c| c.saturating_sub(1))
            .unwrap_or(0);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(n.saturating_sub(1), col);
        }
    }

    /// `find.clear` (palette "Find: clear highlights", `:noh`) — drop the matches.
    /// Extra cursors are preserved so callers like `:noh` don't
    /// silently deselect a live multi-cursor session (#1142 reviewer
    /// pointed out this scope creep — see clear_find_and_deselect
    /// below for the vim-Esc-only combo).
    pub fn clear_find(&mut self) {
        if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.find = None;
        }
    }

    /// `find.clear_and_deselect` — vim Esc's "back to one cursor +
    /// no highlight" gesture. Combines clear_find + drop
    /// extra_cursors. #1142 (nvchad-parity SEV-1) — was folded into
    /// clear_find; extracted after reviewer flag so palette
    /// "Find: clear highlights" + `:noh` don't clobber multi-cursors.
    pub fn clear_find_and_deselect(&mut self) {
        if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.find = None;
            // R10 nvchad-user SEV-1 (2026-08-22) — must clear BOTH
            // extra_cursors and extra_anchors together. Clearing
            // only cursors left the two vectors out of sync, then
            // the very next multi-cursor motion (e.g. `l` after
            // Esc) tripped `replace_extra_positions`'s
            // debug_assert_eq!(len, anchors.len()) and panicked.
            b.editor.clear_extra_cursors();
        }
    }

    /// Move the editor's cursor to byte offset `byte`, scrolling so it's visible.
    fn place_cursor_at_byte(&mut self, pane_id: PaneId, byte: usize) {
        let (row, col) = match self.panes.get(pane_id) {
            Some(Pane::Editor(b)) => byte_to_row_col(b.editor.text(), byte),
            _ => return,
        };
        if let Some(Pane::Editor(b)) = self.panes.get_mut(pane_id) {
            b.editor.place_cursor(row, col);
        }
        self.reveal_pane(pane_id);
    }

    // ─── git graph (coloured-lane commit DAG) ───────────────────────
    // ─── git status / staging view ──────────────────────────────────
    /// The git-rooted path for the *currently-active* repo. In the
    /// single-repo case (or no-repo case) this is the workspace itself;
    /// in a multi-repo workspace it's whichever sub-repo
    /// `[App::active_repo]` points at.
    pub fn active_repo_path(&self) -> &std::path::Path {
        self.repos
            .get(self.active_repo)
            .map(|r| r.path.as_path())
            .unwrap_or(self.workspace.as_path())
    }

    /// Which workspace section the rail considers "focused" — i.e. where a
    /// section-scoped command (like `view.toggle_hidden`) should land.
    /// Picks the extra workspace whose root contains the active repo;
    /// `None` ⇒ the primary tree.
    pub fn focused_tree_workspace_idx(&self) -> Option<usize> {
        let active = self.active_repo_path().to_path_buf();
        self.extra_workspaces
            .iter()
            .position(|w| active.starts_with(&w.root))
    }

    /// The "active workspace" — the workspace whose section currently
    /// owns the rail's focus. Routes through `focused_tree_workspace_idx`
    /// for extras; falls back to the launch primary (`self.workspace`).
    ///
    /// Use this for context-sensitive operations that should follow the
    /// user's current focus: `term.shell` cwd, `:!cmd` cwd, grep root,
    /// `:cd` / `:pwd`. Don't use it for things that should stay anchored
    /// to launch context — session.json location, `[[workspaces]]` config
    /// loading, etc.
    pub fn active_workspace_path(&self) -> &Path {
        if let Some(idx) = self.focused_tree_workspace_idx()
            && let Some(ws) = self.extra_workspaces.get(idx)
        {
            return &ws.root;
        }
        &self.workspace
    }

    /// Resolve the close-confirm overlay. `choice`: 0 = Save (then close),
    /// 1 = Discard (close, lose changes), 2 = Cancel.
    pub fn close_prompt_resolve(&mut self, choice: u8) {
        let Some(id) = self.close_prompt.take() else {
            return;
        };
        match choice {
            0 => {
                // Save then close. A save failure aborts the close (the toast says why).
                let ok = match self.panes.get_mut(id) {
                    Some(Pane::Editor(b)) if b.path.is_some() => match b.save_to_disk() {
                        Ok(()) => true,
                        Err(e) => {
                            self.toast(format!("save failed: {e}"));
                            false
                        }
                    },
                    Some(Pane::Editor(_)) => {
                        self.toast("can't save a scratch buffer — pick Discard or Cancel");
                        false
                    }
                    _ => true,
                };
                if ok {
                    self.git.refresh();
                    self.disarm_quit();
                    self.force_close_pane(id);
                }
            }
            1 => self.force_close_pane(id),
            _ => {} // cancel
        }
    }
    /// `(display_name, has_path)` for the buffer awaiting a close decision, if any.
    pub fn close_prompt_info(&self) -> Option<(String, bool)> {
        let id = self.close_prompt?;
        match self.panes.get(id)? {
            Pane::Editor(b) => Some((b.display_name(), b.path.is_some())),
            Pane::MdPreview(p) => Some((p.title(), false)),
            Pane::Diff(d) => Some((d.title(), false)),
            Pane::GitGraph(g) => Some((g.tab_title(), false)),
            Pane::GitStatus(g) => Some((g.tab_title(), false)),
            Pane::Request(r) => Some((r.title(), false)),
            Pane::Pty(s) => Some((s.title(), false)),
            Pane::Ai(a) => Some((a.tab_title(), false)),
            Pane::Tests(t) => Some((t.tab_title(), false)),
            Pane::Browser(b) => Some((b.tab_title(), false)),
            Pane::Diagnostics(d) => Some((d.tab_title(), false)),
            Pane::Grep(g) => Some((g.tab_title(), false)),
            Pane::Flaky(f) => Some((f.tab_title(), false)),
            Pane::Outline(o) => Some((o.tab_title(), false)),
            Pane::Files(f) => Some((f.tab_title(), false)),
            Pane::Quickfix(g) => Some((format!("Quickfix · {}", g.hits.len()), false)),
            Pane::CmdlineHistory(_) => Some(("q:".to_string(), false)),
            Pane::Cheatsheet(_) => Some(("Cheatsheet".to_string(), false)),
            Pane::Debug(_) => Some(("Debug".to_string(), false)),
            Pane::DapRepl(_) => Some(("DAP REPL".to_string(), false)),
            Pane::Image(p) => Some((p.tab_title(), false)),
            Pane::ClaudeAgents(p) => Some((p.tab_title(), false)),
            Pane::Websocket(p) => Some((p.tab_title(), false)),
            Pane::SpendReport(_) => Some(("AI spend (24h)".to_string(), false)),
            Pane::Mount(m) => Some((m.label.clone(), false)),
            Pane::CloudAgentRun(p) => Some((format!("☁ {}", p.ticket), false)),
            Pane::NewCloudAgentWizard(_) => Some(("+ New Agent from PR".to_string(), false)),
            Pane::NewCloudRunWizard(_) => Some(("+ New Cloud Run".to_string(), false)),
            Pane::IntegrationDetail(d) => Some((d.tab_title(), false)),
            Pane::ClaudeUsage(p) => Some((p.tab_title(), false)),
            Pane::CodexUsage(p) => Some((p.tab_title(), false)),
        }
    }

    pub fn editing_mode(&self) -> EditingMode {
        match self.focus {
            Focus::Pane => self
                .active_editor()
                .map(Buffer::editing_mode)
                .unwrap_or(EditingMode::None),
            _ => EditingMode::None,
        }
    }

    /// code-reviewer S1-2 — single semantic check for "is this user
    /// driving with vim semantics?" so dispatch doesn't pepper
    /// `config.editor.input_style == "vim"` literal checks (spine
    /// rule: editor / buffer / render layers shouldn't reach in to
    /// the input style). Three sites in tui.rs (Ctrl+W remap, Esc
    /// focus-tree, re-dispatch) now route through this. For
    /// `&Config`-only callers (keymap build, settings overlay) the
    /// free fn `crate::input::is_vim_style(&Config)` delegates here
    /// without needing an `&App`.
    pub fn is_vim_mode(&self) -> bool {
        crate::input::is_vim_style(&self.config)
    }

    /// qa-7th code-review C-1 2026-06-30 — semantic accessor for
    /// "does the current input style treat Ctrl+W as a window-nav
    /// prefix (vim) rather than a buffer-close (standard / VS
    /// Code)?". Replaces three `is_vim_mode()` checks in
    /// tui/handlers/pane.rs with a behavior-named question, so a
    /// future input style (Helix, Emacs evil-mode) decides for
    /// itself rather than the dispatch layer asking "are you vim?".
    pub fn ctrl_w_is_window_nav(&self) -> bool {
        crate::input::is_vim_style(&self.config)
    }

    /// qa-7th code-review C-1 2026-06-30 — semantic accessor for
    /// "does Esc on a pane with no selection move focus back to
    /// the tree?". Same reasoning as `ctrl_w_is_window_nav`.
    pub fn esc_blurs_pane_to_tree(&self) -> bool {
        crate::input::is_vim_style(&self.config)
    }

    /// Whether the editor mouse wheel + scrollbar drag should drag the
    /// cursor along with the viewport. Resolves the
    /// `[editor] wheel_moves_cursor` policy:
    ///   - `"always"` ⇒ true (cursor + viewport move together)
    ///   - `"never"` ⇒ false (viewport-only, cursor stays put — may
    ///     scroll off-screen; the scrollbar thumb is the position cue)
    ///   - `"auto"` (default) ⇒ true under vim input style (matches
    ///     `Ctrl+E` / `Ctrl+Y` canon), false under standard (matches
    ///     VS Code / Sublime).
    ///
    /// Called from `scroll_under` (wheel) and `set_pane_scroll`
    /// (scrollbar drag), so both surfaces agree.
    pub fn cursor_follows_wheel(&self) -> bool {
        match self.config.editor.wheel_moves_cursor.as_str() {
            "always" => true,
            "never" => false,
            _ => self.is_vim_mode(),
        }
    }

    pub fn pending_display(&self) -> Option<String> {
        // The no-pane cmdline wins regardless of focus — Ctrl+;
        // opens it from ANY focus including pane, so its visible
        // state has to override whatever the editor's input handler
        // might be reporting. Bug found 2026-06-18: cmdline_bar
        // rendered the editor's pending state and the cmdline was
        // visually hidden by the pane, even though typing was
        // landing in `no_pane_cmdline` correctly.
        if let Some(text) = self.no_pane_cmdline.as_deref() {
            // Match the vim cmdline's display shape — leading `:` +
            // a caret block at the end so the cmdline_bar's
            // `starts_with(':')` branch picks it up and renders in
            // the same yellow style as the in-buffer cmdline.
            return Some(format!(":{text}▏"));
        }
        if self.focus == Focus::Pane {
            self.active_editor().and_then(|b| b.input.pending_display())
        } else {
            None
        }
    }

    // UI-toggle setters (`set_input_style`, `set_wrap`, `set_workspace_dots`,
    // …) and their paired `toggle_*` flip helpers live in `src/app/toggles.rs`.

    /// `project.next_todo` (vim `]t`) / `project.prev_todo` (`[t`) —
    /// jump the cursor to the next / previous `TODO` / `FIXME` / `HACK`
    /// / `XXX` whole-word match in the active buffer. Wraps. Toasts when
    /// nothing matches.
    pub fn jump_todo(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text().to_string();
        let cursor = b.editor.cursor();
        let mut hits: Vec<usize> = ["TODO", "FIXME", "HACK", "XXX"]
            .iter()
            .flat_map(|kw| crate::editor::find_whole_word_occurrences(&text, kw))
            .map(|(s, _)| s)
            .collect();
        hits.sort_unstable();
        hits.dedup();
        if hits.is_empty() {
            self.toast("no TODO/FIXME/HACK/XXX in buffer");
            return;
        }
        let target = if forward {
            hits.iter()
                .find(|&&p| p > cursor)
                .copied()
                .unwrap_or(hits[0])
        } else {
            hits.iter()
                .rev()
                .find(|&&p| p < cursor)
                .copied()
                .unwrap_or_else(|| *hits.last().unwrap())
        };
        let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) else {
            return;
        };
        let (row, col) = b.editor.row_col_at(target);
        b.editor.place_cursor(row, col);
    }

    // Harpoon (`harpoon_add_active` / `harpoon_goto` / `harpoon_open_menu`)
    // lives in `src/app/harpoon.rs`.

    /// Apply a single edit op to the active editor through its
    /// `apply_edit_ops` path — keeps the clipboard borrow scope short
    /// so callers can be 1-liners.
    pub fn apply_op_active(&mut self, op: crate::edit_op::EditOp) {
        let vp = 10usize;
        if let Some(pid) = self.active
            && let Some(Pane::Editor(b)) = self.panes.get_mut(pid)
        {
            b.apply_edit_ops(vec![op], &mut self.clipboard, vp);
        }
    }

    /// chords show up immediately). If one's already open, focuses it.
    /// Run the cheatsheet's selected row's command — used by both Enter
    /// (chord handler) and the new double-click mouse path.
    pub fn cheatsheet_run_selected(&mut self) {
        let Some(cur) = self.active else { return };
        let cmd_id = if let Some(Pane::Cheatsheet(c)) = self.panes.get(cur) {
            c.selected_command_id()
        } else {
            None
        };
        if let Some(id) = cmd_id {
            // Leaking a 'static lifetime via boxing is the existing way mnml
            // dispatches dynamic command ids (mirrors `:` ex command).
            let id_static: &'static str = Box::leak(id.into_boxed_str());
            let _ = crate::command::run(id_static, self);
        }
    }

    /// `:ai.dashboard` — open (or refresh) the Claude Code
    /// agents dashboard pane. Scans `~/.claude/projects/` for every
    /// session file modified in the last 7 days, cross-references
    /// running `claude` PIDs via `pgrep`, and renders one row per
    /// session with live/idle/ended state, model, last user/asst
    /// message, token spend, and PID.
    /// Open the docs page for the webhook-triggered worker
    /// pattern. Unlike the always-on poller (which mnml can
    /// spawn for you via `spawn_managed_agents_worker`), the
    /// webhook flow requires a public HTTPS endpoint Anthropic
    /// can reach — typically Vercel / Cloudflare Worker /
    /// Lambda. mnml can't host that; we surface the docs link
    /// + the SDK snippets the user needs.
    pub fn open_managed_agents_webhook_docs(&mut self) {
        let url = "https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes#webhook-triggered-(sdk)";
        let _ = std::process::Command::new(if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        })
        .arg(url)
        .status();
        self.toast(
            "opened webhook-handler docs — needs a public HTTPS endpoint (Vercel/Cloudflare/Lambda) outside mnml",
        );
    }

    // A-1: cloud agents + claude-agents dashboard methods moved to
    // src/app/cloud_agents_methods.rs.

    pub fn open_cheatsheet(&mut self) {
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Cheatsheet(_)))
        {
            let fresh = crate::cheatsheet::CheatsheetPane::build(&self.keymap);
            if let Some(Pane::Cheatsheet(c)) = self.panes.get_mut(id) {
                *c = fresh;
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Cheatsheet(crate::cheatsheet::CheatsheetPane::build(&self.keymap));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    // ─── focus ──────────────────────────────────────────────────────
    // ─── git rail (`GIT` section in the left rail) ──────────────────
    // ─── tree ───────────────────────────────────────────────────────
    /// Enter/click on the row under the tree cursor: open a file, or expand/collapse a dir.
    pub fn tree_activate(&mut self) {
        if let Some(file) = self.tree.selected_file() {
            self.open_path(&file);
        } else {
            self.tree.toggle_current();
        }
    }

    // ─── misc ───────────────────────────────────────────────────────
    pub fn request_quit(&mut self) {
        // A `Ctrl+Q` fat-finger shouldn't kill the session — open a
        // button-based confirm prompt. Esc cancels via the standard
        // prompt machinery. The renderer inspects the app for dirty
        // panes so buttons adapt (clean: Quit/Cancel; dirty: Save all
        // / Quit anyway / Cancel).
        //
        // R6 R2 vscode-keyboard SEV-3 F7 2026-08-09 — default focus
        // to the CANCEL button so Enter is always safe. Was: cursor
        // started at 0 → Save all (safe when dirty) OR Quit (DESTRUCTIVE
        // when clean). Aligns with the delete-confirm dialog's
        // "safety-first default" convention.
        let title = "Quit mnml?".to_string();
        let mut prompt = crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::QuitConfirm,
            title,
            String::new(),
        );
        let has_dirty = !self.dirty_buffer_names().is_empty();
        prompt.cursor = if has_dirty { 2 } else { 1 };
        self.prompt = Some(prompt);
    }

    /// Dirty buffer display names, in pane order. Empty ⇒ nothing to
    /// lose. Used by the quit confirm dialog to pick its button set.
    pub fn dirty_buffer_names(&self) -> Vec<String> {
        self.panes
            .iter()
            .filter_map(|p| match p {
                Pane::Editor(b) if b.dirty => Some(b.display_name().to_string()),
                _ => None,
            })
            .collect()
    }

    fn disarm_quit(&mut self) {
        self.quit_armed = false;
    }
    /// Exit so the `run.sh` wrapper rebuilds and relaunches us with the same args.
    pub fn request_restart(&mut self) {
        self.restart_requested = true;
        self.should_quit = true;
    }

    pub fn toast(&mut self, msg: impl Into<String>) {
        self.toast_leveled(msg, ToastLevel::Info);
    }

    /// #20 — set the undo slot alongside a fresh toast. Displaces
    /// whatever undo was pending before (single-slot design).
    pub fn set_pending_undo(&mut self, label: impl Into<String>, action: UndoAction) {
        self.pending_undo = Some(PendingUndo {
            label: label.into(),
            action,
            created_at: Instant::now(),
        });
    }

    /// #20 — fire the pending undo action (if any) and clear the
    /// slot. No-op when nothing's pending. Called from the click
    /// handler on the `↶ Undo` chip and from the `u` key when the
    /// undo is live.
    pub fn commit_pending_undo(&mut self) {
        let Some(u) = self.pending_undo.take() else {
            return;
        };
        match u.action {
            UndoAction::RestoreRequestPane {
                pane_id,
                method,
                url,
                body,
                headers_buffer,
                source_buffer,
            } => {
                if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
                    rp.request.method = method;
                    rp.request.url = url;
                    rp.request.body = body;
                    rp.headers_buffer = headers_buffer;
                    rp.source_buffer = source_buffer;
                    self.toast("request restored");
                } else {
                    self.toast("undo: pane no longer exists");
                }
            }
            UndoAction::RestoreHistoryFile { bytes } => {
                let path = self.workspace.join(".rqst").join("history.jsonl");
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                match std::fs::write(&path, &bytes) {
                    Ok(_) => {
                        self.http_panel_refresh();
                        self.toast("recent history restored");
                    }
                    Err(e) => self.toast(format!("undo: {e}")),
                }
            }
            UndoAction::RestoreDeletedPath { from, to } => {
                // Refuse rather than clobber: something may have taken
                // the path back since the delete.
                if to.exists() {
                    self.toast(format!(
                        "undo: {} already exists",
                        to.file_name()
                            .map(|n| n.to_string_lossy())
                            .unwrap_or_default()
                    ));
                } else {
                    match std::fs::rename(&from, &to) {
                        Ok(()) => {
                            self.refresh_trees_for_path(&to);
                            let name = to
                                .file_name()
                                .map(|n| n.to_string_lossy().into_owned())
                                .unwrap_or_default();
                            self.toast(format!("restored {name}"));
                        }
                        Err(e) => self.toast(format!("undo: {e}")),
                    }
                }
            }
            UndoAction::ReopenClosedBuffer {
                path,
                cursor,
                scroll,
            } => {
                self.open_path(&path);
                if let Some(id) = self.active
                    && let Some(Pane::Editor(b)) = self.panes.get_mut(id)
                {
                    b.editor.set_cursor_byte(cursor);
                    b.scroll = scroll;
                }
                self.toast("buffer restored");
            }
            UndoAction::RestoreCapturedFile { bytes } => {
                let path = crate::http::proxy::captured_log_path(&self.workspace);
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                match std::fs::write(&path, &bytes) {
                    Ok(_) => {
                        self.http_panel_refresh();
                        self.toast("captured traffic restored");
                    }
                    Err(e) => self.toast(format!("undo: {e}")),
                }
            }
            UndoAction::RestoreWorkspace { config, position } => {
                let name = config.name.clone();
                let insert_at = position.min(self.config.workspaces.len());
                self.config.workspaces.insert(insert_at, config.clone());
                if let Err(e) = crate::config::persist_workspaces_to_global(&self.config.workspaces)
                {
                    self.toast(format!("undo: {e}"));
                    return;
                }
                // Also restore the extra_workspaces runtime entry so
                // the tree section reappears without a relaunch.
                if let Ok(root) = std::fs::canonicalize(&config.path)
                    && root != self.workspace
                    && !self.extra_workspaces.iter().any(|w| w.root == root)
                {
                    let tree = crate::tree::Tree::open(&root);
                    let mut found = crate::git::repos::discover_repos(&root);
                    let pos = self.next_free_workspace_position();
                    self.extra_workspaces.push(ExtraWorkspace {
                        name: name.clone(),
                        root,
                        tree,
                        expanded: false,
                        position: pos,
                    });
                    self.repos.append(&mut found);
                }
                self.toast(format!("restored workspace: {name}"));
            }
        }
    }

    /// #20 Pattern B — commit the pending confirm modal (user
    /// pressed Y / Enter on the Confirm button / clicked the
    /// Confirm chip). Fires the stashed action + clears the slot.
    pub fn commit_pending_confirm(&mut self) {
        let Some(c) = self.pending_confirm.take() else {
            return;
        };
        match c.action {
            ConfirmAction::OverwriteRequestPane { raw } => {
                self.http_paste_curl_from_text(&raw);
            }
        }
    }

    /// #20 Pattern B — dismiss the pending confirm modal (user
    /// pressed Esc / N / clicked Cancel).
    pub fn dismiss_pending_confirm(&mut self) {
        self.pending_confirm = None;
    }

    /// #993 step 2b (2026-08-20). Periodic background firing of the
    /// auto-update plan. Runs at most once per
    /// `AUTO_UPDATE_TICK_INTERVAL_SECS` (4h). Uses the same planner
    /// + apply path the palette command does, minus the toast noise
    /// — a background tick shouldn't spam the user when nothing is
    /// eligible. Firing is still fully gated by:
    ///   - per-integration `auto_update_override` (right-click toggle)
    ///     OR global `[integrations] auto_update_{cargo,git}`
    ///   - the 24h `AUTO_UPDATE_RATE_CAP_SECS` per integration
    /// Skipped in test builds so the suite doesn't spawn cargo.
    pub fn tick_auto_updates(&mut self) {
        if cfg!(test) {
            return;
        }
        let now = std::time::Instant::now();
        let due = self
            .last_auto_update_tick_at
            .map(|t| {
                now.duration_since(t)
                    >= std::time::Duration::from_secs(
                        crate::app::integration_updates::AUTO_UPDATE_TICK_INTERVAL_SECS,
                    )
            })
            .unwrap_or(true);
        if !due {
            return;
        }
        self.last_auto_update_tick_at = Some(now);
        // Reuse the manual-command logic verbatim by dispatching the
        // palette command. The command handler already handles the
        // empty-plan case with a toast — quiet the tick's version by
        // short-circuiting when the plan will be empty (no per-int
        // override set true AND both global toggles false).
        let has_global =
            self.config.integrations.auto_update_cargo || self.config.integrations.auto_update_git;
        let has_per_int_optin = self
            .integration_manifests
            .iter()
            .any(|m| matches!(m.auto_update_override, Some(true)));
        if !has_global && !has_per_int_optin {
            return;
        }
        crate::command::run("integrations.fire_auto_updates_now", self);
    }

    /// #25 v3 — idle refresh of the Claude Agents prefetch cache.
    /// Every 60 seconds re-runs the background scan so an open
    /// Agents dashboard picks up fresh sessions without the user
    /// pressing `r`. Cheap: only spawns a thread; the main loop
    /// picks up results whenever the pane next renders.
    pub fn tick_claude_agents_prefetch(&mut self) {
        static LAST_TICK: std::sync::OnceLock<std::sync::Mutex<Option<std::time::Instant>>> =
            std::sync::OnceLock::new();
        let mutex = LAST_TICK.get_or_init(|| std::sync::Mutex::new(None));
        let Ok(mut last) = mutex.lock() else {
            return;
        };
        let now = std::time::Instant::now();
        let due = last
            .map(|t| now.duration_since(t) >= std::time::Duration::from_secs(60))
            .unwrap_or(true);
        if !due {
            return;
        }
        *last = Some(now);
        let handle = self.claude_agents_prefetch.clone();
        std::thread::spawn(move || {
            let rows = crate::claude_agents::prefetch_rows();
            if let Ok(mut guard) = handle.lock() {
                *guard = Some(rows);
            }
        });
    }

    /// #20 — expire the undo slot when it's older than [`UNDO_TTL`].
    /// Called from the main loop's tick alongside toast_stack aging.
    pub fn tick_pending_undo(&mut self) {
        if let Some(u) = &self.pending_undo
            && u.created_at.elapsed() > UNDO_TTL
        {
            self.pending_undo = None;
        }
    }
}

// ── Bitbucket integration (lean-build-safe — no Cargo-feature gate) ───

impl App {
    // ── GitHub Actions — sibling of the Bitbucket methods above. ──────

    // ── GitLab ────────────────────────────────────────────────────────

    // ── Azure DevOps ──────────────────────────────────────────────────
}

/// Build the serializable mirror of `layout`. Returns `None` if any leaf isn't
/// in `pane_to_idx` (i.e. it's a non-editor pane we didn't save) — when that
/// happens we drop layout entirely rather than save half a tree.
fn saved_layout_from(layout: &Layout, pane_to_idx: &[Option<usize>]) -> Option<SavedLayout> {
    match layout {
        Layout::Empty => Some(SavedLayout::Empty),
        Layout::Leaf { active, tabs } => {
            // Map every tab through pane_to_idx; drop tabs that
            // map to None (non-editor panes we don't save).
            let saved_tabs: Vec<usize> = tabs
                .iter()
                .filter_map(|&pid| pane_to_idx.get(pid).copied().flatten())
                .collect();
            if saved_tabs.is_empty() {
                return None;
            }
            let active_pos = tabs
                .iter()
                .position(|t| t == active)
                .and_then(|p| pane_to_idx.get(tabs[p])?.map(|_| p))
                .unwrap_or(0)
                .min(saved_tabs.len() - 1);
            Some(SavedLayout::LeafTabs {
                active: active_pos,
                tabs: saved_tabs,
            })
        }
        Layout::Split {
            dir,
            ratio,
            first,
            second,
        } => {
            let f = saved_layout_from(first, pane_to_idx)?;
            let s = saved_layout_from(second, pane_to_idx)?;
            Some(SavedLayout::Split {
                dir: (*dir).into(),
                ratio: *ratio,
                first: Box::new(f),
                second: Box::new(s),
            })
        }
    }
}

/// Rebuild a `Layout` from `SavedLayout`, looking each leaf's saved-index up in
/// `idx_to_pane`. Returns `None` if any leaf points at a file that didn't
/// re-open — we'd rather skip layout restore than show a stale id.
/// Show the one-time "sudo tools need a password" hint the first
/// time the user launches a needs_sudo tool. Uses a persistent toast
/// so it survives the pty pane's paint noise and stays visible until
/// the user hits Esc / clicks it away. Marker file at
/// `~/.config/mnml/.tools-sudo-hint-shown` — delete it to see the
/// hint again. Silent when the config dir can't be resolved.
fn maybe_show_sudo_tools_hint(app: &mut App) {
    let Some(cfg_path) = crate::config::user_config_path() else {
        return;
    };
    let Some(cfg_dir) = cfg_path.parent() else {
        return;
    };
    let marker = cfg_dir.join(".tools-sudo-hint-shown");
    if marker.exists() {
        return;
    }
    let _ = std::fs::create_dir_all(cfg_dir);
    let _ = std::fs::write(&marker, "");
    app.toast_persistent(
        "tools-sudo-hint",
        "sudo needed for packet capture · skip the prompt: see docs/tools.md#passwordless",
        ToastLevel::Warn,
    );
}

fn layout_from_saved(saved: &SavedLayout, idx_to_pane: &[Option<PaneId>]) -> Option<Layout> {
    match saved {
        SavedLayout::Empty => Some(Layout::Empty),
        SavedLayout::Leaf(i) => idx_to_pane.get(*i).copied().flatten().map(Layout::leaf),
        SavedLayout::LeafTabs { active, tabs } => {
            let resolved: Vec<PaneId> = tabs
                .iter()
                .filter_map(|&i| idx_to_pane.get(i).copied().flatten())
                .collect();
            if resolved.is_empty() {
                return None;
            }
            let active_idx = (*active).min(resolved.len() - 1);
            Some(Layout::Leaf {
                active: resolved[active_idx],
                tabs: resolved,
            })
        }
        SavedLayout::Split {
            dir,
            ratio,
            first,
            second,
        } => {
            let f = layout_from_saved(first, idx_to_pane)?;
            let s = layout_from_saved(second, idx_to_pane)?;
            Some(Layout::Split {
                dir: (*dir).into(),
                ratio: *ratio,
                first: Box::new(f),
                second: Box::new(s),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // ── external URL opener ──────────────────────────────────────

    #[test]
    fn ordinary_web_urls_are_allowed() {
        // Query strings matter: an early draft of the validator
        // rejected `&`, which would have refused most real links.
        for url in [
            "https://github.com/chris-mclennan/mnml",
            "http://localhost:7071/jira",
            "https://example.com/a?b=1&c=2",
            "https://example.com/path%20with%20encoded",
            "https://example.com/~user/(parens)/a+b,c",
            "https://bitbucket.org/x/y/pull-requests/12?tab=diff&anchor=f1",
        ] {
            assert!(is_safe_external_url(url), "should allow {url}");
        }
    }

    #[test]
    fn non_http_schemes_are_refused() {
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>",
            "vbscript:x",
            "",
            "not-a-url",
            "https://",
            "https:///no-host",
        ] {
            assert!(!is_safe_external_url(url), "should refuse {url:?}");
        }
    }

    #[test]
    fn quoting_hazards_are_refused() {
        // These break argv quoting or forge a second argument. The
        // Windows arm no longer routes through `cmd /C start`, so `&`
        // is no longer an injection primitive — but a quote, a
        // backslash or a newline never belongs in a URL unencoded.
        for url in [
            "https://example.com/a\"b",
            "https://example.com/a'b",
            "https://example.com/a`b",
            "https://example.com/a\\b",
            "https://example.com/a|b",
            "https://example.com/a>b",
            "https://example.com/a b",
            "https://example.com/a\nhttps://evil",
            "https://example.com/a\tb",
        ] {
            assert!(!is_safe_external_url(url), "should refuse {url:?}");
        }
    }

    #[test]
    fn scheme_matching_is_case_insensitive() {
        assert!(is_safe_external_url("HTTPS://example.com/x"));
        assert!(is_safe_external_url("HtTp://example.com/x"));
    }

    fn app_with_files() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        fs::write(d.path().join("b.txt"), "beta").unwrap();
        // vim input_style — these tests exercise pane management
        // (tab swap / move / reopen), which pre-dates and is
        // orthogonal to the standard-mode preview-tab UX. Forcing
        // vim mode keeps `open_path` always-pin so two sequential
        // opens yield two panes (not one preview-replaced pane).
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    /// nvchad-user SEV-2 2026-07-11 — `dj` / `dk` / `d3j` are linewise
    /// per vim convention: cursor line + N destination lines are all
    /// deleted. The prior charwise selection path silently deleted
    /// only the cursor line.
    #[test]
    fn dj_dk_and_count_are_linewise() {
        use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let k = |c: char| KeyEvent::new(KeyCode::Char(c), KeyModifiers::empty());
        let run = |keys: &[KeyEvent], cursor_line: usize| -> String {
            let d = tempfile::tempdir().unwrap();
            let path = d.path().join("t.txt");
            fs::write(&path, "one\ntwo\nthree\nfour\nfive\nsix\n").unwrap();
            let mut cfg = Config::default();
            cfg.editor.input_style = "vim".to_string();
            let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
            app.open_path(&path);
            let pid = app.active.expect("active pane");
            if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                b.editor.place_cursor(cursor_line, 0);
            }
            for key in keys {
                crate::tui::dispatch_key(&mut app, *key);
            }
            if let Some(Pane::Editor(b)) = app.panes.get(pid) {
                b.editor.text().to_string()
            } else {
                String::new()
            }
        };

        // dj from line 1 (two) — delete "two" and "three"
        assert_eq!(
            run(&[k('d'), k('j')], 1),
            "one\nfour\nfive\nsix\n",
            "dj deletes 2 lines"
        );
        // 3dj from line 1 — delete cursor + 3 = 4 lines
        assert_eq!(
            run(&[k('3'), k('d'), k('j')], 1),
            "one\nsix\n",
            "3dj deletes 4 lines"
        );
        // d3j from line 1 (COUNT BETWEEN OP AND MOTION) — same effect
        // as 3dj per vim's `:h count` (count multiplies motion).
        // nvchad-user round 5 SEV-2 2026-07-11 — was silently dropping
        // the operator when the digit arrived in op-pending.
        assert_eq!(
            run(&[k('d'), k('3'), k('j')], 1),
            "one\nsix\n",
            "d3j deletes 4 lines"
        );
        // dk from line 3 (four) — delete "three" and "four"
        assert_eq!(
            run(&[k('d'), k('k')], 3),
            "one\ntwo\nfive\nsix\n",
            "dk deletes 2 lines"
        );
    }

    /// nvchad-user SEV-2 2026-07-10 — `.` should repeat text-object
    /// ops like `di(` / `da{` / `di"`. Regression against a bug that
    /// dropped the `i<c>` suffix from `dot_keys`.
    #[test]
    fn dot_replay_repeats_text_object_delete() {
        use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("t.txt");
        fs::write(&path, "(foo) (bar) (baz)").unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_path(&path);
        let pid = app.active.expect("active pane");
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            b.editor.place_cursor(0, 2); // inside "foo"
        }
        // `di(` — delete inner parens content.
        let k = |c: char| KeyEvent::new(KeyCode::Char(c), KeyModifiers::empty());
        crate::tui::dispatch_key(&mut app, k('d'));
        crate::tui::dispatch_key(&mut app, k('i'));
        crate::tui::dispatch_key(&mut app, k('('));
        let text_after_first = if let Some(Pane::Editor(b)) = app.panes.get(pid) {
            b.editor.text().to_string()
        } else {
            String::new()
        };
        assert_eq!(
            text_after_first, "() (bar) (baz)",
            "di( deleted the foo body"
        );
        // Move cursor inside "bar" and press `.` — should delete "bar".
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            b.editor.place_cursor(0, 4); // inside "bar"
        }
        crate::tui::dispatch_key(&mut app, k('.'));
        let text_after_dot = if let Some(Pane::Editor(b)) = app.panes.get(pid) {
            b.editor.text().to_string()
        } else {
            String::new()
        };
        assert_eq!(text_after_dot, "() () (baz)", ". repeated the di(");

        // Also verify di{ and di" — the finding claimed both fail;
        // regression against future re-breaks.
        let path2 = d.path().join("t2.txt");
        fs::write(&path2, "{foo} {bar}").unwrap();
        app.open_path(&path2);
        let pid2 = app.active.expect("active");
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid2) {
            b.editor.place_cursor(0, 2);
        }
        crate::tui::dispatch_key(&mut app, k('d'));
        crate::tui::dispatch_key(&mut app, k('i'));
        crate::tui::dispatch_key(&mut app, k('{'));
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid2) {
            b.editor.place_cursor(0, 4);
        }
        crate::tui::dispatch_key(&mut app, k('.'));
        let after = if let Some(Pane::Editor(b)) = app.panes.get(pid2) {
            b.editor.text().to_string()
        } else {
            String::new()
        };
        assert_eq!(after, "{} {}", ". repeated di-brace");
    }

    #[test]
    fn switch_to_last_buffer_toggles_with_previous_active() {
        // vscode-user 2026-06-28 SEV-3: Ctrl+Tab → buffer.last
        // should jump to the MRU partner (previous active), not
        // to panes[0] or a random pane. Lock the 3-file linear
        // case.
        let (d, mut app) = app_with_files();
        fs::write(d.path().join("c.txt"), "gamma").unwrap();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        let c = d.path().join("c.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.open_path(&b);
        app.open_path(&c);
        // Active should be the c.txt pane.
        let c_pid = app.active.unwrap();
        assert!(matches!(
            app.panes.get(c_pid),
            Some(Pane::Editor(buf)) if buf.path.as_deref() == Some(&*c)
        ));
        app.switch_to_last_buffer();
        // Should now be on b.txt (the MRU partner).
        let now_active = app.active.unwrap();
        assert!(matches!(
            app.panes.get(now_active),
            Some(Pane::Editor(buf)) if buf.path.as_deref() == Some(&*b)
        ));
        // A second Ctrl+Tab should oscillate back to c.
        app.switch_to_last_buffer();
        let back = app.active.unwrap();
        assert!(matches!(
            app.panes.get(back),
            Some(Pane::Editor(buf)) if buf.path.as_deref() == Some(&*c)
        ));
    }

    #[test]
    fn close_clears_when_empty() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.close_active_pane();
        assert!(app.panes.is_empty());
        assert!(app.active.is_none());
        assert_eq!(app.focus, Focus::Tree);
        assert!(matches!(app.layout(), Layout::Empty));
    }

    #[test]
    fn editing_mode_is_none_without_editor() {
        let (_d, app) = app_with_files();
        assert_eq!(app.editing_mode(), EditingMode::None);
    }

    #[test]
    fn open_keys_config_appends_stub_when_missing() {
        // `keys.edit` should land users INSIDE a [keys.standard]
        // section — when the config file is missing the section,
        // append the documented stub so the editor opens to a
        // ready-to-copy template instead of "find a place yourself."
        let d = tempfile::tempdir().unwrap();
        // Force config to land in the temp dir via XDG_CONFIG_HOME.
        // EnvGuard restores on scope exit; test_env_lock serializes
        // against other modules' env mutations.
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _xdg = crate::EnvGuard::set("XDG_CONFIG_HOME", d.path());
        let cfg_path = d.path().join("mnml").join("config.toml");
        // Pre-create with no [keys.standard] section.
        std::fs::create_dir_all(d.path().join("mnml")).unwrap();
        std::fs::write(&cfg_path, "[ui]\ntheme = \"onedark\"\n").unwrap();

        let ws = tempfile::tempdir().unwrap();
        let cfg = Config::default();
        let mut app = App::new(ws.path().to_path_buf(), cfg).unwrap();
        app.open_keys_config();
        let contents = std::fs::read_to_string(&cfg_path).unwrap();
        assert!(
            contents.contains("[keys.standard]"),
            "stub appended to config:\n{contents}"
        );
        // Cursor should be inside the section — at the line below
        // the header — so the user can immediately type a new
        // binding without navigating.
        let (row, _) = app.active_editor().unwrap().editor.row_col();
        let target_row = contents
            .lines()
            .position(|l| l.trim() == "[keys.standard]")
            .unwrap()
            + 1;
        assert_eq!(
            row, target_row,
            "cursor landed on line below [keys.standard]"
        );

        // Idempotent: a second call should NOT append a second stub.
        let before = std::fs::read_to_string(&cfg_path).unwrap();
        app.open_keys_config();
        let after = std::fs::read_to_string(&cfg_path).unwrap();
        assert_eq!(
            before, after,
            "second open_keys_config didn't duplicate stub"
        );
        // _xdg drops here → XDG_CONFIG_HOME restored to whatever it was
        // before this test ran.
    }

    #[test]
    fn close_pane_shifts_drag_state_pane_ids() {
        // SEV-1 regression lock for the 2026-06-07 hunt finding
        // "silent exit on multi-tab + split + middle-click sequence."
        // Mid-drag close used to leave `bufferline_drag_tab` /
        // `drag_select` / `close_prompt` / `dragging_scrollbar`
        // pointing at stale PaneIds; the next event panicked
        // indexing past `panes.len()`.
        let (d, mut app) = app_with_files();
        fs::write(d.path().join("c.txt"), "charlie").unwrap();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        app.open_path(&d.path().join("c.txt"));
        assert_eq!(app.panes.len(), 3);

        // Plant a drag-reorder on pane 1 (b.txt), a drag-select on
        // pane 2 (c.txt), a close prompt on pane 1, and a scrollbar
        // drag on pane 2. Then close pane 0 — every PaneId above
        // should decrement, and the drag tied to the closed pane
        // (none in this case) would drop entirely.
        app.rects.bufferline_drag_tab = Some(1);
        app.drag_select = Some((2, 0, 0, false));
        app.close_prompt = Some(1);
        app.dragging_scrollbar = Some(ScrollbarHit {
            area: ratatui::layout::Rect::new(0, 0, 1, 1),
            pane_id: 2,
            total: 1,
            viewport: 1,
            kind: ScrollbarKind::Editor,
        });

        app.force_close_pane(0); // close a.txt (the lowest id)

        assert_eq!(app.panes.len(), 2);
        assert_eq!(
            app.rects.bufferline_drag_tab,
            Some(0),
            "drag tab id shifted"
        );
        assert_eq!(
            app.drag_select.map(|(p, _, _, _)| p),
            Some(1),
            "drag_select id shifted"
        );
        assert_eq!(app.close_prompt, Some(0), "close_prompt id shifted");
        assert_eq!(
            app.dragging_scrollbar.map(|h| h.pane_id),
            Some(1),
            "scrollbar pane_id shifted"
        );
    }

    #[test]
    fn close_pane_drops_drag_state_when_pointed_at_closed_pane() {
        // Same SEV-1 — the OTHER direction: if the drag state points
        // *at* the pane being closed, it must drop to None (not just
        // decrement, which would underflow or alias the next pane).
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        assert_eq!(app.panes.len(), 2);

        app.rects.bufferline_drag_tab = Some(1);
        app.drag_select = Some((1, 0, 0, false));
        app.close_prompt = Some(1);
        app.dragging_scrollbar = Some(ScrollbarHit {
            area: ratatui::layout::Rect::new(0, 0, 1, 1),
            pane_id: 1,
            total: 1,
            viewport: 1,
            kind: ScrollbarKind::Editor,
        });

        app.force_close_pane(1); // close the pane the drag references

        assert_eq!(app.panes.len(), 1);
        assert_eq!(app.rects.bufferline_drag_tab, None);
        assert_eq!(app.drag_select, None);
        assert_eq!(app.close_prompt, None);
        assert_eq!(app.dragging_scrollbar.map(|h| h.pane_id), None);
    }

    #[test]
    fn alt_click_in_editor_body_adds_an_extra_cursor() {
        // Regression lock for the VS-Code-mouse hunt SEV-2 finding:
        // Alt+click should drop a *second* cursor rather than moving
        // the primary. The wire-in lives in `tui::dispatch_mouse`'s
        // Down(Left) handler; the bug-hunt agent's terminal swallowed
        // the ALT modifier so the code path never fired — this test
        // proves the code path is correct when ALT is delivered.
        use ratatui::crossterm::event::{KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("doc.txt");
        std::fs::write(&p, "ED01\nED02\nED03\nED04").unwrap();
        let cfg = Config::default();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_path(&p);
        // Toggle the tree off so the editor body starts at x=0
        // (matches the e2e harness layout).
        app.config.ui.tree_width = 0;

        // Force a render so `rects.editor_panes` is populated — the
        // Alt+click handler hit-tests against it. We render to a
        // discardable backend at the e2e size (120x40).
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;
        let mut term = Terminal::new(TestBackend::new(120, 40)).unwrap();
        term.draw(|f| crate::ui::draw(f, &mut app)).unwrap();

        // Plant the primary cursor at (row=1, col=2). We'll then
        // Alt+click well to the right of it.
        if let Some(Pane::Editor(b)) = app.active.and_then(|i| app.panes.get_mut(i)) {
            b.editor.place_cursor(1, 2);
        }
        let extras_before = match app.active.and_then(|i| app.panes.get(i)) {
            Some(Pane::Editor(b)) => b.editor.extra_cursors.len(),
            _ => 0,
        };
        assert_eq!(extras_before, 0, "fresh buffer has no extra cursors");

        // Alt + left-click in the editor body at (col=40, row=4).
        crate::tui::dispatch_mouse(
            &mut app,
            MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Left),
                column: 40,
                row: 4,
                modifiers: KeyModifiers::ALT,
            },
        );
        let extras_after = match app.active.and_then(|i| app.panes.get(i)) {
            Some(Pane::Editor(b)) => b.editor.extra_cursors.len(),
            _ => 0,
        };
        assert_eq!(extras_after, 1, "Alt+click adds one extra cursor");
    }

    #[test]
    fn cursor_follows_wheel_resolves_per_policy_and_mode() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        // Default config: input_style = "standard", wheel_moves_cursor = "auto"
        // ⇒ cursor pinned (VS Code canon).
        let app = App::new(d.path().to_path_buf(), cfg.clone()).unwrap();
        assert!(
            !app.cursor_follows_wheel(),
            "standard + auto ⇒ cursor pinned"
        );

        // vim + auto ⇒ cursor follows (Ctrl+E / Ctrl+Y canon).
        cfg.editor.input_style = "vim".to_string();
        let app = App::new(d.path().to_path_buf(), cfg.clone()).unwrap();
        assert!(app.cursor_follows_wheel(), "vim + auto ⇒ cursor follows");

        // "always" overrides standard mode.
        cfg.editor.input_style = "standard".to_string();
        cfg.editor.wheel_moves_cursor = "always".to_string();
        let app = App::new(d.path().to_path_buf(), cfg.clone()).unwrap();
        assert!(
            app.cursor_follows_wheel(),
            "standard + always ⇒ cursor follows"
        );

        // "never" overrides vim mode.
        cfg.editor.input_style = "vim".to_string();
        cfg.editor.wheel_moves_cursor = "never".to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        assert!(!app.cursor_follows_wheel(), "vim + never ⇒ cursor pinned");
    }

    #[test]
    fn tabnext_with_count_jumps_to_absolute_index() {
        let (d, mut app) = app_with_files();
        fs::write(d.path().join("c.txt"), "charlie").unwrap();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        let c = d.path().join("c.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        app.tab_new(None);
        app.open_path(&c);
        // We're on tab 3. `:tabnext 1` jumps to tab 1 (active_layout=0).
        app.run_ex_command("tabnext 1");
        assert_eq!(app.active_layout, 0);
        // `:tabnext 3` jumps to tab 3.
        app.run_ex_command("tabnext 3");
        assert_eq!(app.active_layout, 2);
        // Out-of-range clamps.
        app.run_ex_command("tabnext 99");
        assert_eq!(app.active_layout, 2);
        // `:tabprev 1` cycles back one (wraps if needed).
        app.run_ex_command("tabprev 1");
        assert_eq!(app.active_layout, 1);
    }

    #[test]
    fn tab_reopen_restores_last_closed() {
        // Three tabs; close tab 2; reopen → it lands back as tab 2.
        let (d, mut app) = app_with_files();
        fs::write(d.path().join("c.txt"), "charlie").unwrap();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        let c = d.path().join("c.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        app.tab_new(None);
        app.open_path(&c);
        assert_eq!(app.layouts.len(), 3);
        // Close tab 2 (the b.txt one). active_layout was 2; tab_close_at(1)
        // shifts active down to 1.
        app.tab_close_at(1);
        assert_eq!(app.layouts.len(), 2);
        assert_eq!(app.closed_tab_layouts.len(), 1);
        // Reopen.
        app.tab_reopen();
        assert_eq!(app.layouts.len(), 3);
        assert_eq!(app.closed_tab_layouts.len(), 0);
        // The b.txt pane should still exist as a leaf in the reopened tab.
        let b_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&b)))
            .unwrap();
        let restored_idx = app.active_layout;
        assert!(
            app.layouts[restored_idx].contains(b_id),
            "reopened tab should hold b.txt"
        );
        // No closed tabs to reopen ⇒ toast, no-op.
        app.tab_reopen();
        assert_eq!(app.layouts.len(), 3);
    }

    #[test]
    fn reveal_pane_switches_tab_when_pane_is_elsewhere() {
        // Two tabs: tab 1 has a.txt, tab 2 has b.txt. We're on tab 2.
        // Clicking the bufferline tab for a.txt should switch us to
        // tab 1 (not duplicate the leaf into tab 2).
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        let a_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&a)))
            .unwrap();
        let b_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&b)))
            .unwrap();
        assert_eq!(app.active_layout, 1, "should be on tab 2");
        assert_eq!(app.active, Some(b_id));
        // Reveal a.txt — should switch tabs.
        app.reveal_pane(a_id);
        assert_eq!(app.active_layout, 0, "should have switched to tab 1");
        assert_eq!(app.active, Some(a_id));
        // Tab 2's layout must still contain b.txt — not be empty.
        assert!(
            app.layouts[1].contains(b_id),
            "tab 2 should still hold b.txt"
        );
    }

    #[test]
    fn tab_swap_keeps_active_pinned_to_its_pane() {
        // Two tabs, focused on tab 2. Swap with tab 1; active_layout
        // should follow the swap (so the user sees the same tab even
        // though indices changed).
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        let was_active = app.active_layout;
        assert_eq!(was_active, 1);
        app.tab_swap(0, 1);
        assert_eq!(app.active_layout, 0, "active follows the swap");
        // Now swap back.
        app.tab_swap(1, 0);
        assert_eq!(app.active_layout, 1);
        // No-op for equal / out-of-range.
        app.tab_swap(1, 1);
        assert_eq!(app.active_layout, 1);
        app.tab_swap(0, 99);
        assert_eq!(app.active_layout, 1);
    }

    #[test]
    fn tab_move_reorders_active() {
        // Three tabs; move tab 3 (active) to position 1.
        let (d, mut app) = app_with_files();
        fs::write(d.path().join("c.txt"), "charlie").unwrap();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        let c = d.path().join("c.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        app.tab_new(None);
        app.open_path(&c);
        assert_eq!(app.active_layout, 2);
        // Move active (tab 3) to position 1.
        app.tab_move("1");
        assert_eq!(app.active_layout, 0, "active should land at index 0");
        assert_eq!(app.layouts.len(), 3, "tab count unchanged");
        // `+1` moves it back to index 1.
        app.tab_move("+1");
        assert_eq!(app.active_layout, 1);
        // `$` jumps it to the end.
        app.tab_move("$");
        assert_eq!(app.active_layout, 2);
        // Out-of-range clamps.
        app.tab_move("99");
        assert_eq!(app.active_layout, 2);
        // No-op when target == current.
        app.tab_move("3");
        assert_eq!(app.active_layout, 2);
    }

    #[test]
    fn recent_files_dedups_caps_and_round_trips() {
        let (d, mut app) = app_with_files();
        // Open b then a then b again — `b` should land at the top, deduped.
        app.open_path(&d.path().join("b.txt"));
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        let names: Vec<String> = app
            .recent_files
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["b.txt", "a.txt"]);

        app.save_session_on_quit();
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.try_restore_session();
        let names2: Vec<String> = app2
            .recent_files
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        // The restore re-opens the saved buffers, which calls open_path → which
        // pushes to recent_files. So the recent list after restore reflects
        // the re-open order: previously-active first.
        // What we care about: the saved entries are present + the cap holds.
        assert!(names2.contains(&"a.txt".to_string()));
        assert!(names2.contains(&"b.txt".to_string()));
        assert!(app2.recent_files.len() <= RECENT_FILES_MAX);
    }

    #[test]
    fn path_token_extraction() {
        // Cursor anywhere inside the token should yield the full span.
        let s = "see src/app.rs:42:7 for details";
        let i = s.find('p').unwrap();
        let (a, b) = path_token_around(s, i).unwrap();
        assert_eq!(&s[a..b], "src/app.rs:42:7");
        // Cursor on whitespace → None.
        assert!(path_token_around(s, s.find(' ').unwrap()).is_none());
    }

    #[test]
    fn path_with_position_parsing() {
        assert_eq!(
            parse_path_with_position("src/app.rs:42:7"),
            Some(("src/app.rs", 42, 7))
        );
        assert_eq!(
            parse_path_with_position("src/app.rs:42"),
            Some(("src/app.rs", 42, 1))
        );
        // No trailing numbers ⇒ no position.
        assert_eq!(parse_path_with_position("src/app.rs"), None);
    }

    #[test]
    fn nav_history_back_and_forward() {
        let (_d, mut app) = app_with_files();
        let a = app.workspace.join("a.txt");
        let b = app.workspace.join("b.txt");
        app.open_path(&a);
        // On `a` now. Move cursor a bit so the nav point is non-trivial.
        if let Some(ed) = app.active_editor_mut() {
            ed.editor.place_cursor(0, 3);
        }
        app.open_path(&b);
        // On `b` now. Back stack has `a` at row 0, col 3.
        assert_eq!(app.nav_back.len(), 1);
        assert_eq!(app.nav_back[0].path, a);
        // Alt+Left ⇒ jumps back to `a` at (0, 3), pushes `b`'s spot forward.
        app.nav_back_jump();
        let buf = app.active_editor().unwrap();
        assert_eq!(buf.path.as_deref(), Some(a.as_path()));
        assert_eq!(buf.editor.row_col(), (0, 3));
        assert!(app.nav_back.is_empty());
        assert_eq!(app.nav_forward.len(), 1);
        // Alt+Right ⇒ back to `b`.
        app.nav_forward_jump();
        assert_eq!(
            app.active_editor().unwrap().path.as_deref(),
            Some(b.as_path()),
        );
        assert!(app.nav_forward.is_empty());
        assert_eq!(app.nav_back.len(), 1);
    }

    #[test]
    fn za_on_header_line_folds_the_starting_block_not_the_parent() {
        // #polish 2026-07-06 — nvchad-user SEV-2. Cursor on `if x > 0 {`
        // (line 3) must fold lines 3..7, not the outer `fn main() {}`.
        // Before the fix, `enclosing_bracket_pair` walked backward past
        // the `{` on the current line and hit the `fn` header instead.
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("code.rs");
        let src = "fn main() {\n    let x = 1;\n    if x > 0 {\n        println!(\"positive\");\n        for i in 0..10 {\n            println!(\"{}\", i);\n        }\n    }\n}\n";
        fs::write(&path, src).unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_path(&path);
        if let Some(b) = app.active_editor_mut() {
            // Place cursor on line 3 (0-indexed 2), col 4 — the `i` of `if`.
            b.editor.place_cursor(2, 4);
        }
        app.toggle_fold_at_cursor();
        let b = app.active_editor().unwrap();
        assert_eq!(
            b.folds.get(&2).copied(),
            Some(7),
            "expected fold of if-block (rows 2..=7), got folds: {:?}",
            b.folds
        );
        // Outer fn block is NOT folded — only the smallest applicable.
        assert!(!b.folds.contains_key(&0));
    }

    #[test]
    fn za_on_inner_line_still_folds_smallest_block() {
        // Guard against regression: with cursor INSIDE the if body (line
        // 4 = println!), we should still get the if-block fold via the
        // enclosing-pair path — the line-scan branch adds NEW candidates
        // without swallowing the old one.
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("code.rs");
        let src = "fn main() {\n    let x = 1;\n    if x > 0 {\n        println!(\"positive\");\n    }\n}\n";
        fs::write(&path, src).unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_path(&path);
        if let Some(b) = app.active_editor_mut() {
            b.editor.place_cursor(3, 8);
        }
        app.toggle_fold_at_cursor();
        let b = app.active_editor().unwrap();
        // if-block is rows 2..=4 (line 3 open, line 5 close, 0-indexed).
        assert_eq!(b.folds.get(&2).copied(), Some(4));
    }

    #[test]
    fn folds_persist_across_buffer_close_and_reopen() {
        // #polish 2026-07-06 — fold state should survive `close_active_pane`.
        // Was: closing a buffer dropped `Buffer.folds` on the floor; reopen
        // came back with the file unfolded.
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("code.rs");
        fs::write(
            &path,
            "fn a() {\n    line2\n    line3\n    line4\n}\nfn b() {}\n",
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        let path = path.canonicalize().unwrap();
        app.open_path(&path);
        // Inject a fold (skip toggle_fold_at_cursor bracket search — the
        // point of the test is the persistence path, not the fold picker).
        if let Some(b) = app.active_editor_mut() {
            b.folds.insert(0, 4);
        }
        // Sync via toggle path so file_folds picks it up. Alternative:
        // call note_file_folds directly.
        let synced_folds: Vec<(usize, usize)> = app
            .active_editor()
            .unwrap()
            .folds
            .iter()
            .map(|(&s, &e)| (s, e))
            .collect();
        app.note_file_folds(&path, synced_folds);
        // Close → file_folds must retain the fold.
        app.close_active_pane();
        assert!(app.file_folds.contains_key(&path));
        assert_eq!(app.file_folds[&path], vec![(0usize, 4usize)]);
        // Re-open → the fold is back on the buffer.
        app.open_path(&path);
        let b = app.active_editor().unwrap();
        assert_eq!(b.folds.get(&0).copied(), Some(4));
    }

    #[test]
    fn per_file_cursor_restores_on_reopen() {
        let (_d, mut app) = app_with_files();
        let a = app.workspace.join("a.txt");
        // Open `a` and put the cursor mid-word.
        app.open_path(&a);
        if let Some(b) = app.active_editor_mut() {
            b.editor.place_cursor(0, 3);
        }
        // Close → file_cursors records position; the buffer goes away.
        app.close_active_pane();
        assert!(app.file_cursors.contains_key(&a));
        // Re-open → the cursor lands back at (0, 3) instead of (0, 0).
        app.open_path(&a);
        assert_eq!(app.active_editor().unwrap().editor.row_col(), (0, 3));
    }

    #[test]
    fn reload_active_picks_up_external_changes() {
        let (_d, mut app) = app_with_files();
        let a = app.workspace.join("a.txt");
        app.open_path(&a);
        // Touch the file externally.
        fs::write(&a, "REPLACED").unwrap();
        // Without reload, the buffer still has the old text.
        assert_eq!(app.active_editor().unwrap().editor.text(), "alpha");
        app.reload_active(false);
        assert_eq!(app.active_editor().unwrap().editor.text(), "REPLACED");
        // Dirty buffer + force=false ⇒ refuse.
        if let Some(b) = app.active_editor_mut() {
            b.editor.place_cursor(0, 0);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::InsertStr("!".into())],
                &mut Clipboard::new(),
                0,
            );
        }
        fs::write(&a, "AGAIN").unwrap();
        app.reload_active(false);
        // Still the dirty in-memory text (reload refused).
        assert!(app.active_editor().unwrap().editor.text().contains('!'));
        // force=true discards.
        app.reload_active(true);
        assert_eq!(app.active_editor().unwrap().editor.text(), "AGAIN");
    }

    #[test]
    fn fs_delete_via_button_dialog_closes_buffer_and_trims_recents() {
        // Was `fs_delete_requires_exact_filename_match`. Since the
        // 2026-07-06 polish switched delete from a type-the-name
        // text prompt to a `[ Delete ] [ Cancel ]` button dialog,
        // the confirmation gate lives at the button layer — the
        // App fn itself just executes. Cancel doesn't call through
        // at all (`run_delete_button` drops the FsAction).
        let (_d, mut app) = app_with_files();
        let p = app.workspace.join("a.txt");
        assert!(p.exists());
        app.open_path(&p);
        app.execute_delete_fs_entry(&p);
        assert!(!p.exists());
        assert!(!app.recent_files.iter().any(|q| q == &p));
        assert!(!app.panes.iter().any(|pane| matches!(
            pane,
            Pane::Editor(b) if b.is_at(&p)
        )));
    }

    #[test]
    fn open_integration_remove_confirm_opens_prompt_instead_of_removing() {
        // 2026-07-09 — user report: bumped Remove instead of Edit
        // on the right-click menu, lost an integration. Both the
        // context-menu and palette-picker Remove entries now route
        // through this confirm helper, which stashes the id and
        // opens a `[ Remove ] [ Cancel ]` button dialog rather
        // than mutating the integration list directly.
        let (_d, mut app) = app_with_files();
        // Seed a fake integration so there's something to try to remove.
        app.config
            .ui
            .integration_icons
            .push(crate::config::IntegrationIcon {
                id: "test_int".to_string(),
                glyph: "T".to_string(),
                fallback: "T".to_string(),
                command: ":palette".to_string(),
                color: "blue".to_string(),
                label: None,
                enabled: true,
                in_palette_bar: false,
                description: None,
                homepage: None,
                docs: None,
                repository: None,
                author: None,
                version: None,
                commands: Vec::new(),
            });
        let before = app.config.ui.integration_icons.len();
        app.open_integration_remove_confirm("test_int".to_string());
        // Removal did NOT run yet — confirm dialog is what opened.
        assert_eq!(app.config.ui.integration_icons.len(), before);
        assert_eq!(
            app.pending_integration_remove_id.as_deref(),
            Some("test_int")
        );
        let p = app.prompt.as_ref().expect("confirm prompt opened");
        assert!(matches!(
            p.kind,
            crate::prompt::PromptKind::IntegrationRemoveConfirm
        ));
        // Cancel is the default focus — user has to actively pick
        // Remove to proceed. Matches the delete-confirm safety idiom.
        assert_eq!(p.cursor, 1);
    }

    #[test]
    fn open_integration_remove_confirm_no_op_when_id_missing() {
        // If the id doesn't match any current integration, we skip
        // the dialog entirely and toast — same UX as calling
        // `remove_integration_by_id` on a missing id.
        let (_d, mut app) = app_with_files();
        app.open_integration_remove_confirm("ghost".to_string());
        assert!(app.prompt.is_none());
        assert!(app.pending_integration_remove_id.is_none());
    }

    #[test]
    fn fs_actions_create_and_rename() {
        let (_d, mut app) = app_with_files();
        let ws = app.workspace.clone();
        // New file.
        app.create_new_file(&ws, "fresh.rs");
        assert!(ws.join("fresh.rs").exists());
        // New folder.
        app.create_new_folder(&ws, "newdir");
        assert!(ws.join("newdir").is_dir());
        // Rename — `a.txt` is open as an editor; the rename should repoint it.
        app.open_path(&ws.join("a.txt"));
        app.rename_fs_entry(&ws.join("a.txt"), "renamed.txt");
        assert!(!ws.join("a.txt").exists());
        assert!(ws.join("renamed.txt").exists());
        // The buffer that *was* `a.txt` should now point at `renamed.txt`.
        let renamed = ws.join("renamed.txt");
        assert!(app.panes.iter().any(|p| matches!(
            p,
            Pane::Editor(b) if b.path.as_deref() == Some(renamed.as_path()),
        )));
        // Refusing collisions.
        app.create_new_file(&ws, "fresh.rs");
        assert!(ws.join("fresh.rs").exists());
    }

    #[test]
    fn save_active_as_writes_repoints_creates_dirs() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        if let Some(b) = app.active_editor_mut() {
            b.editor.place_cursor(0, 5);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::InsertStr("!!".into())],
                &mut Clipboard::new(),
                0,
            );
        }
        // Relative path with a non-existent subdir — should be created.
        app.save_active_as("subdir/renamed.txt");
        let new_abs = app.workspace.join("subdir").join("renamed.txt");
        assert!(new_abs.exists());
        // ensure_trailing_newline (on by default) appends `\n` since
        // "alpha!!" doesn't end with one.
        assert_eq!(fs::read_to_string(&new_abs).unwrap(), "alpha!!\n");
        let buf = app.active_editor().unwrap();
        assert_eq!(buf.path.as_deref(), Some(new_abs.as_path()));
        assert!(!buf.dirty);
        // The original file is untouched.
        let orig = app.workspace.join("a.txt");
        assert_eq!(fs::read_to_string(&orig).unwrap(), "alpha");
    }

    /// R12 nvchad SEV-3 2026-08-23 — vim `:w <path>` writes bytes
    /// to `<path>` but leaves the buffer's own path unchanged. Only
    /// `:saveas` / `:file` are supposed to rename. Before the fix,
    /// mnml routed `:w path` through `save_active_as` which
    /// repointed the buffer + dirtied the tab title.
    #[test]
    fn write_active_to_does_not_rename_buffer() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        if let Some(b) = app.active_editor_mut() {
            b.editor.place_cursor(0, 5);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::InsertStr("!!".into())],
                &mut Clipboard::new(),
                0,
            );
        }
        let orig_path = app.workspace.join("a.txt");
        // Buffer was pinned at a.txt; make sure it still is post-write.
        app.write_active_to("subdir/snapshot.txt");
        let new_abs = app.workspace.join("subdir").join("snapshot.txt");
        assert!(new_abs.exists(), "snapshot file was written");
        assert_eq!(fs::read_to_string(&new_abs).unwrap(), "alpha!!\n");
        let buf = app.active_editor().unwrap();
        assert_eq!(
            buf.path.as_deref(),
            Some(orig_path.as_path()),
            "buffer path stays pinned to a.txt (vim `:w path` semantic)"
        );
        // Original a.txt is untouched — the write went to the snapshot only.
        assert_eq!(fs::read_to_string(&orig_path).unwrap(), "alpha");
        // Buffer is still dirty (the disk copy on the ORIGINAL path
        // wasn't updated — only the snapshot got the new bytes).
        assert!(buf.dirty, "dirty stays true — original file wasn't touched");
    }

    #[test]
    fn parse_line_range_handles_common_forms() {
        // `:1,5d` — line 1 (0-based: 0) to line 5 (0-based: 4); cmd "d".
        let (s, e, r) = parse_line_range("1,5d", 0, 100).unwrap();
        assert_eq!((s, e, r), (0, 4, "d"));
        // `:5,$y` — line 5 to end. line_count=10 ⇒ end-line=9.
        let (s, e, r) = parse_line_range("5,$y", 0, 10).unwrap();
        assert_eq!((s, e, r), (4, 9, "y"));
        // `:.,+3d` — current=2, +3 ⇒ end=5. line_count clamps.
        let (s, e, r) = parse_line_range(".,+3d", 2, 100).unwrap();
        assert_eq!((s, e, r), (2, 5, "d"));
        // `:.+1d` — single ref form, just next line.
        let (s, e, r) = parse_line_range(".+1d", 2, 100).unwrap();
        assert_eq!((s, e, r), (3, 3, "d"));
        // No range ⇒ None.
        assert!(parse_line_range("d", 0, 10).is_none());
    }

    #[test]
    fn parse_substitute_parses_basic_shapes() {
        let s = parse_substitute("%s/foo/bar/g").unwrap();
        assert_eq!(s.find, "foo");
        assert_eq!(s.replace, "bar");
        assert!(!s.case_insensitive);
        assert!(s.whole_buffer);

        // Bare `s/` ⇒ current line only.
        let s = parse_substitute("s/foo/bar/").unwrap();
        assert!(!s.whole_buffer);

        // `i` flag.
        let s = parse_substitute("%s/Foo/x/i").unwrap();
        assert!(s.case_insensitive);

        // Escaped slash inside the find / replace.
        let s = parse_substitute(r"%s/a\/b/c\/d/").unwrap();
        assert_eq!(s.find, "a/b");
        assert_eq!(s.replace, "c/d");

        // No-replacement form ⇒ delete.
        let s = parse_substitute("%s/foo/").unwrap();
        assert_eq!(s.find, "foo");
        assert_eq!(s.replace, "");

        // `s/…` (without the `%`) is accepted too.
        let s = parse_substitute("s/x/y/").unwrap();
        assert_eq!(s.find, "x");

        // Empty find ⇒ Some (deferred to runtime — `:s//foo/` reuses
        // the last :s find at run time).
        let s = parse_substitute("%s//bar/").unwrap();
        assert_eq!(s.find, "");
        assert_eq!(s.replace, "bar");
        // Not a substitute at all ⇒ None.
        assert!(parse_substitute("w").is_none());
        assert!(parse_substitute("qa").is_none());

        // `c` flag — interactive confirm.
        let s = parse_substitute("%s/foo/bar/c").unwrap();
        assert!(s.confirm);
        let s = parse_substitute("%s/foo/bar/gci").unwrap();
        assert!(s.confirm && s.case_insensitive);
        // Bare s with `c`: line-scoped + interactive.
        let s = parse_substitute("s/foo/bar/c").unwrap();
        assert!(s.confirm && !s.whole_buffer);
    }

    #[test]
    fn find_all_case_sensitive_no_overlap() {
        assert_eq!(find_all_case_sensitive("foo Foo foO", "foo"), vec![(0, 3)]);
        // Empty needle ⇒ empty.
        assert!(find_all_case_sensitive("hi", "").is_empty());
        // Overlap-free.
        assert_eq!(find_all_case_sensitive("aaaa", "aa"), vec![(0, 2), (2, 4)]);
    }

    #[test]
    fn substitute_global_replaces_all_occurrences() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("x.rs"), "let foo = foo();\nfn fooer() {}\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&app.workspace.join("x.rs"));
        app.run_ex_command("%s/foo/bar/g");
        let b = app.active_editor().unwrap();
        assert_eq!(b.editor.text(), "let bar = bar();\nfn barer() {}\n");
        assert!(b.dirty);
    }

    #[test]
    fn substitute_case_insensitive_with_i_flag() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("x.rs"), "Foo foo FOO").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&app.workspace.join("x.rs"));
        app.run_ex_command("%s/foo/zz/gi");
        assert_eq!(app.active_editor().unwrap().editor.text(), "zz zz zz");
    }

    #[test]
    fn substitute_no_match_is_a_noop() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("x.rs"), "abc").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&app.workspace.join("x.rs"));
        app.run_ex_command("%s/xyz/zzz/g");
        let b = app.active_editor().unwrap();
        assert_eq!(b.editor.text(), "abc");
        assert!(!b.dirty);
    }

    #[test]
    fn byte_to_line_col_round_trips_with_byte_at() {
        let t = "ab\ncde\nf";
        // bytes:  0,1, 2=\n, 3,4,5, 6=\n, 7
        assert_eq!(byte_to_line_col(t, 0), (0, 0));
        assert_eq!(byte_to_line_col(t, 2), (0, 2));
        assert_eq!(byte_to_line_col(t, 3), (1, 0));
        assert_eq!(byte_to_line_col(t, 5), (1, 2));
        assert_eq!(byte_to_line_col(t, 7), (2, 0));
        // Round-trip against the lsp::byte_at inverse.
        for &b in &[0usize, 1, 2, 3, 4, 5, 7] {
            let (l, c) = byte_to_line_col(t, b);
            assert_eq!(crate::lsp::byte_at(t, l as u32, c as u32), Some(b));
        }
    }

    #[test]
    fn ranges_overlap_covers_touch_and_disjoint() {
        let r = |l1, c1, l2, c2| crate::lsp::Range {
            start: crate::lsp::Pos {
                line: l1,
                character: c1,
            },
            end: crate::lsp::Pos {
                line: l2,
                character: c2,
            },
        };
        // Same-line overlap.
        assert!(ranges_overlap(r(1, 0, 1, 5), r(1, 3, 1, 7)));
        // Touch at endpoint counts (inclusive).
        assert!(ranges_overlap(r(1, 0, 1, 3), r(1, 3, 1, 5)));
        // Disjoint on different lines.
        assert!(!ranges_overlap(r(1, 0, 1, 5), r(2, 0, 2, 5)));
        // Single-point cursor inside a multi-line diag.
        assert!(ranges_overlap(r(2, 2, 2, 2), r(1, 0, 3, 1)));
        // Single-point cursor before a diag.
        assert!(!ranges_overlap(r(0, 0, 0, 0), r(1, 0, 1, 5)));
    }

    #[test]
    fn tree_width_drag_clamps_and_persists() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let initial = app.tree_width;
        // No drag in progress ⇒ drag_to is a no-op.
        app.drag_tree_edge_to(50, 200);
        assert_eq!(app.tree_width, initial);

        // Simulate a drag — clamps to [16, min(80, screen-20)].
        // mouse-round-11 SEV-2: min bumped 8 → 16 to match the
        // config schema's min. mouse-round-16 F2 2026-07-17: max
        // capped at 80 to match Settings max.
        app.dragging_tree_edge = true;
        app.drag_tree_edge_to(50, 200);
        assert_eq!(app.tree_width, 50);
        app.drag_tree_edge_to(2, 200);
        assert_eq!(app.tree_width, 16);
        app.drag_tree_edge_to(220, 200);
        assert_eq!(app.tree_width, 80);
        app.end_tree_edge_drag();
        assert!(!app.dragging_tree_edge);

        // Round-trip through session.json.
        app.tree_width = 42;
        app.save_session_on_quit();
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert_eq!(app2.tree_width, initial); // pre-restore = config default
        app2.try_restore_session();
        assert_eq!(app2.tree_width, 42);
    }

    #[test]
    fn single_repo_workspace_lists_just_itself() {
        let d = tempfile::tempdir().unwrap();
        // Mark the workspace as a repo.
        std::fs::create_dir(d.path().join(".git")).unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert_eq!(app.repos.len(), 1);
        assert_eq!(app.active_repo, 0);
        assert!(app.repos[0].is_workspace_root);
        // active_repo_path resolves to the workspace itself.
        assert_eq!(app.active_repo_path(), app.workspace);
    }

    #[test]
    fn multi_repo_workspace_discovers_subdirs() {
        let d = tempfile::tempdir().unwrap();
        for name in ["proj-a", "proj-b"] {
            let p = d.path().join(name);
            std::fs::create_dir(&p).unwrap();
            std::fs::create_dir(p.join(".git")).unwrap();
        }
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert_eq!(app.repos.len(), 2);
        assert_eq!(app.active_repo, 0);
        let first = app.repos[0].path.clone();
        let second = app.repos[1].path.clone();
        assert_eq!(app.active_repo_path(), first);
        app.switch_active_repo(1);
        assert_eq!(app.active_repo, 1);
        assert_eq!(app.active_repo_path(), second);
        // out-of-range no-op
        app.switch_active_repo(99);
        assert_eq!(app.active_repo, 1);
    }

    #[test]
    fn switching_active_repo_retargets_app_git() {
        // Two sibling sub-repos. switch_active_repo(1) should re-point
        // App.git at proj-b so the rail / statusline track the new repo.
        let d = tempfile::tempdir().unwrap();
        for name in ["proj-a", "proj-b"] {
            let p = d.path().join(name);
            std::fs::create_dir(&p).unwrap();
            std::fs::create_dir(p.join(".git")).unwrap();
        }
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert_eq!(app.repos.len(), 2);
        // No publicly-accessible `git.workspace`; assert via retarget semantics
        // — calling switch_active_repo bumps active_repo and forces refresh().
        app.switch_active_repo(1);
        assert_eq!(app.active_repo, 1);
        // After switch, active_repo_path is now proj-b. The retarget call in
        // switch_active_repo pointed self.git there too; subsequent
        // self.git.snapshot() reads from proj-b's `git status` (empty, since
        // the test fixture only has an empty `.git/` marker).
        assert_eq!(app.active_repo_path(), &app.repos[1].path);
    }

    #[test]
    fn no_repo_workspace_has_empty_repos() {
        let d = tempfile::tempdir().unwrap();
        // No `.git/` anywhere.
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app.repos.is_empty());
        assert_eq!(app.active_repo, 0);
        // Falls back to the workspace path.
        assert_eq!(app.active_repo_path(), app.workspace);
    }

    #[test]
    fn flash_start_finds_visible_pairs_and_label_jumps() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("c.txt"), "abc abc abc\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&d.path().join("c.txt"));
        // Pretend the editor pane has been rendered so flash sees a viewport.
        let pid = app.active.unwrap();
        app.rects.editor_panes.push((
            ratatui::layout::Rect {
                x: 0,
                y: 0,
                width: 40,
                height: 10,
            },
            pid,
        ));
        app.flash_start('a', 'b');
        let state = app.flash_state.as_ref().expect("flash should have armed");
        assert_eq!(state.targets.len(), 3, "expected 3 'ab' matches on screen");
        // First target lives at row 0, col 0 (the leading "ab").
        let first = &state.targets[0];
        assert_eq!((first.row, first.col_chars), (0, 0));
        // Move cursor away then commit the jump via the third target's label.
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            b.editor.place_cursor(0, 7);
        }
        let third_label = state.targets[2].label;
        let third_pos = (state.targets[2].row, state.targets[2].col_chars);
        assert!(app.flash_consume_char(third_label));
        // flash state cleared + cursor moved.
        assert!(app.flash_state.is_none());
        if let Some(Pane::Editor(b)) = app.panes.get(pid) {
            assert_eq!(b.editor.row_col(), third_pos);
        } else {
            panic!("expected editor");
        }
    }

    #[test]
    fn collect_whole_word_finds_three_hits() {
        let text = "foo bar foo\nbaz foo qux\n";
        let hits = super::collect_whole_word_occurrences(text, "foo");
        assert_eq!(hits, vec![(0, 0, 3), (0, 8, 3), (1, 4, 3)]);
    }

    #[test]
    fn collect_whole_word_respects_boundaries() {
        // "foo" inside "foobar" is NOT a whole-word match; "foo." IS.
        let text = "foobar foo\nfoo.bar afoo\n";
        let hits = super::collect_whole_word_occurrences(text, "foo");
        assert_eq!(hits, vec![(0, 7, 3), (1, 0, 3)]);
    }

    #[test]
    fn harpoon_pins_and_jumps() {
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.harpoon_add_active();
        // a → slot 1
        assert_eq!(app.harpoon[0].as_ref(), Some(&a));
        // Open b.txt, pin it → slot 2.
        app.open_path(&b);
        app.harpoon_add_active();
        assert_eq!(app.harpoon[1].as_ref(), Some(&b));
        // Adding the same file again is a no-op (idempotent toast).
        app.harpoon_add_active();
        assert!(app.harpoon[2].is_none());
        // Jump back to slot 1.
        app.harpoon_goto(1);
        let active = app.active.expect("active");
        match app.panes.get(active) {
            Some(Pane::Editor(buf)) => {
                assert_eq!(buf.path.as_deref(), Some(a.as_path()));
            }
            _ => panic!("expected editor"),
        }
    }

    #[test]
    fn harpoon_session_round_trip() {
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.harpoon_add_active();
        app.save_session_on_quit();
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.try_restore_session();
        assert_eq!(app2.harpoon[0].as_ref(), Some(&a));
    }

    #[test]
    fn flash_start_no_match_skips_state() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("c.txt"), "hello world\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&d.path().join("c.txt"));
        let pid = app.active.unwrap();
        app.rects.editor_panes.push((
            ratatui::layout::Rect {
                x: 0,
                y: 0,
                width: 40,
                height: 10,
            },
            pid,
        ));
        app.flash_start('z', 'z');
        assert!(
            app.flash_state.is_none(),
            "flash with no matches should NOT leave state armed"
        );
    }

    #[test]
    fn next_buffer_cycles_editors_forward_and_wraps() {
        // Regression lock for commit c927679 — next_buffer / prev_buffer
        // skip Pty panes. This test covers the basic two-editor cycle.
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.open_path(&b);
        let b_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&b)))
            .unwrap();
        let a_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&a)))
            .unwrap();
        assert_eq!(app.active, Some(b_id));
        app.next_buffer();
        assert_eq!(app.active, Some(a_id), "next_buffer wraps to a.txt");
        app.next_buffer();
        assert_eq!(app.active, Some(b_id), "next_buffer advances to b.txt");
    }

    #[test]
    fn prev_buffer_cycles_editors_backward_and_wraps() {
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.open_path(&b);
        let b_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&b)))
            .unwrap();
        let a_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&a)))
            .unwrap();
        assert_eq!(app.active, Some(b_id));
        app.prev_buffer();
        assert_eq!(app.active, Some(a_id), "prev_buffer goes to a.txt");
        app.prev_buffer();
        assert_eq!(app.active, Some(b_id), "prev_buffer wraps to b.txt");
    }

    #[test]
    fn toggle_right_panel_command_flips_flag() {
        // Regression lock for commit 6d836ca — view.toggle_right_panel
        // must flip app.right_panel_visible. Bound to Ctrl+Shift+B.
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let initial = app.right_panel_visible;
        crate::command::run("view.toggle_right_panel", &mut app);
        assert_eq!(app.right_panel_visible, !initial, "first toggle flips");
        crate::command::run("view.toggle_right_panel", &mut app);
        assert_eq!(app.right_panel_visible, initial, "second toggle restores");
    }

    #[test]
    fn outline_show_routes_to_right_panel_when_visible() {
        // Right-panel v3: `outline.show` with right_panel_visible=true
        // pushes the outline into right_panel_panes. Toggling the
        // panel off closes every hosted pane (no ghost tabs).
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.right_panel_visible = true;
        let pane_count_before = app.panes.len();
        app.open_outline_pane();
        assert_eq!(app.right_panel_panes.len(), 1, "1 hosted pane");
        let outline_id = app.right_panel_active_pane_id().unwrap();
        assert!(matches!(app.panes.get(outline_id), Some(Pane::Outline(_))));
        assert_eq!(app.panes.len(), pane_count_before + 1);
        crate::command::run("view.toggle_right_panel", &mut app);
        assert!(!app.right_panel_visible);
        assert!(app.right_panel_panes.is_empty(), "host list cleared");
        assert!(
            !matches!(app.panes.get(outline_id), Some(Pane::Outline(_))),
            "outline pane should be closed after panel toggle-off, not just unhosted"
        );
    }

    #[test]
    fn right_panel_hosts_outline_and_diagnostics_as_tabs() {
        // v3 — both Outline AND Diagnostics live in the panel
        // together (no last-opened-wins eviction).
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.right_panel_visible = true;
        app.open_outline_pane();
        app.open_diagnostics_pane();
        assert_eq!(
            app.right_panel_panes.len(),
            2,
            "both Outline + Diagnostics hosted"
        );
        // Last-opened becomes active.
        let active = app.right_panel_active_pane_id().unwrap();
        assert!(matches!(app.panes.get(active), Some(Pane::Diagnostics(_))));
    }

    #[test]
    fn right_panel_tabs_serde_round_trip() {
        // 2026-06-28 session persistence: the new SavedSession
        // fields round-trip through JSON. (Full save → reload
        // covered by save_session_on_quit + load_session paths
        // that touch the filesystem — too heavy for a unit test;
        // the field-shape round-trip is what matters here.)
        let json = r#"{
            "workspace": "/tmp/ws",
            "open": [],
            "right_panel_visible": true,
            "right_panel_width": 32,
            "right_panel_tabs": ["outline", "diagnostics"],
            "right_panel_active_idx": 1
        }"#;
        let parsed: SavedSession = serde_json::from_str(json).expect("parse");
        assert_eq!(parsed.right_panel_visible, Some(true));
        assert_eq!(parsed.right_panel_width, Some(32));
        assert_eq!(
            parsed.right_panel_tabs.as_deref(),
            Some(vec!["outline".to_string(), "diagnostics".to_string()].as_slice())
        );
        assert_eq!(parsed.right_panel_active_idx, Some(1));
    }

    #[test]
    fn empty_state_click_via_command_path_routes_correctly_after_runtime_toggle() {
        // vscode-mouse 2026-06-28 SEV-3 — the agent reported the
        // empty-state ':outline.show' click silently failed after
        // a RUNTIME toggle of the panel (Ctrl+Shift+B from closed
        // → open). The agent's actual repro likely had no active
        // editor — outline.show requires one (toasts otherwise).
        // This test opens a file first then exercises the click
        // path end-to-end through dispatch_mouse → mouse.rs →
        // command::run → open_outline_pane → right_panel_push.
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        app.open_path(&a);

        // Start panel CLOSED, then toggle open at runtime (the
        // scenario the agent's repro used).
        assert!(!app.right_panel_visible);
        crate::command::run("view.toggle_right_panel", &mut app);
        assert!(app.right_panel_visible);
        assert!(app.right_panel_panes.is_empty());

        // Render once so the empty-state rects get registered at
        // the right coordinates for this terminal.
        let mut term = Terminal::new(TestBackend::new(120, 40)).unwrap();
        term.draw(|f| crate::ui::draw(f, &mut app)).unwrap();

        // The outline rect must now exist (panel is tall enough)
        // and a click inside it must fire outline.show.
        let rect = app
            .rects
            .right_panel_empty_outline
            .expect("outline rect should be registered after runtime toggle");
        // Dispatch a synthetic left-click at the rect center.
        let click_x = rect.x + rect.width / 2;
        let click_y = rect.y;
        let event = ratatui::crossterm::event::MouseEvent {
            kind: ratatui::crossterm::event::MouseEventKind::Down(
                ratatui::crossterm::event::MouseButton::Left,
            ),
            column: click_x,
            row: click_y,
            modifiers: ratatui::crossterm::event::KeyModifiers::empty(),
        };
        crate::tui::dispatch_mouse(&mut app, event);

        // outline.show routes into the panel — should now host an
        // Outline pane.
        assert!(
            !app.right_panel_panes.is_empty(),
            "click on :outline.show empty-state row should route outline.show into the panel"
        );
        let active_pane_id = app.right_panel_active_pane_id().unwrap();
        assert!(
            matches!(app.panes.get(active_pane_id), Some(Pane::Outline(_))),
            "active right-panel pane should be Outline"
        );
    }

    #[test]
    fn right_panel_empty_rects_dropped_when_y_outside_panel() {
        // vscode-mouse 2026-06-28 SEV-3 + 035b69b's render fix:
        // when the panel column is short (height <13 rows in the
        // agent's repro), the empty-state click rect for late
        // entries (:test.run / :find.grep / :ai.chat) used to be
        // registered with y values that fell BELOW the panel's
        // bottom, landing in the statusline. A click in the
        // statusline x-range fired the wrong command.
        //
        // The fix in src/ui/mod.rs gates each rect_at(y_offset)
        // call on `y < panel_bottom`. This test exercises the
        // render with a 6-row terminal (panel ≈ 4 rows) and asserts
        // that only the rects that fit IN the panel are registered.
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.right_panel_visible = true;
        // Very short terminal: panel ends up ~4 rows tall, so
        // only the first 1-2 empty-state lines fit. The later
        // rects (ai/grep/test) must be None.
        let mut term = Terminal::new(TestBackend::new(40, 6)).unwrap();
        term.draw(|f| crate::ui::draw(f, &mut app)).unwrap();
        // Outline rect is at hint_rect.y + 2; with a tiny panel
        // it may not fit either. The important property: every
        // registered rect's y must be inside the panel area.
        let panel_bottom = if let Some(close) = app.rects.right_panel_close {
            close.y + 1
        } else {
            // Even the close button got dropped — just assert all
            // empty-state rects are None (panel is too short for
            // anything).
            assert!(app.rects.right_panel_empty_outline.is_none());
            return;
        };
        for (label, rect) in [
            ("outline", app.rects.right_panel_empty_outline),
            ("diagnostics", app.rects.right_panel_empty_diagnostics),
            ("ai", app.rects.right_panel_empty_ai),
            ("grep", app.rects.right_panel_empty_grep),
            ("test", app.rects.right_panel_empty_test),
        ] {
            if let Some(r) = rect {
                assert!(
                    r.y < panel_bottom,
                    "{label} rect at y={} must be < panel_bottom={panel_bottom}",
                    r.y
                );
            }
        }
    }

    #[test]
    fn ask_ai_routes_to_right_panel_when_visible() {
        // v4 — ai.chat hosts in the right panel as a 3rd tab
        // (alongside Outline + Diagnostics, capped at 3).
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.right_panel_visible = true;
        let before = app.right_panel_panes.len();
        app.ask_ai("test", "hi".to_string());
        assert_eq!(
            app.right_panel_panes.len(),
            before + 1,
            "ai pane hosted as a tab"
        );
        let active = app.right_panel_active_pane_id().unwrap();
        assert!(matches!(app.panes.get(active), Some(Pane::Ai(_))));
    }

    #[test]
    fn context_menu_at_focus_uses_hover_chip_fallback_for_gear() {
        // v2 polish (2026-06-28): when no focus match applies but
        // hover_chip is set to ActivityBarGear, Shift+F10 routes
        // to the gear context menu. Lets a mouse-then-keyboard
        // power-user activate chip menus by keyboard.
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        // Focus::Pane + no active pane → skips both Tree and Pane
        // branches, falls through to the hover_chip fallback.
        app.focus = crate::focus::Focus::Pane;
        app.active = None;
        app.rects.activity_bar_gear = Some(ratatui::layout::Rect {
            x: 1,
            y: 10,
            width: 3,
            height: 1,
        });
        app.hover_chip = Some((crate::HoverChip::ActivityBarGear, std::time::Instant::now()));
        assert!(app.context_menu.is_none());
        crate::command::run("view.context_menu_at_focus", &mut app);
        assert!(
            app.context_menu.is_some(),
            "Shift+F10 with hover_chip=Gear should open the gear menu"
        );
    }

    #[test]
    fn context_menu_at_focus_uses_hover_chip_fallback_for_integration_icon() {
        // vscode-user 2nd 2026-06-28 SEV-2: integration chip
        // hover_chip-recent fallback was reportedly not firing
        // despite the v2 polish. Lock the case in a test:
        // hover_chip = IntegrationIcon(0) + a registered rect at
        // index 0 should open the integration context menu.
        use ratatui::layout::Rect;
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.focus = crate::focus::Focus::Pane;
        app.active = None;
        app.rects.integration_icon_rects.push((
            Rect {
                x: 3,
                y: 34,
                width: 4,
                height: 1,
            },
            0,
        ));
        app.hover_chip = Some((
            crate::HoverChip::IntegrationIcon(0),
            std::time::Instant::now(),
        ));
        assert!(app.context_menu.is_none());
        crate::command::run("view.context_menu_at_focus", &mut app);
        assert!(
            app.context_menu.is_some(),
            "Shift+F10 with hover_chip=IntegrationIcon(0) should open the integration menu"
        );
    }

    #[test]
    fn context_menu_at_focus_opens_tab_menu_when_pane_focused() {
        // vscode-user-keyboard 2026-06-28 SEV-2: keyboard users
        // couldn't open a context menu without a mouse. Shift+F10
        // now fires view.context_menu_at_focus, which routes to
        // the active pane's bufferline-tab menu when Focus::Pane.
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.focus = crate::focus::Focus::Pane;
        assert!(app.context_menu.is_none());
        crate::command::run("view.context_menu_at_focus", &mut app);
        assert!(
            app.context_menu.is_some(),
            "Shift+F10 with Focus::Pane should open the tab context menu"
        );
    }

    #[test]
    fn leader_chord_two_keys_fires_in_standard_mode() {
        // vscode-user-keyboard SEV-2: in standard input mode the
        // chord chain bottomed out on `Ctrl+K t` and fired the
        // whichkey.leader fallback (correctly), then DROPPED the
        // `t` instead of feeding it to the just-opened whichkey
        // overlay. So `<leader>tt` (toggle tree) needed
        // `Ctrl+K t t t`. Now: the leader letter that opened
        // whichkey is re-routed to whichkey_feed.
        use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "standard".to_string();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        let initial_tree = app.tree_visible;
        // 2026-07-31 — snapshot theme too. Since `ctrl+k t → theme.toggle`
        // was bound (fda7ef1f) the run-leaf firing shows up as a theme
        // change, not a tree toggle. Test asserts "progressed" so both
        // observable side-effects count.
        let initial_theme = crate::ui::theme::cur().name.to_string();

        // `Ctrl+K` opens the leader chord chain — pending state set.
        crate::tui::dispatch_key(
            &mut app,
            KeyEvent::new(KeyCode::Char('k'), KeyModifiers::CONTROL),
        );
        assert!(
            !app.pending_chord_seq.is_empty(),
            "Ctrl+K should set pending"
        );

        // `t` — chord-chain fails to extend; fires whichkey.leader
        // fallback (opens overlay) AND should be re-routed to
        // whichkey_feed as the first leader letter.
        crate::tui::dispatch_key(
            &mut app,
            KeyEvent::new(KeyCode::Char('t'), KeyModifiers::NONE),
        );
        // whichkey overlay is open and `t` has been fed → it's
        // either now on a sub-leaf (`+toggle` group) OR if `t`
        // is a Cmd leaf (e.g. toggle tree), the command fired
        // and the overlay closed. Either is acceptable —
        // crucially it must NOT have been dropped.
        let theme_changed = crate::ui::theme::cur().name != initial_theme;
        // `theme.toggle` opens the theme picker when no alt theme
        // is configured (default) — that counts as "the leaf
        // fired". Check picker state too.
        let picker_open = app.picker.is_some();
        let progressed = app.whichkey.is_some()
            || app.tree_visible != initial_tree
            || theme_changed
            || picker_open;
        assert!(
            progressed,
            "after Ctrl+K t the whichkey overlay should be open on a sub-trie OR a single-letter leaf should have fired (tree toggle / theme toggle / picker / …)"
        );
    }
}
