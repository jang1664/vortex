from __future__ import annotations

import csv
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.power_summary import read_power_summary


REPO_ROOT = Path(__file__).resolve().parents[2]


def write_sensor(hwmon: Path, kind: str, index: int, label: str, value: int) -> None:
    (hwmon / f"{kind}{index}_label").write_text(f"{label}\n")
    (hwmon / f"{kind}{index}_input").write_text(f"{value}\n")


class PowerMeasurementSplitTest(unittest.TestCase):
    def test_sampler_computes_vcc_pcie_and_total_power_from_labels(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            hwmon = tmp_path / "hwmon0"
            hwmon.mkdir()
            (hwmon / "name").write_text("fake_xilinx_u55c\n")

            write_sensor(hwmon, "in", 9, "VCC INT", 855)
            write_sensor(hwmon, "curr", 3, "VCC INT Current", 10000)
            write_sensor(hwmon, "in", 18, "VCC INT BRAM", 856)
            write_sensor(hwmon, "curr", 5, "VCC 0V85 Current", 3000)
            write_sensor(hwmon, "in", 0, "12V PEX", 12000)
            write_sensor(hwmon, "curr", 1, "12V PEX Current", 2000)
            write_sensor(hwmon, "in", 2, "3V3 PEX", 3300)
            write_sensor(hwmon, "curr", 4, "3V3 PEX Current", 1000)
            write_sensor(hwmon, "power", 1, "POWER", 999999999)

            out_csv = tmp_path / "power.csv"
            env = os.environ.copy()
            env.update(
                {
                    "XRT_DEVICE_INDEX": "0",
                    "XRT_DEVICE_BDF": "0000:00:00.1",
                    "FPGA_0_HWMON": str(hwmon),
                }
            )

            subprocess.run(
                [
                    "timeout",
                    "0.35s",
                    str(REPO_ROOT / "ci" / "measure_power.sh"),
                    "0",
                    "0.05",
                    str(out_csv),
                    "2048",
                ],
                cwd=REPO_ROOT,
                env=env,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            with out_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertGreaterEqual(len(rows), 1)
            row = rows[0]
            self.assertAlmostEqual(8.55, float(row["p_vccint_w"]), places=6)
            self.assertAlmostEqual(2.568, float(row["p_0v85_w"]), places=6)
            self.assertAlmostEqual(11.118, float(row["vcc_power_w"]), places=6)
            self.assertAlmostEqual(24.0, float(row["p_pcie12v_w"]), places=6)
            self.assertAlmostEqual(3.3, float(row["p_pcie3v3_w"]), places=6)
            self.assertAlmostEqual(27.3, float(row["pcie_power_w"]), places=6)
            self.assertAlmostEqual(38.418, float(row["total_power_w"]), places=6)

    def test_sampler_stops_and_marks_truncated_csv_at_size_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            hwmon = tmp_path / "hwmon0"
            hwmon.mkdir()
            (hwmon / "name").write_text("fake_xilinx_u55c\n")
            write_sensor(hwmon, "in", 9, "VCC INT", 855)
            write_sensor(hwmon, "curr", 3, "VCC INT Current", 10000)
            write_sensor(hwmon, "in", 18, "VCC INT BRAM", 856)
            write_sensor(hwmon, "curr", 5, "VCC 0V85 Current", 3000)
            write_sensor(hwmon, "in", 0, "12V PEX", 12000)
            write_sensor(hwmon, "curr", 1, "12V PEX Current", 2000)
            write_sensor(hwmon, "in", 2, "3V3 PEX", 3300)
            write_sensor(hwmon, "curr", 4, "3V3 PEX Current", 1000)

            out_csv = tmp_path / "power.csv"
            env = os.environ.copy()
            env.update({"XRT_DEVICE_INDEX": "0", "FPGA_0_HWMON": str(hwmon)})
            result = subprocess.run(
                [
                    str(REPO_ROOT / "ci" / "measure_power.sh"),
                    "0",
                    "0.01",
                    str(out_csv),
                    "1",
                ],
                cwd=REPO_ROOT,
                env=env,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=2,
            )

            self.assertEqual(0, result.returncode)
            self.assertTrue(Path(f"{out_csv}.truncated").exists())
            self.assertIn("stopping sampler", result.stderr)

    def test_power_summary_parser_reads_split_power_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "power.summary.csv"
            summary.write_text(
                "label,mode,phase,samples,elapsed_s,idle_samples,"
                "idle_avg_w,idle_std_w,idle_vcc_avg_w,idle_pcie_avg_w,"
                "run_min_w,run_avg_w,run_max_w,run_std_w,"
                "run_vcc_min_w,run_vcc_avg_w,run_vcc_max_w,"
                "run_pcie_min_w,run_pcie_avg_w,run_pcie_max_w,"
                "delta_avg_w,delta_peak_w,dynamic_stderr_w,energy_j,raw_csv\n"
                "eladd,separate,run,8,4.0,3,"
                "30.0,1.5,10.0,20.0,"
                "33.0,37.0,41.0,2.5,"
                "11.0,12.0,13.0,"
                "22.0,25.0,28.0,"
                "7.0,11.0,0.95,28.0,power.csv\n"
            )

            power = read_power_summary(summary)

            self.assertEqual(37.0, power["power_avg_w"])
            self.assertEqual(1.5, power["power_idle_std_w"])
            self.assertEqual(2.5, power["power_std_w"])
            self.assertEqual(10.0, power["power_idle_vcc_avg_w"])
            self.assertEqual(20.0, power["power_idle_pcie_avg_w"])
            self.assertEqual(12.0, power["power_vcc_avg_w"])
            self.assertEqual(25.0, power["power_pcie_avg_w"])
            self.assertEqual(7.0, power["power_dynamic_avg_w"])
            self.assertEqual(0.95, power["power_dynamic_stderr_w"])

    def test_power_summary_parser_reads_capture_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "power.summary.csv"
            summary.write_text(
                "label,mode,phase,samples,elapsed_s,run_min_w,run_avg_w,run_max_w,"
                "power_source,power_raw_truncated\n"
                "eladd,latency,run,100,101.0,30.0,31.0,32.0,latency,1\n"
            )

            power = read_power_summary(summary)

            self.assertEqual("latency", power["power_source"])
            self.assertEqual(1, power["power_raw_truncated"])


if __name__ == "__main__":
    unittest.main()
