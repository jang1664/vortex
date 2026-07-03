from __future__ import annotations

import csv
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.runner import RAW_DB_COLUMNS, RunOptions, run_suite
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite


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
  printf 'label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,run_min_w,run_avg_w,run_max_w,delta_avg_w,delta_peak_w,energy_j,power_latency,power_fpga_cycle,raw_csv\n' > "$power_summary"
  printf 'fpint_gemm,separate,run,{power_samples},10.0,2,1.0,3.0,4.0,5.0,3.0,4.0,40.0,12.5,2000,%s\n' "$power_csv" >> "$power_summary"
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
            "suite": "mini_suite",
            "case_id": "existing_case",
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
            **overrides,
        })
        raw_db.parent.mkdir(parents=True, exist_ok=True)
        write_header = not raw_db.exists()
        with raw_db.open("a", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
            if write_header:
                writer.writeheader()
            writer.writerow(row)

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
            self.assertEqual("gemm_m1_n128_k128", rows[0]["case_id"])
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

    def test_live_raw_db_keeps_all_logical_cases_for_shared_execution(self) -> None:
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
            self.assertEqual(2, len(rows))
            self.assertEqual(["case_a", "case_b"], [row["case_id"] for row in rows])
            self.assertEqual(["pass", "pass"], [row["status"] for row in rows])

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
            self.assertEqual(failed_case.exec_key, rows[-1]["exec_key"])

            manifest = json.loads((out_root / "runs" / "resume_run" / "manifest.json").read_text())
            self.assertEqual(2, manifest["execution_count"])
            self.assertEqual(1, manifest["skipped_existing_count"])
            self.assertEqual([passed_case.exec_key], manifest["skipped_existing_exec_keys"])

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
            self.assertEqual([case.exec_key], manifest["skipped_existing_exec_keys"])
            self.assertEqual(0, manifest["run_execution_count"])

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
            self._write_fake_fpga_bin(fpga_bin_dir, content="current bitstream")

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
            self.assertEqual([case.exec_key], manifest["skipped_existing_exec_keys"])
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
            self.assertEqual(case.exec_key, rows[0]["exec_key"])
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

    def test_append_migrates_raw_db_header_when_elapsed_column_is_missing(self) -> None:
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
                    run_id="schema_run",
                ),
            )

            self.assertEqual(0, rc)
            with raw_db.open(newline="") as fp:
                reader = csv.DictReader(fp)
                rows = list(reader)
            self.assertEqual(RAW_DB_COLUMNS, reader.fieldnames)
            self.assertEqual(2, len(rows))
            self.assertEqual("", rows[0]["elapsed_wall_s"])
            self.assertEqual("", rows[0]["failure_reason"])
            self.assertGreaterEqual(float(rows[1]["elapsed_wall_s"]), 0.0)


if __name__ == "__main__":
    unittest.main()
