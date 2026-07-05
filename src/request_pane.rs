//! `Pane::Request` — a request fired from a `.http` / `.curl` / `.rest` editor
//! (the `http.send` command), with its response below: status line, headers,
//! pretty-printed body, and `@assert` / `@capture` results. The send runs on a
//! background thread; [`crate::app::App::tick`] polls the result channel and
//! flips the pane from [`RunState::Sending`] to `Done` / `Failed`.
//!
//! **Editable form fields.** A `Tab` keypress flips between
//! [`ViewMode::Response`] (the read-only view of the last send) and
//! [`ViewMode::Edit`], where the URL, method, and body are editable in place.
//! In Edit mode `Shift+Tab` / `Tab` cycle which field has the caret; typing /
//! backspace / arrows / Home / End edit the focused field; `Space` on Method
//! cycles through the standard verbs; `r` re-fires the request using the
//! current field values (so you can tweak a URL and re-send without flipping
//! back to the source file). Headers stay read-only in this first cut — the
//! list-of-pairs UI is heavier and lands in a follow-up.

use std::path::PathBuf;
use std::time::Duration;

use crate::http::Request;
use crate::http::script::{AssertionResult, Script};

pub struct RequestPane {
    /// The `.http`/`.curl`/`.rest` file the request was launched from (title only).
    pub source_path: Option<PathBuf>,
    /// Name of the source block this request came from, if the source file is
    /// multi-block (`### name` separator). `Some("")` for an unnamed block in a
    /// multi-block file (the `###` separator alone). `None` for single-block
    /// files (`.curl`, or `.http` with no `###` separators) — those overwrite
    /// the whole file on save. Used by `App::save_request_to_source` to do
    /// format-preserving writeback that only edits the matched block.
    pub source_block_name: Option<String>,
    /// The request being sent — templates already expanded, `@set-*` already
    /// applied. **Mutable from the Edit view**: the URL/method/body field
    /// editors mutate this directly so the next `r` re-fires with the edits.
    pub request: Request,
    /// Directives parsed from the same source (re-run on every send).
    pub script: Script,
    /// Set when this pane fires a send, matched against the worker's reply so a
    /// stale result (pane re-fired, or indices shifted) is ignored.
    pub job_id: u64,
    pub state: RunState,
    /// Top rendered row.
    pub scroll: usize,
    /// Which view is up — the Response (read-only) or the Edit form.
    pub view: ViewMode,
    /// Focused field in Edit mode.
    pub focus: EditField,
    /// Byte-offset caret for the URL field (always at a char boundary).
    pub url_cursor: usize,
    /// Byte-offset caret for the Body field. `request.body` is created on
    /// first body keystroke if it was `None`.
    pub body_cursor: usize,
    /// Editable text representation of the headers — `Key: Value` per line.
    /// Source of truth in Edit mode; parsed back into `request.headers` via
    /// [`Self::commit_headers`] before each send.
    pub headers_buffer: String,
    /// Byte-offset caret for the Headers field.
    pub headers_cursor: usize,
    /// Which tab the Edit view is showing. The tab strip (Body /
    /// Headers / Params / Vars / Source) sits above the per-tab
    /// content area; URL + Method always stay above the strip.
    /// Default = Body so the form mirrors rqst's startup tab.
    /// 2026-06-19 — added when the Edit view was restructured into
    /// a tabbed UI to match the rqst Postman-style layout.
    pub edit_tab: EditTab,
    /// Editable raw curl / `.http` source. Lives only as long as
    /// the pane (not persisted to disk). Typing on the Source tab
    /// appends here; `:http.paste_curl` with an empty clipboard
    /// falls back to parsing this buffer, populating the
    /// structured fields, then clearing.
    pub source_buffer: String,
    pub source_cursor: usize,
    /// The previous Done response (if any). Saved off when a new
    /// send completes — lets `:http.diff_last_two` compare the
    /// current Done against this snapshot. Cleared on a fresh
    /// :http.new or paste_curl that overwrites the request.
    pub prev_response: Option<Box<ResponseView>>,
    /// Case-insensitive substring filter applied to header rows
    /// (Edit-tab Headers list, request-summary headers, response
    /// headers). Empty ⇒ show all. Set by `/` in the pane; matches
    /// the sidebar-filter idiom used across Integrations / Agents /
    /// Settings. (#11)
    pub filter: String,
    /// `/` in the pane focuses the filter input; typing appends;
    /// Esc clears + unfocuses; Enter commits + unfocuses.
    pub filter_focused: bool,
    /// Wrap response body lines instead of clipping. Toggled by the
    /// `wrap` chip in the response section header (or `w` in Response
    /// view). Off by default so JSON keeps its raw line breaks. (#11)
    pub body_wrap: bool,
    /// Currently-hovered Params-row key. Set by the mouse-move
    /// handler; the row-row renderer paints it with the shared
    /// `row_highlight_menu` primitive so users see which row will
    /// react to their click. (#11 v13)
    pub hover_params_key: Option<String>,
    /// Currently-hovered Vars-row key (same shape as
    /// `hover_params_key`).
    pub hover_vars_key: Option<String>,
    /// Currently-hovered Auth-row id (same shape).
    pub hover_auth_id: Option<String>,
    /// Orientation of the Request/Response split within the pane.
    /// Vertical = stacked (Request top, Response bottom — default);
    /// Horizontal = side-by-side (Request left, Response right).
    /// Toggled by the `[ ▤ | ▥ ]` chip on the Request block's title
    /// bar or the `Ctrl+\` chord. AI zone stays pinned to the pane's
    /// bottom regardless.
    pub split_orientation: SplitOrientation,
    /// Currently-active Response sub-tab (Body / Headers / Timeline
    /// / Tests). Persists on the pane so a user's choice sticks
    /// across re-fires.
    pub response_tab: ResponseTab,
    /// Inline params-add editor. `None` when idle. `Some(...)` when
    /// the user clicked "+ Add new parameter" — renders as an
    /// editable row at the bottom of the Params list with Tab
    /// cycling between key and value. Enter commits (appends to
    /// URL); Esc cancels.
    pub params_add: Option<InlineKvDraft>,
    /// Inline headers-add editor. Same shape as `params_add` —
    /// Bruno-style key/value inline row. Enter commits (appends
    /// `Name: value\n` to `headers_buffer`); Esc cancels.
    pub headers_add: Option<InlineKvDraft>,
    /// In-place value-cell edit on an existing Params or Headers
    /// row. Populated when the user clicks a value cell.
    pub kv_edit: Option<KvValueEdit>,
}

