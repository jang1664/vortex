from __future__ import annotations

import csv
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

from tools.latency_bench.runner import (
    ExecutionUnit,
    MeasurementReuseState,
    RAW_DB_COLUMNS,
    RunOptions,
    StrictMeasurementPolicy,
    evaluate_measurement_coverage,
    measurement_acquisition_settings,
    normalize_skip_existing_columns,
    run_suite,
)
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite, make_exec_key


class RawDbTest(unittest.TestCase):
    def _write_fake_blackbox(
        self,
        build_dir: Path,
        invocation_log: Path | None = None,
        power_samples: int = 5,
    ) -> None:
        (build_dir / "ci").mkdir(parents=True)
        blackbox = build_dir / "ci" / "blackbox.sh"
        log_line = f"printf '%s\\n' \"$*\" >> {invocation_log}\n" if invocation_log else ""
        blackbox.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
bench_args=""
log_file=""
build_only=0
for arg in "$@"; do
  case "$arg" in
    --args=*) bench_args="${{arg#--args=}}" ;;
    --log=*) log_file="${{arg#--log=}}" ;;
    --build-only) build_only=1 ;;
  esac
done
if [[ "$build_only" == "1" ]]; then
  printf 'build ok\n'
  exit 0
fi
{log_line}
raw_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--output=\\([^ ]*\\).*/\\1/p')
power_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-csv=\\([^ ]*\\).*/\\1/p')
power_summary=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-summary=\\([^ ]*\\).*/\\1/p')
mkdir -p "$(dirname "$raw_csv")" "$(dirname "$log_file")"
printf 'fpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n' > "$raw_csv"
printf '[bench-perf] iteration=1/3 begin\n'
printf 'PERF: instrs=10, cycles=100, IPC=0.100000\n'
printf '[bench-perf] iteration=1/3 end\n'
printf '[bench-perf] iteration=2/3 begin\n'
printf 'PERF: instrs=20, cycles=300, IPC=0.066667\n'
printf '[bench-perf] iteration=2/3 end\n'
printf '[bench-perf] iteration=3/3 begin\n'
printf 'PERF: instrs=30, cycles=200, IPC=0.150000\n'
printf '[bench-perf] iteration=3/3 end\n'
if [[ -n "$power_summary" ]]; then
  mkdir -p "$(dirname "$power_summary")"
  printf 'label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,run_min_w,run_avg_w,run_max_w,delta_avg_w,delta_peak_w,energy_j,power_latency,power_fpga_cycle,power_kernel_iterations,power_kernel_iterations_auto,power_target_sec,raw_csv\n' > "$power_summary"
  printf 'fpint_gemm,separate,run,{power_samples},10.0,2,1.0,3.0,4.0,5.0,3.0,4.0,40.0,12.5,2000,64,1,1.0,%s\n' "$power_csv" >> "$power_summary"
fi
printf 'ok\n' > "$log_file"
"""
        )
        blackbox.chmod(0o755)

    def _write_flaky_power_samples_blackbox(self, build_dir: Path, invocation_log: Path) -> None:
        (build_dir / "ci").mkdir(parents=True)
        blackbox = build_dir / "ci" / "blackbox.sh"
        blackbox.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
bench_args=""
log_file=""
build_only=0
for arg in "$@"; do
  case "$arg" in
    --args=*) bench_args="${{arg#--args=}}" ;;
    --log=*) log_file="${{arg#--log=}}" ;;
    --build-only) build_only=1 ;;
  esac
done
if [[ "$build_only" == "1" ]]; then
  printf 'build ok\n'
  exit 0
fi
printf '%s\n' "$*" >> {invocation_log}
raw_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--output=\\([^ ]*\\).*/\\1/p')
power_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-csv=\\([^ ]*\\).*/\\1/p')
power_summary=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-summary=\\([^ ]*\\).*/\\1/p')
mkdir -p "$(dirname "$raw_csv")" "$(dirname "$log_file")"
state_file="${{raw_csv}}.power_samples_state"
if [[ ! -f "$state_file" ]]; then
  printf 'seen\n' > "$state_file"
  samples=0
else
  samples=5
fi
printf 'fpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n' > "$raw_csv"
printf '[bench-perf] iteration=1/3 begin\n'
printf 'PERF: instrs=10, cycles=100, IPC=0.100000\n'
printf '[bench-perf] iteration=1/3 end\n'
printf '[bench-perf] iteration=2/3 begin\n'
printf 'PERF: instrs=20, cycles=300, IPC=0.066667\n'
printf '[bench-perf] iteration=2/3 end\n'
printf '[bench-perf] iteration=3/3 begin\n'
printf 'PERF: instrs=30, cycles=200, IPC=0.150000\n'
printf '[bench-perf] iteration=3/3 end\n'
if [[ -n "$power_summary" ]]; then
  mkdir -p "$(dirname "$power_summary")"
  printf 'label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,run_min_w,run_avg_w,run_max_w,delta_avg_w,delta_peak_w,energy_j,power_latency,power_fpga_cycle,raw_csv\n' > "$power_summary"
  printf 'fpint_gemm,separate,run,%s,10.0,2,1.0,3.0,4.0,5.0,3.0,4.0,40.0,12.5,2000,%s\n' "$samples" "$power_csv" >> "$power_summary"
fi
printf 'ok\n' > "$log_file"
"""
        )
        blackbox.chmod(0o755)

    def _write_fake_fpga_bin(self, fpga_bin_dir: Path, content: str = "fake bitstream") -> str:
        fpga_bin_dir.mkdir()
        xclbin = fpga_bin_dir / "vortex_afu.xclbin"
        xclbin.write_text(content)
        return hashlib.sha256(content.encode()).hexdigest()

    def _write_flaky_xrt_context_blackbox(self, build_dir: Path) -> None:
        (build_dir / "ci").mkdir(parents=True)
        blackbox = build_dir / "ci" / "blackbox.sh"
        blackbox.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
bench_args=""
log_file=""
build_only=0
for arg in "$@"; do
  case "$arg" in
    --args=*) bench_args="${arg#--args=}" ;;
    --log=*) log_file="${arg#--log=}" ;;
    --build-only) build_only=1 ;;
  esac
done
if [[ "$build_only" == "1" ]]; then
  printf 'build ok\n'
  exit 0
fi
raw_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--output=\\([^ ]*\\).*/\\1/p')
power_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-csv=\\([^ ]*\\).*/\\1/p')
power_summary=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-summary=\\([^ ]*\\).*/\\1/p')
mkdir -p "$(dirname "$raw_csv")" "$(dirname "$log_file")"
state_file="${raw_csv}.state"
if [[ ! -f "$state_file" ]]; then
  printf 'seen\n' > "$state_file"
  printf 'terminate called after throwing an instance of '\\''xrt_core::system_error'\\''\n'
  printf '  what():  failed to open cu context: Invalid argument\n'
  exit 2
fi
printf 'fpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n' > "$raw_csv"
if [[ -n "$power_summary" ]]; then
  mkdir -p "$(dirname "$power_summary")"
  printf 'label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,run_min_w,run_avg_w,run_max_w,delta_avg_w,delta_peak_w,energy_j,latency_samples,latency_min_us,latency_avg_us,latency_max_us,raw_csv\n' > "$power_summary"
  printf 'fpint_gemm,separate,run,5,10.0,2,1.0,3.0,4.0,5.0,3.0,4.0,40.0,0,nan,nan,nan,%s\n' "$power_csv" >> "$power_summary"
