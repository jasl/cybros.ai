def merge_ranges(ranges):
    """Return sorted, merged intervals without changing the input."""
    ranges.sort()
    merged = []
    for start, end in ranges:
        if merged and start < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [tuple(interval) for interval in merged]
