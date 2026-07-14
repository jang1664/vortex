#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

import yaml


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = Path(__file__).resolve().parent

DEFAULT_FPGA_BIN = "naive_simd"
DEFAULT_PLATFORM = "xilinx_u55c_gen3x16_xdma_3_202210_1"
DEFAULT_GENERATED_ROOT = WORKSPACE / "generated_power_sweep"
DEFAULT_OUTPUT_ROOT = WORKSPACE / "outputs_power_sweep"
DEFAULT_POWER_AUTO_DURATION = False
DEFAULT_POWER_MEASURE_LATENCY = True
DEFAULT_POWER_ITERATIONS = 1
DEFAULT_POWER_MIN_RUN_SEC = 10.0
DEFAULT_POWER_MAX_RUN_SEC = 60.0
DEFAULT_POWER_TARGET_SAMPLES = 100
DEFAULT_POWER_MAX_ITERATIONS = 1
DEFAULT_POWER_MIN_INTERVAL = 0.01
DEFAULT_POWER_MAX_INTERVAL = 1.0
DEFAULT_POWER_MIN_SAMPLES = 5


@dataclass(frozen=True)
class PowerCase:
    app: str
    shape_id: str
    shape_rank: int
    args: str
    shape: dict[str, Any]
    label: str

    @property
    def case_id(self) -> str:
        return sanitize_id(f"{self.app}_{self.shape_id}")


@dataclass(frozen=True)
class SkippedApp:
    app: str
    reason: str


ProfileBuilder = Callable[[str], list[tuple[str, dict[str, Any], str]]]


ONE_DIM_SIZES = (
    1_024,
    4_096,
    16_384,
    65_536,
    262_144,
    1_048_576,
    2_097_152,
    4_194_304,
    8_388_608,
    16_777_216,
)

TWO_DIM_SHAPES = (
    (16, 256),
    (32, 512),
    (64, 512),
    (128, 1_024),
    (256, 1_024),
    (512, 1_024),
    (1_024, 1_024),
    (1_024, 2_048),
    (2_048, 2_048),
    (4_096, 2_048),
)

GEMM_SHAPES = (
    (16, 128, 128),
    (32, 256, 256),
    (64, 512, 256),
    (128, 512, 512),
    (256, 1_024, 512),
    (512, 1_024, 1_024),
    (1_024, 1_024, 2_048),
    (1_024, 2_048, 2_048),
    (2_048, 2_048, 2_048),
    (4_096, 2_048, 4_096),
)

RMSNORM_SHAPES = (
    (1, 16, 512),
    (1, 64, 1_024),
    (1, 128, 2_048),
    (1, 256, 4_096),
    (1, 512, 4_096),
    (1, 1_024, 4_096),
    (2, 1_024, 4_096),
    (4, 1_024, 4_096),
    (8, 1_024, 4_096),
    (8, 2_048, 4_096),
)

ATTENTION_SHAPES = (
    (1, 1, 16, 64),
    (1, 4, 16, 128),
    (1, 8, 32, 256),
    (1, 16, 32, 512),
    (1, 32, 64, 512),
    (1, 32, 64, 1_024),
    (2, 32, 64, 1_024),
    (4, 32, 64, 1_024),
    (8, 32, 64, 1_024),
    (8, 32, 128, 1_024),
)

TOKEN_LAYOUT_SHAPES = (
    (1, 16, 8, 64),
    (1, 64, 16, 64),
    (1, 128, 32, 64),
    (1, 256, 32, 64),
    (1, 512, 32, 128),
    (1, 1_024, 32, 128),
    (2, 1_024, 32, 128),
    (4, 1_024, 32, 128),
    (8, 1_024, 32, 128),
    (8, 2_048, 32, 128),
)

KV_SHAPES = (
    (1, 512),
    (2, 1_024),
    (4, 1_024),
    (8, 2_048),
    (16, 2_048),
    (32, 4_096),
    (64, 4_096),
    (128, 4_096),
    (256, 4_096),
    (512, 4_096),
)