/// Draft state for an inline "add a new key/value pair" editor.
/// Shared by the Params and Headers tabs — Bruno-style: key field
/// on the left, value on the right, Tab cycles focus.
#[derive(Debug, Default, Clone)]
pub struct InlineKvDraft {
    pub key: String,
    pub value: String,
    pub key_cursor: usize,
    pub value_cursor: usize,
    /// `true` when the caret is on the value field; `false` on key.
    pub on_value: bool,
}

/// Backwards-compat alias — old code called this `ParamsAddDraft`.
pub type ParamsAddDraft = InlineKvDraft;

/// State for in-place edit of an existing Params or Headers row's
/// VALUE cell. Click a value cell → set this; type / backspace
/// modifies `buffer`; Enter commits (replaces the value in the URL
/// query string or `headers_buffer`); Esc cancels.
#[derive(Debug, Clone)]
pub struct KvValueEdit {
    /// Which tab this edit belongs to. Guards the commit path so
    /// a Params edit doesn't accidentally rewrite a header.
    pub kind: KvEditKind,
    /// Original key of the row — used to locate the entry to
    /// replace when the user commits. If the row was deleted or
    /// renamed under us, commit becomes a no-op.
    pub original_key: String,
    /// Current buffer contents. Renders as the value cell text.
    pub buffer: String,
    pub cursor: usize,
}

/// Which KV table an in-place edit targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KvEditKind {
    Params,
    Headers,
}

/// Two-way orientation for the Request/Response zones inside a
/// single Request pane. Kept on the pane so orientation persists
/// across renders + tab switches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitOrientation {
    Vertical,
    Horizontal,
}

impl SplitOrientation {
    pub fn toggle(self) -> Self {
        match self {
            SplitOrientation::Vertical => SplitOrientation::Horizontal,
            SplitOrientation::Horizontal => SplitOrientation::Vertical,
        }
    }
}

/// Sub-tabs inside the Response zone — mirrors Bruno's Response
/// pane (Body / Headers / Timeline / Tests). Kept on the
/// `RequestPane` so the user's choice persists across renders.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponseTab {
    Body,
    Headers,
    Timeline,
    Tests,
}

