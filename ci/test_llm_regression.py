#!/usr/bin/env python3
"""Correctness and standalone/fused cycle gate for latency_on_hw kernels.

Examples (run from any directory):
  python ci/test_llm_regression.py hw
  python ci/test_llm_regression.py xrt-vcs-sim --apps 'softmax*'
  python ci/test_llm_regression.py hw --config C1=tcu_th16_c1_v2_rev2 \
      --config C4=configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh

An unqualified --config selects its inferred candidate only; C1=..., C3=...,
and C4=... override the defaults without changing the selected candidates.
Hardware runs share one Slurm allocation, including both sides of every pair.
No benchmark result can turn a failed correctness check into a pass.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import asdict, dataclass
from datetime import datetime
import fcntl
import fnmatch
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from tools.latency_bench.fpga_bins import load_fpga_bin_aliases, resolve_fpga_bin_artifacts
from tools.latency_bench.kernel_variants import parse_variants, query_selection, source_identity, variant_environment
from tools.latency_bench.perf_log import parse_fpga_cycle_stats
from tools.latency_bench.yaml_io import safe_load


@dataclass(frozen=True)
class Case:
    candidate: str
    app: str
    shape: str
    args: str
    pair: str = ""
    bench_args: str | None = None


def cases() -> list[Case]:
    """Matched shapes, including actual pipeline layouts and factor-172 Hadamard."""
    out: list[Case] = []

    def pair(app, fused, shapes):
        for name, plain_args, fused_args in shapes:
            key = f"{app}/{name}"
            out.extend((Case("C1", app, name, plain_args, key),
                        Case("C4", fused, name, fused_args, key)))

    for app in ("eladd", "elmul", "silu"):
        pair(app, app + "_layout_fused", [
            ("decode", "-n 128", "-m 1 -k 128"),
            ("prefill", "-n 4096", "-m 32 -k 128"),
            ("tail_rows", "-n 4224", "-m 33 -k 128")])
    pair("rmsnorm", "rms_norm_layout_fused", [
        ("decode", "-batch 1 -seq 1 -hidden 128", "-m 1 -k 128"),
        ("prefill", "-batch 1 -seq 32 -hidden 128", "-m 32 -k 128"),
        ("tail_rows", "-batch 1 -seq 33 -hidden 256", "-m 33 -k 256")])
    # This host checks plain, tile-only and fused paths; avoid its default five
    # repetitions in correctness mode. Its bench host does not accept -i.
    out = [Case(case.candidate, case.app, case.shape, case.args + " -i 1",
                case.pair, case.args) if case.app in ("rms_norm_layout_fused", "silu_layout_fused") else case
           for case in out]
    pair("hadamard", "hadamard_layout_fused", [
        ("decode", "-rows 1 -dim 128 -K 1", "-m 1 -n 1 -k 128"),
        ("prefill", "-rows 64 -dim 128 -K 1", "-m 32 -n 2 -k 128"),
        ("factorized", "-rows 18 -dim 224 -K 28", "-m 9 -n 2 -k 224")])
    pair("hadamard", "hadamard_layout_fused", [
        ("factor172_decode", "-rows 1 -dim 11008 -K 172", "-m 1 -n 1 -k 11008"),
        ("factor172_prefill", "-rows 64 -dim 11008 -K 172", "-m 64 -n 1 -k 11008 --layout-from gemm_a_tiled")])
    head_shapes = [("decode", 1, 1, 2, 32), ("prefill", 1, 32, 4, 32),
                   ("tail_rows", 2, 9, 2, 64)]
    for app in ("head_concat", "rope"):
        shapes = []
        for index, (name, batch, seq, heads, dim) in enumerate(head_shapes):
            args = f"-batch {batch} -seq {seq} -heads {heads} -headdim {dim}"
            if app == "rope":
                args += f" -maxseq 64 -offset {index * 3}"
            shapes.append((name, args, args + " --layout-to gemm_a_tiled"))
        pair(app, app + "_layout_fused", shapes)
    shapes = []
    for name, batch, heads, q, k, stride, mask in (
            ("decode", 1, 2, 1, 128, 128, 0),
            ("prefill", 1, 1, 32, 32, 32, 1),
            ("tail_columns", 2, 2, 3, 17, 32, 0)):
        args = (f"-batch {batch} -heads {heads} -seqq {q} -seqk {k} "
                f"-seqk-stride {stride} -mask {mask} -scale 0.125")
        shapes.append((name, args, args))
    pair("softmax", "softmax_layout_fused", shapes)
    shapes = []
    for name, k, n, q, d, t, mode in (
            ("decode", 1, 128, 128, 1, 1, "spinquant_signed_asymmetric"),
            ("prefill", 32, 128, 128, 1, 1, "spinquant_signed_asymmetric"),
            ("qdir_k", 33, 64, 32, 0, 0, "spinquant_signed_symmetric")):
        args = f"-k {k} -n {n} -q {q} -d {d} -t {t} --quant-mode {mode}"
        shapes.append((name, args, args + " --layout-from row_major_fp16"))
    pair("kv_cache_quant_w4a16", "kv_cache_quant_layout_fused_w4a16", shapes)
    # Actual pipeline paths differ from the row-major cross-packing cases above:
    # V consumes a wide GEMM-C view; K consumes GEMM-A and transposes the result.
    shapes = []
    for name, k, transposed, mode in (
            ("pipeline_value", 1024, False, "spinquant_signed_symmetric"),
            ("pipeline_key", 1024, True, "spinquant_signed_asymmetric"),
            ("pipeline_value_large", 16384, False, "spinquant_signed_symmetric")):
        args = f"-k {k} -n 128 -q 128 -d 1 -t {int(transposed)} --quant-mode {mode}"
        fused = (args + " --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled"
                 " --source-total-n 128 --head-col-offset 0" if transposed else
                 args + " --gemm-qdir 1 --layout-from gemm_c_tiled"
                 " --source-total-n 1024 --head-col-offset 0")
        shapes.append((name, args, fused))
    pair("kv_cache_quant_w4a16", "kv_cache_quant_layout_fused_w4a16", shapes)
    for index, (k, n, q, d, t) in enumerate(((32, 32, 32, 0, 0),
                                          (64, 64, 64, 1, 1), (33, 34, 32, 0, 1)), 1):
        out.append(Case("C1", "kv_cache_dequant_w4a16", f"case{index}",
                        f"-k {k} -n {n} -q {q} -d {d} -t {t} "
                        "--quant-mode signed_int4_asymmetric"))
    for index, (m, n, k) in enumerate(((8, 16, 32), (16, 32, 64), (17, 33, 64)), 1):
        out.append(Case("C1", "sgemm_tcu", f"case{index}", f"-m {m} -n {n} -k {k}"))
    for candidate, app in (("C3", "fpint_gemm_ffn_hw_naive"), ("C4", "fpint_gemm_ffn_hw")):
        for index, (m, n, k, d, t) in enumerate(((1, 32, 32, 0, 0),
                                              (8, 64, 64, 1, 0), (9, 64, 64, 0, 1)), 1):
            out.append(Case(candidate, app, f"case{index}",
                            f"-m {m} -n {n} -k {k} -q 32 -d {d} -t {t}"))
    return out


def load_cases(path: Path | None = None) -> list[Case]:
    if path is None:
        return cases()
    raw = json.loads(path.read_text())
    if not isinstance(raw, list) or not raw:
        raise ValueError("case file must contain a nonempty JSON list")
    routes = {case.app: case.candidate for case in cases()}
    selected = [Case(**item) for item in raw]
    for case in selected:
        if routes.get(case.app) != case.candidate:
            raise ValueError(f"case {case.app}/{case.shape} requires candidate {routes.get(case.app)}")
    keys = [(case.candidate, case.app, case.shape) for case in selected]
    if len(set(keys)) != len(keys):
        raise ValueError("duplicate candidate/app/shape in case file")
    for pair in {case.pair for case in selected if case.pair}:
        members = [case for case in selected if case.pair == pair]
        if (len(members) != 2 or {case.candidate for case in members} != {"C1", "C4"}
                or len({case.shape for case in members}) != 1):
            raise ValueError(f"pair {pair} requires matched C1/C4 cases with the same shape name")
    return selected


@dataclass(frozen=True)
class Selection:
    config: Path
    alias: str | None


def resolve_selection(value: str, mode: str, aliases) -> Selection:
    if value in aliases:
        if not aliases[value].configs:
            raise ValueError(f"alias {value} has no config")
        selected = Selection(Path(aliases[value].configs).resolve(), value)
    else:
        path = Path(value).expanduser()
        if not path.is_file() and not path.is_absolute():
            path = REPO / path
        path = path.resolve()
        matching = [name for name, item in aliases.items()
                    if item.configs and Path(item.configs).resolve() == path]
        if mode == "hw":
            images = {str(Path(aliases[name].path).resolve()) for name in matching}
            if not matching or len(images) != 1:
                raise ValueError(f"hardware config {path} needs an explicit FPGA alias; "
                                 f"matching aliases: {matching}")
        selected = Selection(path, sorted(matching)[0] if matching else None)
    if not selected.config.is_file():
        raise ValueError(f"config does not exist: {selected.config}")
    if mode == "hw":
        resolve_fpga_bin_artifacts(selected.alias, require_alias=True)
    return selected


def infer_candidate(selection: Selection) -> str:
    result = subprocess.run(["bash", "-c", 'source "$1" >&2; printf "%s" "$CONFIGS"',
                             "config", str(selection.config)], capture_output=True, text=True,
                            timeout=15, check=True)
    if re.search(r"-DGEMM_NAIVE(?:\s|=|$)", result.stdout):
        return "C3"
    if "-DENABLE_GEMM_ACCEL" in result.stdout:
        return "C4"
    return "C1"


PASS_RE = re.compile(r"^\s*(?:PASSED\b|Hadamard transform passed\b|requested:\s*PASS\b)", re.M)
FAIL_RE = re.compile(r"^\s*(?:FAILED\b|Hadamard transform failed\b|requested:\s*FAIL\b)", re.M)
VALUE_RE = re.compile(r"(?:GPU|got|actual)=([-+\w.]+).*?(?:CPU|expected)=([-+\w.]+)", re.I)
EXCEPTION_APPS = {"eladd", "elmul", "silu", "rmsnorm", "rope", "softmax",
                  "eladd_layout_fused", "elmul_layout_fused", "silu_layout_fused",
                  "rms_norm_layout_fused", "rope_layout_fused", "softmax_layout_fused"}


def correctness(log: Path, returncode: int, app: str, small_value: float,
                absolute_tolerance: float) -> tuple[str, str]:
    # Only waive fully reported failures; bounded host logs may omit records.
    text = log.read_text(errors="replace")
    if app == "silu_layout_fused" and returncode == 0:
        checks = re.findall(r"^\s*fused output \(real rows only\):.*?errors=(\d+)\b", text, re.M)
        if checks == ["0"]:
            return "PASS", "fused output verification passed"
    if app == "rms_norm_layout_fused" and returncode == 0:
        checks = re.findall(r"^\s*verify(?: \[([23])\]\s*(?:fused)?)?:.*?errors=(\d+)\s*$", text, re.M)
        if len(checks) == 3 and {label for label, count in checks} == {"", "2", "3"}:
            if all(int(count) == 0 for label, count in checks):
                return "PASS", "plain, tile-only, and fused verification passed"
    if returncode == 0 and PASS_RE.search(text) and not FAIL_RE.search(text):
        return "PASS", ""
    if (returncode in (1, 2, 255) and app in EXCEPTION_APPS
            and FAIL_RE.search(text) and small_value > 0):
        counts = re.findall(r"(?:errors\s*=\s*(\d+)|\((\d+) errors\))", text)
        count = int(next(part for part in counts[-1] if part)) if counts else 0
        records = [line for line in text.splitlines() if line.strip().startswith("Error at")]
        forbidden = re.search(r"Row sum error|Modified padding|returned -?\d+!|FATAL|Segmentation fault|REGRESSION:", text)
        valid = count > 0 and len(records) == count and not forbidden
        # The aggregate max also includes valid relative-tolerance comparisons
        # at larger magnitudes. Bound every failed comparison itself instead.
        for line in records:
            match = VALUE_RE.search(line)
            if not match:
                valid = False
                break
            try:
                got, expected = map(float, match.groups())
            except ValueError:
                valid = False
                break
            valid = valid and all(math.isfinite(x) and abs(x) <= small_value for x in (got, expected))
            valid = valid and abs(got - expected) <= absolute_tolerance
        if valid:
            return "PASS_FP16_EXCEPTION", f"{count} fully reported near-zero mismatches"
    return "FAIL", f"exit={returncode}; correctness PASS absent or validation failed"


def execute(command, cwd: Path, log: Path, timeout: float, env=None) -> int:
    with log.open("w") as stream:
        stream.write(shlex.join(command) + "\n")
        stream.flush()
        with subprocess.Popen(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                              env=env, start_new_session=True) as process:
            try:
                return process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                stream.write("\nREGRESSION: interrupted or timed out\n")
                if isinstance(sys.exc_info()[1], KeyboardInterrupt):
                    raise
                return 124


def command_for(mode, selection, case, benchmark=False, iterations=3, benchmark_output=None):
    args = case.args
    command = ["bash", "ci/run_black.sh", mode, "--app", case.app, "--perf", "0"]
    if benchmark:
        args = case.bench_args or args
        args += f" --warmup=1 --iterations={iterations}"
        # bench_util emits marked per-iteration PERF only with CSV + output.
        args += " --csv --output=" + shlex.quote(str(benchmark_output or "regression_bench.csv"))
        command.append("--bench")
    command.extend(("--args", args))
    if mode == "hw":
        command.extend(("--fpga-bin", selection.alias, "--no-srun"))
    return ["bash", "-c", 'source "$1"; shift; exec "$@"', "run",
            str(selection.config), *command]


def static_command(selection: Selection, app: str, build: Path):
    target = (".PHONY: llm-static-check\nllm-static-check:\n"
              "\t$(VX_CXX) $(VX_CFLAGS) -fsyntax-only $(VX_SRCS)\n"
              "\t$(CXX) $(CXXFLAGS) -fsyntax-only $(SRCS)\n"
              "\t$(if $(BENCH_SRCS),$(CXX) $(BENCH_CXXFLAGS) -fsyntax-only $(BENCH_SRCS),:)\n")
    command = ["make", "--no-print-directory", "-C", str(build / "tests/regression" / app),
               "--eval", target, "llm-static-check"]
    return ["bash", "-c", 'source "$1"; shift; exec "$@"', "static",
            str(selection.config), *command]


def execution_stages(selected, results, checks):
    """Finish every correctness case before allowing any benchmark."""
    passed = {(row.get("candidate"), row.get("app"), row.get("shape")) for row in results
              if row["phase"] == "correctness" and row["status"].startswith("PASS")}
    yield "correctness", [case for case in selected
                          if (case.candidate, case.app, case.shape) not in passed]
    checked = [row for row in results if row["phase"] == "correctness"]
    if (checks == "both" and len(checked) == len(selected)
            and all(row["status"].startswith("PASS") for row in checked)):
        yield "benchmark", [case for case in selected if case.pair]


def notify(output: Path, metadata: dict):
    if "notification_exit_code" in metadata:
        return
    report = json.loads((output / "results.json").read_text())
    failures = [f"{row['app']}/{row['shape']} {row['phase']}: {row['reason']}"
                for row in report["results"] if row["status"] == "FAIL"]
    failures += [f"{row['pair']}: +{row['overhead_pct']:.2f}% > {row['limit_pct']:g}%"
                 for row in report["comparisons"]
                 if row["status"] == "FAIL" and row["overhead_pct"] is not None]
    detail = "; ".join(failures) or metadata.get("error", "regression gate failed")
    message = f"LLM regression {metadata['gate']}: {detail}. Report: {output / 'SUMMARY.md'}"
    notifier = shutil.which("notify-me")
    metadata["notification_message"] = message
    metadata["notification_exit_code"] = execute([notifier, "alarm", "-m", message], REPO,
        output / "notification.log", 30) if notifier else "notify-me unavailable"


def reuse_correctness(report_path: Path, selected, metadata):
    """Reuse only matching PASS evidence; changed kernels still execute normally."""
    previous = json.loads(report_path.read_text())
    old = previous["metadata"]
    for key in ("mode", "fp16_small_value", "fp16_abs_tol"):
        if old.get(key) != metadata.get(key):
            raise ValueError(f"cannot reuse correctness with different {key}")
    old_cases = {(c["candidate"], c["app"], c["shape"]): c for c in old["cases"]}
    rows = []
    for case in selected:
        key = (case.candidate, case.app, case.shape)
        if (old_cases.get(key) != asdict(case)
                or old["configs"].get(case.candidate) != metadata["configs"].get(case.candidate)
                or old.get("source_identities", {}).get(case.app) != metadata["source_identities"][case.app]
                or old.get("kernel_variants", {}).get(case.app) != metadata["kernel_variants"][case.app]):
            continue
        row = next((r for r in previous["results"] if
                    (r["candidate"], r["app"], r["shape"]) == key
                    and r["phase"] == "correctness" and r["status"].startswith("PASS")), None)
        if not row or not Path(row["log"]).is_file():
            continue
        if Path(row["config"]).stat().st_mtime_ns > Path(row["log"]).stat().st_mtime_ns:
            continue
        rows.append(dict(row, reused_from=str(report_path.resolve())))
    return rows


def comparisons(selected, results, limit, softmax_limit=30, quant_limit=30):
    output = []
    for key in sorted({case.pair for case in selected if case.pair}):
        members = [case for case in selected if case.pair == key]
        app = key.split("/", 1)[0]
        pair_limit = (softmax_limit if app == "softmax" else
                      quant_limit if app == "kv_cache_quant_w4a16" else limit)
        row = {"pair": key, "status": "NOT_CHECKED", "overhead_pct": None,
               "standalone_cycle": None, "fused_cycle": None, "limit_pct": pair_limit}
        if len(members) != 2:
            row["reason"] = "both C1 standalone and C4 fused must be selected"
        else:
            plain = next(case for case in members if case.candidate == "C1")
            fused = next(case for case in members if case.candidate == "C4")
            def lookup(case, phase):
                return next((item for item in results if item["app"] == case.app
                             and item["shape"] == case.shape and item["phase"] == phase), None)
            checked = [lookup(case, "correctness") for case in (plain, fused)]
            measured = [lookup(case, "benchmark") for case in (plain, fused)]
            if not all(item and item["status"].startswith("PASS") for item in checked):
                row.update(status="FAIL", reason="correctness failed; speed cannot approve this pair")
            elif not all(item and item["status"] == "PASS" and item["cycle"] for item in measured):
                row.update(status="FAIL", reason="valid benchmark cycles missing")
            else:
                a, b = (item["cycle"] for item in measured)
                overhead = (b / a - 1) * 100
                # Compare cycles directly so an exact 30% boundary stays inclusive.
                within_limit = (b - a) * 100 <= a * pair_limit
                row.update(standalone_cycle=a, fused_cycle=b, overhead_pct=overhead,
                           status="PASS" if within_limit else "FAIL",
                           reason="" if within_limit else f"overhead exceeds {pair_limit:g}%")
        output.append(row)
    return output


def write_reports(directory, results, pairs, metadata):
    (directory / "results.json").write_text(json.dumps(
        {"metadata": metadata, "results": results, "comparisons": pairs}, indent=2) + "\n")
    for name, rows in (("results", results), ("comparisons", pairs)):
        if rows:
            fields = list(dict.fromkeys(key for row in rows for key in row))
            with (directory / f"{name}.csv").open("w", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=fields)
                writer.writeheader()
                writer.writerows(rows)
    lines = ["# LLM kernel regression", "", f"Gate: **{metadata['gate']}**", "",
             "| Candidate | Kernel | Shape | Phase | Status | Cycle | Log |",
             "|---|---|---|---|---|---:|---|"]
    for row in results:
        lines.append(f"| {row['candidate']} | {row['app']} | {row['shape']} | {row['phase']} | "
                     f"{row['status']} | {row['cycle'] or ''} | [{Path(row['log']).name}]({row['log']}) |")
    lines.extend(("", "| Pair | Standalone cycle | Fused cycle | Overhead | Limit | Status | Reason |",
                  "|---|---:|---:|---:|---:|---|---|"))
    for row in pairs:
        overhead = "" if row["overhead_pct"] is None else f"{row['overhead_pct']:.2f}%"
        lines.append(f"| {row['pair']} | {row['standalone_cycle'] or ''} | "
                     f"{row['fused_cycle'] or ''} | {overhead} | {row.get('limit_pct', '')}% | {row['status']} | {row.get('reason', '')} |")
    (directory / "SUMMARY.md").write_text("\n".join(lines) + "\n")


def parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=("xrt-vcs-sim", "hw"))
    p.add_argument("--config", action="append", default=[], metavar="[C1|C3|C4=]ALIAS_OR_PATH")
    p.add_argument("--candidate-map", type=Path, default=REPO / "analysis_workspace/candidates_fpga_utils/candidate_fpga_bins.yaml")
    p.add_argument("--candidates", help="comma-separated C1,C3,C4 (default: all, or inferred from unqualified configs)")
    p.add_argument("--apps", default="*", help="comma-separated application globs, e.g. 'softmax*,hadamard*'")
    p.add_argument("--shapes", default="*", help="comma-separated shape globs; --list shows names")
    p.add_argument("--case-file", type=Path,
                   help="JSON list of Case fields for reproducing actual pipeline workloads")
    p.add_argument("--build-dir", type=Path, default=REPO / "build_llm_regression")
    p.add_argument("--output", type=Path, help="new directory for logs, CSV, JSON, and SUMMARY.md")
    p.add_argument("--timeout", type=float, default=300, help="seconds per build/run")
    p.add_argument("--iterations", type=int, default=3, help="benchmark iterations (median cycle)")
    p.add_argument("--max-overhead-pct", type=float, default=50,
                   help="overhead limit for general pairs (default: 50%%)")
    p.add_argument("--softmax-max-overhead-pct", type=float, default=30,
                   help="softmax pair overhead limit (default: 30%%)")
    p.add_argument("--quant-max-overhead-pct", type=float, default=30,
                   help="quantization pair overhead limit (default: 30%%)")
    p.add_argument("--fp16-small-value", type=float, default=0.001, help="near-zero cutoff; 0 disables exceptions")
    p.add_argument("--fp16-abs-tol", type=float, default=0.0001,
                   help="maximum absolute error for fully reported near-zero mismatches")
    p.add_argument("--kernel-variant", action="append", default=[], metavar="APP=VARIANT")
    p.add_argument("--reuse-correctness", type=Path,
                   help="reuse matching PASS correctness rows from a previous results.json")
    p.add_argument("--checks", choices=("both", "correctness"), default="both")
    p.add_argument("--static-only", action="store_true",
                   help="compile-check selected host/device kernels under their actual config, without an FPGA")
    p.add_argument("--_hardware-worker", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--fail-fast", action="store_true")
    p.add_argument("--notify", action="store_true", help="run notify-me alarm once on regression failure")
    p.add_argument("--dry-run", action="store_true", help="print commands without building, allocating, or running")
    p.add_argument("--list", action="store_true", help="list selected cases without running")
    p.add_argument("--srun-time", default="02:00:00", help="single FPGA allocation wall-time")
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    if (args.timeout <= 0 or args.iterations < 1 or args.fp16_small_value < 0
            or args.fp16_abs_tol < 0 or not all(math.isfinite(x) for x in
            (args.timeout, args.fp16_small_value, args.fp16_abs_tol, args.max_overhead_pct,
             args.softmax_max_overhead_pct, args.quant_max_overhead_pct))):
        raise ValueError("timeout/iterations must be positive; tolerances finite and nonnegative")
    aliases = load_fpga_bin_aliases()
    with args.candidate_map.open() as stream:
        defaults = safe_load(stream)["candidates"]
    selections = {candidate: defaults[candidate] for candidate in ("C1", "C3", "C4")}
    inferred = []
    for value in args.config:
        prefix, equal, raw = value.partition("=")
        if equal:
            if prefix not in selections:
                raise ValueError("config prefix must be C1, C3, or C4")
            candidate = prefix
        else:
            raw = value
            candidate = infer_candidate(resolve_selection(raw, args.mode, aliases))
            inferred.append(candidate)
        selections[candidate] = raw
    active = args.candidates.split(",") if args.candidates else (inferred or list(selections))
    if not set(active) <= selections.keys():
        raise ValueError("candidates must be C1, C3, or C4")
    def matches(value, patterns):
        return any(fnmatch.fnmatchcase(value, pattern) for pattern in patterns.split(","))
    selected = [case for case in load_cases(args.case_file) if case.candidate in active
                and matches(case.app, args.apps) and matches(case.shape, args.shapes)]
    if not selected:
        raise ValueError("no matching cases")
    resolved = {candidate: resolve_selection(selections[candidate], args.mode, aliases)
                for candidate in {case.candidate for case in selected}}
    for candidate, selection in resolved.items():
        actual = infer_candidate(selection)
        if actual != candidate:
            raise ValueError(f"{candidate} requires its matching backend; {selection.config} is {actual}")
    requested_variants = parse_variants(args.kernel_variant, REPO)
    variants = variant_environment(REPO, requested_variants)
    if args.list or args.dry_run:
        for case in selected:
            print(f"{case.candidate} {case.app:38s} {case.shape:14s} {case.args}")
            if args.dry_run:
                print("  " + shlex.join(command_for(args.mode, resolved[case.candidate], case)))
                if case.pair and args.checks == "both":
                    print("  " + shlex.join(command_for(args.mode, resolved[case.candidate], case, True, args.iterations)))
        print(f"{len(selected)} correctness cases; {len({case.pair for case in selected if case.pair})} pair keys")
        return 0
    if args._hardware_worker and (args.mode != "hw" or not os.environ.get("SLURM_JOB_ID")):
        raise ValueError("hardware worker requires a Slurm allocation")
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output = (args.output or args.build_dir / "results" / stamp).expanduser().resolve()
    if not args._hardware_worker:
        output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, **variants, CC="/usr/bin/gcc", CXX="/usr/bin/g++")
    # Do not inherit an unrelated FPGA image or RTL CONFIGS from the caller.
    for name in ("CONFIGS", "FPGA_BIN_DIR", "XRT_XCLBIN_PATH"):
        env.pop(name, None)
    results = []
    metadata = {"mode": args.mode, "gate": "RUNNING", "overhead_limit_pct": args.max_overhead_pct,
                "overhead_limits_pct": {"default": args.max_overhead_pct,
                                        "softmax": args.softmax_max_overhead_pct,
                                        "quantization": args.quant_max_overhead_pct},
                "fp16_small_value": args.fp16_small_value, "fp16_abs_tol": args.fp16_abs_tol,
                "configs": {key: {"config": str(value.config), "alias": value.alias}
                            for key, value in resolved.items()}, "variants": variants,
                "slurm_job_id": os.environ.get("SLURM_JOB_ID"),
                "cases": [asdict(case) for case in selected]}
    if args._hardware_worker:
        previous = json.loads((output / "results.json").read_text())
        if previous["metadata"]["gate"] != "STATIC_PASS":
            raise ValueError("hardware execution needs a successful static preflight")
        results = previous["results"]
        metadata.update(previous["metadata"], gate="RUNNING", slurm_job_id=os.environ["SLURM_JOB_ID"])
    print(f"Results: {output}", flush=True)
    locks = []
    try:
        for candidate in sorted(resolved):
            build = args.build_dir.expanduser().resolve() / candidate
            build.mkdir(parents=True, exist_ok=True)
            lock = (build / ".llm_regression.lock").open("a")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locks.append(lock)
            if not args._hardware_worker:
                configure = [str(REPO / "configure"), "--xlen=64", "--tooldir=/opt/vortex",
                             f"--prefix={Path.home() / 'tools/vortex'}"]
                code = execute(configure, build, output / f"configure_{candidate}.log", args.timeout, env)
                if code:
                    raise RuntimeError(f"configure {candidate} failed, exit={code}; see {output}")
                header_command = ["bash", "-c", 'source "$1"; shift; exec "$@"', "headers",
                                  str(resolved[candidate].config), "make", "-C", str(build / "hw"), "config"]
                code = execute(header_command, build, output / f"headers_{candidate}.log", args.timeout, env)
                if code:
                    raise RuntimeError(f"config header generation {candidate} failed, exit={code}")
        if not args._hardware_worker:
            metadata["source_identities"] = {}
            metadata["kernel_variants"] = {}
            seen = set()
            for case in selected:
                if case.app in seen:
                    continue
                seen.add(case.app)
                selection = resolved[case.candidate]
                build = args.build_dir.expanduser().resolve() / case.candidate
                configured, variant, sources = query_selection(
                    build, case.app, selection.config, requested_variants.get(case.app, ""))
                metadata["kernel_variants"][case.app] = dict(configured=configured, selected=variant, sources=sources)
                metadata["source_identities"][case.app] = source_identity(REPO, case.app)
                label = "configured"
                log = output / f"{case.candidate}.{case.app}.{label}.static.log"
                command = static_command(selection, case.app, build)
                started = time.monotonic()
                code = execute(command, build, log, args.timeout, env)
                status = "PASS" if code == 0 else "FAIL"
                results.append(dict(candidate=case.candidate, app=case.app, shape=label,
                    phase="static", status=status, reason="" if code == 0 else f"compile exit={code}",
                    exit_code=code, cycle="", cycle_samples="", elapsed_s=round(time.monotonic()-started,3),
                    log=str(log), command=shlex.join(command), config=str(selection.config), alias=selection.alias))
                print(f"{status}: static {case.app} {label}", flush=True)
                write_reports(output, results, [], metadata)
            static_failed = any(row["status"] == "FAIL" for row in results)
            if not static_failed and not args.static_only and args.reuse_correctness:
                cached = reuse_correctness(args.reuse_correctness.resolve(), selected, metadata)
                results.extend(cached)
                metadata["reused_correctness_count"] = len(cached)
                metadata["reuse_correctness_report"] = str(args.reuse_correctness.resolve())
                print(f"Reused {len(cached)} unchanged correctness PASS cases", flush=True)
            metadata["gate"] = "FAIL" if static_failed else "STATIC_PASS"
            write_reports(output, results, [], metadata)
            if static_failed or args.static_only:
                if static_failed and args.notify:
                    notify(output, metadata)
                    write_reports(output, results, [], metadata)
                return 1 if static_failed else 0
            if args.mode == "hw" and not os.environ.get("SLURM_JOB_ID"):
                for lock in locks:
                    lock.close()
                locks.clear()
                command = ["srun", "--gres=fpga:u55c:1", "--cpus-per-task=4", "--mem=16G",
                           f"--time={args.srun_time}", sys.executable, str(Path(__file__).resolve()),
                           *(sys.argv[1:] if argv is None else argv), "--output", str(output), "--_hardware-worker"]
                print("Static preflight passed; allocating one U55C for the regression", flush=True)
                return subprocess.call(command)
        metadata["gate"] = "RUNNING"
        for phase, stage_cases in execution_stages(selected, results, args.checks):
            print(f"Starting {phase} stage: {len(stage_cases)} cases", flush=True)
            metadata["phase"] = phase
            for case in stage_cases:
                if source_identity(REPO, case.app) != metadata["source_identities"][case.app]:
                    raise RuntimeError(f"{case.app} sources changed after static preflight; rerun the regression")
                selection = resolved[case.candidate]
                build = args.build_dir.expanduser().resolve() / case.candidate
                log = output / f"{case.candidate}.{case.app}.{case.shape}.{phase}.log"
                command = command_for(args.mode, selection, case, phase == "benchmark", args.iterations,
                                      log.with_suffix(".csv"))
                started = time.monotonic()
                case_env = dict(env, VX_REGRESSION_REPORT_ERRORS="1") if phase == "correctness" else env
                code = execute(command, build, log, args.timeout, case_env)
                stats = parse_fpga_cycle_stats(log)
                if phase == "correctness":
                    status, reason = correctness(log, code, case.app, args.fp16_small_value, args.fp16_abs_tol)
                else:
                    status = "PASS" if (code == 0 and stats["fpga_cycle"]
                                         and stats["fpga_cycle_samples"] == args.iterations) else "FAIL"
                    reason = "" if status == "PASS" else f"exit={code}; valid cycles missing"
                row = {"candidate": case.candidate, "app": case.app, "shape": case.shape,
                       "phase": phase, "status": status, "reason": reason, "exit_code": code,
                       "cycle": stats["fpga_cycle"], "cycle_samples": stats["fpga_cycle_samples"],
                       "elapsed_s": round(time.monotonic() - started, 3), "log": str(log),
                       "command": shlex.join(command), "config": str(selection.config), "alias": selection.alias}
                results.append(row)
                print(f"{status}: {case.candidate} {case.app}/{case.shape} {phase} cycles={row['cycle']} {reason}", flush=True)
                write_reports(output, results, [], metadata)
                if status == "FAIL" and args.fail_fast:
                    break
        checked = [row for row in results if row["phase"] == "correctness"]
        functionality_passed = (len(checked) == len(selected)
                                and all(row["status"].startswith("PASS") for row in checked))
        metadata["functionality_gate"] = "PASS" if functionality_passed else "FAIL"
        if not functionality_passed:
            print("Functionality gate failed; overhead measurements skipped", flush=True)
        pairs = comparisons(selected, results, args.max_overhead_pct,
                            args.softmax_max_overhead_pct, args.quant_max_overhead_pct) \
            if args.checks == "both" and functionality_passed else []
        failed = any(row["status"] == "FAIL" for row in results + pairs)
        complete = (len([row for row in results if row["phase"] == "correctness"]) == len(cases())
                    and len(selected) == len(cases()) and args.checks == "both" and args.case_file is None
                    and all(row["status"] == "PASS" for row in pairs))
        metadata["gate"] = "FAIL" if failed else ("PASS" if complete else "PARTIAL_PASS")
        write_reports(output, results, pairs, metadata)
        for row in pairs:
            print(f"{row['status']}: {row['pair']} overhead={row['overhead_pct']} {row.get('reason', '')}")
        print(f"Gate: {metadata['gate']}; report: {output / 'SUMMARY.md'}", flush=True)
        if failed and args.notify:
            notify(output, metadata)
            write_reports(output, results, pairs, metadata)
        return 1 if failed else 0
    except KeyboardInterrupt:
        metadata["gate"] = "INTERRUPTED"
        write_reports(output, results, [], metadata)
        raise
    except Exception as error:
        metadata.update(gate="ERROR", error=str(error))
        write_reports(output, results, [], metadata)
        if args.notify:
            notify(output, metadata)
        write_reports(output, results, [], metadata)
        raise
    finally:
        for lock in locks:
            lock.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