REDUCE_SHAPES = (
    (1, 256),
    (2, 512),
    (4, 1_024),
    (8, 2_048),
    (16, 4_096),
    (32, 4_096),
    (64, 4_096),
    (128, 4_096),
    (256, 4_096),
    (512, 4_096),
)


def sanitize_id(text: str) -> str:
    out = re.sub(r"[^A-Za-z0-9_.-]+", "_", text.strip())
    out = re.sub(r"_+", "_", out).strip("_")
    return out or "case"


def _shape_id(index: int) -> str:
    return f"s{index:02d}"


def _one_dim_profile(app: str) -> list[tuple[str, dict[str, Any], str]]:
    extra = {
        "elunary": " -op exp",
        "elscalar": " -op mul -s 1.25",
    }.get(app, "")
    return [
        (f"-n {n}{extra}", {"n": n}, f"n={n}")
        for n in ONE_DIM_SIZES
    ]


def _two_dim_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (f"-m {m} -k {k}", {"m": m, "k": k}, f"m={m},k={k}")
        for m, k in TWO_DIM_SHAPES
    ]


def _matrix_mn_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (f"-m {m} -n {n}", {"m": m, "n": n}, f"m={m},n={n}")
        for m, n in TWO_DIM_SHAPES
    ]


def _gemm_profile(app: str) -> list[tuple[str, dict[str, Any], str]]:
    cases = []
    for m, n, k in GEMM_SHAPES:
        args = f"-m {m} -n {n} -k {k}"
        if app != "sgemm_tcu":
            args += " -q 32 -t 0 -d 0"
        cases.append((args, {"m": m, "n": n, "k": k}, f"m={m},n={n},k={k}"))
    return cases


def _rmsnorm_profile(app: str) -> list[tuple[str, dict[str, Any], str]]:
    if app == "rms_norm_layout_fused":
        return [
            (
                f"-m {batch * seq} -k {hidden} -eps 0.00001",
                {"batch": batch, "seq": seq, "hidden": hidden, "m": batch * seq, "k": hidden},
                f"batch={batch},seq={seq},hidden={hidden}",
            )
            for batch, seq, hidden in RMSNORM_SHAPES
        ]
    return [
        (
            f"-batch {batch} -seq {seq} -hidden {hidden} -eps 0.00001",
            {"batch": batch, "seq": seq, "hidden": hidden},
            f"batch={batch},seq={seq},hidden={hidden}",
        )
        for batch, seq, hidden in RMSNORM_SHAPES
    ]


def _softmax_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (
            f"-batch {batch} -heads {heads} -seqq {seqq} -seqk {seqk} -mask 1 -scale 1.0",
            {"batch": batch, "heads": heads, "seqq": seqq, "seqk": seqk},
            f"batch={batch},heads={heads},seqq={seqq},seqk={seqk}",
        )
        for batch, heads, seqq, seqk in ATTENTION_SHAPES
    ]


def _token_layout_profile(app: str) -> list[tuple[str, dict[str, Any], str]]:
    cases = []
    for batch, seq, heads, headdim in TOKEN_LAYOUT_SHAPES:
        args = f"-batch {batch} -seq {seq} -heads {heads} -headdim {headdim}"
        shape = {"batch": batch, "seq": seq, "heads": heads, "headdim": headdim}
        label = f"batch={batch},seq={seq},heads={heads},headdim={headdim}"
        if app in {"rope", "rope_layout_fused"}:
            args += f" -maxseq {seq} -offset 0"
            shape["maxseq"] = seq
            if app == "rope_layout_fused":
                args += " --layout-to row_major"
        cases.append((args, shape, label))
    return cases


