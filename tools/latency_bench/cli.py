from __future__ import annotations

import argparse
from pathlib import Path

from .compose import ComposeOptions, compose_to_csv
from .compare import compare_candidates, parse_candidate_spec
from .generate_suites import GenerateSuitesOptions, generate_suites
from .merge_suites import MergeSuitesOptions, merge_suites
from .plot import visualize
from .runner import DEFAULT_SRUN_ARGS, RunOptions, default_run_id, resolve_fpga_bin_config, run_suite
from .suite import find_repo_root, load_suite


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run and visualize Vortex FPGA latency benchmarks.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="Expand a suite, run FPGA bench cases, and write CSV reports.")
    run.add_argument("--build-dir", default="build", help="Configured build directory.")
    run.add_argument(
        "--fpga-bin",
        default=None,
        help="FPGA bin alias, bin directory, or vortex_afu.xclbin path; overrides suite defaults.fpga_bin.",
    )
    run.add_argument("--suite", required=True, help="Suite YAML path.")
    run.add_argument("--out", required=True, help="Output directory.")
    run.add_argument("--run-id", default=None, help="Optional run id under OUT/runs; default is UTC timestamp.")
    run.add_argument("--warmup", type=int, default=None, help="Override suite warmup.")
    run.add_argument("--iterations", type=int, default=None, help="Override suite iterations.")
    run.add_argument("--platform", default=None, help="Override suite/default Xilinx platform.")
    run.add_argument("--xrt-device-index", type=int, default=None, help="Override XRT device index.")
    run.add_argument("--configs-extra", default="", help="Extra CONFIGS defines appended inside the run script.")
    run.add_argument(
        "--blackbox-timeout",
        default=None,
        help="GNU timeout duration per blackbox.sh execution, e.g. 30m or 2h; 0 disables.",
    )
    run.add_argument(
        "--blackbox-arg",
        action="append",
        default=[],
        help="Add or override a blackbox arg from suite defaults; repeat for each arg.",
    )
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
    run.add_argument(
        "--skip-existing",
        action="store_true",
        help="Skip executions that already have a matching status=pass row in OUT/raw_db.csv.",
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

    comp = sub.add_parser("compose", help="Compose workload latency from one or more raw_db.csv files.")
    comp.add_argument("--suite", required=True, help="Suite YAML path to expand into target kernel cases.")
    comp.add_argument("--raw-db", action="append", required=True, help="raw_db.csv path; repeat to search multiple DBs.")
    comp.add_argument("--out", required=True, help="Output CSV path, or directory for composed.csv and summary.csv.")
    comp.add_argument(
        "--metric",
        choices=["avg_us", "p50_us", "p95_us", "min_us", "max_us"],
        default="p50_us",
        help="Latency metric to compose.",
    )
    comp.add_argument(
        "--select",
        choices=["median", "latest", "mean", "min", "strict"],
        default="median",
        help="Policy when multiple raw DB rows match the same case.",
    )
    comp.add_argument(
        "--missing",
        choices=["error", "nan", "skip"],
        default="error",
        help="Policy when a suite case has no matching raw DB row.",
    )
    comp.add_argument("--fpga-bin-label", default=None, help="Only use rows with this fpga_bin_label.")
    comp.add_argument("--xclbin-sha256", default=None, help="Only use rows with this xclbin_sha256.")

    gen = sub.add_parser(
        "generate-suites",
        help="Expand a base suite and export one runnable suite per (app, FPGA bin) group.",
    )
    gen.add_argument("--suite", required=True, help="Base suite YAML path.")
    gen.add_argument("--out", required=True, help="Output directory for generated suites and index.yaml.")
    gen.add_argument("--overwrite", action="store_true", help="Replace existing generated suite files.")

    merge = sub.add_parser(
        "merge-suites",
        help="Merge expanded suite YAML files and dedupe identical executions.",
    )
    merge.add_argument(
        "--suite-glob",
        action="append",
        required=True,
        help="Suite YAML glob pattern; repeat to merge multiple pattern sets. Quote patterns to let Python expand them.",
    )
    merge.add_argument("--out", required=True, help="Output YAML path, or output directory with --group-by-fpga-bin.")
    merge.add_argument("--name", default="", help="Merged suite base name; default is derived from --out.")
    merge.add_argument("--group-by-fpga-bin", action="store_true", help="Write one merged suite per FPGA bin under --out.")
    merge.add_argument("--overwrite", action="store_true", help="Replace existing merged suite files.")
    return parser


def _arg_key(value: str) -> str:
    head = str(value).split("=", 1)[0]
    return head if head.startswith("-") else str(value)


def merge_override_args(defaults: tuple[str, ...], overrides: list[str]) -> tuple[str, ...]:
    merged = list(defaults)
    positions = {_arg_key(arg): idx for idx, arg in enumerate(merged)}
    for arg in overrides:
        key = _arg_key(arg)
        if key in positions:
            merged[positions[key]] = arg
        else:
            positions[key] = len(merged)
            merged.append(arg)
    return tuple(merged)


def normalize_timeout(value: str | None) -> str:
    if value is None:
        return ""
    value = str(value).strip()
    return "" if value in ("", "0") else value


def merge_configs_extra(cli_configs: str) -> str:
    parts: list[str] = []
    cli_configs = cli_configs.strip()
    if cli_configs:
        parts.append(cli_configs)
    return " ".join(parts)


def run_cmd(args: argparse.Namespace) -> int:
    repo_root = find_repo_root()
    suite = load_suite(
        Path(args.suite),
        repo_root=repo_root,
        warmup_override=args.warmup,
        iterations_override=args.iterations,
    )
    fpga_bin_label = args.fpga_bin or suite.defaults.fpga_bin
    if not fpga_bin_label:
        raise ValueError("run requires --fpga-bin unless the suite sets defaults.fpga_bin")
    fpga_bin = resolve_fpga_bin_config(fpga_bin_label)
    platform = args.platform or suite.defaults.platform
    xrt_device_index = args.xrt_device_index
    if xrt_device_index is None:
        xrt_device_index = suite.defaults.xrt_device_index
    blackbox_args = merge_override_args(suite.defaults.blackbox_args, args.blackbox_arg)
    blackbox_timeout = normalize_timeout(args.blackbox_timeout)
    if args.blackbox_timeout is None:
        blackbox_timeout = normalize_timeout(suite.defaults.blackbox_timeout)
    srun_args = tuple(args.srun_arg) if args.srun_arg else DEFAULT_SRUN_ARGS
    run_id = args.run_id or default_run_id()
    configs_extra = merge_configs_extra(args.configs_extra)
    options = RunOptions(
        build_dir=Path(args.build_dir).resolve(),
        fpga_bin_dir=fpga_bin.path,
        fpga_bin_label=fpga_bin_label,
        out_dir=Path(args.out).resolve(),
        platform=platform,
        xrt_device_index=xrt_device_index,
        configs=fpga_bin.configs,
        configs_extra=configs_extra,
        blackbox_args=blackbox_args,
        blackbox_timeout=blackbox_timeout,
        srun=not args.no_srun,
        srun_args=srun_args,
        dry_run=args.dry_run,
        append_raw_csv=Path(args.append_raw).resolve() if args.append_raw else None,
        run_id=run_id,
        skip_existing=args.skip_existing,
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
    if args.cmd == "compose":
        repo_root = find_repo_root()
        suite = load_suite(Path(args.suite), repo_root=repo_root)
        composed_csv, summary_csv = compose_to_csv(
            suite,
            ComposeOptions(
                raw_dbs=tuple(Path(path).resolve() for path in args.raw_db),
                out=Path(args.out).resolve(),
                metric=args.metric,
                select=args.select,
                missing=args.missing,
                fpga_bin_label=args.fpga_bin_label,
                xclbin_sha256=args.xclbin_sha256,
            ),
        )
        print(f"wrote {composed_csv}")
        if summary_csv:
            print(f"wrote {summary_csv}")
        return 0
    if args.cmd == "generate-suites":
        index = generate_suites(GenerateSuitesOptions(
            suite=Path(args.suite),
            out_dir=Path(args.out),
            overwrite=args.overwrite,
        ))
        print(f"wrote {Path(args.out).resolve() / 'index.yaml'}")
        print(f"generated {len(index['generated'])} suites")
        return 0
    if args.cmd == "merge-suites":
        result = merge_suites(MergeSuitesOptions(
            suite_globs=tuple(args.suite_glob),
            out=Path(args.out),
            name=args.name,
            group_by_fpga_bin=args.group_by_fpga_bin,
            overwrite=args.overwrite,
        ))
        if args.group_by_fpga_bin:
            print(f"wrote {result['index']}")
            print(f"generated {len(result['generated'])} suites")
        else:
            print(f"wrote {result['suite']}")
            print(f"merged {result['case_count']} cases")
        if result["dropped_duplicate_count"]:
            print(f"dropped {result['dropped_duplicate_count']} duplicate executions")
        return 0
    parser.error(f"unknown command: {args.cmd}")
    return 2
