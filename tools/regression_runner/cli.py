from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .backends import BACKENDS, BackendContext, make_backend
from .discovery import (
    discover_tests,
    expand_cases,
    filter_tests,
    find_repo_root,
    parse_case_spec,
)
from .reporting import render_table, write_manifest, write_results
from .runner import create_manifest, default_run_id, parse_duration, print_dry_run, run_controller, run_worker


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m tools.regression_runner",
        description="Discover and run Vortex functional regression tests."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List runnable functional regression tests.")
    list_parser.add_argument("--match", action="append", default=[], help="Include tests matching this regex.")
    list_parser.add_argument("--exclude", action="append", default=[], help="Exclude tests matching this regex.")

    run_parser = subparsers.add_parser("run", help="Expand and run regression cases.")
    run_parser.add_argument(
        "--case",
        action="append",
        required=True,
        help="Case in REGEX::ARGS form; repeat for multiple test/argument combinations.",
    )
    run_parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Exclude tests matching this regex; repeat as needed.",
    )
    run_parser.add_argument("--backend", choices=sorted(BACKENDS), default="hw")
    run_parser.add_argument("--fpga-alias", default="", help="FPGA binary alias for the hw backend.")
    run_parser.add_argument("--build-dir", default="build", help="Configured Vortex build directory.")
    run_parser.add_argument(
        "--out",
        default=None,
        help="Output root; default is BUILD_DIR/regression_runner_runs.",
    )
    run_parser.add_argument(
        "--timeout",
        default="30m",
        help="Per-case timeout with optional s, m, or h suffix (default: 30m).",
    )
    run_parser.add_argument("--no-srun", action="store_true", help="Run directly without acquiring Slurm resources.")
    run_parser.add_argument("--dry-run", action="store_true", help="Validate and print expanded cases and commands.")
    run_parser.add_argument("--verbose", action="store_true", help="Stream case output while running.")

    return parser


def list_command(args: argparse.Namespace) -> int:
    repo_root = find_repo_root()
    tests = filter_tests(
        discover_tests(repo_root),
        include_patterns=args.match,
        exclude_patterns=args.exclude,
    )
    print(render_table(["#", "test"], enumerate(tests, start=1), limits={1: 80}))
    print(f"TOTAL={len(tests)}")
    return 0


def run_command(args: argparse.Namespace, argv: list[str]) -> int:
    repo_root = find_repo_root()
    build_dir = (repo_root / args.build_dir).resolve() if not Path(args.build_dir).is_absolute() else Path(args.build_dir).resolve()
    backend = make_backend(args.backend)
    context = BackendContext(
        repo_root=repo_root,
        build_dir=build_dir,
        fpga_alias=args.fpga_alias,
    )
    backend.validate(context)

    specs = [parse_case_spec(raw) for raw in args.case]
    cases = expand_cases(discover_tests(repo_root), specs, args.exclude)
    timeout_sec = parse_duration(args.timeout)
    out_root = (
        (build_dir / "regression_runner_runs")
        if args.out is None
        else Path(args.out).expanduser().resolve()
    )
    run_dir = out_root / default_run_id()
    run_dir.mkdir(parents=True, exist_ok=False)
    (run_dir / "logs").mkdir()
    manifest = create_manifest(
        run_dir=run_dir,
        repo_root=repo_root,
        build_dir=build_dir,
        backend=args.backend,
        fpga_alias=args.fpga_alias,
        timeout_sec=timeout_sec,
        verbose=args.verbose,
        cases=cases,
        argv=argv,
    )
    manifest_path = run_dir / "manifest.json"
    write_manifest(manifest_path, manifest)
    write_results(run_dir, manifest, [])

    print(f"run directory: {run_dir}")
    if args.dry_run:
        print_dry_run(manifest, backend, context)
        return 0
    return run_controller(
        manifest_path=manifest_path,
        backend=backend,
        no_srun=args.no_srun,
    )


def main(argv: list[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    if raw_argv[:1] == ["_worker"]:
        worker_parser = argparse.ArgumentParser(add_help=False)
        worker_parser.add_argument("_worker")
        worker_parser.add_argument("--manifest", required=True)
        worker_args = worker_parser.parse_args(raw_argv)
        try:
            return run_worker(Path(worker_args.manifest).resolve())
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except KeyboardInterrupt:
            print("interrupted", file=sys.stderr)
            return 1

    parser = build_parser()
    args = parser.parse_args(raw_argv)
    try:
        if args.command == "list":
            return list_command(args)
        if args.command == "run":
            return run_command(args, raw_argv)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 1
    parser.error(f"unsupported command: {args.command}")
    return 2