def _kv_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (
            f"-k {k} -n {n} -q 32 -d 0 -t 0",
            {"k": k, "n": n, "qblk": 32},
            f"k={k},n={n},qblk=32",
        )
        for k, n in KV_SHAPES
    ]


def _tile_weight_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (f"-k {k} -n {n} -t 0", {"k": k, "n": n}, f"k={k},n={n}")
        for k, n in KV_SHAPES
    ]


def _tile_scale_zp_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (
            f"-k {k} -n {n} -q 32 -d 0",
            {"k": k, "n": n, "qblk": 32},
            f"k={k},n={n},qblk=32",
        )
        for k, n in KV_SHAPES
    ]


def _elreduce_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (
            f"-b {batch} -r {reduce} -op sum",
            {"batch": batch, "reduce": reduce},
            f"batch={batch},reduce={reduce}",
        )
        for batch, reduce in REDUCE_SHAPES
    ]


def _hadamard_profile(_app: str) -> list[tuple[str, dict[str, Any], str]]:
    return [
        (f"-rows {rows} -dim {dim}", {"rows": rows, "dim": dim}, f"rows={rows},dim={dim}")
        for rows, dim in TWO_DIM_SHAPES
    ]


APP_PROFILES: dict[str, ProfileBuilder] = {
    "detile_output": _matrix_mn_profile,
    "dropout": _one_dim_profile,
    "eladd": _one_dim_profile,
    "eladd_layout_fused": _two_dim_profile,
    "eldiv": _one_dim_profile,
    "elmul": _one_dim_profile,
    "elmul_layout_fused": _two_dim_profile,
    "elreduce": _elreduce_profile,
    "elscalar": _one_dim_profile,
    "elsub": _one_dim_profile,
    "elunary": _one_dim_profile,
    "fpint_gemm_ffn_hw": _gemm_profile,
    "fpint_gemm_ffn_hw_improve": _gemm_profile,
    "fpint_gemm_ffn_hw_naive": _gemm_profile,
    "hadamard": _hadamard_profile,
    "head_concat": _token_layout_profile,
    "head_concat_layout_fused": _token_layout_profile,
    "kv_cache_dequant_w4a16": _kv_profile,
    "kv_cache_quant_layout_fused_w4a16": _kv_profile,
    "kv_cache_quant_w4a16": _kv_profile,
    "rms_norm_layout_fused": _rmsnorm_profile,
    "rmsnorm": _rmsnorm_profile,
    "rope": _token_layout_profile,
    "rope_layout_fused": _token_layout_profile,
    "sgemm_tcu": _gemm_profile,
    "silu": _two_dim_profile,
    "silu_layout_fused": _two_dim_profile,
    "softmax": _softmax_profile,
    "softmax_layout_fused": _softmax_profile,
    "tile_input_a": _two_dim_profile,
    "tile_scale_zp_w4a16": _tile_scale_zp_profile,
    "tile_weight_w4a16": _tile_weight_profile,
    "vecadd": _one_dim_profile,
}


def _compile_regex(pattern: str | None, label: str) -> re.Pattern[str] | None:
    if not pattern:
        return None
    try:
        return re.compile(pattern)
    except re.error as exc:
        raise ValueError(f"invalid {label} regex {pattern!r}: {exc}") from exc


def _regex_allows(value: str, include: re.Pattern[str] | None, exclude: re.Pattern[str] | None) -> bool:
    if include is not None and include.search(value) is None:
        return False
    if exclude is not None and exclude.search(value) is not None:
        return False
    return True


def _regex_allows_any(
    values: Sequence[str],
    include: re.Pattern[str] | None,
    exclude: re.Pattern[str] | None,
) -> bool:
    if include is not None and not any(include.search(value) is not None for value in values):
        return False
    if exclude is not None and any(exclude.search(value) is not None for value in values):
        return False
    return True


