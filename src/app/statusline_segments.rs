//! Data-driven statusline chips declared by integrations.
//!
//! Two schema pieces, split at the manifest level so N chips can
//! share one poll:
//!
//!   * `[[values_sources]]` — one background thread per source
//!     runs a command on an interval, parses stdout as JSON,
//!     stashes the resulting map under the source's `id`.
//!   * `[[statusline_segments]]` — each chip references a source
//!     `id`, formats a template like `"{open}({approved})"`
//!     against the latest snapshot, renders as a right-side
//!     dynamic statusline segment.
//!
//! ## Zero domain knowledge in mnml core
//!
//! Nothing in this module hardcodes an integration id. Bitbucket,
//! Jira, and any future sibling all declare their chips through
//! the same schema. The only mnml-core work is: read the manifest,
//! poll the command, substitute the template, register the chip.
//!
//! ## Install-gate belts
//!
//! Enforced twice for a defense-in-depth:
//!   * At spawn time — a source whose parent integration is
//!     disabled or whose binary isn't on PATH never gets a worker.
//!   * At render time — a segment whose parent integration was
//!     disabled after startup is skipped (the worker's snapshot is
//!     left alone; render simply drops the chip). This makes a
//!     right-click "Disable" take effect on the next frame even if
//!     the worker is mid-flight.
//!
//! ## Templating
//!
//! `{key}` looks up `snapshot.key`; `{a.b}` walks nested objects.
//! Missing keys render as `?`. Non-string primitives (numbers,
//! bools) render via `Value::to_string` with quotes stripped.
//! `{{` and `}}` are NOT escaped — a literal brace in the format
//! is a user problem, not something the v1 template engine tries
//! to handle.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, Sender};
#[cfg(not(test))]
use std::time::Duration;

use serde_json::Value;

use crate::app::{App, SegmentSide};
use crate::integration_manifest::{IntegrationManifest, StatuslineSegment};

/// Default poll interval when a manifest doesn't set one.
pub const DEFAULT_POLL_SECS: u64 = 300;
/// Clamp floor — polling faster than this hammers the sibling
/// binary for no benefit. 30s is already generous for a statusline
/// chip whose users mostly care about "did the number move".
pub const MIN_POLL_SECS: u64 = 30;
/// Clamp ceiling — an hour-plus stale chip is worse than no chip.
pub const MAX_POLL_SECS: u64 = 3600;

/// Priority chip poll-derived segments use when we push into
/// `dynamic_segments`. Sits below the "always show" tier (200)
/// used by high-signal IPC segments but above the default (100)
/// so the chip stays visible under moderate crowding.
const RENDER_PRIORITY: u8 = 120;
/// Minimum width the packed lane will still allocate to the chip.
/// Manifests don't declare this today; a reasonable floor keeps
/// short values ("2") from being dropped alongside long ones.
const RENDER_MIN_WIDTH: u16 = 6;
/// Maximum width — longer content is ellipsized. Matches the
/// manifest `StatuslineSpec::default_max_width` for consistency
/// with the older IPC-side chips.
const RENDER_MAX_WIDTH: u16 = 30;

/// A worker's poll result — either a parsed JSON object (mapped
/// under the source id in [`App::values_source_snapshots`]) or an
/// error message (recorded on the snapshot so dependent chips can
/// render a `!` sigil).
#[derive(Debug, Clone)]
pub struct SourceUpdate {
    pub source_id: String,
    pub result: Result<HashMap<String, Value>, String>,
}

/// The last-seen values for a source id, plus a timestamp and any
/// last error message.
#[derive(Debug, Clone, Default)]
pub struct ValuesSnapshot {
    pub values: HashMap<String, Value>,
    /// Unix seconds when the snapshot was updated. `0` = never
    /// fetched successfully yet.
    pub updated_at: u64,
    /// `Some(msg)` when the most recent poll failed. Cleared on a
    /// subsequent success.
    pub last_error: Option<String>,
}

