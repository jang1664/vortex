"""CLI entry point for FSIM Log Analyzer."""

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

from .monitor import LogMonitor, DebugTestDirectory
from .packet import PacketAnalyzer
from .sync_trace import SyncTraceAnalyzer
from .stall_analysis import StallAnalyzer
from .duration_profile import DurationProfiler, EventCondition, parse_match_expr
from .recv_analysis import (
    count_recv_before_step,
    parse_expected_patterns_from_log,
    compare_recv_patterns,
)
from log_analyzer.utils import parse_patterns, split_log_by_simulation


def cmd_monitor(args):
    """Handle the monitor command."""
    test_dir = None
    log_dir = args.log_dir

    # If debug mode and no log_dir specified, create test directory
    if args.debug and log_dir is None:
        print("=" * 70)
        print("  DEBUG MODE - Creating test environment")
        print("=" * 70)
        test_dir = DebugTestDirectory()
        test_dir.create_test_files(count=10)
        test_dir.start_activity()
        log_dir = test_dir.test_dir
        print(f"Test directory: {log_dir}")
        print("Debug logging: /tmp/fsim_log_analyzer_debug.log")
        print("=" * 70)
        print()

    try:
        monitor = LogMonitor(
            log_dir=log_dir,
            check_interval=args.interval,
            deadlock_threshold=args.threshold,
            extensions=tuple(args.extensions.split(",")),
            include_patterns=parse_patterns(args.include),
            exclude_patterns=parse_patterns(args.exclude),
            verbose=args.verbose,
            debug=args.debug,
        )

        if args.debug and test_dir is None:
            print("Debug mode enabled - logging to /tmp/fsim_log_analyzer_debug.log")
            print()

        deadlock = monitor.monitor(duration=args.duration)
        sys.exit(1 if deadlock else 0)
    finally:
        if test_dir:
            print("\n\nCleaning up test environment...")
            test_dir.cleanup()
            print(f"Test directory preserved at: {test_dir.test_dir}")
            print("You can inspect it or delete with: rm -rf /tmp/fsim_debug_*")


def cmd_summary(args):
    """Handle the summary command."""
    monitor = LogMonitor(
        log_dir=args.log_dir,
        extensions=tuple(args.extensions.split(",")),
        include_patterns=parse_patterns(args.include),
        exclude_patterns=parse_patterns(args.exclude),
    )

    summary = monitor.summary()

    print("=" * 50)
    print("  FSIM Log Summary")
    print("=" * 50)
    print(f"  Directory: {summary['log_dir']}")
    if args.include:
        print(f"  Include: {args.include}")
    if args.exclude:
        print(f"  Exclude: {args.exclude}")
    print(f"  Total files: {summary['total_files']}")
    print(f"  Non-empty files: {summary['non_empty_files']}")
    print(f"  Empty files: {summary['empty_files']}")
    print(f"  Total size: {summary['total_size_mb']:.2f} MB")
    print("=" * 50)


def cmd_check(args):
    """Handle the single check command."""
    monitor = LogMonitor(
        log_dir=args.log_dir,
        deadlock_threshold=args.threshold,
        extensions=tuple(args.extensions.split(",")),
        include_patterns=parse_patterns(args.include),
        exclude_patterns=parse_patterns(args.exclude),
    )

    # Do initial check to populate file statuses
    monitor.check_once()

    # Wait and check again
    print(f"Checking for changes over {args.wait}s...")
    time.sleep(args.wait)

    result = monitor.check_once()

    if result["changed_files"]:
        print(f"\n{len(result['changed_files'])} files changed:")
        for f in result["changed_files"]:
            print(f"  - {f.name}")
        print("\nSimulation appears to be ACTIVE.")
        sys.exit(0)
    else:
        print(f"\nNo files changed in {args.wait}s.")
        print("Simulation may be STALLED or COMPLETE.")
        sys.exit(1)


def cmd_list(args):
    """Handle the list command."""
    monitor = LogMonitor(
        log_dir=args.log_dir,
        extensions=tuple(args.extensions.split(",")),
        include_patterns=parse_patterns(args.include),
        exclude_patterns=parse_patterns(args.exclude),
    )

    files = monitor._get_log_files()

    print("=" * 70)
    print("  Matching Log Files")
    print("=" * 70)
    print(f"  Directory: {monitor.log_dir}")
    if args.include:
        print(f"  Include: {args.include}")
    if args.exclude:
        print(f"  Exclude: {args.exclude}")
    print(f"  Total: {len(files)} files")
    print("-" * 70)

    if not files:
        print("  No matching files found.")
    else:
        for f in files:
            size, mtime = monitor._get_file_stat(f)
            size_str = f"{size:,}" if size > 0 else "(empty)"
            print(f"  {f.name}")
            if args.verbose:
                mtime_str = datetime.fromtimestamp(mtime).strftime(
                    "%Y-%m-%d %H:%M:%S"
                )
                print(f"      Size: {size_str} bytes | Modified: {mtime_str}")

    print("=" * 70)


