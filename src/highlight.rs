//! Tree-sitter syntax highlighting → per-line colored spans.
//!
//! `highlight_lines(text, ext)` parses `text` with the grammar for `ext`, runs
//! the grammar's highlight queries, and returns, for each editor line, a list of
//! `(start_col_chars, end_col_chars, Color)` spans. The output isn't strictly
//! non-overlapping — outer (larger) captures come before inner (smaller) ones
//! in each line's span list, and the renderer in `ui/editor_view.rs` resolves
//! cell colors with `spans.iter().rev().find(...)` so the innermost span wins.
//!
//! Injection support: each `LangConfig` may carry an `injections_query` whose
//! `@injection.content` captures (with `@injection.language` siblings or
//! `#set! injection.language "..."` directives) are recursively highlighted by
//! the inner grammar with `Parser::set_included_ranges` so byte offsets stay in
//! the outer text's coordinate space. Depth-capped at `MAX_INJECTION_DEPTH` to
//! prevent runaway nesting (e.g. markdown→markdown_inline→html→…).
//!
//! Cached, leaked `'static` per ext — queries are expensive to compile and
//! there are only a handful of grammars.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use ratatui::style::Color;
use tree_sitter::{
    InputEdit, Language, Parser, Point, Query, QueryCursor, Range, StreamingIterator, Tree,
};

use crate::edit_op::TextEdit;
use crate::ui::theme;

/// One colored run on a single line: `[start_col, end_col)` in **chars**.
pub type ColoredSpan = (usize, usize, Color);

/// Recursion bound on injection-driven highlighting. Markdown → markdown_inline
/// → html is already 3; anything deeper is almost certainly a query bug we
/// shouldn't follow.
const MAX_INJECTION_DEPTH: u32 = 3;

/// The highlight-name vocabulary mnml recognizes. Each capture in a grammar's
/// `highlights.scm` (e.g. `@keyword.return`, `@function.method`) is mapped to
/// the longest entry it equals or has as a `.`-separated prefix.
const HIGHLIGHT_NAMES: &[&str] = &[
    "attribute",
    "boolean",
    "comment",
    "comment.documentation",
    "constant",
    "constant.builtin",
    "constructor",
    "embedded",
    "escape",
    "function",
    "function.builtin",
    "function.macro",
    "function.method",
    "keyword",
    "keyword.control",
    "keyword.directive",
    "keyword.function",
    "keyword.operator",
    "keyword.return",
    "label",
    "module",
    "namespace",
    "number",
    "operator",
    "property",
    "punctuation",
    "punctuation.bracket",
    "punctuation.delimiter",
    "punctuation.special",
    "string",
    "string.escape",
    "string.regexp",
    "string.special",
    "tag",
    // markdown (block + inline) captures
    "text",
    "text.emphasis",
    "text.literal",
    "text.reference",
    "text.strong",
    "text.title",
    "text.uri",
    "type",
    "type.builtin",
    "variable",
    "variable.builtin",
    "variable.member",
    "variable.parameter",
];

fn color_for(idx: usize) -> Color {
    let name = HIGHLIGHT_NAMES.get(idx).copied().unwrap_or("");
    let head = name.split('.').next().unwrap_or(name);
    match head {
        "keyword" => theme::cur().base16[0x0e],
        "string" => match name {
            "string.escape" | "string.special" => theme::cur().base16[0x0c],
            _ => theme::cur().base16[0x0b],
        },
        "comment" => theme::cur().comment,
        "function" => theme::cur().base16[0x0d],
        "constructor" => theme::cur().base16[0x0c],
        "type" => theme::cur().base16[0x0a],
        "number" | "boolean" | "constant" | "escape" => theme::cur().base16[0x09],
        "attribute" | "tag" | "label" => theme::cur().base16[0x0a],
        "module" | "namespace" => theme::cur().base16[0x0a],
        "text" => match name {
            "text.title" => theme::cur().base16[0x0d],
            "text.literal" => theme::cur().base16[0x0b],
            "text.uri" | "text.reference" => theme::cur().base16[0x0c],
            _ => theme::cur().base16[0x05],
        },
        "property" => theme::cur().base16[0x08],
        "variable" => match name {
            "variable.builtin" | "variable.parameter" | "variable.member" => {
                theme::cur().base16[0x08]
            }
            _ => theme::cur().base16[0x05],
        },
        "operator" => theme::cur().base16[0x05],
        "punctuation" => theme::cur().base16[0x0f],
        _ => theme::cur().base16[0x05],
    }
}

/// A compiled, leaked `'static` per-language config. Building one means
/// loading the grammar + compiling its queries; both are expensive, so we keep
/// them around for the process lifetime.
pub struct LangConfig {
    pub language: Language,
    pub highlights_query: Query,
    /// Optional `injections.scm`-derived query. `None` when the grammar
    /// doesn't ship one (or it failed to compile).
    pub injections_query: Option<Query>,
    /// Capture index of `@injection.content` in `injections_query` (cached so
    /// the hot loop doesn't lookup-by-name each match).
    inj_content_idx: Option<u32>,
    /// Capture index of `@injection.language` in `injections_query` (the
    /// dynamic-language form used by fenced code blocks).
    inj_language_idx: Option<u32>,
    /// Map from `highlights_query` capture index → index into `HIGHLIGHT_NAMES`
    /// (or `-1` if the capture name doesn't match any entry). Built once at
    /// config creation; hot path is a single array lookup.
    highlight_map: Vec<i32>,
}

impl LangConfig {
    fn new(language: Language, highlight_src: &str, injections_src: &str) -> Option<Self> {
        let highlights_query = Query::new(&language, highlight_src).ok()?;
        let highlight_map = build_highlight_map(highlights_query.capture_names());
        let (injections_query, inj_content_idx, inj_language_idx) = if injections_src.is_empty() {
            (None, None, None)
        } else {
            match Query::new(&language, injections_src) {
                Ok(q) => {
                    let c = q.capture_index_for_name("injection.content");
                    let l = q.capture_index_for_name("injection.language");
                    (Some(q), c, l)
                }
                // A grammar's injections.scm not compiling is non-fatal —
                // outer highlighting still works.
                Err(_) => (None, None, None),
            }
        };
        Some(LangConfig {
            language,
            highlights_query,
            injections_query,
            inj_content_idx,
            inj_language_idx,
            highlight_map,
        })
    }
}

/// For each capture name, find the longest entry in `HIGHLIGHT_NAMES` it equals
/// or has as a `.`-separated prefix.
fn build_highlight_map(capture_names: &[&str]) -> Vec<i32> {
    capture_names
        .iter()
        .map(|cap| {
            let mut best: i32 = -1;
            let mut best_len = 0usize;
            for (i, hn) in HIGHLIGHT_NAMES.iter().enumerate() {
                let matches = *cap == *hn
                    || (cap.len() > hn.len()
                        && cap.as_bytes()[hn.len()] == b'.'
                        && cap.starts_with(hn));
                if matches && hn.len() >= best_len {
                    best = i as i32;
                    best_len = hn.len();
                }
            }
            best
        })
        .collect()
}

/// Cumulative byte offsets of every line start in `text`. `line_starts[i]` is
/// the byte offset of line `i`'s first char; `line_starts.len() == n_lines`.
fn build_line_starts(text: &str) -> Vec<usize> {
    std::iter::once(0)
        .chain(
            text.as_bytes()
                .iter()
                .enumerate()
                .filter(|&(_, &b)| b == b'\n')
                .map(|(i, _)| i + 1),
        )
        .collect()
}

