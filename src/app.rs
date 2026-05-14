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

const TOAST_TTL: Duration = Duration::from_secs(4);

/// Cap on `App::recent_files`. Tuned to "deep enough to remember a few tasks
/// ago, short enough that the picker isn't a wall of text."
const RECENT_FILES_MAX: usize = 20;

/// Cap on `App::file_cursors`. Per-file last-position state isn't tied to the
/// recent-files cap because the user may legitimately revisit files long after
/// they've dropped off `recent_files`.
const FILE_CURSORS_MAX: usize = 200;

/// Cap on each nav stack — deep enough to cover a few investigation chains,
/// shallow enough that the old end is never load-bearing.
const NAV_STACK_MAX: usize = 50;

/// Cap on recent find queries — newer entries push older ones off.
const FIND_HISTORY_MAX: usize = 50;

/// Cap on the recently-closed-buffers stack — newer entries push older ones off.
const CLOSED_BUFFERS_MAX: usize = 20;

/// One entry on a navigation stack — a file + a `(row, col)` so we can jump
/// back even if the buffer's text has shifted since (the precise byte offset
/// would be stale; row/col is a more forgiving anchor).
#[derive(Debug, Clone)]
pub struct NavPoint {
    pub path: PathBuf,
    pub row: usize,
    pub col: usize,
}

/// Direction for `Ctrl+W`-style focus navigation between splits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusDir {
    Left,
    Right,
    Up,
    Down,
}

/// True when `path`'s extension marks it as Markdown — used by the outline
/// pane to extract headings directly instead of going through the LSP.
fn is_markdown_path(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some("md" | "markdown" | "mdx" | "mkd")
    )
}

/// `p` made relative to `workspace` (for `git` arguments). Falls back to `p` if
/// it isn't under `workspace`.
fn rel_path(workspace: &Path, p: &Path) -> String {
    p.strip_prefix(workspace)
        .unwrap_or(p)
        .to_string_lossy()
        .into_owned()
}

/// A short text rendering of a CDP `RemoteObject` (console args, eval results).
fn cdp_remote_object_str(o: &serde_json::Value) -> String {
    if let Some(v) = o.get("value") {
        return match v {
            serde_json::Value::String(s) => s.clone(),
            other => other.to_string(),
        };
    }
    if let Some(u) = o
        .get("unserializableValue")
        .and_then(serde_json::Value::as_str)
    {
        return u.to_string();
    }
    if let Some(d) = o.get("description").and_then(serde_json::Value::as_str) {
        return d.to_string();
    }
    o.get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("?")
        .to_string()
}

/// True if a CDP `Network.*` event's resource `type` is worth showing in the
/// browser pane (the page + its data calls — not the asset firehose). `None`
/// (type absent) is treated as interesting (it's usually the main document).
fn cdp_resource_type_is_interesting(rtype: Option<&str>) -> bool {
    !matches!(
        rtype,
        Some(
            "Image"
                | "Media"
                | "Font"
                | "Stylesheet"
                | "Script"
                | "TextTrack"
                | "Manifest"
                | "Other"
                | "Prefetch"
                | "SignedExchange"
        )
    )
}

/// Shorten a URL for a log line: drop the scheme, keep `host/path` (no query),
/// truncate. (Cross-origin hosts are kept so it's clear; same-origin still shows
/// the host — fine for a one-line log.)
fn cdp_short_url(url: &str) -> String {
    let body = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    let body = body.split(['?', '#']).next().unwrap_or(body);
    if body.chars().count() <= 70 {
        body.to_string()
    } else {
        let keep: String = body.chars().take(69).collect();
        format!("{keep}…")
    }
}

/// Render a `Runtime.evaluate` reply (`{result:{result:<RemoteObject>, exceptionDetails?}}`) to text.
fn cdp_eval_result_text(v: &serde_json::Value) -> String {
    let res = v.get("result");
    if let Some(ex) = res.and_then(|r| r.get("exceptionDetails")) {
        let msg = ex
            .get("exception")
            .and_then(|e| e.get("description"))
            .and_then(serde_json::Value::as_str)
            .or_else(|| ex.get("text").and_then(serde_json::Value::as_str))
            .unwrap_or("exception");
        return format!("⚠ {}", msg.lines().next().unwrap_or(msg));
    }
    res.and_then(|r| r.get("result"))
        .map(cdp_remote_object_str)
        .unwrap_or_else(|| "undefined".to_string())
}

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
#[derive(Debug, PartialEq, Eq)]
struct Substitute {
    find: String,
    replace: String,
    /// True ⇒ case-insensitive match (`i` flag).
    case_insensitive: bool,
}

fn parse_substitute(line: &str) -> Option<Substitute> {
    // Accept `%s/…` and the leading-`:`-already-stripped form. The vim parser
    // also accepts `:s/…/…/g` for current-line; we treat that as buffer-wide
    // for now (cursor line isn't tracked separately here).
    let rest = line
        .strip_prefix("%s/")
        .or_else(|| line.strip_prefix("s/"))?;
    // Split into find / replace / flags on unescaped `/`. `\/` and `\\` survive.
    let mut parts: Vec<String> = Vec::with_capacity(3);
    let mut cur = String::new();
    let mut chars = rest.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('/') => cur.push('/'),
                Some('\\') => cur.push('\\'),
                Some('n') => cur.push('\n'),
                Some('t') => cur.push('\t'),
                Some(other) => {
                    cur.push('\\');
                    cur.push(other);
                }
                None => cur.push('\\'),
            }
        } else if c == '/' {
            parts.push(std::mem::take(&mut cur));
            if parts.len() == 2 {
                // Everything after the second `/` is flags (no more splits).
                let flags: String = chars.collect();
                parts.push(flags);
                break;
            }
        } else {
            cur.push(c);
        }
    }
    if parts.len() < 2 {
        // `:%s/foo` — no replacement field. Treat as `:%s/foo//` (delete).
        parts.push(String::new());
    }
    let find = parts.remove(0);
    let replace = parts.remove(0);
    let flags = parts.first().cloned().unwrap_or_default();
    if find.is_empty() {
        return None;
    }
    let case_insensitive = flags.contains('i');
    Some(Substitute {
        find,
        replace,
        case_insensitive,
    })
}