def discover_regression_apps(regression_root: Path | None = None) -> list[str]:
    root = regression_root or REPO_ROOT / "tests" / "regression"
    if not root.is_dir():
        raise FileNotFoundError(f"regression root not found: {root}")
    apps = {
        path.parent.name
        for path in root.glob("**/bench_main.cpp")
        if path.is_file()
    }
    return sorted(apps)


def _make_power_cases(app: str, entries: Sequence[tuple[str, dict[str, Any], str]]) -> list[PowerCase]:
    return [
        PowerCase(
            app=app,
            shape_id=_shape_id(index),
            shape_rank=index,
            args=args,
            shape=dict(shape),
            label=label,
        )
        for index, (args, shape, label) in enumerate(entries)
    ]


def build_case_plan(
    apps: Sequence[str],
    *,
    app_regex: str | None = None,
    exclude_app_regex: str | None = None,
    shape_regex: str | None = None,
    exclude_shape_regex: str | None = None,
    case_regex: str | None = None,
    exclude_case_regex: str | None = None,
    shape_count: int = 10,
) -> tuple[list[PowerCase], list[SkippedApp]]:
    if shape_count < 1:
        raise ValueError("shape_count must be >= 1")

    app_include = _compile_regex(app_regex, "app") if app_regex else None
    app_exclude = _compile_regex(exclude_app_regex, "exclude app")
    shape_include = _compile_regex(shape_regex, "shape") if shape_regex else None
    shape_exclude = _compile_regex(exclude_shape_regex, "exclude shape")
    case_include = _compile_regex(case_regex, "case") if case_regex else None
    case_exclude = _compile_regex(exclude_case_regex, "exclude case")

    planned: list[PowerCase] = []
    skipped: list[SkippedApp] = []
    for app in apps:
        if not _regex_allows(app, app_include, app_exclude):
            continue
        builder = APP_PROFILES.get(app)
        if builder is None:
            skipped.append(SkippedApp(app=app, reason="no built-in shape profile"))
            continue

        for case in _make_power_cases(app, builder(app))[:shape_count]:
            if not _regex_allows_any((case.shape_id, case.label), shape_include, shape_exclude):
                continue
            if not _regex_allows_any((case.case_id, case.args), case_include, case_exclude):
                continue
            planned.append(case)

    return planned, skipped


def write_suite(
    *,
    suite_path: Path,
    suite_name: str,
    cases: Sequence[PowerCase],
    fpga_bin: str,
    platform: str,
    warmup: int,
    iterations: int,
) -> None:
    suite_path.parent.mkdir(parents=True, exist_ok=True)
    suite_cases = []
    for case in cases:
        shape = {
            "shape_id": case.shape_id,
            "shape_rank": case.shape_rank,
            **case.shape,
        }
        suite_cases.append(
            {
                "id": case.case_id,
                "app": case.app,
                "args": case.args,
                "kind": "power_sweep",
                "op": case.app,
                "backend": case.app,
                "variant": "arg_sweep",
                "stage": "power_sweep",
                "name": f"{case.app} {case.shape_id} {case.label}",
                "calls_per_forward": 1,
                "shape": shape,
            }
        )

    suite = {
        "name": suite_name,
        "defaults": {
            "warmup": warmup,
            "iterations": iterations,
            "fpga_bin": fpga_bin,
            "target": "hw",
            "platform": platform,
        },
        "fpga_bins": {
            "default": fpga_bin,
        },
        "cases": suite_cases,
    }
    with suite_path.open("w") as fp:
        yaml.safe_dump(suite, fp, sort_keys=False)


def _append_option(command: list[str], option: str, value: str | int | float | Path | None) -> None:
    if value is None or value == "":
        return
    command.extend([option, str(value)])