impl App {
    /// Startup + `integrations.refresh` hook — walks every
    /// `[[values_sources]]` block across every installed manifest,
    /// filters by the install gate (parent chip enabled AND binary
    /// on PATH), and spawns exactly one background poll thread per
    /// remaining source. Sources declared without any chip
    /// referencing them still get polled — the manifest opting in
    /// is the contract, not the chip count.
    ///
    /// Threads communicate via a single mpsc channel stored on
    /// [`Self::statusline_segments_rx`]. Dropping the sender at
    /// re-init time lets in-flight workers exit cleanly on their
    /// next send.
    pub fn start_statusline_segment_workers(&mut self) {
        // Snapshot the sources we want to poll, applying the
        // install gate here so a disabled chip never even spawns a
        // worker.
        let sources: Vec<(String, String, u64)> = self
            .integration_manifests
            .iter()
            .filter(|m| self.integration_chip_enabled(&m.id))
            .flat_map(|m| {
                m.values_sources
                    .iter()
                    .filter(|s| binary_from_command_on_path(&s.command))
                    .map(|s| {
                        (
                            s.id.clone(),
                            s.command.clone(),
                            clamped_interval(s.poll_interval_secs),
                        )
                    })
            })
            .collect();

        if sources.is_empty() {
            // No sources = no workers. Drop any stale channel so a
            // refresh doesn't hold onto dead threads.
            self.statusline_segments_tx = None;
            self.statusline_segments_rx = None;
            return;
        }

        // Fresh channel every re-init — old workers see the old
        // sender closed on their next send and exit.
        let (tx, rx) = mpsc::channel::<SourceUpdate>();
        self.statusline_segments_tx = Some(tx.clone());
        self.statusline_segments_rx = Some(rx);

        for (id, command, interval) in sources {
            spawn_worker(id, command, interval, tx.clone());
        }
    }

    /// Non-blocking drain of any completed poll results. Called
    /// per tick from [`App::tick`]. Applies the render-tick install
    /// gate — a chip whose parent integration was disabled after
    /// startup gets its `dynamic_segments` entry cleared even if
    /// the worker is still pushing updates.
    pub fn drain_statusline_segments(&mut self) {
        // 1. Drain any completed poll results into the snapshot map.
        let mut got_update = false;
        if let Some(rx) = self.statusline_segments_rx.as_ref() {
            loop {
                match rx.try_recv() {
                    Ok(update) => {
                        got_update = true;
                        let slot = self
                            .values_source_snapshots
                            .entry(update.source_id.clone())
                            .or_default();
                        match update.result {
                            Ok(values) => {
                                slot.values = values;
                                slot.updated_at = now_secs();
                                slot.last_error = None;
                            }
                            Err(err) => {
                                slot.last_error = Some(err);
                            }
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        // Every worker exited (should only happen
                        // after a re-init that dropped the sender).
                        // Drop the receiver so we don't loop on it.
                        self.statusline_segments_rx = None;
                        break;
                    }
                }
            }
        }

        // 2. Re-render every declared segment. We rebuild every
        // tick so an install-gate flip (right-click Disable) shows
        // up on the next frame without a dedicated invalidation
        // path. Cheap — a handful of segments times a template
        // substitution is ~microseconds.
        //
        // We collect the desired state first, THEN mutate
        // dynamic_segments — avoids overlapping borrows.
        let desired = self.compute_segment_render_state();
        self.apply_segment_render_state(desired, got_update);
    }

    /// Read side of the render pass — no `&mut self` so this can
    /// run while we're still holding a borrow of the manifest.
    fn compute_segment_render_state(&self) -> Vec<RenderedSegment> {
        let mut out: Vec<RenderedSegment> = Vec::new();
        for m in &self.integration_manifests {
            if !self.integration_chip_enabled(&m.id) {
                continue;
            }
            for seg in &m.statusline_segments {
                // Text + color depend on the source's snapshot
                // state (unavailable / errored / rendered).
                let (text, color, tooltip_extra) =
                    render_segment_text(seg, self.values_source_snapshots.get(&seg.source), m);
                out.push(RenderedSegment {
                    id: seg.id.clone(),
                    integration_id: m.id.clone(),
                    text,
                    color,
                    click_command: seg.click_command.clone(),
                    tooltip: seg.tooltip.clone(),
                    tooltip_extra,
                });
            }
        }
        out
    }

    fn apply_segment_render_state(&mut self, desired: Vec<RenderedSegment>, _got_update: bool) {
        // Track the ids we care about; anything currently in
        // `dynamic_segments` with a matching id gets updated,
        // anything else declared but not currently present is
        // pushed. On the way out, drop any segment whose id we
        // manage but that no longer appears in `desired` — e.g.
        // an integration was uninstalled between ticks.
        let managed_ids: std::collections::HashSet<String> =
            desired.iter().map(|d| d.id.clone()).collect();
        // Clear any stale managed entries first.
        // We can't distinguish IPC-set entries from manifest-set
        // entries by shape alone, so we track manages via
        // `statusline_segment_managed_ids`.
        let stale: Vec<String> = self
            .statusline_segment_managed_ids
            .iter()
            .filter(|id| !managed_ids.contains(*id))
            .cloned()
            .collect();
        for id in stale {
            self.statusline_clear_segment(&id);
            self.statusline_segment_managed_ids.remove(&id);
        }
        // Push / update. Task #965 reviewer follow-up 2026-08-17:
        // combine manifest tooltip + render-time tooltip_extra
        // ("waiting for first poll" / "last error: …") into ONE
        // tooltip body piped through the tooltip-aware setter so
        // hover-help can explain why the chip is showing what it
        // does. Prior code dropped both on the floor.
        for d in desired {
            let tooltip = match (d.tooltip.as_deref(), d.tooltip_extra.as_deref()) {
                (Some(base), Some(extra)) => Some(format!("{base}\n{extra}")),
                (Some(base), None) => Some(base.to_string()),
                (None, Some(extra)) => Some(extra.to_string()),
                (None, None) => None,
            };
            self.statusline_set_segment_full(
                d.id.clone(),
                SegmentSide::Right,
                d.text,
                Some(d.color),
                tooltip,
                d.click_command,
                RENDER_PRIORITY,
                RENDER_MIN_WIDTH,
                RENDER_MAX_WIDTH,
            );
            self.statusline_segment_managed_ids.insert(d.id);
        }
    }

    /// Chip-render install gate — returns true iff the parent
    /// integration's chip is currently enabled in
    /// `config.ui.integration_icons`. Missing icon slot → false
    /// (a manifest whose merge into config was skipped for any
    /// reason shouldn't advertise chips either).
    fn integration_chip_enabled(&self, integration_id: &str) -> bool {
        self.config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == integration_id && ic.enabled)
    }
}

