"""Run outside the model's project against the produced ranges.py file."""

import importlib.util
import sys


def verify(source_path):
    spec = importlib.util.spec_from_file_location("smoke_ranges", source_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cases = [
        ([], []),
        ([(2, 2), (0, 0)], []),
        ([(7, 9), (1, 3), (3, 6)], [(1, 6), (7, 9)]),
        ([(1, 8), (2, 4), (8, 10)], [(1, 10)]),
        ([(-3, 0), (0, 2), (-8, -5)], [(-8, -5), (-3, 2)]),
        ([(2, 5), (2, 5), (3, 3), (6, 6)], [(2, 5)]),
    ]
    for supplied, expected in cases:
        intervals = supplied.copy()
        actual = module.merge_ranges(intervals)
        assert actual == expected, (supplied, expected, actual)
        assert intervals == supplied, ("input changed", supplied, intervals)
    print("Independent verification passed: 6 cases, input preserved.")


if __name__ == "__main__":
    verify(sys.argv[1])