/// Convert a byte offset into a tree-sitter `Point` (row, col-bytes).
fn point_at_byte(line_starts: &[usize], byte: usize) -> Point {
    let row = match line_starts.binary_search(&byte) {
        Ok(i) => i,
        Err(i) => i.saturating_sub(1),
    };
    let col = byte.saturating_sub(line_starts.get(row).copied().unwrap_or(0));
    Point::new(row, col)
}

/// Highlight `text` for the file extension `ext`. Returns one span list per
/// editor line (`'\n'`-count + 1 lines). Always parses from scratch — see
/// [`highlight_lines_with_cache`] for the incremental variant used by the
/// editor's hot path.
pub fn highlight_lines(text: &str, ext: &str) -> Vec<Vec<ColoredSpan>> {
    let mut prev_tree: Option<Tree> = None;
    highlight_lines_with_cache(text, ext, &mut prev_tree, &[], &[], Vec::new())
}

/// A restriction window for incremental query traversal: re-query only nodes
/// overlapping `byte_range` (via `QueryCursor::set_byte_range`) and emit
/// per-line spans only for lines in `dirty_rows` (`[start, end)` exclusive).
/// Captures that overlap the byte range but whose nodes extend onto unchanged
/// lines are clipped at output — those lines already have the correct spans
/// in the preserved `prev_highlights`.
#[derive(Debug, Clone)]
struct Restrict {
    byte_range: std::ops::Range<usize>,
    dirty_rows: std::ops::Range<usize>,
}

/// Incremental variant of [`highlight_lines`]. If `prev_tree` is `Some` and
/// `edits` is non-empty, applies each edit to the cached tree via `Tree::edit`
/// (using `prev_line_starts` to compute the pre-edit `Point` halves) and reparses
/// with `parser.parse(text, Some(&prev_tree))`, letting tree-sitter reuse the
/// prior tree's structure where the text is unchanged.
///
/// **Incremental query traversal:** when there's exactly one tracked edit *and*
/// `prev_highlights` is non-empty, the function also computes the changed
/// byte-range set between the prior and freshly reparsed tree, derives a dirty
/// line range, copies `prev_highlights` for unchanged lines (shifted by the
/// edit's newline delta), and only re-queries the dirty byte range. Multi-edit
/// batches fall back to a full query — the line-shift math gets ambiguous when
/// edits overlap. The shifted prev_highlights for unchanged lines pick up
/// where the prior frame left off, so visible regions look identical.
///
/// On exit, `*prev_tree` is updated to the freshly produced tree (or cleared on
/// failure). The caller is responsible for updating its own `prev_line_starts`
/// to match `text`.
/// A cache of injection-language trees keyed by lang name (e.g.
/// `"markdown_inline"`, `"rust"`). Lives on `Buffer` alongside the outer
/// `parse_tree` so cross-call reuse is possible — each call applies the
/// outer text edits to every cached injection tree before reparsing, so
/// tree-sitter can reuse unchanged subtrees of the inner grammars.
///
/// Stays small in practice (≤ 3-5 distinct inner languages per file);
/// no eviction policy is needed.
pub type InjectionTreeCache = std::collections::HashMap<String, Tree>;

pub fn highlight_lines_with_cache(
    text: &str,
    ext: &str,
    prev_tree: &mut Option<Tree>,
    edits: &[TextEdit],
    prev_line_starts: &[usize],
    prev_highlights: Vec<Vec<ColoredSpan>>,
) -> Vec<Vec<ColoredSpan>> {
    // Legacy wrapper — callers who don't pass an injection cache get a
    // fresh one per call (no cross-call injection reuse for them).
    let mut inj = InjectionTreeCache::new();
    highlight_lines_with_cache_v2(
        text,
        ext,
        prev_tree,
        &mut inj,
        edits,
        prev_line_starts,
        prev_highlights,
    )
}

/// New API that also takes an injection-tree cache. Callers maintaining
/// a long-lived buffer should use this so injection parsing can reuse
/// unchanged inner subtrees across edits — the principal win on
/// injection-heavy files (markdown with many paragraphs / fenced
/// blocks). When the cache is empty the behavior matches the v1 API.
pub fn highlight_lines_with_cache_v2(
    text: &str,
    ext: &str,
    prev_tree: &mut Option<Tree>,
    inj_cache: &mut InjectionTreeCache,
    edits: &[TextEdit],
    prev_line_starts: &[usize],
    prev_highlights: Vec<Vec<ColoredSpan>>,
) -> Vec<Vec<ColoredSpan>> {
    let n_lines = text.bytes().filter(|&b| b == b'\n').count() + 1;
    let empty_out = || vec![Vec::new(); n_lines];
    let Some(cfg) = config_for_ext(ext) else {
        *prev_tree = None;
        return empty_out();
    };
    let line_starts = build_line_starts(text);

    // Apply each edit's `InputEdit` to the cached tree so tree-sitter knows
    // which bytes shifted before reparsing. Bail to full reparse if anything
    // looks off (out-of-range offsets, etc.).
    if let Some(tree) = prev_tree.as_mut()
        && !edits.is_empty()
        && let Err(()) = apply_edits_to_tree(tree, edits, &line_starts, prev_line_starts)
    {
        *prev_tree = None;
    }
    // Same edit propagation for the per-injection-language tree cache.
    // Any tree that fails the edit-apply check is dropped — it'll be
    // reparsed fresh on its next use.
    if !edits.is_empty() {
        let mut bad_keys: Vec<String> = Vec::new();
        for (lang, tree) in inj_cache.iter_mut() {
            if apply_edits_to_tree(tree, edits, &line_starts, prev_line_starts).is_err() {
                bad_keys.push(lang.clone());
            }
        }
        for k in bad_keys {
            inj_cache.remove(&k);
        }
    }

    let mut parser = Parser::new();
    if parser.set_language(&cfg.language).is_err() {
        *prev_tree = None;
        return empty_out();
    }
    let new_tree = parser.parse(text, prev_tree.as_ref());
    let Some(tree) = new_tree else {
        *prev_tree = None;
        return empty_out();
    };

    // Decide whether to do incremental query traversal. Constraints:
    //  - We must have a prior tree to diff against.
    //  - The edit batch must collapse into a single contiguous edit. Multiple
    //    sequential edits at the same insertion point (typing five chars
    //    within the 120 ms debounce window) collapse cleanly; edits scattered
    //    across the file (LSP rename) don't, and fall back to full query.
    //  - We need non-empty prev_highlights to copy from.
    let collapsed_edit = collapse_edits(edits);
    let do_incremental = collapsed_edit.is_some()
        && !prev_highlights.is_empty()
        && prev_tree.is_some()
        && !prev_line_starts.is_empty();

    let mut out = if do_incremental {
        // Safe to unwrap — the guards above checked these.
        let old_tree = prev_tree.as_ref().unwrap();
        let edit = collapsed_edit.unwrap();
        match plan_incremental(
            &edit,
            prev_line_starts,
            &line_starts,
            n_lines,
            old_tree,
            &tree,
            text.len(),
            prev_highlights,
        ) {
            Some((restrict, mut out)) => {
                // Wipe dirty rows so the re-query refills them clean. Rows
                // outside the dirty window keep their shifted prev_highlights.
                for row in restrict.dirty_rows.clone() {
                    if let Some(line) = out.get_mut(row) {
                        line.clear();
                    }
                }
                apply_query_to_spans(text, &line_starts, cfg, &tree, &mut out, Some(&restrict));
                walk_injections(
                    text,
                    &line_starts,
                    cfg,
                    &tree,
                    0,
                    &mut out,
                    Some(&restrict),
                    inj_cache,
                );
                out
            }
            None => {
                // Couldn't safely plan an incremental window — full reparse.
                full_query(text, &line_starts, cfg, &tree, n_lines, inj_cache)
            }
        }
    } else {
        full_query(text, &line_starts, cfg, &tree, n_lines, inj_cache)
    };

    if out.len() != n_lines {
        out.resize(n_lines, Vec::new());
    }
    *prev_tree = Some(tree);
    out
}