impl ResponseTab {
    pub const ALL: &'static [ResponseTab] = &[
        ResponseTab::Body,
        ResponseTab::Headers,
        ResponseTab::Timeline,
        ResponseTab::Tests,
    ];
    pub fn label(self) -> &'static str {
        match self {
            ResponseTab::Body => "Body",
            ResponseTab::Headers => "Headers",
            ResponseTab::Timeline => "Timeline",
            ResponseTab::Tests => "Tests",
        }
    }
    pub fn next(self) -> Self {
        let i = Self::ALL.iter().position(|t| *t == self).unwrap_or(0);
        Self::ALL[(i + 1) % Self::ALL.len()]
    }
    pub fn prev(self) -> Self {
        let i = Self::ALL.iter().position(|t| *t == self).unwrap_or(0);
        Self::ALL[(i + Self::ALL.len() - 1) % Self::ALL.len()]
    }
}

/// The tabbed UI on the Edit view. `Tab` advances; `Shift+Tab`
/// retreats. Mouse-clickable. The URL + Method row always stays
/// visible above the strip; only the area below switches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditTab {
    Body,
    Headers,
    Params,
    Auth,
    Vars,
    Source,
}

impl EditTab {
    // Bruno-style tab order — Params leads (what most REST-client
    // users tweak first), Body next, then structural fields.
    // Source is labeled "Script" to match Bruno's terminology (mnml
    // uses it for the raw .http source view; the naming just
    // parallels Bruno's Script tab).
    pub const ALL: &'static [EditTab] = &[
        EditTab::Params,
        EditTab::Body,
        EditTab::Headers,
        EditTab::Auth,
        EditTab::Vars,
        EditTab::Source,
    ];
    pub fn label(self) -> &'static str {
        match self {
            EditTab::Body => "Body",
            EditTab::Headers => "Headers",
            EditTab::Params => "Params",
            EditTab::Auth => "Auth",
            EditTab::Vars => "Vars",
            EditTab::Source => "Script",
        }
    }
    pub fn next(self) -> Self {
        let i = Self::ALL.iter().position(|t| *t == self).unwrap_or(0);
        Self::ALL[(i + 1) % Self::ALL.len()]
    }
    pub fn prev(self) -> Self {
        let i = Self::ALL.iter().position(|t| *t == self).unwrap_or(0);
        Self::ALL[(i + Self::ALL.len() - 1) % Self::ALL.len()]
    }
}

/// Which face of the request pane is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewMode {
    /// The send's result — status / headers / body / asserts / captures.
    Response,
    /// The editable request form — URL, method, body.
    Edit,
}

/// The currently-edited field in [`ViewMode::Edit`]. Cycled by Tab / Shift-Tab.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditField {
    Url,
    Method,
    Headers,
    Body,
    /// 2026-06-19 v2 — Source-tab editable buffer. Typing populates
    /// `source_buffer`; Ctrl+Enter (or `:http.paste_curl` with
    /// empty clipboard fall-back) parses the buffer into the
    /// structured Method/URL/Headers/Body fields.
    Source,
}

impl EditField {
    pub fn next(self) -> Self {
        match self {
            EditField::Url => EditField::Method,
            EditField::Method => EditField::Headers,
            EditField::Headers => EditField::Body,
            EditField::Body => EditField::Url,
            // Source is reached only when the Source tab is active;
            // Tab from Source cycles back to URL (out of the Source
            // tab implicitly via re-render with the new focus).
            EditField::Source => EditField::Url,
        }
    }
    pub fn prev(self) -> Self {
        match self {
            EditField::Url => EditField::Body,
            EditField::Method => EditField::Url,
            EditField::Headers => EditField::Method,
            EditField::Body => EditField::Headers,
            EditField::Source => EditField::Body,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            EditField::Url => "URL",
            EditField::Method => "Method",
            EditField::Headers => "Headers",
            EditField::Body => "Body",
            EditField::Source => "Source",
        }
    }
}

