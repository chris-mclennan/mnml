//! The fixture the picker's preview column is cut on.
use std::collections::HashMap;

fn main() {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for word in "the quick brown fox".split_whitespace() {
        *counts.entry(word).or_insert(0) += 1;
    }
    println!("{} distinct words", counts.len());
}
