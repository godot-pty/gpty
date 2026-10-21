use std::collections::HashMap;

/// Count how often each word appears in a log line.
fn word_counts(line: &str) -> HashMap<&str, usize> {
    let mut counts = HashMap::new();
    for word in line.split_whitespace() {
        *counts.entry(word).or_insert(0) += 1;
    }
    counts
}

fn main() {
    let line = "build ok build ok tests ok";
    let mut counts: Vec<_> = word_counts(line).into_iter().collect();
    counts.sort();
    for (word, n) in counts {
        println!("{word}: {n}");
    }
}