/// Run the full outer + injection query over `tree`, producing spans for every
/// line. Used as the fallback path when an incremental window can't be planned.
fn full_query(
    text: &str,
    line_starts: &[usize],
    cfg: &LangConfig,
    tree: &Tree,
    n_lines: usize,
    inj_cache: &mut InjectionTreeCache,
) -> Vec<Vec<ColoredSpan>> {
    let mut out = vec![Vec::new(); n_lines];
    apply_query_to_spans(text, line_starts, cfg, tree, &mut out, None);
    walk_injections(text, line_starts, cfg, tree, 0, &mut out, None, inj_cache);
    out
}

/// Compute the incremental window for a single edit. Returns:
///   - `Restrict`: byte range to feed `QueryCursor::set_byte_range` + the
///     new-text line range to wipe + refill.
///   - `Vec<Vec<ColoredSpan>>`: `prev_highlights` re-indexed onto the new
///     line count. OLD lines `[old_start_row..=old_end_row]` are dropped
///     (the edit replaces them); OLD lines past `old_end_row` shift by
///     `new_end_row - old_end_row` to align with NEW rows.
///
/// Returns `None` if the edit is out-of-bounds against the prior line index.
#[allow(clippy::too_many_arguments)]
fn plan_incremental(
    edit: &TextEdit,
    prev_line_starts: &[usize],
    new_line_starts: &[usize],
    new_n_lines: usize,
    old_tree: &Tree,
    new_tree: &Tree,
    text_len: usize,
    prev_highlights: Vec<Vec<ColoredSpan>>,
) -> Option<(Restrict, Vec<Vec<ColoredSpan>>)> {
    let old_start_row = row_of_byte(prev_line_starts, edit.start_byte)?;
    let old_end_row = row_of_byte(prev_line_starts, edit.old_end_byte)?;
    let new_end_row = row_of_byte(new_line_starts, edit.new_end_byte)?;
    if old_end_row < old_start_row || new_end_row < old_start_row {
        return None;
    }

    // Dirty rows in NEW coords: start at the edit's first affected line, extend
    // through `new_end_row` (the literal edit region). Then expand to include
    // any line overlapping `changed_ranges` — tree-sitter reports structural
    // propagation beyond the literal edit (e.g. typing `/*` makes the rest of
    // the file a comment).
    let mut dirty_lo = old_start_row;
    let mut dirty_hi = new_end_row;
    for r in old_tree.changed_ranges(new_tree) {
        let lo = row_of_byte(new_line_starts, r.start_byte).unwrap_or(0);
        let hi = if r.end_byte > 0 {
            row_of_byte(new_line_starts, r.end_byte - 1).unwrap_or(0)
        } else {
            lo
        };
        dirty_lo = dirty_lo.min(lo);
        dirty_hi = dirty_hi.max(hi);
    }
    if dirty_hi >= new_n_lines {
        dirty_hi = new_n_lines.saturating_sub(1);
    }
    if dirty_lo > dirty_hi {
        // No structural change AND old_end_row is below old_start_row (unusual).
        // Bail to full reparse rather than do something subtle.
        return None;
    }

    // Shift prev_highlights → onto NEW row indices. Lines below the edit slide
    // straight over; lines inside the OLD edit range are skipped (the dirty
    // re-query will refill them); lines past OLD end shift by `line_shift`.
    let line_shift: isize = new_end_row as isize - old_end_row as isize;
    let mut shifted: Vec<Vec<ColoredSpan>> = vec![Vec::new(); new_n_lines];
    for (old_row, spans) in prev_highlights.into_iter().enumerate() {
        let new_row_signed: isize = if old_row < old_start_row {
            old_row as isize
        } else if old_row <= old_end_row {
            continue; // wiped by the edit; re-query will refill
        } else {
            old_row as isize + line_shift
        };
        if new_row_signed < 0 {
            continue;
        }
        let new_row = new_row_signed as usize;
        if new_row < new_n_lines {
            shifted[new_row] = spans;
        }
    }

    let byte_lo = new_line_starts.get(dirty_lo).copied().unwrap_or(0);
    let byte_hi = if dirty_hi + 1 < new_line_starts.len() {
        new_line_starts[dirty_hi + 1]
    } else {
        text_len
    };
    Some((
        Restrict {
            byte_range: byte_lo..byte_hi,
            dirty_rows: dirty_lo..(dirty_hi + 1),
        },
        shifted,
    ))
}

/// Try to fold a batch of sequential `TextEdit`s into a single combined edit.
///
/// Each subsequent edit's byte offsets live in the *post-previous-edit*
/// coordinate space. Two edits can merge when the second starts at or inside
/// the first's new region:
/// * `e2.start_byte ∈ [c.start_byte, c.new_end_byte]`
///
/// Composition formula (derived from working through type / paste / backspace
/// sequences):
/// * `deletion_within_c   = min(e2.old_end, c.new_end) - e2.start_byte`
/// * `deletion_beyond_c   = max(0, e2.old_end - c.new_end_byte)`
/// * `insertion           = e2.new_end_byte - e2.start_byte`
/// * `c.new_end_byte     -= deletion_within_c; c.new_end_byte += insertion`
/// * `c.old_end_byte     += deletion_beyond_c`
///
/// Covers same-line typing (each char picks up at the previous char's
/// `new_end_byte`), paste-then-edit, and type-then-backspace. Returns `None`
/// when any edit can't be merged (gap before the combined region, or an edit
/// strictly before the combined start) — caller falls back to a full reparse.
fn collapse_edits(edits: &[TextEdit]) -> Option<TextEdit> {
    let mut combined = *edits.first()?;
    for e in &edits[1..] {
        if e.start_byte < combined.start_byte || e.start_byte > combined.new_end_byte {
            return None;
        }
        let deletion_within_c = e.old_end_byte.min(combined.new_end_byte) - e.start_byte;
        let deletion_beyond_c = e.old_end_byte.saturating_sub(combined.new_end_byte);
        let insertion = e.new_end_byte - e.start_byte;
        combined.new_end_byte = combined.new_end_byte - deletion_within_c + insertion;
        combined.old_end_byte += deletion_beyond_c;
    }
    Some(combined)
}

/// Look up the row containing `byte` via `line_starts`. Returns `None` only
/// when `line_starts` is empty.
fn row_of_byte(line_starts: &[usize], byte: usize) -> Option<usize> {
    if line_starts.is_empty() {
        return None;
    }
    Some(match line_starts.binary_search(&byte) {
        Ok(i) => i,
        Err(i) => i.saturating_sub(1),
    })
}