/// Serialise headers as `Key: Value\n…` for the editable text buffer.
pub fn headers_to_text(headers: &[(String, String)]) -> String {
    headers
        .iter()
        .map(|(k, v)| format!("{k}: {v}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Parse the editable headers buffer back into `Vec<(name, value)>`. Lines
/// without a `:` are dropped; whitespace around the name and value is
/// trimmed. Blank lines are skipped. Header *names* are lower-cased? No —
/// preserved as typed, like the other parsers in `crate::http`.
pub fn parse_headers_text(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let l = l.trim();
            if l.is_empty() || l.starts_with('#') {
                return None;
            }
            let (k, v) = l.split_once(':')?;
            let k = k.trim();
            let v = v.trim();
            if k.is_empty() {
                None
            } else {
                Some((k.to_string(), v.to_string()))
            }
        })
        .collect()
}

/// The standard HTTP verbs the Method field cycles through. `Space` advances
/// to the next; if the field's current value isn't in this set (it came from
/// a `.http`/`.curl` file with something unusual), the first cycle lands on
/// the value after the closest match — practically the same as starting from
/// GET, which is fine.
pub const STANDARD_METHODS: &[&str] = &["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];

pub fn cycle_method(current: &str) -> String {
    let cur = current.trim().to_ascii_uppercase();
    let idx = STANDARD_METHODS
        .iter()
        .position(|m| **m == cur)
        .unwrap_or(0);
    let next = (idx + 1) % STANDARD_METHODS.len();
    STANDARD_METHODS[next].to_string()
}

pub enum RunState {
    Sending,
    /// 2026-06-20 — SSE progressive display. Stream is open and
    /// events have started arriving; mutating `partial.body` as
    /// each event lands. Flips to `Done` on stream close.
    Streaming(Box<ResponseView>),
    Done(Box<ResponseView>),
    Failed(String),
}

/// Progressive SSE stream messages. Worker thread sends Open
/// → Event* → Close. App.tick drains and mutates the matching
/// Request pane's Streaming state. job_id matches RequestPane.job_id.
pub enum SseStreamMsg {
    Open {
        job_id: u64,
        status: u16,
        status_text: String,
        headers: Vec<(String, String)>,
        started: std::time::Instant,
    },
    Event {
        job_id: u64,
        name: String,
        data: String,
    },
    Close {
        job_id: u64,
    },
    Error {
        job_id: u64,
        error: String,
    },
}

#[derive(Clone)]
pub struct ResponseView {
    pub status: u16,
    pub status_text: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub elapsed: Duration,
    /// Per-phase timing carried through from `http::Response`.
    /// Currently split into `wait` (send → headers received) and
    /// `receive` (body read).
    pub timing: crate::http::Timing,
    pub assertions: Vec<AssertionResult>,
    pub captures: Vec<(String, String)>,
    /// Result of validating the response body against a sibling
    /// `*.schema.json` file (if one exists). `None` if validation
    /// wasn't attempted (e.g. response from the browser pane with
    /// no source file). The Response view renders a one-line
    /// "Schema: ✓ valid" / "Schema: ✗ N errors" footer when this
    /// is `Some`.
    pub schema_result: Option<crate::http::schema::SchemaResult>,
    /// 2026-06-21 api-workflow SEV-2 — proper SSE event counter
    /// for streaming responses. Was previously emulated by pushing
    /// empty `("", "")` tuples into `captures` and clearing on
    /// close — which silently dropped any real `@capture` results.
    pub sse_event_count: u32,
}

impl RequestPane {
    pub fn new(
        source_path: Option<PathBuf>,
        request: Request,
        script: Script,
        job_id: u64,
    ) -> Self {
        let url_cursor = request.url.len();
        let body_cursor = request.body.as_deref().map(str::len).unwrap_or(0);
        let headers_buffer = headers_to_text(&request.headers);
        let headers_cursor = headers_buffer.len();
        RequestPane {
            source_path,
            source_block_name: None,
            request,
            script,
            job_id,
            state: RunState::Sending,
            scroll: 0,
            view: ViewMode::Response,
            focus: EditField::Url,
            url_cursor,
            body_cursor,
            headers_buffer,
            headers_cursor,
            edit_tab: EditTab::Body,
            source_buffer: String::new(),
            source_cursor: 0,
            prev_response: None,
            filter: String::new(),
            filter_focused: false,
            body_wrap: false,
            hover_params_key: None,
            hover_vars_key: None,
            hover_auth_id: None,
            split_orientation: SplitOrientation::Vertical,
            response_tab: ResponseTab::Body,
            params_add: None,
            headers_add: None,
            kv_edit: None,
        }
    }

    /// Render this request as an `.http` block — what
    /// `App::save_request_to_source` writes back into multi-block source files.
    /// `name` (without leading `###`) controls the leading separator: `Some(s)`
    /// emits `### s` (or bare `###` when `s.is_empty()`); `None` skips the
    /// separator entirely (used when the matched block had no `###` prefix).
    pub fn as_http_block(&self, name: Option<&str>) -> String {
        let mut out = String::new();
        if let Some(n) = name {
            if n.is_empty() {
                out.push_str("###\n");
            } else {
                out.push_str("### ");
                out.push_str(n);
                out.push('\n');
            }
        }
        out.push_str(&self.request.method);
        out.push(' ');
        out.push_str(&self.request.url);
        out.push('\n');
        for (k, v) in &self.request.headers {
            out.push_str(k);
            out.push_str(": ");
            out.push_str(v);
            out.push('\n');
        }
        if let Some(body) = &self.request.body {
            out.push('\n');
            out.push_str(body);
            if !body.ends_with('\n') {
                out.push('\n');
            }
        }
        out
    }

    /// Parse the editable `headers_buffer` back into `request.headers`. Called
    /// before each send so the in-flight request reflects the user's edits.
    /// In Response mode (where `headers_buffer` is still tracking the original
    /// list) this is a no-op as long as the buffer matches.
    pub fn commit_headers(&mut self) {
        self.request.headers = parse_headers_text(&self.headers_buffer);
    }

    /// Flip between the read-only Response view and the editable form. Resets
    /// focus to the URL field every time you enter Edit (more predictable
    /// than remembering which field you were on last).
    pub fn toggle_view(&mut self) {
        self.view = match self.view {
            ViewMode::Response => ViewMode::Edit,
            ViewMode::Edit => ViewMode::Response,
        };
        if self.view == ViewMode::Edit {
            self.focus = EditField::Url;
        }
    }
    pub fn focus_next_field(&mut self) {
        self.focus = self.focus.next();
    }
    pub fn focus_prev_field(&mut self) {
        self.focus = self.focus.prev();
    }

    /// Mutable handle to the focused field's `(text, cursor)`. Returns `None`
    /// for Method — that field is cycled via [`cycle_method`], not typed into.
    fn focused_text_mut(&mut self) -> Option<(&mut String, &mut usize)> {
        match self.focus {
            EditField::Url => Some((&mut self.request.url, &mut self.url_cursor)),
            EditField::Method => None,
            EditField::Headers => Some((&mut self.headers_buffer, &mut self.headers_cursor)),
            EditField::Body => {
                // Lazily create an empty body on first edit.
                let body = self.request.body.get_or_insert_with(String::new);
                Some((body, &mut self.body_cursor))
            }
            EditField::Source => Some((&mut self.source_buffer, &mut self.source_cursor)),
        }
    }

    /// Insert one character at the focused field's cursor. URL strips newlines
    /// (single-line field); Headers + Body accept them.
    pub fn type_char(&mut self, c: char) {
        if self.focus == EditField::Method {
            if c == ' ' {
                self.request.method = cycle_method(&self.request.method);
            }
            return;
        }
        let single_line = self.focus == EditField::Url;
        if single_line && c == '\n' {
            return;
        }
        let Some((s, cur)) = self.focused_text_mut() else {
            return;
        };
        let pos = (*cur).min(s.len());
        s.insert(pos, c);
        *cur = pos + c.len_utf8();
    }

    /// Backspace at the focused field's caret.
    pub fn backspace(&mut self) {
        let Some((s, cur)) = self.focused_text_mut() else {
            return;
        };
        if *cur == 0 || s.is_empty() {
            return;
        }
        let prev = s[..*cur]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        s.replace_range(prev..*cur, "");
        *cur = prev;
    }

    /// Move the focused field's caret left one char (no-op for Method).
    pub fn move_left(&mut self) {
        let Some((s, cur)) = self.focused_text_mut() else {
            return;
        };
        if *cur == 0 {
            return;
        }
        *cur = s[..*cur]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    /// Move the focused field's caret right one char.
    pub fn move_right(&mut self) {
        let Some((s, cur)) = self.focused_text_mut() else {
            return;
        };
        if *cur >= s.len() {
            return;
        }
        let step = s[*cur..].chars().next().map(char::len_utf8).unwrap_or(0);
        *cur += step;
    }

    pub fn move_home(&mut self) {
        match self.focus {
            EditField::Url => self.url_cursor = 0,
            EditField::Headers => {
                let cur = self.headers_cursor.min(self.headers_buffer.len());
                self.headers_cursor = self.headers_buffer[..cur]
                    .rfind('\n')
                    .map(|i| i + 1)
                    .unwrap_or(0);
            }
            EditField::Body => {
                let s = self.request.body.as_deref().unwrap_or("");
                // Home goes to the start of the current line in Body.
                let cur = self.body_cursor.min(s.len());
                self.body_cursor = s[..cur].rfind('\n').map(|i| i + 1).unwrap_or(0);
            }
            EditField::Source => {
                let s = self.source_buffer.as_str();
                let cur = self.source_cursor.min(s.len());
                self.source_cursor = s[..cur].rfind('\n').map(|i| i + 1).unwrap_or(0);
            }
            EditField::Method => {}
        }
    }
    pub fn move_end(&mut self) {
        match self.focus {
            EditField::Url => self.url_cursor = self.request.url.len(),
            EditField::Headers => {
                let cur = self.headers_cursor.min(self.headers_buffer.len());
                let to_eol = self.headers_buffer[cur..]
                    .find('\n')
                    .unwrap_or(self.headers_buffer.len() - cur);
                self.headers_cursor = cur + to_eol;
            }
            EditField::Body => {
                let s = self.request.body.as_deref().unwrap_or("");
                let cur = self.body_cursor.min(s.len());
                let to_end_of_line = s[cur..].find('\n').unwrap_or(s.len() - cur);
                self.body_cursor = cur + to_end_of_line;
            }
            EditField::Source => {
                let s = self.source_buffer.as_str();
                let cur = self.source_cursor.min(s.len());
                let to_eol = s[cur..].find('\n').unwrap_or(s.len() - cur);
                self.source_cursor = cur + to_eol;
            }
            EditField::Method => {}
        }
    }

    pub fn title(&self) -> String {
        // Bruno-style tab label: `METHOD  short-url` when a URL is
        // set. Falls back to source-file basename (or "request")
        // when there's no URL yet. Method comes first so the
        // per-verb tab coloring (bufferline picks the icon +
        // fg color from `request.method`) reads as a chip prefix.
        let method = self.request.method.to_uppercase();
        let base = if !self.request.url.is_empty() {
            let short = self
                .request
                .url
                .strip_prefix("https://")
                .or_else(|| self.request.url.strip_prefix("http://"))
                .unwrap_or(&self.request.url);
            let short = short.split(['?', '#']).next().unwrap_or(short);
            format!("{method}  {short}")
        } else {
            self.source_path
                .as_ref()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| format!("{method}  new request"))
        };
        // Tab markers: only signal states the user needs to know
        // about at a glance. A clean 2xx Done state used to render
        // a `⚡` but the Response block already shows the status
        // chip — the tab marker was just visual noise. Now:
        //   Sending  → "…" (in flight)
        //   Streaming → "▶" (SSE open)
        //   Failed assertions on Done → "✗"
        //   Everything else → no marker.
        let marker = match &self.state {
            RunState::Sending => "…",
            RunState::Streaming(_) => "▶",
            RunState::Done(r) if r.assertions.iter().any(|a| !a.passed) => "✗",
            _ => "",
        };
        if marker.is_empty() {
            base
        } else {
            format!("{base} {marker}")
        }
    }

    /// `METHOD url` as a one-liner.
    pub fn request_line(&self) -> String {
        format!("{} {}", self.request.method, self.request.url)
    }

    /// Render this request as a `curl` command line (for `http.copy_curl`).
    pub fn as_curl(&self) -> String {
        let mut out = format!("curl '{}'", self.request.url);
        if self.request.method != "GET"
            && !(self.request.method == "POST" && self.request.body.is_some())
        {
            out.push_str(&format!(" -X {}", self.request.method));
        }
        for (k, v) in &self.request.headers {
            out.push_str(&format!(" \\\n  -H '{}: {}'", k, v.replace('\'', "'\\''")));
        }
        if let Some(body) = &self.request.body {
            out.push_str(&format!(
                " \\\n  --data-raw '{}'",
                body.replace('\'', "'\\''")
            ));
        }
        out
    }

    /// Python (using the `requests` library).
    pub fn as_python(&self) -> String {
        let mut out = String::from("import requests\n\n");
        let mut headers_str = String::from("headers = {\n");
        for (k, v) in &self.request.headers {
            headers_str.push_str(&format!("    {:?}: {:?},\n", k, v));
        }
        headers_str.push_str("}\n\n");
        out.push_str(&headers_str);
        let m = self.request.method.to_lowercase();
        match &self.request.body {
            Some(body) if !body.is_empty() => {
                out.push_str(&format!("data = {body:?}\n\n"));
                out.push_str(&format!(
                    "response = requests.{m}({url:?}, headers=headers, data=data)\n",
                    url = self.request.url,
                ));
            }
            _ => {
                out.push_str(&format!(
                    "response = requests.{m}({url:?}, headers=headers)\n",
                    url = self.request.url,
                ));
            }
        }
        out.push_str("print(response.status_code)\nprint(response.text)\n");
        out
    }

    /// JavaScript (`fetch` API).
    pub fn as_js_fetch(&self) -> String {
        let mut out = format!(
            "const response = await fetch({url:?}, {{\n  method: {m:?},\n",
            url = self.request.url,
            m = self.request.method,
        );
        out.push_str("  headers: {\n");
        for (k, v) in &self.request.headers {
            out.push_str(&format!("    {k:?}: {v:?},\n"));
        }
        out.push_str("  },\n");
        if let Some(body) = &self.request.body
            && !body.is_empty()
        {
            out.push_str(&format!("  body: {body:?},\n"));
        }
        out.push_str(
            "});\nconst data = await response.text();\nconsole.log(response.status, data);\n",
        );
        out
    }

    /// Go (net/http).
    pub fn as_go(&self) -> String {
        let mut out = String::from(
            "package main\n\nimport (\n\t\"fmt\"\n\t\"io\"\n\t\"net/http\"\n\t\"strings\"\n)\n\nfunc main() {\n",
        );
        let body_expr = if let Some(b) = &self.request.body {
            format!("strings.NewReader({b:?})")
        } else {
            "nil".to_string()
        };
        out.push_str(&format!(
            "\treq, err := http.NewRequest({m:?}, {url:?}, {body})\n\tif err != nil {{ panic(err) }}\n",
            m = self.request.method,
            url = self.request.url,
            body = body_expr,
        ));
        for (k, v) in &self.request.headers {
            out.push_str(&format!("\treq.Header.Set({k:?}, {v:?})\n"));
        }
        out.push_str(
            "\tresp, err := http.DefaultClient.Do(req)\n\tif err != nil {{ panic(err) }}\n\tdefer resp.Body.Close()\n\tbody, _ := io.ReadAll(resp.Body)\n\tfmt.Println(resp.Status)\n\tfmt.Println(string(body))\n}\n",
        );
        out
    }

    /// wget one-liner.
    pub fn as_wget(&self) -> String {
        let mut out = format!(
            "wget --method={} '{}'",
            self.request.method, self.request.url
        );
        for (k, v) in &self.request.headers {
            out.push_str(&format!(
                " \\\n  --header='{}: {}'",
                k,
                v.replace('\'', "'\\''"),
            ));
        }
        if let Some(body) = &self.request.body {
            out.push_str(&format!(
                " \\\n  --body-data='{}'",
                body.replace('\'', "'\\''"),
            ));
        }
        out
    }

    /// HTTPie one-liner.
    pub fn as_httpie(&self) -> String {
        let mut out = format!("http {} '{}'", self.request.method, self.request.url);
        for (k, v) in &self.request.headers {
            out.push_str(&format!(" '{}:{}'", k, v));
        }
        if let Some(body) = &self.request.body
            && !body.is_empty()
        {
            let escaped = body.replace('\'', "'\\''");
            out.push_str(&format!(" <<< '{escaped}'"));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane() -> RequestPane {
        RequestPane::new(
            None,
            Request {
                method: "GET".into(),
                url: "https://x.com/a".into(),
                headers: Vec::new(),
                body: None,
            },
            Script::default(),
            1,
        )
    }

    #[test]
    fn toggle_view_lands_on_url_in_edit() {
        let mut p = pane();
        assert_eq!(p.view, ViewMode::Response);
        p.toggle_view();
        assert_eq!(p.view, ViewMode::Edit);
        assert_eq!(p.focus, EditField::Url);
        p.toggle_view();
        assert_eq!(p.view, ViewMode::Response);
    }

    #[test]
    fn focus_cycles_url_method_headers_body() {
        let mut p = pane();
        p.toggle_view();
        assert_eq!(p.focus, EditField::Url);
        p.focus_next_field();
        assert_eq!(p.focus, EditField::Method);
        p.focus_next_field();
        assert_eq!(p.focus, EditField::Headers);
        p.focus_next_field();
        assert_eq!(p.focus, EditField::Body);
        p.focus_next_field();
        assert_eq!(p.focus, EditField::Url);
        p.focus_prev_field();
        assert_eq!(p.focus, EditField::Body);
        p.focus_prev_field();
        assert_eq!(p.focus, EditField::Headers);
    }

    #[test]
    fn headers_round_trip_through_buffer() {
        // Build a request with two headers, drive the pane to edit them, then
        // commit + verify the parsed result.
        let req = Request {
            method: "GET".into(),
            url: "https://x/".into(),
            headers: vec![
                ("Accept".into(), "application/json".into()),
                ("Authorization".into(), "Bearer xyz".into()),
            ],
            body: None,
        };
        let mut p = RequestPane::new(None, req, Script::default(), 1);
        assert_eq!(
            p.headers_buffer,
            "Accept: application/json\nAuthorization: Bearer xyz"
        );

        // Edit: focus Headers, append a new line `X-Trace: abc`.
        p.toggle_view();
        p.focus = EditField::Headers;
        p.move_end();
        p.type_char('\n');
        for c in "X-Trace: abc".chars() {
            p.type_char(c);
        }
        p.commit_headers();
        assert_eq!(p.request.headers.len(), 3);
        assert_eq!(p.request.headers[2], ("X-Trace".into(), "abc".into()));

        // Delete a line — empty the header line entirely; commit drops it.
        p.headers_buffer = "Accept: application/json\n\nAuthorization: Bearer xyz".into();
        p.commit_headers();
        assert_eq!(p.request.headers.len(), 2);

        // Lines without `:` are dropped.
        p.headers_buffer = "Accept: application/json\nthis-is-not-a-header".into();
        p.commit_headers();
        assert_eq!(p.request.headers.len(), 1);
    }

    #[test]
    fn url_field_typing_and_backspace() {
        let mut p = pane();
        p.toggle_view();
        p.move_end();
        p.type_char('?');
        p.type_char('q');
        p.type_char('=');
        p.type_char('1');
        assert_eq!(p.request.url, "https://x.com/a?q=1");
        p.backspace();
        p.backspace();
        assert_eq!(p.request.url, "https://x.com/a?q");
        // URL strips newlines (single-line field).
        p.type_char('\n');
        assert_eq!(p.request.url, "https://x.com/a?q");
    }

    #[test]
    fn body_field_creates_on_first_keystroke_and_accepts_newlines() {
        let mut p = pane();
        p.toggle_view();
        p.focus = EditField::Body;
        assert!(p.request.body.is_none());
        for c in "{\"a\":\n  1}".chars() {
            p.type_char(c);
        }
        assert_eq!(p.request.body.as_deref(), Some("{\"a\":\n  1}"));
        // Home moves to the start of the current line, not the whole body.
        p.move_home();
        assert_eq!(p.body_cursor, "{\"a\":\n".len());
    }

    #[test]
    fn method_cycles_via_space() {
        let mut p = pane();
        p.toggle_view();
        p.focus = EditField::Method;
        assert_eq!(p.request.method, "GET");
        p.type_char(' ');
        assert_eq!(p.request.method, "POST");
        p.type_char(' ');
        assert_eq!(p.request.method, "PUT");
        // Non-space typing on Method is ignored.
        p.type_char('x');
        assert_eq!(p.request.method, "PUT");
    }

    #[test]
    fn cycle_method_wraps() {
        assert_eq!(cycle_method("OPTIONS"), "GET");
        assert_eq!(cycle_method("get"), "POST");
        // Unknown method falls back to "GET" → "POST".
        assert_eq!(cycle_method("FROBNICATE"), "POST");
    }

    #[test]
    fn move_left_right_clamp() {
        let mut p = pane();
        p.toggle_view();
        let len = p.request.url.len();
        p.url_cursor = 0;
        p.move_left(); // no-op at 0
        assert_eq!(p.url_cursor, 0);
        p.url_cursor = len;
        p.move_right(); // no-op at end
        assert_eq!(p.url_cursor, len);
    }
}
