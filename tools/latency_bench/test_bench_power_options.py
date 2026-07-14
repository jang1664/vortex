from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def active_regression_bench_dirs() -> list[Path]:
    return sorted(
        path.parent
        for path in (REPO_ROOT / "tests" / "regression").glob("*/bench_main.cpp")
        if "deprecated" not in path.parts
    )


def active_kernel_sources(app_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in app_dir.glob("kernel*.cpp")
        if ".modified_old." not in path.name
    )


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

    def test_active_power_benches_expose_kernel_iterations(self) -> None:
        missing: list[str] = []

        for app_dir in active_regression_bench_dirs():
            bench = (app_dir / "bench_main.cpp").read_text()
            common = (app_dir / "common.h").read_text()
            rel = app_dir.relative_to(REPO_ROOT)
            kernels = active_kernel_sources(app_dir)

            if "vx_bench::prepare_power_kernel_iterations" not in bench:
                missing.append(f"{rel}/bench_main.cpp: missing shared power kernel iteration upload")
            if "power_kernel_iterations" not in common:
                missing.append(f"{rel}/common.h: missing kernel_arg_t power_kernel_iterations")
            if not kernels:
                missing.append(f"{rel}: missing active kernel source")
            for kernel_path in kernels:
                kernel = kernel_path.read_text()
                if "effective_power_kernel_iterations" not in kernel:
                    missing.append(
                        f"{kernel_path.relative_to(REPO_ROOT)}: missing inner power iteration loop"
                    )

        self.assertEqual([], missing)

    def test_common_power_kernel_iterations_exposes_auto_mode(self) -> None:
        text = (REPO_ROOT / "tests" / "common" / "bench_util.h").read_text()
        required = {
            "power_kernel_iterations_auto": "missing auto mode state",
            "power_target_sec": "missing power target duration state",
            "power_fpga_freq_mhz": "missing FPGA frequency state",
            "power_xclbin_info": "missing xclbin.info state",
            "--power-kernel-iterations-auto": "missing explicit auto CLI option",
            "--power-target-sec": "missing target duration CLI option",
            "--power-fpga-freq-mhz": "missing FPGA frequency CLI option",
            "--power-xclbin-info": "missing xclbin.info CLI option",
            "\"auto\"": "missing --power-kernel-iterations=auto parser",
            "latency_enabled = true": "auto mode must force latency measurement on",
            "parse_data_clk_mhz_from_xclbin_info": "missing DATA_CLK parser",
            "resolve_power_fpga_freq_mhz": "missing DATA_CLK resolver",
            "fpga_cycle": "auto iterations must use FPGA cycle snapshot",
        }
        missing = [message for token, message in required.items() if token not in text]

        self.assertEqual([], missing)

    def test_common_power_long_option_prefix_lengths_are_exact(self) -> None:
        text = (REPO_ROOT / "tests" / "common" / "bench_util.h").read_text()
        expected = {
            "--power-kernel-iterations=": 26,
            "--power-kernel-iterations-auto=": 31,
            "--power-target-sec=": 19,
            "--power-fpga-freq-mhz=": 22,
            "--power-xclbin-info=": 20,
        }
        missing: list[str] = []

        for flag, length in expected.items():
            if f'std::strncmp(s, "{flag}", {length}) == 0' not in text:
                missing.append(f"missing exact strncmp length for {flag}")
            if f"s + {length}" not in text:
                missing.append(f"missing exact value offset for {flag}")

        self.assertEqual([], missing)

    def test_active_power_benches_compute_auto_kernel_iterations(self) -> None:
        missing: list[str] = []

        for app_dir in active_regression_bench_dirs():
            bench_path = app_dir / "bench_main.cpp"
            text = bench_path.read_text()
            rel = bench_path.relative_to(REPO_ROOT)

            if "first_latency_us" not in text:
                missing.append(f"{rel}: missing first latency capture")
            if "first_iter_perf" not in text:
                missing.append(f"{rel}: missing first iteration perf snapshot")
            if "first_fpga_cycle_delta" in text:
                missing.append(f"{rel}: must not use begin/end FPGA cycle delta")
            if "vx_bench::prepare_power_kernel_iterations" not in text:
                missing.append(f"{rel}: missing shared auto iteration helper")

        self.assertEqual([], missing)


if __name__ == "__main__":
    unittest.main()