def _run_packet_sanity_check(analyzer: PacketAnalyzer) -> bool:
    """Run sanity check and print results. Returns True if OK."""
    result = analyzer.sanity_check()

    if not result["ok"] or result["warnings"]:
        print("=" * 70)
        print("  Packet Log Sanity Check")
        print("=" * 70)

        for msg in result["errors"]:
            print(f"  [ERROR] {msg}")
        for msg in result["warnings"]:
            print(f"  [WARN]  {msg}")

        if result["duplicate_rx_local"]:
            print()
            print("  Duplicate RX LOCAL events (first 10):")
            for i, (uuid, locations) in enumerate(result["duplicate_rx_local"].items()):
                if i >= 10:
                    print(f"  ... and {len(result['duplicate_rx_local']) - 10} more")
                    break
                locs = ", ".join(f"{node}@{ts}" for node, ts in locations)
                print(f"    UUID {uuid}: {locs}")

        print("=" * 70)
        print()

    return result["ok"]


def cmd_packet_stats(args):
    """Handle the packet statistics command."""
    analyzer = PacketAnalyzer(log_dir=args.log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all_logs()
    _run_packet_sanity_check(analyzer)

    total_packets = len(analyzer.packets)
    delivered = analyzer.get_delivered_packets()
    undelivered = analyzer.get_undelivered_packets()
    latency_stats = analyzer.get_latency_stats()

    print("=" * 70)
    print("  Packet Statistics")
    print("=" * 70)
    print(f"  Total unique packets: {total_packets}")
    print(f"  Delivered packets: {len(delivered)}")
    print(f"  Undelivered packets: {len(undelivered)}")
    print(
        f"  Delivery rate: {len(delivered)/total_packets*100:.1f}%"
        if total_packets > 0
        else "  Delivery rate: N/A"
    )
    print()
    print("  Latency Statistics (for delivered packets):")
    print(f"    Count: {latency_stats['count']}")
    if latency_stats["count"] > 0:
        print(f"    Min: {latency_stats['min']:,} cycles")
        print(f"    Max: {latency_stats['max']:,} cycles")
        print(f"    Avg: {latency_stats['avg']:,.1f} cycles")
        print(f"    Median: {latency_stats['median']:,} cycles")
    print("=" * 70)


def cmd_packet_undelivered(args):
    """Handle the undelivered packets command."""
    analyzer = PacketAnalyzer(log_dir=args.log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all_logs()
    _run_packet_sanity_check(analyzer)

    undelivered = analyzer.get_undelivered_packets()

    print("=" * 70)
    print(f"  Undelivered Packets: {len(undelivered)}")
    print("=" * 70)

    if not undelivered:
        print("  No undelivered packets found!")
    else:
        # Sort by UUID
        undelivered.sort(key=lambda x: x.uuid)

        if args.limit:
            print(f"  (Showing first {args.limit} packets)")
            undelivered = undelivered[: args.limit]

        for trace in undelivered:
            print(f"\n  UUID: {trace.uuid}")
            print(f"    Issued at: {trace.issued_time:,} cycles")
            print(f"    Issued from: {trace.issued_node}")
            print(f"    Events: {len(trace.events)}")
            print(f"    Hops: {trace.hop_count}")

            if args.verbose:
                print("    Path:")
                for i, event in enumerate(
                    sorted(trace.events, key=lambda x: x.timestamp)
                ):
                    print(
                        f"      [{i}] {event.timestamp:15,} | {event.event_type} {event.direction:6} @ {event.node}"
                    )

    print("=" * 70)


def cmd_packet_trace(args):
    """Handle the packet trace command."""
    analyzer = PacketAnalyzer(log_dir=args.log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all_logs()
    _run_packet_sanity_check(analyzer)

    trace = analyzer.get_packet_by_uuid(args.uuid)

    if trace is None:
        print(f"Packet UUID {args.uuid} not found!")
        sys.exit(1)

    print("=" * 70)
    print(f"  Packet Trace for UUID: {args.uuid}")
    print("=" * 70)
    print(f"  Issued at: {trace.issued_time:,} cycles" if trace.issued_time else "  Issued at: Unknown")
    print(f"  Issued from: {trace.issued_node}" if trace.issued_node else "  Issued from: Unknown")
    print(f"  Delivered: {'Yes' if trace.is_delivered else 'No'}")

    if trace.is_delivered:
        print(f"  Delivered at: {trace.delivered_time:,} cycles")
        print(f"  Delivered to: {trace.delivered_node}")
        if trace.latency:
            print(f"  Latency: {trace.latency:,} cycles")

    print(f"  Total events: {len(trace.events)}")
    print(f"  Hop count: {trace.hop_count}")
    print()
    print("  Event Timeline:")
    print("  " + "-" * 66)

    for i, event in enumerate(sorted(trace.events, key=lambda x: x.timestamp)):
        print(
            f"  [{i:3}] T={event.timestamp:15,} | {event.event_type} {event.direction:6} @ {event.node}"
        )
        if args.verbose:
            print(f"        cmd={event.cmd}, fifo_id={event.fifo_id}, addr={event.addr}, word={event.word}")

    print("=" * 70)


def cmd_packet_node_stats(args):
    """Handle the node traffic statistics command."""
    analyzer = PacketAnalyzer(log_dir=args.log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all_logs()
    _run_packet_sanity_check(analyzer)

    stats = analyzer.get_node_traffic_stats()

    print("=" * 70)
    print("  Node Traffic Statistics")
    print("=" * 70)

    if not stats:
        print("  No traffic data found!")
    else:
        # Sort by total traffic
        sorted_stats = sorted(
            stats.items(), key=lambda x: x[1]["total_traffic"], reverse=True
        )

        if args.limit:
            print(f"  (Showing top {args.limit} nodes)")
            sorted_stats = sorted_stats[: args.limit]

        print(
            f"  {'Node':<40} {'RX':>8} {'TX':>8} {'Unique':>8} {'Total':>8}"
        )
        print("  " + "-" * 68)

        for node, data in sorted_stats:
            print(
                f"  {node:<40} {data['rx_count']:>8} {data['tx_count']:>8} {data['unique_packets']:>8} {data['total_traffic']:>8}"
            )

    print("=" * 70)


def cmd_packet_hotspots(args):
    """Handle the hotspot detection command."""
    analyzer = PacketAnalyzer(log_dir=args.log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all_logs()
    _run_packet_sanity_check(analyzer)

    hotspots = analyzer.get_hotspots(top_n=args.top_n, metric=args.metric)

    print("=" * 70)
    print(f"  Top {args.top_n} Traffic Hotspots (by {args.metric})")
    print("=" * 70)

    if not hotspots:
        print("  No traffic data found!")
    else:
        for i, (node, data) in enumerate(hotspots, 1):
            print(f"\n  [{i}] {node}")
            print(f"      RX count: {data['rx_count']:,}")
            print(f"      TX count: {data['tx_count']:,}")
            print(f"      Unique packets: {data['unique_packets']:,}")
            print(f"      Total traffic: {data['total_traffic']:,}")

    print("=" * 70)


def cmd_packet_cmd_stats(args):
    """Handle the command type statistics."""
    analyzer = PacketAnalyzer(log_dir=args.log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all_logs()
    _run_packet_sanity_check(analyzer)

    cmd_stats = analyzer.get_cmd_type_stats()

    print("=" * 70)
    print("  Command Type Statistics")
    print("=" * 70)

    if not cmd_stats:
        print("  No command data found!")
    else:
        total = sum(cmd_stats.values())
        sorted_cmds = sorted(
            cmd_stats.items(), key=lambda x: x[1], reverse=True
        )

        print(f"  {'Command':<30} {'Count':>12} {'Percentage':>12}")
        print("  " + "-" * 56)

        for cmd, count in sorted_cmds:
            percentage = count / total * 100 if total > 0 else 0
            print(f"  {cmd:<30} {count:>12,} {percentage:>11.1f}%")

        print("  " + "-" * 56)
        print(f"  {'TOTAL':<30} {total:>12,} {100.0:>11.1f}%")

    print("=" * 70)


def cmd_recv_before_step(args):
    """Handle the recv-before-step command."""
    log_file = Path(args.file)

    if not log_file.exists():
        print(f"Error: Log file not found: {log_file}", file=sys.stderr)
        sys.exit(1)

    rd_filter = args.rd if hasattr(args, 'rd') else None
    results = count_recv_before_step(log_file, args.imce, rd_filter=rd_filter)

    print("=" * 70)
    print(f"  RECV Count Before STEP - {args.imce}")
    if rd_filter is not None:
        print(f"  (Filtering OP_RECV with rd={rd_filter})")
    print("=" * 70)
    print(f"  Log file: {log_file}")
    print(f"  Total STEPs: {len(results)}")
    print("-" * 70)

    if not results:
        print(f"  No OP_STEP found for {args.imce}")
    else:
        print(f"  {'STEP#':>6} {'RECV Count':>12} {'PC':>8} {'UID':>10}")
        print("  " + "-" * 40)

        total_recv = 0
        for r in results:
            print(f"  {r['step_index']:>6} {r['recv_count']:>12} {r['pc']:>8} {r['uid']:>10}")
            total_recv += r['recv_count']

        print("  " + "-" * 40)
        print(f"  {'TOTAL':>6} {total_recv:>12}")

        if results:
            avg_recv = total_recv / len(results)
            print(f"  {'AVG':>6} {avg_recv:>12.1f}")

    print("=" * 70)


def cmd_compare_recv_pattern(args):
    """Handle the compare-recv-pattern command."""
    log_file = Path(args.file)
    pattern_file = Path(args.pattern_file)

    if not log_file.exists():
        print(f"Error: Log file not found: {log_file}", file=sys.stderr)
        sys.exit(1)

    if not pattern_file.exists():
        print(f"Error: Pattern file not found: {pattern_file}", file=sys.stderr)
        sys.exit(1)

    # Parse expected patterns from test_random.log
    expected_patterns = parse_expected_patterns_from_log(pattern_file)

    if args.node not in expected_patterns:
        print(f"Error: Node {args.node} not found in pattern file", file=sys.stderr)
        print(f"Available nodes: {sorted(expected_patterns.keys())}", file=sys.stderr)
        sys.exit(1)

    expected = expected_patterns[args.node]

    # Apply scale factor to expected values (ConvBlock.num_blocks = 4)
    scale = args.scale if hasattr(args, 'scale') else 1
    if scale != 1:
        expected = [e * scale for e in expected]

    # Parse actual RECV counts from debug log
    rd_filter = args.rd if hasattr(args, 'rd') and args.rd is not None else 0
    actual = count_recv_before_step(log_file, args.imce, rd_filter=rd_filter)

    # Compare
    result = compare_recv_patterns(actual, expected)

    print("=" * 70)
    print(f"  Pattern Comparison - Node {args.node} / {args.imce}")
    print("=" * 70)
    print(f"  Debug log: {log_file}")
    print(f"  Pattern file: {pattern_file}")
    print(f"  OP_RECV filter: rd={rd_filter}")
    print(f"  Scale factor: {scale}x (expected values multiplied)")
    print("-" * 70)
    print(f"  Expected STEPs: {result['expected_count']}")
    print(f"  Actual STEPs:   {result['actual_count']}")
    print(f"  Matches:        {result['matches']}")
    print(f"  Mismatches:     {len(result['mismatches'])}")
    print("-" * 70)

    if result['mismatches']:
        print("\n  Mismatches (first 20):")
        print(f"  {'Index':>6} {'Expected':>10} {'Actual':>10} {'PC':>8}")
        print("  " + "-" * 38)
        for m in result['mismatches'][:20]:
            print(f"  {m['index']:>6} {m['expected']:>10} {m['actual']:>10} {m['pc']:>8}")
        if len(result['mismatches']) > 20:
            print(f"  ... and {len(result['mismatches']) - 20} more")

    # Show side-by-side comparison if verbose
    if args.verbose:
        print("\n  Full comparison:")
        print(f"  {'Index':>6} {'Expected':>10} {'Actual':>10} {'Match':>8}")
        print("  " + "-" * 38)
        max_len = max(len(expected), len(result['actual_counts']))
        for i in range(max_len):
            exp = expected[i] if i < len(expected) else '-'
            act = result['actual_counts'][i] if i < len(result['actual_counts']) else '-'
            match_str = "OK" if exp == act else "MISMATCH"
            print(f"  {i:>6} {str(exp):>10} {str(act):>10} {match_str:>8}")

    print("=" * 70)


def cmd_sync_trace(args):
    """Handle the sync-trace command."""
    log_dir = args.log_dir or LogMonitor.DEFAULT_LOG_DIR

    if not Path(log_dir).exists():
        print(f"Error: Log directory not found: {log_dir}", file=sys.stderr)
        sys.exit(1)

    analyzer = SyncTraceAnalyzer(
        log_dir=log_dir,
        nodes=args.nodes,
        verbose=args.verbose,
    )
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all()

    # Apply time range filter
    events = analyzer.get_events_in_range(
        start_time=args.start_time,
        end_time=args.end_time,
    )

    # Apply event type filter
    if args.event_types:
        event_types = [t.strip().upper() for t in args.event_types.split(",")]
        events = [e for e in events if any(t in e.event_type.upper() for t in event_types)]

    print("=" * 90)
    print(f"  Sync Trace: {', '.join(args.nodes)}")
    print("=" * 90)
    print(f"  Log directory: {log_dir}")
    print(f"  Total events: {len(events)}")
    if args.start_time:
        print(f"  Start time: {args.start_time:,}")
    if args.end_time:
        print(f"  End time: {args.end_time:,}")
    if args.event_types:
        print(f"  Event filter: {args.event_types}")
    print("-" * 90)

    if not events:
        print("  No events found!")
    else:
        # Apply limit
        display_events = events
        if args.limit:
            display_events = events[:args.limit]

        print(f"\n  {'Time':>15} {'Node':<15} {'Event':<20} {'Details'}")
        print("  " + "-" * 85)

        for event in display_events:
            node_short = event.node.replace("_", ".")
            payload_str = ", ".join(f"{k}={v}" for k, v in event.payload.items()) if event.payload else ""
            details_short = payload_str[:40] + "..." if len(payload_str) > 40 else payload_str
            print(f"  {event.timestamp:>15,} {node_short:<15} {event.event_type:<20} {details_short}")

        if args.limit and len(events) > args.limit:
            print(f"\n  ... and {len(events) - args.limit} more events")

    print("=" * 90)

    # Output to file if specified
    if args.output:
        output_path = Path(args.output)
        with open(output_path, "w") as f:
            f.write(f"# Sync Trace: {', '.join(args.nodes)}\n")
            f.write(f"# Log directory: {log_dir}\n")
            f.write(f"# Total events: {len(events)}\n")
            f.write("#" + "=" * 89 + "\n")
            f.write(f"# {'Time':>14} | {'Node':<15} | {'Event':<20} | Details\n")
            f.write("#" + "-" * 89 + "\n")

            for event in events:
                node_short = event.node.replace("_", ".")
                payload_str = ", ".join(f"{k}={v}" for k, v in event.payload.items()) if event.payload else ""
                f.write(f"{event.timestamp:>15} | {node_short:<15} | {event.event_type:<20} | {payload_str}\n")

        print(f"\n  Output written to: {output_path}")


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
    for i, f in enumerate(output_files):
        # Get file size
        size = f.stat().st_size
        if size < 1024:
            size_str = f"{size} B"
        elif size < 1024 * 1024:
            size_str = f"{size / 1024:.1f} KB"
        else:
            size_str = f"{size / (1024 * 1024):.1f} MB"

        # Count lines
        with open(f, "r") as fp:
            line_count = sum(1 for _ in fp)

        print(f"    [{i}] {f.name:40} {size_str:>10}  ({line_count:,} lines)")

    print("=" * 70)


def cmd_duration_profile(args):
    """Handle the duration-profile command."""
    log_dir = args.log_dir or LogMonitor.DEFAULT_LOG_DIR

    if not Path(log_dir).exists():
        print(f"Error: Log directory not found: {log_dir}", file=sys.stderr)
        sys.exit(1)

    # Build conditions
    start_constraints = parse_match_expr(args.start_match) if args.start_match else []
    end_constraints = parse_match_expr(args.end_match) if args.end_match else []

    start_cond = EventCondition(event=args.start_event, constraints=start_constraints)
    end_cond = EventCondition(event=args.end_event, constraints=end_constraints)

    profiler = DurationProfiler(
        log_dir=log_dir,
        start_cond=start_cond,
        end_cond=end_cond,
        file_pattern=args.file_pattern,
        start_policy=args.start_policy,
        verbose=args.verbose,
    )
    profiler._sequential = getattr(args, "sequential", False)
    profiler.profile_all()

    stats = profiler.get_stats()

    print("=" * 90)
    print("  Duration Profile")
    print("=" * 90)
    print(f"  Log directory:  {log_dir}")
    print(f"  File pattern:   {args.file_pattern}")
    print(f"  Start condition: {start_cond}")
    print(f"  End condition:   {end_cond}")
    print(f"  Start policy:   {args.start_policy}")
    print(f"  Total files:    {stats['total_files']}")
    print(f"  Files matched:  {stats['files_with_matches']}")
    print(f"  Intervals:      {stats['count']}")
    print("-" * 90)

    if stats["count"] == 0:
        print("  No matching start/end pairs found.")
        print("=" * 90)
        return

    # Aggregate stats
    print()
    print("  Aggregate Statistics:")
    print(f"    Count:   {stats['count']}")
    print(f"    Min:     {stats['min']:,}")
    print(f"    Max:     {stats['max']:,}")
    print(f"    Avg:     {stats['avg']:,.1f}")
    print(f"    Median:  {stats['median']:,}")
    print(f"    Total:   {stats['total']:,}")

    # Per-file breakdown
    per_file = profiler.get_per_file_stats()
    if per_file:
        print()
        print("  Per-file Breakdown:")
        print(f"  {'File':<60} {'Count':>6} {'Min':>14} {'Max':>14} {'Avg':>14}")
        print("  " + "-" * 110)
        for pf in per_file:
            fname = pf["file"]
            # Shorten long filenames
            if len(fname) > 58:
                fname = "..." + fname[-55:]
            print(
                f"  {fname:<60} {pf['count']:>6} {pf['min']:>14,} {pf['max']:>14,} {pf['avg']:>14,.1f}"
            )

    # Detailed records (verbose mode)
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
                f"  {i+1:>4} {rec.start_time:>14,} {rec.end_time:>14,} {rec.duration:>14,}  {fname}"
            )

    print("=" * 90)


def cmd_find_stalls(args):
    """Handle the find-stalls command."""
    log_dir = args.log_dir or LogMonitor.DEFAULT_LOG_DIR

    if not Path(log_dir).exists():
        print(f"Error: Log directory not found: {log_dir}", file=sys.stderr)
        sys.exit(1)

    analyzer = StallAnalyzer(log_dir=log_dir, verbose=args.verbose)
    analyzer._sequential = getattr(args, 'sequential', False)
    analyzer.parse_all()

    # Filter by node type if specified
    stalls = analyzer.stalls
    if args.node_type:
        stalls = [s for s in stalls if s.node_type == args.node_type]

    summary = analyzer.get_stall_summary()

    print("=" * 90)
    print("  Find Stalls: Nodes stalled at end of simulation")
    print("=" * 90)
    print(f"  Log directory: {log_dir}")
    print(f"  Total nodes:   {summary['total_nodes']}")
    print(f"  Stalled nodes: {summary['stalled_nodes']}")
    print(f"  Active stalls: {len(stalls)}")
    if args.node_type:
        print(f"  Filter:        {args.node_type} only")
    print("-" * 90)

    if not stalls:
        print("  No nodes are stalled at the end of simulation.")
    else:
        print(f"\n  {'Time':>15}  {'Node':<15} {'Stall Type':<12} {'Reason':<20} {'Extra'}")
        print("  " + "-" * 85)

        for s in stalls:
            node_label = f"{s.node_type}({s.row},{s.col})"
            # Build extra payload string (exclude 'reason' since it's shown separately)
            extra_parts = []
            for k, v in s.payload.items():
                if k != "reason":
                    extra_parts.append(f"{k}={v}")
            extra = ", ".join(extra_parts) if extra_parts else ""

            print(f"  {s.start_time:>15,}  {node_label:<15} {s.stall_type:<12} {s.reason:<20} {extra}")

    # Summary by reason
    if summary["by_reason"]:
        print()
        print("  Summary by reason:")
        for reason, count in summary["by_reason"].items():
            print(f"    {reason:<25} {count} stall(s)")

    if summary["by_node_type"]:
        print()
        print("  Summary by node type:")
        for nt, count in summary["by_node_type"].items():
            print(f"    {nt:<25} {count} stall(s)")

    print("=" * 90)


def main():
    parser = argparse.ArgumentParser(
        description="FSIM Log Analyzer Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Monitor logs for deadlock with default settings
  %(prog)s monitor

  # Monitor with custom threshold
  %(prog)s monitor --threshold 60

  # Monitor only router logs
  %(prog)s monitor --include "*router*"

  # Monitor excluding policy_table logs
  %(prog)s monitor --exclude "*policy_table*"

  # Monitor specific module patterns
  %(prog)s monitor --include "*inode*,*ex_stage*"

  # Quick check if simulation is active
  %(prog)s check --wait 5

  # Get summary of log files
  %(prog)s summary

  # List matching files before monitoring
  %(prog)s --include "*router*" list
  %(prog)s --include "*router*" list -v  # with details

  # Packet analysis commands
  %(prog)s packet-stats -d <log_dir>  # Overall packet statistics
  %(prog)s packet-undelivered -d <log_dir>  # Find undelivered packets
  %(prog)s packet-trace -d <log_dir> --uuid 123  # Trace specific packet
  %(prog)s packet-node-stats -d <log_dir>  # Node traffic statistics
  %(prog)s packet-hotspots -d <log_dir>  # Find traffic hotspots
  %(prog)s packet-cmd-stats -d <log_dir>  # Command type statistics

  # IMCE instruction analysis
  %(prog)s recv-before-step --imce IMCE.2.1 -f <log_file>  # Count RECV before STEP

  # Sync trace between nodes (extract set_flag, standby events)
  %(prog)s sync-trace -n inode_0_0 imce_3_4  # Trace sync events between nodes
  %(prog)s sync-trace -n inode.0.0 imce.3.4 -s 430000000 -e 440000000  # With time range
  %(prog)s sync-trace -n inode_0_0 imce_3_4 -t STANDBY,SETFLAG  # Filter event types
  %(prog)s sync-trace -n inode_0_0 imce_3_4 -o sync_trace.txt  # Save to file

  # Duration profiling (measure time between event pairs)
  %(prog)s duration-profile -d <log_dir> --start-event STATE_CHANGE --start-match "from=S_IDLE,to=S_COMPUTE" --end-event STATE_CHANGE --end-match "from=S_COMPUTE,to=S_IDLE" -f "*ctrl_pl*"
  %(prog)s duration-profile -d <log_dir> --start-event STATE_CHANGE --start-match "from=S_IDLE,to=S_COMPUTE" --end-event STATE_CHANGE --end-match "from=S_COMPUTE,to=S_IDLE" -f "*ctrl_pl*" -v

  # Find stalled nodes at end of simulation
  %(prog)s find-stalls -d <log_dir>  # All stalled nodes
  %(prog)s find-stalls -d <log_dir> --node-type imce  # Only IMCE nodes
  %(prog)s find-stalls -d <log_dir> -v  # Verbose output
""",
    )

    parser.add_argument(
        "--log-dir",
        "-d",
        type=Path,
        default=None,
        help="Log directory (default: rtl_runner/logs/fsim_logs)",
    )
    parser.add_argument(
        "--extensions",
        "-e",
        default=".log",
        help="Comma-separated file extensions to monitor (default: .log)",
    )
    parser.add_argument(
        "--include",
        "-I",
        default=None,
        help="Comma-separated glob patterns to include (e.g., '*router*,*ex_stage*')",
    )
    parser.add_argument(
        "--exclude",
        "-X",
        default=None,
        help="Comma-separated glob patterns to exclude (e.g., '*policy_table*')",
    )
    parser.add_argument(
        "--sequential",
        action="store_true",
        help="Disable grep-based optimization and parallel parsing (for debugging)",
    )

    subparsers = parser.add_subparsers(
        dest="command", help="Available commands"
    )

    # Monitor command
    monitor_parser = subparsers.add_parser(
        "monitor", help="Continuously monitor log files for changes"
    )
    monitor_parser.add_argument(
        "--interval",
        "-i",
        type=float,
        default=2.0,
        help="Check interval in seconds (default: 2.0)",
    )
    monitor_parser.add_argument(
        "--threshold",
        "-t",
        type=float,
        default=30.0,
        help="Deadlock threshold in seconds (default: 30.0)",
    )
    monitor_parser.add_argument(
        "--duration",
        type=float,
        default=None,
        help="Maximum monitoring duration in seconds (default: unlimited)",
    )
    monitor_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed information",
    )
    monitor_parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging to /tmp/fsim_log_analyzer_debug.log. "
             "If --log-dir is not specified, creates a test directory with simulated file activity.",
    )
    monitor_parser.set_defaults(func=cmd_monitor)

    # Summary command
    summary_parser = subparsers.add_parser(
        "summary", help="Show summary of log files"
    )
    summary_parser.set_defaults(func=cmd_summary)

    # Check command
    check_parser = subparsers.add_parser(
        "check", help="Single check if simulation is active"
    )
    check_parser.add_argument(
        "--wait",
        "-w",
        type=float,
        default=5.0,
        help="Wait time before checking (default: 5.0s)",
    )
    check_parser.add_argument(
        "--threshold",
        "-t",
        type=float,
        default=30.0,
        help="Deadlock threshold in seconds (default: 30.0)",
    )
    check_parser.set_defaults(func=cmd_check)

    # List command
    list_parser = subparsers.add_parser(
        "list", help="List files matching the current filter patterns"
    )
    list_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show file size and modification time",
    )
    list_parser.set_defaults(func=cmd_list)

    # Packet stats command
    packet_stats_parser = subparsers.add_parser(
        "packet-stats", help="Show overall packet statistics"
    )
    packet_stats_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed information",
    )
    packet_stats_parser.set_defaults(func=cmd_packet_stats)

    # Packet undelivered command
    packet_undelivered_parser = subparsers.add_parser(
        "packet-undelivered",
        help="Find packets that were issued but not delivered",
    )
    packet_undelivered_parser.add_argument(
        "--limit",
        "-l",
        type=int,
        default=None,
        help="Limit number of packets to display",
    )
    packet_undelivered_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed path information",
    )
    packet_undelivered_parser.set_defaults(func=cmd_packet_undelivered)

    # Packet trace command
    packet_trace_parser = subparsers.add_parser(
        "packet-trace", help="Trace a specific packet by UUID"
    )
    packet_trace_parser.add_argument(
        "--uuid",
        "-u",
        type=int,
        required=True,
        help="UUID of the packet to trace",
    )
    packet_trace_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed event information",
    )
    packet_trace_parser.set_defaults(func=cmd_packet_trace)

    # Packet node stats command
    packet_node_stats_parser = subparsers.add_parser(
        "packet-node-stats", help="Show traffic statistics by node"
    )
    packet_node_stats_parser.add_argument(
        "--limit",
        "-l",
        type=int,
        default=None,
        help="Limit number of nodes to display",
    )
    packet_node_stats_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed information",
    )
    packet_node_stats_parser.set_defaults(func=cmd_packet_node_stats)

    # Packet hotspots command
    packet_hotspots_parser = subparsers.add_parser(
        "packet-hotspots", help="Find traffic hotspots in the NoC"
    )
    packet_hotspots_parser.add_argument(
        "--top-n",
        "-n",
        type=int,
        default=5,
        help="Number of top hotspots to show (default: 5)",
    )
    packet_hotspots_parser.add_argument(
        "--metric",
        "-m",
        choices=["total_traffic", "rx_count", "tx_count", "unique_packets"],
        default="total_traffic",
        help="Metric to sort by (default: total_traffic)",
    )
    packet_hotspots_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed information",
    )
    packet_hotspots_parser.set_defaults(func=cmd_packet_hotspots)

    # Packet cmd stats command
    packet_cmd_stats_parser = subparsers.add_parser(
        "packet-cmd-stats", help="Show statistics by command type"
    )
    packet_cmd_stats_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed information",
    )
    packet_cmd_stats_parser.set_defaults(func=cmd_packet_cmd_stats)

    # Recv before step command
    recv_before_step_parser = subparsers.add_parser(
        "recv-before-step",
        help="Count successful OP_RECV before each OP_STEP for an IMCE",
    )
    recv_before_step_parser.add_argument(
        "--imce",
        required=True,
        help="IMCE identifier (e.g., 'IMCE.2.1')",
    )
    recv_before_step_parser.add_argument(
        "--file",
        "-f",
        required=True,
        help="Path to the log file (e.g., now.debug.log)",
    )
    recv_before_step_parser.add_argument(
        "--rd",
        type=int,
        default=None,
        help="Filter OP_RECV by rd value (e.g., 0 for load_lb)",
    )
    recv_before_step_parser.set_defaults(func=cmd_recv_before_step)

    # Compare recv pattern command
    compare_recv_pattern_parser = subparsers.add_parser(
        "compare-recv-pattern",
        help="Compare actual RECV counts with expected pattern from test log",
    )
    compare_recv_pattern_parser.add_argument(
        "--imce",
        required=True,
        help="IMCE identifier (e.g., 'IMCE.3.1')",
    )
    compare_recv_pattern_parser.add_argument(
        "--node",
        type=int,
        required=True,
        help="Node ID from hw_node_map (e.g., 21 for node that maps to IMCE)",
    )
    compare_recv_pattern_parser.add_argument(
        "--file",
        "-f",
        required=True,
        help="Path to the debug log file (e.g., now.debug.log)",
    )
    compare_recv_pattern_parser.add_argument(
        "--pattern-file",
        "-p",
        required=True,
        help="Path to the pattern file (e.g., test_random.log)",
    )
    compare_recv_pattern_parser.add_argument(
        "--rd",
        type=int,
        default=0,
        help="Filter OP_RECV by rd value (default: 0 for load_lb)",
    )
    compare_recv_pattern_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show full side-by-side comparison",
    )
    compare_recv_pattern_parser.add_argument(
        "--scale",
        "-s",
        type=int,
        default=1,
        help="Scale factor for expected values (default: 1, use 4 for ConvBlock.num_blocks)",
    )
    compare_recv_pattern_parser.set_defaults(func=cmd_compare_recv_pattern)

    # Sync trace command
    sync_trace_parser = subparsers.add_parser(
        "sync-trace",
        help="Extract set_flag, standby sync events between nodes",
    )
    sync_trace_parser.add_argument(
        "--nodes",
        "-n",
        nargs="+",
        required=True,
        help="Node identifiers (e.g., inode_0_0 imce_3_4 or inode.0.0 imce.3.4)",
    )
    sync_trace_parser.add_argument(
        "--start-time",
        "-s",
        type=int,
        default=None,
        help="Start time (simulation cycles) to filter events",
    )
    sync_trace_parser.add_argument(
        "--end-time",
        "-e",
        type=int,
        default=None,
        help="End time (simulation cycles) to filter events",
    )
    sync_trace_parser.add_argument(
        "--event-types",
        "-t",
        default=None,
        help="Comma-separated event types to filter (e.g., 'STANDBY,SETFLAG')",
    )
    sync_trace_parser.add_argument(
        "--limit",
        "-l",
        type=int,
        default=None,
        help="Limit number of events to display",
    )
    sync_trace_parser.add_argument(
        "--output",
        "-o",
        default=None,
        help="Output file path to save the trace",
    )
    sync_trace_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed parsing information",
    )
    sync_trace_parser.set_defaults(func=cmd_sync_trace)

    # Split log command
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

    # Duration profile command
    duration_profile_parser = subparsers.add_parser(
        "duration-profile",
        help="Measure duration between start/end event conditions",
        description=(
            "Measure time intervals between pairs of structured log events.\n"
            "Specify start/end conditions as event name + payload field matches."
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
        help="Payload field constraints for start. Operators: =, !=, >, >=, <, <= "
             "(e.g., 'from=S_IDLE,to=S_COMPUTE' or 'addr!=0,count>=5')",
    )
    duration_profile_parser.add_argument(
        "--end-event",
        required=True,
        help="Event name for end condition (e.g., STATE_CHANGE)",
    )
    duration_profile_parser.add_argument(
        "--end-match",
        default=None,
        help="Payload field constraints for end. Operators: =, !=, >, >=, <, <= "
             "(e.g., 'from=S_COMPUTE,to=S_IDLE')",
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
        help="When multiple start events occur before an end: "
             "'first' keeps the earliest start, 'last' overwrites with the latest (default: last)",
    )
    duration_profile_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show all individual intervals",
    )
    duration_profile_parser.set_defaults(func=cmd_duration_profile)

    # Find stalls command
    find_stalls_parser = subparsers.add_parser(
        "find-stalls",
        help="Find nodes that are stalled at end of simulation",
    )
    find_stalls_parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show detailed parsing information",
    )
    find_stalls_parser.add_argument(
        "--node-type",
        choices=["inode", "imce"],
        default=None,
        help="Filter by node type (inode or imce)",
    )
    find_stalls_parser.set_defaults(func=cmd_find_stalls)

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
