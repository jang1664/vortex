from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.runner import RunOptions, run_script_command, slurm_run_mode


class RunnerRetryScriptTest(unittest.TestCase):
    def _options(self, *, srun: bool = True) -> RunOptions:
        return RunOptions(
            build_dir=Path("/build"),
            fpga_bin_dir=Path("/fpga"),
            out_dir=Path("/out"),
            platform="xilinx_u55c_gen3x16_xdma_3_202210_1",
            srun=srun,
            srun_args=("--gres=fpga:u55c:1", "--time=1:00:00"),
        )

    def test_run_command_uses_one_managed_srun_outside_slurm(self) -> None:
        options = self._options(srun=True)

        self.assertEqual("managed_srun", slurm_run_mode(options, {}))
        self.assertEqual(
            ["srun", "--gres=fpga:u55c:1", "--time=1:00:00", "bash", "/out/run_fpga_bench.sh"],
            run_script_command(Path("/out/run_fpga_bench.sh"), options, {}),
        )

    def test_run_command_does_not_nest_srun_inside_allocation(self) -> None:
        options = self._options(srun=True)

        self.assertEqual("inherited_slurm", slurm_run_mode(options, {"SLURM_JOB_ID": "123"}))
        self.assertEqual(
            ["bash", "/out/run_fpga_bench.sh"],
            run_script_command(Path("/out/run_fpga_bench.sh"), options, {"SLURM_JOB_ID": "123"}),
        )

    def test_xrt_context_retry_resets_before_continue(self) -> None:
        runner = Path(__file__).with_name("runner.py").read_text()
        start = runner.index('"    xrt_open_failure=')
        continue_pos = runner.index('"      continue",', start)
        reset_pos = runner.index("latency_bench_reset_fpga", start)

        self.assertLess(reset_pos, continue_pos)
        self.assertIn("Could not open device", runner[start:continue_pos])
        self.assertIn("xrt_device_open", runner[start:continue_pos])

    def test_power_samples_low_is_retryable(self) -> None:
        runner = Path(__file__).with_name("runner.py").read_text()

        self.assertIn("latency_bench_power_failure_reason", runner)
        self.assertIn("power_samples_low", runner)
        self.assertIn("LATENCY_BENCH_RETRYABLE_FAILURES", runner)
        self.assertIn(
            '[[ "$failure_reason" == "timeout" || "$failure_reason" == "power_samples_low" || ( "$failure_reason" == "xrt_device_open" && "$reset_rc" == "0" ) ]]',
            runner,
        )
        choice_prefix = 'choices=["", "build", "timeout", "xrt_context_open", "xrt_device_open"'
        for filename in ("raw_db.py", "progress.py", "append_raw.py"):
            self.assertIn(choice_prefix, Path(__file__).with_name(filename).read_text())
        self.assertNotIn("LATENCY_BENCH_TIMEOUT_FAILURES", runner)

    def test_xrt_detector_falls_back_to_single_global_bdf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fake_xrt_smi = Path(tmp) / "xrt-smi"
            fake_xrt_smi.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
uses_device=0
for arg in "$@"; do
  if [[ "$arg" == "--device" ]]; then
    uses_device=1
  fi
done
if [[ "$uses_device" == "1" ]]; then
  printf 'per-index examine unavailable\\n' >&2
  exit 2
fi
printf 'Device [0000:3d:00.1]\\n'
"""
            )
            fake_xrt_smi.chmod(0o755)

            repo_root = Path(__file__).resolve().parents[2]
            result = subprocess.run(
                [
                    "bash",
                    "-lc",
                    f"source {repo_root / 'ci' / 'xrt_device_detect.sh'}; "
                    f"detect_single_accessible_xrt_index {fake_xrt_smi}",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

        self.assertEqual("1", result.stdout.strip())

    def test_xrt_detector_retries_index_probe_without_batch_force(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fake_xrt_smi = Path(tmp) / "xrt-smi"
            fake_xrt_smi.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
uses_batch=0
uses_device=0
device=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --batch|--force)
      uses_batch=1
      ;;
    --device)
      uses_device=1
      device="${2:-}"
      shift
      ;;
  esac
  shift
done
if [[ "$uses_batch" == "1" ]]; then
  printf 'unsupported option\\n' >&2
  exit 2
fi
if [[ "$uses_device" == "1" && "$device" == "1" ]]; then
  printf 'Device [0000:3d:00.1]\\n'
  exit 0
fi
exit 2
"""
            )
            fake_xrt_smi.chmod(0o755)

            repo_root = Path(__file__).resolve().parents[2]
            result = subprocess.run(
                [
                    "bash",
                    "-lc",
                    f"source {repo_root / 'ci' / 'xrt_device_detect.sh'}; "
                    f"detect_single_accessible_xrt_index {fake_xrt_smi}",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

        self.assertEqual("1", result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