/// Walk `edits` in order, applying each to `tree` via `tree_sitter::Tree::edit`.
///
/// Each edit's byte offsets are in *its own pre-state* coordinate space (the
/// state after the previous edit in the same batch was applied). To compute
/// the `start_point` / `old_end_point` we need the line-starts of that pre-state;
/// `prev_line_starts` seeds the iteration and is rolled forward locally per edit.
/// `new_line_starts` (the current post-all-edits text) is used as the source of
/// truth for `new_end_point`.
///
/// Returns `Err(())` if any edit looks malformed (out-of-range, non-monotonic
/// rebuild); the caller should drop the cached tree and reparse fresh.
fn apply_edits_to_tree(
    tree: &mut Tree,
    edits: &[TextEdit],
    new_line_starts: &[usize],
    prev_line_starts: &[usize],
) -> Result<(), ()> {
    let mut cur_starts: Vec<usize> = if prev_line_starts.is_empty() {
        new_line_starts.to_vec()
    } else {
        prev_line_starts.to_vec()
    };
    for edit in edits {
        if edit.old_end_byte < edit.start_byte || edit.new_end_byte < edit.start_byte {
            return Err(());
        }
        let start_point = point_at_byte(&cur_starts, edit.start_byte);
        let old_end_point = point_at_byte(&cur_starts, edit.old_end_byte);
        // `new_end_point` references the post-edit state of *this* edit.
        // We can't compute it directly from new_line_starts (which is
        // post-all-edits), but we *can* derive it relative to start_point
        // by counting newlines + trailing-col in the new content. We trust
        // new_line_starts at start_byte (unchanged) and walk forward.
        let new_end_point =
            advance_point_to_byte(&cur_starts, edit.start_byte, start_point, edit.new_end_byte);
        tree.edit(&InputEdit {
            start_byte: edit.start_byte,
            old_end_byte: edit.old_end_byte,
            new_end_byte: edit.new_end_byte,
            start_position: start_point,
            old_end_position: old_end_point,
            new_end_position: new_end_point,
        });
        roll_line_starts_forward(&mut cur_starts, edit, new_line_starts);
    }
    Ok(())
}

/// Update `line_starts` in place to reflect that `edit` was applied. The newly
/// inserted line breaks are read off `new_line_starts` (the post-all-edits
/// index) — for a single edit this is exact; for multi-edit batches the later
/// edits' positions may not line up with `new_line_starts` directly. We accept
/// some imprecision: tree-sitter uses Points as hints, not load-bearing data.
fn roll_line_starts_forward(
    line_starts: &mut Vec<usize>,
    edit: &TextEdit,
    new_line_starts: &[usize],
) {
    // Drop entries that fall inside the deleted range `[start_byte, old_end_byte)`.
    line_starts.retain(|&b| b <= edit.start_byte || b >= edit.old_end_byte);
    // Shift entries past the deleted range by the byte delta.
    let delta = edit.new_end_byte as i64 - edit.old_end_byte as i64;
    for b in line_starts.iter_mut() {
        if *b >= edit.old_end_byte {
            *b = ((*b as i64) + delta).max(0) as usize;
        }
    }
    // Insert any new line breaks inside `[start_byte, new_end_byte)` by reading
    // them off `new_line_starts`. For a single-edit batch this is exact.
    let mut inserts: Vec<usize> = new_line_starts
        .iter()
        .copied()
        .filter(|&b| b > edit.start_byte && b <= edit.new_end_byte)
        .collect();
    inserts.sort_unstable();
    for b in inserts.into_iter().rev() {
        // Insert in sorted position. Since we filtered + sorted ascending and
        // then iterate in reverse, we can binary-search for the insertion point.
        let pos = match line_starts.binary_search(&b) {
            Ok(_) => continue, // already present
            Err(i) => i,
        };
        line_starts.insert(pos, b);
    }
}

/// Compute a `Point` for `target_byte` given a known `(anchor_byte, anchor_point)`
/// and the line_starts index that contains anchor's row. Used to derive
/// `new_end_point` when we have the start_point but not the full post-edit
/// line-start index handy.
fn advance_point_to_byte(
    line_starts: &[usize],
    anchor_byte: usize,
    anchor_point: Point,
    target_byte: usize,
) -> Point {
    if target_byte <= anchor_byte {
        return anchor_point;
    }
    // Approximation: walk forward through `line_starts` from anchor's row,
    // adding rows until we cross target_byte. The column on the final row is
    // `target_byte - last_row_start`.
    let mut row = anchor_point.row;
    while row + 1 < line_starts.len() && line_starts[row + 1] <= target_byte {
        row += 1;
    }
    let row_start = line_starts.get(row).copied().unwrap_or(0);
    let col = target_byte.saturating_sub(row_start);
    Point::new(row, col)
}

/// Parse `text` with `cfg`'s grammar (optionally restricted to `included_ranges`
/// so inner grammars stay in the outer text's coordinate space), append per-line
/// highlight spans, then walk the injection query and recurse for each
/// `@injection.content` capture. `restrict` (when `Some`) narrows the query to
/// a byte sub-range and clips emission to a dirty-row window — used by the
/// incremental hot path.
#[allow(clippy::too_many_arguments)]
fn highlight_recursive(
    text: &str,
    line_starts: &[usize],
    cfg: &'static LangConfig,
    included_ranges: &[Range],
    depth: u32,
    out: &mut [Vec<ColoredSpan>],
    restrict: Option<&Restrict>,
    inj_cache: &mut InjectionTreeCache,
    cache_key: Option<&str>,
) {
    if depth > MAX_INJECTION_DEPTH {
        return;
    }
    let mut parser = Parser::new();
    if parser.set_language(&cfg.language).is_err() {
        return;
    }
    if !included_ranges.is_empty() && parser.set_included_ranges(included_ranges).is_err() {
        return;
    }
    // Reuse the per-language cached tree as a parse hint when available.
    // `apply_edits_to_tree` already ran on each cached tree at the top of
    // `highlight_lines_with_cache_v2`, so the tree's byte offsets are
    // pre-shifted to match `text`. tree-sitter will reuse unchanged
    // subtrees of the inner grammar even when the included_ranges change.
    let prev_inner: Option<&Tree> = cache_key.and_then(|k| inj_cache.get(k));
    let Some(tree) = parser.parse(text, prev_inner) else {
        // Drop a potentially-stale entry on parse failure so the next
        // call doesn't try to reuse a now-invalid tree.
        if let Some(k) = cache_key {
            inj_cache.remove(k);
        }
        return;
    };

    apply_query_to_spans(text, line_starts, cfg, &tree, out, restrict);
    walk_injections(
        text,
        line_starts,
        cfg,
        &tree,
        depth,
        out,
        restrict,
        inj_cache,
    );

    if let Some(k) = cache_key {
        inj_cache.insert(k.to_string(), tree);
    }
}

