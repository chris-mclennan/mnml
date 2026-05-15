use mnml::edit_op::TextEdit;
use mnml::highlight::highlight_lines_with_cache;
use tree_sitter::Tree;

fn main() {
    let chunk = "fn item_NNNN() { let s = \"hello\"; let n = 42; }\n";
    let mut text = String::with_capacity(700_000);
    let mut idx = 0u32;
    while text.len() < 600_000 {
        text.push_str(&chunk.replace("NNNN", &format!("{idx:04}")));
        idx += 1;
    }
    println!(
        "file size: {} bytes, {} lines",
        text.len(),
        text.lines().count()
    );

    // Fresh parse, warm the cache and measure cost.
    let t_warm = std::time::Instant::now();
    let mut tree: Option<Tree> = None;
    let _ = highlight_lines_with_cache(&text, "rs", &mut tree, &[], &[]);
    println!("first fresh parse:  {:?}", t_warm.elapsed());

    let prev_starts: Vec<usize> = std::iter::once(0)
        .chain(
            text.as_bytes()
                .iter()
                .enumerate()
                .filter_map(|(i, &b)| (b == b'\n').then_some(i + 1)),
        )
        .collect();

    let insert_at = text.len() / 2;
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

    // Warm the cache (a few iterations to amortize jitter).
    for _ in 0..3 {
        let mut t = tree.clone();
        let t_inc = std::time::Instant::now();
        let _ = highlight_lines_with_cache(&after, "rs", &mut t, &[edit], &prev_starts);
        println!("incremental insert: {:?}", t_inc.elapsed());
    }
    for _ in 0..3 {
        let mut t: Option<Tree> = None;
        let t_fresh = std::time::Instant::now();
        let _ = highlight_lines_with_cache(&after, "rs", &mut t, &[], &[]);
        println!("fresh reparse:      {:?}", t_fresh.elapsed());
    }
}