/// Everything one manifest chip needs to become a
/// `DynamicSegment`. Computed each tick.
struct RenderedSegment {
    id: String,
    #[allow(dead_code)] // reserved for future per-chip disable UX
    integration_id: String,
    text: String,
    color: String,
    click_command: Option<String>,
    /// Manifest-declared base tooltip body.
    tooltip: Option<String>,
    /// Extra tooltip note appended by the render — "waiting for
    /// binary…" or "last error: …". Appended to `tooltip` before
    /// piping to `statusline_set_segment_full`.
    tooltip_extra: Option<String>,
}

/// Render one segment's `(text, color, tooltip_extra)` from a
/// snapshot. Handles the four states:
///   * binary missing (parent `Requires.binary` absent from PATH,
///     detected pre-render via [`IntegrationManifest::is_ready`])
///     → `<glyph> ⧗` in yellow.
///   * no snapshot yet OR snapshot has no values → `<glyph> …`
///     in `comment`.
///   * snapshot has an error → `<glyph> !` in red, tooltip_extra
///     = `last error: <msg>`.
///   * snapshot has values → template-substitute, keep the
///     manifest's color.
fn render_segment_text(
    seg: &StatuslineSegment,
    snapshot: Option<&ValuesSnapshot>,
    manifest: &IntegrationManifest,
) -> (String, String, Option<String>) {
    // Binary-not-ready — the whole integration can't even talk to
    // its backend, so no point rendering anything but the
    // "install/setup needed" placeholder.
    if !manifest.is_ready() {
        return (
            format!("{} \u{29D6}", seg.glyph.trim()),
            "yellow".to_string(),
            Some("integration not ready — check [requires] on the manifest".to_string()),
        );
    }
    match snapshot {
        None => (
            format!("{} …", seg.glyph.trim()),
            "comment".to_string(),
            Some("waiting for first poll".to_string()),
        ),
        Some(snap) if snap.updated_at == 0 && snap.last_error.is_none() => (
            format!("{} …", seg.glyph.trim()),
            "comment".to_string(),
            Some("waiting for first poll".to_string()),
        ),
        Some(snap) if snap.last_error.is_some() => (
            format!("{} !", seg.glyph.trim()),
            "red".to_string(),
            snap.last_error.clone().map(|e| format!("last error: {e}")),
        ),
        Some(snap) => (
            format!(
                "{} {}",
                seg.glyph.trim(),
                substitute_template(&seg.format, &snap.values)
            ),
            seg.color.clone(),
            None,
        ),
    }
}

