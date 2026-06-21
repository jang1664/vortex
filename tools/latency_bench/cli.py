from __future__ import annotations

import argparse
from pathlib import Path

from .compose import ComposeOptions, MISSING_POLICIES, METRIC_COLUMNS, SELECT_POLICIES, compose_to_csv
from .compare import compare_candidates, parse_candidate_spec
from .generate_suites import GenerateSuitesOptions, generate_suites
from .merge_suites import MergeSuitesOptions, merge_suites
from .plot import (
    BAR_AXIS_CHOICES,
    DEFAULT_BAR_COL,
    DEFAULT_BAR_HUE,
    DEFAULT_BAR_ROW,
    DEFAULT_BAR_X,
    DEFAULT_LEGEND_POSITION,
    DEFAULT_RELATIVE_SCOPE,
    DEFAULT_STACK_BY,
    DEFAULT_STACK_LEGEND_SCOPE,
    DEFAULT_X_TICK_LABEL_MODE,
    LEGEND_POSITION_CHOICES,
    RELATIVE_SCOPE_CHOICES,
    STACK_LEGEND_SCOPE_CHOICES,
    STACK_BY_COLUMNS,
    SuiteBarPlotOptions,
    TEXT_ALIGN_CHOICES,
    X_TICK_LABEL_MODE_CHOICES,
    visualize,
    visualize_suites,
)
from .runner import (
    DEFAULT_POWER_MAX_ITERATIONS,
    DEFAULT_RETRY_MAX_ROUNDS,
    DEFAULT_RETRY_RESET_CMD,
    DEFAULT_RETRY_RESET_WAIT,
    DEFAULT_RETRY_TIMEOUT_GROWTH,
    DEFAULT_SRUN_ARGS,
    RunOptions,
    default_run_id,
    resolve_fpga_bin_config,
    run_suite,
)
from .suite import apply_case_filters, find_repo_root, load_suite


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
    run.set_defaults(measure_latency=True, measure_power=True)
    run.add_argument("--latency", dest="measure_latency", action="store_true", help="Enable normal latency measurement.")
    run.add_argument("--no-latency", dest="measure_latency", action="store_false", help="Skip the normal latency measurement phase.")
    run.add_argument("--power", dest="measure_power", action="store_true", help="Enable separate power measurement.")
    run.add_argument("--no-power", dest="measure_power", action="store_false", help="Disable power measurement.")
    run.set_defaults(power_auto_duration=True)
    run.add_argument(
        "--power-auto-duration",
        dest="power_auto_duration",
        action="store_true",
        help="Calibrate each kernel and automatically choose power iterations and sample interval.",
    )
    run.add_argument(
        "--no-power-auto-duration",
        dest="power_auto_duration",
        action="store_false",
        help="Use the bench binary's fixed power iteration and sample interval defaults.",
    )
    run.add_argument(
        "--power-min-run-sec",
        type=float,
        default=10.0,
        help="Minimum target sampled run duration per kernel when power auto-duration is enabled.",
    )
    run.add_argument(
        "--power-max-run-sec",
        type=float,
        default=60.0,
        help="Maximum target sampled run duration per kernel when power auto-duration is enabled.",
    )
    run.add_argument(
        "--power-target-samples",
        type=int,
        default=100,
        help="Target raw power samples per kernel when power auto-duration is enabled.",
    )
    run.add_argument(
        "--power-max-iterations",
        type=int,
        default=DEFAULT_POWER_MAX_ITERATIONS,
        help="Hard iteration cap for power auto-duration planning; 0 disables the cap.",
    )
    run.add_argument(
        "--power-min-interval",
        type=float,
        default=0.05,
        help="Minimum sampler interval in seconds when power auto-duration is enabled.",
    )
    run.add_argument(
        "--power-max-interval",
        type=float,
        default=1.0,
        help="Maximum sampler interval in seconds when power auto-duration is enabled.",
    )
    run.add_argument("--platform", default=None, help="Override suite/default Xilinx platform.")
    run.add_argument("--xrt-device-index", type=int, default=None, help="Override XRT device index.")
    run.add_argument("--xrt-device-bdf", default="", help="Override XRT user-function BDF for FPGA programming.")
    run.add_argument(
        "--no-program-fpga",
        action="store_true",
        help="Skip explicit xrt-smi programming before HW benchmark execution.",
    )
    run.add_argument("--configs-extra", default="", help="Extra CONFIGS defines appended inside the run script.")
    run.add_argument(
        "--blackbox-timeout",
        default=None,
        help="GNU timeout duration per blackbox.sh execution, e.g. 30m or 2h; 0 disables.",
    )
    run.add_argument(
        "--retry",
        action="store_true",
        help="Retry timeout failures after resetting the FPGA; reset runs directly inside an existing Slurm allocation.",
    )
    run.add_argument(
        "--retry-max-rounds",
        type=int,
        default=DEFAULT_RETRY_MAX_ROUNDS,
        help=f"Maximum total execution rounds when --retry is enabled, including the first run (default: {DEFAULT_RETRY_MAX_ROUNDS}).",
    )
    run.add_argument(
        "--retry-timeout-growth",
        type=float,
        default=DEFAULT_RETRY_TIMEOUT_GROWTH,
        help=f"Timeout growth factor between retry rounds (default: {DEFAULT_RETRY_TIMEOUT_GROWTH:.2f}).",
    )
    run.add_argument(
        "--retry-reset-wait",
        default=DEFAULT_RETRY_RESET_WAIT,
        help=f"Sleep duration after timeout reset when --retry is enabled (default: {DEFAULT_RETRY_RESET_WAIT}).",
    )
    run.add_argument(
        "--retry-reset-cmd",
        default=DEFAULT_RETRY_RESET_CMD,
        help=f"Reset command run under srun after timeout (default: {DEFAULT_RETRY_RESET_CMD!r}).",
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
    run.add_argument(
        "--no-prebuild",
        action="store_true",
        help="Disable the default build-only preflight and let each blackbox invocation build and run.",
    )
    run.add_argument(
        "--filter",
        action="append",
        default=[],
        help="Filter expanded suite cases, e.g. 'app=fpint_gemm_ffn_hw & stage=prefill'. Repeat to AND filters.",
    )

    vis = sub.add_parser("visualize", help="Generate PNG/PDF figures from results.csv or suite/raw_db inputs.")
    vis.add_argument("--results", default=None, help="Path to results.csv for legacy per-run figures.")
    vis.add_argument("--suite", action="append", default=[], help="Suite YAML path; repeat for multi-suite bar plots.")
    vis.add_argument("--raw-db", action="append", default=[], help="raw_db.csv path; repeat to search multiple DBs.")
    vis.add_argument("--out", required=True, help="Figure output directory.")
    vis.add_argument(
        "--metric",
        choices=METRIC_COLUMNS,
        default="p50_us",
        help="Latency metric for suite/raw_db bar plots.",
    )
    vis.add_argument(
        "--select",
        choices=SELECT_POLICIES,
        default="median",
        help="Policy when multiple raw DB rows match the same case.",
    )
    vis.add_argument(
        "--missing",
        choices=MISSING_POLICIES,
        default="nan",
        help="Policy when a suite case has no matching raw DB row.",
    )
    vis.add_argument("--fpga-bin-label", default=None, help="Only use raw DB rows with this fpga_bin_label.")
    vis.add_argument("--xclbin-sha256", default=None, help="Only use raw DB rows with this xclbin_sha256.")
    vis.add_argument(
        "--no-match-fpga-bin",
        dest="match_fpga_bin",
        action="store_false",
        default=True,
        help="Do not require each suite case to match its resolved fpga_bin_label.",
    )
    vis.add_argument("--x", choices=BAR_AXIS_CHOICES, default=DEFAULT_BAR_X, help="Bar chart x axis.")
    vis.add_argument("--hue", choices=BAR_AXIS_CHOICES, default=DEFAULT_BAR_HUE, help="Grouped bar hue axis.")
    vis.add_argument("--row", choices=BAR_AXIS_CHOICES, default=DEFAULT_BAR_ROW, help="Subplot row axis.")
    vis.add_argument("--col", choices=BAR_AXIS_CHOICES, default=DEFAULT_BAR_COL, help="Subplot column axis.")
    vis.add_argument(
        "--stacked",
        dest="stacked",
        action="store_true",
        default=True,
        help="Stack workload cases within each bar for suite/raw_db bar plots (default).",
    )
    vis.add_argument(
        "--no-stacked",
        dest="stacked",
        action="store_false",
        help="Draw one total bar per axis/hue group instead of stacking workload cases.",
    )
    vis.add_argument(
        "--stack-by",
        choices=STACK_BY_COLUMNS,
        default=DEFAULT_STACK_BY,
        help="Case field used as the stacked segment label when --stacked is enabled.",
    )
    vis.add_argument(
        "--stack-legend-scope",
        choices=STACK_LEGEND_SCOPE_CHOICES,
        default=DEFAULT_STACK_LEGEND_SCOPE,
        help="Use one stacked legend globally or one stacked legend per hue; hue scope also uses hue-specific color families.",
    )
    vis.add_argument(
        "--value-labels",
        dest="value_labels",
        action="store_true",
        default=True,
        help="Annotate bars with their plotted values (default).",
    )
    vis.add_argument(
        "--no-value-labels",
        dest="value_labels",
        action="store_false",
        help="Do not annotate bars with plotted values.",
    )
    vis.add_argument(
        "--value-label-rotation",
        type=float,
        default=0.0,
        help="Rotation angle in degrees for bar value labels.",
    )
    vis.add_argument(
        "--value-label-fontsize",
        type=float,
        default=7.0,
        help="Font size for bar value labels.",
    )
    vis.add_argument(
        "--grouped-bar-gap",
        type=float,
        default=0.04,
        help="Gap between hue bars inside one x tick, in x-axis units.",
    )
    vis.add_argument(
        "--x-tick-label-mode",
        choices=X_TICK_LABEL_MODE_CHOICES,
        default=DEFAULT_X_TICK_LABEL_MODE,
        help="Use one x tick label per group or one per hue bar.",
    )
    vis.add_argument(
        "--x-tick-label-rotation",
        type=float,
        default=0.0,
        help="Rotation angle in degrees for x tick labels.",
    )
    vis.add_argument(
        "--x-tick-label-ha",
        choices=TEXT_ALIGN_CHOICES,
        default="center",
        help="Horizontal alignment for x tick labels.",
    )
    vis.add_argument(
        "--relative",
        action="store_true",
        help="Normalize plotted values so the smallest positive bar is 1.0.",
    )
    vis.add_argument(
        "--relative-scope",
        choices=RELATIVE_SCOPE_CHOICES,
        default=DEFAULT_RELATIVE_SCOPE,
        help="Scope used to choose the relative baseline when --relative is set.",
    )
    vis.add_argument(
        "--share-y",
        action="store_true",
        help="Share the y-axis scale across subplot panels; disabled by default.",
    )
    vis.add_argument(
        "--legend-position",
        choices=LEGEND_POSITION_CHOICES,
        default=DEFAULT_LEGEND_POSITION,
        help="Legend placement for suite/raw_db bar plots.",
    )
    vis.add_argument("--legend-ncol", type=int, default=None, help="Override legend column count.")
    vis.add_argument("--figure-title", default=None, help="Optional figure title.")
    vis.add_argument("--x-label", default=None, help="Override x-axis label.")
    vis.add_argument("--y-label", default=None, help="Override y-axis label.")
    vis.add_argument("--legend-title", default=None, help="Override legend title.")
    vis.add_argument(
        "--value-order",
        action="append",
        default=[],
        metavar="AXIS=VALUE[,VALUE...]",
        help="Explicit display order for axis values, e.g. variant=C1,C2,C3. Repeat for multiple axes.",
    )

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
    comp.add_argument(
        "--no-match-fpga-bin",
        dest="match_fpga_bin",
        action="store_false",
        default=True,
        help="Do not require each suite case to match its resolved fpga_bin_label.",
    )

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


def parse_value_order_specs(specs: list[str]) -> dict[str, tuple[str, ...]]:
    valid_axes = {*BAR_AXIS_CHOICES, *STACK_BY_COLUMNS, "stack_key"} - {"none"}
    orders: dict[str, tuple[str, ...]] = {}
    for spec in specs:
        if "=" not in spec:
            raise ValueError(f"--value-order must be AXIS=VALUE[,VALUE...], got: {spec}")
        axis, raw_values = spec.split("=", 1)
        axis = axis.strip()
        if axis not in valid_axes:
            raise ValueError(f"unsupported --value-order axis: {axis}")
        values = tuple(value.strip() for value in raw_values.split(",") if value.strip())
        if not values:
            raise ValueError(f"--value-order for {axis} must include at least one value")
        orders[axis] = values
    return orders


def run_cmd(args: argparse.Namespace) -> int:
    repo_root = find_repo_root()
    suite = load_suite(
        Path(args.suite),
        repo_root=repo_root,
        warmup_override=args.warmup,
        iterations_override=args.iterations,
    )
    suite = apply_case_filters(suite, tuple(args.filter))
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
        xrt_device_bdf=args.xrt_device_bdf,
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
        prebuild=not args.no_prebuild,
        program_fpga=not args.no_program_fpga,
        measure_latency=args.measure_latency,
        measure_power=args.measure_power,
        power_auto_duration=args.power_auto_duration,
        power_min_run_sec=args.power_min_run_sec,
        power_max_run_sec=args.power_max_run_sec,
        power_max_iterations=args.power_max_iterations,
        power_target_samples=args.power_target_samples,
        power_min_interval=args.power_min_interval,
        power_max_interval=args.power_max_interval,
        case_filters=tuple(args.filter),
        retry=args.retry,
        retry_max_rounds=args.retry_max_rounds,
        retry_timeout_growth=args.retry_timeout_growth,
        retry_reset_wait=args.retry_reset_wait,
        retry_reset_cmd=args.retry_reset_cmd,
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
        if args.results:
            if args.suite or args.raw_db:
                parser.error("visualize --results cannot be combined with --suite or --raw-db")
            visualize(Path(args.results), Path(args.out))
            return 0
        if not args.suite or not args.raw_db:
            parser.error("visualize requires either --results or both --suite and --raw-db")
        repo_root = find_repo_root()
        suites = [load_suite(Path(path), repo_root=repo_root) for path in args.suite]
        try:
            value_orders = parse_value_order_specs(args.value_order)
        except ValueError as exc:
            parser.error(str(exc))
        visualize_suites(
            suites,
            SuiteBarPlotOptions(
                raw_dbs=tuple(Path(path).resolve() for path in args.raw_db),
                out_dir=Path(args.out).resolve(),
                metric=args.metric,
                select=args.select,
                missing=args.missing,
                x=args.x,
                hue=args.hue,
                row=args.row,
                col=args.col,
                stacked=args.stacked,
                stack_by=args.stack_by,
                stack_legend_scope=args.stack_legend_scope,
                value_labels=args.value_labels,
                value_label_rotation=args.value_label_rotation,
                value_label_fontsize=args.value_label_fontsize,
                grouped_bar_gap=args.grouped_bar_gap,
                x_tick_label_mode=args.x_tick_label_mode,
                x_tick_label_rotation=args.x_tick_label_rotation,
                x_tick_label_ha=args.x_tick_label_ha,
                relative=args.relative,
                relative_scope=args.relative_scope,
                share_y=args.share_y,
                fpga_bin_label=args.fpga_bin_label,
                xclbin_sha256=args.xclbin_sha256,
                match_fpga_bin=args.match_fpga_bin,
                legend_position=args.legend_position,
                legend_ncol=args.legend_ncol,
                figure_title=args.figure_title,
                x_label=args.x_label,
                y_label=args.y_label,
                legend_title=args.legend_title,
                value_orders=value_orders,
            ),
        )
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
                match_fpga_bin=args.match_fpga_bin,
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
