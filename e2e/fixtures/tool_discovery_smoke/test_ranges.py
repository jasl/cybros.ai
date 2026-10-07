import unittest

from ranges import merge_ranges


class MergeRangesTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual([], merge_ranges([]))

    def test_overlapping_and_adjacent(self):
        self.assertEqual([(1, 9)], merge_ranges([(1, 4), (3, 6), (6, 9)]))

    def test_zero_length_intervals_are_ignored(self):
        self.assertEqual([(2, 5)], merge_ranges([(1, 1), (2, 5), (8, 8)]))

    def test_input_is_unchanged(self):
        original = [(8, 10), (1, 3)]
        self.assertEqual([(1, 3), (8, 10)], merge_ranges(original))
        self.assertEqual([(8, 10), (1, 3)], original)


if __name__ == "__main__":
    unittest.main()