/// Substitute `{key}` and `{a.b}` in `fmt` from `values`. Missing
/// keys render as `?`; non-string primitives render via
/// `Value::to_string` with quotes stripped so a `Number(2)` reads
/// as `2` not `"2"`.
fn substitute_template(fmt: &str, values: &HashMap<String, Value>) -> String {
    let mut out = String::with_capacity(fmt.len());
    let mut chars = fmt.char_indices().peekable();
    while let Some((_, c)) = chars.next() {
        if c != '{' {
            out.push(c);
            continue;
        }
        // Collect the key until the matching `}`. If we don't find
        // one before the end of the string, treat the `{` literally.
        let mut key = String::new();
        let mut closed = false;
        for (_, k) in chars.by_ref() {
            if k == '}' {
                closed = true;
                break;
            }
            key.push(k);
        }
        if !closed {
            out.push('{');
            out.push_str(&key);
            continue;
        }
        match lookup_key(&key, values) {
            Some(v) => out.push_str(&format_value(v)),
            None => out.push('?'),
        }
    }
    out
}

/// Nested-key lookup. `"a.b.c"` walks `values["a"]["b"]["c"]`;
/// each hop must resolve to an object except the last, which can
/// be any JSON value.
fn lookup_key<'a>(key: &str, values: &'a HashMap<String, Value>) -> Option<&'a Value> {
    let mut parts = key.split('.');
    let first = parts.next()?;
    let mut cur = values.get(first)?;
    for p in parts {
        cur = cur.as_object()?.get(p)?;
    }
    Some(cur)
}

fn format_value(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "null".to_string(),
        _ => v.to_string(),
    }
}

/// First whitespace-delimited token in `command`, PATH-resolved
/// like [`crate::integration_manifest::binary_on_path`]. Returns
/// false if the command is empty or the binary isn't found.
fn binary_from_command_on_path(command: &str) -> bool {
    let Some(bin) = command.split_whitespace().next() else {
        return false;
    };
    // Absolute paths short-circuit — no PATH walk needed.
    let p = std::path::Path::new(bin);
    if p.is_absolute() {
        return p.is_file();
    }
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        if dir.join(bin).is_file() {
            return true;
        }
    }
    false
}

fn clamped_interval(secs: Option<u64>) -> u64 {
    secs.unwrap_or(DEFAULT_POLL_SECS)
        .clamp(MIN_POLL_SECS, MAX_POLL_SECS)
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Spawn one poll thread. Gated `#[cfg(not(test))]` so the unit
/// suite doesn't stack un-joined daemon threads across every
/// `App::new` call.
#[cfg(not(test))]
fn spawn_worker(source_id: String, command: String, interval_secs: u64, tx: Sender<SourceUpdate>) {
    std::thread::Builder::new()
        .name(format!("mnml-statusline-{source_id}"))
        .spawn(move || run_worker(source_id, command, interval_secs, tx))
        .ok();
}

#[cfg(test)]
fn spawn_worker(
    _source_id: String,
    _command: String,
    _interval_secs: u64,
    _tx: Sender<SourceUpdate>,
) {
    // Tests skip the thread spawn — poll shape is exercised
    // directly by unit tests below.
}

#[cfg(not(test))]
fn run_worker(source_id: String, command: String, interval_secs: u64, tx: Sender<SourceUpdate>) {
    loop {
        let result = run_poll_once(&command);
        if tx
            .send(SourceUpdate {
                source_id: source_id.clone(),
                result,
            })
            .is_err()
        {
            // Receiver dropped — parent App re-init'd or is
            // shutting down. Exit cleanly.
            return;
        }
        std::thread::sleep(Duration::from_secs(interval_secs));
    }
}

#[cfg(not(test))]
fn run_poll_once(command: &str) -> Result<HashMap<String, Value>, String> {
    let mut parts = command.split_whitespace();
    let bin = parts.next().ok_or_else(|| "empty command".to_string())?;
    let args: Vec<&str> = parts.collect();
    let out = std::process::Command::new(bin)
        .args(&args)
        .output()
        .map_err(|e| format!("spawn: {e}"))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let head: String = stderr.chars().take(200).collect();
        return Err(format!(
            "exit {}: {}",
            out.status.code().unwrap_or(-1),
            head.trim()
        ));
    }
    let value: Value =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("json parse: {e}"))?;
    let obj = value
        .as_object()
        .ok_or_else(|| "expected JSON object at top level".to_string())?;
    Ok(obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
}