fi
printf 'ok\n' > "$log_file"
"""
        )
        blackbox.chmod(0o755)

    def _write_failing_xrt_device_blackbox(self, build_dir: Path) -> None:
        (build_dir / "ci").mkdir(parents=True)
        blackbox = build_dir / "ci" / "blackbox.sh"
        blackbox.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "--build-only" ]]; then
    printf 'build ok\n'
    exit 0
  fi
done
printf 'Could not open device\n'
exit 2
"""
        )
        blackbox.chmod(0o755)

    def _write_flaky_timeout_blackbox(self, build_dir: Path) -> None:
        (build_dir / "ci").mkdir(parents=True)
        blackbox = build_dir / "ci" / "blackbox.sh"
        blackbox.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
bench_args=""
log_file=""
build_only=0
for arg in "$@"; do
  case "$arg" in
    --args=*) bench_args="${arg#--args=}" ;;
    --log=*) log_file="${arg#--log=}" ;;
    --build-only) build_only=1 ;;
  esac
done
if [[ "$build_only" == "1" ]]; then
  printf 'build ok\n'
  exit 0
fi
raw_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--output=\\([^ ]*\\).*/\\1/p')
power_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-csv=\\([^ ]*\\).*/\\1/p')
power_summary=$(printf '%s\n' "$bench_args" | sed -n 's/.*--power-summary=\\([^ ]*\\).*/\\1/p')
mkdir -p "$(dirname "$raw_csv")" "$(dirname "$log_file")"
state_file="${raw_csv}.timeout_state"
if [[ ! -f "$state_file" ]]; then
  printf 'seen\n' > "$state_file"
  printf 'simulated timeout\n'
  exit 124
fi
printf 'fpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n' > "$raw_csv"
if [[ -n "$power_summary" ]]; then
  mkdir -p "$(dirname "$power_summary")"
  printf 'label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,run_min_w,run_avg_w,run_max_w,delta_avg_w,delta_peak_w,energy_j,latency_samples,latency_min_us,latency_avg_us,latency_max_us,raw_csv\n' > "$power_summary"
  printf 'fpint_gemm,separate,run,5,10.0,2,1.0,3.0,4.0,5.0,3.0,4.0,40.0,0,nan,nan,nan,%s\n' "$power_csv" >> "$power_summary"
fi
printf 'ok\n' > "$log_file"
"""
        )
        blackbox.chmod(0o755)

    def _write_fake_reset_tools(self, bin_dir: Path, reset_log: Path, srun_log: Path) -> None:
        bin_dir.mkdir()
        srun = bin_dir / "srun"
        srun.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> {srun_log}
while [[ "$#" -gt 0 && "$1" == --* ]]; do
  shift
done
exec "$@"
"""
        )
        srun.chmod(0o755)
        xrt_smi = bin_dir / "xrt-smi"
        xrt_smi.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
cmd=""
for arg in "$@"; do
  case "$arg" in
    examine|reset)
      cmd="$arg"
      break
      ;;
  esac
done
case "$cmd" in
  examine)
    printf 'Device [0000:2a:00.1]\\n'
    ;;
  reset)
    cat >/dev/null
    printf '%s\\n' "$*" >> {reset_log}
    ;;
  *)
    printf 'unexpected xrt-smi args: %s\\n' "$*" >&2
    exit 3
    ;;
esac
"""
        )
        xrt_smi.chmod(0o755)

    def _write_fake_program_tool(self, path: Path, program_log: Path) -> None:
        path.parent.mkdir()
        path.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
cmd=""
for arg in "$@"; do
  case "$arg" in
    examine|program)
      cmd="$arg"
      break
      ;;
  esac
done
case "$cmd" in
  examine)
    printf 'Device [0000:2a:00.1]\\n'
    ;;
  program)
    printf '%s\\n' "$*" >> {program_log}
    ;;
  *)
    printf 'unexpected xrt-smi args: %s\\n' "$*" >&2
    exit 3
    ;;
esac
"""
        )
        path.chmod(0o755)

    def _write_fake_global_only_program_tool(self, path: Path, program_log: Path) -> None:
        path.parent.mkdir()
        path.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
cmd=""
uses_device=0
for arg in "$@"; do
  case "$arg" in
    examine|program)
      cmd="$arg"
      ;;
    --device)
      uses_device=1
      ;;
  esac
done
case "$cmd" in
  examine)
    if [[ "$uses_device" == "1" ]]; then
      printf 'per-index examine is unavailable\\n' >&2
      exit 2
    fi
    printf 'Device [0000:2a:00.1]\\n'
    ;;
  program)
    printf '%s\\n' "$*" >> {program_log}
    ;;
  *)
    printf 'unexpected xrt-smi args: %s\\n' "$*" >&2
    exit 3
    ;;
