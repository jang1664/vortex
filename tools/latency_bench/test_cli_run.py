from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.cli import main


class CliRunTest(unittest.TestCase):
    def _write_fake_inputs(self, tmp_path: Path) -> tuple[Path, Path, Path]:
        build_dir = tmp_path / "build"
        (build_dir / "ci").mkdir(parents=True)
        blackbox = build_dir / "ci" / "blackbox.sh"
        blackbox.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
bench_args=""
log_file=""
for arg in "$@"; do
  case "$arg" in
    --args=*) bench_args="${arg#--args=}" ;;
    --log=*) log_file="${arg#--log=}" ;;
  esac
done
raw_csv=$(printf '%s\n' "$bench_args" | sed -n 's/.*--output=\\([^ ]*\\).*/\\1/p')
mkdir -p "$(dirname "$raw_csv")" "$(dirname "$log_file")"
printf 'fpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n' > "$raw_csv"
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
            ])

            self.assertEqual(0, rc)
            self.assertTrue((out_root / "runs" / "cli_run" / "results.csv").exists())
            self.assertFalse((out_root / "runs" / "cli_run" / "figures").exists())

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
                "--visualize",
            ])

            self.assertEqual(0, rc)
            self.assertTrue((out_root / "runs" / "cli_run" / "figures").exists())


if __name__ == "__main__":
    unittest.main()