def build_run_command(
    *,
    python_bin: str,
    build_dir: Path,
    suite_path: Path,
    out_dir: Path,
    fpga_bin: str,
    run_id: str | None,
    warmup: int,
    iterations: int,
    power_auto_duration: bool,
    power_measure_latency: bool,
    power_min_run_sec: float,
    power_max_run_sec: float,
    power_target_samples: int,
    power_max_iterations: int,
    power_min_samples: int,
    power_min_interval: float,
    power_max_interval: float,
    blackbox_timeout: str,
    retry: bool,
    retry_max_rounds: int,
    no_srun: bool,
    no_program_fpga: bool,
    xrt_device_bdf: str,
    configs_extra: str,
    extra_run_args: Sequence[str],
    skip_existing: bool = True,
) -> list[str]:
    command = [
        python_bin,
        "-m",
        "tools.latency_bench",
        "run",
        "--build-dir",
        str(build_dir),
        "--fpga-bin",
        fpga_bin,
        "--suite",
        str(suite_path),
        "--out",
        str(out_dir),
        "--warmup",
        str(warmup),
        "--iterations",
        str(iterations),
        "--no-latency",
        "--power",
        "--power-min-samples",
        str(power_min_samples),
    ]
    if power_auto_duration:
        command.extend([
            "--power-auto-duration",
            "--power-min-run-sec",
            str(power_min_run_sec),
            "--power-max-run-sec",
            str(power_max_run_sec),
            "--power-target-samples",
            str(power_target_samples),
            "--power-max-iterations",
            str(power_max_iterations),
            "--power-min-interval",
            str(power_min_interval),
            "--power-max-interval",
            str(power_max_interval),
        ])
    else:
        command.append("--no-power-auto-duration")

    if power_measure_latency:
        command.append("--power-measure-latency")
    else:
        command.append("--no-power-measure-latency")

    if run_id:
        command.extend(["--run-id", run_id])
    if skip_existing:
        command.append("--skip-existing")
    if blackbox_timeout:
        command.extend(["--blackbox-timeout", blackbox_timeout])
    if retry:
        command.append("--retry")
        command.extend(["--retry-max-rounds", str(retry_max_rounds)])
    if no_srun:
        command.append("--no-srun")
    if no_program_fpga:
        command.append("--no-program-fpga")
    _append_option(command, "--xrt-device-bdf", xrt_device_bdf)
    _append_option(command, "--configs-extra", configs_extra)
    command.extend(extra_run_args)
    return command


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="") as fp:
        return list(csv.DictReader(fp))


def _planned_case_index(planned_cases: Sequence[PowerCase]) -> tuple[dict[str, PowerCase], dict[tuple[str, str], PowerCase]]:
    by_id = {case.case_id: case for case in planned_cases}
    by_exec = {(case.app, case.args): case for case in planned_cases}
    return by_id, by_exec


def _case_for_raw_row(
    row: dict[str, str],
    by_id: dict[str, PowerCase],
    by_exec: dict[tuple[str, str], PowerCase],
) -> PowerCase | None:
    case_id = row.get("case_id", "")
    if case_id in by_id:
        return by_id[case_id]
    return by_exec.get((row.get("app", ""), row.get("args", "")))


