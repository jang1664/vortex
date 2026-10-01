import csv
import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "parse_floorplan_util.py"
SPEC = importlib.util.spec_from_file_location("parse_floorplan_util", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
parse_floorplan_util = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = parse_floorplan_util
SPEC.loader.exec_module(parse_floorplan_util)


class ParseFloorplanUtilTests(unittest.TestCase):
    def write_csv(self, directory: Path) -> Path:
        path = directory / "util.csv"
        rows = [
            ("SIMT (excl. memory)", 254041, 180948, 147, 0, 104),
            ("Cache / LMEM / TMEM", 75372, 93901, 269.5, 96, 0),
            ("MXU", 147346, 50430, 0, 60, 1857),
            ("DMA", 60957, 16432, 94, 0, 168),
            ("Misc. (incl. interconnect)", 84373, 74445, 23, 0, 142),
            ("Total Vortex_axi", 622089, 416156, 533.5, 156, 2271),
        ]
        with path.open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["category", "lut", "ff", "bram", "uram", "dsp"])
            writer.writerows(rows)
        return path

    def test_loads_groups_and_computes_u55c_percentages(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_csv(Path(temp_dir))
            usage = parse_floorplan_util.load_utilization(path)
            table = parse_floorplan_util.render_figure_11_table(usage)

        self.assertEqual(147346, usage["GEMM"].values["lut"])
        self.assertIn("147,346 (11.30%)", table)
        self.assertIn("622,089 (47.72%)", table)
        self.assertIn("2,271 (25.17%)", table)

    def test_main_prints_source_and_table(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_csv(Path(temp_dir))
            output = io.StringIO()
            with redirect_stdout(output):
                result = parse_floorplan_util.main([str(path)])

        self.assertEqual(0, result)
        self.assertIn("Percentages are relative to total Alveo U55C", output.getvalue())
        self.assertIn("| GEMM |", output.getvalue())

    def test_rejects_total_that_does_not_match_groups(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_csv(Path(temp_dir))
            text = path.read_text().replace(
                "Total Vortex_axi,622089",
                "Total Vortex_axi,622088",
            )
            path.write_text(text)

            with self.assertRaisesRegex(ValueError, "group sum"):
                parse_floorplan_util.load_utilization(path)


if __name__ == "__main__":
    unittest.main()
