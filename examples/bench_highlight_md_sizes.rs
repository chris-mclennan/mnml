//! Sweeps the markdown bench across realistic file sizes to find out
//! where the 50ms incremental cost from `bench_highlight_md.rs` actually
//! sits on typical files (5K–50K) vs the synthetic 600K worst case.

use mnml::edit_op::TextEdit;
use mnml::highlight::{InjectionTreeCache, highlight_lines_with_cache_v2};
use tree_sitter::Tree;

fn synth_md(target_bytes: usize) -> String {
    let para = "This is a paragraph with **bold** and *emphasis* and a `code` span.\n\
                It continues on a second line with some [a link](https://example.com).\n\n";
    let rust_block = "```rust\nfn hello() {\n    println!(\"hi\");\n    let x = 42;\n}\n```\n\n";
    let mut text = String::with_capacity(target_bytes + 1024);
    while text.len() < target_bytes {
        text.push_str(&format!("# Section heading {}\n\n", text.len()));
        for _ in 0..4 {
            text.push_str(para);
        }
        text.push_str(rust_block);
    }
    text
}

fn main() {
    for &target in &[5_000usize, 30_000, 100_000, 300_000, 600_000] {
        let text = synth_md(target);
        let mut tree: Option<Tree> = None;
        let mut inj = InjectionTreeCache::new();
        let _ =
            highlight_lines_with_cache_v2(&text, "md", &mut tree, &mut inj, &[], &[], Vec::new());

        let prev_starts: Vec<usize> = std::iter::once(0)
            .chain(
                text.as_bytes()
                    .iter()
                    .enumerate()
                    .filter_map(|(i, &b)| (b == b'\n').then_some(i + 1)),
            )
            .collect();
        let prev_h = highlight_lines_with_cache_v2(
            &text,
            "md",
            &mut tree,
            &mut inj,
            &[],
            &prev_starts,
            Vec::new(),
        );

        let mid = text.len() / 2;
        let insert_at = (mid..text.len())
            .find(|&i| {
                text.is_char_boundary(i)
                    && !text[i..].starts_with('`')
                    && !text[i..].starts_with('#')
            })
            .unwrap_or(mid);
        let mut after = text.clone();
        after.insert(insert_at, 'X');
        let edit = TextEdit {
            start_byte: insert_at,
            old_end_byte: insert_at,
            new_end_byte: insert_at + 1,
        };

        // 3-trial best-of for incremental.
        let mut best = std::time::Duration::from_secs(60);
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
            best = best.min(t_inc.elapsed());
        }
        println!(
            "{:>7} bytes ({:>5} lines): incremental best-of-3 = {:>6.2}ms",
            text.len(),
            text.lines().count(),
            best.as_secs_f64() * 1000.0
        );
    }
}
