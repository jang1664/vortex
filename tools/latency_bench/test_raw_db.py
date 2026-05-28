from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.runner import RunOptions, run_suite
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite


class RawDbTest(unittest.TestCase):
    def test_run_appends_results_to_top_level_raw_db(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
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
            fpga_bin_dir = tmp_path / "fpga_bin"
            fpga_bin_dir.mkdir()
            (fpga_bin_dir / "vortex_afu.xclbin").write_text("fake bitstream")

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
            self.assertEqual("2.0", rows[0]["p50_us"])


if __name__ == "__main__":
    unittest.main()