/// `(line, character)` of `byte` in `text` — the inverse of [`crate::lsp::byte_at`].
/// Both 0-based; `character` is a char count (matches how we feed positions to
/// the LSP elsewhere). A byte past the end clamps to the last line's end.
fn byte_to_line_col(text: &str, byte: usize) -> (usize, usize) {
    let cap = byte.min(text.len());
    let line = text[..cap].bytes().filter(|&b| b == b'\n').count();
    let line_start = text[..cap].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let col = text[line_start..cap].chars().count();
    (line, col)
}

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
    /// leaf, the others remain as background tabs).
    #[serde(default)]
    layout: Option<SavedLayout>,
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
    /// Was the `> GIT` section in the rail expanded?
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git_section_expanded: Option<bool>,
    /// Directories the user had expanded in the file tree. `None` (an older
    /// session.json without the field) ⇒ keep the default first-level expand.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tree_expanded_dirs: Option<Vec<String>>,
    /// Most-recently-opened files, newest first (capped on save).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    recent_files: Vec<String>,
    /// The active theme name when we quit. `None` ⇒ launch picks the default
    /// (or whatever `[ui] theme` in the config file says).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    theme: Option<String>,
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
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SavedGlobalMark {
    letter: char,
    path: String,
    row: usize,
    col: usize,
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
struct SavedBuffer {
    path: String,
    cursor_byte: usize,
    scroll: usize,
}

/// A serializable mirror of [`Layout`] where leaves carry indices into
/// `SavedSession.open` instead of `PaneId`s.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
enum SavedLayout {
    Empty,
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
fn byte_to_row_col(text: &str, byte: usize) -> (usize, usize) {
    let byte = byte.min(text.len());
    let row = text[..byte].bytes().filter(|&b| b == b'\n').count();
    let line_start = text[..byte].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let col = text[line_start..byte].chars().count();
    (row, col)
}

/// Place the buffer's cursor at byte offset `byte` (clamped). Used by snippet
/// expansion to land on `$N` / `$0` markers without hand-walking the cursor
/// glyph by glyph.
fn place_cursor_at_byte(b: &mut Buffer, byte: usize) {
    let (row, col) = byte_to_row_col(b.editor.text(), byte);
    b.editor.place_cursor(row, col);
}

/// Replace the named block inside an `.http` / `.rest` source with the
/// pre-rendered `new_block` text, leaving every other block untouched.
/// `name` is what `RequestPane.source_block_name` stored — `Some(s)` means
/// the matched block had `### s` (or `### ` alone when `s.is_empty()`); the
/// only `None` case here is a single-block file, which the caller handles
/// separately. Returns `None` when the file no longer parses as multi-block,
/// or no block matches — caller falls back to whole-file overwrite.
fn splice_http_block(existing: &str, name: Option<&str>, new_block: &str) -> Option<String> {
    let blocks = crate::http::file::parse_all(existing).ok()?;
    if blocks.len() < 2 {
        return None;
    }
    let lines: Vec<&str> = existing.split('\n').collect();
    // Resolve the `### name` separator on each block (`Block.name` is the text
    // after `###`; we also need to know whether the block had a separator at
    // all, since the leading block in a multi-block file doesn't).
    let block_separator_name = |b: &crate::http::file::Block| -> Option<String> {
        lines
            .get(b.start_line)
            .and_then(|l| l.trim_start().strip_prefix("###"))
            .map(|rest| rest.trim().to_string())
    };
    let target_idx = blocks.iter().position(|b| match name {
        // Match both "had a `###` separator" and the right name.
        Some(want) => block_separator_name(b).is_some_and(|n| n == want),
        // We only call this with `Some(name)` from the caller, but stay safe.
        None => block_separator_name(b).is_none(),
    })?;
    let target = &blocks[target_idx];
    let last_idx = lines.len().saturating_sub(1);
    let end = target.end_line.min(last_idx);
    // The replacement carries its own trailing newline (from `as_http_block`).
    // Trim it before splicing so the file's existing line structure isn't
    // double-newlined when we re-join.
    let replacement = new_block.trim_end_matches('\n');
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    out.extend(lines[..target.start_line].iter().map(|s| s.to_string()));
    for line in replacement.split('\n') {
        out.push(line.to_string());
    }
    if end < last_idx {
        out.extend(lines[end + 1..].iter().map(|s| s.to_string()));
    }
    let mut joined = out.join("\n");
    // Preserve the original file's trailing-newline policy.
    if existing.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    Some(joined)
}

/// Workspace grep — try `rg --vimgrep` first (fast, gitignore-aware), fall back
/// to `git grep -n --column` if `rg` isn't on PATH. Returns parsed hits + which
/// tool produced them (used for the `Pane::Grep` title's "rg: …" / "git grep: …"
/// prefix).
fn grep_workspace(
    workspace: &std::path::Path,
    query: &str,
) -> (Vec<crate::grep_pane::GrepHit>, &'static str) {
    use crate::grep_pane::parse_rg_vimgrep;
    use std::process::Command;
    if let Ok(o) = Command::new("rg")
        .arg("--vimgrep")
        .arg("--no-heading")
        .arg("--smart-case")
        .arg(query)
        .arg(".")
        .current_dir(workspace)
        .output()
        && o.status.success()
        && !o.stdout.is_empty()
    {
        return (
            parse_rg_vimgrep(&String::from_utf8_lossy(&o.stdout), workspace),
            "rg",
        );
    }
    // git grep fallback (works in any repo even without rg installed).
    if let Ok(o) = Command::new("git")
        .args(["grep", "-n", "--column", "-I", "-e"])
        .arg(query)
        .current_dir(workspace)
        .output()
        && o.status.success()
        && !o.stdout.is_empty()
    {
        return (
            parse_rg_vimgrep(&String::from_utf8_lossy(&o.stdout), workspace),
            "git grep",
        );
    }
    (Vec::new(), "rg")
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

/// Hand `path` to the OS's default app — `open <path>` on macOS, `xdg-open` on
/// Linux, `cmd /C start` on Windows. Best-effort: errors are swallowed (so a
/// headless / sandboxed env where none of those are available is fine).
fn open_path_external(path: &std::path::Path) {
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
    /// The 1-cell-wide draggable "right edge" of the rail. Click+drag adjusts
    /// `App::tree_width` so the rail resizes live.
    pub tree_edge: Option<Rect>,
    /// The `> GIT` section header row in the rail (when the rail's visible).
    /// Click → `App::toggle_git_section_expanded`.
    pub git_section_toggle: Option<Rect>,
    /// `(rect, hit)` per visible row in the GIT section. Click → focus + run
    /// the row's default action; right-click → context menu.
    pub git_rail_rows: Vec<(Rect, crate::git::rail::GitRailHit)>,
    pub bufferline: Option<Rect>,
    /// `(rect, pane_id)` for each tab in the bufferline (whole tab → activate).
    pub bufferline_tabs: Vec<(Rect, PaneId)>,
    /// `(rect, pane_id)` for each tab's close badge (the trailing `×`/`●` → close).
    pub bufferline_tab_close: Vec<(Rect, PaneId)>,
    /// The whole central split-tree area.
    pub body: Option<Rect>,
    /// `(text_area, pane_id)` per visible editor leaf — the editable region
    /// (gutter excluded). Click → focus that leaf + place the cursor; also the
    /// geometry `Ctrl+W`-style focus navigation uses.
    pub editor_panes: Vec<(Rect, PaneId)>,
    /// `(chip_rect, pane_id, fold_start_line)` per rendered `⋯ N hidden`
    /// chip — click on one to unfold that block. Cleared + rebuilt per
    /// editor render.
    pub fold_chips: Vec<(Rect, PaneId, usize)>,
    /// One entry per split divider, with enough info to drag-resize it.
    pub split_dividers: Vec<crate::layout::DividerHit>,
    pub statusline: Option<Rect>,
    /// The picker overlay's outer box (when open) and `(rect, filtered-index)` per visible row.
    pub picker_box: Option<Rect>,
    pub picker_items: Vec<(Rect, usize)>,
    /// On-screen cell where the picker's query caret should sit (when open).
    pub picker_caret: Option<(u16, u16)>,
    /// `(rect, choice)` per button in the close-confirm overlay (0=Save, 1=Discard, 2=Cancel).
    pub close_prompt_buttons: Vec<(Rect, u8)>,
    /// On-screen cell where the text-input prompt's caret should sit (when open).
    pub prompt_caret: Option<(u16, u16)>,
    /// The context-menu overlay's outer box (when open) and `(rect, item-index)` per row.
    pub context_menu_box: Option<Rect>,
    pub context_menu_items: Vec<(Rect, usize)>,
}

pub struct App {
    pub workspace: PathBuf,
    pub config: Config,
    pub panes: Vec<Pane>,
    pub layout: Layout,
    /// The focused pane id. Invariant (see [`crate::layout`]): every pane is in
    /// exactly one leaf, so this uniquely identifies the focused leaf. `None` ⇔
    /// `layout == Empty` ⇔ no panes open.
    pub active: Option<PaneId>,
    pub focus: Focus,
    pub tree: Tree,
    pub tree_visible: bool,
    /// Current rail width (cells). Initialized from `[ui] tree_width` and
    /// then mutable via mouse-drag on the rail's right edge. Persisted in
    /// `session.json`.
    pub tree_width: u16,
    /// True while the user is mid-drag on the rail's right-edge handle.
    /// Cleared on mouse-up; clamps `tree_width` to a sane range during drag.
    pub dragging_tree_edge: bool,
    /// Bufferline horizontal scroll — index of the leftmost rendered tab. Auto
    /// adjusts on every render to keep the active tab visible (the user never
    /// has to scroll it manually). Reset when the pane count drops past it.
    pub bufferline_first_visible: usize,
    /// "Zen" focus mode (`view.zen`): hide the tree rail, bufferline, and
    /// statusline; the editor takes the full window. Independent of the other
    /// visibility flags, which are remembered separately. Not persisted —
    /// always starts off so a fresh launch is a normal IDE view.
    pub zen_mode: bool,
    /// Most-recently-opened files, newest first, capped at `RECENT_FILES_MAX`.
    /// Updated every time `open_path` opens a file. Persisted in session.json.
    pub recent_files: Vec<PathBuf>,
    /// Stack of recently closed buffers (`(path, cursor_byte, scroll)`),
    /// newest last. `buffer.reopen` (`Ctrl+Shift+T`) pops the top entry
    /// and re-opens it. Capped at `CLOSED_BUFFERS_MAX`. Not persisted —
    /// closing-then-reopening across sessions is what `recent_files` is for.
    pub closed_buffers: Vec<(PathBuf, usize, usize)>,
    /// Per-file last `(cursor_byte, scroll)`, captured when a buffer is closed
    /// or saved, restored when the file is re-opened later. Persisted in
    /// session.json so it survives restarts. Capped at `FILE_CURSORS_MAX`.
    pub file_cursors: std::collections::HashMap<PathBuf, (usize, usize)>,
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
    /// Last mouse left-click for double/triple-click detection — `(when, x,
    /// y, count)`. Reset to count=1 when a click lands too late or in a
    /// different cell. Read by `dispatch_mouse` to upgrade count==2 → word
    /// select, count==3 → line select.
    pub last_click: Option<(std::time::Instant, u16, u16, u8)>,
    /// When `[editor] format_on_save = true`, `save_active` fires
    /// `lsp.format` and stashes `(path, deadline)` here. The next
    /// `LspEvent::Formatting` matching `path` applies + chains a save; if
    /// the deadline passes without a reply, `tick` saves anyway (misbehaving
    /// LSPs can't gate save).
    pub pending_format_save: Option<(PathBuf, std::time::Instant)>,
    /// Is the workspace "section" inside the rail expanded? When `false` the
    /// rail shows just the `> WORKSPACE-NAME` header (clickable to expand);
    /// when `true` it shows the header (`v WORKSPACE-NAME`) + the file list.
    /// Independent of [`Self::tree_visible`] (which controls the rail itself,
    /// `Ctrl+B`). Future sibling sections (OUTLINE, TIMELINE, …) would each
    /// own their own expanded flag here.
    pub tree_root_expanded: bool,
    /// The persistent `GIT` section in the rail — local branches + worktrees,
    /// refreshed on every git-changing action via [`Self::after_git_change`].
    pub git_rail: crate::git::rail::GitRail,
    /// Is the `> GIT` rail section expanded? Sibling of [`Self::tree_root_expanded`].
    /// Persisted in session.json. Default `true`.
    pub git_section_expanded: bool,
    /// Which rail section the keyboard is on when `focus == Focus::Tree`.
    /// Switched by ↓ off the end of the workspace list / ↑ off the top of the
    /// git list, or by clicking a row in the other section.
    pub rail_section: RailSection,
    pub git: GitStatus,
    pub toast: Option<(String, Instant)>,
    pub should_quit: bool,
    /// Set alongside `should_quit` when the loop should exit *for a rebuild+relaunch*
    /// (the `run.sh` wrapper watches for the distinct exit code).
    pub restart_requested: bool,
    /// `view.redraw` (`Ctrl+L`) — clear the terminal backing buffer before the
    /// next paint so a scrambled terminal repaints cleanly. The crossterm loop
    /// checks + clears this flag at the top of each iteration.
    pub redraw_requested: bool,
    /// True after a quit was refused because of unsaved changes — a second
    /// `request_quit` then goes through. Cleared by saving.
    pub quit_armed: bool,
    pub rects: PaneRects,
    /// The active register / system-clipboard bridge, threaded into `Editor::apply`.
    pub clipboard: Clipboard,
    /// The fuzzy-picker / command-palette overlay, when open. Steals key input.
    pub picker: Option<Picker>,
    /// Resolved key→command table (registry defaults + `[keys.*]` config).
    /// Rebuilt when the input style changes (a mode section may rebind a chord).
    pub keymap: crate::input::keymap::Keymap,
    /// While a leader sequence is in flight: the keys typed after `<leader>`
    /// (`Some("")` ⇒ the popup just opened). Steals key input like the picker.
    pub whichkey: Option<String>,
    /// The split divider currently being dragged (between mouse-down on it and
    /// mouse-up), so drag events resize *that* split even off-target.
    pub dragging: Option<crate::layout::DividerHit>,
    /// A buffer whose close is awaiting a Save/Discard/Cancel decision (the
    /// confirm overlay is up). Steals key input like the picker.
    pub close_prompt: Option<PaneId>,
    /// The single-line text-input overlay (commit message, …), when open. Steals
    /// key input like the picker.
    pub prompt: Option<crate::prompt::Prompt>,
    /// The right-click context menu, when open. Steals key + mouse input.
    pub context_menu: Option<crate::context_menu::ContextMenu>,
    /// The LSP hover popup, when open (set when a `textDocument/hover` reply
    /// arrives). The next key dismisses it (j/k/arrows scroll it first).
    pub hover: Option<crate::hover::HoverPopup>,
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
    pending_code_action_path: Option<PathBuf>,
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
    /// Snapshot of the active buffer's find state when the Find prompt
    /// opened — restored on Esc-cancel so incremental find doesn't leak
    /// matches when the user bails. `Some(None)` ⇒ "previously cleared";
    /// `None` ⇒ no Find prompt in flight.
    pub find_preview_snapshot: Option<Option<crate::buffer::FindState>>,
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
    /// Branch name awaiting the "type the name to confirm" prompt that the
    /// git-rail's branch right-click menu opens (→ `git branch -D`).
    pending_delete_branch: Option<String>,
    /// `(path, basename)` of a worktree awaiting the same kind of confirm
    /// prompt (→ `git worktree remove`).
    pending_worktree_remove: Option<(PathBuf, String)>,
    /// The file-system action waiting on its name prompt — captured when the
    /// `NewFile` / `NewFolder` / `Rename` context-menu items open the prompt.
    pending_fs_action: Option<FsAction>,
    /// The as-you-type LSP completion popup, when open. Populated from a
    /// `textDocument/completion` reply (auto-triggered as you type, or via
    /// `lsp.completion`); re-filtered locally as you keep typing.
    pub completion: Option<crate::completion::CompletionPopup>,
    /// Channel for background HTTP sends (lazily created on the first `rqst.send`):
    /// worker threads send `(job_id, result)`; [`Self::tick`] drains it and updates
    /// the matching `Pane::Request`.
    http_chan: Option<(
        std::sync::mpsc::Sender<HttpJobDone>,
        std::sync::mpsc::Receiver<HttpJobDone>,
    )>,
    /// Channel for background `claude -p` runs (lazily created); worker threads
    /// stream `(job_id, AiMsg)` (deltas then a final Done/Failed), [`Self::tick`]
    /// drains it into the matching `Pane::Ai`.
    ai_chan: Option<(
        std::sync::mpsc::Sender<AiJobMsg>,
        std::sync::mpsc::Receiver<AiJobMsg>,
    )>,
    /// Channel for background `npx playwright test` runs → the matching `Pane::Tests`.
    tests_chan: Option<(
        std::sync::mpsc::Sender<TestsJobDone>,
        std::sync::mpsc::Receiver<TestsJobDone>,
    )>,
    /// Receiver for the (single) CDP browser session's worker — events stream in,
    /// [`Self::tick`] drains them into the `Pane::Browser`. `None` when no browser
    /// pane is open (only one at a time in the first cut).
    cdp_chan: Option<std::sync::mpsc::Receiver<crate::cdp::CdpEvent>>,
    /// Job id of an in-flight "AI: write me a commit message" run (it shares
    /// `ai_chan`; when it lands, the commit prompt opens pre-seeded instead of an
    /// answer landing in a `Pane::Ai`).
    pending_commit_msg_job: Option<u64>,
    /// Same as `pending_commit_msg_job`, but for `git.ai_recompose` (rewrite
    /// HEAD's message). The reply lands as a [`PromptKind::GitCommitAmend`]
    /// prompt that calls `git commit --amend -m` on accept.
    pending_amend_msg_job: Option<u64>,
    next_job_id: u64,
    /// Commands registered at runtime by IPC plugins (`register-command`). They
    /// show up in the palette/which-key + keymap; invoking one queues its id in
    /// `pending_plugin_invocations` for the IPC layer to log as an event.
    pub dynamic_commands: Vec<crate::command::DynCommand>,
    /// Plugin-command ids invoked since the IPC layer last drained them.
    pending_plugin_invocations: Vec<String>,
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

impl App {
    pub fn new(workspace: PathBuf, config: Config) -> Result<App, String> {
        let workspace = workspace
            .canonicalize()
            .map_err(|e| format!("cannot open workspace {}: {e}", workspace.display()))?;
        let tree = Tree::open(&workspace);
        let git = GitStatus::new(&workspace);
        let lsp = crate::lsp::LspManager::new(&workspace, &config);
        let test_history = crate::playwright::history::TestHistory::load(&workspace);
        let keymap = crate::input::keymap::Keymap::build(&config);
        let git_rail = {
            let mut r = crate::git::rail::GitRail::empty();
            r.refresh(&workspace);
            r
        };
        let tree_width = config.ui.tree_width;
        Ok(App {
            workspace,
            config,
            panes: Vec::new(),
            layout: Layout::Empty,
            active: None,
            focus: Focus::Tree,
            tree,
            tree_visible: true,
            tree_width,
            dragging_tree_edge: false,
            bufferline_first_visible: 0,
            zen_mode: false,
            recent_files: Vec::new(),
            closed_buffers: Vec::new(),
            file_cursors: std::collections::HashMap::new(),
            global_marks: std::collections::HashMap::new(),
            nav_back: Vec::new(),
            nav_forward: Vec::new(),
            last_click: None,
            pending_format_save: None,
            // VS-Code-style: the rail is shown with its workspace section
            // expanded by default. The last session's choice overrides this
            // in `try_restore_session`.
            tree_root_expanded: true,
            git_rail,
            git_section_expanded: true,
            rail_section: RailSection::Workspace,
            git,
            toast: None,
            should_quit: false,
            restart_requested: false,
            redraw_requested: false,
            quit_armed: false,
            rects: PaneRects::default(),
            clipboard: Clipboard::new(),
            picker: None,
            keymap,
            whichkey: None,
            dragging: None,
            close_prompt: None,
            prompt: None,
            context_menu: None,
            hover: None,
            signature: None,
            pending_rename: None,
            pending_code_actions: Vec::new(),
            pending_code_action_path: None,
            pending_code_action_auto_apply: false,
            pending_outline: false,
            pending_snippets: Vec::new(),
            snippet_session: None,
            pending_workspace_symbols: Vec::new(),
            pending_workspace_symbol_query: None,
            find_regex_default: false,
            find_preview_snapshot: None,
            find_preview_cursor: 0,
            find_history: Vec::new(),
            find_history_cursor: 0,
            pending_branch_source: None,
            pending_delete_branch: None,
            pending_worktree_remove: None,
            pending_fs_action: None,
            completion: None,
            http_chan: None,
            ai_chan: None,
            tests_chan: None,
            cdp_chan: None,
            pending_commit_msg_job: None,
            pending_amend_msg_job: None,
            next_job_id: 1,
            dynamic_commands: Vec::new(),
            pending_plugin_invocations: Vec::new(),
            lsp,
            test_history,
        })
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

    // ─── context menu (right-click) ─────────────────────────────────
    /// Right-click in the file tree on `path` (at screen cell `anchor`).
    pub fn open_tree_context_menu(&mut self, path: PathBuf, is_dir: bool, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        let rel = rel_path(&self.workspace, &path);
        // `parent` for new-file/new-folder: the dir itself when right-clicked
        // on a directory, the file's parent dir when right-clicked on a file.
        let parent = if is_dir {
            path.clone()
        } else {
            path.parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| self.workspace.clone())
        };
        let items = if is_dir {
            vec![
                MenuItem::new("New file…", MenuAction::NewFile(parent.clone())),
                MenuItem::new("New folder…", MenuAction::NewFolder(parent)),
                MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
                MenuItem::new("Delete…", MenuAction::Delete(path.clone())),
                MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                MenuItem::new("Open externally", MenuAction::OpenExternally(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
                MenuItem::new("Refresh tree", MenuAction::Command("tree.refresh")),
            ]
        } else {
            let mut items = vec![
                MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
                MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            ];
            if is_markdown_path(&path) {
                items.push(MenuItem::new(
                    "Preview markdown",
                    MenuAction::PreviewMarkdown(path.clone()),
                ));
            }
            items.extend([
                MenuItem::new("New file…", MenuAction::NewFile(parent.clone())),
                MenuItem::new("New folder…", MenuAction::NewFolder(parent)),
                MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
                MenuItem::new("Delete…", MenuAction::Delete(path.clone())),
                MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                MenuItem::new("Open externally", MenuAction::OpenExternally(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            ]);
            items
        };
        self.context_menu = Some(ContextMenu::new(Some(name), anchor, items));
    }

    /// Right-click on a bufferline tab (the pane `id`) at screen cell `anchor`.
    pub fn open_tab_context_menu(&mut self, id: PaneId, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self.panes.get(id).map(Pane::title).unwrap_or_default();
        let mut items = vec![
            MenuItem::new("Close", MenuAction::CloseTab(id)),
            MenuItem::new("Close others", MenuAction::CloseOtherTabs(id)),
            MenuItem::new("Close all", MenuAction::CloseAllTabs),
        ];
        if let Some(Pane::Editor(b)) = self.panes.get(id)
            && let Some(p) = &b.path
        {
            if is_markdown_path(p) {
                items.push(MenuItem::new(
                    "Preview markdown",
                    MenuAction::PreviewMarkdown(p.clone()),
                ));
            }
            items.push(MenuItem::new(
                "Copy path",
                MenuAction::CopyPath(rel_path(&self.workspace, p)),
            ));
        }
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    pub fn context_menu_cancel(&mut self) {
        self.context_menu = None;
    }
    pub fn context_menu_move(&mut self, delta: isize) {
        if let Some(m) = &mut self.context_menu {
            if delta < 0 {
                m.move_up();
            } else {
                m.move_down();
            }
        }
    }
    pub fn context_menu_select(&mut self, i: usize) {
        if let Some(m) = &mut self.context_menu {
            m.set_selected(i);
        }
    }
    /// Run the highlighted context-menu item and close the menu.
    pub fn context_menu_accept(&mut self) {
        let Some(menu) = self.context_menu.take() else {
            return;
        };
        let Some(item) = menu.items.into_iter().nth(menu.selected) else {
            return;
        };
        self.run_menu_action(item.action);
    }

    fn run_menu_action(&mut self, action: crate::context_menu::MenuAction) {
        use crate::context_menu::MenuAction::*;
        match action {
            OpenPath(p) => self.open_path(&p),
            OpenInSplit(p) => {
                self.split_active(crate::layout::SplitDir::Horizontal);
                self.open_path(&p);
            }
            RevealInFinder(p) => {
                // macOS; harmless no-op (an Err we ignore) elsewhere.
                let _ = std::process::Command::new("open").arg("-R").arg(&p).spawn();
            }
            OpenExternally(p) => open_path_external(&p),
            CopyPath(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast(format!("copied {text}"));
            }
            Command(id) => {
                crate::command::run(id, self);
            }
            CloseTab(id) => self.close_pane(id),
            CloseOtherTabs(id) => self.close_panes_except(Some(id)),
            CloseAllTabs => self.close_panes_except(None),
            NewFile(parent) => self.open_new_file_prompt(parent),
            NewFolder(parent) => self.open_new_folder_prompt(parent),
            Rename(path) => self.open_fs_rename_prompt(path),
            Delete(path) => self.open_fs_delete_prompt(path),
            GitCheckoutBranch(name) => self.git_checkout_named(&name),
            GitNewBranchFrom(name) => self.git_new_branch_from(name),
            GitDeleteBranch(name) => self.git_delete_branch_prompt(name),
            GitWorktreeShell(path) => self.open_worktree_shell(&path.to_string_lossy()),
            GitWorktreeRemove(path) => self.git_worktree_remove_prompt(path),
            PreviewMarkdown(path) => self.open_md_preview_for_path(path, self.active, true),
        }
    }

    /// Open the "New file…" prompt — captures `parent` so the accept handler
    /// knows where to put it.
    pub fn open_new_file_prompt(&mut self, parent: PathBuf) {
        self.pending_fs_action = Some(FsAction::NewFile {
            parent: parent.clone(),
        });
        let title = format!("New file in {}/", rel_path(&self.workspace, &parent));
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewFile,
            title,
        ));
    }

    /// Open the "New folder…" prompt — captures `parent`.
    pub fn open_new_folder_prompt(&mut self, parent: PathBuf) {
        self.pending_fs_action = Some(FsAction::NewFolder {
            parent: parent.clone(),
        });
        let title = format!("New folder in {}/", rel_path(&self.workspace, &parent));
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewFolder,
            title,
        ));
    }

    /// Open the FS rename prompt — captures `path`, seeds with its filename.
    pub fn open_fs_rename_prompt(&mut self, path: PathBuf) {
        let seed = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        self.pending_fs_action = Some(FsAction::Rename { path: path.clone() });
        let title = format!("Rename {}", rel_path(&self.workspace, &path));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::Rename,
            title,
            seed,
        ));
    }

    /// Create an empty file at `parent / name` and open it. `name` may include
    /// `/` separators — any missing intermediate dirs are created. Empty name
    /// is a no-op; an existing target toasts and bails.
    pub fn create_new_file(&mut self, parent: &Path, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let target = parent.join(name);
        if target.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &target)
            ));
            return;
        }
        if let Some(p) = target.parent()
            && let Err(e) = std::fs::create_dir_all(p)
        {
            self.toast(format!("cannot create dirs for {}: {e}", p.display()));
            return;
        }
        if let Err(e) = std::fs::write(&target, "") {
            self.toast(format!("create failed: {e}"));
            return;
        }
        self.tree.refresh();
        self.toast(format!("created {}", rel_path(&self.workspace, &target)));
        self.open_path(&target);
    }

    /// `mkdir -p parent/name` (then refresh the tree).
    pub fn create_new_folder(&mut self, parent: &Path, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let target = parent.join(name);
        if target.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &target)
            ));
            return;
        }
        if let Err(e) = std::fs::create_dir_all(&target) {
            self.toast(format!("mkdir failed: {e}"));
            return;
        }
        self.tree.refresh();
        self.toast(format!("created {}/", rel_path(&self.workspace, &target)));
    }

    /// Open the FS delete prompt — captures `path`. The user must type the
    /// entry's filename to confirm; anything else is a no-op (the prompt just
    /// closes). Cheap two-step guard rather than a yes/no modal.
    pub fn open_fs_delete_prompt(&mut self, path: PathBuf) {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        self.pending_fs_action = Some(FsAction::Delete { path: path.clone() });
        let title = format!(
            "Delete {} — type '{name}' to confirm",
            rel_path(&self.workspace, &path)
        );
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::DeleteConfirm,
            title,
        ));
    }

    /// Execute the delete *iff* `typed` matches `path`'s filename exactly.
    /// Removes any open editor buffer for the file; for a directory, removes
    /// every editor buffer under it. `rm` for a file, `rm -rf` for a dir.
    pub fn confirm_delete_fs_entry(&mut self, path: &Path, typed: &str) {
        let want = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if typed.trim() != want {
            self.toast("delete cancelled (name didn't match)");
            return;
        }
        let is_dir = path.is_dir();
        let res = if is_dir {
            std::fs::remove_dir_all(path)
        } else {
            std::fs::remove_file(path)
        };
        if let Err(e) = res {
            self.toast(format!("delete failed: {e}"));
            return;
        }
        // Force-close any editor buffer for the deleted file (or dir contents).
        let affected: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| match p {
                Pane::Editor(b) => b.path.as_deref().and_then(|bp| {
                    if bp == path || (is_dir && bp.starts_with(path)) {
                        Some(i)
                    } else {
                        None
                    }
                }),
                _ => None,
            })
            .collect();
        for i in affected.into_iter().rev() {
            self.force_close_pane(i);
        }
        self.lsp.did_close(path);
        // Trim out of recent_files.
        self.recent_files
            .retain(|p| p != path && !(is_dir && p.starts_with(path)));
        self.tree.refresh();
        self.toast(format!(
            "deleted {}{}",
            rel_path(&self.workspace, path),
            if is_dir { "/" } else { "" }
        ));
    }

    /// Rename `from` → `<from.parent()>/new_name`. If `from` is open as an
    /// editor buffer, the buffer is repointed at the new path (LSP gets a
    /// close/open pair). Refuses an existing target.
    pub fn rename_fs_entry(&mut self, from: &Path, new_name: &str) {
        let new_name = new_name.trim();
        if new_name.is_empty() {
            return;
        }
        let Some(parent) = from.parent() else {
            self.toast("can't rename — no parent dir");
            return;
        };
        let to = parent.join(new_name);
        if to == from {
            return;
        }
        if to.exists() {
            self.toast(format!(
                "already exists: {}",
                rel_path(&self.workspace, &to)
            ));
            return;
        }
        if let Err(e) = std::fs::rename(from, &to) {
            self.toast(format!("rename failed: {e}"));
            return;
        }
        // Repoint any open buffer for `from` at `to`.
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.path.as_deref() == Some(from)
            {
                b.path = Some(to.clone());
            }
        }
        self.lsp.did_close(from);
        // If still open as an editor, notify the LSP about the new path.
        let new_text = self.panes.iter().find_map(|p| match p {
            Pane::Editor(b) if b.is_at(&to) => Some(b.editor.text().to_string()),
            _ => None,
        });
        if let Some(t) = new_text {
            self.lsp.did_open(&to, &t);
        }
        // Update recent_files too.
        for p in &mut self.recent_files {
            if p == from {
                *p = to.clone();
            }
        }
        self.tree.refresh();
        self.toast(format!(
            "renamed {} → {}",
            rel_path(&self.workspace, from),
            rel_path(&self.workspace, &to),
        ));
    }

    /// vim `*` / `#` — search forward / backward for the identifier under
    /// the cursor. Sets the find state to that word and jumps. Toasts if
    /// the cursor isn't on an identifier.
    pub fn find_word_under_cursor(&mut self, forward: bool) {
        let Some(cur) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(cur) else {
            return;
        };
        let word = b.editor.word_under_cursor().to_string();
        if word.is_empty() {
            self.toast("no word under cursor");
            return;
        }
        // `accept_find` sets the state + jumps to the first match at-or-after
        // the cursor; for `#` we then step back once.
        self.accept_find(word);
        if !forward {
            self.find_prev();
        }
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

    /// Close every pane (optionally keeping `keep`), skipping dirty editors so
    /// nothing is lost silently — they're kept and counted.
    fn close_panes_except(&mut self, keep: Option<PaneId>) {
        let mut kept_dirty = 0usize;
        // Walk high→low so the indices below the one we close stay valid.
        for i in (0..self.panes.len()).rev() {
            if Some(i) == keep {
                continue;
            }
            if matches!(self.panes.get(i), Some(Pane::Editor(b)) if b.dirty) {
                kept_dirty += 1;
                continue;
            }
            self.force_close_pane(i);
        }
        if kept_dirty > 0 {
            self.toast(format!(
                "kept {kept_dirty} unsaved buffer(s) — save or :q! them"
            ));
        }
    }

    // ─── picker / palette ───────────────────────────────────────────
    pub fn open_picker(&mut self, picker: Picker) {
        self.whichkey = None;
        self.picker = Some(picker);
    }
    pub fn close_picker(&mut self) {
        self.picker = None;
    }
    /// Open the fuzzy file finder over every file in the workspace.
    pub fn open_file_picker(&mut self) {
        use crate::picker::PickerItem;
        let root = self.workspace.clone();
        let items: Vec<PickerItem> = self
            .tree
            .all_files()
            .into_iter()
            .map(|p| {
                let rel = p.strip_prefix(&root).unwrap_or(&p).to_path_buf();
                let label = rel.to_string_lossy().to_string();
                let dir = rel
                    .parent()
                    .map(|d| d.to_string_lossy().to_string())
                    .unwrap_or_default();
                PickerItem::new(p.to_string_lossy().to_string(), label, dir)
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Files, "Open file", items));
    }

    /// Open a fuzzy picker over `App::recent_files` (most-recent first). The
    /// items keep that order — fuzzy filtering still works on the labels but
    /// the unfiltered list is recency-sorted (the picker doesn't auto-sort
    /// alphabetically), so just opening the picker + Enter goes "back" to the
    /// last file.
    pub fn open_recent_files_picker(&mut self) {
        use crate::picker::PickerItem;
        let root = self.workspace.clone();
        let items: Vec<PickerItem> = self
            .recent_files
            .iter()
            .filter(|p| p.exists())
            .map(|p| {
                let rel = p.strip_prefix(&root).unwrap_or(p).to_path_buf();
                let label = rel.to_string_lossy().to_string();
                let dir = rel
                    .parent()
                    .map(|d| d.to_string_lossy().to_string())
                    .unwrap_or_default();
                PickerItem::new(p.to_string_lossy().to_string(), label, dir)
            })
            .collect();
        if items.is_empty() {
            self.toast("no recent files yet");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Recent, "Recent files", items));
    }

    /// Open the buffer switcher over the currently-open panes.
    pub fn open_buffer_picker(&mut self) {
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = self
            .panes
            .iter()
            .enumerate()
            .map(|(i, p)| {
                PickerItem::new(
                    i.to_string(),
                    p.title(),
                    if p.is_dirty() { "●" } else { "" },
                )
            })
            .collect();
        if items.is_empty() {
            self.toast("no open buffers");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Buffers, "Switch buffer", items));
    }
    /// Open the command palette over the registered commands (builtins + any
    /// plugin-registered ones).
    pub fn open_command_palette(&mut self) {
        use crate::picker::PickerItem;
        let mut items: Vec<PickerItem> = crate::command::registry()
            .all()
            .iter()
            .filter(|c| c.id != "palette")
            .map(|c| PickerItem::new(c.id, format!("{}  ·  {}", c.group, c.title), c.key_hint()))
            .collect();
        for dc in &self.dynamic_commands {
            items.push(PickerItem::new(
                dc.id.clone(),
                format!("{}  ·  {}", dc.group, dc.title),
                dc.keys.join(" / "),
            ));
        }
        self.open_picker(Picker::new(PickerKind::Commands, "Command palette", items));
    }

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
            self.toast(format!("plugin command registered: {}", dc.title));
            self.dynamic_commands.push(dc);
        }
    }
    /// If `id` is a plugin command, queue it for the IPC layer to log and return
    /// true; otherwise false. (Called by `command::run` after the builtin lookup.)
    pub fn run_dynamic_command(&mut self, id: &str) -> bool {
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
    /// Open the theme picker over the built-in themes.
    pub fn open_theme_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::ui::theme::cur().name;
        let items: Vec<PickerItem> = crate::ui::theme::names()
            .into_iter()
            .map(|n| PickerItem::new(n, n, if n == cur { "current" } else { "" }))
            .collect();
        self.open_picker(Picker::new(PickerKind::Themes, "Theme", items));
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

    /// Like [`Self::set_theme`] but no toast — used at session restore so a
    /// "theme: onedark" doesn't pop on every launch.
    fn set_theme_silent(&mut self, name: &str) -> Option<String> {
        let t = crate::ui::theme::set(name)?;
        self.config.ui.theme = t.name.to_string();
        for pane in &mut self.panes {
            if let Some(b) = pane.as_editor_mut() {
                b.refresh_highlights();
            }
        }
        Some(t.name.to_string())
    }
    /// Act on the picker's current selection, then close it.
    pub fn picker_accept(&mut self) {
        let Some(picker) = self.picker.take() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match picker.kind {
            PickerKind::Files | PickerKind::Recent => self.open_path(Path::new(&item.id)),
            PickerKind::Buffers => {
                if let Ok(i) = item.id.parse::<usize>()
                    && i < self.panes.len()
                {
                    self.reveal_pane(i);
                }
            }
            PickerKind::Commands => {
                crate::command::run(&item.id, self);
            }
            PickerKind::Themes => self.set_theme(&item.id),
            PickerKind::Tasks => self.run_task(&item.id),
            PickerKind::Branches => self.checkout_branch(&item.id),
            PickerKind::Worktrees => self.open_worktree_shell(&item.id),
            PickerKind::Locations => {
                let mut parts = item.id.split('\t');
                if let (Some(p), Some(l), Some(c)) = (parts.next(), parts.next(), parts.next()) {
                    let path = std::path::PathBuf::from(p);
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    self.open_path(&path);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
            PickerKind::CodeActions => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.apply_code_action(idx);
                }
            }
            PickerKind::Symbols => {
                let mut parts = item.id.split('\t');
                if let (Some(l), Some(c)) = (parts.next(), parts.next()) {
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
            PickerKind::BrowserTargets => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.switch_browser_target(idx);
                }
            }
            PickerKind::Snippets => {
                if let Ok(idx) = item.id.parse::<usize>() {
                    self.snippet_insert_at_cursor(idx);
                }
            }
        }
    }

    // ─── as-you-type LSP completion popup ───────────────────────────
    /// Move the completion-popup selection by `delta` rows (no-op if none open).
    pub fn completion_move(&mut self, delta: isize) {
        if let Some(p) = &mut self.completion {
            p.move_by(delta);
        }
    }

    /// Accept the highlighted completion: replace the identifier prefix left of
    /// the cursor with the item's insert text, then close the popup.
    pub fn completion_accept(&mut self) {
        let Some(popup) = self.completion.take() else {
            return;
        };
        let Some(item) = popup.current().cloned() else {
            return;
        };
        let prefix_len = popup.prefix.len(); // bytes — prefix chars are all id chars
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&popup.path)))
        else {
            return;
        };
        let clip = &mut self.clipboard;
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let cursor = b.editor.cursor();
            let start = cursor.saturating_sub(prefix_len);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end: cursor,
                    text: item.insert.clone(),
                }],
                clip,
                0,
            );
        }
        if let Some(Pane::Editor(b)) = self.panes.get(idx) {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&popup.path, &t);
        }
    }

    /// The identifier prefix (`[A-Za-z0-9_]*`) immediately left of the active
    /// editor's cursor, or `None` if there's no active editor.
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

    /// Called after every editor edit. Keeps an open completion popup in sync
    /// with what's being typed (re-filtering it, or closing it once the prefix
    /// empties / stops matching), and auto-triggers a fresh request on a member
    /// access (`.` / `:`) or the first character of a new word.
    pub fn completion_on_edit(&mut self, typed: Option<char>) {
        let is_id = |c: char| c.is_alphanumeric() || c == '_';
        let Some(prefix) = self.cursor_id_prefix() else {
            self.completion = None;
            return;
        };
        if let Some(popup) = &mut self.completion {
            if prefix.is_empty() || !popup.refilter(&prefix) {
                self.completion = None;
            } else {
                return; // already showing — refiltered locally, no re-request
            }
        }
        match typed {
            Some('.') | Some(':') => self.request_completion_at_cursor(),
            Some(c) if is_id(c) => {
                // Auto-trigger only at the start of a word (the char *before*
                // the one just typed isn't an identifier char) — subsequent
                // keystrokes just narrow the popup that this request opens.
                let at_word_start = self.active_editor().is_some_and(|b| {
                    let cur = b.editor.cursor();
                    let before: Vec<char> = b.editor.text()[..cur].chars().collect();
                    before.len() < 2 || !is_id(before[before.len() - 2])
                });
                if at_word_start {
                    self.request_completion_at_cursor();
                }
            }
            _ => {}
        }
        // Signature-help auto-trigger — orthogonal to completion. `(` opens
        // a fresh popup; `,` re-fires so the active param can advance. `)`
        // dismisses any open popup (we left the function call).
        match typed {
            Some('(') | Some(',') => self.request_signature_help_at_cursor(),
            Some(')') => {
                self.signature = None;
            }
            _ => {}
        }
    }

    /// `lsp.signature_help` — fire `textDocument/signatureHelp` at the active
    /// cursor. The reply lands as [`crate::lsp::LspEvent::SignatureHelp`]
    /// and replaces any open popup. Silent if no server is attached.
    pub fn request_signature_help_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let Some(path) = b.path.clone() else { return };
        let (row, col) = b.editor.row_col();
        let text = b.editor.text().to_string();
        self.lsp.did_change(&path, &text);
        self.lsp.signature_help(&path, row as u32, col as u32);
    }

    /// Fire a `textDocument/completion` at the active editor's cursor — the reply
    /// (`tick` → `apply_lsp_event`) opens the popup. Assumes the server already
    /// has the latest text (the edit path sends `didChange` first). Silent if
    /// there's no server for the file.
    fn request_completion_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let Some(path) = b.path.clone() else { return };
        let (row, col) = b.editor.row_col();
        self.lsp.completion(&path, row as u32, col as u32);
    }

    /// `task.run` — open a picker over `[tasks.<name>]` config entries.
    pub fn open_task_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.config.tasks.is_empty() {
            self.toast("no [tasks.*] defined in config".to_string());
            return;
        }
        let items: Vec<PickerItem> = self
            .config
            .tasks
            .iter()
            .map(|(name, t)| PickerItem::new(name.clone(), name.clone(), t.cmd.clone()))
            .collect();
        self.open_picker(Picker::new(PickerKind::Tasks, "Run task", items));
    }

    /// Run a named `[tasks.<name>]` entry in a new pty pane.
    pub fn run_task(&mut self, name: &str) {
        let Some(def) = self.config.tasks.get(name).cloned() else {
            self.toast(format!("unknown task: {name}"));
            return;
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
    pub fn active_pane(&self) -> Option<&Pane> {
        self.active.and_then(|i| self.panes.get(i))
    }
    pub fn active_pane_mut(&mut self) -> Option<&mut Pane> {
        match self.active {
            Some(i) => self.panes.get_mut(i),
            None => None,
        }
    }
    pub fn active_editor(&self) -> Option<&Buffer> {
        self.active_pane().and_then(Pane::as_editor)
    }
    pub fn active_editor_mut(&mut self) -> Option<&mut Buffer> {
        self.active_pane_mut().and_then(Pane::as_editor_mut)
    }

    /// Show pane `id` in the focused leaf (demoting whatever it showed to a
    /// background buffer). If `id` is already shown in some leaf, just focus that
    /// leaf instead — a buffer is never in two leaves at once. If nothing is open,
    /// create the first leaf showing `id`.
    pub fn reveal_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        if self.layout.contains(id) {
            self.active = Some(id);
        } else if let Some(cur) = self.active {
            self.layout.set_leaf_pane(cur, id);
            self.active = Some(id);
        } else {
            self.layout = Layout::Leaf(id);
            self.active = Some(id);
        }
        self.focus = Focus::Pane;
        self.retarget_outline_to_active();
    }

    /// If an outline pane is open and the now-active editor is a different
    /// file, retarget the outline to that file and re-fire `documentSymbol`.
    /// No-op when nothing's open, the active pane isn't an editor with a
    /// saved path, or the outline's already on this target.
    pub fn retarget_outline_to_active(&mut self) {
        let active_path = self.active_editor().and_then(|b| b.path.clone());
        let Some(path) = active_path else { return };
        let outline_idx = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Outline(_)));
        let Some(idx) = outline_idx else { return };
        let needs_retarget = match self.panes.get(idx) {
            Some(Pane::Outline(o)) => o.target != path,
            _ => false,
        };
        if !needs_retarget {
            return;
        }
        if let Some(Pane::Outline(o)) = self.panes.get_mut(idx) {
            o.target = path.clone();
            o.items.clear();
            o.clamp();
        }
        if is_markdown_path(&path) {
            self.populate_markdown_outline(&path);
            return;
        }
        self.pending_outline = true;
        if !self.lsp.document_symbol(&path) {
            self.pending_outline = false;
        }
    }

    /// Open `path` in the focused leaf. If it's already an open buffer it's
    /// revealed/refocused; otherwise a new buffer is opened. The buffer the
    /// focused leaf was showing stays open as a background tab.
    pub fn open_path(&mut self, path: &Path) {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        // Push the *current* position onto the back-stack before navigating
        // (browser-style). Skip when the active editor is already on this
        // exact file — that'd just be churn. Clears the forward stack so
        // Alt+Right doesn't span unrelated trails.
        if let Some(here) = self.current_nav_point()
            && here.path != path
        {
            self.push_nav_back(here);
            self.nav_forward.clear();
        }
        // Bump the recent list — this happens whether the buffer was already
        // open or is freshly created (a re-focus is still a "recent use").
        self.note_recent_file(&path);
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            self.reveal_pane(i);
            return;
        }
        // (Pane kind is picked by extension — only `Editor` exists in P0; `.http`
        // etc. route to `Pane::Request` once that track lands.)
        match Buffer::open(&path, &self.config) {
            Ok(mut buf) => {
                // Restore the cursor + scroll from the last time we had this
                // file open (if anywhere in `file_cursors`); harmless when the
                // saved cursor doesn't fit the new file text.
                if let Some(&(cursor_byte, scroll)) = self.file_cursors.get(&path) {
                    let (row, col) = byte_to_row_col(buf.editor.text(), cursor_byte);
                    buf.editor.place_cursor(row, col);
                    buf.scroll = scroll;
                }
                // Persistent undo — restore the editor's undo+redo stacks if
                // a matching `<workspace>/.mnml/undo/<hash>.json` exists. The
                // helper bails when the file's hash has drifted (file changed
                // outside mnml), so the worst case is "no history."
                let undo_path = crate::editor::undo_path_for(&self.workspace, &path);
                crate::editor::load_history_from(&mut buf.editor, &undo_path);
                let text = buf.editor.text().to_string();
                self.panes.push(Pane::Editor(buf));
                let new_id = self.panes.len() - 1;
                self.reveal_pane(new_id);
                self.lsp.did_open(&path, &text);
                // Auto-open MD preview alongside, if enabled and not yet open.
                // Passive (focus stays on the editor we just opened).
                if self.config.ui.auto_md_preview && is_markdown_path(&path) {
                    self.open_md_preview_for_path(path.clone(), Some(new_id), false);
                }
            }
            Err(e) => self.toast(format!("cannot open {}: {e}", path.display())),
        }
    }

    /// `(path, row, col)` of the currently-active editor, or `None` if the
    /// active pane isn't an editor with a path. Used to seed the nav stacks.
    pub fn current_nav_point(&self) -> Option<NavPoint> {
        let b = self.active_editor()?;
        let path = b.path.clone()?;
        let (row, col) = b.editor.row_col();
        Some(NavPoint { path, row, col })
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
    pub fn nav_back_jump(&mut self) {
        let Some(prev) = self.nav_back.pop() else {
            self.toast("nothing to go back to");
            return;
        };
        if let Some(here) = self.current_nav_point() {
            self.push_nav_forward(here);
        }
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
                Ok(buf) => {
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

    /// Tell the LSP server `path` was saved (re-reads the file — we just wrote it).
    fn notify_lsp_saved(&mut self, path: &Path) {
        if let Ok(text) = std::fs::read_to_string(path) {
            self.lsp.did_save(path, &text);
        }
    }

    // ─── LSP commands ───────────────────────────────────────────────
    /// `lsp.goto_definition` — ask the server where the symbol under the cursor
    /// is defined; the answer arrives async (`tick` jumps there).
    pub fn lsp_goto_definition(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.goto_definition(p, l, c),
            "go-to-definition",
        );
    }
    /// `lsp.hover` — ask the server for hover docs at the cursor (`tick` toasts them).
    pub fn lsp_hover(&mut self) {
        self.lsp_request_at_cursor(|lsp, p, l, c| lsp.hover(p, l, c), "hover");
    }
    /// `lsp.references` — find references to the symbol at the cursor (→ picker).
    pub fn lsp_references(&mut self) {
        self.lsp_request_at_cursor(|lsp, p, l, c| lsp.references(p, l, c), "references");
    }
    /// `lsp.{next,prev}_diagnostic` — move the cursor to the next / previous
    /// diagnostic in the active buffer (wrapping), and show its message in the
    /// hover popup.
    pub fn lsp_goto_diagnostic(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        if b.diagnostics.is_empty() {
            self.toast("no diagnostics in this file");
            return;
        }
        let (row, col) = b.editor.row_col();
        let cur = (row as u32, col as u32);
        let mut diags: Vec<(u32, u32, String)> = b
            .diagnostics
            .iter()
            .map(|d| {
                (
                    d.range.start.line,
                    d.range.start.character,
                    d.message.clone(),
                )
            })
            .collect();
        diags.sort_by_key(|&(l, c, _)| (l, c));
        let target = if forward {
            diags
                .iter()
                .find(|&&(l, c, _)| (l, c) > cur)
                .or_else(|| diags.first())
        } else {
            diags
                .iter()
                .rev()
                .find(|&&(l, c, _)| (l, c) < cur)
                .or_else(|| diags.last())
        };
        let Some(&(l, c, ref msg)) = target else {
            return;
        };
        let (l, c, msg) = (l, c, msg.clone());
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(l as usize, c as usize);
        }
        match crate::hover::HoverPopup::from_text(&msg) {
            Some(h) => self.hover = Some(h),
            None => self.toast(msg),
        }
    }
    /// `lsp.rename` — open a one-line prompt (seeded with the identifier under
    /// the cursor); on accept, send `textDocument/rename` for that spot.
    pub fn lsp_rename(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let (row, col) = b.editor.row_col();
        let word = self.word_under_cursor();
        self.pending_rename = Some((path, row as u32, col as u32));
        let kind = crate::prompt::PromptKind::LspRename;
        self.prompt = Some(match word {
            Some(w) => crate::prompt::Prompt::seeded(kind, "Rename symbol to", w),
            None => crate::prompt::Prompt::new(kind, "Rename symbol to"),
        });
    }
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
    /// `lsp.symbols` (`Ctrl+Shift+O`) — open a fuzzy picker over the active
    /// buffer's symbols (`textDocument/documentSymbol`). The reply lands async
    /// in `apply_lsp_event` → `open_symbols_picker`.
    pub fn lsp_symbols(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        self.lsp.did_change(&path, &text);
        if !self.lsp.document_symbol(&path) {
            self.toast("no language server for this file (symbols)");
        }
    }

    /// `lsp.workspace_symbols` — prompt for a query, then fire
    /// `workspace/symbol` against every running language server. Replies
    /// (`LspEvent::WorkspaceSymbols`) land async and feed
    /// [`Self::apply_workspace_symbols`] which routes the hits to a
    /// `PickerKind::Locations` picker.
    pub fn lsp_workspace_symbols(&mut self) {
        if self.lsp.is_empty() {
            self.toast("no language server running");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::LspWorkspaceSymbol,
            "Workspace symbols (query)",
        ));
    }

    /// Fire `workspace/symbol` after the prompt is accepted. Resets the picker
    /// stash so partial replies from previous queries don't bleed in.
    pub fn run_workspace_symbol_query(&mut self, query: &str) {
        self.pending_workspace_symbols.clear();
        self.pending_workspace_symbol_query = Some(query.to_string());
        if !self.lsp.workspace_symbol(query) {
            self.toast("no language server (workspace symbols)");
        }
    }

    /// Apply a `workspace/symbol` reply: merge hits into a Locations picker.
    /// Multiple servers may each reply — we collect them in a stash and
    /// (re-)open the picker after every reply so the user sees results as
    /// they arrive.
    fn apply_workspace_symbols(&mut self, syms: Vec<crate::lsp::WorkspaceSymbol>) {
        if syms.is_empty() {
            return;
        }
        self.pending_workspace_symbols.extend(syms);
        let stash = self.pending_workspace_symbols.clone();
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = stash
            .iter()
            .map(|s| {
                let rel = rel_path(&self.workspace, &s.path);
                let detail = match &s.container {
                    Some(c) if !c.is_empty() => format!("{}  {}", s.kind, c),
                    _ => s.kind.to_string(),
                };
                PickerItem::new(
                    format!("{}\t{}\t{}", s.path.display(), s.line, s.character),
                    format!("{}  {}:{}", s.name, rel, s.line + 1),
                    detail,
                )
            })
            .collect();
        let title = match &self.pending_workspace_symbol_query {
            Some(q) if !q.is_empty() => format!("Workspace symbols ({})  '{q}'", items.len()),
            _ => format!("Workspace symbols ({})", items.len()),
        };
        self.open_picker(Picker::new(PickerKind::Locations, title, items));
    }

    /// `outline.show` — open (or refocus) a persistent symbol outline for the
    /// active editor. Fires `documentSymbol`; the reply lands async and
    /// populates the outline pane (instead of opening a picker — the
    /// `pending_outline` flag routes the next reply to the pane).
    pub fn open_outline_pane(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        // Already open ⇒ retarget + refresh.
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Outline(_)))
        {
            if let Some(Pane::Outline(o)) = self.panes.get_mut(id) {
                o.target = path.clone();
                o.items.clear();
                o.clamp();
            }
            self.reveal_pane(id);
        } else {
            let pane = Pane::Outline(crate::lsp::outline_pane::OutlinePane::new(
                path.clone(),
                Vec::new(),
            ));
            match self.active {
                Some(cur) => {
                    let new_id =
                        self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                    self.active = Some(new_id);
                }
                None => {
                    self.panes.push(pane);
                    let id = self.panes.len() - 1;
                    self.layout = Layout::Leaf(id);
                    self.active = Some(id);
                }
            }
            self.focus = Focus::Pane;
        }
        // Markdown buffers don't need a language server — extract headings
        // directly from the text and populate the pane synchronously.
        if is_markdown_path(&path) {
            self.populate_markdown_outline(&path);
            return;
        }
        // Ask for symbols; the reply routes to the outline.
        let text = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .unwrap_or_default();
        self.lsp.did_change(&path, &text);
        self.pending_outline = true;
        if !self.lsp.document_symbol(&path) {
            self.pending_outline = false;
            self.toast("no language server for this file (outline)");
        }
    }

    /// Read the active markdown editor's text, extract ATX headings, and
    /// drop them onto the open outline pane. Synchronous — markdown headings
    /// don't need a language server.
    fn populate_markdown_outline(&mut self, path: &Path) {
        let text = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .unwrap_or_default();
        let items = crate::markdown_outline::extract_headings(&text);
        if let Some(o) = self.panes.iter_mut().find_map(|p| match p {
            Pane::Outline(o) => Some(o),
            _ => None,
        }) {
            o.items = items;
            o.clamp();
        }
    }

    /// `r` in the outline pane — refire the request for its current target.
    pub fn refresh_outline_pane(&mut self) {
        let Some(Pane::Outline(o)) = self.active.and_then(|i| self.panes.get(i)) else {
            return;
        };
        let path = o.target.clone();
        if is_markdown_path(&path) {
            self.populate_markdown_outline(&path);
            return;
        }
        self.pending_outline = true;
        if !self.lsp.document_symbol(&path) {
            self.pending_outline = false;
            self.toast("no language server for this file (outline)");
        }
    }

    pub fn move_outline_selection(&mut self, delta: isize) {
        if let Some(Pane::Outline(o)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            o.move_selection(delta);
        }
    }

    /// `Enter` in the outline pane: open the target file (refocusing if
    /// already open) and place the cursor at the selected symbol.
    pub fn jump_to_selected_outline(&mut self) {
        let (target, line, col) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Outline(o)) => {
                let Some(sym) = o.selected_item() else {
                    return;
                };
                (o.target.clone(), sym.line, sym.character)
            }
            _ => return,
        };
        self.open_path(&target);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line as usize, col as usize);
        }
    }

    /// Apply a `textDocument/documentSymbol` reply: open a fuzzy picker over
    /// the symbols, indented by depth. Empty list ⇒ toast.
    fn open_symbols_picker(&mut self, symbols: Vec<crate::lsp::DocumentSymbol>) {
        if symbols.is_empty() {
            self.toast("no symbols");
            return;
        }
        use crate::picker::PickerItem;
        let n = symbols.len();
        let items: Vec<PickerItem> = symbols
            .into_iter()
            .map(|s| {
                let indent = "  ".repeat(s.depth as usize);
                let label = format!("{indent}{}", s.name);
                let detail = format!("{}  {}", s.kind, s.line + 1);
                PickerItem::new(format!("{}\t{}", s.line, s.character), label, detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Symbols,
            format!("Symbols ({n})"),
            items,
        ));
    }

    /// `lsp.code_action` (`Ctrl+.`) — ask the server what actions apply at the
    /// cursor (or across the active selection), passing along the diagnostics
    /// that overlap so quickfixes are offered. The reply lands async in
    /// [`Self::tick`] → `apply_code_action_reply`.
    pub fn lsp_code_action(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (start, end) = if let Some((s, e)) = b.editor.selection() {
            let (sl, sc) = byte_to_line_col(&text, s);
            let (el, ec) = byte_to_line_col(&text, e);
            (
                crate::lsp::Pos {
                    line: sl as u32,
                    character: sc as u32,
                },
                crate::lsp::Pos {
                    line: el as u32,
                    character: ec as u32,
                },
            )
        } else {
            let (row, col) = b.editor.row_col();
            let p = crate::lsp::Pos {
                line: row as u32,
                character: col as u32,
            };
            (p, p)
        };
        let range = crate::lsp::Range { start, end };
        let diagnostics: Vec<crate::lsp::Diagnostic> = b
            .diagnostics
            .iter()
            .filter(|d| ranges_overlap(d.range, range))
            .cloned()
            .collect();
        self.pending_code_action_path = Some(path.clone());
        self.lsp.did_change(&path, &text);
        if !self.lsp.code_action(&path, range, &diagnostics) {
            self.pending_code_action_path = None;
            self.pending_code_action_auto_apply = false;
            self.toast("no language server for this file (code action)");
        }
    }

    /// `lsp.quick_fix` (Alt+Enter) — like [`Self::lsp_code_action`], but the
    /// reply handler auto-applies the *first* action instead of opening a
    /// picker. The point is the common "fix this for me" gesture next to
    /// an inline diagnostic — pick-the-first matches what most IDEs do
    /// because servers front-load the most relevant action.
    pub fn lsp_quick_fix(&mut self) {
        self.pending_code_action_auto_apply = true;
        // Reuse the same request path; `apply_code_action_reply` branches
        // on the auto-apply flag.
        self.lsp_code_action();
    }

    /// Handle a `textDocument/codeAction` reply.
    ///
    /// - With `pending_code_action_auto_apply` set: applies the first action
    ///   directly (toasts when the list is empty). Resets the flag either way.
    /// - Otherwise: stashes the actions and opens a picker; the picker's
    ///   `accept` calls [`Self::apply_code_action`].
    fn apply_code_action_reply(&mut self, actions: Vec<crate::lsp::CodeAction>) {
        let auto = std::mem::take(&mut self.pending_code_action_auto_apply);
        if actions.is_empty() {
            self.toast(if auto {
                "no quick fix available"
            } else {
                "no code actions"
            });
            return;
        }
        if auto {
            // Apply the first action without prompting.
            self.pending_code_actions = actions;
            self.apply_code_action(0);
            return;
        }
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = actions
            .iter()
            .enumerate()
            .map(|(i, a)| {
                let detail = a.kind.clone().unwrap_or_default();
                PickerItem::new(i.to_string(), a.title.clone(), detail)
            })
            .collect();
        let n = items.len();
        self.pending_code_actions = actions;
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::CodeActions,
            format!("Code actions ({n})"),
            items,
        ));
    }

    /// Apply the chosen code action: edit (if any) — through the same workspace-
    /// edit code path as rename — then `workspace/executeCommand` (if any).
    pub fn apply_code_action(&mut self, idx: usize) {
        let Some(action) = self.pending_code_actions.get(idx).cloned() else {
            return;
        };
        let path = self.pending_code_action_path.clone();
        if action.edit.is_none() && action.command.is_none() {
            self.toast(format!("code action: '{}' has no edit", action.title));
            return;
        }
        if let Some(edits) = action.edit {
            self.apply_rename_edits(edits);
        }
        if let (Some(cmd), Some(p)) = (action.command, path)
            && !self.lsp.execute_command(&p, &cmd)
        {
            self.toast(format!("code action: couldn't run '{}'", cmd.command));
        }
    }

    /// `lsp.completion` (`Ctrl+Space`) — manually ask the server for completions
    /// at the cursor; the reply (`tick` → `apply_lsp_event`) opens the popup
    /// ([`Self::completion_on_edit`] auto-triggers it as you type otherwise).
    pub fn lsp_completion(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        self.lsp.did_change(&path, &text);
        if !self.lsp.completion(&path, row as u32, col as u32) {
            self.toast("no language server for this file (completion)");
        }
    }
    // ─── vim marks ──────────────────────────────────────────────────
    /// Set mark `letter` to the active editor's cursor `(row, col)`.
    /// Lowercase letters are buffer-local (`Buffer.marks`); uppercase
    /// letters are global (`App.global_marks`, persisted in session.json).
    /// Bound to vim normal-mode `m<letter>` (via [`AppCommand::SetMark`]).
    pub fn set_mark_at_cursor(&mut self, letter: char) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let (row, col) = b.editor.row_col();
        if letter.is_ascii_uppercase() {
            let Some(path) = b.path.clone() else {
                self.toast("global marks need a saved file");
                return;
            };
            self.global_marks.insert(letter, (path, row, col));
            self.toast(format!("mark '{letter} set (global)"));
        } else if let Some(b) = self.active_editor_mut() {
            b.marks.insert(letter, (row, col));
            self.toast(format!("mark '{letter} set"));
        }
    }

    /// Jump to mark `letter`. Lowercase ⇒ within the active buffer.
    /// Uppercase ⇒ open the buffer the mark points at (if needed) and jump
    /// there. `exact` false (`'<letter>`) lands at column 0; `exact` true
    /// (`` `<letter>``) lands at the stored `(row, col)`. Pushes the current
    /// position onto the nav-back stack so `Alt+Left` returns.
    pub fn jump_to_mark(&mut self, letter: char, exact: bool) {
        let (target_path, row, col) = if letter.is_ascii_uppercase() {
            let Some((path, row, col)) = self.global_marks.get(&letter).cloned() else {
                self.toast(format!("no mark '{letter}"));
                return;
            };
            (Some(path), row, col)
        } else {
            let Some(b) = self.active_editor() else {
                self.toast("no active editor");
                return;
            };
            let Some(&(row, col)) = b.marks.get(&letter) else {
                self.toast(format!("no mark '{letter}"));
                return;
            };
            (None, row, col)
        };

        if let Some(here) = self.current_nav_point() {
            self.push_nav_back(here);
        }
        if let Some(path) = target_path
            && self
                .active_editor()
                .and_then(|b| b.path.clone())
                .is_none_or(|p| p != path)
        {
            self.open_path(&path);
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let target_col = if exact { col } else { 0 };
        b.editor.place_cursor(row, target_col);
        self.toast(format!("→ '{letter} {}:{}", row + 1, target_col + 1));
    }

    // ─── snippets ───────────────────────────────────────────────────
    /// `snippet.expand` (`Ctrl+J`) — look at the identifier prefix immediately
    /// left of the active editor's cursor; if it matches a snippet trigger for
    /// the file's extension (or `global`), replace the prefix with the
    /// expansion. Cursor lands at the `$0` marker (or at end if absent).
    /// No match ⇒ toast.
    pub fn snippet_expand_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let ext = b.language_ext.clone();
        let text = b.editor.text();
        let cursor = b.editor.cursor();
        let (prefix_start, word) = crate::snippets::word_before_cursor(text, cursor);
        if word.is_empty() {
            self.toast("snippet: no trigger word before cursor");
            return;
        }
        let snippets = crate::snippets::snippets_for(&self.config.snippets, ext.as_deref());
        let Some(snip) = crate::snippets::find_by_trigger(&snippets, &word) else {
            self.toast(format!("no snippet matches '{word}'"));
            return;
        };
        let text = snip.text.clone();
        let cursor_offset = snip.cursor_offset;
        let placeholders = snip.placeholders.clone();
        self.apply_snippet_edit(prefix_start, cursor, text, cursor_offset, placeholders);
    }

    /// `snippet.pick` — open a fuzzy picker of every snippet available for the
    /// active buffer (extension + global). Accept inserts the expansion at the
    /// cursor without consuming a trigger word.
    pub fn snippet_pick(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let ext = b.language_ext.clone();
        let snippets = crate::snippets::snippets_for(&self.config.snippets, ext.as_deref());
        if snippets.is_empty() {
            self.toast("no snippets configured (see [snippets.*] in config.toml)");
            return;
        }
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = snippets
            .iter()
            .enumerate()
            .map(|(i, s)| {
                // First line of the expansion as the preview detail.
                let preview = s.text.lines().next().unwrap_or("").to_string();
                PickerItem::new(
                    i.to_string(),
                    format!("{}  →  {}", s.trigger, preview),
                    s.scope.clone(),
                )
            })
            .collect();
        let n = items.len();
        self.pending_snippets = snippets;
        self.open_picker(Picker::new(
            PickerKind::Snippets,
            format!("Snippets ({n})"),
            items,
        ));
    }

    /// Picker-accept side: insert the chosen snippet's expansion at the cursor
    /// (no trigger word to consume).
    fn snippet_insert_at_cursor(&mut self, idx: usize) {
        let Some(snip) = self.pending_snippets.get(idx).cloned() else {
            return;
        };
        let Some(b) = self.active_editor() else {
            return;
        };
        let cursor = b.editor.cursor();
        self.apply_snippet_edit(
            cursor,
            cursor,
            snip.text,
            snip.cursor_offset,
            snip.placeholders,
        );
    }

    /// Shared edit path: replace `[start, end)` with `text`, then place the
    /// cursor at `start + cursor_offset` so `$0` lands where the user expects.
    /// If `placeholders` is non-empty, jump the cursor to the first one
    /// instead and open a [`crate::snippets::SnippetSession`] so Tab cycles
    /// through the rest (and finally to the `$0` spot).
    fn apply_snippet_edit(
        &mut self,
        start: usize,
        end: usize,
        text: String,
        cursor_offset: usize,
        placeholders: Vec<usize>,
    ) {
        let pane_id = self.active;
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let inserted_len = text.len();
        let ops = vec![crate::edit_op::EditOp::ReplaceRange { start, end, text }];
        let mut clip = crate::clipboard::Clipboard::new();
        let changed = b.apply_edit_ops(ops, &mut clip, 0);
        if !changed {
            return;
        }
        // The cursor sits at `start + inserted_len` after the replace. First
        // stop is `placeholders[0]` if any, else the `$0` marker (or end).
        let first_stop = placeholders
            .first()
            .copied()
            .unwrap_or(cursor_offset.min(inserted_len));
        let target_cursor = start + first_stop;
        place_cursor_at_byte(b, target_cursor);
        // Open a placeholder session if there are any tab stops — `$1..$9`
        // at the front, optionally `$0` appended as the final stop. (When
        // `$0` is absent we let Tab terminate at the last `$N` rather than
        // yanking the cursor to the end.)
        let mut stops: Vec<usize> = placeholders.iter().map(|&off| start + off).collect();
        if !placeholders.is_empty() && cursor_offset < inserted_len {
            stops.push(start + cursor_offset);
        }
        let last_text_len = b.editor.text().len();
        let path_for_lsp = b.path.clone();
        let new_text_for_lsp = b.editor.text().to_string();
        // Only worth a session when there's somewhere to tab *to* — a single
        // stop is the one we already placed at, no second stop = nothing to
        // cycle. `current = 0` is where we just placed; advancing puts us at
        // index 1.
        if let (true, Some(pane_id)) = (stops.len() > 1, pane_id) {
            self.snippet_session = Some(crate::snippets::SnippetSession {
                pane_id,
                stops,
                current: 0,
                last_text_len,
            });
        } else {
            self.snippet_session = None;
        }
        // Keep LSP in sync (a snippet may contain identifiers the server
        // cares about) — same shape as buffer-edit paths elsewhere.
        if let Some(path) = path_for_lsp {
            self.lsp.did_change(&path, &new_text_for_lsp);
        }
    }

    /// Tab inside an open snippet session: advance to the next placeholder,
    /// accounting for any text the user inserted at the current one. Closes
    /// the session after the last stop.
    pub fn snippet_next_placeholder(&mut self) {
        self.snippet_step_placeholder(1);
    }

    /// Shift-Tab inside an open snippet session: walk back to the previous
    /// placeholder. No-op at the first stop (doesn't wrap — wrapping mid-edit
    /// is more confusing than helpful).
    pub fn snippet_prev_placeholder(&mut self) {
        self.snippet_step_placeholder(-1);
    }

    /// Shared step: `+1` = forward, `-1` = backward. Shifts all stops
    /// strictly after the current cursor by the text-length delta accrued
    /// since we last placed at a stop, then jumps to the new index.
    fn snippet_step_placeholder(&mut self, dir: i32) {
        let Some(mut sess) = self.snippet_session.take() else {
            return;
        };
        if Some(sess.pane_id) != self.active {
            // Pane drifted away — let the session die.
            return;
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let cur_len = b.editor.text().len();
        // Net chars added (or removed) since we last placed at a stop —
        // shifts every position strictly after the active stop. `i64` to
        // tolerate net deletions.
        let delta = cur_len as i64 - sess.last_text_len as i64;
        let cur_idx = sess.current;
        for (i, off) in sess.stops.iter_mut().enumerate() {
            if i > cur_idx {
                *off = (*off as i64 + delta).max(0) as usize;
            }
        }
        // Compute the new index. Forward off the end ⇒ session ends.
        // Backward at index 0 ⇒ stay put (no wrap).
        let new_idx_signed = cur_idx as i32 + dir;
        if dir > 0 && new_idx_signed >= sess.stops.len() as i32 {
            // Walked off the last stop. Don't restore the session.
            return;
        }
        if dir < 0 && new_idx_signed < 0 {
            // Already at the first stop — re-store and bail.
            sess.last_text_len = cur_len;
            self.snippet_session = Some(sess);
            return;
        }
        let new_idx = new_idx_signed as usize;
        let target = sess.stops[new_idx].min(cur_len);
        place_cursor_at_byte(b, target);
        sess.current = new_idx;
        sess.last_text_len = cur_len;
        self.snippet_session = Some(sess);
    }

    fn lsp_request_at_cursor(
        &mut self,
        send: impl FnOnce(&mut crate::lsp::LspManager, &Path, u32, u32) -> bool,
        what: &str,
    ) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        // Sync the latest text first so positions line up, then send the request.
        self.lsp.did_change(&path, &text);
        if !send(&mut self.lsp, &path, row as u32, col as u32) {
            self.toast(format!("no language server for this file ({what})"));
        }
    }
    /// Apply one LSP event (called from `tick`).
    fn apply_lsp_event(&mut self, ev: crate::lsp::LspEvent) {
        use crate::lsp::LspEvent;
        match ev {
            LspEvent::Diagnostics { path, diags } => {
                for pane in &mut self.panes {
                    if let Pane::Editor(b) = pane
                        && b.is_at(&path)
                    {
                        b.diagnostics = diags.clone();
                    }
                }
                self.refresh_diagnostics_panes();
            }
            LspEvent::GotoDefinition {
                path,
                line,
                character,
            } => {
                self.open_path(&path);
                if let Some(b) = self.active_editor_mut() {
                    b.editor.place_cursor(line as usize, character as usize);
                }
            }
            LspEvent::Hover { text } => match crate::hover::HoverPopup::from_text(&text) {
                Some(h) => self.hover = Some(h),
                None => self.toast("hover: (nothing)"),
            },
            LspEvent::References(locs) => {
                use crate::picker::PickerItem;
                if locs.is_empty() {
                    self.toast("no references");
                    return;
                }
                let n = locs.len();
                let items: Vec<PickerItem> = locs
                    .into_iter()
                    .map(|(p, l, c)| {
                        let rel = rel_path(&self.workspace, &p);
                        PickerItem::new(
                            format!("{}\t{}\t{}", p.display(), l, c),
                            format!("{rel}:{}:{}", l + 1, c + 1),
                            String::new(),
                        )
                    })
                    .collect();
                self.open_picker(Picker::new(
                    PickerKind::Locations,
                    format!("References ({n})"),
                    items,
                ));
            }
            LspEvent::Rename(edits) => self.apply_rename_edits(edits),
            LspEvent::Completion(items) => {
                use crate::completion::{CompletionItem, CompletionPopup};
                if items.is_empty() {
                    return;
                }
                // Build from the *current* cursor — the request may have been
                // fired a few keystrokes ago; we filter against the live prefix.
                let Some(prefix) = self.cursor_id_prefix() else {
                    return;
                };
                let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
                    return;
                };
                let cis: Vec<CompletionItem> = items
                    .into_iter()
                    .take(500)
                    .map(|(label, insert, detail)| CompletionItem {
                        label,
                        insert,
                        detail: detail.unwrap_or_default(),
                    })
                    .collect();
                let popup = CompletionPopup::new(path, cis, &prefix);
                if !popup.is_empty() {
                    self.completion = Some(popup);
                }
            }
            LspEvent::Formatting { path, edits } => self.apply_formatting_edits(path, edits),
            LspEvent::CodeAction(actions) => self.apply_code_action_reply(actions),
            LspEvent::DocumentSymbols(symbols) => {
                if self.pending_outline {
                    self.pending_outline = false;
                    if let Some(o) = self.panes.iter_mut().find_map(|p| match p {
                        Pane::Outline(o) => Some(o),
                        _ => None,
                    }) {
                        o.items = symbols;
                        o.clamp();
                    }
                } else {
                    self.open_symbols_picker(symbols);
                }
            }
            LspEvent::WorkspaceSymbols(syms) => self.apply_workspace_symbols(syms),
            LspEvent::SignatureHelp(sh) => {
                self.signature = crate::signature::SignaturePopup::from_reply(sh);
            }
            LspEvent::Message(m) => self.toast(m),
        }
    }

    /// Apply a `TextEdit[]` from `textDocument/formatting` to the matching open
    /// buffer (single file). Reuses `build_replace_ops` for the Range → byte
    /// translation, applies through `apply_edit_ops` (one undo step). If a
    /// format-on-save is pending for this file, chains the actual save.
    fn apply_formatting_edits(&mut self, path: PathBuf, edits: Vec<(crate::lsp::Range, String)>) {
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        else {
            return;
        };
        let ops = match self.panes.get(idx) {
            Some(Pane::Editor(b)) => build_replace_ops(b.editor.text(), &edits),
            _ => Vec::new(),
        };
        let was_format_then_save = matches!(
            &self.pending_format_save,
            Some((p, _)) if p == &path,
        );
        if !ops.is_empty() {
            let clip = &mut self.clipboard;
            if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                b.apply_edit_ops(ops, clip, 0);
            }
            if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                let t = b.editor.text().to_string();
                self.lsp.did_change(&path, &t);
            }
            if !was_format_then_save {
                self.toast(format!("formatted {}", rel_path(&self.workspace, &path)));
            }
        }
        if was_format_then_save {
            self.pending_format_save = None;
            self.save_active_now();
        }
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
    }

    /// `lsp.format` (`Ctrl+Shift+I`) — ask the LSP to format the active
    /// buffer. The reply lands async in [`Self::tick`] → `apply_formatting_edits`.
    pub fn lsp_format(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("nothing to format (scratch buffer)");
            return;
        };
        let tab_size = self.config.editor.tab_width as u32;
        if !self.lsp.formatting(&path, tab_size, true) {
            self.toast("no LSP server attached to this file");
        }
    }

    /// Apply a flattened `WorkspaceEdit` (from `textDocument/rename`): edit each
    /// affected file — through `Editor::apply` if it's open as a buffer (left
    /// dirty for review), else by splicing the file on disk directly.
    fn apply_rename_edits(&mut self, edits: Vec<(PathBuf, Vec<(crate::lsp::Range, String)>)>) {
        if edits.is_empty() {
            self.toast("rename: no changes");
            return;
        }
        let (mut buffers, mut disk, mut total) = (0usize, 0usize, 0usize);
        for (path, file_edits) in edits {
            let idx = self
                .panes
                .iter()
                .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)));
            if let Some(idx) = idx {
                let ops = match self.panes.get(idx) {
                    Some(Pane::Editor(b)) => build_replace_ops(b.editor.text(), &file_edits),
                    _ => Vec::new(),
                };
                if ops.is_empty() {
                    continue;
                }
                let n = ops.len();
                let clip = &mut self.clipboard;
                let applied = match self.panes.get_mut(idx) {
                    Some(Pane::Editor(b)) => b.apply_edit_ops(ops, clip, 0),
                    _ => false,
                };
                if applied {
                    buffers += 1;
                    total += n;
                    if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                        let t = b.editor.text().to_string();
                        self.lsp.did_change(&path, &t);
                    }
                }
            } else if let Ok(text) = std::fs::read_to_string(&path) {
                let ops = build_replace_ops(&text, &file_edits);
                if ops.is_empty() {
                    continue;
                }
                let n = ops.len();
                let mut s = text;
                for op in &ops {
                    if let crate::edit_op::EditOp::ReplaceRange { start, end, text } = op {
                        s.replace_range(*start..*end, text);
                    }
                }
                if std::fs::write(&path, s).is_ok() {
                    disk += 1;
                    total += n;
                }
            }
        }
        if disk > 0 {
            self.git.refresh();
        }
        self.toast(format!(
            "renamed {total} occurrence(s): {buffers} open buffer(s), {disk} on-disk file(s) — review & save"
        ));
    }

    pub fn drain_lsp_events(&mut self) {
        for ev in self.lsp.poll() {
            self.apply_lsp_event(ev);
        }
    }

    // ─── diagnostics ("Problems") list pane ─────────────────────────
    /// Collect every diagnostic currently held on an open editor buffer into a
    /// fresh [`DiagnosticsPane`].
    fn build_diagnostics_pane(&self) -> crate::lsp::diagnostics_pane::DiagnosticsPane {
        let sources = self.panes.iter().filter_map(|p| match p {
            Pane::Editor(b) => {
                let path = b.path.clone()?;
                if b.diagnostics.is_empty() {
                    return None;
                }
                let rel = rel_path(&self.workspace, &path);
                Some((path, rel, b.diagnostics.as_slice()))
            }
            _ => None,
        });
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
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Diagnostics(self.build_diagnostics_pane());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Rebuild the item list of any open diagnostics pane (called when
    /// diagnostics change, or on the pane's `r` key).
    pub fn refresh_diagnostics_panes(&mut self) {
        if !self.panes.iter().any(|p| matches!(p, Pane::Diagnostics(_))) {
            return;
        }
        let fresh = self.build_diagnostics_pane();
        for pane in &mut self.panes {
            if let Pane::Diagnostics(d) = pane {
                d.items = fresh.items.clone();
                d.clamp();
            }
        }
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
    /// Build a fresh [`crate::playwright::flaky_pane::FlakyPane`] from the
    /// current [`crate::playwright::history::TestHistory`].
    fn build_flaky_pane(&self) -> crate::playwright::flaky_pane::FlakyPane {
        let ws = self.workspace.clone();
        let rows = self.test_history.wobbly_tests();
        crate::playwright::flaky_pane::FlakyPane::build(rows, move |rel| ws.join(rel))
    }

    /// `flaky.show` — open the flaky-test dashboard (or refocus + refresh
    /// the one that's already open) in a split below the focused leaf.
    pub fn open_flaky_pane(&mut self) {
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Flaky(_))) {
            let fresh = self.build_flaky_pane();
            if let Some(Pane::Flaky(f)) = self.panes.get_mut(id) {
                f.items = fresh.items;
                f.clamp();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Flaky(self.build_flaky_pane());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Rebuild the item list of any open flaky panes (called after each test
    /// run, or on the pane's `r` key).
    pub fn refresh_flaky_panes(&mut self) {
        if !self.panes.iter().any(|p| matches!(p, Pane::Flaky(_))) {
            return;
        }
        let fresh = self.build_flaky_pane();
        for pane in &mut self.panes {
            if let Pane::Flaky(f) = pane {
                f.items = fresh.items.clone();
                f.clamp();
            }
        }
    }

    pub fn move_flaky_selection(&mut self, delta: isize) {
        if let Some(Pane::Flaky(f)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            f.move_selection(delta);
        }
    }

    /// Open the highlighted test's file and place the cursor on its line.
    pub fn jump_to_selected_flaky(&mut self) {
        let target = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Flaky(f)) => f.selected_item().map(|it| (it.path.clone(), it.line)),
            _ => None,
        };
        let Some((path, line)) = target else {
            return;
        };
        self.open_path(&path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line as usize, 0);
        }
    }

    /// Drop `app.panes[removed]` and re-index every higher reference (the layout's
    /// leaves, `active`). Caller must have already detached `removed` from the
    /// layout if it was in a leaf.
    fn remove_pane_storage(&mut self, removed: PaneId) {
        if removed >= self.panes.len() {
            return;
        }
        self.panes.remove(removed);
        self.layout.shift_after(removed);
        self.active = self
            .active
            .map(|a| if a > removed { a - 1 } else { a })
            .filter(|_| !self.panes.is_empty());
    }

    /// Split the focused leaf, opening a fresh buffer (a re-open of the same file,
    /// or a scratch buffer) in the new half and focusing it.
    pub fn split_active(&mut self, dir: crate::layout::SplitDir) {
        let Some(cur) = self.active else {
            self.toast("nothing to split");
            return;
        };
        // The new half re-opens the current file fresh (own cursor), else a scratch.
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.path.clone(),
            Some(Pane::MdPreview(p)) => Some(p.path.clone()),
            Some(Pane::Diff(_))
            | Some(Pane::GitGraph(_))
            | Some(Pane::GitStatus(_))
            | Some(Pane::Request(_))
            | Some(Pane::Pty(_))
            | Some(Pane::Ai(_))
            | Some(Pane::Tests(_))
            | Some(Pane::Trace(_))
            | Some(Pane::Browser(_))
            | Some(Pane::Diagnostics(_))
            | Some(Pane::Grep(_))
            | Some(Pane::Flaky(_))
            | Some(Pane::Outline(_))
            | None => None,
        };
        let new_buf = match path {
            Some(p) => {
                Buffer::open(&p, &self.config).unwrap_or_else(|_| Buffer::scratch(&self.config))
            }
            None => Buffer::scratch(&self.config),
        };
        let new_id = self.split_leaf_with(cur, dir, Pane::Editor(new_buf));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Replace `Leaf(leaf)` with `Split{leaf, new-pane}`; returns the new pane id.
    fn split_leaf_with(
        &mut self,
        leaf: PaneId,
        dir: crate::layout::SplitDir,
        pane: Pane,
    ) -> PaneId {
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.layout.replace_leaf(
            leaf,
            Layout::Split {
                dir,
                ratio: 50,
                first: Box::new(Layout::Leaf(leaf)),
                second: Box::new(Layout::Leaf(new_id)),
            },
        );
        new_id
    }

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
            path,
            source,
            scroll: 0,
        });
        let prior_active = self.active;
        let anchor = near.or(prior_active);
        let new_id = if let Some(a) = anchor.filter(|&i| i < self.panes.len()) {
            self.split_leaf_with(a, crate::layout::SplitDir::Horizontal, preview)
        } else {
            self.panes.push(preview);
            let id = self.panes.len() - 1;
            self.layout = Layout::Leaf(id);
            id
        };
        if focus_preview {
            self.active = Some(new_id);
            self.focus = Focus::Pane;
        } else {
            // `split_leaf_with` doesn't touch `self.active`, but be explicit
            // — passive auto-open should leave focus exactly where it was.
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

    // ─── pty / AI-CLI panes ─────────────────────────────────────────
    /// Open an embedded terminal (`profile` = shell / `claude` / `codex`) as a
    /// stacked split below the focused leaf (a terminal "drawer"), and focus it.
    pub fn open_pty(&mut self, profile: crate::pty_pane::BinaryProfile) {
        // The initial size is a guess — `ui/pty_view` resizes the session to its
        // rendered area on the first frame.
        match crate::pty_pane::PtySession::spawn(profile, 24, 80) {
            Ok(s) => {
                let pane = Pane::Pty(s);
                match self.active {
                    Some(cur) => {
                        let new_id =
                            self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                        self.active = Some(new_id);
                    }
                    None => {
                        self.panes.push(pane);
                        let id = self.panes.len() - 1;
                        self.layout = Layout::Leaf(id);
                        self.active = Some(id);
                    }
                }
                self.focus = Focus::Pane;
            }
            Err(e) => self.toast(format!("can't open terminal: {e}")),
        }
    }

    pub fn open_shell(&mut self) {
        self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(
            self.workspace.clone(),
        )));
    }
    pub fn open_claude_code(&mut self) {
        self.open_pty(crate::pty_pane::BinaryProfile::claude_code(
            self.workspace.clone(),
        ));
    }
    pub fn open_codex(&mut self) {
        self.open_pty(crate::pty_pane::BinaryProfile::codex(
            self.workspace.clone(),
        ));
    }

    /// True if any pane is a pty (the event loop polls faster while one's open so
    /// streaming output stays smooth).
    pub fn has_pty_pane(&self) -> bool {
        self.panes.iter().any(|p| matches!(p, Pane::Pty(_)))
    }

    /// True while a `claude -p` run is in flight (so the event loop polls faster
    /// and streamed deltas render promptly).
    pub fn has_pending_ai(&self) -> bool {
        self.pending_commit_msg_job.is_some()
            || self.panes.iter().any(|p| {
                matches!(p, Pane::Ai(a)
                    if matches!(a.state, crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)))
            })
    }

    // ─── AI: `claude -p` one-shots ──────────────────────────────────
    /// Allocate a job id + fresh session id and spawn `claude -p --session-id …`
    /// on a worker thread. Returns `(job_id, session_id, cancel_flag)` — set the
    /// flag to ask the worker to kill its child and bail.
    fn spawn_ai_job(
        &mut self,
        prompt: String,
    ) -> (u64, String, std::sync::Arc<std::sync::atomic::AtomicBool>) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let session_id = crate::ai::gen_session_id();
        let tx = self
            .ai_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let sid = session_id.clone();
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        std::thread::spawn(move || {
            crate::ai::stream_to_channel(&prompt, &sid, &worker_cancel, tx, job_id);
        });
        (job_id, session_id, cancel)
    }

    /// Open a `Pane::Ai` showing `title` and the answer to `prompt`, and kick off
    /// `claude -p <prompt>` on a background thread (`tick` delivers the answer).
    pub fn ask_ai(&mut self, title: impl Into<String>, prompt: String) {
        let (job_id, session_id, cancel) = self.spawn_ai_job(prompt.clone());
        let pane = Pane::Ai(crate::ai::AiPane::new(
            title, prompt, session_id, job_id, cancel,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-send the prompt an existing `Pane::Ai` holds (with a fresh session id).
    /// No-op for a live transcript mirror (it has no `-p` prompt). Signals any
    /// still-running worker for this pane to bail first.
    fn reask_ai(&mut self, pane_id: PaneId) {
        let prompt = match self.panes.get(pane_id) {
            Some(Pane::Ai(a)) if !a.is_live() => {
                a.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
                a.prompt.clone()
            }
            _ => return,
        };
        let (job_id, session_id, cancel) = self.spawn_ai_job(prompt);
        if let Some(Pane::Ai(a)) = self.panes.get_mut(pane_id) {
            a.job_id = job_id;
            a.session_id = session_id;
            a.state = crate::ai::AiState::Asking;
            a.scroll = 0;
            a.cancel = cancel;
            a.pending_apply = None;
        }
    }

    /// `x` in an `Asking` `Pane::Ai` — ask the worker to kill `claude -p` and bail
    /// (the reply lands as `Failed("cancelled")`).
    pub fn cancel_active_ai(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Ai(a)) = self.panes.get(cur)
            && matches!(
                a.state,
                crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)
            )
        {
            a.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            self.toast("cancelling…");
        }
    }

    /// `c` in a `Pane::Ai`: open `claude --resume <session>` interactively (a split
    /// below) so you can carry the conversation further — and flip this pane into
    /// a live transcript mirror of that session.
    pub fn continue_active_ai(&mut self) {
        let Some(cur) = self.active else { return };
        let sid = match self.panes.get(cur) {
            Some(Pane::Ai(a))
                if matches!(
                    a.state,
                    crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)
                ) =>
            {
                self.toast("wait for the answer first");
                return;
            }
            Some(Pane::Ai(a)) => a.session_id.clone(),
            _ => return,
        };
        // Flip the source pane to a live mirror (unless it already is one).
        if let Some(path) = crate::ai::transcript::session_path(&self.workspace, &sid)
            && let Some(Pane::Ai(a)) = self.panes.get_mut(cur)
            && !a.is_live()
        {
            let turns = crate::ai::transcript::read(&path);
            let last_len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            a.state = crate::ai::AiState::Live {
                path,
                last_len,
                turns,
            };
            a.scroll = usize::MAX;
        }
        self.open_pty(crate::pty_pane::BinaryProfile::claude_code_resume(
            self.workspace.clone(),
            sid,
        ));
    }

    /// `ai.session_view` — open a live transcript mirror for the active `Pane::Pty`'s
    /// session (a `claude` pane started by mnml, which knows its `--session-id`).
    pub fn open_session_view(&mut self) {
        let Some(cur) = self.active else { return };
        let sid = match self.panes.get(cur) {
            Some(Pane::Pty(s)) => match &s.profile.session_id {
                Some(sid) => sid.clone(),
                None => {
                    self.toast("this terminal has no Claude session to mirror");
                    return;
                }
            },
            Some(Pane::Ai(a)) => a.session_id.clone(),
            _ => {
                self.toast("open a Claude Code pane first (<leader>a c)");
                return;
            }
        };
        let Some(path) = crate::ai::transcript::session_path(&self.workspace, &sid) else {
            self.toast("can't locate the session transcript ($HOME unset?)");
            return;
        };
        // If we're already showing this session's mirror, just focus it.
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Ai(a) if a.is_live() && a.session_id == sid))
        {
            self.reveal_pane(i);
            return;
        }
        let pane = Pane::Ai(crate::ai::AiPane::live(sid, path));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Re-read any live transcript mirrors whose `.jsonl` has grown — incrementally:
    /// only the bytes past `last_len` are read and parsed (up to the last complete
    /// line) and their turns appended. A shrunk file (rotation / rewrite) triggers a
    /// full re-read.
    fn refresh_live_ai_panes(&mut self) {
        use std::io::{Read, Seek, SeekFrom};
        for pane in &mut self.panes {
            let Pane::Ai(a) = pane else { continue };
            let crate::ai::AiState::Live {
                path,
                last_len,
                turns,
            } = &mut a.state
            else {
                continue;
            };
            let len = std::fs::metadata(&*path).map(|m| m.len()).unwrap_or(0);
            if len < *last_len {
                // file shrank / rotated — re-read from scratch.
                *turns = crate::ai::transcript::read(path);
                *last_len = std::fs::metadata(&*path).map(|m| m.len()).unwrap_or(0);
                continue;
            }
            if len == *last_len {
                continue;
            }
            // Append-only growth: read just the new tail, parse complete lines.
            let mut chunk = String::new();
            let ok = std::fs::File::open(&*path)
                .and_then(|mut f| {
                    f.seek(SeekFrom::Start(*last_len))?;
                    f.read_to_string(&mut chunk)
                })
                .is_ok();
            if !ok {
                continue;
            }
            let Some(cut) = chunk.rfind('\n').map(|i| i + 1) else {
                continue; // a partial line is still being written — wait for the rest
            };
            turns.extend(crate::ai::transcript::parse(&chunk[..cut]));
            *last_len += cut as u64;
        }
    }

    /// `ai.explain` / `ai.fix` / `ai.refactor` / `ai.write_tests` — feed the active
    /// editor's selection (or the whole buffer) + a task prompt to `claude -p`.
    /// For `fix`/`refactor` the source range is remembered as the answer pane's
    /// [`ApplyTarget`](crate::ai::ApplyTarget) so `a` can apply the suggested code.
    pub fn ai_action(&mut self, what: &str) {
        let (code, lang, target) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) => {
                let sel = b.editor.selected_text();
                let (code, range) = if sel.trim().is_empty() {
                    let t = b.editor.text();
                    (t.to_string(), (0usize, t.len()))
                } else {
                    let r = b.editor.selection().unwrap_or((0, 0));
                    (sel, r)
                };
                let target = if matches!(what, "fix" | "refactor") {
                    b.path.clone().map(|path| crate::ai::ApplyTarget {
                        path,
                        start: range.0.min(range.1),
                        end: range.0.max(range.1),
                    })
                } else {
                    None
                };
                (code, b.language_ext.clone().unwrap_or_default(), target)
            }
            // Re-fire from an existing AI pane.
            Some(Pane::Ai(_)) => {
                if let Some(cur) = self.active {
                    self.reask_ai(cur);
                }
                return;
            }
            _ => {
                self.toast("AI actions need an editor (select code, or use the whole file)");
                return;
            }
        };
        if code.trim().is_empty() {
            self.toast("nothing to send");
            return;
        }
        let title = format!("AI: {}", what.replace('_', " "));
        self.ask_ai(title, crate::ai::action_prompt(what, &code, &lang));
        if target.is_some()
            && let Some(Pane::Ai(a)) = self.active.and_then(|i| self.panes.get_mut(i))
        {
            a.target = target;
        }
    }

    /// `a` in a Done `Pane::Ai`: first press *stages* the first fenced code block
    /// from the answer against the range the AI was asked about — building a diff
    /// preview the pane renders. A second `a` applies it (a `ReplaceRange`, left
    /// dirty: review, undo to revert). `r` (re-ask) discards a staged suggestion.
    /// No-op without a recorded target / a code block in the answer.
    pub fn apply_ai_suggestion(&mut self) {
        let Some(cur) = self.active else { return };
        // If a suggestion is already staged, this press applies it.
        if let Some(Pane::Ai(a)) = self.panes.get_mut(cur)
            && let Some(p) = a.pending_apply.take()
        {
            self.do_apply_suggestion(p.target, p.code);
            return;
        }
        // Otherwise stage it: parse target + code, diff against the live range.
        let parsed: Result<(crate::ai::ApplyTarget, String), &'static str> =
            match self.panes.get(cur) {
                Some(Pane::Ai(a)) => match (&a.target, &a.state) {
                    (None, _) => Err("nothing to apply here (use AI `fix`/`refactor` on a buffer)"),
                    (Some(_), crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)) => {
                        Err("wait for the answer first")
                    }
                    (Some(t), crate::ai::AiState::Done(text)) => {
                        match crate::ai::first_code_block(text) {
                            Some(code) => Ok((t.clone(), code)),
                            None => Err("no code block in the answer to apply"),
                        }
                    }
                    (Some(_), _) => Err("nothing to apply (the run didn't finish ok)"),
                },
                _ => return,
            };
        let (target, code) = match parsed {
            Ok(v) => v,
            Err(msg) => {
                self.toast(msg);
                return;
            }
        };
        // The current text of the target range (from the open editor, or disk).
        let old = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&target.path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .or_else(|| std::fs::read_to_string(&target.path).ok())
            .unwrap_or_default();
        let old_range = {
            let s = target.start.min(old.len());
            let e = target.end.min(old.len()).max(s);
            old[s..e].to_string()
        };
        if old_range == code {
            self.toast("the suggestion matches what's already there");
            return;
        }
        let diff = crate::ai::line_diff(&old_range, &code);
        if let Some(Pane::Ai(a)) = self.panes.get_mut(cur) {
            a.pending_apply = Some(crate::ai::PendingApply { target, code, diff });
            a.scroll = usize::MAX; // show the preview at the bottom
        }
        self.toast("review the diff below — press a again to apply (r re-asks)");
    }

    /// Actually splice the AI suggestion's `code` over `target` in the editor
    /// (opening the file if needed), left dirty.
    fn do_apply_suggestion(&mut self, target: crate::ai::ApplyTarget, code: String) {
        if !self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.is_at(&target.path)))
        {
            self.open_path(&target.path);
        }
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&target.path)))
        else {
            self.toast("couldn't open the source file");
            return;
        };
        let clip = &mut self.clipboard;
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let len = b.editor.text().len();
            let start = target.start.min(len);
            let end = target.end.min(len).max(start);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end,
                    text: code,
                }],
                clip,
                0,
            );
        }
        if let Some(Pane::Editor(b)) = self.panes.get(idx)
            && let Some(p) = b.path.clone()
        {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&p, &t);
        }
        self.reveal_pane(idx);
        self.toast("applied — review it; undo to revert");
    }

    /// `rqst.ai_debug` (`.` in a request pane) — hand the request + its response
    /// (or transport error) to `claude -p` and ask why it's failing / how to fix.
    pub fn ai_debug_request(&mut self) {
        use crate::request_pane::RunState;
        let prompt = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => {
                let req = &rp.request;
                let mut req_text = format!("{} {}\n", req.method, req.url);
                for (k, v) in &req.headers {
                    req_text.push_str(&format!("{k}: {v}\n"));
                }
                if let Some(b) = &req.body {
                    req_text.push_str(&format!("\n{b}\n"));
                }
                let resp_text = match &rp.state {
                    RunState::Sending => "(still in flight — wait for it)".to_string(),
                    RunState::Failed(e) => format!("transport error: {e}"),
                    RunState::Done(r) => {
                        let mut s = format!("{} {}\n", r.status, r.status_text);
                        for (k, v) in &r.headers {
                            s.push_str(&format!("{k}: {v}\n"));
                        }
                        let body: String = r.body.chars().take(4000).collect();
                        s.push_str(&format!("\n{body}\n"));
                        s
                    }
                };
                if matches!(rp.state, RunState::Sending) {
                    self.toast("wait for the response first");
                    return;
                }
                format!(
                    "This HTTP request isn't behaving. What's likely wrong and how do I fix it? \
                     Be concise.\n\n## Request\n```http\n{req_text}```\n\n## Response\n```\n{resp_text}```"
                )
            }
            _ => {
                self.toast("open a request pane first (rqst.send)");
                return;
            }
        };
        self.ask_ai("AI: debug request", prompt);
    }

    /// Re-fire the active `Pane::Ai`'s prompt (its `r` key).
    pub fn resend_active_ai(&mut self) {
        if let Some(cur) = self
            .active
            .filter(|&i| matches!(self.panes.get(i), Some(Pane::Ai(_))))
        {
            self.reask_ai(cur);
        }
    }

    /// `ai.ask` — accepted from the text-input prompt: a free-text question to `claude -p`.
    pub fn open_ai_ask_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::AiAsk,
            "Ask Claude",
        ));
    }

    /// Drain the streamed `claude -p` messages into their `Pane::Ai` (deltas
    /// accumulate; a final Done/Failed settles the pane). The commit-message job
    /// shares this channel — it ignores deltas and acts on the final text.
    fn drain_ai_jobs(&mut self) {
        use crate::ai::{AiMsg, AiState};
        let Some((_, rx)) = &self.ai_chan else {
            return;
        };
        let msgs: Vec<AiJobMsg> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        for (job_id, msg) in msgs {
            // An "AI: rewrite HEAD's message" job? Route the final text to a
            // GitCommitAmend prompt (same shape as the GitCommit case below).
            if self.pending_amend_msg_job == Some(job_id) {
                let result = match msg {
                    AiMsg::Delta(_) => continue,
                    AiMsg::Done(text) => Ok(text),
                    AiMsg::Failed(e) => Err(e),
                };
                self.pending_amend_msg_job = None;
                match result {
                    Ok(text) => {
                        let summary = text
                            .lines()
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .unwrap_or("")
                            .trim_matches('`')
                            .trim()
                            .to_string();
                        if summary.is_empty() {
                            toasts.push("AI returned an empty commit message".to_string());
                        } else {
                            self.prompt = Some(crate::prompt::Prompt::seeded(
                                crate::prompt::PromptKind::GitCommitAmend,
                                "Rewrite HEAD's message (AI draft — edit & Enter)",
                                summary,
                            ));
                        }
                    }
                    Err(e) => toasts.push(format!("AI recompose: {e}")),
                }
                continue;
            }
            // An "AI: write me a commit message" job? Route the final text to the
            // commit prompt; deltas are noise here.
            if self.pending_commit_msg_job == Some(job_id) {
                let result = match msg {
                    AiMsg::Delta(_) => continue,
                    AiMsg::Done(text) => Ok(text),
                    AiMsg::Failed(e) => Err(e),
                };
                self.pending_commit_msg_job = None;
                for pane in &mut self.panes {
                    if let Pane::GitStatus(g) = pane
                        && g.ai_msg_job == Some(job_id)
                    {
                        g.ai_msg_job = None;
                    }
                }
                match result {
                    Ok(text) => {
                        let summary = text
                            .lines()
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .unwrap_or("")
                            .trim_matches('`')
                            .trim()
                            .to_string();
                        if summary.is_empty() {
                            toasts.push("AI returned an empty commit message".to_string());
                        } else {
                            self.prompt = Some(crate::prompt::Prompt::seeded(
                                crate::prompt::PromptKind::GitCommit,
                                "Commit message (AI draft — edit & Enter)",
                                summary,
                            ));
                        }
                    }
                    Err(e) => toasts.push(format!("AI commit message: {e}")),
                }
                continue;
            }
            let Some(Pane::Ai(a)) = self.panes.iter_mut().find(|p| {
                matches!(p, Pane::Ai(a)
                    if a.job_id == job_id
                    && matches!(a.state, AiState::Asking | AiState::Streaming(_)))
            }) else {
                continue;
            };
            match msg {
                AiMsg::Delta(s) => match &mut a.state {
                    AiState::Streaming(buf) => buf.push_str(&s),
                    _ => a.state = AiState::Streaming(s),
                },
                AiMsg::Done(text) => {
                    toasts.push(format!("{} — done", a.title));
                    a.state = AiState::Done(text);
                }
                AiMsg::Failed(e) => {
                    toasts.push(format!("AI: {e}"));
                    a.state = AiState::Failed(e);
                }
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    // ─── Playwright: test runner ────────────────────────────────────
    /// Open a `Pane::Tests` and kick off `npx playwright test --reporter=json
    /// <extra_args>` on a worker thread (`tick` delivers the results).
    fn run_playwright(&mut self, extra_args: Vec<String>) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .tests_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let ws = self.workspace.clone();
        let args = extra_args.clone();
        std::thread::spawn(move || {
            let _ = tx.send((job_id, crate::playwright::run(&ws, &args)));
        });
        // Re-use an existing tests pane if there is one; else open a split.
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Tests(_))) {
            if let Some(Pane::Tests(t)) = self.panes.get_mut(id) {
                t.state = crate::playwright::TestsState::Running;
                t.last_args = extra_args;
                t.job_id = job_id;
                t.scroll = 0;
                t.selected = 0;
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Tests(crate::playwright::TestsPane::new(
            self.workspace.clone(),
            extra_args,
            job_id,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// `test.run_all` — the whole Playwright suite.
    pub fn run_tests_all(&mut self) {
        self.run_playwright(Vec::new());
    }

    /// `test.run_file` — the active editor's spec file.
    pub fn run_tests_file(&mut self) {
        match self.active_editor().and_then(|b| b.path.as_deref()) {
            Some(p) => {
                let rel = rel_path(&self.workspace, p);
                self.run_playwright(vec![rel]);
            }
            None => self.toast("open a .spec file first"),
        }
    }

    /// `test.run_at_cursor` — the test at the cursor (Playwright's `file:line` selector).
    pub fn run_tests_at_cursor(&mut self) {
        match self.active_editor() {
            Some(b) => match &b.path {
                Some(p) => {
                    let rel = rel_path(&self.workspace, p);
                    let line = b.editor.row_col().0 + 1;
                    self.run_playwright(vec![format!("{rel}:{line}")]);
                }
                None => self.toast("open a saved .spec file first"),
            },
            None => self.toast("open a .spec file first"),
        }
    }

    /// `test.rerun_failed` — re-run just the failures of the last run (Playwright's `--last-failed`).
    pub fn rerun_failed_tests(&mut self) {
        self.run_playwright(vec!["--last-failed".to_string()]);
    }

    /// `r` in a tests pane — re-run with the same args as last time.
    pub fn rerun_active_tests(&mut self) {
        let args = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => t.last_args.clone(),
            _ => return,
        };
        self.run_playwright(args);
    }

    /// `t` in a tests pane — parse the highlighted test's retained `trace.zip` (we
    /// run with `--trace=retain-on-failure`, so failures have one) and open it as a
    /// `Pane::Trace` timeline in a split below.
    pub fn open_selected_test_trace(&mut self) {
        let info = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) => tc
                    .trace_path
                    .clone()
                    .map(|p| (tc.title.clone(), p))
                    .ok_or("no trace for that test (only failed tests retain one)"),
                None => return,
            },
            _ => {
                self.toast("select a test in the results pane first");
                return;
            }
        };
        let (title, path) = match info {
            Ok(v) => v,
            Err(msg) => {
                self.toast(msg);
                return;
            }
        };
        let events = match crate::playwright::trace::parse_trace_zip(&path) {
            Ok(e) => e,
            Err(e) => {
                self.toast(format!("trace: {e}"));
                return;
            }
        };
        let pane = Pane::Trace(crate::playwright::trace_pane::TracePane::new(
            title, path, events,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// `r` in a trace pane — re-parse the `trace.zip`.
    pub fn refresh_active_trace(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Trace(tr)) = self.panes.get_mut(cur)
            && let Err(e) = tr.refresh()
        {
            self.toast(format!("trace: {e}"));
        }
    }

    /// `test.heal` (`h` in a tests pane) — hand the highlighted *failing* test (its
    /// title, file, error, and the spec source) to `claude -p` and ask for a fix.
    /// Reuses the AI machinery; `c` in the resulting `Pane::Ai` promotes it to an
    /// interactive Claude Code session (which can actually apply the fix / call
    /// your healer agent).
    pub fn heal_selected_test(&mut self) {
        let info = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) if tc.status == crate::playwright::TestStatus::Failed => Some((
                    tc.title.clone(),
                    tc.suite_path.clone(),
                    tc.file.clone(),
                    tc.line,
                    tc.error.clone().unwrap_or_default(),
                )),
                Some(_) => {
                    self.toast("that test isn't failing — nothing to heal");
                    None
                }
                None => None,
            },
            _ => {
                self.toast("select a failing test in the results pane first");
                None
            }
        };
        let Some((title, suite, file, line, error)) = info else {
            return;
        };
        let src = std::fs::read_to_string(self.workspace.join(&file)).unwrap_or_default();
        let where_ = if suite.is_empty() {
            format!("{file}:{line}")
        } else {
            format!("{suite} › {title}  ({file}:{line})")
        };
        let prompt = format!(
            "This Playwright test is failing. Work out why and propose a fix — change the \
             test or the code under test as appropriate. Be concise; reply with the patch in a \
             fenced block plus a short note.\n\n## Failing test\n{where_}\n\n## Error\n```\n{error}\n```\n\n## {file}\n```ts\n{src}\n```"
        );
        self.ask_ai(format!("AI: heal {title}"), prompt);
    }

    /// `h` in a `Pane::Trace` — hand the failed test's *execution trace* (the
    /// timeline of actions / console output / errors) to `claude -p` and ask for a
    /// fix. Complements [`Self::heal_selected_test`] (which feeds the spec source):
    /// here Claude sees what actually happened at runtime and uses its tools to read
    /// the spec / code itself. `c` in the resulting `Pane::Ai` promotes it to an
    /// interactive Claude Code session.
    pub fn heal_from_active_trace(&mut self) {
        let (title, timeline) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Trace(tr)) => (tr.test_title.clone(), tr.timeline_text()),
            _ => {
                self.toast("open a trace pane first (`t` on a failed test)");
                return;
            }
        };
        if timeline.trim().is_empty() {
            self.toast("this trace has no events to heal from");
            return;
        }
        let prompt = format!(
            "A Playwright test failed. Below is its execution trace — the actions it \
             ran, console output, and errors, in order. Work out why it failed and \
             propose a fix; use your tools to read the spec and the code under test as \
             needed. Be concise: reply with the patch in a fenced block plus a short \
             note.\n\n## Failed test\n{title}\n\n## Execution trace\n```\n{timeline}\n```"
        );
        self.ask_ai(format!("AI: heal from trace · {title}"), prompt);
    }

    /// Jump the editor to the source of the highlighted test in a `Pane::Tests`.
    pub fn jump_to_selected_test(&mut self) {
        let Some(cur) = self.active else { return };
        let (rel, line) = match self.panes.get(cur) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) if !tc.file.is_empty() => {
                    (tc.file.clone(), tc.line.saturating_sub(1) as usize)
                }
                _ => return,
            },
            _ => return,
        };
        let path = self.workspace.join(&rel);
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
                b.editor.place_cursor(line, 0);
            }
            self.active = Some(id);
            self.focus = Focus::Pane;
        } else {
            self.open_path(&path);
            if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                b.editor.place_cursor(line, 0);
            }
        }
    }

    /// Move the highlighted-test cursor in a `Pane::Tests`.
    pub fn tests_move_selection(&mut self, delta: isize) {
        if let Some(Pane::Tests(t)) = self.active.and_then(|i| self.panes.get_mut(i))
            && let crate::playwright::TestsState::Done(r) = &t.state
        {
            let n = r.tests.len();
            if n == 0 {
                return;
            }
            let new = (t.selected as isize + delta).clamp(0, n as isize - 1) as usize;
            t.selected = new;
        }
    }

    fn drain_tests_jobs(&mut self) {
        use crate::playwright::TestsState;
        let Some((_, rx)) = &self.tests_chan else {
            return;
        };
        let done: Vec<TestsJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        let mut refresh_flaky = false;
        for (job_id, result) in done {
            let Some(Pane::Tests(t)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Tests(t) if t.job_id == job_id && matches!(t.state, TestsState::Running)),
            ) else {
                continue;
            };
            match result {
                Ok(run) => {
                    let (p, f, s) = (run.passed(), run.failed(), run.skipped());
                    toasts.push(if f > 0 {
                        format!(
                            "tests: {f} failed, {p} passed{}",
                            if s > 0 {
                                format!(", {s} skipped")
                            } else {
                                String::new()
                            }
                        )
                    } else {
                        format!(
                            "tests: all {p} passed{}",
                            if s > 0 {
                                format!(" ({s} skipped)")
                            } else {
                                String::new()
                            }
                        )
                    });
                    t.selected = run
                        .tests
                        .iter()
                        .position(|tc| tc.status == crate::playwright::TestStatus::Failed)
                        .unwrap_or(0);
                    // Update the workspace's persistent test-outcome history so
                    // run-to-run wobbly tests light up with a `≋` glyph.
                    self.test_history.record_run(&run);
                    self.test_history.save(&self.workspace);
                    t.state = TestsState::Done(Box::new(run));
                    // History changed ⇒ any open flaky pane should reflect it.
                    refresh_flaky = true;
                }
                Err(e) => {
                    toasts.push(format!(
                        "playwright: {}",
                        e.lines().next().unwrap_or("error")
                    ));
                    t.state = TestsState::Failed(e);
                }
            }
        }
        for tt in toasts {
            self.toast(tt);
        }
        if refresh_flaky {
            self.refresh_flaky_panes();
        }
    }

    // ─── CDP browser pane ───────────────────────────────────────────
    /// `browser.open` — prompt for a URL, then launch Chrome on it. (One browser
    /// pane at a time.)
    pub fn open_browser_prompt(&mut self) {
        if self.panes.iter().any(|p| matches!(p, Pane::Browser(_))) {
            self.toast("a browser pane is already open — close it first");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserUrl,
            "Open URL in Chrome",
            "https://",
        ));
    }

    /// Launch Chrome on `url` over CDP and open a `Pane::Browser` (split below).
    pub fn open_browser(&mut self, url: &str) {
        if self.panes.iter().any(|p| matches!(p, Pane::Browser(_))) {
            self.toast("a browser pane is already open — close it first");
            return;
        }
        let url = url.trim().to_string();
        let (ev_tx, ev_rx) = std::sync::mpsc::channel::<crate::cdp::CdpEvent>();
        let (cmd_tx, cmd_rx) = std::sync::mpsc::channel::<crate::cdp::CdpCommand>();
        let profile_dir = self.workspace.join(".mnml").join("chrome-profile");
        let _ = std::fs::create_dir_all(&profile_dir);
        let headless = self.config.browser.headless;
        let (worker_url, worker_dir) = (url.clone(), profile_dir);
        std::thread::spawn(move || {
            crate::cdp::run_session(&worker_url, &worker_dir, headless, &ev_tx, &cmd_rx);
        });
        self.cdp_chan = Some(ev_rx);
        let pane = Pane::Browser(crate::browser_pane::BrowserPane::new(url, cmd_tx));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// `g` in a browser pane — prompt for a URL to navigate to (seeded with the
    /// current URL).
    pub fn browser_navigate_prompt(&mut self) {
        let url = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.url.clone(),
            _ => return,
        };
        let seed = if url.trim().is_empty() {
            "https://".to_string()
        } else {
            url
        };
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserNavigate,
            "Navigate to",
            seed,
        ));
    }

    /// `e` in a browser pane — prompt for JS to evaluate in the page.
    pub fn browser_eval_prompt(&mut self) {
        if !matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Browser(_))
        ) {
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::BrowserEval,
            "Eval JS in the page",
        ));
    }

    /// `r` in a browser pane — reload the page.
    pub fn browser_reload(&mut self) {
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.reload();
        }
    }

    /// `s` in a browser pane (or `browser.screenshot`) — capture the viewport;
    /// the PNG is written to `.mnml/screenshots/` when the reply arrives.
    pub fn browser_screenshot(&mut self) {
        match self
            .panes
            .iter_mut()
            .find(|p| matches!(p, Pane::Browser(_)))
        {
            Some(Pane::Browser(b)) => b.screenshot(),
            _ => self.toast("no browser pane open"),
        }
    }

    /// `T` in the browser pane — open a picker over discovered CDP targets
    /// (main page + auto-attached popups / new tabs / iframes). Accept ⇒
    /// `browser.switch_target` routes subsequent commands there.
    pub fn open_browser_target_picker(&mut self) {
        use crate::picker::PickerItem;
        let Some(Pane::Browser(b)) = self.panes.iter().find(|p| matches!(p, Pane::Browser(_)))
        else {
            self.toast("no browser pane open");
            return;
        };
        if b.targets.len() <= 1 {
            self.toast("only one target (no popups / iframes attached)");
            return;
        }
        let items: Vec<PickerItem> = b
            .targets
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let star = if i == b.current_target { "● " } else { "  " };
                let label = if t.session_id.is_empty() {
                    format!("{star}main · {}", t.url)
                } else {
                    let title = if t.title.is_empty() {
                        "(no title)"
                    } else {
                        &t.title
                    };
                    format!("{star}{} · {title}", t.kind)
                };
                PickerItem::new(i.to_string(), label, t.url.clone())
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::BrowserTargets,
            format!("Browser targets ({})", b.targets.len()),
            items,
        ));
    }

    /// Accept handler for `PickerKind::BrowserTargets` — `idx` is parsed from
    /// `PickerItem.id`. Switches the active browser pane's current target.
    pub fn switch_browser_target(&mut self, idx: usize) {
        if let Some(Pane::Browser(b)) = self
            .panes
            .iter_mut()
            .find(|p| matches!(p, Pane::Browser(_)))
        {
            b.switch_target(idx);
        }
    }

    /// `D` in a browser pane (or `browser.dom`) — fetch `DOM.getDocument` if we
    /// haven't yet, and toggle into the DOM panel. (`R` in the panel re-fetches.)
    pub fn browser_open_dom(&mut self) {
        let Some(Pane::Browser(b)) = self
            .panes
            .iter_mut()
            .find(|p| matches!(p, Pane::Browser(_)))
        else {
            self.toast("no browser pane open");
            return;
        };
        if b.dom.is_empty() && b.pending_dom.is_none() {
            b.fetch_dom();
        }
        b.dom_focus = true;
        b.net_focus = false;
        b.dom_sel = b.dom_sel.min(b.dom.len().saturating_sub(1));
    }

    /// `c` in the browser pane's DOM panel — copy the selected node's CSS-ish
    /// selector to the clipboard.
    pub fn copy_dom_selector(&mut self) {
        let sel = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_dom().map(|r| r.selector.clone()),
            _ => None,
        };
        match sel {
            Some(s) if !s.is_empty() => {
                self.clipboard.set(s, false);
                self.toast("copied selector");
            }
            _ => self.toast("no selector for the highlighted row"),
        }
    }

    /// Decode a base64 PNG (from `Page.captureScreenshot`), write it under
    /// `<workspace>/.mnml/screenshots/shot-<millis>.png`, and hand it to the OS's
    /// default image viewer (best-effort). Returns the path.
    fn save_screenshot_png(&self, b64: &str) -> Result<std::path::PathBuf, String> {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .map_err(|e| format!("base64 decode: {e}"))?;
        let dir = self.workspace.join(".mnml").join("screenshots");
        std::fs::create_dir_all(&dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let path = dir.join(format!("shot-{millis}.png"));
        std::fs::write(&path, &bytes).map_err(|e| format!("writing {}: {e}", path.display()))?;
        // Hand the PNG to the OS's default image viewer — best-effort, errors
        // ignored (no viewer available is fine, the file is already on disk).
        open_path_external(&path);
        Ok(path)
    }

    /// `y` in the browser pane's network panel — copy the selected request as a
    /// curl command to the clipboard.
    pub fn copy_net_entry_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_net().map(crate::browser_pane::NetEntry::as_curl),
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no network request selected"),
        }
    }

    /// `Enter` in the browser pane's network panel — open the selected request in a
    /// `Pane::Request` (split below the browser) and re-send it.
    pub fn open_net_entry_as_request(&mut self) {
        let Some(cur) = self.active else { return };
        let request = match self.panes.get(cur) {
            Some(Pane::Browser(b)) => b
                .selected_net()
                .map(crate::browser_pane::NetEntry::to_request),
            _ => None,
        };
        let Some(request) = request else {
            self.toast("no network request selected");
            return;
        };
        let script = crate::http::script::Script::default();
        let job_id = self.spawn_http_job(request.clone(), script.clone());
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            None, request, script, job_id,
        ));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Drain the CDP worker's event channel into the (single) `Pane::Browser`.
    fn drain_cdp_events(&mut self) {
        let Some(rx) = &self.cdp_chan else { return };
        let mut events = Vec::new();
        let mut disconnected = false;
        loop {
            match rx.try_recv() {
                Ok(ev) => events.push(ev),
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    disconnected = true;
                    break;
                }
            }
        }
        if events.is_empty() && !disconnected {
            return;
        }
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Browser(_)))
        else {
            if disconnected {
                self.cdp_chan = None;
            }
            return;
        };
        for ev in events {
            match ev {
                crate::cdp::CdpEvent::Connected { .. } => {
                    if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                        b.push(crate::browser_pane::LogKind::System, "connected to Chrome");
                    }
                }
                crate::cdp::CdpEvent::Message(v) => self.apply_cdp_message(idx, v),
                crate::cdp::CdpEvent::Closed(reason) => {
                    if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                        b.closed = true;
                        b.push(
                            crate::browser_pane::LogKind::System,
                            format!("session ended: {reason}"),
                        );
                    }
                }
            }
        }
        if disconnected {
            self.cdp_chan = None;
        }
    }

    /// Apply one raw CDP message (an event, or a reply to one of our requests) to
    /// the browser pane at `idx`.
    fn apply_cdp_message(&mut self, idx: usize, v: serde_json::Value) {
        use crate::browser_pane::LogKind;
        // A reply to a request we issued?
        if let Some(id) = v.get("id").and_then(serde_json::Value::as_i64) {
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.pending_eval == Some(id)) {
                let text = cdp_eval_result_text(&v);
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_eval = None;
                    b.push(LogKind::Eval, format!("= {text}"));
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.pending_screenshot == Some(id))
            {
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_screenshot = None;
                }
                let data = v
                    .get("result")
                    .and_then(|r| r.get("data"))
                    .and_then(serde_json::Value::as_str);
                match data.map(|d| self.save_screenshot_png(d)) {
                    Some(Ok(path)) => {
                        let p = path.display().to_string();
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::System, format!("screenshot → {p}"));
                        }
                        self.toast(format!("screenshot saved: {p}"));
                    }
                    Some(Err(e)) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::ConsoleErr, format!("screenshot failed: {e}"));
                        }
                        self.toast(format!("screenshot failed: {e}"));
                    }
                    None => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::ConsoleErr, "screenshot: empty reply from Chrome");
                        }
                    }
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_post_data(id)) {
                let data = v
                    .get("result")
                    .and_then(|r| r.get("postData"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.fill_post_data(id, data);
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.pending_dom == Some(id)) {
                let rows = v
                    .get("result")
                    .and_then(|r| r.get("root"))
                    .map(crate::browser_pane::parse_dom)
                    .unwrap_or_default();
                let n = rows.len();
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_dom = None;
                    b.set_dom(rows);
                    b.push(LogKind::System, format!("DOM loaded ({n} rows)"));
                }
                return;
            }
            return;
        }
        let method = v
            .get("method")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let params = v.get("params");
        let Some(Pane::Browser(b)) = self.panes.get_mut(idx) else {
            return;
        };
        match method {
            "Runtime.consoleAPICalled" => {
                let typ = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("log");
                let text = params
                    .and_then(|p| p.get("args"))
                    .and_then(serde_json::Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(cdp_remote_object_str)
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .unwrap_or_default();
                let kind = if matches!(typ, "error" | "assert") {
                    LogKind::ConsoleErr
                } else {
                    LogKind::Console
                };
                b.push(kind, format!("console.{typ}: {text}"));
            }
            "Log.entryAdded" => {
                let entry = params.and_then(|p| p.get("entry"));
                let level = entry
                    .and_then(|e| e.get("level"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("info");
                let text = entry
                    .and_then(|e| e.get("text"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let kind = if level == "error" {
                    LogKind::ConsoleErr
                } else {
                    LogKind::Console
                };
                b.push(kind, format!("[{level}] {text}"));
            }
            "Runtime.exceptionThrown" => {
                let det = params.and_then(|p| p.get("exceptionDetails"));
                let msg = det
                    .and_then(|d| d.get("exception"))
                    .and_then(|e| e.get("description"))
                    .and_then(serde_json::Value::as_str)
                    .or_else(|| {
                        det.and_then(|d| d.get("text"))
                            .and_then(serde_json::Value::as_str)
                    })
                    .unwrap_or("exception");
                b.push(
                    LogKind::ConsoleErr,
                    format!("⚠ {}", msg.lines().next().unwrap_or(msg)),
                );
            }
            "Page.frameNavigated" => {
                let frame = params.and_then(|p| p.get("frame"));
                let is_main = frame.map(|f| f.get("parentId").is_none()).unwrap_or(false);
                if is_main
                    && let Some(url) = frame
                        .and_then(|f| f.get("url"))
                        .and_then(serde_json::Value::as_str)
                {
                    b.url = url.to_string();
                    b.push(LogKind::Nav, format!("→ {url}"));
                }
            }
            "Target.targetCreated" => {
                let ti = params.and_then(|p| p.get("targetInfo"));
                let ty = ti
                    .and_then(|i| i.get("type"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                // The page we're driving fires this for itself (`attached:true`) — skip.
                let attached = ti
                    .and_then(|i| i.get("attached"))
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                if ty == "page" && !attached {
                    let url = ti
                        .and_then(|i| i.get("url"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("about:blank");
                    b.push(LogKind::Nav, format!("⤴ new tab → {url}"));
                }
            }
            "Target.attachedToTarget" => {
                // Multi-page: a popup / new tab / iframe auto-attached. Add
                // it to the pane's target list so the user can `T` to it.
                let session_id = params
                    .and_then(|p| p.get("sessionId"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let ti = params.and_then(|p| p.get("targetInfo"));
                if !session_id.is_empty()
                    && let Some(ti) = ti
                {
                    b.note_attached_target(session_id, ti);
                    let label = b
                        .targets
                        .last()
                        .map(|t| {
                            if t.title.is_empty() {
                                t.url.clone()
                            } else {
                                t.title.clone()
                            }
                        })
                        .unwrap_or_default();
                    b.push(LogKind::System, format!("attached → {label}"));
                }
            }
            "Target.targetInfoChanged" => {
                if let Some(ti) = params.and_then(|p| p.get("targetInfo")) {
                    b.note_target_info_changed(ti);
                }
            }
            "Target.detachedFromTarget" => {
                let session_id = params
                    .and_then(|p| p.get("sessionId"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if !session_id.is_empty() {
                    b.note_detached_target(session_id);
                    b.push(LogKind::System, "detached target".to_string());
                }
            }
            "Network.requestWillBeSent" => {
                let rtype = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str);
                if cdp_resource_type_is_interesting(rtype) {
                    let req = params.and_then(|p| p.get("request"));
                    let method = req
                        .and_then(|r| r.get("method"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("GET");
                    let url = req
                        .and_then(|r| r.get("url"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    b.push(LogKind::Net, format!("→ {method} {}", cdp_short_url(url)));
                    if let (Some(id), Some(req)) = (
                        params
                            .and_then(|p| p.get("requestId"))
                            .and_then(serde_json::Value::as_str),
                        req,
                    ) {
                        b.note_net_request(id, req);
                    }
                }
            }
            "Network.responseReceived" => {
                let rtype = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str);
                if cdp_resource_type_is_interesting(rtype) {
                    let resp = params.and_then(|p| p.get("response"));
                    let status = resp
                        .and_then(|r| r.get("status"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(0);
                    let url = resp
                        .and_then(|r| r.get("url"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    b.push(LogKind::Net, format!("← {status} {}", cdp_short_url(url)));
                    if let Some(id) = params
                        .and_then(|p| p.get("requestId"))
                        .and_then(serde_json::Value::as_str)
                    {
                        let mime = resp
                            .and_then(|r| r.get("mimeType"))
                            .and_then(serde_json::Value::as_str);
                        b.note_net_response(id, status, mime);
                    }
                }
            }
            "Network.loadingFailed" => {
                let rtype = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str);
                if cdp_resource_type_is_interesting(rtype) {
                    let why = params
                        .and_then(|p| p.get("errorText"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("failed");
                    b.push(LogKind::ConsoleErr, format!("✗ request failed: {why}"));
                    if let Some(id) = params
                        .and_then(|p| p.get("requestId"))
                        .and_then(serde_json::Value::as_str)
                    {
                        b.note_net_failed(id, why);
                    }
                }
            }
            _ => {} // loadEventFired, snapshots, etc. — not mirrored here
        }
    }

    // ─── HTTP: request pane ─────────────────────────────────────────
    /// `rqst.send` — parse the active `.http`/`.rest`/`.curl` editor (the block
    /// under the cursor for multi-block `.http` files), expand `{{vars}}` against
    /// `.mnml/env/$MNML_ENV`, open a `Pane::Request` split, and fire the request
    /// on a background thread. `tick` delivers the response.
    pub fn send_request_from_active(&mut self) {
        use crate::http::{self, template::EnvSet};
        let Some(cur) = self.active else {
            self.toast("no active editor");
            return;
        };
        // From an existing request pane, `rqst.send` just re-fires it.
        if matches!(self.panes.get(cur), Some(Pane::Request(_))) {
            self.refire_request(cur);
            return;
        }
        let (path, ext, text, cursor_row) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => (
                b.path.clone(),
                b.language_ext.clone().unwrap_or_default(),
                b.editor.text().to_string(),
                b.editor.row_col().0,
            ),
            _ => {
                self.toast("not an editor");
                return;
            }
        };
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            self.toast("rqst.send needs a .http / .rest / .curl file");
            return;
        }

        // Pick the request + the directive text. For `.http`/`.rest`, use the
        // block under the cursor; otherwise treat the whole buffer as one request.
        // `source_block_name` is captured iff the file is genuinely multi-block
        // (>1 parsed block) — single-block files round-trip through the simple
        // overwrite path on save.
        let (mut request, script_src, source_block_name): (http::Request, String, Option<String>) =
            if matches!(ext.as_str(), "http" | "rest")
                && let Ok(blocks) = http::file::parse_all(&text)
            {
                let lines: Vec<&str> = text.split('\n').collect();
                let b = blocks
                    .iter()
                    .find(|b| cursor_row >= b.start_line && cursor_row <= b.end_line)
                    .unwrap_or(&blocks[0]);
                let src =
                    lines[b.start_line..=b.end_line.min(lines.len().saturating_sub(1))].join("\n");
                let block_name = if blocks.len() > 1 {
                    // Multi-block. `b.name` is `Some(s)` when the block had a
                    // `###` separator with text, `None` for the leading
                    // headerless block. Distinguish the two on save by
                    // remembering "no separator at all" vs "bare ###" — if the
                    // block's first line *is* `###`, store `Some("")`.
                    if lines
                        .get(b.start_line)
                        .is_some_and(|l| l.trim_start().starts_with("###"))
                    {
                        Some(b.name.clone().unwrap_or_default())
                    } else {
                        None
                    }
                } else {
                    None
                };
                (b.request.clone(), src, block_name)
            } else {
                match http::parse(&text) {
                    Ok(r) => (r, text.clone(), None),
                    Err(e) => {
                        self.toast(format!("can't parse request: {e}"));
                        return;
                    }
                }
            };
        let script = http::script::parse(&script_src);
        let mut env = EnvSet::select(&self.workspace, None);
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in &mut request.headers {
            *v = http::template::expand(v, &env);
        }
        if let Some(b) = &mut request.body {
            *b = http::template::expand(b, &env);
        }

        let job_id = self.spawn_http_job(request.clone(), script.clone());
        let mut rp = crate::request_pane::RequestPane::new(path, request, script, job_id);
        rp.source_block_name = source_block_name;
        let new_id =
            self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, Pane::Request(rp));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Re-send the request a `Pane::Request` already holds (its `r` key / re-`rqst.send`).
    fn refire_request(&mut self, pane_id: PaneId) {
        // Apply edits from the Headers field (the editable buffer is the
        // source of truth in Edit mode — parse it back before sending).
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.commit_headers();
        }
        let (request, script) = match self.panes.get(pane_id) {
            Some(Pane::Request(rp)) => (rp.request.clone(), rp.script.clone()),
            _ => return,
        };
        let job_id = self.spawn_http_job(request, script);
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.job_id = job_id;
            rp.state = crate::request_pane::RunState::Sending;
            rp.scroll = 0;
        }
    }

    /// Allocate a job id, ensure the result channel exists, spawn the worker.
    fn spawn_http_job(
        &mut self,
        request: crate::http::Request,
        script: crate::http::script::Script,
    ) -> u64 {
        use crate::request_pane::ResponseView;
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .http_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        std::thread::spawn(move || {
            let result: Result<ResponseView, String> = (|| {
                let resp = crate::http::send(&request)?;
                let assertions = crate::http::script::run_assertions(
                    &script,
                    resp.status,
                    &resp.headers,
                    &resp.body,
                );
                let mut env = crate::http::template::EnvSet::empty();
                let captures = crate::http::script::apply_captures(
                    &script,
                    &resp.headers,
                    &resp.body,
                    &mut env,
                );
                Ok(ResponseView {
                    status: resp.status,
                    status_text: resp.status_text,
                    headers: resp.headers,
                    body: resp.body,
                    elapsed: resp.elapsed,
                    assertions,
                    captures,
                })
            })();
            let _ = tx.send((job_id, result));
        });
        job_id
    }

    /// `Y` in a request pane — copy the *response* body to the clipboard.
    pub fn copy_active_response_body(&mut self) {
        use crate::request_pane::RunState;
        let body = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => match &rp.state {
                RunState::Done(r) => Some(r.body.clone()),
                RunState::Sending => {
                    self.toast("wait for the response first");
                    return;
                }
                RunState::Failed(_) => {
                    self.toast("no response — the request failed");
                    return;
                }
            },
            _ => None,
        };
        match body {
            Some(b) if !b.is_empty() => {
                self.clipboard.set(b, false);
                self.toast("copied response body");
            }
            Some(_) => self.toast("response body is empty"),
            None => self.toast("not a request pane"),
        }
    }

    /// `rqst.copy_curl` — copy the active request (in an editor: parse the buffer;
    /// in a request pane: the request it holds) to the clipboard as a curl command.
    pub fn copy_active_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => Some(rp.as_curl()),
            Some(Pane::Editor(b))
                if matches!(b.language_ext.as_deref(), Some("http" | "rest" | "curl")) =>
            {
                crate::http::parse(b.editor.text()).ok().map(|r| {
                    crate::request_pane::RequestPane::new(None, r, Default::default(), 0).as_curl()
                })
            }
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no request here to copy"),
        }
    }

    /// Deliver any completed background HTTP sends to their request panes.
    fn drain_http_jobs(&mut self) {
        use crate::request_pane::RunState;
        let Some((_, rx)) = &self.http_chan else {
            return;
        };
        let done: Vec<HttpJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        for (job_id, result) in done {
            let Some(Pane::Request(rp)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Request(rp) if rp.job_id == job_id && matches!(rp.state, RunState::Sending)),
            ) else {
                continue;
            };
            match result {
                Ok(rv) => {
                    let failed = rv.assertions.iter().filter(|a| !a.passed).count();
                    let total = rv.assertions.len();
                    toasts.push(if total > 0 {
                        format!(
                            "← {} · {}/{} asserts passed",
                            rv.status,
                            total - failed,
                            total
                        )
                    } else {
                        format!("← {} {}", rv.status, rv.status_text)
                    });
                    rp.state = RunState::Done(Box::new(rv));
                }
                Err(e) => {
                    toasts.push(format!("request failed: {e}"));
                    rp.state = RunState::Failed(e);
                }
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    // ─── git: diff pane + blame ─────────────────────────────────────
    /// Workspace-relative path of an arbitrary path, for `git` arguments.
    fn rel_to_workspace(&self, p: &Path) -> String {
        rel_path(&self.workspace, p)
    }

    /// Toggle the editor's blame-gutter mode for the active buffer (computing
    /// `git blame` when turning it on).
    pub fn toggle_blame(&mut self) {
        let Some(cur) = self.active else { return };
        let already_on = matches!(self.panes.get(cur), Some(Pane::Editor(b)) if b.blame.is_some());
        if already_on {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
                b.blame = None;
            }
            self.toast("blame: off");
            return;
        }
        let rel = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => match &b.path {
                Some(p) => rel_path(&self.workspace, p),
                None => {
                    self.toast("blame needs a saved file");
                    return;
                }
            },
            _ => {
                self.toast("blame: not an editor");
                return;
            }
        };
        let lines = crate::git::blame::blame(&self.workspace, &rel);
        if lines.is_empty() {
            self.toast("git blame returned nothing (untracked file?)");
            return;
        }
        if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
            b.blame = Some(lines);
        }
        self.toast("blame: on");
    }

    /// If a buffer with blame mode on was just saved, recompute its blame.
    fn refresh_blame_for(&mut self, path: &Path) {
        let rel = rel_path(&self.workspace, path);
        let ws = self.workspace.clone();
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.blame.is_some()
                && b.is_at(path)
            {
                b.blame = Some(crate::git::blame::blame(&ws, &rel));
            }
        }
    }
    fn fetch_diff(&self, scope: &crate::pane::DiffScope) -> Vec<crate::git::diff::Hunk> {
        use crate::pane::DiffScope;
        match scope {
            DiffScope::Unstaged(Some(p)) => {
                crate::git::diff::diff_file(&self.workspace, &self.rel_to_workspace(p))
            }
            DiffScope::Unstaged(None) => crate::git::diff::diff_worktree(&self.workspace),
            DiffScope::Staged => crate::git::diff::diff_staged(&self.workspace),
            DiffScope::Commit(h) => crate::git::diff::show_commit(&self.workspace, h),
        }
    }
    /// Open a `git diff` view of the active editor's file, in a split to the right.
    pub fn open_diff_file(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.path.clone(),
            Some(Pane::Diff(d)) => match &d.scope {
                crate::pane::DiffScope::Unstaged(p) => p.clone(),
                crate::pane::DiffScope::Staged | crate::pane::DiffScope::Commit(_) => None,
            },
            _ => None,
        };
        let Some(path) = path else {
            self.toast("git diff needs a saved file");
            return;
        };
        let scope = crate::pane::DiffScope::Unstaged(Some(path));
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unstaged changes in that file");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(crate::pane::DiffView::new(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }
    /// `git.peek_change` (`<leader>g p`) — show the hunk under the cursor as
    /// a floating popup (uses the same hover widget as LSP). Toasts if the
    /// cursor isn't on a changed line.
    pub fn peek_git_change_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("git peek needs a saved file");
            return;
        };
        let (line_0, _) = b.editor.row_col();
        let rel = match path.strip_prefix(&self.workspace) {
            Ok(r) => r.to_string_lossy().to_string(),
            Err(_) => {
                self.toast("file is outside the workspace");
                return;
            }
        };
        let Some(hunk) = crate::git::diff::peek_hunk_at(&self.workspace, &rel, line_0) else {
            self.toast("no change at cursor");
            return;
        };
        // Format as: header line, then the hunk's lines with their `+`/`-`/` ` prefix.
        let mut out: Vec<String> = Vec::with_capacity(hunk.lines.len() + 1);
        out.push(hunk.header.clone());
        for hl in &hunk.lines {
            use crate::git::diff::HunkLine;
            match hl {
                HunkLine::Context(t) => out.push(format!(" {t}")),
                HunkLine::Added(t) => out.push(format!("+{t}")),
                HunkLine::Removed(t) => out.push(format!("-{t}")),
                HunkLine::NoNewline => out.push("\\ No newline at end of file".to_string()),
            }
        }
        match crate::hover::HoverPopup::from_lines(out) {
            Some(h) => self.hover = Some(h),
            None => self.toast("peek: (empty)"),
        }
    }

    /// Open a `git diff` view of the whole worktree, in the focused leaf.
    pub fn open_diff_worktree(&mut self) {
        let scope = crate::pane::DiffScope::Unstaged(None);
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unstaged changes");
            return;
        }
        self.panes
            .push(Pane::Diff(crate::pane::DiffView::new(scope, hunks)));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
    }
    /// Re-run the active diff pane's `git diff` (after staging, or on demand).
    pub fn refresh_active_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let scope = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => d.scope.clone(),
            _ => return,
        };
        let hunks = self.fetch_diff(&scope);
        if let Some(Pane::Diff(d)) = self.panes.get_mut(cur) {
            d.cursor = d.cursor.min(hunks.len().saturating_sub(1));
            d.hunks = hunks;
        }
    }
    /// Stage (`reverse == false`) / unstage the cursor hunk of the active diff pane.
    pub fn apply_cursor_hunk(&mut self, reverse: bool) {
        let Some(cur) = self.active else { return };
        let hunk = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => d.hunks.get(d.cursor).cloned(),
            _ => return,
        };
        let Some(hunk) = hunk else { return };
        if matches!(
            self.panes.get(cur),
            Some(Pane::Diff(d)) if matches!(d.scope, crate::pane::DiffScope::Commit(_))
        ) {
            self.toast("that's a committed change — nothing to stage");
            return;
        }
        match crate::git::diff::apply_hunk(&self.workspace, &hunk, reverse) {
            Ok(()) => {
                self.toast(if reverse {
                    "unstaged hunk"
                } else {
                    "staged hunk"
                });
                self.after_git_change();
                self.refresh_active_diff();
            }
            Err(e) => self.toast(format!("git apply failed: {e}")),
        }
    }
    /// Jump the source editor to the cursor hunk's first new-file line (if that
    /// file is open). Used by Enter in the diff pane.
    pub fn jump_to_cursor_hunk(&mut self) {
        let Some(cur) = self.active else { return };
        let (path, line) = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => match d.hunks.get(d.cursor) {
                Some(h) => (h.file.clone(), h.new_start.saturating_sub(1)),
                None => return,
            },
            _ => return,
        };
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
                b.editor.place_cursor(line, 0);
            }
            self.active = Some(id);
            self.focus = Focus::Pane;
        } else {
            self.open_path(&path);
            if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                b.editor.place_cursor(line, 0);
            }
        }
    }

    // ─── commit ─────────────────────────────────────────────────────
    /// Open the commit-message prompt. Commits whatever is staged when accepted;
    /// if nothing's staged, `git commit` says so.
    pub fn open_commit_prompt(&mut self) {
        let staged = self.git.snapshot().staged;
        let title = if staged > 0 {
            format!("Commit message ({staged} staged)")
        } else {
            "Commit message (nothing staged — stage hunks first)".to_string()
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GitCommit,
            title,
        ));
    }
    pub fn prompt_cancel(&mut self) {
        // Esc-cancel on a Find prompt restores the editor's prior find state
        // (incremental preview is dropped).
        let was_find = matches!(
            self.prompt.as_ref().map(|p| p.kind),
            Some(crate::prompt::PromptKind::Find)
        );
        self.prompt = None;
        self.pending_rename = None;
        self.pending_fs_action = None;
        self.pending_delete_branch = None;
        self.pending_worktree_remove = None;
        self.pending_branch_source = None;
        if was_find {
            self.restore_find_preview_snapshot();
        }
    }
    pub fn prompt_accept(&mut self) {
        let Some(p) = self.prompt.take() else { return };
        match p.kind {
            crate::prompt::PromptKind::GitCommit => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("commit cancelled (empty message)");
                    return;
                }
                match crate::git::commit::commit(&self.workspace, msg) {
                    Ok(summary) => {
                        self.toast(summary);
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit: {e}")),
                }
            }
            crate::prompt::PromptKind::GitCommitAmend => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("amend cancelled (empty message)");
                    return;
                }
                match crate::git::commit::amend(&self.workspace, msg) {
                    Ok(summary) => {
                        self.toast(format!("amended: {summary}"));
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit --amend: {e}")),
                }
            }
            crate::prompt::PromptKind::AiAsk => {
                let q = p.input.trim();
                if q.is_empty() {
                    return;
                }
                let short: String = q.chars().take(24).collect();
                let ellip = if q.chars().count() > 24 { "…" } else { "" };
                self.ask_ai(format!("AI: {short}{ellip}"), q.to_string());
            }
            crate::prompt::PromptKind::NewBranch => {
                let name = p.input.clone();
                self.create_branch(&name);
            }
            crate::prompt::PromptKind::LspRename => {
                let new_name = p.input.trim().to_string();
                let Some((path, line, ch)) = self.pending_rename.take() else {
                    return;
                };
                if new_name.is_empty() {
                    self.toast("rename cancelled (empty name)");
                    return;
                }
                // Sync the buffer's current text so the server's positions line up.
                let text = self.panes.iter().find_map(|p| match p {
                    Pane::Editor(b) if b.is_at(&path) => Some(b.editor.text().to_string()),
                    _ => None,
                });
                if let Some(t) = text {
                    self.lsp.did_change(&path, &t);
                }
                if !self.lsp.rename(&path, line, ch, &new_name) {
                    self.toast("no language server for this file (rename)");
                }
            }
            crate::prompt::PromptKind::BrowserUrl => self.open_browser(p.input.trim()),
            crate::prompt::PromptKind::BrowserNavigate => {
                let url = p.input.clone();
                if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    b.navigate(&url);
                }
            }
            crate::prompt::PromptKind::BrowserEval => {
                let expr = p.input.clone();
                if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                    b.eval(&expr);
                }
            }
            crate::prompt::PromptKind::Find => {
                let q = p.input.clone();
                // Live-preview is the new find state already; commit it.
                self.find_preview_snapshot = None;
                self.accept_find(q);
            }
            crate::prompt::PromptKind::Replace => {
                let r = p.input.clone();
                self.accept_replace(r);
            }
            crate::prompt::PromptKind::Grep => {
                let q = p.input.clone();
                self.run_workspace_grep(q);
            }
            crate::prompt::PromptKind::GrepReplace => {
                let r = p.input.clone();
                self.run_grep_replace(r);
            }
            crate::prompt::PromptKind::GotoLine => {
                let s = p.input.trim().to_string();
                self.goto_line_str(&s);
            }
            crate::prompt::PromptKind::NewFile => {
                let name = p.input.clone();
                if let Some(FsAction::NewFile { parent }) = self.pending_fs_action.take() {
                    self.create_new_file(&parent, &name);
                }
            }
            crate::prompt::PromptKind::NewFolder => {
                let name = p.input.clone();
                if let Some(FsAction::NewFolder { parent }) = self.pending_fs_action.take() {
                    self.create_new_folder(&parent, &name);
                }
            }
            crate::prompt::PromptKind::Rename => {
                let name = p.input.clone();
                if let Some(FsAction::Rename { path }) = self.pending_fs_action.take() {
                    self.rename_fs_entry(&path, &name);
                }
            }
            crate::prompt::PromptKind::DeleteConfirm => {
                let typed = p.input.clone();
                if let Some(FsAction::Delete { path }) = self.pending_fs_action.take() {
                    self.confirm_delete_fs_entry(&path, &typed);
                }
            }
            crate::prompt::PromptKind::GitDeleteBranch => {
                self.confirm_delete_branch(p.input.clone());
            }
            crate::prompt::PromptKind::GitWorktreeRemove => {
                self.confirm_worktree_remove(p.input.clone());
            }
            crate::prompt::PromptKind::LspWorkspaceSymbol => {
                let q = p.input.clone();
                self.run_workspace_symbol_query(&q);
            }
        }
    }

    // ─── find in buffer ─────────────────────────────────────────────
    /// `find.find` (`Ctrl+F`) — prompt for a search string. Seeded with the
    /// active editor's selection if any, else its current find query.
    pub fn open_find_prompt(&mut self) {
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get(cur) else {
            self.toast("find only works in editor panes");
            return;
        };
        let seed = if b.editor.has_selection() {
            b.editor.selected_text().to_string()
        } else if let Some(f) = &b.find {
            f.query.clone()
        } else {
            String::new()
        };
        // A multi-line selection isn't a useful default — keep the first line.
        let seed = seed.lines().next().unwrap_or("").to_string();
        // Remember the editor's current find state so Esc on the prompt
        // restores it (we replace it live as the user types).
        self.find_preview_snapshot = Some(b.find.clone());
        self.find_preview_cursor = b.editor.cursor();
        // History cursor parks past the newest entry — Up walks back, Down
        // walks forward toward the live input.
        self.find_history_cursor = self.find_history.len();
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::Find,
            "Find",
            seed,
        ));
    }

    /// Replace the Find prompt's input with the previous history entry
    /// (Up arrow on the prompt). No-op when there's no older entry.
    pub fn find_history_prev(&mut self) {
        if self.find_history_cursor == 0 || self.find_history.is_empty() {
            return;
        }
        self.find_history_cursor -= 1;
        let q = self.find_history[self.find_history_cursor].clone();
        if let Some(p) = self.prompt.as_mut() {
            p.input = q.clone();
            p.cursor = p.input.len();
        }
        self.update_live_find_preview(q);
    }

    /// Down arrow on the Find prompt — newer entry, or back to an empty
    /// live input when past the newest.
    pub fn find_history_next(&mut self) {
        if self.find_history_cursor >= self.find_history.len() {
            return;
        }
        self.find_history_cursor += 1;
        let q = if self.find_history_cursor >= self.find_history.len() {
            String::new()
        } else {
            self.find_history[self.find_history_cursor].clone()
        };
        if let Some(p) = self.prompt.as_mut() {
            p.input = q.clone();
            p.cursor = p.input.len();
        }
        self.update_live_find_preview(q);
    }

    /// Update the active editor's find state to reflect the in-flight find
    /// prompt's query so the user sees matches as they type. Cursor isn't
    /// moved — just the highlight set + match index. Empty query clears.
    pub fn update_live_find_preview(&mut self, query: String) {
        let regex_default = self.find_regex_default;
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(cur) else {
            return;
        };
        if query.is_empty() {
            b.find = None;
            return;
        }
        let regex = b.find.as_ref().map(|f| f.regex).unwrap_or(regex_default);
        // Smart-case: any uppercase letter in the query ⇒ case-sensitive.
        // Only meaningful for literal mode (regex carries its own `(?i)`).
        let case_sensitive = !regex && query.chars().any(|c| c.is_uppercase());
        let mut state = crate::buffer::FindState {
            query,
            regex,
            case_sensitive,
            ..Default::default()
        };
        state.recompute(b.editor.text());
        // Pick the nearest match at or after the cursor (or 0 if none — UI
        // will just show no current).
        if !state.matches.is_empty() {
            let cur_byte = b.editor.cursor();
            let idx = state
                .matches
                .iter()
                .position(|(s, _)| *s >= cur_byte)
                .unwrap_or(0);
            state.current = Some(idx);
        }
        b.find = Some(state);
    }

    /// Discard the live preview and restore the prior find state (from
    /// [`Self::open_find_prompt`]'s snapshot). Called on Esc-cancel of the
    /// Find prompt; Enter-accept leaves the live state in place + the
    /// snapshot is dropped.
    pub fn restore_find_preview_snapshot(&mut self) {
        let snap = self.find_preview_snapshot.take();
        self.find_preview_cursor = 0;
        let Some(prior) = snap else { return };
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(cur) else {
            return;
        };
        b.find = prior;
    }

    /// Set the active editor's find state to `query` and jump to the nearest
    /// match at-or-after the cursor (wraps).
    pub fn accept_find(&mut self, query: String) {
        // Remember the query in history (de-duped against the most recent
        // entry, capped at FIND_HISTORY_MAX). Done first so even queries
        // that miss are recallable via Up.
        if !query.is_empty() && self.find_history.last() != Some(&query) {
            self.find_history.push(query.clone());
            if self.find_history.len() > FIND_HISTORY_MAX {
                let drop = self.find_history.len() - FIND_HISTORY_MAX;
                self.find_history.drain(..drop);
            }
        }
        self.find_history_cursor = self.find_history.len();
        let regex_default = self.find_regex_default;
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(cur) else {
            return;
        };
        if query.is_empty() {
            b.find = None;
            return;
        }
        // Preserve the existing find's regex flag if any, else use the App
        // default so the toggle is sticky.
        let regex = b.find.as_ref().map(|f| f.regex).unwrap_or(regex_default);
        let case_sensitive = !regex && query.chars().any(|c| c.is_uppercase());
        let mut state = crate::buffer::FindState {
            query: query.clone(),
            regex,
            case_sensitive,
            ..Default::default()
        };
        state.recompute(b.editor.text());
        if state.matches.is_empty() {
            b.find = Some(state);
            self.toast(format!(
                "no {}matches for {query:?}",
                if regex { "regex " } else { "" }
            ));
            return;
        }
        // Jump to the first match at-or-after the cursor (wrap).
        let cur_byte = b.editor.cursor();
        let idx = state
            .matches
            .iter()
            .position(|(s, _)| *s >= cur_byte)
            .unwrap_or(0);
        state.current = Some(idx);
        let (start, _end) = state.matches[idx];
        let total = state.matches.len();
        b.find = Some(state);
        self.place_cursor_at_byte(cur, start);
        self.toast(format!("match {}/{total}", idx + 1));
    }

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

    /// `find.next` (`F3`) — advance to the next find match (wraps).
    pub fn find_next(&mut self) {
        self.step_find(1);
    }
    /// `find.prev` (`Shift+F3`) — step to the previous find match (wraps).
    pub fn find_prev(&mut self) {
        self.step_find(-1);
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

    /// `find.replace` (`Ctrl+H`) — prompt for replacement text (requires a
    /// non-empty find state on the active buffer). Enter ⇒ `accept_replace`
    /// splices the replacement over every match.
    pub fn open_replace_prompt(&mut self) {
        let Some(cur) = self.active else { return };
        let q = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.find.as_ref().map(|f| (f.query.clone(), f.matches.len())),
            _ => None,
        };
        match q {
            Some((query, n)) if n > 0 => {
                let title = format!("Replace {n}× {query:?} with");
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::Replace,
                    title,
                ));
            }
            Some(_) => self.toast("no matches to replace — refine the find query"),
            None => self.toast("find first (Ctrl+F)"),
        }
    }

    /// Splice `replacement` over every find match in the active buffer (in
    /// reverse order, so earlier offsets stay valid). Toasts the count.
    pub fn accept_replace(&mut self, replacement: String) {
        let Some(cur) = self.active else { return };
        let ops: Vec<crate::edit_op::EditOp> = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => match &b.find {
                Some(f) if !f.matches.is_empty() => f
                    .matches
                    .iter()
                    .rev()
                    .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                        start: *s,
                        end: *e,
                        text: replacement.clone(),
                    })
                    .collect(),
                _ => {
                    self.toast("no matches to replace");
                    return;
                }
            },
            _ => return,
        };
        let n = ops.len();
        let clip = &mut self.clipboard;
        let path = if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
            b.apply_edit_ops(ops, clip, 0);
            b.path.clone()
        } else {
            None
        };
        if let Some(p) = path {
            // Same as a normal edit — push the change to the LSP server.
            if let Some(Pane::Editor(b)) = self.panes.get(cur) {
                let t = b.editor.text().to_string();
                self.lsp.did_change(&p, &t);
            }
        }
        self.toast(format!("replaced {n}"));
    }

    /// `find.grep` (palette) — prompt for a query and grep the workspace.
    pub fn open_grep_prompt(&mut self) {
        let seed = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) if b.editor.has_selection() => b
                .editor
                .selected_text()
                .lines()
                .next()
                .unwrap_or("")
                .to_string(),
            _ => String::new(),
        };
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::Grep,
            "Grep workspace",
            seed,
        ));
    }

    /// Run `rg --vimgrep <q> .` in the workspace (falling back to `git grep`),
    /// parse `path:line:col:text` lines, and open the results in a `Pane::Grep`
    /// (split below the focused leaf). If a grep pane is already open for an
    /// earlier query, *that* pane is refilled in place — only one grep pane at
    /// a time.
    pub fn run_workspace_grep(&mut self, q: String) {
        let q = q.trim().to_string();
        if q.is_empty() {
            return;
        }
        let (hits, used) = grep_workspace(&self.workspace, &q);
        if hits.is_empty() {
            self.toast(format!("{used}: no matches for {q:?}"));
            return;
        }
        // Already showing a grep pane somewhere? Refresh it in place.
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Grep(_))) {
            if let Some(Pane::Grep(g)) = self.panes.get_mut(id) {
                *g = crate::grep_pane::GrepPane::new(q, used, hits);
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(q, used, hits));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-run the grep that produced the active `Pane::Grep` (the `r` key).
    pub fn rerun_active_grep(&mut self) {
        let q = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => g.query.clone(),
            _ => return,
        };
        let (hits, used) = grep_workspace(&self.workspace, &q);
        if let Some(Pane::Grep(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            *g = crate::grep_pane::GrepPane::new(q, used, hits);
        }
    }

    pub fn move_grep_selection(&mut self, delta: isize) {
        if let Some(Pane::Grep(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.move_selection(delta);
        }
    }

    /// `y` in a grep pane — copy the selected hit's `path:line` (1-based) to
    /// the system clipboard so the user can paste it into a commit message,
    /// chat, etc.
    pub fn copy_selected_grep_hit(&mut self) {
        let s = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => g
                .selected_hit()
                .map(|h| format!("{}:{}", h.rel, h.line + 1)),
            _ => None,
        };
        let Some(s) = s else { return };
        self.clipboard.set(s.clone(), false);
        self.toast(format!("copied {s}"));
    }

    /// Open the highlighted grep hit's file and place the cursor there.
    pub fn jump_to_selected_grep_hit(&mut self) {
        let target = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => g
                .selected_hit()
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

    /// `find.grep_replace` (the `R` key in a `Pane::Grep`) — prompt for a
    /// replacement string. The grep pane's query is the seed, but the input
    /// starts empty so the user can type the replacement without first deleting
    /// the seed. Requires an active grep pane with at least one hit.
    pub fn open_grep_replace_prompt(&mut self) {
        let (query, n) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) if !g.hits.is_empty() => (g.query.clone(), g.hits.len()),
            Some(Pane::Grep(_)) => {
                self.toast("no grep hits to replace");
                return;
            }
            _ => return,
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GrepReplace,
            format!("Replace {n}× \"{query}\" with"),
        ));
    }

    /// Replace every hit in the active `Pane::Grep` across every file it
    /// matched. For each unique file:
    /// - **Open + clean** ⇒ apply `EditOp::ReplaceRange`s through the buffer
    ///   (so undo works + LSP `didChange` fires).
    /// - **Not open** ⇒ read the file from disk, splice in reverse, write back.
    /// - **Open + dirty** ⇒ skip + toast (refuse to clobber unsaved edits).
    ///
    /// The match positions are re-derived from each file's live text via
    /// `crate::buffer::find_all_ci_ascii` (rather than trusting the grep tool's
    /// line/col, which might be stale by now). After replacing, the grep query
    /// is re-run so the pane reflects the new state.
    pub fn run_grep_replace(&mut self, replacement: String) {
        // Snapshot the (query, unique-file-paths) from the active grep pane.
        let (query, files) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => {
                let mut files: Vec<PathBuf> = Vec::new();
                for h in &g.hits {
                    if !files.iter().any(|p| p == &h.path) {
                        files.push(h.path.clone());
                    }
                }
                (g.query.clone(), files)
            }
            _ => return,
        };
        if query.is_empty() {
            return;
        }
        let mut total_replacements = 0usize;
        let mut files_changed = 0usize;
        let mut files_skipped: Vec<String> = Vec::new();
        let mut io_errors: Vec<String> = Vec::new();
        for path in &files {
            // Is this file open as an editor pane? (Take the first such pane.)
            let open_idx = self.panes.iter().position(
                |p| matches!(p, Pane::Editor(b) if b.path.as_deref() == Some(path.as_path())),
            );
            if let Some(idx) = open_idx {
                let is_dirty = matches!(self.panes.get(idx), Some(Pane::Editor(b)) if b.dirty);
                if is_dirty {
                    files_skipped.push(rel_path(&self.workspace, path));
                    continue;
                }
                let text = match self.panes.get(idx) {
                    Some(Pane::Editor(b)) => b.editor.text().to_string(),
                    _ => continue,
                };
                let matches = crate::buffer::find_all_ci_ascii(&text, &query);
                if matches.is_empty() {
                    continue;
                }
                let ops: Vec<crate::edit_op::EditOp> = matches
                    .iter()
                    .rev()
                    .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                        start: *s,
                        end: *e,
                        text: replacement.clone(),
                    })
                    .collect();
                let n = ops.len();
                let clip = &mut self.clipboard;
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.apply_edit_ops(ops, clip, 0);
                    // Persist the change to disk so the grep re-run reflects
                    // it (and so the user doesn't have to save N files by hand).
                    match b.save_to_disk() {
                        Ok(()) => {}
                        Err(e) => {
                            io_errors.push(format!("{}: {e}", rel_path(&self.workspace, path)));
                            continue;
                        }
                    }
                }
                // Push the new text through LSP just like a normal save.
                if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                    let t = b.editor.text().to_string();
                    self.lsp.did_change(path, &t);
                }
                total_replacements += n;
                files_changed += 1;
            } else {
                // Not open — splice on disk.
                let text = match std::fs::read_to_string(path) {
                    Ok(s) => s,
                    Err(e) => {
                        io_errors.push(format!("{}: {e}", rel_path(&self.workspace, path)));
                        continue;
                    }
                };
                let matches = crate::buffer::find_all_ci_ascii(&text, &query);
                if matches.is_empty() {
                    continue;
                }
                let mut out = String::with_capacity(text.len());
                let mut cursor = 0usize;
                for (s, e) in &matches {
                    out.push_str(&text[cursor..*s]);
                    out.push_str(&replacement);
                    cursor = *e;
                }
                out.push_str(&text[cursor..]);
                if let Err(e) = std::fs::write(path, &out) {
                    io_errors.push(format!("{}: {e}", rel_path(&self.workspace, path)));
                    continue;
                }
                total_replacements += matches.len();
                files_changed += 1;
            }
        }
        // Toast a summary.
        let mut parts = vec![format!(
            "replaced {total_replacements} in {files_changed} files"
        )];
        if !files_skipped.is_empty() {
            parts.push(format!(
                "skipped {} (unsaved): {}",
                files_skipped.len(),
                files_skipped.join(", ")
            ));
        }
        if !io_errors.is_empty() {
            parts.push(format!("{} errored", io_errors.len()));
        }
        self.toast(parts.join(" · "));
        // Refresh the grep pane against the new state.
        self.rerun_active_grep();
    }

    /// `editor.open_at_cursor` (`Ctrl+Shift+O` / vim `gf`) — pull the
    /// "path-like" token under the cursor (e.g. `src/foo.rs:42:7`), resolve
    /// relative to the workspace, open + jump. Toasts when nothing path-like
    /// is under the cursor or the path doesn't exist.
    pub fn open_path_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        let cursor = b.editor.cursor();
        let Some((s, e)) = path_token_around(text, cursor) else {
            self.toast("no path under cursor");
            return;
        };
        let token = &text[s..e];
        // Strip trailing punctuation that often clings to a copied path
        // (commas, periods, parens, quotes).
        let token = token.trim_end_matches([',', '.', ')', ']', '\'', '"', ';', ':']);
        let (path_str, line_col): (&str, Option<(usize, usize)>) =
            match parse_path_with_position(token) {
                Some((p, l, c)) => (p, Some((l, c))),
                None => (token, None),
            };
        let path = std::path::Path::new(path_str);
        let abs = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.workspace.join(path)
        };
        if !abs.exists() {
            self.toast(format!("no such path: {path_str}"));
            return;
        }
        if abs.is_dir() {
            // We can't open a dir as a buffer; just toast it as a hint.
            self.toast(format!("(directory) {}", rel_path(&self.workspace, &abs)));
            return;
        }
        self.open_path(&abs);
        if let Some((line, col)) = line_col
            && let Some(b) = self.active_editor_mut()
        {
            b.editor
                .place_cursor(line.saturating_sub(1), col.saturating_sub(1));
        }
    }

    /// `editor.toggle_fold` (`za`) — fold/unfold at the cursor. Picks the
    /// smallest enclosing bracket-pair (curly preferred over square over
    /// round) and toggles a fold for the line range it covers. Toasts when
    /// the cursor isn't inside any bracket pair.
    pub fn toggle_fold_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        // If the cursor sits on (or in the body of) an existing fold,
        // unfold it instead of folding tighter.
        let cur_row = b.editor.row_col().0;
        if let Some(&owner) = b.folds.keys().find(|&&s| {
            let end = b.folds.get(&s).copied().unwrap_or(s);
            cur_row >= s && cur_row <= end
        }) {
            if let Some(b) = self.active_editor_mut() {
                b.folds.remove(&owner);
                self.toast(format!("unfolded line {}", owner + 1));
            }
            return;
        }
        // Find the smallest enclosing pair across the three bracket kinds.
        let pairs = [('{', '}'), ('[', ']'), ('(', ')')];
        let mut best: Option<(usize, usize)> = None;
        for &(open, close) in &pairs {
            if let Some((o, c)) = b.editor.enclosing_bracket_pair(open, close) {
                let lo_line = b.editor.line_at_byte(o);
                let hi_line = b.editor.line_at_byte(c);
                if hi_line > lo_line {
                    let span = hi_line - lo_line;
                    if best.is_none_or(|(s, e)| (e - s) > span) {
                        best = Some((lo_line, hi_line));
                    }
                }
            }
        }
        let Some((start, end)) = best else {
            self.toast("nothing to fold here");
            return;
        };
        if let Some(b) = self.active_editor_mut() {
            b.folds.insert(start, end);
            self.toast(format!("folded {} lines", end - start));
        }
    }

    /// `editor.unfold_all` — drop every fold from the active buffer.
    pub fn unfold_all_in_active(&mut self) {
        if let Some(b) = self.active_editor_mut() {
            let n = b.folds.len();
            b.folds.clear();
            if n > 0 {
                self.toast(format!("unfolded {n} fold(s)"));
            }
        }
    }

    /// `editor.bracket_match` (`Ctrl+]`) — when the cursor sits on a bracket
    /// (`()` / `[]` / `{}`), jump to its match. Toasts when there's none.
    pub fn bracket_match_jump(&mut self) {
        let target = self.active_editor().and_then(|b| b.editor.bracket_match());
        let Some((row, col)) = target else {
            self.toast("not on a bracket");
            return;
        };
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(row, col);
        }
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
        let Ok(n) = s.parse::<usize>() else {
            if !s.is_empty() {
                self.toast(format!("not a number: {s:?}"));
            }
            return;
        };
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(n.saturating_sub(1), 0);
        }
    }

    /// `find.clear` (Esc when find is the only active overlay) — drop the matches.
    pub fn clear_find(&mut self) {
        if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.find = None;
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

    // ─── git graph (graphical-Git-GUI-style commit DAG) ─────────────────────
    /// Open the commit-DAG browser as a split to the right of the focused leaf.
    pub fn open_git_graph(&mut self) {
        let pane = Pane::GitGraph(crate::git::graph::GitGraphPane::open(&self.workspace));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }
    /// Re-run `git log` for the active git-graph pane (after a commit / fetch).
    pub fn refresh_active_git_graph(&mut self) {
        if let Some(Pane::GitGraph(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.refresh();
        }
    }
    fn refresh_git_graph_panes(&mut self) {
        for pane in &mut self.panes {
            if let Pane::GitGraph(g) = pane {
                g.refresh();
            }
        }
    }
    /// Open the selected commit's diff (`git show <hash>`) as a `Pane::Diff` in a
    /// split to the right of the graph pane.
    pub fn open_selected_commit_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let hash = match self.panes.get(cur) {
            Some(Pane::GitGraph(g)) => g.selected_commit().map(|c| c.hash.clone()),
            _ => None,
        };
        let Some(hash) = hash else { return };
        let scope = crate::pane::DiffScope::Commit(hash.clone());
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast(format!(
                "commit {} has no file changes (merge?)",
                hash.chars().take(9).collect::<String>()
            ));
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(crate::pane::DiffView::new(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }
    /// Copy the selected commit's full hash to the clipboard.
    pub fn copy_selected_commit_hash(&mut self) {
        let Some(cur) = self.active else { return };
        let hash = match self.panes.get(cur) {
            Some(Pane::GitGraph(g)) => g.selected_commit().map(|c| c.hash.clone()),
            _ => None,
        };
        let Some(hash) = hash else { return };
        self.clipboard.set(hash.clone(), false);
        self.toast(format!(
            "copied {}",
            hash.chars().take(12).collect::<String>()
        ));
    }

    // ─── git status / staging view ──────────────────────────────────
    /// Open the staging view as a split to the right of the focused leaf.
    pub fn open_git_status(&mut self) {
        let pane = Pane::GitStatus(crate::git::stage::GitStatusPane::open(&self.workspace));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }
    fn refresh_git_status_panes(&mut self) {
        for pane in &mut self.panes {
            if let Pane::GitStatus(g) = pane {
                g.refresh();
            }
        }
    }
    /// After any staging/commit change: refresh the cached status + all git
    /// panes + the rail's `GIT` section (the current branch may have moved /
    /// a branch may have been created).
    fn after_git_change(&mut self) {
        self.git.refresh();
        self.git_rail.refresh(&self.workspace);
        self.refresh_git_status_panes();
        self.refresh_git_graph_panes();
    }
    /// `(rel, is_staged)` for the highlighted file in the active git-status pane.
    fn git_status_selection(&self) -> Option<(String, bool)> {
        match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::GitStatus(g)) => g.selected_entry().map(|(e, st)| (e.rel.clone(), st)),
            _ => None,
        }
    }
    pub fn git_stage_selected(&mut self) {
        let Some((rel, staged)) = self.git_status_selection() else {
            return;
        };
        if staged {
            self.toast("already staged — `u` to unstage");
            return;
        }
        match crate::git::stage::stage(&self.workspace, &rel) {
            Ok(()) => {
                self.toast(format!("staged {rel}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add: {e}")),
        }
    }
    pub fn git_unstage_selected(&mut self) {
        let Some((rel, staged)) = self.git_status_selection() else {
            return;
        };
        if !staged {
            self.toast("not staged — `s` to stage");
            return;
        }
        match crate::git::stage::unstage(&self.workspace, &rel) {
            Ok(()) => {
                self.toast(format!("unstaged {rel}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore --staged: {e}")),
        }
    }
    /// Space in the status pane — stage if unstaged, unstage if staged.
    pub fn git_toggle_selected(&mut self) {
        match self.git_status_selection() {
            Some((_, false)) => self.git_stage_selected(),
            Some((_, true)) => self.git_unstage_selected(),
            None => {}
        }
    }
    pub fn git_stage_all_active(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitStatus(_))) {
            return;
        }
        match crate::git::stage::stage_all(&self.workspace) {
            Ok(()) => {
                self.toast("staged all changes");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add -A: {e}")),
        }
    }
    pub fn git_unstage_all_active(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitStatus(_))) {
            return;
        }
        match crate::git::stage::unstage_all(&self.workspace) {
            Ok(()) => {
                self.toast("unstaged everything");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore --staged: {e}")),
        }
    }
    /// Enter in the status pane — open the highlighted file's diff in a split.
    pub fn git_status_open_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let sel = match self.panes.get(cur) {
            Some(Pane::GitStatus(g)) => g.selected_entry().map(|(e, st)| (e.abs.clone(), st)),
            _ => None,
        };
        let Some((abs, staged)) = sel else { return };
        let scope = if staged {
            crate::pane::DiffScope::Staged
        } else {
            crate::pane::DiffScope::Unstaged(Some(abs))
        };
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no diff for that file (untracked? — stage it to see it)");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(crate::pane::DiffView::new(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }
    /// `C` in the status pane — ask `claude -p` to write a commit message from the
    /// staged diff; when it lands, the commit prompt opens pre-seeded with the
    /// first line (`drain_ai_jobs` routes it via `pending_commit_msg_job`).
    pub fn request_ai_commit_message(&mut self) {
        if self.git.snapshot().staged == 0 {
            self.toast("nothing staged — stage some changes first");
            return;
        }
        let diff = crate::git::stage::staged_diff(&self.workspace);
        if diff.trim().is_empty() {
            self.toast("no staged diff to summarise");
            return;
        }
        // Keep the prompt from getting silly-long on huge diffs.
        let diff = if diff.len() > 24_000 {
            format!("{}\n…(diff truncated)…", &diff[..24_000])
        } else {
            diff
        };
        let prompt = format!(
            "Write a git commit message for the staged changes below. \
             First line: imperative mood, ≤72 chars, no trailing period. \
             Then a blank line and a short body ONLY if it adds something. \
             Output ONLY the commit message — no preamble, no code fences.\n\n\
             ```diff\n{diff}\n```"
        );
        let (job_id, _sid, _cancel) = self.spawn_ai_job(prompt);
        self.pending_commit_msg_job = Some(job_id);
        if let Some(Pane::GitStatus(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.ai_msg_job = Some(job_id);
        }
        self.toast("asking Claude for a commit message…");
    }

    /// `git.ai_recompose` — ask Claude to rewrite HEAD's commit message based
    /// on its diff. The reply lands as a `PromptKind::GitCommitAmend` prompt;
    /// accept ⇒ `git commit --amend -m <new>`. Limited to HEAD for now —
    /// rewriting older commits would require interactive rebase machinery.
    pub fn request_ai_recompose_message(&mut self) {
        let diff = match crate::git::commit::show_head(&self.workspace) {
            Ok(d) if d.trim().is_empty() => {
                self.toast("HEAD has no patch to summarise");
                return;
            }
            Ok(d) => d,
            Err(e) => {
                self.toast(format!("AI recompose: {e}"));
                return;
            }
        };
        let diff = if diff.len() > 24_000 {
            format!("{}\n…(diff truncated)…", &diff[..24_000])
        } else {
            diff
        };
        let existing = crate::git::commit::head_message(&self.workspace);
        let existing_block = if existing.is_empty() {
            String::new()
        } else {
            format!("Current message:\n```\n{existing}\n```\n\n")
        };
        let prompt = format!(
            "Rewrite this commit's message based on what actually changed. \
             First line: imperative mood, ≤72 chars, no trailing period. \
             Then a blank line and a short body ONLY if it adds something the \
             subject doesn't. Output ONLY the new message — no preamble, no \
             code fences.\n\n\
             {existing_block}\
             ```diff\n{diff}\n```"
        );
        let (job_id, _sid, _cancel) = self.spawn_ai_job(prompt);
        self.pending_amend_msg_job = Some(job_id);
        self.toast("asking Claude to rewrite HEAD's message…");
    }

    // ─── branches / worktrees ───────────────────────────────────────
    /// Open a fuzzy picker over local + remote branches; accept ⇒ checkout.
    pub fn open_branch_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::git::branch::current(&self.workspace);
        let mut items: Vec<PickerItem> = Vec::new();
        // Surface the current branch first + marked with a `●` glyph; rest in
        // for-each-ref order. The picker's fuzzy match still narrows from any
        // position, so the ordering is just a visual default.
        let locals = crate::git::branch::local_branches(&self.workspace);
        if let Some(c) = cur.as_ref()
            && locals.iter().any(|b| b == c)
        {
            items.push(PickerItem::new(
                format!("local:{c}"),
                format!("● {c}"),
                "current",
            ));
        }
        for b in locals {
            if Some(&b) == cur.as_ref() {
                continue;
            }
            items.push(PickerItem::new(
                format!("local:{b}"),
                format!("  {b}"),
                "local",
            ));
        }
        for b in crate::git::branch::remote_branches(&self.workspace) {
            items.push(PickerItem::new(
                format!("remote:{b}"),
                format!("  {b}"),
                "remote",
            ));
        }
        if items.is_empty() {
            self.toast("no branches (not a git repo?)");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Branches, "Checkout branch", items));
    }
    /// Checkout the branch a `PickerKind::Branches` item id encodes.
    pub fn checkout_branch(&mut self, id: &str) {
        let result = if let Some(name) = id.strip_prefix("local:") {
            crate::git::branch::checkout(&self.workspace, name).map(|_| name.to_string())
        } else if let Some(remote) = id.strip_prefix("remote:") {
            crate::git::branch::checkout_track(&self.workspace, remote).map(|_| remote.to_string())
        } else {
            crate::git::branch::checkout(&self.workspace, id).map(|_| id.to_string())
        };
        match result {
            Ok(name) => self.after_checkout(&name),
            Err(e) => self.toast(format!("git checkout: {e}")),
        }
    }
    /// Open the "new branch name" prompt; accept ⇒ `git checkout -b <name>`.
    pub fn open_new_branch_prompt(&mut self) {
        // Bare `git.new_branch` — no source, off HEAD.
        self.pending_branch_source = None;
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewBranch,
            "New branch name (off current HEAD)",
        ));
    }
    pub fn create_branch(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            self.toast("branch creation cancelled (empty name)");
            self.pending_branch_source = None;
            return;
        }
        let source = self.pending_branch_source.take();
        let result = match &source {
            Some(s) => crate::git::branch::create_from(&self.workspace, name, s),
            None => crate::git::branch::create(&self.workspace, name),
        };
        match result {
            Ok(()) => {
                if let Some(s) = source {
                    self.toast(format!("created {name} off {s}"));
                }
                self.after_checkout(name);
            }
            Err(e) => self.toast(format!("git checkout -b: {e}")),
        }
    }
    /// Open a picker over `git worktree list`; accept ⇒ a shell pane in that dir.
    pub fn open_worktree_picker(&mut self) {
        use crate::picker::PickerItem;
        let wts = crate::git::branch::worktrees(&self.workspace);
        if wts.is_empty() {
            self.toast("no worktrees (not a git repo?)");
            return;
        }
        let items: Vec<PickerItem> = wts
            .into_iter()
            .map(|w| {
                let detail = if w.is_current {
                    format!("{} · current", w.label)
                } else {
                    w.label.clone()
                };
                PickerItem::new(
                    w.path.display().to_string(),
                    w.path.display().to_string(),
                    detail,
                )
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::Worktrees,
            "Worktree → shell",
            items,
        ));
    }
    /// Open a shell pane in `path` (a worktree directory).
    pub fn open_worktree_shell(&mut self, path: &str) {
        self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(PathBuf::from(
            path,
        ))));
    }
    /// Common tail of a checkout / new-branch: refresh git + tree, warn that open
    /// editors may now be stale (their file on disk could differ).
    fn after_checkout(&mut self, label: &str) {
        self.after_git_change();
        self.tree.refresh();
        let dirty_open = self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.dirty));
        if dirty_open {
            self.toast(format!(
                "switched to {label} — heads up: you have unsaved edits open"
            ));
        } else {
            self.toast(format!(
                "switched to {label} — reopen files if their content changed"
            ));
        }
    }

    /// Move focus to the leaf in direction `d` of the focused one (by the rects
    /// recorded at last render). No wrap.
    pub fn focus_dir(&mut self, d: FocusDir) {
        let Some(cur) = self.active else { return };
        let Some(&(cur_rect, _)) = self.rects.editor_panes.iter().find(|(_, p)| *p == cur) else {
            return;
        };
        let (cx, cy) = (
            cur_rect.x as i32 + cur_rect.width as i32 / 2,
            cur_rect.y as i32 + cur_rect.height as i32 / 2,
        );
        let mut best: Option<(i64, PaneId)> = None;
        for &(r, pid) in &self.rects.editor_panes {
            if pid == cur {
                continue;
            }
            let (mx, my) = (
                r.x as i32 + r.width as i32 / 2,
                r.y as i32 + r.height as i32 / 2,
            );
            let on_side = match d {
                FocusDir::Left => mx < cx,
                FocusDir::Right => mx > cx,
                FocusDir::Up => my < cy,
                FocusDir::Down => my > cy,
            };
            if !on_side {
                continue;
            }
            // Require some overlap on the perpendicular axis (so a left-and-up
            // neighbour doesn't steal a "go left").
            let overlap = match d {
                FocusDir::Left | FocusDir::Right => {
                    r.y < cur_rect.y + cur_rect.height && cur_rect.y < r.y + r.height
                }
                FocusDir::Up | FocusDir::Down => {
                    r.x < cur_rect.x + cur_rect.width && cur_rect.x < r.x + r.width
                }
            };
            if !overlap {
                continue;
            }
            let dist = ((mx - cx) as i64).pow(2) + ((my - cy) as i64).pow(2);
            if best.is_none_or(|(bd, _)| dist < bd) {
                best = Some((dist, pid));
            }
        }
        if let Some((_, pid)) = best {
            self.active = Some(pid);
            self.focus = Focus::Pane;
        }
    }

    /// Cycle focus to the next leaf (left-to-right / top-to-bottom order).
    pub fn focus_next_split(&mut self) {
        let leaves = self.layout.leaves();
        if leaves.len() < 2 {
            return;
        }
        let here = self
            .active
            .and_then(|a| leaves.iter().position(|&l| l == a))
            .unwrap_or(0);
        self.active = Some(leaves[(here + 1) % leaves.len()]);
        self.focus = Focus::Pane;
    }

    /// If `(x, y)` is on a split divider, begin dragging it. Returns true if so.
    pub fn begin_divider_drag(&mut self, x: u16, y: u16) -> bool {
        if let Some(d) = self
            .rects
            .split_dividers
            .iter()
            .find(|d| {
                x >= d.rect.x
                    && x < d.rect.x + d.rect.width
                    && y >= d.rect.y
                    && y < d.rect.y + d.rect.height
            })
            .cloned()
        {
            self.dragging = Some(d);
            true
        } else {
            false
        }
    }
    /// Continue a divider drag: set the split's ratio from the pointer position.
    pub fn drag_divider_to(&mut self, x: u16, y: u16) {
        if let Some(d) = &self.dragging {
            let ratio = d.ratio_for(x, y);
            let path = d.path.clone();
            self.layout.set_ratio_at(&path, ratio);
        }
    }
    pub fn end_divider_drag(&mut self) {
        self.dragging = None;
    }

    /// If `(x, y)` is on the rail's right-edge handle, start a tree-width drag.
    /// Returns true if so. (The drag continues with [`Self::drag_tree_edge_to`]
    /// + ends with [`Self::end_tree_edge_drag`].)
    pub fn begin_tree_edge_drag(&mut self, x: u16, y: u16) -> bool {
        if let Some(r) = self.rects.tree_edge
            && x >= r.x
            && x < r.x + r.width
            && y >= r.y
            && y < r.y + r.height
        {
            self.dragging_tree_edge = true;
            return true;
        }
        false
    }
    /// Continue a tree-width drag: set the rail's width to the column under
    /// the pointer, clamped to `[8, screen_width - 20]`.
    pub fn drag_tree_edge_to(&mut self, x: u16, screen_width: u16) {
        if !self.dragging_tree_edge {
            return;
        }
        let max = screen_width.saturating_sub(20).max(8);
        let new = x.clamp(8, max);
        self.tree_width = new;
    }
    pub fn end_tree_edge_drag(&mut self) {
        self.dragging_tree_edge = false;
    }

    /// Close the buffer at `id`. If it's a dirty editor, this opens the
    /// Save/Discard/Cancel confirm overlay instead and returns; otherwise it
    /// closes immediately. Use [`Self::force_close_pane`] to skip the prompt.
    pub fn close_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        let dirty = matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.dirty);
        if dirty {
            self.close_prompt = Some(id);
            return;
        }
        self.force_close_pane(id);
    }

    /// Close the buffer at `id` unconditionally, discarding unsaved changes (with
    /// a toast). If it's shown in a leaf, that leaf is removed (its parent split
    /// collapses into the sibling); if the closed leaf was focused, focus moves
    /// to the next leaf — or, if none remain but a background buffer does, that
    /// buffer is shown.
    pub fn force_close_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        // Capture the cursor + scroll so a future `open_path` for this file
        // jumps back to where the user was. Done *before* the pane is removed
        // (and only for editor panes — other variants don't have a "position").
        if let Pane::Editor(b) = &self.panes[id]
            && let Some(p) = b.path.clone()
        {
            let cur = b.editor.cursor();
            let scroll = b.scroll;
            self.note_file_cursor(&p, cur, scroll);
            // Push onto the recently-closed stack so `buffer.reopen` can
            // bring it back. Skip if the file's still open in another pane
            // (closing one of several views of the same file isn't "closed").
            let still_open = self
                .panes
                .iter()
                .enumerate()
                .any(|(i, pane)| i != id && matches!(pane, Pane::Editor(b) if b.is_at(&p)));
            if !still_open {
                self.closed_buffers.push((p, cur, scroll));
                if self.closed_buffers.len() > CLOSED_BUFFERS_MAX {
                    let drop = self.closed_buffers.len() - CLOSED_BUFFERS_MAX;
                    self.closed_buffers.drain(..drop);
                }
            }
        }
        let (discarded, closed_path) = match &self.panes[id] {
            Pane::Editor(b) => (b.dirty.then(|| b.display_name()), b.path.clone()),
            Pane::MdPreview(_)
            | Pane::Diff(_)
            | Pane::GitGraph(_)
            | Pane::GitStatus(_)
            | Pane::Request(_)
            | Pane::Pty(_)
            | Pane::Ai(_)
            | Pane::Tests(_)
            | Pane::Trace(_)
            | Pane::Browser(_)
            | Pane::Diagnostics(_)
            | Pane::Grep(_)
            | Pane::Flaky(_)
            | Pane::Outline(_) => (None, None),
        };
        if self.layout.contains(id) {
            self.layout.remove_leaf(id);
        }
        if self.active == Some(id) {
            self.active = self.layout.first_leaf();
        }
        self.remove_pane_storage(id);
        // If no other editor pane still shows that file, tell the LSP server.
        if let Some(p) = closed_path
            && !self
                .panes
                .iter()
                .any(|pane| matches!(pane, Pane::Editor(b) if b.is_at(&p)))
        {
            self.lsp.did_close(&p);
        }
        // If we dropped the last leaf but background buffers remain, show one.
        if self.active.is_none() && !self.panes.is_empty() {
            self.reveal_pane(self.panes.len() - 1);
        }
        if let Some(name) = discarded {
            self.toast(format!("closed {name} — discarded unsaved changes"));
        }
        if self.active.is_none() {
            self.focus = Focus::Tree;
        }
    }

    pub fn close_active_pane(&mut self) {
        if let Some(i) = self.active {
            self.close_pane(i);
        }
    }
    pub fn force_close_active_pane(&mut self) {
        if let Some(i) = self.active {
            self.force_close_pane(i);
        }
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
            Pane::Trace(t) => Some((t.tab_title(), false)),
            Pane::Browser(b) => Some((b.tab_title(), false)),
            Pane::Diagnostics(d) => Some((d.tab_title(), false)),
            Pane::Grep(g) => Some((g.tab_title(), false)),
            Pane::Flaky(f) => Some((f.tab_title(), false)),
            Pane::Outline(o) => Some((o.tab_title(), false)),
        }
    }

    /// Cycle the focused leaf to the next open buffer (wrapping). A buffer
    /// already visible in another leaf just gets focused there.
    pub fn next_buffer(&mut self) {
        if self.panes.is_empty() {
            return;
        }
        let cur = self.active.unwrap_or(0);
        self.reveal_pane((cur + 1) % self.panes.len());
    }
    pub fn prev_buffer(&mut self) {
        if self.panes.is_empty() {
            return;
        }
        let cur = self.active.unwrap_or(0);
        self.reveal_pane((cur + self.panes.len() - 1) % self.panes.len());
    }

    pub fn save_active(&mut self) {
        // Request-pane writeback: `Ctrl+S` over a `Pane::Request` serialises
        // the edited request (URL / method / headers / body) back to its
        // source file as a `curl` command.
        if matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(_))
        ) {
            self.save_request_to_source();
            return;
        }
        // Format-on-save: ask the LSP to format first; the reply will land
        // async and chain into `save_active_now`. If the LSP isn't attached
        // (no server, or the format request is rejected) we fall through and
        // save immediately so the user isn't left holding a dirty buffer.
        if self.config.editor.format_on_save
            && let Some(b) = self.active_editor()
            && let Some(path) = b.path.clone()
        {
            let tab_size = self.config.editor.tab_width as u32;
            if self.lsp.formatting(&path, tab_size, true) {
                self.pending_format_save = Some((
                    path,
                    std::time::Instant::now() + std::time::Duration::from_millis(2000),
                ));
                return;
            }
        }
        self.save_active_now();
    }

    /// `Ctrl+S` over the active `Pane::Request` — write the current request
    /// (with the in-pane edits applied) back to its source file as a curl
    /// command. Pane has no `source_path` ⇒ toast and bail.
    pub fn save_request_to_source(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.commit_headers();
        }
        // Snapshot the pane state in one pass so we can let go of the borrow
        // before any disk I/O.
        let (path, ext, source_block_name, curl_text, http_block) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(p) = rp.source_path.clone() else {
                    self.toast("no source file to save to (re-fire is in-memory only)");
                    return;
                };
                let ext = p
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                (
                    p,
                    ext,
                    rp.source_block_name.clone(),
                    rp.as_curl(),
                    rp.as_http_block(rp.source_block_name.as_deref()),
                )
            }
            _ => return,
        };
        // Multi-block `.http` / `.rest` source: splice just that block in
        // place so the other blocks survive. If the splice can't find a
        // home for the edit (file was edited externally and the block we
        // sent from is gone) we refuse rather than overwrite — losing the
        // other blocks would be the worst possible outcome.
        if matches!(ext.as_str(), "http" | "rest") && source_block_name.is_some() {
            let existing = match std::fs::read_to_string(&path) {
                Ok(t) => t,
                Err(e) => {
                    self.toast(format!("save failed: {e}"));
                    return;
                }
            };
            let Some(new_text) =
                splice_http_block(&existing, source_block_name.as_deref(), &http_block)
            else {
                self.toast(
                    "can't locate the source block (file changed?) — re-fire from the editor to refresh",
                );
                return;
            };
            match std::fs::write(&path, &new_text) {
                Ok(()) => {
                    let rel = rel_path(&self.workspace, &path);
                    self.toast(format!("saved block → {rel}"));
                    self.git.refresh();
                }
                Err(e) => self.toast(format!("save failed: {e}")),
            }
            return;
        }
        // Single-block source (`.curl`, or `.http` whose only block is the
        // one we're saving): overwrite with the curl one-liner. Same as the
        // pre-multi-block behavior.
        match std::fs::write(&path, format!("{curl_text}\n")) {
            Ok(()) => {
                let rel = rel_path(&self.workspace, &path);
                self.toast(format!("saved request → {rel}"));
                self.git.refresh();
            }
            Err(e) => self.toast(format!("save failed: {e}")),
        }
    }

    /// The actual write — extracted so the format-on-save flow can call it
    /// after the LSP reply lands (or after the deadline times out).
    pub fn save_active_now(&mut self) {
        let workspace = self.workspace.clone();
        let saved_path = match self.active_editor_mut() {
            Some(buf) if buf.path.is_some() => {
                let name = buf.display_name();
                match buf.save_to_disk() {
                    Ok(()) => {
                        let p = buf.path.clone();
                        // Persist the undo/redo stack alongside the file so a
                        // close-and-reopen keeps your history.
                        if let Some(ref fp) = p {
                            let undo_path = crate::editor::undo_path_for(&workspace, fp);
                            crate::editor::save_history_to(&buf.editor, &undo_path);
                        }
                        self.toast(format!("saved {name}"));
                        self.git.refresh();
                        self.disarm_quit();
                        p
                    }
                    Err(e) => {
                        self.toast(format!("save failed: {e}"));
                        None
                    }
                }
            }
            Some(_) => {
                self.toast("nothing to save (scratch buffer)".to_string());
                None
            }
            None => {
                self.toast("no active editor".to_string());
                None
            }
        };
        if let Some(p) = saved_path {
            self.refresh_md_previews(&p);
            self.refresh_blame_for(&p);
            self.notify_lsp_saved(&p);
        }
    }
    /// `:w <path>` — save the active editor to a new path (relative paths are
    /// resolved against the workspace). Repoints the buffer at the new path so
    /// subsequent `:w` writes there. Refreshes git/tree/LSP. Toasts the result.
    pub fn save_active_as(&mut self, raw_path: &str) {
        let path = std::path::PathBuf::from(raw_path);
        let abs = if path.is_absolute() {
            path
        } else {
            self.workspace.join(&path)
        };
        // Make sure the parent dir exists (`:w newdir/foo.rs` shouldn't fail
        // with ENOENT — it's an explicit save, not an accidental write).
        if let Some(parent) = abs.parent()
            && !parent.as_os_str().is_empty()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("save-as: cannot create {}: {e}", parent.display()));
            return;
        }
        let Some(buf) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let prev_path = buf.path.clone();
        if let Err(e) = buf.save_as(abs.clone()) {
            self.toast(format!("save-as failed: {e}"));
            return;
        }
        // Best-effort: refresh subsystems that care about file paths.
        self.git.refresh();
        self.tree.refresh();
        self.refresh_md_previews(&abs);
        self.refresh_blame_for(&abs);
        // LSP: close the old `path` (if any) and open the new one with the
        // current text — the new extension might mean a different server.
        if let Some(p) = prev_path {
            self.lsp.did_close(&p);
        }
        if let Some(b) = self.active_editor() {
            let t = b.editor.text().to_string();
            self.lsp.did_open(&abs, &t);
        }
        self.toast(format!("saved to {}", rel_path(&self.workspace, &abs)));
    }

    /// `file.open_settings` (`Ctrl+,`) — open `~/.config/mnml/config.toml`
    /// (or `$XDG_CONFIG_HOME/mnml/config.toml`) in an editor pane. Creates
    /// the file (+ parent dirs) with a one-line `# mnml config` placeholder
    /// if it doesn't exist yet so the buffer isn't blank.
    pub fn open_settings(&mut self) {
        let Some(path) = crate::config::user_config_path() else {
            self.toast("can't resolve config path (no HOME / XDG_CONFIG_HOME)");
            return;
        };
        if !path.exists() {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&path, "# mnml config\n") {
                self.toast(format!("can't create settings file: {e}"));
                return;
            }
        }
        self.open_path(&path);
    }

    /// Re-read the active buffer from disk, preserving cursor + scroll. Refuses
    /// when the buffer is dirty unless `force=true` (`:e!` / a "discard then
    /// reload" prompt). Notifies LSP with the new text.
    pub fn reload_active(&mut self, force: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("nothing to reload (scratch buffer)");
            return;
        };
        if b.dirty && !force {
            self.toast("unsaved changes — use :e! to discard");
            return;
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                self.toast(format!("reload failed: {e}"));
                return;
            }
        };
        let (row, col, scroll) = match self.active_editor() {
            Some(b) => (b.editor.row_col().0, b.editor.row_col().1, b.scroll),
            None => return,
        };
        let clip = &mut self.clipboard;
        if let Some(b) = self.active.and_then(|i| self.panes.get_mut(i))
            && let Pane::Editor(b) = b
        {
            let end = b.editor.text().len();
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start: 0,
                    end,
                    text,
                }],
                clip,
                0,
            );
            b.editor.place_cursor(row, col);
            b.scroll = scroll;
        }
        if let Some(b) = self.active_editor() {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&path, &t);
        }
        self.toast(format!("reloaded {}", rel_path(&self.workspace, &path)));
    }

    pub fn save_all(&mut self) {
        let mut n = 0;
        let mut saved: Vec<std::path::PathBuf> = Vec::new();
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.path.is_some()
                && b.dirty
                && b.save_to_disk().is_ok()
            {
                n += 1;
                if let Some(p) = &b.path {
                    saved.push(p.clone());
                }
            }
        }
        self.git.refresh();
        self.disarm_quit();
        for p in saved {
            self.refresh_md_previews(&p);
            self.refresh_blame_for(&p);
            self.notify_lsp_saved(&p);
        }
        self.toast(format!("saved {n} file(s)"));
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

    pub fn pending_display(&self) -> Option<String> {
        if self.focus == Focus::Pane {
            self.active_editor().and_then(|b| b.input.pending_display())
        } else {
            None
        }
    }

    // ─── keymap (vim ⇄ standard) ────────────────────────────────────
    /// Swap every editor buffer's input handler to `style` (`"vim"` | `"standard"`),
    /// remember it as the new default, and toast the result.
    pub fn set_input_style(&mut self, style: &str) {
        let style = match style {
            "vim" => "vim",
            "standard" | "vscode" => "standard",
            other => {
                self.toast(format!("unknown input style: {other}"));
                return;
            }
        };
        self.config.editor.input_style = style.to_string();
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane {
                b.input = crate::input::make_handler_for(style, &self.config);
            }
        }
        // A `[keys.<style>]` section may rebind chords — re-resolve the table.
        self.keymap = crate::input::keymap::Keymap::build(&self.config);
        self.toast(format!("input: {style}"));
    }
    pub fn toggle_input_style(&mut self) {
        let next = if self.config.editor.input_style == "vim" {
            "standard"
        } else {
            "vim"
        };
        self.set_input_style(next);
    }

    /// Turn hybrid relative line numbers on/off (`:set [no]relativenumber`,
    /// `view.toggle_relative_numbers`).
    pub fn set_relative_line_numbers(&mut self, on: bool) {
        self.config.ui.relative_line_numbers = on;
        self.toast(if on {
            "relative line numbers: on"
        } else {
            "relative line numbers: off"
        });
    }
    pub fn toggle_relative_line_numbers(&mut self) {
        self.set_relative_line_numbers(!self.config.ui.relative_line_numbers);
    }

    /// `:set tab_width=N` — set the global tab width. Affects new buffers,
    /// indent-guide stride, and the `Tab` key in standard mode. Existing
    /// buffers keep whatever width they were opened with (use `:e!` to reload
    /// to the new setting).
    pub fn set_tab_width(&mut self, n: usize) {
        let n = n.clamp(1, 16);
        self.config.editor.tab_width = n;
        self.toast(format!("tab_width: {n} (re-open file to retake)"));
    }

    /// Toggle visible whitespace markers (`:set list` / `:set nolist`).
    pub fn set_show_whitespace(&mut self, on: bool) {
        self.config.ui.show_whitespace = on;
        self.toast(if on {
            "whitespace: on"
        } else {
            "whitespace: off"
        });
    }
    pub fn toggle_show_whitespace(&mut self) {
        self.set_show_whitespace(!self.config.ui.show_whitespace);
    }

    /// Toggle rainbow-brackets (`:set rainbow` / `:set norainbow`).
    pub fn set_bracket_rainbow(&mut self, on: bool) {
        self.config.ui.bracket_rainbow = on;
        self.toast(if on {
            "rainbow brackets: on"
        } else {
            "rainbow brackets: off"
        });
    }
    pub fn toggle_bracket_rainbow(&mut self) {
        self.set_bracket_rainbow(!self.config.ui.bracket_rainbow);
    }

    /// Toggle the editor scrollbar (`:set scrollbar` / `:set noscrollbar`).
    pub fn set_scrollbar(&mut self, on: bool) {
        self.config.ui.scrollbar = on;
        self.toast(if on {
            "scrollbar: on"
        } else {
            "scrollbar: off"
        });
    }
    pub fn toggle_scrollbar(&mut self) {
        self.set_scrollbar(!self.config.ui.scrollbar);
    }

    /// Toggle trailing-whitespace highlight (`:set [no]trailing`).
    pub fn set_highlight_trailing_ws(&mut self, on: bool) {
        self.config.ui.highlight_trailing_ws = on;
        self.toast(if on {
            "trailing ws: highlighted"
        } else {
            "trailing ws: off"
        });
    }
    pub fn toggle_highlight_trailing_ws(&mut self) {
        self.set_highlight_trailing_ws(!self.config.ui.highlight_trailing_ws);
    }

    /// Toggle "highlight word under cursor" (`:set [no]hlword`).
    pub fn set_highlight_word_under_cursor(&mut self, on: bool) {
        self.config.ui.highlight_word_under_cursor = on;
        self.toast(if on {
            "highlight word: on"
        } else {
            "highlight word: off"
        });
    }
    pub fn toggle_highlight_word_under_cursor(&mut self) {
        self.set_highlight_word_under_cursor(!self.config.ui.highlight_word_under_cursor);
    }

    /// Toggle CDP headless launch (`:set [no]headless`). Takes effect on the
    /// **next** `browser.open` — an in-flight browser pane is unaffected.
    pub fn set_browser_headless(&mut self, on: bool) {
        self.config.browser.headless = on;
        self.toast(if on {
            "browser: headless on (next open)"
        } else {
            "browser: headless off (next open)"
        });
    }
    pub fn toggle_browser_headless(&mut self) {
        self.set_browser_headless(!self.config.browser.headless);
    }

    /// Interpret a vim `:`-line (without the leading `:`). Anything we don't
    /// recognise is bridged to a registered command if one matches, else toasted.
    /// Apply a parsed `:%s/old/new/[flags]` to the active editor — buffer-wide
    /// substring replace (literal, no regex). Case-insensitive when the `i`
    /// flag is set. Result is staged as one undo step + toasted.
    fn run_substitute(&mut self, sub: Substitute) {
        let Some(idx) = self.active else {
            self.toast(":%s — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast(":%s — only works in editor panes");
            return;
        };
        let text = b.editor.text().to_string();
        let matches = if sub.case_insensitive {
            crate::buffer::find_all_ci_ascii(&text, &sub.find)
        } else {
            find_all_case_sensitive(&text, &sub.find)
        };
        if matches.is_empty() {
            self.toast(format!(":%s — no match for {:?}", sub.find));
            return;
        }
        let n = matches.len();
        // Descending order so each replace keeps earlier byte offsets valid.
        let ops: Vec<crate::edit_op::EditOp> = matches
            .into_iter()
            .rev()
            .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                start: s,
                end: e,
                text: sub.replace.clone(),
            })
            .collect();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let clip = &mut self.clipboard;
            b.apply_edit_ops(ops, clip, 0);
        }
        // Push the new text to the LSP so diagnostics stay current.
        if let Some(Pane::Editor(b)) = self.panes.get(idx)
            && let Some(p) = b.path.clone()
        {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&p, &t);
        }
        self.toast(format!(":%s — {n} replacement(s)"));
    }

    pub fn run_ex_command(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        // Bare number ⇒ jump to that line.
        if let Ok(n) = line.parse::<usize>() {
            if let Some(b) = self.active_editor_mut() {
                b.editor.place_cursor(n.saturating_sub(1), 0);
            }
            return;
        }
        // `:%s/old/new/[flags]` — vim-style global substitute. (No regex; flags
        // supported: `g` replace all on each line [default — we always do all
        // matches in the whole buffer]; `i` case-insensitive; `c` confirm
        // ignored for now — applies all without prompting.)
        if let Some(sub) = parse_substitute(line) {
            self.run_substitute(sub);
            return;
        }
        let (cmd, rest) = match line.split_once(char::is_whitespace) {
            Some((c, r)) => (c, r.trim()),
            None => (line, ""),
        };
        match cmd {
            "w" | "write" => {
                if rest.is_empty() {
                    self.save_active();
                } else {
                    self.save_active_as(rest);
                }
            }
            "saveas" => {
                if rest.is_empty() {
                    self.toast(":saveas <path> — path required");
                } else {
                    self.save_active_as(rest);
                }
            }
            "q" | "quit" => {
                if self.active.is_some() && self.active_pane().is_some_and(Pane::is_dirty) {
                    self.toast("unsaved changes — use :q! to discard");
                } else {
                    self.close_active_pane();
                    if self.panes.is_empty() {
                        self.should_quit = true;
                    }
                }
            }
            "q!" | "quit!" => {
                self.force_close_active_pane();
                if self.panes.is_empty() {
                    self.should_quit = true;
                }
            }
            "wq" | "x" | "xit" => {
                self.save_active();
                // After a successful save the buffer's clean, so this won't prompt.
                self.close_active_pane();
                if self.panes.is_empty() {
                    self.should_quit = true;
                }
            }
            "wa" | "wall" => self.save_all(),
            "wqa" | "wqall" | "xa" | "xall" => {
                self.save_all();
                self.should_quit = true;
            }
            "qa" | "qall" | "quitall" => self.should_quit = true,
            "qa!" | "qall!" => self.should_quit = true,
            "bd" | "bdelete" => self.close_active_pane(),
            "bn" | "bnext" => self.next_buffer(),
            "bp" | "bprev" | "bprevious" => self.prev_buffer(),
            "e" | "edit" => {
                if rest.is_empty() {
                    self.reload_active(false);
                } else {
                    let p = self.workspace.join(rest);
                    self.open_path(&p);
                }
            }
            "e!" | "edit!" => self.reload_active(true),
            "set" => {
                // `:set` (bare) → list every option's current value as a toast.
                // `:set input=vim|standard` · `:set theme=…` · `:set tab_width=N`
                // · `:set [no]relativenumber` / `[no]list` (toggle suffix `!`).
                let opt = rest.trim();
                if opt.is_empty() {
                    let cfg = &self.config;
                    let theme = crate::ui::theme::cur().name;
                    self.toast(format!(
                        "input={} · theme={theme} · tab_width={} · {} · {} · {}",
                        cfg.editor.input_style,
                        cfg.editor.tab_width,
                        if cfg.ui.relative_line_numbers {
                            "relativenumber"
                        } else {
                            "norelativenumber"
                        },
                        if cfg.ui.show_whitespace {
                            "list"
                        } else {
                            "nolist"
                        },
                        if cfg.ui.bracket_rainbow {
                            "rainbow"
                        } else {
                            "norainbow"
                        },
                    ));
                } else if let Some(v) = rest.strip_prefix("input=") {
                    self.set_input_style(v.trim());
                } else if let Some(v) = rest.strip_prefix("theme=") {
                    self.set_theme(v.trim());
                } else if let Some(v) = rest.strip_prefix("tab_width=") {
                    if let Ok(n) = v.trim().parse::<usize>() {
                        self.set_tab_width(n);
                    } else {
                        self.toast(format!(":set tab_width={v} — not a number"));
                    }
                } else if matches!(opt, "relativenumber" | "rnu") {
                    self.set_relative_line_numbers(true);
                } else if matches!(opt, "norelativenumber" | "nornu") {
                    self.set_relative_line_numbers(false);
                } else if matches!(opt, "relativenumber!" | "rnu!" | "invrelativenumber") {
                    self.set_relative_line_numbers(!self.config.ui.relative_line_numbers);
                } else if matches!(opt, "list") {
                    self.set_show_whitespace(true);
                } else if matches!(opt, "nolist") {
                    self.set_show_whitespace(false);
                } else if matches!(opt, "list!" | "invlist") {
                    self.set_show_whitespace(!self.config.ui.show_whitespace);
                } else if matches!(opt, "rainbow") {
                    self.set_bracket_rainbow(true);
                } else if matches!(opt, "norainbow") {
                    self.set_bracket_rainbow(false);
                } else if matches!(opt, "rainbow!" | "invrainbow") {
                    self.toggle_bracket_rainbow();
                } else if matches!(opt, "scrollbar") {
                    self.set_scrollbar(true);
                } else if matches!(opt, "noscrollbar") {
                    self.set_scrollbar(false);
                } else if matches!(opt, "scrollbar!" | "invscrollbar") {
                    self.toggle_scrollbar();
                } else if matches!(opt, "headless") {
                    self.set_browser_headless(true);
                } else if matches!(opt, "noheadless") {
                    self.set_browser_headless(false);
                } else if matches!(opt, "headless!" | "invheadless") {
                    self.toggle_browser_headless();
                } else if matches!(opt, "trailing") {
                    self.set_highlight_trailing_ws(true);
                } else if matches!(opt, "notrailing") {
                    self.set_highlight_trailing_ws(false);
                } else if matches!(opt, "trailing!" | "invtrailing") {
                    self.toggle_highlight_trailing_ws();
                } else if matches!(opt, "hlword") {
                    self.set_highlight_word_under_cursor(true);
                } else if matches!(opt, "nohlword") {
                    self.set_highlight_word_under_cursor(false);
                } else if matches!(opt, "hlword!" | "invhlword") {
                    self.toggle_highlight_word_under_cursor();
                } else if matches!(opt, "automdpreview") {
                    self.config.ui.auto_md_preview = true;
                    self.toast("auto-preview md: on");
                } else if matches!(opt, "noautomdpreview") {
                    self.config.ui.auto_md_preview = false;
                    self.toast("auto-preview md: off");
                } else if matches!(opt, "automdpreview!" | "invautomdpreview") {
                    self.config.ui.auto_md_preview = !self.config.ui.auto_md_preview;
                    self.toast(format!(
                        "auto-preview md: {}",
                        if self.config.ui.auto_md_preview {
                            "on"
                        } else {
                            "off"
                        }
                    ));
                } else {
                    self.toast(format!(":set {rest} — not supported"));
                }
            }
            "noh" | "nohl" | "nohlsearch" => {}
            other => {
                // Last resort: maybe it names a registered command.
                if crate::command::registry().get(other).is_some() {
                    crate::command::run(other, self);
                } else {
                    self.toast(format!(":{line} — unknown command"));
                }
            }
        }
    }

    // ─── focus ──────────────────────────────────────────────────────
    pub fn cycle_focus(&mut self) {
        let was_pane = self.focus == Focus::Pane;
        self.focus = self.focus.next(self.active.is_some());
        if was_pane
            && self.focus != Focus::Pane
            && let Some(b) = self.active_editor_mut()
        {
            b.input.on_blur();
        }
    }
    pub fn focus_tree(&mut self) {
        if self.focus == Focus::Pane
            && let Some(b) = self.active_editor_mut()
        {
            b.input.on_blur();
        }
        self.focus = Focus::Tree;
    }
    pub fn focus_pane(&mut self) {
        if self.active.is_some() {
            self.focus = Focus::Pane;
        }
    }

    /// Toggle the file-tree rail in/out entirely (`Ctrl+B`). When the user
    /// hides it while focused there, focus snaps to the active pane.
    pub fn toggle_tree_visibility(&mut self) {
        self.tree_visible = !self.tree_visible;
        if !self.tree_visible && self.focus == Focus::Tree {
            self.focus = if self.active.is_some() {
                Focus::Pane
            } else {
                Focus::Tree
            };
        }
    }

    /// Toggle the workspace "section" inside the rail (the click on the
    /// `> WORKSPACE-NAME` header — VS-Code Explorer style). When expanded,
    /// focus moves into the tree so keyboard nav picks up where it should.
    pub fn toggle_tree_root_expanded(&mut self) {
        self.tree_root_expanded = !self.tree_root_expanded;
        if self.tree_root_expanded {
            self.focus = Focus::Tree;
            self.rail_section = RailSection::Workspace;
        }
    }

    /// Toggle the `> GIT` section in the rail (sibling of the workspace
    /// section). Clicking the header expands/collapses it and parks the rail
    /// keyboard on the git section.
    pub fn toggle_git_section_expanded(&mut self) {
        self.git_section_expanded = !self.git_section_expanded;
        if self.git_section_expanded {
            self.focus = Focus::Tree;
            self.rail_section = RailSection::Git;
        }
    }

    // ─── git rail (`GIT` section in the left rail) ──────────────────
    /// Move the git rail's cursor. Crosses back into the workspace section
    /// when the user goes up off the top of the git list.
    pub fn git_rail_move_up(&mut self) {
        if self.git_rail.cursor == 0 {
            // At top of the git section already → flip back to workspace.
            self.rail_section = RailSection::Workspace;
        } else {
            self.git_rail.move_up();
        }
    }
    pub fn git_rail_move_down(&mut self) {
        self.git_rail.move_down();
    }
    /// Enter on the cursor row: checkout the branch, or open a shell in the
    /// worktree. (Both are also reachable via right-click context menu.)
    pub fn git_rail_activate(&mut self) {
        let Some(hit) = self.git_rail.selected() else {
            return;
        };
        self.run_git_rail_hit(hit);
    }
    /// Click handler — focus the git section, set the cursor, run the row's
    /// default action.
    pub fn click_git_rail(&mut self, hit: crate::git::rail::GitRailHit) {
        self.focus_tree();
        self.rail_section = RailSection::Git;
        self.git_rail.focus(hit);
        self.run_git_rail_hit(hit);
    }
    /// Right-click on a git-rail row: open the appropriate context menu.
    pub fn open_git_rail_context_menu(
        &mut self,
        hit: crate::git::rail::GitRailHit,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        self.focus_tree();
        self.rail_section = RailSection::Git;
        self.git_rail.focus(hit);
        let menu = match hit {
            crate::git::rail::GitRailHit::Branch(i) => {
                let Some(b) = self.git_rail.branches.get(i) else {
                    return;
                };
                let name = b.name.clone();
                let title = if b.is_current {
                    Some(format!("● {name}"))
                } else {
                    Some(name.clone())
                };
                let items = if b.is_current {
                    vec![MenuItem::new(
                        "New branch from here…",
                        MenuAction::GitNewBranchFrom(name),
                    )]
                } else {
                    vec![
                        MenuItem::new(
                            format!("Checkout {name}"),
                            MenuAction::GitCheckoutBranch(name.clone()),
                        ),
                        MenuItem::new(
                            "New branch from here…",
                            MenuAction::GitNewBranchFrom(name.clone()),
                        ),
                        MenuItem::new(format!("Delete {name}…"), MenuAction::GitDeleteBranch(name)),
                    ]
                };
                ContextMenu::new(title, anchor, items)
            }
            crate::git::rail::GitRailHit::Worktree(i) => {
                let Some(w) = self.git_rail.worktrees.get(i) else {
                    return;
                };
                let path = w.path.clone();
                let label = w.label.clone();
                let is_cur = w.is_current;
                let title = Some(format!("{label}  {}", path.display()));
                let mut items = vec![
                    MenuItem::new(
                        "Open shell here",
                        MenuAction::GitWorktreeShell(path.clone()),
                    ),
                    MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                    MenuItem::new(
                        "Copy path",
                        MenuAction::CopyPath(path.to_string_lossy().into_owned()),
                    ),
                ];
                if !is_cur {
                    items.push(MenuItem::new(
                        "Remove worktree…",
                        MenuAction::GitWorktreeRemove(path),
                    ));
                }
                ContextMenu::new(title, anchor, items)
            }
        };
        self.context_menu = Some(menu);
    }
    /// Common tail of click + Enter — run the action attached to `hit`.
    fn run_git_rail_hit(&mut self, hit: crate::git::rail::GitRailHit) {
        match hit {
            crate::git::rail::GitRailHit::Branch(i) => {
                let Some(b) = self.git_rail.branches.get(i) else {
                    return;
                };
                if b.is_current {
                    self.toast(format!("● {} (already checked out)", b.name));
                } else {
                    let name = b.name.clone();
                    self.git_checkout_named(&name);
                }
            }
            crate::git::rail::GitRailHit::Worktree(i) => {
                let Some(w) = self.git_rail.worktrees.get(i) else {
                    return;
                };
                let path = w.path.clone();
                self.open_worktree_shell(&path.to_string_lossy());
            }
        }
    }
    /// Right-click context-menu action: checkout an existing local branch.
    pub fn git_checkout_named(&mut self, name: &str) {
        match crate::git::branch::checkout(&self.workspace, name) {
            Ok(()) => self.after_checkout(name),
            Err(e) => self.toast(format!("checkout: {e}")),
        }
    }
    /// Right-click context-menu action: prompt for a new branch name (off the
    /// named branch's tip) and create+checkout. The existing
    /// [`Self::open_new_branch_prompt`] already does this off `HEAD`; here we
    /// just stash the source branch and reuse that prompt — the user can
    /// switch first if they want a different base.
    pub fn git_new_branch_from(&mut self, source: String) {
        self.pending_branch_source = Some(source.clone());
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewBranch,
            format!("New branch name (off {source})"),
        ));
    }
    /// Right-click context-menu action: prompt to confirm, then `git branch -D`.
    pub fn git_delete_branch_prompt(&mut self, name: String) {
        use crate::prompt::{Prompt, PromptKind};
        self.prompt = Some(Prompt::seeded(
            PromptKind::GitDeleteBranch,
            format!("Type {name:?} to delete this branch"),
            "",
        ));
        self.pending_delete_branch = Some(name);
    }
    /// Accept handler for the `PromptKind::GitDeleteBranch` confirm prompt.
    pub fn confirm_delete_branch(&mut self, typed: String) {
        let Some(name) = self.pending_delete_branch.take() else {
            return;
        };
        if typed.trim() != name {
            self.toast("branch delete cancelled (name didn't match)");
            return;
        }
        match crate::git::branch::delete_branch(&self.workspace, &name) {
            Ok(()) => {
                self.toast(format!("deleted branch {name}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("branch delete: {e}")),
        }
    }
    /// Right-click context-menu action: confirm + `git worktree remove`.
    pub fn git_worktree_remove_prompt(&mut self, path: PathBuf) {
        use crate::prompt::{Prompt, PromptKind};
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();
        self.prompt = Some(Prompt::seeded(
            PromptKind::GitWorktreeRemove,
            format!("Type {name:?} to remove this worktree"),
            "",
        ));
        self.pending_worktree_remove = Some((path, name));
    }
    /// Accept handler for `PromptKind::GitWorktreeRemove`.
    pub fn confirm_worktree_remove(&mut self, typed: String) {
        let Some((path, name)) = self.pending_worktree_remove.take() else {
            return;
        };
        if typed.trim() != name {
            self.toast("worktree remove cancelled (name didn't match)");
            return;
        }
        match crate::git::branch::worktree_remove(&self.workspace, &path) {
            Ok(()) => {
                self.toast(format!("removed worktree {name}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("worktree remove: {e}")),
        }
    }

    /// Toggle "zen" focus mode — hide everything but the editor (tree rail,
    /// bufferline, statusline gone). Always lands focus on the active pane
    /// when entering so the user can start typing immediately.
    pub fn toggle_zen_mode(&mut self) {
        self.zen_mode = !self.zen_mode;
        if self.zen_mode && self.active.is_some() {
            self.focus = Focus::Pane;
        }
    }

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
        let dirty = self.panes.iter().any(|p| p.is_dirty());
        if dirty && !self.quit_armed {
            self.quit_armed = true;
            self.toast("unsaved changes — press quit again, or save first");
        } else {
            self.should_quit = true;
        }
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
        self.toast = Some((msg.into(), Instant::now()));
    }
    /// Current toast text if it hasn't expired.
    pub fn live_toast(&self) -> Option<&str> {
        self.toast
            .as_ref()
            .filter(|(_, t)| t.elapsed() < TOAST_TTL)
            .map(|(s, _)| s.as_str())
    }

    /// Per-event-loop housekeeping (cheap).
    pub fn tick(&mut self) {
        self.git.tick();
        self.drain_http_jobs();
        self.drain_ai_jobs();
        self.drain_tests_jobs();
        self.drain_lsp_events();
        self.drain_cdp_events();
        self.refresh_live_ai_panes();
        self.autosave_idle_buffers();
        self.check_format_save_deadline();
        if let Some((_, t)) = &self.toast
            && t.elapsed() >= TOAST_TTL
        {
            self.toast = None;
        }
    }

    /// `[editor] autosave_secs > 0` ⇒ save any dirty editor buffer whose last
    /// edit was at least that long ago. No-op when off (the default). LSP gets a
    /// `didSave` per saved file so the server stays in sync.
    fn autosave_idle_buffers(&mut self) {
        let after = self.config.editor.autosave_secs;
        if after == 0 {
            return;
        }
        let after = std::time::Duration::from_secs(after);
        let saved: Vec<(std::path::PathBuf, String)> = self
            .panes
            .iter_mut()
            .filter_map(|p| match p {
                Pane::Editor(b) => {
                    if b.dirty
                        && b.path.is_some()
                        && b.last_edited.map(|t| t.elapsed() >= after).unwrap_or(false)
                        && b.save_to_disk().is_ok()
                    {
                        b.path.clone().map(|p| (p, b.editor.text().to_string()))
                    } else {
                        None
                    }
                }
                _ => None,
            })
            .collect();
        for (p, t) in saved {
            self.lsp.did_save(&p, &t);
        }
    }

    /// `[session] restore = true` ⇒ on quit, write the open editor buffers +
    /// their cursors to `<workspace>/.mnml/session.json` so the next launch can
    /// re-open them. Best-effort (errors are swallowed). No-op when restore is
    /// off, or when nothing is open.
    pub fn save_session_on_quit(&self) {
        if !self.config.session.restore {
            return;
        }
        // Save editor buffers in tab order, with PaneId → saved-index lookup
        // for the layout pass. Also fold the currently-open buffers' cursors
        // into `file_cursors` so per-file restore covers them even if the user
        // closes them after relaunch.
        let mut open: Vec<SavedBuffer> = Vec::new();
        let mut pane_to_idx: Vec<Option<usize>> = vec![None; self.panes.len()];
        let mut active: Option<usize> = None;
        let mut merged_cursors = self.file_cursors.clone();
        for (i, p) in self.panes.iter().enumerate() {
            if let Pane::Editor(b) = p
                && let Some(path) = &b.path
            {
                pane_to_idx[i] = Some(open.len());
                if self.active == Some(i) {
                    active = Some(open.len());
                }
                open.push(SavedBuffer {
                    path: path.to_string_lossy().into_owned(),
                    cursor_byte: b.editor.cursor(),
                    scroll: b.scroll,
                });
                merged_cursors.insert(path.clone(), (b.editor.cursor(), b.scroll));
            }
        }
        // Try to mirror the split tree. If any leaf isn't an editor we can save
        // (e.g. a transient pty / diff / browser pane), drop layout — the buffer
        // list alone is enough for the most common case.
        let layout = saved_layout_from(&self.layout, &pane_to_idx);
        let saved = SavedSession {
            workspace: self.workspace.to_string_lossy().into_owned(),
            open,
            active,
            layout,
            tree_visible: Some(self.tree_visible),
            tree_root_expanded: Some(self.tree_root_expanded),
            tree_width: Some(self.tree_width),
            git_section_expanded: Some(self.git_section_expanded),
            tree_expanded_dirs: Some(
                self.tree
                    .expanded_dirs()
                    .into_iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect(),
            ),
            recent_files: self
                .recent_files
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect(),
            theme: Some(crate::ui::theme::cur().name.to_string()),
            file_cursors: merged_cursors
                .iter()
                .map(|(p, &(c, s))| SavedFileCursor {
                    path: p.to_string_lossy().into_owned(),
                    cursor_byte: c,
                    scroll: s,
                })
                .collect(),
            global_marks: self
                .global_marks
                .iter()
                .map(|(&letter, (path, row, col))| SavedGlobalMark {
                    letter,
                    path: path.to_string_lossy().into_owned(),
                    row: *row,
                    col: *col,
                })
                .collect(),
            folds: self
                .panes
                .iter()
                .filter_map(|p| match p {
                    Pane::Editor(b) if !b.folds.is_empty() => {
                        b.path.as_ref().map(|path| SavedFolds {
                            path: path.to_string_lossy().into_owned(),
                            folds: b.folds.iter().map(|(&s, &e)| (s, e)).collect(),
                        })
                    }
                    _ => None,
                })
                .collect(),
        };
        let Ok(text) = serde_json::to_string_pretty(&saved) else {
            return;
        };
        let dir = self.workspace.join(".mnml");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("session.json"), text);
    }

    /// Read `.mnml/session.json` and re-open the buffers in it (if the saved
    /// workspace matches). Called once from `main.rs` after `App::new` when
    /// `[session] restore = true`. Missing / mismatched / corrupt file ⇒ no-op.
    pub fn try_restore_session(&mut self) {
        if !self.config.session.restore {
            return;
        }
        let path = self.workspace.join(".mnml").join("session.json");
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let Ok(saved) = serde_json::from_str::<SavedSession>(&text) else {
            return;
        };
        if saved.workspace != self.workspace.to_string_lossy() {
            return;
        }
        // saved-index → restored PaneId (None if the file was missing on disk).
        let mut idx_to_pane: Vec<Option<PaneId>> = vec![None; saved.open.len()];
        let mut active_pane: Option<PaneId> = None;
        for (i, b) in saved.open.iter().enumerate() {
            let p = std::path::Path::new(&b.path);
            if !p.exists() {
                continue;
            }
            self.open_path(p);
            if let Some(pid) = self.active {
                idx_to_pane[i] = Some(pid);
                if saved.active == Some(i) {
                    active_pane = Some(pid);
                }
                if let Some(Pane::Editor(buf)) = self.panes.get_mut(pid) {
                    let (row, col) = byte_to_row_col(buf.editor.text(), b.cursor_byte);
                    buf.editor.place_cursor(row, col);
                    buf.scroll = b.scroll;
                }
            }
        }
        // If the saved layout maps cleanly, rebuild the split tree from it.
        if let Some(sl) = saved.layout.as_ref()
            && let Some(restored) = layout_from_saved(sl, &idx_to_pane)
        {
            self.layout = restored;
        }
        // Restore the file-tree visibility flag too (`None` ⇒ leave the
        // launch-time default alone — an older session.json without the field).
        if let Some(v) = saved.tree_visible {
            self.tree_visible = v;
        }
        if let Some(v) = saved.tree_root_expanded {
            self.tree_root_expanded = v;
        }
        if let Some(v) = saved.tree_width {
            self.tree_width = v.clamp(8, 200);
        }
        if let Some(v) = saved.git_section_expanded {
            self.git_section_expanded = v;
        }
        if let Some(dirs) = saved.tree_expanded_dirs {
            self.tree
                .set_expanded_dirs(dirs.into_iter().map(PathBuf::from));
        }
        if !saved.recent_files.is_empty() {
            // Honor the saved order (most-recent first), capping at the runtime
            // limit (which may have shrunk between versions).
            self.recent_files = saved
                .recent_files
                .into_iter()
                .map(PathBuf::from)
                .take(RECENT_FILES_MAX)
                .collect();
        }
        if let Some(name) = saved.theme.as_deref() {
            // Best-effort — unknown theme names (e.g. someone deleted a theme
            // file) just leave the launch-default in place. Silent so the
            // restore doesn't toast on every cold start.
            let _ = self.set_theme_silent(name);
        }
        for fc in saved.file_cursors {
            self.file_cursors
                .insert(PathBuf::from(fc.path), (fc.cursor_byte, fc.scroll));
        }
        for gm in saved.global_marks {
            // Uppercase letters only — guard against malformed session files.
            if gm.letter.is_ascii_uppercase() {
                self.global_marks
                    .insert(gm.letter, (PathBuf::from(gm.path), gm.row, gm.col));
            }
        }
        // Restore folds onto any buffer whose path matches a saved entry.
        // Out-of-range pairs (start >= line_count, or end < start) get
        // dropped silently — likely stale because the file was edited
        // externally.
        for sf in saved.folds {
            let target = PathBuf::from(&sf.path);
            for p in self.panes.iter_mut() {
                if let Pane::Editor(b) = p
                    && b.path.as_deref() == Some(target.as_path())
                {
                    let line_count = b.editor.line_count();
                    for (start, end) in &sf.folds {
                        if *end >= *start && *start < line_count && *end < line_count {
                            b.folds.insert(*start, *end);
                        }
                    }
                    break;
                }
            }
        }
        let fallback = idx_to_pane.iter().rev().flatten().next().copied();
        if let Some(p) = active_pane.or(fallback) {
            self.reveal_pane(p);
        }
    }
}

/// Build the serializable mirror of `layout`. Returns `None` if any leaf isn't
/// in `pane_to_idx` (i.e. it's a non-editor pane we didn't save) — when that
/// happens we drop layout entirely rather than save half a tree.
fn saved_layout_from(layout: &Layout, pane_to_idx: &[Option<usize>]) -> Option<SavedLayout> {
    match layout {
        Layout::Empty => Some(SavedLayout::Empty),
        Layout::Leaf(id) => pane_to_idx
            .get(*id)
            .copied()
            .flatten()
            .map(SavedLayout::Leaf),
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
fn layout_from_saved(saved: &SavedLayout, idx_to_pane: &[Option<PaneId>]) -> Option<Layout> {
    match saved {
        SavedLayout::Empty => Some(Layout::Empty),
        SavedLayout::Leaf(i) => idx_to_pane.get(*i).copied().flatten().map(Layout::Leaf),
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

    fn app_with_files() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        fs::write(d.path().join("b.txt"), "beta").unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    #[test]
    fn open_path_dedups_and_refocuses() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        assert_eq!(app.panes.len(), 2);
        app.open_path(&d.path().join("a.txt")); // already open → no new pane
        assert_eq!(app.panes.len(), 2);
        assert_eq!(app.active, Some(0));
        assert_eq!(app.focus, Focus::Pane);
    }

    #[test]
    fn close_clears_when_empty() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.close_active_pane();
        assert!(app.panes.is_empty());
        assert!(app.active.is_none());
        assert_eq!(app.focus, Focus::Tree);
        assert!(matches!(app.layout, Layout::Empty));
    }

    #[test]
    fn editing_mode_is_none_without_editor() {
        let (_d, app) = app_with_files();
        assert_eq!(app.editing_mode(), EditingMode::None);
    }

    #[test]
    fn session_round_trips_open_buffers_and_active() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        // Move b.txt's cursor onto "beta"'s `t` (byte 2).
        if let Some(Pane::Editor(b)) = app.panes.get_mut(1) {
            b.editor.place_cursor(0, 2);
            b.scroll = 0;
        }
        app.save_session_on_quit();
        assert!(d.path().join(".mnml/session.json").exists());
        // A fresh App on the same workspace + try_restore re-opens both.
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app2.panes.is_empty());
        app2.try_restore_session();
        assert_eq!(app2.panes.len(), 2);
        // The previously-active (b.txt = index 1) should be focused.
        assert_eq!(app2.active, Some(1));
        // Cursor on b.txt was at (0, 2).
        if let Some(Pane::Editor(b)) = app2.panes.get(1) {
            assert_eq!(b.editor.row_col(), (0, 2));
        } else {
            panic!("expected an editor at index 1");
        }
    }

    #[test]
    fn session_round_trips_split_layout() {
        let (d, mut app) = app_with_files();
        let a_path = d.path().join("a.txt").canonicalize().unwrap();
        let b_path = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a_path);
        app.split_active(crate::layout::SplitDir::Horizontal);
        app.open_path(&b_path);
        assert!(matches!(app.layout, Layout::Split { .. }));
        app.save_session_on_quit();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.try_restore_session();
        match &app2.layout {
            Layout::Split { first, second, .. } => {
                let a = app2
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&a_path)))
                    .expect("a.txt should be re-opened");
                let b = app2
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&b_path)))
                    .expect("b.txt should be re-opened");
                assert!(matches!(**first, Layout::Leaf(id) if id == a));
                assert!(matches!(**second, Layout::Leaf(id) if id == b));
            }
            other => panic!("expected a Split, got {other:?}"),
        }
    }

    #[test]
    fn session_skips_save_when_restore_off() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        let mut cfg = Config::default();
        cfg.session.restore = false;
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_path(&d.path().join("a.txt"));
        app.save_session_on_quit();
        assert!(!d.path().join(".mnml/session.json").exists());
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
    fn open_path_at_cursor_jumps_to_position() {
        let (_d, mut app) = app_with_files();
        // Make a buffer whose text references another file with `:line:col`.
        let stub = app.workspace.join("ref.txt");
        std::fs::write(&stub, "see a.txt:1:3\n").unwrap();
        app.open_path(&stub);
        // Place the cursor inside the "a.txt:1:3" token.
        if let Some(b) = app.active_editor_mut() {
            // "see a.txt:1:3" — cursor at index of 'a' in "a.txt".
            let pos = b.editor.text().find("a.txt").unwrap();
            let (row, col) = byte_to_row_col(b.editor.text(), pos);
            b.editor.place_cursor(row, col);
        }
        app.open_path_at_cursor();
        // The active buffer is now `a.txt`, cursor at line 1, col 3 → (0, 2).
        let a = app.workspace.join("a.txt");
        assert_eq!(
            app.active_editor().unwrap().path.as_deref(),
            Some(a.as_path())
        );
        assert_eq!(app.active_editor().unwrap().editor.row_col(), (0, 2));
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
    fn fs_delete_requires_exact_filename_match() {
        let (_d, mut app) = app_with_files();
        let p = app.workspace.join("a.txt");
        // Wrong typed name ⇒ file untouched.
        app.confirm_delete_fs_entry(&p, "b.txt");
        assert!(p.exists());
        // Correct ⇒ deleted, recent_files cleaned up.
        app.open_path(&p);
        app.confirm_delete_fs_entry(&p, "a.txt");
        assert!(!p.exists());
        assert!(!app.recent_files.iter().any(|q| q == &p));
        // Pane for the deleted file is gone.
        assert!(!app.panes.iter().any(|pane| matches!(
            pane,
            Pane::Editor(b) if b.is_at(&p)
        )));
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
        assert_eq!(fs::read_to_string(&new_abs).unwrap(), "alpha!!");
        let buf = app.active_editor().unwrap();
        assert_eq!(buf.path.as_deref(), Some(new_abs.as_path()));
        assert!(!buf.dirty);
        // The original file is untouched.
        let orig = app.workspace.join("a.txt");
        assert_eq!(fs::read_to_string(&orig).unwrap(), "alpha");
    }

    #[test]
    fn session_round_trips_tree_state() {
        let d = tempfile::tempdir().unwrap();
        // Need a sub-directory so the tree has something to expand/collapse.
        fs::create_dir(d.path().join("sub")).unwrap();
        fs::write(d.path().join("sub").join("c.txt"), "c").unwrap();
        fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Default after `Tree::open`: depth-0 dirs are expanded. Collapse `sub`.
        let sub = app.workspace.join("sub");
        let mut dirs: Vec<PathBuf> = app
            .tree
            .expanded_dirs()
            .into_iter()
            .filter(|p| p != &sub)
            .collect();
        dirs.sort();
        let collapsed_snapshot = dirs.clone();
        app.tree.set_expanded_dirs(dirs);
        // Also flip the section header (independent state) so we exercise both.
        app.tree_root_expanded = false;
        app.save_session_on_quit();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Pre-restore, the default expansion is whatever Tree::open chose.
        // After restore, it should match what we saved.
        app2.try_restore_session();
        let mut got = app2.tree.expanded_dirs();
        got.sort();
        assert_eq!(got, collapsed_snapshot);
        assert!(!app2.tree_root_expanded);
    }

    #[test]
    fn grep_pane_jump_opens_file_and_places_cursor() {
        // Manually seed a Pane::Grep — the grep tool itself (rg / git grep)
        // isn't reliably available in test sandboxes, but the rest of the flow
        // (jump-to-hit) is the part we want to cover end-to-end.
        let (_d, mut app) = app_with_files();
        // `app.workspace` is the *canonicalized* tmp dir; the buffer the editor
        // opens will hold the same canonical form, so compare against it.
        let abs = app.workspace.join("a.txt");
        // a.txt is `alpha`; pretend a tool matched at line 0, col 2.
        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(
            "alpha".into(),
            "rg",
            vec![crate::grep_pane::GrepHit {
                path: abs.clone(),
                rel: "a.txt".into(),
                line: 0,
                col: 2,
                text: "alpha".into(),
            }],
        ));
        app.panes.push(pane);
        let id = app.panes.len() - 1;
        app.layout = Layout::Leaf(id);
        app.active = Some(id);
        app.focus = Focus::Pane;

        app.jump_to_selected_grep_hit();

        // Opening the file added an editor pane and focused it.
        assert!(matches!(
            app.active.and_then(|i| app.panes.get(i)),
            Some(Pane::Editor(b)) if b.is_at(&abs)
        ));
        let buf = app.active_editor().unwrap();
        assert_eq!(buf.editor.row_col(), (0, 2));
    }

    #[test]
    fn grep_replace_writes_open_buffer_and_disk() {
        // Two files, both contain `foo`. Open one as an editor (clean), leave
        // the other on disk only. `run_grep_replace("BAR")` should rewrite
        // both, replacing every match.
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "foo bar foo").unwrap();
        fs::write(d.path().join("b.txt"), "say foo loud").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let a = app.workspace.join("a.txt");
        let b = app.workspace.join("b.txt");
        app.open_path(&a); // a.txt now open as a clean editor

        // Seed a Pane::Grep with hits for both files (positions don't need to
        // be real — `run_grep_replace` re-derives matches via find_all_ci_ascii).
        let mk_hit = |path: &Path, rel: &str| crate::grep_pane::GrepHit {
            path: path.to_path_buf(),
            rel: rel.into(),
            line: 0,
            col: 0,
            text: "".into(),
        };
        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(
            "foo".into(),
            "rg",
            vec![mk_hit(&a, "a.txt"), mk_hit(&b, "b.txt")],
        ));
        app.panes.push(pane);
        let grep_id = app.panes.len() - 1;
        // Make the grep pane the active one (so run_grep_replace targets it).
        app.layout = Layout::Leaf(grep_id);
        app.active = Some(grep_id);

        app.run_grep_replace("BAR".into());

        // a.txt was open + clean ⇒ the buffer + disk both updated.
        let a_buf = app
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&a) => Some(b),
                _ => None,
            })
            .unwrap();
        assert_eq!(a_buf.editor.text(), "BAR bar BAR");
        assert!(!a_buf.dirty); // saved through to disk
        assert_eq!(fs::read_to_string(&a).unwrap(), "BAR bar BAR");

        // b.txt was disk-only ⇒ just the disk got rewritten.
        assert_eq!(fs::read_to_string(&b).unwrap(), "say BAR loud");
    }

    #[test]
    fn grep_replace_skips_dirty_open_buffer() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "foo").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let a = app.workspace.join("a.txt");
        app.open_path(&a);
        // Make the buffer dirty (without changing the matched text).
        if let Some(Pane::Editor(b)) = app
            .panes
            .iter_mut()
            .find(|p| matches!(p, Pane::Editor(b) if b.is_at(&a)))
        {
            b.editor.place_cursor(0, 3);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::InsertStr("!".into())],
                &mut Clipboard::new(),
                0,
            );
        }

        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(
            "foo".into(),
            "rg",
            vec![crate::grep_pane::GrepHit {
                path: a.clone(),
                rel: "a.txt".into(),
                line: 0,
                col: 0,
                text: "".into(),
            }],
        ));
        app.panes.push(pane);
        let grep_id = app.panes.len() - 1;
        app.layout = Layout::Leaf(grep_id);
        app.active = Some(grep_id);

        app.run_grep_replace("BAR".into());

        // Disk is untouched (the dirty buffer was skipped).
        assert_eq!(fs::read_to_string(&a).unwrap(), "foo");
    }

    #[test]
    fn parse_substitute_parses_basic_shapes() {
        let s = parse_substitute("%s/foo/bar/g").unwrap();
        assert_eq!(s.find, "foo");
        assert_eq!(s.replace, "bar");
        assert!(!s.case_insensitive);

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

        // Empty find ⇒ None.
        assert!(parse_substitute("%s//bar/").is_none());
        // Not a substitute at all ⇒ None.
        assert!(parse_substitute("w").is_none());
        assert!(parse_substitute("qa").is_none());
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

        // Simulate a drag — clamps to [8, 180].
        app.dragging_tree_edge = true;
        app.drag_tree_edge_to(50, 200);
        assert_eq!(app.tree_width, 50);
        app.drag_tree_edge_to(2, 200);
        assert_eq!(app.tree_width, 8);
        app.drag_tree_edge_to(220, 200);
        assert_eq!(app.tree_width, 180);
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
    fn request_pane_save_writes_curl_back_to_source() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("hello.curl");
        std::fs::write(&src, "curl 'https://x/'\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Build a Request pane manually (no real HTTP send — we just want to
        // exercise the save-back path).
        let (cmd_tx, _cmd_rx) = std::sync::mpsc::channel::<crate::cdp::CdpCommand>();
        let _ = cmd_tx; // silence unused; we don't have a worker
        let req = crate::http::Request {
            method: "POST".into(),
            url: "https://example.test/v1".into(),
            headers: vec![("Accept".into(), "application/json".into())],
            body: Some(r#"{"q":1}"#.into()),
        };
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            Some(src.clone()),
            req,
            crate::http::script::Script::default(),
            1,
        ));
        app.panes.push(pane);
        app.active = Some(app.panes.len() - 1);
        app.save_request_to_source();
        let on_disk = std::fs::read_to_string(&src).unwrap();
        assert!(on_disk.contains("curl 'https://example.test/v1'"));
        // POST + --data-raw lets curl infer POST, so `-X POST` is omitted.
        assert!(on_disk.contains("Accept: application/json"));
        assert!(on_disk.contains(r#"--data-raw '{"q":1}'"#));
    }

    #[test]
    fn git_rail_section_toggles_focus_rail() {
        let (_d, mut app) = app_with_files();
        // Both sections start expanded; collapse + re-expand each and
        // verify the rail keyboard parks on the section just expanded.
        assert!(app.tree_root_expanded);
        assert!(app.git_section_expanded);
        app.toggle_tree_root_expanded(); // collapse
        assert!(!app.tree_root_expanded);
        app.toggle_git_section_expanded(); // collapse
        assert!(!app.git_section_expanded);
        app.toggle_git_section_expanded(); // expand
        assert!(app.git_section_expanded);
        assert_eq!(app.rail_section, RailSection::Git);
        assert_eq!(app.focus, Focus::Tree);
        app.toggle_tree_root_expanded(); // expand
        assert_eq!(app.rail_section, RailSection::Workspace);
    }

    #[test]
    fn click_git_rail_branch_routes_to_checkout() {
        // No `git` available in the sandbox is fine — we just seed the rail
        // directly + verify the click handler routes to the checkout call.
        let (_d, mut app) = app_with_files();
        app.git_rail.branches = vec![
            crate::git::rail::BranchRow {
                name: "main".into(),
                is_current: true,
            },
            crate::git::rail::BranchRow {
                name: "feature/x".into(),
                is_current: false,
            },
        ];
        app.git_rail.current_branch = Some("main".into());

        // Click the current branch → toasts "already checked out", no crash.
        app.click_git_rail(crate::git::rail::GitRailHit::Branch(0));
        assert_eq!(app.rail_section, RailSection::Git);
        assert!(app.git_rail.selected() == Some(crate::git::rail::GitRailHit::Branch(0)));

        // Click the other branch → would shell out to `git checkout`; the
        // workspace isn't a repo so we just verify the cursor moved.
        app.click_git_rail(crate::git::rail::GitRailHit::Branch(1));
        assert_eq!(
            app.git_rail.selected(),
            Some(crate::git::rail::GitRailHit::Branch(1))
        );
    }

    #[test]
    fn right_click_git_rail_branch_opens_menu_with_actions() {
        use crate::context_menu::MenuAction;
        let (_d, mut app) = app_with_files();
        app.git_rail.branches = vec![
            crate::git::rail::BranchRow {
                name: "main".into(),
                is_current: true,
            },
            crate::git::rail::BranchRow {
                name: "topic".into(),
                is_current: false,
            },
        ];
        app.git_rail.current_branch = Some("main".into());

        // Right-click the *current* branch ⇒ only "New branch from here…".
        app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Branch(0), (0, 0));
        let m = app.context_menu.as_ref().unwrap();
        assert_eq!(m.items.len(), 1);
        assert!(matches!(m.items[0].action, MenuAction::GitNewBranchFrom(_)));

        // Right-click a non-current branch ⇒ Checkout / New / Delete.
        app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Branch(1), (0, 0));
        let m = app.context_menu.as_ref().unwrap();
        assert_eq!(m.items.len(), 3);
        assert!(matches!(
            m.items[0].action,
            MenuAction::GitCheckoutBranch(ref n) if n == "topic"
        ));
        assert!(matches!(m.items[2].action, MenuAction::GitDeleteBranch(_)));
    }

    #[test]
    fn session_round_trips_git_section_expanded() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app.git_section_expanded);
        app.git_section_expanded = false;
        app.save_session_on_quit();
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Pre-restore: runtime default is true.
        assert!(app2.git_section_expanded);
        app2.try_restore_session();
        assert!(!app2.git_section_expanded);
    }

    #[test]
    fn code_action_reply_opens_picker_and_apply_runs_edits() {
        // No LSP server needed — we drive `apply_code_action_reply` directly
        // with synthesized actions, then walk the picker → `apply_code_action`
        // path to confirm the edit is applied to an open buffer.
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("x.rs"), "let x = 1;\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let path = app.workspace.join("x.rs");
        app.open_path(&path);

        // Build a fake code-action reply: a single quickfix that replaces
        // "let x = 1;" with "let y = 1;".
        let edit_range = crate::lsp::Range {
            start: crate::lsp::Pos {
                line: 0,
                character: 4,
            },
            end: crate::lsp::Pos {
                line: 0,
                character: 5,
            },
        };
        let action = crate::lsp::CodeAction {
            title: "rename x → y".into(),
            kind: Some("quickfix".into()),
            edit: Some(vec![(path.clone(), vec![(edit_range, "y".into())])]),
            command: None,
        };
        app.apply_code_action_reply(vec![action]);

        // The picker should be open + populated.
        let pk = app.picker.as_ref().expect("picker opened");
        assert_eq!(pk.kind, crate::picker::PickerKind::CodeActions);
        assert_eq!(pk.len(), 1);
        // No items selected matter (only one) — accept it.
        app.picker_accept();

        // The open editor should reflect the edit (left dirty for review).
        let b = app.active_editor().unwrap();
        assert_eq!(b.editor.text(), "let y = 1;\n");
        assert!(b.dirty);
    }

    #[test]
    fn splice_http_block_preserves_other_blocks() {
        let src = "\
### one
GET https://example.com/one

### two
POST https://example.com/two
Content-Type: application/json

{\"a\": 1}

### three
GET https://example.com/three
";
        let new_two = "### two\nPUT https://example.com/two-EDITED\n";
        let out = splice_http_block(src, Some("two"), new_two).unwrap();
        // The other blocks survive verbatim.
        assert!(out.contains("### one\nGET https://example.com/one"));
        assert!(out.contains("### three\nGET https://example.com/three"));
        // The target block is the edited one, not the original.
        assert!(out.contains("PUT https://example.com/two-EDITED"));
        assert!(!out.contains("POST https://example.com/two"));
        // Trailing-newline policy preserved.
        assert!(out.ends_with('\n'));
    }

    #[test]
    fn splice_http_block_returns_none_for_single_block() {
        let src = "GET https://example.com\n";
        let new_text = "### x\nPUT https://example.com\n";
        // Single-block file ⇒ caller falls back to whole-file overwrite.
        assert!(splice_http_block(src, Some("x"), new_text).is_none());
    }

    #[test]
    fn splice_http_block_returns_none_when_name_missing() {
        let src = "\
### a
GET https://example.com/a

### b
GET https://example.com/b
";
        // No block named "missing" ⇒ caller falls back to overwrite (which the
        // user would notice is destructive — better than silently editing the
        // wrong block).
        assert!(splice_http_block(src, Some("missing"), "### missing\nGET x\n").is_none());
    }

    #[test]
    fn splice_http_block_handles_unnamed_leading_block() {
        // The leading block in a multi-block .http file may not have a `###`
        // separator. Editing it shouldn't disturb the named blocks below.
        let src = "\
GET https://example.com/leading

### second
GET https://example.com/second
";
        // The unnamed leading block: matched with `Some(\"\")`? No — by the
        // capture rule it gets `None` (no `###` separator at all). The save
        // path won't reach `splice_http_block` for None, so this test
        // documents what `splice_http_block` does in case it's called: it
        // matches the block whose start_line has no `###` prefix.
        let new_text = "PUT https://example.com/leading-EDITED\n";
        let out = splice_http_block(src, None, new_text).unwrap();
        assert!(out.contains("PUT https://example.com/leading-EDITED"));
        assert!(out.contains("### second\nGET https://example.com/second"));
        assert!(!out.contains("GET https://example.com/leading\n"));
    }
}