esac
"""
        )
        path.chmod(0o755)

    def _write_raw_db_row(self, raw_db: Path, **overrides: object) -> None:
        row = {column: "" for column in RAW_DB_COLUMNS}
        row.update({
            "run_id": "existing_run",
            "timestamp_utc": "2026-05-30T00:00:00+00:00",
            "fpga_bin_label": "improve_tcol1",
            "exec_key": "existing_exec",
            "app": "fpint_gemm_ffn_hw",
            "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
            "warmup": "1",
            "iterations": "1",
            "status": "pass",
            "returncode": "0",
            "measure_latency": "1",
            "measure_power": "1",
            "samples": "3",
            "min_us": "1.0",
            "avg_us": "2.0",
            "max_us": "4.0",
            "p50_us": "2.0",
            "p95_us": "3.0",
        })
        row.update({
            key: value for key, value in overrides.items()
            if key in RAW_DB_COLUMNS
        })
        raw_db.parent.mkdir(parents=True, exist_ok=True)
        write_header = not raw_db.exists()
        with raw_db.open("a", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
            if write_header:
                writer.writeheader()
            writer.writerow(row)

    def _strict_unit(self, root: Path) -> ExecutionUnit:
        return ExecutionUnit(
            "strict-exec", "fpint_gemm_ffn_hw",
            "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0", 1, 2,
            root / "raw.csv", root / "power.csv", root / "power.summary.csv",
            root / "run.log",
        )

    def _strict_policy(self, *, measure_power: bool = True, power_min_samples: int = 5,
                       adopt_legacy: bool = False, **overrides: object) -> StrictMeasurementPolicy:
        values = {
            "fpga_bin_label": "C1", "xclbin_sha256": "xsha",
            "config_sha256": "csha", "fpga_period_s": 4e-9,
            "application_source_identity": "app-source-v1",
            "measure_latency": True, "measure_power": measure_power,
            "power_min_samples": power_min_samples,
            "acquisition_settings": {"platform": "xrt", **({"power_mode": "separate"} if measure_power else {})},
            "adopt_legacy": adopt_legacy,
        }
        values.update(overrides)
        return StrictMeasurementPolicy(**values)

    def _strict_manifest(self, root: Path, *, source: object = "app-source-v1",
                         config_sha: str = "csha", period: float = 4e-9,
                         settings: object = None) -> tuple[dict[str, object], Path]:
        return ({
            "run_id": "existing_run",
            "blackbox_timeout": "changed-scheduling-only",
            "stream_case_logs": True,
            "measurement_compatibility": {
                "xclbin_sha256": "xsha", "config_sha256": config_sha,
                "fpga_period_s": period, "application_source_identity": source,
                "acquisition_settings": settings if settings is not None else {
                    "platform": "xrt", "power_mode": "separate"
                },
            },
        }, root / "runs" / "existing_run" / "manifest.json")

    def _write_strict_row(self, raw_db: Path, **overrides: object) -> None:
        values = {
            "run_id": "existing_run", "fpga_bin_label": "C1",
            "xclbin_sha256": "xsha", "warmup": "1", "iterations": "2",
            "measure_latency": "1", "measure_power": "1", "power_samples": "8",
            "power_avg_w": "4", "power_vcc_avg_w": "3", "power_pcie_avg_w": "1",
            "power_dynamic_avg_w": "-0.25",
        }
        values.update(overrides)
        self._write_raw_db_row(raw_db, **values)

    def test_strict_measurement_reuse_is_capability_based_and_ignores_scheduling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw_db = root / "raw_db.csv"
            self._write_strict_row(raw_db, power_samples="4")
            unit = self._strict_unit(root)
            manifest = self._strict_manifest(root)
            manifest[0]["selection_digest"] = "changed-only-because-unused-C2-moved"
            manifest[0]["experiment"] = {"candidates": {"C2": {"xclbin_sha256": "other"}}}

            latency_only = evaluate_measurement_coverage(
                raw_db, [unit], self._strict_policy(measure_power=False),
                manifests={"existing_run": manifest},
            )
            lower_threshold = evaluate_measurement_coverage(
                raw_db, [unit], self._strict_policy(power_min_samples=3),
                manifests={"existing_run": manifest},
            )

            self.assertTrue(latency_only.complete)
            self.assertTrue(lower_threshold.complete)
            self.assertEqual((unit.exec_key,), lower_threshold.reusable_exec_keys)

    def test_strict_measurement_coverage_preserves_bucket_order_and_normalizes_args(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw_db = root / "raw_db.csv"
            first = self._strict_unit(root)
            second = replace(first, exec_key="strict-exec-2", args="-m 2 -n 128")
            self._write_strict_row(
                raw_db,
                run_id="first_reusable",
                args="  -m  1  -n 128 -k 128 -q 32 -t 0 -d 0  ",
            )
            self._write_strict_row(
                raw_db,
                run_id="first_newer_pending",
                xclbin_sha256="other",
            )
            self._write_strict_row(
                raw_db,
                run_id="second_blocked",
                args=" -m  2   -n 128 ",
                xclbin_sha256="",
            )
            self._write_strict_row(
                raw_db,
                run_id="second_newer_pending",
                args="-m 2 -n 128",
                xclbin_sha256="other",
            )
            manifests = {
                run_id: self._strict_manifest(root)
                for run_id in (
                    "first_reusable",
                    "first_newer_pending",
                    "second_blocked",
                    "second_newer_pending",
                )
            }

            coverage = evaluate_measurement_coverage(
                raw_db,
                [first, second],
                self._strict_policy(),
                manifests=manifests,
            )

            self.assertEqual(MeasurementReuseState.REUSE, coverage.evidence[0].state)
            self.assertEqual("first_reusable", coverage.evidence[0].run_id)
            self.assertEqual(MeasurementReuseState.BLOCKED_METADATA, coverage.evidence[1].state)
            self.assertEqual("second_blocked", coverage.evidence[1].run_id)

    def test_strict_measurement_reuse_rejects_incomplete_metrics_and_capabilities(self) -> None:
        cases = (
            ({"measure_power": "0"}, "power capability"),
            ({"power_samples": "4"}, "power samples"),
            ({"power_avg_w": ""}, "power metric power_avg_w"),
            ({"power_dynamic_avg_w": "nan"}, "power metric power_dynamic_avg_w"),
            ({"avg_us": "inf"}, "latency metric avg_us"),
        )
        for changes, reason in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                raw_db = root / "raw_db.csv"
                self._write_strict_row(raw_db, **changes)
                coverage = evaluate_measurement_coverage(
                    raw_db, [self._strict_unit(root)], self._strict_policy(),
                    manifests={"existing_run": self._strict_manifest(root)},
                )
                self.assertFalse(coverage.complete)
                self.assertEqual(MeasurementReuseState.PENDING, coverage.evidence[0].state)
                self.assertTrue(any(reason in item for item in coverage.evidence[0].reasons))

    def test_strict_measurement_reuse_rejects_physical_and_acquisition_mismatches(self) -> None:
        cases = (
            ({"warmup": "9"}, self._strict_manifest, {}, "warmup differs"),
            ({"iterations": "9"}, self._strict_manifest, {}, "iterations differs"),
            ({}, self._strict_manifest, {"config_sha": "other"}, "config_sha256 differs"),
            ({}, self._strict_manifest, {"period": 5e-9}, "fpga_period_s differs"),
            ({}, self._strict_manifest, {"settings": {"platform": "xrt", "power_mode": "inline"}}, "power_mode differs"),
        )
        for row_changes, manifest_factory, manifest_changes, reason in cases:
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                raw_db = root / "raw_db.csv"
                self._write_strict_row(raw_db, **row_changes)
                coverage = evaluate_measurement_coverage(
                    raw_db, [self._strict_unit(root)], self._strict_policy(),
                    manifests={"existing_run": manifest_factory(root, **manifest_changes)},
                )
                self.assertEqual(MeasurementReuseState.PENDING, coverage.evidence[0].state)
                self.assertTrue(any(reason in item for item in coverage.evidence[0].reasons))

    def test_adopt_legacy_only_waives_missing_application_source_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw_db = root / "raw_db.csv"
            self._write_strict_row(raw_db)
            unit = self._strict_unit(root)
            legacy = self._strict_manifest(root, source=None)
            blocked = evaluate_measurement_coverage(
                raw_db, [unit], self._strict_policy(), manifests={"existing_run": legacy}
            )
            adopted = evaluate_measurement_coverage(
                raw_db, [unit], self._strict_policy(adopt_legacy=True),
                manifests={"existing_run": legacy},
            )
            self.assertEqual(MeasurementReuseState.BLOCKED_METADATA, blocked.evidence[0].state)
            self.assertTrue(adopted.complete)
            self.assertTrue(adopted.evidence[0].legacy_provenance)

            raw_db.unlink()
            self._write_strict_row(raw_db, xclbin_sha256="wrong", power_avg_w="")
            contradicted = evaluate_measurement_coverage(
                raw_db, [unit], self._strict_policy(adopt_legacy=True),
                manifests={"existing_run": legacy},
            )
            self.assertFalse(contradicted.complete)

    def test_strict_all_reusable_bypasses_build_hardware_and_live_map_preflight(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out_root = root / "out"
            fpga_dir = root / "missing-fpga-image"
            config = root / "missing-config.sh"
            candidates = {
                label: {
                    "alias": f"alias-{label}", "bin_dir": str(fpga_dir.resolve()),
                    "xclbin": str((fpga_dir / "vortex_afu.xclbin").resolve()),
                    "xclbin_sha256": "xsha", "config": str(config),
                    "config_sha256": "csha", "manifest": str(fpga_dir / "manifest.json"),
                    "manifest_sha256": "msha", "fpga_period_s": 4e-9,
                    "fpga_clock_source": str(fpga_dir / "xclbin.info"),
                }
                for label in ("C1", "C2", "C3", "C4")
            }
            digest = hashlib.sha256(
                json.dumps(candidates, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
            experiment = {
                "schema_version": 1, "candidate_map": str(root / "missing-map.yaml"),
                "selection_digest": digest, "candidates": candidates,
            }
            case = BenchCase(
                "strict", "fpint_gemm_ffn_hw",
                "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0", warmup=1, iterations=2,
            )
            suite = BenchSuite("strict-suite", BenchDefaults(warmup=1, iterations=2), [case], experiment=experiment)
            options = RunOptions(
                build_dir=root / "missing-build", fpga_bin_dir=fpga_dir,
                fpga_bin_label="C1", configs=config, out_dir=out_root, platform="xrt",
                srun=False, run_id="all-reused", skip_existing=True,
                strict_measurement_reuse=True, application_source_identity="app-source-v1",
            )
            self._write_strict_row(out_root / "raw_db.csv")
            manifest, _ = self._strict_manifest(
                root,
                settings=measurement_acquisition_settings(options),
            )
            manifest_dir = out_root / "runs" / "existing_run"
            manifest_dir.mkdir(parents=True)
            (manifest_dir / "manifest.json").write_text(json.dumps(manifest))

            with mock.patch("tools.latency_bench.runner.subprocess.call") as call:
                rc = run_suite(suite, options)

            self.assertEqual(0, rc)
            call.assert_not_called()

    def test_strict_zero_exit_without_complete_rows_returns_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_dir = root / "build"
            self._write_fake_blackbox(build_dir)
            fpga_dir = root / "fpga"
            self._write_fake_fpga_bin(fpga_dir)
            config = root / "config.sh"
            config.write_text("CONFIGS=-DSTRICT\n")
            case = BenchCase("strict", "fpint_gemm_ffn_hw", "-n 128", warmup=1, iterations=2)
            suite = BenchSuite("strict-suite", BenchDefaults(warmup=1, iterations=2), [case])
            options = RunOptions(
                build_dir=build_dir, fpga_bin_dir=fpga_dir, fpga_bin_label="C1",
                configs=config, out_dir=root / "out", platform="xrt", srun=False,
                program_fpga=False, run_id="zero-exit", skip_existing=True,
                strict_measurement_reuse=True, application_source_identity="app-source-v1",
                provenance={"fpga_period_s": 4e-9},
            )

            with mock.patch("tools.latency_bench.runner.subprocess.call", return_value=0):
                rc = run_suite(suite, options)

            self.assertEqual(1, rc)

    def test_run_appends_results_to_top_level_raw_db(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)

            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm_m1_n128_k128",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        kind="fpint_gemm",
                        stage="sweep",
                        name="gemm",
                        shape={"M": 1, "N": 128, "K": 128},
                        warmup=1,
                        iterations=1,
                    )
                ],
            )

            out_root = tmp_path / "latency_db"
            for run_id in ("run_a", "run_b"):
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="improve_tcol1",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=suite.defaults.xrt_device_index,
                        blackbox_args=(),
                        srun=False,
                        program_fpga=False,
                        run_id=run_id,
                    ),
                )
                self.assertEqual(0, rc)

            self.assertTrue((out_root / "runs" / "run_a" / "results.csv").exists())
            self.assertTrue((out_root / "runs" / "run_b" / "results.csv").exists())

            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual(2, len(rows))
            self.assertEqual(["run_a", "run_b"], [row["run_id"] for row in rows])
            self.assertEqual("improve_tcol1", rows[0]["fpga_bin_label"])
            self.assertEqual("fpint_gemm_ffn_hw", rows[0]["app"])
            self.assertEqual("pass", rows[0]["status"])
            self.assertIn("elapsed_wall_s", rows[0])
            self.assertGreaterEqual(float(rows[0]["elapsed_wall_s"]), 0.0)
            self.assertEqual("2.0", rows[0]["p50_us"])
            self.assertEqual("200", rows[0]["fpga_cycle"])
            self.assertEqual("3", rows[0]["fpga_cycle_samples"])
            self.assertEqual("200", rows[0]["fpga_cycle_p50"])
            self.assertEqual("300", rows[0]["fpga_cycle_p95"])
            self.assertEqual("", rows[0]["fpga_cycle_parse_error"])
            self.assertEqual("5", rows[0]["power_samples"])
            self.assertEqual("10.0", rows[0]["power_elapsed_s"])
            self.assertEqual("3.0", rows[0]["power_min_w"])
            self.assertEqual("4.0", rows[0]["power_avg_w"])
            self.assertEqual("5.0", rows[0]["power_max_w"])
            self.assertEqual("12.5", rows[0]["power_latency"])
            self.assertEqual("2000", rows[0]["power_fpga_cycle"])
            self.assertEqual("64", rows[0]["power_kernel_iterations"])
            self.assertEqual("1", rows[0]["power_kernel_iterations_auto"])
            self.assertEqual("1.0", rows[0]["power_target_sec"])
            self.assertEqual("", rows[0]["power_parse_error"])
            self.assertTrue(rows[0]["git_commit"])
            self.assertTrue(rows[0]["git_branch"])
            self.assertIn(rows[0]["git_dirty"], ("0", "1"))

            with (out_root / "runs" / "run_a" / "results.csv").open(newline="") as fp:
                result_rows = list(csv.DictReader(fp))
            self.assertEqual(rows[0]["git_commit"], result_rows[0]["git_commit"])
            self.assertEqual(rows[0]["git_branch"], result_rows[0]["git_branch"])
            self.assertEqual(rows[0]["git_dirty"], result_rows[0]["git_dirty"])
            self.assertEqual(rows[0]["elapsed_wall_s"], result_rows[0]["elapsed_wall_s"])
            self.assertEqual(rows[0]["power_avg_w"], result_rows[0]["power_avg_w"])
            self.assertEqual(rows[0]["power_latency"], result_rows[0]["power_latency"])
            self.assertEqual(rows[0]["power_fpga_cycle"], result_rows[0]["power_fpga_cycle"])
            self.assertEqual(rows[0]["power_kernel_iterations"], result_rows[0]["power_kernel_iterations"])
            self.assertEqual(rows[0]["power_kernel_iterations_auto"], result_rows[0]["power_kernel_iterations_auto"])
            self.assertEqual(rows[0]["power_target_sec"], result_rows[0]["power_target_sec"])
            self.assertEqual(rows[0]["fpga_cycle"], result_rows[0]["fpga_cycle"])

            with (out_root / "runs" / "run_a" / "progress.csv").open(newline="") as fp:
                progress_rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(progress_rows))
            self.assertEqual("pass", progress_rows[0]["status"])
            self.assertEqual("2.0", progress_rows[0]["p50_us"])
            self.assertEqual("200", progress_rows[0]["fpga_cycle"])
            self.assertEqual("4.0", progress_rows[0]["power_avg_w"])
            self.assertEqual("12.5", progress_rows[0]["power_latency"])
            self.assertEqual("2000", progress_rows[0]["power_fpga_cycle"])
            self.assertEqual("64", progress_rows[0]["power_kernel_iterations"])
            self.assertEqual("1", progress_rows[0]["power_kernel_iterations_auto"])
            self.assertEqual("1.0", progress_rows[0]["power_target_sec"])
            self.assertEqual(rows[0]["elapsed_wall_s"], progress_rows[0]["elapsed_wall_s"])

            manifest = json.loads((out_root / "runs" / "run_a" / "manifest.json").read_text())
            self.assertEqual(rows[0]["git_commit"], manifest["git_commit"])
            self.assertEqual(rows[0]["git_branch"], manifest["git_branch"])
            self.assertEqual(rows[0]["git_dirty"], manifest["git_dirty"])

    def test_low_power_samples_marks_status_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir, power_samples=4)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)

            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm_m1_n128_k128",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="low_power_samples",
                ),
            )
            self.assertEqual(0, rc)

            with (out_root / "raw_db.csv").open(newline="") as fp:
                raw_rows = list(csv.DictReader(fp))
            with (out_root / "runs" / "low_power_samples" / "results.csv").open(newline="") as fp:
                result_rows = list(csv.DictReader(fp))
            with (out_root / "runs" / "low_power_samples" / "progress.csv").open(newline="") as fp:
                progress_rows = list(csv.DictReader(fp))

            self.assertEqual("4", raw_rows[0]["power_samples"])
            self.assertEqual("fail", raw_rows[0]["status"])
            self.assertEqual("power_samples_low", raw_rows[0]["failure_reason"])
            self.assertEqual("fail", result_rows[0]["status"])
            self.assertEqual("power_samples_low", result_rows[0]["failure_reason"])
            self.assertEqual("fail", progress_rows[0]["status"])
            self.assertEqual("power_samples_low", progress_rows[0]["failure_reason"])

    def test_retry_power_samples_low_reruns_and_keeps_final_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            invocation_log = tmp_path / "invocations.log"
            self._write_flaky_power_samples_blackbox(build_dir, invocation_log)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            reset_log = tmp_path / "reset.log"
            srun_log = tmp_path / "srun.log"
            fake_bin = tmp_path / "bin"
            self._write_fake_reset_tools(fake_bin, reset_log, srun_log)

            suite = BenchSuite(
                name="retry_power_samples_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, blackbox_timeout="5m"),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = f"{fake_bin}{os.pathsep}{old_path}"
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="retry_power_bin",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=suite.defaults.xrt_device_index,
                        blackbox_args=(),
                        blackbox_timeout=suite.defaults.blackbox_timeout,
                        srun=False,
                        program_fpga=False,
                        run_id="retry_power_samples_run",
                        retry=True,
                        retry_max_rounds=2,
                        retry_reset_wait="0",
                    ),
                )
            finally:
                os.environ["PATH"] = old_path

            self.assertEqual(0, rc)
            self.assertEqual(2, len(invocation_log.read_text().splitlines()))

            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual("0", rows[0]["returncode"])
            self.assertEqual("", rows[0]["failure_phase"])
            self.assertEqual("", rows[0]["failure_reason"])
            self.assertEqual("5", rows[0]["power_samples"])

            run_dir = out_root / "runs" / "retry_power_samples_run"
            with (run_dir / "attempt_status.csv").open(newline="") as fp:
                attempt_rows = list(csv.DictReader(fp))
            self.assertEqual(2, len(attempt_rows))
            self.assertEqual(["1", "2"], [row["retry_round"] for row in attempt_rows])
            self.assertEqual(["power_samples_low", ""], [row["failure_reason"] for row in attempt_rows])
            self.assertEqual(["0", "0"], [row["reset_ran"] for row in attempt_rows])
            self.assertFalse(reset_log.exists())
            self.assertFalse(srun_log.exists())

    def test_live_raw_db_keeps_one_row_for_shared_execution(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            invocation_log = tmp_path / "invocations.log"
            self._write_fake_blackbox(build_dir, invocation_log=invocation_log)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)

            shared_args = "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"
            suite = BenchSuite(
                name="shared_exec_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(case_id="case_a", app="fpint_gemm_ffn_hw", args=shared_args, warmup=1, iterations=1),
                    BenchCase(case_id="case_b", app="fpint_gemm_ffn_hw", args=shared_args, warmup=1, iterations=1),
                ],
            )
            out_root = tmp_path / "latency_db"
            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="shared_run",
                ),
            )

            self.assertEqual(0, rc)
            self.assertEqual(1, len(invocation_log.read_text().splitlines()))
            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual(
                make_exec_key(rows[0]["xclbin_sha256"], rows[0]["app"], rows[0]["args"]),
                rows[0]["exec_key"],
            )

    def test_programs_fpga_before_bench_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            fake_xrt_smi = tmp_path / "bin" / "xrt-smi"
            xrt_program_log = tmp_path / "xrt_program.log"
            self._write_fake_program_tool(fake_xrt_smi, xrt_program_log)

            suite = BenchSuite(
                name="program_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            old_xrt_smi = os.environ.get("XRT_SMI")
            old_xrt_device_bdf = os.environ.get("XRT_DEVICE_BDF")
            os.environ["XRT_SMI"] = str(fake_xrt_smi)
            os.environ.pop("XRT_DEVICE_BDF", None)
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="program_bin",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        blackbox_args=(),
                        srun=False,
                        run_id="program_run",
                    ),
                )
            finally:
                if old_xrt_smi is None:
                    os.environ.pop("XRT_SMI", None)
                else:
                    os.environ["XRT_SMI"] = old_xrt_smi
                if old_xrt_device_bdf is None:
                    os.environ.pop("XRT_DEVICE_BDF", None)
                else:
                    os.environ["XRT_DEVICE_BDF"] = old_xrt_device_bdf

            self.assertEqual(0, rc)
            self.assertEqual(
                f"program --device 0000:2a:00.1 --user {fpga_bin_dir / 'vortex_afu.xclbin'}",
                xrt_program_log.read_text().strip(),
            )
            identity_env = out_root / "runs" / "program_run" / "fpga_identity.env"
            identity_json = out_root / "runs" / "program_run" / "fpga_identity.json"
            self.assertIn("XRT_DEVICE_INDEX=0", identity_env.read_text())
            self.assertEqual("0000:2a:00.1", json.loads(identity_json.read_text())["xrt_device_bdf"])
            program_log = out_root / "runs" / "program_run" / "logs" / "program_fpga.log"
            self.assertIn("programming FPGA: device=0000:2a:00.1", program_log.read_text())

    def test_program_identity_falls_back_to_single_global_xrt_bdf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            fake_xrt_smi = tmp_path / "bin" / "xrt-smi"
            xrt_program_log = tmp_path / "xrt_program.log"
            self._write_fake_global_only_program_tool(fake_xrt_smi, xrt_program_log)

            suite = BenchSuite(
                name="program_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            old_xrt_smi = os.environ.get("XRT_SMI")
            old_xrt_device_index = os.environ.get("XRT_DEVICE_INDEX")
            old_xrt_device_bdf = os.environ.get("XRT_DEVICE_BDF")
            os.environ["XRT_SMI"] = str(fake_xrt_smi)
            os.environ.pop("XRT_DEVICE_INDEX", None)
            os.environ.pop("XRT_DEVICE_BDF", None)
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="program_bin",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=0,
                        blackbox_args=(),
                        srun=False,
                        run_id="program_run",
                    ),
                )
            finally:
                if old_xrt_smi is None:
                    os.environ.pop("XRT_SMI", None)
                else:
                    os.environ["XRT_SMI"] = old_xrt_smi
                if old_xrt_device_index is None:
                    os.environ.pop("XRT_DEVICE_INDEX", None)
                else:
                    os.environ["XRT_DEVICE_INDEX"] = old_xrt_device_index
                if old_xrt_device_bdf is None:
                    os.environ.pop("XRT_DEVICE_BDF", None)
                else:
                    os.environ["XRT_DEVICE_BDF"] = old_xrt_device_bdf

            self.assertEqual(0, rc)
            identity_json = out_root / "runs" / "program_run" / "fpga_identity.json"
            self.assertEqual(
                {"xrt_device_index": "0", "xrt_device_bdf": "0000:2a:00.1"},
                {
                    key: json.loads(identity_json.read_text())[key]
                    for key in ("xrt_device_index", "xrt_device_bdf")
                },
            )
            self.assertEqual(
                f"program --device 0000:2a:00.1 --user {fpga_bin_dir / 'vortex_afu.xclbin'}",
                xrt_program_log.read_text().strip(),
            )

    def test_timeout_returncode_is_appended_as_timeout_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            (build_dir / "ci").mkdir(parents=True)
            blackbox = build_dir / "ci" / "blackbox.sh"
            blackbox.write_text("#!/usr/bin/env bash\nexit 124\n")
            blackbox.chmod(0o755)
            fpga_bin_dir = tmp_path / "fpga_bin"
            fpga_bin_dir.mkdir()
            (fpga_bin_dir / "vortex_afu.xclbin").write_text("fake bitstream")

            suite = BenchSuite(
                name="timeout_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm_timeout",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="timeout_bin",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="timeout_run",
                    prebuild=False,
                ),
            )

            self.assertEqual(0, rc)
            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual("timeout", rows[0]["status"])
            self.assertEqual("124", rows[0]["returncode"])

    def test_build_fail_is_appended_as_build_fail_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            (build_dir / "ci").mkdir(parents=True)
            blackbox = build_dir / "ci" / "blackbox.sh"
            blackbox.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "--build-only" ]]; then
    echo "compile failed"
    exit 2
  fi
done
exit 0
"""
            )
            blackbox.chmod(0o755)
            fpga_bin_dir = tmp_path / "fpga_bin"
            fpga_bin_dir.mkdir()
            (fpga_bin_dir / "vortex_afu.xclbin").write_text("fake bitstream")

            suite = BenchSuite(
                name="build_fail_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm_build_fail",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="build_fail_bin",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="build_fail_run",
                ),
            )

            self.assertEqual(0, rc)
            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual("build_fail", rows[0]["status"])
            self.assertEqual("2", rows[0]["returncode"])
            self.assertEqual("build", rows[0]["failure_phase"])
            self.assertEqual("build", rows[0]["failure_reason"])
            self.assertIn("compile failed", Path(rows[0]["log_file"]).read_text())

    def test_xrt_context_open_failure_retries_same_execution(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_flaky_xrt_context_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            reset_log = tmp_path / "reset.log"
            srun_log = tmp_path / "srun.log"
            fake_bin = tmp_path / "bin"
            self._write_fake_reset_tools(fake_bin, reset_log, srun_log)
            bash_env = tmp_path / "bash_env.sh"
            bash_env.write_text("sleep() { :; }\n")

            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, blackbox_timeout="5m"),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            old_path = os.environ.get("PATH", "")
            old_bash_env = os.environ.get("BASH_ENV")
            old_slurm_job_id = os.environ.get("SLURM_JOB_ID")
            os.environ["PATH"] = f"{fake_bin}{os.pathsep}{old_path}"
            os.environ["BASH_ENV"] = str(bash_env)
            os.environ["SLURM_JOB_ID"] = "test_job"
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="improve_tcol1",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=suite.defaults.xrt_device_index,
                        blackbox_args=(),
                        blackbox_timeout=suite.defaults.blackbox_timeout,
                        srun=False,
                        program_fpga=False,
                        run_id="retry_run",
                        retry_reset_wait="0",
                    ),
                )
            finally:
                os.environ["PATH"] = old_path
                if old_bash_env is None:
                    os.environ.pop("BASH_ENV", None)
                else:
                    os.environ["BASH_ENV"] = old_bash_env
                if old_slurm_job_id is None:
                    os.environ.pop("SLURM_JOB_ID", None)
                else:
                    os.environ["SLURM_JOB_ID"] = old_slurm_job_id

            self.assertEqual(0, rc)
            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual("0", rows[0]["returncode"])
            self.assertEqual("", rows[0]["failure_phase"])
            self.assertEqual("", rows[0]["failure_reason"])
            log_text = Path(rows[0]["log_file"]).read_text()
            self.assertIn("xrt_context_open retry 1/3", log_text)
            self.assertIn("failed to open cu context", log_text)
            self.assertEqual("reset -d 0000:2a:00.1", reset_log.read_text().strip())
            self.assertFalse(srun_log.exists())

    def test_xrt_device_open_reset_failure_is_recorded_without_outer_retry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_failing_xrt_device_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            reset_log = tmp_path / "reset.log"
            srun_log = tmp_path / "srun.log"
            fake_bin = tmp_path / "bin"
            self._write_fake_reset_tools(fake_bin, reset_log, srun_log)
            xrt_smi = fake_bin / "xrt-smi"
            xrt_smi.write_text(
                f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *examine* ]]; then
  printf 'Device [0000:2a:00.1]\n'
  exit 0
