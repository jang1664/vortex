"""CLI entry point for RTL log analyzer."""

import argparse
import json
import sys
from pathlib import Path

from .dma_analysis import check_dma_transactions
from .duration_profile import DurationProfiler, EventCondition, parse_match_expr
from log_analyzer.utils import split_log_by_simulation

DEFAULT_LOG_DIR = Path("rtl_runner/logs/fsim_logs")


def cmd_split_log(args):
    """Handle the split-log command."""
    log_file = Path(args.file)

    if not log_file.exists():
        print(f"Error: Log file not found: {log_file}", file=sys.stderr)
        sys.exit(1)

    output_dir = Path(args.output_dir) if args.output_dir else None

    print("=" * 70)
    print("  Split Log by Simulation")
    print("=" * 70)
    print(f"  Input file: {log_file}")
    print(f"  Output dir: {output_dir or log_file.parent}")
    print("-" * 70)

    output_files = split_log_by_simulation(log_file, output_dir)

    print(f"\n  Created {len(output_files)} file(s):")
    for i, path in enumerate(output_files):
        size = path.stat().st_size
        if size < 1024:
            size_str = f"{size} B"
        elif size < 1024 * 1024:
            size_str = f"{size / 1024:.1f} KB"
        else:
            size_str = f"{size / (1024 * 1024):.1f} MB"

        with open(path, "r") as fp:
            line_count = sum(1 for _ in fp)

        print(f"    [{i}] {path.name:40} {size_str:>10}  ({line_count:,} lines)")

    print("=" * 70)


def cmd_duration_profile(args):
    """Handle the duration-profile command."""
    target_file = args.log_file
    if target_file is not None:
        target_file = Path(target_file)
        if not target_file.exists():
            print(f"Error: Log file not found: {target_file}", file=sys.stderr)
            sys.exit(1)
        if not target_file.is_file():
            print(f"Error: Not a file: {target_file}", file=sys.stderr)
            sys.exit(1)
        log_dir = target_file.parent
        file_pattern = target_file.name
    else:
        log_dir = DEFAULT_LOG_DIR
        file_pattern = args.file_pattern

    if not Path(log_dir).exists():
        print(f"Error: Log directory not found: {log_dir}", file=sys.stderr)
        sys.exit(1)

    start_constraints = parse_match_expr(args.start_match) if args.start_match else []
    end_constraints = parse_match_expr(args.end_match) if args.end_match else []

    start_cond = EventCondition(event=args.start_event, constraints=start_constraints)
    end_cond = EventCondition(event=args.end_event, constraints=end_constraints)

    profiler = DurationProfiler(
        log_dir=log_dir,
        start_cond=start_cond,
        end_cond=end_cond,
        file_pattern=file_pattern,
        start_policy=args.start_policy,
        verbose=args.verbose,
    )
    profiler._sequential = args.sequential
    profiler.profile_all()

    stats = profiler.get_stats()

    print("=" * 90)
    print("  Duration Profile")
    print("=" * 90)
    if target_file is not None:
        print(f"  Log file:        {target_file}")
    else:
        print(f"  Log directory:   {log_dir}")
        print(f"  File pattern:    {file_pattern}")
    print(f"  Start condition: {start_cond}")
    print(f"  End condition:   {end_cond}")
    print(f"  Start policy:    {args.start_policy}")
    print(f"  Total files:     {stats['total_files']}")
    print(f"  Files matched:   {stats['files_with_matches']}")
    print(f"  Intervals:       {stats['count']}")
    print("-" * 90)

    if stats["count"] == 0:
        print("  No matching start/end pairs found.")
        print("=" * 90)
        return

    print()
    print("  Aggregate Statistics:")
    print(f"    Count:   {stats['count']}")
    print(f"    Min:     {stats['min']:,}")
    print(f"    Max:     {stats['max']:,}")
    print(f"    Avg:     {stats['avg']:,.1f}")
    print(f"    Median:  {stats['median']:,}")
    print(f"    Total:   {stats['total']:,}")

    per_file = profiler.get_per_file_stats()
    if per_file:
        print()
        print("  Per-file Breakdown:")
        print(f"  {'File':<60} {'Count':>6} {'Min':>14} {'Max':>14} {'Avg':>14}")
        print("  " + "-" * 110)
        for pf in per_file:
            fname = pf["file"]
            if len(fname) > 58:
                fname = "..." + fname[-55:]
            print(
                f"  {fname:<60} {pf['count']:>6} {pf['min']:>14,} {pf['max']:>14,} {pf['avg']:>14,.1f}"
            )

    if args.verbose:
        print()
        print("  All Intervals:")
        print(f"  {'#':>4} {'Start':>14} {'End':>14} {'Duration':>14}  {'File'}")
        print("  " + "-" * 90)
        for i, rec in enumerate(sorted(profiler.records, key=lambda r: r.start_time)):
            fname = rec.source_file
            if len(fname) > 35:
                fname = "..." + fname[-32:]
            print(
                f"  {i + 1:>4} {rec.start_time:>14,} {rec.end_time:>14,} {rec.duration:>14,}  {fname}"
            )

    print("=" * 90)