/// Run `cfg.highlights_query` over `tree`, append per-line spans to `out`.
/// When `restrict` is `Some`, the query is limited to `restrict.byte_range`
/// (via `QueryCursor::set_byte_range`) and spans are emitted only on rows in
/// `restrict.dirty_rows` — captures whose nodes extend onto unchanged rows
/// have their out-of-window slices dropped (the caller's shifted
/// `prev_highlights` already covers those rows).
fn apply_query_to_spans(
    text: &str,
    line_starts: &[usize],
    cfg: &LangConfig,
    tree: &tree_sitter::Tree,
    out: &mut [Vec<ColoredSpan>],
    restrict: Option<&Restrict>,
) {
    let bytes = text.as_bytes();
    let mut cursor = QueryCursor::new();
    if let Some(r) = restrict {
        cursor.set_byte_range(r.byte_range.clone());
    }
    let mut iter = cursor.captures(&cfg.highlights_query, tree.root_node(), bytes);

    // Collect (start_byte, end_byte, color, pattern_idx) for every relevant capture.
    let mut caps: Vec<(usize, usize, Color, u32)> = Vec::new();
    while let Some(item) = iter.next() {
        let qmatch = &item.0;
        let cap_idx_in_match = item.1;
        let cap = qmatch.captures[cap_idx_in_match];
        let cap_idx = cap.index as usize;
        let hn_idx = cfg.highlight_map.get(cap_idx).copied().unwrap_or(-1);
        if hn_idx < 0 {
            continue;
        }
        let start = cap.node.start_byte();
        let end = cap.node.end_byte();
        if end <= start {
            continue;
        }
        let color = color_for(hn_idx as usize);
        caps.push((start, end, color, qmatch.pattern_index as u32));
    }

    // Innermost wins: emit smaller ranges *later* so the renderer's
    // `spans.iter().rev().find(...)` picks them first. Pattern-index
    // ascending → a later .scm pattern (which by tree-sitter convention
    // overrides earlier ones at the same node) ends up later in the Vec too.
    caps.sort_by(|a, b| {
        let alen = a.1.saturating_sub(a.0);
        let blen = b.1.saturating_sub(b.0);
        blen.cmp(&alen).then(a.3.cmp(&b.3))
    });

    for &(start, end, color, _) in &caps {
        let mut b = start;
        while b < end {
            let line = match line_starts.binary_search(&b) {
                Ok(i) => i,
                Err(i) => i.saturating_sub(1),
            };
            if line >= out.len() {
                break;
            }
            let content_end = if line + 1 < line_starts.len() {
                line_starts[line + 1] - 1
            } else {
                bytes.len()
            };
            let seg_end = end.min(content_end);
            let ls = line_starts[line];
            let in_window = restrict.is_none_or(|r| r.dirty_rows.contains(&line));
            if in_window && seg_end > b && b >= ls {
                // Byte offsets → char columns. Slicing `text` (not `bytes`)
                // is char-boundary-safe because tree-sitter only ever returns
                // node boundaries that *are* char boundaries.
                let scol = text[ls..b].chars().count();
                let ecol = text[ls..seg_end].chars().count();
                if ecol > scol {
                    out[line].push((scol, ecol, color));
                }
            }
            let next = if line + 1 < line_starts.len() {
                line_starts[line + 1]
            } else {
                bytes.len()
            };
            b = next.max(b + 1);
        }
    }
}

/// Walk `cfg.injections_query` over `tree`. For each match, find the
/// `@injection.content` byte range(s) + the language (captured `@injection.language`
/// or `#set! injection.language "…"`), resolve the inner `LangConfig`, recurse.
///
/// When `restrict` is `Some`, the injection query is limited to the dirty byte
/// window (matches still surface multi-line injection nodes that *overlap* the
/// window) and injection content ranges that don't touch the window are
/// skipped — the unchanged inner spans are already in the caller's
/// `prev_highlights`-derived `out`.
#[allow(clippy::too_many_arguments)]
fn walk_injections(
    text: &str,
    line_starts: &[usize],
    cfg: &LangConfig,
    tree: &tree_sitter::Tree,
    depth: u32,
    out: &mut [Vec<ColoredSpan>],
    restrict: Option<&Restrict>,
    inj_cache: &mut InjectionTreeCache,
) {
    let (Some(query), Some(content_idx)) = (cfg.injections_query.as_ref(), cfg.inj_content_idx)
    else {
        return;
    };

    let mut cursor = QueryCursor::new();
    if let Some(r) = restrict {
        cursor.set_byte_range(r.byte_range.clone());
    }
    let mut iter = cursor.matches(query, tree.root_node(), text.as_bytes());
    while let Some(qmatch) = iter.next() {
        let mut content_ranges: Vec<Range> = Vec::new();
        let mut captured_lang: Option<String> = None;
        for cap in qmatch.captures {
            if cap.index == content_idx {
                let node = cap.node;
                let sb = node.start_byte();
                let eb = node.end_byte();
                if eb > sb {
                    content_ranges.push(Range {
                        start_byte: sb,
                        end_byte: eb,
                        start_point: point_at_byte(line_starts, sb),
                        end_point: point_at_byte(line_starts, eb),
                    });
                }
            } else if Some(cap.index) == cfg.inj_language_idx {
                let node = cap.node;
                let sb = node.start_byte();
                let eb = node.end_byte();
                if eb > sb && eb <= text.len() {
                    captured_lang = Some(text[sb..eb].to_string());
                }
            }
        }

        // `#set! injection.language "rust"` directive on the pattern.
        let set_lang = query
            .property_settings(qmatch.pattern_index)
            .iter()
            .find(|p| &*p.key == "injection.language")
            .and_then(|p| p.value.as_ref().map(|v| v.to_string()));

        let Some(lang_name) = captured_lang.or(set_lang) else {
            continue;
        };
        if content_ranges.is_empty() {
            continue;
        }
        let Some(inner_cfg) = config_for_lang(&lang_name) else {
            continue;
        };

        // tree-sitter requires included ranges sorted by start_byte and non-overlapping.
        content_ranges.sort_by_key(|r| r.start_byte);
        if has_overlap(&content_ranges) {
            continue;
        }
        // Under a restrict window, skip injections whose content lives entirely
        // outside the dirty byte range — the inner spans are already in
        // prev_highlights for those rows.
        if let Some(r) = restrict
            && !content_ranges
                .iter()
                .any(|cr| cr.end_byte > r.byte_range.start && cr.start_byte < r.byte_range.end)
        {
            continue;
        }
        // Use the (normalized) language name as the cache key so the same
        // logical injection language reuses its tree across calls. Each
        // pattern match contributes one set of content_ranges; per-paragraph
        // matches for markdown_inline merge into one cache entry via the
        // shared key.
        let normalized_key = lang_name.trim().to_ascii_lowercase();
        highlight_recursive(
            text,
            line_starts,
            inner_cfg,
            &content_ranges,
            depth + 1,
            out,
            restrict,
            inj_cache,
            Some(&normalized_key),
        );
    }
}

fn has_overlap(ranges: &[Range]) -> bool {
    ranges.windows(2).any(|w| w[0].end_byte > w[1].start_byte)
}

fn config_for_ext(ext: &str) -> Option<&'static LangConfig> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<&'static LangConfig>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut g = cache.lock().ok()?;
    if let Some(c) = g.get(ext) {
        return *c;
    }
    let built: Option<&'static LangConfig> = build_config(ext).map(|c| &*Box::leak(Box::new(c)));
    g.insert(ext.to_string(), built);
    built
}

/// Resolve an *injection language name* (a code-fence info string like `rust`,
/// or a literal from an `injections.scm` such as `markdown_inline` / `html`) to
/// a highlight config — by mapping it onto an extension `build_config` knows.
fn config_for_lang(name: &str) -> Option<&'static LangConfig> {
    let name = name.trim().to_ascii_lowercase();
    // `markdown_inline` is the inline half of tree-sitter-md (no real extension).
    if name == "markdown_inline" || name == "markdown-inline" {
        return config_for_ext("markdown_inline");
    }
    let ext = match name.as_str() {
        "rust" | "rs" => "rs",
        "javascript" | "js" | "node" => "js",
        "jsx" => "jsx",
        "typescript" | "ts" => "ts",
        "tsx" => "tsx",
        "python" | "py" => "py",
        "json" | "jsonc" | "json5" => "json",
        "go" | "golang" => "go",
        "toml" => "toml",
        "css" | "scss" => "css",
        "bash" | "sh" | "shell" | "shellscript" | "zsh" | "console" => "sh",
        "html" | "htm" | "xml" => "html",
        "markdown" | "md" => "md",
        "c" => "c",
        "cpp" | "c++" | "cxx" | "cc" => "cpp",
        "ruby" | "rb" => "rb",
        "java" => "java",
        "csharp" | "c#" | "cs" | "c_sharp" => "cs",
        "lua" => "lua",
        "yaml" | "yml" => "yaml",
        "scala" | "sbt" => "scala",
        "elixir" | "ex" | "exs" => "ex",
        "haskell" | "hs" => "hs",
        "php" | "php_only" => "php",
        "swift" => "swift",
        "zig" => "zig",
        "nix" => "nix",
        "ocaml" | "ml" => "ocaml",
        "ocaml_interface" | "mli" => "mli",
        "dart" => "dart",
        "sql" | "psql" | "mysql" => "sql",
        "make" | "makefile" => "make",
        "kotlin" | "kt" | "kts" => "kt",
        "regex" => "regex",
        _ => return None,
    };
    config_for_ext(ext)
}