// Keep the unused-import silencer quiet — the App fields
// downstream of this module hold `Sender<SourceUpdate>` and
// `Receiver<SourceUpdate>` directly, but nothing else in this
// file mentions the aliases by name, so the linter would
// otherwise flag them.
#[allow(dead_code)]
fn _channel_type_witness() -> Option<(Sender<SourceUpdate>, Receiver<SourceUpdate>)> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn vals(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect()
    }

    #[test]
    fn substitutes_top_level_keys() {
        let v = vals(&[("open", json!(3)), ("approved", json!(1))]);
        assert_eq!(substitute_template("{open}({approved})", &v), "3(1)");
    }

    #[test]
    fn missing_keys_render_as_question_mark() {
        let v = vals(&[("open", json!(3))]);
        assert_eq!(substitute_template("{open} / {gone}", &v), "3 / ?");
    }

    #[test]
    fn nested_keys_walk_objects() {
        let v = vals(&[("scoped", json!({"limits": {"fable": 42}}))]);
        assert_eq!(substitute_template("{scoped.limits.fable}%", &v), "42%");
        // Non-object hop → missing.
        assert_eq!(substitute_template("{scoped.limits.fable.deep}", &v), "?");
    }

    #[test]
    fn string_values_render_without_quotes() {
        // `Value::to_string` on a String would wrap in `"…"` — the
        // template shouldn't do that.
        let v = vals(&[("name", json!("bitbucket"))]);
        assert_eq!(substitute_template("[{name}]", &v), "[bitbucket]");
    }

    #[test]
    fn primitives_render_via_to_string() {
        let v = vals(&[
            ("n", json!(2)),
            ("b", json!(true)),
            ("f", json!(1.5)),
            ("null", json!(null)),
        ]);
        assert_eq!(
            substitute_template("{n}/{b}/{f}/{null}", &v),
            "2/true/1.5/null"
        );
    }

    #[test]
    fn unclosed_brace_renders_literally() {
        let v = vals(&[("open", json!(3))]);
        assert_eq!(substitute_template("{open} and {stuck", &v), "3 and {stuck");
    }

    #[test]
    fn clamp_defaults_and_bounds() {
        assert_eq!(clamped_interval(None), DEFAULT_POLL_SECS);
        assert_eq!(clamped_interval(Some(0)), MIN_POLL_SECS);
        assert_eq!(clamped_interval(Some(10)), MIN_POLL_SECS);
        assert_eq!(clamped_interval(Some(120)), 120);
        assert_eq!(clamped_interval(Some(99_999)), MAX_POLL_SECS);
    }

    #[test]
    fn binary_lookup_absolute_path() {
        // Whatever `sh` maps to should exist on any test host.
        assert!(binary_from_command_on_path("/bin/sh -c 'echo hi'"));
        assert!(!binary_from_command_on_path(
            "/definitely/nonexistent/xyzzy --flag"
        ));
        assert!(!binary_from_command_on_path(""));
    }

    #[test]
    fn snapshot_state_transitions() {
        use crate::integration_manifest::{IntegrationManifest, StatuslineSegment};
        use std::path::PathBuf;
        // Manifest with no [requires] → always ready.
        let m = IntegrationManifest {
            id: "bb".into(),
            label: "BB".into(),
            description: None,
            version: None,
            binary: Some("mnml-forge-bitbucket".into()),
            category: None,
            homepage: None,
            docs: None,
            repository: None,
            author: None,
            chip: None,
            commands: vec![],
            context_menu: vec![],
            menu_bar: vec![],
            statusline: None,
            values_sources: vec![],
            statusline_segments: vec![],
            settings: vec![],
            notifications: None,
            requires: None,
            auth: vec![],
            source_path: PathBuf::new(),
            override_env: HashMap::new(),
            override_auth_values: HashMap::new(),
        };
        let seg = StatuslineSegment {
            id: "prs".into(),
            source: "bb_vals".into(),
            glyph: "".into(),
            color: "cyan".into(),
            format: "{open}".into(),
            tooltip: None,
            click_command: None,
        };
        // No snapshot → placeholder.
        let (text, color, _) = render_segment_text(&seg, None, &m);
        assert!(
            text.ends_with('…'),
            "expected waiting placeholder, got {text:?}"
        );
        assert_eq!(color, "comment");
        // Error → red !.
        let snap = ValuesSnapshot {
            values: HashMap::new(),
            updated_at: 100,
            last_error: Some("boom".into()),
        };
        let (text, color, extra) = render_segment_text(&seg, Some(&snap), &m);
        assert!(text.ends_with('!'), "expected error sigil, got {text:?}");
        assert_eq!(color, "red");
        assert_eq!(extra.as_deref(), Some("last error: boom"));
        // Success → color from manifest, substituted format.
        let snap = ValuesSnapshot {
            values: vals(&[("open", json!(4))]),
            updated_at: 100,
            last_error: None,
        };
        let (text, color, extra) = render_segment_text(&seg, Some(&snap), &m);
        assert!(
            text.ends_with(" 4"),
            "expected substituted text, got {text:?}"
        );
        assert_eq!(color, "cyan");
        assert!(extra.is_none());
    }
}