def write_power_summary(
    *,
    raw_db: Path,
    summary_csv: Path,
    planned_cases: Sequence[PowerCase],
) -> list[dict[str, str]]:
    raw_rows = _read_csv(raw_db)
    by_id, by_exec = _planned_case_index(planned_cases)
    rows: list[dict[str, str]] = []
    for row in raw_rows:
        case = _case_for_raw_row(row, by_id, by_exec)
        if case is None:
            continue
        rows.append(
            {
                "case_id": case.case_id,
                "app": case.app,
                "shape_id": case.shape_id,
                "shape_rank": str(case.shape_rank),
                "shape_label": case.label,
                "args": case.args,
                "status": row.get("status", ""),
                "failure_reason": row.get("failure_reason", ""),
                "power_samples": row.get("power_samples", ""),
                "power_avg_w": row.get("power_avg_w", ""),
                "power_min_w": row.get("power_min_w", ""),
                "power_max_w": row.get("power_max_w", ""),
                "power_std_w": row.get("power_std_w", ""),
                "power_idle_std_w": row.get("power_idle_std_w", ""),
                "power_dynamic_stderr_w": row.get("power_dynamic_stderr_w", ""),
                "power_elapsed_s": row.get("power_elapsed_s", ""),
                "power_csv": row.get("power_csv", ""),
                "power_summary": row.get("power_summary", ""),
            }
        )

    rows.sort(key=lambda item: (item["app"], int(item["shape_rank"]), item["case_id"]))
    summary_csv.parent.mkdir(parents=True, exist_ok=True)
    with summary_csv.open("w", newline="") as fp:
        fieldnames = [
            "case_id",
            "app",
            "shape_id",
            "shape_rank",
            "shape_label",
            "args",
            "status",
            "failure_reason",
            "power_samples",
            "power_avg_w",
            "power_min_w",
            "power_max_w",
            "power_std_w",
            "power_idle_std_w",
            "power_dynamic_stderr_w",
            "power_elapsed_s",
            "power_csv",
            "power_summary",
        ]
        writer = csv.DictWriter(fp, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    return rows


def default_python_bin() -> str:
    env_python = os.environ.get("PYTHON")
    if env_python:
        return env_python
    conda_python = Path.home() / ".conda" / "envs" / "vortex" / "bin" / "python"
    if conda_python.exists():
        return str(conda_python)
    return sys.executable or "python3"


def _resolve_from_cwd(path: Path, cwd: Path) -> Path:
    expanded = Path(path).expanduser()
    if expanded.is_absolute():
        return expanded.resolve()
    return (cwd / expanded).resolve()


def normalize_path_args(args: argparse.Namespace, *, cwd: Path | None = None) -> None:
    base = Path.cwd() if cwd is None else cwd
    args.regression_root = _resolve_from_cwd(args.regression_root, base)
    args.generated_root = _resolve_from_cwd(args.generated_root, base)
    args.out = _resolve_from_cwd(args.out, base)
    args.build_dir = _resolve_from_cwd(args.build_dir, base)


def _timestamp() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def _split_extra_run_args(values: Sequence[str]) -> list[str]:
    out: list[str] = []
    for value in values:
        out.extend(shlex.split(value))
    return out


def _print_case_list(cases: Sequence[PowerCase], skipped: Sequence[SkippedApp]) -> None:
    for case in cases:
        print(f"{case.case_id}\t{case.app}\t{case.shape_id}\t{case.label}\t{case.args}")
    if skipped:
        print("[measure-power] skipped unsupported apps:", file=sys.stderr)
        for item in skipped:
            print(f"  {item.app}: {item.reason}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Sweep tests/regression bench apps across 10 small-to-large arg shapes and measure FPGA power."
    )
    parser.add_argument("--regression-root", type=Path, default=REPO_ROOT / "tests" / "regression")
    parser.add_argument("--generated-root", type=Path, default=DEFAULT_GENERATED_ROOT)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--run-id", default=None)
    parser.add_argument("--suite-name", default=None)
    parser.add_argument("--fpga-bin", default=DEFAULT_FPGA_BIN)
    parser.add_argument("--build-dir", type=Path, default=REPO_ROOT / "build")
    parser.add_argument("--platform", default=DEFAULT_PLATFORM)
    parser.add_argument("--python", dest="python_bin", default=default_python_bin())
    parser.add_argument("--warmup", type=int, default=0)
    parser.add_argument(
        "--iterations",
        type=int,
        default=None,
        help="Alias for --power-iterations in this power-only sweep.",
    )
    parser.add_argument(
        "--power-iterations",
        type=int,
        default=DEFAULT_POWER_ITERATIONS,
        help="Fixed power measurement iterations when auto-duration is disabled.",
    )
    parser.add_argument("--shape-count", type=int, default=10)
    parser.add_argument("--app-regex", "--task-regex", dest="app_regex", default=".*")
    parser.add_argument("--exclude-app-regex", "--exclude-task-regex", dest="exclude_app_regex", default=None)
    parser.add_argument("--shape-regex", default=".*")
    parser.add_argument("--exclude-shape-regex", default=None)
    parser.add_argument("--case-regex", default=None)
    parser.add_argument("--exclude-case-regex", default=None)
    parser.add_argument("--limit-apps", type=int, default=0)
    parser.add_argument("--limit-shapes", type=int, default=0)
    parser.add_argument("--list", action="store_true", help="List selected cases and exit without writing a suite.")
    parser.add_argument("--dry-run", action="store_true", help="Write the suite and print the latency_bench command without executing it.")
    parser.add_argument("--no-summary", action="store_true", help="Do not write power_sweep_summary.csv after execution.")
    parser.add_argument("--no-skip-existing", dest="skip_existing", action="store_false", default=True)
    parser.add_argument("--retry", action="store_true")
    parser.add_argument("--retry-max-rounds", type=int, default=3)
    parser.add_argument("--no-srun", action="store_true")
    parser.add_argument("--no-program-fpga", action="store_true")
    parser.add_argument("--xrt-device-bdf", default="")
    parser.add_argument("--configs-extra", default="")
    parser.add_argument("--blackbox-timeout", default="24h")
    parser.set_defaults(power_auto_duration=DEFAULT_POWER_AUTO_DURATION)
    parser.add_argument(
        "--power-auto-duration",
        dest="power_auto_duration",
        action="store_true",
        help="Enable latency_bench auto-duration planning for power measurements.",
    )
    parser.add_argument(
        "--no-power-auto-duration",
        dest="power_auto_duration",
        action="store_false",
        help="Disable auto-duration planning and use fixed power iterations.",
    )
    parser.set_defaults(power_measure_latency=DEFAULT_POWER_MEASURE_LATENCY)
    parser.add_argument(
        "--power-measure-latency",
        dest="power_measure_latency",
        action="store_true",
        help="Record latency/cycle samples during the power measurement phase.",
    )
    parser.add_argument(
        "--no-power-measure-latency",
        dest="power_measure_latency",
        action="store_false",
        help="Disable latency/cycle sampling during the power measurement phase.",
    )
    parser.add_argument("--power-min-run-sec", type=float, default=DEFAULT_POWER_MIN_RUN_SEC)
    parser.add_argument("--power-max-run-sec", type=float, default=DEFAULT_POWER_MAX_RUN_SEC)
    parser.add_argument("--power-target-samples", type=int, default=DEFAULT_POWER_TARGET_SAMPLES)
    parser.add_argument("--power-max-iterations", type=int, default=DEFAULT_POWER_MAX_ITERATIONS)
    parser.add_argument("--power-min-samples", type=int, default=DEFAULT_POWER_MIN_SAMPLES)
    parser.add_argument("--power-min-interval", type=float, default=DEFAULT_POWER_MIN_INTERVAL)
    parser.add_argument("--power-max-interval", type=float, default=DEFAULT_POWER_MAX_INTERVAL)
    parser.add_argument(
        "--extra-run-arg",
        action="append",
        default=[],
        help="Extra argument(s) appended to tools.latency_bench run; shell-style splitting is applied.",
    )
    return parser


def _validate_args(args: argparse.Namespace) -> None:
    if args.warmup < 0:
        raise ValueError("--warmup must be >= 0")
    if args.power_iterations < 1:
        raise ValueError("--power-iterations must be >= 1")
    if args.iterations is None:
        args.iterations = args.power_iterations
    if args.iterations < 1:
        raise ValueError("--iterations must be >= 1")
    if args.power_max_iterations < 0:
        raise ValueError("--power-max-iterations must be >= 0")
    if args.shape_count < 1:
        raise ValueError("--shape-count must be >= 1")
    if args.limit_apps < 0:
        raise ValueError("--limit-apps must be >= 0")
    if args.limit_shapes < 0:
        raise ValueError("--limit-shapes must be >= 0")


def _selected_apps(args: argparse.Namespace) -> list[str]:
    apps = discover_regression_apps(args.regression_root)
    if args.limit_apps:
        apps = apps[: args.limit_apps]
    return apps


def _planned_cases(args: argparse.Namespace) -> tuple[list[PowerCase], list[SkippedApp]]:
    shape_count = args.limit_shapes or args.shape_count
    return build_case_plan(
        _selected_apps(args),
        app_regex=args.app_regex,
        exclude_app_regex=args.exclude_app_regex,
        shape_regex=args.shape_regex,
        exclude_shape_regex=args.exclude_shape_regex,
        case_regex=args.case_regex,
        exclude_case_regex=args.exclude_case_regex,
        shape_count=shape_count,
    )


def _render_command(command: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        normalize_path_args(args)
        _validate_args(args)
        cases, skipped = _planned_cases(args)
    except Exception as exc:
        parser.error(str(exc))

    if args.list:
        _print_case_list(cases, skipped)
        return 0

    if not cases:
        print("[measure-power] no cases selected", file=sys.stderr)
        if skipped:
            _print_case_list(cases, skipped)
        return 2

    run_id = args.run_id or _timestamp()
    suite_name = sanitize_id(args.suite_name or f"power_sweep_{run_id}_{args.fpga_bin}")
    generated_dir = args.generated_root / run_id
    suite_path = generated_dir / f"{suite_name}.yaml"
    out_dir = args.out / args.fpga_bin
    summary_csv = out_dir / "power_sweep_summary.csv"

    write_suite(
        suite_path=suite_path,
        suite_name=suite_name,
        cases=cases,
        fpga_bin=args.fpga_bin,
        platform=args.platform,
        warmup=args.warmup,
        iterations=args.iterations,
    )

    command = build_run_command(
        python_bin=args.python_bin,
        build_dir=args.build_dir,
        suite_path=suite_path,
        out_dir=out_dir,
        fpga_bin=args.fpga_bin,
        run_id=run_id,
        warmup=args.warmup,
        iterations=args.iterations,
        power_auto_duration=args.power_auto_duration,
        power_measure_latency=args.power_measure_latency,
        power_min_run_sec=args.power_min_run_sec,
        power_max_run_sec=args.power_max_run_sec,
        power_target_samples=args.power_target_samples,
        power_max_iterations=args.power_max_iterations,
        power_min_samples=args.power_min_samples,
        power_min_interval=args.power_min_interval,
        power_max_interval=args.power_max_interval,
        blackbox_timeout=args.blackbox_timeout,
        retry=args.retry,
        retry_max_rounds=args.retry_max_rounds,
        no_srun=args.no_srun,
        no_program_fpga=args.no_program_fpga,
        xrt_device_bdf=args.xrt_device_bdf,
        configs_extra=args.configs_extra,
        extra_run_args=_split_extra_run_args(args.extra_run_arg),
        skip_existing=args.skip_existing,
    )

    print(f"[measure-power] cases={len(cases)} suite={suite_path}")
    if skipped:
        print(f"[measure-power] skipped_unsupported={len(skipped)}", file=sys.stderr)
        for item in skipped:
            print(f"  {item.app}: {item.reason}", file=sys.stderr)
    print(f"[measure-power] command={_render_command(command)}")
    if args.dry_run:
        return 0

    completed = subprocess.run(command, cwd=REPO_ROOT, check=False)
    if completed.returncode != 0:
        return completed.returncode

    if not args.no_summary:
        rows = write_power_summary(
            raw_db=out_dir / "raw_db.csv",
            summary_csv=summary_csv,
            planned_cases=cases,
        )
        print(f"[measure-power] summary={summary_csv} rows={len(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
