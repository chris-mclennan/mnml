//! Same shape as bench_highlight.rs but on a synthetic markdown file with
//! many paragraphs (markdown_inline injections) + several fenced code blocks
//! (rust injections). Surfaces how injection-heavy files behave with the
//! current incremental query path.
//!
//! On the dev machine (Apple Silicon, release): ~294ms fresh, ~50ms
//! incremental. The 50ms floor is dominated by the markdown grammar's own
//! incremental parse cost (markdown's grammar is structurally awkward for
//! incremental reuse — even isolating just `parser.parse` with a known
//! prev_tree costs ~67ms on this file size).
//!
//! Per-language injection tree caching (group-and-batch every
//! `markdown_inline` content range into one `set_included_ranges` call) was
//! tried and reverted: it made the *fresh* parse ~60% slower without
//! moving incremental. Hypothesis: tree-sitter's bookkeeping per included
//! range scales worse than many independent small parses for grammars with
//! thousands of tiny injection ranges. A smarter strategy (per-injection
//! caching with stable identity, or skipping the per-paragraph injection
//! for markdown_inline and parsing the document monolithically) might
//! still help — left for a future arc.

use mnml::edit_op::TextEdit;
use mnml::highlight::highlight_lines_with_cache;
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
    let t_warm = std::time::Instant::now();
    let prev_h = highlight_lines_with_cache(&text, "md", &mut tree, &[], &[], Vec::new());
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
        let t_inc = std::time::Instant::now();
        let _ =
            highlight_lines_with_cache(&after, "md", &mut t, &[edit], &prev_starts, prev_h.clone());
        println!("incremental insert: {:?}", t_inc.elapsed());
    }
    for _ in 0..3 {
        let mut t: Option<Tree> = None;
        let t_fresh = std::time::Instant::now();
        let _ = highlight_lines_with_cache(&after, "md", &mut t, &[], &[], Vec::new());
        println!("fresh reparse:      {:?}", t_fresh.elapsed());
    }
}
