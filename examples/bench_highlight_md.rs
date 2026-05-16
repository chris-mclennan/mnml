//! Same shape as bench_highlight.rs but on a synthetic markdown file with
//! many paragraphs (markdown_inline injections) + several fenced code blocks
//! (rust injections). Surfaces how injection-heavy files behave with the
//! current incremental query path.
//!
//! Numbers (Apple Silicon, release build, 2026-05-16):
//! * 600KB / 19k-line file: fresh ~295ms, incremental ~22ms.
//! * Real-world sizes (see `bench_highlight_md_sizes.rs` for the sweep):
//!   5KB README — 0.17ms, 30KB — 1.0ms, 100KB — 3.6ms, 300KB — 11ms.
//!
//! The "50ms floor" referenced in earlier handoff notes was stale (likely
//! debug-build numbers). In release on modern hardware, even the 600KB
//! worst case is below 25ms — well under the threshold of human notice
//! for a 120ms-debounced refresh. Real markdown files are 5–50KB, where
//! the cost is sub-millisecond.
//!
//! **Take 2 of the per-injection tree cache (current state):** the cache
//! is wired through — `highlight_lines_with_cache_v2` accepts an
//! `InjectionTreeCache: HashMap<String, Tree>` that Buffer maintains
//! across calls. The cache's trees have the outer text edits applied
//! before each reparse, so tree-sitter can reuse unchanged subtrees of
//! the inner grammars (markdown_inline / rust-in-fences). The cache
//! architecture is kept because it's a strict improvement for OTHER
//! injection-heavy shapes (long HTML with many embedded CSS/JS blocks)
//! and is essentially free for markdown.
//!
//! Take 1 (group-and-batch every `markdown_inline` range into one
//! `set_included_ranges` call) was tried earlier and reverted: it made
//! the *fresh* parse ~60% slower without moving incremental — that
//! approach is documented here for posterity, NOT what's live.
//!
//! Why we no longer pursue "window the outer markdown reparse to just
//! the changed paragraph": the sweep data shows incremental cost on
//! realistic file sizes is already imperceptible. The surgery (paragraph
//! boundary detection, sub-string parsing with offset rebasing, structural-
//! change fallback for headings / list mutations / fence open/close)
//! carries high regression risk for a win measured in tenths of a
//! millisecond at typical file sizes. Deferred indefinitely; revisit if
//! a real user hits a perceptible markdown lag.

use mnml::edit_op::TextEdit;
use mnml::highlight::{InjectionTreeCache, highlight_lines_with_cache_v2};
use tree_sitter::Tree;

fn main() {
    let para = "This is a paragraph with **bold** and *emphasis* and a `code` span.\n\
                It continues on a second line with some [a link](https://example.com).\n\n";
    let rust_block = "```rust\nfn hello() {\n    println!(\"hi\");\n    let x = 42;\n}\n```\n\n";

    let mut text = String::with_capacity(700_000);
    while text.len() < 600_000 {
        text.push_str(&format!("# Section heading {}\n\n", text.len()));
        for _ in 0..4 {
            text.push_str(para);
        }
        text.push_str(rust_block);
    }
    println!(
        "file size: {} bytes, {} lines",
        text.len(),
        text.lines().count()
    );

    let mut tree: Option<Tree> = None;
    let mut inj = InjectionTreeCache::new();
    let t_warm = std::time::Instant::now();
    let prev_h =
        highlight_lines_with_cache_v2(&text, "md", &mut tree, &mut inj, &[], &[], Vec::new());
    println!("first fresh parse:  {:?}", t_warm.elapsed());

    let prev_starts: Vec<usize> = std::iter::once(0)
        .chain(
            text.as_bytes()
                .iter()
                .enumerate()
                .filter_map(|(i, &b)| (b == b'\n').then_some(i + 1)),
        )
        .collect();

    let mid = text.len() / 2;
    let insert_at = (mid..text.len())
        .find(|&i| {
            text.is_char_boundary(i) && !text[i..].starts_with('`') && !text[i..].starts_with('#')
        })
        .unwrap_or(mid);
    let mut after = text.clone();
    after.insert(insert_at, 'X');
    let edit = TextEdit {
        start_byte: insert_at,
        old_end_byte: insert_at,
        new_end_byte: insert_at + 1,
    };

    for _ in 0..3 {
        let mut t = tree.clone();
        let mut inj2 = inj.clone();
        let t_inc = std::time::Instant::now();
        let _ = highlight_lines_with_cache_v2(
            &after,
            "md",
            &mut t,
            &mut inj2,
            &[edit],
            &prev_starts,
            prev_h.clone(),
        );
        println!("incremental insert: {:?}", t_inc.elapsed());
    }
    for _ in 0..3 {
        let mut t: Option<Tree> = None;
        let mut inj3 = InjectionTreeCache::new();
        let t_fresh = std::time::Instant::now();
        let _ =
            highlight_lines_with_cache_v2(&after, "md", &mut t, &mut inj3, &[], &[], Vec::new());
        println!("fresh reparse:      {:?}", t_fresh.elapsed());
    }
}
