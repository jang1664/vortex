from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.perf_log import parse_fpga_cycle_stats


class PerfLogTest(unittest.TestCase):
    def test_parses_marked_per_iteration_core_cycles(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "bench.log"
            log.write_text(
                "\n".join(
                    [
                        "[bench-perf] iteration=1/3 begin",
                        "PERF: instrs=10, cycles=100, IPC=0.100000",
                        "[bench-perf] iteration=1/3 end",
                        "[bench-perf] iteration=2/3 begin",
                        "PERF: instrs=20, cycles=300, IPC=0.066667",
                        "[bench-perf] iteration=2/3 end",
                        "[bench-perf] iteration=3/3 begin",
                        "PERF: instrs=30, cycles=200, IPC=0.150000",
                        "[bench-perf] iteration=3/3 end",
                    ]
                )
                + "\n"
            )

            stats = parse_fpga_cycle_stats(log)

            self.assertEqual(3, stats["fpga_cycle_samples"])
            self.assertEqual(100, stats["fpga_cycle_min"])
            self.assertEqual(200, stats["fpga_cycle_avg"])
            self.assertEqual(300, stats["fpga_cycle_max"])
            self.assertEqual(200, stats["fpga_cycle_p50"])
            self.assertEqual(300, stats["fpga_cycle_p95"])
            self.assertEqual(200, stats["fpga_cycle"])
            self.assertEqual("", stats["fpga_cycle_parse_error"])

    def test_parses_legacy_single_unmarked_core_cycle_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "bench.log"
            log.write_text("PERF: instrs=9, cycles=42, IPC=0.214286\n")

            stats = parse_fpga_cycle_stats(log)

            self.assertEqual(1, stats["fpga_cycle_samples"])
            self.assertEqual(42, stats["fpga_cycle"])
            self.assertEqual("", stats["fpga_cycle_parse_error"])

    def test_reports_missing_cycle_data(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "bench.log"
            log.write_text("no performance counters here\n")

            stats = parse_fpga_cycle_stats(log)

            self.assertEqual("", stats["fpga_cycle"])
            self.assertEqual("missing_fpga_cycle", stats["fpga_cycle_parse_error"])

    def test_reports_invalid_log_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            stats = parse_fpga_cycle_stats(Path(tmp))

            self.assertEqual("", stats["fpga_cycle"])
            self.assertEqual("invalid_log_file", stats["fpga_cycle_parse_error"])


if __name__ == "__main__":
    unittest.main()
