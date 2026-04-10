"""CLI entry point for fsdb_cli.

Usage:
    python -m fsdb_cli info  <fsdb>
    python -m fsdb_cli hier  <fsdb> [scope] [-l N]
    python -m fsdb_cli find  <fsdb> <pattern>
    python -m fsdb_cli cut   <fsdb> -s <scope> [-bt T] [-et T] [-o out.fsdb]
    python -m fsdb_cli events <fsdb> -s <sig> [...] [-bt T] [-et T]
    python -m fsdb_cli metric <fsdb> latency -req <sig> -ack <sig> [-bt T] [-et T]
    python -m fsdb_cli metric <fsdb> stall   -valid <sig> -ready <sig> [-bt T] [-et T]
    python -m fsdb_cli metric <fsdb> state   -signal <sig> [-bt T] [-et T]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

from fsdb_cli.backends import (
    run_fsdbdebug,
    run_fsdbextract,
    run_fsdbreport,
    run_fsdbreport_file,
)
from fsdb_cli.parsers import (
    FsdbInfo,
    format_csv_table,
    format_scope_flat,
    format_scope_tree,
    parse_csv_report,
    parse_full_tree,
    parse_fsdb_info,
    parse_scope_tree,
    parse_tree_vars,
)
from fsdb_cli.analyzers import (
    events_from_csv,
    handshake_latency,
    stall_ratio,
    state_residency,
)


def cmd_info(args: argparse.Namespace) -> None:
    """Show FSDB file metadata."""
    raw = run_fsdbdebug(["-info"], args.fsdb)
    info = parse_fsdb_info(raw)

    def _fmt(label: str, val: str) -> str:
        return f"  {label:<30s} {val}"

    print(f"FSDB: {args.fsdb}")
    print(_fmt("version", info.fsdb_version))
    print(_fmt("status", info.file_status))
    print(_fmt("type", info.file_type))
    print(_fmt("scale unit", info.scale_unit))
    print(_fmt("sim date", info.simulation_date))
    print(_fmt("simulator", info.simulator_type))
    print(_fmt("sim version", info.simulator_version))
    print(_fmt("time range", f"{info.min_time} .. {info.max_time}"))
    print(_fmt("scopes", str(info.scope_count)))
    print(_fmt("signals", str(info.var_count)))
    print(_fmt("max var id", str(info.max_var_idcode)))

    if info.extra:
        print()
        for k, v in info.extra.items():
            if v:
                print(_fmt(k, v))


def cmd_hier(args: argparse.Namespace) -> None:
    """List hierarchy tree."""
    import tempfile

    show_vars = args.signals
    level = args.level
    max_depth = None if level == 0 else (level if level else 1)

    scope_path_parts: list[str] = []
    if args.scope:
        scope_path_parts = [p for p in args.scope.strip("/").split("/") if p]

    if show_vars:
        if not scope_path_parts:
            print("Error: --signals requires a scope to be specified.", file=sys.stderr)
            print("Usage: fsdb hier <fsdb> <scope> -S", file=sys.stderr)
            sys.exit(1)

        # Strategy: extract scope to small temp FSDB, then parse -tree.
        # fsdbdebug -tree on the full FSDB is too slow for large files,
        # but on an extracted scope it takes milliseconds.
        scope_str = "/" + "/".join(scope_path_parts)
        with tempfile.NamedTemporaryFile(suffix=".fsdb", delete=False) as f:
            tmp_fsdb = f.name
        try:
            extract_level = max_depth if max_depth is not None else 0
            run_fsdbextract(
                args.fsdb, scope=scope_str, level=extract_level,
                output=tmp_fsdb,
            )
            raw = run_fsdbdebug(["-tree"], tmp_fsdb)
            tree = parse_full_tree(raw)
            start = tree
            # Navigate to target scope in the extracted tree
            for part in scope_path_parts:
                found = None
                for child in start.children:
                    if child.name == part:
                        found = child
                        break
                if found is None:
                    break
                start = found
        finally:
            os.unlink(tmp_fsdb)

    else:
        # -scope is fast, scopes only
        raw = run_fsdbdebug(["-scope"], args.fsdb)
        tree = parse_scope_tree(raw)

        start = tree
        for part in scope_path_parts:
            found = None
            for child in start.children:
                if child.name == part:
                    found = child
                    break
            if found is None:
                print(f"Scope not found: {args.scope}", file=sys.stderr)
                print(f"Available at this level:", file=sys.stderr)
                for child in start.children:
                    print(f"  {child.name}/", file=sys.stderr)
                sys.exit(1)
            start = found

    if args.mode == "flat":
        flat_prefix = "/".join(scope_path_parts) if scope_path_parts else ""
        lines = format_scope_flat(start, prefix=flat_prefix, max_depth=max_depth,
                                  show_vars=show_vars)
    else:
        lines = format_scope_tree(start, max_depth=max_depth, show_vars=show_vars)
    for line in lines:
        print(line)


def cmd_find(args: argparse.Namespace) -> None:
    """Find signals matching a regex pattern."""
    raw = run_fsdbdebug(["-tree"], args.fsdb)
    all_vars = parse_tree_vars(raw)

    pattern = re.compile(args.pattern, re.IGNORECASE)
    matches = [v for v in all_vars if pattern.search(v.name)]

    if not matches:
        print(f"No signals matching '{args.pattern}'", file=sys.stderr)
        return

    for v in matches:
        bits_str = f"[{v.bits}]" if v.bits else ""
        print(f"  {v.name}{bits_str}  ({v.type}, id={v.id}, {v.width}B)")


def cmd_cut(args: argparse.Namespace) -> None:
    """Extract a sub-FSDB by scope and/or time range."""
    output = args.output or "extracted.fsdb"
    result = run_fsdbextract(
        args.fsdb,
        scope=args.scope,
        level=args.level,
        bt=args.bt,
        et=args.et,
        output=output,
    )
    print(f"Extracted: {output}")
    if result.strip():
        print(result)


def cmd_events(args: argparse.Namespace) -> None:
    """Dump signal value changes as a table."""
    raw = run_fsdbreport_file(
        args.fsdb,
        args.signals,
        bt=args.bt,
        et=args.et,
    )
    time_unit, signal_names, data_rows = parse_csv_report(raw)

    if args.csv:
        print(raw, end="")
        return

    table = format_csv_table(time_unit, signal_names, data_rows)
    print(table)
    print(f"\n({len(data_rows)} transitions)")


def cmd_metric(args: argparse.Namespace) -> None:
    """Compute performance metrics from signal value changes."""
    # Collect all signals needed
    signals = []
    if args.metric_type == "latency":
        signals = [args.req, args.ack]
    elif args.metric_type == "stall":
        signals = [args.valid, args.ready]
    elif args.metric_type == "state":
        signals = [args.signal]
    else:
        print(f"Unknown metric: {args.metric_type}", file=sys.stderr)
        sys.exit(1)

    raw = run_fsdbreport_file(args.fsdb, signals, bt=args.bt, et=args.et)
    time_unit, signal_names, data_rows = parse_csv_report(raw)
    events = events_from_csv(signal_names, data_rows)

    if not events:
        print("No events found in the specified time range.", file=sys.stderr)
        return

    if args.metric_type == "latency":
        latencies = handshake_latency(events, args.req, args.ack)
        if not latencies:
            print("No handshake events found.", file=sys.stderr)
            return
        print(f"Handshake latency ({args.req} -> {args.ack}):")
        print(f"  Count:    {len(latencies)}")
        print(f"  Min:      {min(latencies)} {time_unit}")
        print(f"  Max:      {max(latencies)} {time_unit}")
        avg = sum(latencies) / len(latencies)
        print(f"  Average:  {avg:.1f} {time_unit}")

    elif args.metric_type == "stall":
        ratio = stall_ratio(events, args.valid, args.ready)
        total = events[-1].time - events[0].time if len(events) > 1 else 0
        print(f"Stall analysis ({args.valid} / {args.ready}):")
        print(f"  Total time:  {total} {time_unit}")
        print(f"  Stall ratio: {ratio:.4f} ({ratio * 100:.1f}%)")
        print(f"  Throughput:  {1 - ratio:.4f} ({(1 - ratio) * 100:.1f}%)")

    elif args.metric_type == "state":
        residency = state_residency(events, args.signal)
        if not residency:
            print("No state transitions found.", file=sys.stderr)
            return
        total = events[-1].time - events[0].time if len(events) > 1 else 1
        print(f"State residency ({args.signal}):")
        for state_val, ratio in residency.items():
            duration = int(ratio * total)
            print(f"  {state_val:<20s} {ratio * 100:6.2f}%  ({duration} {time_unit})")


def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser."""
    parser = argparse.ArgumentParser(
        prog="fsdb",
        description="FSDB Terminal Analyzer — CLI wrapper for Verdi FSDB utilities",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # info
    p_info = subparsers.add_parser("info", help="Show FSDB file metadata")
    p_info.add_argument("fsdb", help="Path to FSDB file")

    # hier
    p_hier = subparsers.add_parser("hier", help="List hierarchy tree")
    p_hier.add_argument("fsdb", help="Path to FSDB file")
    p_hier.add_argument("scope", nargs="?", help="Starting scope (e.g., /tb/dut)")
    p_hier.add_argument("-l", "--level", type=int, default=1,
                        help="Depth to show (0=unlimited, default=1)")
    p_hier.add_argument("-m", "--mode", choices=["tree", "flat"], default="tree",
                        help="Output format: tree (default) or flat (full paths)")
    p_hier.add_argument("-S", "--signals", action="store_true",
                        help="Show leaf signals (uses -tree backend, slower)")

    # find
    p_find = subparsers.add_parser("find", help="Find signals by regex pattern")
    p_find.add_argument("fsdb", help="Path to FSDB file")
    p_find.add_argument("pattern", help="Regex pattern to search")

    # cut
    p_cut = subparsers.add_parser("cut", help="Extract sub-FSDB by scope/time")
    p_cut.add_argument("fsdb", help="Path to FSDB file")
    p_cut.add_argument("-s", "--scope", help="Hierarchy scope to extract")
    p_cut.add_argument("-bt", help="Begin time with unit (e.g., 10ns)")
    p_cut.add_argument("-et", help="End time with unit (e.g., 20us)")
    p_cut.add_argument("-o", "--output", help="Output FSDB file path")
    p_cut.add_argument("--level", type=int, help="Descendant depth")

    # events
    p_events = subparsers.add_parser("events", help="Dump signal value changes")
    p_events.add_argument("fsdb", help="Path to FSDB file")
    p_events.add_argument("-s", "--signals", nargs="+", required=True,
                          help="Signal paths")
    p_events.add_argument("-bt", help="Begin time with unit")
    p_events.add_argument("-et", help="End time with unit")
    p_events.add_argument("--csv", action="store_true",
                          help="Output raw CSV instead of table")

    # metric
    p_metric = subparsers.add_parser("metric", help="Compute performance metrics")
    p_metric.add_argument("fsdb", help="Path to FSDB file")
    p_metric.add_argument("metric_type", choices=["latency", "stall", "state"],
                          help="Metric to compute")
    p_metric.add_argument("-req", help="Request signal (for latency)")
    p_metric.add_argument("-ack", help="Acknowledge signal (for latency)")
    p_metric.add_argument("-valid", help="Valid signal (for stall)")
    p_metric.add_argument("-ready", help="Ready signal (for stall)")
    p_metric.add_argument("-signal", help="State signal (for state residency)")
    p_metric.add_argument("-bt", help="Begin time with unit")
    p_metric.add_argument("-et", help="End time with unit")

    return parser


def main() -> None:
    """Main entry point."""
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(0)

    commands = {
        "info": cmd_info,
        "hier": cmd_hier,
        "find": cmd_find,
        "cut": cmd_cut,
        "events": cmd_events,
        "metric": cmd_metric,
    }

    try:
        commands[args.command](args)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