def cmd_dma_check(args):
    """Handle DMA transaction validation command."""
    log_file = Path(args.file)

    if not log_file.exists():
        print(f"Error: Log file not found: {log_file}", file=sys.stderr)
        sys.exit(1)

    try:
        report = check_dma_transactions(log_file)
    except Exception as exc:
        print(f"[FAIL] analyzer error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("=" * 70)
        print("  DMA Transaction Check (GMEM -> LMEM)")
        print("=" * 70)
        print(f"  log: {report['log_path']}")
        print(
            f"  shape: M={report['shape']['M']} "
            f"N={report['shape']['N']} K={report['shape']['K']}"
        )
        print(
            f"  checked starts: {report['num_checked_starts']} / "
            f"total starts: {report['num_dma_starts']}"
        )
        print("-" * 70)
        for check in report["checks"]:
            print(
                f"  - start@line{check['start_line']} "
                f"src={check['src_base']} dst={check['dst_base']} "
                f"wr {check['observed_wr']}/{check['expected_wr']} "
                f"rd {check['observed_rd']}/{check['expected_rd']} "
                f"mism={check['mismatch_count']}"
            )
        if report["pass"]:
            print("\n  [PASS] GMEM->LMEM DMA data check passed")
        else:
            print("\n  [FAIL] GMEM->LMEM DMA data check failed")
            for failure in report["failures"]:
                print(f"    - {failure}")
        print("=" * 70)

    sys.exit(0 if report["pass"] else 1)


def build_parser() -> argparse.ArgumentParser:
    """Build and return CLI parser."""
    parser = argparse.ArgumentParser(
        description="RTL Log Analyzer Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Duration profiling (measure time between event pairs)
  %(prog)s duration-profile --log-file hw/unittest/gemm_node/logs/sim_M2K32N64.log --start-event STATE_CHANGE --start-match "from=S_IDLE,to=S_COMPUTE" --end-event STATE_CHANGE --end-match "from=S_COMPUTE,to=S_IDLE"
  %(prog)s duration-profile --start-event STATE_CHANGE --start-match "from=S_IDLE,to=S_COMPUTE" --end-event STATE_CHANGE --end-match "from=S_COMPUTE,to=S_IDLE" -f "*ctrl_pl*" -v

  # DMA validation (GMEM->LMEM transfer correctness)
  %(prog)s dma-check -f hw/unittest/gemm_node/logs/sim.log
  %(prog)s dma-check -f hw/unittest/gemm_node/logs/sim.log --json

  # Split combined log into simulation segments
  %(prog)s split-log -f hw/unittest/gemm_node/logs/now.debug.log
  %(prog)s split-log -f hw/unittest/gemm_node/logs/now.debug.log -o /tmp/split_logs
""",
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    duration_profile_parser = subparsers.add_parser(
        "duration-profile",
        help="Measure duration between start/end event conditions",
        description=(
            "Measure time intervals between pairs of structured log events.\n"
            "Specify start/end conditions as event name + payload field matches.\n"
            "Use --log-file to analyze one specific file."
        ),
    )
    duration_profile_parser.add_argument(
        "--log-file",
        type=Path,
        default=None,
        help=(
            "Path to one log file to analyze. "
            f"If omitted, searches {DEFAULT_LOG_DIR} using --file-pattern."
        ),
    )
    duration_profile_parser.add_argument(
        "--start-event",
        required=True,
        help="Event name for start condition (e.g., STATE_CHANGE)",
    )
    duration_profile_parser.add_argument(
        "--start-match",
        default=None,
        help="Payload constraints for start. Operators: =, !=, >, >=, <, <=",
    )
    duration_profile_parser.add_argument(
        "--end-event",
        required=True,
        help="Event name for end condition (e.g., STATE_CHANGE)",
    )
    duration_profile_parser.add_argument(
        "--end-match",
        default=None,
        help="Payload constraints for end. Operators: =, !=, >, >=, <, <=",
    )
    duration_profile_parser.add_argument(
        "--file-pattern",
        "-f",
        default="*.log",
        help="Glob pattern for log files to search (default: *.log)",
    )
    duration_profile_parser.add_argument(
        "--start-policy",
        choices=["first", "last"],
        default="last",
        help=(
            "When multiple start events occur before an end: "
            "'first' keeps earliest start, 'last' uses latest (default: last)"
        ),
    )
    duration_profile_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show all individual intervals",
    )
    duration_profile_parser.add_argument(
        "--sequential",
        action="store_true",
        help="Disable parallel parsing (for debugging)",
    )
    duration_profile_parser.set_defaults(func=cmd_duration_profile)

    dma_check_parser = subparsers.add_parser(
        "dma-check",
        help="Validate GEMM-node DMA operations using structured DMA trace events",
    )
    dma_check_parser.add_argument(
        "--file",
        "-f",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "logs" / "sim.log",
        help="Path to simulation log file (default: hw/unittest/gemm_node/logs/sim.log)",
    )
    dma_check_parser.add_argument(
        "--json",
        action="store_true",
        help="Print full JSON report",
    )
    dma_check_parser.set_defaults(func=cmd_dma_check)

    split_log_parser = subparsers.add_parser(
        "split-log",
        help="Split log file by 'Simulation finished.' markers",
    )
    split_log_parser.add_argument(
        "--file",
        "-f",
        required=True,
        help="Path to the log file to split (e.g., now.debug.log)",
    )
    split_log_parser.add_argument(
        "--output-dir",
        "-o",
        default=None,
        help="Output directory for split files (default: same as input file)",
    )
    split_log_parser.set_defaults(func=cmd_split_log)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
