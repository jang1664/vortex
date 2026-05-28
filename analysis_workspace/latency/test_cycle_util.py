import sys
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

import cycle_util


def test_count_cycle_tuples_partitions_denominator():
    denominator = set(range(6))
    cycle_sets = {
        'A': {0, 1, 4},
        'B': {1, 2},
    }

    df = cycle_util._count_cycle_tuples(denominator, cycle_sets)
    counts = dict(zip(df['cycle_tuple'], df['cycles']))

    assert counts == {
        'A': 2,
        'A+B': 1,
        'B': 1,
        'OTHER': 2,
    }
    assert df['cycles'].sum() == len(denominator)


def test_priority_partition_cycles_is_exclusive_and_complete():
    cycles = set(range(5))
    classes = [
        ('A', {0, 1}),
        ('B', {1, 2}),
        ('C', {4}),
    ]

    df = cycle_util._priority_partition_cycles(cycles, classes)
    counts = dict(zip(df['category'], df['cycles']))

    assert counts == {
        'A': 2,
        'B': 1,
        'C': 1,
        'UNCLASSIFIED': 1,
    }
    assert df['cycles'].sum() == len(cycles)
