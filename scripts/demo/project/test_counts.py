import unittest

from counts import word_counts


class WordCounts(unittest.TestCase):
    def test_counts_repeats(self):
        self.assertEqual(word_counts("ok ok ok"), {"ok": 3})

    def test_counts_are_per_word(self):
        self.assertEqual(word_counts("a b a"), {"a": 2, "b": 1})

    def test_empty_line_has_no_words(self):
        self.assertEqual(word_counts(""), {})


if __name__ == "__main__":
    unittest.main()
