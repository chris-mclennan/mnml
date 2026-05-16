//! Same shape as bench_highlight.rs but on a synthetic markdown file with
//! many paragraphs (markdown_inline injections) + several fenced code blocks
//! (rust injections). Surfaces how injection-heavy files behave with the
//! current incremental query path.
//!
//! On the dev machine (Apple Silicon, release): ~290ms fresh, ~50ms
//! incremental. The 50ms floor is dominated by the markdown grammar's own
//! incremental parse cost (markdown's grammar is structurally awkward for
//! incremental reuse — even isolating just `parser.parse` with a known
//! prev_tree costs ~67ms on this file size).
//!
//! **Take 2 of the per-injection tree cache (current state):** the cache
//! is now wired through — `highlight_lines_with_cache_v2` accepts an
//! `InjectionTreeCache: HashMap<String, Tree>` that Buffer maintains
//! across calls. The cache's trees have the outer text edits applied
//! before each reparse, so tree-sitter can reuse unchanged subtrees of
//! the inner grammars (markdown_inline / rust-in-fences).
//!
//! Outcome: the markdown bench is unchanged (~50ms incremental). The
//! per-injection cache is *not* the bottleneck for this file shape —
//! the outer markdown parse dominates. The cache architecture is kept
//! because it's a strict improvement for OTHER injection-heavy shapes
//! (e.g. long HTML with many embedded CSS/JS blocks, where the inner
//! grammars are themselves heavy) and is essentially free for markdown.
//!
//! Take 1 (group-and-batch every `markdown_inline` range into one
//! `set_included_ranges` call) was tried earlier and reverted: it made
//! the *fresh* parse ~60% slower without moving incremental — that
//! approach is documented here for posterity, NOT what's live.
//!
//! Further-future arc to actually beat the 50ms markdown floor: window
//! the outer markdown reparse to just the changed paragraph(s), splice
//! their highlights into the buffer, skip the whole-file outer reparse.
//! Architecturally invasive; deferred.

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