fn build_config(ext: &str) -> Option<LangConfig> {
    // (language, highlights, injections). Empty injection-source string ⇒ none.
    let (lang, hl_q, inj_q): (Language, &str, &str) = match ext {
        "rs" => (
            tree_sitter_rust::LANGUAGE.into(),
            tree_sitter_rust::HIGHLIGHTS_QUERY,
            tree_sitter_rust::INJECTIONS_QUERY,
        ),
        "js" | "cjs" | "mjs" | "jsx" => (
            tree_sitter_javascript::LANGUAGE.into(),
            tree_sitter_javascript::HIGHLIGHT_QUERY,
            tree_sitter_javascript::INJECTIONS_QUERY,
        ),
        "py" => (
            tree_sitter_python::LANGUAGE.into(),
            tree_sitter_python::HIGHLIGHTS_QUERY,
            "",
        ),
        "json" => (
            tree_sitter_json::LANGUAGE.into(),
            tree_sitter_json::HIGHLIGHTS_QUERY,
            "",
        ),
        "go" => (
            tree_sitter_go::LANGUAGE.into(),
            tree_sitter_go::HIGHLIGHTS_QUERY,
            "",
        ),
        "toml" => (
            tree_sitter_toml_ng::LANGUAGE.into(),
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY,
            "",
        ),
        "ts" | "cts" | "mts" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
            "",
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
            "",
        ),
        "css" | "scss" => (
            tree_sitter_css::LANGUAGE.into(),
            tree_sitter_css::HIGHLIGHTS_QUERY,
            "",
        ),
        "html" | "htm" => (
            tree_sitter_html::LANGUAGE.into(),
            tree_sitter_html::HIGHLIGHTS_QUERY,
            tree_sitter_html::INJECTIONS_QUERY,
        ),
        "sh" | "bash" | "zsh" => (
            tree_sitter_bash::LANGUAGE.into(),
            tree_sitter_bash::HIGHLIGHT_QUERY,
            "",
        ),
        // Markdown is two grammars: the block structure (headings/fences/lists/quotes)
        // and the *inline* grammar (emphasis, inline code, links) injected via
        // `INJECTION_QUERY_BLOCK` — `config_for_lang("markdown_inline")` resolves to
        // the arm below. Fenced code blocks inject their own language the same way.
        "md" | "markdown" => (
            tree_sitter_md::LANGUAGE.into(),
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
            tree_sitter_md::INJECTION_QUERY_BLOCK,
        ),
        "markdown_inline" => (
            tree_sitter_md::INLINE_LANGUAGE.into(),
            tree_sitter_md::HIGHLIGHT_QUERY_INLINE,
            tree_sitter_md::INJECTION_QUERY_INLINE,
        ),
        "c" | "h" => (
            tree_sitter_c::LANGUAGE.into(),
            tree_sitter_c::HIGHLIGHT_QUERY,
            "",
        ),
        "cpp" | "cc" | "cxx" | "hpp" | "hh" | "hxx" => (
            tree_sitter_cpp::LANGUAGE.into(),
            tree_sitter_cpp::HIGHLIGHT_QUERY,
            "",
        ),
        "rb" | "rake" | "gemspec" => (
            tree_sitter_ruby::LANGUAGE.into(),
            tree_sitter_ruby::HIGHLIGHTS_QUERY,
            "",
        ),
        "java" => (
            tree_sitter_java::LANGUAGE.into(),
            tree_sitter_java::HIGHLIGHTS_QUERY,
            "",
        ),
        "cs" => (
            tree_sitter_c_sharp::LANGUAGE.into(),
            tree_sitter_c_sharp::HIGHLIGHTS_QUERY,
            "",
        ),
        "lua" => (
            tree_sitter_lua::LANGUAGE.into(),
            tree_sitter_lua::HIGHLIGHTS_QUERY,
            "",
        ),
        "yaml" | "yml" => (
            tree_sitter_yaml::LANGUAGE.into(),
            tree_sitter_yaml::HIGHLIGHTS_QUERY,
            "",
        ),
        "scala" | "sc" | "sbt" => (
            tree_sitter_scala::LANGUAGE.into(),
            tree_sitter_scala::HIGHLIGHTS_QUERY,
            "",
        ),
        "ex" | "exs" => (
            tree_sitter_elixir::LANGUAGE.into(),
            tree_sitter_elixir::HIGHLIGHTS_QUERY,
            tree_sitter_elixir::INJECTIONS_QUERY,
        ),
        "hs" => (
            tree_sitter_haskell::LANGUAGE.into(),
            tree_sitter_haskell::HIGHLIGHTS_QUERY,
            tree_sitter_haskell::INJECTIONS_QUERY,
        ),
        "php" | "php3" | "php4" | "php5" | "phtml" => (
            tree_sitter_php::LANGUAGE_PHP.into(),
            tree_sitter_php::HIGHLIGHTS_QUERY,
            tree_sitter_php::INJECTIONS_QUERY,
        ),
        "swift" => (
            tree_sitter_swift::LANGUAGE.into(),
            tree_sitter_swift::HIGHLIGHTS_QUERY,
            tree_sitter_swift::INJECTIONS_QUERY,
        ),
        "zig" => (
            tree_sitter_zig::LANGUAGE.into(),
            tree_sitter_zig::HIGHLIGHTS_QUERY,
            tree_sitter_zig::INJECTIONS_QUERY,
        ),
        "nix" => (
            tree_sitter_nix::LANGUAGE.into(),
            tree_sitter_nix::HIGHLIGHTS_QUERY,
            tree_sitter_nix::INJECTIONS_QUERY,
        ),
        "ocaml" | "ml" => (
            tree_sitter_ocaml::LANGUAGE_OCAML.into(),
            tree_sitter_ocaml::HIGHLIGHTS_QUERY,
            "",
        ),
        "mli" => (
            tree_sitter_ocaml::LANGUAGE_OCAML_INTERFACE.into(),
            tree_sitter_ocaml::HIGHLIGHTS_QUERY,
            "",
        ),
        "dart" => (
            tree_sitter_dart::LANGUAGE.into(),
            tree_sitter_dart::HIGHLIGHTS_QUERY,
            "",
        ),
        "sql" | "psql" | "mysql" => (
            tree_sitter_sequel::LANGUAGE.into(),
            tree_sitter_sequel::HIGHLIGHTS_QUERY,
            "",
        ),
        "mk" | "make" | "makefile" => (
            tree_sitter_make::LANGUAGE.into(),
            tree_sitter_make::HIGHLIGHTS_QUERY,
            "",
        ),
        "kt" | "kts" => (
            tree_sitter_kotlin_sg::LANGUAGE.into(),
            tree_sitter_kotlin_sg::HIGHLIGHTS_QUERY,
            "",
        ),
        "regex" => (
            tree_sitter_regex::LANGUAGE.into(),
            tree_sitter_regex::HIGHLIGHTS_QUERY,
            "",
        ),
        _ => return None,
    };
    LangConfig::new(lang, hl_q, inj_q)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_keywords_and_strings_get_colored() {
        let src = "fn main() {\n    let s = \"hi\";\n}\n";
        let lines = highlight_lines(src, "rs");
        assert_eq!(lines.len(), 4); // 3 '\n' + 1
        assert!(
            lines[0].iter().any(|&(s, e, _)| s == 0 && e >= 2),
            "expected a span over `fn`: {:?}",
            lines[0]
        );
        assert!(
            lines[1].iter().any(|&(s, e, _)| s <= 12 && e >= 14),
            "expected a span covering the string literal: {:?}",
            lines[1]
        );
    }

    #[test]
    fn unknown_ext_is_plain() {
        let lines = highlight_lines("hello\nworld\n", "xyz");
        assert_eq!(lines.len(), 3);
        assert!(lines.iter().all(|l| l.is_empty()));
    }

    #[test]
    fn kotlin_parses() {
        let src = "fun main() { println(\"hi\") }\n";
        let lines = highlight_lines(src, "kt");
        assert!(!lines.is_empty());
        assert!(
            !lines[0].is_empty(),
            "expected kotlin highlighter to emit at least one span: {:?}",
            lines[0]
        );
    }

    #[test]
    fn json_parses() {
        let lines = highlight_lines("{\n  \"a\": 1\n}\n", "json");
        assert_eq!(lines.len(), 4);
        assert!(
            lines[1].iter().any(|&(s, e, _)| s <= 2 && e >= 4),
            "expected a span over the key: {:?}",
            lines[1]
        );
        assert!(
            lines[1].iter().any(|&(s, e, _)| s <= 7 && e >= 8),
            "expected a span over the number: {:?}",
            lines[1]
        );
    }

    #[test]
    fn markdown_injects_fenced_code() {
        // A ```rust fence's body should be highlighted by the Rust grammar via
        // the injection-query walk; the heading line gets a `text.title` span.
        let src = "# Title\n\n```rust\nfn x() {}\n```\n";
        let lines = highlight_lines(src, "md");
        assert_eq!(lines.len(), 6);
        assert!(
            lines[0].iter().any(|&(s, e, _)| s <= 2 && e >= 4),
            "expected the heading text to be colored: {:?}",
            lines[0]
        );
        assert!(
            lines[3].iter().any(|&(s, e, _)| s == 0 && e >= 2),
            "expected the fenced Rust code to be highlighted: {:?}",
            lines[3]
        );
    }

    #[test]
    fn markdown_injects_inline_emphasis() {
        // `**bold**` text in a markdown paragraph should receive an
        // emphasis-style span via the `markdown_inline` injection.
        let src = "This is **bold** text.\n";
        let lines = highlight_lines(src, "md");
        // Some span (the bold emphasis) should cover bytes 8..16 — "**bold**".
        assert!(
            lines[0].iter().any(|&(s, e, _)| s <= 8 && e >= 16),
            "expected the markdown_inline injection to mark the **bold** run: {:?}",
            lines[0]
        );
    }

    #[test]
    fn injection_tree_cache_populates_and_survives_calls() {
        // After a markdown parse, the inj cache should contain entries for
        // every injection language the file activated (markdown_inline at
        // least; rust too because the source has a fenced rust block).
        let src = "Hello **world**.\n\n```rust\nfn x() {}\n```\n";
        let mut prev: Option<Tree> = None;
        let mut inj = InjectionTreeCache::new();
        let _ = highlight_lines_with_cache_v2(src, "md", &mut prev, &mut inj, &[], &[], Vec::new());
        assert!(
            inj.contains_key("markdown_inline"),
            "expected markdown_inline tree to be cached, got keys: {:?}",
            inj.keys().collect::<Vec<_>>()
        );
        assert!(
            inj.contains_key("rust"),
            "expected rust tree to be cached, got keys: {:?}",
            inj.keys().collect::<Vec<_>>()
        );
        // Same call with no edits should keep the cache populated.
        let prev_count = inj.len();
        let _ = highlight_lines_with_cache_v2(src, "md", &mut prev, &mut inj, &[], &[], Vec::new());
        assert_eq!(
            inj.len(),
            prev_count,
            "cache shouldn't shrink between equivalent calls"
        );
    }

    #[test]
    fn extra_grammars_load_and_color_something() {
        let cases: &[(&str, &str)] = &[
            ("ts", "const x: number = 1;\n"),
            ("tsx", "const C = () => <div>{x}</div>;\n"),
            ("css", "a { color: red; }\n"),
            ("sh", "echo \"hi\" && ls -la\n"),
            ("html", "<div class=\"x\">hi</div>\n"),
            ("md", "# Heading\n\n- item\n"),
            ("c", "int main(void) { return 0; }\n"),
            ("cpp", "auto f() -> int { return 42; }\n"),
            ("rb", "def hi(name) = puts \"hi #{name}\"\n"),
            ("java", "class A { void f() { return; } }\n"),
            ("cs", "class A { void F() { return; } }\n"),
            ("lua", "local function f(x) return x + 1 end\n"),
            ("yaml", "name: value\nlist:\n  - one\n"),
            ("scala", "object A { def f(x: Int): Int = x + 1 }\n"),
            (
                "ex",
                "defmodule A do\n  def hi(name), do: IO.puts(name)\nend\n",
            ),
            ("hs", "main :: IO ()\nmain = putStrLn \"hi\"\n"),
            ("php", "<?php function hi($name) { echo \"hi $name\"; }\n"),
            (
                "swift",
                "func hi(_ name: String) -> String { return \"hi \\(name)\" }\n",
            ),
            ("mk", "CC = clang\nall: build\nbuild:\n\t$(CC) main.c\n"),
            (
                "zig",
                "const std = @import(\"std\");\npub fn main() void {}\n",
            ),
            ("nix", "{ pkgs ? import <nixpkgs> {} }: pkgs.hello\n"),
            ("ocaml", "let hi name = print_endline (\"hi \" ^ name)\n"),
            (
                "dart",
                "void main() {\n  print('hi');\n  var x = 1 + 2;\n}\n",
            ),
            (
                "sql",
                "SELECT id, name FROM users WHERE active = TRUE LIMIT 10;\n",
            ),
        ];
        for &(ext, src) in cases {
            let lines = highlight_lines(src, ext);
            assert!(
                !lines.is_empty() && lines.iter().any(|l| !l.is_empty()),
                "{ext}: expected some highlight spans, got {lines:?}"
            );
        }
    }

    #[test]
    fn incremental_reparse_matches_fresh_for_typing() {
        // Simulate typing "X" between "main" and "()" in `fn main() {}`.
        // Incremental reparse with a one-char InputEdit should produce the
        // same per-line spans as a fresh parse of the post-edit text.
        let before = "fn main() {}\n";
        let after = "fn mainX() {}\n";
        let edit = TextEdit {
            start_byte: 7,
            old_end_byte: 7,
            new_end_byte: 8,
        };

        let mut tree: Option<Tree> = None;
        let prev_h = highlight_lines_with_cache(before, "rs", &mut tree, &[], &[], Vec::new());
        assert!(tree.is_some(), "fresh parse should produce a tree");

        let prev_starts: Vec<usize> = std::iter::once(0)
            .chain(
                before
                    .as_bytes()
                    .iter()
                    .enumerate()
                    .filter_map(|(i, &b)| (b == b'\n').then_some(i + 1)),
            )
            .collect();
        let incremental =
            highlight_lines_with_cache(after, "rs", &mut tree, &[edit], &prev_starts, prev_h);
        assert!(tree.is_some(), "incremental reparse should update tree");

        let mut fresh_tree: Option<Tree> = None;
        let fresh = highlight_lines_with_cache(after, "rs", &mut fresh_tree, &[], &[], Vec::new());
        assert_eq!(
            incremental, fresh,
            "incremental and fresh highlights should match"
        );
    }

    #[test]
    fn incremental_reparse_faster_than_fresh_on_big_file() {
        // Synthesize a ~600 KB Rust file and verify that an incremental
        // one-char insertion is meaningfully faster than a fresh parse.
        // Not a strict perf guarantee (CI machines vary) — we just assert
        // incremental ≤ fresh, which catches regressions where the cached
        // tree isn't actually being reused.
        let chunk = "fn item_NNNN() { let s = \"hello\"; let n = 42; }\n";
        let mut text = String::with_capacity(700_000);
        let mut idx = 0u32;
        while text.len() < 600_000 {
            text.push_str(&chunk.replace("NNNN", &format!("{idx:04}")));
            idx += 1;
        }

        // Warm: cache the initial tree.
        let mut tree: Option<Tree> = None;
        let prev_h = highlight_lines_with_cache(&text, "rs", &mut tree, &[], &[], Vec::new());
        assert!(tree.is_some());
        let prev_starts: Vec<usize> = std::iter::once(0)
            .chain(
                text.as_bytes()
                    .iter()
                    .enumerate()
                    .filter_map(|(i, &b)| (b == b'\n').then_some(i + 1)),
            )
            .collect();

        // Insert a single char near the middle.
        let insert_at = text.len() / 2;
        // Snap to a char boundary just to be safe.
        let insert_at = (insert_at..text.len())
            .find(|&i| text.is_char_boundary(i))
            .unwrap_or(insert_at);
        let mut after = text.clone();
        after.insert(insert_at, 'X');
        let edit = TextEdit {
            start_byte: insert_at,
            old_end_byte: insert_at,
            new_end_byte: insert_at + 1,
        };

        let t_inc = std::time::Instant::now();
        let _ = highlight_lines_with_cache(&after, "rs", &mut tree, &[edit], &prev_starts, prev_h);
        let inc = t_inc.elapsed();

        let mut fresh_tree: Option<Tree> = None;
        let t_fresh = std::time::Instant::now();
        let _ = highlight_lines_with_cache(&after, "rs", &mut fresh_tree, &[], &[], Vec::new());
        let fresh = t_fresh.elapsed();

        // Looser than the handoff's "< 5ms" — that's a real-machine target.
        // We just want a confidence floor that incremental is doing *something*
        // useful, so allow it to be up to fresh's time. In practice it's much
        // less (the parse is the dominant cost; query traversal is similar).
        assert!(
            inc <= fresh,
            "incremental ({inc:?}) should not be slower than fresh ({fresh:?})"
        );
    }

    #[test]
    fn incremental_reparse_handles_backspace() {
        // Buffer "fn main() {}", backspace deletes the trailing brace.
        let before = "fn main() {}";
        let after = "fn main() {";
        let edit = TextEdit {
            start_byte: 11,
            old_end_byte: 12,
            new_end_byte: 11,
        };

        let mut tree: Option<Tree> = None;
        let prev_h = highlight_lines_with_cache(before, "rs", &mut tree, &[], &[], Vec::new());
        let prev_starts: Vec<usize> = vec![0];
        let incremental =
            highlight_lines_with_cache(after, "rs", &mut tree, &[edit], &prev_starts, prev_h);

        let mut fresh_tree: Option<Tree> = None;
        let fresh = highlight_lines_with_cache(after, "rs", &mut fresh_tree, &[], &[], Vec::new());
        assert_eq!(incremental, fresh);
    }

    #[test]
    fn collapse_edits_sequential_typing() {
        // Type "AB" at byte 5 as two single-char inserts.
        let edits = [
            TextEdit {
                start_byte: 5,
                old_end_byte: 5,
                new_end_byte: 6,
            },
            TextEdit {
                start_byte: 6,
                old_end_byte: 6,
                new_end_byte: 7,
            },
        ];
        let c = collapse_edits(&edits).expect("contiguous");
        assert_eq!(c.start_byte, 5);
        assert_eq!(c.old_end_byte, 5);
        assert_eq!(c.new_end_byte, 7);
    }

    #[test]
    fn collapse_edits_type_then_backspace_cancels() {
        // Type "X" at 3, then backspace it.
        let edits = [
            TextEdit {
                start_byte: 3,
                old_end_byte: 3,
                new_end_byte: 4,
            },
            TextEdit {
                start_byte: 3,
                old_end_byte: 4,
                new_end_byte: 3,
            },
        ];
        let c = collapse_edits(&edits).expect("merged");
        assert_eq!(
            c,
            TextEdit {
                start_byte: 3,
                old_end_byte: 3,
                new_end_byte: 3
            }
        );
    }

    #[test]
    fn collapse_edits_type_then_delete_forward() {
        // Type "X" at 3, then delete the next original byte (D).
        let edits = [
            TextEdit {
                start_byte: 3,
                old_end_byte: 3,
                new_end_byte: 4,
            },
            TextEdit {
                start_byte: 4,
                old_end_byte: 5,
                new_end_byte: 4,
            },
        ];
        let c = collapse_edits(&edits).expect("merged");
        assert_eq!(
            c,
            TextEdit {
                start_byte: 3,
                old_end_byte: 4,
                new_end_byte: 4
            }
        );
    }

    #[test]
    fn collapse_edits_refuses_disjoint() {
        // Two edits on different parts of the file (LSP rename pattern):
        // can't merge into one extent.
        let edits = [
            TextEdit {
                start_byte: 100,
                old_end_byte: 103,
                new_end_byte: 108,
            },
            TextEdit {
                start_byte: 200,
                old_end_byte: 203,
                new_end_byte: 208,
            },
        ];
        assert!(collapse_edits(&edits).is_none());
    }

    #[test]
    fn incremental_reparse_matches_fresh_for_multi_char_typing() {
        // Five sequential single-char inserts on the same line — the
        // collapsed-edit incremental path should match a fresh parse.
        let before = "fn main() {}\n";
        let after = "fn main() {LMNOP}\n";
        let mut edits = Vec::new();
        for i in 0..5 {
            edits.push(TextEdit {
                start_byte: 11 + i,
                old_end_byte: 11 + i,
                new_end_byte: 12 + i,
            });
        }

        let mut tree: Option<Tree> = None;
        let prev_h = highlight_lines_with_cache(before, "rs", &mut tree, &[], &[], Vec::new());
        let prev_starts: Vec<usize> = vec![0, 13];
        let incremental =
            highlight_lines_with_cache(after, "rs", &mut tree, &edits, &prev_starts, prev_h);

        let mut fresh_tree: Option<Tree> = None;
        let fresh = highlight_lines_with_cache(after, "rs", &mut fresh_tree, &[], &[], Vec::new());
        assert_eq!(incremental, fresh);
    }

    #[test]
    fn highlight_map_picks_longest_prefix() {
        let caps: &[&str] = &[
            "keyword",
            "keyword.return",
            "keyword.foo.bar",
            "made.up",
            "string.escape",
        ];
        let map = build_highlight_map(caps);
        let idx_of = |name: &str| HIGHLIGHT_NAMES.iter().position(|n| *n == name);
        assert_eq!(map[0], idx_of("keyword").unwrap() as i32);
        assert_eq!(map[1], idx_of("keyword.return").unwrap() as i32);
        assert_eq!(map[2], idx_of("keyword").unwrap() as i32);
        assert_eq!(map[3], -1);
        assert_eq!(map[4], idx_of("string.escape").unwrap() as i32);
    }
}