fi
cat >/dev/null
printf '%s\n' "$*" >> {reset_log}
exit 2
"""
            )
            xrt_smi.chmod(0o755)
            bash_env = tmp_path / "bash_env.sh"
            bash_env.write_text("sleep() { :; }\n")

            suite = BenchSuite(
                name="device_open_fail_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, blackbox_timeout="5m"),
                cases=[BenchCase(case_id="device_fail", app="fpint_gemm_ffn_hw", args="")],
            )
            out_root = tmp_path / "latency_db"
            old_env = {
                key: os.environ.get(key)
                for key in ("PATH", "BASH_ENV", "SLURM_JOB_ID")
            }
            os.environ["PATH"] = f"{fake_bin}{os.pathsep}{old_env['PATH'] or ''}"
            os.environ["BASH_ENV"] = str(bash_env)
            os.environ["SLURM_JOB_ID"] = "test_job"
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="device_fail_bin",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=0,
                        blackbox_args=(),
                        blackbox_timeout=suite.defaults.blackbox_timeout,
                        srun=False,
                        program_fpga=False,
                        measure_power=False,
                        run_id="device_fail_run",
                        retry=True,
                        retry_reset_wait="0",
                    ),
                )
            finally:
                for key, value in old_env.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value

            self.assertEqual(0, rc)
            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("xrt_device_open", rows[0]["failure_reason"])
            with (out_root / "runs" / "device_fail_run" / "attempt_status.csv").open(newline="") as fp:
                attempts = list(csv.DictReader(fp))
            self.assertEqual(1, len(attempts))
            self.assertEqual("2", attempts[0]["reset_rc"])

    def test_retry_timeout_resets_fpga_and_keeps_final_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_flaky_timeout_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            reset_log = tmp_path / "reset.log"
            srun_log = tmp_path / "srun.log"
            fake_bin = tmp_path / "bin"
            self._write_fake_reset_tools(fake_bin, reset_log, srun_log)

            suite = BenchSuite(
                name="retry_timeout_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, blackbox_timeout="10s"),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = f"{fake_bin}{os.pathsep}{old_path}"
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="retry_bin",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=suite.defaults.xrt_device_index,
                        blackbox_args=(),
                        blackbox_timeout=suite.defaults.blackbox_timeout,
                        srun=False,
                        program_fpga=False,
                        run_id="retry_timeout_run",
                        retry=True,
                        retry_max_rounds=2,
                        retry_reset_wait="0",
                    ),
                )
            finally:
                os.environ["PATH"] = old_path

            self.assertEqual(0, rc)
            with (out_root / "raw_db.csv").open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual("0", rows[0]["returncode"])

            run_dir = out_root / "runs" / "retry_timeout_run"
            with (run_dir / "run_status.csv").open(newline="") as fp:
                status_rows = list(csv.DictReader(fp))
            self.assertEqual(["timeout", ""], [row["failure_reason"] for row in status_rows])

            with (run_dir / "attempt_status.csv").open(newline="") as fp:
                attempt_rows = list(csv.DictReader(fp))
            self.assertEqual(2, len(attempt_rows))
            self.assertEqual(["1", "2"], [row["retry_round"] for row in attempt_rows])
            self.assertEqual(["10s", "11s"], [row["blackbox_timeout"] for row in attempt_rows])
            self.assertEqual(["1", "0"], [row["reset_ran"] for row in attempt_rows])
            self.assertEqual("0", attempt_rows[0]["reset_rc"])
            self.assertEqual("reset -d 0000:2a:00.1", reset_log.read_text().strip())
            self.assertFalse(srun_log.exists())

    def test_retry_timeout_rerun_replaces_previous_failed_row(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            (build_dir / "ci").mkdir(parents=True)
            blackbox = build_dir / "ci" / "blackbox.sh"
            blackbox.write_text("#!/usr/bin/env bash\nexit 124\n")
            blackbox.chmod(0o755)
            fpga_bin_dir = tmp_path / "fpga_bin"
            xclbin_sha = self._write_fake_fpga_bin(fpga_bin_dir)

            case = BenchCase(
                case_id="gemm_timeout",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            suite = BenchSuite(
                name="retry_timeout_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, blackbox_timeout="1s"),
                cases=[case],
            )
            out_root = tmp_path / "latency_db"
            raw_db = out_root / "raw_db.csv"
            self._write_raw_db_row(
                raw_db,
                run_id="old_timeout_run",
                case_id=case.case_id,
                exec_key=case.exec_key,
                app=case.app,
                args=case.args,
                fpga_bin_label="retry_bin",
                xclbin_sha256=xclbin_sha,
                warmup=case.warmup,
                iterations=case.iterations,
                status="timeout",
                returncode="124",
                failure_phase="run",
                failure_reason="timeout",
                elapsed_wall_s="10.000",
            )

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="retry_bin",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    blackbox_timeout=suite.defaults.blackbox_timeout,
                    srun=False,
                    program_fpga=False,
                    measure_power=False,
                    run_id="new_timeout_run",
                    retry=True,
                    retry_max_rounds=1,
                    retry_reset_wait="0",
                    retry_reset_cmd="true",
                    prebuild=False,
                ),
            )

            self.assertEqual(0, rc)
            with raw_db.open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("new_timeout_run", rows[0]["run_id"])
            self.assertEqual("timeout", rows[0]["status"])
            self.assertEqual("124", rows[0]["returncode"])
            self.assertNotEqual("10.000", rows[0]["elapsed_wall_s"])

    def test_retry_timeout_resets_directly_inside_slurm_allocation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_flaky_timeout_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)
            reset_log = tmp_path / "reset.log"
            srun_log = tmp_path / "srun.log"
            fake_bin = tmp_path / "bin"
            self._write_fake_reset_tools(fake_bin, reset_log, srun_log)

            suite = BenchSuite(
                name="retry_timeout_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, blackbox_timeout="10s"),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            old_path = os.environ.get("PATH", "")
            old_slurm_job_id = os.environ.get("SLURM_JOB_ID")
            os.environ["PATH"] = f"{fake_bin}{os.pathsep}{old_path}"
            os.environ["SLURM_JOB_ID"] = "test_job"
            try:
                rc = run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="retry_bin",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=suite.defaults.xrt_device_index,
                        blackbox_args=(),
                        blackbox_timeout=suite.defaults.blackbox_timeout,
                        srun=False,
                        program_fpga=False,
                        run_id="retry_timeout_run",
                        retry=True,
                        retry_max_rounds=2,
                        retry_reset_wait="0",
                    ),
                )
            finally:
                os.environ["PATH"] = old_path
                if old_slurm_job_id is None:
                    os.environ.pop("SLURM_JOB_ID", None)
                else:
                    os.environ["SLURM_JOB_ID"] = old_slurm_job_id

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "retry_timeout_run"
            with (run_dir / "attempt_status.csv").open(newline="") as fp:
                attempt_rows = list(csv.DictReader(fp))
            self.assertEqual(["1", "0"], [row["reset_ran"] for row in attempt_rows])
            self.assertEqual("0", attempt_rows[0]["reset_rc"])
            self.assertEqual("reset -d 0000:2a:00.1", reset_log.read_text().strip())
            self.assertFalse(srun_log.exists())
            self.assertIn(
                "retry reset: direct xrt-smi reset -d 0000:2a:00.1",
                Path(attempt_rows[0]["log_file"]).read_text(),
            )

    def test_skip_existing_runs_only_missing_or_failed_measurements(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            invocation_log = tmp_path / "invocations.log"
            self._write_fake_blackbox(build_dir, invocation_log=invocation_log)
            fpga_bin_dir = tmp_path / "fpga_bin"
            xclbin_sha = self._write_fake_fpga_bin(fpga_bin_dir)

            passed_case = BenchCase(
                case_id="passed",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            failed_case = BenchCase(
                case_id="failed",
                app="fpint_gemm_ffn_hw",
                args="-m 2 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[passed_case, failed_case],
            )
            out_root = tmp_path / "latency_db"
            raw_db = out_root / "raw_db.csv"
            self._write_raw_db_row(
                raw_db,
                case_id=passed_case.case_id,
                exec_key=passed_case.exec_key,
                app=passed_case.app,
                args=passed_case.args,
                fpga_bin_label="improve_tcol1",
                xclbin_sha256=xclbin_sha,
                warmup=passed_case.warmup,
                iterations=passed_case.iterations,
                status="pass",
            )
            self._write_raw_db_row(
                raw_db,
                case_id=failed_case.case_id,
                exec_key=failed_case.exec_key,
                app=failed_case.app,
                args=failed_case.args,
                fpga_bin_label="improve_tcol1",
                xclbin_sha256=xclbin_sha,
                warmup=failed_case.warmup,
                iterations=failed_case.iterations,
                status="fail",
                returncode="2",
            )

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="resume_run",
                    skip_existing=True,
                ),
            )

            self.assertEqual(0, rc)
            invocations = invocation_log.read_text().splitlines()
            self.assertEqual(1, len(invocations))
            self.assertIn("-m 2 -n 128 -k 128", invocations[0])
            self.assertNotIn("-m 1 -n 128 -k 128", invocations[0])

            with raw_db.open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(2, len(rows))
            self.assertEqual(["pass", "pass"], [row["status"] for row in rows])
            self.assertEqual(
                make_exec_key(xclbin_sha, failed_case.app, failed_case.args),
                rows[-1]["exec_key"],
            )

            manifest = json.loads((out_root / "runs" / "resume_run" / "manifest.json").read_text())
            self.assertEqual(2, manifest["execution_count"])
            self.assertEqual(1, manifest["skipped_existing_count"])
            self.assertEqual(
                [make_exec_key(xclbin_sha, passed_case.app, passed_case.args)],
                manifest["skipped_existing_exec_keys"],
            )

    def test_skip_existing_default_columns_do_not_require_exec_key_or_iteration_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            xclbin_sha = self._write_fake_fpga_bin(fpga_bin_dir)

            case = BenchCase(
                case_id="same_command",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[case],
            )
            out_root = tmp_path / "latency_db"
            raw_db = out_root / "raw_db.csv"
            self._write_raw_db_row(
                raw_db,
                case_id=case.case_id,
                exec_key="different_exec_key",
                app=case.app,
                args=case.args,
                fpga_bin_label="improve_tcol1",
                xclbin_sha256=xclbin_sha,
                warmup="99",
                iterations="99",
                status="pass",
            )

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="resume_run",
                    skip_existing=True,
                    dry_run=True,
                ),
            )

            self.assertEqual(0, rc)
            manifest = json.loads((out_root / "runs" / "resume_run" / "manifest.json").read_text())
            self.assertEqual(["status", "xclbin_sha256", "app", "args"], manifest["skip_existing_columns"])
            self.assertEqual(1, manifest["skipped_existing_count"])
            self.assertEqual(
                [make_exec_key(xclbin_sha, case.app, case.args)],
                manifest["skipped_existing_exec_keys"],
            )
            self.assertEqual(0, manifest["run_execution_count"])

    def test_skip_existing_rejects_measurement_environment_columns(self) -> None:
        for column in (
            "exec_key",
            "warmup",
            "iterations",
            "power_interval",
        ):
            with self.subTest(column=column):
                with self.assertRaisesRegex(ValueError, "unsupported skip-existing column"):
                    normalize_skip_existing_columns(("status", "app", "args", column))

    def test_skip_existing_does_not_skip_when_xclbin_sha_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            invocation_log = tmp_path / "invocations.log"
            self._write_fake_blackbox(build_dir, invocation_log=invocation_log)
            fpga_bin_dir = tmp_path / "fpga_bin"
            current_sha = self._write_fake_fpga_bin(fpga_bin_dir, content="current bitstream")

            case = BenchCase(
                case_id="same_exec_key",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[case],
            )
            out_root = tmp_path / "latency_db"
            raw_db = out_root / "raw_db.csv"
            self._write_raw_db_row(
                raw_db,
                case_id=case.case_id,
                exec_key=case.exec_key,
                app=case.app,
                args=case.args,
                fpga_bin_label="improve_tcol1",
                xclbin_sha256="different_sha",
                warmup=case.warmup,
                iterations=case.iterations,
                status="pass",
            )

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="strict_run",
                    skip_existing=True,
                ),
            )

            self.assertEqual(0, rc)
            self.assertEqual(1, len(invocation_log.read_text().splitlines()))
            with raw_db.open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(2, len(rows))
            self.assertEqual(["different_sha", current_sha], [row["xclbin_sha256"] for row in rows])

    def test_skip_existing_columns_can_ignore_xclbin_sha_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            current_sha = self._write_fake_fpga_bin(fpga_bin_dir, content="current bitstream")

            case = BenchCase(
                case_id="same_command",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[case],
            )
            out_root = tmp_path / "latency_db"
            raw_db = out_root / "raw_db.csv"
            self._write_raw_db_row(
                raw_db,
                case_id=case.case_id,
                exec_key=case.exec_key,
                app=case.app,
                args=case.args,
                fpga_bin_label="improve_tcol1",
                xclbin_sha256="different_sha",
                warmup=case.warmup,
                iterations=case.iterations,
                status="pass",
            )

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="relaxed_run",
                    skip_existing=True,
                    skip_existing_columns=("status", "app", "args"),
                    dry_run=True,
                ),
            )

            self.assertEqual(0, rc)
            manifest = json.loads((out_root / "runs" / "relaxed_run" / "manifest.json").read_text())
            self.assertEqual(["status", "app", "args"], manifest["skip_existing_columns"])
            self.assertEqual(1, manifest["skipped_existing_count"])
            self.assertEqual(
                [make_exec_key(current_sha, case.app, case.args)],
                manifest["skipped_existing_exec_keys"],
            )
            self.assertEqual(0, manifest["run_execution_count"])

    def test_generated_script_updates_raw_db_before_post_processing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            invocation_log = tmp_path / "invocations.log"
            self._write_fake_blackbox(build_dir, invocation_log=invocation_log)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)

            case = BenchCase(
                case_id="live_raw",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                warmup=1,
                iterations=1,
            )
            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[case],
            )
            out_root = tmp_path / "latency_db"

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="script_only",
                    dry_run=True,
                ),
            )
            self.assertEqual(0, rc)

            run_dir = out_root / "runs" / "script_only"
            script = run_dir / "run_fpga_bench.sh"
            env = os.environ.copy()
            env["PYTHONPATH"] = str(Path.cwd())
            self.assertEqual(0, subprocess.call(["bash", str(script)], env=env))

            raw_db = out_root / "raw_db.csv"
            with raw_db.open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual(1, len(rows))
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual(
                make_exec_key(rows[0]["xclbin_sha256"], rows[0]["app"], rows[0]["args"]),
                rows[0]["exec_key"],
            )
            self.assertFalse((run_dir / "results.csv").exists())

            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=fpga_bin_dir,
                    fpga_bin_label="improve_tcol1",
                    out_dir=out_root,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=(),
                    srun=False,
                    program_fpga=False,
                    run_id="resume_dry",
                    skip_existing=True,
                    dry_run=True,
                ),
            )
            self.assertEqual(0, rc)
            manifest = json.loads((out_root / "runs" / "resume_dry" / "manifest.json").read_text())
            self.assertEqual(1, manifest["skipped_existing_count"])
            self.assertEqual(0, manifest["run_execution_count"])

    def test_append_rejects_legacy_raw_db_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            self._write_fake_blackbox(build_dir)
            fpga_bin_dir = tmp_path / "fpga_bin"
            self._write_fake_fpga_bin(fpga_bin_dir)

            suite = BenchSuite(
                name="mini_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        warmup=1,
                        iterations=1,
                    )
                ],
            )
            out_root = tmp_path / "latency_db"
            raw_db = out_root / "raw_db.csv"
            raw_db.parent.mkdir(parents=True)
            old_columns = [
                column for column in RAW_DB_COLUMNS
                if column not in {"elapsed_wall_s", "failure_reason"}
            ]
            with raw_db.open("w", newline="") as fp:
                writer = csv.DictWriter(fp, fieldnames=old_columns)
                writer.writeheader()
                writer.writerow({column: "" for column in old_columns})

            with self.assertRaisesRegex(ValueError, "schema mismatch"):
                run_suite(
                    suite,
                    RunOptions(
                        build_dir=build_dir,
                        fpga_bin_dir=fpga_bin_dir,
                        fpga_bin_label="improve_tcol1",
                        out_dir=out_root,
                        platform=suite.defaults.platform,
                        xrt_device_index=suite.defaults.xrt_device_index,
                        blackbox_args=(),
                        srun=False,
                        program_fpga=False,
                        run_id="schema_run",
                    ),
                )


if __name__ == "__main__":
    unittest.main()
