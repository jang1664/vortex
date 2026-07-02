from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class BenchPowerOptionsTest(unittest.TestCase):
    def test_all_power_benches_expose_power_latency_option(self) -> None:
        missing: list[str] = []
        bench_files = sorted((REPO_ROOT / "tests" / "regression").glob("**/bench_main.cpp"))

        for path in bench_files:
            text = path.read_text()
            if "vx_bench::run_power_measurement(" not in text:
                continue
            rel = path.relative_to(REPO_ROOT)
            if "--power-measure-latency" not in text:
                missing.append(f"{rel}: usage missing --power-measure-latency")
            if "bench.power_measure_latency" not in text:
                missing.append(f"{rel}: run_power_measurement missing bench.power_measure_latency")

        self.assertEqual([], missing)


if __name__ == "__main__":
    unittest.main()
