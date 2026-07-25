from __future__ import annotations

import json
import os
import tempfile
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import yaml

from tools.latency_bench.cli import main, merge_override_args, normalize_timeout
from tools.latency_bench.fpga_bins import FPGA_BIN_ALIAS_MAP_ENV


class CliRunTest(unittest.TestCase):
    def test_blackbox_args_merge_and_override_defaults(self) -> None:
        merged = merge_override_args(
            ("--driver=xrt", "--log=old.log"),
            ["--log=new.log", "--trace"],
        )

        self.assertEqual(("--driver=xrt", "--log=new.log", "--trace"), merged)

    def test_normalize_timeout(self) -> None:
        self.assertEqual("", normalize_timeout(None))
        self.assertEqual("", normalize_timeout(""))
        self.assertEqual("", normalize_timeout("0"))
        self.assertEqual("30m", normalize_timeout(" 30m "))

    def _write_fake_inputs(self, tmp_path: Path) -> tuple[Path, Path, Path]:
        build_dir = tmp_path / "build"
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

        fpga_bin = tmp_path / "fpga_bin"
        fpga_bin.mkdir()
        (fpga_bin / "vortex_afu.xclbin").write_text("fake bitstream")

        suite = tmp_path / "suite.yaml"
        suite.write_text(
            """
name: cli_suite
defaults:
  warmup: 1
  iterations: 1
  app: fpint_gemm_ffn_hw
cases:
  - id: gemm
    args: "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"
""".lstrip()
        )
        return build_dir, fpga_bin, suite

    def _write_alias_map(self, path: Path, alias: str, fpga_bin: Path, configs: tuple[str, ...]) -> Path:
        config_path = path.parent / "configs" / f"{alias}.sh"
        config_path.parent.mkdir()
        config_path.write_text(
            "CONFIGS='{}'\nexport CONFIGS\n".format(" ".join(configs))
        )
        path.write_text(
            f"""
aliases:
  {alias}:
    path: {fpga_bin}
    configs: configs/{alias}.sh
""".lstrip()
        )
        return config_path

    @contextmanager
    def _alias_map_env(self, alias_map: Path) -> Iterator[None]:
        old_value = os.environ.get(FPGA_BIN_ALIAS_MAP_ENV)
        os.environ[FPGA_BIN_ALIAS_MAP_ENV] = str(alias_map)
        try:
            yield
        finally:
            if old_value is None:
                os.environ.pop(FPGA_BIN_ALIAS_MAP_ENV, None)
            else:
                os.environ[FPGA_BIN_ALIAS_MAP_ENV] = old_value

    def test_run_does_not_visualize_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--no-program-fpga",
            ])

            self.assertEqual(0, rc)
            self.assertTrue((out_root / "runs" / "cli_run" / "results.csv").exists())
            self.assertFalse((out_root / "runs" / "cli_run" / "figures").exists())

    def test_run_writes_fpga_programming_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "program_run",
                "--no-srun",
                "--dry-run",
                "--xrt-device-bdf", "0000:3d:00.1",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "program_run"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("source", script)
            self.assertIn("ci/xrt_device_detect.sh", script)
            self.assertIn(
                'export XRT_INI_PATH="${XRT_INI_PATH:-/dev/null}"',
                script,
            )
            self.assertIn(f"export VORTEX_RT_PATH={build_dir / 'runtime'}", script)
            self.assertIn(f"export VORTEX_KN_PATH={build_dir / 'kernel'}", script)
            self.assertIn("LATENCY_BENCH_PROGRAM_FPGA=1", script)
            self.assertIn("LATENCY_BENCH_REQUESTED_XRT_DEVICE_BDF=0000:3d:00.1", script)
            self.assertIn("LATENCY_BENCH_FPGA_IDENTITY_ENV=", script)
            self.assertIn('program --device "$user_bdf" --user "$xclbin"', script)
            self.assertNotIn("export XRT_DEVICE_INDEX=0", script)
            self.assertLess(script.index("if ! latency_bench_program_fpga"), script.index("declare -A LATENCY_BENCH_BUILD_RC"))
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertTrue(manifest["program_fpga"])
            self.assertEqual("auto", manifest["xrt_device_index_request"])
            self.assertEqual("0000:3d:00.1", manifest["xrt_device_bdf"])

    def test_run_defaults_to_separate_power_and_can_skip_latency(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "power_default",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "power_default"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("--power=separate", script)
            self.assertIn("/power/", script)
            self.assertIn("--power-csv=", script)
            self.assertIn("--power-summary=", script)
            self.assertIn("--power-auto-duration=on", script)
            self.assertIn("--power-min-run-sec=10.0", script)
            self.assertIn("--power-max-run-sec=60.0", script)
            self.assertIn("--power-max-iterations=1024", script)
            self.assertIn("--power-target-samples=100", script)
            self.assertIn("--power-latency-interval=1.0", script)
            self.assertIn("--power-min-interval=0.01", script)
            self.assertIn("--power-max-interval=1.0", script)
            self.assertIn("--power-min-samples 5", script)
            self.assertNotIn("--no-latency", script)
            self.assertIn("stage=build_begin", script)
            self.assertIn("stage=build_end", script)
            self.assertIn("stage=case_begin", script)
            self.assertIn("stage=case_args", script)
            self.assertIn("stage=run_attempt_begin", script)
            self.assertIn("stage=run_attempt_end", script)
            self.assertIn("stage=case_end", script)
            self.assertIn("2>&1 | tee -a", script)
            self.assertIn("\"$attempt_log\"", script)
            self.assertIn('if [[ -n "${NO_COLOR:-}" ]]; then', script)
            self.assertIn("LATENCY_BENCH_PROGRESS_BLUE=$'\\033[34m'", script)
            self.assertIn(
                "printf '%s[1/1]%s %s\\n' "
                '"$LATENCY_BENCH_PROGRESS_BLUE" "$LATENCY_BENCH_PROGRESS_RESET"',
                script,
            )
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertTrue(manifest["measure_latency"])
            self.assertTrue(manifest["measure_power"])
            self.assertEqual("separate", manifest["power_mode"])
            self.assertTrue(manifest["power_auto_duration"])
            self.assertEqual(1, manifest["power_kernel_iterations"])
            self.assertFalse(manifest["power_kernel_iterations_auto"])
            self.assertEqual(20.0, manifest["power_target_sec"])
            self.assertEqual(100.0, manifest["power_fpga_freq_mhz"])
            self.assertTrue(manifest["power_fpga_freq_mhz_auto"])
            self.assertEqual(10.0, manifest["power_min_run_sec"])
            self.assertEqual(60.0, manifest["power_max_run_sec"])
            self.assertEqual(1024, manifest["power_max_iterations"])
            self.assertEqual(100, manifest["power_target_samples"])
            self.assertEqual(0.01, manifest["power_min_interval"])
            self.assertEqual(1.0, manifest["power_max_interval"])
            self.assertEqual(5, manifest["power_min_samples"])

            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "power_off_latency_off",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
                "--no-latency",
                "--no-power",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "power_off_latency_off"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("--no-latency", script)
            self.assertNotIn("--power=separate", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertFalse(manifest["measure_latency"])
            self.assertFalse(manifest["measure_power"])
            self.assertEqual("off", manifest["power_mode"])
            self.assertFalse(manifest["power_auto_duration"])
            self.assertEqual(1, manifest["power_kernel_iterations"])
            self.assertFalse(manifest["power_kernel_iterations_auto"])
            self.assertEqual(20.0, manifest["power_target_sec"])
            self.assertEqual(5, manifest["power_min_samples"])

    def test_run_records_explicit_xrt_device_index_request(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "index_run",
                "--no-srun",
                "--dry-run",
                "--xrt-device-index", "1",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "index_run"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("LATENCY_BENCH_REQUESTED_XRT_DEVICE_INDEX=1", script)
            self.assertNotIn("export XRT_DEVICE_INDEX=0", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual("1", manifest["xrt_device_index_request"])

    def test_run_can_disable_power_auto_duration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "fixed_power",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
                "--no-power-auto-duration",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "fixed_power"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("--power=separate", script)
            self.assertNotIn("--power-auto-duration=on", script)
            self.assertNotIn("--power-min-run-sec=", script)
            self.assertNotIn("--power-max-iterations=", script)
            self.assertIn("--power-target-samples=100", script)
            self.assertIn("--power-latency-interval=1.0", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertFalse(manifest["power_auto_duration"])

    def test_run_can_override_power_max_iterations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "power_cap",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
                "--power-max-iterations", "256",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "power_cap"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("--power-max-iterations=256", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(256, manifest["power_max_iterations"])

    def test_run_can_override_power_kernel_iterations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "power_kernel_iters",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
                "--power",
                "--power-kernel-iterations", "64",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "power_kernel_iters"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("--power-kernel-iterations=64", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(64, manifest["power_kernel_iterations"])
            self.assertFalse(manifest["power_kernel_iterations_auto"])
            self.assertEqual(20.0, manifest["power_target_sec"])

    def test_run_can_auto_power_kernel_iterations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "power_kernel_iters_auto",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
                "--no-latency",
                "--power",
                "--power-kernel-iterations", "auto",
                "--power-target-sec", "2.5",
                "--power-fpga-freq-mhz", "125",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "power_kernel_iters_auto"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertNotIn("--no-latency", script)
            self.assertIn("--power-kernel-iterations=auto", script)
            self.assertIn("--power-target-sec=2.5", script)
            self.assertIn("--power-fpga-freq-mhz=125.0", script)
            self.assertIn("--power-xclbin-info=", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertTrue(manifest["measure_latency"])
            self.assertEqual(1, manifest["power_kernel_iterations"])
            self.assertTrue(manifest["power_kernel_iterations_auto"])
            self.assertEqual(2.5, manifest["power_target_sec"])
            self.assertEqual(125.0, manifest["power_fpga_freq_mhz"])
            self.assertFalse(manifest["power_fpga_freq_mhz_auto"])

    def test_run_rejects_invalid_power_kernel_iterations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"

            with self.assertRaisesRegex(ValueError, "--power-kernel-iterations must be >= 1"):
                main([
                    "run",
                    "--build-dir", str(build_dir),
                    "--fpga-bin", str(fpga_bin),
                    "--suite", str(suite),
                    "--out", str(out_root),
                    "--run-id", "bad_power_kernel_iters",
                    "--no-srun",
                    "--dry-run",
                    "--no-program-fpga",
                    "--power-kernel-iterations", "0",
                ])

    def test_run_rejects_invalid_power_target_sec(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"

            with self.assertRaisesRegex(ValueError, "--power-target-sec must be > 0"):
                main([
                    "run",
                    "--build-dir", str(build_dir),
                    "--fpga-bin", str(fpga_bin),
                    "--suite", str(suite),
                    "--out", str(out_root),
                    "--run-id", "bad_power_target_sec",
                    "--no-srun",
                    "--dry-run",
                    "--no-program-fpga",
                    "--power-kernel-iterations", "auto",
                    "--power-target-sec", "0",
                ])

    def test_run_can_override_power_min_samples(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "power_min_samples",
                "--no-srun",
                "--dry-run",
                "--no-program-fpga",
                "--power-min-samples", "8",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "power_min_samples"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("--power-min-samples 8", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(8, manifest["power_min_samples"])

    def test_run_blackbox_args_merge_into_generated_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
                "--blackbox-arg=--trace",
            ])

            self.assertEqual(0, rc)
            script = (out_root / "runs" / "cli_run" / "run_fpga_bench.sh").read_text()
            self.assertIn("--trace --driver=xrt", script)
            manifest = json.loads((out_root / "runs" / "cli_run" / "manifest.json").read_text())
            self.assertEqual(["--trace"], manifest["blackbox_args"])

    def test_run_blackbox_timeout_wraps_generated_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
                "--blackbox-timeout", "30m",
            ])

            self.assertEqual(0, rc)
            script = (out_root / "runs" / "cli_run" / "run_fpga_bench.sh").read_text()
            self.assertIn("timeout --kill-after=30s 30m ./ci/blackbox.sh", script)
            self.assertNotIn("timeout --foreground", script)
            self.assertIn("--build-only", script)
            self.assertIn("--run-only", script)

    def test_run_retry_writes_retry_reset_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_retry_run",
                "--no-srun",
                "--dry-run",
                "--blackbox-timeout", "30m",
                "--retry",
                "--retry-max-rounds", "4",
                "--retry-timeout-growth", "1.2",
                "--retry-reset-wait", "0",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "cli_retry_run"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn("LATENCY_BENCH_RETRY_ENABLED=1", script)
            self.assertIn("LATENCY_BENCH_RETRY_MAX_ROUNDS=4", script)
            self.assertIn("LATENCY_BENCH_CURRENT_TIMEOUT_S=1800", script)
            self.assertIn('timeout --kill-after=30s "${LATENCY_BENCH_CURRENT_TIMEOUT_S}s" ./ci/blackbox.sh', script)
            self.assertIn("LATENCY_BENCH_RESET_ADD_DEVICE=1", script)
            self.assertIn('reset_cmd+=("-d" "$reset_bdf")', script)
            self.assertIn("timeout --kill-after=10s 60s \"${reset_cmd[@]}\"", script)
            self.assertNotIn("timeout --kill-after=10s 60s srun", script)
            self.assertIn('reset_bdf="${LATENCY_BENCH_XRT_DEVICE_BDF:-${XRT_DEVICE_BDF:-}}"', script)
            self.assertIn("LATENCY_BENCH_RESET_CMD=(xrt-smi reset)", script)
            self.assertIn("attempt_status.csv", script)
            self.assertIn("latency_bench_power_failure_reason", script)
            self.assertIn("LATENCY_BENCH_RETRYABLE_FAILURES=0", script)
            self.assertIn(
                '[[ "$failure_reason" == "timeout" || "$failure_reason" == "power_samples_low" || ( "$failure_reason" == "xrt_device_open" && "$reset_rc" == "0" ) ]]',
                script,
            )
            self.assertNotIn("LATENCY_BENCH_TIMEOUT_FAILURES", script)
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertTrue(manifest["retry"])
            self.assertEqual(4, manifest["retry_max_rounds"])
            self.assertEqual(1.2, manifest["retry_timeout_growth"])
            self.assertTrue(manifest["retry_reset_add_device"])

    def test_run_accepts_skip_existing_option(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
                "--skip-existing",
            ])

            self.assertEqual(0, rc)
            manifest = json.loads((out_root / "runs" / "cli_run" / "manifest.json").read_text())
            self.assertTrue(manifest["skip_existing"])
            self.assertEqual(["status", "xclbin_sha256", "app", "args"], manifest["skip_existing_columns"])

    def test_run_accepts_skip_existing_columns_option(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
                "--skip-existing",
                "--skip-existing-columns", "status,app,args",
            ])

            self.assertEqual(0, rc)
            manifest = json.loads((out_root / "runs" / "cli_run" / "manifest.json").read_text())
            self.assertEqual(["status", "app", "args"], manifest["skip_existing_columns"])

    def test_run_uses_suite_default_fpga_bin_when_cli_arg_is_omitted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            suite.write_text(
                f"""
name: cli_suite
defaults:
  warmup: 1
  iterations: 1
  app: fpint_gemm_ffn_hw
  fpga_bin: {fpga_bin}
cases:
  - id: gemm
    args: "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"
""".lstrip()
            )
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
            ])

            self.assertEqual(0, rc)
            manifest = json.loads((out_root / "runs" / "cli_run" / "manifest.json").read_text())
            self.assertEqual(str(fpga_bin), manifest["fpga_bin_label"])
            self.assertEqual(str(fpga_bin.resolve()), manifest["fpga_bin_dir"])

    def test_run_exports_alias_compile_configs_and_records_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            config_path = self._write_alias_map(alias_map, "remap_alias", fpga_bin, ("-DPLATFORM_MEMORY_REMAP", "-DBANK_INTERLEAVE"))
            with self._alias_map_env(alias_map):
                rc = main([
                    "run",
                    "--build-dir", str(build_dir),
                    "--fpga-bin", "remap_alias",
                    "--suite", str(suite),
                    "--out", str(out_root),
                    "--run-id", "cli_run",
                    "--no-srun",
                    "--dry-run",
                ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "cli_run"
            script = (run_dir / "run_fpga_bench.sh").read_text()
            self.assertIn(
                f"source {config_path}",
                script,
            )
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(str(config_path.resolve()), manifest["configs"])
            self.assertEqual("", manifest["configs_extra"])

    def test_run_uses_suite_default_blackbox_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            suite.write_text(
                """
name: cli_suite
defaults:
  warmup: 1
  iterations: 1
  app: fpint_gemm_ffn_hw
  blackbox_timeout: 5m
cases:
  - id: gemm
    args: "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"
""".lstrip()
            )
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
            ])

            self.assertEqual(0, rc)
            script = (out_root / "runs" / "cli_run" / "run_fpga_bench.sh").read_text()
            self.assertIn("timeout --kill-after=30s 5m ./ci/blackbox.sh", script)
            self.assertNotIn("timeout --foreground", script)

            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run_no_timeout",
                "--no-srun",
                "--dry-run",
                "--blackbox-timeout", "0",
            ])

            self.assertEqual(0, rc)
            script = (out_root / "runs" / "cli_run_no_timeout" / "run_fpga_bench.sh").read_text()
            self.assertNotIn("timeout --kill-after=30s", script)

    def test_run_accepts_no_prebuild_option(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--dry-run",
                "--no-prebuild",
            ])

            self.assertEqual(0, rc)
            script = (out_root / "runs" / "cli_run" / "run_fpga_bench.sh").read_text()
            self.assertNotIn("--build-only", script)
            self.assertNotIn("--run-only", script)
            manifest = json.loads((out_root / "runs" / "cli_run" / "manifest.json").read_text())
            self.assertFalse(manifest["prebuild"])

    def test_run_filter_selects_expanded_cases_by_expression(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            suite.write_text(
                """
name: filter_suite
defaults:
  warmup: 1
  iterations: 1
cases:
  - id: prefill_gemm
    app: fpint_gemm_ffn_hw
    stage: prefill
    backend: fpint_gemm_improve
    args: "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"
  - id: decode_gemm
    app: fpint_gemm_ffn_hw
    stage: decode
    backend: fpint_gemm_improve
    args: "-m 1 -n 256 -k 128 -q 32 -t 0 -d 0"
  - id: prefill_silu
    app: silu
    stage: prefill
    backend: scalar
    args: "-n 128"
""".lstrip()
            )
            out_root = tmp_path / "out"

            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "filtered",
                "--no-srun",
                "--dry-run",
                "--filter", "app=fpint_gemm_ffn_hw & stage=prefill",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "filtered"
            expanded = yaml.safe_load((run_dir / "suite.expanded.yaml").read_text())
            self.assertEqual(["prefill_gemm"], [case["id"] for case in expanded["cases"]])
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(1, manifest["case_count"])
            self.assertEqual(1, manifest["execution_count"])
            self.assertEqual(["app=fpint_gemm_ffn_hw & stage=prefill"], manifest["case_filters"])

    def test_run_filter_supports_glob_match_operator(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            suite.write_text(
                """
name: filter_suite
defaults:
  warmup: 1
  iterations: 1
cases:
  - id: kv_cache_quant_base
    app: kv_cache_quant
    args: "-k 128 -n 32 -q 128 -d 0 -t 1"
  - id: kv_cache_quant_fused
    app: kv_cache_quant_layout_fused
    args: "-k 128 -n 32 -q 128 -d 0 -t 1"
  - id: gemm
    app: fpint_gemm_ffn_hw
    args: "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"
""".lstrip()
            )
            out_root = tmp_path / "out"

            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "filtered",
                "--no-srun",
                "--dry-run",
                "--filter", "app=~kv_cache_quant*",
            ])

            self.assertEqual(0, rc)
            expanded = yaml.safe_load((out_root / "runs" / "filtered" / "suite.expanded.yaml").read_text())
            self.assertEqual(
                ["kv_cache_quant_base", "kv_cache_quant_fused"],
                [case["id"] for case in expanded["cases"]],
            )

    def test_run_filter_allows_empty_selection_as_noop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"

            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "filtered",
                "--no-srun",
                "--filter", "stage=missing",
            ])

            self.assertEqual(0, rc)
            run_dir = out_root / "runs" / "filtered"
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(0, manifest["case_count"])
            self.assertEqual(0, manifest["execution_count"])
            self.assertEqual(0, manifest["run_execution_count"])
            self.assertTrue((run_dir / "cases.csv").exists())
            self.assertTrue((run_dir / "results.csv").exists())
            self.assertTrue((run_dir / "summary.csv").exists())

    def test_run_visualizes_when_requested(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir, fpga_bin, suite = self._write_fake_inputs(tmp_path)
            out_root = tmp_path / "out"
            rc = main([
                "run",
                "--build-dir", str(build_dir),
                "--fpga-bin", str(fpga_bin),
                "--suite", str(suite),
                "--out", str(out_root),
                "--run-id", "cli_run",
                "--no-srun",
                "--no-program-fpga",
                "--visualize",
            ])

            self.assertEqual(0, rc)
            self.assertTrue((out_root / "runs" / "cli_run" / "figures").exists())


if __name__ == "__main__":
    unittest.main()
