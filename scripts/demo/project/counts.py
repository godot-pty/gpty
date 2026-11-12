"""The same word count as ``src/main.rs``, so the demo can run a test."""


def word_counts(line: str) -> dict[str, int]:
    """Count how often each word appears in a log line."""
    counts: dict[str, int] = {}
    for word in line.split():
        counts[word] = counts.get(word, 0) + 1
    return counts
