from __future__ import annotations

import argparse
from pathlib import Path

from .compare import compare_candidates, parse_candidate_spec
from .plot import visualize
from .runner import DEFAULT_SRUN_ARGS, RunOptions, default_run_id, resolve_fpga_bin, run_suite
from .suite import find_repo_root, load_suite


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run and visualize Vortex FPGA latency benchmarks.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="Expand a suite, run FPGA bench cases, and write CSV reports.")
    run.add_argument("--build-dir", default="build", help="Configured build directory.")
    run.add_argument("--fpga-bin", required=True, help="FPGA bin alias, bin directory, or vortex_afu.xclbin path.")
    run.add_argument("--suite", required=True, help="Suite YAML path.")
    run.add_argument("--out", required=True, help="Output directory.")
    run.add_argument("--run-id", default=None, help="Optional run id under OUT/runs; default is UTC timestamp.")
    run.add_argument("--warmup", type=int, default=None, help="Override suite warmup.")
    run.add_argument("--iterations", type=int, default=None, help="Override suite iterations.")
    run.add_argument("--platform", default=None, help="Override suite/default Xilinx platform.")
    run.add_argument("--xrt-device-index", type=int, default=None, help="Override XRT device index.")
    run.add_argument("--configs-extra", default="", help="Extra CONFIGS defines appended inside the run script.")
    run.add_argument("--blackbox-arg", action="append", default=[], help="Replace default blackbox args; repeat for each arg.")
    run.add_argument("--no-srun", action="store_true", help="Run directly without srun.")
    run.add_argument("--srun-arg", action="append", default=[], help="Replace default srun args; repeat for each arg.")
    run.add_argument(
        "--dry-run",
        action="store_true",
        help="Only expand suite, write suite snapshots, and emit the run script.",
    )
    run.add_argument("--visualize", action="store_true", help="Generate figures after a successful run.")
    run.add_argument(
        "--append-raw",
        default=None,
        help="Append each execution's raw benchmark row to this aggregate CSV while the run script executes.",
    )

    vis = sub.add_parser("visualize", help="Generate PNG/PDF figures from results.csv.")
    vis.add_argument("--results", required=True, help="Path to results.csv.")
    vis.add_argument("--out", required=True, help="Figure output directory.")

    cmp = sub.add_parser("compare", help="Merge multiple run outputs and generate candidate comparison plots.")
    cmp.add_argument(
        "--candidate",
        action="append",
        required=True,
        help="Candidate input in LABEL=PATH form. PATH can be a run dir, results.csv, or summary.csv.",
    )
    cmp.add_argument("--out", required=True, help="Comparison output directory.")
    cmp.add_argument("--metric", choices=["avg", "p50", "p95"], default="p50", help="Latency metric to compare.")
    cmp.add_argument("--suite", default=None, help="Optional suite name to plot; default aggregates all suites.")
    cmp.add_argument(
        "--breakdown",
        choices=["kernel", "kind"],
        default="kernel",
        help="Stacked-bar component type.",
    )
    cmp.add_argument(
        "--top-components",
        type=int,
        default=24,
        help="Keep top N stacked components and collapse the rest into __other__; <=0 keeps all.",
    )
    cmp.add_argument("--no-plots", action="store_true", help="Only write merged/comparison CSVs.")
    return parser


def run_cmd(args: argparse.Namespace) -> int:
    repo_root = find_repo_root()
    suite = load_suite(
        Path(args.suite),
        repo_root=repo_root,
        warmup_override=args.warmup,
        iterations_override=args.iterations,
    )
    fpga_bin_dir = resolve_fpga_bin(args.fpga_bin)
    platform = args.platform or suite.defaults.platform
    xrt_device_index = args.xrt_device_index
    if xrt_device_index is None:
        xrt_device_index = suite.defaults.xrt_device_index
    blackbox_args = tuple(args.blackbox_arg) if args.blackbox_arg else suite.defaults.blackbox_args
    srun_args = tuple(args.srun_arg) if args.srun_arg else DEFAULT_SRUN_ARGS
    run_id = args.run_id or default_run_id()
    options = RunOptions(
        build_dir=Path(args.build_dir).resolve(),
        fpga_bin_dir=fpga_bin_dir,
        fpga_bin_label=args.fpga_bin,
        out_dir=Path(args.out).resolve(),
        platform=platform,
        xrt_device_index=xrt_device_index,
        configs_extra=args.configs_extra,
        blackbox_args=blackbox_args,
        srun=not args.no_srun,
        srun_args=srun_args,
        dry_run=args.dry_run,
        append_raw_csv=Path(args.append_raw).resolve() if args.append_raw else None,
        run_id=run_id,
    )
    rc = run_suite(suite, options)
    results_csv = options.out_dir / "runs" / run_id / "results.csv"
    if rc == 0 and not args.dry_run and args.visualize and results_csv.exists():
        visualize(results_csv, results_csv.parent / "figures")
    return rc


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "run":
        return run_cmd(args)
    if args.cmd == "visualize":
        visualize(Path(args.results), Path(args.out))
        return 0
    if args.cmd == "compare":
        candidates = [parse_candidate_spec(value) for value in args.candidate]
        compare_candidates(
            candidates,
            Path(args.out).resolve(),
            metric=args.metric,
            suite=args.suite,
            breakdown=args.breakdown,
            top_components=args.top_components,
            make_plots=not args.no_plots,
        )
        return 0
    parser.error(f"unknown command: {args.cmd}")
    return 2
