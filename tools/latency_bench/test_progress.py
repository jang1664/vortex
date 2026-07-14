from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.progress import append_progress_execution


class ProgressTest(unittest.TestCase):
    def test_appends_progress_row_with_measurements(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_csv = tmp_path / "raw.csv"
            raw_csv.write_text("# comment\nfpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n")
            log_file = tmp_path / "bench.log"
            log_file.write_text(
                "[bench-perf] iteration=1/3 begin\n"
                "PERF: instrs=10, cycles=100, IPC=0.100000\n"
                "[bench-perf] iteration=1/3 end\n"
                "[bench-perf] iteration=2/3 begin\n"
                "PERF: instrs=20, cycles=300, IPC=0.066667\n"
                "[bench-perf] iteration=2/3 end\n"
                "[bench-perf] iteration=3/3 begin\n"
                "PERF: instrs=30, cycles=200, IPC=0.150000\n"
                "[bench-perf] iteration=3/3 end\n"
            )
            power_csv = tmp_path / "power.csv"
            power_summary = tmp_path / "power.summary.csv"
            power_summary.write_text(
                "label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,idle_std_w,"
                "run_min_w,run_avg_w,run_max_w,run_std_w,delta_avg_w,delta_peak_w,dynamic_stderr_w,energy_j,"
                "power_latency,power_fpga_cycle,raw_csv\n"
                f"fpint_gemm,separate,run,5,10.0,2,1.0,0.1,3.0,4.0,5.0,0.2,3.0,4.0,0.15,40.0,12.5,2000,{power_csv}\n"
            )
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=2,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128",
                warmup=1,
                iterations=3,
                returncode=0,
                elapsed_wall_s="12.345",
                raw_csv=raw_csv,
                power_csv=power_csv,
                power_summary=power_summary,
                log_file=log_file,
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual(1, len(rows))
            self.assertEqual("1", rows[0]["idx"])
            self.assertEqual("2", rows[0]["total"])
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual("12.345", rows[0]["elapsed_wall_s"])
            self.assertEqual("", rows[0]["failure_reason"])
            self.assertEqual("2.0", rows[0]["p50_us"])
            self.assertEqual("3", rows[0]["fpga_cycle_samples"])
            self.assertEqual("100", rows[0]["fpga_cycle_min"])
            self.assertEqual("200", rows[0]["fpga_cycle_avg"])
            self.assertEqual("300", rows[0]["fpga_cycle_max"])
            self.assertEqual("200", rows[0]["fpga_cycle_p50"])
            self.assertEqual("300", rows[0]["fpga_cycle_p95"])
            self.assertEqual("200", rows[0]["fpga_cycle"])
            self.assertEqual("", rows[0]["fpga_cycle_parse_error"])
            self.assertEqual("", rows[0]["parse_error"])
            self.assertEqual(str(power_csv), rows[0]["power_csv"])
            self.assertEqual(str(power_summary), rows[0]["power_summary"])
            self.assertEqual("5", rows[0]["power_samples"])
            self.assertEqual("10.0", rows[0]["power_elapsed_s"])
            self.assertEqual("3.0", rows[0]["power_min_w"])
            self.assertEqual("4.0", rows[0]["power_avg_w"])
            self.assertEqual("5.0", rows[0]["power_max_w"])
            self.assertEqual("0.2", rows[0]["power_std_w"])
            self.assertEqual("0.1", rows[0]["power_idle_std_w"])
            self.assertEqual("0.15", rows[0]["power_dynamic_stderr_w"])
            self.assertEqual("12.5", rows[0]["power_latency"])
            self.assertEqual("2000", rows[0]["power_fpga_cycle"])
            self.assertEqual("", rows[0]["power_parse_error"])

    def test_low_power_samples_records_failure_reason(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_csv = tmp_path / "raw.csv"
            raw_csv.write_text("fpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n")
            power_csv = tmp_path / "power.csv"
            power_summary = tmp_path / "power.summary.csv"
            power_summary.write_text(
                "label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,"
                "run_min_w,run_avg_w,run_max_w,delta_avg_w,delta_peak_w,energy_j,"
                "latency_samples,latency_min_us,latency_avg_us,latency_max_us,raw_csv\n"
                f"fpint_gemm,separate,run,4,10.0,2,1.0,3.0,4.0,5.0,3.0,4.0,40.0,0,nan,nan,nan,{power_csv}\n"
            )
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=1,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128",
                warmup=1,
                iterations=3,
                returncode=0,
                elapsed_wall_s="12.345",
                raw_csv=raw_csv,
                power_csv=power_csv,
                power_summary=power_summary,
                log_file=tmp_path / "bench.log",
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual("fail", rows[0]["status"])
            self.assertEqual("power_samples_low", rows[0]["failure_reason"])
            self.assertEqual("4", rows[0]["power_samples"])
            self.assertEqual("", rows[0]["power_parse_error"])

    def test_failed_execution_records_parse_error_without_parse_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=1,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="app_a",
                args="--bad",
                warmup=0,
                iterations=1,
                returncode=1,
                elapsed_wall_s="0.010",
                raw_csv=tmp_path / "missing.csv",
                log_file=tmp_path / "bench.log",
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual("fail", rows[0]["status"])
            self.assertEqual("", rows[0]["failure_phase"])
            self.assertEqual("", rows[0]["failure_reason"])
            self.assertEqual("missing_raw_csv", rows[0]["parse_error"])

    def test_build_failure_records_build_fail_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=1,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="app_a",
                args="",
                warmup=0,
                iterations=1,
                returncode=2,
                elapsed_wall_s="0.000",
                raw_csv=tmp_path / "missing.csv",
                log_file=tmp_path / "build.log",
                failure_phase="build",
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual("build_fail", rows[0]["status"])
            self.assertEqual("build", rows[0]["failure_phase"])
            self.assertEqual("build", rows[0]["failure_reason"])
            self.assertEqual("missing_raw_csv", rows[0]["parse_error"])

    def test_parse_error_records_failure_reason_for_zero_returncode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=1,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="app_a",
                args="",
                warmup=0,
                iterations=1,
                returncode=0,
                elapsed_wall_s="0.010",
                raw_csv=tmp_path / "missing.csv",
                log_file=tmp_path / "bench.log",
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual("parse_error", rows[0]["status"])
            self.assertEqual("parse_error", rows[0]["failure_reason"])


if __name__ == "__main__":
    unittest.main()
